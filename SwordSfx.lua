--!strict
-- ModuleScript "SwordSfx"  (parent: Tool "DarkV1", next to Client)
-- Everything about sound lives here. Client only calls:
--   local Sfx = require(tool:WaitForChild("SwordSfx"))
--   Sfx.swing(step, index, rollMax) -> returns a cancel function     Sfx.impact(index, gain, dull)
--   Sfx.blast()   Sfx.miss()   Sfx.equip()   Sfx.grab(gain, dull)   (grab = hit 3 catches: the roll sounds stop)
--   Sfx.setRoom(size, closed, material)   Sfx.doppler(ratio)
--
-- Parts: 1 SETTINGS, 2 MIX (groups + effects), 3 PLAYER (pools, voice limit), 4 CUES, 5 API.
-- Ideas borrowed from game engines (Unity / FMOD / Wwise): events made of layers, random
-- containers (never the same id twice), voice limits with priorities, mixer groups with
-- sidechain ducking, and a short low-pass "muffle" on big hits.

local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local Sfx = {}

----------------------------------------------------------------------------
-- 1. SETTINGS
----------------------------------------------------------------------------
local SOUND = {
	Volume = 1, -- master volume, 0 = silent
	WhooshLead = 0.05, -- seconds the hit 1/2 whoosh starts BEFORE the strike (a sound that comes before its picture is noticed sooner)
	MaxVoices = 10, -- sounds playing at once; only IMPORTANT sounds may go over this
	MinGap = 0.035, -- the same sound cannot start twice inside this many seconds
	MaxCopies = 4, -- most copies of one sound playing at the same time
}

-- Put one id, or several ids (they are rotated, never the same twice in a row).
local IDS: { [string]: { string } } = {
	-- EVERY hit has its own slot. They all start with the ORIGINAL ids; paste a new id (or several, they rotate) into a slot to change only that sound.
	swing1 = { "rbxassetid://124971777918932" }, -- whoosh of hit 1
	swing2 = { "rbxassetid://124971777918932" }, -- whoosh of hit 2
	swing3 = { "rbxassetid://128069607726183" }, -- whoosh of hit 3 (the crouch)
	hit1 = { "rbxassetid://121642440688650" }, -- impact of hit 1
	hit2 = { "rbxassetid://121642440688650" }, -- impact of hit 2
	tail1 = { "rbxassetid://123236325459253" }, -- late tail of hit 1
	tail2 = { "rbxassetid://123236325459253" }, -- late tail of hit 2
	tail3 = { "rbxassetid://123236325459253" }, -- tail of the grab and the slam
	dash = { "rbxassetid://9114157695" }, -- the roll
	gather = { "rbxassetid://84317873848171" }, -- the held breath after the catch
	blast = { "rbxassetid://122258480286280" }, -- the slam
	miss = { "rbxassetid://111254855668531" },
	equip = { "rbxassetid://83339137444985" },
}

-- which mixer group each sound goes through
local GROUP_OF: { [string]: string } = {
	swing1 = "swing", swing2 = "swing", swing3 = "swing", dash = "swing", miss = "swing", equip = "swing",
	hit1 = "impact", hit2 = "impact", tail1 = "impact", tail2 = "impact", tail3 = "impact",
	blast = "big", gather = "big",
}

-- these are never skipped when the mix is crowded
local IMPORTANT: { [string]: boolean } = { blast = true, swing3 = true, hit1 = true, hit2 = true, gather = true }

----------------------------------------------------------------------------
-- 2. MIX
----------------------------------------------------------------------------
local folder = Instance.new("Folder")
folder.Name = "DarkSwordSounds" -- 2D sounds: they never depend on where the Tool or Handle is
folder.Parent = SoundService

local master = Instance.new("SoundGroup")
master.Name = "DarkMaster"
master.Parent = folder

-- the whole mix: a gentle compressor (no ear-splitting peaks) and a light EQ (dB)
local compressor = Instance.new("CompressorSoundEffect")
compressor.Threshold = -14
compressor.Ratio = 4
compressor.Attack = 0.01
compressor.Release = 0.12
compressor.Parent = master
local masterEq = Instance.new("EqualizerSoundEffect")
masterEq.LowGain = 2
masterEq.MidGain = -1
masterEq.HighGain = 1
masterEq.Parent = master
local HIGH_NORMAL = masterEq.HighGain

