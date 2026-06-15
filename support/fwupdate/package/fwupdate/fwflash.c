#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <mtd/mtd-user.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define COPY_BUFFER (64U * 1024U)
#define ROOTFS_PARTITION_SIZE (8U * 1024U * 1024U)
#define OVERLAY_PARTITION_SIZE (5U * 1024U * 1024U)
#define DEFAULT_STATUS "/run/fwupdate/status.json"
#define DEFAULT_LOG "/run/fwupdate/flash.log"

struct image_job {
    const char *label;
    const char *image;
    const char *device;
    const char *rollback;
    uint32_t expected_partition_size;
    int progress_start;
    int progress_end;
};

static const char *status_path = DEFAULT_STATUS;
static const char *log_path = DEFAULT_LOG;
static const char *status_source = "";
static const char *status_firmware = "";
static FILE *log_file;
static bool reboot_after = true;

static void json_escape(FILE *f, const char *s) {
    const unsigned char *p = (const unsigned char *)(s ? s : "");
    for (; *p; ++p) {
        switch (*p) {
        case '\\': fputs("\\\\", f); break;
        case '"': fputs("\\\"", f); break;
        case '\n': fputs("\\n", f); break;
        case '\r': fputs("\\r", f); break;
        case '\t': fputs("\\t", f); break;
        default:
            if (*p < 0x20) fprintf(f, "\\u%04x", *p);
            else fputc(*p, f);
        }
    }
}

static void write_status(const char *state, const char *stage, int progress,
                         const char *message) {
    char tmp[512];
    time_t now = time(NULL);
    snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", status_path, (long)getpid());
    FILE *f = fopen(tmp, "w");
    if (f) {
        fputs("{\"state\":\"", f); json_escape(f, state);
        fputs("\",\"stage\":\"", f); json_escape(f, stage);
        fprintf(f, "\",\"progress\":%d,\"timestamp\":%ld,\"message\":\"",
                progress, (long)now);
        json_escape(f, message);
        fputs("\",\"source\":\"", f); json_escape(f, status_source);
        fputs("\",\"firmware\":\"", f); json_escape(f, status_firmware);
        fputs("\"}\n", f);
        if (fflush(f) == 0) (void)fsync(fileno(f));
        fclose(f);
        (void)rename(tmp, status_path);
    }
    if (log_file) {
        fprintf(log_file, "%ld|%s|%s|%d|%s\n", (long)now, state, stage,
                progress, message ? message : "");
        fflush(log_file);
        (void)fsync(fileno(log_file));
    }
}

static void log_statusf(const char *state, const char *stage, int progress,
                        const char *fmt, ...) {
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    write_status(state, stage, progress, msg);
}

static void reboot_system(void) {
    sync();
    sleep(3);
    (void)reboot(RB_AUTOBOOT);
    int fd = open("/proc/sysrq-trigger", O_WRONLY);
    if (fd >= 0) {
        (void)write(fd, "b", 1);
        close(fd);
    }
}

static void fatal(const char *stage, const char *fmt, ...) {
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    write_status("error", stage, 100, msg);
    fprintf(stderr, "fwflash: %s\n", msg);
    if (reboot_after) reboot_system();
    exit(EXIT_FAILURE);
}

static off_t file_size(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0)
        fatal("preflight", "stat(%s): %s", path, strerror(errno));
    if (!S_ISREG(st.st_mode))
        fatal("preflight", "%s is not a regular file", path);
    return st.st_size;
}

static int progress_between(const struct image_job *job, uint64_t done,
                            uint64_t total) {
    if (!total) return job->progress_start;
    uint64_t span = (uint64_t)(job->progress_end - job->progress_start);
    return job->progress_start + (int)((span * done) / total);
}

