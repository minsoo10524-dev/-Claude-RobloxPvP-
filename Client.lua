--!strict
-- LocalScript "Client"  (parent: Tool "DarkV1")
-- One file: CONFIG, effects (slash disc, hit picture, debris, blade glow), the attack controller (prediction, buffer, soft-lock)
-- and the Server feedback handler. Body animation lives in the module SwordRig, the camera in CameraFx, sounds in SwordSfx.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")

type Spring = { x: number, v: number, w: number, z: number }
type StepT = { [string]: any } -- a combo step (poses, timings, camera cues) from SwordRig
type Lunge = { freeze: (on: boolean) -> (), stop: () -> () }
type PrevState = { readyAt: number, comboIndex: number, comboClock: number }
type Session = {
	seq: number, index: number, step: StepT, alive: boolean, startClock: number, cleanups: { () -> () },
	prev: PrevState,
	target: { dir: Vector3, dist: number, model: Model }?, dir: Vector3, lungeCtl: Lunge?, slamStart: number?, caught: boolean?,
}

-- guard(fn): wraps a PURELY VISUAL function so that an error in it is printed as a warning and never stops the gameplay code that called it
local function guard<A...>(fn: (A...) -> ()): (A...) -> ()
	return function(...: A...)
		local ok, err = pcall(fn, ...)
		if not ok then warn("[DarkSword] effect error: " .. tostring(err)) end
	end
end
-- budget for the speed lines: too many at once (many enemies, fast clicking) are skipped, not stacked
local linesAlive = 0
local LINES_MAX = 3

local tool = script.Parent :: Tool

-- If an old copy of this script (or a second Client) is also inside the Tool, two copies would
-- each draw their own effect. Only the first one keeps running.
if tool:GetAttribute("DarkSwordClientRunning") then
	warn("[DarkSword] a second Client script is running on", tool.Name, "- stopping this copy (", script:GetFullName(), ")")
	return
