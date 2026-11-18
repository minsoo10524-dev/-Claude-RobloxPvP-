--!strict
-- LocalScript "ReaperMarkClient" (parent: Tool "TrueKatana")
-- X skill on the client: the key, the mark on the enemy (ReaperMarkHud) and the dash.
-- Flow: press X -> the request goes to the server with the line of sight -> the server answers
--   "mark"  : the enemy is marked (the mark and its distance stay on it until the server says "clear")
--   "go"    : the dash. This player moves itself to the end point (BehindDistance studs behind the enemy) in Config.DashTime, so fast that it is a blink;
--             a crouch first, then a flat lunge pose; the speed lines (in the air, a ribbon behind the body, and on the screen) are made here
--   "reject": nothing happened (no enemy, too far, or still cooling)
-- PHYSICS of the dash: the body is moved by CFrame along the line (no velocity is added), collisions with the bodies on the way are off while it
-- moves, and at the end the velocity is set to ZERO (no carried speed, no slide), so nothing is thrown around afterwards.
-- COOLDOWN: the number on the label "XName" is drawn by SkillGuiMotion from XReadyAt (the server's) and XReadyAtLocal (this script's guess, written when the
-- server says "go" so the countdown starts at once). The mark is free and does not touch the cooldown.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
if not player then return end
local toolParent = script.Parent
if not (toolParent and toolParent:IsA("Tool")) then return end
local tool: Tool = toolParent

local function need(name: string, class: string): Instance?
	local found = tool:WaitForChild(name, 10)
	if not (found and found:IsA(class)) then
		warn("[ReaperMarkClient] the tool needs a " .. class .. " named " .. name)
		return nil
	end
	return found
end
local remoteInstance = need("ReaperMark", "RemoteEvent")
local configModule = need("ReaperMarkConfig", "ModuleScript")
local hudModule = need("ReaperMarkHud", "ModuleScript")
if not (remoteInstance and configModule and hudModule) then return end
local remote = remoteInstance :: RemoteEvent
local Config = require(configModule :: ModuleScript) :: { [string]: number }
local carryModule = need("ReaperMarkCarry", "ModuleScript")
local fxModule = need("ReaperMarkFx", "ModuleScript")
if not (carryModule and fxModule) then return end
local Fx = require(fxModule :: ModuleScript) :: any
local Carry = require(carryModule :: ModuleScript) :: any
local Hud = require(hudModule :: ModuleScript) :: { show: (Model) -> (), clear: () -> () }

-- the pose and the sound of BLINK CUT's dash are reused when they are in the tool (nothing breaks if they are not)
local function optional(name: string): any?
	local module = tool:FindFirstChild(name)
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok then return result end
		warn("[ReaperMarkClient] could not load " .. name .. " (the animation will be missing):", result)
	end
	return nil
end
local Anim: any? = optional("BlinkCutAnim")
local Sfx: any? = optional("BlinkCutSfx")

local ACTION = "ReaperMark"
local KEY = Enum.KeyCode.X
local GUESS = "XReadyAtLocal" -- the client's own guess for the label
local WHITE = Color3.fromRGB(255, 241, 241)
local ROSE = Color3.fromRGB(251, 129, 127)
local WINDUP = 0.12 -- seconds of the crouch before the rush
local CUT_HOLD = 0.14 -- seconds the cut that passes through the enemy is held
local GRAB_HOIST = 0.22 -- seconds after the clamp at which the hoist (a second beat) lands
local FOV_KICK = 14 -- degrees the field of view opens at the start of the rush
local WAIT = 1.5 -- seconds the client waits for an answer before it may send the next request

local equipped = false
local pending = 0 -- the number of the request that waits for an answer (0 = none)
local dashing = false
local dashingSince = 0 -- (a safety: a sequence that never ended cannot lock the key forever)
local MAX_SEQUENCE = 6 -- seconds

