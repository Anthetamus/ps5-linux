# ChimeraOS

Image-based distro target; entrypoint.sh handles the build via:

1. Download `arch-gamescope-${CHIMERA_VER}.img.tar.xz` from upstream GitHub releases
2. Extract straight to `$CHROOT`
3. Install our `linux-ps5` `.pkg.tar.zst` (replaces upstream `linux-arch-gamescope`)
4. Regenerate initramfs

There's no `image.yaml` because we don't use distrobuilder for image-based distros
(same pattern as `bazzite/` and `batocera*` — see entrypoint.sh).

To pin a different upstream version, set `CHIMERA_VER` when invoking the build:

    CHIMERA_VER=49-1_cabd8c9 ./build_image.sh --distro arch-gamescope

