# Dropbear for HSGQ firmware

Build scripts for Dropbear SSH on HSGQ GPON SFP firmware. The binaries were
tested on `V1.1.6_sfp_HSGQ_HGU_250729` with password login and an interactive
shell. Other firmware versions have not been tested.

This project does not provide initial access to a stick: you need a way to copy
and run a binary there first.

## Build

Install Docker with `buildx` and unpack the firmware you want to target. Point
the build at its `lib/` directory:

```sh
FIRMWARE_LIBS_DIR=/absolute/path/to/rootfs/lib ./build.sh
```

`out/` contains `dropbear` (standalone), `dropbear-inetd`, `dropbearkey`,
`SHA256SUMS`, `build-info.txt`, and the symbol check result. The build fails if
required runtime symbols are missing from the supplied libraries. It fetches
pinned RSDK and Dropbear source revisions; no vendor libraries are included in
this repository.

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

The build scripts are MIT licensed. Upstream source licenses remain separate.
