--!strict
-- Luau | LocalScript "GojoCamera" | put it in StarterPlayer > StarterPlayerScripts
-- The camera and the screen for the Gojo dummy. The server says "what happened, where, how strong" (RemoteEvent "GojoFx");
-- this script decides how hard it feels from the distance to the camera.
--   gather : the slow push-in while Gojo gathers power (the field of view narrows, a faint tremor)
--   seal   : a small tremor (the hand sign)
--   burst  : the domain expansion: a hard shake, the field of view kicks out (a spring), a white flash and a blur pulse
--   flex   : Hollow Purple: a medium version of the burst
--   hit    : the fall of the body
-- The effects are ADDITIVE (they are added to what the normal camera did this frame and taken back after it), so other camera scripts keep working.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local RANGE = 140 -- studs: farther than this the effect is zero

local trauma = 0 -- 0..1, the shake is trauma^2 (small hits are small, big hits are very big)
local fovX, fovV = 0, 0 -- the field of view offset: a damped spring (it overshoots, then settles)
local tension, tensionUntil = 0, 0 -- the slow push-in
local flash = 0
local appliedFov = 0

local FOV_OMEGA, FOV_ZETA = 14, 0.45
local SEED = math.random() * 100

local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "GojoGrade"
grade.Parent = Lighting
local blur = Instance.new("BlurEffect")
blur.Name = "GojoBlur"
blur.Size = 0
blur.Parent = Lighting

local function onFx(kind: string, pos: Vector3, power: number)
	local camera = workspace.CurrentCamera
	if not camera then return end
	local distance = (camera.CFrame.Position - pos).Magnitude
	local k = power * math.clamp(1 - distance / RANGE, 0, 1)
	if k < 0.02 then return end

	if kind == "gather" then
		tension = k
		tensionUntil = os.clock() + 1.3
		trauma = math.max(trauma, 0.08 * k)
	elseif kind == "seal" then
		trauma = math.max(trauma, 0.25 * k)
	elseif kind == "burst" then
		trauma = math.max(trauma, 1.0 * k)
		fovV += 190 * k
		flash = math.max(flash, 0.9 * k)
		blur.Size = math.max(blur.Size, 28 * k)
		for _, step in { { 0.18, 1.0 }, { 0.42, 0.85 }, { 0.8, 0.65 }, { 1.3, 0.4 } } do -- the aftershocks: the ground keeps shaking
			task.delay(step[1], function()
				trauma = math.max(trauma, step[2] * k)
				fovV += 40 * k
			end)
		end
		tensionUntil = 0
	elseif kind == "flex" then
		trauma = math.max(trauma, 0.55 * k)
		fovV += 55 * k
		flash = math.max(flash, 0.3 * k)
		blur.Size = math.max(blur.Size, 8 * k)
	elseif kind == "hit" then
		trauma = math.max(trauma, 0.75 * k)
		fovV += 90 * k
		flash = math.max(flash, 0.35 * k)
		blur.Size = math.max(blur.Size, 10 * k)
	end
end

local function connect(remote: RemoteEvent)
	remote.OnClientEvent:Connect(onFx)
end

task.spawn(function()
	local remote = ReplicatedStorage:WaitForChild("GojoFx", 60)
	if remote and remote:IsA("RemoteEvent") then
		connect(remote)
	end
end)

RunService:BindToRenderStep("GojoCamera", Enum.RenderPriority.Camera.Value + 1, function(dtRaw: number)
	local camera = workspace.CurrentCamera
	if not camera then return end
	local dt = math.min(dtRaw, 1 / 30)
	local now = os.clock()

	-- the field of view: the slow push-in is the spring's target, a kick is an instant speed change
	local target = if now < tensionUntil then -9 * tension else 0
	local steps = 2
	local h = dt / steps
	for _ = 1, steps do
		fovV += (FOV_OMEGA * FOV_OMEGA * (target - fovX) - 2 * FOV_ZETA * FOV_OMEGA * fovV) * h
		fovX += fovV * h
	end

	trauma = math.max(0, trauma - dt * 0.5)
	local shake = trauma * trauma
	local t = now * 28
	if shake > 0.0005 then
		local nx = math.noise(t, SEED, 0)
		local ny = math.noise(t, SEED, 10)
		local nz = math.noise(t, SEED, 20)
		camera.CFrame = camera.CFrame
			* CFrame.new(nx * 2.2 * shake, ny * 2.2 * shake, nz * 0.8 * shake)
			* CFrame.Angles(ny * 0.22 * shake, nx * 0.22 * shake, nz * 0.16 * shake)
	end

	camera.FieldOfView += fovX - appliedFov
	appliedFov = fovX

	flash = math.max(0, flash - dt * 2.2)
	grade.Brightness = flash
	grade.Saturation = -0.25 * (if now < tensionUntil then tension else 0) -- the world drains a little while the power gathers
	blur.Size = math.max(0, blur.Size - dt * 40)
end)