local groups: { [string]: SoundGroup } = {}
for _, gname in { "swing", "impact", "big" } do
	local g = Instance.new("SoundGroup")
	g.Name = gname
	g.Parent = master
	groups[gname] = g
end

-- impacts get extra low end so they feel heavier than the whooshes
local impactEq = Instance.new("EqualizerSoundEffect")
impactEq.LowGain = 3
impactEq.MidGain = 0
impactEq.HighGain = 0
impactEq.Parent = groups.impact

-- the big sounds (blast, gather) get a short room
local reverb = Instance.new("ReverbSoundEffect")
reverb.DecayTime = 0.9
reverb.Density = 0.6
reverb.Diffusion = 0.7
reverb.DryLevel = 0
reverb.WetLevel = -9
reverb.Parent = groups.big

-- ROOM (laws 16, 17, 19): the impacts also get a room whose size, floor timbre and bass resonance follow the place you fight in (see Sfx.setRoom)
local roomReverb = Instance.new("ReverbSoundEffect")
roomReverb.DecayTime = 0.5
roomReverb.Density = 0.7
roomReverb.Diffusion = 0.8
roomReverb.DryLevel = 0
roomReverb.WetLevel = -20 -- starts almost dry; setRoom raises it in small rooms
roomReverb.Parent = groups.impact
-- MASKING (law 18): a loud sound hides quiet sounds of the same pitch range, so the whooshes lose some of their mid range while the big sound plays
-- SWISH BRIGHTNESS (aeroacoustics): a faster blade sheds smaller, quicker vortices, so its whoosh gets brighter; the Client sets this with the blade speed
local swishEq = Instance.new("EqualizerSoundEffect")
swishEq.LowGain = 0
swishEq.MidGain = 0
swishEq.HighGain = -6
swishEq.Parent = groups.swing
local maskEq = Instance.new("EqualizerSoundEffect")
maskEq.LowGain = 0
maskEq.MidGain = 0
maskEq.HighGain = 0
maskEq.Parent = groups.swing

-- SIDECHAIN DUCKING: whooshes and impacts get quieter by themselves while the "big" group
-- plays. If this Studio rejects SideChain, duck() lowers them by hand instead.
local sideChainOk = true
for _, gname in { "swing", "impact" } do
	local duckFx = Instance.new("CompressorSoundEffect")
	duckFx.Threshold = -36
	duckFx.Ratio = 10
	duckFx.Attack = 0.01
	duckFx.Release = 0.4
	if pcall(function() duckFx.SideChain = groups.big end) then
		duckFx.Parent = groups[gname]
	else
		sideChainOk = false
		duckFx:Destroy()
	end
end

----------------------------------------------------------------------------
-- 3. PLAYER
----------------------------------------------------------------------------
type Pool = { sounds: { Sound }, last: number }
local pools: { [string]: Pool } = {} -- [name] = the sounds of that name and the id index used last
local endsAt: { [Sound]: number } = {} -- os.clock() when a sound will be finished (for the voice count)
local lastStart: { [string]: number } = {} -- [name] = os.clock() of the last start
local lastPitch: { [string]: number } = {} -- [name] = last pitch used
local fadeToken: { [Sound]: {} } = {} -- token of a running fade
local ready = false -- true after the first sounds have loaded
local fadeInfo = TweenInfo.new(0.05)

local function newSound(name: string, id: string): Sound
	local s = Instance.new("Sound")
	s.Name = "Dark_" .. name
	s.SoundId = id
	s.SoundGroup = groups[GROUP_OF[name] or "swing"]
	s.Parent = folder
	return s
end

local preload: { Sound } = {}
for name, list in IDS do
	pools[name] = { sounds = {}, last = 0 }
	for _, id in list do
		local s = newSound(name, id)
		table.insert(pools[name].sounds, s)
		table.insert(preload, s)
	end
end

-- load everything, warn about ids that fail, then open the gate
task.spawn(function()
	pcall(function()
		game:GetService("ContentProvider"):PreloadAsync(preload, function(id, status)
			if status ~= Enum.AssetFetchStatus.Success then
				warn("[DarkSword] sound failed to load:", id, status)
			end
		end)
	end)
	local t0 = os.clock() -- one shared deadline, so a bad id cannot block the others
	for _, snd in preload do
		while not snd.IsLoaded and os.clock() - t0 < 8 do
			task.wait(0.1)
		end
		snd:Stop() -- clear any half-started state
	end
	ready = true
end)

