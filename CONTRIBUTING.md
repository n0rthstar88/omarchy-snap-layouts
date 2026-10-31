# Contributing

Issues and pull requests are welcome. This is a small project, so please open an issue before starting anything large.

## Setup

Clone the repo, then copy it into your plugins folder so the shell loads your version:

```sh
omarchy plugin remove io.github.n0rthstar88.snap-layouts   # if installed
cp -r . ~/.config/omarchy/plugins/io.github.n0rthstar88.snap-layouts
omarchy plugin enable io.github.n0rthstar88.snap-layouts
omarchy restart shell
```

Copy your changes across and restart the shell after each QML change, and run `omarchy plugin validate .` before opening a pull request.

## Pull requests

- Keep each pull request to one change.
- Say what you tested, and on which Omarchy and Hyprland versions.
- Check both ways of dragging if you touch the drag code: a Hyprland mouse bind and a title bar.

## Hyprland crash to avoid

Never call `remove()` on the mouse binds in `hook.lua`. In Hyprland 0.56.2, `Keybind:remove()` deletes every bind on the same key and leaves the other handles dangling, and the next call on one of those crashes Hyprland. The binds are only ever added, and the plugin ignores their events when drag-to-snap is off.