end
tool:SetAttribute("DarkSwordClientRunning", true)
local player = Players.LocalPlayer
local attackRemote = tool:WaitForChild("Attack") :: RemoteEvent
local feedbackRemote = tool:WaitForChild("FeedbackFX") :: RemoteEvent
local handle = tool:WaitForChild("Handle") :: BasePart

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local CONFIG = {
	-- Direction fixes. If a motion turns the wrong way, flip the sign to -1.
	YawSign = 1,
	PitchSign = 1,
	ArmCrossSign = 1, -- hit 1: the sword arm crosses to the LEFT leg; if it swings away from the body instead, change this to -1
	RollSign = 1, -- side bend of the waist: if the body leans the WRONG way in the swing, change this to -1
	ElbowSign = 1,

	-- Combo / input (must match the server)
	ComboReset = 2.0, -- seconds after the start of a swing in which the next hit continues the combo (the Server's COMBO_RESET must be the same)
	Buffer = 0.15,
	BufferFinisher = 0.10,
	BufferMargin = 0.03,
	RejectBlend = 0.1,
	SessionExtra = 0.15,

	-- Animation feel
	AnticipateRatio = 0.35,
	RecoverTime = 0.45, -- seconds to settle back into the ready pose (longer = softer)
	SettleTime = 0.22, -- the "let go" keyframe between the last strike and the ready pose
	HitStopScale = 0.04,

	-- Soft-lock (aim assist for body direction and dash distance)
	LockRadius = 14,
	LockCone = 50,
	LockStopDistance = 3.5,
	PersonalSpace = 3.0, -- closer than this (studs, root to root): you step back instead of lunging
	TurnSpeed = 900, -- degrees per second

	-- Camera
	CameraStrength = 1, -- 0 = off, 1 = full (shake, kick, push, FOV)
	CameraPost = 1, -- 0 = off, 1 = full (blur / bloom / color pulses on the screen)
}

--------------------------------------------------------------------------------
-- Effect helpers (shared state lives in this one table)
--------------------------------------------------------------------------------
local Vfx: { [string]: any } = {}

-- THE ONE COLOR FAMILY (color science): every effect color comes from ONE hue family on the same lightness ramp, in Oklch
-- (a perceptual space: equal steps in L look like equal steps in brightness, and hue stays put when chroma changes).
-- Hue stays at 20-25 (crimson) the whole way; only lightness and chroma move: white-hot (high L, almost no chroma) ->
-- pale pink -> rose -> hot red -> crimson -> deep -> near black. Hot things look WHITER, not different colors (like real heat glow).
-- The RGB values were computed with the same Oklch matrices as oklch().
Vfx.PAL = {
	white = Color3.fromRGB(255, 241, 241), pale = Color3.fromRGB(255, 198, 196), rose = Color3.fromRGB(251, 129, 127),
	hot = Color3.fromRGB(244, 81, 82), crim = Color3.fromRGB(219, 43, 51), deep = Color3.fromRGB(141, 25, 37), dark = Color3.fromRGB(61, 16, 20),
}
local PAL: { [string]: Color3 } = Vfx.PAL
-- a tint recolours an effect (the Z skill's cold colours, see BLINK below): `from` and `to` are the colours at the start and at the end of its life,
-- at(t) = the gradient between them (t = 0..1), bright(u) = the hot centre of a flash (u = 0..1), k = how strongly the tint replaces the normal colour
type Tint = { from: Color3, to: Color3, k: number, at: (number) -> Color3, bright: (number) -> Color3, map: (Color3) -> Color3, doppler: boolean?, set: string? }

-- law 185 (multi-sense match): the pad shakes with the picture and the sound
Vfx.rumble = function(large: number, small: number, secs: number)
	pcall(function()
		local HS = game:GetService("HapticService")
		local pad = Enum.UserInputType.Gamepad1
		if not HS:IsVibrationSupported(pad) then return end
		local hasLarge = HS:IsMotorSupported(pad, Enum.VibrationMotor.Large)
		local hasSmall = HS:IsMotorSupported(pad, Enum.VibrationMotor.Small)
		if hasLarge then HS:SetMotor(pad, Enum.VibrationMotor.Large, math.clamp(large, 0, 1)) end
		if hasSmall then HS:SetMotor(pad, Enum.VibrationMotor.Small, math.clamp(small, 0, 1)) end
		task.delay(secs, function()
			pcall(function()
				if hasLarge then HS:SetMotor(pad, Enum.VibrationMotor.Large, 0) end
				if hasSmall then HS:SetMotor(pad, Enum.VibrationMotor.Small, 0) end
			end)
		end)
	end)
end
-- law 160 (level of detail): far things need fewer particles. Full detail within 40 studs of the camera, falling to 40 % at 200 studs.
Vfx.lodK = function(pos: Vector3): number
	local cam = workspace.CurrentCamera
	if not cam then return 1 end
	local d = (pos - cam.CFrame.Position).Magnitude
	return math.clamp(1 - (d - 40) / 160 * 0.6, 0.4, 1)
end
-- the material of a flying bit: the material of what it was broken from, except Neon and Glass (they would glow or be see-through)
local function bitMaterial(m: Enum.Material): Enum.Material
	if m == Enum.Material.Neon or m == Enum.Material.Glass then
		return Enum.Material.SmoothPlastic
	end
	return m
end
-- DISTANCE COMPENSATION: an effect that is seen from far away looks tiny (perspective), so it is made bigger in proportion to the distance
-- from the camera (1 inside 22 studs, up to 3.2 times at 70 studs and more): it keeps about the same size on the screen.
local function distScale(pos: Vector3): number
	local cam = workspace.CurrentCamera
	if not cam then return 1 end
	return math.clamp((pos - cam.CFrame.Position).Magnitude / 22, 1, 3.2)
end
-- one shared RaycastParams for rays that are cast at once (no waiting between setting the filter and the ray): saves an allocation per hit
local POOL_RAY = RaycastParams.new()
POOL_RAY.FilterType = Enum.RaycastFilterType.Exclude
Vfx.exRay = function(list: { Instance }): RaycastParams
	POOL_RAY.FilterDescendantsInstances = list
	return POOL_RAY
end

local SLASH_IMAGE = "rbxassetid://14187131206" -- the slash picture (drawn on both sides of every slash layer)
-- SEDOV-TAYLOR BLAST WAVE: after the first instant the front of an explosion grows as R ~ t^(2/5) (fast at first, then ever slower). This returns a
-- size curve of that shape for a layer: it starts at r0 (share of the final size) and reaches 1 at the end of the life.
local function sedov(r0: number): { { number } }
	local keys: { { number } } = {}
	for _, x in { 0, 0.05, 0.1, 0.2, 0.4, 0.7, 1 } do
		table.insert(keys, { x, r0 + (1 - r0) * x ^ 0.4 })
	end
	return keys
end
local FX_HIT_SCALE = 0.55 -- overall size of the hit picture: 1 = the old size; smaller = smaller
-- THE HIT PICTURE = three layers, each ONE picture at a time (a sheet is read one cell at a time, so it can never show as several):
--   image / cols x rows = the sheet and its grid,  frames = how many cells are played (row by row from the top left)
--   life = seconds the layer lives,  size = its size compared with the base,  delay = seconds after the hit,  tint = color
local FX_HIT_LAYERS = {
	-- Every number below is one "detail setting". Curves are lists of { time 0..1 of the layer's life, value }, blended smoothly between points.
	--   sizeCurve   = size over life (1 = the layer's size)           alphaCurve = TRANSPARENCY over life (0 = solid, 1 = gone)
	--   squash      = wide (above 1) or tall (below 1) stretch over life, the area stays about the same
	--   colorFrom -> colorTo = the color travels from one to the other over the life
	--   spinSpeed   = degrees per second (single pictures only)       drift = studs per second the layer flies along the hit direction (eases out)
	--   spread / toward = where it sits (random sideways spread, pushed toward the attacker when positive, behind the hit point when negative)
	{ -- BURST: the big starburst picture (12402888086, a single picture): the first and shortest layer, the white-hot core of the hit
		name = "burst", image = "rbxassetid://12402888086", cols = 1, rows = 1, frames = 1, life = 0.16, size = 3.0, delay = 0,
		sizeCurve = sedov(0.3), alphaCurve = { { 0, 0 }, { 0.5, 0.1 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } },
		colorFrom = PAL.white, colorTo = PAL.rose, spinSpeed = 25, drift = 0, spread = 0.15, toward = 0.6 },	{ -- MAIN: the hit burst (10198434999), 4 x 4 frames: a ring opens, a flash with sparks flares up and thins out. The first cells are the ring,
		-- so it starts at frame 7 (the flash with the sparks) and the ring is never shown.
		name = "main", image = "rbxassetid://10198434999", cols = 4, rows = 4, frames = 16, startFrame = 7, life = 0.45, size = 2.5, delay = 0,
		sizeCurve = sedov(0.55), alphaCurve = { { 0, 0 }, { 0.88, 0 }, { 1, 1 } }, squash = { { 0, 1.15 }, { 0.25, 1 } }, -- biggest, solid longest, a hard pop at the start; grows like a blast wave (t^(2/5))
		colorFrom = PAL.white, colorTo = PAL.pale, spinSpeed = 0, drift = 0, spread = 0.2, toward = 0.5 },
	{ -- ECHO: the same burst again, bigger, softer and deep crimson, 3 frames later (also without the ring). White core + colored glow = depth
		name = "echo", image = "rbxassetid://10198434999", cols = 4, rows = 4, frames = 16, startFrame = 7, life = 0.42, size = 3.3, delay = 3 / 30,
		sizeCurve = sedov(0.5), alphaCurve = { { 0, 0.55 }, { 0.5, 0.62 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } },
		colorFrom = PAL.hot, colorTo = PAL.deep, spinSpeed = 0, drift = 0, spread = 0.2, toward = 0.2 },	{ -- SHARDS: the fragment sheet (10198439352), 4 x 4 frames: a small star with fragments flying out that fade; the first cell and the last cells are
		-- nearly empty, so cells 1 to 11 are played. It follows the burst two frames later.
		name = "shards", image = "rbxassetid://10198439352", cols = 4, rows = 4, frames = 12, startFrame = 1, life = 0.4, size = 2.6, delay = 2 / 30,
		sizeCurve = sedov(0.5), alphaCurve = { { 0, 0.1 }, { 0.6, 0.2 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } },
		colorFrom = PAL.pale, colorTo = PAL.crim, spinSpeed = 0, drift = 0, spread = 0.3, toward = 0.3 },	{ -- STARLIGHT: only a short afterglow that shows up a few frames LATER (120067432715909), the last thing to appear
		name = "starlight", image = "rbxassetid://120067432715909", cols = 2, rows = 2, frames = 4, life = 0.2, size = 0.7, delay = 6 / 30,
		sizeCurve = { { 0, 0.5 }, { 0.5, 1 }, { 1, 1.05 } }, alphaCurve = { { 0, 0.4 }, { 0.3, 0.4 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } }, -- half see-through: a quiet afterglow
		colorFrom = PAL.white, colorTo = PAL.rose, spinSpeed = 0, drift = 0, spread = 0.5, toward = 0.3 },
	{ -- SPARKS: a burst of fine sparks (311395391, a single picture), one frame after the main flash; short and smaller than the main burst
		name = "sparks", image = "rbxassetid://311395391", cols = 1, rows = 1, frames = 1, life = 0.16, size = 0.5, delay = 8 / 30,
		sizeCurve = { { 0, 0.9 }, { 1, 0.45 } }, alphaCurve = { { 0, 0.45 }, { 0.5, 0.6 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } }, -- late, tiny and dim: it only dusts the end of the hit, it must not look like a second main burst
		colorFrom = PAL.white, colorTo = PAL.rose, spinSpeed = 0, drift = 0, spread = 0.4, toward = 0.2 },
}

-- the speed-line picture drawn behind a flying enemy (a single picture)
local SPEED_IMAGE = "rbxassetid://7216979807"

-- POOL of speed-line parts (one Part + one Decal each): the lines are made in bursts, so instead of Instance.new/Destroy every time the finished
-- parts are kept (unparented) and reused. Callers set Size, CFrame, Color3 and Parent themselves, exactly as before.
local linePool: { Part } = {}
local LINE_POOL_MAX = 48
local function acquireLine(name: string): (Part, Decal)
	local part = table.remove(linePool)
	if part then
		part.Name = name
		part.Transparency = 1
		local decal = part:FindFirstChildOfClass("Decal") :: Decal
		decal.Transparency = 1
		return part, decal
	end
	part = Instance.new("Part")
	part.Name = name
	part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = true, false, false, false, false
	part.Transparency = 1
	local decal = Instance.new("Decal")
	decal.Texture = SPEED_IMAGE
	decal.Face = Enum.NormalId.Back -- the part's +Z side faces the camera (turned every frame)
	decal.Transparency = 1
	decal.Parent = part
	return part, decal
end
local function releaseLine(part: Part)
	if #linePool >= LINE_POOL_MAX then
		part:Destroy()
		return
	end
	part.Parent = nil
	table.insert(linePool, part)
end

local F = 1 / 30
-- value of a curve at time t (smooth blend between the points)
local function curve(keys: { { number } }?, t: number): number
	if keys == nil or #keys == 0 then return 1 end -- a layer without this curve: no change (a nil curve used to crash here)
	if t <= keys[1][1] then return keys[1][2] end
	for i = 2, #keys do
		local k1, k2 = keys[i - 1], keys[i]
		if t <= k2[1] then
			local k = (t - k1[1]) / math.max(k2[1] - k1[1], 1e-4)
			k = k * k * (3 - 2 * k)
			return k1[2] + (k2[2] - k1[2]) * k
		end
	end
	return keys[#keys][2]
end
-- ONE big slash disc around the torso (like the reference video): the picture lies in a
-- plane that goes through the chest and is tilted, the arc bulges behind you and its ends
-- reach forward. The Part is reused; a new slash cancels the old one, so only ONE exists.
-- Per hit: size0 -> size1 (studs), life (s), tilt (degrees the plane leans sideways:
-- 0 = flat like a plate, 90 = standing up), roll (turns the arc inside its plane),
-- spin (degrees it turns while it lives), fwd (studs in front of the chest).
-- The start spot is the same for every hit: chest height, `fwd` studs in front of you.
-- travel = studs it drifts forward from there (0 = stays put); dy = how far it rises (+) / sinks (-)
-- The disc starts at chest height, `fwd` studs in front of you, leaning `tilt` degrees (3 for every hit), and stays there.
local FX_EMIT = {
	-- The tilt is the same for every hit. Only the START SPOT differs per hit:
	-- side = studs right (+) / left (-), fwd = studs ahead, oy = studs up (+) / down (-) from the chest spot.
	{ size0 = 11, size1 = 24, life = 0.42, tilt = 3, roll = 0, spin = -40, fwd = 0.3, side = -0.6, oy = 0.6, travel = 0, dy = 0 },
	{ size0 = 11, size1 = 24, life = 0.42, tilt = 3, roll = 0, spin = -40, fwd = 0.4, side = 0.7, oy = -0.2, travel = 0, dy = 0 },
	{ size0 = 12, size1 = 20, life = 0.26, tilt = 3, roll = 0, spin = -40, fwd = 0.7, side = 0.1, oy = 1.0, travel = 0, dy = 0 },
	{ size0 = 14, size1 = 22, life = 0.28, tilt = 3, roll = 0, spin = 200, fwd = 0, side = 0, oy = 0, travel = 0, dy = 0 }, -- [4] ring around you (blast)
}
local FX_WALL_PEEK = 0.3 -- keep the disc this far above the floor

-- SLASH DISC: six stacked copies of the SAME picture (white core, crimson middle, ember outer glow), each with its own size / start delay / roll offset. Every frame (PreRender) the discs are placed again at
-- "your body x fixed offset", so they stay in front of you while the swing pushes your body forward (they never stay behind at
-- the spawn spot). The tilt stays exactly cfg.tilt (3 degrees); roll only turns the arc INSIDE its plane. The fade is hand-made:
-- it holds opaque at first, then drops fast at the end (alpha ease-in), while the size grows fast and then stops (ease-out).
-- All numbers are estimates: tune them in Studio.
local SLASH_LAYERS = {
	-- scale = size multiplier, delay = seconds after the start, roll = degrees added inside the plane, lift = studs up (no z-fight),
	-- peak = the LOWEST transparency this layer reaches at the apex K. All peaks stay close together.
	-- dL / dH = this layer's small Oklch lightness / hue offset from the section colors, pow = growth sharpness, life = share of the slash life.
	{ scale = 0.84, delay = 0.000, roll = 0,   lift = 0.070, peak = 0.14, dL = 0.30,  dH = 4,  cm = 0.15,  pow = 5, life = 0.88 },
	{ scale = 0.92, delay = 0.012, roll = 5,   lift = 0.056, peak = 0.16, dL = 0.18,  dH = 2,  cm = 0.35,  pow = 4.6, life = 0.94 },
	{ scale = 1.00, delay = 0.024, roll = -6,  lift = 0.042, peak = 0.17, dL = 0.00,  dH = 0,  cm = 0.85,  pow = 4.2, life = 1.00 },
	{ scale = 1.08, delay = 0.036, roll = 10,  lift = 0.028, peak = 0.19, dL = -0.04, dH = -2, cm = 1.0, pow = 3.8, life = 1.05 },
	{ scale = 1.20, delay = 0.048, roll = -12, lift = 0.014, peak = 0.30, dL = -0.14, dH = -3, cm = 0.9, pow = 3.4, life = 1.10 },
	{ scale = 1.34, delay = 0.060, roll = 14,  lift = 0.000, peak = 0.38, dL = -0.24, dH = -4, cm = 0.75, pow = 3.0, life = 1.16 },
}

-- THE 3-SECTION CURVE. x = share of the life (0..1), result 0..1.
-- Section 1 (M -> K'): almost a straight line. Section 2 (K' -> K): a parabola that begins with the SAME slope, so the join is smooth
-- (the end of the line is slightly rounded, not a corner). Section 3: the apex K. After K the curve is mirrored (K -> K'' -> M').
-- Math: line y = s*u up to u0, then y = 1 - c*(1-u)^2 with s = 2/(1+u0) and c = s/(2*(1-u0)); they meet with equal value AND slope.
local CURVE_K1 = 0.60 -- where section 1 (the straight part) ends, as a share of the rise
local CURVE_APEX = 0.45 -- where the apex K sits in the life
local function curveRise(u: number): number
	u = math.clamp(u, 0, 1)
	local u0 = CURVE_K1
	local s = 2 / (1 + u0)
	if u <= u0 then
		return s * u
	end
	local c = s / (2 * (1 - u0))
	return 1 - c * (1 - u) ^ 2
end
-- full shape: rises to 1 at the apex, then mirrors down to 0 at the end. Returns value, section (1, 2 or 3)
local function curve3(x: number): (number, number, number)
	x = math.clamp(x, 0, 1)
	local u: number
	if x <= CURVE_APEX then
		u = x / CURVE_APEX
	else
		u = (1 - x) / (1 - CURVE_APEX)
	end
	local sec = u < CURVE_K1 and 1 or (u < 0.97 and 2 or 3)
	return curveRise(u), sec, u
end

-- Oklch -> Color3 (Bjorn Ottosson's Oklab matrices). L 0..1, C chroma, H degrees. Out-of-gamut values are clamped.
local function oklch(L: number, C: number, Hdeg: number): Color3
	local h = math.rad(Hdeg)
	local a, b = C * math.cos(h), C * math.sin(h)
	local l_ = L + 0.3963377774 * a + 0.2158037573 * b
	local m_ = L - 0.1055613458 * a - 0.0638541728 * b
	local s_ = L - 0.0894841775 * a - 1.2914855480 * b
	local l, m, s = l_ ^ 3, m_ ^ 3, s_ ^ 3
	local r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
	local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
	local bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	local function enc(v: number): number
		v = math.clamp(v, 0, 1)
		return v <= 0.0031308 and 12.92 * v or 1.055 * v ^ (1 / 2.4) - 0.055
	end
	return Color3.new(enc(r), enc(g), enc(bl))
end
-- L / C / H differ per section (estimates, tune in Studio): S1 dark deep red, S2 vivid crimson, S3 hot pale core at the apex
local SEC_L = { 0.44, 0.66, 0.92 }
local SEC_C = { 0.10, 0.19, 0.06 }
local SEC_H = { 10, 25, 40 }
-- color along the rise u (0..1): S1 at u=0, S2 at the end of the straight part, S3 at the apex (L, C, H blended each)
local function slashColor(u: number, dL: number, dH: number, cm: number?): Color3
	local u0 = CURVE_K1
	local L: number, C: number, H: number
	if u <= u0 then
		local k = u / u0
		L, C, H = SEC_L[1] + (SEC_L[2] - SEC_L[1]) * k, SEC_C[1] + (SEC_C[2] - SEC_C[1]) * k, SEC_H[1] + (SEC_H[2] - SEC_H[1]) * k
	else
		local k = (u - u0) / (1 - u0)
		L, C, H = SEC_L[2] + (SEC_L[3] - SEC_L[2]) * k, SEC_C[2] + (SEC_C[3] - SEC_C[2]) * k, SEC_H[2] + (SEC_H[3] - SEC_H[2]) * k
	end
	return oklch(math.clamp(L + dL, 0, 1), C * (cm or 1), H + dH)
end
local SLASH_TR_START = 0.72 -- section 1 never starts at transparency 0: it begins faint
local SLASH_LIGHT_PEAK = 2.2 -- PointLight brightness at the apex
-- AERIAL PERSPECTIVE (law 28): far things lose contrast and take on the color of the air. The color is mixed toward the scene's fog
-- color by 1 - e^(-d/350) (at most 60 %), d = distance from the camera. Used for dust, drops and floor bits.
-- the other way round: a colour -> its OKLCH (L lightness, C chroma, H hue in degrees), with the same matrices as oklch() above
local function oklchOf(c: Color3): (number, number, number)
	local function lin(x: number): number
		return if x <= 0.04045 then x / 12.92 else ((x + 0.055) / 1.055) ^ 2.4
	end
	local r, g, b = lin(c.R), lin(c.G), lin(c.B)
	local l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ^ (1 / 3)
	local m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ^ (1 / 3)
	local s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ^ (1 / 3)
	local L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
	local A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
	local B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
	return L, math.sqrt(A * A + B * B), math.deg(math.atan2(B, A)) % 360
end

-- FAR EFFECTS (the throw and the landing of the Z finish are seen from far away, because the enemy flies off): a small light-coloured thing against the
-- sky loses its colour first, and AERIAL PERSPECTIVE (above) would make it worse, mixing it toward the fog colour. Light that a thing GIVES OFF is not
-- fogged like matter, so these effects skip the fog mix and instead get MORE chroma with the distance (up to +60 % from 125 studs on, and a little
-- lighter), so that the colour still reads when the picture is small.
local function farBoost(c: Color3, pos: Vector3): Color3
	local cam = workspace.CurrentCamera
	if not cam then return c end
	local k = math.clamp(((pos - cam.CFrame.Position).Magnitude - 25) / 100, 0, 1)
	if k <= 0 then return c end
	local L, C, H = oklchOf(c)
	return oklch(math.min(L + 0.04 * k, 0.99), C * (1 + 0.6 * k), H)
end

-- BLINK CUT (the Z skill) has the COLOURS OF THE NORMAL ATTACK (white-hot heart, rose glow, crimson edge): the names below are kept because the
-- code of the skill uses them, but they are the palette of hit 3. A tint is still handed to the effects (it tells them which hit pictures to use
-- and that the Z lines are not fogged), and its map changes nothing.
local BLINK = {
	white = PAL.white, ice = PAL.pale, cyan = PAL.rose, violet = PAL.crim, deep = PAL.deep,
}
local BLINK_TINT: Tint = {
	from = PAL.pale, to = PAL.crim, k = 1, set = "zc", -- (the cuts: their hit pictures are Z_CUT_LAYERS)
	at = function(t: number): Color3 return PAL.pale:Lerp(PAL.crim, math.clamp(t, 0, 1)) end,
	bright = function(u: number): Color3 return PAL.pale:Lerp(PAL.white, math.clamp(u, 0, 1)) end,
	map = function(c: Color3): Color3 return c end,
}
-- the throw of the finish: the colours and the hit pictures of hit 3, unchanged (no set of its own); its flight lines are pale like those of hit 3
local FLING_TINT: Tint = {
	from = PAL.pale, to = PAL.crim, k = 1, doppler = false,
	at = function(t: number): Color3 return PAL.pale:Lerp(PAL.crim, math.clamp(t, 0, 1)) end,
	bright = function(u: number): Color3 return PAL.pale:Lerp(PAL.white, math.clamp(u, 0, 1)) end,
	map = function(c: Color3): Color3 return c end,
}
-- THE HIT PICTURES OF THE Z THROW: its own set of three pictures (the sheets 10198434999 and 10198439352 and the picture 14622697144), used only by the
-- throw (FLING_TINT.set = "z"); the 25 cuts keep the big star of hit 3. What makes the three read as three different things:
--   * every one is played through ALL its frames, slowly enough that each frame can be seen (the sheets change their shape from frame to frame: the
--     ring that opens, the flash, the fragments), and each has its own colour ramp, directly in the cold palette (they are not recoloured, and no
--     colour is dark: a picture is TINTED by multiplying, so a dark colour would make a dark blob): white-ice for the pop, ice to cyan for the core,
--     cyan to violet for the fragments;
--   * PHYSICS: the pop spreads like a blast wave (size ~ t^(2/5), Sedov-Taylor); the fragments carry the momentum of the enemy (they drift along the
--     throw and slow down with the air) and FALL under gravity (y = g t^2 / 2, with g scaled down so that the picture still reads).
-- 14622697144 is used as ONE picture (cols = rows = frames = 1); if it is a sheet, set its grid here.
local Z_HIT_LAYERS = {
	{ -- the pop: the burst sheet, ALL its frames (the ring opens, then the flash)
		name = "zmain", image = "rbxassetid://10198434999", cols = 4, rows = 4, frames = 16, startFrame = 0, life = 0.6, size = 2.8, delay = 0,
		sizeCurve = sedov(0.5), alphaCurve = { { 0, 0 }, { 0.8, 0.05 }, { 1, 1 } }, squash = { { 0, 1.1 }, { 0.25, 1 } },
		colorFrom = BLINK.white, colorTo = BLINK.ice, spinSpeed = 0, drift = 0, spread = 0.2, toward = 0.5 },
	{ -- the core: one picture that turns, a frame later
		name = "zcore", image = "rbxassetid://14622697144", cols = 1, rows = 1, frames = 1, life = 0.34, size = 2.2, delay = 1 / 30,
		sizeCurve = sedov(0.4), alphaCurve = { { 0, 0.05 }, { 0.5, 0.25 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } },
		colorFrom = BLINK.ice, colorTo = BLINK.cyan, spinSpeed = 60, spinDecay = true, drift = 3, fall = 6, spread = 0.15, toward = 0.4 },
	{ -- the fragments: the shard sheet, two frames after the pop; they are thrown along the throw and fall
		name = "zshards", image = "rbxassetid://10198439352", cols = 4, rows = 4, frames = 14, startFrame = 1, life = 0.55, size = 3.0, delay = 2 / 30,
		sizeCurve = sedov(0.5), alphaCurve = { { 0, 0.1 }, { 0.65, 0.2 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } },
		colorFrom = BLINK.cyan, colorTo = BLINK.violet, spinSpeed = 0, drift = 14, fall = 30, spread = 0.3, toward = 0.3 },
}

-- THE HIT PICTURES OF THE 25 CUTS: the same family as the throw (the same three sheets plus the big star of hit 3), smaller, each in its own cold colour,
-- so that cuts and throw look like one effect. Every cut starts each sheet at a DIFFERENT frame (jitter): a cut lives only 0.11 s before the next one
-- restarts the pictures, so a sheet always played from its first frame would show the same two or three frames 25 times. With the random start
-- the flurry shows the whole range of shapes: rings, flashes, fragments.
local Z_CUT_LAYERS = {
	{ -- the big star (kept from hit 3): one picture, short
		name = "czstar", image = "rbxassetid://12402888086", cols = 1, rows = 1, frames = 1, life = 0.16, size = 2.4, delay = 0,
		sizeCurve = sedov(0.3), alphaCurve = { { 0, 0 }, { 0.5, 0.1 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } },
		colorFrom = BLINK.white, colorTo = BLINK.ice, spinSpeed = 25, drift = 0, spread = 0.15, toward = 0.6 },
	{ -- the burst sheet from a random cell between the ring and the flash
		name = "czmain", image = "rbxassetid://10198434999", cols = 4, rows = 4, frames = 16, startFrame = 5, jitter = 4, life = 0.24, size = 1.7, delay = 0,
		sizeCurve = sedov(0.55), alphaCurve = { { 0, 0 }, { 0.8, 0.05 }, { 1, 1 } }, squash = { { 0, 1.1 }, { 0.25, 1 } },
		colorFrom = BLINK.ice, colorTo = BLINK.cyan, spinSpeed = 0, drift = 0, spread = 0.2, toward = 0.5 },
	{ -- the fragments, from a random cell, a little thrown and falling
		name = "czshards", image = "rbxassetid://10198439352", cols = 4, rows = 4, frames = 14, startFrame = 1, jitter = 5, life = 0.26, size = 1.9, delay = 2 / 30,
		sizeCurve = sedov(0.5), alphaCurve = { { 0, 0.1 }, { 0.65, 0.2 }, { 1, 1 } }, squash = { { 0, 1 }, { 1, 1 } },
		colorFrom = BLINK.cyan, colorTo = BLINK.violet, spinSpeed = 0, drift = 6, fall = 14, spread = 0.3, toward = 0.3 },
}

-- Doppler ramp for the speed lines of the dash: s = -1 (red-shifted: the lines left behind) .. 0 (pale) .. +1 (blue-shifted: toward the front). The colours
-- are the ones of the normal attack: the shift goes from the crimson of hit 3 (behind) through its pale rose to its white-hot white (ahead).
local function dopplerColor(s: number, _sat: number): Color3
	local m = math.clamp(math.abs(s), 0, 1)
	return if s < 0 then PAL.pale:Lerp(PAL.crim, m) else PAL.pale:Lerp(PAL.white, m)
end

local function aerial(color: Color3, worldPos: Vector3?): Color3
	local cam = workspace.CurrentCamera
	if not (cam and worldPos) then return color end
	local d = (worldPos - cam.CFrame.Position).Magnitude
	local k = math.min(1 - math.exp(-d / 350), 0.6)
	return color:Lerp(Lighting.FogColor, k)
end
-- BLACK-BODY COLOR (law 15): a hot thing glows white-yellow, then orange, then red, then dark as it cools. t = 1 (hottest) .. 0.
local function blackbody(t: number): Color3
	local keys: { { number } } = { { 0, 0.28, 0.08, 20 }, { 0.25, 0.45, 0.15, 22 }, { 0.55, 0.62, 0.20, 24 }, { 0.8, 0.82, 0.12, 22 }, { 1, 0.96, 0.03, 20 } } -- one hue family: hotter = lighter and less saturated, never yellow or orange
	t = math.clamp(t, 0, 1)
	for i = 2, #keys do
		if t <= keys[i][1] then
			local a, b = keys[i - 1], keys[i]
			local k = (t - a[1]) / (b[1] - a[1])
			return oklch(a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k, a[4] + (b[4] - a[4]) * k)
		end
	end
	return oklch(0.96, 0.03, 20)
end
local function floorBelow(pos: Vector3, ignore: Instance): RaycastResult?
	return workspace:Raycast(pos, Vector3.new(0, -14, 0), Vfx.exRay({ ignore }))
end
local bladeVelNow = Vector3.zero -- velocity vector of the blade tip
local bladeSpeedNow = 0 -- studs/s of the blade tip, written by the blade loop, read by the slash (law 26)
-- restitution by floor material (law 23): how much of its vertical speed a bit keeps when it hits that floor
local REST_BY_MATERIAL = {
	[Enum.Material.Metal] = 0.5, [Enum.Material.DiamondPlate] = 0.5, [Enum.Material.CorrodedMetal] = 0.45,
	[Enum.Material.Ice] = 0.45, [Enum.Material.Glass] = 0.4, [Enum.Material.Plastic] = 0.38, [Enum.Material.SmoothPlastic] = 0.38,
	[Enum.Material.Wood] = 0.3, [Enum.Material.WoodPlanks] = 0.3, [Enum.Material.Brick] = 0.28, [Enum.Material.Concrete] = 0.25,
	[Enum.Material.Slate] = 0.3, [Enum.Material.Granite] = 0.3, [Enum.Material.Marble] = 0.33, [Enum.Material.Pavement] = 0.25,
	[Enum.Material.Cobblestone] = 0.27, [Enum.Material.Grass] = 0.1, [Enum.Material.LeafyGrass] = 0.1, [Enum.Material.Ground] = 0.1,
	[Enum.Material.Mud] = 0.04, [Enum.Material.Sand] = 0.05, [Enum.Material.Snow] = 0.04, [Enum.Material.Salt] = 0.08,
}
-- SPRING DAMPER (law 30): x'' = -w^2 (x - target) - 2 z w x'. f = frequency in Hz, z = damping ratio (1 = no overshoot, <1 = swings and settles).
-- Small sub-steps keep it stable at any frame rate.
local function newSpring(f: number, z: number, x0: number?): Spring
	return { x = x0 or 0, v = 0, w = 2 * math.pi * f, z = z }
end
local function stepSpring(sp: Spring, target: number, dt: number): number
	local n = math.clamp(math.ceil(dt * sp.w * 2), 1, 8)
	local h = dt / n
	for _ = 1, n do
		sp.v += (-sp.w * sp.w * (sp.x - target) - 2 * sp.z * sp.w * sp.v) * h
		sp.x += sp.v * h
	end
	return sp.x
end
-- INVERSE-SQUARE SOUND (law 28): loudness falls with the square of the distance to the listener (the camera), a wall in the way
-- absorbs part of it and cuts the highs, and air itself takes the highs away over long distances. Returns gain 0..1, dull 0..1.
local SND_REF = 12 -- studs: closer than this = full volume
local function soundAtten(worldPos: Vector3?): (number, number, number)
	local cam = workspace.CurrentCamera
	if not (cam and worldPos) then return 1, 0, 0 end
	local from = cam.CFrame.Position
	local d = (worldPos - from).Magnitude
	local gain = math.clamp((SND_REF / math.max(d, SND_REF)) ^ 2, 0.2, 1)
	local dull = math.clamp((d - 40) / 160, 0, 0.5) -- air absorption of the highs
	local delay = d > 30 and math.min(d / 1200, 0.12) or 0 -- law 27: sound travels about 1200 studs/s, so far hits are heard a moment later
	local rp = Vfx.exRay({ player.Character })
	local hit = workspace:Raycast(from, worldPos - from, rp)
	if hit and hit.Instance and hit.Instance.CanCollide and hit.Instance.Transparency < 0.8 and not hit.Instance:FindFirstAncestorOfClass("Model") then
		-- law 13 (diffraction): sound bends round corners. If a ray to a point 6 studs above or beside the target gets through,
		-- the sound leaks round the edge: louder and less dull than a thick wall
		local leak = false
		local side = (worldPos - from):Cross(Vector3.yAxis)
		side = side.Magnitude > 1e-3 and side.Unit * 6 or Vector3.zero
		for _, off in { Vector3.new(0, 6, 0), side, -side } do
			local h2 = workspace:Raycast(from, worldPos + off - from, rp)
			if not (h2 and h2.Instance and h2.Instance.CanCollide and h2.Instance.Transparency < 0.8 and not h2.Instance:FindFirstAncestorOfClass("Model")) then
				leak = true
				break
			end
		end
		gain *= leak and 0.8 or 0.6 -- a wall absorbs
		dull = math.max(dull, leak and 0.45 or 0.7)
	end
	return gain, dull, delay
end

type SlashLayer = { part: Part, decals: { Decal }, ang: number? }
local slashRig: { layers: { SlashLayer }?, conn: RBXScriptConnection?, job: { t: number }?, light: PointLight? } = { layers = nil, conn = nil, job = nil, light = nil }

-- RED LIGHT: a crimson PointLight on your body; its Brightness follows the same 3-section curve every frame (set in slashDisc).
local function slashLight(root: BasePart): PointLight
	local l = slashRig.light
	if not (l and l.Parent == root) then
		if l then l:Destroy() end
		l = Instance.new("PointLight")
		l.Name = "DarkSlashLight"
		l.Color = oklch(0.62, 0.2, 22)
		l.Range = 14
		l.Shadows = false
		l.Brightness = 0
		l.Parent = root
		slashRig.light = l
	end
	return l
end

local function makeSlashLayer(color: Color3): SlashLayer
	local p = Instance.new("Part")
	p.Name = "DarkSlash"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 0.05)
	local decals: { Decal } = {}
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do -- both sides, so it is visible from every direction
		local d = Instance.new("Decal")
		d.Name = "Image"
		d.Face = face
		d.Texture = SLASH_IMAGE
		d.Color3 = color
		d.Transparency = 1
		d.Parent = p
		table.insert(decals, d)
	end
	p.Parent = workspace
	return { part = p, decals = decals }
end

local function getSlashLayers(): { SlashLayer }
	local list = slashRig.layers
	if list then
		local ok = true
		for _, l in list do
			if not l.part.Parent then ok = false break end
		end
		if ok then return list end
		for _, l in list do l.part:Destroy() end
	end
	list = {}
	for i = 1, #SLASH_LAYERS do
		list[i] = makeSlashLayer(Color3.new(1, 1, 1))
	end
	slashRig.layers = list
	return list
end

local function hideSlash()
	if slashRig.conn then slashRig.conn:Disconnect() slashRig.conn = nil end
	slashRig.job = nil
	if slashRig.light then slashRig.light.Brightness = 0 end
	if slashRig.layers then
		for _, l in slashRig.layers do
			for _, d in l.decals do d.Transparency = 1 end
		end
	end
end

local function slashDisc(character: Model, index: number, tint: Tint?)
	local r = character:FindFirstChild("HumanoidRootPart")
	local cfg = FX_EMIT[index]
	if not r or not cfg then return end
	local layers = getSlashLayers()
	local light = slashLight(r)
	light.Color = if tint then tint.map(oklch(0.62, 0.2, 22)) else oklch(0.62, 0.2, 22) -- (the light on your body: cold for the Z skill)
	for _, l in layers do l.ang = 0 end
	if slashRig.conn then slashRig.conn:Disconnect() slashRig.conn = nil end

	local hum = character:FindFirstChildOfClass("Humanoid")
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	local hipH = (hum and hum.HipHeight or 2) + r.Size.Y / 2
	local tilt = math.rad(cfg.tilt)
	local half = cfg.size1 / 2
	local roll0 = math.rad(cfg.roll)
	local spin = math.rad(cfg.spin)
	-- a small random roll / size per swing so no two slashes look identical
	local jitterRoll = math.rad((math.random() * 2 - 1) * 7)
	local jitterSize = 0.95 + math.random() * 0.1
	-- law 26 (energy): the energy of the swing grows with the square of its speed, the size of the slash with the square root of that energy = with the speed.
	local energyK = math.clamp(bladeSpeedNow / 50, 0.85, 1.2)
	jitterSize *= energyK

	local job = { t = 0 }
	slashRig.job = job
	local total = cfg.life + SLASH_LAYERS[#SLASH_LAYERS].delay

	slashRig.conn = RunService.PreRender:Connect(function(dt)
		if slashRig.job ~= job or not r.Parent then
			if slashRig.job == job then hideSlash() end
			return
		end
		job.t += math.min(dt, 1 / 20)
		if job.t >= total then
			hideSlash()
			return
		end
		-- placement from the CURRENT body: the yaw of the root, the horizontal spot of the torso (it leans forward in the swing)
		local look = r.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
		local rightV = Vector3.new(-flat.Z, 0, flat.X) -- your right side (forward (0,0,-1) gives (1,0,0))
		local basePos = r.Position
		if torso and torso:IsA("BasePart") then
			basePos = Vector3.new(torso.Position.X, r.Position.Y, torso.Position.Z)
		end
		local groundY = r.Position.Y - hipH
		local y = (cfg.oy or 0) + math.max(r.Position.Y + 0.3, groundY + FX_WALL_PEEK + half * math.abs(math.sin(tilt)) * 0.5 + math.max(0, -cfg.dy))
		local frameBase = CFrame.lookAt(Vector3.zero, flat) * CFrame.Angles(0, 0, tilt) * CFrame.Angles(math.rad(90), 0, 0)

		local lightV = 0
		for i, def in SLASH_LAYERS do
			local l = layers[i]
			local lt = job.t - def.delay
			if lt < 0 then
				for _, d in l.decals do d.Transparency = 1 end
			else
				local a = math.min(lt / (cfg.life * (def.life or 1)), 1)
				local grow = 1 - (1 - a) ^ (1.6 + (def.pow or 4) * 0.2) -- spreads outward during the WHOLE life, quick at first and still moving at the end (each layer a little different)
				local size = (cfg.size0 + (cfg.size1 - cfg.size0) * grow) * def.scale * jitterSize
				-- the spot drifts forward by cfg.travel, ease-out, and is measured from the body every frame
				local pos = Vector3.new(basePos.X, y + def.lift, basePos.Z)
					+ flat * (cfg.fwd + cfg.travel * grow) + rightV * (cfg.side or 0) + Vector3.new(0, cfg.dy * grow, 0)
				-- the 3-section curve value h (0 at the ends, 1 at the apex K) drives spin speed, transparency, color and light
				local h, _, u = curve3(a)
				-- RotSpeed: angular speed follows the curve (slow start, fastest at K, slow end); the angle is its running sum
				l.ang = (l.ang or 0) + spin / cfg.life * 1.7 * h * math.min(dt, 1 / 20)
				local roll = roll0 + jitterRoll + math.rad(def.roll) + l.ang
				l.part.Size = Vector3.new(size, size, 0.05)
				l.part.CFrame = CFrame.new(pos) * frameBase * CFrame.Angles(0, 0, roll)
				-- transparency: starts faint (SLASH_TR_START, never 0), falls to this layer's peak at K, then returns to 1 at the end
				local edge = a <= CURVE_APEX and SLASH_TR_START or 1
				local hh = a <= CURVE_APEX and h or h ^ 1.6 -- after the apex the fade has a long soft tail (no sudden vanish)
				local tr = edge + (def.peak - edge) * hh
				local col = slashColor(u, def.dL, def.dH, def.cm) -- Oklch, different L/C/H per section
				if index == 3 then -- the finisher cut: a whiter, more solid slash (the tilt is still 3 degrees)
					col = col:Lerp(PAL.white, 0.4)
					tr = tr * 0.85
				end
				for _, d in l.decals do
					d.Transparency = tr
					d.Color3 = if tint then tint.map(col) else col
				end
				lightV = math.max(lightV, hh * (1 - (tr - def.peak)))
			end
		end
		-- light: same curve, so the glow on the ground and your clothes peaks together with the slash
		light.Brightness = SLASH_LIGHT_PEAK * energyK * math.clamp(lightV, 0, 1)
	end)
end

-- HIT EFFECTS on the enemy (kept small on purpose): the hit picture (popStar), a body flash, a blink, a light and a few real-part bits.
-- flare = size of the hit picture (studs, 0 = none), flash = seconds of the body flash, amount = how bright the flash starts (0..1)
local HIT_FX: { [string]: { flare: number, flash: number, amount: number } } = {
	rise = { flare = 5.5, flash = 0.2, amount = 0.65 }, -- hit 2
	chop = { flare = 6.5, flash = 0.2, amount = 0.75 }, -- hit 1: the main burst is the biggest of the basic combo
	grab = { flare = 3, flash = 0.14, amount = 0.4 },
	blast = { flare = 8, flash = 0.28, amount = 0.75 },
	fling = { flare = 9, flash = 0.3, amount = 0.8 }, -- hit 3, the slash that throws the enemy
	slam = { flare = 9.5, flash = 0.3, amount = 0.6 }, -- hit 3 slam: the biggest star and flash
	blink = { flare = 5, flash = 0.16, amount = 0.7 }, -- the Z skill: many small cuts in a row, so each one is smaller than a hit 1
}
-- LIGHT on the enemy at the moment of the hit (a crimson PointLight on the body, fades out): brightness peak and seconds, per kind
local HIT_LIGHT = {
	rise = { 4.6, 0.3 }, chop = { 5.5, 0.32 }, grab = { 2.5, 0.25 }, blast = { 7, 0.5 }, slam = { 4.5, 0.9 }, fling = { 7.5, 0.5 }, blink = { 4.2, 0.26 },
}
local HIT_LIGHT_COLOR = PAL.crim
-- WEBER-FECHNER: the eye judges brightness by ratio, so each hit of the combo is a multiple of the one before it (chop 1, rise 1.25, cut 1.6, slam 2.0)
local HIT_STEP = { chop = 1, rise = 1.25, fling = 1.6, slam = 2.0, blast = 2.0, grab = 0.8, blink = 1.1 }

-- flash ----------------------------------------------------------------
local function flash(model: Model, cfg: { flash: number, amount: number }, I: number?, soft: boolean?, tint: Tint?)
	-- soft = true (the hit 3 slam): a calmer flash. The impact frame is 1 frame and not fully white, the body glow is weaker and pinker,
	-- so the body and the move can still be read while the hit stop holds the picture.
	local power: number = I or 0.6
	local h = model:FindFirstChild("DarkHitFlash") :: Highlight?
	if not h then
		h = Instance.new("Highlight")
		h.Name = "DarkHitFlash"
		h.FillColor = PAL.pale -- bright red-white body flash
		h.OutlineColor = PAL.crim -- crimson glowing rim
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.FillTransparency = 1
		h.OutlineTransparency = 1
		h.Parent = model
	end
	local hl = h :: Highlight
	local token = ((hl:GetAttribute("t") :: number?) or 0) + 1
	hl:SetAttribute("t", token)
	-- a bright body flash with a glowing rim, a tiny dip, a second weaker blink, then fade out
	local amount = math.clamp(math.max(cfg.amount, 0.7) * (0.8 + 0.4 * power), 0.6, 0.95) -- a strong, clearly visible highlight; stronger hit = brighter
	if soft then amount *= 0.8 end
	hl.FillColor = if soft then PAL.pale else PAL.white -- white-hot first...
	hl.OutlineColor = if soft then PAL.rose else PAL.white
	hl.FillTransparency = if soft then 0.4 else 0 -- IMPACT FRAME: the whole body is pure white for the first 2 frames (1 frame and not fully white for the slam)
	hl.OutlineTransparency = 0
	if tint then hl.FillColor, hl.OutlineColor = tint.map(hl.FillColor), tint.map(hl.OutlineColor) end -- the Z skill: the same flash in cold colours
	local dip = TweenService:Create(hl, TweenInfo.new((if soft then 1 else 2) / 30, Enum.EasingStyle.Linear), { FillTransparency = 1 - amount * 0.35 })
	dip:Play()
	dip.Completed:Once(function()
		if not hl.Parent or hl:GetAttribute("t") ~= token then return end
		hl.FillTransparency = 1 - amount * 0.7 -- second blink
		local tw = TweenService:Create(hl, TweenInfo.new(cfg.flash * 0.7 + 0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			FillTransparency = 1, OutlineTransparency = 1,
			FillColor = if tint then tint.map(PAL.hot) else PAL.hot, OutlineColor = if tint then tint.map(PAL.crim) else PAL.crim, -- ...then it cools to crimson (violet, for the Z skill) while it fades
		})
		tw:Play()
		tw.Completed:Once(function()
			if hl.Parent and hl:GetAttribute("t") == token then hl:Destroy() end -- keep the world free of leftovers
		end)
	end)
end
-- 2b) blink: the enemy's body flickers (fades out and back) a few times after the hit, locally only (LocalTransparencyModifier).
-- A new hit restarts it; the transparency always ends at 0.
local function blinkBody(model: Model, I: number, kind: string)
	local token = (model:GetAttribute("DarkBlink") or 0) + 1
	model:SetAttribute("DarkBlink", token)
	local parts = {}
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then table.insert(parts, p) end
	end
	local function set(v)
		for _, p in parts do
			if p.Parent then p.LocalTransparencyModifier = v end
		end
	end
	task.spawn(function()
		task.wait(2 / 30) -- the white impact frame comes first
		local blinks = (kind == "slam" and 4 or 3) + (I > 0.7 and 1 or 0)
		for _ = 1, blinks do
			if model:GetAttribute("DarkBlink") ~= token then return end
			set(0.65) -- half gone
			task.wait(2 / 30)
			if model:GetAttribute("DarkBlink") ~= token then return end
			set(0)
			task.wait(2 / 30)
		end
		if model:GetAttribute("DarkBlink") == token then set(0) end
	end)
end
blinkBody = guard(blinkBody)

-- hit 1, 2: the slash disc. hit 3: the same slash for a blink, then the dash trail while you fly.
Vfx.strike = function(character: Model, index: number, tint: Tint?)
	if Vfx.bladeSwing then Vfx.bladeSwing(index) end
	slashDisc(character, index, tint)
end

-- A thin outline around YOU for a moment (Highlight, no fill), on every hit and on the blast
local RIM_TIME = 0.7 -- seconds the outline on you lasts per hit
local RIM_TIME_FINAL = 1.2 -- ...and after the blast
local rimByChar = setmetatable({}, { __mode = "k" })
local function selfRim(character: Model, strong: boolean, tint: Tint?)
	local h = rimByChar[character]
	if not h or h.Parent ~= character then
		h = Instance.new("Highlight")
		h.Name = "DarkSelfRim"
		h.FillTransparency = 1 -- outline only
		h.OutlineColor = PAL.pale
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.OutlineTransparency = 1
		h.Parent = character
		rimByChar[character] = h
	end
	h.OutlineColor = if tint then tint.map(PAL.pale) else PAL.pale
	local token = (h:GetAttribute("t") or 0) + 1
	h:SetAttribute("t", token)
	h.OutlineTransparency = strong and 0 or 0.15
	local tw = TweenService:Create(h, TweenInfo.new(strong and RIM_TIME_FINAL or RIM_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { OutlineTransparency = 1 })
	tw:Play()
	tw.Completed:Once(function()
		if h.Parent and h:GetAttribute("t") == token then
			h:Destroy() -- leave nothing behind
			if rimByChar[character] == h then rimByChar[character] = nil end
		end
	end)
end

Vfx.hit = function(character: Model, _strength: number?, tint: Tint?)
	selfRim(character, false, tint)
end

local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- Hit effects live ON the enemy's torso (an Attachment), so they ride along while the enemy is
-- knocked back or dragged: the glitter and the flare are LockedToPart, nothing is left behind in the air.
local function torsoOf(model: Model): BasePart?
	return model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso") or model:FindFirstChild("HumanoidRootPart")
end

local fxByModel = setmetatable({}, { __mode = "k" })
local fxByModelZ = setmetatable({}, { __mode = "k" }) -- the same for the pictures of the throw of the Z skill (tint.set = "z")
local fxByModelZC = setmetatable({}, { __mode = "k" }) -- ...and for the pictures of its cuts (tint.set = "zc")

local function getHitFx(model: Model, tint: Tint?): any
	local torso = torsoOf(model)
	if not torso then return nil end
	local setName = if tint ~= nil and tint.set ~= nil then tint.set else "base" -- "z" = the throw, "zc" = the cuts, "base" = the normal hits
	local cache = if setName == "z" then fxByModelZ elseif setName == "zc" then fxByModelZC else fxByModel
	local defs = if setName == "z" then Z_HIT_LAYERS elseif setName == "zc" then Z_CUT_LAYERS else FX_HIT_LAYERS
	local fx = cache[model]
	if fx and fx.att.Parent == torso then return fx end
	if fx then
		fx.att:Destroy()
		for _, L in fx.layers or {} do L.bb:Destroy() end
	end
	local att = Instance.new("Attachment")
	att.Name = if setName == "base" then "DarkHitFX" else "DarkHitFX" .. string.upper(setName)
	att.Parent = torso
	fx = { att = att, token = 0 }
	local light = Instance.new("PointLight")
	light.Name = "DarkHitLight"
	light.Color = HIT_LIGHT_COLOR
	light.Range = 14
	light.Shadows = false
	light.Brightness = 0
	light.Parent = att
	fx.light = light
	-- the hit picture layers: one BillboardGui per layer per enemy (reused). A clipping frame shows ONE cell of the sheet; popStar moves the picture.
	fx.layers = {}
	for i, def in defs do
		local bb = Instance.new("BillboardGui")
		bb.Name = "DarkHit_" .. def.name
		bb.Size = UDim2.fromScale(1, 1) -- scale = studs for a BillboardGui
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.ResetOnSpawn = false
		bb.MaxDistance = 5000 -- never hidden by distance
		bb.Adornee = torso
		bb.Enabled = false
		local clip = Instance.new("Frame")
		clip.BackgroundTransparency = 1
		clip.BorderSizePixel = 0
		clip.ClipsDescendants = def.cols * def.rows > 1 -- a single picture is not cropped, so it can be turned freely
		clip.Size = UDim2.fromScale(1, 1)
		clip.Parent = bb
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(def.cols, def.rows) -- the sheet is cols x rows times bigger than the frame
		img.Image = def.image
		img.ImageColor3 = def.colorFrom
		img.ScaleType = Enum.ScaleType.Stretch
		img.ImageTransparency = 1
		img.Parent = clip
		bb.Parent = torso
		fx.layers[i] = { def = def, bb = bb, img = img, token = 0 }
	end
	cache[model] = fx
	return fx
end

-- Plays all four layers. A new hit on the same enemy restarts every layer (old tweens and loops stop first), so each layer is only ever one picture.
local function playLayer(L: any, big: number, dir: Vector3, I: number, tint: Tint?)
	local def = L.def
	L.token += 1
	local token = L.token
	local frames = math.max(def.frames, 1)
	local single = def.cols * def.rows == 1
	local function showFrame(i) -- frame i (0-based), read row by row from the top left
		if single then return end -- a single picture stays where it is
		L.img.Position = UDim2.fromScale(-(i % def.cols), -math.floor(i / def.cols))
	end
	task.delay(def.delay, function()
		if L.token ~= token or not L.bb.Parent then return end
		-- a little different every hit: where it sits, how big, how long it lives, how far its color travels, how it is turned
		local right = Vector3.yAxis:Cross(dir)
		right = right.Magnitude > 0.01 and right.Unit or Vector3.xAxis
		local jx, jy = (math.random() - 0.5) * 2, (math.random() - 0.5) * 2
		-- (the pictures of the Z skill sit in the CENTRE of the body, wherever the attack comes from: the normal pictures are pushed toward the attacker
		-- by def.toward and scattered by def.spread, which put them beside the body when the dash came from the side)
		local centered = tint ~= nil and tint.set ~= nil
		local toward = if centered then 0 else def.toward
		local spread = if centered then def.spread * 0.3 else def.spread
		local baseOffset = -dir * toward + right * jx * spread + Vector3.yAxis * jy * spread
		local first = (def.startFrame or 0) + (if def.jitter then math.random(0, def.jitter) else 0) -- a different first frame for every cut
		local colorMix = 0.6 + 0.4 * math.random()
		local life = def.life * (0.9 + 0.2 * math.random())
		local adorn = L.bb.Adornee
		local camK = if adorn and adorn:IsA("BasePart") then distScale(adorn.Position) else 1 -- bigger when far away
		local size0 = big * def.size * (0.85 + 0.3 * math.random()) * (0.85 + 0.3 * I) * camK
		local rot0 = (math.random() * 2 - 1) * 35
		if single then
			L.img.AnchorPoint = Vector2.new(0.5, 0.5)
			L.img.Position = UDim2.fromScale(0.5, 0.5)
		end
		showFrame(first)
		L.bb.Enabled = true
		local t0 = os.clock()
		while L.token == token and L.bb.Parent do
			local t = os.clock() - t0
			local tn = math.min(t / life, 1)
			-- (the leading empty cells of a sheet are skipped: see startFrame)
			showFrame(math.min(first + math.floor(tn * (frames - first)), frames - 1))
			local size = size0 * curve(def.sizeCurve, tn)
			local sq = curve(def.squash, tn)
			L.bb.Size = UDim2.fromScale(size * sq, size / sq)
			L.img.ImageTransparency = curve(def.alphaCurve, tn)
			local col = def.colorFrom:Lerp(def.colorTo, tn * colorMix)
			if tint then
					if tint.set == nil then col = tint.map(col) end -- (the sets of the Z skill have their own cold colours, see Z_HIT_LAYERS)
					if adorn and adorn:IsA("BasePart") then col = farBoost(col, adorn.Position) end -- (seen from far: more chroma, see farBoost)
				end
			L.img.ImageColor3 = col
			if single and def.spinSpeed > 0 then
					-- a free body that spins slows down (air drag on the spin): the angle grows fast at first and then more and more slowly
					L.img.Rotation = rot0 + (if def.spinDecay then def.spinSpeed * life * 0.5 * (1 - (1 - tn) ^ 2) else def.spinSpeed * t)
				end
			L.bb.StudsOffsetWorldSpace = baseOffset + dir * def.drift * (1 - (1 - tn) ^ 2) - Vector3.new(0, (def.fall or 0) * t * t, 0) -- (the drift slows down; the fall is g t^2 / 2)
			if tn >= 1 then break end
			RunService.RenderStepped:Wait()
		end
		if L.token == token and L.bb.Parent then
			L.img.ImageTransparency = 1
			L.bb.Enabled = false
		end
	end)
end

local function popStar(model: Model, torso: BasePart, big: number, dir: Vector3, I: number, tint: Tint?)
	local fx = getHitFx(model, tint)
	if not fx or not fx.layers then return end
	for _, L in fx.layers do playLayer(L, big, dir, I, tint) end
end

-- REAL PART DEBRIS: small bits in the enemy's own colors and materials fly off the body, fall and shrink (moved by hand, anchored, so they
-- never push anybody). More and faster for a stronger hit.
local DEBRIS = { gravity = 55, drag = 1.6, life = 0.6, max = 60 } -- gone with the other layers, about 0.55 s after the hit
local debrisList, debrisConn = {}, nil
local debrisFrame = 0
local DEBRIS_RAY = RaycastParams.new() -- shared by every bit: walls and props only, never the characters
DEBRIS_RAY.FilterType = Enum.RaycastFilterType.Exclude
DEBRIS_RAY.RespectCanCollide = true
local function debrisStep(dt: number)
	debrisFrame += 1
	dt = math.min(dt, 1 / 20) * (Vfx.timeScale or 1) -- law: time dilation, the bits freeze together with the world during a hit stop
	for i = #debrisList, 1, -1 do
		local d = debrisList[i]
		d.t += dt
		if d.t >= DEBRIS.life or not d.part.Parent then
			d.part:Destroy()
			debrisList[i] = debrisList[#debrisList]
			debrisList[#debrisList] = nil
		else
			-- DEBRIS PHYSICS v2 (semi-implicit Euler, per bit):
			-- mass ~ volume; drag = linear (Stokes) + quadratic (v^2) divided by mass, so small bits stop in the air much sooner;
			-- turbulence only on light bits; angular drag; at the floor: restitution with a rest threshold (no endless micro bounces),
			-- Coulomb sliding friction (mu*g, stops the slide), and rolling (spin follows the slide speed / radius).
			local vol = d.size.X * d.size.Y * d.size.Z
			local mass = math.max(vol * 40, 0.02)
			local light = 1 / (0.6 + d.size.Magnitude * 2.2)
			local sp = d.vel.Magnitude
			if not d.rest then
				d.vel += Vector3.new(0, -DEBRIS.gravity * dt, 0)
				-- law 23, terminal velocity: falling speed stops growing where drag equals weight. Small / light bits have a low limit.
				local vt = 14 + 90 * d.size.Magnitude
				if d.vel.Y < -vt then d.vel = Vector3.new(d.vel.X, -vt, d.vel.Z) end
				d.vel -= d.vel * ((0.25 + 0.03 * sp) / mass * dt) * 0.12
				if light > 0.9 then
					d.vel += Vector3.new(math.noise(d.t * 7, i), 0, math.noise(i, d.t * 7)) * 9 * dt
				end
			end
			-- law 21 (Magnus effect): a spinning bit moving through air feels a sideways force F ~ spin x velocity, so its path bends
			if not d.rest then
				d.vel += d.spin:Cross(d.vel) * 0.03 * dt
			end
			local a = d.t / DEBRIS.life
			local shrink = math.max(a > 0.55 and (1 - (a - 0.55) / 0.45) or 1, 0.05)
			local sqv = Vector3.one
			if d.sq then
				local q = stepSpring(d.sq, 0, dt)
				sqv = Vector3.new(1 + q * 0.5, math.max(1 - q, 0.3), 1 + q * 0.5) -- volume stays about the same: wider when flatter
			end
			d.part.Size = d.size * shrink * sqv
			local pos = d.part.Position + d.vel * dt
			-- law 157 (collision scatter): a fast bit that meets a wall bounces off it (reflect the velocity, keep 40 %).
			-- One ray every other frame per bit, only while it is still fast and young (cheap).
			if not d.rest and d.t < 0.4 and (i + debrisFrame) % 2 == 0 and d.vel.Magnitude > 6 then
				local wh = workspace:Raycast(d.part.Position, d.vel * (dt * 2 + 0.03), DEBRIS_RAY)
				local wm = wh and wh.Instance:FindFirstAncestorWhichIsA("Model")
				if wh and not (wm and wm:FindFirstChildOfClass("Humanoid")) then -- walls and props only, not bodies
					d.vel = (d.vel - 2 * d.vel:Dot(wh.Normal) * wh.Normal) * 0.4
					pos = wh.Position + wh.Normal * 0.08
				end
			end
			d.spin *= 1 - math.min(1.2 * dt, 0.5) -- angular drag
			if d.floorY and pos.Y <= d.floorY + d.size.Y / 2 and d.vel.Y <= 0 then
				pos = Vector3.new(pos.X, d.floorY + d.size.Y / 2, pos.Z)
				local rest = REST_BY_MATERIAL[d.mat] or math.clamp(0.18 + light * 0.2, 0.2, 0.45) -- restitution by material (law 23)
				rest *= math.clamp(1.15 - d.size.Magnitude * 0.6, 0.6, 1.1) -- bigger bits bounce less
				rest /= 1 + math.abs(d.vel.Y) * 0.02 -- law 25, inelastic collision: the harder the hit, the more energy is lost as heat and deformation
				d.sq = newSpring(14, 0.4, 0.45) -- elastic squash on impact (law 25): flattens, then springs back
				local vy = -d.vel.Y * rest
				if vy < 1.6 then -- too weak to bounce: it lies on the floor and only slides
					vy = 0
					d.rest = true
				end
				local hv = Vector3.new(d.vel.X, 0, d.vel.Z)
				local hs = hv.Magnitude
				if hs > 0 then
					hs = math.max(hs - 0.55 * DEBRIS.gravity * 0.3 * dt, 0) -- Coulomb friction: a fixed deceleration while sliding
					hv = hv.Unit * hs
				end
				d.vel = Vector3.new(hv.X, vy, hv.Z)
				-- law 26, friction heat: sliding work (friction * speed * time) heats the bit; hot bits glow orange and cool down again
				d.heat = (d.heat or 0) + hs * dt * 0.12
				if d.rest then
					-- rolling: the bit turns around the axis across its slide (spin = speed / radius)
					local rad = math.max(d.size.Magnitude * 0.25, 0.05)
					local axis = Vector3.yAxis:Cross(hv.Magnitude > 0.01 and hv.Unit or Vector3.zAxis)
					d.spin = axis * (hs / rad)
				else
					d.spin *= 0.4
				end
			end
			if d.heat then
				d.heat *= math.exp(-3 * dt)
				local hk = math.clamp(d.heat, 0, 1)
				if hk > 0.05 then
					d.baseColor = d.baseColor or d.part.Color
					d.part.Material = Enum.Material.Neon
					local glow = blackbody(hk)
						if d.tint then glow = d.tint.map(glow) end -- (the Z finish: the glow of a hot bit is cold too, no orange next to the blue)
						d.part.Color = d.baseColor:Lerp(glow, math.min(hk * 2, 1))
				elseif d.baseColor then
					d.part.Color = d.baseColor
				end
			end
			d.part.CFrame = CFrame.new(pos) * (d.part.CFrame.Rotation * CFrame.Angles(d.spin.X * dt, d.spin.Y * dt, d.spin.Z * dt))
		end
	end
	if #debrisList == 0 and debrisConn then
		debrisConn:Disconnect()
		debrisConn = nil
	end
end

-- SKID DIRT (hit 1): while the enemy slides, small bits of the floor under its feet are kicked up and back toward you, one every 3 frames, a few only.
-- The bits take the color and material of the floor they scrape.
-- SPEED LINES v3: MANY copies, like real game speed lines. 12 streaks (6 on phones) are scattered around the flight path of the enemy:
-- different distances around the body, lengths, thicknesses and start times. Each streak = a bright core + a wide dim veil, it shoots out
-- fast, then draws back in, and stays behind in the world while the enemy keeps going. up = true: upright streaks (hit 2 launches the enemy).
local function speedLines(model: Model, dir: Vector3, I: number, up: boolean?, size: number?, fewer: number?, down: boolean?, tint: Tint?)
	if linesAlive >= LINES_MAX then return end
	local r = model:FindFirstChild("HumanoidRootPart")
	local cam = workspace.CurrentCamera
	if not r or not cam then return end
	local flat = Vector3.new(dir.X, 0, dir.Z)
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.zAxis
	if down then up = true end
	local axis = down and -Vector3.yAxis or (up and Vector3.yAxis or flat)
	-- two directions that are both perpendicular to the flight axis: the streaks are scattered in this plane
	local perpA = up and Vector3.xAxis or Vector3.yAxis
	local perpB = axis:Cross(perpA)
	local count = fewer or (IS_MOBILE and 6 or 12) -- hits 1 and 2 pass a small number; the hit 3 throw uses the full set
	count = math.max(2, math.floor(count * Vfx.lodK(r.Position) + 0.5)) -- law 160: fewer streaks when far from the camera
	if IS_MOBILE and fewer then count = math.max(2, math.floor(fewer / 2)) end
	local function layer(part, color, alpha)
		local d = Instance.new("Decal")
		d.Texture = SPEED_IMAGE
		d.Face = Enum.NormalId.Back -- the part's +Z side faces the camera (turned every frame)
		d.Color3 = color
		d.Transparency = alpha
		d.Parent = part
		return d
	end
	local lines = {}
	for i = 1, count do
		local len = (4 + 5 * I + math.random() * 5) * (size or 1)
		local function mkPart()
			local p = Instance.new("Part")
			p.Name = "DarkSpeed"
			p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
			p.Transparency = 1
			p.Size = Vector3.new(len, len * 0.3, 0.05)
			p.Parent = workspace
			return p
		end
		local core, veil = mkPart(), mkPart()
		local ang = math.random() * math.pi * 2
		local rad = 0.4 + math.random() * 2.0
		lines[i] = {
			core = core, veil = veil,
			coreDecal = layer(core, Color3.fromRGB(255, 255, 255), 0.15),
			veilDecal = layer(veil, if tint then tint.map(Color3.fromRGB(255, 170, 185)) else Color3.fromRGB(255, 170, 185), 0.5),
			len = len, life = 0.3 + math.random() * 0.22, delay = (i / count) * 0.16 + math.random() * 0.04,
			thick = (up and 0.6 or 0.3) + math.random() * (up and 0.3 or 0.25), -- how fat the streak is compared with its length (upright pillars are fatter)
			off = perpA * math.cos(ang) * rad + perpB * math.sin(ang) * rad * 0.8 + (up and Vector3.zero or Vector3.new(0, 0.3, 0)),
			back = math.random() * 2.5, -- how far behind the enemy it starts
			anchor = nil,
		}
	end
	linesAlive = linesAlive + 1
	local t0 = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		local now = os.clock() - t0
		local alive = false
		for _, l in lines do
			local a = (now - l.delay) / l.life
			if a >= 1 or not r.Parent then
				l.core.Transparency, l.veil.Transparency = 1, 1
				l.coreDecal.Transparency, l.veilDecal.Transparency = 1, 1
			elseif a >= 0 then
				alive = true
				-- length: shoots out fast (first third), then draws back in toward nothing
				local grow = a < 0.3 and (0.4 + 2.0 * (a / 0.3)) or (2.4 - 2.1 * ((a - 0.3) / 0.7) ^ 0.8)
				local len = l.len * 0.5 * grow
				local th = len * l.thick * (1 - 0.35 * a)
				local follow = r.Position + l.off - axis * (len * 0.5 + 0.5 + l.back)
				if not l.anchor then l.anchor = follow end
				local center = follow:Lerp(l.anchor, math.min(a * 1.3, 0.8)) -- the enemy goes on, the streak stays behind
				local toCam = cam.CFrame.Position - center
				local z = toCam - axis * toCam:Dot(axis)
				z = z.Magnitude > 0.01 and z.Unit or Vector3.zAxis
				local cf = CFrame.fromMatrix(center, axis, z:Cross(axis), z)
				l.core.CFrame = cf
				l.core.Size = Vector3.new(len, th * (up and 0.95 or 0.6), 0.05) -- the bright core
				l.veil.CFrame = cf
				l.veil.Size = Vector3.new(len * 1.3, th * (up and 2.6 or 1.6), 0.05) -- the wide dim veil
				l.coreDecal.Transparency = 0.15 + 0.85 * a * a * a
				l.veilDecal.Transparency = 0.5 + 0.5 * math.min(a * 1.2, 1)
			else
				alive = true
			end
		end
		if not alive then
			conn:Disconnect()
			linesAlive = linesAlive - 1
			for _, l in lines do l.core:Destroy() l.veil:Destroy() end
		end
	end)
end
speedLines = guard(speedLines)

-- FLIGHT LINES: speed lines that FOLLOW a thrown enemy from the moment it leaves until it lands. A small pool of streaks is kept around the
-- enemy; each streak is placed behind it along its REAL velocity (so the lines bend with the flight and point the right way when it tumbles
-- or falls), shoots back, fades, and is reborn at a new spot around the body, so there is always a stream and never a gap. They stop when
-- the enemy has landed (slow again) or after 2.2 s.
local function flightLines(model: Model, I: number, onLand: (() -> ())?, tint: Tint?)
	local r = model:FindFirstChild("HumanoidRootPart")
	local cam = workspace.CurrentCamera
	if not (r and r:IsA("BasePart") and cam) then return end
	local count = IS_MOBILE and 5 or 9
	local lines: { { part: Part, decal: Decal, t: number, life: number, off: Vector3, back: number, len: number, phase: number } } = {}
	local function respawn(l: any, delay: number)
		local a = math.random() * math.pi * 2
		local rad = 0.5 + math.random() * 1.8
		l.t, l.life, l.back, l.len = -delay, 0.2 + math.random() * 0.16, math.random() * 1.2, (4 + 4 * I + math.random() * 3)
		l.off = Vector3.new(math.cos(a) * rad, math.sin(a) * rad * 0.8, 0) -- turned into the plane across the flight every frame
	end
	for i = 1, count do
		local part, decal = acquireLine("DarkFlightLine")
		part.Size = Vector3.new(1, 0.3, 0.05)
		decal.Color3 = PAL.pale
		local l = { part = part, decal = decal, t = 0, life = 0.3, off = Vector3.zero, back = 0, len = 5, phase = (i % 2) * math.pi } -- neighbours sway in opposite phase
		respawn(l, (i / count) * 0.2)
		lines[i] = l
	end
	local t0 = os.clock()
	local lastPos, vel = r.Position, Vector3.zero
	local axis = Vector3.zAxis
	local conn: RBXScriptConnection
	local function finish()
		conn:Disconnect()
		for _, l in lines do releaseLine(l.part) end
	end
	conn = RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock() - t0
		if not r.Parent or now > 2.2 then return finish() end
		-- the velocity is MEASURED from the position (the replicated velocity of a body that the Server simulates is not reliable on the client)
		local raw = if dt > 0 then (r.Position - lastPos) / dt else Vector3.zero
		lastPos = r.Position
		vel = vel:Lerp(raw, 0.5)
		local speed = vel.Magnitude
		if now > 0.45 and speed < 10 then -- it has landed
			finish()
			if onLand then onLand() end
			return
		end
		if speed > 2 then axis = vel.Unit end
		local across = axis:Cross(Vector3.yAxis)
		across = if across.Magnitude > 0.1 then across.Unit else Vector3.xAxis
		local up = axis:Cross(across)
		local k = math.clamp(speed / 60, 0.35, 1) -- slower flight = shorter lines
		local farK = if tint then math.min(distScale(r.Position), 1.6) else 1 -- the Z lines keep their size on the screen when the enemy is far (see distScale)
		-- KARMAN VORTEX STREET: a body moving through air sheds vortices alternately to the left and the right of its wake at the frequency
		-- f = St * v / D (Strouhal number St ~ 0.2 for a wide range of speeds, D = the width of the body, about 2 studs). The streaks sway sideways
		-- at that frequency, neighbours in opposite phase, so the wake looks like a real turbulent trail and not like straight rulers.
		local shed = 0.2 * speed / 2
		-- DOPPLER (the Z skill's colours): light from a body that flies TOWARD the camera is blue-shifted, from one that flies AWAY is red-shifted
		-- (60 studs/s toward or away = the full shift; the colours are made in OKLCH, see dopplerColor)
		local shiftS = 0
		if tint then
			local toCamera = cam.CFrame.Position - r.Position
			if toCamera.Magnitude > 0.5 and speed > 2 then shiftS = math.clamp(vel:Dot(toCamera.Unit) / 60, -1, 1) end
		end
		for _, l in lines do
			l.t += dt
			if l.t >= l.life then respawn(l, 0) end
			if l.t >= 0 then
				local a = l.t / l.life
				local len = l.len * k * (1 - 0.45 * a) * farK
				local sway = math.sin(2 * math.pi * shed * now + l.phase) * 0.45
				local center = r.Position + across * (l.off.X + sway) + up * l.off.Y - axis * (len * 0.5 + 0.8 + l.back + a * 2.5)
				local toCam = cam.CFrame.Position - center
				local z = toCam - axis * toCam:Dot(axis)
				z = if z.Magnitude > 0.01 then z.Unit else Vector3.yAxis
				l.part.CFrame = CFrame.fromMatrix(center, axis, z:Cross(axis), z)
				l.part.Size = Vector3.new(len, len * 0.1, 0.05)
				-- BEER-LAMBERT: light that crosses the air is weakened as e^(-d / L), and what remains takes on the colour of the air (Rayleigh
				-- scattering): far streaks are fainter and bluer-grey, near ones are bright
				local tr = 0.15 + 0.85 * a * a
				local lineColor = if tint == nil then PAL.pale elseif tint.doppler == false then tint.map(PAL.pale) else dopplerColor(shiftS, 1)
				if tint then -- (the Z lines are light, not matter: no fog mix, no fading with the distance, more chroma instead)
					l.decal.Transparency = tr
					l.decal.Color3 = farBoost(lineColor, center)
				else
					l.decal.Transparency = 1 - (1 - tr) * math.exp(-toCam.Magnitude / 400)
					l.decal.Color3 = aerial(lineColor, center)
				end
				-- (the colour of the line is set above)
				l.part.Parent = workspace
			end
		end
	end)
end
flightLines = guard(flightLines)

-- LAUNCH BURST: a burst of sparks (picture-based) thrown back against the hit direction from the contact point.
local SPARK_PICTURE = "rbxassetid://311395391" -- fine sparks

-- PRELOAD: a picture that is not downloaded yet shows NOTHING (this is what happens on the first throw, and far away it is easy to miss), so
-- every picture of the effects is loaded at the start. The Billboards of the hit pictures also get a huge MaxDistance so they are never
-- hidden by distance.
task.spawn(function()
	local ids: { string } = { SPEED_IMAGE, SLASH_IMAGE, SPARK_PICTURE }
	for _, def in FX_HIT_LAYERS do table.insert(ids, def.image) end
	for _, def in Z_HIT_LAYERS do table.insert(ids, def.image) end
	for _, def in Z_CUT_LAYERS do table.insert(ids, def.image) end
	local ok, err = pcall(function() game:GetService("ContentProvider"):PreloadAsync(ids) end)
	if not ok then warn("[DarkSword] could not preload the effect pictures:", err) end
end)
-- INCANDESCENT SPARKS (physics + chemistry): a spark is a hot metal grain burning in the air, so its colour is that of a black body and it
-- cools by Newton's law, T ~ e^(-kt): white-hot at first, then rose, then deep red (the colour keys below are taken from the same black-body
-- ramp as the light of the hit). Only additive light is used, like fire. Each spark falls under gravity and is slowed by air drag. As in real
-- sparks there are few big LEADER sparks (long-lived) and many small SECONDARY sparks (short-lived, wider, slower).
local function coolingColors(tint: Tint?): ColorSequence
	local keys = {}
	for i = 0, 4 do
		local x = i / 4
		local c = blackbody(math.exp(-2.2 * x))
		table.insert(keys, ColorSequenceKeypoint.new(x, if tint then tint.map(c) else c))
	end
	return ColorSequence.new(keys)
end

local function sparkBurst(pos: Vector3, dir: Vector3, count: number, tint: Tint?)
	local camK = distScale(pos)
	local holder = Instance.new("Part")
	holder.Name = "DarkBurst"
	holder.Anchored, holder.CanCollide, holder.CanQuery, holder.CanTouch, holder.CastShadow = true, false, false, false, false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.CFrame = CFrame.lookAt(pos, pos - dir) -- the front looks back against the throw: sparks fly off the contact point
	local colors = coolingColors(tint)
	local fade = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.7, 0.2), NumberSequenceKeypoint.new(1, 1) })
	local fall = Vector3.new(0, -workspace.Gravity * 0.35, 0) -- gravity (a little lighter than real, so the sparks still read as a burst)
	local function emitter(lifetime: NumberRange, speed: NumberRange, spread: number, size: number, drag: number, n: number)
		local e = Instance.new("ParticleEmitter")
		e.Texture = SPARK_PICTURE
		e.Rate = 0
		e.Lifetime = lifetime
		e.Speed = speed
		e.SpreadAngle = Vector2.new(spread, spread)
		e.EmissionDirection = Enum.NormalId.Front
		e.Acceleration = fall
		e.Drag = drag
		e.Orientation = Enum.ParticleOrientation.VelocityParallel
		e.LightEmission = 1
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size * camK), NumberSequenceKeypoint.new(1, 0) })
		e.Transparency = fade
		e.Color = colors
		e.Parent = holder
		e:Emit(n)
	end
	emitter(NumberRange.new(0.4, 0.65), NumberRange.new(34, 62), 38, 1.5, 2.5, math.max(2, math.floor(count * 0.3))) -- leaders
	emitter(NumberRange.new(0.15, 0.32), NumberRange.new(16, 46), 75, 0.55, 4, count) -- secondary sparks
	holder.Parent = workspace
	Debris:AddItem(holder, 1.2)
