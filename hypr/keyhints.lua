-- Keyhints usage tracker.
--
-- Wraps hl.bind so every keybinding press is appended to
-- ~/.local/state/omarchy/keyhints/usage.log as "<epoch>\t<keys>\t<description>".
-- The keyhints bar widget reads that log to decide which bindings you already
-- know and which one to surface next.
--
-- Installed by install-tracker.sh, which copies this file to
-- ~/.config/hypr/keyhints.lua and adds require("hypr.keyhints") to hyprland.lua
-- *before* the Omarchy defaults so every default and personal binding passes
-- through it. Remove that require line (or run install-tracker.sh --uninstall)
-- to stop tracking.

local log_path = (os.getenv("HOME") or "") .. "/.local/state/omarchy/keyhints/usage.log"

-- Keep the original across config reloads so we never wrap the wrapper.
if not _G.__keyhints_real_bind then
  _G.__keyhints_real_bind = hl.bind
end
local real_bind = _G.__keyhints_real_bind

local function log_use(keys, description)
  local file = io.open(log_path, "a")
  if not file then
    return
  end
  file:write(os.time(), "\t", keys, "\t", description or "", "\n")
  file:close()
end

hl.bind = function(keys, action, options)
  local opts = options or {}

  -- Mouse binds need the real dispatcher for drag/resize, and repeating binds
  -- (volume, brightness) would flood the log. Leave both untouched.
  if opts.mouse or opts.repeating or type(keys) ~= "string" then
    return real_bind(keys, action, options)
  end

  return real_bind(keys, function(...)
    pcall(log_use, keys, opts.description)
    if type(action) == "function" then
      return action(...)
    end
    return hl.dispatch(action)
  end, options)
end