local function parts(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if char and hum and hum.Health > 0 and root and root:IsA("BasePart") then return char, hum, root end
	return nil, nil, nil
end

local function press()
	if dashing and os.clock() - dashingSince > MAX_SEQUENCE then dashing = false end
	if not equipped or pending ~= 0 or dashing then return end
	local char, _, root = parts()
	if not char or not root then return end
	local cam = workspace.CurrentCamera
	local look = if cam then cam.CFrame.LookVector else root.CFrame.LookVector
	pending += 1
	local mine = pending
	remote:FireServer("cast", look)
	task.delay(WAIT, function()
		if pending == mine then pending = 0 end -- no answer: the next press is allowed
	end)
end

-- SPEED LINES (light and thin now): a few long streaks in the air along the path and a ribbon behind the body. Nothing on the screen.
local function worldLines(from: Vector3, to: Vector3)
	local dir = (to - from).Unit
	local side = dir:Cross(Vector3.yAxis)
	side = if side.Magnitude > 0.05 then side.Unit else Vector3.xAxis
	local count = math.clamp(math.floor((to - from).Magnitude / 4), 10, 28)
	for _ = 1, count do
		local pos = from:Lerp(to, math.random()) + side * ((math.random() - 0.5) * 9) + Vector3.new(0, math.random() * 5 - 1.5, 0)
		local len = 8 + math.random() * 14
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = if math.random() < 0.7 then WHITE else ROSE
		p.Transparency = 0.1
		p.Size = Vector3.new(0.1, 0.1, len)
		p.CFrame = CFrame.lookAt(pos, pos + dir)
		p.Parent = workspace
		TweenService:Create(p, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.02, 0.02, len * 2.2),
			Transparency = 1,
			CFrame = p.CFrame + dir * (len * 0.8),
		}):Play()
		Debris:AddItem(p, 0.45)
	end
end

local function fovKick(seconds: number)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local base = cam.FieldOfView
	TweenService:Create(cam, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = base + FOV_KICK }):Play()
	task.delay(seconds, function()
		TweenService:Create(cam, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { FieldOfView = base }):Play()
	end)
end

-- the body is hidden on this screen while it travels (the others still see it move) and shows again at the end
local function hideBody(char: Model, hidden: boolean)
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then d.LocalTransparencyModifier = if hidden then 1 else 0 end
	end
end

