#!/usr/bin/env bash
# Build a minimal Ubuntu 22.04 (jammy) arm64 root filesystem for the ASUS
# Tinker Edge R with debootstrap.
#
# Must run as root (chroot, device nodes, ownership) on a host - or, as in the
# tinker-edge-r build repository, inside a privileged Docker container - where
# binfmt_misc runs arm64 binaries through qemu-user-static.  No loop devices,
# no disk images: the result is a directory tree that the image stage packs
# with mke2fs -d.
#
# usage: mkrootfs.sh --out DIR --kernel-out DIR --npu-src DIR [options]
#   --suite jammy --arch arm64 --mirror URL
#   --hostname NAME --user NAME --password PW --timezone TZ --locale LOCALE
#   --extra-packages "pkg pkg ..."   --skip-firmware   --skip-pip
#
# Result: DIR/root (the tree), DIR/packages.txt, DIR/BUILD-INFO.txt
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE=jammy ARCH=arm64 MIRROR=http://ports.ubuntu.com/ubuntu-ports
OUTDIR="" KERNEL_OUT="" NPU_SRC=""
HOSTNAME_="tinker-edge-r" USER_="tinker" PASSWORD_="tinker" TZ_="Etc/UTC" LOCALE_="C.UTF-8"
EXTRA_PACKAGES="" SKIP_FIRMWARE=0 SKIP_PIP=0 DOCS_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --docs) DOCS_DIR="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        --out) OUTDIR="$2"; shift 2 ;;
        --kernel-out) KERNEL_OUT="$2"; shift 2 ;;
        --npu-src) NPU_SRC="$2"; shift 2 ;;
        --hostname) HOSTNAME_="$2"; shift 2 ;;
        --user) USER_="$2"; shift 2 ;;
        --password) PASSWORD_="$2"; shift 2 ;;
        --timezone) TZ_="$2"; shift 2 ;;
        --locale) LOCALE_="$2"; shift 2 ;;
        --extra-packages) EXTRA_PACKAGES="$2"; shift 2 ;;
        --skip-firmware) SKIP_FIRMWARE=1; shift ;;
        --skip-pip) SKIP_PIP=1; shift ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUTDIR" ] || { echo "--out is required" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
command -v debootstrap >/dev/null || { echo "debootstrap not installed" >&2; exit 1; }
if [ "$ARCH" != "$(dpkg --print-architecture 2>/dev/null || uname -m)" ] && ! grep -qs enabled /proc/sys/fs/binfmt_misc/qemu-aarch64; then
    echo "binfmt_misc qemu-aarch64 is not registered on this kernel; cannot chroot into an $ARCH tree" >&2
    exit 1
fi

