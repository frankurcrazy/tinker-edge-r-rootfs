#!/usr/bin/env bash
# Install the RK3399Pro NPU userspace into a root filesystem tree.
#   install.sh <rootfs-dir> <RK3399Pro_npu checkout> [skip-pip 0|1]
#
# Pieces and where they come from:
#   /usr/share/npu_fw/*        NPU firmware, USB-mode set   <- RK3399Pro_npu/drivers/npu_firmware/npu_fw
#   /usr/bin/npu_transfer_proxy RKNN API <-> NPU proxy        <- RK3399Pro_npu/drivers/npu_transfer_proxy/linux-aarch64
#   /usr/lib/aarch64-linux-gnu/librknn_api.so + /usr/include/rknn_api.h  <- RK3399Pro_npu/rknn-api
#   /usr/share/rknn-api/       C demos + docs                <- RK3399Pro_npu/rknn-api
#   /usr/bin/upgrade_tool, npu_powerctrl, npu_upgrade        <- vendored here (ASUS TinkerBoard2/debian overlay-firmware)
#   rknn_toolkit_lite (python3.10 wheel)                     <- vendored here (rockchip-linux/rknn-toolkit)
set -euo pipefail
ROOT="$1"; NPU_SRC="${2:-}"; SKIP_PIP="${3:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '\033[1;32m[npu]\033[0m %s\n' "$*"; }

[ -n "$NPU_SRC" ] && [ -d "$NPU_SRC/drivers/npu_firmware/npu_fw" ] || { echo "RK3399Pro_npu checkout not found: $NPU_SRC" >&2; exit 1; }

install -d "$ROOT/usr/share/npu_fw" "$ROOT/usr/bin" "$ROOT/usr/lib/aarch64-linux-gnu" "$ROOT/usr/include" \
           "$ROOT/usr/share/rknn-api" "$ROOT/usr/share/doc/tinker-edge-r"

log "firmware (USB mode)"
install -m 644 "$NPU_SRC"/drivers/npu_firmware/npu_fw/{MiniLoaderAll.bin,uboot.img,trust.img,boot.img,parameter.txt} "$ROOT/usr/share/npu_fw/"

log "npu_transfer_proxy, librknn_api"
install -m 755 "$NPU_SRC/drivers/npu_transfer_proxy/linux-aarch64/npu_transfer_proxy" "$ROOT/usr/bin/npu_transfer_proxy"
install -m 644 "$NPU_SRC"/rknn-api/librknn_api/Linux/lib64/librknn_api.so "$ROOT/usr/lib/aarch64-linux-gnu/librknn_api.so"
install -m 644 "$NPU_SRC/rknn-api/librknn_api/include/rknn_api.h" "$ROOT/usr/include/rknn_api.h"
cp -a "$NPU_SRC/rknn-api/examples/c_demos" "$ROOT/usr/share/rknn-api/examples"
cp -a "$NPU_SRC/rknn-api/doc" "$ROOT/usr/share/rknn-api/doc"
install -m 644 "$NPU_SRC/LICENSE" "$ROOT/usr/share/doc/tinker-edge-r/LICENSE.RK3399Pro_npu"

log "upgrade_tool, npu_powerctrl, npu_upgrade (ASUS/Rockchip)"
install -m 755 "$HERE/bin/upgrade_tool" "$ROOT/usr/bin/upgrade_tool"
install -m 755 "$HERE/bin/npu_powerctrl" "$ROOT/usr/bin/npu_powerctrl"
install -m 755 "$HERE/bin/npu_upgrade" "$ROOT/usr/bin/npu_upgrade"
install -m 644 "$HERE/LICENSE.asus-debian" "$ROOT/usr/share/doc/tinker-edge-r/LICENSE.asus-debian"
install -m 644 "$HERE/PROVENANCE.md" "$ROOT/usr/share/doc/tinker-edge-r/npu-provenance.md"

# NPU-side libraries linked against libpthread/librt/libstdc++ (present in the base image)

if [ "$SKIP_PIP" = 0 ]; then
    log "rknn_toolkit_lite (python3)"
    WHL="$(ls "$HERE"/python/rknn_toolkit_lite-*-cp310-*linux_aarch64.whl | head -1)"
    cp "$WHL" "$ROOT/tmp/"
    # numpy / psutil / ruamel.yaml come from apt (see packages-extra.txt); no network needed
    chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive pip3 install --no-deps --no-cache-dir "/tmp/$(basename "$WHL")" \
        || echo "warning: rknn_toolkit_lite install failed (python3-pip missing?)" >&2
    rm -f "$ROOT/tmp/$(basename "$WHL")"
fi
log "done"
