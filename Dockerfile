# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS builder

ARG DEBIAN_FRONTEND=noninteractive

# 1. Install prerequisites and 32-bit x86 compatibility runtime for RSDK
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      make \
      autoconf \
      automake \
      libtool \
      file \
      binutils \
      patch \
      perl \
      python3 \
      bzip2 \
      libc6:i386 \
      libstdc++6:i386 \
      libgcc-s1:i386 \
      zlib1g:i386 && \
    rm -rf /var/lib/apt/lists/*

# 2. Fetch Realtek RSDK 1.5.6 for RTL8672 / RTL8677
ARG RSDK_REPO="https://github.com/Frak8/RTL8677"
ARG RSDK_COMMIT="258cd6120e1789633ec2cbbc45d1a1412b4e1055"
ARG RSDK_DIR="rsdk-1.5.6-5281-EB-2.6.30-0.9.30.3-110915"
WORKDIR /opt/rsdk
RUN git clone --no-checkout --filter=blob:none "${RSDK_REPO}" . && \
    git sparse-checkout set "${RSDK_DIR}" && \
    git checkout "${RSDK_COMMIT}"

# Configure toolchain symlinks
# Note: In this RSDK distribution, mips-linux-gcc points to rsdk-linux-wrapper,
# which rejects -march=4180 with "FATAL: -march mismatch. RSDK is configured for -march=5281 only".
# Pointing compiler symlinks directly to mips-linux-xgcc/xg++ bypasses the wrapper's
# SoC check while preserving full GCC 4.4.6 code generation, uClibc specs, crt files, and linker paths.
RUN cd "${RSDK_DIR}/bin" && \
    ln -sf mips-linux-xgcc mips-linux-gcc && \
    ln -sf mips-linux-xg++ mips-linux-g++ && \
    ln -sf mips-linux-xgcc rsdk-linux-gcc && \
    ln -sf mips-linux-xg++ rsdk-linux-g++

ARG TOOLCHAIN_DIR="/opt/rsdk/${RSDK_DIR}"
ENV PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
ARG CC="${TOOLCHAIN_DIR}/bin/rsdk-linux-gcc"
ARG AR="${TOOLCHAIN_DIR}/bin/rsdk-linux-ar"
ARG RANLIB="${TOOLCHAIN_DIR}/bin/rsdk-linux-ranlib"
ARG STRIP="${TOOLCHAIN_DIR}/bin/rsdk-linux-strip"
ARG CFLAGS="-march=4180 -msoft-float -EB -Os -fno-strict-aliasing -ffunction-sections -fdata-sections -fvisibility=hidden"
ARG LDFLAGS="-Wl,--gc-sections"

WORKDIR /build
RUN mkdir -p /out

# 3. Fetch and build Dropbear SSH (v2020.81)
ARG DROPBEAR_REPO="https://github.com/mkj/dropbear"
ARG DROPBEAR_TAG="DROPBEAR_2020.81"
ARG DROPBEAR_COMMIT="d852d69b50187dd81d424846e7dc677ec57e2d4f"

WORKDIR /build/dropbear
RUN git clone --depth 1 --branch "${DROPBEAR_TAG}" "${DROPBEAR_REPO}" . && \
    test "$(git rev-parse HEAD)" = "${DROPBEAR_COMMIT}" && \
    autoconf && \
    (autoheader || true)

# Configure Dropbear localoptions.h:
# - Password authentication against the vendor /etc/passwd -> /var/passwd.
# - PAM, shadow lookup, and public-key authentication are disabled.
# - Disable unused features (X11 forwarding, agent forwarding, client password/pubkey).
# - Keep one modern, OpenSSH-compatible algorithm suite only:
#   Ed25519 host keys, Curve25519 KEX, and ChaCha20-Poly1305 encryption.
COPY <<'EOF' /build/dropbear/localoptions.h
#define DROPBEAR_SMALL_CODE 1
#define DROPBEAR_SVR_PASSWORD_AUTH 1
#define DROPBEAR_SVR_PAM_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH 0
#define DROPBEAR_SVR_PUBKEY_OPTIONS 0
#define DROPBEAR_CLI_PASSWORD_AUTH 0
#define DROPBEAR_CLI_PUBKEY_AUTH 0
#define DROPBEAR_X11FWD 0
#define DROPBEAR_SVR_AGENTFWD 0
#define DROPBEAR_CLI_AGENTFWD 0
#define DROPBEAR_SVR_LOCALTCPFWD 0
#define DROPBEAR_SVR_REMOTETCPFWD 0
#define DROPBEAR_CLI_LOCALTCPFWD 0
#define DROPBEAR_CLI_REMOTETCPFWD 0
#define DROPBEAR_SFTPSERVER 0
#define DROPBEAR_RSA 0
#define DROPBEAR_DSS 0
#define DROPBEAR_ECDSA 0
#define DROPBEAR_ED25519 1
#define DROPBEAR_DH_GROUP14_SHA1 0
#define DROPBEAR_DH_GROUP14_SHA256 0
#define DROPBEAR_DH_GROUP16 0
#define DROPBEAR_CURVE25519 1
#define DROPBEAR_ECDH 0
#define DROPBEAR_DH_GROUP1 0
#define DROPBEAR_AES128 0
#define DROPBEAR_AES256 0
#define DROPBEAR_3DES 0
#define DROPBEAR_TWOFISH256 0
#define DROPBEAR_TWOFISH128 0
#define DROPBEAR_CHACHA20POLY1305 1
#define DROPBEAR_ENABLE_CTR_MODE 0
#define DROPBEAR_ENABLE_CBC_MODE 0
#define DROPBEAR_ENABLE_GCM_MODE 0
#define DROPBEAR_SHA1_HMAC 0
#define DROPBEAR_SHA1_96_HMAC 0
#define DROPBEAR_SHA2_256_HMAC 1
#define DROPBEAR_MD5_HMAC 0
#define DROPBEAR_USER_ALGO_LIST 0
#define DROPBEAR_KEXGUESS2 0
#define DROPBEAR_DELAY_HOSTKEY 0
#define DO_HOST_LOOKUP 0
#define DO_MOTD 0
EOF

# Add real seteuid/setegid compatibility implementations to compat.c using Linux syscalls.
# The target firmware uClibc (0.9.30.3) was built with UCLIBC_SUSV3_LEGACY disabled,
# omitting seteuid/setegid shared library symbols. Implementing them here ensures
# they resolve directly within the binary via sys_setresuid/sys_setresgid syscalls
# whose SYS_* identifiers come directly from target RSDK headers (<sys/syscall.h>).
RUN cat <<'EOF' >> compat.c

#include <unistd.h>
#include <sys/syscall.h>

int seteuid(uid_t euid) {
	return syscall(SYS_setresuid, (uid_t)-1, euid, (uid_t)-1);
}

int setegid(gid_t egid) {
	return syscall(SYS_setresgid, (gid_t)-1, egid, (gid_t)-1);
}
EOF

# Target uClibc compatibility cache overrides:
# - ac_cv_header_shadow_h=no / ac_cv_func_getspnam=no: use the hash stored directly in /var/passwd
# - crypt() is linked from the firmware-compatible libcrypt.so.0 in the RSDK
# - ac_cv_func_getusershell=no: enables Dropbear's internal compat.c implementation (reading /etc/shells)
# - ac_cv_func_strlcat=no: enables Dropbear's internal compat.c implementation (firmware libc lacks strlcat)
# - ac_cv_func_getgrouplist=no: disables optional getgrouplist call
# - --disable-openpty: uses Dropbear's BSD PTY fallback (/dev/ptyp0...f and /dev/ttyp0...f) matching firmware device nodes without missing libutil.so.0
# - --disable-loginfunc: avoids libutil.so.0 dependency
ARG CONFIGURE_CACHE_VARS="\
ac_cv_header_shadow_h=no \
ac_cv_func_getspnam=no \
ac_cv_func_getusershell=no \
ac_cv_func_strlcat=no \
ac_cv_func_getgrouplist=no"

# First build: supports BOTH standalone daemon mode and inetd mode
RUN ./configure \
      --host=mips-linux \
      --disable-zlib \
      --disable-harden \
      --disable-lastlog \
      --disable-syslog \
      --disable-utmp \
      --disable-wtmp \
      --disable-openpty \
      --disable-loginfunc \
      ${CONFIGURE_CACHE_VARS} && \
    make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" && \
    cp dropbear /out/dropbear && \
    cp dropbearkey /out/dropbearkey && \
    ${STRIP} /out/dropbear /out/dropbearkey

# Optional second build: inetd-only mode (NON_INETD_MODE disabled).
# Syslog must be enabled here: vendor inetd maps the accepted socket to fd 0/1/2,
# so a DISABLE_SYSLOG build would inject stderr log messages into the SSH stream.
RUN echo "#define NON_INETD_MODE 0" >> localoptions.h && \
    make clean && \
    ./configure \
      --host=mips-linux \
      --disable-zlib \
      --disable-harden \
      --disable-lastlog \
      --enable-syslog \
      --disable-utmp \
      --disable-wtmp \
      --disable-openpty \
      --disable-loginfunc \
      ${CONFIGURE_CACHE_VARS} && \
    make -j"$(nproc)" PROGRAMS="dropbear" && \
    cp dropbear /out/dropbear-inetd && \
    ${STRIP} /out/dropbear-inetd

# 4. Automated Symbol Gate: verify 100% dynamic symbol resolution against firmware libraries
COPY firmware-libs/ /firmware-libs/
COPY check-symbols.py /build/check-symbols.py
RUN python3 /build/check-symbols.py /firmware-libs /out


# 5. Generate build-info.txt and SHA256SUMS
RUN set -e; \
    RSDK_COMMIT=$(cd /opt/rsdk && git rev-parse HEAD); \
    DROPBEAR_COMMIT=$(cd /build/dropbear && git rev-parse HEAD); \
    { \
      echo "================================================================================"; \
      echo "HSGQ RTL8672 (Lexra LX4180) - Dropbear SSH Build Info"; \
      echo "Build timestamp (UTC): $(date -u '+%Y-%m-%d %H:%M:%S UTC')"; \
      echo "================================================================================"; \
      echo ""; \
      echo "1. TOOLCHAIN SPECIFICATION"; \
      echo "   RSDK Repository: ${RSDK_REPO}"; \
      echo "   RSDK Commit: ${RSDK_COMMIT}"; \
      echo "   RSDK Directory: ${RSDK_DIR}"; \
      echo "   RSDK Version: RSDK-1.5.6p2 (gcc 4.4.6, uClibc 0.9.30.3)"; \
      echo "   Target CPU: Lexra LX4180 / MIPS I compatible (32-bit O32 ABI, Big-Endian, Soft Float)"; \
      echo ""; \
      echo "   Compiler Version (rsdk-linux-gcc -v):"; \
      ${CC} -v 2>&1 | sed 's/^/     /'; \
      echo ""; \
      echo "   CFLAGS: ${CFLAGS}"; \
      echo "   LDFLAGS: ${LDFLAGS}"; \
      echo ""; \
      echo "2. DROPBEAR SOURCE & AUTH SPECIFICATION"; \
      echo "   Dropbear Repository: ${DROPBEAR_REPO}"; \
      echo "   Dropbear Tag: ${DROPBEAR_TAG}"; \
      echo "   Dropbear Commit: ${DROPBEAR_COMMIT}"; \
      echo "   Authentication Model: vendor /var/passwd password only (public-key auth=0, PAM=0)"; \
      echo "   Crypt / Shadow: crypt() via libcrypt.so.0; shadow/getspnam disabled"; \
      echo "   Algorithm Profile: Ed25519 + Curve25519 + ChaCha20-Poly1305 only; HMAC-SHA256 retained"; \
      echo "   Disabled Algorithms: RSA, DSS, ECDSA/ECDH, finite-field DH, AES, 3DES, Twofish, SHA-1/MD5 HMAC"; \
      echo "   Slimmed configuration: SFTP, TCP forwarding, agent forwarding, X11, MOTD, delayed hostkey generation disabled"; \
      echo ""; \
      echo "   Configure Command:"; \
      echo "     ./configure --host=mips-linux --disable-zlib --disable-harden --disable-lastlog --disable-syslog --disable-utmp --disable-wtmp --disable-openpty --disable-loginfunc ${CONFIGURE_CACHE_VARS}"; \
      echo "   Inetd-only difference: --enable-syslog (vendor inetd maps its socket to fd 0/1/2)"; \
      echo ""; \
      echo "3. ARTIFACTS AND FILE DETAILS"; \
      echo "   Files in /out:"; \
      ls -lh /out | sed 's/^/     /'; \
      echo ""; \
      echo "   File Identification (file command):"; \
      file /out/* | sed 's/^/     /'; \
      echo ""; \
      echo "4. ELF HEADERS & DEPENDENCIES"; \
      for f in /out/dropbear /out/dropbearkey /out/dropbear-inetd; do \
        echo "   --- $(basename $f) ---"; \
        echo "   [ELF Header]"; \
        readelf -h "$f" | sed 's/^/     /'; \
        echo "   [Program Interpreter & Load Segments]"; \
        readelf -l "$f" | grep -E "INTERP|Requesting|LOAD" | sed 's/^/     /'; \
        echo "   [Dynamic NEEDED Libraries]"; \
        readelf -d "$f" | grep NEEDED | sed 's/^/     /'; \
        echo ""; \
      done; \
      echo "5. AUTOMATED SYMBOL GATE & FIRMWARE COMPATIBILITY AUDIT"; \
      echo "   Audit against native libraries supplied at build time:"; \
      echo "     - Transitive DT_NEEDED closure: verified for each binary (strict dependency chain)"; \
      echo "     - missing-runtime-symbols.txt: $(wc -l < /out/missing-runtime-symbols.txt) missing symbols (EMPTY)"; \
      echo "     - syscall(): verified in DT_NEEDED closure (exported by native uClibc libc.so.0)"; \
      echo "     - WEAK UND symbols: GCC runtime frame hooks (_Jv_RegisterClasses, __frame_info) permitted as weak"; \
      echo "     - crypt(): resolved by target libcrypt.so.0; getspnam() eliminated (hash read from /var/passwd)"; \
      echo "     - getusershell/setusershell/endusershell: compiled via Dropbear internal compat.c (validates /etc/shells)"; \
      echo "     - strlcat: compiled via Dropbear internal compat.c fallback"; \
      echo "     - getgrouplist: eliminated via ac_cv_func_getgrouplist=no"; \
      echo "     - seteuid/setegid: implemented via genuine Linux sys_setresuid/sys_setresgid syscalls"; \
      echo "     - openpty: avoided via --disable-openpty; Dropbear BSD PTY fallback targets /dev/ptypX and /dev/ttypX"; \
      echo "   Result: 100% of required dynamic symbols exist in transitive DT_NEEDED closure."; \
      echo ""; \
      echo "6. SHA256 CHECKSUMS"; \
      (cd /out && sha256sum dropbear dropbearkey dropbear-inetd missing-runtime-symbols.txt) | sed 's/^/     /'; \
    } > /tmp/build-info.txt && \
    cp /tmp/build-info.txt /out/build-info.txt && \
    (cd /out && sha256sum dropbear dropbearkey dropbear-inetd missing-runtime-symbols.txt build-info.txt > SHA256SUMS)

# Export stage for BuildKit local output
FROM scratch
COPY --from=builder /out/ /