local function voicesPlaying(now: number): number
	local n = 0
	for _, t in endsAt do
		if t > now then n += 1 end
	end
	return n
end

-- the next id of a name: rotates through the ids, never the same one twice in a row
local function pickSound(name: string): Sound?
	local pool = pools[name]
	local list = IDS[name]
	if not pool or #list == 0 then return nil end
	local idIndex = 1
	if #list > 1 then
		idIndex = math.random(#list - 1)
		if idIndex >= pool.last then idIndex += 1 end
	end
	pool.last = idIndex
	local id = list[idIndex]
	local busyCopies = 0
	local first
	for _, s in pool.sounds do
		if s.SoundId == id then
			first = first or s
			if not s.IsPlaying then return s end
			busyCopies += 1
		end
	end
	if busyCopies < SOUND.MaxCopies then
		local s = newSound(name, id)
		table.insert(pool.sounds, s)
		return s
	end
	return first -- every copy is busy: restart the first one
end

-- name, volume (1 = full), jitter (random pitch spread), base (pitch multiplier)
local function play(name: string, volume: number?, jitter: number?, base: number?, ramp: { number }?)
	if not ready then return nil end -- not loaded yet: skip instead of leaving a broken sound behind
	local now = os.clock()
	if lastStart[name] and now - lastStart[name] < SOUND.MinGap then return nil end
	if not IMPORTANT[name] and voicesPlaying(now) >= SOUND.MaxVoices then return nil end
	local s = pickSound(name)
	if not s then return nil end
	lastStart[name] = now
	fadeToken[s] = nil -- cancel a fade that is still running on this sound
	-- pitch jitter, never the same pitch twice in a row
	local b: number = base or 1
	local j: number = jitter or 0.05
	local pitch: number = b * (1 + (math.random() * 2 - 1) * j)
	local lp = lastPitch[name]
	if lp and math.abs(pitch - lp) < j * 0.3 then
		pitch = b * (1 + (lp > b and -1 or 1) * j * (0.4 + math.random() * 0.5))
	end
	lastPitch[name] = pitch
	s:Stop()
	s.Volume = (volume or 1) * SOUND.Volume
	s.PlaybackSpeed = pitch
	s:SetAttribute("p0", pitch) -- the pitch before any Doppler shift
	s:SetAttribute("v0", s.Volume) -- the volume before the speed scaling
	s.TimePosition = 0
	s:Play()
	if ramp then
		-- the pitch slides while the sound plays: { from, to, seconds } (multipliers of base), e.g. a whoosh that climbs with an upward cut
		s.PlaybackSpeed = b * ramp[1]
		TweenService:Create(s, TweenInfo.new(ramp[3], Enum.EasingStyle.Sine), { PlaybackSpeed = b * ramp[2] }):Play()
	end
	local length: number = s.TimeLength
	if length <= 0 then length = 2 end -- not loaded yet: guess 2 seconds
	local rate: number = math.max(pitch, 0.1)
	endsAt[s] = now + length / rate
	return s
end

-- quickly fade a sound that is still playing (so it does not overlap the impact)
local function fadeOut(name: string, time: number)
	local pool = pools[name]
	if not pool then return end
	for _, snd in pool.sounds do
		if snd.IsPlaying then
			local token = {}
			fadeToken[snd] = token
			TweenService:Create(snd, fadeInfo, { Volume = 0 }):Play()
			task.delay(time, function()
				if fadeToken[snd] == token then -- only if nobody restarted it meanwhile
					snd:Stop()
					endsAt[snd] = nil
				end
			end)
		end
	end
end

-- manual ducking (only used when the sidechain above is not available)
local duckToken = 0
local function duck(depth: number, hold: number)
	if sideChainOk then return end
	duckToken += 1
	local token = duckToken
	groups.swing.Volume = 1 - depth
	groups.impact.Volume = 1 - depth
	task.delay(hold, function()
		if duckToken ~= token then return end
		for _, gname in { "swing", "impact" } do
			TweenService:Create(groups[gname], TweenInfo.new(0.35, Enum.EasingStyle.Sine), { Volume = 1 }):Play()
		end
	end)
end

-- muffle: the highs drop for a moment on a big hit and come back (like a low-pass snapshot)
local muffleToken = 0
local function muffle(hold: number, back: number, depth: number?)
	muffleToken += 1
	local token = muffleToken
	masterEq.HighGain = HIGH_NORMAL + (-16 - HIGH_NORMAL) * (depth or 1) -- depth 1 = the full dip, less = a softer dip
	task.delay(hold, function()
		if muffleToken ~= token then return end
		TweenService:Create(masterEq, TweenInfo.new(back, Enum.EasingStyle.Sine), { HighGain = HIGH_NORMAL }):Play()
	end)
end

-- masking: the mid range of the quiet group dips for a moment and comes back (depth 0..1)
local maskToken = 0
local function mask(depth: number, hold: number)
	maskToken += 1
	local token = maskToken
	maskEq.MidGain = -9 * depth
	maskEq.HighGain = -4 * depth
	task.delay(hold, function()
		if maskToken ~= token then return end
		TweenService:Create(maskEq, TweenInfo.new(0.4, Enum.EasingStyle.Sine), { MidGain = 0, HighGain = 0 }):Play()
	end)
end

-- ROOM + FLOOR (laws 16, 17, 19). The Client measures the place (average wall distance in studs, how closed it is 0..1, the floor material).
--  16: Sabine's idea: reverb time grows with the room size (T ~ 0.107 * length in metres); open air = almost no echo
--  17: hard floors ring (more highs and mids), soft floors swallow them (fewer highs)
--  19: a small closed room boosts the low notes (room mode f = c / 2L; below ~8 m the bass swells)
local FLOOR_EQ: { [Enum.Material]: { number } } = { -- { low, mid, high } dB added to the impact group
	[Enum.Material.Metal] = { 0, 1.5, 3.5 }, [Enum.Material.DiamondPlate] = { 0, 1.5, 3.5 }, [Enum.Material.CorrodedMetal] = { 0, 1, 2.5 },
	[Enum.Material.Ice] = { 0, 0.5, 2.5 }, [Enum.Material.Glass] = { 0, 0.5, 3 },
	[Enum.Material.Wood] = { 1, 1.5, 0 }, [Enum.Material.WoodPlanks] = { 1, 1.5, 0 },
	[Enum.Material.Concrete] = { 1, 0, 1 }, [Enum.Material.Pavement] = { 1, 0, 1 }, [Enum.Material.Brick] = { 1, 0.5, 0.5 },
	[Enum.Material.Slate] = { 1, 0, 1.5 }, [Enum.Material.Granite] = { 1, 0, 1.5 }, [Enum.Material.Marble] = { 0.5, 0, 2 }, [Enum.Material.Cobblestone] = { 1, 0.5, 0.5 },
	[Enum.Material.Grass] = { -1, -1, -4 }, [Enum.Material.LeafyGrass] = { -1, -1, -4 }, [Enum.Material.Ground] = { -0.5, -0.5, -3 },
	[Enum.Material.Mud] = { -1.5, -1.5, -5 }, [Enum.Material.Sand] = { -1.5, -1, -5 }, [Enum.Material.Snow] = { -2, -2, -6 },
}
function Sfx.setRoom(size: number, closed: number, material: Enum.Material)
	if type(size) ~= "number" or size ~= size or type(closed) ~= "number" or closed ~= closed then return end
	closed = math.clamp(closed, 0, 1)
	local lenM = math.clamp(size * 2 * 0.28, 2, 60) -- room length in metres (1 stud = 0.28 m)
	local rt = math.clamp(0.107 * lenM, 0.25, 3.5)
	local eq = FLOOR_EQ[material] or { 0, 0, 0 }
	local bass = (closed > 0.5 and lenM < 8) and (8 - lenM) / 6 * 2.5 or 0 -- up to +2.5 dB in a small closed room
	local info = TweenInfo.new(0.35, Enum.EasingStyle.Sine)
	TweenService:Create(roomReverb, info, { WetLevel = -20 + closed * 12 }):Play() -- open air -20 dB (almost none), a closed room -8 dB
	roomReverb.DecayTime = rt * (0.35 + 0.65 * closed)
	TweenService:Create(impactEq, info, { LowGain = 3 + eq[1] + bass, MidGain = eq[2], HighGain = eq[3] }):Play()
end

----------------------------------------------------------------------------
-- 4. CUES  (a cue = a list of layers, played together)
--   s = sound name   vol = volume   jitter = random pitch spread   pitch = pitch multiplier
--   at = "windup" / "gather" (time anchor of the swing)   delay = seconds after the anchor
--   rand = extra random delay up to this many seconds (so layers never line up the same way twice)
----------------------------------------------------------------------------
local CUES: { [string]: any } = {
	-- the sounds are the originals; each hit only picks its own slot (see IDS), the pitch stays natural
	swing1 = { { s = "swing1", vol = 1, jitter = 0.05, at = "windup", delay = -SOUND.WhooshLead } },
	swing2 = { { s = "swing2", vol = 1, jitter = 0.05, at = "windup", delay = -SOUND.WhooshLead } },
	-- HIT 3: the ORIGINAL sounds. The crouch whoosh and the dash start together at the roll, as before.
	swingFinisher = {
		{ s = "swing3", vol = 1, jitter = 0.03, at = "windup" },
		{ s = "dash", vol = 0.9, jitter = 0.03, at = "windup" },
	},
	-- the catch (the roll is over, the enemy goes up): the original hit-3 impact (low whoosh + heavy tail) and the held breath
	grab = {
		duck = { 0.35, 0.5 },
		{ s = "swing3", vol = 1, jitter = 0.03, pitch = 0.94 },
		{ s = "tail3", vol = 0.8, jitter = 0.03, pitch = 0.90, delay = 0.06 },
		{ s = "gather", vol = 0.9, jitter = 0.02 },
	},
	impact = {
		{ fade = "swing1",
			{ s = "hit1", vol = 1.05, jitter = 0.04 },
			{ s = "hit2", vol = 0.16, jitter = 0, pitch = 1.012, delay = 0.04 }, -- laws 76/77 (beating): the same impact 1.2 % higher, a little later; the two pitches drift in and out of phase and the hit hums
			{ s = "tail1", vol = 0.45, jitter = 0.05, delay = 0.045, rand = 0.02 },
			{ s = "tail2", vol = 0.2, jitter = 0.01, pitch = 1.7, delay = 0.09, ramp = { 1.0, 0.94, 0.5 } } }, -- law 73/75: the blade rings on a high pitch and the ring dies away
		{ fade = "swing2",
			{ s = "hit2", vol = 1.1, jitter = 0.04, pitch = 1.04 },
			{ s = "hit1", vol = 0.16, jitter = 0, pitch = 1.04 * 0.988, delay = 0.04 }, -- laws 76/77 (beating): the same impact 1.2 % lower
			{ s = "tail2", vol = 0.4, jitter = 0.05, delay = 0.045, rand = 0.02 },
			{ s = "tail1", vol = 0.22, jitter = 0.01, pitch = 1.8, delay = 0.09, ramp = { 1.0, 0.94, 0.5 } } },
		{ duck = { 0.35, 0.5 },
			{ s = "swing3", vol = 1, jitter = 0.03 }, -- (fallback, the real hit 3 sounds are grab and blast)
			{ s = "tail3", vol = 0.8, jitter = 0.03, delay = 0.06 } },
	},
	-- the slam: the blast, a long tail, and a soft tail again with the camera's aftershock
	blast = { duck = { 0.5, 0.6 }, muffle = { 0.12, 0.4 }, { s = "blast", vol = 1, jitter = 0.03 },
		{ s = "tail3", vol = 0.7, jitter = 0.02, pitch = 0.55, delay = 0.03 } }, -- the original slam sound + law 80: a low rumble under it for weight
	miss = { { s = "miss", vol = 1, jitter = 0.05 } },
	equip = { { s = "equip", vol = 1, jitter = 0.02 } },
}

-- plays a cue; returns the list of delayed threads (so they can be cancelled)
-- gain = distance / blocking loudness (1 = full), dull = how much the highs are cut (0..1): see Sfx.impact
local function fire(cue: any, anchors: { [string]: number }?, gain: number?, dull: number?, pitchMul: number?): { thread }
	local g: number = gain or 1
	local pm: number = pitchMul or 1
	if cue.fade then fadeOut(cue.fade, 0.05) end
	if cue.duck then
		duck(cue.duck[1], cue.duck[2])
		mask(math.clamp(cue.duck[1] * 1.4, 0, 1), cue.duck[2]) -- law 18
	end
	if cue.muffle then muffle(cue.muffle[1], cue.muffle[2])
	elseif dull and dull > 0.05 then muffle(0.25, 0.4, dull) end
	local threads = {}
	for _, layer in ipairs(cue) do
		local delay = (anchors and layer.at and anchors[layer.at] or 0) + (layer.delay or 0)
		if layer.rand then delay += math.random() * layer.rand end
		if delay <= 0 then
			play(layer.s, (layer.vol or 1) * g, layer.jitter, (layer.pitch or 1) * pm, layer.ramp)
		else
			table.insert(threads, task.delay(delay, play, layer.s, (layer.vol or 1) * g, layer.jitter, (layer.pitch or 1) * pm, layer.ramp))
		end
	end
	return threads
end

local function cancelAll(threads: { thread })
	for _, th in threads do
		pcall(task.cancel, th)
	end
end

----------------------------------------------------------------------------
-- 5. API  (the rest of the script only calls these)
----------------------------------------------------------------------------
-- the roll sounds of hit 3: a repeating whoosh that goes on until Sfx.grab or Sfx.miss
local rollThreads: { thread } = {}
local function stopRoll()
	cancelAll(rollThreads)
	rollThreads = {}
	fadeOut("dash", 0.08)
end

-- the swing starts; returns a function that cancels everything not yet played
-- index = 1, 2 or 3 (each hit has its own sound)
function Sfx.swing(step: any, index: number, rollMax: number?): () -> ()
	local threads
	if step.finisher then
		threads = fire(CUES.swingFinisher, { windup = step.windupTime })
		stopRoll()
		-- safety: if neither a catch nor a miss arrives, the loop is faded out after the longest roll
		table.insert(rollThreads, task.delay(step.windupTime + (rollMax or 3) + 0.3, stopRoll))
		return function() cancelAll(threads) stopRoll() end
	elseif index == 2 or step.launch then
		threads = fire(CUES.swing2, { windup = step.windupTime })
	else
		threads = fire(CUES.swing1, { windup = step.windupTime })
	end
	return function() cancelAll(threads) end
end
-- gain / dull come from the Client (distance to the hit and anything standing in the way)
-- strength (0..1) = how hard the hit is: harder = louder and a little lower (more mass behind it), like a heavier blow on a real object
function Sfx.impact(index: number, gain: number?, dull: number?, strength: number?)
	local I = math.clamp(strength or 0.6, 0, 1)
	fire(CUES.impact[index] or CUES.impact[1], nil, (gain or 1) * (0.75 + 0.5 * I), dull, 1.06 - 0.12 * I)
end
function Sfx.grab(gain: number?, dull: number?)
	stopRoll()
	fire(CUES.grab, nil, gain, dull)
end
function Sfx.blast() fire(CUES.blast) end
function Sfx.miss()
	stopRoll()
	fire(CUES.miss)
end
function Sfx.equip() fire(CUES.equip) end
-- DOPPLER (law 9): the Client says how the pitch of the swing sounds must change right now (ratio = c / (c - v_toward_listener))
-- speed = tip speed in studs/s. The same speed also drives the whoosh (Selfridge & Moffat 2017, sword aeroacoustics: pitch and gain follow the swing speed):
--   pitch a little higher and louder the faster the blade moves (the loudness of such a dipole source rises steeply with speed), and brighter (swishEq).
function Sfx.doppler(ratio: number, speed: number?)
	local k = math.clamp((speed or 45) / 90, 0, 1)
	local pitchK = ratio * (0.92 + 0.2 * k)
	local volK = 0.35 + 0.65 * k ^ 1.5
	swishEq.HighGain = -6 + 9 * k
	for _, name in { "swing1", "swing2", "swing3", "dash" } do
		local pool = pools[name]
		if pool then
			for _, snd in pool.sounds do
				local p0 = snd:GetAttribute("p0")
				local v0 = snd:GetAttribute("v0")
				if snd.IsPlaying and p0 then
					snd.PlaybackSpeed = p0 * pitchK
					if v0 then snd.Volume = v0 * volK end
				end
			end
		end
	end
end

return Sfx
