-- FERAL>>FEEDBACK
-- Circuit bent noise simulator
-- by (AW) @audiowanderer
-- Script generate Random
-- seed files when loading
-- so... New noises every
-- time you play with it
--
-- CONTROLS
-- E1: Vol>Saturation
-- E2: Filt.Mod
-- E3: Entropy
-- K2: Noise Burst
-- K3: Freeze toggle
--
-- DELAY COMBO >>Warning<<
-- Heavy noise ahead...
-- K1+E1 = >>ON <<OFF
-- K2+K3 + E2/E3
-- E2: delay RATE
-- E3. delay FEEDback
-- K1+K2+K3= reset to default

local util = require "util"
local hs = include("lib/feral-halfsecond")
-- -----------------------------------------------------------------------------
-- CONFIG
-- -----------------------------------------------------------------------------
local FPS = 18
local dt = 1 / FPS

local SR = 44100
local V  = {1, 2, 3, 4}

local BUF_LEN  = 1.25
local SEED_LEN = 3.5

local BASE     = 0.05
local OUT_CEIL = 0.78

-- topology switching bounds (seconds)
local TOPO_MIN = 0.11
local TOPO_MAX = 1.11

-- visuals: strict per-frame budgets (avoid screen event Q full)
local MAX_PIX_LOW   = 30
local MAX_PIX_MED   = 90
local MAX_PIX_HIGH  = 160

local MAX_RECT_LOW  = 5
local MAX_RECT_MED  = 12
local MAX_RECT_HIGH = 18

local MAX_LINE_LOW  = 4
local MAX_LINE_MED  = 8
local MAX_LINE_HIGH = 12

-- traces (light)
local MAX_TRACE_PX   = 56
local MAX_TRACE_LINE = 22

local REGEN_SEED_EACH_RUN = true  -- set false to keep the same seed file between runs
-- -----------------------------------------------------------------------------
-- STATE
-- -----------------------------------------------------------------------------
local m

local s = {
  -- params
  vknob = 0.18, -- E1 (0..1)
  fmod  = 0.45, -- E2
  ent   = 0.45, -- E3

  -- derived each frame
  vol_gain = 0.0, -- 0..1
  fuzz     = 0.0, -- 0..1 after half-turn

-- keys
k1_down = false,
k2_down = false,
k3_down = false,
delay_reset_latched = false,

  -- envelopes / mode
  drive = BASE,
  burst_time = 0.0,
  shock = 0.0,

  freeze = {active=false, a=0.0, b=0.05},

  -- visuals
  visual_burst = 0.0,     -- 0..1 decays fast
  burst_fade_s = 0.16,    -- seconds; set on burst

  particles = {},

  -- cadences
  topo_cd = 0.0,
  shard_cd = 0.0,

  phase = 0.0,
  fphase = 0.0,

  -- afterimages (only used for freeze “pause scars”)
  trace_px = {},
  trace_ln = {},
}

local DATA_DIR  = _path.data .. "feral_feedback/"
local SEED_FILE = DATA_DIR .. "seed_v4_refined.wav"

-- -----------------------------------------------------------------------------
-- UTILS
-- -----------------------------------------------------------------------------
local function le16(u)
  local lo = u % 256
  local hi = math.floor(u / 256) % 256
  return string.char(lo, hi)
end

local function le32(u)
  local b1 = u % 256
  local b2 = math.floor(u / 256) % 256
  local b3 = math.floor(u / 65536) % 256
  local b4 = math.floor(u / 16777216) % 256
  return string.char(b1, b2, b3, b4)
end

local function lerp(a, b, x) return a + (b - a) * x end
local function clamp01(x) return util.clamp(x, 0, 1) end
local function randf(a, b) return a + (b - a) * math.random() end

local function exp_towards(x, target, tau, dt_)
  if tau <= 0 then return target end
  return target + (x - target) * math.exp(-dt_ / tau)
end

