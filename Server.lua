--!strict
-- Script "Server"  (parent: Tool "DarkV1")
-- Validates swings, runs hit checks and the finisher (invulnerable roll, grab, overhead slam, stun),
-- and tells the owner's client what happened. The look of the hit is done on the client.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local tool = script.Parent :: Tool
local attackRemote = tool:WaitForChild("Attack") :: RemoteEvent
local feedbackRemote = tool:WaitForChild("FeedbackFX") :: RemoteEvent

-- windup / strike / nextAt come from the shared ModuleScript "ComboTiming" (the client reads the same numbers)
local Timing = require(tool:WaitForChild("ComboTiming") :: ModuleScript) :: { [number]: { [string]: number } }
type Step = {
	windup: number, strike: number, damage: number, hitScale: number?, stun: number?, knockDist: number, knockTime: number,
	slide: boolean?, lift: number?, nextAt: number, power: number, finisher: boolean?,
}
local COMBO: { Step } = {
	-- BALANCE: hit 1 = 15 damage, hit box +10%, stun 0.7 s (it holds the enemy until hit 2 lands, so 1 -> 2 always connects); hit 2 = 17 damage, hit box +15%,
	-- stun = its startup time; hit 3 = 30 damage, a wide catch, a long stun, 20 % lifesteal and a cooldown. If hit 2 misses the combo starts over with hit 1.
	-- hitScale = the size of the hit box, stun = seconds of stun on a hit.
	{ windup = Timing[1].windup, strike = Timing[1].strike, damage = 15, hitScale = 1.10, stun = 0.7, knockDist = 4.5, knockTime = 0.22, slide = true, nextAt = Timing[1].nextAt, power = 0.85 },
	{ windup = Timing[2].windup, strike = Timing[2].strike, damage = 17, hitScale = 1.15, stun = Timing[2].windup, knockDist = 3.2, knockTime = 0.26, lift = 2.6, nextAt = Timing[2].nextAt, power = 1.1 },
	{ windup = Timing[3].windup, strike = Timing[3].strike, damage = 30, knockDist = 22, knockTime = 0.25, nextAt = Timing[3].nextAt, power = 1.4, finisher = true, slide = true },
}

-- impact strength I (0..1) = how hard the hit "feels"; the client uses it for hit stop, flash, knockback and camera
local IMPACT_A = { 0.40, 0.60, 1.00 } -- by hit number
local MAX_DAMAGE = 30
local NEAR_DIST, FAR_DIST = 3, 10 -- studs: closer than NEAR = full power, FAR = weakest
-- (the chain bonus is gone: hit 2 always deals the same damage)

