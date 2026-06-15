# MS42P reproducible PostmerkOS build scripts — revision 12

This staged workflow targets an MS42/MS42P and deliberately uses Buildroot **2023.02.4**. It builds a compressed `vmlinuz`, imports the known-good donor `/etc` regular files and complete `/lib/modules`, builds `rootfs.squashfs`, and packs a 16 MiB NOR image without renaming artifacts to `vmlinux` or `bootubi.new`.

## Project location

Copy this bundle to:

```text
~/meraki-ms42p-build/
```

No manually-created `meraki.zip` is required. Stage 02 fetches both Hal Martin's known-good base integration and Hall's `config-status` branch. Stage 06 preserves the proven standard build path; Stages 13/14 replace the Buildroot integration with Hall's complete config-status tree for the optional web-management image.

Stage 05 accepts an optional local `inputs/good-rootfs.squashfs` or `inputs/postmerkOS-20240818.bin`. If neither exists, it downloads the PostmerkOS 20240818 reference image automatically and extracts its 8 MiB squashfs region. Donor binaries are downloaded at build time and are not included in this bundle.

## First run

On CachyOS/Arch:

```bash
cd ~/meraki-ms42p-build
./scripts/00-setup-host.sh
distrobox enter meraki-build
cd ~/meraki-ms42p-build
./scripts/build-all.sh
```

The interactive shell may be fish or Bash. The scripts themselves use Bash shebangs, so do not source them into fish.

## Individual stages

Run `01` through `10` independently to isolate build failures. Stage `11` is intentionally excluded from `build-all.sh` because it performs hardware backup/flashing and must remain interactive. Logs are written to `~/meraki-ms42p-build/logs/` and outputs to `artifacts/`.

Useful overrides:

```bash
JOBS=1 ./scripts/03-build-openwrt-toolchain.sh
CLEAN=1 ./scripts/04-build-compressed-kernel.sh
REDBOOT_SOURCE=donor ./scripts/08-stage-nor-inputs.sh
REDBOOT_SOURCE=file REDBOOT_FILE=/path/to/loader1.bin ./scripts/08-stage-nor-inputs.sh
```

## Important behavior

- Rootfs is accepted at any non-zero size up to the 8 MiB partition limit.
- Kernel is accepted only when the ELF entry point is `0x81000000` and kernel+header fit the 2816 KiB region.
- Buildroot kernel headers are loaded from a local `file://` tarball; no temporary web server is used.
- Buildroot downloads prefer `https://sources.buildroot.net` and use a persistent `download-cache/buildroot/` directory, avoiding repeated dead-mirror delays while retaining normal fallback behavior.
- Buildroot's post-image step only validates `rootfs.squashfs`; final NOR packing is external and deterministic.
- The packer writes the 32-byte SPIM header directly with Python `struct`, avoiding the old `cut -b0-2` bug.
- Final images are timestamped and never silently overwritten.

## Expected image layout

```text
0x000000–0x03ffff  loader1       256 KiB
0x040000–0x2fffff  kernel       2816 KiB
0x300000–0xafffff  squashfs        8 MiB
0xb00000–0xffffff  JFFS2 overlay   5 MiB
```

The complete staged build process has been successfully tested end-to-end, and the generated image has been flashed and booted successfully on an MS42P.


## Back up and flash the completed image

Stage 11 runs on the **host**, not as part of `build-all.sh`:

```bash
cd ~/meraki-ms42p-build
./scripts/11-backup-and-flash.sh
```

You may also pass a specific validated 16 MiB image:

```bash
./scripts/11-backup-and-flash.sh /path/to/ms42p-postmerkos-YYYYMMDD-HHMMSS.bin
```

Defaults:

- Programmer: `ch341a_spi`
- Flash chip: `MX25L12805D`
- Original-firmware backup: enabled by default
- Backup verification: three independent reads, all required to match byte-for-byte
- Flash verification: normal flashrom write verification plus a separate full readback comparison
- UART: selectable from `/dev/serial/by-id/*`, `/dev/ttyUSB*`, or `/dev/ttyACM*`
- UART settings: 115200 baud, 8N1, XON/XOFF

Useful overrides:

```bash
BACKUP_READS=2 ./scripts/11-backup-and-flash.sh
PROGRAMMER=ch341a_spi CHIP=MX25L12805D ./scripts/11-backup-and-flash.sh
```

The script repeatedly warns that the switch must remain unpowered during SPI reads/writes and that the programmer must be disconnected before powering the switch on. It offers retries after backup mismatch/read failure, flash failure, verification failure, and serial-port connection failure.

## Stage 12: reusable serial-console utility

`./scripts/12-serial-console.sh` can be run independently of flashing whenever UART debugging is needed. It detects `/dev/serial/by-id/*`, `/dev/ttyUSB*`, and `/dev/ttyACM*`, lets the user select a device, and opens it at 115200 8N1 with XON/XOFF using picocom.

If the selected device is not readable and writable by the current account, the utility offers to:

1. Add the user to the group that owns the serial device (commonly `uucp` on Arch/CachyOS or `dialout` on Debian/Ubuntu), then use sudo for the current session; or
2. Use sudo only for the current session; or
3. Re-select a different serial port.

After adding the user to the serial group, the utility warns that logout/login or reboot is required, then offers to open the console immediately with sudo; the default answer is yes. If the user is already listed in the owning group but the current session has not refreshed its permissions, it detects that state and offers sudo directly. A specific device can be supplied directly:

```bash
./scripts/12-serial-console.sh /dev/ttyUSB0
```

Stage 11 now launches Stage 12 after flashing instead of embedding its own serial-monitor implementation.

## Optional config-status web-interface rebuild

