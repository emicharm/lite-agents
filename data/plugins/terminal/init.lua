-- data/plugins/terminal/init.lua
--
-- Tier-2 terminal: a real PTY (`pty` module) feeding a libvterm screen
-- (`vterm` module), rendered as a cell grid. Supports colors, alt screen,
-- cursor positioning — enough for `vim`, `tmux`, `htop`, `less`, etc.

local core    = require "core"
local style   = require "core.style"
local config  = require "core.config"
local command = require "core.command"
local keymap  = require "core.keymap"
local View    = require "core.view"

config.terminal_poll_ms = 16

-- ── Key handling ──────────────────────────────────────────────────────────

-- Special keys: lite-stroke-name → libvterm key name.
local special_keys = {
  ["return"]    = "enter",
  ["tab"]       = "tab",
  ["backspace"] = "backspace",
  ["escape"]    = "escape",
  ["up"]        = "up",       ["down"]  = "down",
  ["left"]      = "left",     ["right"] = "right",
  ["insert"]    = "insert",   ["delete"]   = "delete",
  ["home"]      = "home",     ["end"]      = "end",
  ["pageup"]    = "pageup",   ["pagedown"] = "pagedown",
  ["f1"]  = "f1",  ["f2"]  = "f2",  ["f3"]  = "f3",  ["f4"]  = "f4",
  ["f5"]  = "f5",  ["f6"]  = "f6",  ["f7"]  = "f7",  ["f8"]  = "f8",
  ["f9"]  = "f9",  ["f10"] = "f10", ["f11"] = "f11", ["f12"] = "f12",
}

local function current_mods()
  return {
    ctrl  = keymap.modkeys.ctrl  or false,
    alt   = keymap.modkeys.alt   or false,
    shift = keymap.modkeys.shift or false,
  }
end

-- Lua 5.2 has no utf8 library; small streaming decoder used to feed vterm.
local function utf8_iter(s)
  local i, n = 1, #s
  return function()
    if i > n then return nil end
    local b = s:byte(i)
    local cp, len
    if b < 0x80 then cp, len = b, 1
    elseif b < 0xc0 then cp, len = b, 1
    elseif b < 0xe0 then
      cp = (b - 0xc0) * 64 + (s:byte(i+1) or 0) - 0x80; len = 2
    elseif b < 0xf0 then
      cp = (b - 0xe0) * 4096 + ((s:byte(i+1) or 0) - 0x80) * 64
                             + (s:byte(i+2) or 0) - 0x80; len = 3
    else
      cp = (b - 0xf0) * 262144 + ((s:byte(i+1) or 0) - 0x80) * 4096
                              + ((s:byte(i+2) or 0) - 0x80) * 64
                              + (s:byte(i+3) or 0) - 0x80; len = 4
    end
    local pos = i
    i = i + len
    return pos, cp
  end
end

local function as_color(c) return c and { c[1], c[2], c[3], 255 } or nil end

-- ── TerminalView ──────────────────────────────────────────────────────────

local TerminalView = View:extend()

function TerminalView:new(cmd)
  TerminalView.super.new(self)
  self.scrollable = false
  self.cmd     = cmd or (os.getenv("SHELL") or "/bin/sh") .. " -i"
  self.rows    = 24
  self.cols    = 80
  self.cursor_visible = true

  -- Grab font metrics now so we know our initial geometry.
  self.cell_w  = math.max(1, style.code_font:get_width("m"))
  self.cell_h  = math.max(1, style.code_font:get_height())

  self.vt  = vterm.new(self.rows, self.cols)
  local p, err = pty.open(self.cmd, self.cols, self.rows)
  if not p then
    core.error("terminal: pty.open failed: %s", err or "?")
    self.failed = err or "unknown error"
    return
  end
  self.pty = p

  -- PTY → vterm pump.
  local tv = self
  core.add_thread(function()
    while tv.alive ~= false and tv.pty do
      local chunk, err2 = tv.pty:read()
      if chunk and chunk ~= "" then
        tv.vt:input_write(chunk)
        -- Drain any keyboard responses (cursor-position reports etc.).
        local resp = tv.vt:output_read()
        if resp ~= "" then tv.pty:write(resp) end
        core.redraw = true
      elseif err2 == "eof" then
        tv.dead = true
        tv.pty:close()
        tv.pty = nil
        core.redraw = true
        break
      end
      coroutine.yield(config.terminal_poll_ms / 1000)
    end
  end, self)
end

function TerminalView:try_close(do_close)
  self.alive = false
  if self.pty then self.pty:close(); self.pty = nil end
  do_close()
end

function TerminalView:get_name()
  return "terminal" .. (self.dead and " (exited)" or "")
end

-- ── Layout / resize ───────────────────────────────────────────────────────

function TerminalView:_compute_grid()
  local cw = style.code_font:get_width("m")
  local ch = style.code_font:get_height()
  self.cell_w, self.cell_h = math.max(1, cw), math.max(1, ch)
  local cols = math.max(20, math.floor((self.size.x - style.padding.x * 2) / self.cell_w))
  local rows = math.max(4,  math.floor((self.size.y - style.padding.y * 2) / self.cell_h))
  if cols ~= self.cols or rows ~= self.rows then
    self.cols, self.rows = cols, rows
    self.vt:resize(rows, cols)
    if self.pty then self.pty:resize(cols, rows) end
  end
