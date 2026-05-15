-- beads/sidebar.lua
--
-- Right-docked read-only Tasks sidebar listing this project's open `bd`
-- issues. Tier 1: no writes, no detail view. Refresh runs in a coroutine so
-- io.popen blocking doesn't stall the editor.

local core   = require "core"
local common = require "core.common"
local config = require "core.config"
local style  = require "core.style"
local View   = require "core.view"
local model  = require "plugins.beads.model"

config.beads_sidebar_size = config.beads_sidebar_size or (280 * SCALE)

local BeadsSidebar = View:extend()

-- ── Style helpers ─────────────────────────────────────────────────────────

local function resolve_style(name, fallback)
  if not name then return fallback end
  local section, key = name:match("^([^%.]+)%.(.+)$")
  if section then
    local t = style[section]
    if t and t[key] then return t[key] end
  else
    if style[name] then return style[name] end
  end
  return fallback
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────

function BeadsSidebar:new()
  BeadsSidebar.super.new(self)
  self.scrollable        = true
  self.visible           = false
  self.init_size         = true
  self.hovered           = nil
  self.refreshing        = false
  self.last_project_dir  = nil
  self.was_focused       = true
end

function BeadsSidebar:get_name() return "Tasks" end

function BeadsSidebar:get_item_height()
  return style.font:get_height() + style.padding.y
end

-- ── Background refresh ────────────────────────────────────────────────────

-- Single persistent coroutine: every 1s we check for focus regain, periodic
-- 30s timeout, or a project_dir change. When any fires, we run the bd query
-- in this same coroutine — io.popen blocks here, but the editor's other
-- threads still run between yields.
function BeadsSidebar:start_background_thread()
  local self_ref = self
  core.add_thread(function()
    local last_auto = 0
    while true do
      local now = system.get_time()
      local focused = system.window_has_focus()
      local focus_regained  = focused and not self_ref.was_focused
      local periodic_due    = now - last_auto > 30
      local project_changed = core.project_dir ~= self_ref.last_project_dir

      if focus_regained or periodic_due or project_changed then
        self_ref.refreshing = true
        core.redraw = true
        model.refresh_sync(core.project_dir)
        coroutine.yield()
        self_ref.last_project_dir = core.project_dir
        self_ref.refreshing = false
        last_auto = now
        core.redraw = true
      end
      self_ref.was_focused = focused
      coroutine.yield(1.0)
    end
  end, self)
end

-- One-shot manual refresh — separate thread so we don't have to wake the
-- sleeping background coroutine.
function BeadsSidebar:request_refresh()
  if self.refreshing then return end
  local self_ref = self
  core.add_thread(function()
    self_ref.refreshing = true
    core.redraw = true
    model.refresh_sync(core.project_dir)
    self_ref.refreshing = false
    core.redraw = true
  end)
end

-- ── Layout iteration ──────────────────────────────────────────────────────

function BeadsSidebar:_header_height()
  return style.font:get_height() + style.padding.y * 2
end

function BeadsSidebar:_each_row()
  return coroutine.wrap(function()
    local ox, oy = self:get_content_offset()
    local w = self.size.x
    local rh = self:get_item_height()
    local hh = self:_header_height()

    local y = oy
    coroutine.yield("header", nil, ox, y, w, hh)
    y = y + hh

    if model.state.workspace == nil and model.state.ready then
      coroutine.yield("noworkspace", nil, ox, y, w, rh)
      return
    end
    if model.state.error and model.state.error ~= "no_workspace" then
      coroutine.yield("error", model.state.error, ox, y, w, rh)
      y = y + rh
    end

    local rows = model.group_tree()
    if #rows == 0 and model.state.ready and not model.state.error then
      coroutine.yield("empty", nil, ox, y, w, rh)
      return
    end
    for _, r in ipairs(rows) do
      coroutine.yield("row", r, ox, y, w, rh)
      y = y + rh
    end
  end)
end

function BeadsSidebar:get_scrollable_size()
  local total = self:_header_height()
  local rh = self:get_item_height()
  if model.state.workspace == nil and model.state.ready then
    return total + rh
  end
  if model.state.error and model.state.error ~= "no_workspace" then
    total = total + rh
  end
  total = total + #model.group_tree() * rh
  return total + rh   -- bottom padding
end

-- ── Mouse ─────────────────────────────────────────────────────────────────

local function point_in(x, y, rx, ry, rw, rh)
  return x >= rx and y >= ry and x < rx + rw and y < ry + rh
end

local function refresh_button_rect(self)
  local rx = self.position.x + self.size.x - 22 * SCALE
  local ry = self.position.y + 4 * SCALE
  return rx, ry, 18 * SCALE, 18 * SCALE
end

local function chevron_x(row, x)
  return x + row.depth * style.padding.x + style.padding.x
end

local CHEVRON_HIT_W = 18

function BeadsSidebar:on_mouse_moved(px, py, ...)
  BeadsSidebar.super.on_mouse_moved(self, px, py, ...)
  self.hovered = nil
  for kind, ref, x, y, w, h in self:_each_row() do
    if point_in(px, py, x, y, w, h) then
      self.hovered = { kind = kind, ref = ref, row_x = x, row_y = y, row_w = w }
      break
    end
  end
  local rx, ry, rw, rh = refresh_button_rect(self)
  if point_in(px, py, rx, ry, rw, rh) then
    self.hovered = { kind = "refresh" }
  end
end

