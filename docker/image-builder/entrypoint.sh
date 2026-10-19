#!/bin/bash
set -ex

DISTRO="${DISTRO:-ubuntu2604}"
# Bazzite ships large (~10 GB rootfs after OCI unpack), bump the default img.
case "${DISTRO}" in
    bazzite*)  IMG_SIZE="${IMG_SIZE:-20000}" ;;
    batocera*) IMG_SIZE="${IMG_SIZE:-16000}" ;;
    steamos)   IMG_SIZE="${IMG_SIZE:-14000}" ;;
    *)         IMG_SIZE="${IMG_SIZE:-12000}" ;;
esac
SKIP_CHROOT="${SKIP_CHROOT:-false}"
STAGING="/tmp/build-staging"
ROOT_LABEL="${DISTRO:0:16}"
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
LABEL=$EFI_LABEL /boot/efi vfat defaults,nofail,x-systemd.device-timeout=10s 0 2
EOF
    cp /repo/distros/${DISTRO}/nm-dns.conf       "$STAGING/" 2>/dev/null || true

    case "$DISTRO" in
        ubuntu*|debian*|mint*|hannah-montana-linux)
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
        devuan*)
            # Devuan: same deb/debootstrap pipeline, but the boot-time
            # grow-rootfs is a sysv init script (no systemd here) instead
            # of a .service unit.
            cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.sysv  "$STAGING/"
            # Pre-provisioned wifi (test builds only — strip before push)
            [ -f /repo/distros/${DISTRO}/wifi.nmconnection ] && \
                cp /repo/distros/${DISTRO}/wifi.nmconnection "$STAGING/"
            cp /kernel-debs/*.deb                          "$STAGING/debs/"
            # Ubuntu's debootstrap (the one bundled in this builder image)
            # doesn't ship a script for any Devuan codename, so it bails on
            # `excalibur` / `daedalus` etc. with "No such script". Excalibur
            # is built on top of Debian 13 Trixie's archive layout, so
            # symlinking the suite onto debootstrap's trixie script gives
            # us a functional bootstrap path without touching the Dockerfile.
            DEVUAN_RELEASE=$(awk '/^[[:space:]]*release:/ {print $2; exit}' \
                /repo/distros/${DISTRO}/image.yaml)
            if [ -n "$DEVUAN_RELEASE" ] && [ ! -e "/usr/share/debootstrap/scripts/$DEVUAN_RELEASE" ]; then
                ln -sf trixie "/usr/share/debootstrap/scripts/$DEVUAN_RELEASE"
            fi
            ;;
        artix*)
            # Artix bootstraps from its live ISO (no upstream tarball);
            # the only staged files are the init-specific grow-rootfs
            # pair and the linux-ps5 .pkg.tar.zst kernel. Pick the right
            # variant by DISTRO name — openrc by default, runit when the
            # distro is explicitly artix-runit.
            case "$DISTRO" in
                artix-runit)
                    cp /repo/distros/artix-runit/grow-rootfs       "$STAGING/"
                    cp /repo/distros/artix-runit/grow-rootfs.runit "$STAGING/"
                    ;;
                *)
                    cp /repo/distros/artix-openrc/grow-rootfs        "$STAGING/"
                    cp /repo/distros/artix-openrc/grow-rootfs.openrc "$STAGING/"
                    ;;
            esac
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                    "$STAGING/pkgs/"
            ;;
        arch|endeavoros)
            cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
            cp /repo/distros/${DISTRO}/first-boot-setup    "$STAGING/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                  "$STAGING/pkgs/"
            ;;
        miaos*)
            # MiaOS recipe is self-contained in distros/miaos/image.yaml
            # (gamescope + Steam + KDE post-install via distrobuilder actions).
            # Only the patched kernel needs staging here.
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
        steamos)
            # SteamOS image-swap path: stages just the linux-ps5 pkg.tar.zst
            # so the rootfs build below can extract it into the unpacked
            # SteamOS rootfs.
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                             "$STAGING/pkgs/"
            ;;
    esac

    # --- Build rootfs ---
    rm -rf "$CHROOT"/* "$CHROOT"/.[!.]* 2>/dev/null || true

    case "$DISTRO" in
        batocera*)
            # Batocera is a Buildroot-based emulation distro. It ships as a
            # single .img.gz with FAT32 boot + ext4 SHARE partitions; the OS
            # itself lives in a squashfs file (`/boot/batocera`) on the FAT32.
            # We unsquash, swap our PS5 kernel + modules in, and let the rest
            # of the standard image-builder flow pack everything onto ext4.
            BATOCERA_VER="${BATOCERA_VER:-43}"
            BATOCERA_BUILD="${BATOCERA_BUILD:-20260430}"
            BATOCERA_URL="${BATOCERA_URL:-https://mirrors.o2switch.fr/batocera/x86_64/stable/last/batocera-x86_64-${BATOCERA_VER}-${BATOCERA_BUILD}.img.gz}"

            echo "=== Batocera: locate / download $BATOCERA_VER ($BATOCERA_BUILD) ==="
            # /build/cache is per-run temp. The workflow symlinks /build/cache/
            # persistent -> /data/cache/ps5/downloads, so the .img.gz can be
            # pre-staged or survive between runs. The mirror rate-limits per-IP
            # to ~250KB/s sustained (4MB/s burst), so re-downloading every run
            # is unacceptably slow.
            # The workflow hard-links /data/cache/ps5/downloads/* into
            # image/work/cache before the build container starts, so the
            # image appears as /build/cache/batocera-*.img.gz inside.
            CACHED="/build/cache/batocera-${BATOCERA_VER}-${BATOCERA_BUILD}.img.gz"
            if [ ! -s "$CACHED" ]; then
                echo ">> No cached image, downloading (this will be slow due to mirror rate-limiting)"
                wget --tries=3 -O "$CACHED.part" "$BATOCERA_URL"
                mv "$CACHED.part" "$CACHED"
            fi
            echo ">> Using $CACHED ($(du -h "$CACHED" | cut -f1))"

            echo "=== Batocera: decompress + loop ==="
            BAT_IMG=/build/batocera-src.img
            gunzip -c "$CACHED" > "$BAT_IMG"
            BATLOOP=$(losetup -Pf --show "$BAT_IMG")
            sleep 1
            # kpartx fallback in case partition kernel events didn't fire
            [ -e "${BATLOOP}p1" ] || kpartx -av "$BATLOOP"
            BAT_MNT=$(mktemp -d)
            BAT_PART1=""
            for p in "${BATLOOP}p1" "/dev/mapper/$(basename "$BATLOOP")p1"; do
                [ -e "$p" ] && BAT_PART1="$p" && break
            done
            mount -o ro "$BAT_PART1" "$BAT_MNT"

            BAT_SQUASH=""
            for c in /boot/batocera /batocera /boot/batocera.update; do
                [ -f "$BAT_MNT$c" ] && BAT_SQUASH="$BAT_MNT$c" && break
            done
            if [ -z "$BAT_SQUASH" ]; then
                echo "ERROR: squashfs not found in batocera image:"
                find "$BAT_MNT" -maxdepth 3 -type f | head -30
                exit 1
            fi
            echo "=== Batocera: unsquashfs $BAT_SQUASH -> $CHROOT ==="
            unsquashfs -f -d "$CHROOT" "$BAT_SQUASH"

            # Batocera ships a SECOND squashfs (boot/rufomaculata) with the
            # libretro cores, mame binary, and other emulator assets. At
            # runtime it's mounted as a second overlayfs layer on top of the
            # main batocera squashfs. We don't do overlay — just unsquash
            # rufomaculata on top of $CHROOT so the unified view is realised
            # on the ext4 root. Without this, /usr/lib/libretro/ doesn't
            # exist and EmulationStation reports "no games start" because
            # retroarch fails to load any core.
            if [ -f "$BAT_MNT/boot/rufomaculata" ]; then
                echo "=== Batocera: unsquashfs boot/rufomaculata (libretro + mame) -> $CHROOT ==="
                unsquashfs -f -d "$CHROOT" "$BAT_MNT/boot/rufomaculata"
            else
                echo "WARN: boot/rufomaculata not found — emulator cores will be missing"
            fi

            umount "$BAT_MNT"
            rmdir "$BAT_MNT"
            kpartx -dv "$BATLOOP" 2>/dev/null || true
            losetup -d "$BATLOOP"
            rm -f "$BAT_IMG"

            echo "=== Batocera: install linux-ps5 kernel + modules ==="
            KSTAGE=/tmp/bat-kernel-staging
            rm -rf "$KSTAGE"; mkdir -p "$KSTAGE"
            # The kernel-builder ships a single combined linux-ps5_*.deb
            # (Provides: linux-image-X) — there is no linux-image-*.deb on
            # disk, so target the actual filename pattern.
            shopt -s nullglob
            for deb in /kernel-debs/linux-ps5*.deb /kernel-debs/linux-image-*.deb; do
                [ -f "$deb" ] && dpkg-deb -x "$deb" "$KSTAGE"
            done
            shopt -u nullglob
            KVER=$(ls -1 "$KSTAGE/lib/modules" 2>/dev/null | head -1)
            if [ -z "$KVER" ]; then
                echo "ERROR: no kernel modules found after dpkg-deb -x of /kernel-debs/*.deb"
                ls -la /kernel-debs/
                exit 1
            fi
            rm -rf "$CHROOT"/lib/modules/*
            cp -a "$KSTAGE/lib/modules/$KVER" "$CHROOT/lib/modules/"
            mkdir -p "$CHROOT/boot/efi"
            cp "$KSTAGE/boot/vmlinuz-$KVER" "$CHROOT/boot/efi/bzImage"
            # depmod -b runs from outside the chroot — Batocera's busybox
            # depmod may not be present, and host depmod handles -b cleanly.
            depmod -a -b "$CHROOT" "$KVER" || true
            # Stage WLAN firmware loader + module autoload (same files the
            # debian/fedora paths get from /kernel-debs/staging via .deb).
            for src in usr/local/sbin etc/modules-load.d etc/systemd/system; do
                [ -d "$KSTAGE/$src" ] || continue
                mkdir -p "$CHROOT/$src"
                cp -an "$KSTAGE/$src/." "$CHROOT/$src/" || true
            done

            echo "=== Batocera: PS5 modprobe quirks ==="
            mkdir -p "$CHROOT/etc/modprobe.d" "$CHROOT/etc/modules-load.d"
            cat > "$CHROOT/etc/modprobe.d/ps5-amdgpu.conf" <<MODPROBE
options amdgpu dpm=0 gpu_recovery=0
MODPROBE
            # uinput is needed by Batocera's hotkeygen (for virtual keyboard
            # events when launching games). It's not autoloaded by default on
            # PS5, so hotkeygen crashes with 'UInputError: /dev/uinput does
            # not exist'. Force-load on boot.
            cat > "$CHROOT/etc/modules-load.d/uinput.conf" <<MODPROBE
uinput
MODPROBE

            echo "=== Batocera: build initrd via host mkinitramfs ==="
            # Host (image-builder, ubuntu:24.04) has initramfs-tools. Trick
            # it into building for our PS5 kernel by symlinking the chroot's
            # modules into /lib/modules/$KVER, then unlinking after.
            #
            # initramfs-tools default behaviour: autodetect kernel modules
            # from /sys on the BUILD HOST — which is a docker container with
            # no USB, no amdgpu, no real disks. The resulting initrd would
            # ship without xhci_pci / usb_storage / ext4 / amdgpu drivers,
            # and the PS5 hangs silently when the kernel tries to find the
            # USB root partition. Override with an explicit modules list +
            # MODULES=most so initramfs-tools includes everything the PS5
            # actually needs at boot.
            mkdir -p /lib/modules
            ln -sfn "$CHROOT/lib/modules/$KVER" "/lib/modules/$KVER"

            cat > /etc/initramfs-tools/modules <<'INITMODS'
# USB host controllers (PS5 boot drive is on USB 3 — xhci is the must-have).
xhci_pci
xhci_hcd
ehci_pci
ehci_hcd
ohci_pci
ohci_hcd
# USB storage class + UAS (faster path).
usb_storage
uas
sd_mod
# Filesystems for root + EFI.
ext4
vfat
nls_iso8859-1
nls_cp437
# Common HID so a USB keyboard works at the initramfs shell if we drop there.
usbhid
hid_generic
INITMODS
            # Force MODULES=most (curated full driver set, no autodetect).
            sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

            mkinitramfs -k "$KVER" -o "$CHROOT/boot/efi/initrd.img"
            rm -f "/lib/modules/$KVER"
            rm -rf "$KSTAGE"

            echo "=== Batocera: patch configgen to bind HOTKEY combos on gamepad ==="
            # Upstream Batocera's libretroControllers.py only sets
            # input_enable_hotkey_btn — the hotkey "enable" button — and never
            # binds input_exit_emulator_btn / input_menu_toggle_btn /
            # input_save_state_btn / input_load_state_btn. The keyboard-side
            # bindings (escape = exit, f1 = menu) work fine but on a DualSense
            # there's no way out of a game without sshing in and pkill'ing
            # retroarch. Patch the function to also bind start/select/L1/R1.
            PYFILE="$CHROOT/usr/lib/python3.12/site-packages/configgen/generators/libretro/libretroControllers.py"
            if [ -f "$PYFILE" ]; then
                python3 - "$PYFILE" <<'PYPATCH'
import sys
p = sys.argv[1]
src = open(p).read()
old = "        retroconfig.save('input_enable_hotkey_btn', controllers[0].inputs['hotkey'].id)"
extra = '''
        # PS5: map HOTKEY combos to gamepad — upstream sets only the
        # enable button, leaving exit-emulator unbound on gamepad. Without
        # this, gamepad users can't exit a retroarch game without sshing
        # in and pkill'ing retroarch.
        for batocera_key, retroarch_key in [
            ('start', 'input_exit_emulator_btn'),
            ('select', 'input_menu_toggle_btn'),
            ('pageup', 'input_load_state_btn'),
            ('pagedown', 'input_save_state_btn'),
        ]:
            if batocera_key in controllers[0].inputs:
                retroconfig.save(retroarch_key, controllers[0].inputs[batocera_key].id)'''
if old in src and extra not in src:
    open(p, 'w').write(src.replace(old, old + extra))
    print('  patched libretroControllers.py')
else:
    print('  skipped (line not found or already patched)')
PYPATCH
            else
                echo "  WARN: $PYFILE missing — configgen patch skipped"
            fi

            echo "=== Batocera: fstab + users ==="
            # NOTE the FAT32 boot partition is mounted at /boot (not
            # /boot/efi like the other distros) because batocera-part —
            # which S11share uses to autodetect the SHARE partition by
            # 'partition next to /boot' — greps /proc/mounts for /boot.
            # If we mount at /boot/efi the SHARE auto-detection silently
            # fails and S11share falls back to a 256 MB tmpfs at
            # /userdata, which won't fit Steam / save data / anything.
            # PS5 loader reads bzImage / cmdline.txt from the FAT32
            # partition's root regardless of where Linux mounts it.
            mkdir -p "$CHROOT/boot"
            cat > "$CHROOT/etc/fstab" <<FSTAB
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL  /boot vfat defaults 0 1
LABEL=SHARE       /userdata ext4 defaults 0 2
FSTAB

            echo "=== Batocera: first-boot SHARE partition creator ==="
            # Batocera's design splits the disk into:
            #   sda1 = rootfs (this image, ~15 GB)
            #   sda2 = /boot FAT32
            #   sda3 = /userdata SHARE (everything user-facing — games,
            #           BIOS, Steam flatpak, screenshots, saves)
            # The image only ships sda1+sda2. On first boot, expand the
            # GPT backup header to the actual disk end (so parted/sgdisk
            # see the full free space) then carve sda3 = SHARE out of
            # the remainder. Self-disables after running.
            cat > "$CHROOT/usr/local/sbin/ps5-share-init" <<'PS5SHARE'
#!/bin/sh
# First-boot: create the SHARE partition + fs if missing, so /userdata
# is a real disk-backed mount (916 GB on a 1 TB drive) instead of the
# 256 MB tmpfs fallback in /etc/init.d/S11share.
set -e
ROOT_DEV=$(findmnt -no SOURCE /)
DISK=$(/usr/bin/batocera-part prefix "$ROOT_DEV")
SHARE_NUM=$(/usr/bin/batocera-part share_internal_num)
SHARE_DEV="${DISK}${SHARE_NUM}"
[ -b "$DISK" ] || exit 0
# already created on a previous boot?
if [ -b "$SHARE_DEV" ] && blkid -L SHARE >/dev/null 2>&1; then
    exit 0
fi
echo "ps5-share-init: extending GPT + creating $SHARE_DEV"
sgdisk -e "$DISK"
partprobe "$DISK"
sleep 1
sgdisk -n "$SHARE_NUM":0:0 -c "$SHARE_NUM":share -t "$SHARE_NUM":8300 "$DISK"
partprobe "$DISK"
sleep 1
mkfs.ext4 -L SHARE -F "$SHARE_DEV"
PS5SHARE
            chmod +x "$CHROOT/usr/local/sbin/ps5-share-init"
            # Hook into Batocera's init order: run BEFORE S11share so
            # S11share's batocera-part share_internal call finds the
            # partition we just created.
            cat > "$CHROOT/etc/init.d/S07ps5share" <<'INITSHARE'
#!/bin/sh
# First-boot SHARE partition creator — see /usr/local/sbin/ps5-share-init
case "$1" in
    start|"") /usr/local/sbin/ps5-share-init >> /tmp/ps5-share-init.log 2>&1 ;;
    stop|restart|reload|*) ;;
esac
INITSHARE
            chmod +x "$CHROOT/etc/init.d/S07ps5share"

            # First-boot defaults for /userdata/system/batocera.conf — set
            # display.empty=1 so every system (PSP, PS1, PS2, PS3, PS4,
            # Switch, etc) is visible in EmulationStation even before
            # ROMs are loaded. S12 runs after S11share has populated
            # /userdata. Idempotent: only sets a key if not already
            # present, so the user remains free to flip it back.
            cat > "$CHROOT/etc/init.d/S12ps5defaults" <<'INITDEF'
#!/bin/sh
case "$1" in
    start|"")
        CONF=/userdata/system/batocera.conf
        [ -f "$CONF" ] || exit 0
        grep -qE '^display\.empty=' "$CONF" || echo 'display.empty=1' >> "$CONF"
        ;;
esac
INITDEF
            chmod +x "$CHROOT/etc/init.d/S12ps5defaults"

            # Batocera ships root passwordless. Leave root usable (a lot of
            # Batocera scripts assume root) but ALSO add a ps5 user so the
            # release-page convention works.
            if ! grep -q "^ps5:" "$CHROOT/etc/passwd"; then
                echo "ps5:x:1000:1000:PS5:/home/ps5:/bin/sh" >> "$CHROOT/etc/passwd"
                echo "ps5:!::0:99999:7:::"                   >> "$CHROOT/etc/shadow"
                echo "ps5:x:1000:"                           >> "$CHROOT/etc/group"
                mkdir -p "$CHROOT/home/ps5"
                chroot "$CHROOT" /bin/sh -c "chown -R 1000:1000 /home/ps5" 2>/dev/null || true
            fi
            # Both root and ps5 get pw 'ps5' — Batocera's chpasswd is busybox.
            chroot "$CHROOT" /bin/sh -c "printf 'ps5\nps5\n' | passwd ps5 2>/dev/null; printf 'ps5\nps5\n' | passwd root 2>/dev/null" || true

            echo "=== Batocera: grow-rootfs first-boot service ==="
            mkdir -p "$CHROOT/usr/local/sbin" "$CHROOT/etc/systemd/system"
            cat > "$CHROOT/usr/local/sbin/grow-rootfs" <<'GROW'
#!/bin/sh
set -e
ROOT=$(findmnt -no SOURCE / || mount | awk '$3=="/"{print $1; exit}')
DISK=$(lsblk -no PKNAME "$ROOT" 2>/dev/null | head -1)
PARTNUM=$(echo "$ROOT" | grep -oE '[0-9]+$' || true)
[ -z "$DISK" ] || [ -z "$PARTNUM" ] && exit 0
growpart "/dev/$DISK" "$PARTNUM" || true
resize2fs "$ROOT" || true
GROW
            chmod +x "$CHROOT/usr/local/sbin/grow-rootfs"
            cat > "$CHROOT/etc/systemd/system/grow-rootfs.service" <<SVC
[Unit]
Description=Grow rootfs to fill disk (first boot)
ConditionPathExists=/usr/local/sbin/grow-rootfs
ConditionFirstBoot=yes
After=local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/grow-rootfs
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
SVC
            # Batocera switched to systemd in v33+. Try systemctl enable;
            # tolerate buildroot quirks where /etc/systemd/system layout
            # differs.
            mkdir -p "$CHROOT/etc/systemd/system/sysinit.target.wants"
            ln -sf ../grow-rootfs.service \
                "$CHROOT/etc/systemd/system/sysinit.target.wants/grow-rootfs.service"
            ;;
        artix*)
            # Artix Linux: Arch derivative without systemd. The project
            # ships ISOs (artix-base-{openrc,runit,dinit,s6}-…iso) but no
            # bootstrap tarball, so we extract the live airootfs squashfs
            # from the ISO and customize it in chroot. Pacman + Artix
            # repos already work inside the airootfs (it's a fully
            # functional rootfs the live env runs on).
            case "$DISTRO" in
                artix-runit) ARTIX_INIT="runit" ;;
                artix-openrc) ARTIX_INIT="openrc" ;;
            esac
            ARTIX_INIT="${ARTIX_INIT:-openrc}"
            # Artix only keeps a small window of dated ISO builds online; the
            # mirror prunes older ones, so hardcoding ARTIX_BUILD bitrots fast.
            # Scrape the mirror index for the newest matching ISO instead.
            if [ -z "${ARTIX_URL:-}" ]; then
                ARTIX_INDEX="https://mirror1.artixlinux.org/iso/"
                ARTIX_BUILD=$(wget -q -O - "$ARTIX_INDEX" \
                    | grep -oE "artix-base-${ARTIX_INIT}-[0-9]{8}-x86_64\.iso" \
                    | sort -u | tail -1 \
                    | grep -oE "[0-9]{8}")
                [ -n "$ARTIX_BUILD" ] || { echo "ERROR: no Artix $ARTIX_INIT ISO on mirror"; exit 1; }
                ARTIX_URL="${ARTIX_INDEX}artix-base-${ARTIX_INIT}-${ARTIX_BUILD}-x86_64.iso"
            else
                ARTIX_BUILD=$(echo "$ARTIX_URL" | grep -oE "[0-9]{8}")
            fi

            echo "=== Artix: locate / download $ARTIX_INIT build $ARTIX_BUILD ==="
            CACHED="/build/cache/artix-base-${ARTIX_INIT}-${ARTIX_BUILD}-x86_64.iso"
            # Validate cached ISO against the mirror's Content-Length. Without
            # this, a previous run that died mid-download (curl/wget killed,
            # disk full, etc) leaves a truncated file at $CACHED — the next
            # run sees it's non-zero, skips the download, and silently fails
            # later at unsquashfs / mount-loop. Re-download if short.
            if [ -s "$CACHED" ]; then
                EXPECTED=$(wget -q -S --spider "$ARTIX_URL" 2>&1 \
                    | awk 'tolower($1) == "content-length:" {print $2}' \
                    | tail -1 | tr -d '\r')
                ACTUAL=$(stat -c%s "$CACHED")
                if [ -n "$EXPECTED" ] && [ "$ACTUAL" -lt "$EXPECTED" ]; then
                    echo ">> Cached ISO is partial ($ACTUAL B < $EXPECTED B), discarding"
                    rm -f "$CACHED"
                fi
            fi
            if [ ! -s "$CACHED" ]; then
                echo ">> No cached ISO, downloading"
                wget --tries=3 -O "$CACHED.part" "$ARTIX_URL"
                mv "$CACHED.part" "$CACHED"
            fi
            echo ">> Using $CACHED ($(du -h "$CACHED" | cut -f1))"

            echo "=== Artix: mount ISO + locate airootfs.sfs ==="
            ARTIX_MNT=$(mktemp -d)
            mount -o ro,loop "$CACHED" "$ARTIX_MNT"
            # Artix ISOs put the airootfs squashfs under either
            # /arch/x86_64/airootfs.sfs (current) or /arch/boot/x86_64/
            # (older). Probe both.
            ARTIX_SFS=""
            for c in /arch/x86_64/airootfs.sfs /arch/boot/x86_64/airootfs.sfs /LiveOS/rootfs.img /LiveOS/squashfs.img; do
                [ -f "$ARTIX_MNT$c" ] && ARTIX_SFS="$ARTIX_MNT$c" && break
            done
            if [ -z "$ARTIX_SFS" ]; then
                echo "ERROR: airootfs squashfs not found in Artix ISO:"
                find "$ARTIX_MNT" -maxdepth 4 -name '*.sfs' -o -name '*.img' | head -20
                exit 1
            fi

            echo "=== Artix: unsquashfs $ARTIX_SFS -> $CHROOT ==="
            unsquashfs -f -d "$CHROOT" "$ARTIX_SFS"

            umount "$ARTIX_MNT"
            rmdir "$ARTIX_MNT"

            echo "=== Artix: strip live-iso scaffolding ==="
            # Live ISOs ship calamares + archiso/artools install scripts
            # we don't want on a flashed root. They're harmless if left,
            # but bloat the image and may auto-start on TTY1.
            rm -rf "$CHROOT/etc/skel/Desktop" \
                   "$CHROOT/etc/calamares" \
                   "$CHROOT/etc/runlevels"/*/calamares* 2>/dev/null || true
            # The live ISO autostarts a "live" user shell on tty1. Disable.
            rm -f "$CHROOT/etc/runit/runsvdir/default/agetty-autologin-tty1" \
                  "$CHROOT/etc/runlevels/default/agetty-autologin-tty1" \
                  "$CHROOT/etc/init.d/agetty-autologin-tty1" 2>/dev/null || true
            # Remove the `artix` live user entries if present (lives in
            # /etc/passwd of the airootfs).
            if [ -f "$CHROOT/etc/passwd" ]; then
                sed -i '/^artix:/d;/^live:/d' "$CHROOT/etc/passwd" "$CHROOT/etc/shadow" "$CHROOT/etc/group" 2>/dev/null || true
            fi

            echo "=== Artix: stage linux-ps5 + grow-rootfs ==="
            mkdir -p "$CHROOT/var/cache/ps5-pkgs"
            cp "$STAGING/pkgs/"*.pkg.tar.zst "$CHROOT/var/cache/ps5-pkgs/"
            install -Dm755 "$STAGING/grow-rootfs"        "$CHROOT/usr/local/sbin/grow-rootfs"
            case "$ARTIX_INIT" in
                runit)
                    install -Dm755 "$STAGING/grow-rootfs.runit" \
                        "$CHROOT/etc/runit/1.d/grow-rootfs"
                    ;;
                *)
                    install -Dm755 "$STAGING/grow-rootfs.openrc" \
                        "$CHROOT/etc/init.d/grow-rootfs"
                    ;;
            esac
            # Pre-provisioned wifi (test builds only — strip before push).
            # NM requires mode 0600 on keyfiles; anything looser is silently
            # ignored.
            if [ -f /repo/distros/artix-openrc/wifi.nmconnection ]; then
                install -Dm600 /repo/distros/artix-openrc/wifi.nmconnection \
                    "$CHROOT/etc/NetworkManager/system-connections/wifi.nmconnection"
            fi

            echo "=== Artix: enter chroot for pacman + service setup ==="
            cleanup_artix_mounts() {
                for m in dev sys proc; do
                    mountpoint -q "$CHROOT/$m" && umount "$CHROOT/$m" || true
                done
            }
            trap cleanup_artix_mounts RETURN ERR EXIT
            mount --bind /proc "$CHROOT/proc"
            mount --bind /sys  "$CHROOT/sys"
            mount --bind /dev  "$CHROOT/dev"
            rm -f "$CHROOT/etc/resolv.conf"
            cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

            chroot "$CHROOT" env ARTIX_INIT="$ARTIX_INIT" /bin/bash -e <<'ARTIX_IN'
                # Pacman 7 Landlock sandbox is unsupported under QEMU/docker.
                sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf 2>/dev/null || true

                # The live ISO's pacman config has [system] [world] [galaxy]
                # already wired; make sure keyrings are populated for fresh
                # installs from those repos.
                pacman-key --init
                pacman-key --populate artixlinux 2>/dev/null || pacman-key --populate artix 2>/dev/null || true
                # Refresh package DBs against current mirrors.
                pacman -Syy --noconfirm

                # Desktop: sway (Wayland tiling WM) + greetd autologin.
                # No X server — xwayland alone handles legacy X11 clients.
                # Per-init suffix for the Artix service-glue subpackages
                # (NetworkManager-openrc vs -runit, etc.).
                SFX="$ARTIX_INIT"
                pacman -S --noconfirm --needed --overwrite '*' \
                    sway swaybg swayidle swaylock waybar foot wofi \
                    xdg-desktop-portal-wlr xorg-xwayland \
                    greetd \
                    mesa vulkan-radeon libva-mesa-driver \
                    libinput xkeyboard-config \
                    pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils \
                    networkmanager networkmanager-$SFX network-manager-applet \
                    elogind-$SFX \
                    openssh openssh-$SFX \
                    sudo bash nano vim htop wget curl git base-devel \
                    e2fsprogs parted gptfdisk \
                    polkit dbus dbus-$SFX seatd \
                    kexec-tools kmod \
                    ttf-dejavu ttf-liberation noto-fonts noto-fonts-cjk noto-fonts-emoji fontconfig \
                    linux-firmware \
                    || true

                # The live ISO ships the mainline `linux` kernel + headers
                # pre-installed; linux-ps5 conflicts with both at the
                # package level. Force-remove with -Rdd (skip dependency
                # checks; nothing depending on /boot/vmlinuz-linux can run
                # on PS5 hardware anyway). Ignore failure if either is
                # already gone on older ISO snapshots.
                pacman -Rdd --noconfirm linux linux-headers linux-api-headers 2>/dev/null || true

                # Install our patched kernel + modules.
                pacman -U --noconfirm --overwrite '*' /var/cache/ps5-pkgs/*.pkg.tar.zst
                rm -rf /var/cache/ps5-pkgs

                # Pre-configure repo.etawen.dev so users can `pacman -Syu`
                # for kernel updates after first boot.
                curl -fsSL https://repo.etawen.dev/key.asc | pacman-key --add - 2>/dev/null || true
                pacman-key --lsign-key E40FB2409C9AD5243762294293AB12C4159FEDAB 2>/dev/null || true
                if ! grep -q "^\[ps5\]" /etc/pacman.conf; then
                    cat >> /etc/pacman.conf <<ETAWEN

[ps5]
SigLevel = Required DatabaseRequired
Server = https://repo.etawen.dev/arch
ETAWEN
                fi

                # mkinitcpio: drop autodetect so the initramfs covers the
                # PS5's hardware, not the build host's (matches the arch
                # path's recipe).
                sed -i 's/ autodetect//' /etc/mkinitcpio.conf
                KVER=$(ls -1t /lib/modules | head -1)
                mkinitcpio -k "$KVER" -g "/boot/initramfs-${KVER}.img" || true
                mkdir -p /boot/efi
                cp "/boot/vmlinuz-$KVER"            /boot/efi/bzImage
                cp "/boot/initramfs-${KVER}.img"    /boot/efi/initrd.img

                # SSH
                sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'               /etc/ssh/sshd_config
                sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

                # Service wiring — branch by init system.
                if [ "$ARTIX_INIT" = "runit" ]; then
                    # Runit: each -runit subpackage drops /etc/runit/sv/<svc>/.
                    # Activate by symlinking into the default runsvdir.
                    mkdir -p /etc/runit/runsvdir/default
                    for svc in dbus elogind seatd NetworkManager sshd greetd; do
                        [ -d "/etc/runit/sv/$svc" ] && \
                            ln -sfn "/etc/runit/sv/$svc" "/etc/runit/runsvdir/default/$svc"
                    done
                    # grow-rootfs is a one-shot stage-1 hook (installed by host
                    # at /etc/runit/1.d/grow-rootfs) — no symlink needed.
                else
                    # OpenRC: -openrc subpackages drop /etc/init.d/<svc>; plug into runlevels.
                    rc-update add dbus default        || true
                    rc-update add elogind boot        || true
                    rc-update add seatd default       || true
                    rc-update add NetworkManager default || true
                    rc-update add sshd default        || true
                    rc-update add greetd default      || true
                    rc-update add grow-rootfs default || true
                fi

                # Default user (ps5 / ps5). plugdev is a Debian-ism not
                # pre-created on Artix — the udev removable-device rules
                # there target the `uucp`/`input` groups instead, so skip
                # the missing group rather than fight it.
                if ! id ps5 >/dev/null 2>&1; then
                    useradd -m -s /bin/bash -G wheel,video,audio,input,seat ps5
                fi
                echo "ps5:ps5" | chpasswd
                passwd -l root
                echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel

                # greetd: autologin ps5 -> exec sway. Single Wayland session,
                # no display manager UI.
                mkdir -p /etc/greetd
                cat > /etc/greetd/config.toml <<GREETD
[terminal]
vt = 1

[default_session]
command = "sway"
user = "ps5"
GREETD

                # amdgpu options — PS5 Oberon GPU needs dpm disabled.
                mkdir -p /etc/modprobe.d
                cat > /etc/modprobe.d/ps5-amdgpu.conf <<AMDGPU
options amdgpu dpm=0 gpu_recovery=0
AMDGPU

                # Hold linux-ps5 against upstream replacement.
                sed -i '/^IgnorePkg/d' /etc/pacman.conf
                sed -i '/^\[options\]/a IgnorePkg = linux-ps5' /etc/pacman.conf

                # vconsole.conf needed by mkinitcpio sd-vconsole hook.
                [ -f /etc/vconsole.conf ] || echo "KEYMAP=us" > /etc/vconsole.conf
ARTIX_IN
            cleanup_artix_mounts
            trap - RETURN ERR EXIT
            ;;
        bazzite*)
            # Bazzite is an OCI atomic image; bypass distrobuilder entirely.
            # DISTRO=bazzite      -> ghcr.io/ublue-os/bazzite:stable
            # DISTRO=bazzite-deck -> ghcr.io/ublue-os/bazzite-deck:stable
            # Anything else after `bazzite-` is treated as the same uBlue
            # image-name pattern (bazzite-gnome, bazzite-nvidia, ...).
            case "$DISTRO" in
                bazzite)      REF="ghcr.io/ublue-os/bazzite:stable" ;;
                bazzite-*)    REF="ghcr.io/ublue-os/${DISTRO}:stable" ;;
                *)            REF="ghcr.io/ublue-os/bazzite:stable" ;;
            esac
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

            # Force NetworkManager off iwd back to wpa_supplicant. Bazzite
            # defaults to iwd; iwd's compat with the PS5 NXP IW620 mwifiex
            # driver is broken (no SSIDs scanned, NM hangs). wpa_supplicant
            # works out of the box.
            mkdir -p "$CHROOT/etc/NetworkManager/conf.d"
            cat > "$CHROOT/etc/NetworkManager/conf.d/00-no-iwd.conf" <<'NMCONF'
[device]
wifi.backend=wpa_supplicant
NMCONF
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
                # Drop the embedded ostree object store + deploy tree. With
                # rpm-ostree masked, the running rootfs is the flat OCI
                # extract — /sysroot/ostree/repo/objects/ is a deduplicated
                # second copy of the same content (~5GB+), and /ostree/
                # deploy/ holds yet another. Wiping them shrinks the disk
                # image roughly in half. Leave the dir skeleton in case
                # anything probes for it.
                rm -rf /sysroot/ostree/repo/objects \
                       /sysroot/ostree/repo/refs \
                       /sysroot/ostree/deploy
                mkdir -p /sysroot/ostree/repo/objects \
                         /sysroot/ostree/repo/refs/heads
                # Bazzite/rpm-ostree convention: /root is a symlink to
                # /var/roothome which doesn't exist in the OCI extract.
                # dracut's hostonly enumeration follows the symlink, hits
                # ENOENT, fails with `dracut-install: ERROR: installing '/root'`.
                # Make /root a real dir so dracut + the kernel postinst's own
                # dracut call both work.
                mkdir -p /var/roothome
                if [ -L /root ]; then
                    rm -f /root
                    mkdir -m 0700 /root
                fi
                # Install PS5 kernel via rpm --replacefiles (handles the file-
                # level conflict between our /usr/include/* headers and
                # Bazzite's kernel-headers; see fedora image.yaml comment).
                # Bazzite ships kernel modules as a dir; our rpm wants a symlink.
                rm -rf /lib/modules/*
                rpm -Uvh --replacefiles --replacepkgs --nodeps /var/cache/ps5-rpms/*.rpm
                rm -rf /var/cache/ps5-rpms

                # cyan_skillfish (PS5 Oberon) GPU firmware MUST land in the
                # rootfs uncompressed. The linux-ps5 amdgpu patches write into
                # the request_firmware() buffer to skip Sony's signature header
                # (gfx_v10_0_early_init + amdgpu_sdma_init_microcode). Firmware
                # loaded from a .xz file is decompressed into pages the kernel
                # maps PAGE_KERNEL_RO (fw_decompress_xz_pages -> fw_map_paged_buf
                # -> vmap PAGE_KERNEL_RO), so the write oopses amdgpu at
                # gfx_v10_0_early_init+0x415 and /dev/dri never appears.
                # Distros that ship .zst (arch) or raw .bin (debian) decompress
                # into writable buffers and are unaffected — this fix is for
                # the rpm path only. linux-firmware dedupes blobs as symlinks
                # (mec2 -> mec) and unxz refuses symlinks, so materialize the
                # link targets first while the canonical .xz still exists.
                # Upstream did this same fix in
                # github.com/ps5-linux/ps5-linux-image@ed54e99 — same kernel
                # patches, same firmware, same failure mode.
                cd /usr/lib/firmware/amdgpu
                for f in cyan_skillfish*.xz; do
                    if [ -L "$f" ]; then
                        tgt=$(readlink -f "$f")
                        rm "$f"
                        xz -dc "$tgt" > "${f%.xz}"
                    fi
                done
                unxz cyan_skillfish*.xz
                cd /

                # Pre-configure repo.etawen.dev so users can
                # `dnf upgrade linux-ps5` after first boot. Per-package
                # gpgcheck=0 (alien-converted RPMs aren't per-package
                # signed); repodata IS signed by the mia PGP key.
                cat > /etc/yum.repos.d/etawen-ps5.repo <<ETAWEN
[etawen-ps5]
name=Etawen PS5 kernel repo
baseurl=https://repo.etawen.dev/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=https://repo.etawen.dev/key.asc
ETAWEN
                # amdgpu options — PS5 Oberon GPU needs dpm disabled or HDMI
                # stays dark. Must land in initramfs (amdgpu loads early).
                mkdir -p /etc/modprobe.d
                cat > /etc/modprobe.d/ps5-amdgpu.conf <<AMDGPU
options amdgpu dpm=0 gpu_recovery=0
AMDGPU
                # Build the initrd, then deploy bzImage+initrd to /boot/efi/
                # for the PS5 kexec loader. (zz-update-boot is the deb-flow
                # helper; bazzite never stages it, so we inline the copies.)
                KVER=$(ls -1t /lib/modules | head -1)
                dracut -f --kver "$KVER" "/boot/initrd.img-$KVER"
                mkdir -p /boot/efi
                cp "/boot/vmlinuz-$KVER" /boot/efi/bzImage
                cp "/boot/initrd.img-$KVER" /boot/efi/initrd.img

                # Suppress first-boot wizards. plasma-setup.service runs on every
                # boot until /etc/plasma-setup-done exists, and its bootutil
                # rewrites SDDM autologin to User=plasma-setup (clobbering our
                # User=ps5) and starts the Plasma OOBE wizard, which prompts the
                # user to create a fresh account. Our build pre-creates ps5; the
                # wizard is unwanted.
                touch /etc/plasma-setup-done
                systemctl mask plasma-setup.service 2>/dev/null || true

                # bazzite-hardware-setup.service runs on every boot until the
                # marker files in /etc/bazzite/ match the image-info.json. Seed
                # them so the script exits at its early-return; also mask it
                # outright since the script calls `rpm-ostree kargs` which fails
                # against our masked rpm-ostreed. The script's other work
                # (zram, IOMMU karg, hw-specific kargs) isn't applicable on PS5
                # anyway — we set our own cmdline in /boot/efi/cmdline.txt.
                mkdir -p /etc/bazzite
                jq -r '."image-name"'     < /usr/share/ublue-os/image-info.json > /etc/bazzite/image_name
                jq -r '."image-branch"'   < /usr/share/ublue-os/image-info.json > /etc/bazzite/image_branch
                jq -r '."fedora-version"' < /usr/share/ublue-os/image-info.json > /etc/bazzite/fedora_version
                grep -oP '^HWS_VER=\K[0-9]+' /usr/libexec/bazzite-hardware-setup > /etc/bazzite/hws_version
                systemctl mask bazzite-hardware-setup.service 2>/dev/null || true

                # User setup. Bazzite exposes video/audio/input/render via
                # systemd-userdbd, so `getent group video` returns a row —
                # and `groupadd -f` short-circuits as "already exists" and
                # does nothing. But useradd reads /etc/group directly (no
                # NSS), sees an empty file, and bails with "group X does not
                # exist". Materialize each group into /etc/group ourselves,
                # preserving the NSS-assigned GID when there is one so
                # existing file ownerships in the rootfs stay correct.
                passwd -l root
                # Ensure /etc/gshadow exists with the right perms; useradd
                # refuses to "prepare new entry" silently if it's missing.
                [ -e /etc/gshadow ] || { touch /etc/gshadow; chmod 0 /etc/gshadow; }
                for g in wheel video audio input render; do
                    if ! grep -q "^${g}:" /etc/group; then
                        gid=$(getent group "$g" 2>/dev/null | cut -d: -f3 || true)
                        if [ -z "$gid" ]; then
                            # Pick the next free system gid (100-999).
                            gid=$(awk -F: 'BEGIN{m=100} $3>=100 && $3<1000 && $3>m {m=$3} END{print m+1}' /etc/group)
                        fi
                        echo "${g}:x:${gid}:" >> /etc/group
                    fi
                    # Always make sure /etc/gshadow has a row.
                    grep -q "^${g}:" /etc/gshadow || echo "${g}:!::" >> /etc/gshadow
                done
                if ! id ps5 >/dev/null 2>&1; then
                    useradd -m -s /bin/bash -G wheel,video,audio,input,render ps5
                fi
                echo "ps5:ps5" | chpasswd
                sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

                # Install pieces Bazzite's slim OCI image is missing.
                #   cloud-utils-growpart + parted: grow-rootfs needs growpart
                #     and partprobe — without them the rootfs stays sized to
                #     the build image (~10GB) on whatever USB it lands on.
                #   plasma-systemmonitor + ksystemstats: standard Plasma
                #     "System Monitor" app. Bazzite's container drops it.
                #   kdiff3 / gwenview / ark / okular / spectacle: rest of
                #     the Plasma utilities most people expect.
                #   chrony: NTP. PS5's RTC is wrong on boot; without an NTP
                #     client the system clock is years off and TLS breaks.
                dnf install -y --setopt=install_weak_deps=False \
                    cloud-utils-growpart parted \
                    plasma-systemmonitor ksystemstats \
                    kdiff3 gwenview ark okular spectacle \
                    chrony \
                    || echo "WARN: dnf install failed; some pkgs may be missing"

                # Services
                systemctl enable grow-rootfs.service NetworkManager sshd 2>/dev/null || true
                # Time sync. Prefer systemd-timesyncd if present (lighter);
                # fall back to chrony (which we just dnf-installed).
                systemctl enable systemd-timesyncd 2>/dev/null \
                    || systemctl enable chronyd 2>/dev/null || true
                # Virtual terminals. Bazzite's preset disables getty@tty2-6;
                # explicitly enable them so Ctrl+Alt+F2..F6 give text consoles.
                for n in 2 3 4 5 6; do
                    systemctl enable getty@tty${n}.service 2>/dev/null || true
                done
                # Default DM (Bazzite ships KDE Plasma + SDDM)
                systemctl enable sddm 2>/dev/null || systemctl enable gdm 2>/dev/null || true
                # resolv.conf -> systemd-resolved stub
                rm -f /etc/resolv.conf
                ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                # Steam Deck UI's "Switch to Desktop" button calls SteamOS-
                # Manager's SetTemporarySession(s) dbus method, which writes
                # Session=<bare-alias> (literally "desktop"/"gamescope") into
                # /etc/sddm.conf.d/zzt-steamos-temp-login.conf. That conf
                # sorts AFTER zz-steamos-autologin.conf so it wins precedence
                # at autologin time — but SDDM has no `desktop.desktop`
                # session to resolve the alias to, so the button silently
                # no-ops and the user stays on gamescope. (The bash
                # steamos-session-select tool works fine because it resolves
                # aliases itself before writing — only the dbus path is
                # broken.) Fix it with alias symlinks SDDM can follow.
                for cand in plasma-steamos-wayland-oneshot.desktop \
                            gnome-wayland-oneshot.desktop plasma.desktop; do
                    if [ -e "/usr/share/wayland-sessions/$cand" ]; then
                        ln -sf "$cand" /usr/share/wayland-sessions/desktop.desktop
                        break
                    fi
                done
                for cand in gamescope-session.desktop gamescope-session-plus.desktop; do
                    if [ -e "/usr/share/wayland-sessions/$cand" ]; then
                        ln -sf "$cand" /usr/share/wayland-sessions/gamescope.desktop
                        break
                    fi
                done
                # Autologin straight into Bazzite's gamescope session (Steam
                # Big-Picture / Deck UI) — Bazzite is gaming-focused, and a
                # field report said it landed on the Plasma desktop instead
                # of gamemode. Pick whichever gamescope session file exists,
                # fall back to plasma if Bazzite stripped them.
                mkdir -p /etc/sddm.conf.d
                SESSION=plasma
                for s in gamescope-session-plus.desktop gamescope-session.desktop steam-wayland.desktop; do
                    if [ -e "/usr/share/wayland-sessions/$s" ] || [ -e "/usr/share/xsessions/$s" ]; then
                        SESSION="${s%.desktop}"
                        break
                    fi
                done
                cat > /etc/sddm.conf.d/autologin.conf <<SDDM
[Autologin]
User=ps5
Session=$SESSION
SDDM

                # Gamescope-session fallback. Field report: bazzite-deck boots
                # to a black screen on PS5 because gamescope can't grab the
                # display (PSP/TA + Salina HDMI bridge weirdness — workaround
                # is `steamos-session-select plasma` from a VT). Automate it:
                # first-boot oneshot waits 60s for a gamescope process; if
                # nothing shows up, flip the session to plasma and bounce
                # SDDM. Only arm this when the chosen session is gamescope-
                # flavoured. After first boot the user owns session choice
                # via the standard steamos-session-select tool + the desktop
                # shortcut we drop below.
                case "$SESSION" in gamescope*|steam-wayland*)
                    mkdir -p /usr/local/sbin /etc/systemd/system/graphical.target.wants
                    cat > /usr/local/sbin/ps5-gamescope-recovery <<'POKE'
#!/bin/bash
# Wait up to 60s for gamescope to actually grab a display. If it doesn't,
# the user is staring at a black screen — fall back to plasma and bounce
# the display manager so they get a usable login session.
for _ in $(seq 1 60); do
    sleep 1
    pgrep -x gamescope >/dev/null 2>&1 && exit 0
done
logger -t ps5-gamescope-recovery "gamescope didn't start within 60s, switching to plasma"
runuser -u ps5 -- steamos-session-select plasma 2>/dev/null \
    || sed -i 's/^Session=.*/Session=plasma/' /etc/sddm.conf.d/autologin.conf
