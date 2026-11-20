# Media userspace: where every file comes from

The RK3399Pro's video units are driven through Rockchip's MPP. The kernel side is
built into the kernel: `mpp_service` with the VDPU2 and RKVDEC decoders and the
VEPU2 encoder, plus RGA2 for 2D conversion and IEP. This directory installs the
userspace libraries that talk to it.

| File in rootfs | Origin | Version |
|---|---|---|
| `/usr/lib/aarch64-linux-gnu/librockchip_mpp.so*`, `librockchip_vpu.so*`, `pkgconfig/rockchip_{mpp,vpu}.pc`, `/usr/include/rockchip/` | `rockchip-linux/mpp`, pinned in the build repo manifest (`src/mpp`), built by `install.sh` inside the rootfs with the image's own toolchain, `-DRKPLATFORM=ON -DHAVE_DRM=ON` | commit `48962a10` (branch `develop`) |
| `/usr/bin/mpi_dec_test`, `mpi_enc_test` and the other `mpi_*_test`, `mpp_info_test`, `vpu_api_test` | MPP's test programs, same build | same |
| `/usr/lib/aarch64-linux-gnu/librga.so`, `/usr/include/rga/` | `airockchip/librga` `libs/Linux/gcc-aarch64/librga.so` and `include/` (prebuilt by Rockchip), pinned in the manifest (`src/rga`) | tag `v1.10.0`, commit `fb3357d0` |
| `/usr/lib/aarch64-linux-gnu/pkgconfig/librga.pc` | written by `install.sh`; librga ships none | version read from `im2d_version.h` |

Notes

* No GStreamer plugin is installed.  Rockchip's `rockchipmpp` plugin (from
  `gstreamer-rockchip`) builds on the board against these files with GStreamer
  1.20's development packages, for example
  `meson setup build -Drockchipmpp=enabled -Drga=enabled -Drkximage=disabled
  -Dkmssrc=disabled -Dvpxalphadec=enabled`.
* MPP 48962a10 is the commit the 1080p H.264 encode and JPEG/H.264 decode
  measurements on this board were made with.  MPP's HEAD has moved on; a newer pin
  needs those measurements repeated.
* librga 1.10.0 closes the destination's `in_fence_fd` after every successful blit
  when it is `>= 0`, with the RGA driver in this kernel (above 1.3.0).  A caller that
  zero-initializes `rga_info_t` leaves `in_fence_fd` at 0, so every blit closes the
  process's stdin.  Set `in_fence_fd` and `out_fence_fd` to -1 (librga's own "none").
* MPP's sources carry Apache-2.0 and MIT licenses (copied to
  `/usr/share/doc/tinker-edge-r/LICENSE.mpp.*`); librga's license is copied to
  `/usr/share/doc/tinker-edge-r/LICENSE.librga`.
