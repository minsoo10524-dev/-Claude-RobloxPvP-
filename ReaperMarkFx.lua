--!strict
-- ModuleScript "ReaperMarkFx" (parent: Tool "TrueKatana")
-- The visual effects of the X skill. Built ONLY from the pictures the project already has (the hit sheets, the big star, the floor sheet) and from stones.
-- Colours are the palette of the normal attack: white -> pale -> rose -> crimson (nothing else), so the skill looks like it belongs to the sword.
--   SHEETS: the pictures are sprite SHEETS, played one cell at a time (a clip frame shows one cell of a sheet that is cols x rows times bigger):
--       flash  10198434999  4 x 4  the diagonal flash with sparks (cells 4-15)
--       burst  10198439352  4 x 4  the star with flying shards (cells 1-13): the main hit picture
--       glint  14622697144  4 x 4  small glints that flare and go out (cells 0-6)
--       star   12402888086  one big star picture (it can be turned freely)
--       floor  17000892071  4 x 4  a ring on the floor that opens, swirls and fades (cells 1-15)
--   sprite(): one animated picture on a part (it FOLLOWS the part, so a picture on a body travels with the body), growing like a blast wave
--       (radius ~ t^(2/5), Sedov-Taylor: very fast at first, then slower), its colour going from white to rose to crimson as it ages.
--   hit(): the heavy hit on a body part: the big star turning for a heartbeat + the flash sheet + the burst sheet, three layers that overlap
--   flicker(): glints and flashes that keep flaring on the parts of a body (the body is "cut" by light while it is dragged)
--   groundMark / seismic : floor rings (Sedov-Taylor growth); a quake with its P and S waves for the camera
--   debris: stones thrown with their own physics: gravity, air drag (more on small stones), bounce, friction, spin; "hot" stones glow white-rose and cool
--       (Newton's law) to stone grey
--   camera: shake, quake (P wave: a short jolt at 50 Hz; S wave: 0.1 s later, rolling at 13 Hz, much stronger, dying out), fovPunch, flash
-- Everything is made on the owner's client only.

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local WHITE = Color3.fromRGB(255, 241, 241)
local PALE = Color3.fromRGB(255, 198, 196)
local ROSE = Color3.fromRGB(251, 129, 127)
local CRIMSON = Color3.fromRGB(219, 43, 51)
local TAU = math.pi * 2

type Sheet = { image: string, cols: number, rows: number, frames: number, start: number }
local SHEETS: { [string]: Sheet } = {
	flash = { image = "rbxassetid://10198434999", cols = 4, rows = 4, frames = 16, start = 4 },
	burst = { image = "rbxassetid://10198439352", cols = 4, rows = 4, frames = 14, start = 1 },
	glint = { image = "rbxassetid://14622697144", cols = 4, rows = 4, frames = 7, start = 0 },
	star = { image = "rbxassetid://12402888086", cols = 1, rows = 1, frames = 1, start = 0 },
	floor = { image = "rbxassetid://17000892071", cols = 4, rows = 4, frames = 16, start = 1 },
}

local Fx = {}

local ignore: { Instance } = {}
function Fx.setIgnore(list: { Instance })
	ignore = list
end

local function rayParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	return params
end

local function floorAt(pos: Vector3): Vector3
	local hit = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -60, 0), rayParams())
	return if hit then hit.Position else pos
end

local function anchorPart(cf: CFrame, size: Vector3): Part
	local p = Instance.new("Part")
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Parent = workspace
	return p
end

