--!strict
-- Script "ReaperMarkServer" (parent: Tool "TrueKatana")
-- X skill on the server. One key, two jobs:
--   * the MARK: if the owner has no mark (or looks at another enemy), X marks the rig closest to the line of sight (inside Config.Range and Config.Cone).
--     Placing a mark costs nothing. The mark STAYS until the enemy dies or is removed, the owner dies, the dash uses it up, or a new mark replaces it.
--   * the DASH: if the owner looks at the marked enemy (inside Config.Cone, inside Config.DashRange), X dashes to a point Config.BehindDistance studs
--     BEHIND it (on the far side from where the dash starts). The server plans the point (a wall on the way shortens it) and answers "go"; the client
--     moves itself there (the same way as BLINK CUT). The dash starts the cooldown and uses the mark up.
-- The cooldown is an attribute of the PLAYER ("XReadyAt" = server time when it is ready), so dying does not reset it.
-- Messages to the client: "mark" (enemy model) | "clear" | "go" (end point, enemy model) | "reject" (seconds left on the cooldown, 0 = nothing happened)
-- Message from the client: "cast" (aim direction)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local tool = script.Parent :: Tool
local remote = tool:WaitForChild("ReaperMark") :: RemoteEvent
local Config = require(tool:WaitForChild("ReaperMarkConfig") :: ModuleScript) :: { [string]: number }
local Victim = require(tool:WaitForChild("ReaperMarkVictim") :: ModuleScript) :: any
local Carry = require(tool:WaitForChild("ReaperMarkCarry") :: ModuleScript) :: { LEAD: number, TOTAL: number, IMPACT: number, DRAG: number, final: (number?) -> (Vector3, number), sample: (number, number?) -> (number, CFrame, string, boolean, number, Vector3) }

local ATTR = "XReadyAt"
local COOLDOWN_SLACK = 0.1 -- seconds a request may come early (network jitter)
local MIN_INTERVAL = 0.15 -- seconds between two requests of one player (against spam)
local BODY_RADIUS = 1.6 -- how far in front of a wall the dash stops
local MAX_REPEAT_RAYS = 8 -- characters on the path are skipped one by one

type Active = { model: Model, token: number }
local active: { [Player]: Active } = {}
local lastRequest: { [Player]: number } = {}
local busyUntil: { [Player]: number } = {} -- the grab and slam is running: no new request until it is over
local tokenCounter = 0

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 128

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

local function clear(player: Player)
	if active[player] then
		active[player] = nil
		if player.Parent then remote:FireClient(player, "clear") end
	end
end

-- a living rig (a Humanoid model that is not a player's character) and its root
local function rigParts(model: Model): (Humanoid?, BasePart?)
	if Players:GetPlayerFromCharacter(model) then return nil, nil end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hum and hum.Health > 0 and hrp and hrp:IsA("BasePart") then return hum, hrp end
	return nil, nil
end

-- the rig that is closest to the line of sight, inside the range and the cone
local function pick(char: Model, root: BasePart, aim: Vector3): Model?
	overlap.FilterDescendantsInstances = { char }
	local origin = root.Position
	local minCos = math.cos(math.rad(Config.Cone))
	local best: Model? = nil
	local bestCos = -1
	local bestDist = math.huge
	local seen: { [Model]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(origin, Config.Range, overlap) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not seen[model] then
			seen[model] = true
			local _, hrp = rigParts(model)
			if hrp then
				local offset = hrp.Position - origin
				local dist = offset.Magnitude
				if dist <= Config.Range and dist > 0.01 then
					local c = aim:Dot(offset.Unit)
					if c >= minCos and (c > bestCos + 0.01 or (math.abs(c - bestCos) <= 0.01 and dist < bestDist)) then
						best, bestCos, bestDist = model, c, dist
					end
				end
			end
		end
	end
	return best
end

local function place(player: Player, model: Model, hum: Humanoid)
	tokenCounter += 1
	local token = tokenCounter
	active[player] = { model = model, token = token }
	remote:FireClient(player, "mark", model)

	local function stillMine(): boolean
		local a = active[player]
		return a ~= nil and a.token == token
	end
	hum.Died:Once(function()
		if stillMine() then clear(player) end
	end)
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) and stillMine() then clear(player) end
	end)
end

-- the enemy is GRABBED: it is held still from the moment of "go", and from T0 on it follows the shared timeline (ReaperMarkCarry) relative to B, the
-- frame where the dash ends. The owner's client follows the same timeline for the owner. Animation only: no damage. Everything is put back at the end
-- (also when the enemy is removed or something takes too long).
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

