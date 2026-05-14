-- Ported from enkia.tokyo-night VS Code extension
-- (tokyo-night-color-theme.json)
local style = require "core.style"
local common = require "core.common"

style.background       = { common.color "#1a1b26" }  -- editor.background
style.background2      = { common.color "#16161e" }  -- sideBar / statusBar / tab bg
style.background3      = { common.color "#1f2335" }  -- popup / suggest widget
style.background_outer = { common.color "#0d0d12" }  -- the "desktop" behind the panels
style.text             = { common.color "#a9b1d6" }  -- editor.foreground
style.caret            = { common.color "#c0caf5" }  -- editorCursor.foreground
style.accent           = { common.color "#7aa2f7" }  -- the signature Tokyo Night blue
style.dim              = { common.color "#565f89" }
style.divider          = { common.color "#101014" }
style.selection        = { common.color "#283457" }  -- editor.selectionBackground (alpha-flattened)
style.line_number      = { common.color "#363b54" }
style.line_number2     = { common.color "#787c99" }
style.line_highlight   = { common.color "#1e202e" }  -- editor.lineHighlightBackground
style.scrollbar        = { common.color "#2f3549" }
style.scrollbar2       = { common.color "#414868" }

style.syntax["normal"]   = { common.color "#a9b1d6" }
style.syntax["symbol"]   = { common.color "#c0caf5" }
style.syntax["comment"]  = { common.color "#565f89" }
style.syntax["keyword"]  = { common.color "#bb9af7" }  -- control flow, keyword
style.syntax["keyword2"] = { common.color "#9d7cd8" }  -- storage / type modifiers
style.syntax["number"]   = { common.color "#ff9e64" }
style.syntax["literal"]  = { common.color "#ff9e64" }
style.syntax["string"]   = { common.color "#9ece6a" }
style.syntax["operator"] = { common.color "#89ddff" }
style.syntax["function"] = { common.color "#7aa2f7" }
