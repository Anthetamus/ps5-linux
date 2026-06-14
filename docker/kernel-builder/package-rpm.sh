#!/bin/bash
# Build linux-ps5 .rpm from the staged kernel artifacts in /out/staging.
# Runs after package-deb.sh in the kernel-builder container.
#
# This historically used `alien --to-rpm` to convert the .deb produced by
# package-deb.sh into an .rpm. That worked for installation but silently
# stripped ELF sections from large modules — most notably the `.BTF`
# section in `amdgpu.ko`, which is ~90 KB and required by the kernel's
# BTF-aware module loader (CONFIG_DEBUG_INFO_BTF_MODULES). With the BTF
# section gone, the kernel rejects amdgpu at load time:
#
#     failed to validate module [amdgpu] BTF: -22
#     amdgpu 0000:20:00.0: probe with driver amdgpu failed with error -22
#
# That's the no-display regression we kept hitting on every rpm-based
# distro (bazzite*, fedora-*, batocera) while .deb-based and arch-based
# distros worked fine.
#
# Replacement strategy: skip alien entirely. The staged kernel files in
# /out/staging are already laid out the way a kernel package installs
# (/boot, /lib/modules, /etc, /usr). Have rpmbuild package them in place
# via --buildroot, with the post-install strip steps disabled so .BTF
# (and any other ELF section rpmbuild's macros would munge) survives.
set -e

STAGING="/out/staging"
if [ ! -d "$STAGING" ]; then
    echo "package-rpm.sh: $STAGING missing — did build.sh stage artifacts?" >&2
    exit 1
fi

KVER=$(ls -1 "$STAGING/lib/modules" | head -1)
VER="${KVER%%-*}"
REL=1
ARCH=x86_64
NVR="linux-ps5-${VER}-${REL}.${ARCH}"

TOPDIR=$(mktemp -d -t ps5-rpm-XXXXXX)
mkdir -p "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
BUILDROOT="$TOPDIR/BUILDROOT/${NVR}"
mkdir -p "$BUILDROOT/boot" "$BUILDROOT/lib/modules" "$BUILDROOT/etc" "$BUILDROOT/usr"

# Mirror package-deb.sh's layout: same files, same paths.
cp "$STAGING/boot/bzImage" "$BUILDROOT/boot/vmlinuz-$KVER"
cp "$STAGING/System.map"   "$BUILDROOT/boot/System.map-$KVER"
cp "$STAGING/.config"      "$BUILDROOT/boot/config-$KVER"
cp -a "$STAGING/lib/modules/$KVER" "$BUILDROOT/lib/modules/"

if [ -d "$STAGING/etc" ]; then
    cp -a "$STAGING/etc/." "$BUILDROOT/etc/"
fi
if [ -d "$STAGING/usr" ]; then
    cp -a "$STAGING/usr/." "$BUILDROOT/usr/"
fi
# Kernel headers, same exclusion as package-deb.sh (no /lib/modules/build
# convenience symlink — let users point KERNELDIR at /usr/lib/modules/$KVER/build).
if [ -d "$STAGING/headers" ]; then
    cp -a "$STAGING/headers/usr/." "$BUILDROOT/usr/"
    mkdir -p "$BUILDROOT/usr/lib/modules/$KVER"
    cp -a "$STAGING/headers/lib/modules/$KVER/build" "$BUILDROOT/usr/lib/modules/$KVER/build"
fi

# Build a list of every file we just placed under BUILDROOT. rpmbuild
# packs whatever %files declares; using `find` keeps us honest with the
# real on-disk tree without having to enumerate every kernel module.
FILELIST="$TOPDIR/files.list"
( cd "$BUILDROOT" && find . -mindepth 1 \( -type f -o -type l \) -printf '/%P\n' ) > "$FILELIST"

# Write the spec. The key bit is `%global __os_install_post %{nil}` which
# disables rpmbuild's post-install pipeline (strip, dwz, BTF strip, etc.)
# so the modules land in the .rpm byte-identical to what's in BUILDROOT.
# `AutoReqProv: no` skips automatic dependency scanning — these are
# kernel files, not userspace libraries; we don't want rpm tracking
# every shared library a stray helper script links against.
SPEC="$TOPDIR/SPECS/linux-ps5.spec"
cat > "$SPEC" <<SPEC
%global __os_install_post %{nil}
%global __arch_install_post %{nil}
%global _build_id_links none
%global _enable_debug_packages 0
%global debug_package %{nil}
%global _binary_payload w7T.zstdio

