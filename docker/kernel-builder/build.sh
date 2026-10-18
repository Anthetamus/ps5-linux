#!/bin/bash
# Compiles the kernel and stages all artifacts into /out/staging.
# Runs inside Docker; kernel source is bind-mounted at /src.
set -e

# Clean host-built tool artifacts that may reference wrong include paths
make -C tools/objtool clean 2>/dev/null || true

make olddefconfig
make -j"$(nproc)" bzImage modules

# Stage all artifacts so downstream packagers don't need to run make
echo "=== Staging build artifacts ==="
rm -rf /out/staging
mkdir -p /out/staging/boot

cp arch/x86/boot/bzImage /out/staging/boot/
cp System.map             /out/staging/
cp .config                /out/staging/

make modules_install INSTALL_MOD_PATH=/out/staging INSTALL_MOD_STRIP=1

# Remove dangling symlinks back into the source tree
KVER=$(make -s kernelrelease)
rm -f "/out/staging/lib/modules/$KVER/build" \
      "/out/staging/lib/modules/$KVER/source"

# Stage kernel headers for out-of-tree module builds
echo "=== Staging kernel headers ==="
HDR="/out/staging/headers"
make headers_install INSTALL_HDR_PATH="$HDR/usr"

# Use the kernel's own install-extmod-build script (same as deb-pkg uses)
export srctree=/src SRCARCH=x86
CC="${CROSS_COMPILE}gcc" HOSTCC=gcc MAKE=make /src/scripts/package/install-extmod-build "$HDR/lib/modules/$KVER/build"

# install-extmod-build copies tools/objtool/objtool from the kernel source
# tree. If that tree was previously built under --platform linux/arm64 (our
# CI runners share a /data cache across arches), the staged objtool is an
# aarch64 ELF, which dpkg-shlibdeps then auto-pins as `ld-linux-aarch64.so.1`
# in the .deb. alien -> rpm carries that bogus dep over and dnf upgrade
# fails with "nothing provides ld-linux-aarch64.so.1". Out-of-tree builders
# don't need a prebuilt objtool — kbuild rebuilds it on demand.
find "$HDR/lib/modules/$KVER/build/tools/objtool" -maxdepth 1 -type f \
    -exec file {} + 2>/dev/null \
    | awk -F: '/ELF/ && !/x86-64/ {print $1}' \
    | xargs -r rm -f

# ─── PS5 IW620 mwifiex driver ────────────────────────────────────────────────
# Out-of-tree module built against the kernel we just compiled. The
# ps5-linux-mwifiex repo provides a single patch on top of NXP's mwifiex
# release; building from that pin + that base produces mlan.ko / moal.ko
# staged alongside the in-tree modules.
MWIFIEX_REF="${MWIFIEX_REF:-5cfd063449f27e2f8a7d17c814a3bb21c27aa903}"   # ps5-linux/ps5-linux-mwifiex
NXP_REF="${NXP_REF:-lf-6.18.2_1.0.0}"                                   # nxp-imx/mwifiex base

echo "=== Build PS5 mwifiex (patch $MWIFIEX_REF on NXP $NXP_REF) ==="
rm -rf /tmp/mwifiex-ps5 /tmp/mwifiex-nxp
git clone --quiet https://github.com/ps5-linux/ps5-linux-mwifiex.git /tmp/mwifiex-ps5
git -C /tmp/mwifiex-ps5 checkout --quiet "$MWIFIEX_REF"
git clone --quiet --depth 1 --branch "$NXP_REF" https://github.com/nxp-imx/mwifiex.git /tmp/mwifiex-nxp
git -C /tmp/mwifiex-nxp apply /tmp/mwifiex-ps5/ps5-iw620.patch

# As of mwifiex commit cecdc29 (2026-06-23) upstream ships additional
# patches in its install.sh: a command-timeout recovery patch and a
# kernel 7.1 cfg80211 API compat patch. We don't use install.sh (its
# version detection is `uname -r` which reflects the BUILD HOST kernel
# on a Docker runner, never the target), so apply the extras here.
#
# Detect target kernel major.minor from /src/Makefile (the kernel
# source we're building against), not uname -r.
if [ -f /tmp/mwifiex-ps5/ps5-iw620-cmd-timeout-recover.patch ]; then
    echo "  + applying cmd-timeout-recover patch"
    git -C /tmp/mwifiex-nxp apply /tmp/mwifiex-ps5/ps5-iw620-cmd-timeout-recover.patch
fi
KMAJ=$(awk -F= '/^VERSION/{print $2}' /src/Makefile | tr -d ' ')
KMIN=$(awk -F= '/^PATCHLEVEL/{print $2}' /src/Makefile | tr -d ' ')
if [ -f /tmp/mwifiex-ps5/ps5-iw620-kernel71-compat.patch ]; then
    if [ "${KMAJ:-0}" -gt 7 ] || { [ "${KMAJ:-0}" = "7" ] && [ "${KMIN:-0}" -ge 1 ]; }; then
        echo "  + applying kernel 7.1 cfg80211 compat patch (target kernel $KMAJ.$KMIN)"
        git -C /tmp/mwifiex-nxp apply /tmp/mwifiex-ps5/ps5-iw620-kernel71-compat.patch
    fi
