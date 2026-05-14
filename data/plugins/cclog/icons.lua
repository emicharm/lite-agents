-- cclog/icons.lua
--
-- Loads the provider icons from data/icons/ once and exposes a draw helper
-- that tints them by a style colour. Missing files are tolerated: the loader
-- returns nil and the caller falls back to a letter badge.

local icons = { _images = {} }

-- source kind → filename, per the user's chosen naming.
local files = {
  claude  = "claude.png",
  codex   = "openaigym.png",
  copilot = "githubcopilot.png",
}

function icons.load_all()
  for kind, name in pairs(files) do
    local path = EXEDIR .. "/data/user/icons/" .. name
    local ok, img = pcall(renderer.image.load, path)
    if ok and img then icons._images[kind] = img end
  end
end

function icons.get(kind)
  return icons._images[kind]
end

-- Draw the icon for `kind` into a square of size `size` (px) anchored at
-- (x, y). Returns true if drawn, false if the icon isn't loaded.
function icons.draw(kind, x, y, size, color)
  local img = icons._images[kind]
  if not img then return false end
  renderer.draw_image(img, x, y, size, size, color)
  return true
end

return icons
