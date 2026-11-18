--!strict
-- ModuleScript "CameraFx"  (parent: Tool "DarkV1", next to Client and SwordSfx)
-- Everything about the camera lives here. Client only calls:
--   local Cam = require(tool:WaitForChild("CameraFx"))
--   Cam.configure({ Strength = 1, Post = 1 })      -- once, at the start
--   Cam.enable() / Cam.disable()                    -- on equip / unequip
--   Cam.shake(amount)          Cam.shakeAt(worldPos, amount, radius)
--   Cam.kick(pitch, yaw, roll) Cam.push(studs)     Cam.fov(deg)      Cam.impulse(worldDir, studs)
--   Cam.fovHold(deg, time)     Cam.pushHold(studs, time)             Cam.sweep(yaw, pitch, roll, time)
--   Cam.post({ blur, bloom, tint, flash })         Cam.speedHold(time)
--   Cam.play(def)  (def = a table of the values above, see Cam.play)
--   Cam.cleanCFrame()          the camera without the shake (use it for aiming)
--   Every move is ignored while the camera is not enabled (nothing piles up before equip or after unequip).
--
-- Techniques used (see the sources in the chat answer):
--   * TRAUMA shake: every hit adds "trauma" (0..1) that falls by itself; the shake size is trauma^2
--     and is read from smooth noise over time, not from random numbers (Eiserloh GDC talk idea).
--   * SPRING kicks: a sharp first move that rings down and settles, instead of a constant shake.
--   * Layering: a short noise rumble on top of the spring kick (hits, blast).
--   * ONE global strength number that scales moves that are already playing (accessibility slider).
--   * Shake is mostly small movement; turning is limited and roll is kept tiny (sickness safety).
--   * Camera input of the player is never touched: every move is an offset that is removed again
--     before the default camera runs on the next frame.

local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local rad = math.rad
local noise = math.noise
local abs = math.abs
local clamp = math.clamp
local PI2 = 2 * math.pi

local Cam = {}

--------------------------------------------------------------------------------
-- 1. SETTINGS
--------------------------------------------------------------------------------
-- set from Client with Cam.configure
Cam.settings = {
	Strength = 1, -- 0 = off, 1 = full (shake, kick, push, FOV)
	Post = 1, -- 0 = off, 1 = full (blur / bloom / color pulses)
}

local TUNING = {
	-- shake (trauma)
	-- math.noise gives about -0.5..0.5 for fractional inputs (Roblox docs), so the REAL size of these shake values is about half
	MaxRot = 2.4, -- degrees at trauma = 1 (real size about 1.1; small on purpose: big shakes make people dizzy)
	MaxRoll = 0.66, -- degrees of shake roll at trauma = 1 (roll is the part that makes people sick)
	MaxMove = 0.082, -- studs of shake movement at trauma = 1 (real size about half; movement is safer than turning)
	Decay = 2.6, -- trauma per second (a full hit is gone in about 0.4 s)
	Attack = 30, -- how fast the shake rises to a new trauma (per second): a soft start of about 2 frames
	NoiseSpeed = 16, -- shake speed: lower = smoother, less jittery

	-- limits for all moves together
	MaxTurn = 6, -- degrees: the camera never turns more than this (pitch / yaw)
	MaxRollTotal = 1.6, -- degrees: and never leans more than this
	MaxFov = 11, -- degrees: the FOV never changes more than this

	-- springs: frequency (Hz) and damping ratio (1 = no overshoot, lower = more bounce)
	Kick = { f = 11, z = 0.7 },
	Push = { f = 10, z = 0.75 },
	Fov = { f = 6, z = 0.8 },
	Sweep = { f = 3.5, z = 1.1 },
	Impulse = { f = 9, z = 0.55 },

	-- how strong one "unit" of a move is (multiplied into the spring speed)
	KickGain = 1.4,
	PushGain = 1.4,
	FovGain = 1.4,
	ImpulseGain = 1.5,

	-- screen effects: how fast each pulse fades (per second)
	PostDecay = { blur = 6, bloom = 4, tint = 3.5, flash = 10, dof = 3, dim = 16 },
	DashPush = 0.4, -- studs the view is pulled forward while dashing
	DashFov = 4, -- degrees wider while dashing
	DashBlur = 1.2, -- light blur while dashing
	-- law 2: inertia. The camera trails behind when you speed up and catches up when you stop (offset = filtered velocity - real velocity)
	LagTime = 0.2, -- seconds the camera takes to catch up with your speed
	LagGain = 0.012, -- studs of lag per stud/s of speed difference
	LagMax = 0.45, -- studs: never more than this
	-- law 3: lens compression. Going fast opens the lens a little (wider view = faster feeling), up to this many degrees
	SpeedFov = 3,
	-- law 7: depth of field. Strong hits blur what is far behind the target for a moment
	DofFar = 0.35,
	-- law 8: landing. A fall harder than this (studs/s) pushes the camera down; 90 studs/s and more = the full push
	LandMin = 18,
	LandDip = 0.6, -- studs at the full push
	-- law 10: tunnel vision. Above this speed (studs/s) the screen edges darken, fully dark at +50
	TunnelFrom = 40,
	TunnelMax = 0.5, -- darkest edge (0..1)
}