ROOT="$OUTDIR/root"
log() { printf '\033[1;32m[rootfs]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[rootfs] error:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- chroot plumbing -------------------------------------------------------------------
MOUNTED=()
mount_chroot() {
    mount -t proc proc "$ROOT/proc";            MOUNTED+=("$ROOT/proc")
    mount --bind /sys "$ROOT/sys";              MOUNTED+=("$ROOT/sys")
    mount --bind /dev "$ROOT/dev";              MOUNTED+=("$ROOT/dev")
    mount -t devpts devpts "$ROOT/dev/pts" -o gid=5,mode=620,ptmxmode=666 2>/dev/null && MOUNTED+=("$ROOT/dev/pts") || true
    mount -t tmpfs tmpfs "$ROOT/tmp";           MOUNTED+=("$ROOT/tmp")
    mount -t tmpfs tmpfs "$ROOT/run";           MOUNTED+=("$ROOT/run")
}
umount_chroot() {
    local i
    for (( i=${#MOUNTED[@]}-1; i>=0; i-- )); do umount -l "${MOUNTED[$i]}" 2>/dev/null || true; done
    MOUNTED=()
}
trap 'umount_chroot' EXIT
chr() { DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8 chroot "$ROOT" "$@"; }
chr_apt() { chr apt-get -o Dpkg::Options::=--force-confnew -o APT::Install-Recommends=false -y "$@"; }

# ---- 1. debootstrap ----------------------------------------------------------------
log "debootstrap $SUITE/$ARCH from $MIRROR into $ROOT"
umount_chroot
rm -rf "$ROOT"; mkdir -p "$ROOT"
debootstrap --arch="$ARCH" --variant=minbase --components=main,universe \
    --include=ca-certificates,apt-utils,gnupg "$SUITE" "$ROOT" "$MIRROR"
[ -x "$ROOT/bin/bash" ] || die "debootstrap did not produce a usable tree"

# Do not start services inside the chroot.
cat > "$ROOT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$ROOT/usr/sbin/policy-rc.d"
cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf.build" 2>/dev/null || echo "nameserver 1.1.1.1" > "$ROOT/etc/resolv.conf.build"
rm -f "$ROOT/etc/resolv.conf"; cp "$ROOT/etc/resolv.conf.build" "$ROOT/etc/resolv.conf"

mount_chroot

# ---- 2. apt sources + packages -------------------------------------------------------
sed -e "s|@MIRROR@|$MIRROR|g" -e "s|@SUITE@|$SUITE|g" "$HERE/config/sources.list.in" > "$ROOT/etc/apt/sources.list"
cat > "$ROOT/etc/apt/apt.conf.d/90tinker" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF
# keep the image small: no docs/man pages (packages still work)
cat > "$ROOT/etc/dpkg/dpkg.cfg.d/01-nodoc" <<'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/locale/*/LC_MESSAGES/*.mo
path-include /usr/share/locale/en*/LC_MESSAGES/*.mo
EOF

pkgs() { grep -hvE '^\s*(#|$)' "$@" | tr '\n' ' '; }
BASE_PKGS="$(pkgs "$HERE/config/packages-base.txt")"
EXTRA_PKGS="$(pkgs "$HERE/config/packages-extra.txt") $EXTRA_PACKAGES"
log "apt update + install"
chr_apt update
# shellcheck disable=SC2086
chr_apt install $BASE_PKGS
# shellcheck disable=SC2086
chr_apt install $EXTRA_PKGS

# ---- 3. system configuration -----------------------------------------------------------
log "configuring system: hostname=$HOSTNAME_ user=$USER_ tz=$TZ_ locale=$LOCALE_"
echo "$HOSTNAME_" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
ln -sf "/usr/share/zoneinfo/$TZ_" "$ROOT/etc/localtime"; echo "$TZ_" > "$ROOT/etc/timezone"
if [ "$LOCALE_" != "C.UTF-8" ] && chr test -x /usr/sbin/locale-gen; then
    echo "$LOCALE_ UTF-8" >> "$ROOT/etc/locale.gen"; chr locale-gen >/dev/null
fi
echo "LANG=$LOCALE_" > "$ROOT/etc/default/locale"

# placeholder fstab; the image stage rewrites it with the real PARTUUIDs
cat > "$ROOT/etc/fstab" <<'EOF'
# populated by the tinker-edge-r image stage (root and /boot by PARTUUID)
EOF

# user with sudo, password login allowed (change it on first login!)
chr useradd -m -s /bin/bash -G sudo,adm,dialout,plugdev,video,audio,input,i2c,gpio,netdev,render "$USER_" 2>/dev/null \
    || chr useradd -m -s /bin/bash -G sudo,adm,dialout,plugdev,video,audio,input,netdev "$USER_"
echo "$USER_:$PASSWORD_" | chr chpasswd
echo "$USER_ ALL=(ALL) NOPASSWD: ALL" > "$ROOT/etc/sudoers.d/90-$USER_"; chmod 440 "$ROOT/etc/sudoers.d/90-$USER_"
chr passwd -l root >/dev/null

# ---- 4. overlay (config files, services, helper scripts) -------------------------------
log "applying overlay"
cp -a "$HERE/overlay/." "$ROOT/"
chmod 755 "$ROOT"/usr/local/sbin/* "$ROOT"/usr/local/bin/* 2>/dev/null || true

# ---- 5. kernel modules -------------------------------------------------------------
if [ -n "$KERNEL_OUT" ] && [ -d "$KERNEL_OUT/modules/lib/modules" ]; then
    REL="$(cat "$KERNEL_OUT/kernel.release")"
    log "installing kernel modules $REL"
    mkdir -p "$ROOT/lib/modules"
    cp -a "$KERNEL_OUT/modules/lib/modules/." "$ROOT/lib/modules/"
    chr depmod -a "$REL"
else
    log "no kernel modules given (--kernel-out); skipping"
fi

# ---- 6. firmware (Wi-Fi / Bluetooth) -----------------------------------------------
if [ "$SKIP_FIRMWARE" = 0 ]; then
    log "fetching pinned firmware files"
    while read -r url sha path; do
        [ -n "$url" ] || continue; case "$url" in \#*) continue ;; esac
        mkdir -p "$ROOT/lib/firmware/$(dirname "$path")"
        curl -fsSL --retry 3 -o "$ROOT/lib/firmware/$path" "$url" || die "download failed: $url"
        echo "$sha  $ROOT/lib/firmware/$path" | sha256sum -c --quiet - || die "checksum mismatch: $path"
    done < "$HERE/config/firmware.txt"
fi

# ---- 7. NPU userspace -------------------------------------------------------------
log "installing NPU userspace"
"$HERE/npu/install.sh" "$ROOT" "$NPU_SRC" "$SKIP_PIP"

# ---- 8. HDMI-RX helpers (EDID) --------------------------------------------------------
mkdir -p "$ROOT/usr/share/hdmirx"
python3 "$HERE/tools/mkedid.py" --profile 1080p30 -o "$ROOT/usr/share/hdmirx/edid-1080p30.bin"
python3 "$HERE/tools/mkedid.py" --profile 720p60 -o "$ROOT/usr/share/hdmirx/edid-720p60.bin"

# ---- 8b. on-device documentation + motd -----------------------------------------------
mkdir -p "$ROOT/usr/share/doc/tinker-edge-r"
if [ -n "$DOCS_DIR" ] && [ -d "$DOCS_DIR" ]; then
    cp -f "$DOCS_DIR"/*.md "$ROOT/usr/share/doc/tinker-edge-r/" 2>/dev/null || true
fi
cat > "$ROOT/etc/motd" <<EOF

  ASUS Tinker Edge R - Ubuntu $SUITE (arm64), built $(date -u +%F)
  docs: /usr/share/doc/tinker-edge-r/   NPU: npu-status   Type-C gadget: /etc/default/usb-gadget
  HDMI-RX (X1301): hdmirx-setup         change the default password with: passwd

EOF

# ---- 9. services ------------------------------------------------------------------
log "enabling services"
chr systemctl enable systemd-networkd systemd-resolved systemd-timesyncd ssh >/dev/null 2>&1
chr systemctl enable npu-firmware.service npu-transfer-proxy.service usb-gadget.service tinker-first-boot.service >/dev/null 2>&1
chr systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
# serial console on the fiq debugger UART (UART0 header pins); systemd also adds a
# getty for every console= device automatically.
chr systemctl enable serial-getty@ttyFIQ0.service >/dev/null 2>&1 || true
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf.systemd"

# ---- 10. cleanup ----------------------------------------------------------------------
log "cleanup"
chr apt-get clean
rm -rf "$ROOT/var/lib/apt/lists/"* "$ROOT/var/cache/apt/"*.bin "$ROOT/tmp/"* "$ROOT/root/.cache" 2>/dev/null || true
rm -f "$ROOT/usr/sbin/policy-rc.d" "$ROOT/etc/resolv.conf" "$ROOT/etc/resolv.conf.build"
mv "$ROOT/etc/resolv.conf.systemd" "$ROOT/etc/resolv.conf"
rm -f "$ROOT/etc/ssh/ssh_host_"*            # regenerated on first boot
: > "$ROOT/etc/machine-id"                  # regenerated on first boot
rm -f "$ROOT/var/lib/dbus/machine-id"
find "$ROOT/var/log" -type f -delete
umount_chroot

# ---- 11. manifest ------------------------------------------------------------------------
chr dpkg-query -W -f='${Package}\t${Version}\n' > "$OUTDIR/packages.txt" 2>/dev/null || \
    chroot "$ROOT" dpkg-query -W -f='${Package}\t${Version}\n' > "$OUTDIR/packages.txt"
{
    echo "suite/arch:   $SUITE/$ARCH ($MIRROR)"
    echo "built:        $(date -u +%FT%TZ)"
    echo "rootfs repo:  $(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel:       ${REL:-none}"
    echo "npu src:      ${NPU_SRC:-none} ($(git -C "$NPU_SRC" rev-parse --short HEAD 2>/dev/null || echo ?))"
    echo "user:         $USER_ (password set at build time; sudo without password)"
    echo "packages:     $(wc -l < "$OUTDIR/packages.txt")"
    echo "size:         $(du -sxh "$ROOT" | cut -f1)"
} > "$OUTDIR/BUILD-INFO.txt"
log "done: $(du -sxh "$ROOT" | cut -f1) in $ROOT"