-- -----------------------------------------------------------------------------
-- SEED WAV (generated once)
-- -----------------------------------------------------------------------------
local function write_seed_wav(path, seconds)
  local n = math.floor(seconds * SR)
  local data_bytes = n * 2
  local riff_size = 4 + (8 + 16) + (8 + data_bytes)

  local f = assert(io.open(path, "wb"))
  f:write("RIFF"); f:write(le32(riff_size)); f:write("WAVE")
  f:write("fmt "); f:write(le32(16))
  f:write(le16(1)); f:write(le16(1)) -- PCM mono
  f:write(le32(SR))
  f:write(le32(SR * 2))
  f:write(le16(2)); f:write(le16(16))
  f:write("data"); f:write(le32(data_bytes))

  local tau = 2 * math.pi

  -- ---------------------------------------------------------------------------
  -- Per-run personality
  -- ---------------------------------------------------------------------------
  local profile = math.random(1, 5)

  local lp = 0
  local a = randf(0.02, 0.24)

  local ph1 = randf(0, tau)
  local ph2 = randf(0, tau)
  local ph3 = randf(0, tau)

  local hz1 = randf(28, 260)
  local hz2 = randf(70, 1800)
  local hz3 = randf(6, 90)

  local t1 = randf(20, 3200)
  local t2 = randf(40, 4200)
  local t3 = randf(4, 140)

  local drift1 = randf(0.00010, 0.00180)
  local drift2 = randf(0.00008, 0.00140)
  local drift3 = randf(0.00005, 0.00070)

  local sine1_amt = randf(0.00, 0.35)
  local sine2_amt = randf(0.00, 0.25)
  local fm_amt    = randf(0.00, 0.35)
  local noise_amt = randf(0.18, 0.95)
  local burst_amt = randf(0.08, 0.90)
  local imp_amt   = randf(0.00, 0.45)

  local burst_chance = randf(0.00005, 0.00140)
  local imp_chance   = randf(0.00003, 0.00120)
  local gate_chance  = randf(0.00002, 0.00045)

  local burst_min = math.random(40, 220)
  local burst_max = math.random(500, 3200)

  local retarget1 = math.random(1200, 7200)
  local retarget2 = math.random(1800, 8200)
  local retarget3 = math.random(2200, 10000)

  local gate = 0
  local burst = 0

  local drive = randf(0.10, 1.80)
  local dc = randf(-0.02, 0.02)

  -- ---------------------------------------------------------------------------
  -- Profiles: small set of strong personalities
  -- ---------------------------------------------------------------------------
  if profile == 1 then
    -- tonal drift
    sine1_amt = randf(0.12, 0.34)
    sine2_amt = randf(0.06, 0.22)
    fm_amt    = randf(0.02, 0.16)
    noise_amt = randf(0.18, 0.48)
    burst_amt = randf(0.04, 0.28)
    imp_amt   = randf(0.00, 0.12)
    burst_chance = randf(0.00003, 0.00030)
    imp_chance   = randf(0.00002, 0.00018)
    a = randf(0.03, 0.11)
    drive = randf(0.10, 0.70)

  elseif profile == 2 then
    -- noisy hiss / swarm
    sine1_amt = randf(0.00, 0.14)
    sine2_amt = randf(0.00, 0.10)
    fm_amt    = randf(0.00, 0.10)
    noise_amt = randf(0.55, 0.98)
    burst_amt = randf(0.20, 0.70)
    imp_amt   = randf(0.06, 0.28)
    burst_chance = randf(0.00020, 0.00130)
    imp_chance   = randf(0.00010, 0.00080)
    a = randf(0.08, 0.24)
    drive = randf(0.50, 1.50)

  elseif profile == 3 then
    -- pulsed / torn / clicky
    sine1_amt = randf(0.02, 0.18)
    sine2_amt = randf(0.00, 0.12)
    fm_amt    = randf(0.00, 0.20)
    noise_amt = randf(0.24, 0.62)
    burst_amt = randf(0.35, 0.90)
    imp_amt   = randf(0.12, 0.45)
    burst_chance = randf(0.00030, 0.00140)
    imp_chance   = randf(0.00020, 0.00120)
    gate_chance  = randf(0.00008, 0.00045)
    a = randf(0.04, 0.18)
    drive = randf(0.70, 1.80)

  elseif profile == 4 then
    -- hollow radio / ghost carrier
    sine1_amt = randf(0.08, 0.30)
    sine2_amt = randf(0.04, 0.20)
    fm_amt    = randf(0.10, 0.35)
    noise_amt = randf(0.18, 0.50)
    burst_amt = randf(0.05, 0.24)
    imp_amt   = randf(0.00, 0.10)
    burst_chance = randf(0.00004, 0.00022)
    imp_chance   = randf(0.00003, 0.00012)
    a = randf(0.02, 0.09)
    drive = randf(0.12, 0.60)

  else
    -- broken motor / unstable machine
    sine1_amt = randf(0.04, 0.22)
    sine2_amt = randf(0.00, 0.16)
    fm_amt    = randf(0.08, 0.26)
    noise_amt = randf(0.26, 0.72)
    burst_amt = randf(0.12, 0.55)
    imp_amt   = randf(0.02, 0.22)
    burst_chance = randf(0.00008, 0.00070)
    imp_chance   = randf(0.00005, 0.00045)
    a = randf(0.05, 0.16)
    drive = randf(0.35, 1.20)
  end

  local chunk, chunk_n = {}, 0

  for i = 1, n do
    -- retarget drift points occasionally
    retarget1 = retarget1 - 1
    retarget2 = retarget2 - 1
    retarget3 = retarget3 - 1

    if retarget1 <= 0 then
      t1 = randf(18, 3800)
      retarget1 = math.random(1200, 8200)
    end
    if retarget2 <= 0 then
      t2 = randf(35, 4600)
      retarget2 = math.random(1600, 9200)
    end
    if retarget3 <= 0 then
      t3 = randf(3, 180)
      retarget3 = math.random(2200, 12000)
    end

    hz1 = hz1 + (t1 - hz1) * drift1
    hz2 = hz2 + (t2 - hz2) * drift2
    hz3 = hz3 + (t3 - hz3) * drift3

    ph1 = ph1 + (tau * hz1 / SR)
    ph2 = ph2 + (tau * hz2 / SR)
    ph3 = ph3 + (tau * hz3 / SR)

    if ph1 > tau then ph1 = ph1 - tau end
    if ph2 > tau then ph2 = ph2 - tau end
    if ph3 > tau then ph3 = ph3 - tau end

    local lfo = math.sin(ph3)
    local mod_hz = hz2 + (hz2 * fm_amt * 0.35 * lfo)
    local mod_ph = ph2 + (tau * mod_hz / SR)

    local s1 = math.sin(ph1)
    local s2 = math.sin(mod_ph)

    -- square-ish component, but still soft
    local sq = (math.sin(ph2 * 0.5 + ph1 * 0.13) >= 0) and 1 or -1
    sq = sq * 0.15

    -- filtered noise
    local x = (math.random() * 2 - 1)
    lp = lp + a * (x - lp)

    -- bursts / gates / impulses
    if burst > 0 then burst = burst - 1 end
    if gate > 0 then gate = gate - 1 end

    if math.random() < burst_chance then
      burst = math.random(burst_min, burst_max)
    end

    if math.random() < gate_chance then
      gate = math.random(80, 1400)
    end

    local b = (burst > 0) and (burst_amt * (math.random() * 2 - 1)) or 0
    local imp = (math.random() < imp_chance) and ((math.random() * 2 - 1) * imp_amt) or 0

    local sig =
      noise_amt * lp +
      sine1_amt * s1 +
      sine2_amt * s2 +
      b + imp + dc

    -- profile-specific shaping
    if profile == 1 then
      sig = sig + 0.08 * math.sin(ph1 * 0.5)

    elseif profile == 2 then
      sig = sig + 0.10 * sq

    elseif profile == 3 then
      local gate_lfo = (math.sin(ph3 * 0.37 + ph1 * 0.09) > 0.2) and 1.0 or 0.35
      sig = sig * gate_lfo + 0.06 * sq

    elseif profile == 4 then
      sig = sig + 0.12 * math.sin(ph1 + ph2 * 0.17)

    else
      sig = sig + 0.09 * math.sin(ph1 * 0.23 + ph2 * 0.11)
      if math.random() < 0.00018 then
        sig = -sig
      end
    end

    if gate > 0 then
      sig = sig * randf(0.04, 0.30)
    end

    -- gentle nonlinear shaping
    sig = sig / (1 + math.abs(sig) * drive)

    if sig > 1 then sig = 1 end
    if sig < -1 then sig = -1 end

    local samp = math.floor(sig * 29500)
    if samp < -32768 then samp = -32768 end
    if samp >  32767 then samp =  32767 end

    local u = (samp < 0) and (samp + 65536) or samp
    chunk_n = chunk_n + 1
    chunk[chunk_n] = le16(u)

    if chunk_n >= 2048 then
      f:write(table.concat(chunk))
      chunk, chunk_n = {}, 0
    end
  end

  if chunk_n > 0 then
    f:write(table.concat(chunk))
  end

  f:close()
