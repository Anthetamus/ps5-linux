# ps5-tinycore

Smallest known PS5-bootable Linux image (~80 MB). TinyCore Linux userspace on
top of the linux-ps5 kernel — boots to a busybox shell on HDMI tty1.

Built standalone, outside the docker/distrobuilder pipeline the other distros
use (TinyCore doesn't fit `distrobuilder`'s rootfs-based model).

## What's in it

- **GPT canonical layout** — matches the layout PS5 OS expects to auto-mount:
  - partition number 2 = FAT32 EFI labeled `boot`, physically first (1MiB..60MiB)
  - partition number 1 = ext4 placeholder rootfs, physically second (60MiB..end)
- **bzImage**: linux-ps5 7.0.10 build output (provided via `--bzimage`)
- **initrd.img**: TinyCore CorePure64 `corepure64.gz` + the entire linux-ps5
  kernel module tree + `cyan_skillfish` firmware **uncompressed** (linux-ps5's
  patched `request_firmware()` writes the sig-stripped header back into the
  firmware buffer in-place — if that buffer is mapped `PAGE_KERNEL_RO` from a
  zstd/xz blob it oopses at `gfx_v10_0_early_init+0x415`) + a custom `/init`
  that direct-`exec`s a busybox shell on tty1 (no `/sbin/init`, no TC `rcS`,
  no `switch_root`).  Firmware blobs are bundled here at
  `distros/tinycore/firmware/amdgpu/` — extracted once from upstream
  linux-firmware, no per-distro package dependency.
- **cmdline.txt**: `noembed multivt console=ttyTitania0 console=tty0 …`

## Boot flow

This image is loaded via [`ps5-linux-loader`][loader] — **not** kexec.sh.
The loader runs as a PS5 payload after the webkit/umtx2/Y2JB jailbreak; it
stat()s `/mnt/usb*/bzImage,initrd.img,cmdline.txt` on whatever FAT partition
the PS5 OS auto-mounted, then patches the hypervisor and enters rest mode.
Resume → linux-ps5 boots → our `/init` brings up amdgpu + HID + USB-Ethernet
→ busybox shell on the HDMI console.

[loader]: https://git.etawen.dev/mia/ps5-linux-loader

## Building

```bash
# 1. Build the linux-ps5 kernel + modules with the normal pipeline:
./build_image.sh --kernel-only

# 2. Build the tinycore image.  Both bzImage and modules come from
#    linux-bin/staging/ (populated by the --kernel-only build).  Firmware
#    is bundled in this dir — no --firmware-dir needed.
./distros/tinycore/build.sh \
    --bzimage     linux-bin/staging/boot/bzImage \
    --modules-dir linux-bin/staging/lib/modules/7.0.10
```

Output: `output/ps5-tinycore.img` (~80 MB).

## Flash + boot

```bash
sudo dd if=output/ps5-tinycore.img of=/dev/sdX bs=4M status=progress conv=fsync
```

On the PS5:

1. Run a userland jailbreak (Netflix-N-Hack, umtx2, Y2JB — anything that
   gives you a kernel ROP exec primitive listening on TCP/9021).
2. Send the loader payload:
   ```
   socat -t 99999999 - TCP:$PS5IP:9021 < ps5-linux-loader.elf
   ```
3. PS5 enters rest mode (orange LED blinking).  Wait for it to go solid.
4. Press the power button — LED goes white, HDMI shows the linux-ps5 boot
   log, then the busybox prompt on tty1.

## Why this works (and our earlier small images didn't)

PS5 OS only auto-mounts a USB at `/mnt/usb*/` if the FAT partition matches
the layout it expects.  Empirically, that means:

- **Partition number 2 must be the FAT partition** (not partition 1).
- **The FAT partition must be physically first on disk** (start at sector
  2048, i.e. 1 MiB offset).
- **Label `boot`** is what every working PS5 image uses.

Get any of those wrong and the loader's `stat("/mnt/usb0/bzImage")` fails
silently — PS5 boots, jailbreak runs, payload sends, hypervisor patches,
rest mode entered, resume… and nothing happens because there was no kernel
to hand off to.  Symptom: black screen, no HDMI signal.

The 64 GB drive-size minimum from the loader README is the conservative
recommendation; in practice 80 MB total works fine, provided the layout
matches above.

## Wiring into `build_image.sh`

Not yet wired up — call `distros/tinycore/build.sh` directly.  To add it
to the `--distro` dispatch (as a special-case that skips the docker
distrobuilder path), add to `build_image.sh` after the kernel build:

```bash
if [ "$DISTRO" = "tinycore" ]; then
    "$SCRIPT_DIR/distros/tinycore/build.sh" \
        --bzimage      "$KERNEL_OUT/bzImage" \
        --modules-dir  "$CHROOT_DIR/debian13-server/usr/lib/modules/7.0.10" \
        --firmware-dir "$CHROOT_DIR/debian13-server/usr/lib/firmware/amdgpu" \
        --output       "$OUTPUT_DIR/ps5-tinycore.img"
    exit 0
fi
```
