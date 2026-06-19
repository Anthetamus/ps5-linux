#!/bin/bash
# Build ps5-tinycore.img — smallest known PS5-bootable Linux image (~80 MB).
#
# Recipe:
#   * GPT canonical layout (matches the rest of the image matrix):
#       p2 numbered = FAT32 EFI labeled "boot", physically first (1MiB..EFI_END)
#       p1 numbered = ext4 placeholder rootfs, physically second (EFI_END..100%)
#   * bzImage = linux-ps5 build output (this script reads it from --bzimage).
#   * initrd  = TinyCore CorePure64 corepure64.gz +
#               every linux-ps5 kernel module from --modules-dir +
#               cyan_skillfish firmware (UNCOMPRESSED — linux-ps5's patched
#               request_firmware() writes the sig-stripped header back into
#               the firmware buffer, which oopses if the buffer was mapped
#               PAGE_KERNEL_RO from a zstd/xz blob) +
#               distros/tinycore/init (direct-to-shell, no /sbin/init).
#   * cmdline.txt = noembed multivt console=ttyTitania0 console=tty0 …
#
# Boots via ps5-linux-loader.elf — does NOT use /boot/efi/kexec.sh.  The
# loader only stat()s /mnt/usb*/bzImage,initrd.img,cmdline.txt on a
# FAT partition the PS5 OS auto-mounted; kexec.sh is irrelevant.
#
# Required inputs:
#   --bzimage <path>      linux-ps5 bzImage produced by the kernel-builder
#   --modules-dir <dir>   Mirrors /usr/lib/modules/<KVER>/ from a built rootfs
#                         (must contain kernel/, modules.builtin, modules.order)
#   --firmware-dir <dir>  Path containing cyan_skillfish*.{zst,xz,bin} (typically
#                         /usr/lib/firmware/amdgpu/ from a built rootfs)
# Optional:
#   --kver <ver>          Override kernel version (default: detected from --bzimage)
#   --img-size <MB>       Total disk image size (default: 80)
#   --efi-size <MB>       EFI partition size (default: 60)
#   --output <path>       Output image path (default: output/ps5-tinycore.img)
#   --keep-work           Don't delete the build workspace
#
# Network deps: curl, parted, mkfs.{ext4,vfat}, cpio, gzip, zstd, xz, depmod.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BZIMAGE=""
MODULES_DIR=""
FIRMWARE_DIR=""
KVER=""
IMG_SIZE_MB=80
EFI_SIZE_MB=60
OUTPUT=""
KEEP_WORK=0

usage() {
    sed -n '/^# Build ps5-tinycore/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bzimage)      BZIMAGE="$2"; shift 2 ;;
        --modules-dir)  MODULES_DIR="$2"; shift 2 ;;
        --firmware-dir) FIRMWARE_DIR="$2"; shift 2 ;;
        --kver)         KVER="$2"; shift 2 ;;
        --img-size)     IMG_SIZE_MB="$2"; shift 2 ;;
        --efi-size)     EFI_SIZE_MB="$2"; shift 2 ;;
        --output)       OUTPUT="$2"; shift 2 ;;
        --keep-work)    KEEP_WORK=1; shift ;;
        -h|--help)      usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

[ -n "$BZIMAGE" ] && [ -f "$BZIMAGE" ] || { echo "ERROR: --bzimage <existing file> required" >&2; exit 2; }
[ -n "$MODULES_DIR" ] && [ -d "$MODULES_DIR" ] || { echo "ERROR: --modules-dir <existing dir> required" >&2; exit 2; }
[ -n "$FIRMWARE_DIR" ] && [ -d "$FIRMWARE_DIR" ] || { echo "ERROR: --firmware-dir <existing dir> required" >&2; exit 2; }

# Auto-detect kernel version from the modules dir if not specified.
if [ -z "$KVER" ]; then
    if [ -f "$MODULES_DIR/modules.builtin" ]; then
        KVER="$(basename "$MODULES_DIR")"
    else
        # Modules dir is /usr/lib/modules/X.Y.Z — the basename IS the version.
        KVER="$(basename "$MODULES_DIR")"
    fi
fi
[ -n "$KVER" ] || { echo "ERROR: could not infer kernel version" >&2; exit 2; }

OUTPUT="${OUTPUT:-$REPO_ROOT/output/ps5-tinycore.img}"
WORK="${TMPDIR:-/tmp}/ps5-tinycore.$$"
mkdir -p "$WORK"
trap '[ "$KEEP_WORK" -eq 0 ] && rm -rf "$WORK"' EXIT

INIT_SCRIPT="$SCRIPT_DIR/init"
[ -f "$INIT_SCRIPT" ] || { echo "ERROR: missing $INIT_SCRIPT" >&2; exit 2; }

echo "==> kernel:     $BZIMAGE"
echo "==> modules:    $MODULES_DIR ($KVER)"
echo "==> firmware:   $FIRMWARE_DIR"
echo "==> output:     $OUTPUT"
echo "==> work dir:   $WORK"
echo "==> image:      ${IMG_SIZE_MB}MiB total, ${EFI_SIZE_MB}MiB EFI"

mkdir -p "$(dirname "$OUTPUT")"