--------------------------------------------------------------------------------
-- 2. STATE (plain numbers in small tables: nothing new is created every frame)
--------------------------------------------------------------------------------
type State3 = { x: number, y: number, z: number, vx: number, vy: number, vz: number }
type State1 = { x: number, v: number }
type SpringParams = { f: number, z: number }
local function state3(): State3 return { x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0 } end
local function state1(): State1 return { x = 0, v = 0 } end

local trauma, shown = 0, 0 -- shown = trauma after the short attack ramp
local kick = state3() -- degrees: pitch (up +), yaw (left +), roll
local sweep = state3() -- degrees: x = yaw (left +), y = pitch (up +), z = roll
local imp = state3() -- studs, camera-local shove (x right, y up, z back)
local push = state1() -- studs, forward +
local fovS = state1() -- degrees
local sweepTarget = { x = 0, y = 0, z = 0 }
local pushTarget, fovTarget = 0, 0
local fovHoldThread: thread?, pushHoldThread: thread?, sweepThread: thread?, speedThread: thread?
local seed = math.random() * 100
local cleanCF: CFrame?, shakenCF: CFrame?, cleanFov: number?, shakenFov: number?
local enabled = false

-- screen effects (local only): each is a 0..1 amount that fades by itself
local post = { blur = 0, bloom = 0, tint = 0, flash = 0, dof = 0, dim = 0 } -- dim: a 2-frame dip of the picture just before a big flash (law 174, contrast)
local speed, speedTarget = 0, 0 -- held while dashing
-- FOCUS (0..1): the world loses colour and gets a little darker and more contrasty, so that the effects stand out from it (a skill that wants
-- the viewer to look at the fight, not at the scenery, switches it on and off). focusT = where it goes, focusA = where it is now (it eases).
local focusT, focusA = 0, 0
local fxBlur: BlurEffect?, fxBloom: BloomEffect?, fxColor: ColorCorrectionEffect?, fxDof: DepthOfFieldEffect?
local tunnelGui: ScreenGui?, tunnelFrames: { Frame }?
local swingE, swingTarget, swingStamp, swingRoll, swingRollTarget = 0, 0, -10, 0, 0
local lagVel, lagOff, spdFov, tunnel = Vector3.zero, Vector3.zero, 0, 0
local wasAir, vyPrev = false, 0
local gaitOff = { x = 0, y = 0, roll = 0, pitch = 0 } -- walk / run head bob (camera-local studs, degrees)

local reducedValue, reducedChecked = false, -100
local function reduced(): boolean -- asked at most once a second, not every frame
	local now = os.clock()
	if now - reducedChecked > 1 then
		reducedChecked = now
		local ok, r = pcall(function()
			return GuiService.ReducedMotionEnabled
		end)
		reducedValue = ok and r == true
	end
	return reducedValue
end

-- soft limit: behaves like x for small values and slowly flattens at +-max (no hard edge)
local function soft(x: number, max: number): number
	return x / (1 + abs(x) / max)
end

-- the global strength; applies to moves that are already playing too
local function strength(): number
	local s = Cam.settings.Strength or 1
	if reduced() then
		s *= 0.25
	end
	return s
end

local function w(f: number): number return PI2 * f end

-- a real, finite number (rejects nil, strings, NaN and infinity)
local function num(v: any): boolean
	return type(v) == "number" and v == v and v > -1e9 and v < 1e9
end

-- one spring step (semi-implicit Euler, stable at 60 fps when called with two half steps)
local function spring1(s: State1, target: number, p: SpringParams, h: number)
	local ww = w(p.f)
	s.v += (-ww * ww * (s.x - target) - 2 * p.z * ww * s.v) * h
	s.x += s.v * h
end

