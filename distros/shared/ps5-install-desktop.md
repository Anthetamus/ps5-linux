# ps5-install-desktop

Installs GNOME, KDE Plasma or Sway (all Wayland) on the minimal `arch` image.
Script: `distros/shared/ps5-install-desktop`, installed as
`/usr/local/sbin/ps5-install-desktop`.

```
sudo ps5-install-desktop [gnome|kde|sway] [--no-autologin]
```

First-boot setup (`ps5-first-boot-setup`) runs it after the account is
created, offering GNOME, KDE Plasma, Sway, or staying on the console. It can
be run again later, also to switch desktops.

## Steps

While it runs, the console log level is lowered to critical messages only
(`dmesg -n 3`) and restored on exit, so kernel messages (the wifi driver is
chatty) don't draw over the dialogs and the install output.

1. **Desktop**: a menu, unless `gnome`/`kde`/`sway` is given.
2. **Packages**: a checklist of every optional package, all selected; Space
   deselects. The packages the desktop can't run without are listed above the
   checklist and are always installed. pacman doesn't install optional
   dependencies, so the list is exactly what's added (plus dependencies).
3. **Autologin**: asks whether to log in automatically as the user who ran
   `sudo` (or the first-boot user). `--no-autologin` skips the question.
4. **Network**: if NetworkManager isn't connected, offers `nmtui` (wifi or
   ethernet), a retry, or skipping the install.
5. **Confirm**: warns that the install can take a long time on a slow USB
   stick and must not be interrupted (a power-off during the install leaves
   a half-installed system).
6. **Install**: `pacman -Syu --needed` with the chosen packages. A leftover
   `/var/lib/pacman/db.lck` from an interrupted run is removed first (only if
   no pacman is running), and it waits for `archlinux-keyring-wkd-sync` to
   finish: on first boot that refreshes pacman's keyring as soon as the
   network is up, and a GNOME install started during it failed. pacman is
   retried up to 3 times; if it still fails, the error stays on screen until
   Enter is pressed.
7. **Configure** (below), then start the desktop: at first boot right away;
   otherwise GNOME with `sudo systemctl start ps5-monitors-xml
   display-manager`, KDE/Sway by logging in again on tty1.

## GNOME

- GDM, with autologin in `/etc/gdm/custom.conf` if chosen.
- `ps5-monitors-xml.service` enabled: before GDM starts it writes
  `/etc/xdg/monitors.xml` from each monitor's EDID with `<maxbpc>8</maxbpc>`.
  The PS5's DP→HDMI bridge shows a black screen when mutter leaves `max bpc`
  at the amdgpu default of 16. A user's own `~/.config/monitors.xml` takes
  precedence; if the screen goes black after changing display settings, check
  that it still has `<maxbpc>8</maxbpc>`.
- `/usr/share/glib-2.0/schemas/90_ps5.gschema.override`: the screen never
  blanks (`idle-delay=0`) and never auto-suspends (suspend is untested on PS5).
- Default target `graphical.target`.

## KDE Plasma

- No display manager, as on the CachyOS image (SDDM needs an X server).
  `/etc/profile.d/ps5-plasma.sh` starts `startplasma-wayland` after logging in
  on tty1, with `KWIN_FORCE_ASSUME_HDR_SUPPORT=0` and
  `KWIN_DRM_PREFER_COLOR_DEPTH=24`, which keep KWin off HDR / 10 bpc output
  (black screen through the PS5's bridge). Log: `~/.cache/ps5-plasma.log`.
- `/etc/xdg/powerdevilrc`: on AC, never auto-suspend, dim or turn off the
  display.

## Sway

- Like Plasma, no display manager: `/etc/profile.d/ps5-sway.sh` starts `sway`
  after logging in on tty1, with sway's default config (`/etc/sway/config`:
  `foot` terminal, `wmenu` launcher, `swaybg` wallpaper, built-in bar). Copy it to
  `~/.config/sway/config` to customise. Log: `~/.cache/ps5-sway.log`.

