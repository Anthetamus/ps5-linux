#!/bin/bash
set -ex

DISTRO="${DISTRO:-ubuntu2604}"
# Bazzite ships large (~10 GB rootfs after OCI unpack), bump the default img.
case "${DISTRO}" in
    bazzite*)  IMG_SIZE="${IMG_SIZE:-20000}" ;;
    batocera*) IMG_SIZE="${IMG_SIZE:-16000}" ;;
    *)         IMG_SIZE="${IMG_SIZE:-12000}" ;;
esac
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
            mkdir -p "$CHROOT/etc/modprobe.d"
            cat > "$CHROOT/etc/modprobe.d/ps5-amdgpu.conf" <<MODPROBE
options amdgpu dpm=0 gpu_recovery=0
MODPROBE

            echo "=== Batocera: build initrd via host mkinitramfs ==="
            # Host (image-builder, ubuntu:24.04) has initramfs-tools. Trick
            # it into building for our PS5 kernel by symlinking the chroot's
            # modules into /lib/modules/$KVER, then unlinking after.
            mkdir -p /lib/modules
            ln -sfn "$CHROOT/lib/modules/$KVER" "/lib/modules/$KVER"
            mkinitramfs -k "$KVER" -o "$CHROOT/boot/efi/initrd.img"
            rm -f "/lib/modules/$KVER"
            rm -rf "$KSTAGE"

            echo "=== Batocera: fstab + users ==="
            cat > "$CHROOT/etc/fstab" <<FSTAB
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL  /boot/efi vfat defaults 0 1
FSTAB
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
        *)
            YAML="/repo/distros/${DISTRO}/image.yaml"
            distrobuilder build-dir "$YAML" "$CHROOT" --with-post-files --cache-dir /build/cache --cleanup=false
            ;;
    esac
fi

# --- Post-distrobuilder fixups ---
case "$DISTRO" in
    ubuntu*|debian*|fedora*|bazzite*|batocera*)
        rm -f "$CHROOT/etc/resolv.conf"
        ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
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

if [ "$DISTRO" != "alpine" ]; then
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
fi
rm -rf "$PS5TOOLS_DIR"

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
