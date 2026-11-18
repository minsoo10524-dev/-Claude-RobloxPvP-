--!strict
-- ShiftLock V3 (LocalScript, put it in StarterPlayerScripts). No pictures, logic only.
-- Shift toggles (or holds) an over-the-shoulder camera lock: the character turns with the camera, the camera sits a little to one side of the
-- character, and Q swaps the shoulder.
--
-- PHYSICS USED (every motion is a damped harmonic oscillator, x'' = -w^2 (x - target) - 2 z w x', solved EXACTLY each frame, so it behaves the same
-- at 30 and at 240 frames per second and can never blow up on a long frame):
--   * The camera offset is a spring: it swings to the shoulder with a small overshoot and settles.
--   * The character yaw is a spring that chases the camera yaw along the SHORT way round the circle.
--   * Speed makes the springs stiffer in damping (air drag grows with speed): fast running steadies the camera, standing still lets it breathe.
--   * INERTIA: when the character accelerates, the camera lags behind it a little (a head on a neck), then catches up.
--   * LANDING: a sudden stop of a fall dips the camera (the body absorbs the impact), then it springs back.
--   * FOV: a first-order response (exponential approach) and wider with speed (more of the world flows past the eye).
-- PERFORMANCE: the frame loop is bound only while something is moving; once the lock is off and everything has settled it is unbound again.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
if not player then return end

-- A phone without a keyboard has no Shift key: this script has nothing to do there.
if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then return end

type Config = {
	OFFSET: Vector3, -- camera offset to the shoulder (camera space: x right, y up)
	OFFSET_K: number, -- spring constant of the offset (w = sqrt(k))
	OFFSET_ZETA: number, -- damping ratio of the offset (1 = critical, below 1 = overshoot)
	YAW_K: number,
	YAW_ZETA: number,
	FOV_NORMAL: number,
	FOV_LOCK: number,
	FOV_K: number, -- rate constant of the first-order FOV response (per second)
	FOV_SPEED_GAIN: number, -- extra degrees of FOV at full running speed
	RUN_SPEED: number, -- studs/s that count as "full speed" for the speed effects
	HOLD_MODE: boolean, -- true: Shift must be held, false: Shift toggles
	SPEED_DAMPING: number, -- how much the damping ratio grows at full speed (air drag)
	LAG_GAIN: number, -- studs of camera lag per stud/s^2 of acceleration
	LAG_MAX: number, -- the lag never exceeds this many studs
	LANDING_GAIN: number, -- studs/s of downward kick per stud/s of landing speed
	LANDING_MIN: number, -- falls slower than this (studs/s) do not dip the camera
	BREATH_AMOUNT: number, -- studs of the breathing movement when standing still
	BREATH_HZ: number,
	MAX_DT: number, -- a longer frame is cut to this (a lag spike must not throw the springs around)
	MAX_ERRORS: number, -- after this many frame errors in a row the lock switches itself off
}

local CONFIG: Config = {
	OFFSET = Vector3.new(2, 0.35, 0),
	OFFSET_K = 180,
	OFFSET_ZETA = 0.85,
	YAW_K = 260,
	YAW_ZETA = 0.9,
	FOV_NORMAL = 70,
	FOV_LOCK = 58,
	FOV_K = 6,
	FOV_SPEED_GAIN = 4,
	RUN_SPEED = 16,
	HOLD_MODE = false,
	SPEED_DAMPING = 0.25,
	LAG_GAIN = 0.012,
	LAG_MAX = 0.6,
	LANDING_GAIN = 0.05,
	LANDING_MIN = 25,
	BREATH_AMOUNT = 0.12,
	BREATH_HZ = 0.25,
	MAX_DT = 0.05,
	MAX_ERRORS = 5,
}

local STEP_NAME = "ShiftLockV3"
local PI = math.pi
local BLOCKED_STATES: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Dead] = true, [Enum.HumanoidStateType.Seated] = true, [Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.Ragdoll] = true, [Enum.HumanoidStateType.FallingDown] = true, [Enum.HumanoidStateType.PlatformStanding] = true,
}