-- THE CAMERA: while the owner flies, the view looks the way he flies (toward the enemy's back); from the landing on it follows the enemy until the end
-- (also while he jumps 40 studs). It is blended in and out (so it never snaps), and it is only a turn of the view: the position stays the camera's own.
local aimOn = false
local aimWeight = 0
local aimDir: Vector3? = nil
local aimFollow: BasePart? = nil
local AIM_DISTANCE = 15 -- studs before the end of the rush from which the view looks at the enemy
local abortFlag = false -- the enemy died or vanished (the server says "abort", or this client sees it)
local currentAbort: (() -> ())? = nil

RunService:BindToRenderStep("ReaperMarkAim", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	if aimOn and not dashing then aimOn = false end -- (a safety: the view is never held when the skill is not running)
	local cam = workspace.CurrentCamera
	local want = if aimOn then 1 else 0
	aimWeight += (want - aimWeight) * (1 - math.exp(-dt * (if aimOn then 14 else 5)))
	if aimWeight < 0.01 or not cam then return end
	local desired: Vector3? = aimDir
	local follow = aimFollow
	if follow and follow.Parent then
		local v = follow.Position - cam.CFrame.Position
		if v.Magnitude > 0.5 then desired = v.Unit end
	end
	if not desired then return end
	local look = cam.CFrame.LookVector:Lerp(desired, aimWeight)
	if look.Magnitude < 0.01 then return end
	cam.CFrame = CFrame.lookAt(cam.CFrame.Position, cam.CFrame.Position + look.Unit)
end)

-- THE POSTURE OF THE WHOLE BODY: the joints move the limbs, but the silhouette is changed by tilting the whole body in space (pitch: negative = leaning forward,
-- positive = leaning back; roll = the sway to a side). Every part of the skill has its own: it leans into the grab, walks bent and swaying, crouches before the
-- jump, rises leaning back, arches at the top, dives head first in the slam and lands on one knee.
local function tiltFor(phase: string, pc: number): (number, number, number) -- pitch, roll (degrees), speed of the change
	if phase == "grab" or phase == "clamp" or phase == "hoist" then return -14, 0, 14
	elseif phase == "drag" then return -12, 0, 12 -- leaning forward a little into the spin
	elseif phase == "knock" then return -28, 0, 22 -- thrown forward behind the shove
	elseif phase == "regrab" then return -22, 0, 16
	elseif phase == "heave" then return -26, 0, 18 -- the crouch
	elseif phase == "rise" then return 16, 0, 40 -- the jump: the body goes up leaning back, the feet trailing
	elseif phase == "hang" then return 24, 5 * math.sin(pc * 6), 10 -- arched at the top, floating
	elseif phase == "load" then return 40, 0, 30 -- the back bent over the top for the blow
	elseif phase == "slam" then return -62, 0, 45 -- the dive: head first
	elseif phase == "hit" or phase == "rest" then return -24, 0, 16 -- the landing crouch
	end
	return 0, 0, 14
end

local forcedCF: CFrame? = nil -- where the body must stand this frame (written at the very end of the frame)
local restoreRotate: (() -> ())? = nil
RunService:BindToRenderStep("ReaperMarkBody", Enum.RenderPriority.Last.Value, function()
	local cf = forcedCF
	if not cf then return end
	local char = player.Character
	local r = char and char:FindFirstChild("HumanoidRootPart")
	if r and r:IsA("BasePart") then r.CFrame = cf end
end)

local function unlock() -- the end of the skill (or of anything that goes wrong): the key and the camera are free again
	dashing = false
	aimOn = false
	aimFollow = nil
	currentAbort = nil
	forcedCF = nil
	local back = restoreRotate
	restoreRotate = nil
	if back then back() end
end

-- THE TELEPORT: a short crouch (the body coils); then a ghost of the body stays where it stood and fades, a thin line of light is drawn along the path, the body
-- VANISHES for the travel (ghosts show it again at three places on the way, each fading), and it lands with a stomp: a ring on the floor, dust, stones.
-- The time grows with the distance (from Config.DashTime to Config.DashTimeMax) so that a 200 stud blink still reads as a blink.
local function dash(finish: Vector3, target: Model?, startsAt: number?, base: CFrame?, dragLen: number?)
	local char, _, root = parts()
	if not char or not root then return end
	if (finish - root.Position).Magnitude < 0.5 then return end
	dashing = true
	dashingSince = os.clock()
	abortFlag = false
	local humStart = char:FindFirstChildOfClass("Humanoid") -- the character must not turn by itself (the humanoid, ShiftLock) while the skill moves it
	if humStart then
		local wasAuto = humStart.AutoRotate
		humStart.AutoRotate = false
		restoreRotate = function()
			if humStart.Parent then humStart.AutoRotate = wasAuto end
		end
	end
	local handle: any? = if Anim then Anim.new(char) else nil
	if handle then handle.windup() end -- the crouch: the body coils, the sword arm is drawn back
	if Sfx then Sfx.windup(root) end

	task.delay(WINDUP, function()
		local char2, _, root2 = parts()
		if not char2 or not root2 or root2 ~= root then
			if handle then handle.release() end
			unlock()
			return
		end
		local from = root2.Position
		local delta = finish - from
		if delta.Magnitude < 0.5 then
			if handle then handle.release() end
			unlock()
			return
		end
		local dir = delta.Unit
		local dashTime = math.clamp(delta.Magnitude / Config.DashSpeed, Config.DashTime, Config.DashTimeMax)

		local saved: { BasePart } = {} -- no bumping into the bodies on the way
		for _, p in char2:GetDescendants() do
			if p:IsA("BasePart") and p.CanCollide then
				table.insert(saved, p)
				p.CanCollide = false
			end
		end
		if handle then
			handle.lunge()
			handle.fly(1) -- in the air the free arm trails and the wrists flutter
			handle.motion("fly")
		end
		if Sfx then Sfx.dash(root2, dashTime) end
		pcall(Fx.setIgnore, { char2, if target then target else char2 }) -- the stones and floor pictures ignore the two bodies

		-- the departure
		pcall(Fx.debris, from, 14, 18, 0.5)
		pcall(fovKick, dashTime)
		local aimStarted = false
		local enemyRoot = if target then target:FindFirstChild("HumanoidRootPart") else nil

		local function reveal()
			if char2.Parent then hideBody(char2, false) end
		end

		local t0 = os.clock()
		local conn: RBXScriptConnection? = nil
		conn = RunService.PreSimulation:Connect(function()
			local t = math.clamp((os.clock() - t0) / dashTime, 0, 1)
			local alive = root2.Parent ~= nil
			if alive then
				local p = from:Lerp(finish, 1 - (1 - t) ^ 4) -- a hard start and a soft stop
				if not aimStarted and (finish - p).Magnitude <= AIM_DISTANCE and enemyRoot and enemyRoot:IsA("BasePart") then
					aimStarted = true -- the last 15 studs: the view turns to the enemy
					aimFollow, aimOn = enemyRoot, true
				end
				root2.CFrame = CFrame.lookAt(p, p + dir) * CFrame.Angles(math.rad(-38 * math.min(t * 8, 1) * (1 - math.max(0, (t - 0.85) / 0.15))), 0, 0) -- the body flies leaning forward
					forcedCF = root2.CFrame
				root2.AssemblyLinearVelocity = Vector3.zero -- (no speed is added: the body is only placed)
				root2.AssemblyAngularVelocity = Vector3.zero
			end
			if t >= 1 or not alive then
				if conn then
					conn:Disconnect()
					conn = nil
				end
				for _, p in saved do
					if p.Parent then p.CanCollide = true end
				end
				reveal()
				if not alive then
					unlock()
					return
				end
				root2.AssemblyLinearVelocity = Vector3.zero -- no carried speed, no slide
				if handle then
					handle.motion("none")
					handle.grab() -- the arms reach out: the grab
				end
				local eroot = if target then target:FindFirstChild("HumanoidRootPart") else nil
				local soundAt: BasePart = if eroot and eroot:IsA("BasePart") then eroot else root2

				-- the landing of the teleport: a stomp
				pcall(Fx.groundMark, finish, 24, WHITE, 0.35, 0.6)
				pcall(Fx.debris, finish, 20, 22, 0.6)
				pcall(Fx.shake, 0.35)
				local tHum = if target then target:FindFirstChildOfClass("Humanoid") else nil
				local gone = abortFlag or not (target and target.Parent and tHum and tHum.Health > 0) -- the enemy died on the way: no carry
				aimOn = false -- from the landing on the view is free again
				aimFollow = nil
				if gone or not (startsAt and base) then -- (the enemy is gone, or no timeline from the server: the old ending)
					if handle then task.delay(CUT_HOLD, handle.release) end
					unlock()
					return
				end

				-- THE CARRY: the owner follows the shared timeline (the server moves the enemy on the same one): grab, swing, heave, jump, hang, load, slam, rest
				local hum2 = char2:FindFirstChildOfClass("Humanoid")
				local wasPlatform = if hum2 then hum2.PlatformStand else false
				if hum2 then hum2.PlatformStand = true end
				local phaseNow = ""
				local phaseClock = os.clock()
				local carryLinks: { RBXScriptConnection } = {}
				-- EXCEPTION: the enemy dies or vanishes during the carry: the owner lets go and FALLS (gravity), then everything is put back
				local aborted = false
				local fallLift, fallVel, lastLift, lastYaw, lastClock = 0, 0, 0, 0, os.clock()
					local lastOff = Vector3.zero
					local recovering, recoverAt = false, 0 -- the RECOVERY after the last move: the body is eased back to standing before it is let go
					local tiltP, tiltR = 0, 0
					local omegaS = 0
					local flyS = 0
					local lastSpeed, leanSmooth, lastBiasClock = 0, 0, os.clock()
					local lastDrag, dragTick, strideSecond = 0, 0, false
					local slashN = 0
					local flat = Vector3.new(base.LookVector.X, 0, base.LookVector.Z)
					local forward = if flat.Magnitude > 0.01 then flat.Unit else Vector3.zAxis * -1
					local function ePart(name: string): BasePart -- a part of the enemy's body (the chest if there is no such part)
						local p = if target then target:FindFirstChild(name, true) else nil
						if p and p:IsA("BasePart") then return p end
						return soundAt
					end
					local function hand(name: string): BasePart
						local p = char2:FindFirstChild(name, true)
						if p and p:IsA("BasePart") then return p end
						return root2
					end
				local function abort()
					if aborted or phaseNow == "slam" or phaseNow == "rest" then return end -- (the blow itself may kill it: that is not an exception)
					aborted = true
					fallLift, fallVel, lastClock = lastLift, 0, os.clock()
					aimFollow = nil
					if handle then handle.slam() end
				end
				currentAbort = abort
				if tHum then
					table.insert(carryLinks, tHum.Died:Connect(abort))
				end
				if target then
					table.insert(carryLinks, target.AncestryChanged:Connect(function()
						if not target:IsDescendantOf(workspace) then abort() end
					end))
				end
				local carryConn: RBXScriptConnection? = nil
				local function finishCarry()
					if carryConn then
						carryConn:Disconnect()
						carryConn = nil
					end
					for _, link in carryLinks do link:Disconnect() end
					table.clear(carryLinks)
					if root2.Parent then
						root2.CFrame = base * CFrame.new(lastOff) * CFrame.Angles(0, lastYaw, 0)
						root2.AssemblyLinearVelocity = Vector3.zero
					end
					if hum2 and hum2.Parent then hum2.PlatformStand = wasPlatform end
					if handle then handle.release() end
					unlock()
				end
				carryConn = RunService.PreSimulation:Connect(function()
					if not root2.Parent then
						finishCarry()
						return
					end
					if abortFlag and not aborted then abort() end
					if aborted then -- falling back down under real gravity
						local now = os.clock()
						local dtf = math.min(now - lastClock, 1 / 20)
						lastClock = now
						fallVel -= workspace.Gravity * dtf
						fallLift = math.max(fallLift + fallVel * dtf, 0)
						root2.CFrame = base * CFrame.new(lastOff) * CFrame.Angles(0, lastYaw, 0) * CFrame.new(0, fallLift, 0)
						forcedCF = root2.CFrame
						root2.AssemblyLinearVelocity = Vector3.zero
						root2.AssemblyAngularVelocity = Vector3.zero
						if fallLift <= 0 then
							pcall(Fx.quake, 0.45)
							finishCarry()
						end
						return
					end
						local lift, _, phase, done, yaw, off = Carry.sample(workspace:GetServerTimeNow() - startsAt, dragLen)
						-- BODY PHYSICS: a runner leans INTO his acceleration, tan(lean) = a / g: forward when the run starts, back when he stops dead
						local nowB = os.clock()
						local dtB = math.max(nowB - lastBiasClock, 1 / 240)
						lastBiasClock = nowB
						local speedB = -(off.Z - lastOff.Z) / dtB
						local accelB = (speedB - lastSpeed) / dtB
						lastSpeed = speedB
						local wantLean = if phase == "drag" or phase == "heave" then -math.clamp(math.deg(math.atan(accelB / workspace.Gravity)), -30, 30) else 0
						leanSmooth += (wantLean - leanSmooth) * (1 - math.exp(-dtB * 10))
						if handle and handle.lean then handle.lean(leanSmooth) end
						local prevYaw = lastYaw
						local prevLift = lastLift
						lastLift, lastYaw, lastOff = lift, yaw, off
						root2.CFrame = base * CFrame.new(off) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, lift, 0)
						root2.AssemblyLinearVelocity = Vector3.zero
						root2.AssemblyAngularVelocity = Vector3.zero
						if phase == "drag" and math.floor(yaw / math.pi) ~= math.floor(prevYaw / math.pi) then -- the body whips through the middle of a turn: the sword cuts the enemy on its tip: a slash, a spray of stones, a rush of air
							pcall(Fx.slash, ePart("UpperTorso"), 12)
							pcall(Fx.debris, ePart("LowerTorso").Position, 10, 16, 0.5, -forward)
							pcall(Fx.shake, 0.35)
							if Sfx then Sfx.whoosh(root2, 1 + slashN % 2, 0.7, slashN * 5 + 5) end
							slashN += 1
						end
						if phase == "drag" then -- every 0.09 s the stride changes; every second step is a FOOTFALL on the beat: a ring, stones, a quake, a hit on the dragged body, a thud
							local clock = os.clock()
							if clock - lastDrag > 0.32 then -- one step every 0.32 s: the pose, the running layer (0.64 s per two steps), the sway and the bob of the bodies all keep this beat
								lastDrag = clock
								strideSecond = not strideSecond
								dragTick += 1
								-- (the steps are in the clip)
								if true then -- every step is a footfall
									local here = root2.Position
																		pcall(Fx.debris, here, 3, 8, 0.3, -forward)
									-- (no footstep sound)
								end
							end
						elseif phase == "clamp" or phase == "hit" then -- HIT STOP: a tremor runs through the owner too
							root2.CFrame = root2.CFrame * CFrame.new((math.random() - 0.5) * 0.1, (math.random() - 0.5) * 0.08, (math.random() - 0.5) * 0.1)
						end
						local omegaRaw = (yaw - prevYaw) / dtB -- the speed of the turn of the body, smoothed: the body layer of the spin follows it
						omegaS += (omegaRaw - omegaS) * (1 - math.exp(-dtB * 16))
						if handle and handle.spin then handle.spin(if phase == "drag" then omegaS else 0) end
						local vyRaw = (lift - prevLift) / dtB -- how fast the body goes up or down: the arms trail behind it
						flyS += (math.clamp(math.abs(vyRaw) / 250, 0, 1) - flyS) * (1 - math.exp(-dtB * 10))
						if handle and handle.fly then handle.fly(flyS) end
						local wantP, wantR, rate = tiltFor(phase, os.clock() - phaseClock)
						if recovering then wantP, wantR, rate = 0, 0, 5 end
						local kT = 1 - math.exp(-dtB * rate)
						tiltP += (wantP - tiltP) * kT
						tiltR += (wantR - tiltR) * kT
						root2.CFrame = root2.CFrame * CFrame.Angles(math.rad(tiltP), 0, math.rad(tiltR))
						forcedCF = root2.CFrame -- (after the tremor of the hit stops, so it is shown)
						if handle and handle.arm then -- THE ARMS: each part of the skill has its own arm motion on top of the pose
							local pc = os.clock() - phaseClock
							local rA, lA, rE, lE = 0, 0, 0, 0 -- shoulders and elbows, in degrees, on top of the pose
							local function ease(x: number): number
								return 1 - (1 - math.clamp(x, 0, 1)) ^ 2
							end
							if phase == "drag" then -- the turn: the sword arm goes round its shoulder twice, the other arm the other way (a pinwheel)
								local u = math.clamp((workspace:GetServerTimeNow() - startsAt - Carry.SWEEP_AT) / Carry.SWEEPT, 0, 1)
								local w = u * u * (3 - 2 * u)
								rA = 360 * Carry.SPIN * w
								lA = -360 * Carry.SPIN * w
							elseif phase == "hoist" then -- the first lift: both arms rise with the enemy, the elbows straighten as the weight goes up, the shoulders tremble with the effort
								local e = ease(pc / 0.23)
								rA = 45 * e + 2.5 * math.sin(pc * 60)
								lA = 38 * e - 2.5 * math.sin(pc * 57)
								rE = 34 * (1 - e)
								lE = 40 * (1 - e)
							elseif phase == "regrab" then -- the SCOOP: the sword arm swings up from low in an arc (an uppercut under the enemy), the free hand follows a moment later and takes the collar
								rA = -55 + 100 * ease(pc / 0.28)
								lA = -45 + 95 * ease((pc - 0.08) / 0.28)
								rE = 46 * (1 - ease(pc / 0.3))
								lE = 36 * (1 - ease((pc - 0.08) / 0.3))
							elseif phase == "heave" then -- the loading: both arms drawn back and the elbows bent: the enemy is pulled in to the chest, the shoulders tremble with the weight
								local e = ease(pc / 0.3)
								rA = -50 * e + 3 * math.sin(pc * 55)
								lA = -50 * e - 3 * math.sin(pc * 52)
								rE = 52 * e
								lE = 52 * e
							elseif phase == "rise" then -- the jump: the sword arm stays bent (the blade at the neck), the other hand yanks the collar up and its elbow straightens
								lA = -40 * (1 - math.clamp(pc / 0.3, 0, 1)) ^ 2
								lE = 30 * (1 - ease(pc / 0.3))
							elseif phase == "hang" then -- at the top the arms float: a slow sway, one up as the other goes down
								rA = 7 * math.sin(pc * 12)
								lA = -rA
							end
							handle.arm(rA)
							handle.armL(lA)
							if handle.elbows then handle.elbows(rE, lE) end
						end
						if phase ~= phaseNow then
							phaseNow = phase
							phaseClock = os.clock()
							if handle then handle.motion(if phase == "drag" then "spin" elseif phase == "rise" or phase == "hang" or phase == "load" or phase == "slam" then "fly" else "none") end -- the walk cycle runs during the drag only
							if handle then
								if phase == "drag" then
									handle.drag() -- the pose of the spin: the sword arm out in front holding the enemy, the free arm forward and out; the spin layer is below
									lastDrag = os.clock() - 0.16 -- the first foot comes down a quarter of a stride later, then every 0.32 s
								elseif phase == "knock" then
									handle.push()
								elseif phase == "heave" then
									handle.clip("jump") -- one clip from the crouch to the landing: heave, launch, top, load, dive, land
								elseif phase == "rise" or phase == "hang" or phase == "load" or phase == "slam" or phase == "hit" or phase == "rest" then
									-- (the "jump" clip is playing)
								else
									handle.grab()
								end
							end
							if Sfx then -- the sound of each part (BlinkCutSfx)
								if phase == "grab" then
									Sfx.whoosh(root2, 1, 0.5, 1)
								elseif phase == "clamp" then
									Sfx.catch(soundAt) -- the clamp: a chop and a held breath
									task.delay(0.1, function() if soundAt.Parent then Sfx.finishHit(soundAt) end end)
								elseif phase == "drag" then
									for i, p in { 0.5, 1 } do -- the wind of the run: two long rushes, the second higher
										task.delay((i - 1) * 0.4, function() if root2.Parent then Sfx.whoosh(root2, 1 + i % 2, p, i * 5) end end)
									end
								elseif phase == "heave" then
									Sfx.land(root2, 0.7) -- the dead stop
								elseif phase == "sweep" then
									Sfx.whoosh(root2, 2, 1, 10) -- the whip of the spin, and its echo
									task.delay(0.15, function() if root2.Parent then Sfx.whoosh(root2, 1, 0.8, 15) end end)
								elseif phase == "knock" then
									Sfx.finishHit(soundAt) -- the enemy leaves the sword tip: a heavy chop and a thud, like the end of the third hit
									Sfx.land(soundAt, 1.0)
								elseif phase == "regrab" then
									Sfx.catch(soundAt) -- the re-grab
								elseif phase == "rise" then
									Sfx.whoosh(root2, 2, 1, 5) -- the jump: one sharp, high rush
								elseif phase == "hang" then
									Sfx.hush(Carry.HANG + Carry.SLAM) -- the quiet at the top: the whole mix drops, so the blow is felt bigger
								elseif phase == "hit" then
									Sfx.land(soundAt, 1.6)
									task.delay(0.05, function() if soundAt.Parent then Sfx.finishHit(soundAt) end end)
								end
							end
							local here = (base * CFrame.new(lastOff)).Position -- the floor point of the owner now
							if phase == "grab" then
								pcall(Fx.quake, 0.25)
							elseif phase == "clamp" then
								-- THE CLAMP: the hit pictures flare ON the enemy's chest, head and hips and at the hands; a ring and stones on the floor; the view punches in, the
								-- ground jolts (P and S waves) and the screen flashes for one frame
								pcall(Fx.hit, ePart("UpperTorso"), 17)
								pcall(Fx.hit, ePart("Head"), 8)
								pcall(Fx.groundMark, here, 32, WHITE, 0.3, 1)
								pcall(Fx.debris, here, 28, 20, 1.0)
								pcall(Fx.quake, 0.8)
								if handle then -- the clamp: the arms snap in and the back bends (follow-through)
									handle.kick("RightShoulder", Vector3.new(520, 0, 0))
									handle.kick("LeftShoulder", Vector3.new(520, 0, 0))
									handle.kick("Waist", Vector3.new(-380, 0, 0))
								end
								pcall(Fx.fovPunch, -11)
							elseif phase == "hoist" then
								pcall(Fx.fovPunch, 6)
								pcall(Fx.quake, 0.4)
							elseif phase == "drag" then
								-- THE RUN: a big ring and a spray of stones thrown back; the view widens; the enemy's body keeps flaring with light and so does the runner
								pcall(Fx.groundMark, here, 34, WHITE, 0.4, 2)
								pcall(Fx.debris, here, 28, 24, 0.7, -forward)
								pcall(Fx.slash, ePart("UpperTorso"), 14) -- the hook: the sword cuts in as the run begins
								pcall(Fx.quake, 0.55)
								pcall(Fx.fovPunch, 16)
							elseif phase == "heave" then
								pcall(Fx.groundMark, here, 26, WHITE, 0.3, 1) -- the dead stop: stones fly on ahead, the view tightens
								pcall(Fx.debris, here, 22, 20, 0.6, forward)
								pcall(Fx.quake, 0.5)
								pcall(Fx.fovPunch, -8)
							elseif phase == "sweep" then
								-- THE SWEEP: the sword cuts across: two big slashes one after the other on the enemy, stones thrown out along the turn, the view punches in
								pcall(Fx.slash, ePart("UpperTorso"), 18)
								task.delay(0.12, function() pcall(Fx.slash, ePart("LowerTorso"), 14) end)
								pcall(Fx.debris, here, 22, 22, 0.6, forward)
								pcall(Fx.quake, 0.5)
								pcall(Fx.fovPunch, -6)
							elseif phase == "knock" then
								-- THE KNOCK: it comes off the tip: a heavy hit on the body, a ring where it skids, stones along its path, the view widens, one frame of flash
								local away = Vector3.new(ePart("LowerTorso").Position.X - root2.Position.X, 0, ePart("LowerTorso").Position.Z - root2.Position.Z)
								local along = if away.Magnitude > 0.01 then away.Unit else forward
								pcall(Fx.hit, ePart("UpperTorso"), 16)
								pcall(Fx.hit, ePart("Head"), 8)
								pcall(Fx.groundMark, ePart("LowerTorso").Position, 24, WHITE, 0.3, 1)
								pcall(Fx.debris, ePart("LowerTorso").Position, 18, 24, 0.5, along)
								pcall(Fx.quake, 0.7)
								pcall(Fx.fovPunch, 8)
								if handle then -- the shove: the sword arm is driven out and the body is thrown round behind it
									handle.kick("RightShoulder", Vector3.new(900, 0, 0))
									handle.kick("Waist", Vector3.new(0, 900, 0))
								end -- the follow-through of the knock: the body is thrown round
							elseif phase == "regrab" then
								pcall(Fx.starBurst, root2.Position + Vector3.new(0, 1, 0), 11)
								pcall(Fx.groundMark, root2.Position, 24, WHITE, 0.3, 1)
								pcall(Fx.quake, 0.4)
							elseif phase == "rise" then
								pcall(Fx.seismic, here, 44, 0.7)
								pcall(Fx.slash, ePart("Head"), 8) -- the blade bites at the neck as they leave the ground -- the jump: a quake, a big ring, stones thrown up
								pcall(Fx.debris, here, 32, 30, 1.4)
								pcall(Fx.starBurst, here + Vector3.new(0, 1, 0), 16)
								pcall(Fx.fovPunch, 12)
							elseif phase == "load" then
							elseif phase == "hit" then
								-- THE BLOW: the hit pictures flare on the whole body of the enemy and on the floor under it, two rings and a quake, hot stones, a flash
								local impact = (base * CFrame.new(lastOff) * CFrame.Angles(0, lastYaw, 0) * CFrame.new(0, 0, -3)).Position
								pcall(Fx.hit, ePart("UpperTorso"), 18)
								pcall(Fx.hit, ePart("Head"), 11)
								pcall(Fx.hit, ePart("LowerTorso"), 12)
								pcall(Fx.starBurst, impact + Vector3.new(0, 1.5, 0), 34)
								pcall(Fx.seismic, impact, 66, 1.8) -- the biggest quake of the skill
								pcall(Fx.debris, impact, 80, 40, 1.0)
								task.delay(0.1, function() pcall(Fx.debris, impact, 40, 28, 1.2) end) -- a second wave of smaller stones
								pcall(Fx.fovPunch, -14)
								pcall(Fx.shake, 1)
								if handle then -- THE BLOW: the whole body takes it: the arms are driven down and rebound, the knees buckle and come back, the back whips
									handle.kick("RightShoulder", Vector3.new(-900, 0, 120))
									handle.kick("LeftShoulder", Vector3.new(-900, 0, -120))
									handle.kick("RightKnee", Vector3.new(-600, 0, 0))
									handle.kick("LeftKnee", Vector3.new(-600, 0, 0))
									handle.kick("Waist", Vector3.new(-700, 0, 0))
									handle.kick("Neck", Vector3.new(500, 0, 0))
								end
							end
						end
					if done and not recovering then -- the last move is over: first the recovery (0.45 s): the arms and legs relax by the springs and the tilt goes back to upright; only then is everything let go
							recovering = true
							recoverAt = os.clock()
							if handle then
								handle.arm(0)
								handle.armL(0)
								handle.clip("finish") -- the finish: it stands up in three moves
							end
						end
						if recovering and os.clock() - recoverAt > 0.95 then finishCarry() end
				end)
			end
		end)
	end)