-- the picture shown is cell i of a sheet: the image is cols x rows times bigger than its clip frame and moved so that cell i is in the frame
local function showCell(img: ImageLabel, sheet: Sheet, i: number)
	img.Position = UDim2.fromScale(-(i % sheet.cols), -(i // sheet.cols))
end

--------------------------------------------------------------------------------
-- The animated picture
--------------------------------------------------------------------------------
-- colour over life: white -> pale -> rose -> crimson
local function lifeColor(u: number): Color3
	return WHITE:Lerp(PALE, math.clamp(u / 0.6, 0, 1)) -- clean: white, going to a pale rose, no red at the end
end

-- sheetName: "flash" / "burst" / "glint" / "star"; adornee: the part it sits on (it follows it); offset: in world space; size in studs; life in seconds
function Fx.sprite(sheetName: string, adornee: BasePart, offset: Vector3, size: number, life: number, spin: number?, onTop: boolean?, delay: number?)
	local sheet = SHEETS[sheetName]
	if not sheet or not adornee.Parent then return end
	task.spawn(function()
		if delay and delay > 0 then task.wait(delay) end
		if not adornee.Parent then return end
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromScale(size, size)
		gui.StudsOffsetWorldSpace = offset
		gui.AlwaysOnTop = onTop == true
		gui.LightInfluence = 0
		gui.Adornee = adornee
		gui.Parent = adornee
		local single = sheet.cols * sheet.rows == 1
		local clip = Instance.new("Frame")
		clip.BackgroundTransparency = 1
		clip.Size = UDim2.fromScale(1, 1)
		clip.AnchorPoint = Vector2.new(0.5, 0.5)
		clip.Position = UDim2.fromScale(0.5, 0.5)
		clip.ClipsDescendants = not single -- a single picture is not cropped, so it can be turned
		clip.Parent = gui
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(sheet.cols, sheet.rows)
		img.Image = sheet.image
		img.ImageColor3 = WHITE
		img.Parent = clip
		local turn = if single then math.random(0, 359) else 0
		local t0 = os.clock()
		while gui.Parent do
			local u = (os.clock() - t0) / life
			if u >= 1 then break end
			local cell = sheet.start + math.min(math.floor(u * (sheet.frames - sheet.start)), sheet.frames - sheet.start - 1)
			showCell(img, sheet, cell)
			local grow = 0.3 + 0.7 * u ^ 0.4 -- a blast wave grows as t^(2/5)
			gui.Size = UDim2.fromScale(size * grow, size * grow)
			img.ImageColor3 = lifeColor(u)
			img.ImageTransparency = if u < 0.8 then 0 else (u - 0.8) / 0.2
			if single then clip.Rotation = turn + (spin or 0) * u * life end
			RunService.Heartbeat:Wait()
		end
		gui:Destroy()
	end)
end

-- the heavy hit on a body part: the big star for a heartbeat, the flash and the burst over it, all on the body (on top, so the body does not hide them)
function Fx.hit(part: BasePart, size: number)
	Fx.sprite("star", part, Vector3.zero, size * 1.25, 0.16, 140, true)
	Fx.sprite("flash", part, Vector3.zero, size * 1.0, 0.34, 0, true)
	Fx.sprite("burst", part, Vector3.zero, size * 1.5, 0.5, 0, true, 0.03)
end

-- a SLASH: two flash pictures one after the other (the cut and its echo) and a burst behind them, on the body that was cut
function Fx.slash(part: BasePart, size: number)
	Fx.sprite("flash", part, Vector3.zero, size * 1.2, 0.3, 0, true)
	Fx.sprite("flash", part, Vector3.new(0.9, 0.5, 0), size * 0.85, 0.3, 0, true, 0.04)
	Fx.sprite("burst", part, Vector3.zero, size * 0.9, 0.4, 0, true, 0.06)
end

-- a hit picture standing at a point of the world (not on a body)
function Fx.starBurst(pos: Vector3, size: number)
	local anchor = anchorPart(CFrame.new(pos), Vector3.one * 0.2)
	Debris:AddItem(anchor, 1.2)
	Fx.sprite("star", anchor, Vector3.zero, size * 1.2, 0.18, 120, false)
	Fx.sprite("flash", anchor, Vector3.zero, size, 0.36, 0, false)
	Fx.sprite("burst", anchor, Vector3.zero, size * 1.45, 0.5, 0, false, 0.03)
end

-- glints and flashes that keep flaring on the parts of a body for `seconds` (rate per second): the body is cut by light as it is dragged
function Fx.flicker(model: Instance, seconds: number, rate: number, size: number)
	task.spawn(function()
		local list: { BasePart } = {}
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Size.Magnitude > 0.5 then table.insert(list, d) end
		end
		if #list == 0 then return end
		local t0 = os.clock()
		while os.clock() - t0 < seconds and model.Parent do
			local part = list[math.random(#list)]
			if part.Parent then
				local off = Vector3.new((math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2)
				local pick = math.random()
				Fx.sprite(if pick < 0.5 then "glint" elseif pick < 0.8 then "flash" else "burst", part, off, size * (0.6 + math.random() * 0.8), 0.28, 0, true)
			end
			task.wait(1 / rate)
		end
	end)
end

--------------------------------------------------------------------------------
-- The floor ring (a sheet; Sedov-Taylor growth)
--------------------------------------------------------------------------------
function Fx.groundMark(center: Vector3, diameter: number, color: Color3, growTime: number, spin: number)
	local floor = floorAt(center)
	local p = anchorPart(CFrame.new(floor.X, floor.Y + 0.1, floor.Z) * CFrame.Angles(0, math.random() * TAU, 0), Vector3.new(diameter * 0.3, 0.05, diameter * 0.3))
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(512, 512)
	gui.Parent = p
	local clip = Instance.new("Frame")
	clip.BackgroundTransparency = 1
	clip.Size = UDim2.fromScale(1, 1)
	clip.ClipsDescendants = true
	clip.Parent = gui
	local sheet = SHEETS.floor
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(sheet.cols, sheet.rows)
	img.Image = sheet.image
	img.ImageColor3 = color
	img.Parent = clip
	local baseCF = p.CFrame
	task.spawn(function() -- SEDOV-TAYLOR: the radius of a blast wave grows as t^(2/5)
		local t0 = os.clock()
		local fade = 1.4 * growTime + 0.35 -- seconds the whole ring lives
		while p.Parent do
			local now = os.clock() - t0
			local u = math.clamp(now / growTime, 0, 1)
			local d = diameter * (0.3 + 0.7 * u ^ 0.4)
			p.Size = Vector3.new(d, 0.05, d)
			p.CFrame = baseCF * CFrame.Angles(0, math.rad(spin * 60) * u, 0)
			local life = now / fade
			if life >= 1 then break end
			showCell(img, sheet, sheet.start + math.min(math.floor(life * (sheet.frames - sheet.start)), sheet.frames - sheet.start - 1))
			RunService.Heartbeat:Wait()
		end
		p:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- Debris: its own small physics, no collisions with players
--------------------------------------------------------------------------------
type Stone = { part: Part, pos: Vector3, vel: Vector3, rot: CFrame, axis: Vector3, spin: number, size: number, age: number, life: number, rest: boolean, heat: number, base: Color3, glowing: boolean }
local stones: { Stone } = {}
local stepper: RBXScriptConnection? = nil
local MAX_STONES = 320
local RESTITUTION = 0.38 -- the share of the speed that is kept in a bounce
local FRICTION = 0.72 -- the share of the sliding speed that is kept in a bounce

local function step(dt: number)
	dt = math.min(dt, 1 / 30)
	local params = rayParams()
	local g = workspace.Gravity
	local i = 1
	while i <= #stones do
		local s = stones[i]
		s.age += dt
		if s.age >= s.life or not s.part.Parent then
			s.part:Destroy()
			stones[i] = stones[#stones]
			stones[#stones] = nil
		else
			if not s.rest then
				s.vel += Vector3.new(0, -g, 0) * dt -- real gravity
				s.vel -= s.vel * (0.0016 / math.max(s.size, 0.4)) * s.vel.Magnitude * dt -- air drag grows with the square of the speed and matters more for small stones
				local delta = s.vel * dt
				local hit = if delta.Magnitude > 1e-4 then workspace:Raycast(s.pos, delta + delta.Unit * (s.size * 0.4), params) else nil
				if hit then
					local n = hit.Normal
					s.pos = hit.Position + n * (s.size * 0.4)
					local vn = n * s.vel:Dot(n)
					s.vel = (s.vel - vn) * FRICTION - vn * RESTITUTION
					s.spin *= 0.7
					if s.vel.Magnitude < 4 then
						s.rest = true
						s.vel = Vector3.zero
					end
				else
					s.pos += delta
				end
				s.rot = CFrame.fromAxisAngle(s.axis, s.spin * dt) * s.rot
			end
			s.part.CFrame = CFrame.new(s.pos) * s.rot
			if s.heat > 0 then -- fresh stones are hot: white-rose, cooling to crimson to stone (Newton's law, 0.9 s), in the colours of the sword
				local h = s.heat * math.exp(-s.age / 0.9)
				if h > 0.04 then
					s.part.Color = s.base:Lerp(CRIMSON:Lerp(WHITE, h), math.min(h * 1.6, 1))
					if not s.glowing then
						s.glowing = true
						s.part.Material = Enum.Material.Neon
					end
				elseif s.glowing then
					s.glowing = false
					s.part.Material = Enum.Material.Slate
					s.part.Color = s.base
				end
			end
			local fade = s.life - s.age
			if fade < 0.5 then -- the stone shrinks away at the end of its life
				s.part.Size = Vector3.one * s.size * math.max(fade / 0.5, 0.05)
			end
			i += 1
		end
	end
	if #stones == 0 and stepper then
		stepper:Disconnect()
		stepper = nil
	end
end

function Fx.debris(center: Vector3, count: number, power: number, upBias: number, push: Vector3?, heat: number?)
	local floor = floorAt(center)
	for _ = 1, count do
		if #stones >= MAX_STONES then break end
		local angle = math.random() * TAU
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local size = 0.5 + math.random() ^ 2.2 * 1.9 -- many small stones, a few big chunks
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = true
		p.Material = Enum.Material.Slate
		local shade = 60 + math.random() * 55
		local baseColor = Color3.fromRGB(shade, shade * 0.96, shade * 1.04)
		p.Color = baseColor
		p.Size = Vector3.new(size, size * (0.6 + math.random() * 0.5), size * (0.7 + math.random() * 0.5))
		local pos = floor + out * (1 + math.random() * 4) + Vector3.new(0, 0.5, 0)
		p.CFrame = CFrame.new(pos)
		p.Parent = workspace
		local speed = power * (0.35 + math.random() * 0.75) / (0.6 + size * 0.4) -- big chunks are slower
		table.insert(stones, {
			part = p, pos = pos, rot = CFrame.Angles(math.random() * TAU, math.random() * TAU, 0),
			vel = out * speed + Vector3.new(0, power * upBias * (0.5 + math.random() * 0.7), 0) + (if push then push * power * (0.5 + math.random() * 0.8) else Vector3.zero),
			axis = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit,
			spin = 6 + math.random() * 14, size = size, age = 0, life = 2.4 + math.random() * 1.2, rest = false, heat = 0, base = baseColor, glowing = false, -- (the stones stay stone: no glow, no red)
		})
	end
	if not stepper then stepper = RunService.Heartbeat:Connect(step) end
end

--------------------------------------------------------------------------------
-- The camera: shake, seismic waves, a quick change of the field of view, a flash
--------------------------------------------------------------------------------
local trauma = 0
local quakeAmp, quakeAt = 0, 0
local bound = false
local punch = 0 -- degrees added to the field of view right now
local punchApplied = 0
local punchTween: Tween? = nil
local SEED = math.random() * 100

local function render(dt: number)
	local cam = workspace.CurrentCamera
	if not cam then return end
	trauma = math.max(0, trauma - dt * 1.3)
	local shake = trauma * trauma
	if shake > 0.0005 then
		local t = os.clock() * 30
		local nx, ny, nz = math.noise(t, SEED, 0), math.noise(t, SEED, 10), math.noise(t, SEED, 20)
		cam.CFrame = cam.CFrame * CFrame.new(nx * 1.6 * shake, ny * 1.6 * shake, 0) * CFrame.Angles(ny * 0.16 * shake, nx * 0.16 * shake, nz * 0.1 * shake)
	end
	-- SEISMIC WAVES: the fast P wave first (a short sharp jolt up and down, about 50 Hz); the S wave 0.1 s later: sideways and rolling, slower (about 13 Hz),
	-- much stronger, dying out like a damped oscillation
	local age = os.clock() - quakeAt
	if quakeAmp > 0.01 and age < 3 then
		local pitch, roll, yaw, sway = 0, 0, 0, 0
		if age < 0.22 then pitch = quakeAmp * 0.05 * math.sin(age * 320) * (1 - age / 0.22) end
		if age >= 0.1 then
			local a = quakeAmp * math.exp(-(age - 0.1) * 2.4)
			local ph = age * 80
			roll, yaw, sway = 0.07 * a * math.sin(ph), 0.04 * a * math.sin(ph + 1), 0.9 * a * math.sin(ph)
		end
		cam.CFrame = cam.CFrame * CFrame.new(sway, 0, 0) * CFrame.Angles(pitch, yaw, roll)
	end
	cam.FieldOfView += punch - punchApplied
	punchApplied = punch
	if trauma <= 0 and math.abs(punch) < 0.01 and math.abs(punchApplied) < 0.01 and (quakeAmp <= 0.01 or age >= 3) then
		RunService:UnbindFromRenderStep("ReaperMarkCamera")
		bound = false
	end
end

local function bind()
	if not bound then
		bound = true
		RunService:BindToRenderStep("ReaperMarkCamera", Enum.RenderPriority.Camera.Value + 2, render)
	end
end

function Fx.shake(amount: number)
	trauma = math.min(1, math.max(trauma, amount))
	bind()
end

function Fx.quake(amount: number)
	quakeAmp = math.min(amount, 2.0)
	quakeAt = os.clock()
	bind()
end

-- a quake with its two rings on the floor: the P wave ring runs out first and fast, the S wave ring follows, slower and stronger in effect
function Fx.seismic(center: Vector3, size: number, amount: number)
	Fx.groundMark(center, size, WHITE, 0.28, 0.5)
	task.delay(0.1, function() Fx.groundMark(center, size * 0.72, ROSE, 0.55, -0.8) end)
	Fx.quake(amount)
end

-- degrees < 0 narrows the view (a punch-in): quick in, slow out
function Fx.fovPunch(degrees: number)
	bind()
	if punchTween then punchTween:Cancel() end
	local holder = Instance.new("NumberValue")
	holder.Value = 0
	local conn = holder:GetPropertyChangedSignal("Value"):Connect(function()
		punch = holder.Value
	end)
	local into = TweenService:Create(holder, TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = degrees })
	punchTween = into
	into.Completed:Connect(function()
		local out = TweenService:Create(holder, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Value = 0 })
		out.Completed:Connect(function()
			conn:Disconnect()
			holder:Destroy()
			punch = 0
		end)
		out:Play()
	end)
	into:Play()
end

-- a white flash of the whole screen that dies away fast (the moment of a heavy impact)
local grade: ColorCorrectionEffect? = nil
function Fx.flash(amount: number)
	local g = grade
	if not g or not g.Parent then
		g = Instance.new("ColorCorrectionEffect")
		g.Name = "ReaperMarkFlash"
		g.Parent = Lighting
		grade = g
	end
	if not g then return end
	g.Brightness = amount
	TweenService:Create(g, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()
end

return Fx
