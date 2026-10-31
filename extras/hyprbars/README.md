# Title bars (optional)

This adds a header with close, maximize and minimize buttons to every window, using the official [hyprbars](https://github.com/hyprwm/hyprland-plugins) plugin. Snap Layouts works without it: you can drag with Super+drag instead.

Hyprbars stops Hyprland's mouse binds from seeing a title bar drag, so a stock hyprbars build won't open the picker. `hyprbars-drag-events.patch` makes it send `hyprbars:dragstart` and `hyprbars:dragend` events, which the plugin listens for.

**The patch is for Hyprland 0.56.0 to 0.56.2**, using hyprland-plugins commit `7644cec`, the commit upstream's `hyprpm.toml` pins for those releases. Newer hyprland-plugins commits changed the same lines, so the patch doesn't apply to them. You'd need to adapt it for those, and a plugin built for one Hyprland version won't load on another.

## Build

You need `git`, `make`, a C++ compiler and the Hyprland headers (on Arch, the `hyprland` package includes them). From this folder, run:

```sh
patch_file="$PWD/hyprbars-drag-events.patch"
work=$(mktemp -d)
git clone https://github.com/hyprwm/hyprland-plugins.git "$work/hyprland-plugins"
cd "$work/hyprland-plugins"
git checkout 7644cec
git apply "$patch_file"
make -C hyprbars
mkdir -p ~/.local/lib/hyprland
cp hyprbars/hyprbars.so ~/.local/lib/hyprland/libhyprbars.so
```

The patch was tested using a build made through Arch's `hyprland-plugins` recipe at the same commit. The steps above are the manual equivalent.

## Enable

1. Copy `titlebars.lua` from this folder to `~/.config/hypr/titlebars.lua`.
2. Add this line to `~/.config/hypr/hyprland.lua`, after `require("hypr.looknfeel")`:

   ```lua
   require("hypr.titlebars")
   ```

3. Log out and back in.

If you change `bar_height`, set `titleBarHeight` in `SnapLayouts.qml` to match.

## After a Hyprland update

Hyprland refuses to load a plugin built for a different version. It shows a red "Version mismatch" notification and the title bars disappear, but nothing else breaks. Rebuild for the new version, or delete the `require` line to remove the title bars.

## Remove

Delete the `require("hypr.titlebars")` line, `~/.config/hypr/titlebars.lua` and `~/.local/lib/hyprland/libhyprbars.so`, then log out and back in.
