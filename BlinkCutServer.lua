--!strict
-- Script "BlinkCutServer" (parent: Tool "TrueKatana")
-- Z skill BLINK CUT on the server: checks the request, starts the cooldown, plans the dash (a ray that stops at walls but not at
-- characters). With no enemy on the path it is only a blink. If the path meets an enemy, the dash stops in front of it, the enemy is HELD
-- and cut many times (Config.Slashes): every cut is a damage tick and a message to the owner's client, which plays hit 1 / hit 2 with their
-- effects and sounds. The last cut throws the enemy. Everything that was changed (anchored enemy, frozen owner) is put back at the end,
-- also when something goes wrong or the owner dies / puts the sword away.
-- The cooldown is an attribute of the PLAYER ("ZReadyAt" = server time when it is ready), so dying does not reset it. The client keeps its own
-- copy of the cooldown for the display (see BlinkCutClient); this one is the one that counts.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local tool = script.Parent :: Tool
local remote = tool:WaitForChild("BlinkCut") :: RemoteEvent
local Config = require(tool:WaitForChild("BlinkCutConfig") :: ModuleScript) :: { [string]: number }

local ATTR = "ZReadyAt"
local COOLDOWN_SLACK = 0.1 -- seconds a request may come early (network jitter)
local BODY_RADIUS = 1.6 -- how far in front of a wall the dash stops
local MAX_REPEAT_RAYS = 8 -- characters on the path are skipped one by one
local SEQUENCE_DELAY = 0.08 -- seconds after the dash before the first cut

type Target = { model: Model, hum: Humanoid, root: BasePart }

local busyUntil = 0 -- one tool = one owner
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 64

local function sane(v: any): Vector3?
	if typeof(v) ~= "Vector3" then return nil end
	local x, y, z = v.X, v.Y, v.Z
	if x ~= x or y ~= y or z ~= z or math.abs(x) > 1e4 or math.abs(y) > 1e4 or math.abs(z) > 1e4 then return nil end -- no NaN, no huge values
	return v
end

local function owner(player: Player): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	if not char or tool.Parent ~= char then return nil, nil, nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not root or not root:IsA("BasePart") then return nil, nil, nil end
	return char, hum, root
end

-- where the dash ends: straight ahead, stopped by walls (characters do not stop it: the cut passes through them)
local function plan(start: Vector3, dir: Vector3, char: Model): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	local ignore: { Instance } = { char }
	params.FilterDescendantsInstances = ignore
	for _ = 1, MAX_REPEAT_RAYS do
		local hit = workspace:Raycast(start, dir * Config.Range, params)
		if not hit then break end
		local model = hit.Instance:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			table.insert(ignore, model)
			params.FilterDescendantsInstances = ignore
		else
			local along = math.max((hit.Position - start):Dot(dir) - BODY_RADIUS, 0)
			return start + dir * along
		end
	end
	return start + dir * Config.Range
end

-- the first living enemy on the path (the nearest one along the dash)
local function firstEnemy(char: Model, start: Vector3, finish: Vector3, dir: Vector3): Target?
	overlap.FilterDescendantsInstances = { char }
	local mid = (start + finish) / 2
	local size = Vector3.new(Config.HitWidth, Config.HitHeight, (finish - start).Magnitude + 4)
	local best: Target? = nil
	local bestAlong = math.huge
	local seen: { [Model]: boolean } = {}
	for _, part in workspace:GetPartBoundsInBox(CFrame.lookAt(mid, mid + dir), size, overlap) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not seen[model] then
			seen[model] = true
			local hum = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if hum and hum.Health > 0 and root and root:IsA("BasePart") then
				local along = (root.Position - start):Dot(dir)
				if along < bestAlong then
					best, bestAlong = { model = model, hum = hum, root = root }, along
				end
			end
		end
	end
	return best
end

