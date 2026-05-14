-- data/plugins/terminal/init.lua
--
-- Bottom-docked console panel with its own tab strip, hosting one or more
-- libvterm-backed terminals. ctrl+` toggles the panel; the first toggle
-- spawns a terminal if none exist. ctrl+shift+` opens an extra tab.
--
-- Layout: the panel is inserted as a locked split below the editor area
-- (above the command/status views). It animates its height between 0 and
-- config.terminal_panel_height * SCALE.

local core    = require "core"
local common  = require "core.common"
local style   = require "core.style"
local config  = require "core.config"
local command = require "core.command"
local keymap  = require "core.keymap"
local View    = require "core.view"
local scroll_math = require "plugins.terminal.scroll_math"

config.terminal_poll_ms     = 16
config.terminal_panel_height = 260   -- unscaled pixels when expanded

-- ── Key handling helpers ──────────────────────────────────────────────────

-- Shell-essential keys: always forwarded to the active terminal. The editor
-- has bindings for some of these (arrows → doc:move-*, enter → doc:newline,
-- …) but they're all predicated on core.docview, so they never fire while
-- the terminal is active anyway.
local shell_keys = {
  ["return"]    = "enter",
  ["tab"]       = "tab",
  ["backspace"] = "backspace",
  ["escape"]    = "escape",
  ["up"]    = "up",    ["down"]     = "down",
  ["left"]  = "left",  ["right"]    = "right",
  ["insert"]= "insert",["delete"]   = "delete",
  ["home"]  = "home",  ["end"]      = "end",
  ["pageup"]= "pageup",["pagedown"] = "pagedown",
}

-- Contested keys: useful to both the editor (F6 = cclog:toggle, F5 =
-- core:restart, …) and to TUIs running inside the terminal (htop, mc, …).
-- We try the editor's keymap first and only forward to vterm if no
-- command actually performed.
local contested_keys = {
  ["f1"]="f1", ["f2"]="f2", ["f3"]="f3", ["f4"]="f4",
  ["f5"]="f5", ["f6"]="f6", ["f7"]="f7", ["f8"]="f8",
  ["f9"]="f9", ["f10"]="f10", ["f11"]="f11", ["f12"]="f12",
}

local function current_mods()
  return {
    ctrl  = keymap.modkeys.ctrl  or false,
    alt   = keymap.modkeys.alt   or false,
    shift = keymap.modkeys.shift or false,
  }
end

-- Mirrors keymap.lua's private key_to_stroke (same modifier order). Used to
-- probe the editor keymap for contested keys before forwarding them to vterm.
local function key_to_stroke(k)
  local s = ""
  if keymap.modkeys.ctrl  then s = s .. "ctrl+"  end
  if keymap.modkeys.alt   then s = s .. "alt+"   end
  if keymap.modkeys.altgr then s = s .. "altgr+" end
  if keymap.modkeys.shift then s = s .. "shift+" end
  return s .. k
end

-- Try to run an editor binding for k. Returns true iff at least one bound
-- command's predicate passed and it ran. keymap.on_key_pressed can't be
-- reused here because it returns true even when every predicate failed.
local function try_editor_binding(k)
  local cmds = keymap.map[key_to_stroke(k)]
  if not cmds then return false end
  for _, cmd in ipairs(cmds) do
    if command.perform(cmd) then return true end
  end
  return false
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

-- ── TerminalView (single shell + vterm screen) ────────────────────────────

local TerminalView = View:extend()

