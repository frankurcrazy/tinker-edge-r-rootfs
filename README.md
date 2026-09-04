# tinker-edge-r-rootfs

Root filesystem builder for the ASUS Tinker Edge R (Rockchip RK3399Pro):
a minimal **Ubuntu 22.04 (jammy) arm64** system with the NPU userspace, a
configurable USB gadget on the Type-C port and helpers for the Geekworm X1301
HDMI-to-CSI-2 board.

This repository is one piece of a set that a `repo` manifest ties together:

| repository | role |
|---|---|
| [tinker-edge-r](https://github.com/frankurcrazy/tinker-edge-r) | manifest, Docker builder, build scripts, image assembly, documentation |
| [TB-RK3399ProD-Kernel-6.1](https://github.com/frankurcrazy/TB-RK3399ProD-Kernel-6.1) (branch `tinker-edge-r`) | Linux 6.1 Rockchip vendor kernel with the Tinker Edge R device tree |
| [tinker-edge-r-debian-u-boot](https://github.com/frankurcrazy/tinker-edge-r-debian-u-boot) | ASUS U-Boot 2017.09 |
| **this repository** | rootfs |

## What `mkrootfs.sh` produces

`debootstrap --variant=minbase` of jammy from `ports.ubuntu.com`, plus:

* `config/packages-base.txt` (systemd, networkd/resolved, ssh, sudo, basic tools)
  and `config/packages-extra.txt` (v4l-utils, ffmpeg, GStreamer, build tools, ...).
* `overlay/` copied verbatim on top: network config (`eth0` DHCP, `usb0` gadget
  network with a DHCP server), systemd units and helper scripts:
  * `npu-firmware.service` / `npu-transfer-proxy.service` - NPU bring-up at boot
    (`npu-status` to check), see `npu/PROVENANCE.md`.
  * `usb-gadget.service` - configfs composite gadget on the Type-C port,
    configured in `/etc/default/usb-gadget` (default: NCM Ethernet + ACM serial).
  * `tinker-first-boot.service` - grows the root partition, regenerates SSH host
    keys and the machine-id on the first boot.
  * `hdmirx-setup` - EDID load + ISP pipeline configuration for the X1301.
* Kernel modules from the kernel build (`--kernel-out`), Realtek RTL8822CE Wi-Fi
  and Bluetooth firmware fetched from linux-firmware (`config/firmware.txt`,
  sha256-pinned), NPU firmware/proxy/API from the `RK3399Pro_npu` checkout
  (`--npu-src`), RKNN Toolkit Lite for Python 3.10.
* A user (default `tinker`/`tinker`, passwordless sudo), hostname, timezone,
  locale; SSH enabled; serial console on the UART0 header pins (115200).

The result is a directory tree (`<out>/root`) that the build repo packs into an
ext4 partition with `mke2fs -d` (no loop devices anywhere).

## Running it by hand

```sh
sudo ./mkrootfs.sh --out /tmp/rootfs --kernel-out ../out/kernel --npu-src ../src/npu \
     --hostname tinker --user tinker --password tinker
```

Requirements: root, `debootstrap`, `qemu-user-static` with binfmt_misc registered
for aarch64 (the build repo's Docker image provides all of this; the container
must be `--privileged`).

## Layout

```
mkrootfs.sh            the builder
config/                package lists, apt sources template, firmware pins
overlay/               files copied into the rootfs (etc/, usr/local/...)
npu/                   NPU userspace glue: install.sh, vendored ASUS/Rockchip binaries, wheel, provenance
tools/mkedid.py        EDID generator for the HDMI-RX bridge
```

Scripts in this repository are MIT licensed (`LICENSE`).  Vendored third-party
binaries keep their own licenses (`npu/LICENSE.asus-debian`, and the
`RK3399Pro_npu` license copied into the image).
