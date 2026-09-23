# Dropbear for HSGQ firmware

Build scripts for Dropbear SSH on HSGQ GPON SFP firmware. The binaries were
tested on `V1.1.6_sfp_HSGQ_HGU_250729` with password login and an interactive
shell. Other firmware versions have not been tested.

This project does not provide initial access to a stick: you need a way to copy
and run a binary there first.

## Prerequisites

- Docker with `buildx`.
- The unpacked original firmware for the target stick (`V1.1.6_sfp_HSGQ_HGU_250729`
  for the tested setup), specifically its `rootfs/lib/` directory. The build
  checks the binaries' required symbols against these runtime libraries; the
  RSDK toolchain alone cannot verify they exist on the stick. Firmware libraries
  are used for this check and are not included in `out/`.

## Build

Point the build at that `lib/` directory:

```sh
FIRMWARE_LIBS_DIR=/absolute/path/to/rootfs/lib ./build.sh
```

`out/` contains `dropbear` (standalone), `dropbear-inetd`, `dropbearkey`,
`SHA256SUMS`, `build-info.txt`, and the symbol check result. The build fails if
required runtime symbols are missing. It fetches pinned RSDK and Dropbear source
revisions; no vendor libraries are included in this repository.

The build uses password authentication; user public-key authentication and
SFTP are disabled. Before starting a server on another firmware, check its ABI
and libraries and run `dropbear -h` from temporary storage on the stick.

## Transfer to RAM

If you can execute a command on the stick, start this on the host first
(OpenBSD `nc`, as used here):

```sh
nc -N -l 49123 < out/dropbear
md5sum out/dropbear
```

Then on the stick, replacing `HOST_IP` with the host's address. The stick must
have a route to that address:

```sh
/bin/nc HOST_IP 49123 > /tmp/dropbear
/bin/md5sum /tmp/dropbear
```

Compare the MD5 values. Only if they match, run:

```sh
chmod 700 /tmp/dropbear
/tmp/dropbear -h
```

Repeat the transfer with `out/dropbearkey` to `/tmp/dropbearkey` if you
need to generate a host key.

## Keeping SSH across reboots

On the tested `V1.1.6_sfp_HSGQ_HGU_250729` firmware, `/var/config` is a writable
partition that persists across reboots. After checking a binary from `/tmp`, you
can store the binary and its host key under `/var/config/dropbear/`, provided
there is enough free space. Keep the host key private. A stored binary does not
start by itself: without a startup configuration change, you must start the
standalone `dropbear` manually after each reboot.

For automatic startup on the tested stick, the vendor's `/bin/inetd` runs
`dropbear-inetd` from `/var/config/dropbear/`. This required adding an SSH entry
to `/etc/inetd.conf` in the read-only SquashFS RootFS and flashing the rebuilt
image. The entry points to the binary and host key in `/var/config/dropbear/`;
the firmware image does not need to contain either file. This repository builds
the binaries but does not rebuild or flash the RootFS.

Check the partition layout and startup mechanism on other firmware versions
before trying to make SSH persistent. This setup has not been validated for
those versions.

The build scripts are MIT licensed. Upstream source licenses remain separate.