static bool erase_partition(int fd, const struct mtd_info_user *mtd,
                            const struct image_job *job,
                            char *why, size_t whylen) {
    struct erase_info_user erase;
    uint64_t blocks = mtd->size / mtd->erasesize;
    for (uint64_t i = 0; i < blocks; ++i) {
        erase.start = (uint32_t)(i * mtd->erasesize);
        erase.length = mtd->erasesize;
        if (ioctl(fd, MEMERASE, &erase) != 0) {
            snprintf(why, whylen, "%s erase failed at 0x%08x: %s",
                     job->label, erase.start, strerror(errno));
            return false;
        }
        if ((i & 7U) == 0 || i + 1 == blocks) {
            int p = progress_between(job, i + 1, blocks * 3U);
            log_statusf("flashing", "erase", p,
                        "Erasing %s (%llu/%llu blocks)", job->label,
                        (unsigned long long)(i + 1),
                        (unsigned long long)blocks);
        }
    }
    return true;
}

static bool write_image(int devfd, int imgfd, off_t size,
                        const struct mtd_info_user *mtd,
                        const struct image_job *job,
                        char *why, size_t whylen) {
    unsigned char *buf = malloc(COPY_BUFFER);
    if (!buf) fatal("write", "out of memory");
    off_t done = 0;
    if (lseek(devfd, 0, SEEK_SET) < 0 || lseek(imgfd, 0, SEEK_SET) < 0) {
        snprintf(why, whylen, "seek failed: %s", strerror(errno));
        free(buf);
        return false;
    }
    while (done < size) {
        size_t want = (size - done > (off_t)COPY_BUFFER)
                          ? COPY_BUFFER : (size_t)(size - done);
        ssize_t nr = read(imgfd, buf, want);
        if (nr <= 0) {
            snprintf(why, whylen, "read(%s) failed: %s", job->image,
                     nr == 0 ? "unexpected EOF" : strerror(errno));
            free(buf);
            return false;
        }
        size_t off = 0;
        while (off < (size_t)nr) {
            ssize_t nw = write(devfd, buf + off, (size_t)nr - off);
            if (nw <= 0) {
                snprintf(why, whylen, "write(%s) failed: %s", job->device,
                         nw == 0 ? "short write" : strerror(errno));
                free(buf);
                return false;
            }
            off += (size_t)nw;
        }
        done += nr;
        int p = progress_between(job, mtd->size + (uint64_t)done,
                                 (uint64_t)mtd->size * 3U);
        log_statusf("flashing", "write", p,
                    "Writing %s (%lld/%lld bytes)", job->label,
                    (long long)done, (long long)size);
    }
    if (fsync(devfd) != 0 && errno != EINVAL && errno != ENOTTY) {
        snprintf(why, whylen, "fsync(%s): %s", job->device, strerror(errno));
        free(buf);
        return false;
    }
    free(buf);
    return true;
}

static bool compare_image(int devfd, int imgfd, off_t size,
                          const struct mtd_info_user *mtd,
                          const struct image_job *job,
                          char *why, size_t whylen) {
    unsigned char *a = malloc(COPY_BUFFER);
    unsigned char *b = malloc(COPY_BUFFER);
    if (!a || !b) fatal("verify", "out of memory");
    if (lseek(devfd, 0, SEEK_SET) < 0 || lseek(imgfd, 0, SEEK_SET) < 0) {
        snprintf(why, whylen, "verify seek failed: %s", strerror(errno));
        free(a); free(b);
        return false;
    }
    off_t done = 0;
    while (done < size) {
        size_t want = (size - done > (off_t)COPY_BUFFER)
                          ? COPY_BUFFER : (size_t)(size - done);
        ssize_t ni = read(imgfd, a, want);
        ssize_t nd = read(devfd, b, want);
        if (ni != (ssize_t)want || nd != (ssize_t)want) {
            snprintf(why, whylen, "short read at offset %lld",
                     (long long)done);
            free(a); free(b);
            return false;
        }
        if (memcmp(a, b, want) != 0) {
            size_t i;
            for (i = 0; i < want && a[i] == b[i]; ++i) {}
            snprintf(why, whylen, "data mismatch at offset %lld",
                     (long long)(done + (off_t)i));
            free(a); free(b);
            return false;
        }
        done += (off_t)want;
        int p = progress_between(job,
                                 (uint64_t)mtd->size * 2U + (uint64_t)done,
                                 (uint64_t)mtd->size * 3U);
        log_statusf("flashing", "verify", p,
                    "Verifying %s (%lld/%lld bytes)", job->label,
                    (long long)done, (long long)size);
    }

    /* The complete partition was erased. Confirm any unwritten tail is 0xff. */
    off_t tail = size;
    memset(a, 0xff, COPY_BUFFER);
    while (tail < (off_t)mtd->size) {
        size_t want = ((off_t)mtd->size - tail > (off_t)COPY_BUFFER)
                          ? COPY_BUFFER
                          : (size_t)((off_t)mtd->size - tail);
        ssize_t nd = read(devfd, b, want);
        if (nd != (ssize_t)want) {
            snprintf(why, whylen, "short tail read at offset %lld",
                     (long long)tail);
            free(a); free(b);
            return false;
        }
        if (memcmp(a, b, want) != 0) {
            size_t i;
            for (i = 0; i < want && b[i] == 0xff; ++i) {}
            snprintf(why, whylen, "non-erased tail at offset %lld",
                     (long long)(tail + (off_t)i));
            free(a); free(b);
            return false;
        }
        tail += (off_t)want;
    }
    free(a); free(b);
    return true;
}