-- holds the enemy still; returns the function that lets it go again
local function hold(v: Target): () -> ()
	local root, hum = v.root, v.hum
	local wasAnchored, wasPlatform = root.Anchored, hum.PlatformStand
	root.Anchored = true
	hum.PlatformStand = true
	return function()
		if root.Parent then root.Anchored = wasAnchored end
		if hum.Parent then hum.PlatformStand = wasPlatform end
	end
end

-- the knockback of the last cut: a WEAK push (a few studs, like a normal hit; Server.lua does it with its own knock and a short stun when asked here).
-- It only works on NPCs (a player owns the physics of his own body), like the knockback of the normal hits. Returns true when the enemy was pushed.
local function throw(victim: Target, char: Model?, dir: Vector3, distance: number): boolean
	if Players:GetPlayerFromCharacter(victim.model) then return false end
	local fn = tool:FindFirstChild("BlinkThrow")
	if fn and fn:IsA("BindableFunction") then
		local ok = pcall(function() return fn:Invoke(victim.model, char, dir, distance) end)
		if ok then return true end
	end
	-- fallback when Server.lua does not answer: a short skid away from the owner (v = 2 d / t, as the knock of the normal hits)
	victim.root.AssemblyLinearVelocity = dir * (2 * distance / 0.3)
	return true
end

-- THE LANDING: the throw is hit 3's (Server.lua). What the Z skill adds is what happens when the thrown enemy comes down:
--   * it BOUNCES like a ball that keeps a part of its speed (restitution e: the speed after the impact = e * the speed before), twice at most;
--   * the FIRST impact sends a SHOCK WAVE: the characters around are pushed away, the harder the closer (the push falls as 1 / (1 + r / 6));
--   * the owner's client is told at every impact how fast the enemy hit the floor, to play the camera and the effects.
-- Only NPCs are pushed or bounced (a player owns the physics of his own body), like with hit 3.
local BOUNCE_REST = 0.42 -- restitution of the body on the floor
local BOUNCE_MAX_SPEED = 45 -- studs/s: the fastest bounce
local BOUNCES = 2 -- how many times it bounces
local IMPACT_MIN = 22 -- studs/s: a slower fall is no impact (it neither bounces nor counts)
local SHOCK_RADIUS = 22 -- studs
local SHOCK_SPEED = 38 -- studs/s of the push in the middle of the wave, for an impact of 60 studs/s
local LAND_WATCH = 3 -- seconds the landing is watched after the throw
-- FRICTION AND TUMBLE at an impact: the sliding speed that is kept comes from the floor (kinetic friction: ice keeps it, sand and mud take it; the same
-- table as the skid of the normal hits), and part of the energy of the fall turns into a SPIN (a body that lands does not stay upright).
local SLIDE_KEEP = 0.7 -- the share of the sliding speed kept on a normal floor
local TUMBLE = 0.12 -- rad/s of spin per stud/s of the fall speed (at most about half of that on each axis)
local FLOOR_SLIDE: { [Enum.Material]: number } = {
	[Enum.Material.Ice] = 1.6, [Enum.Material.Glacier] = 1.6, [Enum.Material.Snow] = 1.25, [Enum.Material.Slate] = 1.1,
	[Enum.Material.Sand] = 0.75, [Enum.Material.Mud] = 0.7, [Enum.Material.Ground] = 0.9, [Enum.Material.Grass] = 0.9,
	[Enum.Material.LeafyGrass] = 0.85, [Enum.Material.Pebble] = 0.85,
}