--------------------------------------------------------------------------------
-- Springs (exact solution of the damped oscillator)
--------------------------------------------------------------------------------
-- One axis: x and v are measured from the target. Returns the new position and speed after dt seconds.
local function solve(x: number, v: number, target: number, w: number, z: number, dt: number): (number, number)
	local d = x - target
	if z >= 0.999 then -- critical damping: no oscillation
		local e = math.exp(-w * dt)
		local c1 = v + w * d
		return target + (d + c1 * dt) * e, (v - c1 * w * dt) * e
	end
	local wd = w * math.sqrt(1 - z * z)
	local e = math.exp(-z * w * dt)
	local c, s = math.cos(wd * dt), math.sin(wd * dt)
	local b = (v + z * w * d) / wd
	local osc = d * c + b * s
	return target + e * osc, e * (-z * w * osc + wd * (b * c - d * s))
end

type SpringNumber = { x: number, v: number, target: number, w: number, z: number }
type SpringVector = { x: Vector3, v: Vector3, target: Vector3, w: number, z: number }

local function newNumber(k: number, zeta: number, x0: number): SpringNumber
	return { x = x0, v = 0, target = x0, w = math.sqrt(k), z = zeta }
end
local function newVector(k: number, zeta: number, x0: Vector3): SpringVector
	return { x = x0, v = Vector3.zero, target = x0, w = math.sqrt(k), z = zeta }
end

local function stepNumber(s: SpringNumber, zeta: number, dt: number)
	s.x, s.v = solve(s.x, s.v, s.target, s.w, zeta, dt)
end
local function stepVector(s: SpringVector, zeta: number, dt: number)
	local x, v, t = s.x, s.v, s.target
	local nx, vx = solve(x.X, v.X, t.X, s.w, zeta, dt)
	local ny, vy = solve(x.Y, v.Y, t.Y, s.w, zeta, dt)
	local nz, vz = solve(x.Z, v.Z, t.Z, s.w, zeta, dt)
	s.x, s.v = Vector3.new(nx, ny, nz), Vector3.new(vx, vy, vz)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local offsetSpring = newVector(CONFIG.OFFSET_K, CONFIG.OFFSET_ZETA, Vector3.zero)
local yawSpring = newNumber(CONFIG.YAW_K, CONFIG.YAW_ZETA, 0)

local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil
local locked = false
local shoulder = 1 -- 1 = right shoulder, -1 = left
local fov = CONFIG.FOV_NORMAL
local looping = false
local errorCount = 0
local savedAutoRotate = true
local lastVelocity = Vector3.zero
local accelerationFilter = Vector3.zero
local connections: { RBXScriptConnection } = {} -- the permanent ones
local characterConnections: { RBXScriptConnection } = {} -- the ones of the current character

local function disconnectAll(list: { RBXScriptConnection })
	for _, c in list do c:Disconnect() end
	table.clear(list)
end

local function wrapAngle(a: number): number
	return (a + PI) % (2 * PI) - PI
end

local function canRotate(hum: Humanoid): boolean
	return not hum.Sit and not hum.PlatformStand and not BLOCKED_STATES[hum:GetState()]
end

--------------------------------------------------------------------------------
-- Frame loop
--------------------------------------------------------------------------------
local stopLoop: () -> ()

