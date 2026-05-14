-- Regression tests for the terminal's fractional-scroll math.
--
-- Run from the project root with `busted` (install via `luarocks install
-- busted`). The .busted file at the project root wires up the lua path.
--
-- The bug these tests pin down: when the pixel scroll offset was between two
-- row boundaries, the drawing loop kept showing the live screen rows shifted
-- up by `frac` pixels instead of showing the scrollback row above them.
-- Scrollback would only appear when the offset crossed a full cell_h and the
-- integer part incremented — producing a visible row-pop mid-animation.

local layout = require("plugins.terminal.scroll_math").layout

local CH, ROWS = 18, 24

describe("terminal scroll_math.layout", function()
  describe("at a row boundary (frac == 0)", function()
    it("draws exactly `rows` rows", function()
      local L = layout(0, CH, ROWS)
      assert.equals(ROWS, L.count)
    end)

    it("maps i=0 to source row 0 at the top of the viewport", function()
      local L = layout(0, CH, ROWS)
      assert.equals(0, L.src(0))
      assert.equals(0, L.y(0))
    end)

    it("uses integer line shifts for exact-row offsets", function()
      -- Scrolled exactly 3 rows up: viewport top shows scrollback row -3.
      local L = layout(3 * CH, CH, ROWS)
      assert.equals(ROWS, L.count)
      assert.equals(-3, L.src(0))
      assert.equals(0, L.y(0))
      assert.equals(-3 + ROWS - 1, L.src(ROWS - 1))
    end)
  end)

  describe("during a fractional scroll (frac > 0)", function()
    it("draws one extra row to cover the partial top + bottom", function()
      local L = layout(CH / 2, CH, ROWS)
      assert.equals(ROWS + 1, L.count)
    end)

    it("reveals the scrollback row above the viewport, not a shifted live row", function()
      -- This is THE regression: at px=ch/2, i=0 must be the scrollback row
      -- (-1) drawn at y = -ch/2 (bottom half visible at the top), not live
      -- row 0 shifted up by ch/2.
      local L = layout(CH / 2, CH, ROWS)
      assert.equals(-1, L.src(0))
      assert.equals(-CH / 2, L.y(0))
      assert.equals(0, L.src(1))
      assert.equals(CH / 2, L.y(1))
    end)

    it("preserves a constant gap of `ch` between successive drawn rows", function()
      local L = layout(7, CH, ROWS)
      for i = 1, L.count - 1 do
        assert.equals(CH, L.y(i) - L.y(i - 1))
        assert.equals(1, L.src(i) - L.src(i - 1))
      end
    end)
  end)

  describe("continuity across row boundaries", function()
    -- Locate a given source row N in the layout and return its screen y, or
    -- nil if it isn't drawn for this px.
    local function y_of_src(target, px)
      local L = layout(px, CH, ROWS)
      for i = 0, L.count - 1 do
        if L.src(i) == target then return L.y(i) end
      end
    end

    it("moves a source row continuously across px = ch", function()
      -- The pre-fix bug: at px just below ch, the layout never drew source
      -- row -1 at all (it kept showing live rows shifted up by `frac`). Then
      -- as int_off incremented, row -1 popped in at y ≈ 0. Now it should be
      -- present on both sides at smoothly-changing y positions.
      local below = y_of_src(-1, CH - 0.001)
      local at    = y_of_src(-1, CH)
      local above = y_of_src(-1, CH + 0.001)
      assert.is_true(below ~= nil, "row -1 missing at px = ch - ε")
      assert.is_true(at    ~= nil, "row -1 missing at px = ch")
      assert.is_true(above ~= nil, "row -1 missing at px = ch + ε")
      -- y(src=-1) must equal -ch + px (the affine identity), so:
      assert.is_true(math.abs(below - (-0.001)) < 1e-9)
      assert.equals(0, at)
      assert.is_true(math.abs(above - 0.001) < 1e-9)
    end)

    it("never lets a visible row jump by more than the step in px", function()
      -- Walk px in 1-pixel increments and verify that for every source row
      -- visible in both consecutive frames, its y position changes by
      -- exactly the step. This catches any future regression that breaks
      -- the affine identity y(src) = src*ch + px.
      local prev_layout = layout(0, CH, ROWS)
      for px = 1, 5 * CH do
        local cur = layout(px, CH, ROWS)
        for i = 0, cur.count - 1 do
          local s = cur.src(i)
          local prev_y
          for j = 0, prev_layout.count - 1 do
            if prev_layout.src(j) == s then prev_y = prev_layout.y(j); break end
          end
          if prev_y then
            assert.equals(1, cur.y(i) - prev_y,
              ("src %d jumped by %s pixels at px=%d (expected 1)")
                :format(s, cur.y(i) - prev_y, px))
          end
        end
        prev_layout = cur
      end
    end)
  end)

  describe("y(i) and src(i) form a consistent affine sequence", function()
    -- For any valid px, the pair (src(i), y(i)) must satisfy
    --   y(i) = src(i) * ch + px
    -- equivalently: drawing source row N at screen y = N*ch + px is the
    -- defining property of the scrollback rendering.
    local function check_identity(px)
      local L = layout(px, CH, ROWS)
      for i = 0, L.count - 1 do
        assert.equals(L.src(i) * CH + px, L.y(i),
          ("identity failed at px=%s, i=%d"):format(px, i))
      end
    end
    it("holds at px=0", function() check_identity(0) end)
    it("holds at sub-row offsets",   function() check_identity(7) end)
    it("holds at exact row offsets", function() check_identity(3 * CH) end)
    it("holds at multi-row + frac",  function() check_identity(3 * CH + 5) end)
  end)
end)