end
local function launchBurst(model: Model, dir: Vector3, I: number, tint: Tint?)
	local torso = torsoOf(model)
	if not torso then return end
	local flat = if dir.Magnitude > 0.01 then dir.Unit else Vector3.zAxis
	local pos = torso.Position
sparkBurst(pos, flat, IS_MOBILE and 10 or 20, tint)
end
launchBurst = guard(launchBurst)

-- AFTERIMAGES: while the enemy flies, a ghost of its REAL body (a clone, so the exact shape, limbs and accessories in the pose of that
-- moment) is left behind every 0.07 s. The ghosts are made of glowing Neon, white-hot at first and a deeper crimson the later they come,
-- and each one fades out in 0.4 s: the eye reads the whole path of the throw as a smooth sweep of fading bodies.
local ghostsAlive = 0
local GHOST_MAX = 14
local function spawnGhost(model: Model, heat: number, color: Color3?, tint: Tint?)
	if ghostsAlive >= GHOST_MAX then return end
	local was = model.Archivable
	model.Archivable = true
	local ghost = model:Clone()
	model.Archivable = was
	if not ghost then return end
	ghost.Name = "DarkGhost"
	for _, d in ghost:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide, d.CanQuery, d.CanTouch, d.CastShadow = false, false, false, false
			d.Massless = true
			if d.Name == "HumanoidRootPart" then
				d.Transparency = 1
			else
				d.Material = Enum.Material.Neon -- (ForceField was too faint in daylight)
				local base = color or PAL.pale:Lerp(PAL.crim, heat)
					d.Color = aerial(if tint then tint.map(base) else base, d.Position) -- the colour of the air takes over with distance
				d.Transparency = 0.35
				TweenService:Create(d, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 1 }):Play()
			end
		elseif d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture") or d:IsA("Humanoid") or d:IsA("Script") or d:IsA("LocalScript")
			or d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Highlight") or d:IsA("Light") or d:IsA("Sound")
			or d:IsA("Constraint") or d:IsA("JointInstance") or d:IsA("BillboardGui") or d:IsA("Animator") or d:IsA("ForceField") then
			d:Destroy()
		end
	end
	ghostsAlive += 1
	ghost.Parent = workspace
	Debris:AddItem(ghost, 0.45)
	task.delay(0.45, function() ghostsAlive -= 1 end)
