# MS42/MS42P postmerkOS firmware updater — first implementation

This package replaces the existing `fw_upgrade` shell-only approach with a
transport-independent updater and a small **statically linked RAM flasher**.
It is designed for the current 16 MiB RedBoot/NOR layout:

| Region | Offset | Size | Updater behavior |
|---|---:|---:|---|
| RedBoot | `0x000000` | 256 KiB | never touched |
| Kernel/SPIM | `0x040000` | 2816 KiB | never touched |
| SquashFS | `0x300000` | 8 MiB | always updated |
| JFFS2/config | `0xB00000` | 5 MiB | preserve, migrate, reset, or use image |

The updater is intended only for switches already running this alternative
firmware. It does not install over stock Meraki firmware.

## Why a static helper is used

Erasing the mounted SquashFS while executing `/bin/sh`, BusyBox, `flash_erase`,
or shared libraries from that SquashFS is fragile. Copying only the executable
to `/tmp` is not sufficient when it is dynamically linked or demand-paged.

`fw_update` therefore requires its work directory to be on tmpfs, performs all
validation and preparation first, copies the static `fwflash` helper to RAM,
stops all other userspace processes, unmounts `/etc`, `/root`, and `/overlay`,
takes consistent rollback snapshots, and then `exec`s the helper. The helper:

1. validates both MTD devices and all staged/rollback images;
2. flashes JFFS2 first when requested;
3. flashes SquashFS last;
4. erases the complete partition;
5. writes and reads back every byte;
6. verifies that any unwritten tail remains erased (`0xff`);
7. retries once after a failed write/verification;
8. treats SquashFS and an optional JFFS2 replacement as one transaction;
9. restores every changed partition if a later stage fails;
10. reboots immediately after success or after the rollback attempt.

This greatly improves failure handling, but it cannot make a single-partition
layout power-fail atomic. Loss of power while SquashFS is erased or being
written can still require the CH341A recovery path.

## Included commands

- `fw_update`: validates and installs a local image.
- `fw_update_http`: gathers indexes from configured HTTP(S) repositories,
  presents a numbered list, downloads the selected image and sidecar, and calls
  `fw_update`.
- `fw_update_tftp`: downloads an explicitly named image and sidecar by TFTP.
- `fw_update_sftp`: downloads an explicitly named image and sidecar by SFTP.
- `fw_update_status`: prints or watches the JSON status file.

Runtime status is written atomically to:

```text
/run/fwupdate/status.json
```

Logs are written to:

```text
/run/fwupdate/update.log
/run/fwupdate/flash.log
```

A future web endpoint can launch a command with `--yes` and poll the JSON file.
The web/SSH connection will disappear when services are stopped and the switch
reboots; that is expected. `/run` is volatile, so the final status is not retained
across the reboot in this first implementation.

## Overlay policies

### `preserve` — default

JFFS2 is not written at all. This preserves every current setting and every
other upper-layer file byte-for-byte.

The tradeoff is that old files in the JFFS2 upper layer can continue to shadow
new files supplied by the new SquashFS.

### `migrate`

Builds a clean JFFS2 image and copies only paths listed in:

```text
/etc/fwupdate/preserve.list
```

The initial list retains switch configuration, MAC/board information, Dropbear
keys, the root password database, and `/root/.ssh`. This is the preferred policy
once the exact persistent-data contract has been validated on the switch.

### `reset`

Builds and flashes an empty but valid JFFS2 overlay containing only the required
OverlayFS `.upper` and `.work` directories.

### `image`

Extracts and flashes the final 5 MiB region from a complete 16 MiB firmware
image. It is rejected for a standalone SquashFS input.

## Checksum format

Every remote image must have a same-name sidecar:

```text
ms42p-postmerkos-20260615-120000.bin
ms42p-postmerkos-20260615-120000.bin.sha256
```

The sidecar must contain the basename, not an absolute build-host path:

```text
0123456789abcdef...  ms42p-postmerkos-20260615-120000.bin
```

The updater rejects a sidecar whose recorded filename does not exactly match
the downloaded image.


## Transport and authenticity model

The SHA-256 sidecar detects corruption and prevents a mismatched image/sidecar
pair from being installed. A checksum downloaded from the same unauthenticated
HTTP or TFTP server does **not** prove who published the image: an attacker able
to replace the firmware can replace its checksum too.

For an authenticated update channel, use one of:

- HTTPS with a valid certificate and the installed CA bundle;
- SFTP with `--hostpubsha256`;
- SFTP with a pre-populated `known_hosts` file.

The SFTP wrapper refuses a connection without a host-key pin or known-hosts
file unless `--insecure-host-key` is explicitly supplied. HTTPS redirects are
restricted to HTTPS, preventing an HTTPS source from silently downgrading to
plain HTTP.

This design does not yet add a separately signed release manifest. A future
version should add an offline release-signing key if firmware authenticity must
remain verifiable even when the download server is compromised.