local function spring3(s: State3, tx: number, ty: number, tz: number, p: SpringParams, h: number)
	local ww = w(p.f)
	local ww2, damp = ww * ww, 2 * p.z * ww
	s.vx += (-ww2 * (s.x - tx) - damp * s.vx) * h
	s.vy += (-ww2 * (s.y - ty) - damp * s.vy) * h
	s.vz += (-ww2 * (s.z - tz) - damp * s.vz) * h
	s.x += s.vx * h
	s.y += s.vy * h
	s.z += s.vz * h
end

local function cancel(thread: thread?)
	if thread then pcall(task.cancel, thread) end
end

--------------------------------------------------------------------------------
-- 3. API (the moves)
--------------------------------------------------------------------------------
function Cam.configure(opts: { [string]: number })
	if type(opts) ~= "table" then return end
	for k, v in opts do
		if Cam.settings[k] ~= nil and type(v) == "number" then Cam.settings[k] = v end
	end
end

function Cam.shake(amount: number)
	if not enabled or not num(amount) then return end
	trauma = math.min(1, trauma + amount)
	if amount >= 0.12 then post.dof = math.max(post.dof, math.min(1, amount * 3)) end -- law 7: a strong hit pulls the focus
end

-- a shake that gets weaker with distance (for explosions): full inside 20% of the radius
function Cam.shakeAt(worldPos: Vector3, amount: number, radius: number?)
	local cam = workspace.CurrentCamera
	if not enabled or not cam or typeof(worldPos) ~= "Vector3" or not num(amount) then return end
	local d = (cam.CFrame.Position - worldPos).Magnitude
	local r = num(radius) and radius or 60
	if not num(d) or r <= 0 then return end
	local f = clamp((r - d) / (r * 0.8), 0, 1)
	if f > 0 then Cam.shake(amount * f) end
end

function Cam.kick(pitch: number, yaw: number, roll: number?)
	if not enabled or not num(pitch) or not num(yaw) then return end
	if roll ~= nil and not num(roll) then roll = 0 end
	local g = w(TUNING.Kick.f) * TUNING.KickGain
	kick.vx += pitch * g
	kick.vy += yaw * g
	kick.vz += (roll or 0) * g
end

function Cam.push(studs: number)
	if not enabled or not num(studs) then return end
	push.v += studs * w(TUNING.Push.f) * TUNING.PushGain
end

function Cam.fov(deg: number)
	if not enabled or not num(deg) then return end
	fovS.v += deg * w(TUNING.Fov.f) * TUNING.FovGain
end

-- shove the camera along a WORLD direction (e.g. the way the enemy flies), studs
function Cam.impulse(worldDir: Vector3, studs: number)
	local cam = workspace.CurrentCamera
	if not enabled or not cam or typeof(worldDir) ~= "Vector3" or not num(studs) then return end
	local mag = worldDir.Magnitude
	if not num(mag) or mag < 1e-3 then return end -- also rejects NaN
	local l = cam.CFrame:VectorToObjectSpace(worldDir.Unit)
	local g = studs * w(TUNING.Impulse.f) * TUNING.ImpulseGain
	imp.vx += l.X * g
	imp.vy += l.Y * 0.4 * g
	imp.vz += l.Z * g
end

-- the user's 3-section curve as a rise: a straight start (slope 1.25), then a parabola with the same slope that lands softly
local function curveRise(x: number): number
	local u0 = 0.6
	local s = 2 / (1 + u0)
	x = math.clamp(x, 0, 1)
	if x <= u0 then return s * x end
	return 1 - (s / (2 * (1 - u0))) * (1 - x) * (1 - x)
end
-- FOV hold envelope: rises along the curve (first 30 %), holds, falls back mirrored (last 30 %). The spring then follows it.
local fovHoldDeg, fovHoldT0, fovHoldDur = 0, 0, 0
local function fovEnvelope(): number
	if fovHoldDur <= 0 then return 0 end
	local x = (os.clock() - fovHoldT0) / fovHoldDur
	if x >= 1 then return 0 end
	if x < 0.3 then return fovHoldDeg * curveRise(x / 0.3) end
	if x > 0.7 then return fovHoldDeg * curveRise((1 - x) / 0.3) end
	return fovHoldDeg
end

function Cam.fovHold(deg: number, duration: number)
	if not enabled or not num(deg) or not num(duration) then return end
	fovHoldDeg, fovHoldT0, fovHoldDur = deg, os.clock(), math.max(duration, 0.05)
	cancel(fovHoldThread)
	fovHoldThread = task.delay(duration, function()
		fovHoldDur = 0
		fovTarget = 0
		fovHoldThread = nil
	end)