end

local function afterimages(model: Model, color: Color3?, tint: Tint?)
	local r = model:FindFirstChild("HumanoidRootPart")
	if not (r and r:IsA("BasePart")) then return end
	local t0, last = os.clock(), 0
	local lastPos, speed = r.Position, 0
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock() - t0
		if dt > 0 then speed += ((r.Position - lastPos).Magnitude / dt - speed) * 0.5 end -- measured speed (see flightLines)
		lastPos = r.Position
		if not r.Parent or now > 1.3 or (now > 0.4 and speed < 12) then
			conn:Disconnect()
			return
		end
		if now - last < 0.07 then return end
		last = now
		spawnGhost(model, math.clamp(now / 0.9, 0, 1), color, tint)
	end)
end
afterimages = guard(afterimages)

-- LANDING BURST: where the enemy comes down, the big hit picture (grown with the distance, so it reads from far away) and sparks thrown up
local function landingBurst(model: Model, I: number, tint: Tint?, size: number?)
	local torso = torsoOf(model)
	if not torso then return end
	popStar(model, torso, 9.5 * FX_HIT_SCALE * (size or 1), Vector3.yAxis, I, tint)
	sparkBurst(torso.Position, -Vector3.yAxis, IS_MOBILE and 12 or 24, tint) -- dir = down: the sparks fly back up from the floor
end
landingBurst = guard(landingBurst)


-- MOONFALL SHOCK (hit 3): at the moment of the slam the floor under the enemy bursts outward: a ring of small floor-colored bits
-- (the color and material of the floor), thrown out low and fast, plus a few that jump high. No ring or crack picture, only real bits.
local function slamBurst(model: Model, I: number, tint: Tint?)
	local r = model:FindFirstChild("HumanoidRootPart")
	if not r then return end
	local rp = Vfx.exRay({ model })
	local hit = workspace:Raycast(r.Position, Vector3.new(0, -8, 0), rp)
	if not (hit and hit.Instance and hit.Instance:IsA("BasePart")) then return end
	-- law 14 (stress threshold): the floor only breaks when the force passes a limit. Below it nothing flies; above it the number of
	-- bits grows with how far the force is over the limit.
	if I < 0.4 then return end
	local camK = distScale(hit.Position) -- the bits are bigger when the landing is far away
	local over = math.clamp((I - 0.4) / 0.6, 0, 1)
	local count = math.max(3, math.floor((IS_MOBILE and 8 or 14) * (0.35 + 0.65 * over) * Vfx.lodK(hit.Position)))
	for i = 1, count do
		if #debrisList > DEBRIS.max then break end
		local a = (i / count) * math.pi * 2 + (math.random() - 0.5) * 0.4
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		local sz = (0.1 + math.random() ^ 2 * 0.22) * camK
		local size = Vector3.new(sz, sz * (0.6 + math.random() * 0.6), sz * (0.8 + math.random() * 0.5))
		local p = Instance.new("Part")
		p.Name = "DarkShock"
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
		p.Color = aerial(hit.Instance.Color, hit.Position)
		p.Material = bitMaterial(hit.Material)
		p.Size = size
		p.CFrame = CFrame.new(hit.Position + hit.Normal * 0.05 + out * 0.8)
		p.Parent = workspace
		local high = i % 4 == 0
		table.insert(debrisList, {
			part = p, size = size, t = DEBRIS.life * 0.1, floorY = hit.Position.Y, mat = hit.Material, tint = tint,
			vel = out * ((high and 5 or 9) + 6 * I + math.random() * 3) + Vector3.new(0, (high and 11 or 3.5) + 4 * I + math.random() * 2, 0),
			spin = Vector3.new((math.random() - 0.5) * 20, (math.random() - 0.5) * 20, (math.random() - 0.5) * 20),
		})
	end
	-- law 1 (shock wave decay): a pressure wave runs outward from the landing at about 40 studs/s and gets weaker with distance
	-- (amplitude ~ 1 / (1 + r / 3)). No ring is drawn: only bits of floor at 4 distances jump when the front reaches them, lower and lower.
	if not IS_MOBILE then
		for _, rr in { 3, 6, 10, 15 } do
			task.delay(rr / 40, function()
				if #debrisList > DEBRIS.max then return end
				local amp = (1 + 0) / (1 + rr / 3) * (0.5 + I)
				for q = 1, 3 do
					local ang = math.random() * math.pi * 2
					local sz = (0.08 + math.random() * 0.12) * camK
					local size = Vector3.new(sz, sz * 0.8, sz)
					local p = Instance.new("Part")
					p.Name = "DarkShock"
					p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
					p.Color = aerial(hit.Instance.Color, hit.Position)
					p.Material = bitMaterial(hit.Material)
					p.Size = size
					p.CFrame = CFrame.new(hit.Position + hit.Normal * 0.05 + Vector3.new(math.cos(ang), 0, math.sin(ang)) * rr)
					p.Parent = workspace
					table.insert(debrisList, {
						part = p, size = size, t = DEBRIS.life * 0.25, floorY = hit.Position.Y, mat = hit.Material, tint = tint,
						vel = Vector3.new(0, 3 + 7 * amp + math.random() * 2, 0),
						spin = Vector3.new((math.random() - 0.5) * 12, 0, (math.random() - 0.5) * 12),
					})
				end
				if not debrisConn then
					debrisConn = RunService.Heartbeat:Connect(debrisStep)
				end
			end)
		end
	end
	-- laws 143/144 (vacuum and the back-draught after a blast): when the burst has passed, the air rushes back in, so a few small bits
	-- 3 to 6 studs out are pulled in toward the landing spot (floor bits only, no dust)
	if not IS_MOBILE then
		task.delay(0.25, function()
			for _ = 1, 5 do
				if #debrisList > DEBRIS.max then break end
				local ang = math.random() * math.pi * 2
				local rr = 3 + math.random() * 3
				local out = Vector3.new(math.cos(ang), 0, math.sin(ang))
				local sz = (0.08 + math.random() * 0.1) * camK
				local size = Vector3.new(sz, sz * 0.8, sz)
				local p = Instance.new("Part")
				p.Name = "DarkShock"
				p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
				p.Color = aerial(hit.Instance.Color, hit.Position)
				p.Material = bitMaterial(hit.Material)
				p.Size = size
				p.CFrame = CFrame.new(hit.Position + hit.Normal * 0.05 + out * rr)
				p.Parent = workspace
				table.insert(debrisList, {
					part = p, size = size, t = DEBRIS.life * 0.3, floorY = hit.Position.Y, mat = hit.Material,
					vel = -out * (4 + math.random() * 2.5) + Vector3.new(0, 1.5 + math.random(), 0),
					spin = Vector3.new((math.random() - 0.5) * 10, 0, (math.random() - 0.5) * 10),
				})
			end
			if not debrisConn then
				debrisConn = RunService.Heartbeat:Connect(debrisStep)
			end
		end)
	end
	if not debrisConn then
		debrisConn = RunService.Heartbeat:Connect(debrisStep)
	end
end
slamBurst = guard(slamBurst)

local function scrapeFx(model: Model, dir: Vector3, I: number, launch: boolean?, heavy: boolean?, tint: Tint?)
	local r = model:FindFirstChild("HumanoidRootPart")
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not r then return end
	local reach = (hum and hum.HipHeight or 2) + r.Size.Y / 2 + 1.5
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { model }
	local flat = Vector3.new(dir.X, 0, dir.Z)
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.zAxis
	task.spawn(function()
		local count = IS_MOBILE and 4 or (5 + math.floor(3 * I)) -- a longer path of dust
		if not heavy then count = IS_MOBILE and 3 or 4 end
		if launch then count = IS_MOBILE and 3 or 5 end
		for _ = 1, count do
			if not r.Parent or #debrisList > DEBRIS.max then return end -- (_ is the number of the bit)
			local hit = workspace:Raycast(r.Position, Vector3.new(0, -reach, 0), rp)
			if hit and hit.Instance and hit.Instance:IsA("BasePart") then
				local sz = 0.08 + math.random() ^ 2 * 0.16
				local size = Vector3.new(sz, sz * (0.6 + math.random() * 0.6), sz * (0.8 + math.random() * 0.5))
				local p = Instance.new("Part")
				p.Name = "DarkScrape"
				p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
				p.Color = aerial(hit.Instance.Color, hit.Position)
				p.Material = bitMaterial(hit.Material)
				p.Size = size
				p.CFrame = CFrame.new(hit.Position + hit.Normal * 0.05)
				p.Parent = workspace
				local side = Vector3.new(-flat.Z, 0, flat.X) * ((math.random() - 0.5) * 2.5)
				table.insert(debrisList, {
					part = p, size = size, t = DEBRIS.life * 0.15, floorY = hit.Position.Y, mat = hit.Material, tint = tint,
					vel = launch and (flat * (0.5 + math.random()) + Vector3.new(0, 6 + 5 * I + math.random() * 3, 0) + side)
						or (-flat * (2 + 3 * I + math.random() * 2) + Vector3.new(0, 2.5 + 3 * I + math.random() * 2, 0) + side),
					spin = Vector3.new((math.random() - 0.5) * 16, (math.random() - 0.5) * 16, (math.random() - 0.5) * 16),
				})
				if not debrisConn then
					debrisConn = RunService.Heartbeat:Connect(debrisStep)
				end
			end
			task.wait((launch and 1 or 3) * F)
		end
	end)
