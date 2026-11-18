--!strict
-- Luau | Script (DummyRespawn) | parent: the dummy Model (Rig) | server only
-- GOJO dummy:
--   * a smooth health bar (the white "damage trail" follows the red-to-cyan bar a moment later)
--   * death = real physics (the body falls with broken joints, then it breaks into sparks and shrinks to nothing; no see-through fade)
--   * respawn = blink-in flash + DOMAIN EXPANSION (springs for the animation, timed with sound, vfx and the camera of nearby players)
--   * when nobody has hit it for a while, it shows off: HOLLOW PURPLE (blue and red orbs fly into the palm and merge)
-- The camera part is in "GojoCamera" (a LocalScript); this script only tells the clients "what happened, where, how strong" through a RemoteEvent.

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local PhysicsService = game:GetService("PhysicsService")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local CONFIG = {
	RespawnTime = 2.4, -- seconds after death (the body needs ~2.7 s to fall and break up)
	CorpseTime = 0.1, -- the hit stop (the body hangs still), then it bursts apart -- seconds the body lies there before it breaks up
	BreakUpTime = 0.85, -- seconds of the break-up
	MaxRespawnRetries = 3,
	FlexDelay = 7, -- seconds without being hit before it shows off
	CameraRange = 150, -- studs: clients farther away get no camera effect

	ShockwaveRadius = 38,
	ShockwaveSpeed = 40, -- studs/second velocity change at the center
	ShockwavePushPlayers = true,
	MaxPushedAssemblies = 60,
	RockCount = 30,
}

local SOUND = {
	domain = "rbxassetid://138283818946733", -- the domain voice and music
	impact = "rbxassetid://121642440688650", -- the same sounds the sword uses
	blast = "rbxassetid://122258480286280",
	windup = "rbxassetid://84317873848171",
	tail = "rbxassetid://123236325459253",
}
-- the hit pictures of the sword (the same ids as the Z skill)
local STAR_IMAGES = { "rbxassetid://10198434999", "rbxassetid://14622697144", "rbxassetid://10198439352" }

local GROUND_IMAGE = "rbxassetid://17000892071" -- the picture on the floor (the sigil, the rings)
local ELBOW_SIGN = 1 -- flip the sign if a forearm or shin bends the wrong way on your R15 rig
local KNEE_SIGN = 1

local PARTICLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local VIOLET = Color3.fromRGB(140, 80, 255)
local CYAN = Color3.fromRGB(120, 200, 255)
local WHITE = Color3.fromRGB(235, 225, 255)
local BLUE = Color3.fromRGB(70, 140, 255)
local RED = Color3.fromRGB(255, 70, 90)
local PURPLE = Color3.fromRGB(170, 70, 255)
local ZERO = Vector3.zero
local TAU = math.pi * 2
local rad = math.rad

--------------------------------------------------------------------------------
-- Setup and early exits
--------------------------------------------------------------------------------
local model = script.Parent
if not model or not model:IsA("Model") then
	warn("[DummyRespawn] Parent must be a Model.")
	return
end

model:WaitForChild("Humanoid", 10)
local foundHumanoid = model:FindFirstChildOfClass("Humanoid")
if not foundHumanoid then
	warn("[DummyRespawn] No Humanoid found in " .. model:GetFullName())
	return
end
local humanoid: Humanoid = foundHumanoid
local respawnParent: Instance = model.Parent or workspace

-- the channel to the camera script of the players
local fxRemote = ReplicatedStorage:FindFirstChild("GojoFx") :: RemoteEvent?
if not fxRemote then
	local made = Instance.new("RemoteEvent")
	made.Name = "GojoFx"
	made.Parent = ReplicatedStorage
	fxRemote = made
end

local function sendFx(kind: string, pos: Vector3, power: number)
	local remote = fxRemote
	if not remote then return end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") and (hrp.Position - pos).Magnitude <= CONFIG.CameraRange then
			remote:FireClient(player, kind, pos, power)
		end
	end
end

--------------------------------------------------------------------------------
-- Pose data (degrees, studs). Missing channel = 0 = neutral stance.
-- Arms/legs use elevation + azimuth: lift the limb forward by "el", then swing it outward by "az".
--   lean: forward +   twist: turn left +   tilt: lean left +   headP: look up +   headY: look left +   headR: tilt left +
--   *_elb: elbow bend (R15 only)   *_kn: knee bend (R15 only)
--------------------------------------------------------------------------------
type Pose = { [string]: number }

local IDLE: Pose = {}

local ANTICIPATE: Pose = { -- crouch and coil, looking down
	rootY = -0.35, lean = 16, headP = -14,
	aR_el = -18, aR_az = 12, aR_elb = 15,
	aL_el = -18, aL_az = 12, aL_elb = 15,
	lR_fl = 18, lR_az = 6, lR_kn = 30,
	lL_fl = -8, lL_az = 6, lL_kn = 10,
}

local SEAL: Pose = { -- hover up, the fingers crossed in front of the chest
	rootY = 1.1, lean = -6, tilt = 6, headP = -4, headR = 10,
	aR_el = 75, aR_az = -30, aR_elb = 105,
	aL_el = 62, aL_az = -24, aL_elb = 118,
	lR_fl = -12, lR_az = 3, lR_kn = 20,
	lL_fl = 8, lL_az = 3, lL_kn = 28,
}

local MUDRA: Pose = { -- the hand sign of the domain: the right hand rises to the face (the crossed fingers), the left hand supports it under the chest
	rootY = 0.9, lean = -3, twist = -6, tilt = 3, headP = -9, headR = 7,
	aR_el = 96, aR_az = -14, aR_elb = 122, wR = -28,
	aL_el = 58, aL_az = -12, aL_elb = 104, wL = 18,
	lR_fl = -8, lR_az = 4, lR_kn = 16,
	lL_fl = 10, lL_az = 4, lL_kn = 22,
}

local OPEN: Pose = { -- "tenkai": the hands part, the chest opens, the head comes up
	rootY = 1.4, lean = -12, twist = 4, headP = 14,
	aR_el = 96, aR_az = 44, aR_elb = 48, wR = 12,
	aL_el = 92, aL_az = 44, aL_elb = 52, wL = 12,
	lR_fl = -6, lR_az = 10, lR_kn = 14,
	lL_fl = -2, lL_az = 10, lL_kn = 16,
}

local EXPAND: Pose = { -- the last moment before the burst: arms wide, head back, the whole body drawn up
	rootY = 1.8, lean = -20, headP = 24,
	aR_el = 108, aR_az = 82, aR_elb = 14, wR = 22,
	aL_el = 108, aL_az = 82, aL_elb = 14, wL = 22,
	lR_fl = -4, lR_az = 14, lR_kn = 12,
	lL_fl = -4, lL_az = 14, lL_kn = 12,
}

local IMPACT: Pose = { -- the landing: deep crouch, arms flung down and out
	rootY = -0.75, lean = 22, headP = -6,
	aR_el = 40, aR_az = 70, aR_elb = 30, wR = -15,
	aL_el = 40, aL_az = 70, aL_elb = 30, wL = -15,
	lR_fl = 14, lR_az = 16, lR_kn = 45,
	lL_fl = 14, lL_az = 16, lL_kn = 45,
}

local CONFIDENT: Pose = { -- one hand up, the other at the hip, the head tilted: "nah, I'd win"
	lean = -4, twist = -10, tilt = -4, headP = 8, headY = 10, headR = -12,
	aR_el = 120, aR_az = 18, aR_elb = 30,
	aL_el = -12, aL_az = -2, aL_elb = 55,
	lR_fl = 12, lR_az = 6, lR_kn = 8,
	lL_fl = -8, lL_az = 6, lL_kn = 4,
}

