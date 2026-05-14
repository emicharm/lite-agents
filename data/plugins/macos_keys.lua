-- On macOS treats the Cmd key as Ctrl so the default keymap (ctrl+P,
-- ctrl+S, …) works with the platform-native modifier.
if PLATFORM ~= "Mac OS X" then return end

local keymap = require "core.keymap"

local gui_keys = {
  ["left gui"]      = "left ctrl",
  ["right gui"]     = "left ctrl",
  ["left meta"]     = "left ctrl",
  ["right meta"]    = "left ctrl",
  ["left command"]  = "left ctrl",
  ["right command"] = "left ctrl",
}

local prev_pressed  = keymap.on_key_pressed
local prev_released = keymap.on_key_released

function keymap.on_key_pressed(k)
  return prev_pressed(gui_keys[k] or k)
end

function keymap.on_key_released(k)
  return prev_released(gui_keys[k] or k)
end