end
scrapeFx = guard(scrapeFx)

-- BLINK CUT TRAIL (the Z dash): speed lines along the path, afterimages, a cold glow and the floor bits kicked up by the stop, coloured by physics.
-- Science: the RELATIVISTIC DOPPLER EFFECT. Light from a source that moves at the fraction beta = v / c of the speed of light is blue-shifted
-- AHEAD of it and red-shifted BEHIND it. C_GAME is this effect's own "speed of light" (studs/s), chosen so that the dash is a large part of it.
-- So the streaks near the end of the path are blue, the ones near the start are red, in between they are white, and the afterimages left
-- BEHIND are red-shifted too (the colours are made in OKLCH, see dopplerColor). LENGTH CONTRACTION: the streaks are shortened by
-- sqrt(1 - beta^2). CHERENKOV GLOW: a particle faster than light in a medium glows blue, so the body gets a cold blue light for a moment.
-- FRICTION: where the body stops, the floor under it is scraped (the same bits as the enemy's skid).
local C_GAME = 220 -- studs/s
local BLINK_DASH_TIME = 0.12 -- the same as BlinkCutConfig.DashTime

local function blinkTrail(from: Vector3, to: Vector3, model: Model)
	local delta = to - from
	local dist = delta.Magnitude
	local cam = workspace.CurrentCamera
	local root = model:FindFirstChild("HumanoidRootPart")
	if dist < 1 or not cam or not (root and root:IsA("BasePart")) then return end
	local axis = delta.Unit
	local beta = math.clamp(dist / BLINK_DASH_TIME / C_GAME, 0, 0.95)
	local contraction = math.sqrt(1 - beta * beta)
	local sat = math.clamp(beta / 0.7, 0.45, 1) -- the faster the dash, the stronger the colour of the shift

	-- afterimages: one every 0.03 s while the body flies, red-shifted because they are left BEHIND
	local tailColor = dopplerColor(-1, sat)
	local t0 = os.clock()
	local lastGhost = -1
	local ghostConn: RBXScriptConnection? = nil
	ghostConn = RunService.Heartbeat:Connect(function()
		local now = os.clock() - t0
		if now > BLINK_DASH_TIME + 0.03 or not root.Parent then
			if ghostConn then
				ghostConn:Disconnect()
				ghostConn = nil
			end
			return
		end
		if now - lastGhost >= 0.03 then
			lastGhost = now
			spawnGhost(model, 0, tailColor)
		end
	end)

	-- the cold light of the Cherenkov glow
	local glow = Instance.new("PointLight")
	glow.Color = dopplerColor(1, sat)
	glow.Range = 16
	glow.Brightness = 3.5
	glow.Shadows = false
	glow.Parent = root
	TweenService:Create(glow, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()
	Debris:AddItem(glow, 0.5)

	-- the stop scrapes the floor
	task.delay(BLINK_DASH_TIME, function()
		if root.Parent then scrapeFx(model, axis, 0.7, nil, false, BLINK_TINT) end
	end)

	-- speed lines along the path
	if linesAlive >= LINES_MAX + 2 then return end
	local count = IS_MOBILE and 7 or 14
	count = math.max(3, math.floor(count * Vfx.lodK(from:Lerp(to, 0.5)) + 0.5))
	local perpB = axis:Cross(Vector3.yAxis)
	perpB = if perpB.Magnitude > 0.01 then perpB.Unit else Vector3.xAxis
	local perpA = perpB:Cross(axis)
	local lines = {}
	for i = 1, count do
		local part, decal = acquireLine("DarkBlinkLine")
		part.Size = Vector3.new(1, 1, 0.05)
		part.Parent = workspace
		local along = math.random() -- 0 = start of the path, 1 = its end
		local ang = math.random() * math.pi * 2
		local rad = 0.5 + math.random() * 2.6
		decal.Color3 = dopplerColor(2 * along - 1, sat) -- red at the start, white in the middle, blue at the end
		lines[i] = {
			part = part, decal = decal,
			len = (9 + math.random() * 9) * contraction,
			thick = 0.25 + math.random() * 0.2,
			life = 0.28 + math.random() * 0.2,
			delay = along * BLINK_DASH_TIME + math.random() * 0.03, -- it appears when the body passes
			center = from + axis * (along * dist) + perpA * math.cos(ang) * rad + perpB * math.sin(ang) * rad * 0.8 + Vector3.new(0, 0.3, 0),
		}
	end
	linesAlive += 1
	local start = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		local now = os.clock() - start
		local alive = false
		for _, l in lines do
			local a = (now - l.delay) / l.life
			if a >= 1 then
				l.decal.Transparency = 1
			else
				alive = true
				if a >= 0 then
					local grow = if a < 0.3 then 0.4 + 2 * (a / 0.3) else 2.4 - 2.1 * ((a - 0.3) / 0.7) ^ 0.8 -- shoots out, then draws back in
					local len = l.len * 0.5 * grow
					local toCam = cam.CFrame.Position - l.center
					local z = toCam - axis * toCam:Dot(axis)
					z = if z.Magnitude > 0.01 then z.Unit else Vector3.zAxis
					l.part.CFrame = CFrame.fromMatrix(l.center, axis, z:Cross(axis), z)
					l.part.Size = Vector3.new(len, len * l.thick, 0.05)
					l.decal.Transparency = 0.15 + 0.85 * a * a * a
				end
			end
		end
		if not alive then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			linesAlive -= 1
			for _, l in lines do releaseLine(l.part) end
		end
	end)
end
blinkTrail = guard(blinkTrail)

-- THE DELAYED CUT (the signature of the dash): the body is already gone when the air it went through is CUT. 0.08 s after the blink one long bright
-- line appears along the whole path, thin at first, opening quickly and then thinning out and fading in half a second (the way an anime shows a cut
-- that the eye did not see happen). It is made of the same speed-line picture as the other lines, in the white and rose of the normal attack.
local function blinkCutLine(from: Vector3, to: Vector3)
	local cam = workspace.CurrentCamera
	local delta = to - from
	local dist = delta.Magnitude
	if not cam or dist < 3 then return end
	local axis = delta.Unit
	local mid = (from + to) / 2 + Vector3.new(0, 0.4, 0)
	local function make(color: Color3, alpha: number): (Part, Decal)
		local part, decal = acquireLine("DarkBlinkCut")
		part.Size = Vector3.new(dist, 0.1, 0.05)
		part.CFrame = CFrame.new(mid)
		part.Parent = workspace
		decal.Color3 = color
		return part, decal
	end
	local core, coreDecal = make(PAL.white, 0.1)
	local veil, veilDecal = make(PAL.rose, 0.5)
	local start = os.clock()
	local DELAY, LIFE = 0.08, 0.5
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		local a = (os.clock() - start - DELAY) / LIFE
		if a >= 1 or not core.Parent then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			releaseLine(core)
			releaseLine(veil)
			return
		end
		if a < 0 then return end
		local toCam = cam.CFrame.Position - mid
		local z = toCam - axis * toCam:Dot(axis)
		z = if z.Magnitude > 0.01 then z.Unit else Vector3.zAxis
		local cf = CFrame.fromMatrix(mid, axis, z:Cross(axis), z)
		local opening = 1 - (1 - math.min(a * 4, 1)) ^ 3 -- the line opens in the first quarter of its life
		local thick = (0.12 + 0.5 * opening) * (1 - a) -- then it thins out
		core.CFrame, veil.CFrame = cf, cf
		core.Size = Vector3.new(dist, thick + 0.05, 0.05)
		veil.Size = Vector3.new(dist, thick * 3 + 0.1, 0.05)
		coreDecal.Transparency = 0.05 + 0.95 * a * a
		veilDecal.Transparency = 0.45 + 0.55 * a
	end)
end
blinkCutLine = guard(blinkCutLine)

-- Z CUT LINES: the look that only the flurry has. Thin bright streaks cross the enemy's body at random angles, one for each cut, drawn flat to the
-- screen. They shoot out fast from the middle and fade in about 1/6 s. Science: PERSISTENCE OF VISION. The eye keeps an image for about 1/16 s, so a
-- blade that moves faster than that is seen as a LINE along its path, not as a blade; the lines of the fastest cuts are white-hot, the others cooler.
local cutLinesAlive = 0
local function cutLines(model: Model, count: number, length: number, tint: Tint)
	local torso = torsoOf(model)
	local cam = workspace.CurrentCamera
	if not (torso and cam) or cutLinesAlive >= 6 then return end
	cutLinesAlive += 1
	local lines = {}
	for i = 1, count do
		local part, decal = acquireLine("DarkCutLine")
		part.Size = Vector3.new(1, 1, 0.05)
		part.Parent = workspace
		decal.Color3 = tint.map(if math.random() < 0.4 then PAL.white else PAL.rose) -- white-hot or cooler
		decal.Parent = part
		lines[i] = {
			part = part, decal = decal,
			angle = math.random() * math.pi, offset = (math.random() - 0.5) * 1.6,
			len = length * (0.7 + 0.6 * math.random()), life = 0.14 + 0.08 * math.random(), delay = (i - 1) * 0.02,
		}
	end
	local start = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.Heartbeat:Connect(function()
		local now = os.clock() - start
		local alive = false
		local look = cam.CFrame
		for _, l in lines do
			local a = (now - l.delay) / l.life
			if a >= 1 or not torso.Parent then
				l.decal.Transparency = 1
			else
				alive = true
				if a >= 0 then
					local along = look.RightVector * math.cos(l.angle) + look.UpVector * math.sin(l.angle) -- a direction in the plane of the screen
					local across = -look.RightVector * math.sin(l.angle) + look.UpVector * math.cos(l.angle)
					local center = torso.Position + across * l.offset
					local len = l.len * (1 - (1 - math.min(a * 2, 1)) ^ 3) * math.min(distScale(torso.Position), 1.6) -- shoots out fast; a little bigger when the enemy is far (at most 1.6 times: no line may outgrow the rest)
					l.part.CFrame = CFrame.fromMatrix(center, along, -look.LookVector:Cross(along), -look.LookVector)
					l.part.Size = Vector3.new(len, len * 0.05 + 0.04, 0.05)
					l.decal.Transparency = 0.05 + 0.95 * a * a
				end
			end
		end
		if not alive then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			cutLinesAlive -= 1
			for _, l in lines do releaseLine(l.part) end
		end
	end)
end
cutLines = guard(cutLines)

-- inherit = the velocity of the enemy when it is THROWN: the bits it loses share that velocity (momentum: a piece that breaks off a moving body keeps
-- moving with it) and burst out of it in every direction. Without it the bits were thrown along the blade and stayed behind in the air while the
-- enemy shot away, which looked like a trail of dropped bits instead of a body that breaks apart.
local function spawnDebris(model: Model, torso: BasePart, dir: Vector3, I: number, tint: Tint?, inherit: Vector3?)
	local pool = {}
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" and p.Transparency < 0.9 then table.insert(pool, p) end
	end
	if #pool == 0 or #debrisList > DEBRIS.max then return end
	local count = math.floor((2 + 4 * I) * (IS_MOBILE and 0.5 or 1) * Vfx.lodK(torso.Position) + 0.5) -- few small bits: light hits get 2-3, only strong ones 5-6
	local rp = Vfx.exRay({ model })
	local gh = workspace:Raycast(torso.Position, Vector3.new(0, -10, 0), rp)
	local floorY = gh and gh.Position.Y or nil -- the bits bounce on the floor under the enemy
	-- the bits are made one after another (every 2 frames), not all in the same frame
	local function makePiece()
		if not torso.Parent then return end
		local src = pool[math.random(#pool)]
		local sz = 0.1 + math.random() ^ 2 * 0.22
		local size = Vector3.new(sz, sz * (0.6 + math.random() * 0.7), sz * (0.8 + math.random() * 0.5))
		local p = Instance.new("Part")
		p.Name = "DarkDebris"
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
		p.Color = src.Color
		p.Material = bitMaterial(src.Material)
		p.Size = size
		local off = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 1.4
		p.CFrame = CFrame.new(torso.Position + off) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		p.Parent = workspace
		local spread = Vector3.new(math.random() - 0.5, math.random() * 0.4, math.random() - 0.5) * 7
		table.insert(debrisList, {
			part = p, size = size, t = 0, floorY = floorY, tint = tint,
			-- KINETIC ENERGY: E ~ v^2, so the launch speed grows with the square root of the blade speed (60 studs/s = normal).
			-- MOMENTUM TRANSFER: the bit also takes a part (18 %) of the blade's own velocity, so it flies the way the sword moved.
			vel = if inherit then inherit * 0.75 + Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit * (6 + 8 * I + math.random() * 4)
					else dir * (7 + 9 * I + math.random() * 5) * math.clamp(math.sqrt(bladeSpeedNow / 60), 0.7, 1.4)
				+ Vector3.new(0, 4 + math.random() * 6, 0) + spread + bladeVelNow * 0.18,
			spin = Vector3.new((math.random() - 0.5) * 24, (math.random() - 0.5) * 24, (math.random() - 0.5) * 24),
		})
		if not debrisConn then
			debrisConn = RunService.Heartbeat:Connect(debrisStep)
		end
	end
	for n = 1, count do
		task.delay((n - 1) * 2 * F, makePiece)
	end
end

Vfx.hitTarget = function(model: Model, kind: string, dir: Vector3, strength: number?, tint: Tint?)
	local r = model:FindFirstChild("HumanoidRootPart")
	local cfg = HIT_FX[kind] or HIT_FX.rise
	local fx = getHitFx(model, tint)
	if not r or not fx then return end
	local I = math.clamp(tonumber(strength) or 0.6, 0, 1) -- the Server's impact strength
	local torso = fx.att.Parent
	-- aim the streaks away from you: the attachment's front looks along the hit direction
	fx.att.WorldCFrame = CFrame.lookAt(torso.Position, torso.Position + dir)
	if cfg.flare > 0 then popStar(model, torso, cfg.flare * FX_HIT_SCALE, dir, I, tint) end -- the hit picture (3 layers)
	flash(model, cfg, I, kind == "slam", tint) -- the white glow on the enemy body (calmer for the slam)
	blinkBody(model, I, kind) -- ...and the body flickers
	spawnDebris(model, torso, dir, I, tint, if kind == "fling" then dir * 40 + Vector3.new(0, 24, 0) else nil) -- small real-part bits
	local function lightBlock() -- the light: jumps to full on the hit, then fades; the ground and the enemy around light up in red for a blink
		local peak, secs = unpack(HIT_LIGHT[kind] or HIT_LIGHT.rise)
		peak = peak * (0.8 + 0.7 * I) * (HIT_STEP[kind] or 1) * (((Lighting.ClockTime < 6 or Lighting.ClockTime > 18) and 1.3) or 1) -- PURKINJE: at night deep red looks darker to the eye, so the red light is a little brighter then -- a stronger hit lights up more, and each hit of the combo is a step above the last; the light belongs to the main burst, so it peaks at frame 0
		-- law 22 (inverse-square light): what you SEE of the flash falls with the square of the distance from the camera (reference 15 studs, never below 25 %)
		do
			local cam = workspace.CurrentCamera
			local at = fx.att and fx.att.WorldPosition
			if cam and at then
				local d = (at - cam.CFrame.Position).Magnitude
				peak = peak * math.clamp((15 / math.max(d, 15)) ^ 2, 0.25, 1)
			end
		end
		local light = fx.light
		if fx.lightTween then fx.lightTween:Cancel() end
		light.Brightness = peak
		light.Range = 10
		local hot = blackbody(0.6 + 0.4 * I):Lerp(Color3.new(1, 1, 1), 0.55)
		light.Color = if tint then tint.map(hot) else hot -- WIEN: a stronger hit is hotter, so whiter; a weak one is more orange-red
		-- two blinks: a hard flash, a quick dip, a second weaker flash, then the slow fade (a single smooth fade reads as flat)
		local lightToken = (fx.lightToken or 0) + 1
		fx.lightToken = lightToken
		fx.lightTween = TweenService:Create(light, TweenInfo.new(3 / 30, Enum.EasingStyle.Linear), { Brightness = peak * 0.2 })
		fx.lightTween:Play()
		fx.lightTween.Completed:Once(function(state)
			if state ~= Enum.PlaybackState.Completed or fx.lightToken ~= lightToken or not light.Parent then return end -- a cancelled tween (a new hit) must not start the second blink
			-- law 29 (spherical spreading): the same light energy over a bigger sphere is dimmer, intensity ~ 1 / R^2.
			-- The second blink starts at range 14 with brightness scaled by (10 / 14)^2, then the range grows to 18 as it fades.
			light.Range = 14
			light.Brightness = peak * 0.75 * (10 / 14) ^ 2 * 1.6
			-- NEWTON COOLING: a hot spot loses heat in proportion to how hot it still is, so the light dies as e^(-t/tau):
			-- bright at first, then a long soft tail (a Quad tween fades too evenly)
			local b0 = light.Brightness
			local t0 = os.clock()
			task.spawn(function()
				while light.Parent and fx.lightToken == lightToken do
					local t = os.clock() - t0
					if t >= secs then break end
					local a = t / secs
					light.Brightness = b0 * math.exp(-(kind == "slam" and 2.6 or 4) * a) * (1 - a * a * 0.2) -- the slam leaves the floor glowing longer (slower cooling)
					light.Range = 14 + 4 * a
					light.Color = light.Color:Lerp(if tint then tint.map(HIT_LIGHT_COLOR) else HIT_LIGHT_COLOR, 0.15) -- it also cools from white toward crimson
					RunService.Heartbeat:Wait()
				end
				if light.Parent and fx.lightToken == lightToken then light.Brightness = 0 end
			end)
		end)
	end
	-- law 134 (the pressure comes before the light): on the slam the bits fly first, the flash follows 0.05 s later
	if kind == "slam" then task.delay(0.05, lightBlock) else lightBlock() end
	-- remove the attachment (and its emitters) when this enemy has not been hit for a while
	fx.token += 1
	local token = fx.token
	task.delay(4, function()
		if fx.token == token and fx.att.Parent then
			fx.att:Destroy()
			for _, L in fx.layers or {} do L.bb:Destroy() end
			local cache = if tint ~= nil and tint.set == "z" then fxByModelZ elseif tint ~= nil and tint.set == "zc" then fxByModelZC else fxByModel
				if cache[model] == fx then cache[model] = nil end
		end
	end)
end

-- HIT 3 HOLD: while the enemy hangs in the air a crimson light on its body pulses, slow at first and faster toward the slam (5 beats).
Vfx.holdPulse = function(model: Model, secs: number, tint: Tint?)
	local fx = getHitFx(model, tint)
	if not fx or not fx.light then return end
	fx.lightToken = (fx.lightToken or 0) + 1
	local token = fx.lightToken
	if fx.lightTween then fx.lightTween:Cancel() end
	local light = fx.light
	light.Color = if tint then tint.map(HIT_LIGHT_COLOR) else HIT_LIGHT_COLOR
	light.Range = 14
	task.spawn(function()
		local t0 = os.clock()
		while light.Parent and fx.lightToken == token and os.clock() - t0 < secs do
			local a = (os.clock() - t0) / secs
			local beat = math.abs(math.sin(a * a * math.pi * 5 + a * 1.2)) -- the beats come faster as it nears the slam
			light.Brightness = (1 + 3.5 * a) * (0.35 + 0.65 * beat)
			RunService.RenderStepped:Wait()
		end
		if fx.lightToken == token and light.Parent then light.Brightness = 0 end
	end)
end

local Timing = require(tool:WaitForChild("ComboTiming") :: ModuleScript) :: { [number]: { [string]: number } } -- numbers shared with the Server
local Anim = require(tool:WaitForChild("SwordRig") :: ModuleScript).new(CONFIG, {
	player = player,
	timing = Timing,
})
local Rig, COMBO, HitReact = Anim.Rig, Anim.COMBO, Anim.HitReact
local rad = math.rad
-- (poses, combo table and spring rig live in the ModuleScript "SwordRig")
-- the camera cues of a hit are made stronger or weaker by the Server's impact strength I (0..1): 0.6 .. 1.4 times
local function scaleCam(cue: any, k: number): any
	if typeof(cue) ~= "table" then return cue end
	local out = {}
	for key, v in cue do
		if key == "kick" and typeof(v) == "table" then
			out.kick = { v[1] * k, v[2] * k, v[3] * k }
		elseif key == "post" and typeof(v) == "table" then
			local p = {}
			for pk, pv in v do p[pk] = pv * k end
			out.post = p
		elseif key == "shake" or key == "push" or key == "fov" then
			out[key] = v * k
		else
			out[key] = v
		end
	end
	return out
end
-- strongest impact of a list of hit entries (0.5 if the Server sent none)
local function strongest(list: any): number
	local best
	if typeof(list) == "table" then
		for _, t in list do
			if typeof(t) == "table" and typeof(t.strength) == "number" then
				best = math.max(best or 0, t.strength)
			end
		end
	end
	return best or 0.5
end


local Cam = require(tool:WaitForChild("CameraFx")) -- all camera code lives in the ModuleScript "CameraFx"
Cam.configure({ Strength = CONFIG.CameraStrength, Post = CONFIG.CameraPost })

local Sfx = require(tool:WaitForChild("SwordSfx")) -- all sound code lives in the ModuleScript "SwordSfx"
-- ROOM PROBE (laws 16, 17, 19): shoots 8 rays round and one up from the body, so the sound can follow the place (size, how closed, floor)
local roomAt = -10
local function roomProbe()
	local now = os.clock()
	if now - roomAt < 0.5 then return end -- at most twice a second
	roomAt = now
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	local sum, n, hits = 0, 0, 0
	local origin = root.Position
	for i = 0, 7 do
		local a = i * math.pi / 4
		local h = workspace:Raycast(origin, Vector3.new(math.cos(a), 0, math.sin(a)) * 80, rp)
		n += 1
		if h then
			sum += h.Distance
			hits += 1
		else
			sum += 80
		end
	end
	local up = workspace:Raycast(origin, Vector3.new(0, 40, 0), rp)
	if up then hits += 1 end
	n += 1
	sum += up and up.Distance * 2 or 80
	local fl = workspace:Raycast(origin, Vector3.new(0, -14, 0), rp)
	Sfx.setRoom(sum / n, hits / 9, fl and fl.Material or Enum.Material.Plastic)
end


--------------------------------------------------------------------------------
-- Attack controller
--------------------------------------------------------------------------------
local char: Model = nil :: any -- set on equip; every use is guarded by alive() / equipped
local hum: Humanoid = nil :: any
local root: BasePart = nil :: any
local actor: any = nil -- the SwordRig Actor of your character
local rayParams = RaycastParams.new() -- reused (filter set on equip)
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.MaxParts = 64
local equipped = false
local diedConn: RBXScriptConnection?
local comboIndex, comboClock = 0, -100
local comboCycle = 0 -- counts started combos; picks which motion variant plays
local readyAt = 0
local finisherReadyAt = 0 -- hit 3 can be used again after this time (the Server counts the same)
local seqCounter = 0
local session: Session?
local recent: { [number]: Session } = {}
local queued: thread?

local function alive(): boolean
	return equipped and hum ~= nil and hum.Health > 0 and root ~= nil and root.Parent ~= nil
end

local function aimDirection(): Vector3
	local cam = workspace.CurrentCamera
	local look = Cam.cleanCFrame().LookVector -- the aim never reads the shake
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 1e-3 then
		flatLook = root.CFrame.LookVector
	end
	flatLook = flatLook.Unit
	local lastType = UserInputService:GetLastInputType().Name
	if lastType == "Touch" or lastType:find("Gamepad") then
		return flatLook
	end
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	local res = workspace:Raycast(ray.Origin, ray.Direction * 500, rayParams)
	local point = res and res.Position or (ray.Origin + ray.Direction * 100)
	local d = Vector3.new(point.X - root.Position.X, 0, point.Z - root.Position.Z)
	if d.Magnitude < 0.5 then
		return flatLook
	end
	return d.Unit
end

local function pickTarget(aim: Vector3): { dir: Vector3, dist: number, model: Model }?
	local parts = workspace:GetPartBoundsInRadius(root.Position, CONFIG.LockRadius, overlapParams)
	local best, bestScore
	local seen = {}
	for _, p in parts do
		local m = p:FindFirstAncestorOfClass("Model")
		if m and not seen[m] then
			seen[m] = true
			local h = m:FindFirstChildOfClass("Humanoid")
			local r = m:FindFirstChild("HumanoidRootPart")
			if h and r and h.Health > 0 then
				local d = Vector3.new(r.Position.X - root.Position.X, 0, r.Position.Z - root.Position.Z)
				local dist = d.Magnitude
				if dist > 0.1 then
					local a = math.deg(math.acos(math.clamp(aim:Dot(d.Unit), -1, 1)))
					if a <= CONFIG.LockCone then
						local score = a + dist * 1.5
						if not bestScore or score < bestScore then
							best = { dir = d.Unit, dist = dist, model = m }
							bestScore = score
						end
					end
				end
			end
		end
	end
	return best
end

local function turnToward(dir: Vector3, maxRad: number)
	local look = root.CFrame.LookVector
	local cur = math.atan2(-look.X, -look.Z)
	local want = math.atan2(-dir.X, -dir.Z)
	local diff = (want - cur + math.pi) % (2 * math.pi) - math.pi
	local step = math.clamp(diff, -maxRad, maxRad)
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, cur + step, 0)
end

-- returns { stop, freeze } or nil
local function lunge(dir: Vector3, speed: number, time: number, targetDist: number?, dragDist: number?, keepSpeed: boolean?): Lunge?
	if speed <= 0 then return nil end
	local dist = speed * time
	if keepSpeed then
		-- hit 3 roll: no distance limit. It goes straight at the enemy (or on and on, up to rollMax seconds) at a constant speed;
		-- a near enemy still gets a full turn (at least one dash time, slower), the Server catches after rollMin seconds
		dist = speed * Timing[3].rollMax
		if targetDist then dist = math.min(dist, math.max(0, targetDist - CONFIG.LockStopDistance)) end
	elseif targetDist then
		-- distance to reach the enemy, plus the drag after meeting them (0 for normal hits)
		local drag = dragDist or 0
		dist = math.clamp(math.max(0, targetDist - CONFIG.LockStopDistance) + drag, math.min(drag, dist), dist)
	end
	local hit = workspace:Raycast(root.Position, dir * (dist + 1.5), rayParams)
	if hit then
		dist = math.max(0, hit.Distance - 1.5)
	end
	if dist < 0.1 then return nil end -- (standing against a wall or an enemy: the somersault still plays, only the movement is skipped)
	if keepSpeed then time = math.max(dist / speed, Timing[3].rollMin) end -- the roll keeps its speed; a near enemy just means a slower, shorter dash
	local v = dist / time
	local att = Instance.new("Attachment")
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	lv.LineDirection = dir
	lv.LineVelocity = v
	lv.MaxForce = math.huge
	lv.Parent = root
	local ctl = {}
	local stopped = false
	function ctl.freeze(on)
		if not stopped then
			lv.LineVelocity = on and 0 or v
		end
	end
	function ctl.stop()
		if stopped then return end
		stopped = true
		if keepSpeed and lv.Parent then
			-- ROLLING FRICTION + INERTIA: the roll slows down over 0.1 s instead of stopping dead
			TweenService:Create(lv, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { LineVelocity = 0 }):Play()
			task.delay(0.11, function()
				lv:Destroy()
				att:Destroy()
				if root and root.Parent then
					local vv = root.AssemblyLinearVelocity
					root.AssemblyLinearVelocity = Vector3.new(0, math.min(vv.Y, 0), 0)
				end
			end)
			return
		end
		lv:Destroy()
		att:Destroy()
		-- no leftover speed after the dash (it used to slide or pop you up)
		if root and root.Parent then
			local v = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(0, math.min(v.Y, 0), 0)
		end
	end
	task.delay(time + 0.05, ctl.stop)
	return ctl
end

local function endSession(s: Session?)
	if not s or not s.alive then return end
	s.alive = false
	for i = #s.cleanups, 1, -1 do
		pcall(s.cleanups[i])
	end
	if session == s then
		session = nil
	end
end

local function onStrike(s: Session)
	if not s.alive then return end
	local step = s.step
	if not step.finisher then Vfx.strike(char, s.index) end -- (the leap of hit 3 has its slash at the throw, with the chop)
	Cam.play(step.strikeCam)
	if actor then actor:strikePhysics(s.index) end -- ...and at the strike: weight forward, knees dip, torso counter-turn, free arm counter-swing, rebound
	-- law 6 (motion blur by speed): the screen blur at the strike grows with the speed of the blade (nothing when it is slow)
	Cam.post({ blur = math.clamp(bladeSpeedNow / 90, 0, 0.45) })
	-- do not bump into the enemy (local only, restored afterwards): hit 3 passes through EVERY character within 200 studs while it rolls;
	-- hits 1 and 2 pass through the ones within 30 studs, so the enemy being knocked back can never trip YOU
	do
		local saved = {}
		for _, part in workspace:GetPartBoundsInRadius(root.Position, step.finisher and 200 or 30, overlapParams) do
			local m = part:FindFirstAncestorOfClass("Model")
			if m and m ~= char and m:FindFirstChildOfClass("Humanoid") and part.CanCollide then
				saved[part] = true
				part.CanCollide = false
			end
		end
		table.insert(s.cleanups, function()
			for p in saved do
				if p.Parent then p.CanCollide = true end
			end
		end)
	end
	local ctl
	if not step.finisher and s.target and s.target.dist < CONFIG.PersonalSpace then
		-- standing inside each other: step back a little instead of lunging into the enemy
		local gap = math.min(CONFIG.PersonalSpace - s.target.dist, 1.5)
		ctl = lunge(-s.dir, gap / step.lungeTime, step.lungeTime)
	else
		-- hit 3: an invulnerable roll toward the enemy (or straight ahead, up to 30 studs) at a constant speed
		ctl = lunge(s.dir, step.lunge, step.lungeTime, s.target and s.target.dist, 0, step.finisher)
	end
	s.lungeCtl = ctl
	if step.finisher then -- the LEAP of hit 3: an upward launch on top of the dash (the dash line constraint only holds the horizontal direction)
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, 60, v.Z)
	end
	if ctl then
		table.insert(s.cleanups, ctl.stop)
	end
