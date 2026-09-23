#!/usr/bin/env bash
# ==============================================================================
# Build Dropbear SSH for HSGQ RTL960x with caller-supplied firmware libraries.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FIRMWARE_LIBS_DIR:?Set FIRMWARE_LIBS_DIR to the lib directory of an unpacked firmware image}"
firmware_libs_dir="$(realpath "$FIRMWARE_LIBS_DIR")"
for soname in ld-uClibc.so.0 libc.so.0 libcrypt.so.0 libgcc_s.so.1; do
    if [ ! -e "$firmware_libs_dir/$soname" ]; then
        echo "Missing $soname in $firmware_libs_dir" >&2
        exit 1
    fi
done

# Keep vendor libraries outside the source tree and the exported artifacts.
build_context="$(mktemp -d)"
trap 'rm -rf -- "$build_context"' EXIT
mkdir -p "$build_context/firmware-libs" "$SCRIPT_DIR/out"
cp "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/check-symbols.py" "$build_context/"
cp -a -- "$firmware_libs_dir"/*.so* "$build_context/firmware-libs/"

echo "================================================================================"
echo " Building Dropbear SSH for HSGQ GPON (RTL8672 / Lexra LX4180)"
echo " Target directory: ${SCRIPT_DIR}/out"
echo " Firmware libraries: ${firmware_libs_dir}"
echo "================================================================================"

# Use Docker BuildKit with local output directory
DOCKER_BUILDKIT=1 docker buildx build \
  --output "type=local,dest=${SCRIPT_DIR}/out" \
  "$build_context"

# A previous build may have left this removed verification program in out/.
rm -f -- "$SCRIPT_DIR/out/hello-rtl8672"
(cd "$SCRIPT_DIR/out" && sha256sum --check SHA256SUMS)

echo ""
echo "================================================================================"
echo " Build successful! Artifacts exported to ${SCRIPT_DIR}/out:"
echo "================================================================================"
ls -lh "$SCRIPT_DIR/out/"
echo ""
echo "Automated Symbol Gate status:"
if [ -f "$SCRIPT_DIR/out/missing-runtime-symbols.txt" ] && [ ! -s "$SCRIPT_DIR/out/missing-runtime-symbols.txt" ]; then
    echo "  [PASS] missing-runtime-symbols.txt is EMPTY. Zero missing dynamic dependencies!"
else
    echo "  [WARN/FAIL] Review ./out/missing-runtime-symbols.txt:"
    cat "$SCRIPT_DIR/out/missing-runtime-symbols.txt" 2>/dev/null || true
fi
echo ""
echo "SHA256 Checksums:"
cat "$SCRIPT_DIR/out/SHA256SUMS"
echo "================================================================================"
