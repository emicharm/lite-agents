local common = require "core.common"
local config = require "core.config"
local style = {}

style.padding = { x = common.round(14 * SCALE), y = common.round(7 * SCALE) }
style.divider_size = common.round(config.gap_size * SCALE)
style.panel_radius = common.round(config.panel_radius * SCALE)
style.scrollbar_size = common.round(4 * SCALE)
style.caret_width = common.round(2 * SCALE)
style.tab_width = common.round(170 * SCALE)

style.font = renderer.font.load(EXEDIR .. "/data/fonts/font.ttf", 14 * SCALE)
style.big_font = renderer.font.load(EXEDIR .. "/data/fonts/font.ttf", 34 * SCALE)
style.icon_font = renderer.font.load(EXEDIR .. "/data/fonts/icons.ttf", 14 * SCALE)
style.code_font = renderer.font.load(EXEDIR .. "/data/fonts/monospace.ttf", 13.5 * SCALE)

style.background = { common.color "#2e2e32" }
style.background2 = { common.color "#252529" }
style.background3 = { common.color "#252529" }
style.background_outer = { common.color "#19191c" }
style.text = { common.color "#97979c" }
style.caret = { common.color "#93DDFA" }
style.accent = { common.color "#e1e1e6" }
style.dim = { common.color "#525257" }
style.divider = { common.color "#202024" }
style.selection = { common.color "#48484f" }
style.line_number = { common.color "#525259" }
style.line_number2 = { common.color "#83838f" }
style.line_highlight = { common.color "#343438" }
style.scrollbar = { common.color "#414146" }
style.scrollbar2 = { common.color "#4b4b52" }

style.syntax = {}
style.syntax["normal"] = { common.color "#e1e1e6" }
style.syntax["symbol"] = { common.color "#e1e1e6" }
style.syntax["comment"] = { common.color "#676b6f" }
style.syntax["keyword"] = { common.color "#E58AC9" }
style.syntax["keyword2"] = { common.color "#F77483" }
style.syntax["number"] = { common.color "#FFA94D" }
style.syntax["literal"] = { common.color "#FFA94D" }
style.syntax["string"] = { common.color "#f7c95c" }
style.syntax["operator"] = { common.color "#93DDFA" }
style.syntax["function"] = { common.color "#93DDFA" }

-- ANSI 16-color palette used by the terminal plugin. Themes can override this
-- to retune how `\e[3Xm`/`\e[9Xm` sequences look. Index 0..7 are the base
-- colors, 8..15 are the "bright" variants. Default fg/bg fall back to
-- style.text / style.background and are handled separately.
style.terminal_palette = {
  { common.color "#3a3a40" }, -- 0 black (slightly above bg so black-on-default reads)
  { common.color "#F77483" }, -- 1 red          (syntax.keyword2)
  { common.color "#89D185" }, -- 2 green
  { common.color "#F7C95C" }, -- 3 yellow       (syntax.string)
  { common.color "#93DDFA" }, -- 4 blue         (syntax.operator/function)
  { common.color "#E58AC9" }, -- 5 magenta      (syntax.keyword)
  { common.color "#6FD0E0" }, -- 6 cyan
  { common.color "#97979C" }, -- 7 white        (style.text)
  { common.color "#676B6F" }, -- 8 bright black (syntax.comment)
  { common.color "#FF9CA8" }, -- 9 bright red
  { common.color "#A3E3A0" }, -- 10 bright green
  { common.color "#FFA94D" }, -- 11 bright yellow (syntax.number)
  { common.color "#B6E6FF" }, -- 12 bright blue
  { common.color "#F3B0DD" }, -- 13 bright magenta
  { common.color "#A5E6F0" }, -- 14 bright cyan
  { common.color "#E1E1E6" }, -- 15 bright white  (style.accent)
}

return style
