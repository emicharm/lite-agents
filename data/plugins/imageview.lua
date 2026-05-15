local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local command = require "core.command"
local View = require "core.view"
local RootView = require "core.rootview"


-- Per-frame exponential lerp without `View:move_towards`' 0.5 snap threshold.
-- That threshold is tuned for pixel coordinates; zoom values live in the 0.05–32
-- range, so any zoom step smaller than 0.5 would snap instantly. Pan must use
-- the same curve as zoom to keep the cursor anchor point stationary throughout
-- the animation.
local function smooth_to(t, k, dest, rate, eps)
  local val = t[k]
  if val == dest then return end
  local r = 1 - (1 - rate) ^ (60 / config.fps)
  local n = val + (dest - val) * r
  if math.abs(n - dest) < (eps or 0.001) then n = dest end
  t[k] = n
  core.redraw = true
end


local image_exts = {
  png = true, jpg = true, jpeg = true, bmp = true,
  gif = true, tga = true, psd = true,
}

local function is_image(filename)
  if not filename then return false end
  local ext = filename:lower():match("%.([%w]+)$")
  return ext and image_exts[ext] or false
end


local ImageView = View:extend()

function ImageView:new(filename)
  ImageView.super.new(self)
  self.filename = filename
  self.cursor = "arrow"
  self.scrollable = false
  self.zoom = 1
  self.zoom_to = 1
  self.zoom_user = false  -- user has zoomed/panned; stop auto-fit
  self.pan = { x = 0, y = 0 }
  self.pan_to = { x = 0, y = 0 }
  self.image, self.load_error = renderer.image.load(filename)
  if self.image then
    self.iw, self.ih = self.image:get_size()
  else
    self.iw, self.ih = 0, 0
  end
end


function ImageView:get_name()
  return self.filename:match("[^/%\\]*$")
end


function ImageView:try_close(do_close)
  do_close()
end


-- Fit-to-view zoom, preserving aspect. Leave a small margin.
function ImageView:get_fit_zoom()
  if self.iw <= 0 or self.ih <= 0 then return 1 end
  local pad = style.padding.x * 2
  local aw = math.max(1, self.size.x - pad)
  local ah = math.max(1, self.size.y - pad)
  local z = math.min(aw / self.iw, ah / self.ih)
  -- don't upscale beyond 1:1 in auto-fit, looks better
  if z > 1 then z = 1 end
  return z
end


function ImageView:reset_view()
  self.zoom_user = false
  self.pan_to.x, self.pan_to.y = 0, 0
end


function ImageView:zoom_at(factor, mx, my)
  -- keep the image point under the cursor stationary while zooming
  local cx = self.position.x + self.size.x / 2 + self.pan_to.x
  local cy = self.position.y + self.size.y / 2 + self.pan_to.y
  local new_zoom = common.clamp(self.zoom_to * factor, 0.05, 32)
  local ratio = new_zoom / self.zoom_to
  -- vector from cursor to image center, scaled by ratio
  self.pan_to.x = (cx - mx) * ratio + mx - (self.position.x + self.size.x / 2)
  self.pan_to.y = (cy - my) * ratio + my - (self.position.y + self.size.y / 2)
  self.zoom_to = new_zoom
  self.zoom_user = true
end


function ImageView:on_mouse_pressed(button, x, y, clicks)
  if View.on_mouse_pressed(self, button, x, y, clicks) then return true end
  if clicks == 2 then
    self:reset_view()
    return true
  end
  if button == "left" or button == "middle" then
    self.dragging_pan = true
    return true
  end
end


function ImageView:on_mouse_released(button, x, y)
  View.on_mouse_released(self, button, x, y)
  self.dragging_pan = false
end


function ImageView:on_mouse_moved(x, y, dx, dy)
  View.on_mouse_moved(self, x, y, dx, dy)
  if self.dragging_pan then
    self.pan_to.x = self.pan_to.x + dx
    self.pan_to.y = self.pan_to.y + dy
    self.zoom_user = true
  end
end