After the standard stages have produced a known-good firmware, run either:

```bash
./scripts/13-add-web-ui-and-rebuild.sh
```

or the explicit compatibility alias:

```bash
./scripts/14-add-web-ui-config-status-and-rebuild.sh
```

Both now use Hall's `config-status` branch of `hall/meraki-builder` by default and
build the web frontend directly from the `main` branch of
`hall/postmerkos-ui`. Stage 02 also checks out the config-status branch during a
fresh setup, while Stages 13/14 can fetch it themselves when upgrading an
existing workspace.

The web stage deliberately overlays the **complete** config-status Buildroot
tree. Hall's repository stores custom packages under `buildroot/packages/`, so
the stage copies them into upstream Buildroot's `package/` directory, registers
their Kconfig entries, and always enables:

```text
BR2_PACKAGE_CONFIGD=y
BR2_PACKAGE_PD690XX=y
BR2_PACKAGE_UHTTPD=y
```

The standalone `clickswstatus` diagnostic utility is optional. The stage prompts
whether to leave `BR2_PACKAGE_STATUS` disabled, which is the default, or enable
it and require `/bin/clickswstatus` in the generated rootfs.

The UI source currently requires Node.js 20 or newer. A suitable system Node is
used when available; otherwise the stage downloads a project-local, pinned
Node.js 22 toolchain and runs `npm ci` followed by `npm run build`. The files
installed into `/www` therefore come from the checked-out UI `main` commit, not
from a prebuilt release archive.

### Startup-script merge prompt

The donor firmware and Hall's config-status overlay contain overlapping
`/etc/init.d` filenames. The web stage prints and saves a comparison report, then
prompts for one of two policies:

1. **Hall only — default.** Donor `init.d` files are excluded. Hall's
   `buildroot/board/meraki/ms220/overlay/etc/init.d` directory is authoritative.
2. **Mixed.** Donor-only startup scripts are retained, but Hall's complete board
   overlay is copied last, so every matching filename is overwritten with
   Hall's version.

The report is saved as:

```text
artifacts/init-script-comparison.txt
```

For unattended builds, select the policy explicitly:

```bash
STARTUP_SCRIPT_POLICY=hall  ./scripts/14-add-web-ui-config-status-and-rebuild.sh
STARTUP_SCRIPT_POLICY=mixed ./scripts/14-add-web-ui-config-status-and-rebuild.sh
```

### Standalone clickswstatus prompt

Hall's `configd` already compiles its own status implementation, so the separate
`/bin/clickswstatus` program is not required by the WebSocket UI. Stage 13/14
therefore asks:

1. **Continue without clickswstatus — default.** `BR2_PACKAGE_STATUS` is disabled
   and the rootfs check does not require `/bin/clickswstatus`.
2. **Enable clickswstatus.** `BR2_PACKAGE_STATUS=y` is set and the rootfs check
   requires `/bin/clickswstatus`.

For unattended builds:

```bash
CLICKSWSTATUS_POLICY=disabled ./scripts/14-add-web-ui-config-status-and-rebuild.sh
CLICKSWSTATUS_POLICY=enabled  ./scripts/14-add-web-ui-config-status-and-rebuild.sh
```

The selected value is saved in:

```text
artifacts/clickswstatus-policy.txt
```

When enabled, the stage normalizes Hall's package layout from
`package/clickswstatus/clickswstatus.mk` to `package/status/status.mk`, aligning
the `STATUS_*` recipe variables and `BR2_PACKAGE_STATUS` symbol with the package
name Buildroot derives from the makefile filename.
It also rewrites Hall's original
`source "package/clickswstatus/Config.in"` entry to
`source "package/status/Config.in"` and removes duplicate source entries. This
Kconfig path rewrite is required in both enabled and disabled modes because
Kconfig parses every `source` statement before applying package selections.

Buildroot package-provided startup scripts remain present in either mode. If
Hall's branch does not provide service scripts for `configd` or `uhttpd`, the
stage adds verified `S15configd` and `S16uhttpd` scripts so the web service can
start after the Click graph is initialized.

### Older released Click compatibility

The current config-status `configd` source still reads
`/click/switch_port_table/dump_port_storm_control`, while the released donor
Click graph exposes the corresponding setter but not that read handler. The
stage examines the checked-out source and applies the narrow compatibility
fallback only when it is still required. If Hall fixes the source upstream, the
patch is automatically skipped. The decision is recorded in:

```text
artifacts/configd-compatibility-patch.txt
```

### Clean rebuild and verification

The web stage performs a clean Buildroot rebuild. This is intentional: stale
files already installed in `output/target`, especially donor startup scripts,
would otherwise survive a policy change. The persistent Buildroot download
cache is retained.

Before repacking NOR, the generated SquashFS is always checked for:

```text
/www/index.html
/bin/configd
/bin/pd690xx
/usr/bin/uhttpd
```

`/bin/clickswstatus` is checked only when the user selected the enabled
`BR2_PACKAGE_STATUS` option.

Every Hall board startup script is also compared byte-for-byte against the
resulting rootfs. The effective rootfs startup-script list is saved as:

```text
artifacts/effective-rootfs-init-scripts.txt
```

The completed image is recorded in:

```text
artifacts/latest-webui-image.txt
```

After flashing, browse to `http://<switch-ip>/`. `configd` listens on TCP port
4001, and its runtime diagnostics are written to `/tmp/configd.log`.


## Revision 12 validation correction

`S14passwd` is intentionally modified by the MS220 post-build script. Revision 12 reproduces that salt substitution during validation rather than requiring the final rootfs file to match Hall's placeholder-bearing source byte-for-byte. Other Hall init scripts still require exact content matches.
