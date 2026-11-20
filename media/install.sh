#!/usr/bin/env bash
# Install the Rockchip media userspace into a root filesystem tree.
#   install.sh <rootfs-dir> <rockchip-linux/mpp checkout> <airockchip/librga checkout>
#
# Pieces and where they come from:
#   /usr/lib/aarch64-linux-gnu/librockchip_{mpp,vpu}.so*, pkgconfig/rockchip_{mpp,vpu}.pc,
#   /usr/include/rockchip/, /usr/bin/mpi_*_test, mpp_info_test, vpu_api_test
#                                     <- rockchip-linux/mpp, built here inside the rootfs
#   /usr/lib/aarch64-linux-gnu/librga.so, /usr/include/rga/, pkgconfig/librga.pc
#                                     <- airockchip/librga, prebuilt (libs/Linux/gcc-aarch64)
#
# The kernel side (mpp_service with VDPU2/VEPU2/RKVDEC, RGA2, IEP) is built into the
# kernel, and overlay/etc/udev/rules.d/60-rockchip-media.rules gives the video group
# their device nodes.  No GStreamer plugin is installed: build one (rockchipmpp from
# gstreamer-rockchip) on the board against these libraries and pkg-config files.
#
# MPP is built inside the rootfs with the image's own toolchain (build-essential and
# cmake come from config/packages-extra.txt), as it is built on the board, so it links
# against the glibc and libstdc++ the image runs.  On an x86 host the compilers run
# through qemu-aarch64, which takes a few minutes.
set -euo pipefail
ROOT="$1"; MPP_SRC="${2:-}"; RGA_SRC="${3:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '\033[1;32m[media]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[media] error:\033[0m %s\n' "$*" >&2; exit 1; }
gitrev() { git -c safe.directory='*' -C "$1" rev-parse --short HEAD 2>/dev/null || echo '?'; }

[ -n "$MPP_SRC" ] && [ -f "$MPP_SRC/CMakeLists.txt" ] && [ -f "$MPP_SRC/mpp/mpp.cpp" ] \
    || die "rockchip-linux/mpp checkout not found: $MPP_SRC"
[ -n "$RGA_SRC" ] && [ -f "$RGA_SRC/libs/Linux/gcc-aarch64/librga.so" ] \
    || die "airockchip/librga checkout not found: $RGA_SRC"
in_root() { chroot "$ROOT" /usr/bin/env LC_ALL=C.UTF-8 "$@"; }
for t in cmake gcc g++ make; do
    in_root sh -c "command -v $t" >/dev/null \
        || die "$t missing in the rootfs: keep build-essential and cmake in config/packages-extra.txt"
done

LIBDIR=/usr/lib/aarch64-linux-gnu
DOC=/usr/share/doc/tinker-edge-r
LOGS="$(mktemp -d)"
IN_SRC=/tmp/mpp-src IN_BUILD=/tmp/mpp-build
cleanup() { rm -rf "$LOGS" "${ROOT:?}$IN_SRC" "${ROOT:?}$IN_BUILD"; }
trap cleanup EXIT
install -d "$ROOT$LIBDIR/pkgconfig" "$ROOT/usr/include/rga" "$ROOT$DOC"

log "MPP $(gitrev "$MPP_SRC"): build in the rootfs"
step() {   # step <log name> <command...>: quiet unless it fails
    local name=$1; shift
    "$@" > "$LOGS/$name.log" 2>&1 || { tail -30 "$LOGS/$name.log" >&2; die "MPP $name failed"; }
}
rm -rf "${ROOT:?}$IN_SRC" "${ROOT:?}$IN_BUILD"
mkdir -p "$ROOT$IN_SRC"
tar -C "$MPP_SRC" --exclude=.git -cf - . | tar -C "$ROOT$IN_SRC" -xf -
step configure in_root cmake -S "$IN_SRC" -B "$IN_BUILD" \
    -DCMAKE_BUILD_TYPE=Release -DRKPLATFORM=ON -DHAVE_DRM=ON \
    -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu
step build in_root cmake --build "$IN_BUILD" -j"$(nproc)"
step install in_root cmake --install "$IN_BUILD"
rm -f "$ROOT$LIBDIR/librockchip_mpp.a"     # static library: nothing in the image links it
install -m 644 "$MPP_SRC/LICENSES/Apache-2.0" "$ROOT$DOC/LICENSE.mpp.Apache-2.0"
install -m 644 "$MPP_SRC/LICENSES/MIT" "$ROOT$DOC/LICENSE.mpp.MIT"

ver() { sed -n "s/^#define RGA_API_$1_VERSION[[:space:]]*\([0-9]*\).*/\1/p" "$RGA_SRC/include/im2d_version.h"; }
RGA_VERSION="$(ver MAJOR).$(ver MINOR).$(ver REVISION)"
log "librga $RGA_VERSION ($(gitrev "$RGA_SRC")): prebuilt"
# its SONAME is the unversioned librga.so
install -m 644 "$RGA_SRC/libs/Linux/gcc-aarch64/librga.so" "$ROOT$LIBDIR/librga.so"
install -m 644 "$RGA_SRC"/include/*.h "$RGA_SRC"/include/*.hpp "$ROOT/usr/include/rga/"
cat > "$ROOT$LIBDIR/pkgconfig/librga.pc" <<EOF
prefix=/usr
libdir=\${prefix}/lib/aarch64-linux-gnu
includedir=\${prefix}/include

Name: librga
Description: Rockchip RGA 2D acceleration (airockchip/librga, prebuilt)
Version: $RGA_VERSION
Libs: -L\${libdir} -lrga
Cflags: -I\${includedir} -I\${includedir}/rga
EOF
chmod 644 "$ROOT$LIBDIR/pkgconfig/librga.pc"
install -m 644 "$RGA_SRC/COPYING" "$ROOT$DOC/LICENSE.librga"

install -m 644 "$HERE/PROVENANCE.md" "$ROOT$DOC/media-provenance.md"
in_root /sbin/ldconfig
log "done"
