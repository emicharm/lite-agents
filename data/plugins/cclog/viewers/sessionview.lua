-- cclog/sessionview.lua
--
-- One tab per opened session. Renders header, a type-filter bar, and a
-- scrollable list of message rows. Clicking a row toggles an inline pretty
-- JSON expand. A background coroutine first reads the file fully, then tails
-- it for appended lines.

local core   = require "core"
local common = require "core.common"
local style  = require "core.style"
local config = require "core.config"
local View   = require "core.view"
local json   = require "libraries.json"
local data   = require "plugins.cclog.model"
local icons  = require "plugins.cclog.icons"

local SessionView = View:extend()

-- Tokyo Night auxiliaries that don't have a style.* slot.
local function rgb(hex)
  return { common.color(hex) }
end
local col_user        = rgb "#9ece6a"
local col_assistant   = rgb "#7aa2f7"
local col_tool        = rgb "#ff9e64"
local col_thinking    = rgb "#bb9af7"
local col_summary     = rgb "#bb9af7"
local col_system      = rgb "#565f89"
local col_alt_row     = rgb "#1f2030"
local col_expanded    = rgb "#242636"
local col_chip_bg     = rgb "#16161e"

local function kind_color(k)
  if k == "user"        then return col_user end
  if k == "assistant"   then return col_assistant end
  if k == "tool_use"    then return col_tool end
  if k == "tool_result" then return col_tool end
  if k == "thinking"    then return col_thinking end
  if k == "summary"     then return col_summary end
  return col_system
end

-- ── Pretty JSON ────────────────────────────────────────────────────────────

local hidden_keys = {
  gitBranch=true, version=true, sessionId=true, cwd=true, entrypoint=true,
  userType=true, timestamp=true, uuid=true, requestId=true, isSidechain=true,
  parentUuid=true, id=true, parentId=true,
}