local COOLDOWN_TOLERANCE = 0.1
local COMBO_RESET = 2.0 -- seconds after the start of a swing in which the next hit still continues the combo (the Client's CONFIG.ComboReset must be the same)
local HIT_BOX = Vector3.new(10, 6, 11)
local HIT_OFFSET = 4.5
local MAX_REACH = 22
local MAX_TARGETS = 5
local SAME_TARGET_GAP = 0.2
local MAX_GRAB = 1 -- hit 3 catches ONE enemy

-- hit 3 "Moonfall"
local ROLL_CATCH = 9 -- an enemy this close in front of you is caught (a wide catch: it used to be 6.9)
local ROLL_CATCH_WIDTH = 16 -- ...and this wide (it used to be 11.3)
local STUN_TIME = 0.9 -- the stun of hit 3
local STUN_IMMUNE = 4 -- after a stun ends, the same enemy cannot be stunned again for this long
local LIFESTEAL = 0.20 -- the share of the damage dealt by hit 3 that the attacker gets back (hits 1 and 2 do not heal)
local FINISHER_COOLDOWN = Timing[3].cooldown -- hit 3 can be used again this many seconds after it starts (until then the combo starts over with hit 1)

--------------------------------------------------------------------------------
-- State (one tool = one owner, so one table is enough)
--------------------------------------------------------------------------------
local state: { index: number?, last: number, lastNextAt: number, busyUntil: number, finisherReadyAt: number } =
	{ index = nil, last = -100, lastNextAt = 0, busyUntil = 0, finisherReadyAt = 0 }
local lastHitAt: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any -- [model] = os.clock()
local stunImmuneUntil: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any -- [model] = os.clock()

local function getOwner(player: Player): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	if not char or tool.Parent ~= char then return nil, nil, nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not root or not root:IsA("BasePart") then return nil, nil, nil end
	return char, hum, root
end

local function refuse(player: Player, seq: number, reason: string, left: number?)
	feedbackRemote:FireClient(player, "reject", seq, reason, left or 0)
end

type Target = { model: Model, hum: Humanoid, root: BasePart }

local function validTarget(model: Model, attackerChar: Model): (Humanoid?, BasePart?)
	if model == attackerChar then return nil, nil end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not hum or not root or not root:IsA("BasePart") or hum.Health <= 0 then return nil, nil end
	return hum, root
end

local overlap = OverlapParams.new() -- reused for every query
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 64
local overlapChar: Model? = nil

local function collectTargets(cf: CFrame, size: Vector3, attackerChar: Model, originPos: Vector3, limit: number): { Target }
	if overlapChar ~= attackerChar then
		overlapChar = attackerChar
		overlap.FilterDescendantsInstances = { attackerChar }
	end
	local parts = workspace:GetPartBoundsInBox(cf, size, overlap)
	local list: { Target }, seen: { [Model]: boolean } = {}, {}
	for _, p in parts do
		local m = p:FindFirstAncestorOfClass("Model")
		if m and not seen[m] then
			seen[m] = true
			local hum, root = validTarget(m, attackerChar)
			if hum and (root.Position - originPos).Magnitude <= MAX_REACH then
				table.insert(list, { model = m, hum = hum, root = root })
				if #list >= limit then break end
			end
		end
	end
	return list
end

local function flatDir(from: Vector3, to: Vector3): Vector3
	local d = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if d.Magnitude < 1e-3 then return Vector3.zAxis end
	return d.Unit
end

-- knockback over a planned time (NPCs only: players own their own physics)
-- MOMENTUM CONSERVATION (law 2): the blow gives a fixed momentum p = m * v, so the speed (and the distance) of the throw goes as 1 / mass.
-- The reference is the attacker's own mass: an enemy as heavy as you flies the normal distance, a light one farther, a heavy one less.
local function massRatio(attackerChar: Model?, victimModel: Model?): number
	local a = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart")
	local v = victimModel and victimModel:FindFirstChild("HumanoidRootPart")
	if not (a and v) then return 1 end
	local ma, mv = a.AssemblyMass, v.AssemblyMass
	if mv <= 0 or ma <= 0 then return 1 end
	return math.clamp(ma / mv, 0.6, 1.5)
end

-- KINETIC FRICTION: the stopping distance is v^2 / (2 * mu * g), so the same push slides further on a slippery floor and less on a rough or soft one.
-- The multiplier is read from the material under the victim (1 = the distance the tuning was made for).
local FLOOR_SLIDE = {
	[Enum.Material.Ice] = 1.6, [Enum.Material.Glacier] = 1.6, [Enum.Material.Snow] = 1.25, [Enum.Material.Slate] = 1.1,
	[Enum.Material.Sand] = 0.75, [Enum.Material.Mud] = 0.7, [Enum.Material.Ground] = 0.9, [Enum.Material.Grass] = 0.9,
	[Enum.Material.LeafyGrass] = 0.85, [Enum.Material.Pebble] = 0.85, [Enum.Material.Asphalt] = 1.0,
}
local SLIDE_RAY = RaycastParams.new() -- reused: the filter is set right before each ray
SLIDE_RAY.FilterType = Enum.RaycastFilterType.Exclude
local function floorSlide(root: BasePart): number
	SLIDE_RAY.FilterDescendantsInstances = { root.Parent :: Instance }
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -8, 0), SLIDE_RAY)
	return hit and FLOOR_SLIDE[hit.Material] or 1
end

