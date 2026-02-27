-- lib/feral-halfsecond.lua
-- Half-second delay as a send effect for other softcut voices.
-- Uses a dedicated voice (default 6) and buffer 2 so it doesn't overwrite your seed buffer.

local controlspec = require "controlspec"
local util = require "util"

local sc = {
  voice = 6,
  sources = {1, 2, 3, 4}, -- voices to feed into the delay
  loop_len = 0.5,         -- seconds
}

local function route_amount(x)
  local v = sc.voice
  for _, src in ipairs(sc.sources) do
    softcut.level_cut_cut(src, v, x) -- send from src -> delay voice input
  end
end

-- on/off state
sc.enabled = true

local function apply_enabled()
  local v = sc.voice

  if sc.enabled then
    softcut.rec(v, 1)
    softcut.rec_level(v, 1.0)

    -- restore wet + send from current delay param (or fallback)
    local d = 0.5
    local ok, val = pcall(function() return params:get("delay") end)
    if ok and type(val) == "number" then d = val end

    softcut.level(v, d)
    route_amount(d)
  else
    -- true bypass: no send, no wet, no writing
    route_amount(0.0)
    softcut.level(v, 0.0)
    softcut.rec_level(v, 0.0)
    softcut.rec(v, 0)
  end
end

function sc.add_params()
  params:add_group("DELAY", 5)

  params:add{
    id="delay_on",
    name="ON/OFF",
    type="option",
    options={"OFF","ON"},
    default=1,
    action=function(v)
      sc.enabled = (v == 2)
      apply_enabled()
    end
  }

  -- delay = wet level AND send amount (only when enabled)
  params:add{
    id="delay",
    name="WET",
    type="control",
    controlspec=controlspec.new(0, 1, "lin", 0, 0.5, ""),
    action=function(x)
      if sc.enabled then
        softcut.level(sc.voice, x)
        route_amount(x)
      end
      -- if disabled: we just store the value in params; apply_enabled() will restore on re-enable
    end
  }

  params:add{
    id="delay_rate",
    name="RATE",
    type="control",
    controlspec=controlspec.new(0.01, 4.0, "lin", 0, 1.0, ""),
    action=function(x) softcut.rate(sc.voice, x) end
  }

  params:add{
    id="delay_feedback",
    name="FEEDBACK",
    type="control",
    controlspec=controlspec.new(0, 2.0, "lin", 0, 0.75, ""),
    action=function(x)
      softcut.pre_level(sc.voice, x)
      if sc.enabled then softcut.rec_level(sc.voice, 1.0) end
    end
  }

  params:add{
    id="delay_pan",
    name="PANORAMA",
    type="control",
    controlspec=controlspec.new(-1, 1.0, "lin", 0, 0.0, ""),
    action=function(x) softcut.pan(sc.voice, x) end
  }
end

function sc.init(opts)
  opts = opts or {}
  sc.voice    = opts.voice or sc.voice
  sc.sources  = opts.sources or sc.sources
  sc.loop_len = opts.loop_len or sc.loop_len

  local v = sc.voice
  local L = sc.loop_len

  -- IMPORTANT: do NOT softcut.reset() here (your main script already set everything up)
  softcut.enable(v, 1)
  softcut.buffer(v, 2) -- separate buffer (prevents overwriting your seed buffer)
  softcut.loop(v, 1)
  softcut.loop_start(v, 0.0)
  softcut.loop_end(v, L)
  softcut.fade_time(v, 0.05)

  softcut.play(v, 1)
  softcut.rate(v, 1.0)
  softcut.position(v, 0.0)

  softcut.rec(v, 1)
  softcut.rec_level(v, 1.0)
  softcut.pre_level(v, 0.75)

  softcut.level_slew_time(v, 0.10)
  softcut.rate_slew_time(v, 0.10)
  softcut.pan(v, 0.0)
  softcut.level(v, 0.5)

  -- bandpass character on the delay output (modern API)
  softcut.post_filter_dry(v, 0.0)
  softcut.post_filter_bp(v, 1.0)
  softcut.post_filter_lp(v, 0.0)
  softcut.post_filter_hp(v, 0.0)
  softcut.post_filter_br(v, 0.0)
  softcut.post_filter_fc(v, 1200)
  softcut.post_filter_rq(v, 2.0)

  -- apply current param value to routing + wet
  local d = params:get("delay") or 0.5
  softcut.level(v, d)
  route_amount(d)
    -- apply initial on/off from params (if present), otherwise default ON
  local ok, v = pcall(function() return params:get("delay_on") end)
  if ok and v then sc.enabled = (v == 2) end
  apply_enabled()
end

return sc