end

local function ensure_seed()
  util.make_dir(DATA_DIR)

  if REGEN_SEED_EACH_RUN then
    -- overwrite seed file every run (new sound each load)
    write_seed_wav(SEED_FILE, SEED_LEN)
  else
    -- generate only once (cached)
    if not util.file_exists(SEED_FILE) then
      write_seed_wav(SEED_FILE, SEED_LEN)
    end
  end
end

local function delay_combo_active()
  return s.k2_down and s.k3_down
end

local function set_delay_enabled(on)
  params:set("delay_on", on and 2 or 1) -- 1=OFF, 2=ON
end

local function adjust_delay_rate(d)
  local x = params:get("delay_rate") or 1.0
  x = util.clamp(x + d / 60, 0.01, 4.0)
  params:set("delay_rate", x)
end

local function adjust_delay_feedback(d)
  local x = params:get("delay_feedback") or 0.75
  x = util.clamp(x + d / 80, 0.0, 2.0)
  params:set("delay_feedback", x)
end

local function reset_delay_defaults()
  params:set("delay_on", 1)        -- OFF (default in your lib)
  params:set("delay", 0.5)         -- WET
  params:set("delay_rate", 1.0)    -- RATE
  params:set("delay_feedback", 0.75) -- FEEDBACK
  params:set("delay_pan", 0.0)     -- PANORAMA
end

local function delay_reset_combo_active()
  return s.k1_down and s.k2_down and s.k3_down
end

-- -----------------------------------------------------------------------------
-- SOFTCUT SETUP + HELPERS
-- -----------------------------------------------------------------------------
local function seed_loop_region()
  softcut.buffer_read_mono(SEED_FILE, 0, 0, BUF_LEN, 1, 1, 0, 1)
end

local function clear_matrix()
  for _, a in ipairs(V) do
    for _, b in ipairs(V) do
      softcut.level_cut_cut(a, b, 0.0)
    end
  end
end

local function setup_voice(v)
  softcut.enable(v, 1)
  softcut.buffer(v, 1)

  softcut.level_slew_time(v, 0.015)
  softcut.recpre_slew_time(v, 0.015)
  softcut.rate_slew_time(v, 0.015)

  softcut.loop(v, 1)
  softcut.loop_start(v, 0.0)
  softcut.loop_end(v, BUF_LEN)
  softcut.fade_time(v, 0.006)

  softcut.position(v, randf(0, BUF_LEN))
  softcut.rate(v, 1.0)
  softcut.play(v, 1)
  softcut.rec(v, 1)

  softcut.pan(v, (v == 1 or v == 3) and -0.4 or 0.4)

  -- pre filter: bandpass throat
  softcut.pre_filter_dry(v, 0.0)
  softcut.pre_filter_bp(v, 1.0)
  softcut.pre_filter_lp(v, 0.0)
  softcut.pre_filter_hp(v, 0.0)
  softcut.pre_filter_br(v, 0.0)
  softcut.pre_filter_fc(v, 900)
  softcut.pre_filter_rq(v, 1.1)

  -- post filter: bp for 1/2, lp for 3/4
  softcut.post_filter_dry(v, 0.0)
  if v <= 2 then
    softcut.post_filter_bp(v, 1.0)
    softcut.post_filter_lp(v, 0.0)
    softcut.post_filter_fc(v, 1300)
    softcut.post_filter_rq(v, 1.0)
  else
    softcut.post_filter_bp(v, 0.0)
    softcut.post_filter_lp(v, 1.0)
    softcut.post_filter_fc(v, 600)
    softcut.post_filter_rq(v, 0.8)
  end
