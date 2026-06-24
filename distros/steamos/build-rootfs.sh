#!/bin/bash
# distros/steamos/build-rootfs.sh — fetch Valve's Steam Deck recovery image,
# extract its erofs rootfs to $CHROOT, swap in our linux-ps5 kernel. Called
# from docker/image-builder/entrypoint.sh for DISTRO=steamos.
#
# Source: https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2
#   ~3.4 GB compressed, ~10 GB raw. Valve's CDN, fast (no per-IP throttle
#   we've hit so far). The framework hard-links /data/cache/ps5/downloads/*
#   into image/work/cache before the build container starts, so subsequent
#   runs are instant.
#
# Image layout: GPT with EFI-A/B + rootfs-A/B (erofs, identical) + var-A/B
# (ext4) + home (ext4). We pull rootfs-A (whichever erofs partition is
# first by index) and var-A (whichever is first ext4 < 2 GB containing
# /lib or /log directories).
#
# Expects in env: DISTRO, CHROOT, KVER
# Expects on disk: /kernel-debs/linux-ps5-*.pkg.tar.zst (Arch pkg)
set -ex

: "${CHROOT:?ERROR: \$CHROOT unset/empty}"
[ -d "$CHROOT" ] || { echo "ERROR: \$CHROOT=$CHROOT not a directory"; exit 2; }
case "$CHROOT" in /) echo "ERROR: refuse to operate on /"; exit 2 ;; esac

STEAMOS_URL="${STEAMOS_URL:-https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2}"

echo "=== SteamOS: resolve latest image URL ==="
# `-latest` is a 302 to a dated filename like steamdeck-oobe-repair-YYYYMMDD.10-3.X.X.img.bz2.
# Follow the redirect once so the cache key matches a stable filename and
# we can rebuild deterministically without re-downloading every run.
RESOLVED_URL=$(curl -sIL -o /dev/null -w '%{url_effective}' "$STEAMOS_URL")
IMG_NAME=$(basename "$RESOLVED_URL")
echo ">> resolved $IMG_NAME"

CACHED="/build/cache/$IMG_NAME"
if [ ! -s "$CACHED" ]; then
    echo ">> downloading $IMG_NAME from Valve CDN"
    wget --tries=3 -O "$CACHED.part" "$RESOLVED_URL"
    mv "$CACHED.part" "$CACHED"
fi
echo ">> using $CACHED ($(du -h "$CACHED" | cut -f1))"

echo "=== SteamOS: decompress + loop ==="
STEAMOS_IMG=/build/steamos-src.img
bunzip2 -kc "$CACHED" > "$STEAMOS_IMG"
SLOOP=$(losetup -Pf --show "$STEAMOS_IMG")
sleep 1
# kpartx fallback in case partition kernel events didn't fire
[ -e "${SLOOP}p1" ] || kpartx -av "$SLOOP"

# Pick the FIRST erofs partition (rootfs-A; A and B are identical).
SROOT=""
for p in "${SLOOP}"p*; do
    [ -e "$p" ] || continue
    t=$(blkid -o value -s TYPE "$p" 2>/dev/null || echo "")
    if [ "$t" = "erofs" ]; then
        SROOT="$p"
        break
    fi
done
[ -z "$SROOT" ] && { echo "ERROR: no erofs rootfs in SteamOS image"; exit 1; }
echo ">> rootfs slot: $SROOT"

SMNT=$(mktemp -d)
mount -t erofs -o ro "$SROOT" "$SMNT"
echo "=== SteamOS: copy rootfs ($(du -sh "$SMNT" | cut -f1)) -> \$CHROOT ==="
cp -a "$SMNT"/. "$CHROOT/"
umount "$SMNT"
rmdir "$SMNT"

# SteamOS splits /var off the rootfs onto its own partition; without it,
# things like systemd-journald, pacman db, /var/lib/dbus all start empty
# and the first boot fails (no machine-id, etc).
VARMNT=$(mktemp -d)
for p in "${SLOOP}"p*; do
    [ -e "$p" ] || continue
    t=$(blkid -o value -s TYPE "$p" 2>/dev/null || echo "")
    sz=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
    if [ "$t" = "ext4" ] && [ "$sz" -lt $((2 * 1024 * 1024 * 1024)) ]; then
        if mount -o ro "$p" "$VARMNT" 2>/dev/null; then
            if [ -d "$VARMNT/lib" ] || [ -d "$VARMNT/log" ]; then
                echo "=== SteamOS: copy var ($(du -sh "$VARMNT" | cut -f1)) -> \$CHROOT/var ==="
                mkdir -p "$CHROOT/var"
                cp -a "$VARMNT"/. "$CHROOT/var/" || true
                umount "$VARMNT"
                break
            fi
            umount "$VARMNT" 2>/dev/null || true
        fi
    fi
done
rmdir "$VARMNT"

losetup -d "$SLOOP"

echo "=== SteamOS: install linux-ps5 kernel pkg ==="
PKG=$(ls /kernel-debs/linux-ps5-*.pkg.tar.zst 2>/dev/null | head -1)
[ -z "$PKG" ] && { echo "ERROR: no /kernel-debs/linux-ps5-*.pkg.tar.zst found"; exit 1; }
TMP=$(mktemp -d)
bsdtar -xf "$PKG" -C "$TMP"
# pkg.tar.zst lays itself out as { usr/lib/modules/$KVER/, boot/vmlinuz-$KVER, etc/modprobe.d/* }
for d in usr boot etc; do
    [ -d "$TMP/$d" ] && cp -a "$TMP/$d"/. "$CHROOT/$d/" 2>/dev/null || true
done
rm -rf "$TMP"

# Remove SteamOS's own kernel(s) — we want grub to boot ours, not theirs.
# Their kernel lives at /boot/vmlinuz-linux-neptune* and its modules at
# /usr/lib/modules/<some-neptune-kver>/.
rm -f "$CHROOT"/boot/vmlinuz-linux*       2>/dev/null || true
rm -f "$CHROOT"/boot/initrd*-neptune*     2>/dev/null || true
rm -f "$CHROOT"/boot/initramfs-linux*.img 2>/dev/null || true
for d in "$CHROOT"/usr/lib/modules/*; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "$KVER" ] && continue
    rm -rf "$d"
done

# Rebuild module index for our kernel. If depmod isn't in the rootfs (unlikely
# but possible if SteamOS trimmed it), the host's will do — we just need a
# usable modules.dep.
if [ -x "$CHROOT/usr/bin/depmod" ]; then
    chroot "$CHROOT" /usr/bin/depmod -a "$KVER" || true
else
    depmod -b "$CHROOT" "$KVER" || true
fi

# Make sure /boot/vmlinuz-$KVER exists (the framework's grub/cmdline step
# expects it). Some pkg layouts put it as /boot/vmlinuz (unversioned).
[ -f "$CHROOT/boot/vmlinuz-$KVER" ] || cp "$CHROOT"/boot/vmlinuz-* "$CHROOT/boot/vmlinuz-$KVER" 2>/dev/null || true

echo "=== SteamOS: rootfs prepared at \$CHROOT ($(du -sh "$CHROOT" | cut -f1)) ==="