local function pretty(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "string"  then return json.encode(v) end
  if t == "number"  then return tostring(v) end
  if t == "boolean" then return tostring(v) end
  if v == nil       then return "null" end
  if t ~= "table"   then return "?" end
  -- array detection: keys are 1..#v exactly
  local is_array = (rawget(v, 1) ~= nil) or (next(v) == nil)
  if is_array then
    if #v == 0 then return "[]" end
    local parts = {}
    for _, item in ipairs(v) do
      parts[#parts + 1] = indent .. "  " .. pretty(item, indent .. "  ")
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = {}
  for k in pairs(v) do
    if type(k) == "string" and not hidden_keys[k] then keys[#keys + 1] = k end
  end
  if #keys == 0 then return "{}" end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = indent .. "  " .. json.encode(k) .. ": " .. pretty(v[k], indent .. "  ")
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function pretty_json(raw)
  local ok, obj = pcall(json.decode, raw)
  if not ok or type(obj) ~= "table" then return raw end
  return pretty(obj)
end

-- Cheap line-count helper.
local function count_lines(s)
  local n = 1
  for i = 1, #s do if s:byte(i) == 10 then n = n + 1 end end
  return n
end

-- Greedy word-wrap for plain text against a target pixel width.
-- Returns an array of lines. Words wider than max_w get hard-broken.
local function wrap_text(font, s, max_w)
  local out = {}
  if not s or s == "" then return { "" } end
  if max_w <= 0 then return { s } end
  for raw in (s .. "\n"):gmatch("([^\n]*)\n") do
    if raw == "" then
      out[#out + 1] = ""
    else
      local cur = ""
      local i = 1
      while i <= #raw do
        local j = raw:find("%s", i)
        local word
        if j then
          word = raw:sub(i, j - 1)
          i = j + 1
        else
          word = raw:sub(i)
          i = #raw + 1
        end
        if word == "" then -- run of spaces; preserve a single space
          if cur ~= "" and font:get_width(cur .. " ") <= max_w then
            cur = cur .. " "
          end
        else
          local trial = (cur == "") and word or (cur .. " " .. word)
          if font:get_width(trial) <= max_w then
            cur = trial
          else
            if cur ~= "" then out[#out + 1] = cur end
            -- hard-break if a single word doesn't fit
            while font:get_width(word) > max_w and #word > 1 do
              local lo, hi = 1, #word
              while lo < hi do
                local m = math.floor((lo + hi + 1) / 2)
                if font:get_width(word:sub(1, m)) <= max_w then
                  lo = m
                else
                  hi = m - 1
                end
              end
              if lo < 1 then lo = 1 end
              out[#out + 1] = word:sub(1, lo)
              word = word:sub(lo + 1)
            end
            cur = word
          end
        end
      end
      if cur ~= "" then out[#out + 1] = cur end
    end
  end
  if #out == 0 then out[1] = "" end
  return out
end

-- ── SessionView ────────────────────────────────────────────────────────────

function SessionView:new(session)
  SessionView.super.new(self)
  self.scrollable = true
  self.session    = session
  self.messages   = {}
  self.filter     = {}      -- kind -> bool
  self.kind_order = {}
  self.tail_off   = 0
  self.loading    = true
  self.layout     = {}      -- row index → { y, h }
  self.filter_hits = {}
  self.header_h   = 0
  self.filter_h   = 0
  self.scroll.to.y = 1e9    -- pinned to bottom until user scrolls up

  -- Default visible kinds (everything else is filtered out at load).
  self.default_visible = {
    user = true, assistant = true, tool_use = true, tool_result = true,
    thinking = true,
  }

  -- Streaming loader thread.
  local sv = self
  core.add_thread(function()
    -- Full read first.
    local msgs, off = data.read_session(session.path, session.source, 200)
    sv:_ingest(msgs)
    sv.tail_off = off
    sv.loading = false
    core.redraw = true
    -- Then tail.
    while sv.alive ~= false do
      coroutine.yield(0.15)
      local new, no = data.tail_session(session.path, session.source, sv.tail_off)
      sv.tail_off = no
      if #new > 0 then
        sv:_ingest(new)
        core.redraw = true
      end
    end
  end, sv)
end

function SessionView:try_close(do_close)
  self.alive = false
  do_close()
end

function SessionView:_note_kind(k)
  if not k or k == "" then return end
  if self.filter[k] ~= nil then return end
  self.filter[k] = self.default_visible[k] == true
  table.insert(self.kind_order, k)
  table.sort(self.kind_order)
end

function SessionView:_ingest(msgs)
  for _, m in ipairs(msgs) do
    self:_note_kind(m.kind)
    self.messages[#self.messages + 1] = m
  end
end

function SessionView:get_name()
  local s = self.session
  local base = s.title and s.title ~= "" and s.title or s.id or "(session)"
  local short = base:sub(1, 16)
  return ("cclog: %s · %s"):format(s.source, short)
end

-- ── Sizing helpers ────────────────────────────────────────────────────────

-- Geometry constants for a message row. Kept here so draw + hit-test agree.
-- The first text column is the timestamp + kind label + tokens; the second is
-- the wrapped summary, which determines the row's height.
-- Width reserved on the right side of the body for the vertical filter list.
function SessionView:_filter_panel_width()
  if #self.kind_order == 0 then return 0 end
  return math.floor(120 * SCALE)
end

function SessionView:_summary_geometry()
  local pad = style.padding.x
  local ts_w   = style.code_font:get_width("00:00:00 ")
  local kind_w = style.code_font:get_width("tool_result  ")
  local tok_w  = style.code_font:get_width("9999.9k  ")
  local summary_x = pad + ts_w + kind_w + tok_w
  local summary_w = self.size.x - summary_x - pad - self:_filter_panel_width()
  return summary_x, math.max(40, summary_w)
end

function SessionView:_wrap_summary(m)
  local _, summary_w = self:_summary_geometry()
  if m._wrap_w == summary_w and m._wrap_lines then return m._wrap_lines end
  m._wrap_lines = wrap_text(style.font, m.summary or "", summary_w)
  m._wrap_w = summary_w
  return m._wrap_lines
end

function SessionView:get_row_height(m)
  local lines = self:_wrap_summary(m)
  local n = math.max(1, #lines)
  local h = n * style.font:get_height() + style.padding.y
  if m._expanded then
    local pj = m._pretty
    if not pj then
      pj = pretty_json(m.raw)
      m._pretty = pj
    end
    local jl = count_lines(pj)
    h = h + jl * style.code_font:get_height() + style.padding.y
  end
  return h
end

function SessionView:_visible_messages()
  local out = {}
  for _, m in ipairs(self.messages) do
    if self.filter[m.kind] then out[#out + 1] = m end
  end
  return out
end

function SessionView:get_scrollable_size()
  local h = self.header_h + style.padding.y
  for _, m in ipairs(self:_visible_messages()) do
    h = h + self:get_row_height(m)
  end
  return h
end

-- ── Mouse + scroll ────────────────────────────────────────────────────────

function SessionView:_pin_to_bottom()
  -- Stay pinned at the bottom until the user scrolls up; re-engage when they
  -- scroll back to (or near) the bottom.
  local max = self:get_scrollable_size() - self.size.y
  if max < 0 then max = 0 end
  if self._was_at_bottom == nil then self._was_at_bottom = true end
  if not self._was_at_bottom and not self.dragging_scrollbar then
    local threshold = style.font:get_height() * 2
    if self.scroll.to.y >= max - threshold then
      self._was_at_bottom = true
    end
  end
  if self._was_at_bottom then
    self.scroll.to.y = max
    self.scroll.y    = max
  end
end

function SessionView:on_mouse_wheel(y)
  SessionView.super.on_mouse_wheel(self, y)
  -- Detach from bottom-pin once the user scrolls.
  self._was_at_bottom = false
end

function SessionView:on_mouse_moved(x, y, dx, dy)
  SessionView.super.on_mouse_moved(self, x, y, dx, dy)
  if self.dragging_scrollbar then self._was_at_bottom = false end
end

function SessionView:on_mouse_pressed(button, x, y, clicks)
  if SessionView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  -- Filter panel hits (vertical list on the right).
  for _, hit in ipairs(self.filter_hits) do
    if x >= hit.x and y >= hit.y and x < hit.x + hit.w and y < hit.y + hit.h then
      if hit.action == "all"  then
        for k in pairs(self.filter) do self.filter[k] = true end
      elseif hit.action == "none" then
        for k in pairs(self.filter) do self.filter[k] = false end
      else
        self.filter[hit.kind] = not self.filter[hit.kind]
      end
      core.redraw = true
      return true
    end
  end
  -- Reject clicks that landed in the filter strip but not on a checkbox.
  local body_right = self.position.x + self.size.x - self:_filter_panel_width()
  if x >= body_right then return end
  -- Row click → toggle expand.
  for _, info in ipairs(self.layout) do
    if y >= info.y and y < info.y + info.h then
      info.m._expanded = not info.m._expanded
      core.redraw = true
      return true
    end
  end
end

-- ── Update ─────────────────────────────────────────────────────────────────

function SessionView:update()
  self.header_h = style.font:get_height() + style.padding.y * 2
  self:_pin_to_bottom()
  SessionView.super.update(self)
end

-- ── Draw ───────────────────────────────────────────────────────────────────

local function draw_text_clipped(font, color, text, x, y, max_w)
  -- naïve: just draw; lite's renderer doesn't word-wrap, and overlong text
  -- is fine because the next column starts further right.
  return renderer.draw_text(font, text, x, y, color)
end

-- Header: provider icon + title + a status line (model · tokens · time + an
-- active dot) on the left; the message count is right-aligned. One row only.
function SessionView:_draw_header(x, y, w)
  local pad = style.padding.x
  local h   = self.header_h
  renderer.draw_rect(x, y, w, h, style.background2)

  local s = self.session
  local cx = x + pad
  -- Provider icon (or letter fallback).
  local icon_sz = math.floor(style.font:get_height())
  local icon_y  = y + (h - icon_sz) / 2
  if icons.draw(s.source, cx, icon_y, icon_sz, style.text) then
    cx = cx + icon_sz + pad
  else
    cx = common.draw_text(style.code_font, style.text,
                          (s.source or "?"):sub(1, 1):upper(),
                          nil, cx, y, 0, h) + pad
  end

  local label = (s.title and s.title ~= "") and s.title or (s.id or "(session)")
  cx = common.draw_text(style.font, style.text, label, nil, cx, y, 0, h)
  cx = cx + pad * 2

  -- Status crumbs: model · tokens · time · active dot.
  local parts = {}
  if s.model and s.model ~= "" then parts[#parts + 1] = data.short_model(s.model) end
  if s.tokens and s.tokens > 0  then parts[#parts + 1] = data.format_tokens(s.tokens) end
  if s.last_dt and s.last_dt > 0 then
    parts[#parts + 1] = os.date("%m-%d %H:%M", s.last_dt)
  end
  if #parts > 0 then
    cx = common.draw_text(style.code_font, style.dim,
                          table.concat(parts, " · "), nil, cx, y, 0, h)
  end
  if s.active then
    local d = math.floor(6 * SCALE)
    renderer.draw_rect(cx + 6 * SCALE, y + (h - d) / 2, d, d,
                       { common.color "#7aa2f7" })
  end

  -- Right: message count (and a loading hint if we're still ingesting).
  local total = #self.messages
  local vis   = #self:_visible_messages()
  local txt
  if self.loading then
    txt = ("loading… %d"):format(total)
  elseif vis == total then
    txt = ("%d msg"):format(total)
  else
    txt = ("%d / %d msg"):format(vis, total)
  end
  -- Reserve room on the right for the filter-panel toggle area.
  local right = x + w - pad - self:_filter_panel_width()
  local tw = style.font:get_width(txt)
  common.draw_text(style.font, style.dim, txt, nil, right - tw, y, 0, h)
end

-- Vertical filter list on the right edge of the body. Each kind gets a row
-- with a tinted checkbox; "all" / "none" sit at the bottom.
function SessionView:_draw_filter_panel(x, y, w, h)
  self.filter_hits = {}
  if w <= 0 or #self.kind_order == 0 then return end
  local pad = style.padding.x
  local row_h = style.font:get_height() + style.padding.y / 2
  renderer.draw_rect(x, y, w, h, col_chip_bg)
  -- subtle left divider
  renderer.draw_rect(x, y, math.max(1, math.floor(SCALE)), h, style.divider)

  local cy = y + pad
  for _, k in ipairs(self.kind_order) do
    local on = self.filter[k]
    local color = on and kind_color(k) or style.dim
    local mark  = on and "✓ " or "  "
    common.draw_text(style.font, color, mark .. k, nil,
                     x + pad, cy, 0, row_h)
    table.insert(self.filter_hits, {
      x = x, y = cy, w = w, h = row_h, kind = k,
    })
    cy = cy + row_h
  end
  cy = cy + pad / 2
  for _, lbl in ipairs({ "all", "none" }) do
    common.draw_text(style.font, style.text, lbl, nil,
                     x + pad, cy, 0, row_h)
    table.insert(self.filter_hits, {
      x = x, y = cy, w = w, h = row_h, action = lbl,
    })
    cy = cy + row_h
  end
end

function SessionView:_draw_row(i, m, x, y, w)
  local rh  = self:get_row_height(m)
  local pad = style.padding.x
  local bg
  if m._expanded     then bg = col_expanded
  elseif i % 2 == 0  then bg = col_alt_row end
  if bg then renderer.draw_rect(x, y, w, rh, bg) end

  local cy = y + style.padding.y / 2
  local ts = (m.ts and m.ts > 0) and os.date("%H:%M:%S", m.ts) or "        "
  renderer.draw_text(style.font, ts, x + pad, cy, style.dim)

  local ts_w   = style.code_font:get_width("00:00:00 ")
  local kind_w = style.code_font:get_width("tool_result  ")
  renderer.draw_text(style.code_font, m.kind or "?",
                     x + pad + ts_w, cy, kind_color(m.kind))

  local tok = (m.tokens and m.tokens > 0) and data.format_tokens(m.tokens) or ""
  if tok ~= "" then
    renderer.draw_text(style.code_font, tok,
                       x + pad + ts_w + kind_w, cy, style.dim)
  end

  -- Wrapped summary column.
  local sx, _ = self:_summary_geometry()
  local lines = self:_wrap_summary(m)
  local ly = cy
  local fh = style.font:get_height()
  for _, line in ipairs(lines) do
    renderer.draw_text(style.font, line, x + sx, ly, style.text)
    ly = ly + fh
  end

  if m._expanded then
    local pj = m._pretty or pretty_json(m.raw)
    m._pretty = pj
    local n = #lines
    local py = y + math.max(1, n) * fh + style.padding.y
    local px = x + pad + 16 * SCALE
    for line in (pj .. "\n"):gmatch("([^\n]*)\n") do
      renderer.draw_text(style.code_font, line, px, py, style.text)
      py = py + style.code_font:get_height()
    end
  end
  return rh
end

function SessionView:draw()
  self:draw_background(style.background)
  local x0, y0 = self.position.x, self.position.y
  local w      = self.size.x

  -- Header pinned at the top.
  self:_draw_header(x0, y0, w)

  local body_y = y0 + self.header_h
  local body_h = self.size.y - self.header_h
  local filter_w = self:_filter_panel_width()
  local body_w   = w - filter_w

  -- Messages on the left, filter panel on the right.
  local ox, oy = self:get_content_offset()
  local y = oy + self.header_h + style.padding.y / 2

  core.push_clip_rect(x0, body_y, body_w, body_h)
  self.layout = {}
  local visible = self:_visible_messages()
  for i, m in ipairs(visible) do
    local rh = self:get_row_height(m)
    if y + rh > body_y and y < y0 + self.size.y then
      self:_draw_row(i, m, ox, y, body_w)
    end
    self.layout[#self.layout + 1] = { y = y, h = rh, m = m }
    y = y + rh
  end
  core.pop_clip_rect()

  -- Right-side vertical filter panel.
  if filter_w > 0 then
    core.push_clip_rect(x0 + body_w, body_y, filter_w, body_h)
    self:_draw_filter_panel(x0 + body_w, body_y, filter_w, body_h)
    core.pop_clip_rect()
  end

  self:draw_scrollbar()
end

return SessionView