static bool program_once(const struct image_job *job,
                         char *why, size_t whylen) {
    int imgfd = -1, devfd = -1;
    struct mtd_info_user mtd;
    off_t size = file_size(job->image);

    imgfd = open(job->image, O_RDONLY);
    if (imgfd < 0) {
        snprintf(why, whylen, "open(%s): %s", job->image, strerror(errno));
        return false;
    }
    devfd = open(job->device, O_RDWR | O_SYNC);
    if (devfd < 0) {
        snprintf(why, whylen, "open(%s): %s", job->device, strerror(errno));
        close(imgfd);
        return false;
    }
    if (ioctl(devfd, MEMGETINFO, &mtd) != 0) {
        snprintf(why, whylen, "MEMGETINFO(%s): %s", job->device,
                 strerror(errno));
        close(imgfd); close(devfd);
        return false;
    }
    if (mtd.type != MTD_NORFLASH) {
        snprintf(why, whylen, "%s is not NOR flash (MTD type %u)",
                 job->device, mtd.type);
        close(imgfd); close(devfd);
        return false;
    }
    if (mtd.size != job->expected_partition_size) {
        snprintf(why, whylen, "%s size %u does not match expected %u",
                 job->device, mtd.size, job->expected_partition_size);
        close(imgfd); close(devfd);
        return false;
    }
    if (size <= 0 || size > (off_t)mtd.size) {
        snprintf(why, whylen, "image size %lld is outside partition size %u",
                 (long long)size, mtd.size);
        close(imgfd); close(devfd);
        return false;
    }
    if (mtd.erasesize == 0 || (mtd.size % mtd.erasesize) != 0) {
        snprintf(why, whylen, "invalid MTD erase geometry");
        close(imgfd); close(devfd);
        return false;
    }

    bool ok = erase_partition(devfd, &mtd, job, why, whylen);
    if (ok) ok = write_image(devfd, imgfd, size, &mtd, job, why, whylen);
    if (ok) ok = compare_image(devfd, imgfd, size, &mtd, job, why, whylen);
    close(imgfd);
    close(devfd);
    return ok;
}

static bool program_job(const struct image_job *job,
                        char *why, size_t whylen) {
    for (int attempt = 1; attempt <= 2; ++attempt) {
        log_statusf("flashing", "start", job->progress_start,
                    "Programming %s (attempt %d/2)", job->label, attempt);
        if (program_once(job, why, whylen)) {
            log_statusf("flashing", "verified", job->progress_end,
                        "%s programmed and verified", job->label);
            return true;
        }
        log_statusf("flashing", "retry", job->progress_start,
                    "%s attempt %d failed: %s", job->label, attempt, why);
    }
    return false;
}

