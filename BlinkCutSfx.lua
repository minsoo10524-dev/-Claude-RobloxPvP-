--!strict
-- ModuleScript "BlinkCutSfx" (parent: Tool "TrueKatana")
-- The sound of BLINK CUT, with a mix of its own (the normal attack has its own mixer in SwordSfx; this one is only for the Z skill):
--   master  : a gentle compressor (no ear-splitting peaks) and a cold EQ (a little more high end, a little less mid)
--     dash   : the blink                          cuts : the 25 quick cuts (whoosh + impact of each)
--     finish : the catch and the throw, with a cold hall (reverb) behind them
--   * DUCKING: while the finish plays, the dash and the cuts get quieter (the big sound makes room for itself). It is done by hand, by lowering
--     the volume of those two buses for a moment: a SideChain compressor could squash EVERY sound of the bus when the Studio treats it differently.
--   * RISING FLURRY (physics of sound): the faster something moves, the higher and brighter its whoosh. The cuts speed up in the ear: the pitch of
--     each whoosh and impact rises with the progress of the flurry (p = 0 .. 1) and the high end of the whole "cuts" bus opens up with it. Every
--     fifth cut is an accent, a little louder, so the ear can count them and 25 sounds do not turn into noise.
--   * Roll-off with distance (the sounds are 3D, they sit on the body that makes them) and a tiny random pitch change on every sound.
-- The sound ids are the ones SwordSfx already uses.

local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

type Cue = { id: string, bus: string, volume: number, from: number, to: number, jitter: number }
local CUES: { [string]: Cue } = {
	windup = { id = "rbxassetid://84317873848171", bus = "cuts", volume = 0.6, from = 1.25, to = 1.0, jitter = 0.04 },
	dash = { id = "rbxassetid://9114157695", bus = "dash", volume = 0.8, from = 0.9, to = 1.4, jitter = 0.05 },
	cross = { id = "rbxassetid://124971777918932", bus = "dash", volume = 0.9, from = 1.05, to = 1.5, jitter = 0.05 }, -- the cross cut of a plain blink
	whoosh = { id = "rbxassetid://124971777918932", bus = "cuts", volume = 0.7, from = 1.0, to = 1.1, jitter = 0.06 },
	impact = { id = "rbxassetid://121642440688650", bus = "cuts", volume = 1.0, from = 1.0, to = 0.95, jitter = 0.06 },
	tail = { id = "rbxassetid://123236325459253", bus = "finish", volume = 0.5, from = 1.0, to = 0.9, jitter = 0.04 },
	catchHit = { id = "rbxassetid://121642440688650", bus = "finish", volume = 1.0, from = 0.7, to = 0.6, jitter = 0.03 }, -- the chop: lower and heavier
	gather = { id = "rbxassetid://84317873848171", bus = "finish", volume = 0.7, from = 1.1, to = 0.85, jitter = 0.03 }, -- the held breath
	blast = { id = "rbxassetid://122258480286280", bus = "finish", volume = 1.0, from = 1.0, to = 0.92, jitter = 0.02 }, -- the throw
}
local MIN_GAP = 0.04 -- the same cue never starts twice within this time
local LIFE = 4 -- seconds until a sound is removed
local ROLLOFF_MIN, ROLLOFF_MAX = 12, 140
local RISE = 0.45 -- how much higher the pitch of the cuts is at the end of the flurry (1 + RISE)
local BRIGHT = 5 -- dB the high end of the cuts bus opens up by the end of the flurry
local ACCENT = 1.4 -- gain of every fifth cut

--------------------------------------------------------------------------------
-- The mix
--------------------------------------------------------------------------------
local folder = Instance.new("Folder")
folder.Name = "BlinkCutSounds"
folder.Parent = SoundService

local master = Instance.new("SoundGroup")
master.Name = "BlinkMaster"
master.Parent = folder
local compressor = Instance.new("CompressorSoundEffect")
compressor.Threshold = -10
compressor.Ratio = 2
compressor.Attack = 0.01
compressor.Release = 0.15
compressor.Parent = master
local coldEq = Instance.new("EqualizerSoundEffect")
coldEq.LowGain = 1
coldEq.MidGain = -1
coldEq.HighGain = 3
coldEq.Parent = master

local buses: { [string]: SoundGroup } = {}
for _, name in { "dash", "cuts", "finish" } do
	local g = Instance.new("SoundGroup")
	g.Name = name
	g.Parent = master
	buses[name] = g
end

local hall = Instance.new("ReverbSoundEffect") -- a cold hall behind the finish
hall.DecayTime = 1.4
hall.Density = 0.7
hall.Diffusion = 0.8
hall.DryLevel = 0
hall.WetLevel = -10
hall.Parent = buses.finish

local cutsEq = Instance.new("EqualizerSoundEffect") -- opens up with the flurry
cutsEq.LowGain = 0
cutsEq.MidGain = 0
cutsEq.HighGain = 0
cutsEq.Parent = buses.cuts

