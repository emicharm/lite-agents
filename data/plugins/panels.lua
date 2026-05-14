-- Applies a window-edge margin equal to the inter-panel gap, so the
-- desktop background frames the entire panel tree. Also makes
-- config.gap_size / config.panel_radius the source of truth — overrides
-- in user/init.lua take effect live.
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local RootView = require "core.rootview"

local prev_update = RootView.update
function RootView:update()
  style.divider_size = common.round(config.gap_size * SCALE)
  style.panel_radius = common.round(config.panel_radius * SCALE)
  local m = style.divider_size
  self.position.x, self.position.y = m, m
  self.size.x = math.max(0, self.size.x - m * 2)
  self.size.y = math.max(0, self.size.y - m * 2)
  prev_update(self)
end