fi
# Kernel 7.2 removed strncpy() entirely; upstream ships the proper fix as
# ps5-iw620-kernel72-compat.patch (strncpy->strscpy plus the 7.2
# remain_on_channel mac_addr param). Apply it for 7.2+.
if [ -f /tmp/mwifiex-ps5/ps5-iw620-kernel72-compat.patch ]; then
    if [ "${KMAJ:-0}" -gt 7 ] || { [ "${KMAJ:-0}" = "7" ] && [ "${KMIN:-0}" -ge 2 ]; }; then
        echo "  + applying kernel 7.2 compat patch (target kernel $KMAJ.$KMIN)"
        git -C /tmp/mwifiex-nxp apply /tmp/mwifiex-ps5/ps5-iw620-kernel72-compat.patch
    fi
fi
# 7.3 changed cfg80211 again (cookie passed by value, remain_on_channel
# gained rx_addr, probe_client removed). Our layered patch lives in the
# image repo (docker/kernel-builder/, bind-mounted with the build context).
if [ "${KMAJ:-0}" -gt 7 ] || { [ "${KMAJ:-0}" = "7" ] && [ "${KMIN:-0}" -ge 3 ]; }; then
    echo "  + applying kernel 7.3 cfg80211 compat patch (target kernel $KMAJ.$KMIN)"
    git -C /tmp/mwifiex-nxp apply /ps5-iw620-kernel73-compat.patch
fi

make -C /tmp/mwifiex-nxp CONFIG_OBJTOOL= KERNELDIR=/src ARCH=x86 -j"$(nproc)"

mkdir -p "/out/staging/lib/modules/$KVER/extra/ps5-iw620"
cp /tmp/mwifiex-nxp/mlan.ko /tmp/mwifiex-nxp/moal.ko \
    "/out/staging/lib/modules/$KVER/extra/ps5-iw620/"

# modprobe config — values lifted from install.sh in ps5-linux-mwifiex.
mkdir -p /out/staging/etc/modprobe.d
cat > /out/staging/etc/modprobe.d/ps5-iw620.conf <<MODPROBE
# PS5 IW620 mwifiex
softdep moal pre: cfg80211 mlan
options moal fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 auto_fw_reload=0 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1
MODPROBE

# Do NOT auto-load moal at boot via /etc/modules-load.d/. That used to
# race with the firmware-staging service (moal loads before firmware is
# copied from /boot/efi → request_firmware fails → driver fails).
# Instead, ps5-iw620-firmware.service runs at multi-user.target, after
# /boot/efi is mounted, and does both: copy firmware + modprobe moal.
# See distros/shared/ps5-iw620-firmware{.service,-install}.
rm -f /out/staging/etc/modules-load.d/ps5-iw620.conf 2>/dev/null || true

# Firmware staging. The PS5 WLAN firmware blob
# (nxp/pcieuartiw620_combo_v1.bin) is placed on the FAT32 EFI partition
# by ps5-linux-loader at /boot/efi/lib/nxp/. moal calls request_firmware()
# which searches /lib/firmware/, so we need a copy on boot. The blob is
# Sony-proprietary, so we can't bake it into the image.
mkdir -p /out/staging/usr/local/sbin
cat > /out/staging/usr/local/sbin/ps5-stage-firmware <<'EOF'
#!/bin/sh
set -eu
FW=nxp/pcieuartiw620_combo_v1.bin
DST=/lib/firmware/$FW
[ -e "$DST" ] && exit 0
for d in /boot/efi /efi /boot; do
    SRC="$d/lib/$FW"
    if [ -f "$SRC" ]; then
        install -Dm0644 "$SRC" "$DST"
        echo "ps5-stage-firmware: copied $SRC -> $DST"
        # Reload moal so it picks up firmware now that it exists.
        modprobe -r moal mlan 2>/dev/null || true
        modprobe moal 2>/dev/null || true
        exit 0
    fi
done
echo "ps5-stage-firmware: $FW not found on EFI partition; skipping"
exit 0
EOF
chmod +x /out/staging/usr/local/sbin/ps5-stage-firmware

mkdir -p /out/staging/etc/systemd/system/sysinit.target.wants
cat > /out/staging/etc/systemd/system/ps5-stage-firmware.service <<'EOF'
[Unit]
Description=Copy PS5 WLAN firmware from EFI partition to /lib/firmware
After=local-fs.target
Before=systemd-modules-load.service network-pre.target
ConditionPathExists=/usr/local/sbin/ps5-stage-firmware

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-stage-firmware
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
ln -sf ../ps5-stage-firmware.service \
    /out/staging/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service

# ─── PS5 GBE driver ──────────────────────────────────────────────────────────
#
# The PS5's onboard gigabit ethernet (104d:9104) is driven in-tree by the
# `mts` driver added in ps5-linux-patches @ kernel-7.0.10-643e214 (PR #8).
# We no longer build rmuxnet/ps5-salina-gbe out-of-tree.

# Record the refs we built against (used in release-body rendering later).
echo "$MWIFIEX_REF" > /out/staging/mwifiex-ref
echo "$NXP_REF"     > /out/staging/nxp-ref

echo "=== Build artifacts staged in /out/staging ==="