local function frame(dt: number)
	local hum, root = humanoid, rootPart
	local camera = workspace.CurrentCamera
	if not (hum and root and root.Parent and camera) or hum.Health <= 0 then
		stopLoop()
		return
	end
	dt = math.min(dt, CONFIG.MAX_DT)
	if dt <= 0 then return end

	-- another script or a menu may release the mouse: take it back while the lock is on
	if locked and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end

	local velocity = root.AssemblyLinearVelocity
	local speedRatio = math.clamp(Vector3.new(velocity.X, 0, velocity.Z).Magnitude / CONFIG.RUN_SPEED, 0, 1.5)

	-- speed adds damping (air drag grows with speed): fast running steadies the camera
	local drag = CONFIG.SPEED_DAMPING * math.min(speedRatio, 1)

	local target = Vector3.zero
	if locked then
		-- INERTIA: the smoothed acceleration, in camera space, moves the target the other way (the camera lags behind the body)
		local acceleration = (velocity - lastVelocity) / dt
		accelerationFilter += (acceleration - accelerationFilter) * math.min(1, dt * 12)
		local cf = camera.CFrame
		local flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		local forward = if flatLook.Magnitude > 0.01 then flatLook.Unit else Vector3.zAxis
		local lagX = -accelerationFilter:Dot(cf.RightVector) * CONFIG.LAG_GAIN
		local lagZ = accelerationFilter:Dot(forward) * CONFIG.LAG_GAIN -- forward acceleration pushes the camera back (+z is back)
		local breath = math.sin(os.clock() * 2 * PI * CONFIG.BREATH_HZ) * CONFIG.BREATH_AMOUNT * (1 - math.min(speedRatio, 1))
		target = Vector3.new(
			CONFIG.OFFSET.X * shoulder + math.clamp(lagX, -CONFIG.LAG_MAX, CONFIG.LAG_MAX),
			CONFIG.OFFSET.Y + breath,
			CONFIG.OFFSET.Z + math.clamp(lagZ, -CONFIG.LAG_MAX, CONFIG.LAG_MAX)
		)
		-- LANDING: a fall that stops suddenly kicks the offset downward; the spring brings it back
		if lastVelocity.Y < -CONFIG.LANDING_MIN and velocity.Y > lastVelocity.Y + 20 then
			offsetSpring.v -= Vector3.new(0, math.min(-lastVelocity.Y, 80) * CONFIG.LANDING_GAIN * 20, 0)
		end
	else
		accelerationFilter = Vector3.zero
	end
	lastVelocity = velocity

	offsetSpring.target = target
	stepVector(offsetSpring, math.min(CONFIG.OFFSET_ZETA + drag, 1), dt)
	hum.CameraOffset = offsetSpring.x

	-- FOV: first-order response, a little wider with speed
	local targetFov = if locked then CONFIG.FOV_LOCK + CONFIG.FOV_SPEED_GAIN * math.min(speedRatio, 1) else CONFIG.FOV_NORMAL
	fov = targetFov + (fov - targetFov) * math.exp(-CONFIG.FOV_K * dt)
	camera.FieldOfView = fov

	-- the character follows the camera yaw (the short way round the circle) through a spring
	if locked and canRotate(hum) then
		local look = camera.CFrame.LookVector
		local cameraYaw = math.atan2(-look.X, -look.Z)
		yawSpring.target = yawSpring.x + wrapAngle(cameraYaw - yawSpring.x)
		stepNumber(yawSpring, math.min(CONFIG.YAW_ZETA + drag * 0.5, 1), dt)
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yawSpring.x, 0)
	end

	-- everything settled and the lock is off: the loop is not needed any more
	if not locked then
		local settled = (offsetSpring.x - target).Magnitude < 0.001 and offsetSpring.v.Magnitude < 0.001 and math.abs(fov - targetFov) < 0.05
		if settled then
			hum.CameraOffset = Vector3.zero
			stopLoop()
		end
	end
end

local function guardedFrame(dt: number)
	local ok, err = pcall(frame, dt)
	if ok then
		errorCount = 0
		return
	end
	errorCount += 1
	if errorCount == 1 then warn("[ShiftLock] frame error:", err) end
	if errorCount >= CONFIG.MAX_ERRORS then -- keep failing: give the camera back instead of leaving it half way
		warn("[ShiftLock] switched off after repeated errors")
		stopLoop()
		pcall(function()
			locked = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			if humanoid then
				humanoid.AutoRotate = savedAutoRotate
				humanoid.CameraOffset = Vector3.zero
			end
		end)
		errorCount = 0
	end