local function shockwave(origin: Vector3, strength: number, skip: { Instance })
	overlap.FilterDescendantsInstances = skip
	local seen: { [Model]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(origin, SHOCK_RADIUS, overlap) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not seen[model] and not Players:GetPlayerFromCharacter(model) then
			seen[model] = true
			local hum = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if hum and hum.Health > 0 and root and root:IsA("BasePart") and not root.Anchored then
				local away = Vector3.new(root.Position.X - origin.X, 0, root.Position.Z - origin.Z)
				local d = away.Magnitude
				local f = strength / (1 + d / 6)
				pcall(function() root:SetNetworkOwner(nil) end)
				root.AssemblyLinearVelocity = (if d > 0.05 then away.Unit else Vector3.zAxis) * SHOCK_SPEED * f + Vector3.new(0, 16 * f, 0)
			end
		end
	end
end

local function watchLanding(player: Player, seq: number, victim: Target, attacker: Model?)
	task.spawn(function()
		local root, hum = victim.root, victim.hum
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { victim.model }
		local reach = hum.HipHeight + root.Size.Y / 2 + 0.8 -- how close to the floor counts as "on the floor"
		local t0 = os.clock()
		local lastVy = 0
		local lastImpact = -1
		local bounces = 0
		while os.clock() - t0 < LAND_WATCH and root.Parent and hum.Health > 0 do
			local v = root.AssemblyLinearVelocity
			local ground = if os.clock() - lastImpact > 0.25 and lastVy < -IMPACT_MIN then workspace:Raycast(root.Position, Vector3.new(0, -reach, 0), params) else nil
			if ground then
				lastImpact = os.clock()
				local speed = -lastVy
				remote:FireClient(player, "land", seq, victim.model, speed, bounces)
				if bounces == 0 then
					shockwave(root.Position, math.clamp(speed / 60, 0.5, 1.6), { victim.model, attacker or victim.model })
				end
				local keep = math.clamp(SLIDE_KEEP * (FLOOR_SLIDE[ground.Material] or 1), 0.3, 0.95) -- friction: what is left of the sliding speed
				root.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * (speed * TUMBLE) -- the tumble
				if bounces >= BOUNCES then
					root.AssemblyLinearVelocity = Vector3.new(v.X * keep, v.Y, v.Z * keep) -- the last impact: it slides on and stops
					return
				end
				bounces += 1
				root.AssemblyLinearVelocity = Vector3.new(v.X * keep, math.min(speed * BOUNCE_REST, BOUNCE_MAX_SPEED), v.Z * keep)
				lastVy = root.AssemblyLinearVelocity.Y
			else
				lastVy = v.Y
			end
			RunService.Heartbeat:Wait()
		end
	end)
end

-- PHYSICS OF THE BLOW: loose things nearby (unanchored parts that are not characters) are thrown outward by the blast. It is a change of VELOCITY (impulse = mass x dv), so a
-- heavy crate and a light plank get the same kick, like a real blast wave; the push falls off with the distance as 1 / (1 + r / 6) and has an upward part.
local function pushLoose(origin: Vector3, radius: number, speed: number, skip: { Instance })
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = skip
	params.MaxParts = 120
	local seen: { [BasePart]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(origin, radius, params) do
		local assemblyRoot = part.AssemblyRootPart
		if assemblyRoot and not assemblyRoot.Anchored and not seen[assemblyRoot] then
			seen[assemblyRoot] = true
			local model = assemblyRoot:FindFirstAncestorOfClass("Model")
			if not (model and model:FindFirstChildOfClass("Humanoid")) then -- characters have their own physics
				local offset = assemblyRoot.Position - origin
				local dist = offset.Magnitude
				local out = if dist > 0.1 then offset.Unit else Vector3.yAxis
				local push = (out + Vector3.new(0, 0.45, 0)).Unit * (speed / (1 + dist / 6))
				pcall(function()
					assemblyRoot:ApplyImpulse(push * assemblyRoot.AssemblyMass)
				end)
			end
		end
	end
end

-- the cuts: runs from the moment the dash has ended
local function slashes(player: Player, seq: number, victim: Target)
	local ownerChar, ownerHum = owner(player)
	local completed = false -- true when all the cuts were made: only then the enemy is thrown
	local walk = ownerHum and ownerHum.WalkSpeed or 16
	local letGo = hold(victim)
	if ownerHum then ownerHum.WalkSpeed = 0 end -- the owner stands still while he cuts
	local lastDir = Vector3.zAxis

	local ok, err = pcall(function()
		for i = 1, Config.Slashes do
			local char, _, root = owner(player)
			if not char or not root then return end -- the owner died or put the sword away
			if victim.hum.Health <= 0 or not victim.root.Parent then return end -- the enemy is gone
			local away = Vector3.new(victim.root.Position.X - root.Position.X, 0, victim.root.Position.Z - root.Position.Z)
			if away.Magnitude > Config.HoldRange then return end -- pulled apart
			if away.Magnitude > 0.01 then lastDir = away.Unit end

			if i == Config.Slashes then
				-- THE LAST CUT is a heavier chop: the client starts its wind-up now, and the damage and the knockback come when it strikes
				remote:FireClient(player, "finish", seq, victim.model)
				task.wait(Config.FinishWindup)
				if victim.hum.Health <= 0 or not victim.root.Parent then return end
				victim.hum:TakeDamage(Config.FinalDamage)
					pushLoose(victim.root.Position, 24, 30, { victim.model, ownerChar or victim.model }) -- the last cut throws loose things aside
				completed = true
			else
				victim.hum:TakeDamage(Config.SlashDamage)
				remote:FireClient(player, "slash", seq, if i % 2 == 1 then 1 else 2, victim.model) -- hits 1 and 2 take turns
				task.wait(Config.SlashGap)
			end
		end
	end)
	if not ok then warn("[BlinkCutServer] the cuts stopped:", err) end

	-- everything is put back, whatever happened
	letGo()
	if completed and victim.root.Parent then
		-- the last cut has struck (its damage was dealt above): the enemy is pushed away a few studs
		if victim.hum.Health > 0 then throw(victim, ownerChar, lastDir, Config.FinishKnock) end
	end
	if ownerHum and ownerHum.Parent then ownerHum.WalkSpeed = walk end -- the owner stands still until the finish is over
	remote:FireClient(player, "end", seq)
end

local connection = remote.OnServerEvent:Connect(function(player: Player, action: any, seq: any, aim: any)
	if action ~= "cast" or typeof(seq) ~= "number" or seq ~= seq then return end
	local want = sane(aim)
	if not want then return end
	local flat = Vector3.new(want.X, 0, want.Z)
	if flat.Magnitude < 0.05 then return end
	local char, _, root = owner(player)
	if not char or not root then return end

	local now = os.clock()
	local serverNow = workspace:GetServerTimeNow()
	local readyAt = player:GetAttribute(ATTR)
	if typeof(readyAt) == "number" and readyAt - serverNow > COOLDOWN_SLACK then
		remote:FireClient(player, "reject", seq, readyAt - serverNow)
		return
	end
	if now < busyUntil then
		remote:FireClient(player, "reject", seq, 0)
		return
	end

	local dir = flat.Unit
	local start = root.Position
	local finish = plan(start, dir, char)
	local victim = firstEnemy(char, start, finish, dir)
	local stopAt = finish
	if victim then -- the dash ends a few studs in front of the enemy
		local along = math.clamp((victim.root.Position - start):Dot(dir) - Config.StopDistance, 0, (finish - start).Magnitude)
		stopAt = start + dir * along
	end

	player:SetAttribute(ATTR, serverNow + Config.Cooldown)
	local dashEnd = Config.Windup + Config.DashTime
	busyUntil = now + dashEnd + 0.3 + (if victim then SEQUENCE_DELAY + Config.Slashes * Config.SlashGap + 1 else 0) -- (+1: the hold and the throw of the finish)
	remote:FireClient(player, "go", seq, stopAt, if victim then victim.model else nil)

	if victim then
		task.delay(dashEnd + SEQUENCE_DELAY, slashes, player, seq, victim)
	end
	task.delay(dashEnd + 0.6, function() -- the client moved itself: bring back a player who went too far
		local c, _, r = owner(player)
		if c and r and (r.Position - start).Magnitude > Config.Range + Config.PositionSlack then
			local pivot = c:GetPivot()
			c:PivotTo(CFrame.new(stopAt.X, pivot.Y, stopAt.Z) * pivot.Rotation)
		end
	end)
end)

tool.Destroying:Connect(function()
	connection:Disconnect()
end)
