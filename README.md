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

The build scripts are MIT licensed. Upstream source licenses remain separate.