end

local function startLoop()
	if looping then return end
	looping = true
	-- just AFTER the default camera script, so that the offset and the FOV set here are the last word of the frame
	RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Camera.Value + 1, guardedFrame)
end

stopLoop = function()
	if not looping then return end
	looping = false
	pcall(function() RunService:UnbindFromRenderStep(STEP_NAME) end)
end

--------------------------------------------------------------------------------
-- Lock on / off
--------------------------------------------------------------------------------
local function setLocked(state: boolean)
	if state == locked then return end
	local hum = humanoid
	if state and (not hum or hum.Health <= 0) then return end
	locked = state
	if state then
		if hum then
			savedAutoRotate = hum.AutoRotate
			hum.AutoRotate = false -- the script turns the character itself
		end
		local camera = workspace.CurrentCamera
		if camera then -- start from where the camera looks: no sudden turn of the character
			local look = camera.CFrame.LookVector
			local yaw = math.atan2(-look.X, -look.Z)
			yawSpring.x, yawSpring.v, yawSpring.target = yaw, 0, yaw
		end
		lastVelocity = if rootPart then rootPart.AssemblyLinearVelocity else Vector3.zero
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
		startLoop()
	else
		if hum then hum.AutoRotate = savedAutoRotate end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		startLoop() -- the offset and the FOV spring back; the loop stops itself when they have settled
	end
end

--------------------------------------------------------------------------------
-- Character
--------------------------------------------------------------------------------
local function onCharacterAdded(character: Model)
	disconnectAll(characterConnections)
	local hum = character:WaitForChild("Humanoid", 5)
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not (hum and hum:IsA("Humanoid") and root and root:IsA("BasePart")) then
		warn("[ShiftLock] the character has no Humanoid or HumanoidRootPart")
		return
	end
	humanoid, rootPart = hum, root
	offsetSpring.x, offsetSpring.v = Vector3.zero, Vector3.zero
	lastVelocity = Vector3.zero
	savedAutoRotate = true
	if locked then hum.AutoRotate = false end
	table.insert(characterConnections, hum.Died:Connect(function()
		setLocked(false)
		stopLoop()
		humanoid, rootPart = nil, nil
	end))
	if locked then startLoop() end
end

table.insert(connections, player.CharacterAdded:Connect(onCharacterAdded))
table.insert(connections, player.CharacterRemoving:Connect(function()
	disconnectAll(characterConnections)
	stopLoop()
	humanoid, rootPart = nil, nil
end))
if player.Character then task.spawn(onCharacterAdded, player.Character) end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------
local function isShift(code: Enum.KeyCode): boolean
	return code == Enum.KeyCode.LeftShift or code == Enum.KeyCode.RightShift
end

table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or UserInputService:GetFocusedTextBox() then return end
	if isShift(input.KeyCode) then
		if CONFIG.HOLD_MODE then setLocked(true) else setLocked(not locked) end
	elseif input.KeyCode == Enum.KeyCode.Q and locked then
		shoulder = -shoulder
		startLoop()
	end
end))
table.insert(connections, UserInputService.InputEnded:Connect(function(input: InputObject)
	if CONFIG.HOLD_MODE and isShift(input.KeyCode) then setLocked(false) end
end))

-- the window lost focus while Shift was held: do not leave the lock on in hold mode
table.insert(connections, UserInputService.WindowFocusReleased:Connect(function()
	if CONFIG.HOLD_MODE then setLocked(false) end
end))

-- clean up when the script is removed
script.Destroying:Connect(function()
	setLocked(false)
	stopLoop()
	disconnectAll(characterConnections)
	disconnectAll(connections)
	if humanoid then humanoid.CameraOffset = Vector3.zero end
end)
