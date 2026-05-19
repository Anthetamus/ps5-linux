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

# Record the refs we built against (used in release-body rendering later).
echo "$MWIFIEX_REF" > /out/staging/mwifiex-ref
echo "$NXP_REF"     > /out/staging/nxp-ref

echo "=== Build artifacts staged in /out/staging ==="