function BeadsSidebar:on_mouse_pressed(button, x, y, clicks)
  if BeadsSidebar.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  if not self.hovered then return end
  if self.hovered.kind == "refresh" then
    self:request_refresh()
    return true
  end
  if self.hovered.kind == "row" then
    local row = self.hovered.ref
    if row.has_children then
      local cx = chevron_x(row, self.hovered.row_x)
      if x >= cx - 4 * SCALE and x < cx + CHEVRON_HIT_W * SCALE then
        model.toggle_collapse(row.issue.id)
        return true
      end
    end
    -- Tier 1 is read-only; row body click is a no-op.
    return true
  end
end

-- ── Update / draw ─────────────────────────────────────────────────────────

function BeadsSidebar:update()
  local dest = self.visible and config.beads_sidebar_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end
  BeadsSidebar.super.update(self)
end

local function draw_priority_stripe(x, y, h, prio)
  local w = math.max(1, math.floor(3 * SCALE))
  local color = resolve_style(model.PRIORITY_STYLE[prio], style.dim)
  renderer.draw_rect(x, y, w, h, color)
end

local function draw_status_dot(x, y, h, status)
  local d = math.floor(6 * SCALE)
  local color = resolve_style(model.STATUS_COLOR[status], style.dim)
  renderer.draw_rect(x, y + (h - d) / 2, d, d, color)
end

local function ellipsize(font, text, max_w)
  if font:get_width(text) <= max_w then return text end
  local ell = "…"
  local ew = font:get_width(ell)
  local lo, hi = 1, #text
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if font:get_width(text:sub(1, mid)) + ew <= max_w then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return text:sub(1, lo) .. ell
end

function BeadsSidebar:draw()
  self:draw_background(style.background2)
  local x0, y0 = self.position.x, self.position.y
  local sw, sh = self.size.x, self.size.y
  if sw < 1 then return end

  core.push_clip_rect(x0, y0, sw, sh)
  for kind, ref, x, y, w, h in self:_each_row() do
    if kind == "header" then
      local label = "Tasks"
      common.draw_text(style.font, style.text, label, nil,
                       x + style.padding.x, y, 0, h)
      local count = #model.state.issues
      local cstr = tostring(count)
      local cw = style.font:get_width(cstr)
      common.draw_text(style.font, style.dim, cstr, nil,
                       x + w - 30 * SCALE - cw, y, 0, h)
      -- Refresh "button": a dot, drawn as a primitive so we don't depend on
      -- specific icon-font glyphs. Brighter when hovered or refreshing.
      local rx, ry, rw, rh = refresh_button_rect(self)
      local hovered = self.hovered and self.hovered.kind == "refresh"
      local active = self.refreshing or hovered
      local color = active and style.accent or style.dim
      local d = math.floor(6 * SCALE)
      renderer.draw_rect(rx + (rw - d) / 2, ry + (rh - d) / 2, d, d, color)

    elseif kind == "noworkspace" then
      local msg = "initialize beads with `bd init`"
      local mw = style.font:get_width(msg)
      common.draw_text(style.font, style.dim, msg, nil,
                       x + (w - mw) / 2, y, 0, h)

    elseif kind == "empty" then
      local msg = "no open issues"
      local mw = style.font:get_width(msg)
      common.draw_text(style.font, style.dim, msg, nil,
                       x + (w - mw) / 2, y, 0, h)

    elseif kind == "error" then
      common.draw_text(style.code_font, style.dim,
                       "bd: " .. tostring(ref), nil,
                       x + style.padding.x, y, 0, h)

    elseif kind == "row" then
      local row = ref
      local issue = row.issue
      local hovered = self.hovered
        and self.hovered.kind == "row"
        and self.hovered.ref == row
      if hovered then
        renderer.draw_rect(x, y, w, h, style.line_highlight)
      end
      local txt_color = hovered and style.accent or style.text
      local id_color  = hovered and style.accent or style.dim

      draw_priority_stripe(x, y, h, issue.priority)

      local cx = chevron_x(row, x)
      if row.has_children then
        local glyph = model.state.collapsed[issue.id] and "+" or "-"
        common.draw_text(style.icon_font, id_color, glyph, nil, cx, y, 0, h)
      elseif row.orphan then
        common.draw_text(style.code_font, id_color, "↳", nil, cx, y, 0, h)
      end
      cx = cx + style.icon_font:get_width("D")

      draw_status_dot(cx + 2 * SCALE, y, h, issue.status)
      cx = cx + 12 * SCALE

      -- Type badge (single letter, hidden if width is too tight)
      if w > 160 * SCALE then
        local badge = model.TYPE_BADGE[issue.issue_type] or "?"
        cx = common.draw_text(style.code_font, id_color, badge, nil, cx, y, 0, h)
        cx = cx + 6 * SCALE
      end

      -- ID + title
      local id_str = issue.id or ""
      cx = common.draw_text(style.code_font, id_color, id_str, nil, cx, y, 0, h)
      cx = cx + style.font:get_width("  ")

      -- "ready" marker eats a bit of right-side budget
      local right_pad = style.padding.x
      local ready = issue.status == "open"
        and (issue.dependency_count or 0) == 0
      if ready then right_pad = right_pad + 14 * SCALE end

      local avail = (x + w - right_pad) - cx
      if avail > 0 then
        local title = issue.title or ""
        common.draw_text(style.font, txt_color,
                         ellipsize(style.font, title, avail),
                         nil, cx, y, 0, h)
      end

      if ready then
        local m = "▸"
        local mw = style.font:get_width(m)
        common.draw_text(style.font, style.accent, m, nil,
                         x + w - style.padding.x - mw, y, 0, h)
      end
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

return BeadsSidebar
