# Dropbear for HSGQ firmware

This project builds Dropbear SSH for an HSGQ GPON SFP firmware environment using
Realtek RSDK 1.5.6 and Docker BuildKit. **Runtime was tested on
`V1.1.6_sfp_HSGQ_HGU_250729` only.** Other HSGQ releases, including V1.7.1,
may differ in their libraries, account database, PTY devices, or service setup.
The kernel's `RTL8672` platform string is not a verified physical SoC model.

| Firmware | Evidence |
| --- | --- |
| `V1.1.6_sfp_HSGQ_HGU_250729` | Built, checked against its libraries, and tested on a physical stick: password login, interactive shell, two PTY sessions, reconnect, and Ed25519 host key. |
| Other versions | Not tested. Check the exact firmware before trying to run the binaries. |

This build does **not** provide initial access to a device. You already need a
way to transfer and execute a file on the stick. It does not change flash,
startup scripts, GPON identity, or network rules. The source release does not
include prebuilt binaries, firmware, vendor libraries, passwords, or host keys.

## Build

Requires Docker with `buildx`, access to the upstream RSDK and Dropbear source
repositories, and a local unpacked copy of the *target* firmware's `lib/`
directory. Supply the libraries explicitly; they are copied into a temporary
Docker build context and are not exported with the resulting binaries.

```sh
FIRMWARE_LIBS_DIR=/absolute/path/to/unpacked-rootfs/lib ./build.sh
```

The output is in `out/`:

- `dropbear`: standalone server for a temporary test;
- `dropbearkey`: Ed25519 host key generator;
- `dropbear-inetd`: smaller inetd-only server with syslog enabled;
- `missing-runtime-symbols.txt`: empty when the symbol check passes;
- `build-info.txt` and `SHA256SUMS`: build details and artifact hashes.

The source revisions are pinned in `Dockerfile`. The build uses
`DROPBEAR_2020.81`, Lexra `-march=4180`, MIPS-I/O32, big endian, soft float,
and target uClibc 0.9.30.3. It has password authentication but no public-key
user authentication, PAM, or SFTP. It expects the firmware account database to
provide a usable password hash, home directory, and shell. The tested firmware
uses BSD PTYs and lacks `seteuid`/`setegid` libc symbols; the build contains
the corresponding compatibility choices. These assumptions must be checked
again for another firmware. Treat this older SSH build as a narrowly scoped
device tool and restrict network reachability.

## Check before starting a server

On the build host:

```sh
(cd out && sha256sum --check SHA256SUMS)
file out/dropbear out/dropbearkey out/dropbear-inetd
readelf -l out/dropbear | grep 'Requesting program interpreter'
readelf -d out/dropbear | grep NEEDED
test ! -s out/missing-runtime-symbols.txt
```

Expect a 32-bit MSB MIPS-I ELF and interpreter `/lib/ld-uClibc.so.0`. Confirm
the required shared libraries exist in the *target* firmware. A symbol check
against libraries from a different release does not establish compatibility.

If you have authorized shell access, transfer `dropbear` and `dropbearkey` to
temporary storage such as `/tmp`. Run `dropbear -h` there before generating a
host key or starting the server. `Illegal instruction`, `Segmentation fault`,
`not found`, or invalid help output means stop and investigate ABI and library
compatibility. Generate a fresh host key on each device; never share one.
Keep existing access available during a temporary SSH test.

## Source and licensing

The Dockerfile and helper scripts in this repository are MIT licensed. The
build fetches upstream [Dropbear](https://github.com/mkj/dropbear) and the
[RSDK mirror](https://github.com/Frak8/RTL8677); their own terms apply to those
projects. No third-party source tree or firmware library is redistributed here.