## KDE Plasma and Sway

- Autologin, if chosen: `/etc/systemd/system/getty@tty1.service.d/ps5-autologin.conf`
  (`agetty --autologin USER`), so the desktop starts at boot.
- Logging out returns to the tty1 shell. Create `~/.config/ps5-no-desktop` to
  stay on the console.
- Only one desktop starts from tty1: installing one removes the other's
  `profile.d` script, and disables GDM and `ps5-monitors-xml` if GNOME was
  installed before. Default target `multi-user.target`.

## Package lists

### GNOME

Always installed: `gdm`, `gnome-shell`, `gnome-session`, `gnome-settings-daemon`, `gnome-control-center`, `gnome-keyring`, `xdg-desktop-portal-gnome`, `mesa`, `pipewire`, `pipewire-pulse`, `wireplumber`, `noto-fonts`.

| Optional (selected by default) | |
|---|---|
| `nautilus` | Files (file manager) |
| `gnome-console` | Console (terminal) |
| `gnome-text-editor` | Text Editor |
| `gnome-system-monitor` | System Monitor |
| `gnome-disk-utility` | Disks |
| `gnome-calculator` | Calculator |
| `loupe` | Image Viewer |
| `papers` | Document Viewer (PDF) |
| `firefox` | Firefox web browser |
| `gvfs` | Trash, network and removable drives in Files |
| `gnome-backgrounds` | Default wallpapers |
| `gnome-menus` | Legacy application menu support |
| `xdg-user-dirs-gtk` | Creates Documents, Downloads, ... folders |
| `vulkan-radeon` | Vulkan driver for the PS5 GPU |
| `ttf-dejavu` | DejaVu fonts |

### KDE Plasma

Always installed: `plasma-desktop`, `xdg-desktop-portal-kde`, `mesa`, `pipewire`, `pipewire-pulse`, `wireplumber`, `noto-fonts`.

| Optional (selected by default) | |
|---|---|
| `dolphin` | Dolphin (file manager) |
| `konsole` | Konsole (terminal) |
| `kate` | Kate (text editor) |
| `plasma-nm` | Network/wifi applet |
| `plasma-pa` | Volume applet |
| `bluedevil` | Bluetooth applet |
| `powerdevil` | Power management |
| `kscreen` | Display settings |
| `plasma-systemmonitor` | System Monitor |
| `kinfocenter` | Info Center |
| `spectacle` | Screenshots |
| `gwenview` | Image viewer |
| `okular` | Document viewer (PDF) |
| `ark` | Archive manager |
| `breeze-gtk` | Breeze theme for GTK apps |
| `kde-gtk-config` | GTK app settings in System Settings |
| `firefox` | Firefox web browser |
| `xdg-user-dirs` | Creates Documents, Downloads, ... folders |
| `vulkan-radeon` | Vulkan driver for the PS5 GPU |
| `ttf-dejavu` | DejaVu fonts |

### Sway

Always installed: `sway`, `swaybg`, `foot`, `wmenu`, `xdg-desktop-portal-wlr`, `mesa`, `pipewire`, `pipewire-pulse`, `wireplumber`, `noto-fonts`.

| Optional (selected by default) | |
|---|---|
| `swaylock` | Screen locker |
| `swayidle` | Idle management (lock/blank after inactivity) |
| `mako` | Notifications |
| `grim` | Screenshots |
| `slurp` | Select a region for screenshots |
| `wl-clipboard` | Clipboard tools (wl-copy, wl-paste) |
| `xorg-xwayland` | Run X11 apps |
| `thunar` | Thunar (file manager) |
| `firefox` | Firefox web browser |
| `vulkan-radeon` | Vulkan driver for the PS5 GPU |
| `ttf-dejavu` | DejaVu fonts |
| `noto-fonts-cjk` | Chinese, Japanese, Korean fonts |
| `noto-fonts-emoji` | Emoji font |