end

local function startSwing(seq: number, idx: number, step: StepT, aim: Vector3, prev: PrevState): Session
	endSession(session)
	local s = {
		seq = seq, index = idx, step = step, alive = true,
		startClock = os.clock(), cleanups = {}, prev = prev,
	}
	session = s
	recent[seq] = s
	task.delay(3, function() recent[seq] = nil end)
	if Vfx.bladeBegin then Vfx.bladeBegin(step) end
	if actor then actor:shift(-2.5) end -- law 12: before the swing the weight goes onto the back foot
	if actor and not step.finisher then -- the legs load about 0.07 s before the strike starts (the push-off comes with the strike)
		task.delay(math.max(step.windupTime - 0.07, 0), function()
			if s.alive and actor then actor:loadLegs() end
		end)
	end

	local target = pickTarget(aim)
	s.target = target
	s.dir = target and target.dir or aim

	local prevAuto = hum.AutoRotate
	hum.AutoRotate = false
	table.insert(s.cleanups, function()
		if hum then hum.AutoRotate = prevAuto end
	end)
	local turnUntil = s.startClock + step.windupTime + step.strikeTime
	local function hook(dt)
		if root and root.Parent and os.clock() < turnUntil then
			turnToward(s.dir, rad(CONFIG.TurnSpeed) * dt)
		else
			Rig.clearTurnHook(hook)
		end
	end
	Rig.setTurnHook(hook)
	table.insert(s.cleanups, function()
		Rig.clearTurnHook(hook)
	end)

	table.insert(s.cleanups, Sfx.swing(step, idx, Timing[3].rollMax))
	if not actor then
		-- (no rig: the swing still runs on the server)
	elseif step.finisher then
		actor:playFinisher(step, function() onStrike(s) end)
	else
		actor:playSwing(step, function() onStrike(s) end)
	end
	if idx == 1 then
		Cam.fovHold(-1.8, step.windupTime + 0.02) -- hit 1: the view tightens a little during the startup, the punch-in comes on the hit
		Cam.sweep(-0.8, 0.3, -0.3, step.windupTime) -- the view leans away with the coil (the cut then sweeps it back the other way)
		Cam.pushHold(-0.25, step.windupTime) -- and drifts back a little: room for the punch-in
	end
	if idx == 2 then
		Cam.fovHold(1.6, step.windupTime + 0.02) -- hit 2: the view opens a little while you crouch, then it snaps tight on the upward cut
		Cam.sweep(0.8, -0.5, 0.3, step.windupTime) -- the view sinks and leans with the crouch
		Cam.pushHold(0.2, step.windupTime)
	end
	if step.finisher then
		-- gathering power: the view tightens and darkens a little during the windup
		Cam.fovHold(-5, step.windupTime + 0.02)
		Cam.pushHold(0.4, step.windupTime + 0.02)
		Cam.shake(0.1)
		Cam.post({ tint = 0.25 })
	end

	local total
	if step.finisher then -- roll + hold + slam + a safety margin (the slam message ends it earlier)
		total = step.windupTime + Timing[3].rollMax + step.holdTime + step.slamTime + 1.0
	else
		total = step.windupTime + step.strikeTime + step.followTime + CONFIG.SessionExtra + step.hitStop
	end
	task.delay(total, function() endSession(s) end)
	return s
end

-- hit 3 is running (crouch, roll, catch, slam): clicks do nothing. Otherwise the click goes to the Server, which is busy, refuses it
-- and the Client cancels the roll (even a short roll against a near enemy).
local function finisherRunning(): boolean
	return session ~= nil and session.alive and session.step ~= nil and session.step.finisher == true
end

local blinkLock = false -- true while the Z skill cuts an enemy: a click cannot break the sequence
local function fireSwing()
	if not alive() or not actor then return end
	if finisherRunning() or blinkLock then return end
	local now = os.clock()
	local idx = comboIndex + 1
	if comboIndex >= #COMBO or now - comboClock > CONFIG.ComboReset then
		idx = 1
	end
	if idx == #COMBO and now < finisherReadyAt then idx = 1 end -- hit 3 is recharging: the combo starts over with hit 1
	if idx == #COMBO then finisherReadyAt = now + Timing[3].cooldown end
	if idx == 1 then comboCycle += 1 end
	local step = Anim.stepFor(idx, comboCycle) -- the motion alternates from one combo to the next
	seqCounter += 1
	local seq = seqCounter
	local aim = aimDirection()
	local prev = { readyAt = readyAt, comboIndex = comboIndex, comboClock = comboClock }
	comboIndex = idx
	comboClock = now
	readyAt = now + step.nextAt
	startSwing(seq, idx, step, aim, prev)
	attackRemote:FireServer(aim, seq)
end

local function onActivated()
	if not alive() or not actor then return end
	if finisherRunning() or blinkLock then return end
	local now = os.clock()
	if now >= readyAt then
		fireSwing()
		return
	end
	-- input buffer: keep one click that arrives just before the next swing is allowed
	local nextIdx = comboIndex + 1
	if comboIndex >= #COMBO or now - comboClock > CONFIG.ComboReset then
		nextIdx = 1
	end
	local window = (nextIdx == #COMBO) and CONFIG.BufferFinisher or CONFIG.Buffer
	if readyAt - now <= window then
		if queued then pcall(task.cancel, queued) end
		queued = task.delay(readyAt - now + CONFIG.BufferMargin, function()
			queued = nil
			if alive() then fireSwing() end
		end)
	end
end

local function stopEverything()
	if queued then
		pcall(task.cancel, queued)
		queued = nil
	end
	endSession(session)
end

-- victims and feedback -------------------------------------------------------
-- BODY SPLIT (hit 3): the cut at chest height; the upper body slides apart along the cut and lifts a little, then settles back together.
-- Not real mesh cutting: the Waist joint (Motor6D) gets a temporary offset that follows the user's 3-section curve (fast rise, slow settle).
local SPLIT_TIME, SPLIT_UP, SPLIT_SIDE = 0.9, 0.85, 0.55
local function bodySplit(model: Model, dir: Vector3)
	local lower = model:FindFirstChild("LowerTorso")
	local upper = model:FindFirstChild("UpperTorso")
	local waist = upper and upper:FindFirstChild("Waist")
	if not (lower and waist and waist:IsA("Motor6D")) then return end
	local flat = Vector3.new(dir.X, 0, dir.Z)
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.zAxis
	local c0 = waist.C0
	local t = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		t += math.min(dt, 1 / 20)
		if t >= SPLIT_TIME or not waist.Parent then
			conn:Disconnect()
			if waist.Parent then waist.C0 = c0 end
			return
		end
		local h = curve3(t / SPLIT_TIME)
		local world = Vector3.new(0, SPLIT_UP * h, 0) + flat * (SPLIT_SIDE * h)
		waist.C0 = c0 + lower.CFrame:VectorToObjectSpace(world)
	end)
end
bodySplit = guard(bodySplit)


-- BLOOD DROPS: a few dark red drops leave the wound. In the air a drop is stretched along its flight (pulled out by speed, held
-- together by surface tension). They vanish when they reach the floor.
local function bloodDrops(model: Model, dir: Vector3, I: number)
	local r = model:FindFirstChild("HumanoidRootPart")
	if not r then return end
	local rp = Vfx.exRay({ model })
	local fl = workspace:Raycast(r.Position, Vector3.new(0, -30, 0), rp)
	if not fl then return end
	local floorY = fl.Position.Y + 0.03
	local flat = Vector3.new(dir.X, 0, dir.Z)
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.zAxis
	for _ = 1, IS_MOBILE and 2 or 4 do
		local sz = 0.14 + math.random() * 0.12
		local drop = Instance.new("Part")
		drop.Name = "DarkBlood"
		drop.Shape = Enum.PartType.Ball
		drop.Anchored, drop.CanCollide, drop.CanQuery, drop.CanTouch, drop.CastShadow = true, false, false, false, false
		drop.Material = Enum.Material.SmoothPlastic
		drop.Color = aerial(oklch(0.36 + math.random() * 0.06, 0.16, 22), r.Position)
		drop.Size = Vector3.new(sz, sz, sz)
		local pos = r.Position + Vector3.new((math.random() - 0.5) * 0.8, 0.4 + math.random() * 0.8, (math.random() - 0.5) * 0.8)
		local vel = flat * (3 + 4 * I + math.random() * 3) + Vector3.new((math.random() - 0.5) * 3, 2 + math.random() * 3, (math.random() - 0.5) * 3)
		drop.CFrame = CFrame.new(pos)
		drop.Parent = workspace
		local born = os.clock()
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			dt = math.min(dt, 1 / 30)
			vel += Vector3.new(0, -55 * dt, 0)
			vel *= math.exp(-0.6 * dt)
			pos += vel * dt
			local sp = vel.Magnitude
			-- stretched along the flight: longer when faster, thinner to keep the volume
			local age = os.clock() - born
			local st = 1 + math.min(sp * 0.05, 1.2) + 0.25 * math.sin(42 * age) * math.exp(-6 * age) -- law 13: a drop rings like a bell, the surface tension pulls it round again
			drop.Size = Vector3.new(sz / math.sqrt(st), sz / math.sqrt(st), sz * st)
			drop.CFrame = CFrame.lookAt(pos, pos + (sp > 0.1 and vel or Vector3.zAxis))
			if pos.Y <= floorY then -- it reaches the floor and is gone
				conn:Disconnect()
				drop:Destroy()
				return
			end
		end)
	end
end
bloodDrops = guard(bloodDrops)

-- CHAIN COLLISION (law 19, Newton's cradle, VISUAL ONLY): a thrown enemy that passes close to other characters hands them part of
-- its momentum: each one it touches (within 4.5 studs) gets a hit reaction away from the flight direction, about half as strong.
-- The Server is not involved, so no damage and no real push: it only looks like they were bumped.
local function chainBump(model: Model, dir: Vector3)
	local r = model:FindFirstChild("HumanoidRootPart")
	if not r then return end
	local hit = {}
	local flat = Vector3.new(dir.X, 0, dir.Z)
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.zAxis
	local t0 = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if os.clock() - t0 > 0.9 or not r.Parent then
			conn:Disconnect()
			return
		end
		local op = OverlapParams.new()
		op.FilterType = Enum.RaycastFilterType.Exclude
		op.FilterDescendantsInstances = { model, char }
		for _, part in workspace:GetPartBoundsInRadius(r.Position, 4.5, op) do
			local m = part:FindFirstAncestorOfClass("Model")
			if m and not hit[m] and m:FindFirstChildOfClass("Humanoid") then
				hit[m] = true
				local rt = m:FindFirstChild("HumanoidRootPart")
				if rt then
					local away = Vector3.new(rt.Position.X - r.Position.X, 0, rt.Position.Z - r.Position.Z)
					away = away.Magnitude > 0.1 and away.Unit or flat
					pcall(HitReact.play, m, "chop", (away + flat * 0.5).Unit, 0.6, { strength = 0.5 })
				end
			end
		end
	end)
end
chainBump = guard(chainBump)

-- SAFETY NET: after a throw, whatever the hit effects may have left on the target is removed for good: the white/red body glow (Highlight),
-- the red light, the hit pictures that are still shown and the blink of the body. (Several hits one after the other on the same enemy restart
-- these effects and can leave one of them half way, which showed as a red patch on the enemy.)
local function cleanTarget(model: Model)
	local flashFx = model:FindFirstChild("DarkHitFlash")
	if flashFx then flashFx:Destroy() end
	for _, fx in { fxByModel[model], fxByModelZ[model], fxByModelZC[model] } do -- (the normal set and the two sets of the Z skill)
		if fx.light then fx.light.Brightness = 0 end
		for _, L in fx.layers or {} do
			L.token += 1 -- stops a layer that is still running
			L.bb.Enabled = false
			L.img.ImageTransparency = 1
		end
	end
	model:SetAttribute("DarkBlink", (model:GetAttribute("DarkBlink") or 0) + 1) -- stops a blink that is still running
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.LocalTransparencyModifier = 0 end
	end
end

local function reactAll(targets: any, kind: string, tint: Tint?)
	for _, t in targets do
		if typeof(t.model) == "Instance" and t.model.Parent then
			HitReact.play(t.model, kind, t.dir, t.power, { strength = t.strength, chained = t.chained })
			if not tint then -- (the Z skill has no red blood drops)
				bloodDrops(t.model, typeof(t.dir) == "Vector3" and t.dir or Vector3.zAxis, typeof(t.strength) == "number" and t.strength or 0.6)
			end
			-- the hit effect on the enemy is called here (not from inside the body reaction), so it also plays when the body reaction cannot
			local d = typeof(t.dir) == "Vector3" and t.dir.Magnitude > 0.01 and t.dir or Vector3.zAxis
			local ok, err = pcall(Vfx.hitTarget, t.model, kind, d, t.strength, tint)
			if not ok then warn("[DarkSword] hit effect:", err) end
		end
	end
end

local function applyHitStop(s: Session, duration: number)
	if duration <= 0 then return end
	if not Rig.freeze(duration) then return end -- no stacking
	-- TIME DILATION: the effect clock slows to 8 % while the world is frozen, then eases back to 1 (so bits hang in the air with the enemy)
	Vfx.timeScale = 0.08
	-- TENSION: the picture is frozen but the camera trembles a little (pressure building), then the release pushes forward
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < duration do
			Cam.shake(0.02)
			task.wait(1 / 30)
		end
		Cam.push(0.3)
		Cam.fov(1.5)
	end)
	task.delay(duration, function()
		local t0 = os.clock()
		local conn
		conn = RunService.Heartbeat:Connect(function()
			local a = math.clamp((os.clock() - t0) / 0.18, 0, 1)
			Vfx.timeScale = 0.08 + 0.92 * a * a
			if a >= 1 then
				Vfx.timeScale = 1
				conn:Disconnect()
			end
		end)
	end)
	if actor then actor:recoil() end
	Cam.fovHold(-2.5, duration + 0.05) -- punch-in while the world is frozen
	local ctl = s.lungeCtl
	if ctl then
		ctl.freeze(true)
		task.delay(duration, function() ctl.freeze(false) end)
	end
end