-- ducking by hand: the dash and the cuts go down while the finish plays and come back after it
local duckToken = 0
local function duck(depth: number, hold: number)
	duckToken += 1
	local token = duckToken
	for _, name in { "dash", "cuts" } do buses[name].Volume = depth end
	task.delay(hold, function()
		if token ~= duckToken then return end -- a newer duck is running
		for _, name in { "dash", "cuts" } do
			TweenService:Create(buses[name], TweenInfo.new(0.5, Enum.EasingStyle.Sine), { Volume = 1 }):Play()
		end
	end)
end

local lastStart: { [string]: number } = {}
local Sfx = {}

task.spawn(function()
	local ids: { string } = {}
	for _, cue in CUES do table.insert(ids, cue.id) end
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(ids, function(id: string, status: Enum.AssetFetchStatus)
			if status ~= Enum.AssetFetchStatus.Success then warn("[BlinkCutSfx] a sound did not load:", id, status) end
		end)
	end)
	if not ok then warn("[BlinkCutSfx] could not preload the sounds:", err) end
end)

local function play(name: string, at: BasePart, seconds: number?, gain: number?, pitch: number?)
	local cue = CUES[name]
	if not cue or not at.Parent then return end
	local now = os.clock()
	if lastStart[name] and now - lastStart[name] < MIN_GAP then return end
	lastStart[name] = now
	local sound = Instance.new("Sound")
	sound.SoundId = cue.id
	sound.SoundGroup = buses[cue.bus]
	sound.Volume = cue.volume * (gain or 1)
	local start = cue.from * (pitch or 1) * (1 + (math.random() * 2 - 1) * cue.jitter)
	sound.PlaybackSpeed = start
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = ROLLOFF_MIN
	sound.RollOffMaxDistance = ROLLOFF_MAX
	sound.Parent = at
	sound:Play()
	if seconds and cue.to ~= cue.from then
		TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { PlaybackSpeed = start * cue.to / cue.from }):Play()
	end
	Debris:AddItem(sound, LIFE)
end

-- the progress of the flurry (0 .. 1) sets the brightness of the whole "cuts" bus
local function progress(p: number)
	cutsEq.HighGain = BRIGHT * math.clamp(p, 0, 1)
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------
function Sfx.windup(at: BasePart)
	progress(0)
	play("windup", at, 0.09)
end
function Sfx.dash(at: BasePart, seconds: number) play("dash", at, seconds) end
function Sfx.cut(at: BasePart) -- the cross cut of a plain blink
	play("cross", at, 0.15)
	task.delay(0.08, play, "tail", at, 0.3)
end

-- one cut of the flurry: the whoosh starts a little BEFORE the strike (the Client calls it when the swing starts), the impact AT the strike.
-- index = 1 or 2, p = the progress of the flurry (0 .. 1), n = the number of this cut
function Sfx.whoosh(at: BasePart, index: number, p: number, n: number)
	progress(p)
	local accent = if n % 5 == 0 then ACCENT else 1
	play("whoosh", at, 0.1, accent, (1 + RISE * p) * (if index == 2 then 1.06 else 1)) -- hit 2 a little higher than hit 1
end
function Sfx.impact(at: BasePart, index: number, p: number, n: number)
	local accent = if n % 5 == 0 then ACCENT else 1
	play("impact", at, nil, accent, (1 + RISE * 0.6 * p) * (if index == 2 then 1.04 else 1))
end

-- the catch: the chop and the held breath
function Sfx.catch(at: BasePart)
	progress(1)
	play("catchHit", at, 0.2)
	play("gather", at, 0.3)
end

-- the throw: the blast and its tail (the dash and the cuts duck under it)
-- the quiet BEFORE the throw (expectation and release): the whole mix drops for a moment, so the blast that follows is felt much bigger
function Sfx.hush(seconds: number)
	master.Volume = 0.25
	task.delay(seconds, function()
		TweenService:Create(master, TweenInfo.new(0.08), { Volume = 1 }):Play()
	end)
end

function Sfx.finish(at: BasePart)
	master.Volume = 1
	duck(0.35, 0.9)
	play("blast", at, 0.4) -- the low thump
	play("impact", at, nil, 0.7, 1.7) -- the high ring on top of it (a low sound and a high one together feel bigger)
	task.delay(0.15, play, "tail", at, 0.5)
end

-- the landing of the thrown enemy: the heaviest sound of the skill. k = how hard (about 0.5 .. 1.6, from the speed of the impact); the later
-- bounces are softer. A lower pitch for a harder impact: more mass behind it sounds lower (the same rule as the impacts of the normal hits).
function Sfx.land(at: BasePart, k: number)
	duck(0.3, 0.7)
	local low = 0.85 - 0.12 * math.clamp(k - 0.5, 0, 1)
	play("blast", at, 0.5, 1.2 * k, low)
	play("catchHit", at, 0.3, 1.0 * k, low)
	task.delay(0.12, play, "tail", at, 0.6, 0.8 * k, low)
end

-- the last cut (a heavy chop, no blast): a low thump and the impact together, a short tail; the dash and the quick cuts duck under it for a moment
function Sfx.finishHit(at: BasePart)
	duck(0.5, 0.5)
	play("catchHit", at, 0.2, 1.1, 1.0)
	play("impact", at, nil, 1.0, 0.9)
	task.delay(0.08, play, "tail", at, 0.4, 0.8, 1)
end

function Sfx.hit(at: BasePart) play("impact", at) end -- (kept for older callers)

return Sfx