local function knock(model: Model, dir: Vector3, distance: number, time: number, slide: boolean?, lift: number?)
	if Players:GetPlayerFromCharacter(model) then return end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or root.Anchored then return end
	if not lift or lift <= 0 then distance *= floorSlide(root) end -- (the launch of hit 2 is in the air: no friction)
	pcall(function() root:SetNetworkOwner(nil) end)
	local att = Instance.new("Attachment")
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	lv.MaxForce = math.huge
	if lift and lift > 0 then
		-- LAUNCH (hit 2): the enemy is cut upward, rises about `lift` studs while drifting back, then gravity takes it down again
		local v = dir * distance + Vector3.yAxis * lift
		lv.LineDirection = v.Unit
		-- UNIFORM DECELERATION (law 4): it leaves fast and slows to a stop at the top (v0 = 2 d / t, the same height as before), then gravity takes over
		lv.LineVelocity = 2 * v.Magnitude / time
		lv.Parent = root
		TweenService:Create(lv, TweenInfo.new(time, Enum.EasingStyle.Linear), { LineVelocity = 0 }):Play()
		Debris:AddItem(lv, time)
		Debris:AddItem(att, time + 0.05)
		return
	end
	lv.LineDirection = dir
	if slide then
		-- SKID: a hard start that slows down evenly (like feet scraping the floor), the same distance over a longer time
		local T = time * 1.35
		lv.LineVelocity = 2 * distance / T
		lv.Parent = root
		TweenService:Create(lv, TweenInfo.new(T, Enum.EasingStyle.Linear), { LineVelocity = 0 }):Play()
		Debris:AddItem(lv, T + 0.02)
		Debris:AddItem(att, T + 0.07)
	else
		lv.LineVelocity = distance / time
		lv.Parent = root
		Debris:AddItem(lv, time)
		Debris:AddItem(att, time + 0.05)
	end
end

--------------------------------------------------------------------------------
-- Stun and buffs
--------------------------------------------------------------------------------
-- ONE stun state per victim: a second stun only extends the first, and the walk / jump values are restored exactly once.
local stunInfo = setmetatable({}, { __mode = "k" }) -- [model] = { ws, jp, jh, untilT }

local function applyStun(model: Model, duration: number): boolean
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 or duration <= 0 then return false end
	local now = os.clock()
	local info = stunInfo[model]
	if info and info.untilT > now then
		info.untilT = math.max(info.untilT, now + duration) -- already stunned: only longer, never shorter
		return true
	end
	info = { ws = hum.WalkSpeed, jp = hum.JumpPower, jh = hum.JumpHeight, untilT = now + duration }
	stunInfo[model] = info
	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.JumpHeight = 0
	model:SetAttribute("DarkStunned", true)
	local function check()
		local left = info.untilT - os.clock()
		if left > 0.005 then
			task.delay(left, check) -- it was extended: wait for the new end
			return
		end
		if hum.Parent then
			hum.WalkSpeed, hum.JumpPower, hum.JumpHeight = info.ws, info.jp, info.jh
		end
		if model.Parent then model:SetAttribute("DarkStunned", nil) end
		if stunInfo[model] == info then stunInfo[model] = nil end
	end
	task.delay(duration, check)
	return true
end

-- the long stun of hit 3: the same enemy cannot be stunned again for STUN_IMMUNE seconds after it ends.
-- (The short stuns of hits 1 and 2 ignore this immunity and do not start it.)
local function stun(model: Model): boolean
	local now = os.clock()
	if (stunImmuneUntil[model] or 0) > now then return false end
	if not applyStun(model, STUN_TIME) then return false end
	stunImmuneUntil[model] = now + STUN_TIME + STUN_IMMUNE
	return true
end

-- lifesteal (hit 3 only): a share of the damage that was really dealt goes back to the attacker
local function lifesteal(hum: Humanoid, dealt: number)
	if dealt > 0 and hum.Health > 0 then
		hum.Health = math.min(hum.MaxHealth, hum.Health + dealt * LIFESTEAL)
	end
end