local function runCarry(player: Player, owner: Model, model: Model, hum: Humanoid, root: BasePart, base: CFrame, startsAt: number, dragLen: number)
	local wasAnchored, wasPlatform = root.Anchored, hum.PlatformStand
	root.Anchored = true
	hum.PlatformStand = true
	local victim: any? = Victim.new(model) -- the body language of the enemy (nil for a rig that is not R15)
	local lastPhase = ""
	task.spawn(function()
		local began = os.clock()
		local limit = Carry.LEAD + Carry.TOTAL + 3
		local struck = false
		local ownerGone = false
		while os.clock() - began < limit do
			-- EXCEPTIONS: the enemy died or was removed before the blow -> the owner's client is told to let go ("abort") and the enemy's own death
			-- script (or nothing) takes over; the owner died or left -> the enemy is put back and no blow lands
			if not (root.Parent and hum.Parent) or (not struck and hum.Health <= 0) then
				if player.Parent then remote:FireClient(player, "abort") end
				if victim then victim.destroy() end
				return
			end
			local ownerHum = owner:FindFirstChildOfClass("Humanoid")
			if not owner.Parent or not ownerHum or ownerHum.Health <= 0 then
				ownerGone = true
				break
			end
			local t = workspace:GetServerTimeNow() - startsAt
			if t >= 0 then
				local _, rel, phase, done, yaw, off = Carry.sample(t, dragLen)
				root.CFrame = base * CFrame.new(off) * CFrame.Angles(0, yaw, 0) * rel
				root.AssemblyLinearVelocity = Vector3.zero
				if phase == "clamp" or phase == "hit" then -- HIT STOP: the enemy trembles in place (a few hundredths of a stud, every frame)
					root.CFrame = root.CFrame * CFrame.new((math.random() - 0.5) * 0.3, (math.random() - 0.5) * 0.2, (math.random() - 0.5) * 0.3)
				end
				if victim and phase ~= lastPhase then -- the pose of the body follows the phase of the carry
					lastPhase = phase
					local map: { [string]: string } = { grab = "grab", clamp = "grab", hoist = "grab", drag = "drag", sweep = "drag", knock = "slam", regrab = "grab", heave = "grab", rise = "lift", hang = "lift", load = "lift", slam = "slam", hit = "slam", rest = "rest" }
					local pose = map[phase]
					if pose then victim.pose(pose) end
				end
				if not struck and t >= Carry.IMPACT then -- the enemy hits the floor: THE DAMAGE
					struck = true
					do -- the blast of the slam throws loose things away from the point of impact
						local offI, yawI = Carry.final(dragLen)
						local impactAt = (base * CFrame.new(offI) * CFrame.Angles(0, yawI, 0) * CFrame.new(0, 0, -3)).Position
						pushLoose(impactAt, 28, 42, { owner, model })
					end
					if victim then -- the impact: the limbs jiggle, and ring twice more
						victim.kick()
						task.delay(0.12, function() victim.kick() end)
						task.delay(0.28, function() victim.kick() end)
					end
					if hum.Health > 0 then hum:TakeDamage(Config.Damage) end
					if hum.Health <= 0 then -- it died: its own death script takes over, nothing is put back
						if victim then victim.destroy() end
						return
					end
				end
				if done then break end
			end
			RunService.Heartbeat:Wait()
		end
		if root.Parent then
			local offF, yawF = Carry.final(dragLen)
			root.CFrame = base * CFrame.new(offF) * CFrame.Angles(0, yawF, 0) * CFrame.new(0, 0, -3.2) * CFrame.Angles(0, math.pi, 0) -- standing again, facing the owner
			root.AssemblyLinearVelocity = Vector3.zero
			root.Anchored = wasAnchored
		end
		if hum.Parent then hum.PlatformStand = wasPlatform end
		if victim then -- after the blow: the knees buckle (the stun), then the body is let go back to normal
			victim.pose("stagger")
			task.delay(math.max(Config.Stun * 0.7, 0.6), function() victim.release() end)
		end

		-- THE KNOCKBACK and THE STUN: away from the owner, through the same push and stun as the normal hits (Server.lua: BlinkThrow)
		if struck and not ownerGone and hum.Parent and hum.Health > 0 and root.Parent then
			local offK, yawK = Carry.final(dragLen)
			local look = (base * CFrame.new(offK) * CFrame.Angles(0, yawK, 0)).LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			local dir = if flat.Magnitude > 0.01 then flat.Unit else base.LookVector
			local pushed = false
			local fn = tool:FindFirstChild("BlinkThrow")
			if fn and fn:IsA("BindableFunction") then
				pushed = pcall(function()
					return fn:Invoke(model, owner, dir, Config.KnockDistance, Config.Stun, Config.KnockTime)
				end)
			end
			if not pushed then -- (Server.lua did not answer: a plain skid, v = 2 d / t)
				root.AssemblyLinearVelocity = dir * (2 * Config.KnockDistance / Config.KnockTime)
			end
		end
	end)
end

-- how far the drag can go: Carry.DRAG studs ahead of where the dash ended (the way the owner was looking at the enemy), shortened if a wall is in the way
local function dragLength(char: Model, target: Model, base: CFrame): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	params.FilterDescendantsInstances = { char, target }
	local flat = Vector3.new(base.LookVector.X, 0, base.LookVector.Z)
	if flat.Magnitude < 0.01 then return 0 end
	local hit = workspace:Raycast(base.Position, flat.Unit * (Carry.DRAG + 4), params)
	if hit then return math.clamp(hit.Distance - 4, 0, Carry.DRAG) end
	return Carry.DRAG