end

-- hold the camera a bit forward/back for a while (studs, forward +)
function Cam.pushHold(studs: number, duration: number)
	if not enabled or not num(studs) or not num(duration) then return end
	pushTarget = studs
	cancel(pushHoldThread)
	pushHoldThread = task.delay(duration, function()
		pushTarget = 0
		pushHoldThread = nil
	end)
end

-- a slow, smooth camera move that goes there and comes back: yaw (left +), pitch (up +), roll
function Cam.sweep(yaw: number, pitch: number, roll: number?, duration: number?)
	if not enabled or not num(yaw) or not num(pitch) then return end
	if not num(roll) then roll = 0 end
	if not num(duration) then duration = 0.3 end
	sweepTarget.x, sweepTarget.y, sweepTarget.z = yaw, pitch, roll
	cancel(sweepThread)
	sweepThread = task.delay(duration, function()
		sweepTarget.x, sweepTarget.y, sweepTarget.z = 0, 0, 0
		sweepThread = nil
	end)
end

local ROSE_TINT = Color3.fromRGB(255, 205, 203) -- a pale rose tint, same family as the effects
local tintColor = ROSE_TINT -- the colour of the "tint" pulse (a skill with another palette changes it with Cam.setTintColor)
-- the world fades toward grey (amount 0..1) and comes back with 0; it eases in and out by itself
function Cam.focus(amount: number)
	focusT = if num(amount) then clamp(amount, 0, 1) else 0
end

-- the colour of the "tint" pulse; nil = the normal pale rose
function Cam.setTintColor(color: Color3?)
	tintColor = if typeof(color) == "Color3" then color else ROSE_TINT
end

-- screen pulse: { blur, bloom, tint, flash } each 0..1
function Cam.post(def: { [string]: number })
	if not enabled or type(def) ~= "table" then return end
	for k in TUNING.PostDecay do
		local v = def[k]
		if num(v) then post[k] = math.max(post[k], v) end
	end
end

-- dash look: wide FOV, a little forward pull and a light blur while you travel
function Cam.speedHold(duration: number)
	if not enabled or not num(duration) then return end
	speedTarget = 1
	cancel(speedThread)
	speedThread = task.delay(duration, function()
		speedTarget = 0
		speedThread = nil
	end)
end

-- SWING ENERGY (kinetic energy of the blade, E ~ v^2): the faster the tip moves, the more the camera is pulled in (wider lens,
-- a little forward) and the more the view rumbles in the wind. The view also BANKS into the swing like a car in a curve
-- (roll follows the sideways speed of the blade). Call it every frame while the blade is moving: speed in studs/s, lateral = blade speed along the camera's right (studs/s).
function Cam.energy(speedNow: number, lateral: number?)
	if not enabled or not num(speedNow) then return end
	swingTarget = clamp(speedNow / 90, 0, 1)
	swingRollTarget = num(lateral) and clamp(lateral / 90, -1, 1) or 0
	swingStamp = os.clock()
end

-- def = { shake, kick = {pitch, yaw, roll}, push, fov, hold, holdTime, pushHold, post = {...}, speed, sweep = {yaw, pitch, roll, time} }
function Cam.play(def: { [string]: any })
	if not enabled or type(def) ~= "table" then return end
	if def.shake then Cam.shake(def.shake) end
	if type(def.kick) == "table" then Cam.kick(def.kick[1] or 0, def.kick[2] or 0, def.kick[3] or 0) end
	if def.push then Cam.push(def.push) end
	if def.fov then Cam.fov(def.fov) end
	if def.hold then Cam.fovHold(def.hold, def.holdTime or 0.3) end
	if def.pushHold then Cam.pushHold(def.pushHold, def.holdTime or 0.3) end
	if def.post then Cam.post(def.post) end
	if def.speed then Cam.speedHold(def.speed) end
	if type(def.sweep) == "table" then Cam.sweep(def.sweep[1] or 0, def.sweep[2] or 0, def.sweep[3] or 0, def.sweep[4]) end
end

-- the camera as it was BEFORE the shake (use this for aiming and ray casts, not camera.CFrame)
function Cam.cleanCFrame(): CFrame
	local cam = workspace.CurrentCamera
	if not cam then return CFrame.identity end
	if shakenCF and cleanCF and cam.CFrame == shakenCF then
		return cleanCF
	end
	return cam.CFrame
