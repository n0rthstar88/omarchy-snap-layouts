-- Title bars on every window, so any window can be dragged without Super.
-- Drag the bar to move a window; double-click it to maximize or restore.
-- See README.md in this folder for how to build the plugin and enable this.

local plugin = os.getenv("HOME") .. "/.local/lib/hyprland/libhyprbars.so"
local f = io.open(plugin, "r")
if not f then
  return
end
f:close()

-- Bar colors follow the current Omarchy theme.
local function theme_color(name, fallback)
  local colors = io.open(os.getenv("HOME") .. "/.local/state/omarchy/current/theme/colors.toml", "r")
  if not colors then
    return fallback
  end
  local text = colors:read("a")
  colors:close()
  local hex = text:match("\n" .. name .. '%s*=%s*"#(%x%x%x%x%x%x)"')
  return hex and ("rgb(" .. hex .. ")") or fallback
end

hl.plugin.load(plugin)

hl.config({
  plugin = {
    hyprbars = {
      bar_height = 24,
      bar_color = theme_color("dark_background", "rgb(13141c)"),
      col = { text = theme_color("foreground", "rgb(a9b1d6)") },
      bar_text_font = "JetBrainsMono Nerd Font",
      bar_text_size = 10,
      bar_padding = 10,
      bar_precedence_over_border = true,
      bar_buttons_alignment = "right",
      bar_button_padding = 8,
      icon_on_hover = true,
      on_double_click = [[hyprctl eval "hl.dispatch(hl.dsp.window.fullscreen({ mode = 'maximized' }))"]],
    },
  },
})

-- Buttons are listed right to left, so close is outermost. Clicking one
-- focuses that window first, so the actions target it. Icons appear on hover.
hl.plugin.hyprbars.add_button({
  bg_color = "rgb(ff5f57)",
  fg_color = "rgb(4d0000)",
  size = 13,
  icon = "×",
  action = [[hyprctl dispatch 'hl.dsp.window.close()']],
})

hl.plugin.hyprbars.add_button({
  bg_color = "rgb(28c840)",
  fg_color = "rgb(004d00)",
  size = 13,
  icon = "+",
  action = [[hyprctl dispatch "hl.dsp.window.fullscreen({ mode = 'maximized', action = 'toggle' })"]],
})

-- Minimize uses the same place as Omarchy's minimized windows.
hl.plugin.hyprbars.add_button({
  bg_color = "rgb(febc2e)",
  fg_color = "rgb(5a3d00)",
  size = 13,
  icon = "–",
  action = [[hyprctl dispatch "hl.dsp.window.move({ workspace = 'special:omarchy-minimized', follow = false })"]],
})