end

local function softcut_setup()
  softcut.reset()
  softcut.buffer_clear()

  audio.level_dac(1.0)
  audio.level_cut(1.0)

  audio.level_adc(1.0)
  audio.level_adc_cut(0.10)

  audio.level_eng_cut(0.0)
  audio.level_tape_cut(0.0)

  ensure_seed()
  seed_loop_region()

  for _, v in ipairs(V) do setup_voice(v) end

  softcut.event_phase(function(v, ph)
    if v == 1 then s.phase = ph end
  end)
  softcut.phase_quant(1, 0.02)
  softcut.poll_start_phase()

  clear_matrix()
end

local function inject_shard(amount)
  local slice = lerp(0.008, 0.190, amount)
  local src = randf(0.0, math.max(0.0, SEED_LEN - slice))
  local dst = randf(0.0, math.max(0.0, BUF_LEN  - slice))
  softcut.buffer_read_mono(SEED_FILE, src, dst, slice, 1, 1, 0, 1)
end

-- -----------------------------------------------------------------------------
-- TOPOLOGY MODES
-- -----------------------------------------------------------------------------
local function topo_ring(g)
  clear_matrix()
  for i = 1, 4 do
    local a = i
    local b = (i % 4) + 1
    softcut.level_cut_cut(a, b, g)
  end
end

local function topo_star(g)
  clear_matrix()
  local hub = math.random(1, 4)
  for i = 1, 4 do
    if i ~= hub then
      softcut.level_cut_cut(i, hub, g)
      softcut.level_cut_cut(hub, i, g * 0.75)
    end
  end
end

local function topo_random(g, var)
  clear_matrix()
  for a = 1, 4 do
    local edges = 1 + math.floor(math.random() * (1 + math.floor(3 * s.ent)))
    for _ = 1, edges do
      local b = math.random(1, 4)
      local gg = util.clamp(g + (math.random()*2 - 1) * var, 0.0, 0.995)
      if a == b and s.ent < 0.60 then gg = gg * 0.25 end
      softcut.level_cut_cut(a, b, gg)
    end
  end
end

local function apply_topology(g, var)
  local r = math.random()
  if r < 0.33 then topo_ring(g)
  elseif r < 0.66 then topo_star(g)
  else topo_random(g, var) end
end