systemctl restart sddm
POKE
                    chmod +x /usr/local/sbin/ps5-gamescope-recovery
                    cat > /etc/systemd/system/ps5-gamescope-recovery.service <<RECOV
[Unit]
Description=Fall back to plasma if gamescope can't grab a display (first boot)
After=graphical.target
ConditionFirstBoot=yes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-gamescope-recovery
RemainAfterExit=no

[Install]
WantedBy=graphical.target
RECOV
                    ln -sf ../ps5-gamescope-recovery.service \
                        /etc/systemd/system/graphical.target.wants/ps5-gamescope-recovery.service

                    # Desktop shortcut so the user can opt back into gamescope
                    # after a recovery (or after switching to plasma manually).
                    mkdir -p /home/ps5/Desktop
                    cat > /home/ps5/Desktop/Switch-to-Gamescope.desktop <<DESK
[Desktop Entry]
Version=1.0
Type=Application
Name=Switch to Gamescope (Big Picture)
Comment=Switch the autologin session back to gamescope / Steam Deck UI
Exec=bash -c 'steamos-session-select gamescope && systemctl restart sddm'
Icon=steam
Terminal=false
Categories=System;
DESK
                    chmod +x /home/ps5/Desktop/Switch-to-Gamescope.desktop
                    chown -R ps5:ps5 /home/ps5/Desktop 2>/dev/null || \
                        chown -R 1000:1000 /home/ps5/Desktop
                    ;;
                esac

                # DTM TA race workaround. amdgpu's display-topology TA
                # (Trusted Application) loads async via PSP; if DRM probes
                # connectors before that finishes, you get
                #   [drm] Failed to add display topology, DTM TA is not initialized
                # and the screen stays dark until the user manually toggles
                # VT (ctrl+alt+F7 -> ctrl+alt+F1) which forces a re-probe.
                # Mimic that automatically: after amdgpu binds, wait a beat
                # then re-trigger DRM connector detection.
                mkdir -p /usr/local/sbin /etc/udev/rules.d
                cat > /usr/local/sbin/ps5-amdgpu-reprobe <<'POKE'
