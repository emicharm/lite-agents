-- beads: read-only Tasks sidebar backed by the `bd` (beads) CLI.
--
-- Docks a sidebar on the right side of the editor — same side as treeview,
-- with a 3-state cycle (tree → tasks → none) on ctrl+\.

local core    = require "core"
local common  = require "core.common"
local config  = require "core.config"
local style   = require "core.style"
local command = require "core.command"
local keymap  = require "core.keymap"
local cli     = require "plugins.beads.cli"
local Sidebar = require "plugins.beads.sidebar"
local treeview = require "plugins.treeview"   -- treeview returns its View

local view = Sidebar()
local node = core.root_view:get_active_node()
node:split("right", view, true)

if not cli.available() then
  -- Stub commands so user keybindings don't fail. Sidebar stays hidden.
  command.add(nil, {
    ["beads:toggle"]  = function() core.log("bd not installed") end,
    ["beads:refresh"] = function() core.log("bd not installed") end,
  })
  return
end

view:start_background_thread()

local function set_only(which)
  treeview.visible = (which == "tree")
  view.visible     = (which == "tasks")
end

command.add(nil, {
  ["beads:toggle"]   = function() view.visible = not view.visible end,
  ["beads:refresh"]  = function() view:request_refresh() end,
  ["sidebar:cycle"]  = function()
    if not treeview.visible and not view.visible then set_only("tree")
    elseif treeview.visible                       then set_only("tasks")
    else                                                set_only("none") end
  end,
  ["sidebar:treeview-only"] = function() set_only("tree") end,
  ["sidebar:tasks-only"]    = function() set_only("tasks") end,
})

keymap.add {
  ["ctrl+\\"]    = "sidebar:cycle",
  ["ctrl+alt+1"] = "sidebar:treeview-only",
  ["ctrl+alt+2"] = "sidebar:tasks-only",
  ["ctrl+alt+r"] = "beads:refresh",
}

-- Drag-to-resize on the tasks sidebar's left edge.
local RootView = require "core.rootview"

local function near_edge(x)
  if not view.visible then return false end
  local edge = view.position.x
  return math.abs(x - edge) <= style.divider_size
end

local prev_mp = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and near_edge(x) then
    self.beads_resizing = true
    return
  end
  prev_mp(self, button, x, y, clicks)
end

local prev_mr = RootView.on_mouse_released
function RootView:on_mouse_released(...)
  if self.beads_resizing then
    self.beads_resizing = false
    return
  end
  prev_mr(self, ...)
end

local prev_mm = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  if self.beads_resizing then
    -- Sidebar is on the right; dragging left (dx < 0) grows it.
    local min_w = 120 * SCALE
    local max_w = self.size.x - 200 * SCALE
    config.beads_sidebar_size = common.clamp(
      config.beads_sidebar_size - dx, min_w, max_w)
    view.size.x = config.beads_sidebar_size
    return
  end
  prev_mm(self, x, y, dx, dy)
  if near_edge(x) then
    system.set_cursor("sizeh")
  end
end