-- -----------------------------------------------------------------------------
-- TRACES (only used for freeze “pause scars”)
-- -----------------------------------------------------------------------------
local function trace_add_px(x, y, lvl)
  local tp = s.trace_px
  if #tp >= MAX_TRACE_PX then table.remove(tp, 1) end
  tp[#tp+1] = {x=x, y=y, lvl=lvl}
end

local function trace_add_ln(x0, y0, x1, y1, lvl)
  local tl = s.trace_ln
  if #tl >= MAX_TRACE_LINE then table.remove(tl, 1) end
  tl[#tl+1] = {x0=x0, y0=y0, x1=x1, y1=y1, lvl=lvl}
end

local function traces_decay()
  -- faster fade (short-lived)
  for i = #s.trace_px, 1, -1 do
    local p = s.trace_px[i]
    p.lvl = p.lvl - 2
    if p.lvl <= 0 then table.remove(s.trace_px, i) end
  end
  for i = #s.trace_ln, 1, -1 do
    local l = s.trace_ln[i]
    l.lvl = l.lvl - 2
    if l.lvl <= 0 then table.remove(s.trace_ln, i) end
  end
end

local function draw_traces()
  for i = 1, #s.trace_ln do
    local l = s.trace_ln[i]
    screen.level(util.clamp(l.lvl, 1, 15))
    screen.move(l.x0, l.y0)
    screen.line(l.x1, l.y1)
    screen.stroke()
  end
  for i = 1, #s.trace_px do
    local p = s.trace_px[i]
    screen.level(util.clamp(p.lvl, 1, 15))
    screen.pixel(p.x, p.y)
  end
end

-- -----------------------------------------------------------------------------
-- VISUALS (optimized + burst fades fast + freeze VHS pause)
-- -----------------------------------------------------------------------------
local function init_particles()
  s.particles = {}
  for i = 1, 22 do
    s.particles[i] = {
      x = math.random(0, 127),
      y = math.random(0, 63),
      px = nil,   -- previous position for bi-location ghost
      py = nil,
      ghost = 0,  -- frames remaining for second location
      hold = math.random(0, 2),
      lvl = math.random(3, 9),
    }
  end
end

local function update_particles()
  for i = 1, #s.particles do
    local p = s.particles[i]

    if p.ghost > 0 then
      p.ghost = p.ghost - 1
    end

    if p.hold > 0 then
      p.hold = p.hold - 1
    else
      local r = math.random()

      -- keep old position sometimes for bi-location
      p.px, p.py = p.x, p.y

      if r < 0.50 then
        -- tiny local jitter
        p.x = util.clamp(p.x + math.random(-2, 2), 0, 127)
        p.y = util.clamp(p.y + math.random(-1, 1), 0, 63)

      elseif r < 0.80 then
        -- medium jump
        p.x = util.clamp(p.x + math.random(-10, 10), 0, 127)
        p.y = util.clamp(p.y + math.random(-6, 6), 0, 63)

      else
        -- hard teleport
        p.x = math.random(0, 127)
        p.y = math.random(0, 63)
      end

      -- occasional bilocation for 1–2 frames
      if math.random() < (0.12 + 0.20 * s.ent) then
        p.ghost = math.random(1, 2)
      else
        p.ghost = 0
      end

      -- uneven brightness
      if math.random() < 0.18 then
        p.lvl = math.random(9, 15)
      else
        p.lvl = math.random(3, 8)
      end

      -- brief pauses make it feel less like motion physics
      p.hold = math.random(0, 2)
    end
  end
end

local function draw_latent()
  -- unstable dots
  for i = 1, #s.particles do
    local p = s.particles[i]

    screen.level(p.lvl)
    screen.pixel(p.x, p.y)

    if p.ghost > 0 and p.px and p.py then
      screen.level(math.max(2, p.lvl - 3))
      screen.pixel(p.px, p.py)
    end
  end
  screen.stroke()

  -- background digital interference
  local pix = util.clamp(math.floor(24 + 42 * s.ent), 24, 70)
  screen.level(6)
  for _ = 1, pix do
    screen.pixel(math.random(-4,131), math.random(-2,65))
  end
  screen.stroke()

  -- short erratic scratches
  local short_line_count = util.clamp(2 + math.floor(5 * s.ent), 2, 7)
  for _ = 1, short_line_count do
    local vertical = (math.random() < 0.35)
    screen.level(math.random(3, 8))

    if vertical then
      local x = math.random(0, 127)
      local y0 = math.random(0, 63)
      local len = math.random(2, 10)
      screen.move(x, y0)
      screen.line(x, util.clamp(y0 + len, 0, 63))
    else
      local y = math.random(0, 63)
      local x0 = math.random(0, 127)
      local len = math.random(3, 18)
      screen.move(x0, y)
      screen.line(util.clamp(x0 + len, 0, 127), y)
    end
    screen.stroke()
  end

  -- full-span interference lines
  local full_line_count = util.clamp(2 + math.floor(5 * s.ent), 2, 7)
  for _ = 1, full_line_count do
    local vertical = (math.random() < 0.35)
    screen.level(math.random(1, 3))

    if vertical then
      local x = math.random(-2, 129)
      screen.move(x, 0)
      screen.line(x, 63)
    else
      local y = math.random(-1, 64)
      screen.move(0, y)
      screen.line(127, y)
    end

    screen.stroke()
  end

  -- occasional micro-clusters / dropout specks
  if math.random() < (0.18 + 0.25 * s.ent) then
    local cx = math.random(4, 123)
    local cy = math.random(4, 59)
    local n = math.random(3, 7)
    screen.level(math.random(6, 12))
    for _ = 1, n do
      screen.pixel(
        util.clamp(cx + math.random(-2, 2), 0, 127),
        util.clamp(cy + math.random(-1, 1), 0, 63)
      )
    end
    screen.stroke()
  end
end

local function draw_noise_budgets(intensity)
  local pix, rects, lines
  if intensity < 0.34 then
    pix   = MAX_PIX_LOW
    rects = MAX_RECT_LOW
    lines = MAX_LINE_LOW
  elseif intensity < 0.68 then
    pix   = MAX_PIX_MED
    rects = MAX_RECT_MED
    lines = MAX_LINE_MED
  else
    pix   = MAX_PIX_HIGH
    rects = MAX_RECT_HIGH
    lines = MAX_LINE_HIGH
  end

  local e = s.ent

  screen.level(15)
  for _ = 1, rects do
    local w = 1 + math.random(1, 6)
    local h = 1 + math.random(1, (e > 0.6) and 4 or 3)
    local x = math.random(0, 127 - w)
    local y = math.random(0, 63 - h)
    screen.rect(x, y, w, h)
    screen.fill()
  end

  screen.level(util.clamp(5 + math.floor(7*e), 4, 15))
  for _ = 1, lines do
    local y = math.random(0, 63)
    local len = math.random(18, 80)
    local x0 = math.random(0, 127 - len)
    local wob = math.floor((math.random()*2 - 1) * (1 + 7*e))
    screen.move(x0, y)
    screen.line(x0 + len, util.clamp(y + wob, 0, 63))
    screen.stroke()
  end

  screen.level(15)
  for _ = 1, pix do
    screen.pixel(math.random(0,127), math.random(0,63))
  end
  screen.stroke()
end

local function draw_burst()
  -- burst intensity decays quickly (fast fade)
  local intensity = util.clamp(s.visual_burst, 0, 1)
  draw_noise_budgets(intensity)
end

local function draw_freeze_vhs()
  -- “pause” look: mostly horizontal trembling lines + a few dropout blocks
  local e = s.ent
  local trem = 1 + math.floor(10 * (0.30 + 0.70*e))

  -- background: very light snow (bounded)
  screen.level(10)
  for _ = 1, 40 do
    screen.pixel(math.random(0,127), math.random(0,63))
  end

  -- main VHS pause lines
  local line_count = util.clamp(8 + math.floor(10*e), 8, 18)
  screen.level(15)
  for _ = 1, line_count do
    local y = math.random(4, 59)
    local wob = math.floor((math.random()*2 - 1) * trem)
    local x0 = math.random(0, 10)
    local x1 = 127 - math.random(0, 10)
    screen.move(x0, y)
    screen.line(x1, util.clamp(y + wob, 0, 63))
    screen.stroke()

    if math.random() < 0.25 then
      trace_add_ln(x0, y, x1, y, math.random(4, 10))
    end
  end

  -- dropout blocks (tape damage)
  if math.random() < (0.35 + 0.45*e) then
    screen.level(15)
    local blocks = 2 + math.floor(6*e)
    for _ = 1, blocks do
      local w = math.random(6, 24)
      local h = math.random(1, 5)
      local x = math.random(0, 127 - w)
      local y = math.random(0, 63 - h)
      screen.rect(x, y, w, h)
      screen.fill()
      if math.random() < 0.35 then
        trace_add_px(x + math.random(0,w), y + math.random(0,h), math.random(3, 8))
      end
    end
  end

  draw_traces()
end

function redraw()
  if math.random() < 0.85 then
    screen.clear()
  end
    if math.random() < 0.33 then
  traces_decay()
  end
  

  if s.freeze.active then
    draw_freeze_vhs()
  elseif s.visual_burst > 0 then
    draw_burst()
  else
    draw_latent()
    draw_traces()
  end

  if math.random() < 0.10 then
    screen.clear()
  end

  screen.update()
end

-- -----------------------------------------------------------------------------
-- AUDIO CORE (reference + freeze mode + volume/fuzz mapping)
-- -----------------------------------------------------------------------------
local function update_vol_fuzz()
  -- half-turn => full gain
  local vg = util.clamp(s.vknob * 2.0, 0, 1) -- 0..1
  local fz = util.clamp((s.vknob - 0.5) * 2.0, 0, 1) -- 0..1
  s.vol_gain = vg
  s.fuzz = fz
end

local function enter_freeze()
  s.freeze.active = true

  -- capture around current phase
  local win = lerp(0.090, 0.018, util.clamp(0.25 + 0.75*s.ent, 0, 1)) -- short
  local center = util.clamp(s.phase, 0.0, BUF_LEN)
  local a = util.clamp(center - win * 0.5, 0.0, BUF_LEN - win)
  local b = a + win
  s.freeze.a, s.freeze.b = a, b

  -- stop writing + stop network feedback (true "freeze")
  -- clear_matrix() uncomment to avoid feedback artifacts
for _, v in ipairs(V) do
  softcut.loop_start(v, a)
  softcut.loop_end(v, b)
  softcut.rec(v, 0)
  softcut.rec_level(v, 0)

  local rr = 1.0
  if s.ent > 0.65 and math.random() < 0.30 then
    rr = -rr
  end
  softcut.rate(v, rr)
end
  -- add a few “pause scars”
  for _ = 1, 10 do
    trace_add_ln(math.random(0,127), math.random(0,63), math.random(0,127), math.random(0,63), math.random(4, 10))
  end
end

local function exit_freeze()
  s.freeze.active = false

  -- restore full loop + recording on
  for _, v in ipairs(V) do
    softcut.loop_start(v, 0.0)
    softcut.loop_end(v, BUF_LEN)
    softcut.rec(v, 1)
  end

  -- force quick topology refresh
  s.topo_cd = 0
  s.shard_cd = 0
end

local function burst_shock()
  -- burst exits freeze
  if s.freeze.active then exit_freeze() end

  s.shock = 0.22 + 0.30 * s.ent
  s.burst_time = 0.25 + 0.45 * s.ent

  -- visual: fast fade
  s.visual_burst = 1.0
  s.burst_fade_s = lerp(0.18, 0.10, s.ent) -- faster with more entropy

  -- buffer punch (unique each press)
  local n = 2 + math.floor(8 * s.ent)
  for _ = 1, n do
    inject_shard(0.45 + 0.55 * s.ent)
  end

  -- randomize positions/rates so the burst never repeats
  for _, v in ipairs(V) do
    softcut.rec(v, 1)
    softcut.position(v, randf(0, BUF_LEN))
    local rr = randf(-1.8, 1.8)
    if math.abs(rr) < 0.08 then rr = 0.08 end
    softcut.rate(v, rr)
  end

  -- force immediate topology with high variance (fuzz makes it nastier)
  local fuzz = s.fuzz
  local g   = util.clamp(0.52 + 0.36*s.ent + 0.10*fuzz, 0.0, 0.995)
  local var = util.clamp(0.30 + 0.60*s.ent + 0.25*fuzz, 0.0, 0.95)
  apply_topology(g, var)
end

local function apply_audio_freeze()
  update_vol_fuzz()

  -- keep output under ceiling; fuzz changes character, not amplitude past 100%
  local out = OUT_CEIL * s.vol_gain

  -- in freeze: slight VHS tremble = tiny position nudges + filter wobble
  local a, b = s.freeze.a, s.freeze.b
  local e = s.ent
  local fz = s.fuzz

  -- filter modulation oscillator
  local f_rate  = lerp(0.08, 12.0, s.fmod)
  local f_depth = lerp(0.00, 1.25, s.fmod) * (0.60 + 0.90*e)
  s.fphase = s.fphase + (2 * math.pi * f_rate * dt)
  if s.fphase > 2 * math.pi then s.fphase = s.fphase - 2 * math.pi end

  for _, v in ipairs(V) do
    softcut.level(v, out * ((v <= 2) and 1.0 or (0.20 + 0.18*e)))

    -- occasional micro jump inside the frozen window
    if math.random() < (0.08 + 0.25*e + 0.15*fz) then
      local p = randf(a, b)
      softcut.position(v, p)
    end

    -- slow “tape head wobble”: tiny rate jitter (not re-looping, just tremble)
    if math.random() < (0.06 + 0.18*e) then
      local rr = 1.0
      rr = rr + (math.random()*2 - 1) * lerp(0.001, 0.020, e + 0.6*fz)
      rr = util.clamp(rr, -1.2, 1.2)
      if math.abs(rr) < 0.05 then rr = 0.05 end
      softcut.rate(v, rr)
    end

    -- filter wobble
    local osc = math.sin(s.fphase + v * 1.1)
    local jitter = (math.random()*2 - 1) * (0.04 + 0.25*e + 0.18*fz)

    local base_fc = (v <= 2) and 900 or 350
    local hi_fc   = (v <= 2) and 9800 or 2600
    local lo_fc   = (v <= 2) and 60   or 40

    local fc = base_fc * (1 + f_depth * osc) * (1 + jitter)
    fc = util.clamp(fc, lo_fc, hi_fc)

    local rq = lerp(1.15, 0.45, util.clamp(e + 0.6*fz, 0, 1))
    softcut.pre_filter_fc(v, fc)
    softcut.pre_filter_rq(v, rq)

    if v <= 2 then
      softcut.post_filter_fc(v, fc)
      softcut.post_filter_rq(v, rq)
    else
      softcut.post_filter_fc(v, util.clamp(fc * 0.85, lo_fc, hi_fc))
      softcut.post_filter_rq(v, lerp(0.95, 0.65, e))
    end
  end
end

local function apply_audio_normal()
  update_vol_fuzz()

  local burst_on = (s.burst_time > 0)
  if burst_on then
    s.drive = exp_towards(s.drive, 1.0, 0.030, dt)
  else
    s.drive = exp_towards(s.drive, BASE, 0.50, dt)
  end

  local fz = s.fuzz
  local chaos = clamp01(
    0.18
    + 0.82 * (s.ent ^ 1.35) * (0.30 + 0.70 * s.drive)
    + ((s.shock > 0) and 0.35 or 0)
    + 0.22 * fz
  )

  -- volume mapping: max level reached at half-turn (vol_gain==1),
  -- beyond that fuzz increases chaos/resonance, not amplitude past OUT_CEIL
  local out = OUT_CEIL * s.vol_gain
  out = util.clamp(out, 0, OUT_CEIL)

  -- memory: fuzz pushes pre/feedback a bit (more “saturated” behavior)
  local pre = lerp(0.72, 0.999, util.clamp(0.20 + 0.80 * (0.35 + 0.65 * s.fmod), 0, 1))
  pre = util.clamp(pre + 0.06 * (s.ent * s.drive) + 0.05 * (fz * s.drive), 0.0, 0.999)
  local rec = lerp(0.05, 1.0, s.drive)

  -- E2 filter modulation oscillator
  local f_rate  = lerp(0.08, 12.0, s.fmod)
  local f_depth = lerp(0.00, 1.25, s.fmod) * (0.70 + 0.60*fz)
  s.fphase = s.fphase + (2 * math.pi * f_rate * dt)
  if s.fphase > 2 * math.pi then s.fphase = s.fphase - 2 * math.pi end

  -- topology switching (faster with chaos)
  s.topo_cd = s.topo_cd - dt
  local topo_period = lerp(TOPO_MAX, TOPO_MIN, clamp01(0.30 + 0.70 * chaos))
  if s.topo_cd <= 0 then
    local g = util.clamp(
      lerp(0.10, 0.96, (0.35 + 0.65 * s.drive)) + (s.shock > 0 and 0.10 or 0) + 0.08*fz,
      0.0, 0.995
    )
    local var = util.clamp((lerp(0.08, 0.92, s.ent) + 0.25*fz) * lerp(0.25, 1.0, s.drive), 0.0, 0.95)
    apply_topology(g, var)
    s.topo_cd = topo_period
  end

  -- shard injection
  s.shard_cd = math.max(0, s.shard_cd - dt)
  if s.shard_cd <= 0 then
    local p = (0.01 + 0.22 * (s.ent ^ 1.6) * s.drive) + (s.shock > 0 and 0.10 or 0) + 0.06*fz
    if math.random() < p then
      inject_shard(chaos)
      s.shard_cd = lerp(0.22, 0.02, chaos)
    else
      s.shard_cd = 0.05
    end
  end

  local win_min = lerp(0.050, 0.005, chaos)

  for _, v in ipairs(V) do
      local want_stutter = (s.drive > 0.10) and (math.random() < (0.04 + 0.78 * chaos))

    if want_stutter then
      local win = randf(win_min, lerp(0.18, 0.022, chaos))
      local center = util.clamp(s.phase + (math.random()*2 - 1) * lerp(0.03, 0.55, chaos), 0.0, BUF_LEN)
      local a = util.clamp(center - win * 0.5, 0.0, BUF_LEN - win)
      local b = a + win

      local off = (math.random()*2 - 1) * lerp(0.00, 0.12, s.ent + 0.6*fz)
      a = util.clamp(a + off, 0.0, BUF_LEN - win)
      b = a + win

      softcut.loop_start(v, a)
      softcut.loop_end(v, b)

      if math.random() < (0.25 * chaos) then
        softcut.position(v, randf(a, b))
      end
    else
      if math.random() < (0.06 + 0.22 * (s.ent + 0.4*fz)) then
        softcut.loop_start(v, 0.0)
        softcut.loop_end(v, BUF_LEN)
      end
    end

    local rr = 1.0 + (math.random()*2 - 1) * lerp(0.12, 2.1, chaos)
    if (burst_on or s.shock > 0) and math.random() < (0.08 + 0.18 * (s.ent + 0.5*fz)) then
      rr = -rr * lerp(0.8, 1.7, s.ent + 0.5*fz)
    end
    rr = util.clamp(rr, -2.0, 2.0)
    if math.abs(rr) < 0.06 then rr = 0.06 end
    softcut.rate(v, rr)

    softcut.pre_level(v, pre)
    softcut.rec_level(v, rec)

    if math.random() < (0.01 + 0.16 * chaos) then
      softcut.rec(v, 0)
    else
      softcut.rec(v, 1)
    end

    local osc = math.sin(s.fphase + (v * 1.3))
    local jitter = (math.random()*2 - 1) * (0.10 + 0.70 * s.ent + 0.30*fz) * (burst_on and 1 or 0.35)

    local base_fc = (v <= 2) and 900 or 350
    local hi_fc   = (v <= 2) and 9800 or 2600
    local lo_fc   = (v <= 2) and 60   or 40

    local fc = base_fc * (1 + f_depth * osc) * (1 + jitter)
    fc = util.clamp(fc, lo_fc, hi_fc)

    local rq = lerp(1.25, 0.45, util.clamp(s.ent + 0.7*fz, 0, 1))
    softcut.pre_filter_fc(v, fc)
    softcut.pre_filter_rq(v, rq)

    if v <= 2 then
      softcut.post_filter_fc(v, fc)
      softcut.post_filter_rq(v, rq)
    else
      softcut.post_filter_fc(v, util.clamp(fc * 0.85, lo_fc, hi_fc))
      softcut.post_filter_rq(v, lerp(0.95, 0.65, s.ent))
    end
  end

  softcut.level(1, out)
  softcut.level(2, out * 0.92)
  softcut.level(3, out * lerp(0.03, 0.30, chaos))
  softcut.level(4, out * lerp(0.03, 0.24, chaos))

end

local function apply_audio()
  if s.freeze.active then
    apply_audio_freeze()
  else
    apply_audio_normal()
  end
end

local function update_timers()
  if s.visual_burst > 0 then
    local dec = dt / math.max(0.06, s.burst_fade_s)
    s.visual_burst = math.max(0, s.visual_burst - dec)
  end
  if s.shock > 0 then s.shock = math.max(0, s.shock - dt) end
  if s.burst_time > 0 then s.burst_time = math.max(0, s.burst_time - dt) end
end

-- -----------------------------------------------------------------------------
-- MAIN LOOP
-- -----------------------------------------------------------------------------
local function tick()
  update_timers()
  apply_audio()
  if not s.freeze.active then
    update_particles()
  end

  if s.k2_down and (not s.freeze.active) then
    local p = util.clamp(0.10 + 0.55 * s.ent, 0.10, 0.80)
    if math.random() < p then
      s.visual_burst = math.max(s.visual_burst, randf(0.55, 1.0))
      s.burst_fade_s = lerp(0.18, 0.10, s.ent)
    end
  end

  redraw()
end

function init()
  math.randomseed(os.time())
  screen.aa(0)

  if hs then
    if hs.add_params then pcall(hs.add_params) end
    if hs.params then pcall(hs.params) end
  end

  init_particles()
  softcut_setup()
  if hs and hs.init then hs.init() end
  m = metro.init()
  m.time = dt
  m.event = tick
  m:start()

  redraw()
end

-- -----------------------------------------------------------------------------
-- CONTROLS
-- -----------------------------------------------------------------------------
function key(n, z)
  if n == 1 then
    s.k1_down = (z == 1)

    if z == 0 then
      s.delay_reset_latched = false
    elseif delay_reset_combo_active() and not s.delay_reset_latched then
      reset_delay_defaults()
      s.delay_reset_latched = true
    end
    return
  end

  if n == 2 then
    s.k2_down = (z == 1)

    if z == 1 then
      if delay_reset_combo_active() and not s.delay_reset_latched then
        reset_delay_defaults()
        s.delay_reset_latched = true
      else
        burst_shock()
      end
    else
      s.delay_reset_latched = false
    end
    return
  end

  if n == 3 then
    s.k3_down = (z == 1)

    if z == 1 then
      if delay_reset_combo_active() and not s.delay_reset_latched then
        reset_delay_defaults()
        s.delay_reset_latched = true
      elseif not s.k2_down then
        if s.freeze.active then
          exit_freeze()
          s.trace_px = {}
          s.trace_ln = {}
        else
          enter_freeze()
        end
      end
    else
      s.delay_reset_latched = false
    end
  end
end

function enc(n, d)
  if n == 1 then
    if s.k1_down then
      if d > 0 then
        set_delay_enabled(true)
      elseif d < 0 then
        set_delay_enabled(false)
      end
      return
    end

    s.vknob = clamp01(s.vknob + d / 120)
    return
  end

  if delay_combo_active() then
    if n == 2 then
      adjust_delay_rate(d)
      return
    elseif n == 3 then
      adjust_delay_feedback(d)
      return
    end
  end

  if n == 2 then
    s.fmod = clamp01(s.fmod + d / 120)
  elseif n == 3 then
    s.ent = clamp01(s.ent + d / 120)
  end
end

function cleanup()
  if m then m:stop() end
  softcut.poll_stop_phase()
  audio.level_adc_cut(0)

  for _, v in ipairs(V) do
    softcut.level(v, 0)
    softcut.rec_level(v, 0)
    softcut.pre_level(v, 0)
    softcut.rec(v, 0)
  end

  params:set("delay_on", 1) -- OFF
  softcut.level(6, 0)
  softcut.rec_level(6, 0)
  softcut.pre_level(6, 0)
  softcut.rec(6, 0)

  for _, src in ipairs(V) do
    softcut.level_cut_cut(src, 6, 0)
  end

  clear_matrix()
end