end

remote.OnClientEvent:Connect(function(kind: any, value: any, extra: any, extra2: any, extra3: any, extra4: any)
	if kind == "mark" then
		pending = 0
		if typeof(value) == "Instance" and value:IsA("Model") then Hud.show(value) end
	elseif kind == "clear" then
		Hud.clear()
	elseif kind == "abort" then -- the server saw the enemy die or vanish during the carry
		abortFlag = true
		local fn = currentAbort
		if fn then fn() end
	elseif kind == "go" then
		pending = 0
		player:SetAttribute(GUESS, workspace:GetServerTimeNow() + Config.Cooldown) -- the countdown starts now
		if typeof(value) == "Vector3" then
			dash(value, if typeof(extra) == "Instance" and extra:IsA("Model") then extra else nil, if typeof(extra2) == "number" then extra2 else nil, if typeof(extra3) == "CFrame" then extra3 else nil, if typeof(extra4) == "number" then extra4 else nil)
		end
	elseif kind == "reject" then
		pending = 0
		if typeof(value) == "number" and value > 0 then -- still cooling: the server says how long is left
			player:SetAttribute(GUESS, workspace:GetServerTimeNow() + value)
		end
	end
end)

local function onEquipped()
	equipped = true
	ContextActionService:BindAction(ACTION, function(_, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then press() end
		return Enum.ContextActionResult.Sink
	end, false, KEY)
end

local function onUnequipped() -- the mark STAYS on the enemy when the sword is put away; only the key is released
	equipped = false
	ContextActionService:UnbindAction(ACTION)
end

tool.Equipped:Connect(onEquipped)
tool.Unequipped:Connect(onUnequipped)
tool.Destroying:Connect(function()
	ContextActionService:UnbindAction(ACTION)
	Hud.clear()
end)

if tool.Parent == player.Character then onEquipped() end