local function onFeedback(kind: string, seq: number, a: any, b: any)
	if kind == "ack" then
		local s = recent[seq]
		if s and a and a ~= s.index then
			comboIndex = a -- the swing already played; only resync the counter
		end
	elseif kind == "reject" then
		local s = recent[seq]
		if not s then return end
		recent[seq] = nil
		if seq == seqCounter then
			comboIndex = s.prev.comboIndex
			comboClock = s.prev.comboClock
			if (a == "cooldown" or a == "busy") and b then
				readyAt = os.clock() + b
			else
				readyAt = s.prev.readyAt
			end
		end
		if s.alive and session == s and actor then
			actor:cancel(CONFIG.RejectBlend)
			endSession(s)
		end
	elseif kind == "hit" then
		-- a = targets, b = combo index
		local s = recent[seq]
		local step = (s and s.step) or COMBO[b] or COMBO[1] -- the variant that was really played
		-- TIMING: the sword touches the enemy at the END of the strike in the animation (startClock + windup + strike).
		-- Everything the player sees and feels (body reaction, star, light, camera, hit stop) waits for that frame; if the message
		-- came later than that (ping), it plays at once.
		local contactAt = s and (s.startClock + step.windupTime + step.strikeTime) or os.clock()
		local wait = math.clamp(contactAt - os.clock(), 0, 0.2)
		task.delay(wait, function()
			if not equipped then return end
			reactAll(a, step.reaction) -- body reaction first: nothing below may block it
			Vfx.hit(char, 1)
			local I = strongest(a)
			-- ACTION AND REACTION (law 3): the cut pushes the enemy forward and you a little backward (the push dies out quickly; a running dash overrides it)
			if root and root.Parent then
				local back = -root.CFrame.LookVector
				local flat = Vector3.new(back.X, 0, back.Z)
				if flat.Magnitude > 0.01 then
					local kick = (b == 2 and 6 or 5) * (0.7 + 0.6 * I)
					task.delay(0.03, function()
						if root.Parent then root.AssemblyLinearVelocity += flat.Unit * kick end
					end)
				end
			end
			Vfx.rumble(0.35 * (0.6 + I), 0.5, 0.08) -- law 185: a short pad rumble with the hit (nothing on keyboard or phone)
			if (step.slide or step.launch) and typeof(a) == "table" then -- hit 1: the enemy skids, the floor is scraped; hit 2: floor bits are kicked up at take-off
				for _, t in a do
					if typeof(t) == "table" and typeof(t.model) == "Instance" and t.model.Parent and typeof(t.dir) == "Vector3" then
						local It = typeof(t.strength) == "number" and t.strength or 0.5
						scrapeFx(t.model, t.dir, It, step.launch, false)
						speedLines(t.model, t.dir, It, step.launch == true, step.launch and 0.9 or 0.75, step.launch and 4 or 3) -- a few thin lines only
					end
				end
			end
			Cam.play(scaleCam(step.hitCam, 0.6 + 0.8 * I)) -- a close, chained, strong hit shakes the view more
			do -- the view springs BACK a moment after the hit (hit 1 snapped down, so it comes up; hit 2 snapped up, so it comes down)
				local reb = ({ { 0.09, 1.2, -0.4, -0.7 }, { 0.1, -1.0, 0.5, 0.5 } })[b]
				if reb then
					local kk = 0.6 + 0.8 * I
					task.delay(reb[1] + step.hitStop * 0.5, function()
						if equipped then Cam.kick(reb[2] * kk, reb[3] * kk, reb[4] * kk) end
					end)
				end
			end
			if b == 2 then -- the enemy is cut UP: the view tilts up with it and backs off a little so it is not cut at the top of the screen
				Cam.sweep(0, 3.4, 0, 0.7)
				Cam.pushHold(-0.9, 0.7)
				Cam.fovHold(3, 0.7)
			end
			if typeof(a) == "table" and typeof(a[1]) == "table" and typeof(a[1].dir) == "Vector3" then
				Cam.impulse(a[1].dir, 0.34 * (a[1].power or 1) * (0.7 + 0.6 * I)) -- the view gets pushed the way the enemy flies, more for a stronger hit
			end
			local sg, sd, sdl = 1, 0, 0
			if typeof(a) == "table" and typeof(a[1]) == "table" and typeof(a[1].model) == "Instance" then
				local tr = a[1].model:FindFirstChild("HumanoidRootPart")
				if tr then sg, sd, sdl = soundAtten(tr.Position) end
			end
			pcall(roomProbe)
			if sdl > 0 then task.delay(sdl, Sfx.impact, b, sg, sd, I) else Sfx.impact(b, sg, sd, I) end
			if Vfx.bladeHit then Vfx.bladeHit(I) end
			if s and s.alive and session == s then
				applyHitStop(s, step.hitStop * (0.7 + 0.6 * I)) -- stronger hit = longer freeze
			end
		end)
	elseif kind == "grab" then
		-- caught: the roll stops, the sword and the enemy go up; the slam animation starts when the Server's hold time is over
		local step = COMBO[3]
		local s = recent[seq]
		reactAll(a, "slam") -- the chop lands: the enemy is driven down, folds and bounces (the throw follows 0.12 s later)
		Cam.play(step.grabCam)
		Cam.impulse(-Vector3.yAxis, 0.5) -- the view is shoved down with the chop
		Vfx.rumble(0.9, 0.6, 0.15)
		Rig.freeze(0.07) -- a short hit stop at the moment of contact
		do
			local sg, sd = 1, 0
			if typeof(a) == "table" and typeof(a[1]) == "table" and typeof(a[1].model) == "Instance" then
				local tr = a[1].model:FindFirstChild("HumanoidRootPart")
				if tr then sg, sd = soundAtten(tr.Position) end
			end
			pcall(roomProbe)
			Sfx.grab(sg, sd)
		end
		-- the hold, frame by frame: the view slowly tightens, a small shake at every beat of the light, the enemy's light pulses faster and faster
		Cam.fovHold(-6, step.holdTime + 0.05)
		Cam.pushHold(0.5, step.holdTime + 0.05)
		for i = 1, 5 do
			local at = step.holdTime * (i / 5) ^ 1.3 -- the beats come closer together
			task.delay(at * 0.95, function()
				if equipped then Cam.shake(0.05 + 0.03 * i) end
			end)
		end
		if typeof(a) == "table" then
			for _, t in a do
				if typeof(t) == "table" and typeof(t.model) == "Instance" and t.model.Parent then
					Vfx.holdPulse(t.model, step.holdTime)
				end
			end
		end
		if s and s.alive and session == s then
			if s.lungeCtl then s.lungeCtl.stop() end
				s.caught = true
			if actor then
				actor:catch()
				task.delay(step.holdTime, function()
					if equipped and actor and s.alive and session == s then
						s.slamStart = os.clock()
						actor:slam()
						if char then
							-- two slash discs, a beat apart (the 3 degree tilt is the same for both): the cut, then its after-image
							Vfx.strike(char, 1)
							task.delay(0.05, function()
								if equipped and char.Parent then Vfx.strike(char, 3) end
							end)
						end
						-- the fall: speed lines streak UP behind the enemy as it is driven down (downward flight = lines trail above it)
						if typeof(a) == "table" then
							for _, t in a do
								if typeof(t) == "table" and typeof(t.model) == "Instance" and t.model.Parent then
									speedLines(t.model, Vector3.yAxis, 0.9, true, 1.1, nil, true)
								end
							end
						end
					end
				end)
			end
		end
	elseif kind == "slam" then
		-- the hit: the biggest freeze of the combo, then the view drops hard
		local step = COMBO[3]
		local s = recent[seq]
		-- ENERGY (1/2 m v^2) and SHOCK WAVES: the harder the throw the bigger the camera hit; the camera feels the P wave (up and down) first and the
		-- slower S wave (side to side) a moment later, each after a delay that grows with the distance to the impact
		local Eslam, dcam = 1, 20
		if typeof(a) == "table" and typeof(a[1]) == "table" then
			local st = typeof(a[1].strength) == "number" and a[1].strength or 0.8
			Eslam = math.clamp(0.6 + 0.6 * st, 0.7, 1.3) -- the Server's impact strength stands in for the throw energy
			local hrp = typeof(a[1].model) == "Instance" and a[1].model:FindFirstChild("HumanoidRootPart")
			local camNow = workspace.CurrentCamera
			if hrp and camNow then dcam = (hrp.Position - camNow.CFrame.Position).Magnitude end
		end
		-- everything of the throw starts the moment the Server says the enemy is thrown (it is already flying then), so picture, sound and
		-- physics stay together: no waiting for the hit stop of the animation
		task.delay(0, function()
		if not equipped then return end
		pcall(roomProbe)
		Sfx.blast()
		task.delay(math.max(step.hitStop - 2 / 30, 0), function() Cam.post({ dim = 1 }) end) -- CONTRAST (law 174): the picture dips for 2 frames just before the big flash, so the flash looks brighter
		Vfx.rumble(1, 0.6, 0.18) -- law 185: the pad rumbles with the slam
		local freeze = step.hitStop
		Rig.freeze(freeze)
		if actor then actor:recoil(1.7) end -- the blade carries on through the freeze: a heavier follow-through
		Cam.fovHold(-5, freeze + 0.02)
		Cam.shake(0.2 * Eslam)
		Cam.speedHold(0.6) -- the lens opens and the view is pulled forward while the enemy flies (the same look as the dash)
		if typeof(a) == "table" and typeof(a[1]) == "table" and typeof(a[1].dir) == "Vector3" then
			Cam.impulse(a[1].dir, 0.55) -- and shoved the way it flies
		end
		task.delay(0.03, function()
			if equipped then Cam.play(step.slamCam) end
		end)
		task.delay(0.45, function() -- the enemy flies away: the view eases back
			if equipped then Cam.play(step.releaseCam) end
		end)
		reactAll(a, "fling") -- cut and thrown: snap, tumble, landing (see HitReact "fling")
		if typeof(a) == "table" then
			for _, t in a do
				if typeof(t) == "table" and typeof(t.model) == "Instance" and t.model.Parent then
					local I3 = typeof(t.strength) == "number" and t.strength or 0.8
					task.delay(0.1, function() -- in flight: it can bump into others on the way
						if t.model.Parent then chainBump(t.model, typeof(t.dir) == "Vector3" and t.dir or Vector3.zAxis) end
					end)
					bodySplit(t.model, typeof(t.dir) == "Vector3" and t.dir or Vector3.zAxis)
						task.delay(2.2, function() -- everything is over by now: nothing of the hit may stay on the enemy
							if t.model.Parent then cleanTarget(t.model) end
						end)
					task.delay(0, function() -- the flight starts: sparks from the contact point and the ghosts of the body
						if t.model.Parent then
						launchBurst(t.model, typeof(t.dir) == "Vector3" and t.dir or Vector3.zAxis, I3)
							afterimages(t.model)
					end
					end)
					if typeof(t.dir) == "Vector3" then
						task.delay(0, function() -- the enemy skids across the floor when it lands; the lines follow it all the way
							if t.model.Parent then
								scrapeFx(t.model, t.dir, I3, nil, true)
								flightLines(t.model, I3, function() -- the lines follow the enemy all the way to the floor; when it lands (seen from its real flight): bits of the floor and a shake
								if not t.model.Parent then return end
								slamBurst(t.model, I3) -- bits of the floor
								landingBurst(t.model, I3) -- the picture and the sparks
								task.delay(0.8, function() if t.model.Parent then cleanTarget(t.model) end end) -- (they are over by then)
								local lr = t.model:FindFirstChild("HumanoidRootPart")
								if equipped and lr then Cam.shakeAt(lr.Position, 0.25 * I3, 70) end
							end)
							end
						end)
					end
				end
			end
		end
		local tP = 0.08 + math.min(dcam / 260, 0.3) -- P wave: up and down, fast
		local tS = tP + math.min(dcam / 150, 0.5) -- S wave: side to side, slower
		task.delay(tP, function()
			if equipped then Cam.shake(0.25 * Eslam) Cam.kick(1.2 * Eslam, 0, 0) end
		end)
		task.delay(tS, function()
			if equipped then Cam.shake(0.2 * Eslam) Cam.kick(0, 0.9 * Eslam, 0.7 * Eslam) end
		end)
		local sum, n = Vector3.zero, 0
		if typeof(a) == "table" then
			for _, t in a do
				local m = typeof(t) == "table" and t.model
				if typeof(m) == "Instance" and m:IsDescendantOf(workspace) then
					local mr = m:FindFirstChild("HumanoidRootPart")
					if mr and root and (mr.Position - root.Position).Magnitude < 60 then
						sum += mr.Position
						n += 1
					end
				end
			end
		end
		if n > 0 then Cam.shakeAt(sum / n, 0.3, 60) end
		if s and s.alive and session == s then
			task.delay(0.5, function() endSession(s) end)
		end
		end)
	elseif kind == "miss" then
		Sfx.miss()
		Cam.kick(-0.5, 0, 0)
		local s = recent[seq]
		if s and s.index == 2 then comboIndex = 0 end -- hit 2 missed: the combo starts over with hit 1 (the Server does the same)
		if s and s.alive and s.step.finisher and session == s and actor then
			endSession(s) -- also stops the roll
			actor:recover(0.15) -- nothing caught: stand up fast, the roll is also an escape
		end
	end
end

feedbackRemote.OnClientEvent:Connect(onFeedback)

-- equip / unequip -------------------------------------------------------------
local stateConn: RBXScriptConnection?
local prevStates: { FallingDown: boolean, Ragdoll: boolean }? -- the "never fall over" guard (see onEquipped)
-- BLADE EFFECTS: built once on the Handle. The attachment sits along the LONGEST side of the Handle (assumed to be the blade).
--  * a red PointLight that breathes at rest and spikes on a swing
local BLADE_TIP_AT = 0.5 -- the sharp tip, as a fraction of the Handle length from its centre (0.5 = the very end)

local blade: {
	built: boolean, light: PointLight?, swingUntil: number, spikeAt: number, spikeUntil: number,
	conn: RBXScriptConnection?, lightSpring: Spring?, reflect0: number,
} = { built = false, light = nil, swingUntil = 0, spikeAt = 0, spikeUntil = 0, conn = nil, lightSpring = nil, reflect0 = 0 }

local function buildBlade()
	if blade.built and handle.Parent then return end
	local sz = handle.Size
	local axis, len = Vector3.xAxis, sz.X
	if sz.Y >= sz.X and sz.Y >= sz.Z then
		axis, len = Vector3.yAxis, sz.Y
	elseif sz.Z >= sz.X and sz.Z >= sz.Y then
		axis, len = Vector3.zAxis, sz.Z
	end
	local tip = handle:FindFirstChild("DarkBladeTip") :: Attachment?
	if not tip then
		tip = Instance.new("Attachment")
		tip.Name = "DarkBladeTip"
		tip.Parent = handle
	end
	tip.Position = axis * (len * BLADE_TIP_AT)
	-- no trail, beam or particles on the blade: remove any left over from an older version (or placed by hand)
	for _, d in handle:GetDescendants() do
		if d:IsA("Trail") or d:IsA("Beam") or d:IsA("ParticleEmitter") then d:Destroy() end
	end
	local l = (handle:FindFirstChild("DarkBladeLight") or Instance.new("PointLight")) :: PointLight
	l.Name = "DarkBladeLight"
	l.Color = oklch(0.62, 0.2, 22)
	l.Range = 9
	l.Shadows = false
	l.Brightness = 0
	l.Parent = handle
	blade.light = l
	blade.reflect0 = handle.Reflectance
	blade.built = true
end

local function bladeSetOn(on: boolean)
	local light = blade.light
	if not (blade.built and light) then return end
	if not on then
		light.Brightness = 0
		handle.Reflectance = blade.reflect0
		if blade.conn then
			blade.conn:Disconnect()
			blade.conn = nil
		end
		return
	end
	if blade.conn then return end
	local tipAtt = handle:FindFirstChild("DarkBladeTip") :: Attachment?
	local lastTip: Vector3? = tipAtt and tipAtt.WorldPosition
	local speedS = 0
	local lastRot: CFrame? = nil
	local omegaS = 0
	local spring = newSpring(9, 0.45, 0.5)
	blade.lightSpring = spring
	blade.conn = RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		local cam = workspace.CurrentCamera
		local window = now < blade.swingUntil -- the whole attack: from the start of the wind-up to the end of the follow-through
		local sp = 0
		if tipAtt and lastTip and dt > 0 then
			local p = tipAtt.WorldPosition
			local vel = (p - lastTip) / dt
			sp = vel.Magnitude
			lastTip = p
			bladeVelNow = vel
			-- law 9 (Doppler): the pitch of the whoosh follows the speed of the tip TOWARD the camera: f' = f * c / (c - v_r).
			-- c = 600 studs/s is a game-sized speed of sound (the real one would change the pitch too little to hear).
			if cam and window and sp > 5 then
				local toCam = cam.CFrame.Position - p
				if toCam.Magnitude > 0.5 then
					local vr = vel:Dot(toCam.Unit)
					if Sfx.doppler then Sfx.doppler(math.clamp(600 / (600 - vr), 0.85, 1.2), sp) end -- (an older SwordSfx without this function must not stop the loop)
				end
			end
		end
		speedS += (sp - speedS) * math.min(dt * 18, 1)
		-- law 24 (torque and lever): the speed of the tip from the TURNING of the handle is v = omega * r (omega = angle turned per second,
		-- r = distance from the grip to the tip). The slash is driven by half the measured tip speed and half this rotational speed.
		local rotNow = handle.CFrame.Rotation
		if lastRot and dt > 0 then
			local _, ang = (rotNow * lastRot:Inverse()):ToAxisAngle()
			omegaS += (ang / dt - omegaS) * math.min(dt * 18, 1)
		end
		lastRot = rotNow
		bladeSpeedNow = 0.5 * speedS + 0.5 * omegaS * (handle.Size.Magnitude * 0.5)
		if window and cam then -- the camera feels the swing (energy, banking): see Cam.energy
			Cam.energy(bladeSpeedNow, cam.CFrame:VectorToObjectSpace(bladeVelNow).X)
		end
		-- light: breathes at rest, spikes at the hit along the 3-section curve
		local breathe = 0.5 + 0.2 * math.sin(now * 3)
		local spike = 0
		if now < blade.spikeUntil then
			spike = 2.2 * curve3((now - blade.spikeAt) / (blade.spikeUntil - blade.spikeAt))
		end
		-- law 17 (Fresnel): a surface reflects more the more it is seen edge-on. Reflectance = 0.04 + 0.5 * (1 - |cos|)^4, cos = angle between
		-- the view direction and the flat side (the thinnest axis) of the blade. Law 18 (anisotropic gleam): when the flat side turns to face
		-- the camera exactly while the blade moves fast, a short gleam adds to the light.
		if cam then
			local sz = handle.Size
			local cf = handle.CFrame
			local n = cf.XVector
			if sz.Y <= sz.X and sz.Y <= sz.Z then
				n = cf.YVector
			elseif sz.Z <= sz.X and sz.Z <= sz.Y then
				n = cf.ZVector
			end
			local cosv = math.abs(n:Dot((cam.CFrame.Position - handle.Position).Unit))
			local refl = 0.04 + 0.5 * (1 - cosv) ^ 4
			if math.abs(refl - handle.Reflectance) > 0.004 then handle.Reflectance = refl end -- skip tiny writes
			spike += math.clamp((cosv - 0.93) / 0.07, 0, 1) * math.clamp(speedS / 30, 0, 1) * 1.6
		end
		-- the light follows its target through a spring (a little underdamped): a spike overshoots and settles, it never jumps
		light.Brightness = math.max(stepSpring(spring, (breathe + spike), dt), 0)
	end)
end

-- BLADE VIBRATION (law 10, resonance): after a hit the blade rings like a struck bar: a damped oscillation theta(t) = A * e^(-z*w*t) * sin(w*t)
-- (about 22 Hz, dying out in ~0.35 s) around the point of the grip, so the sword shivers a little in the hand and then is still.
local vibrating = false
Vfx.bladeHit = function(I: number?)
	if not (char and not vibrating) then return end
	local hand = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
	local weld = hand and hand:FindFirstChild("RightGrip")
	if not (weld and weld:IsA("JointInstance")) then return end
	vibrating = true
	local base = weld.C1
	local amp = math.rad(2.2) * (0.6 + 0.8 * (I or 0.6))
	local w, z = 2 * math.pi * 22, 9
	local t = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		t += math.min(dt, 1 / 30)
		if t > 0.4 or not weld.Parent then
			conn:Disconnect()
			if weld.Parent then weld.C1 = base end
			vibrating = false
			return
		end
		weld.C1 = base * CFrame.Angles(amp * math.exp(-z * t) * math.sin(w * t), 0, amp * 0.6 * math.exp(-z * t) * math.cos(w * t))
	end)
end
Vfx.bladeHit = guard(Vfx.bladeHit)

Vfx.bladeBegin = function(step: StepT)
	if not blade.built then return end
	local total = (step.windupTime or 0.3) + (step.strikeTime or 0.1) + (step.followTime or 0.1) + 0.35
	blade.swingUntil = os.clock() + total
end
Vfx.bladeBegin = guard(Vfx.bladeBegin)

-- called at the hit moment: sparks and the light spike
Vfx.bladeSwing = function(index: number)
	if not blade.built then return end
	local now = os.clock()
	blade.spikeAt = now - 0.05
	blade.spikeUntil = now + (index == 3 and 0.5 or 0.32)
end
Vfx.bladeSwing = guard(Vfx.bladeSwing)

-- BLINK CUT (Z skill) bridge: BlinkCutClient sends "dash" (the blink starts: from, to), "begin" (an enemy was caught), "slash" (one of the quick
-- cuts), "fling" (the last cut threw the enemy) and "end" through a BindableEvent. Each slash plays hit 1 or hit 2 with the times squeezed so that
-- 15 of them fit in a few seconds, in the colours of the Z skill (cold light instead of crimson), with the effects of the normal hits on the
-- enemy's body and its OWN hit animation (BlinkCutVictim: the enemy shakes harder with every cut, by resonance). The last cut is a clean finish like
-- a normal hit (the same kinds of effects, cold colours, its own flying pose for the enemy); its knockback is Server.lua's, the same as hit 3.
-- While it runs the normal attack is locked (blinkLock).

local function blinkConfig(): { [string]: number }
	local m = tool:FindFirstChild("BlinkCutConfig")
	if m and m:IsA("ModuleScript") then
		local ok, result = pcall(require, m)
		if ok and typeof(result) == "table" then return result end
	end
	return { SlashGap = 0.11 } -- the same number as BlinkCutConfig
end

local blinkVictim: { model: Model, handle: any }? = nil
local function victimAnim(victim: Model): any
	local current = blinkVictim
	if current and current.model == victim then return current.handle end
	if current then
		current.handle.finish()
		blinkVictim = nil
	end
	local m = tool:FindFirstChild("BlinkCutVictim")
	if not (m and m:IsA("ModuleScript")) then return nil end
	local okRequire, module = pcall(require, m)
	if not okRequire then return nil end
	local okNew, made = pcall(module.new, victim, blinkConfig().SlashGap)
	if okNew and made then
		blinkVictim = { model = victim, handle = made }
		return made
	end
	return nil
end