end

--------------------------------------------------------------------------------
-- 4. SCREEN EFFECTS (blur / bloom / color; created on enable, destroyed on disable)
--------------------------------------------------------------------------------
local function makeFx()
	fxBlur = Instance.new("BlurEffect")
	fxBlur.Name = "DarkCamBlur"
	fxBlur.Size = 0
	fxBlur.Enabled = false
	fxBlur.Parent = Lighting
	fxBloom = Instance.new("BloomEffect")
	fxBloom.Name = "DarkCamBloom"
	fxBloom.Intensity = 0
	fxBloom.Size = 30
	fxBloom.Threshold = 0.85
	fxBloom.Enabled = false
	fxBloom.Parent = Lighting
	fxColor = Instance.new("ColorCorrectionEffect")
	fxColor.Name = "DarkCamColor"
	fxColor.Enabled = false
	fxColor.Parent = Lighting
	fxDof = Instance.new("DepthOfFieldEffect")
	fxDof.Name = "DarkCamDof"
	fxDof.FarIntensity = 0
	fxDof.NearIntensity = 0
	fxDof.InFocusRadius = 30
	fxDof.FocusDistance = 20
	fxDof.Enabled = false
	fxDof.Parent = Lighting
end

-- law 10: four edge strips (black, fading to clear toward the middle). Never blocks the mouse.
local function makeTunnel()
	local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then return end
	local old = pg:FindFirstChild("DarkCamTunnel")
	if old then old:Destroy() end
	tunnelGui = Instance.new("ScreenGui")
	tunnelGui.Name = "DarkCamTunnel"
	tunnelGui.IgnoreGuiInset = true
	tunnelGui.ResetOnSpawn = false
	tunnelGui.DisplayOrder = -10
	tunnelGui.Parent = pg
	tunnelFrames = {}
	-- { position, size, gradient rotation }
	for _, d in { { UDim2.fromScale(0, 0), UDim2.fromScale(0.16, 1), 0 }, { UDim2.fromScale(0.84, 0), UDim2.fromScale(0.16, 1), 180 },
		{ UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.14), 90 }, { UDim2.fromScale(0, 0.86), UDim2.fromScale(1, 0.14), 270 } } do
		local f = Instance.new("Frame")
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Active = false
		f.Position, f.Size = d[1], d[2]
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.55), NumberSequenceKeypoint.new(1, 1) })
		g.Rotation = d[3]
		g.Parent = f
		f.Parent = tunnelGui
		table.insert(tunnelFrames, f)
	end
end

local WHITE = Color3.new(1, 1, 1)

local function setFxEnabled(on: boolean)
	local blurFx, bloomFx, colorFx = fxBlur, fxBloom, fxColor
	if blurFx and bloomFx and colorFx and (blurFx.Enabled or bloomFx.Enabled or colorFx.Enabled or on) then
		blurFx.Enabled, bloomFx.Enabled, colorFx.Enabled = on, on, on
	end
	if fxDof and not on then fxDof.Enabled = false end
end

local function updateFx(dt: number)
	local ps = (Cam.settings.Post or 1) * (reduced() and 0 or 1)
	for k, rate in TUNING.PostDecay do
		post[k] = math.max(0, post[k] - rate * dt)
	end
	speed += (speedTarget - speed) * math.min(1, dt * 12)
	focusA += (focusT - focusA) * math.min(1, dt * 6)
	local blurFx, bloomFx, colorFx, dofFx = fxBlur, fxBloom, fxColor, fxDof
	if not (blurFx and bloomFx and colorFx) then return end
	if ps <= 0 then
		setFxEnabled(false)
		return
	end
	local blur = post.blur * 5 + speed * TUNING.DashBlur -- light blur only
	local bloom = post.bloom * 1.1 + post.flash * 1.6
	local tint = post.tint
	local active = blur > 0.05 or bloom > 0.02 or tint > 0.01 or post.flash > 0.01 or post.dim > 0.01 or speed > 0.01 or post.dof > 0.02 or focusA > 0.01
	if not active then
		setFxEnabled(false)
		return
	end
	blurFx.Enabled = blur > 0.05
	blurFx.Size = blur * ps
	bloomFx.Enabled = bloom > 0.02
	bloomFx.Intensity = bloom * ps
	if dofFx then
		local cam = workspace.CurrentCamera
		dofFx.Enabled = post.dof > 0.02
		dofFx.FarIntensity = post.dof * TUNING.DofFar * ps
		if cam then dofFx.FocusDistance = clamp((cam.CFrame.Position - cam.Focus.Position).Magnitude, 4, 80) end
	end
	colorFx.Enabled = true
	colorFx.Contrast = (tint * 0.22 + speed * 0.08 + post.flash * 0.15 + focusA * 0.12) * ps
	colorFx.Saturation = (-tint * 0.18 - focusA * 0.5) * ps
	colorFx.Brightness = (post.flash * 0.12 - post.dim * 0.07 - focusA * 0.03) * ps
	colorFx.TintColor = WHITE:Lerp(tintColor, clamp(tint * 0.5 * ps, 0, 1))
