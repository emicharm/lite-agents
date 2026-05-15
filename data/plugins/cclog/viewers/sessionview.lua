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
local util   = require "plugins.cclog.util"

local SessionView = View:extend()

math.randomseed(os.time())

-- UUID v4. claude --session-id requires a valid UUID; generated client-side so
-- we know the .jsonl path before claude has created it.
local function uuid_v4()
  local function hexn(n)
    local s = ""
    for _ = 1, n do s = s .. string.format("%x", math.random(0, 15)) end
    return s
  end
  return string.format("%s-%s-4%s-%x%s-%s",
    hexn(8), hexn(4), hexn(3),
    8 + math.random(0, 3), hexn(3), hexn(12))
end

local function shquote(s)
  return "'" .. (s or ""):gsub("'", "'\\''") .. "'"
end

local function find_unlocked_leaf(n)
  if not n then return nil end
  if n.type == "leaf" then return (not n.locked) and n or nil end
  return find_unlocked_leaf(n.a) or find_unlocked_leaf(n.b)
end

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

-- ── Markdown ───────────────────────────────────────────────────────────────
--
-- A small markdown-flavoured parser: `code`, **bold**, *italic*, ATX headers,
-- and fenced ``` code blocks. Anything else falls through as plain text.
--
-- Pipeline: parse_markdown(text) → blocks → wrap_blocks(blocks, max_w) →
-- visual lines, each a list of {text, style} segments. Style names line up
-- with what _draw_seg consumes below.

local function font_for(style_name)
  if style_name == "code" then return style.code_font end
  return style.font
end

-- Inline scan: returns array of {text, style}. `base` is the fallback style
-- applied to non-marked-up runs (e.g. "bold" for header lines).
local function parse_inline(s, base)
  base = base or "plain"
  local out = {}
  local function push(text, style_name)
    if text == "" then return end
    out[#out + 1] = { text = text, style = style_name }
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "`" then
      local j = s:find("`", i + 1, true)
      if j then
        push(s:sub(i + 1, j - 1), "code")
        i = j + 1
      else
        push(c, base); i = i + 1
      end
    elseif c == "*" then
      if s:sub(i + 1, i + 1) == "*" then
        local j = s:find("**", i + 2, true)
        if j then
          push(s:sub(i + 2, j - 1), "bold")
          i = j + 2
        else
          push("*", base); i = i + 1
        end
      else
        local j = s:find("*", i + 1, true)
        if j then
          push(s:sub(i + 1, j - 1), "italic")
          i = j + 1
        else
          push("*", base); i = i + 1
        end
      end
    else
      local nxt = s:find("[`*]", i)
      if nxt then
        push(s:sub(i, nxt - 1), base); i = nxt
      else
        push(s:sub(i), base); i = n + 1
      end
    end
  end
  return out
end