end

-- where the dash ends: BehindDistance studs behind the enemy (seen from the start), at the owner's own height above the floor; a wall on the way shortens it
local function planDash(char: Model, root: BasePart, target: Model, targetRoot: BasePart): Vector3
	local start = root.Position
	local flat = Vector3.new(targetRoot.Position.X - start.X, 0, targetRoot.Position.Z - start.Z)
	local dir = if flat.Magnitude > 0.01 then flat.Unit else root.CFrame.LookVector
	local dest = targetRoot.Position + dir * Config.BehindDistance

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	local ignore: { Instance } = { char, target }
	params.FilterDescendantsInstances = ignore

	-- the height: the owner stands this far above the floor under him; the end point gets the same height above the floor under IT
	local own = workspace:Raycast(start, Vector3.new(0, -12, 0), params)
	local lift = if own then start.Y - own.Position.Y else 3
	local floor = workspace:Raycast(dest + Vector3.new(0, 6, 0), Vector3.new(0, -24, 0), params)
	local finish = if floor then Vector3.new(dest.X, floor.Position.Y + lift, dest.Z) else Vector3.new(dest.X, start.Y, dest.Z)

	-- a wall between the start and the end point: stop in front of it (characters do not stop the dash)
	local path = finish - start
	local pathDir = if path.Magnitude > 0.01 then path.Unit else dir
	for _ = 1, MAX_REPEAT_RAYS do
		local hit = workspace:Raycast(start, path, params)
		if not hit then break end
		local model = hit.Instance:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			table.insert(ignore, model)
			params.FilterDescendantsInstances = ignore
		else
			local along = math.max((hit.Position - start):Dot(pathDir) - BODY_RADIUS, 0)
			return start + pathDir * along
		end
	end
	return finish
end

remote.OnServerEvent:Connect(function(player: Player, kind: any, aimValue: any)
	if kind ~= "cast" then return end
	local now = os.clock()
	if now - (lastRequest[player] or 0) < MIN_INTERVAL then return end
	if (busyUntil[player] or 0) > now then return end
	lastRequest[player] = now

	local char, _, root = owner(player)
	local aimRaw = sane(aimValue)
	if not char or not root or not aimRaw or aimRaw.Magnitude < 0.05 then return end
	local aim = aimRaw.Unit

	-- 1. the DASH: the owner looks at the enemy he has marked
	local mark = active[player]
	if mark then
		local _, targetRoot = rigParts(mark.model)
		if not targetRoot then
			clear(player) -- the marked enemy is gone
		else
			local offset = targetRoot.Position - root.Position
			local dist = offset.Magnitude
			if dist > 0.01 and aim:Dot(offset.Unit) >= math.cos(math.rad(Config.Cone)) then
				if dist > Config.DashRange then
					remote:FireClient(player, "reject", 0) -- looking at it, but too far for the dash
					return
				end
				local serverNow = workspace:GetServerTimeNow()
				local ready = player:GetAttribute(ATTR)
				local left = (if typeof(ready) == "number" then ready else 0) - serverNow
				if left > COOLDOWN_SLACK then
					remote:FireClient(player, "reject", left)
					return
				end
				local finish = planDash(char, root, mark.model, targetRoot)
				player:SetAttribute(ATTR, serverNow + Config.Cooldown)
				local targetHum = rigParts(mark.model)
				local face = Vector3.new(targetRoot.Position.X, finish.Y, targetRoot.Position.Z)
				if (face - finish).Magnitude < 0.05 then face = finish + root.CFrame.LookVector end
				local base = CFrame.lookAt(finish, face)
				local startsAt = serverNow + Carry.LEAD
				local dragLen = dragLength(char, mark.model, base)
				remote:FireClient(player, "go", finish, mark.model, startsAt, base, dragLen)
				if targetHum then runCarry(player, char, mark.model, targetHum, targetRoot, base, startsAt, dragLen) end
				busyUntil[player] = now + Carry.LEAD + Carry.TOTAL + 0.3
				clear(player) -- the mark is used up
				return
			end
		end
	end

	-- 2. the MARK: any other press marks the enemy closest to the line of sight (and replaces the old mark)
	local target = pick(char, root, aim)
	if not target then
		remote:FireClient(player, "reject", 0)
		return
	end
	local hum = rigParts(target)
	if hum then place(player, target, hum) end
end)

local function forget(player: Player)
	active[player] = nil
end

Players.PlayerRemoving:Connect(function(player: Player)
	forget(player)
	lastRequest[player] = nil
	busyUntil[player] = nil
end)

local function watch(player: Player)
	player.CharacterRemoving:Connect(function() -- the owner died or left the character: the mark does not follow to the next life
		clear(player)
	end)
end
for _, player in Players:GetPlayers() do watch(player) end
Players.PlayerAdded:Connect(watch)