end

--------------------------------------------------------------------------------
-- 5. FRAME UPDATE
--------------------------------------------------------------------------------
-- all motion back to zero (the screen effects are not touched)
local function resetMotion()
	trauma, shown, pushTarget, fovTarget = 0, 0, 0, 0
	fovHoldDur = 0
	for _, s in { kick, sweep, imp } do
		s.x, s.y, s.z, s.vx, s.vy, s.vz = 0, 0, 0, 0, 0, 0
	end
	push.x, push.v, fovS.x, fovS.v = 0, 0, 0, 0
	sweepTarget.x, sweepTarget.y, sweepTarget.z = 0, 0, 0
end

local function restore()
	local cam = workspace.CurrentCamera
	if cam then
		if shakenCF and cam.CFrame == shakenCF then cam.CFrame = cleanCF end
		if shakenFov and cam.FieldOfView == shakenFov then cam.FieldOfView = cleanFov end
	end
	shakenCF, shakenFov = nil, nil
end

-- laws 2, 3, 8, 10: read the body's real speed and fall; returns the lag offset (world), and updates the FOV and tunnel amounts
local function bodyMotion(dt: number)
	local char = Players.LocalPlayer and Players.LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (root and hum) then
		lagOff = lagOff * 0.8
		tunnel += (0 - tunnel) * math.min(1, dt * 6)
		return
	end
	local v = root.AssemblyLinearVelocity
	if not num(v.X) or not num(v.Y) or not num(v.Z) or v.Magnitude > 400 then v = lagVel end -- a teleport or a glitch: ignore this frame
	-- law 2: the filtered velocity lags behind the real one; the difference is the offset
	lagVel += (v - lagVel) * math.min(1, dt / TUNING.LagTime)
	local off = (lagVel - v) * TUNING.LagGain
	if off.Magnitude > TUNING.LagMax then off = off.Unit * TUNING.LagMax end
	lagOff = off
	-- law 3 and 10: horizontal speed
	local hs = Vector3.new(v.X, 0, v.Z).Magnitude
	spdFov += (clamp((hs - 8) / 40, 0, 1) - spdFov) * math.min(1, dt * 4)
	local tn = clamp((hs - TUNING.TunnelFrom) / 50, 0, 1) * TUNING.TunnelMax + speed * 0.25
	tunnel += (tn - tunnel) * math.min(1, dt * 5)
	-- law 8: landing. The fall speed of the last frame in the air decides how far the camera sinks
	local air = hum.FloorMaterial == Enum.Material.Air
	-- GAIT CAMERA: the head bobs twice per stride (lowest at each footfall), sways side to side once per stride and rolls a hair with it.
	-- It reads the stride phase the rig publishes, so the bob lands on the footsteps. Run = a bigger, faster bob.
	local gp = char:GetAttribute("DarkGaitPhase")
	local gw = char:GetAttribute("DarkGaitW")
	local gr = char:GetAttribute("DarkGaitRun")
	if typeof(gp) == "number" and typeof(gw) == "number" and not air then
		gr = if typeof(gr) == "number" then gr else 0
		local g = gw * (0.6 + 0.4 * gr)
		gaitOff.y = -math.cos(2 * gp) * (0.035 + 0.06 * gr) * g
		gaitOff.x = math.sin(gp) * (0.03 + 0.012 * gr) * g
		gaitOff.roll = math.sin(gp) * 0.35 * g
		gaitOff.pitch = math.cos(2 * gp) * (0.25 + 0.5 * gr) * g
	else
		local k = math.min(1, dt * 10)
		gaitOff.y *= 1 - k; gaitOff.x *= 1 - k; gaitOff.roll *= 1 - k; gaitOff.pitch *= 1 - k
	end
	-- JUMP: the take-off pushes the camera up a little and nods it up; the lens opens a hair
	if not wasAir and air and v.Y > 10 then
		imp.vy += 0.15 * w(TUNING.Impulse.f) * TUNING.ImpulseGain
		kick.vx += 0.2 * w(TUNING.Kick.f) * TUNING.KickGain
		fovS.v += 1.2 * w(TUNING.Fov.f) * TUNING.FovGain
	end
	if wasAir and not air and vyPrev < -TUNING.LandMin then
		local f = clamp((-vyPrev - TUNING.LandMin) / 65, 0, 1)
		imp.vy -= f * TUNING.LandDip * w(TUNING.Impulse.f) * TUNING.ImpulseGain
		kick.vx -= f * 1.2 * w(TUNING.Kick.f) * TUNING.KickGain -- a small nod down
		trauma = math.min(1, trauma + 0.08 * f)
	end
	wasAir = air
	if air then vyPrev = v.Y end