function TerminalView:new(cmd)
  TerminalView.super.new(self)
  self.scrollable = false
  self.cmd     = cmd or (os.getenv("SHELL") or "/bin/sh") .. " -i"
  self.rows    = 24
  self.cols    = 80
  self.cursor_visible = true
  self.cursor = "ibeam"
  -- Scrollback offset in *pixels* above the live screen. 0 = tracking the
  -- bottom; positive = scrolled up into scrollback. We animate the current
  -- value (scroll_offset_px) toward the target (scroll_target_px) the same
  -- way DocView animates self.scroll.y toward self.scroll.to.y, so wheel
  -- input feels smooth instead of jumping a whole line at a time.
  self.scroll_offset_px = 0
  self.scroll_target_px = 0

  -- Selection in vterm row coordinates (>=0 live screen, <0 scrollback).
  -- Nil while not selecting. While dragging, sel.dragging is true.
  self.sel = nil

  self.cell_w  = math.max(1, style.code_font:get_width("m"))
  self.cell_h  = math.max(1, style.code_font:get_height())

  self.vt  = vterm.new(self.rows, self.cols)
  -- Apply the theme-defined ANSI palette so `ls`, prompts, etc. use the
  -- editor's color scheme instead of libvterm's hard-coded xterm defaults.
  if style.terminal_palette then
    for i, c in ipairs(style.terminal_palette) do
      if c then self.vt:set_palette_color(i - 1, c[1], c[2], c[3]) end
    end
  end
  local p, err = pty.open(self.cmd, self.cols, self.rows)
  if not p then
    core.error("terminal: pty.open failed: %s", err or "?")
    self.failed = err or "unknown error"
    return
  end
  self.pty = p

  local tv = self
  core.add_thread(function()
    while tv.alive ~= false and tv.pty do
      -- Drain everything available before yielding so a single burst
      -- (e.g. a TUI re-rendering its full backbuffer) lands in one frame
      -- instead of scrolling visibly at 16 KB / 16 ms.
      local drained, eof = false, false
      local total = 0
      while tv.pty and total < 4 * 1024 * 1024 do
        local chunk, err2 = tv.pty:read()
        if chunk and chunk ~= "" then
          tv.vt:input_write(chunk)
          total = total + #chunk
          drained = true
        elseif err2 == "eof" then
          eof = true
          break
        else
          break
        end
      end
      if drained then
        local resp = tv.vt:output_read()
        if resp ~= "" and tv.pty then tv.pty:write(resp) end
        core.redraw = true
      end
      if eof then
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

function TerminalView:close()
  self.alive = false
  if self.pty then self.pty:close(); self.pty = nil end
end

function TerminalView:get_name()
  return "terminal" .. (self.dead and " (exited)" or "")
end

function TerminalView:_compute_grid()
  local cw = style.code_font:get_width("m")
  local ch = style.code_font:get_height()
  self.cell_w, self.cell_h = math.max(1, cw), math.max(1, ch)
  local pad_x, pad_y = style.padding.x, style.padding.y
  local cols = math.max(20, math.floor((self.size.x - pad_x * 2) / self.cell_w))
  local rows = math.max(4,  math.floor((self.size.y - pad_y * 2) / self.cell_h))
  if cols ~= self.cols or rows ~= self.rows then
    self.cols, self.rows = cols, rows
    self.vt:resize(rows, cols)
    if self.pty then self.pty:resize(cols, rows) end
  end
end

function TerminalView:update()
  TerminalView.super.update(self)
  if self.size.x > 0 and self.size.y > 0 then self:_compute_grid() end

  -- Clamp the target offset to the available scrollback range. Has to happen
  -- here (not only on input) because resizing or new scrollback lines can
  -- change the max between frames.
  local ch = self.cell_h
  local max_px = (self.vt and self.vt:get_scrollback_count() or 0) * ch
  if self.scroll_target_px < 0 then self.scroll_target_px = 0 end
  if self.scroll_target_px > max_px then self.scroll_target_px = max_px end

  -- Once we've caught up to the (raw, unsnapped) target, nudge the target to
  -- the nearest row boundary so the resting position always sits on a row.
  -- The nudge is small (< cell_h / 2) so move_towards animates the final
  -- snap smoothly instead of teleporting.
  if math.abs(self.scroll_offset_px - self.scroll_target_px) < 0.5 then
    local snapped = math.floor(self.scroll_target_px / ch + 0.5) * ch
    self.scroll_target_px = snapped
  end

  self:move_towards(self, "scroll_offset_px", self.scroll_target_px, 0.3)

  local t = math.floor(system.get_time() * 2)
  if t ~= self._cursor_t then
    self._cursor_t = t
    self.cursor_visible = not self.cursor_visible
    core.redraw = true
  end
end

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

  -- scroll_math handles the layout: which scrollback / live rows to draw,
  -- and at what y-offset, given the animated pixel offset. See
  -- data/plugins/terminal/scroll_math.lua for the math + the spec file for
  -- the regression assertions that pin down its behavior.
  local L = scroll_math.layout(self.scroll_offset_px or 0, ch, self.rows)

  core.push_clip_rect(x0, y0, self.cols * cw, self.rows * ch)

  local sel_sr, sel_sc, sel_er, sel_ec = self:_sel_normalized()

  for i = 0, L.count - 1 do
    local row_y = y0 + L.y(i)
    local src_row = L.src(i)
    local run_start, run_bg = 0, nil
    local cells = {}
    for c = 0, self.cols - 1 do
      local cell = self.vt:get_cell(src_row, c) or {}
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

    -- Selection highlight: drawn after cell backgrounds, before glyphs, so
    -- the selection color overrides any ANSI bg but text on top stays
    -- legible.
    if sel_sr and src_row >= sel_sr and src_row <= sel_er then
      local lo = (src_row == sel_sr) and sel_sc or 0
      local hi = (src_row == sel_er) and sel_ec or self.cols
      if hi > lo then
        renderer.draw_rect(x0 + lo * cw, row_y, (hi - lo) * cw, ch, style.selection)
      end
    end

    for c = 0, self.cols - 1 do
      local cell = cells[c]
      if cell and cell.ch and cell.ch ~= " " and cell.ch ~= "" then
        local fg = as_color(cell.fg) or style.text
        renderer.draw_text(style.code_font, cell.ch,
                           x0 + c * cw, row_y, fg)
      end
    end
  end

  -- Only draw the cursor when we're tracking live output. Use the same
  -- fractional shift so the cursor stays glued to its cell mid-animation.
  if L.int_off == 0 and L.frac == 0 and self.cursor_visible and not self.dead then
    local cr, cc = self.vt:get_cursor()
    if cr and cc and cr < self.rows and cc < self.cols then
      renderer.draw_rect(x0 + cc * cw, y0 + cr * ch, cw, ch, style.caret)
    end
  end

  core.pop_clip_rect()
end

function TerminalView:on_mouse_wheel(y)
  -- Match DocView: positive y (wheel/fingers up) reveals content above —
  -- i.e. moves further into scrollback. The target is in raw pixels and
  -- accumulates without quantizing here, so a trackpad's many small events
  -- compose naturally instead of each one snapping a full row. update()
  -- handles the "stick to a row when at rest" part.
  self.scroll_target_px = self.scroll_target_px + y * config.mouse_wheel_scroll
end

function TerminalView:on_text_input(text)
  if not self.vt or not self.pty then return end
  -- Typing clears any active selection (matches editor / standard terminal UX).
  self.sel = nil
  self.scroll_target_px = 0
  self.scroll_offset_px = 0
  for _, cp in utf8_iter(text) do
    self.vt:keyboard_unichar(cp, 0)
  end
  local out = self.vt:output_read()
  if out ~= "" then self.pty:write(out) end
end

-- ── Selection ────────────────────────────────────────────────────────────
--
-- Selection is stored in vterm "src_row" coordinates: 0..rows-1 are the live
-- screen, negative rows index scrollback (matching vt:get_cell). This is the
-- same coord space the draw loop already uses, so highlight rects line up
-- with the chars under them. Selection visually drifts as new output pushes
-- lines into scrollback — acceptable for the common "copy what's on screen"
-- case; tracking absolute line numbers would require a counter in vterm.c.

function TerminalView:_mouse_to_cell(x, y)
  local x0 = self.position.x + style.padding.x
  local y0 = self.position.y + style.padding.y
  local cw, ch = self.cell_w, self.cell_h
  local px = self.scroll_offset_px or 0
  local int_off = math.floor(px / ch)
  local frac    = px - int_off * ch
  local col = math.floor((x - x0) / cw)
  local row = math.floor((y - y0 - frac) / ch) - int_off
  if col < 0 then col = 0 end
  if col > self.cols then col = self.cols end
  return row, col
end

-- Returns normalized (sr,sc,er,ec) with start ≤ end in reading order, or nil
-- if there's no selection or it's empty.
function TerminalView:_sel_normalized()
  local s = self.sel
  if not s then return nil end
  local sr, sc, er, ec = s.sr, s.sc, s.er, s.ec
  if er < sr or (er == sr and ec < sc) then
    sr, sc, er, ec = er, ec, sr, sc
  end
  if sr == er and sc == ec then return nil end
  return sr, sc, er, ec
end

function TerminalView:has_selection()
  return self:_sel_normalized() ~= nil
end

function TerminalView:clear_selection()
  self.sel = nil
  core.redraw = true
end

function TerminalView:get_selected_text()
  local sr, sc, er, ec = self:_sel_normalized()
  if not sr then return "" end
  local rows = {}
  for r = sr, er do
    local lo = (r == sr) and sc or 0
    local hi = (r == er) and ec or self.cols
    local line = {}
    for c = lo, hi - 1 do
      local cell = self.vt:get_cell(r, c)
      if cell and cell.width and cell.width > 0 then
        line[#line + 1] = cell.ch or " "
      end
    end
    local s = table.concat(line):gsub(" +$", "")
    rows[#rows + 1] = s
  end
  return table.concat(rows, "\n")
end

function TerminalView:on_mouse_pressed(button, x, y, clicks)
  if TerminalView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  if button ~= "left" then return end
  local r, c = self:_mouse_to_cell(x, y)
  self.sel = { sr = r, sc = c, er = r, ec = c, dragging = true }
  core.redraw = true
  return true
end

function TerminalView:on_mouse_moved(x, y, dx, dy)
  TerminalView.super.on_mouse_moved(self, x, y, dx, dy)
  if self.sel and self.sel.dragging then
    local r, c = self:_mouse_to_cell(x, y)
    self.sel.er, self.sel.ec = r, c
    core.redraw = true
  end
end

function TerminalView:on_mouse_released(button, x, y)
  TerminalView.super.on_mouse_released(self, button, x, y)
  if self.sel then
    self.sel.dragging = false
    -- A bare click with no drag — no real selection, drop it.
    if not self:has_selection() then self.sel = nil end
  end
end

-- ── BottomPanelView (container with tab strip) ────────────────────────────

local BottomPanelView = View:extend()

function BottomPanelView:new()
  BottomPanelView.super.new(self)
  self.terminals  = {}
  self.active_idx = 0
  self.size.y     = 0
  self.target_y   = 0
  self.cursor     = "arrow"
end

function BottomPanelView:get_name()
  return "Terminal"
end

function BottomPanelView:_tab_height()
  return style.font:get_height() + style.padding.y * 2
end

function BottomPanelView:get_active_terminal()
  return self.terminals[self.active_idx]
end

function BottomPanelView:add_terminal()
  local t = TerminalView()
  table.insert(self.terminals, t)
  self.active_idx = #self.terminals
  return t
end

function BottomPanelView:close_terminal(idx)
  idx = idx or self.active_idx
  local t = self.terminals[idx]
  if not t then return end
  t:close()
  table.remove(self.terminals, idx)
  if self.active_idx > #self.terminals then
    self.active_idx = #self.terminals
  end
  if #self.terminals == 0 then self.target_y = 0 end
end

function BottomPanelView:is_visible()
  return self.target_y > 0
end

function BottomPanelView:show()
  if #self.terminals == 0 then self:add_terminal() end
  self.target_y = math.floor(config.terminal_panel_height * SCALE)
end

function BottomPanelView:hide()
  self.target_y = 0
end

function BottomPanelView:toggle()
  if self:is_visible() then self:hide() else self:show() end
end

function BottomPanelView:_tab_rect(i)
  local tw = math.min(style.tab_width, math.ceil(self.size.x / math.max(1, #self.terminals)))
  local h  = self:_tab_height()
  return self.position.x + (i - 1) * tw, self.position.y, tw, h
end

function BottomPanelView:_tab_at(x, y)
  if #self.terminals == 0 then return nil end
  local tx, ty, tw, th = self:_tab_rect(1)
  if y < ty or y >= ty + th then return nil end
  if x < tx or x >= tx + tw * #self.terminals then return nil end
  return math.floor((x - tx) / tw) + 1
end

function BottomPanelView:_position_active(t)
  if not t then return end
  local th = self:_tab_height()
  t.position.x = self.position.x
  t.position.y = self.position.y + th
  t.size.x     = self.size.x
  t.size.y     = math.max(0, self.size.y - th)
end

function BottomPanelView:update()
  self:move_towards(self.size, "y", self.target_y)
  local t = self:get_active_terminal()
  if t then
    self:_position_active(t)
    t:update()
  end
  BottomPanelView.super.update(self)
end

function BottomPanelView:draw()
  if self.size.y < 1 then return end
  self:draw_background(style.background)

  -- Tab strip
  local _, ty, _, th = self:_tab_rect(1)
  local ds = style.divider_size
  core.push_clip_rect(self.position.x, ty, self.size.x, th)
  renderer.draw_rect(self.position.x, ty, self.size.x, th, style.background2)
  renderer.draw_rect(self.position.x, ty + th - ds, self.size.x, ds, style.divider)

  for i, term in ipairs(self.terminals) do
    local x, y, w, h = self:_tab_rect(i)
    local text = term:get_name()
    local color = style.dim
    if i == self.active_idx then
      color = style.text
      renderer.draw_rect(x, y, w, h, style.background)
      renderer.draw_rect(x + w, y, ds, h, style.divider)
      renderer.draw_rect(x - ds, y, ds, h, style.divider)
    end
    if i == self.hovered_tab then color = style.text end
    core.push_clip_rect(x, y, w, h)
    local tx, tw = x + style.padding.x, w - style.padding.x * 2
    local align = style.font:get_width(text) > tw and "left" or "center"
    common.draw_text(style.font, color, text, align, tx, y, tw, h)
    core.pop_clip_rect()
  end
  core.pop_clip_rect()

  -- Active terminal content
  local t = self:get_active_terminal()
  if t and t.size.y > 0 then
    core.push_clip_rect(t.position.x, t.position.y, t.size.x, t.size.y)
    t:draw()
    core.pop_clip_rect()
  end
end

function BottomPanelView:on_mouse_moved(x, y, dx, dy)
  self.hovered_tab = self:_tab_at(x, y)
  local t = self:get_active_terminal()
  if t then t:on_mouse_moved(x, y, dx, dy) end
end

function BottomPanelView:on_mouse_pressed(button, x, y, clicks)
  local idx = self:_tab_at(x, y)
  if idx then
    if button == "middle" then
      self:close_terminal(idx)
    else
      self.active_idx = idx
    end
    return true
  end
  -- Click below the tab strip → forward to the active terminal so it can
  -- start a selection. Without this the click would do nothing and any
  -- existing selection would persist invisibly until the next keystroke.
  local t = self:get_active_terminal()
  if t and y >= t.position.y then
    return t:on_mouse_pressed(button, x, y, clicks)
  end
end

function BottomPanelView:on_mouse_released(button, x, y)
  local t = self:get_active_terminal()
  if t then t:on_mouse_released(button, x, y) end
end

function BottomPanelView:on_text_input(text)
  local t = self:get_active_terminal()
  if t then t:on_text_input(text) end
end

function BottomPanelView:on_mouse_wheel(y)
  local t = self:get_active_terminal()
  if t then t:on_mouse_wheel(y) end
end

-- ── Singleton + integration ──────────────────────────────────────────────

local panel = BottomPanelView()

-- Install the panel as a locked split between the editor and the
-- command/status views. core.root_view.root_node.a is the editor leaf at
-- this point; splitting it "down" puts the panel just below it. Node:split
-- already restores focus to whatever was active pre-split (the editor leaf
-- view), so no manual focus fix-up is needed here — and forcing one would
-- send later plugins (treeview, cclog) into the locked panel node.
core.root_view.root_node.a:split("down", panel, true)

-- Intercept the global keymap dispatch so that when the panel (or one of
-- its terminals) is focused, key events go through libvterm instead of
-- running editor commands. The toggle binding itself still resolves first
-- via prev_on_key_pressed -> command lookup, so ctrl+` keeps working.
-- macos_keys.lua rewrites "left gui"/"left command" → "left ctrl" so the
-- editor's Ctrl-based bindings work with the platform-native Cmd key. That
-- conflation is wrong for the terminal: Cmd+C must still copy at the
-- editor level, while real Ctrl+C must reach the shell as ^C. Track the
-- *physical* Ctrl key here, before delegating to macos_keys.
local real_ctrl = false

local function is_modifier_key(k)
  return k == "left ctrl"    or k == "right ctrl"
      or k == "left alt"     or k == "right alt"
      or k == "left shift"   or k == "right shift"
      or k == "left gui"     or k == "right gui"
      or k == "left meta"    or k == "right meta"
      or k == "left command" or k == "right command"
end

local prev_on_key_pressed  = keymap.on_key_pressed
local prev_on_key_released = keymap.on_key_released

function keymap.on_key_pressed(k)
  if k == "left ctrl" or k == "right ctrl" then real_ctrl = true end

  local v = core.active_view
  local term = (v == panel) and panel:get_active_terminal() or nil
  if not term or not term.pty or not term.vt then
    return prev_on_key_pressed(k)
  end

  -- Modifier-only events: defer so macos_keys/keymap can update modkeys.
  if is_modifier_key(k) then return prev_on_key_pressed(k) end

  -- Panel toggle / new-tab keep working from inside the terminal regardless
  -- of platform; Ctrl+` as a control byte (NUL) is useless to the shell.
  if k == "`" and keymap.modkeys.ctrl then
    return prev_on_key_pressed(k)
  end

  -- Cmd-as-Ctrl (Mac): run editor commands rather than send a control byte.
  -- The presence of modkeys.ctrl without real_ctrl uniquely identifies it.
  if keymap.modkeys.ctrl and not real_ctrl then
    return prev_on_key_pressed(k)
  end

  -- Shell-essential keys (Enter, arrows, …) always go to vterm.
  local sk = shell_keys[k]
  if sk then
    term.scroll_target_px = 0; term.scroll_offset_px = 0
    term.vt:keyboard_key(sk, current_mods())
    local out = term.vt:output_read()
    if out ~= "" then term.pty:write(out) end
    return true
  end

  -- Contested keys (F-keys): editor binding wins if one fires; otherwise
  -- forward to vterm so TUIs running inside the shell still see them.
  local ck = contested_keys[k]
  if ck then
    if try_editor_binding(k) then return true end
    term.scroll_target_px = 0; term.scroll_offset_px = 0
    term.vt:keyboard_key(ck, current_mods())
    local out = term.vt:output_read()
    if out ~= "" then term.pty:write(out) end
    return true
  end

  -- Real Ctrl + single char → editor binding wins if any predicate fires
  -- (terminal:copy with a selection on ctrl+c, ctrl+shift+c on Linux/Win),
  -- otherwise forward as a control sequence so Ctrl+C/D/Z still reach the
  -- shell.
  if real_ctrl and #k == 1 then
    if try_editor_binding(k) then return true end
    term.scroll_target_px = 0; term.scroll_offset_px = 0
    term.vt:keyboard_unichar(k:byte(), current_mods())
    local out = term.vt:output_read()
    if out ~= "" then term.pty:write(out) end
    return true
  end

  return prev_on_key_pressed(k)
end

function keymap.on_key_released(k)
  if k == "left ctrl" or k == "right ctrl" then real_ctrl = false end
  return prev_on_key_released(k)
end

-- ── Commands & keymap ────────────────────────────────────────────────────

command.add(nil, {
  ["terminal:toggle"] = function()
    if panel:is_visible() then
      panel:hide()
      if core.last_active_view and core.last_active_view ~= panel then
        core.set_active_view(core.last_active_view)
      end
    else
      panel:show()
      core.set_active_view(panel)
    end
  end,
  ["terminal:new-tab"] = function()
    panel:add_terminal()
    if not panel:is_visible() then panel:show() end
    core.set_active_view(panel)
  end,
  ["terminal:close-tab"] = function()
    panel:close_terminal()
    if #panel.terminals == 0 then
      if core.last_active_view and core.last_active_view ~= panel then
        core.set_active_view(core.last_active_view)
      end
    end
  end,
  ["terminal:next-tab"] = function()
    if #panel.terminals == 0 then return end
    panel.active_idx = (panel.active_idx % #panel.terminals) + 1
  end,
  ["terminal:prev-tab"] = function()
    if #panel.terminals == 0 then return end
    panel.active_idx = ((panel.active_idx - 2) % #panel.terminals) + 1
  end,
})

-- Predicated commands: only fire when the panel is the active view so they
-- can be bound to the same strokes as the editor's doc:* equivalents and
-- fall through when the editor is focused (keymap.add prepends).
-- Bracketed-paste-aware: keyboard_start_paste/end_paste emit \e[200~..\e[201~
-- iff the shell has DECSET 2004 on (bash/zsh/fish all do by default for
-- interactive sessions), letting it accept multi-line input without executing
-- each line on the embedded newline. With bracketed paste off, clipboard text
-- is written raw, so embedded newlines still act as Enter.
command.add(function() return core.active_view == panel end, {
  ["terminal:paste"] = function()
    local term = panel:get_active_terminal()
    if not term or not term.pty then return end
    local text = system.get_clipboard():gsub("\r\n", "\n"):gsub("\r", "\n")
    term.vt:keyboard_start_paste()
    local pre = term.vt:output_read()
    if pre ~= "" then term.pty:write(pre) end
    term.pty:write(text)
    term.vt:keyboard_end_paste()
    local post = term.vt:output_read()
    if post ~= "" then term.pty:write(post) end
  end,
})

-- ctrl+c is overloaded with ^C (SIGINT). Predicate gates on an active
-- selection so a bare Ctrl+C in the shell still interrupts, while Cmd+C
-- (Mac) and Ctrl+Shift+C (Linux/Win terminal convention) copy when there's
-- something selected.
command.add(function()
  local t = panel:get_active_terminal()
  return core.active_view == panel and t and t:has_selection()
end, {
  ["terminal:copy"] = function()
    local term = panel:get_active_terminal()
    if not term then return end
    local text = term:get_selected_text()
    if text ~= "" then system.set_clipboard(text) end
    term:clear_selection()
  end,
})

keymap.add {
  ["ctrl+`"]       = "terminal:toggle",
  ["ctrl+shift+`"] = "terminal:new-tab",
  ["ctrl+v"]       = "terminal:paste",
  ["ctrl+c"]       = "terminal:copy",
  ["ctrl+shift+c"] = "terminal:copy",
}

return { panel = panel, TerminalView = TerminalView }
