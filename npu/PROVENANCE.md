# NPU userspace: where every binary comes from

The RK3399Pro's NPU is a separate processor (an RK1808-class core with its own
2 GB LPDDR3) attached to the application processor over USB on the Tinker Edge R.
It has no storage: at every boot the host resets it into Rockchip maskrom mode and
pushes a firmware set into its RAM over USB, after which the NPU runs its own Linux
with `rknn_server`, and the host talks to it through `npu_transfer_proxy`.

| File in rootfs | Origin | Version / checksum |
|---|---|---|
| `/usr/share/npu_fw/{MiniLoaderAll.bin,uboot.img,trust.img,boot.img,parameter.txt}` | `airockchip/RK3399Pro_npu` `drivers/npu_firmware/npu_fw` (USB set), pinned in the build repo manifest (`src/npu`) | commit `8858114`; boot.img md5 `28631626008f897338483a1ffdae7173` |
| `/usr/bin/npu_transfer_proxy` | `airockchip/RK3399Pro_npu` `drivers/npu_transfer_proxy/linux-aarch64` | md5 `069a830b65b6d4f75ea774f920d690bf` |
| `/usr/lib/aarch64-linux-gnu/librknn_api.so`, `/usr/include/rknn_api.h`, `/usr/share/rknn-api/` | `airockchip/RK3399Pro_npu` `rknn-api` | RKNN API 1.7.5 |
| `/usr/bin/upgrade_tool` | `TinkerBoard2/debian` `overlay-firmware/usr/bin/upgrade_tool` (Rockchip maskrom/loader tool, aarch64 build), repo licensed Apache-2.0 | 429240 bytes, md5 `ce468100eab2f9e3ccc5d844df70cadd` |
| `/usr/bin/npu_powerctrl` | `TinkerBoard2/debian` `overlay-firmware/usr/bin/npu_powerctrl` | 14408 bytes, md5 `205e06e05b90454da2ac90085b6c9b2d`, reports `V1.1` |
| `/usr/bin/npu_upgrade` | rewritten from `TinkerBoard2/debian` `overlay-firmware/usr/bin/npu_upgrade` (bash script, Apache-2.0) | see `bin/npu_upgrade` |
| `rknn_toolkit_lite-1.7.5-cp310-cp310-linux_aarch64.whl` | `rockchip-linux/rknn-toolkit` `rknn-toolkit-lite/packages/` at commit `8e30ee72e772d6d39f2fcaf4047fead450b3ee89` | sha256 `d1c3f119f7cae1ce9eed07c6d753c6554afec47b128afb2d0582a3d462a9b14c` |

Notes

* The firmware set and `npu_transfer_proxy`/`librknn_api` must come from the same
  RKNN release (the `rknn_server` inside `boot.img` speaks the API version of the
  host library).  The RK3399Pro_npu repository ships them together (1.7.5).
* `npu_powerctrl` is a tiny static tool: `-i` exports GPIO 35 (GPIO1_A3) and 56
  (GPIO1_D0) through `/sys/class/gpio`, `-o` toggles them and enables the NPU
  reference clocks through the writable `clk_enable_count` debugfs attributes
  (`clk_wifi_pmu`, `rk808-clkout2`).  The 6.1 kernel tree keeps that debugfs ABI
  writable specifically for this tool.  It is the same binary the stock ASUS
  Debian 10 image runs on the Tinker Edge R (`/usr/bin/npu_powerctrl`).
* `upgrade_tool` needs raw USB access (runs as root from `npu-firmware.service`).
