-- cclog/sidebar.lua
--
-- Docked sidebar (left edge) showing one entry per project. Each project
-- expands into the sessions found across Claude/Codex/Copilot for that cwd.
-- Clicking a session opens it in a new tab as a SessionView.

local core   = require "core"
local common = require "core.common"
local style  = require "core.style"
local config = require "core.config"
local View   = require "core.view"
local data   = require "plugins.cclog.model"
local icons  = require "plugins.cclog.icons"

config.cclog_sidebar_size      = config.cclog_sidebar_size      or (260 * SCALE)
config.cclog_initial_count     = config.cclog_initial_count     or 6
config.cclog_show_more_step    = config.cclog_show_more_step    or 20
-- List of project cwd paths to hide entirely from the sidebar. Match against
-- the project's `key` (= cwd).
config.cclog_excluded_projects = config.cclog_excluded_projects or {}

local SessionView = require "plugins.cclog.viewers.sessionview"

local SessionsSidebar = View:extend()

local function rgb(hex) return { common.color(hex) } end
local col_active = rgb "#9ece6a"
local col_new    = rgb "#7aa2f7"

function SessionsSidebar:new()
  SessionsSidebar.super.new(self)
  self.scrollable = true
  self.visible    = false
  self.init_size  = true
  self.projects   = {}
  self.seen       = {}     -- session path -> true (for "new" indicator)
  self.hovered    = nil    -- { kind = "project"|"session", ref = ... }
  self.last_scan_ms = 0
  self._first_scan = true
end

function SessionsSidebar:get_name() return "Sessions" end

-- ── Scanning ──────────────────────────────────────────────────────────────