function ImageView:on_mouse_wheel(y)
  -- zoom centered on current mouse position
  local mx = core.root_view and core.root_view.mouse.x or
             (self.position.x + self.size.x / 2)
  local my = core.root_view and core.root_view.mouse.y or
             (self.position.y + self.size.y / 2)
  local factor = (y > 0) and 1.15 or (1 / 1.15)
  self:zoom_at(factor, mx, my)
end


function ImageView:update()
  if not self.zoom_user then
    self.zoom_to = self:get_fit_zoom()
    self.pan_to.x, self.pan_to.y = 0, 0
  end
  -- same rate for zoom and pan so the cursor anchor stays put across the
  -- whole animation (see derivation in zoom_at).
  local rate = 0.3
  smooth_to(self,     "zoom", self.zoom_to,  rate, 0.0005)
  smooth_to(self.pan, "x",    self.pan_to.x, rate, 0.1)
  smooth_to(self.pan, "y",    self.pan_to.y, rate, 0.1)
  View.update(self)
end


function ImageView:draw()
  self:draw_background(style.background)

  if not self.image then
    local msg = self.load_error or ("failed to load image: " .. self.filename)
    local tw = style.font:get_width(msg)
    local th = style.font:get_height()
    renderer.draw_text(style.font, msg,
      self.position.x + (self.size.x - tw) / 2,
      self.position.y + (self.size.y - th) / 2,
      style.accent)
    return
  end

  local dw = math.max(1, math.floor(self.iw * self.zoom))
  local dh = math.max(1, math.floor(self.ih * self.zoom))
  local dx = math.floor(self.position.x + (self.size.x - dw) / 2 + self.pan.x)
  local dy = math.floor(self.position.y + (self.size.y - dh) / 2 + self.pan.y)

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  renderer.draw_image(self.image, dx, dy, dw, dh, { 255, 255, 255, 255 })
  core.pop_clip_rect()

  -- info strip: filename, size, zoom %
  local info = string.format("%dx%d  %d%%", self.iw, self.ih,
                             math.floor(self.zoom * 100 + 0.5))
  local th = style.font:get_height()
  renderer.draw_text(style.font, info,
    self.position.x + style.padding.x,
    self.position.y + self.size.y - th - style.padding.y / 2,
    style.dim)
end


-- ----------------------------------------------------------------------------
-- Dispatch: route image files through ImageView instead of DocView.
-- We do this by short-circuiting core.open_doc to return a stub, and patching
-- RootView:open_doc to recognise the stub and instantiate an ImageView.
-- ----------------------------------------------------------------------------

local function is_image_stub(t)
  return type(t) == "table" and t.__image_stub == true
end

local old_open_doc = core.open_doc
function core.open_doc(filename)
  if is_image(filename) then
    return { __image_stub = true, filename = filename }
  end
  return old_open_doc(filename)
end


local old_root_open = RootView.open_doc
function RootView:open_doc(doc)
  if is_image_stub(doc) then
    local node = self:get_active_node()
    if node.locked and core.last_active_view then
      core.set_active_view(core.last_active_view)
      node = self:get_active_node()
    end
    assert(not node.locked, "Cannot open image on locked node")
    -- reuse existing image view if already open in this node
    for _, view in ipairs(node.views) do
      if view:is(ImageView) and view.filename == doc.filename then
        node:set_active_view(view)
        return view
      end
    end
    local view = ImageView(doc.filename)
    node:add_view(view)
    self.root_node:update_layout()
    return view
  end
  return old_root_open(self, doc)
end


command.add(ImageView, {
  ["image-view:reset"]    = function() core.active_view:reset_view() end,
  ["image-view:zoom-in"]  = function() core.active_view:zoom_at(1.25,
      core.root_view.mouse.x, core.root_view.mouse.y) end,
  ["image-view:zoom-out"] = function() core.active_view:zoom_at(1/1.25,
      core.root_view.mouse.x, core.root_view.mouse.y) end,
})

keymap.add {
  ["ctrl+0"]     = "image-view:reset",
  ["ctrl+="]     = "image-view:zoom-in",
  ["ctrl+-"]     = "image-view:zoom-out",
}


return ImageView