-- Split into per-source-line blocks. Each block is either a fenced code line
-- (rendered as-is in code style), a header (whole line bold), or a regular
-- line with inline parsing.
local function parse_markdown(src)
  local blocks = {}
  if not src or src == "" then return { { segs = {} } } end
  local in_fence = false
  for raw in (src .. "\n"):gmatch("([^\n]*)\n") do
    if raw:match("^%s*```") then
      in_fence = not in_fence
    elseif in_fence then
      blocks[#blocks + 1] = { segs = { { text = raw, style = "code" } } }
    else
      local hashes, htext = raw:match("^(#+)%s+(.*)$")
      if hashes and #hashes <= 6 then
        blocks[#blocks + 1] = { segs = parse_inline(htext, "bold") }
      else
        blocks[#blocks + 1] = { segs = parse_inline(raw, "plain") }
      end
    end
  end
  if #blocks == 0 then blocks[1] = { segs = {} } end
  return blocks
end

-- Lay out a segment list across visual lines bounded by max_w. Returns
-- { { segs = {{text, style}, …} }, … }. Overlong words are hard-broken.
local function layout_segs(segs, max_w)
  local lines = { { segs = {}, w = 0 } }
  local function newline()
    lines[#lines + 1] = { segs = {}, w = 0 }
  end
  for _, seg in ipairs(segs) do
    local f = font_for(seg.style)
    local text = seg.text
    local i = 1
    while i <= #text do
      local ws_at = text:find("%s", i)
      local tok, kind, ni
      if not ws_at then
        tok = text:sub(i); kind = "word"; ni = #text + 1
      elseif ws_at == i then
        local j = i
        while j <= #text and text:sub(j, j):match("%s") do j = j + 1 end
        tok = text:sub(i, j - 1); kind = "space"; ni = j
      else
        tok = text:sub(i, ws_at - 1); kind = "word"; ni = ws_at
      end
      i = ni
      local line = lines[#lines]
      local tw = f:get_width(tok)
      if kind == "space" then
        if line.w > 0 then
          if line.w + tw <= max_w then
            line.segs[#line.segs + 1] = { text = tok, style = seg.style }
            line.w = line.w + tw
          else
            newline()
          end
        end
      else
        if line.w + tw <= max_w then
          line.segs[#line.segs + 1] = { text = tok, style = seg.style }
          line.w = line.w + tw
        elseif tw <= max_w then
          if line.w > 0 then newline() end
          line = lines[#lines]
          line.segs[#line.segs + 1] = { text = tok, style = seg.style }
          line.w = tw
        else
          local rest = tok
          while #rest > 0 do
            local lo, hi = 1, #rest
            while lo < hi do
              local m = math.floor((lo + hi + 1) / 2)
              if f:get_width(rest:sub(1, m)) <= max_w then lo = m else hi = m - 1 end
            end
            if lo < 1 then lo = 1 end
            local part = rest:sub(1, lo)
            local pw   = f:get_width(part)
            local cur  = lines[#lines]
            if cur.w + pw > max_w and cur.w > 0 then
              newline(); cur = lines[#lines]
            end
            cur.segs[#cur.segs + 1] = { text = part, style = seg.style }
            cur.w = cur.w + pw
            rest = rest:sub(lo + 1)
            if #rest > 0 then newline() end
          end
        end
      end
    end
  end
  return lines
end

local function wrap_blocks(blocks, max_w)
  local out = {}
  if max_w <= 0 then
    for _, b in ipairs(blocks) do out[#out + 1] = { segs = b.segs } end
    return out
  end
  for _, b in ipairs(blocks) do
    if #b.segs == 0 then
      out[#out + 1] = { segs = {} }
    else
      for _, l in ipairs(layout_segs(b.segs, max_w)) do
        out[#out + 1] = l
      end
    end
  end
  if #out == 0 then out[1] = { segs = {} } end
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
  if not m._blocks then m._blocks = parse_markdown(m.summary or "") end
  m._wrap_lines = wrap_blocks(m._blocks, summary_w)
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

function SessionView:_open_session_in_terminal()
  local ok, term = pcall(require, "plugins.terminal")
  if not ok or not term or not term.panel then
    core.error("cclog: terminal plugin unavailable")
    return
  end
  local id  = self.session and self.session.id
  local cwd = self.session and self.session.cwd
  if not id or id == "" then
    core.error("cclog: no session id")
    return
  end
  local cmd
  if cwd and cwd ~= "" then
    cmd = string.format(
      "cd %s && claude --dangerously-skip-permissions --resume %s",
      shquote(cwd), shquote(id))
  else
    cmd = string.format(
      "claude --dangerously-skip-permissions --resume %s", shquote(id))
  end
  term.panel:add_terminal(cmd)
  if not term.panel:is_visible() then term.panel:show() end
  core.set_active_view(term.panel)
end

-- Start a fresh claude session. We pre-allocate a UUID via --session-id so the
-- target .jsonl path is known up front; the SessionView's tail loop will pick
-- the file up the moment claude writes the first record.
function SessionView:_new_claude_session()
  local cwd = self.session and self.session.cwd
  if not cwd or cwd == "" then
    core.error("cclog: no cwd for new session")
    return
  end
  local term_ok, term = pcall(require, "plugins.terminal")
  if not term_ok or not term or not term.panel then
    core.error("cclog: terminal plugin unavailable")
    return
  end

  local id = uuid_v4()
  local home = os.getenv("HOME") or ""
  local enc = util.encode_claude_cwd(cwd)
  local path = home .. "/.claude/projects/" .. enc .. "/" .. id .. ".jsonl"

  local new_session = {
    id      = id,
    path    = path,
    source  = "claude",
    last_dt = os.time(),
    cwd     = cwd,
    title   = "(new session)",
  }

  local v = SessionView(new_session)
  local node = core.root_view:get_active_node()
  if not node or node.locked then
    node = find_unlocked_leaf(core.root_view.root_node)
  end
  if not node then
    core.error("cclog: no node available for new session view")
    return
  end
  node:add_view(v)

  local cmd = string.format(
    "cd %s && claude --dangerously-skip-permissions --session-id %s",
    shquote(cwd), shquote(id))
  term.panel:add_terminal(cmd)
  if not term.panel:is_visible() then term.panel:show() end
end

local function point_in(r, x, y)
  return r and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h
end

function SessionView:on_mouse_moved(x, y, dx, dy)
  SessionView.super.on_mouse_moved(self, x, y, dx, dy)
  if self.dragging_scrollbar then self._was_at_bottom = false end
  local oh = point_in(self._open_btn_rect, x, y)
  local nh = point_in(self._new_btn_rect,  x, y)
  if oh ~= self._open_btn_hovered or nh ~= self._new_btn_hovered then
    self._open_btn_hovered = oh
    self._new_btn_hovered  = nh
    self.cursor = (oh or nh) and "hand" or nil
    core.redraw = true
  end
end

function SessionView:on_mouse_pressed(button, x, y, clicks)
  if SessionView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  if point_in(self._open_btn_rect, x, y) then
    self:_open_session_in_terminal()
    return true
  end
  if point_in(self._new_btn_rect, x, y) then
    self:_new_claude_session()
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

-- Tints for markdown styles. No bold/italic faces are bundled, so bold is
-- faked by double-striking and italic gets a slight palette shift.
local col_md_code   = rgb "#7aa2f7"
local col_md_italic = rgb "#bb9af7"

-- base_color: overrides the per-style palette for the whole row. Used for
-- subdued kinds (tool_use, tool_result) so they don't compete visually with
-- user/assistant text.
function SessionView:_draw_seg(seg, x, y, base_color)
  local f = font_for(seg.style)
  local color
  if base_color then
    color = base_color
  elseif seg.style == "code"   then color = col_md_code
  elseif seg.style == "italic" then color = col_md_italic
  elseif seg.style == "bold"   then color = style.accent
  else color = style.text end
  local nx = renderer.draw_text(f, seg.text, x, y, color)
  if seg.style == "bold" then
    renderer.draw_text(f, seg.text, x + 1, y, color)
    nx = nx + 1
  end
  return nx
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

  -- Buttons (rightmost: "open session", then "new session" to its left).
  local btn_pad = math.floor(8 * SCALE)
  local btn_h   = h - math.floor(8 * SCALE)
  local btn_y   = y + (h - btn_h) / 2
  local cursor_x = right - tw - pad * 2

  local function place_button(label, hovered)
    local lw = style.font:get_width(label)
    local bw = lw + btn_pad * 2
    local bx = cursor_x - bw
    cursor_x = bx - math.floor(6 * SCALE)
    local px = math.max(1, math.floor(SCALE))
    local bg = hovered and style.background or col_chip_bg
    renderer.draw_rect(bx, btn_y, bw, btn_h, bg)
    renderer.draw_rect(bx, btn_y, bw, px, style.divider)
    renderer.draw_rect(bx, btn_y + btn_h - px, bw, px, style.divider)
    renderer.draw_rect(bx, btn_y, px, btn_h, style.divider)
    renderer.draw_rect(bx + bw - px, btn_y, px, btn_h, style.divider)
    common.draw_text(style.font, hovered and style.accent or style.text,
                     label, "center", bx, btn_y, bw, btn_h)
    return { x = bx, y = btn_y, w = bw, h = btn_h }
  end

  self._open_btn_rect = place_button("▶ open session", self._open_btn_hovered)
  self._new_btn_rect  = place_button("+ new session",  self._new_btn_hovered)
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

  -- Wrapped summary column (markdown-aware).
  local sx, _ = self:_summary_geometry()
  local lines = self:_wrap_summary(m)
  local ly = cy
  local fh = style.font:get_height()
  local base_color
  if m.kind == "tool_use" or m.kind == "tool_result" then
    base_color = style.dim
  end
  for _, line in ipairs(lines) do
    local lx = x + sx
    for _, seg in ipairs(line.segs) do
      lx = self:_draw_seg(seg, lx, ly, base_color)
    end
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