local BF_REACH: Pose = { -- the show-off, part 1: the right hand rises to the face, the other arm hangs relaxed, a calm look ahead
	rootY = 0.2, lean = -4, twist = 4, headP = 4, headY = -4,
	aR_el = 128, aR_az = -6, aR_elb = 128, wR = -12,
	aL_el = 6, aL_az = 12, aL_elb = 24,
	lR_fl = -3, lR_az = 6, lR_kn = 6,
	lL_fl = 3, lL_az = 6, lL_kn = 10,
}

local BF_LIFTED: Pose = { -- part 2: the blindfold is up, the head tips back a little: "see for yourself"
	rootY = 0.3, lean = -8, twist = 6, headP = 14, headY = 6, headR = -9,
	aR_el = 136, aR_az = -4, aR_elb = 134, wR = -6,
	aL_el = 6, aL_az = 12, aL_elb = 24,
	lR_fl = -3, lR_az = 6, lR_kn = 6,
	lL_fl = 3, lL_az = 6, lL_kn = 10,
}

local BF_PUSH: Pose = { -- part 3: the hand pushes the blindfold back down, the head comes back to level
	rootY = 0.2, lean = -4, twist = 2, headP = 2, headY = 0, headR = -2,
	aR_el = 126, aR_az = -6, aR_elb = 126, wR = -14,
	aL_el = 6, aL_az = 12, aL_elb = 24,
	lR_fl = -3, lR_az = 6, lR_kn = 6,
	lL_fl = 3, lL_az = 6, lL_kn = 10,
}