Name:           linux-ps5
Version:        $VER
Release:        $REL
Summary:        PS5 Linux kernel (image + modules + headers)
License:        GPL-2.0
BuildArch:      $ARCH
Provides:       kernel-uname-r = $KVER
AutoReqProv:    no

%description
PS5 Linux kernel $KVER — vmlinuz, in-tree modules, headers, and the
PS5-specific firmware-staging glue.

%files -f $FILELIST

%post
KVER="\$(ls -1t /lib/modules | head -1)"
echo ">> linux-ps5 post: kernel \$KVER"

if command -v dracut >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with dracut for \$KVER"
    dracut -f --kver "\$KVER" "/boot/initrd.img-\$KVER" || true
elif command -v mkinitcpio >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with mkinitcpio for \$KVER"
    mkinitcpio -k "\$KVER" -g "/boot/initrd.img-\$KVER" || true
elif command -v update-initramfs >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with update-initramfs for \$KVER"
    update-initramfs -c -k "\$KVER" || true
elif command -v mkinitfs >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with mkinitfs for \$KVER"
    mkinitfs -o "/boot/initrd.img-\$KVER" "\$KVER" || true
else
    echo ">> No initramfs tool found; skipping initramfs build"
fi

if [ -d /boot/efi ]; then
    [ -f "/boot/vmlinuz-\$KVER" ]    && cp "/boot/vmlinuz-\$KVER"    /boot/efi/bzImage
    [ -f "/boot/initrd.img-\$KVER" ] && cp "/boot/initrd.img-\$KVER" /boot/efi/initrd.img
    echo ">> Kernel \$KVER files deployed to /boot/efi"
else
    echo ">> /boot/efi not found, skipping EFI deploy"
fi
SPEC

# `--noclean` keeps the buildroot tree we already populated. `-bb`
# builds binary only (no .src.rpm). `--target` ensures arch tag matches
# our cross-built artifacts even when host arch differs.
rpmbuild \
    --define "_topdir $TOPDIR" \
    --define "_rpmdir $TOPDIR/RPMS" \
    --buildroot "$BUILDROOT" \
    --target "$ARCH" \
    --noclean \
    -bb "$SPEC"

RPM=$(ls -1t "$TOPDIR/RPMS/$ARCH"/linux-ps5-*.rpm | head -1)
[ -n "$RPM" ] || { echo "package-rpm.sh: rpmbuild produced no .rpm" >&2; exit 1; }

# Sanity check: the amdgpu.ko inside the produced .rpm MUST be the same
# byte length as the one we staged. If it's smaller, rpmbuild stripped
# something despite our %global overrides and we want to fail loud
# instead of shipping another silently-broken .rpm.
STAGE_KO="$BUILDROOT/lib/modules/$KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
if [ -f "$STAGE_KO" ]; then
    STAGE_SZ=$(stat -c%s "$STAGE_KO")
    RPM_SZ=$(rpm2cpio "$RPM" 2>/dev/null \
        | cpio --to-stdout -i "./lib/modules/$KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko" 2>/dev/null \
        | wc -c)
    if [ "$RPM_SZ" != "$STAGE_SZ" ]; then
        echo "package-rpm.sh: amdgpu.ko in .rpm ($RPM_SZ B) does not match staging ($STAGE_SZ B)" >&2
        echo "  rpmbuild stripped the module despite __os_install_post=%{nil} — refusing to ship a BTF-broken .rpm" >&2
        exit 1
    fi
    echo "package-rpm.sh: amdgpu.ko byte-equal between staging and .rpm ($STAGE_SZ B) — BTF preserved"
fi

cp "$RPM" /out/
RPM_BASENAME=$(basename "$RPM")
echo "package-rpm.sh: produced /out/$RPM_BASENAME"
ls -lh "/out/$RPM_BASENAME"

rm -rf "$TOPDIR"
