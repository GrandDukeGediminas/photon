photon runs Wallpaper Engine wallpapers natively on macOS and Linux. It is a clean-room reimplementation: no part of
Wallpaper Engine is included.

**You need a Steam account that owns Wallpaper Engine.** photon checks this at launch through Valve's steamcmd. It can
set steamcmd up and sign it in from its own window; your password and Steam Guard code go only to steamcmd. Scene
wallpapers also need the engine's base assets from a Wallpaper Engine install (for example in a CrossOver bottle on
macOS, or Steam/Proton on Linux).

**macOS** (14 or later, Apple Silicon or Intel): unzip `photon-<version>-macos.zip` and move `photon.app` to
Applications. The app is not notarised, so macOS blocks the first launch: open it once, then allow it in System
Settings → Privacy & Security → "Open Anyway" (or run `xattr -dr com.apple.quarantine /Applications/photon.app`).

**Linux**: install the `.deb` (Ubuntu 24.04+, or the `deb12` one for Debian 12), the `.rpm` (Fedora 40+), the
`.flatpak` (`flatpak install --user photon2-<arch>.flatpak`), or run the `.AppImage`. X11 and Wayland (wlroots
compositors, KDE Plasma, GNOME with the bundled Shell extension) are supported.

Check downloads against `SHA256SUMS`.