type Cue = { t: number, pose: Pose?, cue: string? }

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------
local function tween(inst: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local tw = TweenService:Create(inst, info, goal)
	tw:Play()
	return tw
end

local function seq(keys: { NumberSequenceKeypoint }): NumberSequence
	return NumberSequence.new(keys)
end

local function playSound(id: string, parent: Instance, volume: number, pitch: number)
	local snd = Instance.new("Sound")
	snd.SoundId = id
	snd.Volume = volume
	snd.PlaybackSpeed = pitch * (1 + (math.random() - 0.5) * 0.06)
	snd.RollOffMaxDistance = 160
	snd.Parent = parent
	pcall(function()
		snd:Play()
	end)
	Debris:AddItem(snd, 8)
end

local function makeFxPart(shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	p.Size = size
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.CFrame = cf
	p.Parent = workspace
	return p
end

local function animateAndRemove(p: Part, duration: number, goal: { [string]: any }, style: Enum.EasingStyle)
	tween(p, TweenInfo.new(duration, style, Enum.EasingDirection.Out), goal)
	Debris:AddItem(p, duration + 0.15)
end

local function findGroundY(center: Vector3): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	local result = workspace:Raycast(center, Vector3.new(0, -25, 0), params)
	if result then
		return result.Position.Y
	end
	return center.Y - 3
end

-- The floor picture is a SPRITE SHEET (4 x 4 cells, the first cell is empty): cells 1-3 the ring opens, 4-11 it swirls, 12-15 it fades out.
-- The sheet is shown one cell at a time (ImageRectOffset), so it is ONE ring, not sixteen. The cell size is 256 px if the sheet is 1024 x 1024 (assumed).
local SHEET_CELL = 256
local function groundMark(center: Vector3, diameter: number, color: Color3, growTime: number, hold: number?): (Part, () -> ())
	local groundY = findGroundY(center)
	local p = Instance.new("Part")
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.new(diameter * 0.3, 0.05, diameter * 0.3)
	p.CFrame = CFrame.new(center.X, groundY + 0.1, center.Z) * CFrame.Angles(0, math.random() * TAU, 0)
	p.Parent = workspace

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(512, 512)
	gui.Parent = p
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Image = GROUND_IMAGE
	label.ImageColor3 = color
	label.ImageRectSize = Vector2.new(SHEET_CELL, SHEET_CELL)
	label.Parent = gui

	tween(p, TweenInfo.new(growTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(diameter, 0.05, diameter) })

	local finishing = false
	local function finish()
		finishing = true
	end
	if hold then
		task.delay(hold, finish)
	end

	task.spawn(function()
		local function show(cell: number)
			label.ImageRectOffset = Vector2.new((cell % 4) * SHEET_CELL, (cell // 4) * SHEET_CELL)
		end
		local fps = 16
		for cell = 1, 3 do -- opening
			if not p.Parent then return end
			show(cell)
			task.wait(1 / fps)
		end
		local cell = 4
		while not finishing do -- swirling (cells 4..11, round and round)
			if not p.Parent then return end
			show(cell)
			cell = if cell >= 11 then 4 else cell + 1
			task.wait(1 / fps)
		end
		for outro = 12, 15 do -- fading out
			if not p.Parent then return end
			show(outro)
			task.wait(1 / 12)
		end
		p:Destroy()
	end)
	return p, finish
end

local function newEmitterHolder(pos: Vector3): (Part, Attachment)
	local holder = makeFxPart(Enum.PartType.Ball, Vector3.one, CFrame.new(pos), WHITE, 1)
	local att = Instance.new("Attachment")
	att.Parent = holder
	return holder, att
end

-- The hit pictures of the sword, layered and spinning in different directions: one star made of three pictures (the same idea as the Z skill)
local function starBurst(pos: Vector3, size: number)
	local anchor = makeFxPart(Enum.PartType.Ball, Vector3.one * 0.2, CFrame.new(pos), WHITE, 1)
	Debris:AddItem(anchor, 1.2)
	local tints = { WHITE, CYAN, VIOLET }
	for i, image in STAR_IMAGES do
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromScale(size * (1.15 - 0.2 * i), size * (1.15 - 0.2 * i)) -- the first is the biggest
		gui.AlwaysOnTop = false
		gui.LightInfluence = 0
		gui.Adornee = anchor
		gui.Parent = anchor
		local label = Instance.new("ImageLabel")
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromScale(0.15, 0.15)
		label.Image = image
		label.ImageColor3 = tints[i]
		label.ImageTransparency = 0.05
		label.Rotation = math.random(0, 359)
		label.Parent = gui
		local spin = (if i % 2 == 0 then 1 else -1) * (40 + 30 * i)
		local life = 0.5 + 0.12 * i
		tween(label, TweenInfo.new(life * 0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) })
		tween(label, TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Rotation = label.Rotation + spin,
			ImageTransparency = 1,
		})
	end
end

local function emitSparks(pos: Vector3, groundPos: Vector3)
	local holder, att = newEmitterHolder(pos)

	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = PARTICLE_TEXTURE
	sparks.Rate = 0
	sparks.Lifetime = NumberRange.new(0.6, 1.1)
	sparks.Speed = NumberRange.new(40, 90)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Drag = 3
	sparks.LightEmission = 1
	sparks.Color = ColorSequence.new(CYAN, VIOLET)
	sparks.Size = seq({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 0) })
	sparks.Transparency = seq({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.7, 0.2), NumberSequenceKeypoint.new(1, 1) })
	sparks.Parent = att
	sparks:Emit(160)

	local embers = Instance.new("ParticleEmitter")
	embers.Texture = PARTICLE_TEXTURE
	embers.Rate = 0
	embers.Lifetime = NumberRange.new(1.2, 2)
	embers.Speed = NumberRange.new(6, 14)
	embers.SpreadAngle = Vector2.new(180, 180)
	embers.Acceleration = Vector3.new(0, 10, 0)
	embers.LightEmission = 1
	embers.Color = ColorSequence.new(WHITE, VIOLET)
	embers.Size = seq({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
	embers.Transparency = seq({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	embers.Parent = att
	embers:Emit(70)
	Debris:AddItem(holder, 2.5)

	local dustHolder, dustAtt = newEmitterHolder(groundPos + Vector3.new(0, 0.5, 0)) -- ground dust that rolls outward and settles
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = DUST_TEXTURE
	dust.Rate = 0
	dust.Lifetime = NumberRange.new(1, 1.8)
	dust.Speed = NumberRange.new(14, 26)
	dust.SpreadAngle = Vector2.new(90, 180)
	dust.Drag = 2.5
	dust.Acceleration = Vector3.new(0, 2, 0)
	dust.Color = ColorSequence.new(Color3.fromRGB(120, 110, 150))
	dust.Size = seq({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 7) })
	dust.Transparency = seq({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
	dust.Parent = dustAtt
	dust:Emit(90)
	Debris:AddItem(dustHolder, 3)
end

-- Rocks launched with real physics: gravity, bounces and spin are handled by the engine
local function spawnRocks(ground: Vector3)
	for _ = 1, CONFIG.RockCount do
		local angle = math.random() * TAU
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local s = 0.7 + math.random() ^ 2 * 2.4 -- many small stones and a few big chunks
		local rock = Instance.new("Part")
		rock.Size = Vector3.new(s, s * (0.6 + math.random() * 0.6), s * (0.7 + math.random() * 0.5))
		rock.Material = Enum.Material.Slate
		rock.Color = Color3.fromRGB(70, 65, 85)
		rock.CanTouch = false
		rock.CFrame = CFrame.new(ground + dir * (3 + math.random() * 3) + Vector3.new(0, 0.8, 0))
			* CFrame.Angles(math.random() * TAU, math.random() * TAU, 0)
		rock.Parent = workspace
		pcall(function()
			rock:SetNetworkOwner(nil)
		end)
		rock.AssemblyLinearVelocity = dir * (18 + math.random() * 30) + Vector3.new(0, 30 + math.random() * 34, 0)
		rock.AssemblyAngularVelocity = Vector3.new(math.random() * 20 - 10, math.random() * 20 - 10, math.random() * 20 - 10)
		Debris:AddItem(rock, 5.5)
		task.delay(4.7, function()
			if rock.Parent then
				tween(rock, TweenInfo.new(0.6), { Transparency = 1 })
			end
		end)
	end
end

-- Radial impulse with linear falloff. Impulse = mass * deltaVelocity, so heavy and light assemblies get the same velocity change.
local function applyShockwave(center: Vector3, radius: number, speed: number)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	local hits = workspace:GetPartBoundsInRadius(center, radius, params)

	local seen: { [BasePart]: boolean } = {}
	local count = 0
	for _, part in hits do
		local assemblyRoot = part.AssemblyRootPart
		if not assemblyRoot or seen[assemblyRoot] or assemblyRoot.Anchored then
			continue
		end
		seen[assemblyRoot] = true
		if not CONFIG.ShockwavePushPlayers then
			local character = assemblyRoot:FindFirstAncestorOfClass("Model")
			if character and Players:GetPlayerFromCharacter(character) then
				continue
			end
		end
		count += 1
		if count > CONFIG.MaxPushedAssemblies then
			break
		end
		local offset = assemblyRoot.Position - center
		local dist = offset.Magnitude
		local outward = if dist > 0.1 then offset.Unit else Vector3.yAxis
		local falloff = 1 - math.clamp(dist / radius, 0, 1)
		local dir = (outward + Vector3.new(0, 0.6, 0)).Unit
		pcall(function()
			assemblyRoot:ApplyImpulse(dir * (speed * falloff * assemblyRoot.AssemblyMass))
		end)
	end
end

local function spawnDomainFX(center: Vector3)
	local groundY = findGroundY(center)
	local ground = Vector3.new(center.X, groundY + 0.15, center.Z)

	starBurst(center, 26)
	emitSparks(center, ground)
	spawnRocks(ground)
	task.delay(0.22, spawnRocks, ground) -- a second wave
	applyShockwave(ground, CONFIG.ShockwaveRadius, CONFIG.ShockwaveSpeed)
end

--------------------------------------------------------------------------------
-- Spring-driven animation engine (used by the domain expansion and the Hollow Purple show-off)
--------------------------------------------------------------------------------
type Spring = {
	x: number,
	v: number,
	target: number,
	omega: number, -- natural frequency (rad/s): higher = snappier
	zeta: number, -- damping ratio: < 1 overshoots and wobbles
	delay: number, -- follow-through lag when a new pose is set
	pending: number?,
	pendAt: number,
}

-- Heavy parts react slower and settle calmer; light parts overshoot and lag more
local function springParams(name: string): (number, number, number)
	if name:sub(1, 4) == "root" then
		return 4.5, 0.8, 0
	elseif name == "lean" or name == "twist" or name == "tilt" then
		return 5.5, 0.8, 0.04
	elseif name:sub(1, 4) == "head" then
		return 6.5, 0.75, 0.1 -- the head follows the body a moment later
	elseif name:find("_elb", 1, true) then
		return 7.5, 0.75, 0.14
	elseif name:sub(1, 1) == "a" then
		return 6.5, 0.72, 0.08
	elseif name:find("_kn", 1, true) then
		return 6, 0.8, 0.05
	end
	return 6, 0.8, 0.03
end

local CHANNELS = {
	"rootY", "rootZ", "lean", "twist", "tilt", "headP", "headY", "headR",
	"aR_el", "aR_az", "aR_elb", "aL_el", "aL_az", "aL_elb",
	"lR_fl", "lR_az", "lR_kn", "lL_fl", "lL_az", "lL_kn", "wR", "wL",
}
local SUBSTEP = 1 / 120

type MotorEntry = { motor: Motor6D, pos: Vector3, rot: CFrame }
type Ctx = { root: BasePart, fx: { Instance }, restores: { () -> () }, holding: boolean, groove: boolean, kick: (string, number) -> () }
type Sequence = { kind: string, cues: { Cue }, endTime: number, handlers: (Ctx) -> { [string]: () -> () }, speed: number? } -- speed: how much faster than normal the joints move (a dance needs quick joints)

local currentCleanup: (() -> ())? = nil
local currentKind = ""

local function cancelAnimation()
	local fn = currentCleanup
	if fn then
		fn()
	end
end

local function playSequence(sequence: Sequence)
	cancelAnimation()

	local rootInstance = model:FindFirstChild("HumanoidRootPart")
	if not rootInstance or not rootInstance:IsA("BasePart") then
		warn("[DummyRespawn] HumanoidRootPart missing, skipping animation.")
		return
	end
	local root: BasePart = rootInstance
	local isR15 = humanoid.RigType == Enum.HumanoidRigType.R15

	-- Motors by name, with the original C0 split into position and rotation
	local joints: { [string]: MotorEntry } = {}
	local allMotors: { MotorEntry } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and not joints[d.Name] then
			local entry: MotorEntry = { motor = d, pos = d.C0.Position, rot = d.C0.Rotation }
			joints[d.Name] = entry
			table.insert(allMotors, entry)
		end
	end
	if not joints[if isR15 then "Root" else "RootJoint"] then
		warn("[DummyRespawn] Root motor missing, skipping animation.")
		return
	end

	local active = true
	local connection: RBXScriptConnection? = nil
	local ctx: Ctx = { root = root, fx = {}, restores = {}, holding = false, groove = false, kick = function() end }
	local savedAnchored = root.Anchored
	local savedWalkSpeed = humanoid.WalkSpeed
	local savedAutoRotate = humanoid.AutoRotate

	root.Anchored = true
	humanoid.WalkSpeed = 0
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	currentKind = sequence.kind

	local springs: { [string]: Spring } = {}
	for _, name in CHANNELS do
		local omega, zeta, delay = springParams(name)
		local quick = sequence.speed or 1
		omega *= quick
		delay /= quick
		springs[name] = { x = 0, v = 0, target = 0, omega = omega, zeta = zeta, delay = delay, pending = nil, pendAt = 0 }
	end

	local function setPose(pose: Pose, now: number)
		for name, s in springs do
			s.pending = pose[name] or 0
			s.pendAt = now + s.delay
		end
	end
	-- Instant velocity change: this is what makes a landing snap instead of glide
	ctx.kick = function(name: string, velocity: number)
		local s = springs[name]
		if s then
			s.v += velocity
		end
	end

	local handlers = sequence.handlers(ctx)

	local function cleanup()
		if not active then
			return
		end
		active = false
		currentCleanup = nil
		currentKind = ""
		if connection then
			connection:Disconnect()
			connection = nil
		end
		for _, m in allMotors do
			if m.motor.Parent then
				m.motor.C0 = CFrame.new(m.pos) * m.rot
			end
		end
		for _, restore in ctx.restores do
			pcall(restore)
		end
		for _, fx in ctx.fx do
			if fx.Parent then
				if fx:IsA("ParticleEmitter") then
					fx.Enabled = false
					Debris:AddItem(fx, 2)
				else
					fx:Destroy()
				end
			end
		end
		if root.Parent then
			root.Anchored = savedAnchored
		end
		if humanoid.Parent then
			humanoid.WalkSpeed = savedWalkSpeed
			humanoid.AutoRotate = savedAutoRotate
			humanoid.PlatformStand = false
		end
	end
	currentCleanup = cleanup

	-- Limb rotation in the PARENT frame: lift forward by el, then swing outward by az. side = +1 right, -1 left.
	local function limbQ(el: number, az: number, side: number): CFrame
		return CFrame.Angles(0, rad(-side * az), 0) * CFrame.Angles(rad(el), 0, 0)
	end

	local function setMotor(name: string, q: CFrame, offset: Vector3?)
		local m = joints[name]
		if m and m.motor.Parent then
			m.motor.C0 = CFrame.new(m.pos + (offset or ZERO)) * q * m.rot
		end
	end

	local function applyPose(now: number)
		local function val(name: string): number
			return springs[name].x
		end
		-- Small procedural motion on top of the springs: a concentration tremble and a slow hover bob
		local tremble = if ctx.holding then math.sin(now * 31) * 0.35 else 0
		local rootY = val("rootY")
		local bob = math.sin(now * 3.2) * 0.07 * math.clamp(rootY, 0, 1)
		-- THE GROOVE (dance technique): the beat is 120 per minute (with a tiny drift in time: perfect timing has no groove). Every beat the knees bend and the hips settle (bounce); the WEIGHT goes
		-- from one leg to the other every two beats (sway): the loaded leg bends more and the pelvis shifts over it (the hip movement is the result of the weight transfer, not a separate
		-- wiggle). The pelvis and the shoulders turn against each other (counter-rotation) and the head against the shoulders, so the upper body is never one block.
		local gb = if ctx.groove then now * 12.57 + 0.15 * math.sin(now * 1.3) else 0
		local gBounce = if ctx.groove then 0.5 + 0.5 * math.sin(gb) else 0
		local gSway = if ctx.groove then math.sin(gb * 0.5) else 0
		local wR, wL = math.max(0, gSway), math.max(0, -gSway)
		local offset = Vector3.new(gSway * 0.12, rootY + bob - gBounce * 0.07, val("rootZ"))

		local breath = math.sin(now * 2.1) -- breathing and a slow shift of weight, so the pose never freezes
		local lean = val("lean") + breath * 0.8
		local twist = val("twist") + math.sin(now * 0.9) * 1.2 + gSway * 4
		local tilt = val("tilt") + math.sin(now * 0.7 + 1) * 0.8 - gSway * 5
		local headQ = CFrame.Angles(rad(val("headP") + lean * 0.45 - breath * 0.5 + gBounce * 3), rad(val("headY") - gSway * 5), rad(val("headR") + tremble))
		local aREl, aLEl = val("aR_el") + tremble, val("aL_el") - tremble
		local aRElb, aLElb = val("aR_elb"), val("aL_elb")

		if isR15 then
			setMotor("Root", CFrame.Angles(rad(-lean * 0.35), rad(twist * 0.3 + gSway * 7), rad(tilt * 0.3)), offset)
			setMotor("Waist", CFrame.Angles(rad(-lean * 0.65), rad(twist * 0.7 - gSway * 9), rad(tilt * 0.7)))
			setMotor("Neck", headQ)
			setMotor("RightShoulder", limbQ(aREl, val("aR_az"), 1))
			setMotor("LeftShoulder", limbQ(aLEl, val("aL_az"), -1))
			setMotor("RightWrist", CFrame.Angles(rad(val("wR")), 0, rad(val("wR") * 0.35)))
			setMotor("LeftWrist", CFrame.Angles(rad(val("wL")), 0, rad(-val("wL") * 0.35)))
			setMotor("RightElbow", CFrame.Angles(rad(aRElb * ELBOW_SIGN), 0, 0))
			setMotor("LeftElbow", CFrame.Angles(rad(aLElb * ELBOW_SIGN), 0, 0))
			setMotor("RightHip", limbQ(val("lR_fl") + gBounce * 4, val("lR_az") + gSway * 6, 1))
			setMotor("LeftHip", limbQ(val("lL_fl") + gBounce * 4, val("lL_az") + gSway * 6, -1))
			setMotor("RightKnee", CFrame.Angles(rad(-(val("lR_kn") + 8 * gBounce + 12 * wR) * KNEE_SIGN), 0, 0))
			setMotor("LeftKnee", CFrame.Angles(rad(-(val("lL_kn") + 8 * gBounce + 12 * wL) * KNEE_SIGN), 0, 0))
		else
			setMotor("RootJoint", CFrame.Angles(rad(-lean), rad(twist), rad(tilt)), offset)
			setMotor("Neck", headQ)
			setMotor("Right Shoulder", limbQ(aREl + aRElb * 0.35, val("aR_az"), 1)) -- R6 arms are rigid: part of the elbow goes into the shoulder
			setMotor("Left Shoulder", limbQ(aLEl + aLElb * 0.35, val("aL_az"), -1))
			setMotor("Right Hip", limbQ(val("lR_fl"), val("lR_az"), 1))
			setMotor("Left Hip", limbQ(val("lL_fl"), val("lL_az"), -1))
		end
	end

	local startTime = os.clock()
	local cueIndex = 1
	local cues = sequence.cues

	connection = RunService.Heartbeat:Connect(function(dtRaw: number)
		if not active then
			return
		end
		if not model.Parent or not root.Parent then
			cleanup()
			return
		end

		local ok, err = pcall(function()
			local now = os.clock() - startTime

			while cueIndex <= #cues and cues[cueIndex].t <= now do
				local cue = cues[cueIndex]
				cueIndex += 1
				if cue.pose then
					setPose(cue.pose, now)
				end
				local name = cue.cue
				local fn = if name then handlers[name] else nil
				if fn then
					local okCue, cueErr = pcall(fn)
					if not okCue then
						warn("[DummyRespawn] FX handler '" .. tostring(name) .. "' failed: " .. tostring(cueErr))
					end
				end
			end

			-- Damped spring integration with sub-steps so a lag spike cannot blow it up
			local dt = math.min(dtRaw, 0.05)
			local steps = math.max(1, math.ceil(dt / SUBSTEP))
			local h = dt / steps
			for _, s in springs do
				local pending = s.pending
				if pending ~= nil and now >= s.pendAt then
					s.target = pending
					s.pending = nil
				end
				local ww = s.omega * s.omega
				local damp = 2 * s.zeta * s.omega
				for _ = 1, steps do
					s.v += (ww * (s.target - s.x) - damp * s.v) * h
					s.x += s.v * h
				end
			end

			applyPose(now)

			if now >= sequence.endTime then
				cleanup()
			end
		end)
		if not ok then
			warn("[DummyRespawn] Animation error: " .. tostring(err))
			cleanup() -- always restore the humanoid, even after an error
		end
	end)
end

--------------------------------------------------------------------------------
-- The two sequences: every cue lines up pose, sound, vfx and the camera on one clock
--------------------------------------------------------------------------------
-- DOMAIN EXPANSION (on every respawn)
--   0.00 the blink-in flash, the coil, the camera slowly pushes in      1.25 the voice starts (the burst is at 2.40)
--   0.55 hover + the sigil on the ground                                2.40 the burst: slam, star, shockwave, camera punch
local function domainHandlers(ctx: Ctx): { [string]: () -> () }
	local root = ctx.root
	local aura: ParticleEmitter? = nil
	local auraLight: PointLight? = nil
	local sigil: Part? = nil
	local sigilFinish: (() -> ())? = nil

	return {
		aura = function()
			playSound(SOUND.tail, root, 0.7, 1.3)
			playSound(SOUND.windup, root, 0.8, 1.0)
			sendFx("gather", root.Position, 1)

			local emitter = Instance.new("ParticleEmitter")
			emitter.Texture = PARTICLE_TEXTURE
			emitter.Rate = 28
			emitter.Lifetime = NumberRange.new(0.8, 1.4)
			emitter.Speed = NumberRange.new(1, 3)
			emitter.Acceleration = Vector3.new(0, 6, 0)
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.RotSpeed = NumberRange.new(-90, 90)
			emitter.LightEmission = 1
			emitter.Color = ColorSequence.new(CYAN, VIOLET)
			emitter.Size = seq({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
			emitter.Transparency = seq({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
			emitter.Parent = root
			aura = emitter
			table.insert(ctx.fx, emitter)

			local light = Instance.new("PointLight")
			light.Color = VIOLET
			light.Range = 14
			light.Brightness = 0
			light.Parent = root
			auraLight = light
			table.insert(ctx.fx, light)
			tween(light, TweenInfo.new(0.5, Enum.EasingStyle.Sine), { Brightness = 3 })
		end,

		sigil = function() -- the picture on the floor under the hovering body: it opens and turns slowly while the power gathers
			local mark, finish = groundMark(root.Position, 17, WHITE, 0.8, nil)
			sigil = mark
			sigilFinish = finish
			table.insert(ctx.fx, mark)
			sendFx("seal", root.Position, 1)
		end,

		sealed = function()
			ctx.holding = true
			ctx.kick("lean", -14) -- a breath in as the voice starts
			ctx.kick("headP", -12)
			playSound(SOUND.domain, root, 1, 1)
			local emitter = aura
			if emitter then
				emitter.Rate = 70
			end
			local light = auraLight
			if light then
				tween(light, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { Brightness = 8, Range = 26 })
			end
		end,

		burst = function()
			ctx.holding = false
			-- slam down, then let the springs rebound the body and fling the arms
			ctx.kick("rootY", -7)
			ctx.kick("aR_az", 45)
			ctx.kick("aL_az", 45)
			ctx.kick("headP", -30)

			playSound(SOUND.blast, root, 1, 0.9) -- the low thump and the high ring together feel bigger
			playSound(SOUND.impact, root, 0.8, 1.6)
			task.delay(0.15, playSound, SOUND.tail, root, 0.8, 0.9)
			sendFx("burst", root.Position, 1)
			spawnDomainFX(root.Position)

			local emitter = aura
			if emitter then
				emitter.Rate = 12
			end
			local light = auraLight
			if light then
				tween(light, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { Brightness = 0 })
			end
			local disc, finish = sigil, sigilFinish
			if disc and finish then
				tween(disc, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(60, 0.05, 60) })
				finish() -- the ring fades out while it spreads
			end
		end,

		finish = function()
			local emitter = aura
			if emitter then
				emitter.Enabled = false
			end
		end,
	}
end

-- THE SHOW-OFF (when nobody has hit it for a while): the right hand lifts the BLINDFOLD up, a pause, then pushes it back down. No effects, no sound:
-- only the body language. The blindfold is found by the name "Blindfold" (an Accessory or a part anywhere in the character).
local function presenceHandlers(ctx: Ctx): { [string]: () -> () }
	local weld: Weld? = nil
	local baseC0: CFrame = CFrame.identity
	local disabled: { Instance } = {} -- the original joints of the blindfold, switched off while it is driven by hand

	-- find it: anything called "...blindfold..." (any case); an Accessory means its Handle
	local handle: BasePart? = nil
	for _, d in model:GetDescendants() do
		if d.Name:lower():find("blindfold", 1, true) then
			local candidate: Instance? = if d:IsA("Accessory") then d:FindFirstChild("Handle") else d
			if candidate and candidate:IsA("BasePart") then
				handle = candidate
				break
			elseif candidate and candidate:IsA("Model") then
				handle = candidate.PrimaryPart or candidate:FindFirstChildWhichIsA("BasePart", true)
				if handle then break end
			end
		end
	end
	local head = model:FindFirstChild("Head")
	if handle and head and head:IsA("BasePart") then
		-- every joint that holds the blindfold is switched off and replaced by ONE weld of our own, so the same code works for an
		-- AccessoryWeld, a Motor6D or a WeldConstraint: we know where the blindfold is relative to the head, and we move that
		for _, d in model:GetDescendants() do
			if (d:IsA("WeldConstraint") or d:IsA("JointInstance")) and d.Parent then
				local j0, j1 = (d :: any).Part0, (d :: any).Part1
				if j0 == handle or j1 == handle then
					table.insert(disabled, d)
				end
			end
		end
		baseC0 = head.CFrame:ToObjectSpace(handle.CFrame)
		local mine = Instance.new("Weld")
		mine.Name = "BlindfoldDrive"
		mine.Part0 = head
		mine.Part1 = handle
		mine.C0 = baseC0
		for _, d in disabled do
			(d :: any).Enabled = false
		end
		mine.Parent = handle
		weld = mine
	else
		warn("[DummyRespawn] No part named like 'Blindfold' (or no Head) was found in the character; the show-off plays without it.")
	end

	-- the blindfold goes up on the forehead and tips back a little, like a hand pushing it up (in the space of the head)
	local lift = CFrame.new(0, 0.6, -0.05) * CFrame.Angles(rad(-20), 0, 0)
	local function move(up: boolean, seconds: number)
		local w = weld
		if not w or not w.Parent then return end
		tween(w, TweenInfo.new(seconds, Enum.EasingStyle.Quad, if up then Enum.EasingDirection.Out else Enum.EasingDirection.In), {
			C0 = if up then lift * baseC0 else baseC0,
		})
	end

	table.insert(ctx.restores, function() -- always: our weld goes away and the original joints come back (also when the show-off is cut short)
		local w = weld
		if w then
			w:Destroy()
		end
		for _, d in disabled do
			if d.Parent then
				(d :: any).Enabled = true
			end
		end
		if handle and handle.Parent and head and head:IsA("BasePart") then
			handle.CFrame = head.CFrame * baseC0
		end
	end)

	return {
		lift = function() move(true, 0.45) end,
		lower = function() move(false, 0.4) end,
	}
end

local VOICE_AT = 1.0
local domainLength = 2.4 -- seconds; the real length replaces it as soon as it is measured
local lengthKnown = false
task.spawn(function()
	local probe = Instance.new("Sound")
	probe.SoundId = SOUND.domain
	pcall(function()
		ContentProvider:PreloadAsync({ probe })
	end)
	if probe.TimeLength > 0.5 then
		domainLength = probe.TimeLength
	end
	probe:Destroy()
	lengthKnown = true
end)

local function makeDomain(): Sequence
	local L = domainLength
	local burst = VOICE_AT + math.clamp(L * 0.85, 1.2, 6)
	local span = burst - VOICE_AT
	return {
		kind = "domain",
		endTime = burst + 3.0,
		handlers = domainHandlers,
		cues = {
			{ t = 0.00, pose = ANTICIPATE, cue = "aura" }, -- blink-in, the coil
			{ t = 0.55, pose = SEAL, cue = "sigil" }, -- it rises, the picture opens on the floor
			{ t = VOICE_AT, pose = MUDRA, cue = "sealed" }, -- the voice starts: the hand sign
			{ t = VOICE_AT + span * 0.45, pose = OPEN }, -- "tenkai": the hands part
			{ t = VOICE_AT + span * 0.78, pose = EXPAND }, -- drawn up for the burst
			{ t = burst, pose = IMPACT, cue = "burst" }, -- the burst
			{ t = burst + 0.55, pose = CONFIDENT },
			{ t = burst + 1.9, pose = IDLE },
			{ t = burst + 2.95, cue = "finish" },
		},
	}
end

local SHOW_OFF: Sequence = {
	kind = "flex",
	endTime = 5.4,
	handlers = presenceHandlers,
	cues = {
		{ t = 0.00, pose = BF_REACH }, -- the hand comes up
		{ t = 0.80, pose = BF_LIFTED, cue = "lift" }, -- the blindfold goes up, the head tips back
		{ t = 2.30, pose = BF_PUSH, cue = "lower" }, -- after a pause: the hand pushes it back down
		{ t = 3.20, pose = CONFIDENT }, -- the arm drops, the cocky stance
		{ t = 4.60, pose = IDLE },
	},
}

--------------------------------------------------------------------------------
-- THE DANCE (5 seconds), from four reference photos, in this order: photo 1 -> 2 -> 1 -> 2 -> 3 -> 4
local P_HEAD: Pose = { -- photo 1: both hands on top of the head, the elbows wide out to the sides, the body straight, the feet together, the head tipped a little
	rootY = 0, headR = 6, headP = 2, aR_el = 100, aR_az = 72, aR_elb = 140, aL_el = 100, aL_az = 72, aL_elb = 140,
	lR_fl = 0, lR_az = 1, lR_kn = 4, lL_fl = 0, lL_az = 1, lL_kn = 4,
}
local P_LEG: Pose = { -- photo 2: standing on one leg, the other knee lifted high and out with the foot hanging; one arm up over the head pointing, the other bent in front at the waist; the body leans
	rootY = 0.15, lean = -4, twist = 10, tilt = -5, headR = -12, headY = 8,
	aL_el = 150, aL_az = 18, aL_elb = 40, aR_el = 42, aR_az = -10, aR_elb = 100,
	lR_fl = 78, lR_az = 18, lR_kn = 92, lL_fl = -2, lL_az = 2, lL_kn = 4,
}
local P_CHIN: Pose = { -- photo 3: one hand at the mouth/chin, the other arm bent across the chest, the head tilted, the knees together
	rootY = 0, twist = -6, headR = -10, headP = 4, aR_el = 140, aR_az = 6, aR_elb = 122, aL_el = 55, aL_az = -25, aL_elb = 100,
	lR_fl = 0, lR_az = -1, lR_kn = 8, lL_fl = 0, lL_az = -1, lL_kn = 8,
}
local P_WAIST: Pose = { -- photo 4: both forearms crossed in front of the waist (a hand holding the other wrist), standing straight, the feet together
	rootY = 0, lean = 3, headP = -4, aR_el = 38, aR_az = -8, aR_elb = 95, aL_el = 36, aL_az = -10, aL_elb = 95,
	lR_fl = 0, lR_az = 0, lR_kn = 4, lL_fl = 0, lL_az = 0, lL_kn = 4,
}

-- the in-between poses: a body does not jump from one picture to the next, it prepares (the weight goes onto the standing leg, the arms start to move) and it passes through a middle
local P_PREP: Pose = { -- before the leg goes up: the weight on the left leg (it bends a little), the hips shift, the right knee starts to lift, the arms start to open
	rootY = -0.12, tilt = -6, twist = 4, headR = -6, aL_el = 125, aL_az = 40, aL_elb = 80, aR_el = 62, aR_az = 22, aR_elb = 112,
	lR_fl = 20, lR_az = 8, lR_kn = 30, lL_fl = -2, lL_az = 2, lL_kn = 12,
}
local P_MID: Pose = { -- on the way back: the leg comes down, the arms are half way between the two pictures
	rootY = 0, tilt = -2, headR = 0, aL_el = 110, aL_az = 25, aL_elb = 70, aR_el = 72, aR_az = 40, aR_elb = 122,
	lR_fl = 18, lR_az = 6, lR_kn = 30, lL_fl = 0, lL_az = 2, lL_kn = 6,
}
local P_MID2: Pose = { -- from the chin to the waist: the hand leaves the face, the arms come down together
	rootY = 0, lean = 1, headR = -4, headP = 0, aR_el = 80, aR_az = 0, aR_elb = 105, aL_el = 45, aL_az = -18, aL_elb = 100,
	lR_fl = 0, lR_az = 0, lR_kn = 6, lL_fl = 0, lL_az = 0, lL_kn = 6,
}

local P_SIDE: Pose = { -- a wide bouncing stance: the legs apart, the knees bent, the hips low, the fists at the chest (the groove does the rest)
	rootY = -0.3, aR_el = 70, aR_az = 20, aR_elb = 110, aL_el = 70, aL_az = 20, aL_elb = 110, headP = 2,
	lR_fl = 6, lR_az = 20, lR_kn = 32, lL_fl = 6, lL_az = 20, lL_kn = 32,
}
local P_WHISTLE: Pose = { -- the whistle: the right hand at the mouth, the left hand on the hip, the head up, the feet apart a little
	rootY = 0, lean = -3, headP = 7, aR_el = 150, aR_az = 2, aR_elb = 128, aL_el = 18, aL_az = 22, aL_elb = 72,
	lR_fl = 2, lR_az = 8, lR_kn = 12, lL_fl = -2, lL_az = 8, lL_kn = 12,
}

local DANCE: Sequence = {
	kind = "flex", -- (a hit cuts it short, like the other show-off)
	endTime = 6.4,
	speed = 1.7,
	handlers = function(ctx: Ctx): { [string]: () -> () }
		local music: Sound? = nil
		table.insert(ctx.restores, function() -- however the dance ends (time over, or cut short by a hit) the music fades out, it never just stops
			local m = music
			music = nil
			ctx.groove = false
			if m then
				TweenService:Create(m, TweenInfo.new(0.4), { Volume = 0 }):Play()
				Debris:AddItem(m, 0.5)
			end
		end)
		return {
			start = function()
				ctx.groove = true
				local sound = Instance.new("Sound")
				sound.SoundId = "rbxassetid://70420797579049"
				sound.Volume = 0.28 -- low
				sound.RollOffMaxDistance = 80
				sound.Parent = ctx.root
				pcall(function()
					sound:Play()
				end)
				music = sound
			end,
		}
	end,
	cues = {
		{ t = 0.00, pose = P_HEAD, cue = "start" }, -- photo 1
		{ t = 0.55, pose = P_PREP },
		{ t = 0.85, pose = P_LEG }, -- photo 2
		{ t = 1.25, pose = P_MID },
		{ t = 1.55, pose = P_HEAD }, -- photo 1
		{ t = 2.10, pose = P_PREP },
		{ t = 2.40, pose = P_LEG }, -- photo 2
		{ t = 2.90, pose = P_MID },
		{ t = 3.35, pose = P_CHIN }, -- photo 3
		{ t = 3.90, pose = P_MID2 },
		{ t = 4.20, pose = P_SIDE }, -- a wide bouncing step
		{ t = 4.90, pose = P_WHISTLE }, -- THE WHISTLE: the last 1.5 seconds of the dance (it ends at 6.4)
		{ t = 5.65, pose = P_WAIST }, -- photo 4
		{ t = 6.20, pose = IDLE },
	},
}

--------------------------------------------------------------------------------
-- Health bar: the red-to-cyan bar follows the health smoothly, a white trail follows a moment later, and the bar shakes when hit
--------------------------------------------------------------------------------
local lastHit = os.clock()
local dying = false
local hideBar: () -> () = function() end

local function createHealthBar()
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then return end

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- the default bar would sit on top of this one

	-- The same language as the BLINK CUT hud: text and thin lines only, one accent colour, a soft swell instead of a shake.
	local FONT = Enum.Font.GothamMedium
	local CRIMSON = Color3.fromRGB(219, 43, 51)
	local ROSE = Color3.fromRGB(251, 129, 127)
	local PALE = Color3.fromRGB(255, 241, 241)

	local gui = Instance.new("BillboardGui")
	gui.Name = "GojoBar"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(220, 56)
	gui.StudsOffset = Vector3.new(0, 2.9, 0)
	gui.MaxDistance = 120
	gui.AlwaysOnTop = true
	gui.Parent = head

	-- everything sits in one group that is SCALED by the distance (a bar of the same pixel size would look huge on a far dummy): the group shrinks as the camera goes
	-- away (size ~ 1 / distance, never below 45%) and fades out at the end of the range
	local rootGroup = Instance.new("CanvasGroup")
	rootGroup.BackgroundTransparency = 1
	rootGroup.Size = UDim2.fromScale(1, 1)
	rootGroup.Parent = gui
	local distanceScale = Instance.new("UIScale")
	distanceScale.Parent = rootGroup

	local function stroke(l: TextLabel)
		local st = Instance.new("UIStroke") -- a faint dark edge only for legibility on bright ground
		st.Color = Color3.new(0, 0, 0)
		st.Thickness = 1
		st.Transparency = 0.6
		st.Parent = l
	end

	-- the name, with wide tracking (a thin space between the letters)
	local letters: { string } = {}
	for i = 1, #"GOJO SATORU" do
		letters[i] = string.sub("GOJO SATORU", i, i)
	end
	local spaced = table.concat(letters, "\u{2009}\u{200A}")
	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0, 16)
	nameLabel.Font = FONT
	nameLabel.TextSize = 13
	nameLabel.Text = spaced
	nameLabel.TextColor3 = PALE
	nameLabel.TextTransparency = 0.15
	nameLabel.Parent = rootGroup
	stroke(nameLabel)

	-- the number and the maximum beside it, small and rose ("620 / 1000")
	local number = Instance.new("TextLabel")
	number.BackgroundTransparency = 1
	number.Position = UDim2.fromOffset(0, 16)
	number.Size = UDim2.new(1, 0, 0, 26)
	number.Font = FONT
	number.RichText = true
	number.TextSize = 22
	number.TextColor3 = PALE
	number.Parent = rootGroup
	stroke(number)
	local numberScale = Instance.new("UIScale")
	numberScale.Parent = number

	-- one thin line: the faint track, the trail that follows a moment later, the bar itself (white to the accent colour)
	local back = Instance.new("Frame")
	back.AnchorPoint = Vector2.new(0.5, 0)
	back.Position = UDim2.new(0.5, 0, 0, 46)
	back.Size = UDim2.fromOffset(180, 2)
	back.BackgroundColor3 = PALE
	back.BackgroundTransparency = 0.8
	back.BorderSizePixel = 0
	back.Parent = rootGroup

	local trail = Instance.new("Frame")
	trail.Size = UDim2.fromScale(1, 1)
	trail.BackgroundColor3 = ROSE
	trail.BackgroundTransparency = 0.45
	trail.BorderSizePixel = 0
	trail.Parent = back

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = PALE
	fill.BorderSizePixel = 0
	fill.Parent = back
	local gradient = Instance.new("UIGradient")
	gradient.Parent = fill

	local shown, lag = 1, 1
	local lastHealth = humanoid.Health
	local lastText = -1
	local connection: RBXScriptConnection? = nil

	local function ratio(): number
		return math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
	end
	shown = ratio()
	lag = shown

	local healthConn = humanoid.HealthChanged:Connect(function(health: number)
		if health < lastHealth then
			-- the breath of the number: a soft swell that settles (the harder the hit, the bigger)
			local hardness = math.clamp((lastHealth - health) / math.max(humanoid.MaxHealth, 1) * 6, 0, 1)
			numberScale.Scale = 1.08 + 0.12 * hardness
			TweenService:Create(numberScale, TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		lastHealth = health
	end)

	connection = RunService.Heartbeat:Connect(function(dt: number)
		local goal = ratio()
		shown += (goal - shown) * (1 - math.exp(-14 * dt))
		if lag > shown then
			if os.clock() - lastHit > 0.45 then -- the trail waits a moment, then slides down
				lag += (shown - lag) * (1 - math.exp(-4 * dt))
			end
		else
			lag = shown
		end
		fill.Size = UDim2.fromScale(shown, 1)
		trail.Size = UDim2.fromScale(lag, 1)
		gradient.Color = ColorSequence.new(PALE, CRIMSON:Lerp(CYAN, shown)) -- the end of the line turns from cyan to crimson as health falls

		local value = math.ceil(shown * humanoid.MaxHealth - 0.01)
		if value ~= lastText then -- the text changes only when the number does
			lastText = value
			number.Text = string.format('%d <font size="13" color="rgb(%d,%d,%d)">/ %d</font>', value, 251, 129, 127, math.ceil(humanoid.MaxHealth))
			number.TextColor3 = PALE:Lerp(ROSE, (1 - shown) * 0.5)
		end
	end)

	hideBar = function()
		gui.Enabled = false
		if connection then
			connection:Disconnect()
			connection = nil
		end
		healthConn:Disconnect()
	end
	model.Destroying:Connect(hideBar)
end

--------------------------------------------------------------------------------
-- Template, death and respawn
--------------------------------------------------------------------------------
-- A clean copy built before anything changes the model
local okTemplate, templateResult = pcall(function(): Model
	local clean = model:Clone()
	clean:SetAttribute("Respawned", false)
	for _, d in clean:GetDescendants() do
		if d:IsA("Humanoid") then
			d.PlatformStand = false
			d.Health = d.MaxHealth
		elseif d:IsA("GuiBase") or d.Name == "GojoBar" then
			d:Destroy() -- the bar is built again by the new copy
		end
	end
	return clean
end)
if not okTemplate or typeof(templateResult) ~= "Instance" then
	warn("[DummyRespawn] Could not build the respawn template (is the model Archivable?): " .. tostring(templateResult))
	return
end
local template: Model = templateResult :: Model

local function respawn(attempt: number)
	local created: Model? = nil
	local ok, err = pcall(function()
		local parent = if respawnParent:IsDescendantOf(game) then respawnParent else workspace
		local newDummy = template:Clone()
		created = newDummy
		local newHum = newDummy:FindFirstChildOfClass("Humanoid")
		if not newHum then
			error("template has no Humanoid")
		end
		newHum.Health = newHum.MaxHealth
		newDummy:SetAttribute("Respawned", true)
		newDummy.Parent = parent
	end)

	if ok then
		model:Destroy()
		return
	end
	warn(("[DummyRespawn] Respawn attempt %d failed: %s"):format(attempt, tostring(err)))
	local partial = created
	if partial then
		partial:Destroy()
	end
	if attempt < CONFIG.MaxRespawnRetries then
		task.delay(1, respawn, attempt + 1)
	else
		warn("[DummyRespawn] Giving up on respawn.")
	end
end

-- DEATH: no sound. The blow lands, the body hangs still for a heartbeat, then it is cut into 60 pieces that fly apart under real physics while
-- the blood picture (an animated sprite sheet, 4 x 4 cells) splashes in several places on the body.
local BLOOD_IMAGE = "rbxassetid://14601007537"
local BLOOD_CELL = 256 -- 256 px per cell if the sheet is 1024 x 1024 (assumed)
local BLOOD_COLOR = Color3.fromRGB(170, 12, 24)
local SHARD_COUNT = 60
local SHARD_GROUP = "GojoShards"

pcall(function()
	PhysicsService:RegisterCollisionGroup(SHARD_GROUP)
end)
pcall(function()
	PhysicsService:CollisionGroupSetCollidable(SHARD_GROUP, SHARD_GROUP, false) -- the pieces fall through each other, but land on the ground
end)

-- one splash of the blood sheet: the 16 cells played in order, turned at random
local function bloodSplash(pos: Vector3, size: number)
	local anchor = makeFxPart(Enum.PartType.Ball, Vector3.one * 0.2, CFrame.new(pos), WHITE, 1)
	Debris:AddItem(anchor, 1.5)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(size, size)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Adornee = anchor
	gui.Parent = anchor
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Image = BLOOD_IMAGE
	label.ImageColor3 = BLOOD_COLOR
	label.ImageRectSize = Vector2.new(BLOOD_CELL, BLOOD_CELL)
	label.Rotation = math.random(0, 359)
	label.Parent = gui
	task.spawn(function()
		for cell = 0, 15 do
			if not anchor.Parent then return end
			label.ImageRectOffset = Vector2.new((cell % 4) * BLOOD_CELL, (cell // 4) * BLOOD_CELL)
			task.wait(1 / 24)
		end
		anchor:Destroy()
	end)
end

-- THE EFFECTS THAT LIVE IN THE DUMMY (particles, trails, beams, fire, lights, highlights, gui): when the body is gone they must be gone too; with the body hidden they
-- would hang in the air. stopEffects() stops what is emitting at once (at the moment of death), clearEffects() removes everything when the body breaks up.
local function isEffect(d: Instance): boolean
	return d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles")
		or d:IsA("Light") or d:IsA("Highlight") or d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("ForceField")
end

local function stopEffects(target: Instance)
	for _, d in target:GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Light") then
			pcall(function()
				(d :: any).Enabled = false
			end)
		end
	end
end

-- the body is cut into SHARD_COUNT pieces: every visible part gives pieces in proportion to its volume (at least one), each piece has the colour
-- of its part and sits where it was inside the part, so the body looks whole for the first frame and then falls apart
local function shatter(center: Vector3)
	local sources: { BasePart } = {}
	local volumes: { number } = {}
	local total = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Transparency < 0.95 then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			table.insert(sources, d)
			table.insert(volumes, v)
			total += v
		end
	end
	if #sources == 0 then return end

	local counts: { number } = {}
	local sum = 0
	for i, v in volumes do
		counts[i] = math.max(1, math.floor(SHARD_COUNT * v / total + 0.5))
		sum += counts[i]
	end
	while sum ~= SHARD_COUNT do -- make it exactly 60: take from / give to the biggest part
		local biggest = 1
		for i = 2, #counts do
			if counts[i] > counts[biggest] then biggest = i end
		end
		if sum > SHARD_COUNT then
			if counts[biggest] <= 1 then break end
			counts[biggest] -= 1
			sum -= 1
		else
			counts[biggest] += 1
			sum += 1
		end
	end

	for i, src in sources do
		local n = counts[i]
		local edge = math.clamp((volumes[i] / n) ^ (1 / 3) * 1.15, 0.25, 1.7)
		for _ = 1, n do
			local size = src.Size
			local inside = Vector3.new((math.random() - 0.5) * size.X, (math.random() - 0.5) * size.Y, (math.random() - 0.5) * size.Z) * 0.85
			local world = src.CFrame:PointToWorldSpace(inside)
			local shard = Instance.new("Part")
			shard.Size = Vector3.new(edge * (0.6 + math.random() * 0.8), edge * (0.6 + math.random() * 0.8), edge * (0.6 + math.random() * 0.8))
			shard.Color = src.Color
			shard.Material = if src:IsA("Part") then src.Material else Enum.Material.SmoothPlastic
			shard.CFrame = CFrame.new(world) * src.CFrame.Rotation
			shard.CanTouch = false
			shard.CollisionGroup = SHARD_GROUP
			shard.Parent = workspace
			pcall(function()
				shard:SetNetworkOwner(nil)
			end)
			local away = world - center
			local dir = if away.Magnitude > 0.1 then away.Unit else Vector3.yAxis
			local velocity = (dir + Vector3.new((math.random() - 0.5) * 0.7, 0.55 + math.random() * 0.6, (math.random() - 0.5) * 0.7)) * (14 + math.random() * 20)
			shard:ApplyImpulse(velocity * shard.AssemblyMass) -- impulse = mass * velocity: every piece gets the same speed
			shard:ApplyAngularImpulse(Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 14 * shard.AssemblyMass)
			Debris:AddItem(shard, 2.6)
			task.delay(math.random() * 0.3, function() -- every piece spurts a little blood of its own, a moment after it is thrown
				if shard.Parent then
					bloodSplash(shard.Position, 2.2 + math.random() * 2.6)
				end
			end)
			task.delay(1.4 + math.random() * 0.4, function() -- the pieces are used up: they shrink away
				if shard.Parent then
					tween(shard, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = shard.Size * 0.05 })
				end
			end)
		end
	end

	for _, d in model:GetDescendants() do -- the body itself is gone (the pieces replace it), and so is every effect that lived in it
		if isEffect(d) then
			pcall(function()
				d:Destroy()
			end)
		elseif d:IsA("BasePart") then
			d.Transparency = 1
			d.CanCollide = false
			d.Anchored = true
		end
	end
end

local function onDied()
	if dying then return end
	dying = true
	cancelAnimation() -- a running animation would fight the freeze
	hideBar()
	stopEffects(model) -- nothing keeps emitting from the dying body

	local rootInstance = model:FindFirstChild("HumanoidRootPart")
	local center = if rootInstance and rootInstance:IsA("BasePart") then rootInstance.Position else model:GetPivot().Position
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true -- the hit stop: the whole body hangs still for a heartbeat
		end
	end
	sendFx("hit", center, 1) -- only the camera, no sound

	task.delay(CONFIG.CorpseTime, function()
		if not model:IsDescendantOf(game) then return end
		shatter(center)
	end)
	task.delay(CONFIG.RespawnTime, respawn, 1)
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------
createHealthBar()

do
	local last = humanoid.Health
	humanoid.HealthChanged:Connect(function(health: number)
		if health < last then
			lastHit = os.clock()
			if currentKind == "flex" then
				cancelAnimation() -- being hit cuts the show-off short
			end
		end
		last = health
	end)
end

-- THE IDLE LIFE: when nobody has hit it for a while it shows off with the blindfold; a few seconds after that it DANCES for 3 seconds; then it is quiet for a while
-- and starts again with the blindfold (so the show-off can come again after the dance). Being hit cuts any of them short and starts the waiting again.
task.spawn(function()
	local nextKind = "show"
	local nextAt = os.clock() + CONFIG.FlexDelay
	local seenHit = lastHit
	while model.Parent and not dying do
		task.wait(0.4)
		local now = os.clock()
		if lastHit > seenHit then -- it was hit: the waiting starts again, with the blindfold
			seenHit = lastHit
			nextKind = "show"
			nextAt = lastHit + CONFIG.FlexDelay
		end
		if not dying and currentCleanup == nil and now >= nextAt and now - lastHit > CONFIG.FlexDelay * 0.5 then
			if nextKind == "show" then
				playSequence(SHOW_OFF)
				nextKind = "dance"
				nextAt = now + SHOW_OFF.endTime + 3 -- the dance comes a few seconds after the blindfold
			else
				playSequence(DANCE)
				nextKind = "show"
				nextAt = now + DANCE.endTime + CONFIG.FlexDelay -- then a quiet while, then the blindfold again
			end
		end
	end
end)

if model:GetAttribute("Respawned") == true then
	lastHit = os.clock()
	task.spawn(function()
		local waited = os.clock()
		while not lengthKnown and os.clock() - waited < 2 do
			task.wait()
		end
		if model.Parent and not dying then
			playSequence(makeDomain())
		end
	end)
end

if humanoid.Health <= 0 then
	onDied()
else
	humanoid.Died:Once(onDied)
end
model.Destroying:Connect(cancelAnimation)
