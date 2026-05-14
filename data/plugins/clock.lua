-- Appends a "14 may, 0:45"-style clock to the right of the status bar.
local core = require "core"
local style = require "core.style"
local StatusView = require "core.statusview"

local months = { "jan", "feb", "mar", "apr", "may", "jun",
                 "jul", "aug", "sep", "oct", "nov", "dec" }

local function format_clock()
  local t = os.date("*t")
  return string.format("%d %s, %d:%02d", t.day, months[t.month], t.hour, t.min)
end

local prev_get_items = StatusView.get_items
function StatusView:get_items()
  local left, right = prev_get_items(self)
  table.insert(right, self.separator)
  table.insert(right, style.dim)
  table.insert(right, format_clock())
  return left, right
end

local prev_update = StatusView.update
function StatusView:update()
  local clock = format_clock()
  if clock ~= self.last_clock then
    self.last_clock = clock
    core.redraw = true
  end
  prev_update(self)
end