static bool restore_backup(const struct image_job *job) {
    if (!job->rollback) return false;
    struct image_job rb = *job;
    rb.image = job->rollback;
    rb.label = job->label;
    rb.progress_start = 1;
    rb.progress_end = 99;
    char why[256] = {0};
    for (int attempt = 1; attempt <= 2; ++attempt) {
        log_statusf("rollback", "restore", 1,
                    "Restoring previous %s (attempt %d/2)",
                    job->label, attempt);
        if (program_once(&rb, why, sizeof(why))) {
            log_statusf("rollback", "verified", 99,
                        "Previous %s restored and verified", job->label);
            return true;
        }
        log_statusf("rollback", "retry", 1,
                    "%s rollback attempt %d failed: %s",
                    job->label, attempt, why);
    }
    return false;
}

static void preflight_job(const struct image_job *job) {
    struct stat st;
    struct mtd_info_user mtd;
    int fd;
    if (!job || !job->image || !job->device) return;
    if (stat(job->image, &st) != 0 || !S_ISREG(st.st_mode))
        fatal("preflight", "invalid image %s: %s", job->image,
              strerror(errno));
    fd = open(job->device, O_RDONLY);
    if (fd < 0)
        fatal("preflight", "open(%s): %s", job->device, strerror(errno));
    if (ioctl(fd, MEMGETINFO, &mtd) != 0) {
        close(fd);
        fatal("preflight", "MEMGETINFO(%s): %s", job->device,
              strerror(errno));
    }
    close(fd);
    if (mtd.type != MTD_NORFLASH)
        fatal("preflight", "%s is not NOR flash", job->device);
    if (mtd.size != job->expected_partition_size)
        fatal("preflight", "%s has size %u; expected %u", job->device,
              mtd.size, job->expected_partition_size);
    if (mtd.erasesize == 0 || (mtd.size % mtd.erasesize) != 0)
        fatal("preflight", "%s has invalid erase geometry", job->device);
    if (st.st_size <= 0 || st.st_size > (off_t)mtd.size)
        fatal("preflight", "%s size %lld is outside partition size %u",
              job->label, (long long)st.st_size, mtd.size);
    if (job->rollback) {
        struct stat rb;
        if (stat(job->rollback, &rb) != 0 || !S_ISREG(rb.st_mode) ||
            rb.st_size != (off_t)mtd.size)
            fatal("preflight", "invalid rollback image for %s", job->label);
    }
}

static void ensure_overlays_unmounted(void) {
    FILE *f = fopen("/proc/mounts", "r");
    if (!f)
        fatal("preflight", "cannot read /proc/mounts: %s", strerror(errno));
    char source[256], target[256], type[64], options[256];
    int dump, pass;
    while (fscanf(f, "%255s %255s %63s %255s %d %d", source, target, type,
                  options, &dump, &pass) == 6) {
        if (!strcmp(target, "/etc") || !strcmp(target, "/root") ||
            !strcmp(target, "/overlay")) {
            fclose(f);
            fatal("preflight", "filesystem %s is still mounted", target);
        }
    }
    fclose(f);
}

static void rollback_and_reboot(const struct image_job *root,
                                bool restore_root,
                                const struct image_job *overlay,
                                bool restore_overlay,
                                const char *reason) {
    bool root_ok = true;
    bool overlay_ok = true;
    write_status("rollback", "begin", 1, reason);

    /* Restore the boot-critical rootfs first. */
    if (restore_root) root_ok = restore_backup(root);
    if (restore_overlay) overlay_ok = restore_backup(overlay);

    if (root_ok && overlay_ok) {
        write_status("rollback", "reboot", 100,
                     "Upgrade failed; all changed partitions were restored and verified. Rebooting.");
    } else {
        char msg[512];
        snprintf(msg, sizeof(msg),
                 "Upgrade and rollback were not fully successful (rootfs=%s, overlay=%s). Hardware recovery may be required; rebooting.",
                 root_ok ? "ok" : "failed", overlay_ok ? "ok" : "failed");
        write_status("error", "recovery_required", 100, msg);
    }
    if (reboot_after) reboot_system();
    exit(EXIT_FAILURE);
}