end

local lastTunnelA = -1
local function updateTunnel()
	if not tunnelFrames then return end
	local ps = (Cam.settings.Post or 1) * (reduced() and 0 or 1)
	local a = clamp(tunnel * ps, 0, 1)
	if abs(a - lastTunnelA) < 0.002 then return end -- unchanged: skip the 8 property writes
	lastTunnelA = a
	for _, f in tunnelFrames do
		f.Visible = a > 0.01
		f.BackgroundTransparency = 1 - a
	end
end

-- two octaves of noise (the second twice as fast, half as strong) = a rougher, more natural shake than one smooth wave
-- (defined once here: it used to be a new closure every frame)
local function fbm(a, b) return (noise(a, b) + 0.5 * noise(a * 2.1 + 3.3, b * 2.1 + 1.7)) / 1.5 end

local function apply(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then return end
	dt = math.min(dt, 1 / 20)
	bodyMotion(dt)
	updateTunnel()

	-- trauma falls linearly; the shown value follows it up quickly (soft start), down at once
	-- energy loss: part exponential (fast at first, long soft tail) and part linear (so it really ends)
	trauma = math.max(0, trauma * math.exp(-1.1 * dt) - TUNING.Decay * 0.55 * dt)
	if trauma >= shown then
		shown = math.min(trauma, shown + TUNING.Attack * dt)
	else
		shown = trauma
	end
	updateFx(dt)

	-- the springs must take small steps: (frequency * 2 pi * step) must stay under about 1.
	-- At 60 fps this is 2 steps (as before); at low frame rates it grows up to 6.
	local steps = math.clamp(math.ceil(dt * w(TUNING.Kick.f)), 2, 6)
	local h = dt / steps
	if os.clock() - swingStamp > 0.12 then swingTarget, swingRollTarget = 0, 0 end -- no fresh data: let it settle
	swingE += (swingTarget - swingE) * math.min(1, dt * (swingTarget > swingE and 14 or 5)) -- rises fast, falls slowly (inertia)
	swingRoll += (swingRollTarget - swingRoll) * math.min(1, dt * 9)
	local pt = pushTarget + speed * TUNING.DashPush + swingE * swingE * 0.1 -- dashing pulls the view slightly forward
	if fovHoldDur > 0 then fovTarget = fovEnvelope() end
	local ft = fovTarget + speed * TUNING.DashFov + spdFov * TUNING.SpeedFov + swingE * swingE * 1.5 -- and opens the view a little (also with real speed, law 3)
	for _ = 1, steps do
		spring3(kick, 0, 0, 0, TUNING.Kick, h)
		spring1(push, pt, TUNING.Push, h)
		spring1(fovS, ft, TUNING.Fov, h)
		spring3(sweep, sweepTarget.x, sweepTarget.y, sweepTarget.z, TUNING.Sweep, h)
		spring3(imp, 0, 0, 0, TUNING.Impulse, h)
	end

	-- a NaN anywhere would ruin the picture for good: if one slipped in, start again from zero
	local sum = kick.x + kick.y + kick.z + sweep.x + sweep.y + sweep.z + imp.x + imp.y + imp.z + push.x + fovS.x + trauma
		+ kick.vx + kick.vy + kick.vz + imp.vx + imp.vy + imp.vz + push.v + fovS.v
	if sum ~= sum or sum == math.huge or sum == -math.huge then
		resetMotion()
		return
	end

	local k = strength()
	local lagLocal = cam.CFrame:VectorToObjectSpace(lagOff)
	local lagBig = lagOff.Magnitude > 0.004
	local s = (shown * shown + swingE * swingE * swingE * 0.03) * k -- the rumble of the wind grows with the cube of the swing energy
	local kickBig = abs(kick.x) + abs(kick.y) + abs(kick.z) > 0.02
	local sweepBig = abs(sweep.x) + abs(sweep.y) + abs(sweep.z) > 0.02
	local impBig = abs(imp.x) + abs(imp.y) + abs(imp.z) > 0.003
	if s > 0.0005 or kickBig or sweepBig or impBig or abs(push.x) > 0.003 or abs(fovS.x) > 0.02 or lagBig or swingE > 0.02 or abs(gaitOff.y) > 0.002 or abs(gaitOff.roll) > 0.02 then
		local t = os.clock() * TUNING.NoiseSpeed
		local rx = fbm(t, seed) * s * rad(TUNING.MaxRot)
		local ry = fbm(seed, t) * s * rad(TUNING.MaxRot)
		local rz = fbm(t, t + seed) * s * rad(TUNING.MaxRoll)
		local px = fbm(t + 7, seed) * s * TUNING.MaxMove
		local py = fbm(seed, t + 7) * s * TUNING.MaxMove
		-- all moves add up, then get softly limited so the view can never swing wildly
		local pitch = soft(kick.x + sweep.y, TUNING.MaxTurn) * k
		local yaw = soft(kick.y + sweep.x, TUNING.MaxTurn) * k
		local roll = soft((kick.z + sweep.z) * 0.4 + swingRoll * swingE * 0.9, TUNING.MaxRollTotal) * k
		cleanCF = cam.CFrame
		cleanFov = cam.FieldOfView
		cam.CFrame = cleanCF
			* CFrame.new(px + (imp.x + lagLocal.X + gaitOff.x) * k, py + (imp.y + lagLocal.Y + gaitOff.y) * k, -push.x * k + (imp.z + lagLocal.Z) * k)
			* CFrame.Angles(rx + rad(pitch + gaitOff.pitch * k), ry + rad(yaw), rz + rad(roll + gaitOff.roll * k))
		cam.FieldOfView = clamp(cleanFov + soft(fovS.x, TUNING.MaxFov) * k, 20, 100)
		shakenCF = cam.CFrame
		shakenFov = cam.FieldOfView
	end
end

--------------------------------------------------------------------------------
-- 6. ENABLE / DISABLE
--------------------------------------------------------------------------------
function Cam.enable()
	if enabled then return end
	enabled = true
	-- if an old binding with the same name is still there (a tool that vanished before it could clean up)
	pcall(function() RunService:UnbindFromRenderStep("DarkCamApply") end)
	pcall(function() RunService:UnbindFromRenderStep("DarkCamRestore") end)
	for _, name in { "DarkCamBlur", "DarkCamBloom", "DarkCamColor", "DarkCamDof" } do
		local old = Lighting:FindFirstChild(name)
		if old then old:Destroy() end
	end
	makeFx()
	makeTunnel()
	lastTunnelA = -1
	lagVel, lagOff, spdFov, tunnel, wasAir, vyPrev = Vector3.zero, Vector3.zero, 0, 0, false, 0
	-- the default camera runs at Camera (200): undo our offset just before it, apply a new one just after
	RunService:BindToRenderStep("DarkCamRestore", Enum.RenderPriority.Camera.Value - 1, restore)
	RunService:BindToRenderStep("DarkCamApply", Enum.RenderPriority.Camera.Value + 1, apply)
end

function Cam.disable()
	if not enabled then return end
	enabled = false
	pcall(function() RunService:UnbindFromRenderStep("DarkCamApply") end)
	pcall(function() RunService:UnbindFromRenderStep("DarkCamRestore") end)
	restore() -- give the player's camera back clean
	for _, e in { fxBlur, fxBloom, fxColor, fxDof, tunnelGui } do
		if e then e:Destroy() end
	end
	fxBlur, fxBloom, fxColor, fxDof, tunnelGui, tunnelFrames = nil, nil, nil, nil, nil, nil
	lastTunnelA = -1
	lagVel, lagOff, spdFov, tunnel = Vector3.zero, Vector3.zero, 0, 0
	swingE, swingTarget, swingRoll, swingRollTarget = 0, 0, 0, 0
	for _, th in { fovHoldThread, pushHoldThread, sweepThread, speedThread } do cancel(th) end
	fovHoldThread, pushHoldThread, sweepThread, speedThread = nil, nil, nil, nil
	for k in post do post[k] = 0 end
	speed, speedTarget = 0, 0
	resetMotion()
end

return Cam
