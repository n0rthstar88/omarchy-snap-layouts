-- Drag-to-snap for io.github.n0rthstar88.snap-layouts.
--
-- The plugin runs this with `hyprctl eval` when `hyprctl binds` is missing
-- the binds below for a button (first start, after a config reload wipes
-- runtime binds, or after another plugin removed binds on that button). It
-- sets snap_layouts_buttons to the buttons that need them first. The binds
-- only report left/right button presses and releases to the plugin as
-- Hyprland events; non_consuming keeps every click reaching apps, and
-- ignore_mods covers Super+drag too. Turning drag-to-snap off leaves them in
-- place and the plugin ignores the events.
--
-- Never call remove() on these. In Hyprland 0.56.2, Keybind:remove() deletes
-- every bind on the same key, so the press and release binds (and other
-- plugins' binds on the same button) are left as dangling handles, and the
-- next call on one of those crashes Hyprland.

for _, button in ipairs(snap_layouts_buttons or { "mouse:272", "mouse:273" }) do
  hl.bind(button, hl.dsp.event("io.github.n0rthstar88.snap-layouts:press"), {
    non_consuming = true,
    ignore_mods = true,
    description = "io.github.n0rthstar88.snap-layouts drag",
  })
  hl.bind(button, hl.dsp.event("io.github.n0rthstar88.snap-layouts:release"), {
    release = true,
    non_consuming = true,
    ignore_mods = true,
    description = "io.github.n0rthstar88.snap-layouts drag",
  })
end
snap_layouts_buttons = nil
