# PoE Campaign Overlay

I vibe-coded this for personal use, but decided to release it so everyone can use it.
I haven't tested it on other systems, so it may not work for you. Basically, it's Exile Leveling adapted for a single monitor. You can import your own build, and it will show you which gems to buy in town. It should automatically show only the gems available to you. The route may not be perfect; I've tested it up to Act 5, and it covers the important stuff. You can skip steps and go back with keybinds, and check the passive tree and gems from your PoB build. You can also disable skill-set loadouts, so you don't see gems you'll only need for T16 maps while you're still in Act 1.
The route should handle crashes and mistakes pretty well. For example, if you forget to buy a gem in town, you can come back and see what you should have done before leaving, and which zone you need to return to.

## Will It Run On My System?

This is a Linux app, not an Arch-only app. It should run on a Wayland desktop if your compositor supports the `wlr-layer-shell` protocol and you can install QuickShell with its Qt 6 QML and Wayland modules. Hyprland is not required for manual launch, but the automatic game detection and workspace behavior in `auto-watcher.sh` are Hyprland-only. I have only tested it on my own setup, so other distributions and compositors are not confirmed.

You will need:

- Path of Exile 1. The default log location assumes the Steam version; for other installs, set the `Client.txt` path in the build import window.
- QuickShell 0.3.2 or newer and Python 3.10 or newer.
- The standard Linux `tail` command (usually already installed).
- For Hyprland auto-start only: Hyprland (which includes `hyprctl`) and `jq` (may need to be installed separately).

## Install

### Check Wayland

```sh
printf 'Session type: %s\nWayland display: %s\n' \
	"${XDG_SESSION_TYPE:-not set}" "${WAYLAND_DISPLAY:-not set}"
```

### Install QuickShell

```sh
# Choose one QuickShell install command for your distribution.
# Python 3 and tail are required by the app; no pip packages are needed.
# Add jq only for Hyprland auto-start.

# Arch
sudo pacman -S quickshell python

# Fedora Rawhide
sudo dnf install quickshell python3

# Debian testing or unstable
sudo apt install quickshell python3

# Ubuntu
sudo add-apt-repository ppa:avengemedia/danklinux
sudo apt install quickshell python3

# jq is only needed for Hyprland auto-start
# Arch: sudo pacman -S jq
# Fedora: sudo dnf install jq
# Debian or Ubuntu: sudo apt install jq

```

Other distributions: [QuickShell installation instructions](https://quickshell.org/docs/guide/install-setup).

### Download And Run

```sh
# Replace the URL with this repository's GitHub URL.
git clone https://github.com/LiomyL/poe-overlay.git poe-overlay
cd poe-overlay
chmod +x manual.sh auto-watcher.sh
./manual.sh
# Stop the manually launched overlay with Ctrl+C in its terminal.
```

### Hyprland Auto-Start

Add **one** of these to your Hyprland startup config. Replace the example path with the path to this repository.

Hyprlang:

```ini
exec-once = /path/to/poe-overlay/auto-watcher.sh
```

Lua:

```lua
hl.on("hyprland.start", function()
	hl.exec_cmd("/path/to/poe-overlay/auto-watcher.sh")
end)
```

## Use It

The overlay reads PoE 1's `Client.txt` log. By default, it looks here:

```text
~/.local/share/Steam/steamapps/common/Path of Exile/logs/Client.txt
```

For a different installation, open the build importer and enter the full path to `Client.txt` in the **Path to Client.txt** field. The setting is saved on this device and applies immediately.

To open the build importer while the overlay is running:

```sh
./auto-watcher.sh open-build
```

Paste a Path of Building export code (or use **Paste** if `wl-paste` is installed), then select **Import**. The imported build's enabled skill sets are used for gem reminders. **View build** opens the gem and passive-tree viewer.

The watcher also accepts these commands:

| Command | Action |
| --- | --- |
| `open-build` | Open or close the build importer |
| `open-build-viewer` | Toggle the build viewer |
| `toggle-overlay` | Enable or disable the HUD |
| `route-cursor-forward` / `route-cursor-backward` | Move the route cursor one step |

Add a keybind in your Hyprland config to call a watcher command.

Hyprlang:

```ini
bind = SUPER, B, exec, /home/you/poe-overlay/auto-watcher.sh open-build
```

Lua:

```lua
hl.bind("SUPER + B", hl.dsp.exec_cmd(home .. "/poe-overlay/auto-watcher.sh open-build"))
```

## Data

Campaign routes are bundled and do not update automatically. Missing passive-tree versions are downloaded from GitHub on first use and cached locally. Imported builds, settings, and campaign progress stay in your user data directory.

See `LICENSE` and `THIRD_PARTY_NOTICES.md` for license information.