static void usage(FILE *f) {
    fprintf(f,
        "usage: fwflash --rootfs-image FILE --rootfs-mtd DEV [options]\n"
        "  --rootfs-backup FILE\n"
        "  --overlay-image FILE --overlay-mtd DEV [--overlay-backup FILE]\n"
        "  --status-file FILE --log-file FILE\n"
        "  --source TEXT --firmware NAME --no-reboot\n");
}

int main(int argc, char **argv) {
    struct image_job root = {
        .label = "SquashFS",
        .expected_partition_size = ROOTFS_PARTITION_SIZE,
        .progress_start = 45,
        .progress_end = 95
    };
    struct image_job overlay = {
        .label = "JFFS2 overlay",
        .expected_partition_size = OVERLAY_PARTITION_SIZE,
        .progress_start = 5,
        .progress_end = 40
    };

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--rootfs-image") && ++i < argc) root.image = argv[i];
        else if (!strcmp(argv[i], "--rootfs-mtd") && ++i < argc) root.device = argv[i];
        else if (!strcmp(argv[i], "--rootfs-backup") && ++i < argc) root.rollback = argv[i];
        else if (!strcmp(argv[i], "--overlay-image") && ++i < argc) overlay.image = argv[i];
        else if (!strcmp(argv[i], "--overlay-mtd") && ++i < argc) overlay.device = argv[i];
        else if (!strcmp(argv[i], "--overlay-backup") && ++i < argc) overlay.rollback = argv[i];
        else if (!strcmp(argv[i], "--status-file") && ++i < argc) status_path = argv[i];
        else if (!strcmp(argv[i], "--log-file") && ++i < argc) log_path = argv[i];
        else if (!strcmp(argv[i], "--source") && ++i < argc) status_source = argv[i];
        else if (!strcmp(argv[i], "--firmware") && ++i < argc) status_firmware = argv[i];
        else if (!strcmp(argv[i], "--no-reboot")) reboot_after = false;
        else if (!strcmp(argv[i], "--help")) { usage(stdout); return 0; }
        else { usage(stderr); return 2; }
    }
    if (!root.image || !root.device || !root.rollback) {
        usage(stderr);
        return 2;
    }
    if ((overlay.image && !overlay.device) || (!overlay.image && overlay.device) ||
        (overlay.image && !overlay.rollback)) {
        fprintf(stderr, "fwflash: overlay image, device and backup must be supplied together\n");
        return 2;
    }

    log_file = fopen(log_path, "a");
    write_status("flashing", "begin", 1,
                 "RAM-resident flashing helper started");
    if (overlay.image && !strcmp(overlay.device, root.device))
        fatal("preflight", "rootfs and overlay devices are identical");
    preflight_job(&root);
    if (overlay.image) preflight_job(&overlay);
    ensure_overlays_unmounted();

    char why[256] = {0};
    bool overlay_changed = false;
    if (overlay.image) {
        if (!program_job(&overlay, why, sizeof(why))) {
            char reason[512];
            snprintf(reason, sizeof(reason),
                     "JFFS2 update failed after two attempts: %s", why);
            rollback_and_reboot(&root, false, &overlay, true, reason);
        }
        overlay_changed = true;
    }

    memset(why, 0, sizeof(why));
    if (!program_job(&root, why, sizeof(why))) {
        char reason[512];
        snprintf(reason, sizeof(reason),
                 "SquashFS update failed after two attempts: %s", why);
        rollback_and_reboot(&root, true, &overlay, overlay_changed, reason);
    }

    write_status("success", reboot_after ? "reboot" : "complete", 100,
                 reboot_after ? "Firmware verified; rebooting"
                              : "Firmware verified");
    if (!reboot_after) return 0;
    reboot_system();
    fatal("reboot", "reboot failed: %s", strerror(errno));
    return 1;
}