#####################################################################
# 1. Fetch TinyCore CorePure64 base initrd.
#####################################################################
TC_VERSION="${TC_VERSION:-15.x}"
TC_ISO_URL="${TC_ISO_URL:-http://tinycorelinux.net/${TC_VERSION}/x86_64/release/CorePure64-current.iso}"
ISO="$WORK/CorePure64.iso"

echo "[1/5] downloading $TC_ISO_URL"
curl -fsSL -o "$ISO" "$TC_ISO_URL"

mkdir -p "$WORK/iso"
sudo mount -o loop,ro "$ISO" "$WORK/iso"
trap 'sudo umount "$WORK/iso" 2>/dev/null; sudo umount "$WORK/efi" 2>/dev/null; sudo losetup -D 2>/dev/null; [ "$KEEP_WORK" -eq 0 ] && rm -rf "$WORK"' EXIT

#####################################################################
# 2. Unpack corepure64.gz + augment with linux-ps5 modules/firmware/init.
#####################################################################
mkdir -p "$WORK/rootfs"
echo "[2/5] unpacking CorePure64 initrd"
zcat "$WORK/iso/boot/corepure64.gz" | (cd "$WORK/rootfs" && sudo cpio -idm 2>/dev/null)

echo "[2/5] copying linux-ps5 kernel modules ($KVER)"
sudo mkdir -p "$WORK/rootfs/lib/modules/$KVER"
sudo cp -a "$MODULES_DIR/kernel" "$WORK/rootfs/lib/modules/$KVER/"
for f in modules.builtin modules.order modules.builtin.alias.bin modules.builtin.bin; do
    [ -f "$MODULES_DIR/$f" ] && sudo cp "$MODULES_DIR/$f" "$WORK/rootfs/lib/modules/$KVER/"
done

echo "[2/5] copying + decompressing cyan_skillfish firmware"
sudo mkdir -p "$WORK/rootfs/lib/firmware/amdgpu"
for f in "$FIRMWARE_DIR"/cyan_skillfish*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    real="$(readlink -f "$f")"
    case "$real" in
        *.zst) out="${base%.zst}"; sudo zstd -d -c "$real" | sudo tee "$WORK/rootfs/lib/firmware/amdgpu/$out" >/dev/null ;;
        *.xz)  out="${base%.xz}";  sudo xz   -d -c "$real" | sudo tee "$WORK/rootfs/lib/firmware/amdgpu/$out" >/dev/null ;;
        *)     sudo cp "$real" "$WORK/rootfs/lib/firmware/amdgpu/$base" ;;
    esac
done

sudo depmod -b "$WORK/rootfs" "$KVER"

echo "[2/5] installing custom /init"
sudo install -m 0755 "$INIT_SCRIPT" "$WORK/rootfs/init"

sudo umount "$WORK/iso"

#####################################################################
# 3. Repack initrd as initrd.img (gzip — kernel reads it transparently).
#####################################################################
echo "[3/5] repacking initrd"
( cd "$WORK/rootfs" && sudo find . -print0 | sudo cpio --null -o -H newc 2>/dev/null ) \
    | gzip -9 > "$WORK/initrd.img"
ls -la "$WORK/initrd.img"

#####################################################################
# 4. Build the disk image with the canonical PS5 layout.
#    EFI is partition NUMBER 2, physically FIRST (matches Debian/Alpine
#    images that PS5 OS auto-mounts at /mnt/usb*). PS5 OS won't mount
#    arbitrary FAT positions/numbers — this exact layout is required.
#####################################################################
echo "[4/5] building disk image"
IMG="$WORK/ps5-tinycore.img"
truncate -s "${IMG_SIZE_MB}M" "$IMG"
sudo parted -s "$IMG" mklabel gpt
sudo parted -s "$IMG" mkpart primary ext4  "${EFI_SIZE_MB}MiB" 100%
sudo parted -s "$IMG" mkpart primary fat32 1MiB                "${EFI_SIZE_MB}MiB"
sudo parted -s "$IMG" set 2 esp on

LOOP="$(sudo losetup -fP --show "$IMG")"
sleep 1
sudo mkfs.ext4 -F -q -L tinycore-rootfs "${LOOP}p1"
sudo mkfs.vfat -n boot -F32 "${LOOP}p2" >/dev/null

mkdir -p "$WORK/efi"
sudo mount "${LOOP}p2" "$WORK/efi"
sudo cp "$BZIMAGE"        "$WORK/efi/bzImage"
sudo cp "$WORK/initrd.img" "$WORK/efi/initrd.img"
sudo tee "$WORK/efi/cmdline.txt" >/dev/null <<'EOF'
console=ttyTitania0 console=tty0 mitigations=off idle=halt preempt=full noembed multivt
EOF

sudo umount "$WORK/efi"
sudo losetup -d "$LOOP"

#####################################################################
# 5. Stage to OUTPUT.
#####################################################################
echo "[5/5] moving to $OUTPUT"
mv "$IMG" "$OUTPUT"
ls -la "$OUTPUT"

echo
echo "DONE. flash with:"
echo "  sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress conv=fsync"
echo
echo "On PS5: jailbreak (Netflix-N-Hack / umtx2 / Y2JB), then:"
echo "  socat -t 99999999 - TCP:\$PS5IP:9021 < ps5-linux-loader.elf"
