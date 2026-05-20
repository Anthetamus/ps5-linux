#!/bin/bash
set -ex

DISTRO="${DISTRO:-ubuntu2604}"
# Bazzite ships large (~10 GB rootfs after OCI unpack), bump the default img.
case "${DISTRO}" in bazzite*) IMG_SIZE="${IMG_SIZE:-20000}" ;; *) IMG_SIZE="${IMG_SIZE:-12000}" ;; esac
SKIP_CHROOT="${SKIP_CHROOT:-false}"
STAGING="/tmp/build-staging"
ROOT_LABEL="${DISTRO}"
EFI_LABEL="boot"
CHROOT="/build/chroot"
IMG="/output/ps5-${DISTRO}.img"

if [ "$SKIP_CHROOT" = "true" ] && [ -d "$CHROOT/bin" ]; then
    echo "=== Reusing cached $DISTRO rootfs ==="
else
    echo "=== Building $DISTRO rootfs ==="
    # --- Stage files for distrobuilder's copy generators ---
    rm -rf "$STAGING"
    mkdir -p "$STAGING/debs"
    cp /repo/distros/shared/zz-update-boot      "$STAGING/"
    # Generate per-distro fstab with partition labels
    cat <<EOF > "$STAGING/fstab"
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL /boot/efi vfat defaults 0 1
EOF
    cp /repo/distros/${DISTRO}/nm-dns.conf       "$STAGING/" 2>/dev/null || true

    case "$DISTRO" in
        ubuntu*|debian*)
            cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
            cp /kernel-debs/*.deb                          "$STAGING/debs/"
            ;;
        fedora*)
            cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
            mkdir -p "$STAGING/rpms"
            cp /kernel-debs/*.rpm                          "$STAGING/rpms/"
            ;;
        alpine)
            cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
            cp /repo/distros/alpine/grow-rootfs.openrc     "$STAGING/"
            ;;
        arch)
            cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
            cp /repo/distros/arch/grow-rootfs.service      "$STAGING/"
            cp /repo/distros/arch/first-boot-setup         "$STAGING/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                  "$STAGING/pkgs/"
            ;;
        cachyos)
            mkdir -p "$STAGING/files"
            cp /repo/distros/cachyos/files/grow-rootfs                "$STAGING/files/"
            cp /repo/distros/cachyos/files/grow-rootfs.service        "$STAGING/files/"
            cp /repo/distros/cachyos/files/first-boot-setup           "$STAGING/files/"
            cp /repo/distros/cachyos/files/first-boot.service         "$STAGING/files/"
            cp /repo/distros/cachyos/files/gamescope-session-ps5      "$STAGING/files/"
            cp /repo/distros/cachyos/files/steamos-session-select     "$STAGING/files/"
            cp /repo/distros/cachyos/files/return-to-gaming-mode.desktop "$STAGING/files/"
            cp /repo/distros/cachyos/files/ps5-display.lua            "$STAGING/files/"
            cp /repo/distros/cachyos/files/plasma-workspace-env-ps5.sh "$STAGING/files/"
            cp /repo/distros/cachyos/files/ps5-tty-session.sh         "$STAGING/files/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                             "$STAGING/pkgs/"
            ;;
    esac

    # --- Build rootfs ---
    rm -rf "$CHROOT"/* "$CHROOT"/.[!.]* 2>/dev/null || true

    case "$DISTRO" in
        bazzite*)
            # Bazzite is an OCI atomic image; bypass distrobuilder entirely.
            REF="ghcr.io/ublue-os/bazzite:stable"
            echo "=== Bazzite: skopeo copy $REF ==="
            OCI=$(mktemp -d)
            skopeo copy --override-os linux --override-arch amd64 \
                "docker://$REF" "oci:$OCI:bazzite"
            echo "=== umoci unpack -> $CHROOT ==="
            UNPACK=$(mktemp -d)
            umoci unpack --keep-dirlinks --image "$OCI:bazzite" "$UNPACK"
            # umoci layout: $UNPACK/{config.json, rootfs/}
            mv "$UNPACK/rootfs"/* "$CHROOT/" 2>/dev/null || true
            mv "$UNPACK/rootfs"/.[!.]* "$CHROOT/" 2>/dev/null || true
            rm -rf "$UNPACK" "$OCI"
            # ostree convention: /usr/etc holds the defaults; /etc is empty in
            # the image. Promote /usr/etc to /etc so the system boots normally.
            if [ -d "$CHROOT/usr/etc" ]; then
                cp -an "$CHROOT/usr/etc/." "$CHROOT/etc/" || true
                rm -rf "$CHROOT/usr/etc"
            fi
            # Stage PS5 kernel RPMs + grow-rootfs. /opt and /home are ostree
            # symlinks in Bazzite, /var is a real dir — drop staging files there.
            mkdir -p "$CHROOT/var/cache/ps5-rpms"
            cp /kernel-debs/*.rpm "$CHROOT/var/cache/ps5-rpms/"
            # /usr/local is a symlink to /var/usrlocal in ostree-based systems;
            # mkdir the target before cp to avoid following-symlink-on-missing.
            mkdir -p "$CHROOT/var/usrlocal/sbin"
            cp /repo/distros/bazzite/grow-rootfs       "$CHROOT/var/usrlocal/sbin/grow-rootfs"
            chmod +x "$CHROOT/var/usrlocal/sbin/grow-rootfs"
            cp /repo/distros/bazzite/grow-rootfs.service "$CHROOT/etc/systemd/system/grow-rootfs.service"
            # Chroot in: disable ostree stack, install PS5 kernel, user setup.
            # Trap to always umount, even if the chroot script exits early.
            cleanup_bazzite_mounts() {
                for m in dev sys proc; do
                    mountpoint -q "$CHROOT/$m" && umount "$CHROOT/$m" || true
                done
            }
            trap cleanup_bazzite_mounts RETURN ERR EXIT
            mount --bind /proc "$CHROOT/proc"
            mount --bind /sys  "$CHROOT/sys"
            mount --bind /dev  "$CHROOT/dev"
            # Bazzite has no /etc/resolv.conf inside the chroot (symlink target
            # doesn't exist yet) — provide a working one so dnf can reach mirrors.
            rm -f "$CHROOT/etc/resolv.conf"
            cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
            chroot "$CHROOT" /bin/bash -e <<"BAZIN"
                # Disable rpm-ostree services — we're a flat fs now.
                systemctl mask rpm-ostreed.service rpm-ostree-countme.service rpm-ostree-bootstatus.service 2>/dev/null || true
                # Install PS5 kernel via rpm --replacefiles (handles the file-
                # level conflict between our /usr/include/* headers and
                # Bazzite's kernel-headers; see fedora image.yaml comment).
                # Bazzite ships kernel modules as a dir; our rpm wants a symlink.
                rm -rf /lib/modules/*
                rpm -Uvh --replacefiles --replacepkgs --nodeps /var/cache/ps5-rpms/*.rpm
                rm -rf /var/cache/ps5-rpms
                # Build the initrd at the path zz-update-boot expects, then
                # deploy bzImage+initrd to /boot/efi/ for the PS5 kexec loader.
                KVER=$(ls -1t /lib/modules | head -1)
                dracut -f --kver "$KVER" "/boot/initrd.img-$KVER"
                /etc/kernel/postinst.d/zz-update-boot "$KVER"
                # User setup. Bazzite's slim OCI image doesn't pre-create the
                # video/audio/input/render groups, and useradd -G fails on
                # missing groups under bash -e. Build the list dynamically.
                passwd -l root
                GRPS="wheel"
                for g in video audio input render; do
                    getent group "$g" >/dev/null 2>&1 && GRPS="$GRPS,$g"
                done
                if ! id ps5 >/dev/null 2>&1; then
                    useradd -m -s /bin/bash -G "$GRPS" ps5
                fi
                echo "ps5:ps5" | chpasswd
                sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true
                # Services
                systemctl enable grow-rootfs.service NetworkManager sshd 2>/dev/null || true
                # Default DM (Bazzite ships KDE Plasma + SDDM)
                systemctl enable sddm 2>/dev/null || systemctl enable gdm 2>/dev/null || true
                # resolv.conf -> systemd-resolved stub
                rm -f /etc/resolv.conf
                ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                # SDDM autologin for ps5
                mkdir -p /etc/sddm.conf.d
                cat > /etc/sddm.conf.d/autologin.conf <<SDDM
[Autologin]
User=ps5
Session=plasma
SDDM
BAZIN
            # explicit cleanup (the trap covers the failure path)
            cleanup_bazzite_mounts
            trap - RETURN ERR EXIT
            ;;
        *)
            YAML="/repo/distros/${DISTRO}/image.yaml"
            distrobuilder build-dir "$YAML" "$CHROOT" --with-post-files --cache-dir /build/cache --cleanup=false
            ;;
    esac
fi

# --- Post-distrobuilder fixups ---
case "$DISTRO" in
    ubuntu*|debian*|fedora*|bazzite*)
        rm -f "$CHROOT/etc/resolv.conf"
        ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
        ;;
esac

# --- Alpine kernel gap: no kernel installed via image.yaml ---
# Extract kernel from .deb, copy modules + bzImage, then chroot to run mkinitfs
if [ "$DISTRO" = "alpine" ]; then
    echo "=== Alpine: installing kernel from .deb artifacts ==="

    ALPINE_STAGING="/tmp/alpine-kernel-staging"
    rm -rf "$ALPINE_STAGING"
    mkdir -p "$ALPINE_STAGING"
    for deb in /kernel-debs/linux-image-*.deb; do
        [ -f "$deb" ] || continue
        dpkg-deb -x "$deb" "$ALPINE_STAGING"
    done

    KVER=$(ls -1 "$ALPINE_STAGING/lib/modules" 2>/dev/null | head -1)

    if [ -n "$KVER" ]; then
        # Resolve the real modules path (Alpine may use usr-merge: /lib -> usr/lib)
        if [ -L "$CHROOT/lib" ]; then
            MODDIR="$CHROOT/usr/lib/modules"
        else
            MODDIR="$CHROOT/lib/modules"
        fi
        mkdir -p "$MODDIR"
        rm -rf "$MODDIR/$KVER"
        cp -a "$ALPINE_STAGING/lib/modules/$KVER" "$MODDIR/"
        mkdir -p "$CHROOT/boot"
        cp "$ALPINE_STAGING/boot/vmlinuz-$KVER" "$CHROOT/boot/vmlinuz-$KVER"
        echo ">> Alpine: modules copied to $MODDIR/$KVER"
    fi
    rm -rf "$ALPINE_STAGING"

    if [ -n "$KVER" ]; then
        chroot "$CHROOT" depmod -a "$KVER" 2>/dev/null || true

        mount --bind /dev  "$CHROOT/dev"
        mount --bind /proc "$CHROOT/proc"
        mount --bind /sys  "$CHROOT/sys"
        chroot "$CHROOT" mkinitfs -k "$KVER" -o "/boot/initrd.img-$KVER" "$KVER" || true
        umount "$CHROOT/sys" "$CHROOT/proc" "$CHROOT/dev"

        # Populate /boot/efi/ for boot partition assembly
        mkdir -p "$CHROOT/boot/efi"
        cp "$CHROOT/boot/vmlinuz-$KVER" "$CHROOT/boot/efi/bzImage"
        if [ -f "$CHROOT/boot/initrd.img-$KVER" ]; then
            cp "$CHROOT/boot/initrd.img-$KVER" "$CHROOT/boot/efi/initrd.img"
        else
            INITRD=$(ls -1t "$CHROOT"/boot/initramfs-* "$CHROOT"/boot/initrd* 2>/dev/null | head -1)
            if [ -n "$INITRD" ]; then
                cp "$INITRD" "$CHROOT/boot/efi/initrd.img"
            else
                echo "WARNING: No initrd found for alpine after mkinitfs"
            fi
        fi
        echo ">> Alpine: kernel $KVER staged to boot/efi/"
    else
        echo "WARNING: No kernel modules found in .deb for alpine"
    fi
fi

# --- Create GPT disk image ---
echo "=== Creating ${IMG_SIZE}MB disk image ==="
TMPIMG="/build/ps5-${DISTRO}.img"
dd if=/dev/zero of="$TMPIMG" bs=1M count=$IMG_SIZE conv=fsync status=progress

parted -s "$TMPIMG" mklabel gpt
parted -s "$TMPIMG" mkpart primary ext4  500MiB 100%
parted -s "$TMPIMG" mkpart primary fat32 1MiB   500MiB
parted -s "$TMPIMG" set 2 esp on

# Ensure the free loop device node exists (udev doesn't run inside containers,
# so when the kernel allocates a new loop number it may lack a /dev node)
LOOP_PATH=$(losetup -f)
if [ ! -e "$LOOP_PATH" ]; then
    LOOP_NUM=${LOOP_PATH#/dev/loop}
    mknod "$LOOP_PATH" b 7 "$LOOP_NUM"
fi

LOOPDEV=$(losetup -f --show "$TMPIMG")
# Use kpartx to create partition device mappings (more reliable in containers)
kpartx -av "$LOOPDEV"
sleep 1

# kpartx creates /dev/mapper/loopXp1, /dev/mapper/loopXp2
LOOP_BASE=$(basename "$LOOPDEV")
PART1="/dev/mapper/${LOOP_BASE}p1"
PART2="/dev/mapper/${LOOP_BASE}p2"

echo "=== Formatting partitions ==="
mkfs.ext4 -L "$ROOT_LABEL" -m 1  "$PART1"
mkfs.vfat -n "$EFI_LABEL"  -F32  "$PART2"

mkdir -p /tmp/usb_root /tmp/usb_efi
mount "$PART1" /tmp/usb_root
mount "$PART2" /tmp/usb_efi

echo "=== Copying rootfs to image ==="
cp -a "$CHROOT"/* /tmp/usb_root/
sync

echo "=== Assembling boot partition ==="
mv /tmp/usb_root/boot/efi/* /tmp/usb_efi/ 2>/dev/null || true
sed "s|__DISTRO__|$ROOT_LABEL|" /repo/boot/cmdline.txt > /tmp/usb_efi/cmdline.txt
cp /repo/boot/vram.txt     /tmp/usb_efi/
cp /repo/boot/kexec.sh     /tmp/usb_efi/
sync

umount /tmp/usb_root /tmp/usb_efi
rmdir  /tmp/usb_root /tmp/usb_efi
kpartx -dv "$LOOPDEV"
losetup -d "$LOOPDEV"

# Move finished image to output volume
mv "$TMPIMG" "$IMG"
sync

echo "========================================"
echo "Done! $IMG (${IMG_SIZE}MB)"
echo "Flash: sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "========================================"