## HTTP(S) repository format

Configure repositories in `/etc/fwupdate/sources.conf`:

```text
# name|base URL|index filename
official|https://firmware.example.net/postmerkos/ms42p|index.tsv
lab|http://192.168.1.20/firmware/ms42p|index.tsv
```

Each repository provides `index.tsv`:

```text
# version|target|firmware filename|byte size|description
20260615-120000|ms42p|ms42p-postmerkos-20260615-120000.bin|16777216|Stable build
20260614-230000|ms42p|ms42p-postmerkos-20260614-230000.bin|16777216|Previous build
```

Bad or unreachable configured indexes are skipped. At least one compatible
entry must remain.

The included host helper publishes an artifact and atomically updates the
index:

```bash
./host/fwupdate-publish.sh \
  ~/meraki-ms42p-build/artifacts/ms42p-postmerkos-20260615-120000.bin \
  /srv/http/firmware/ms42p \
  20260615-120000 \
  "Web UI and updater build"
```

## Command examples

Interactive HTTP repository selection, retaining JFFS2 exactly:

```sh
fw_update_http
```

Headless HTTP install by version, migrating only approved settings:

```sh
fw_update_http --version 20260615-120000 --overlay migrate --yes
```

Direct HTTPS URL:

```sh
fw_update_http \
  --url https://server.example/fw/ms42p-postmerkos-20260615-120000.bin \
  --overlay preserve --yes
```

TFTP:

```sh
fw_update_tftp \
  --server 192.168.1.20 \
  --file firmware/ms42p-postmerkos-20260615-120000.bin \
  --overlay preserve --yes
```

SFTP with a pinned SSH host public-key hash:

```sh
fw_update_sftp \
  --server files.example.net \
  --file /firmware/ms42p-postmerkos-20260615-120000.bin \
  --user updater \
  --password-file /tmp/sftp-password \
  --hostpubsha256 'BASE64_SHA256_VALUE' \
  --overlay migrate --yes
```

SFTP using an existing OpenSSH known-hosts file:

```sh
fw_update_sftp \
  --server files.example.net \
  --file /firmware/ms42p-postmerkos-20260615-120000.bin \
  --user updater \
  --password-file /tmp/sftp-password \
  --known-hosts /root/.ssh/known_hosts \
  --overlay preserve --yes
```

SFTP defaults to username `anonymous` and an empty password when credentials
are omitted, but SFTP has no standardized anonymous-login mechanism; the server
must actually provide such an account.

Validate a local file and sidecar without flashing:

```sh
fw_update --verify-only \
  --checksum /tmp/firmware.bin.sha256 \
  /tmp/firmware.bin
```

Watch status:

```sh
fw_update_status --watch
```

## Build-script integration

Copy these into the existing `ms42p-build-scripts` tree:

```text
build-scripts/scripts/15-add-fwupdate-and-rebuild.sh
    -> scripts/15-add-fwupdate-and-rebuild.sh

build-scripts/support/fwupdate/
    -> support/fwupdate/
```

After completing the normal web-UI build stage, run:

```bash
./scripts/15-add-fwupdate-and-rebuild.sh
```

The stage:

- installs `package/fwupdate`;
- registers its Kconfig entry;
- patches the NOR packer so generated `.sha256` files contain only the firmware basename;
- switches Buildroot from shared-only to shared-plus-static libc archives;
- enables the updater;
- enables curl with mbed TLS, libssh2, TFTP protocol support, and CA roots;
- performs a clean Buildroot rebuild;
- verifies that `fwflash` is statically linked and all scripts are present;
- repacks and validates the complete NOR image.

Because the updater and transport libraries consume additional SquashFS space,
the existing 8 MiB size check remains authoritative. The build aborts rather
than producing an oversized image.


## Validation status

The shell scripts pass POSIX-shell syntax checks, and the RAM flasher builds
cleanly as a static executable with `-Wall -Wextra -Werror`. The publisher and
strict sidecar parser were also exercised against generated test artifacts.
The updater has **not yet been run on the physical MS42P NOR device**, so the
serial-attached validation sequence below remains mandatory before treating it
as production-safe.

## First hardware validation sequence

Use the existing CH341A backup/recovery setup and start with `preserve`:

1. Flash an updater-enabled image externally.
2. Boot and save `/proc/mtd`, `mount`, and `fw_update --verify-only` output.
3. Publish the same image under a different test filename and run an HTTP
   `--verify-only` download.
4. Build a harmless changed SquashFS, then install it with
   `--overlay preserve` while attached to serial.
5. Confirm SSH, UI, `/etc/switch.json`, host keys, password, and switch state.
6. Test `--overlay reset` only after the preserve path is confirmed.
7. Intentionally corrupt a staged image after checksum generation to confirm it
   is rejected before services are stopped.

Do not test power interruption during the first software update unless an
external full-flash backup and immediate hardware recovery are ready.