function SessionsSidebar:_merge_projects(fresh)
  -- Preserve expansion state across rescans by keying on project.key.
  local prev = {}
  for _, p in ipairs(self.projects) do prev[p.key] = p end

  local excluded = {}
  for _, k in ipairs(config.cclog_excluded_projects or {}) do
    excluded[k] = true
  end

  local out = {}
  for _, p in ipairs(fresh) do
    if not excluded[p.key] then
      local old = prev[p.key]
      if old then
        p.expanded = old.expanded
        p.show_count = old.show_count
      end
      -- Annotate new sessions for the dot indicator.
      if not self._first_scan then
        for _, s in ipairs(p.sessions) do
          if not self.seen[s.path] then s._new = true end
        end
      end
      out[#out + 1] = p
    end
  end
  for _, p in ipairs(out) do
    for _, s in ipairs(p.sessions) do self.seen[s.path] = true end
  end
  self.projects = out
  self._first_scan = false
end

function SessionsSidebar:refresh()
  self:_merge_projects(data.scan())
  core.redraw = true
end

-- A long-running coroutine that rescans every few seconds and fills in the
-- per-session model+tokens+active stats lazily (one project at a time, so a
-- big history doesn't stall the UI).
function SessionsSidebar:start_background_thread()
  local sv = self
  core.add_thread(function()
    while true do
      sv:_merge_projects(data.scan())
      core.redraw = true
      -- First pass: cheap is_active for every session (tail-read only).
      for _, p in ipairs(sv.projects) do
        for _, s in ipairs(p.sessions) do
          local info = system.get_file_info(s.path)
          if info then
            s.active = data.is_active(s.path, info.modified or 0, s.source)
          end
          coroutine.yield()
        end
        core.redraw = true
      end
      -- Second pass: full stats (model + tokens) only for expanded projects,
      -- since each one walks the full session file.
      for _, p in ipairs(sv.projects) do
        if p.expanded then
          for _, s in ipairs(p.sessions) do
            local info = system.get_file_info(s.path)
            if info then
              local st = data.stats_for(s.path, info.modified or 0, s.source)
              if st then
                s.model  = st.model  or s.model
                s.tokens = st.tokens or s.tokens
                s.active = data.is_active(s.path, info.modified or 0, s.source)
                core.redraw = true
              end
            end
            coroutine.yield()
          end
        end
      end
      coroutine.yield(30.0)
    end
  end, self)
end

-- ── Layout iteration (project rows + visible session rows) ────────────────

function SessionsSidebar:get_project_height()
  return style.font:get_height() + style.padding.y
end

function SessionsSidebar:get_session_height()
  return style.font:get_height() + style.padding.y
end

function SessionsSidebar:_each_row()
  return coroutine.wrap(function()
    local ph = self:get_project_height()
    local sh = self:get_session_height()
    local ox, oy = self:get_content_offset()
    local y = oy + style.padding.y
    local w = self.size.x
    for _, p in ipairs(self.projects) do
      coroutine.yield("project", p, ox, y, w, ph)
      y = y + ph
      if p.expanded then
        local limit = p.show_count or config.cclog_initial_count
        local shown = 0
        for _, s in ipairs(p.sessions) do
          if shown >= limit then break end
          coroutine.yield("session", s, ox, y, w, sh)
          y = y + sh
          shown = shown + 1
        end
        if #p.sessions > limit then
          coroutine.yield("show_more", p, ox, y, w, sh)
          y = y + sh
        end
      end
    end
  end)
end

function SessionsSidebar:get_scrollable_size()
  local ph = self:get_project_height()
  local sh = self:get_session_height()
  local total = style.padding.y * 2 + 28 * SCALE -- header band
  for _, p in ipairs(self.projects) do
    total = total + ph
    if p.expanded then
      local limit = p.show_count or config.cclog_initial_count
      local visible = math.min(#p.sessions, limit)
      total = total + visible * sh
      if #p.sessions > limit then total = total + sh end
    end
  end
  return total
end

local function fit_text(font, text, max_width)
  if max_width <= 0 then return "" end
  if font:get_width(text) <= max_width then return text end
  local ellipsis = "..."
  local ell_w = font:get_width(ellipsis)
  if ell_w >= max_width then return ellipsis end
  local lo, hi = 1, #text
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if font:get_width(text:sub(1, mid)) + ell_w <= max_width then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return text:sub(1, lo) .. ellipsis
end

-- ── Mouse ─────────────────────────────────────────────────────────────────

local function point_in(x, y, rx, ry, rw, rh)
  return x >= rx and y >= ry and x < rx + rw and y < ry + rh
end

function SessionsSidebar:on_mouse_moved(px, py, ...)
  SessionsSidebar.super.on_mouse_moved(self, px, py, ...)
  self.hovered = nil
  for kind, ref, x, y, w, h in self:_each_row() do
    if point_in(px, py, x, y, w, h) then
      self.hovered = { kind = kind, ref = ref }
      break
    end
  end
  -- Refresh button hit area (top-right of sidebar).
  local rx = self.position.x + self.size.x - 22 * SCALE
  local ry = self.position.y + 4 * SCALE
  if point_in(px, py, rx, ry, 18 * SCALE, 18 * SCALE) then
    self.hovered = { kind = "refresh" }
  end
end

function SessionsSidebar:on_mouse_pressed(button, x, y, clicks)
  if SessionsSidebar.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  if not self.hovered then return end
  if self.hovered.kind == "refresh" then
    self:refresh()
    return true
  elseif self.hovered.kind == "project" then
    self.hovered.ref.expanded = not self.hovered.ref.expanded
    core.redraw = true
    return true
  elseif self.hovered.kind == "session" then
    self.hovered.ref._new = false
    self:open_session(self.hovered.ref)
    return true
  elseif self.hovered.kind == "show_more" then
    local p = self.hovered.ref
    local cur = p.show_count or config.cclog_initial_count
    p.show_count = cur + config.cclog_show_more_step
    core.redraw = true
    return true
  end
end

-- Walk the node tree and return the first leaf that isn't locked. We can't
-- open into our own (locked) sidebar node, and the active node usually IS
-- our node right after the user clicks a session row.
local function first_unlocked_leaf(n)
  if not n then return nil end
  if n.type == "leaf" then
    if n.locked then return nil end
    return n
  end
  return first_unlocked_leaf(n.a) or first_unlocked_leaf(n.b)
end

-- Walk the node tree looking for an existing SessionView whose session path
-- matches `path`. Returns (node, view) on hit so the caller can re-activate
-- the tab rather than spawn a duplicate.
local function find_session_view(n, path)
  if not n then return nil end
  if n.type == "leaf" then
    for _, v in ipairs(n.views) do
      if v.session and v.session.path == path then
        return n, v
      end
    end
    return nil
  end
  local na, va = find_session_view(n.a, path)
  if na then return na, va end
  return find_session_view(n.b, path)
end

function SessionsSidebar:open_session(session)
  local existing_node, existing_view =
    find_session_view(core.root_view.root_node, session.path)
  if existing_view then
    existing_node:set_active_view(existing_view)
    self.selected = session
    return
  end
  local v = SessionView(session)
  local node = core.root_view:get_active_node()
  if not node or node.locked then
    node = first_unlocked_leaf(core.root_view.root_node)
  end
  if not node then
    core.error("cclog: no editor node available to host session view")
    return
  end
  node:add_view(v)
  self.selected = session
end

-- ── Update / draw ─────────────────────────────────────────────────────────

function SessionsSidebar:update()
  local dest = self.visible and config.cclog_sidebar_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end
  SessionsSidebar.super.update(self)
end

local function draw_dot(x, y, color)
  local d = math.floor(6 * SCALE)
  renderer.draw_rect(x, y, d, d, color)
end


function SessionsSidebar:draw()
  self:draw_background(style.background2)
  local x0, y0 = self.position.x, self.position.y
  local w = self.size.x
  local hh = 0

  core.push_clip_rect(x0, y0 + hh, w, self.size.y - hh)
  local spacing = style.font:get_width(" ") * 2

  for kind, ref, x, y, rw, rh in self:_each_row() do
    if kind == "project" then
      local hovered = (self.hovered and self.hovered.kind == "project" and self.hovered.ref == ref)
      if hovered then
        renderer.draw_rect(x, y, rw, rh, style.line_highlight)
      end
      local color = hovered and style.accent or style.text
      local cx = x + style.padding.x
      -- Folder glyph (treeview convention: "D" expanded, "d" collapsed) plus
      -- a label, both vertically centred via common.draw_text.
      local glyph = ref.expanded and "D" or "d"
      cx = common.draw_text(style.icon_font, color, glyph, nil, cx, y, 0, rh)
      cx = cx + style.padding.x

      -- Right: session count + status dot — reserve their space first so the
      -- label can be truncated to fit the remaining width.
      local right = x + rw - style.padding.x
      local count = tostring(#ref.sessions)
      local cw = style.font:get_width(count)
      local reserved = cw + 12 * SCALE + 6 * SCALE
      local label_max = right - reserved - cx - style.padding.x
      local label = fit_text(style.font, ref.label or "(unknown)", label_max)
      common.draw_text(style.font, color, label, nil, cx, y, 0, rh)
      common.draw_text(style.font, style.dim, count, nil,
                       right - cw, y, 0, rh)
      local any_active, any_new = false, false
      for _, s in ipairs(ref.sessions) do
        if s.active then any_active = true end
        if s._new   then any_new = true end
      end
      if any_active then
        draw_dot(right - cw - 12 * SCALE, y + (rh - 6 * SCALE) / 2, col_active)
      elseif any_new then
        draw_dot(right - cw - 12 * SCALE, y + (rh - 6 * SCALE) / 2, col_new)
      end
    elseif kind == "show_more" then
      local hovered = (self.hovered and self.hovered.kind == "show_more" and self.hovered.ref == ref)
      if hovered then
        renderer.draw_rect(x, y, rw, rh, style.line_highlight)
      end
      local color = hovered and style.accent or style.text
      local cx = x + style.padding.x
      local cur = ref.show_count or config.cclog_initial_count
      local step = math.min(config.cclog_show_more_step, #ref.sessions - cur)
      local label = string.format("Show %d more (%d/%d)", step, cur, #ref.sessions)
      common.draw_text(style.font, color, label, nil, cx, y, 0, rh)

    else -- session
      local selected = (self.selected == ref)
      local hovered  = (self.hovered and self.hovered.kind == "session" and self.hovered.ref == ref)
      if selected then
        renderer.draw_rect(x, y, rw, rh, style.selection)
      elseif hovered then
        renderer.draw_rect(x, y, rw, rh, style.line_highlight)
      end
      local color = (hovered or selected) and style.accent or style.text
      local indent = style.padding.x
      local cx = x + indent
      -- Provider icon (with letter fallback) at the left of the row,
      -- vertically centred against the row height.
      local icon_sz = math.floor(style.font:get_height())
      local icon_y  = y + (rh - icon_sz) / 2
      if icons.draw(ref.source, cx, icon_y, icon_sz, style.dim) then
        cx = cx + icon_sz + style.padding.x
      else
        local badge = (ref.source or "?"):sub(1, 1):upper()
        cx = common.draw_text(style.code_font, style.dim, badge,
                              nil, cx, y, 0, rh)
        cx = cx + style.padding.x
      end

      -- Title (preferred over id) — date/model are moved to the SessionView
      -- header on open, so this row stays terse.
      local raw_label = (ref.title and ref.title ~= "")
                    and ref.title
                    or (ref.id or ""):sub(1, 12)
      local right = x + rw - style.padding.x
      local label_max = right - 12 * SCALE - cx
      local label = fit_text(style.font, raw_label, label_max)
      common.draw_text(style.font, color, label, nil, cx, y, 0, rh)

      -- Status dot only (if applicable) at the right edge.
      if ref.active then
        draw_dot(right - 6 * SCALE, y + (rh - 6 * SCALE) / 2, col_active)
      elseif ref._new then
        draw_dot(right - 6 * SCALE, y + (rh - 6 * SCALE) / 2, col_new)
      end
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

return SessionsSidebar