end

function TerminalView:update()
  TerminalView.super.update(self)
  if self.size.x > 0 and self.size.y > 0 then self:_compute_grid() end
  -- Blink the cursor at ~2 Hz.
  local t = math.floor(system.get_time() * 2)
  if t ~= self._cursor_t then
    self._cursor_t = t
    self.cursor_visible = not self.cursor_visible
    core.redraw = true
  end
end

-- ── Drawing ───────────────────────────────────────────────────────────────

function TerminalView:draw()
  self:draw_background(style.background)
  if self.failed then
    renderer.draw_text(style.code_font, "(failed: " .. self.failed .. ")",
                       self.position.x + style.padding.x,
                       self.position.y + style.padding.y, style.text)
    return
  end

  local x0 = self.position.x + style.padding.x
  local y0 = self.position.y + style.padding.y
  local cw, ch = self.cell_w, self.cell_h
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  for r = 0, self.rows - 1 do
    local row_y = y0 + r * ch
    -- Collect runs of same-bg cells so we can fill the background per run
    -- rather than per cell — cheaper for the dirty-rect cache.
    local run_start, run_bg = 0, nil
    local cells = {}
    for c = 0, self.cols - 1 do
      local cell = self.vt:get_cell(r, c) or {}
      cells[c] = cell
      local bg = as_color(cell.bg)
      if bg and (not run_bg or bg[1] ~= run_bg[1] or bg[2] ~= run_bg[2] or bg[3] ~= run_bg[3]) then
        if run_bg then
          renderer.draw_rect(x0 + run_start * cw, row_y,
                             (c - run_start) * cw, ch, run_bg)
        end
        run_start, run_bg = c, bg
      elseif not bg and run_bg then
        renderer.draw_rect(x0 + run_start * cw, row_y,
                           (c - run_start) * cw, ch, run_bg)
        run_bg = nil
      end
    end
    if run_bg then
      renderer.draw_rect(x0 + run_start * cw, row_y,
                         (self.cols - run_start) * cw, ch, run_bg)
    end

    -- Glyph pass.
    for c = 0, self.cols - 1 do
      local cell = cells[c]
      if cell and cell.ch and cell.ch ~= " " and cell.ch ~= "" then
        local fg = as_color(cell.fg) or style.text
        renderer.draw_text(style.code_font, cell.ch,
                           x0 + c * cw, row_y, fg)
      end
    end
  end

  -- Cursor: invert the cell under it when blinking on.
  if self.cursor_visible and not self.dead then
    local cr, cc = self.vt:get_cursor()
    if cr and cc and cr < self.rows and cc < self.cols then
      renderer.draw_rect(x0 + cc * cw, y0 + cr * ch, cw, ch, style.caret)
    end
  end

  core.pop_clip_rect()
end

-- ── Input ─────────────────────────────────────────────────────────────────

function TerminalView:on_text_input(text)
  if not self.vt or not self.pty then return end
  for _, cp in utf8_iter(text) do
    self.vt:keyboard_unichar(cp, 0)
  end
  local out = self.vt:output_read()
  if out ~= "" then self.pty:write(out) end
end

-- Intercept the global keymap dispatch: when a terminal is focused, route
-- key events through vterm.keyboard_* instead of running editor commands.
local prev_on_key_pressed = keymap.on_key_pressed
function keymap.on_key_pressed(k)
  local v = core.active_view
  if v and v:is(TerminalView) and v.pty and v.vt then
    -- Plain modifier presses: still need keymap.modkeys tracking.
    if k == "left ctrl" or k == "right ctrl" or k == "left alt"  or k == "right alt"
    or k == "left shift" or k == "right shift" then
      return prev_on_key_pressed(k)
    end
    local sk = special_keys[k]
    if sk then
      v.vt:keyboard_key(sk, current_mods())
      local out = v.vt:output_read()
      if out ~= "" then v.pty:write(out) end
      return true
    end
    -- Ctrl/Alt + single char: feed as unichar with the modifier set so vterm
    -- emits the correct control sequence. Plain printable keys fall through
    -- so on_text_input handles them (preserves shift+layout/IME).
    if (keymap.modkeys.ctrl or keymap.modkeys.alt) and #k == 1 then
      v.vt:keyboard_unichar(k:byte(), current_mods())
      local out = v.vt:output_read()
      if out ~= "" then v.pty:write(out) end
      return true
    end
  end
  return prev_on_key_pressed(k)
end

-- ── Commands ──────────────────────────────────────────────────────────────

local function open_terminal()
  local v = TerminalView()
  local node = core.root_view:get_active_node()
  if not node or node.locked then
    local function find(n)
      if n.type == "leaf" then return (not n.locked) and n or nil end
      return find(n.a) or find(n.b)
    end
    node = find(core.root_view.root_node)
  end
  if node then node:add_view(v) end
end

command.add(nil, {
  ["terminal:open"] = open_terminal,
})

keymap.add {
  ["ctrl+`"] = "terminal:open",
}

return TerminalView