#!/bin/sh
# Wait for PSP/TA firmware to settle, then re-probe DRM connectors.
# Equivalent of the ctrl+alt+F7 / ctrl+alt+F1 dance.
(
    sleep 3
    for c in /sys/class/drm/card*-*/status; do
        [ -w "$c" ] && echo detect > "$c"
    done
) &
POKE
                chmod +x /usr/local/sbin/ps5-amdgpu-reprobe
                cat > /etc/udev/rules.d/70-ps5-amdgpu-reprobe.rules <<'UDEV'
# Re-trigger DRM hotplug after amdgpu binds, so the DTM TA-not-initialized
# race doesn't leave the user with a dark screen until they manually VT-cycle.
SUBSYSTEM=="drm", ACTION=="add", KERNEL=="card[0-9]*", RUN+="/usr/local/sbin/ps5-amdgpu-reprobe"
UDEV
BAZIN
            # explicit cleanup (the trap covers the failure path)
            cleanup_bazzite_mounts
            trap - RETURN ERR EXIT
            ;;
        steamos)
            # SteamOS — image-swap based on Valve's Steam Deck recovery
            # image. Same pattern as batocera: download upstream image,
            # extract its rootfs to $CHROOT, swap in linux-ps5 kernel.
            STEAMOS_URL="${STEAMOS_URL:-https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2}"
            echo "=== SteamOS: resolve latest image URL ==="
            RESOLVED_URL=$(curl -sIL -o /dev/null -w '%{url_effective}' "$STEAMOS_URL")
            IMG_NAME=$(basename "$RESOLVED_URL")
            echo ">> resolved $IMG_NAME"

            CACHED="/build/cache/$IMG_NAME"
            if [ ! -s "$CACHED" ]; then
                echo ">> downloading $IMG_NAME (~3.4 GB from Valve CDN)"
                wget --tries=3 -O "$CACHED.part" "$RESOLVED_URL"
                mv "$CACHED.part" "$CACHED"
            fi
            echo ">> using $CACHED ($(du -h "$CACHED" | cut -f1))"

            echo "=== SteamOS: decompress + loop ==="
            STEAMOS_IMG=/build/steamos-src.img
            bunzip2 -kc "$CACHED" > "$STEAMOS_IMG"
            SLOOP=$(losetup -Pf --show "$STEAMOS_IMG")
            sleep 1
            # kpartx fallback when loopNpX devices didn't appear under /dev/
            if [ ! -e "${SLOOP}p1" ]; then
                kpartx -av "$SLOOP"
                sleep 1
            fi
            # Build candidate partition list — either /dev/loopNpX or
            # /dev/mapper/loopNpX depending on how kpartx mapped them.
            SLOOP_BASE=$(basename "$SLOOP")
            PART_PATHS=()
            for cand in "${SLOOP}"p* "/dev/mapper/${SLOOP_BASE}"p*; do
                [ -e "$cand" ] && PART_PATHS+=("$cand")
            done

            # The RECOVERY image uses btrfs for the rootfs (production
            # SteamOS uses erofs A/B; recovery needs writes so it's btrfs).
            # Take the first btrfs partition; that's rootfs. Fall back to
            # erofs in case Valve ever changes it.
            SROOT=""
            SROOT_FS=""
            for fstype in btrfs erofs; do
                for p in "${PART_PATHS[@]}"; do
                    t=$(blkid -o value -s TYPE "$p" 2>/dev/null || echo "")
                    if [ "$t" = "$fstype" ]; then
                        SROOT="$p"; SROOT_FS="$fstype"; break 2
                    fi
                done
            done
            if [ -z "$SROOT" ]; then
                echo "ERROR: no btrfs/erofs rootfs in SteamOS image. partitions seen:"
                for p in "${PART_PATHS[@]}"; do
                    echo "  $p  type=$(blkid -o value -s TYPE "$p" 2>/dev/null) size=$(blockdev --getsize64 "$p" 2>/dev/null)"
                done
                exit 1
            fi
            echo ">> rootfs slot: $SROOT ($SROOT_FS)"

            SMNT=$(mktemp -d)
            mount -t "$SROOT_FS" -o ro "$SROOT" "$SMNT"

            # If btrfs, look for SteamOS's @rootfs subvolume — the top-level
            # btrfs view may be empty / hold only subvol entries, in which
            # case we need to remount with subvol=@rootfs (or @, depending
            # on the image's layout).
            if [ "$SROOT_FS" = "btrfs" ] && [ ! -d "$SMNT/usr" ]; then
                echo ">> top-level btrfs has no /usr; scanning subvolumes"
                btrfs subvolume list "$SMNT" 2>&1 | head -20 || true
                umount "$SMNT"
                for sub in @rootfs @ rootfs root; do
                    if mount -t btrfs -o "ro,subvol=$sub" "$SROOT" "$SMNT" 2>/dev/null; then
                        if [ -d "$SMNT/usr" ]; then
                            echo ">> rootfs at subvol=$sub"
                            break
                        fi
                        umount "$SMNT"
                    fi
                done
                if [ ! -d "$SMNT/usr" ]; then
                    echo "ERROR: couldn't locate rootfs in btrfs at any known subvol"
                    exit 1
                fi
            fi
            echo "=== SteamOS: copy rootfs ($(du -sh "$SMNT" | cut -f1)) -> \$CHROOT ==="
            cp -a "$SMNT"/. "$CHROOT/"
            umount "$SMNT"
            rmdir "$SMNT"

            # SteamOS splits /var off the rootfs onto its own partition.
            # First-boot fails without /var/lib/dbus etc.
            VARMNT=$(mktemp -d)
            for p in "${PART_PATHS[@]}"; do
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

            kpartx -dv "$SLOOP" 2>/dev/null || true
            losetup -d "$SLOOP"
            rm -f "$STEAMOS_IMG"

            echo "=== SteamOS: install linux-ps5 kernel pkg ==="
            PKG=$(ls "$STAGING"/pkgs/linux-ps5-*.pkg.tar.zst 2>/dev/null | head -1)
            [ -z "$PKG" ] && { echo "ERROR: no linux-ps5 pkg.tar.zst staged"; exit 1; }
            TMP=$(mktemp -d)
            bsdtar -xf "$PKG" -C "$TMP"
            for d in usr boot etc; do
                [ -d "$TMP/$d" ] && cp -a "$TMP/$d"/. "$CHROOT/$d/" 2>/dev/null || true
            done
            rm -rf "$TMP"

            # KVER from the pkg layout
            KVER=$(ls -1 "$CHROOT/usr/lib/modules" 2>/dev/null \
                | grep -v "$(ls -1 "$CHROOT/usr/lib/modules" 2>/dev/null \
                             | grep -E 'neptune|^[0-9]+\.[0-9]+\.[0-9]+-[^-]+$' \
                             | grep -v 'ps5' || true)" | head -1)
            [ -z "$KVER" ] && KVER=$(ls -1 "$CHROOT/usr/lib/modules" 2>/dev/null | grep ps5 | head -1)
            [ -z "$KVER" ] && KVER=$(ls -1 "$CHROOT/usr/lib/modules" 2>/dev/null | head -1)
            echo ">> KVER=$KVER"

            # Drop SteamOS's own kernel(s) so grub boots ours
            rm -f "$CHROOT"/boot/vmlinuz-linux* "$CHROOT"/boot/initrd*-neptune* \
                  "$CHROOT"/boot/initramfs-linux*.img 2>/dev/null || true
            for d in "$CHROOT"/usr/lib/modules/*; do
                [ -d "$d" ] || continue
                [ "$(basename "$d")" = "$KVER" ] && continue
                rm -rf "$d"
            done

            if [ -x "$CHROOT/usr/bin/depmod" ]; then
                chroot "$CHROOT" /usr/bin/depmod -a "$KVER" || true
            else
                depmod -b "$CHROOT" "$KVER" || true
            fi

            [ -f "$CHROOT/boot/vmlinuz-$KVER" ] || \
                cp "$CHROOT"/boot/vmlinuz-* "$CHROOT/boot/vmlinuz-$KVER" 2>/dev/null || true
            mkdir -p "$CHROOT/boot/efi"
            cp "$CHROOT/boot/vmlinuz-$KVER" "$CHROOT/boot/efi/bzImage" 2>/dev/null || true

            # Symlink chroot's modules into host /lib/modules so the build
            # container's mkinitramfs/depmod can see them. PS5 kernel pkg
            # installs modules under /usr/lib/modules.
            echo "=== SteamOS: build initrd via host mkinitramfs ==="
            mkdir -p /lib/modules
            ln -sfn "$CHROOT/usr/lib/modules/$KVER" "/lib/modules/$KVER"

            cat > /etc/initramfs-tools/modules <<'INITMODS'
# USB host controllers (PS5 boot drive is USB 3 — xhci must be present).
xhci_pci
xhci_hcd
ehci_pci
ehci_hcd
ohci_pci
ohci_hcd
# Storage
usb-storage
uas
# Filesystems we may root on
ext4
btrfs
vfat
# Block stack
sd_mod
loop
dm_mod
# AMD GPU + display for early framebuffer
amdgpu
INITMODS

            # Force MODULES=most so we include everything for the PS5
            # regardless of what's loaded in the build container.
            sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

            # amdgpu options for the PS5 Oberon GPU: dpm=0 keeps HDMI alive
            # (DPM transitions stall the DP→HDMI bridge into a stuck-low
            # state, displayed as a black screen the moment KWin tries to
            # take DRM master from gamescope — exact symptom: 'failed to
            # display topology' in Plasma + black screen with cursor after
            # Switch-to-Desktop). gpu_recovery=0 avoids the linux-ps5
            # patched recovery path that hard-faults on Oberon. Bazzite
            # already ships these for the same reason.
            #
            # Land in both initramfs and rootfs so amdgpu picks them up at
            # both probe times (early initramfs phase + post-switch_root).
            mkdir -p "$CHROOT/etc/modprobe.d" /etc/modprobe.d
            cat > "$CHROOT/etc/modprobe.d/ps5-amdgpu.conf" <<'AMDGPU'
options amdgpu dpm=0 gpu_recovery=0
AMDGPU
            cp "$CHROOT/etc/modprobe.d/ps5-amdgpu.conf" /etc/modprobe.d/ps5-amdgpu.conf

            mkinitramfs -k "$KVER" -o "$CHROOT/boot/efi/initrd.img"
            # Also drop a copy at the standard location inside the rootfs.
            cp "$CHROOT/boot/efi/initrd.img" "$CHROOT/boot/initramfs-$KVER.img"

            rm -f "/lib/modules/$KVER"

            # SteamOS recovery image ships without a default.target symlink and
            # relies on the cmdline to set systemd.unit=. Without either,
            # systemd hangs at "solid cursor on tty1" forever. Fix both so
            # either path reaches graphical.target.
            ln -sf /usr/lib/systemd/system/graphical.target "$CHROOT/etc/systemd/system/default.target"

            # sshd: recovery image ships it disabled. We want it on by
            # default so we can ssh in from the LAN without poking the
            # console. Enable + set deck's password to 'deck' (matches
            # the build-time convention used for the other distros).
            mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
            ln -sf /usr/lib/systemd/system/sshd.service \
                "$CHROOT/etc/systemd/system/multi-user.target.wants/sshd.service"
            chroot "$CHROOT" /usr/bin/bash -c 'echo "deck:deck" | chpasswd' 2>/dev/null || \
                chroot "$CHROOT" /bin/sh -c 'echo "deck:deck" | chpasswd' 2>/dev/null || true
            # also unlock the account in case it's locked
            chroot "$CHROOT" /usr/bin/passwd -u deck 2>/dev/null || true

            # Enable sddm. The recovery image ships sddm.service in
            # /usr/lib/systemd/system but NEVER symlinks it into
            # graphical.target.wants — relies on a first-boot Valve setup
            # script that we've cut out. Without this, graphical.target
            # is reached but no display manager starts → black screen
            # even with working GPU init.
            mkdir -p "$CHROOT/etc/systemd/system/graphical.target.wants"
            ln -sf /usr/lib/systemd/system/sddm.service \
                "$CHROOT/etc/systemd/system/graphical.target.wants/sddm.service"

            # Switch-to-Desktop / Return-to-Gaming buttons: gamescope/Steam
            # and steamos-manager may invoke a session named literally
            # "desktop" or "gamescope" (bare aliases) — those land both in
            # SDDM's session lookup AND in our steamos-session-select shim
            # below. Add symlinks so the SDDM lookup path resolves, and
            # match the same naming below in the shim's case statement.
            ln -sfn plasma.desktop             "$CHROOT/usr/share/wayland-sessions/desktop.desktop"
            ln -sfn plasmax11.desktop          "$CHROOT/usr/share/xsessions/desktop.desktop"
            ln -sfn gamescope-wayland.desktop  "$CHROOT/usr/share/wayland-sessions/gamescope.desktop"

            # AMD GPU firmware comes from the SteamOS rootfs as .bin.zst
            # (zstd-compressed). Our linux-ps5 7.0.10 kernel is built
            # WITHOUT CONFIG_FW_LOADER_COMPRESS_ZSTD=y so the kernel's
            # firmware loader looks for the bare .bin only, fails -2,
            # amdgpu logs "Fatal error during GPU init", no display.
            # Decompress every firmware blob in place; keep the .zst
            # alongside (cheap, harmless) so the kernel finds the .bin
            # without us having to enumerate which specific blobs amdgpu
            # asks for on this revision (currently pfp + sdma; could
            # grow). Side benefit: covers wifi/bluetooth/etc firmware
            # for free.
            echo "=== SteamOS: decompress *.bin.zst firmware (kernel can't load compressed) ==="
            fw_count=0
            while IFS= read -r -d '' zst; do
                out="${zst%.zst}"
                if [ ! -e "$out" ]; then
                    zstd -dq -o "$out" "$zst" && fw_count=$((fw_count+1))
                fi
            done < <(find "$CHROOT/lib/firmware" "$CHROOT/usr/lib/firmware" \
                          -name '*.bin.zst' -print0 2>/dev/null)
            echo ">> decompressed $fw_count firmware files"

            # mkinitramfs runs BEFORE this point in the script and bakes
            # the amdgpu module into the initramfs (per our modules list).
            # But Debian's mkinitramfs does NOT copy /lib/firmware/* into
            # the initramfs by default — so when amdgpu probes in early
            # userspace (initramfs phase, before switch_root), it requests
            # firmware from initramfs's /lib/firmware/ which doesn't have
            # it → ENOENT → fatal GPU init → no display, identical
            # symptom to the .zst-only-firmware bug above. Inject the
            # decompressed amdgpu blobs INTO the initrd image now (it's
            # a zstd cpio newc archive — extract, add, repack).
            INITRD="$CHROOT/boot/efi/initrd.img"
            if [ -f "$INITRD" ] && [ -d "$CHROOT/lib/firmware/amdgpu" ]; then
                echo "=== SteamOS: inject amdgpu firmware into initramfs ==="
                IWORK=$(mktemp -d)
                ( cd "$IWORK" && zstd -dc "$INITRD" | cpio -idmu --quiet --no-absolute-filenames )
                mkdir -p "$IWORK/usr/lib/firmware/amdgpu"
                cp "$CHROOT/lib/firmware/amdgpu"/*.bin "$IWORK/usr/lib/firmware/amdgpu/" 2>/dev/null || true
                # Some kernels probe /lib/firmware first, some /usr/lib/firmware.
                # Make both reachable.
                ln -sfn usr/lib/firmware "$IWORK/lib/firmware" 2>/dev/null || true
                ( cd "$IWORK" && find . | cpio -o -H newc --quiet | zstd -19 --quiet ) > "$INITRD.new"
                mv "$INITRD.new" "$INITRD"
                cp "$INITRD" "$CHROOT/boot/initramfs-$KVER.img"
                rm -rf "$IWORK"
                echo ">> initramfs repacked with firmware ($(du -h "$INITRD" | cut -f1))"
            fi

            # Persistent journal so post-boot failures are debuggable from
            # outside (read it by mounting the rootfs). Needs the
            # systemd-journal group ownership + setgid bit or journald
            # refuses to use it and silently stays volatile.
            mkdir -p "$CHROOT/var/log/journal"
            chown 0:980 "$CHROOT/var/log/journal" 2>/dev/null || \
                chroot "$CHROOT" chown 0:systemd-journal /var/log/journal 2>/dev/null || true
            chmod 2755 "$CHROOT/var/log/journal"

            # SteamOS fstab references its A/B atomic partset paths
            # (/dev/disk/by-partsets/{self,shared}/...) which don't exist
            # on a flat-rootfs flash — every mount unit fails and stalls
            # local-fs.target dependencies (NetworkManager etc.).
            sed -i '/by-partsets/s|^|#FLAT-ROOTFS-DISABLED# |' "$CHROOT/etc/fstab"

            # …but we still need /efi mounted at boot. ps5-stage-firmware
            # reads the NXP IW620 WLAN blob from /boot/efi/lib/nxp/, and
            # cmdline.txt / kexec.sh / bzImage live there too. Append a
            # label-based mount line so the FAT boot partition is up
            # before sysinit.target. /boot/efi is a symlink to /efi in
            # the recovery image; mount the canonical target.
            cat >> "$CHROOT/etc/fstab" <<FSTAB
LABEL=$EFI_LABEL /efi vfat defaults,nofail,umask=0077 0 2
FSTAB

            # steamos-customizations also ships explicit .mount units for
            # esp/efi/home that pull in partset-aware fsck + blockdev
            # targets. Mask esp.mount + home.mount (we don't have those
            # partitions), but leave efi.mount alone — it'd race the
            # fstab line above. systemd just generates a fresh efi.mount
            # from our fstab entry.
            for u in esp.mount home.mount; do
                ln -sf /dev/null "$CHROOT/etc/systemd/system/$u"
            done

            # The recovery image ships /etc/sddm.conf.d/zz-steamos-autologin.conf
            # with Session=plasma — it's normally written when a Deck user
            # picks "Switch to Desktop" from Steam, but the recovery image
            # bakes it in pre-set to KDE. With it present, SDDM autologs
            # into Plasma instead of the gamescope-wayland session.
            #
            # Just `rm` isn't enough: on first boot ps5-gamescope-recovery
            # (or steam-jupiter falling back to KDE because gamescope can't
            # grab a display) writes this file back with Session=plasma,
            # and we land in Plasma on every subsequent boot too.
            # Overwrite with gamescope-wayland.desktop so even when the
            # file gets recreated by Steam/recovery, we still autologin
            # into Big Picture.
            mkdir -p "$CHROOT/etc/sddm.conf.d"
            cat > "$CHROOT/etc/sddm.conf.d/zz-steamos-autologin.conf" <<'EOF'
[Autologin]
Session=gamescope-wayland.desktop
EOF

            # Replace /usr/bin/steamos-session-select with a dumb shim that
            # writes the sddm autologin file directly + restarts sddm. The
            # vendored version delegates to steamosctl/steamos-manager whose
            # Steam Deck hardware code paths silently no-op on PS5 — the
            # symptom is "Return to Gaming Mode just reloads Desktop" because
            # the autologin Session= never actually changes. This shim bypasses
            # the whole DBus dance.
            if [ -f "$CHROOT/usr/bin/steamos-session-select" ]; then
                mv "$CHROOT/usr/bin/steamos-session-select" \
                   "$CHROOT/usr/bin/steamos-session-select.orig"
                cat > "$CHROOT/usr/bin/steamos-session-select" <<'SHIM'
#!/bin/bash
# PS5-flat-rootfs shim: write a sddm autologin override directly +
# restart sddm. Bypasses the vendored script that delegates to
# steamosctl/steamos-manager (which silently no-ops on PS5).
#
# Uses sudo (deck has passwordless sudo on this build) rather than
# the recovery image's pkexec → steamos-priv-write path: that helper
# only whitelists /sys/class/backlight and similar paths, NOT
# /etc/sddm.conf.d, so any pkexec write attempt fails with an
# unbound-variable error from the priv-write script. Sudo is simpler
# and works from any context (Konsole, desktop shortcut, even SSH).
#
# Conf filename 'zzz-session-override.conf':
#   * sorts AFTER zz-steamos-autologin.conf so this file wins precedence
#   * does NOT match sddm's ExecStartPre 'rm /etc/sddm.conf.d/zzt-...'
#     drop-in pattern, so the override survives systemctl restart sddm
set -e
session="${1:-gamescope}"
case "$session" in
    plasma-wayland|plasma-wayland-persistent)  target="plasma.desktop"            ;;
    plasma|plasma-x11|plasma-x11-persistent)   target="plasmax11.desktop"         ;;
    desktop)                                   target="plasma.desktop"            ;;
    gamescope)                                 target="gamescope-wayland.desktop" ;;
    *)                                         target="gamescope-wayland.desktop" ;;
esac
sudo tee /etc/sddm.conf.d/zzz-session-override.conf >/dev/null <<EOF
[Autologin]
User=deck
Session=$target
Relogin=true
EOF
sudo systemctl restart sddm
SHIM
                chmod 755 "$CHROOT/usr/bin/steamos-session-select"
            fi

            # Steam Big Picture's Power-Menu "Switch to Desktop" button
            # fires a dbus call:
            #     dbus-send --system --dest=org.freedesktop.DisplayManager \
            #         /org/freedesktop/DisplayManager/Seat0 \
            #         org.freedesktop.DisplayManager.Seat.SwitchToUser \
            #         string:doorstop string:<session>
            # On the real Steam Deck this lands in Valve's patched SDDM
            # which writes /etc/sddm.conf.d/zzt-steamos-temp-login.conf.
            # Stock Arch SDDM (what the recovery image ships) accepts the
            # call but does nothing useful with it — the button is a no-op,
            # and re-adding -steamos3 to the Steam launcher to route the
            # button through our shim triggers Steam's A/B atomic-update
            # reboot loop (commit 11cdddd).
            #
            # Workaround: a tiny daemon that BecomeMonitor()s the system
            # bus, catches the SwitchToUser call, and runs the same
            # zzz-session-override.conf write + sddm restart that our shim
            # does. Steam's button now works without the -steamos3 flag.
            mkdir -p "$CHROOT/usr/local/sbin" "$CHROOT/etc/systemd/system"
            install -m 755 /repo/distros/steamos/steam-session-switch-listener.py \
                "$CHROOT/usr/local/sbin/steam-session-switch-listener" 2>/dev/null \
                || cp /repo/distros/steamos/steam-session-switch-listener.py \
                      "$CHROOT/usr/local/sbin/steam-session-switch-listener"
            chmod +x "$CHROOT/usr/local/sbin/steam-session-switch-listener"
            cp /repo/distros/steamos/steam-session-switch-listener.service \
                "$CHROOT/etc/systemd/system/steam-session-switch-listener.service"
            mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
            ln -sf ../steam-session-switch-listener.service \
                "$CHROOT/etc/systemd/system/multi-user.target.wants/steam-session-switch-listener.service"

            # Replace the recovery image's broken Return.desktop. The vendor
            # shortcut delegates to steamosctl, which silently no-ops on
            # PS5. Ours calls steamos-session-select gamescope directly
            # (our shim above does the real work). Drop it on deck's
            # Desktop AND in /usr/share/applications so it's discoverable
            # from the app menu too.
            mkdir -p "$CHROOT/home/deck/Desktop" "$CHROOT/usr/share/applications"
            cp /repo/distros/steamos/return-to-gaming-mode.desktop \
                "$CHROOT/home/deck/Desktop/Return.desktop"
            cp /repo/distros/steamos/return-to-gaming-mode.desktop \
                "$CHROOT/usr/share/applications/return-to-gaming-mode.desktop"
            chmod 755 "$CHROOT/home/deck/Desktop/Return.desktop"

            # The recovery image ships /home/deck owned by root:root (the
            # vendor install flow chowns it later during first-boot OOBE,
            # which we've masked out). Without this fix, KDE Plasma fails
            # to create /home/deck/.config on first login — error popup:
            # "Configuration file /home/deck/.config/kcminitrc not writable.
            # Please contact your system administrator."
            # Chown the whole tree to deck:deck (uid/gid 1000) so Plasma
            # init can write its caches/configs.
            chroot "$CHROOT" chown -R deck:deck /home/deck 2>/dev/null || \
                chown -R 1000:1000 "$CHROOT/home/deck"

            # The recovery image's pacman trust DB is populated for
            # archlinux only — not the holo (SteamOS Valve CI) keys —
            # so `pacman -Syu` on first boot fails every package with
            # "unknown trust" from the GitLab CI Package Builder key.
            # The holo-keyring package IS installed; just needs --populate.
            chroot "$CHROOT" pacman-key --init 2>/dev/null || true
            chroot "$CHROOT" pacman-key --populate holo 2>/dev/null || true

            # First-boot rootfs grow. Our build_image.sh writes a fixed-size
            # rootfs (~14 GB), but the user flashes onto multi-hundred-GB USB
            # drives. Without this, sda1 stays 11 GB and Steam/flatpak run
            # out of space within an hour.
            install -m 755 /repo/distros/arch/grow-rootfs \
                "$CHROOT/usr/local/sbin/grow-rootfs"
            install -m 644 /repo/distros/arch/grow-rootfs.service \
                "$CHROOT/etc/systemd/system/grow-rootfs.service"
            mkdir -p "$CHROOT/etc/systemd/system/local-fs.target.wants"
            ln -sf ../grow-rootfs.service \
                "$CHROOT/etc/systemd/system/local-fs.target.wants/grow-rootfs.service"

            # Disable the atomic OS updater. The Steam UI calls
            # /usr/bin/steamos-update on session start, which tries to
            # apply Valve's A/B atomic OTA via partsets we don't have +
            # neptune kernel != our linux-ps5. Result: "Unable to
            # download the required update" nag every session. Replace
            # with a noop that returns "no update available" (exit 7)
            # while honoring the --supports-duplicate-detection probe.
            if [ -f "$CHROOT/usr/bin/steamos-update" ]; then
                mv "$CHROOT/usr/bin/steamos-update" "$CHROOT/usr/bin/steamos-update.orig"
                cat > "$CHROOT/usr/bin/steamos-update" <<'SHIM'
#!/bin/bash
# Disabled — flat-rootfs PS5 build can't apply SteamOS A/B atomic OTAs.
if [ "$1" = "--supports-duplicate-detection" ]; then
    echo "supports duplicate detection" >&2
    exit 0
fi
echo "No update available (disabled — flat-rootfs PS5 build)" >&2
exit 7
SHIM
                chmod 755 "$CHROOT/usr/bin/steamos-update"
            fi

            # Even with steamos-update shimmed, the Steam Big Picture UI
            # downloads the OS update tarball directly from
            # update.steamos.cloud and calls steamos-reboot --reboot-other
            # to apply it. --reboot-other is Valve's "switch active A/B
            # partset slot then reboot" — since we have no partsets it
            # just reboots into the same image, Steam sees the update
            # still pending, downloads again, reboots. Infinite loop.
            # Shim steamos-reboot so --reboot-other is a silent noop;
            # plain reboot still works.
            # Strip -steamos3 + -steampal from the gamescope-session launcher.
            # These two flags are what makes the Steam client believe it's
            # running on a real Deck with the A/B atomic update model, so
            # after every bootstrap download Steam calls logind.Reboot to
            # "apply" the update — on a flat-rootfs build the reboot does
            # nothing and we just come back to the same image, loop forever.
            # Keep -steamdeck (Big Picture UI fidelity) and -gamepadui
            # (gamepad-driven UI). Also tack on -noverifyfiles so the
            # 493 MB client redownload doesn't repeat every session.
            sed -i 's|^steamargs=("-steamos3" "-steampal" "-steamdeck" "-gamepadui")|steamargs=("-steamdeck" "-gamepadui" "-noverifyfiles")|' \
                "$CHROOT/usr/lib/steamos/steam-launcher" 2>/dev/null || true

            # /usr/bin/steam → /usr/bin/steam-jupiter (symlink). The
            # steam-jupiter wrapper is Valve's OOBE script that does
            # `rm -rf ~/.steam ~/.local/share/Steam` at the top of every
            # launch — because the recovery image is meant to live as a
            # single-shot first-boot installer and the A/B atomic system
            # handles persistence. On our flat-rootfs build that wipe is
            # the cause of the "Steam downloads ~493 MB every session"
            # loop. Replace with one that just execs the real Steam
            # binary with the deck flags.
            if [ -f "$CHROOT/usr/bin/steam-jupiter" ]; then
                mv "$CHROOT/usr/bin/steam-jupiter" "$CHROOT/usr/bin/steam-jupiter.orig"
                cat > "$CHROOT/usr/bin/steam-jupiter" <<'SHIM'
#!/bin/bash
# Patched for flat-rootfs PS5 build:
# - skip OOBE rm -rf so Steam state persists across the reboot Steam
#   would otherwise fire post-bootstrap
# - drop -steamdeck so this desktop entry doesn't trigger the Deck-
#   specific reboot-to-apply update path either. Gaming Mode entry
#   path keeps its UI flags via /usr/lib/steamos/steam-launcher.
set -euo pipefail
exec /usr/lib/steam/steam -skipinitialbootstrap "$@"
SHIM
                chmod 755 "$CHROOT/usr/bin/steam-jupiter"
            fi

            # Steam binary calls logind.Reboot via DBus directly after the
            # bootstrap finishes downloading (its "apply the update by
            # rebooting" flow that assumes Deck-style A/B atomic). The
            # reboot happens BEFORE the bootstrap can mark itself
            # complete, so next boot Steam still thinks installed=0 and
            # re-downloads — loop. Block reboot/power-off from the deck
            # user via polkit so Steam can't trigger it. Manual reboots
            # via SSH/Konsole as root still work.
            mkdir -p "$CHROOT/etc/polkit-1/rules.d"
            cat > "$CHROOT/etc/polkit-1/rules.d/05-disable-deck-reboot.rules" <<'PK'
// Block Steam (running as deck) from issuing reboot/poweroff via DBus.
// On a real Steam Deck the A/B atomic update model wants Steam to be
// able to "reboot to apply" — here it traps us in a download loop
// because nothing actually applies. Manual reboots still work as root
// (sudo reboot via SSH or Konsole in Desktop Mode).
polkit.addRule(function(action, subject) {
    if (subject.user === "deck" && (
        action.id === "org.freedesktop.login1.reboot" ||
        action.id === "org.freedesktop.login1.reboot-multiple-sessions" ||
        action.id === "org.freedesktop.login1.power-off" ||
        action.id === "org.freedesktop.login1.power-off-multiple-sessions" ||
        action.id === "org.freedesktop.login1.set-reboot-to-firmware-setup"
    )) {
        return polkit.Result.NO;
    }
});
PK
            chmod 644 "$CHROOT/etc/polkit-1/rules.d/05-disable-deck-reboot.rules"

            if [ -f "$CHROOT/usr/bin/steamos-reboot" ]; then
                mv "$CHROOT/usr/bin/steamos-reboot" "$CHROOT/usr/bin/steamos-reboot.orig"
                cat > "$CHROOT/usr/bin/steamos-reboot" <<'SHIM'
#!/bin/bash
# Shimmed for flat-rootfs PS5 build — no A/B partsets, so --reboot-other
# (Steam OS-update apply path) restarts SDDM instead of doing the A/B
# slot switch + reboot. Gamescope-session relaunches cleanly into Steam
# login. Plain reboot still works.
case "${1:-}" in
    --reboot-other)
        # Clear pending atomupd state so Steam does not immediately
        # re-prompt for the same "update" on the next session.
        rm -rf /var/lib/steamos-atomupd/.cache \
               /home/.steamos/offload/var/lib/steamos-atomupd/.cache \
               2>/dev/null || true
        echo "steamos-reboot: --reboot-other -> sddm restart (no A/B partsets)" >&2
        systemctl restart sddm
        exit 0
        ;;
    *)
        exec /sbin/reboot "$@"
        ;;
esac
SHIM
                chmod 755 "$CHROOT/usr/bin/steamos-reboot"
            fi

            # FINAL OVERRIDE — the earlier zz-steamos-autologin.conf write at
            # ~line 1418 isn't sticking on the flashed image (file shows the
            # recovery image's stock mtime Jun 18 / Session=plasma after boot).
            # Something between that write and the partition copy at line ~2014
            # is overlaying it back. Last-write-wins: redo it here at the end of
            # the steamos block, and ALSO drop a sentinel zzz-session-override.conf
            # that sorts even later — same one our shim writes — so SDDM merge
            # order absolutely lands on gamescope-wayland for first boot.
            mkdir -p "$CHROOT/etc/sddm.conf.d"
            cat > "$CHROOT/etc/sddm.conf.d/zz-steamos-autologin.conf" <<'AUTOLOGIN_END'
[Autologin]
Session=gamescope-wayland.desktop
AUTOLOGIN_END
            cat > "$CHROOT/etc/sddm.conf.d/zzz-session-override.conf" <<'OVERRIDE_END'
[Autologin]
User=deck
Session=gamescope-wayland.desktop
Relogin=true
OVERRIDE_END
            echo "=== verify autologin file content ==="
            ls -la "$CHROOT/etc/sddm.conf.d/"
            grep -H Session= "$CHROOT/etc/sddm.conf.d/"*.conf || true

            echo "=== SteamOS: rootfs prepared at \$CHROOT ($(du -sh "$CHROOT" | cut -f1)), initrd $(du -h "$CHROOT/boot/efi/initrd.img" | cut -f1) ==="
            ;;
        *)
            YAML="/repo/distros/${DISTRO}/image.yaml"
            distrobuilder build-dir "$YAML" "$CHROOT" --with-post-files --cache-dir /build/cache --cleanup=false
            ;;
    esac
fi

# --- Universal: etawen.dev boot banner ---
# Shown by agetty at the pre-login prompt (/etc/issue), to remote logins
# via SSH (/etc/issue.net), and post-login (/etc/motd). On distros with
# tty1 autologin (cachyos, steamos) /etc/issue isn't seen but ssh + motd
# still are.
if [ -r /repo/distros/shared/etawen-banner.txt ]; then
    install -Dm644 /repo/distros/shared/etawen-banner.txt "$CHROOT/etc/etawen-banner.txt"
    cp /repo/distros/shared/etawen-banner.txt "$CHROOT/etc/issue"
    cp /repo/distros/shared/etawen-banner.txt "$CHROOT/etc/issue.net"
    cp /repo/distros/shared/etawen-banner.txt "$CHROOT/etc/motd"
fi

# --- Post-distrobuilder fixups ---
case "$DISTRO" in
    ubuntu*|debian*|mint*|fedora*|bazzite*|batocera*)
        rm -f "$CHROOT/etc/resolv.conf"
        ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
        ;;
    devuan*)
        # No systemd-resolved on Devuan. resolvconf creates
        # /etc/resolvconf/run/resolv.conf at boot; NetworkManager writes
        # through to it (rc-manager=resolvconf). Point /etc/resolv.conf
        # at that path so name resolution works as soon as NM brings up
        # an interface.
        rm -f "$CHROOT/etc/resolv.conf"
        ln -sf /etc/resolvconf/run/resolv.conf "$CHROOT/etc/resolv.conf"
        ;;
    artix*)
        # No systemd-resolved on Artix either. NetworkManager writes
        # /etc/resolv.conf directly when dns=default (the openrc-nm
        # default). Drop the build-container's resolv.conf so NM has
        # a clean slate to populate on first boot.
        rm -f "$CHROOT/etc/resolv.conf"
        : > "$CHROOT/etc/resolv.conf"
        ;;
esac

# --- ps5-linux-tools: fan + boost services ---
# Without /dev/icc fan control the PS5 runs at default (loud) fan curve;
# without /dev/mp1 boost the CPU/GPU stay at base clocks. ps5-linux-tools
# ships ps5_control (the binary that pokes both devices) and two systemd
# oneshots that bring them on at boot. Same recipe as the upstream README's
# install.sh — we just bake it into every image instead of asking the user
# to run it manually after first boot.
PS5TOOLS_REF="${PS5TOOLS_REF:-main}"
echo "=== ps5-linux-tools: build + install fan/boost services ==="
PS5TOOLS_DIR=/tmp/ps5-linux-tools
rm -rf "$PS5TOOLS_DIR"
git clone --depth 1 --branch "$PS5TOOLS_REF" \
    https://github.com/ps5-linux/ps5-linux-tools "$PS5TOOLS_DIR"
( cd "$PS5TOOLS_DIR" && make ps5_control m2_init )

install -Dm755 "$PS5TOOLS_DIR/ps5_control" "$CHROOT/usr/local/sbin/ps5_control"
install -Dm755 "$PS5TOOLS_DIR/m2_init"     "$CHROOT/usr/local/sbin/m2_init"

# Preserve the source tree at /opt/ps5-linux-tools so README-style commands
# (cd ps5-linux-tools && ./m2_install.sh, etc.) work on first boot without
# needing internet to re-clone.
#
# On Fedora-atomic / bazzite, /opt is a symlink to var/opt. mkdir -p on the
# symlink dangles because var/opt doesn't exist in the chroot yet, so resolve
# the symlink first and mkdir the actual target.
OPT_DEST=$(readlink -f "$CHROOT/opt" 2>/dev/null || echo "$CHROOT/opt")
mkdir -p "$OPT_DEST"
cp -a "$PS5TOOLS_DIR" "$OPT_DEST/ps5-linux-tools"
rm -rf "$OPT_DEST/ps5-linux-tools/.git"

case "$DISTRO" in
    alpine)
        # Alpine ships ps5fan/ps5boost via the OpenRC path in
        # post-files actions of its image.yaml; skip the systemd drop.
        :
        ;;
    devuan*)
        # Devuan is sysvinit. Drop /etc/init.d scripts and enable them
        # with update-rc.d during chroot below. The actual update-rc.d
        # call happens in image.yaml post-packages for the distro-built
        # units (ssh, NM, etc.) — for ps5fan/ps5boost we wire them up
        # here since they're staged outside the distrobuilder flow.
        cat > "$CHROOT/etc/init.d/ps5fan" <<'PS5FAN_SYSV'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ps5fan
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: PS5 fan control
### END INIT INFO
case "$1" in
    start) [ -e /dev/icc ] && /usr/local/sbin/ps5_control --fan on ;;
    stop)  [ -e /dev/icc ] && /usr/local/sbin/ps5_control --fan off ;;
    restart|force-reload) $0 stop; $0 start ;;
esac
exit 0
PS5FAN_SYSV
        cat > "$CHROOT/etc/init.d/ps5boost" <<'PS5BOOST_SYSV'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ps5boost
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: PS5 CPU/GPU boost mode
### END INIT INFO
case "$1" in
    start) [ -e /dev/mp1 ] && /usr/local/sbin/ps5_control --boost on ;;
    stop)  [ -e /dev/mp1 ] && /usr/local/sbin/ps5_control --boost off ;;
    restart|force-reload) $0 stop; $0 start ;;
esac
exit 0
PS5BOOST_SYSV
        chmod +x "$CHROOT/etc/init.d/ps5fan" "$CHROOT/etc/init.d/ps5boost"
        # update-rc.d may not be on PATH outside the chroot; run inside.
        chroot "$CHROOT" /usr/sbin/update-rc.d ps5fan defaults  >/dev/null 2>&1 || true
        chroot "$CHROOT" /usr/sbin/update-rc.d ps5boost defaults >/dev/null 2>&1 || true
        ;;
    artix-runit)
        # Artix runit: drop runit service trees and symlink into the
        # default runsvdir. Runit's run scripts are foreground-loop
        # daemons; ps5fan/ps5boost are one-shots, so do the work then
        # `exec pause` (or sleep infinity if no pause) to keep the
        # supervisor happy.
        mkdir -p "$CHROOT/etc/runit/sv/ps5fan"   "$CHROOT/etc/runit/sv/ps5boost"
        mkdir -p "$CHROOT/etc/runit/runsvdir/default"

        cat > "$CHROOT/etc/runit/sv/ps5fan/run" <<'PS5FAN_RUNIT'
#!/bin/sh
exec 2>&1
if [ -e /dev/icc ]; then
    /usr/local/sbin/ps5_control --fan on
fi
# Stay running so runsv keeps the service "up"; the one-shot effect is
# already applied. `sleep infinity` is portable across busybox/coreutils.
exec sleep infinity
PS5FAN_RUNIT

        cat > "$CHROOT/etc/runit/sv/ps5boost/run" <<'PS5BOOST_RUNIT'
#!/bin/sh
exec 2>&1
if [ -e /dev/mp1 ]; then
    /usr/local/sbin/ps5_control --boost on
fi
exec sleep infinity
PS5BOOST_RUNIT

        chmod +x "$CHROOT/etc/runit/sv/ps5fan/run" \
                 "$CHROOT/etc/runit/sv/ps5boost/run"
        ln -sfn /etc/runit/sv/ps5fan   "$CHROOT/etc/runit/runsvdir/default/ps5fan"
        ln -sfn /etc/runit/sv/ps5boost "$CHROOT/etc/runit/runsvdir/default/ps5boost"
        ;;
    artix*)
        # Artix OpenRC. Drop /etc/init.d openrc-run scripts and
        # rc-update them into the default runlevel.
        cat > "$CHROOT/etc/init.d/ps5fan" <<'PS5FAN_OPENRC'
#!/sbin/openrc-run
description="PS5 fan control"
depend() { need localmount; after dev-settle; }
start() {
    [ -e /dev/icc ] || { ebegin "PS5 fan: /dev/icc missing"; eend 0; return 0; }
    ebegin "Enabling PS5 fan control"
    /usr/local/sbin/ps5_control --fan on
    eend $?
}
stop() {
    [ -e /dev/icc ] || return 0
    ebegin "Disabling PS5 fan control"
    /usr/local/sbin/ps5_control --fan off
    eend $?
}
PS5FAN_OPENRC
        cat > "$CHROOT/etc/init.d/ps5boost" <<'PS5BOOST_OPENRC'
#!/sbin/openrc-run
description="PS5 CPU/GPU boost mode"
depend() { need localmount; after dev-settle; }
start() {
    [ -e /dev/mp1 ] || { ebegin "PS5 boost: /dev/mp1 missing"; eend 0; return 0; }
    ebegin "Enabling PS5 boost mode"
    /usr/local/sbin/ps5_control --boost on
    eend $?
}
stop() {
    [ -e /dev/mp1 ] || return 0
    ebegin "Disabling PS5 boost mode"
    /usr/local/sbin/ps5_control --boost off
    eend $?
}
PS5BOOST_OPENRC
        chmod +x "$CHROOT/etc/init.d/ps5fan" "$CHROOT/etc/init.d/ps5boost"
        chroot "$CHROOT" /sbin/rc-update add ps5fan default  >/dev/null 2>&1 || true
        chroot "$CHROOT" /sbin/rc-update add ps5boost default >/dev/null 2>&1 || true
        ;;
    *)
        # systemd distros: drop the service files and enable them.
        install -Dm644 "$PS5TOOLS_DIR/systemd/ps5fan.service" \
            "$CHROOT/etc/systemd/system/ps5fan.service"
        install -Dm644 "$PS5TOOLS_DIR/systemd/ps5boost.service" \
            "$CHROOT/etc/systemd/system/ps5boost.service"
        mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
        ln -sf ../ps5fan.service \
            "$CHROOT/etc/systemd/system/multi-user.target.wants/ps5fan.service"
        ln -sf ../ps5boost.service \
            "$CHROOT/etc/systemd/system/multi-user.target.wants/ps5boost.service"
        ;;
esac
rm -rf "$PS5TOOLS_DIR"

# --- NXP IW620 wifi firmware bridge ---
# The PS5's NXP IW620 wifi needs nxp/pcieuartiw620_combo_v1.bin, which is
# NOT in linux-firmware. ps5-linux-loader dumps it to /boot/efi/lib/nxp/
# at exploit time. This one-shot service copies that blob into
# /lib/firmware/nxp/ early in sysinit so moal finds it when it loads.
# Idempotent (no-op on subsequent boots), ConditionPathExists guards
# against running if the loader never ran (and the firmware was never
# dumped).
install -Dm755 /repo/distros/shared/ps5-iw620-firmware-install \
    "$CHROOT/usr/local/sbin/ps5-iw620-firmware-install"

case "$DISTRO" in
    alpine|devuan*|artix*)
        # Non-systemd distros: skip the unit for now. moal still works if
        # the firmware happens to be present from a previous boot or
        # manually placed.
        # TODO: openrc/runit/sysv equivalents
        ;;
    *)
        install -Dm644 /repo/distros/shared/ps5-iw620-firmware.service \
            "$CHROOT/etc/systemd/system/ps5-iw620-firmware.service"
        mkdir -p "$CHROOT/etc/systemd/system/sysinit.target.wants"
        ln -sf ../ps5-iw620-firmware.service \
            "$CHROOT/etc/systemd/system/sysinit.target.wants/ps5-iw620-firmware.service"
        ;;
esac

# --- Alpine kernel gap: no kernel installed via image.yaml ---
# Extract kernel from .deb, copy modules + bzImage, then chroot to run mkinitfs
if [ "$DISTRO" = "alpine" ]; then
    echo "=== Alpine: installing kernel from .deb artifacts ==="

    ALPINE_STAGING="/tmp/alpine-kernel-staging"
    rm -rf "$ALPINE_STAGING"
    mkdir -p "$ALPINE_STAGING"
    # Kernel-builder ships linux-ps5_*.deb (a single combined deb that
    # provides linux-image-*). The old linux-image-*.deb pattern matches
    # nothing on disk; keep both so an upstream naming shift doesn't
    # silently break alpine again.
    shopt -s nullglob
    for deb in /kernel-debs/linux-ps5*.deb /kernel-debs/linux-image-*.deb; do
        [ -f "$deb" ] || continue
        dpkg-deb -x "$deb" "$ALPINE_STAGING"
    done
    shopt -u nullglob

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
case "$DISTRO" in
    steamos)
        # Failsafe: even with default.target symlinked to graphical.target,
        # some early-userspace paths re-pick multi-user.target if the
        # symlink isn't readable yet. The cmdline override is read first
        # and bypasses that race.
        #
        # amdgpu.dpm=0 / amdgpu.gpu_recovery=0 — same fix as Bazzite. The
        # modprobe.d conf alone wasn't enough on the live PS5: amdgpu was
        # already loading with default params before the rootfs conf got
        # read (presumably built-in init order). Cmdline is parsed by the
        # kernel before any module init, so this is the reliable path.
        # See commit message "amdgpu dpm=0 gpu_recovery=0 — fixes Switch-
        # to-Desktop black screen" for the rationale.
        sed -i 's/$/ systemd.unit=graphical.target amdgpu.dpm=0 amdgpu.gpu_recovery=0/' /tmp/usb_efi/cmdline.txt
        ;;
    cachyos)
        # Same amdgpu params as steamos — without these the soft tty
        # handoff for Switch-to-Desktop black-screens the HDMI bridge
        # and the original cachyos workaround was a forced reboot.
        # With these on the cmdline, the kill-gamescope path works
        # cleanly (steamos-session-select plasma → no reboot).
        sed -i 's/$/ amdgpu.dpm=0 amdgpu.gpu_recovery=0/' /tmp/usb_efi/cmdline.txt
        ;;
    bazzite-deck)
        # Explicit LSM stack — bazzite-deck's built-in game-mode/desktop-mode
        # switcher (gamescope-session-plus) needs apparmor+landlock+bpf up
        # front or the mode switch silently no-ops. Tested on hardware; keep
        # the shared cmdline untouched for every other distro.
        sed -i 's/$/ lsm=landlock,lockdown,yama,integrity,apparmor,bpf/' /tmp/usb_efi/cmdline.txt
        ;;
esac
cp /repo/boot/vram.txt     /tmp/usb_efi/
cp /repo/boot/kexec.sh     /tmp/usb_efi/
sync

# Trim free space before the image leaves the builder: discard on the loop
# device punches holes in the backing file, so free blocks read as zeros and
# xz compresses them away (~3% smaller downloads, free at build time).
fstrim -v /tmp/usb_root 2>/dev/null || true
fstrim -v /tmp/usb_efi  2>/dev/null || true

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