-- THE SOUND of the Z skill has a mixer of its own (BlinkCutSfx: buses, ducking, a flurry that rises in pitch and brightness)
local zsfxModule: any = nil
local function zsfx(): any
	if zsfxModule == nil then
		zsfxModule = false -- (a failure is reported once and the normal sounds are used instead)
		local m = tool:FindFirstChild("BlinkCutSfx")
		if m and m:IsA("ModuleScript") then
			local ok, result = pcall(require, m)
			if ok then
				zsfxModule = result
			else
				warn("[DarkSword] BlinkCutSfx could not start:", result)
			end
		else
			warn("[DarkSword] the tool has no ModuleScript named BlinkCutSfx")
		end
	end
	return zsfxModule or nil
end

-- THE SIGNATURE ON THE SCREEN (BlinkCutHud): the name of the skill and the counter of the cuts
local zhudModule: any = nil
local function zhud(): any
	if zhudModule == nil then
		zhudModule = false
		local m = tool:FindFirstChild("BlinkCutHud")
		if m and m:IsA("ModuleScript") then
			local ok, result = pcall(require, m)
			if ok then zhudModule = result else warn("[DarkSword] BlinkCutHud could not start:", result) end
		end
	end
	return zhudModule or nil
end

-- THE CAMERA of the Z skill: one thing seen from three places, so that the camera, the sound and the effects of every beat start in the same frame
local blinkCount = 0 -- the number of the cut in the flurry
-- The camera work follows the rules of film: (1) every move EASES in and out (nothing starts or stops dead: the springs of the camera do that, and
-- long moves are made of two halves that go there and come back); (2) the camera ANTICIPATES and OVERSHOOTS (it gathers before a fast move, goes a
-- little past, and settles); (3) one slow big move carries the shot, small quick moves only ride on it; (4) the roll follows the direction of the
-- movement like a car in a curve (banking); (5) the beat of the cuts is felt in the camera in the same frame as in the sound and the picture.
local function blinkCamDash(from: Vector3, to: Vector3)
	-- the blink: the lens opens while you travel (the view is pulled forward and banks into the dash), the arrival is a PUNCH-IN that overshoots and
	-- then settles with a small breath (the view opens a little, then rests)
	local cam = workspace.CurrentCamera
	local side = if cam and (to - from).Magnitude > 0.1 then cam.CFrame.RightVector:Dot((to - from).Unit) else 0
	Cam.speedHold(0.35)
	Cam.fovHold(7, BLINK_DASH_TIME + 0.1)
	Cam.pushHold(1.2, BLINK_DASH_TIME + 0.1)
	Cam.sweep(-side * 1.2, 0.4, -side * 3, BLINK_DASH_TIME + 0.12)
	task.delay(BLINK_DASH_TIME, function()
		if not equipped then return end
		Cam.kick(-0.8, 0, 0)
		Cam.fovHold(-5.5, 0.22)
		Cam.shake(0.08)
		Cam.pushHold(-0.5, 0.25) -- the camera steps back as the body stops: room for the flurry
	end)
	task.delay(BLINK_DASH_TIME + 0.28, function() -- the breath after the punch-in
		if equipped then Cam.fov(1.2) end
	end)
end
local function blinkCamFlurry()
	-- the flurry: ONE slow move carries the shot (the view tightens and leans in during the whole flurry, and it drifts to one side in the first half
	-- and to the other in the second, with a slow roll); the kicks of the cuts only ride on it
	local c = blinkConfig()
	local total = (c.Slashes or 25) * (c.SlashGap or 0.11) + 0.2
	local half = total / 2
	Cam.fovHold(-6, total)
	Cam.pushHold(0.8, total)
	Cam.sweep(1.8, 0.7, -1.2, half)
	task.delay(half, function()
		if equipped then Cam.sweep(-1.8, 0.4, 1.2, half) end
	end)
end
local function blinkCamCut(index: number, p: number)
	-- one cut: a very small kick that goes the way of the cut (hit 1 and hit 2 go opposite ways, like the push on the enemy), growing with the flurry,
	-- a tiny pulse of the dolly (the camera "breathes" with the beat), and a firmer accent on every fifth cut
	-- (a LONG fovHold runs during the whole flurry: the accents use Cam.fov, a spring kick, so they do not cancel it)
	local sign = if index == 2 then -1 else 1
	local k = 0.6 + 0.8 * p
	Cam.kick(-0.1 * k, 0.08 * k * sign, 0.06 * k * sign)
	Cam.push(0.04 * k)
	Cam.shake(0.006 + 0.014 * p)
	if blinkCount % 5 == 0 then -- every fifth cut: an accent
		Cam.shake(0.045)
		Cam.fov(-1.4)
	end
end

-- the hit effect on the enemy's body in the Z colours; a failure is reported (it used to be swallowed silently)
local function blinkHitFx(victim: Model, kind: string, dir: Vector3, strength: number)
	local ok, err = pcall(Vfx.hitTarget, victim, kind, dir, strength, BLINK_TINT)
	if not ok then warn("[DarkSword] Z hit effect (" .. kind .. "):", err) end
end

local function blinkSlash(index: number, victim: Model?)
	if not (equipped and actor and char and root and root.Parent) then return end
	local base = COMBO[index]
	if not base then return end
	local step: StepT = table.clone(base :: any)
	-- one cut fits exactly into the gap between two cuts (32 % wind-up, 36 % strike, 32 % follow-through), so the next cut never chops off the
	-- follow-through of this one: the 25 cuts flow into each other instead of jerking
	local gap = blinkConfig().SlashGap or 0.11
	step.windupTime, step.strikeTime, step.followTime = gap * 0.32, gap * 0.36, gap * 0.32
	step.hold, step.rebound, step.hitStop = 0, 0.02, 0
	local vroot = victim and victim:FindFirstChild("HumanoidRootPart")
	local dir = root.CFrame.LookVector
	if vroot and vroot:IsA("BasePart") then
		local flat = Vector3.new(vroot.Position.X - root.Position.X, 0, vroot.Position.Z - root.Position.Z)
		if flat.Magnitude > 0.01 then
			dir = flat.Unit
			root.CFrame = CFrame.lookAt(root.Position, root.Position + dir) -- always face the enemy
		end
	end
	blinkCount += 1
	local n = blinkCount
	local p = math.clamp(n / (blinkConfig().Slashes or 25), 0, 1) -- how far into the flurry (0 .. 1)
	local zs = zsfx()
	if zs then zs.whoosh(root, index, p, n) else Sfx.swing(step, index, 0) end -- the whoosh starts the wind-up time BEFORE the strike, like the whoosh of the normal hits
	if Vfx.bladeBegin then Vfx.bladeBegin(step) end
	actor:shift(if index == 1 then -1.2 else 1.2) -- the weight rocks from one foot to the other with the cuts (hit 1 and hit 2 go opposite ways)
	actor:playSwing(step, function()
		if not equipped then return end
		Vfx.strike(char, index, BLINK_TINT)
		if victim and victim.Parent then
			blinkHitFx(victim, "blink", dir, 0.55) -- the star, the body flash and blink, the bits and the light, all cold
			local anim = victimAnim(victim) -- the hit animation that only this skill has
			if anim then anim.hit(index, 0.6, dir) end
			pcall(speedLines, victim, dir, 0.55, index == 2, if index == 2 then 0.9 else 0.75, if index == 2 then 4 else 3, nil, BLINK_TINT) -- the thin lines of the normal hit, cold
			cutLines(victim, 2, 7, BLINK_TINT) -- the cut lines of the flurry
		end
		Vfx.hit(char, 1, BLINK_TINT)
		if zs then zs.impact(root, index, p, n) else Sfx.impact(index, 1, 0, 0.55) end
		local hud = zhud()
		if hud then hud.count(n, blinkConfig().Slashes or 25) end -- the counter punches in the same frame as the cut -- the impact, the effects above and the camera below all start in this one frame
		if Vfx.bladeHit then Vfx.bladeHit(0.55) end
		blinkCamCut(index, p)
		Vfx.rumble(0.12 + 0.2 * p, 0.2, 0.05)
	end)
end
blinkSlash = guard(blinkSlash)


-- THE LAST CUT is the ULTIMATE MOVE of the skill. It is staged like one:
--   * LETTERBOX bars frame the picture and the scenery loses its colour (already, from the flurry): "this is the big moment";
--   * the WIND-UP (0.32 s) is long: the camera steps far back and the lens narrows, the whole mix drops to a hush (expectation), the sword is raised
--     in hit 1's chop, slowed down;
--   * the STRIKE: the world STOPS (a long hit stop) and the effects crawl in slow motion (time dilation); a hard punch-in, a flash and bloom;
--     three slash discs, one after the other (the cut, its after-image, a ring around you), the biggest star, many cut lines, sparks, speed lines;
--   * the blast of the finish sounds, the camera is shocked (P wave, then S wave), then it pulls out in one long move and the world comes back.
-- The enemy is pushed away only a few studs (Server.lua): all of this is show, not knockback.
local lastFinishAt = -10
local function blinkFinish(victim: Model?)
	if not (equipped and actor and victim and victim.Parent and char and root and root.Parent) then return end
	if os.clock() - lastFinishAt < 0.5 then return end -- it can arrive by two ways: it plays once
	lastFinishAt = os.clock()
	local vroot = victim:FindFirstChild("HumanoidRootPart")
	if not (vroot and vroot:IsA("BasePart")) then return end
	local flat = Vector3.new(vroot.Position.X - root.Position.X, 0, vroot.Position.Z - root.Position.Z)
	local dir = if flat.Magnitude > 0.01 then flat.Unit else root.CFrame.LookVector
	local held = blinkVictim -- the shaking of the held enemy lets go
	blinkVictim = nil
	if held then held.handle.finish() end
	Cam.focus(0.6)
	local windup = blinkConfig().FinishWindup or 0.32
	local hud = zhud()
	if hud then
		hud.finish()
	end
	local zs = zsfx()
	if zs then
		zs.whoosh(root, 1, 0.2, 1)
		zs.hush(windup) -- the quiet before the blow
	end

	local step: StepT = table.clone(COMBO[1] :: any)
	step.windupTime, step.strikeTime, step.followTime = windup, 0.08, 0.2
	step.hold, step.rebound, step.hitStop = 0.08, 0.08, 0.22
	local cam = workspace.CurrentCamera
	local side = if cam then cam.CFrame.RightVector:Dot(dir) else 0
	-- the wind-up: the camera steps far back and the lens narrows (the gathering of power)
	Cam.pushHold(-3.2, windup) -- the camera drifts far back and low: the shot opens up
	Cam.fovHold(-4, windup)
	Cam.sweep(side * 2.2, -1.4, side * 1.8, windup)
	Cam.shake(0.05) -- a faint tremor builds while the power gathers
	if Vfx.bladeBegin then Vfx.bladeBegin(step) end
	actor:shift(-3)
	actor:playSwing(step, function()
		if not equipped then return end
		-- the world stops and the effects crawl (time dilation); both come back together
		Rig.freeze(step.hitStop)
		Vfx.timeScale = 0.08
		task.delay(step.hitStop, function()
			local t0 = os.clock()
			local conn: RBXScriptConnection? = nil
			conn = RunService.Heartbeat:Connect(function()
				local a = math.clamp((os.clock() - t0) / 0.3, 0, 1)
				Vfx.timeScale = 0.08 + 0.92 * a * a
				if a >= 1 and conn then
					conn:Disconnect()
					conn = nil
				end
			end)
		end)
		Cam.post({ dim = 1 })
		-- three discs, one after the other: the cut, its after-image, the ring
		Vfx.strike(char, 1, BLINK_TINT)
		task.delay(0.05, function() if equipped and char.Parent then Vfx.strike(char, 3, BLINK_TINT) end end)
		task.delay(0.1, function() if equipped and char.Parent then Vfx.strike(char, 4, BLINK_TINT) end end)
		task.delay(0.16, function() if equipped and char.Parent then Vfx.strike(char, 1, BLINK_TINT) end end) -- a second, wider slash wave
		task.delay(0.24, function() if equipped and char.Parent then Vfx.strike(char, 4, BLINK_TINT) end end)
		if victim.Parent then
			blinkHitFx(victim, "fling", dir, 1) -- the biggest star of the skill
			task.delay(0.05, function() if victim.Parent then blinkHitFx(victim, "blink", dir, 0.9) end end)
			pcall(HitReact.play, victim, "chop", dir, 1, { strength = 1 }) -- the body reaction of a hit: it is pushed back
			pcall(speedLines, victim, dir, 0.9, false, 1.2, IS_MOBILE and 5 or 10, nil, BLINK_TINT)
			cutLines(victim, 14, 18, BLINK_TINT)
			task.delay(0.12, function() if victim.Parent then blinkHitFx(victim, "fling", dir, 1.15) cutLines(victim, 10, 16, BLINK_TINT) end end)
			task.delay(0.26, function() if victim.Parent then blinkHitFx(victim, "blink", dir, 1) end end)
			launchBurst(victim, dir, 1.4, BLINK_TINT)
			scrapeFx(victim, dir, 0.8, nil, false, BLINK_TINT)
			task.delay(1.4, function() if victim.Parent then cleanTarget(victim) end end)
		end
		Vfx.hit(char, 1, BLINK_TINT)
		pcall(roomProbe)
		if zs then
			zs.finishHit(root)
			zs.finish(root) -- the blast of the finish
		else
			Sfx.impact(1, 1, 0, 1)
		end
		if Vfx.bladeHit then Vfx.bladeHit(1) end
		Vfx.rumble(1, 0.8, 0.2)
		-- the camera: a hard punch-in held through the hit stop, a kick, a flash and bloom, a shove along the enemy; then the shock waves arrive
		-- (the P wave up and down, the slower S wave side to side) and the camera pulls out in one long move while the colour of the world returns
		Cam.fovHold(-11, step.hitStop + 0.14) -- a violent punch-in
		Cam.kick(-3.2, 0, -1.2 * side)
		Cam.shake(0.6)
		Cam.impulse(dir, 1.0)
		Cam.post({ flash = 0.7, bloom = 0.6, blur = 0.3 })
		Cam.focus(0)
		task.delay(0.1, function() if equipped then Cam.shake(0.4) Cam.kick(2.2, 0, 0) end end)
		task.delay(0.28, function() if equipped then Cam.shake(0.32) Cam.kick(0, 1.6, 1.2) end end)
		for i = 1, 8 do -- the rumble after the blow: small shakes that die out
			task.delay(0.35 + 0.1 * i, function() if equipped then Cam.shake(0.14 * (1 - i / 9)) end end)
		end
		task.delay(step.hitStop + 0.05, function()
			if not equipped then return end
			Cam.speedHold(1.0)
			Cam.pushHold(-3.8, 1.3) -- a long crane pull-out that shows the enemy and the whole place
			Cam.fovHold(10, 1.3)
			Cam.sweep(-side * 4, 2.0, -side * 2.6, 1.4)
		end)
	end)
end
blinkFinish = guard(blinkFinish)


-- everything of the skill is put back (the end of the sequence, or the sword is put away)
local function blinkReset(hard: boolean?) -- hard = the sword is put away: the screen is cleared at once (a normal end lets the counter finish its burst)
	blinkLock = false
	Cam.focus(0)
	local hud = zhud()
	if hud and hard then hud.clear() end
	do
		local v = blinkVictim
		blinkVictim = nil
		if v then v.handle.finish() end
	end
	if blade.light then blade.light.Color = oklch(0.62, 0.2, 22) end -- the blade's own light is crimson again
	task.delay(1.5, function() Cam.setTintColor(nil) end) -- (after the last tint pulse has faded) the tint pulse is rose again
end

local blinkBridge = (tool:FindFirstChild("BlinkBridge") or Instance.new("BindableEvent")) :: BindableEvent
blinkBridge.Name = "BlinkBridge"
blinkBridge.Parent = tool
blinkBridge.Event:Connect(function(kind: string, index: number?, victim: Model?, from: Vector3?, to: Vector3?)
	if kind == "dash" then
		if from and to and char then
			blinkTrail(from, to, char)
			blinkCutLine(from, to) -- the delayed cut: the line of the air that was cut, a moment after the body is gone
			blinkCamDash(from, to) -- the camera starts in the same frame as the effects and the sound of the blink
		end
	elseif kind == "begin" then
		blinkLock = true
		blinkCount = 0
		blinkCamFlurry()
		Cam.focus(1) -- the scenery loses its colour while the flurry runs: the eye stays on the fight
		local hud = zhud()
		if hud then hud.title() end -- the name of the skill drops in
		Cam.setTintColor(BLINK.ice) -- the tint pulse of the camera: pale rose, the colour of the normal attack
		if blade.light then blade.light.Color = BLINK.cyan end -- the blade's own light glows a little pinker while the skill runs
	elseif kind == "slash" then
		if index then blinkSlash(index, victim) end
	elseif kind == "finish" then
		blinkFinish(victim)
	elseif kind == "end" then
		blinkReset()
		if actor then actor:recover(0.25) end
	end
end)

-- the finish ALSO listens to the skill's RemoteEvent itself, so it does not depend on BlinkCutClient passing it on (the one that arrives first
-- plays it, the other is ignored)
task.spawn(function()
	local remote = tool:WaitForChild("BlinkCut", 10)
	if not (remote and remote:IsA("RemoteEvent")) then return end
		remote.OnClientEvent:Connect(function(kind: any, _id: any, value: any)
			if kind == "finish" and typeof(value) == "Instance" and value:IsA("Model") then blinkFinish(value) end
		end)
end)


-- CLOTH / HAIR INERTIA (law 3): accessories (hair, capes, hats' ribbons) are rigid and welded, so they never lag. Here each one gets a
-- spring offset: when the body accelerates, the accessory is left behind (it feels the opposite force, F = -m a), then swings back and
-- settles (an underdamped spring, f = 3.5 Hz, z = 0.3). The offset is clamped to 0.35 studs so nothing leaves the body.
local cloth = { list = {}, conn = nil }
local function clothStart(character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end
	cloth.list = {}
	for _, acc in character:GetChildren() do
		if acc:IsA("Accessory") then
			local h = acc:FindFirstChild("Handle")
			local weld = h and h:FindFirstChildOfClass("Weld")
			if weld and weld.Part0 then
				table.insert(cloth.list, { weld = weld, base = weld.C0, sx = newSpring(3.5, 0.3), sy = newSpring(3.5, 0.3), sz = newSpring(3.5, 0.3) })
			end
		end
	end
	local lastV = rootPart.AssemblyLinearVelocity
	if cloth.conn then cloth.conn:Disconnect() end
	cloth.conn = RunService.Heartbeat:Connect(function(dt)
		if dt <= 0 or not rootPart.Parent then return end
		local v = rootPart.AssemblyLinearVelocity
		local acc = (v - lastV) / dt
		lastV = v
		local push = -acc * 0.012 -- the accessory lags against the acceleration
		push = Vector3.new(math.clamp(push.X, -0.35, 0.35), math.clamp(push.Y, -0.35, 0.35), math.clamp(push.Z, -0.35, 0.35))
		-- CENTRIFUGAL (law 14): when the body turns (angular speed w), a loose part is thrown outward by w x (w x r) (outward = away from the axis)
		local w = rootPart.AssemblyAngularVelocity
		if w.Magnitude > 20 then w = w.Unit * 20 end
		for _, a in cloth.list do
			if a.weld.Parent and a.weld.Part0 then
				local rel = a.weld.Part0.Position - rootPart.Position
				local cf = -w:Cross(w:Cross(rel)) * 0.012
				local total = push + Vector3.new(math.clamp(cf.X, -0.25, 0.25), math.clamp(cf.Y, -0.25, 0.25), math.clamp(cf.Z, -0.25, 0.25))
				total = Vector3.new(math.clamp(total.X, -0.4, 0.4), math.clamp(total.Y, -0.4, 0.4), math.clamp(total.Z, -0.4, 0.4))
				local local_ = a.weld.Part0.CFrame:VectorToObjectSpace(total)
				a.weld.C0 = a.base * CFrame.new(stepSpring(a.sx, local_.X, dt), stepSpring(a.sy, local_.Y, dt), stepSpring(a.sz, local_.Z, dt))
			end
		end
	end)
end
local function clothStop()
	if cloth.conn then cloth.conn:Disconnect() cloth.conn = nil end
	for _, a in cloth.list do
		if a.weld.Parent then a.weld.C0 = a.base end
	end
	cloth.list = {}
end

local drawToken = 0

local function onEquipped()
	local c = tool.Parent
	if not c or not c:IsA("Model") then return end
	local h = c:FindFirstChildOfClass("Humanoid")
	local r = c:FindFirstChild("HumanoidRootPart")
	if not h or not r then return end
	char, hum, root = c, h, r
	rayParams.FilterDescendantsInstances = { c }
	overlapParams.FilterDescendantsInstances = { c }
	equipped = true
	buildBlade()
	bladeSetOn(true)
	clothStart(c)
	local a = Rig.equip(c)
	if not a then return end
	if not equipped then
		a:unequip()
		return
	end
	actor = a
	-- the sword is DRAWN FROM THE BACK: the sword in the hand stays invisible (only on this screen) while the hand reaches for the back; the back copy
	-- (BackSword script) must already be hidden from the Equipped event on, and the hand sword appears as the blade is pulled forward
	a:playDraw()
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then d.LocalTransparencyModifier = 1 end
	end
	drawToken += 1
	local myDraw = drawToken
	task.delay(0.26, function()
		-- a newer equip/unequip owns the sword now: no reveal from a stale timer
		if myDraw ~= drawToken or not equipped then return end
		for _, d in tool:GetDescendants() do
			if d:IsA("BasePart") then d.LocalTransparencyModifier = 0 end
		end
	end)
	-- YOU NEVER FALL OVER: the falling-down and ragdoll states are off while the sword is out, and if something still pushes the character
	-- into one of them it is put back on its feet at once
	prevStates = {
		FallingDown = h:GetStateEnabled(Enum.HumanoidStateType.FallingDown),
		Ragdoll = h:GetStateEnabled(Enum.HumanoidStateType.Ragdoll),
	}
	h:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	h:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	stateConn = h.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.FallingDown or new == Enum.HumanoidStateType.Ragdoll then
			h:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end)
	Cam.enable()
	pcall(roomProbe)
	Sfx.equip()
	diedConn = hum.Died:Connect(stopEverything)
end

local function onUnequipped()
	blinkReset(true)
	equipped = false
	drawToken += 1
	bladeSetOn(false)
	clothStop()
	stopEverything()
	if stateConn then
		stateConn:Disconnect()
		stateConn = nil
	end
	if hum and hum.Parent and prevStates then
		hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, prevStates.FallingDown)
		hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, prevStates.Ragdoll)
	end
	prevStates = nil
	if diedConn then
		diedConn:Disconnect()
		diedConn = nil
	end
	if actor then
		actor:unequip()
		actor = nil
	end
	Cam.disable()
	comboIndex, comboClock, readyAt = 0, -100, 0
	Sfx.equip()
end

tool.Equipped:Connect(function()
	task.spawn(onEquipped)
end)
tool.Unequipped:Connect(onUnequipped)
tool.Destroying:Connect(function() -- the tool vanished (death, reset): give the camera back too
	Cam.disable()
end)
tool.Activated:Connect(onActivated)
