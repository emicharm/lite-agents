-- cclog: a unified viewer for Claude / Codex / Copilot agent sessions.
--
-- Docks a sessions sidebar on the left edge of the editor; clicking a
-- session opens it in a new tab as a SessionView. Sessions are grouped by
-- cwd so the same project across all three agents shows up as one entry.

local core    = require "core"
local common  = require "core.common"
local style   = require "core.style"
local config  = require "core.config"
local command = require "core.command"
local keymap  = require "core.keymap"

local SessionsSidebar = require "plugins.cclog.viewers.sidebar"
local icons           = require "plugins.cclog.icons"

icons.load_all()

local sidebar = SessionsSidebar()

-- Dock the sidebar on the left side of the editor.
local node = core.root_view:get_active_node()
node:split("left", sidebar, true)

sidebar:start_background_thread()

-- Commands -------------------------------------------------------------------

command.add(nil, {
  ["cclog:toggle"] = function()
    sidebar.visible = not sidebar.visible
  end,
  ["cclog:refresh"] = function()
    sidebar:refresh()
  end,
  -- system.exec already backgrounds the launched process; quitting after
  -- it returns leaves the freshly-spawned lite running.
  ["core:restart"] = function()
    local parts = { string.format("%q", EXEFILE) }
    for i = 2, #ARGS do
      parts[#parts + 1] = string.format("%q", ARGS[i])
    end
    system.exec(table.concat(parts, " "))
    core.quit(true)
  end,
})

keymap.add {
  ["f6"]           = "cclog:toggle",
  ["ctrl+shift+e"] = "cclog:toggle",  -- backup if F6 is bound by the user
  ["shift+f6"]     = "cclog:refresh",
  ["f5"]           = "core:restart",
}

-- RootView:open_doc — with two locked side-docks, lite's built-in fallback
-- (try last_active_view) isn't enough: if the user clicks cclog, then clicks
-- a file in treeview, both `active` and `last_active` are locked and the
-- core assertion fires. Walk the tree for any non-locked leaf instead.

local RootView = require "core.rootview"

local function any_unlocked_leaf(n)
  if not n then return nil end
  if n.type == "leaf" then
    return (not n.locked) and n or nil
  end
  return any_unlocked_leaf(n.a) or any_unlocked_leaf(n.b)
end

local prev_open_doc = RootView.open_doc
function RootView:open_doc(doc)
  local node = self:get_active_node()
  if node and node.locked then
    local target = any_unlocked_leaf(self.root_node)
    if target then core.set_active_view(target.active_view) end
  end
  return prev_open_doc(self, doc)
end

-- Drag-to-resize on the sidebar's right edge -------------------------------

local function near_edge(x)
  if not sidebar.visible then return false end
  local edge = sidebar.position.x + sidebar.size.x
  return math.abs(x - edge) <= style.divider_size
end

local prev_mp = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and near_edge(x) then
    self.cclog_resizing = true
    return
  end
  prev_mp(self, button, x, y, clicks)
end

local prev_mr = RootView.on_mouse_released
function RootView:on_mouse_released(...)
  if self.cclog_resizing then
    self.cclog_resizing = false
    return
  end
  prev_mr(self, ...)
end

local prev_mm = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  if self.cclog_resizing then
    -- sidebar is on the left: dragging right (dx > 0) grows it.
    local min_w = 80 * SCALE
    local max_w = self.size.x - 200 * SCALE
    config.cclog_sidebar_size = common.clamp(
      config.cclog_sidebar_size + dx, min_w, max_w)
    sidebar.size.x = config.cclog_sidebar_size
    return
  end
  prev_mm(self, x, y, dx, dy)
  if near_edge(x) then
    system.set_cursor("sizeh")
  end
end