--------------------------------------------------------------------------------
-- Normal swings (1 and 2)
--------------------------------------------------------------------------------
-- impact strength from the hit number, damage, distance and chain (all known by the server only)
local function impactStrength(index: number, dealt: number, distance: number): number
	local a = IMPACT_A[index] or 0.4
	local d = math.clamp(dealt / MAX_DAMAGE, 0, 1)
	local r = 1 - 0.6 * math.clamp((distance - NEAR_DIST) / (FAR_DIST - NEAR_DIST), 0, 1)
	return 0.45 * a + 0.25 * d + 0.20 * r
end

local function checkHits(player: Player, char: Model, seq: number, index: number)
	local _, hum, root = getOwner(player)
	if not hum then return end
	local step = COMBO[index]
	local boxCF = root.CFrame * CFrame.new(0, 0, -HIT_OFFSET)
	local list = collectTargets(boxCF, HIT_BOX * (step.hitScale or 1), char, root.Position, MAX_TARGETS)
	local now = os.clock()
	local entries = {}
	local damage = step.damage
	for _, t in list do
		if now - (lastHitAt[t.model] or -100) >= SAME_TARGET_GAP then
			lastHitAt[t.model] = now
			local dir = flatDir(root.Position, t.root.Position)
			local dist = (Vector3.new(t.root.Position.X, 0, t.root.Position.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
			local before = t.hum.Health
			t.hum:TakeDamage(damage)
			local dealt = before - t.hum.Health -- real damage (a ForceField makes it 0)
			local strength = impactStrength(index, dealt, dist)
			-- law 117 (stopping distance ~ v^2): the launch speed grows with strength (0.7 .. 1.3), the slide goes with its square
			local vK = 0.7 + 0.6 * strength
			knock(t.model, dir, step.knockDist * vK * vK * massRatio(char, t.model), step.knockTime, step.slide, step.lift)
			if dealt > 0 then
				applyStun(t.model, step.stun or 0) -- the short stun of hit 1 / 2 (no immunity involved)
			end
			table.insert(entries, {
				model = t.model, dir = dir, power = step.power, damage = dealt, killed = t.hum.Health <= 0,
				strength = strength, chained = false, distance = dist,
			})
		end
	end
	if #entries == 0 then
		feedbackRemote:FireClient(player, "miss", seq)
		if index == 2 then state.index = nil end -- hit 2 missed: the combo starts over with hit 1
	else
		feedbackRemote:FireClient(player, "hit", seq, entries, index, false)
	end
end

--------------------------------------------------------------------------------
-- Finisher (3) "Moonfall": invulnerable roll -> catch -> hold up high -> slam -> stun
--------------------------------------------------------------------------------
-- Caught NPCs are moved by physics constraints (smooth, no teleport, replicates well).
-- Side slots so several victims do not overlap.
local SLOT_X = { 0, 2.8, -2.8 }
local HOLD_HEIGHT = 4.2 -- studs above the normal standing spot while held
local HOLD_FRONT = 5.4

type Grab = {
	model: Model, root: BasePart, npc: boolean, collide: { [BasePart]: boolean }, extras: { Instance }, slot: number,
	hum: Humanoid?, platformStand: boolean?, ap: AlignPosition?, ao: AlignOrientation?,
}

local function grabModel(model: Model, root: BasePart, slot: number): Grab
	local g: Grab = { model = model, root = root, npc = Players:GetPlayerFromCharacter(model) == nil, collide = {}, extras = {}, slot = slot }
	if g.npc then
		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") then
				g.collide[p] = p.CanCollide
				p.CanCollide = false
			end
		end
		local hum = model:FindFirstChildOfClass("Humanoid")
		if hum then
			g.platformStand = hum.PlatformStand
			g.hum = hum
			hum.PlatformStand = true -- stop the humanoid from fighting the pull
		end
		pcall(function() root:SetNetworkOwner(nil) end)

		-- ONE-sided constraints: they only push the victim (a two-attachment constraint would push the attacker too)
		local a0 = Instance.new("Attachment")
		a0.Name = "DarkGrab0"
		a0.Parent = root

		local ap = Instance.new("AlignPosition")
		ap.Mode = Enum.PositionAlignmentMode.OneAttachment
		ap.Attachment0 = a0
		ap.Position = root.Position
		ap.RigidityEnabled = false
		ap.MaxForce = math.huge
		ap.MaxVelocity = 140
		ap.Responsiveness = 22
		ap.Parent = root

		local ao = Instance.new("AlignOrientation")
		ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
		ao.Attachment0 = a0
		ao.CFrame = root.CFrame
		ao.RigidityEnabled = false
		ao.MaxTorque = math.huge
		ao.Responsiveness = 18
		ao.Parent = root

		g.ap, g.ao = ap, ao
		g.extras = { a0, ap, ao }
	end
	return g
end

-- every frame: tell each held NPC where to be (in front of the attacker, lifted, facing the attacker)
local function updateGrabs(grabbed: { Grab }, attackerRoot: BasePart, height: number, front: number?)
	for _, g in grabbed do
		if g.npc and g.ap and g.ap.Parent then
			local cf = attackerRoot.CFrame * CFrame.new(SLOT_X[g.slot] or 0, height, -(front or HOLD_FRONT))
			g.ap.Position = cf.Position
			g.ao.CFrame = cf * CFrame.Angles(0, math.pi, 0)
		end
	end
end

local function release(g: Grab)
	if not g.npc then return end
	for _, e in g.extras do
		e:Destroy()
	end
	g.extras = {}
	if g.hum and g.hum.Parent then
		g.hum.PlatformStand = g.platformStand
	end
	for p, c in g.collide do
		if p.Parent then p.CanCollide = c end
	end
	-- the fling leaves the body with a huge speed and a tilt: clear the spin, keep a capped flat speed, stand it upright and let it get up
	local r = g.root
	if r and r.Parent and not r.Anchored then
		local v = r.AssemblyLinearVelocity
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude > 60 then flat = flat.Unit * 60 end
		local vy = math.clamp(v.Y, -30, 12)
		if v.Y < -10 then vy = math.min(-v.Y * 0.22, 12) end -- laws 27/28 (restitution): a hard fall keeps 22 % of its speed and hops once (max 12)
		r.AssemblyLinearVelocity = flat + Vector3.new(0, vy, 0)
		r.AssemblyAngularVelocity = Vector3.zero
		local look = r.CFrame.LookVector
		local yaw = Vector3.new(look.X, 0, look.Z)
		if yaw.Magnitude > 0.01 then
			r.CFrame = CFrame.lookAt(r.Position, r.Position + yaw.Unit)
		end
		if g.hum and g.hum.Parent and g.hum.Health > 0 then
			g.hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end
end

-- BALLISTIC THROW (NPCs only): the enemy leaves the cut with a real launch velocity and from then on only gravity, the air and the floor act
-- on it (no constraint pulls it any more). So the arc, the backwards tumble and the landing are physics, and the Client effects can follow
-- the real velocity of the body. scale = 0.7 .. 1.3 from the mass ratio (a lighter enemy flies farther).
local function launch(model: Model, dir: Vector3, scale: number)
	if Players:GetPlayerFromCharacter(model) then return end
	local root = model:FindFirstChild("HumanoidRootPart")
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart")) or root.Anchored then return end
	pcall(function() root:SetNetworkOwner(nil) end)
	root.AssemblyLinearVelocity = dir * (52 * scale) + Vector3.new(0, 32 * scale, 0)
	root.AssemblyAngularVelocity = dir:Cross(Vector3.yAxis) * 6 -- a backwards tumble (the axis lies across the throw, right-hand rule)
	if hum then
		hum.PlatformStand = true -- no standing and no walking while it flies
		task.delay(1.0, function()
			if hum.Parent and hum.Health > 0 then
				hum.PlatformStand = false
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end)
	end
end

local function runFinisher(player: Player, char: Model, seq: number, index: number)
	local step = COMBO[index]
	local hum = char:FindFirstChildOfClass("Humanoid")
	local grabbed = {}
	local shield: ForceField? = nil -- invisible shield: NO invulnerability during the roll any more, only while the caught enemy is held and cut
	local function stillValid()
		return char.Parent ~= nil and hum ~= nil and hum.Health > 0 and tool.Parent == char
	end

	local ok, err = pcall(function()
		task.wait(step.windup)

		-- roll: scan in front every frame, so a fast roll cannot skip an enemy. Stops at the first catch or after ROLL_RANGE studs.
		local startRoot = char:FindFirstChild("HumanoidRootPart")
		if not startRoot then return end
		local seen = {}
		local t0 = os.clock()
		while os.clock() - t0 < Timing[3].rollMax and #grabbed == 0 do
			if not stillValid() then return end
			local root = char:FindFirstChild("HumanoidRootPart")
			if not root then return end
			local list = (os.clock() - t0 >= Timing[3].rollMin) and collectTargets(root.CFrame * CFrame.new(0, 0, -ROLL_CATCH * 0.5), Vector3.new(ROLL_CATCH_WIDTH, 6, ROLL_CATCH + 2), char, root.Position, MAX_GRAB) or {}
			for _, t in list do
				if not seen[t.model] and #grabbed < MAX_GRAB then
					seen[t.model] = true
					table.insert(grabbed, grabModel(t.model, t.root, #grabbed + 1))
				end
			end
			RunService.Heartbeat:Wait()
		end

		if #grabbed == 0 then
			state.busyUntil = os.clock() -- nothing caught: no recovery at all, you are free at once
			feedbackRemote:FireClient(player, "miss", seq)
			return
		end

		local root = char:FindFirstChild("HumanoidRootPart")
		if not root then return end
		state.busyUntil = os.clock() + Timing[3].hold + Timing[3].slam + 0.1
		shield = Instance.new("ForceField") -- from now on nobody can interrupt the hold and the cut
		shield.Visible = false
		shield.Name = "DarkRollShield"
		shield.Parent = char
		local entries = {}
		for _, g in grabbed do
			table.insert(entries, { model = g.model, dir = flatDir(root.Position, g.root.Position), power = step.power })
		end
		feedbackRemote:FireClient(player, "grab", seq, entries, index)

		-- hold: the enemies float up in front of you while the sword is drawn back
		local h0 = os.clock()
		while os.clock() - h0 < Timing[3].hold do
			if not stillValid() then return end
			local gr = char:FindFirstChild("HumanoidRootPart")
			if not gr then return end
			local a = (os.clock() - h0) / Timing[3].hold
			updateGrabs(grabbed, gr, HOLD_HEIGHT * math.min(a * 2, 1)) -- they rise in the first half, then wait
				RunService.Heartbeat:Wait()
		end

		-- slam: the sword cuts and the enemies are thrown forward fast
		root = char:FindFirstChild("HumanoidRootPart")
		if not root then return end
		local ignore = { char }
		for _, g in grabbed do table.insert(ignore, g.model) end
		for _, g in grabbed do
			if g.ap then
				g.ap.MaxVelocity = 480
				g.ap.Responsiveness = 130
			end
		end
		local s0 = os.clock()
		while os.clock() - s0 < Timing[3].slam do
			if not stillValid() then return end
			local gr = char:FindFirstChild("HumanoidRootPart")
			if not gr then return end
			updateGrabs(grabbed, gr, 3, HOLD_FRONT + 26) -- the cut throws them forward and a little up (no longer driven into the floor)
			RunService.Heartbeat:Wait()
		end

		root = char:FindFirstChild("HumanoidRootPart")
		if not root then return end
		for _, g in grabbed do release(g) end
		local out = {}
		for _, g in grabbed do
			local h = g.model:FindFirstChildOfClass("Humanoid")
			local dir = flatDir(root.Position, g.root.Position)
			local dist = (Vector3.new(g.root.Position.X, 0, g.root.Position.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
			local dealt, stunned, strength = 0, false, 0
			if h and h.Health > 0 then
				local before = h.Health
				h:TakeDamage(step.damage)
				dealt = before - h.Health
				strength = impactStrength(index, dealt, math.min(dist, NEAR_DIST))
				launch(g.model, dir, math.clamp(massRatio(char, g.model), 0.7, 1.3))
				stunned = stun(g.model)
				if dealt > 0 then
					lifesteal(hum, dealt)
				end
			end
			table.insert(out, {
				model = g.model, dir = dir, power = step.power, damage = dealt, killed = h ~= nil and h.Health <= 0,
				strength = strength, stunned = stunned, distance = dist,
			})
		end
		feedbackRemote:FireClient(player, "slam", seq, out, index)
		task.wait(0.05)
	end)
	if not ok then
		warn("[DarkSword] finisher error:", err)
	end
	for _, g in grabbed do release(g) end
	if shield then shield:Destroy() end
	state.busyUntil = os.clock() -- no recovery after hit 3
end

-- BLINK CUT (Z skill): its last cut pushes the enemy away a few studs, WEAKLY, like a normal hit: the same knock as hits 1 and 2 (a skid that slows
-- down evenly) and a short stun. BlinkCutServer calls this function (a BindableFunction made here, so the numbers of the knock stay in one place).
local FINISH_STUN = 0.8-- seconds of stun after the last cut
local FINISH_KNOCK_TIME = 0.45-- seconds of the skid
local throwFn = (tool:FindFirstChild("BlinkThrow") or Instance.new("BindableFunction")) :: BindableFunction
throwFn.Name = "BlinkThrow"
throwFn.Parent = tool
throwFn.OnInvoke = function(model: any, char: any, dir: any, distance: any, stun: any, skid: any): boolean
	if typeof(model) ~= "Instance" or not model:IsA("Model") or typeof(dir) ~= "Vector3" then return false end
	local attacker: Model? = if typeof(char) == "Instance" and char:IsA("Model") then char else nil
	local d = if typeof(distance) == "number" then math.clamp(distance, 0, 30) else 8
	local skidTime = if typeof(skid) == "number" then math.clamp(skid, 0.1, 1.5) else FINISH_KNOCK_TIME -- (X skill: its own, longer skid and stun)
	local stunTime = if typeof(stun) == "number" then math.clamp(stun, 0, 4) else FINISH_STUN
	knock(model, dir, d * massRatio(attacker, model), skidTime, true, nil)
	return applyStun(model, stunTime)
end
--------------------------------------------------------------------------------
-- Remote
--------------------------------------------------------------------------------
attackRemote.OnServerEvent:Connect(function(player, direction, seq)
	if typeof(seq) ~= "number" or seq ~= seq or math.abs(seq) > 1e9 then return end
	if typeof(direction) ~= "Vector3" then return end -- the direction is only a hint; the hit box uses the server pose

	local char, hum, root = getOwner(player)
	if not char then return end

	local now = os.clock()
	if state.busyUntil > now then
		refuse(player, seq, "busy", state.busyUntil - now)
		return
	end
	local prev = state.index and COMBO[state.index]
	if prev then
		local left = state.lastNextAt - (now - state.last) -- (nextAt of the swing before, already divided by the attack speed it had)
		if left > COOLDOWN_TOLERANCE then
			refuse(player, seq, "cooldown", left)
			return
		end
	end

	local combo = 1
	if state.index and state.index < #COMBO and now - state.last <= COMBO_RESET then
		combo = state.index + 1
	end
	if combo == #COMBO and state.finisherReadyAt > now then combo = 1 end -- hit 3 is recharging: the combo starts over with hit 1
	state.index = combo
	state.last = now
	feedbackRemote:FireClient(player, "ack", seq, combo)

	local step = COMBO[combo]
	state.lastNextAt = step.nextAt
	if step.finisher then
		state.busyUntil = now + step.windup + Timing[3].rollMax + 0.1 -- grows when something is caught
		state.finisherReadyAt = now + FINISHER_COOLDOWN
		task.spawn(runFinisher, player, char, seq, combo)
	else
		task.delay(step.windup + step.strike * 0.9, checkHits, player, char, seq, combo)
	end
end)

tool.Unequipped:Connect(function()
	state.index = nil
end)
