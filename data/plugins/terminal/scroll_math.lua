-- Pure math for the terminal's fractional scrollback rendering.
--
-- The drawing loop maps a pixel scroll offset (px ≥ 0; 0 = tracking the
-- bottom, positive = scrolled up into scrollback) onto a list of source rows
-- to render, each with a sub-pixel vertical offset. Getting this wrong gives
-- the row-pop artifact where scrollback only appears when the offset crosses
-- a row boundary instead of sliding in continuously — keep the assertions in
-- spec/terminal_scroll_math_spec.lua honest if you change this file.

local M = {}

-- For a viewport of `rows` cells of height `ch` and a scroll offset of `px`
-- pixels into scrollback, returns a table describing the rows to draw:
--   count   total rows to render (rows or rows+1)
--   src(i)  source row for the i-th drawn row (0-indexed); negative = scrollback
--   y(i)    pixel y-offset (relative to viewport top) for the i-th drawn row
--   int_off / frac / extra  intermediate values (exposed for testing)
function M.layout(px, ch, rows)
  assert(px >= 0 and ch > 0 and rows > 0)
  local int_off = math.floor(px / ch)
  local frac    = px - int_off * ch
  local extra   = (frac > 0) and 1 or 0
  return {
    count = rows + extra,
    src   = function(i) return i - int_off - extra end,
    y     = function(i) return (i - extra) * ch + frac end,
    int_off = int_off,
    frac    = frac,
    extra   = extra,
  }
end

return M
