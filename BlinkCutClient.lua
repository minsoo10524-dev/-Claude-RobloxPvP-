--!strict
-- LocalScript "BlinkCutClient" (parent: Tool "TrueKatana")
-- Z skill BLINK CUT on the client: the key (a touch button is made too), the windup, the dash (this player moves itself, along the path the
-- server planned), motion and sound.
-- Flow: press Z -> windup motion and sound start AT ONCE (this hides the network delay) and the request goes to the server -> the server
-- answers "go" with the end point (and the enemy it will catch, if there is one) -> when the windup is over the dash starts.
--   * no enemy: the dash ends with a cross cut (a plain blink)
--   * an enemy: the dash ends in front of it and the CUTS begin: the server sends "slash" 25 times (Config.Slashes), then "catch", "fling" and "end". The client
--     hands each cut to the main client script (Client.lua) through the BindableEvent "BlinkBridge", because that script owns the sword
--     motion (hits 1 and 2), the slash effect, the hit effect on the enemy and the impact sound. The same event locks the normal attack
--     ("begin" ... "end") so a click cannot break the sequence.
-- COOLDOWN (client side): the number on the label of the skill is drawn by SkillGuiMotion. This script gives it the client's own guess the
-- moment Z is pressed, as the client-only attribute ZReadyAtLocal (server time; an attribute set on the client is never sent to the server),
-- so the countdown starts with no delay. The server's value (the player attribute ZReadyAt) is read as well and the later of the two counts.
-- If the server refuses or never answers, the guess goes back to what it was. The server still decides whether a cast is allowed.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
if not player then return end
local toolParent = script.Parent
if not (toolParent and toolParent:IsA("Tool")) then return end
local tool: Tool = toolParent

-- everything the skill needs must be inside the tool: if something is missing the script says WHICH one and stops (it never waits forever)
local function need(name: string, class: string): Instance?
	local found = tool:WaitForChild(name, 10)
	if not (found and found:IsA(class)) then
		warn("[BlinkCutClient] the tool needs a " .. class .. " named " .. name)
		return nil
	end
	return found
end
local remoteInstance = need("BlinkCut", "RemoteEvent")
local configModule = need("BlinkCutConfig", "ModuleScript")
local animModule = need("BlinkCutAnim", "ModuleScript")
local sfxModule = need("BlinkCutSfx", "ModuleScript")
if not (remoteInstance and configModule and animModule and sfxModule) then return end
local remote = remoteInstance :: RemoteEvent
local Config = require(configModule :: ModuleScript) :: { [string]: number }
local Anim = require(animModule :: ModuleScript) :: any
local Sfx = require(sfxModule :: ModuleScript) :: any

local ACTION = "BlinkCut"
local KEY = Enum.KeyCode.Z
local ATTR = "ZReadyAt" -- the server's value
local GUESS = "ZReadyAtLocal" -- the client's own guess
local GIVE_UP = 1 -- seconds after the windup the client waits for the server's "go"
-- SKID: after the dash the body slides on with the speed that kinetic friction stops in SKID_DISTANCE studs: from v^2 = 2 a d with a = mu g,
-- v = sqrt(2 mu g d). Ice lets it slide farther, sand and mud stop it sooner (the same table as the enemy's skid in Server.lua).
local SKID_DISTANCE, FRICTION, GRAVITY = 2, 0.7, 196.2 -- studs, coefficient of friction, studs/s^2
local FLOOR_SLIDE: { [Enum.Material]: number } = {
	[Enum.Material.Ice] = 1.6, [Enum.Material.Glacier] = 1.6, [Enum.Material.Snow] = 1.25, [Enum.Material.Slate] = 1.1,
	[Enum.Material.Sand] = 0.75, [Enum.Material.Mud] = 0.7, [Enum.Material.Ground] = 0.9, [Enum.Material.Grass] = 0.9,
	[Enum.Material.LeafyGrass] = 0.85, [Enum.Material.Pebble] = 0.85,
}
local FINISH_TIME = 0.45 -- seconds the finishing pose is held before it lets go
local BRACE_TIME = 0.1 -- seconds the braking pose is held before the cuts (or the cross cut) take over
local EARLY = 0.05 -- seconds a press may come before the cooldown is over (the server has its own slack)
local END_WAIT = 2 -- seconds beyond the longest sequence after which the client unlocks itself if the server's "end" never comes

type Cast = { seq: number, t0: number, handle: any?, dashed: boolean, prevGuess: number, victim: Model?, grabbing: boolean }
local cast: Cast? = nil
local seq = 0
local equipped = false

--------------------------------------------------------------------------------
-- The cooldown (client side)
--------------------------------------------------------------------------------
local function number(value: any): number
	return if typeof(value) == "number" then value else 0
end

-- the later of the client's guess and the server's value: the server's value is kept on the player, so it survives a respawn
local function readyAt(): number
	return math.max(number(player:GetAttribute(ATTR)), number(player:GetAttribute(GUESS)))
end

local function remaining(): number
	return readyAt() - workspace:GetServerTimeNow()
end

local function setGuess(t: number)
	player:SetAttribute(GUESS, t)
end

--------------------------------------------------------------------------------
-- The bridge to Client.lua
--------------------------------------------------------------------------------
-- kind = "dash" (from, to) | "begin" | "slash" (index, victim) | "end"; Client.lua creates the event and listens to it (nothing happens if it is not there)
local function bridge(kind: string, index: number?, victim: Model?, from: Vector3?, to: Vector3?)
	local event = tool:FindFirstChild("BlinkBridge")
	if event and event:IsA("BindableEvent") then event:Fire(kind, index, victim, from, to) end
end

--------------------------------------------------------------------------------
-- The cast
--------------------------------------------------------------------------------
local function parts(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if char and hum and hum.Health > 0 and root and root:IsA("BasePart") then return char, hum, root end
	return nil, nil, nil
end

local function release(mine: Cast)
	if cast == mine then cast = nil end
	local h = mine.handle
	if h then h.release() end
end

-- the cuts are over (or must stop): the normal attack is free again
local function endGrab(mine: Cast)
	if mine.grabbing then
		mine.grabbing = false
		bridge("end")
	end
	release(mine)
end

-- the cast did not happen: the guess goes back to what it was (the server's value, if it set one, still counts through readyAt)
local function giveBack(mine: Cast)
	setGuess(mine.prevGuess)
end

local function skidSpeed(root: BasePart, char: Model): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -8, 0), params)
	local k = hit and FLOOR_SLIDE[hit.Material] or 1
	return math.sqrt(2 * FRICTION * GRAVITY * SKID_DISTANCE * k)
end

-- the dash is over and an enemy was caught: the cuts take over
local function beginGrab(mine: Cast, root: BasePart)
	local victim = mine.victim
	if not victim then return end
	mine.grabbing = true
	bridge("begin")
	local h = mine.handle
	if h then
		h.brace() -- the body brakes in front of the enemy...
		task.delay(BRACE_TIME, h.release) -- ...then the cuts bring their own motion (hits 1 and 2)
	end
	local vroot = victim:FindFirstChild("HumanoidRootPart")
	if vroot and vroot:IsA("BasePart") then -- face the enemy
		local flat = Vector3.new(vroot.Position.X - root.Position.X, 0, vroot.Position.Z - root.Position.Z)
		if flat.Magnitude > 0.01 then root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit) end
	end
	task.delay(Config.Slashes * Config.SlashGap + END_WAIT, function() -- the server's "end" never came: unlock anyway
		if mine.grabbing then endGrab(mine) end
	end)
end

local function runDash(mine: Cast, finish: Vector3)
	local char, _, root = parts()
	if cast ~= mine or not char or not root then
		endGrab(mine)
		return
	end
	mine.dashed = true
	local from = root.Position
	local target = Vector3.new(finish.X, from.Y, finish.Z) -- the height stays the player's own
	local delta = target - from
	local h = mine.handle
	if delta.Magnitude < 0.5 then -- no room to dash (a wall, or the enemy is right here)
		if mine.victim then
			beginGrab(mine, root)
		else
			if h then h.cut() end
			Sfx.cut(root)
			task.delay(0.12, release, mine)
		end
		return
	end
	local dir = delta.Unit

	local saved: { BasePart } = {} -- no bumping into the bodies on the path
	for _, p in char:GetDescendants() do
		if p:IsA("BasePart") and p.CanCollide then
			table.insert(saved, p)
			p.CanCollide = false
		end
	end
	if h then h.dash() end
	Sfx.dash(root, Config.DashTime)
	bridge("dash", nil, nil, from, target) -- the speed lines, the afterimages and the glow of the blink (drawn by Client.lua)

	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.PreSimulation:Connect(function()
		local t = math.clamp((os.clock() - t0) / Config.DashTime, 0, 1)
		local alive = root.Parent ~= nil
		if alive then
			local p = from:Lerp(target, 1 - (1 - t) * (1 - t)) -- fast at the start, slowing down: a "blink"
			root.CFrame = CFrame.lookAt(p, p + dir)
			root.AssemblyLinearVelocity = Vector3.zero
		end
		if t >= 1 or not alive then
			if conn then
				conn:Disconnect()
				conn = nil
			end
			for _, p in saved do
				if p.Parent then p.CanCollide = true end
			end
			if not alive then
				endGrab(mine)
			elseif mine.victim then
				root.AssemblyLinearVelocity = Vector3.zero -- standing in front of the enemy: no carry
				beginGrab(mine, root)
			else
				root.AssemblyLinearVelocity = dir * skidSpeed(root, char) -- the body slides on and friction stops it
				if h then h.brace() end
				task.delay(BRACE_TIME, function() -- the braking pose, then the cross cut
					if h then h.cut() end
					Sfx.cut(root)
				end)
				task.delay(BRACE_TIME + 0.15, release, mine)
			end
		end
	end)
end

local function startCast()
	if cast or not equipped then return end
	local char, _, root = parts()
	if not char or not root then return end
	if remaining() > EARLY then return end -- still cooling (the server checks again)

	local cam = workspace.CurrentCamera
	local look = if cam then cam.CFrame.LookVector else root.CFrame.LookVector
	local aim = Vector3.new(look.X, 0, look.Z)
	if aim.Magnitude < 0.05 then aim = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z) end -- the camera looks straight up or down
	if aim.Magnitude < 0.05 then return end

	seq += 1
	local mine: Cast = {
		seq = seq, t0 = os.clock(), handle = Anim.new(char), dashed = false,
		prevGuess = number(player:GetAttribute(GUESS)), victim = nil, grabbing = false,
	}
	cast = mine
	setGuess(workspace:GetServerTimeNow() + Config.Cooldown) -- the countdown starts now, with no wait for the server
	if mine.handle then mine.handle.windup() end
	Sfx.windup(root)
	remote:FireServer("cast", seq, aim.Unit)
	task.delay(Config.Windup + GIVE_UP, function() -- the server never answered: let go
		if cast == mine and not mine.dashed then
			release(mine)
			giveBack(mine)
		end
	end)
end

remote.OnClientEvent:Connect(function(kind: any, id: any, value: any, extra: any)
	local mine = cast
	if kind == "go" then
		if mine and mine.seq == id and typeof(value) == "Vector3" then
			if typeof(extra) == "Instance" and extra:IsA("Model") then mine.victim = extra end -- the enemy that will be caught
			task.delay(math.max(Config.Windup - (os.clock() - mine.t0), 0), runDash, mine, value) -- the dash starts when the windup is over
		end
	elseif kind == "slash" then
		if mine and mine.seq == id and typeof(value) == "number" then
			bridge("slash", value, if typeof(extra) == "Instance" and extra:IsA("Model") then extra else mine.victim)
		end
	elseif kind == "finish" then
		if mine and mine.seq == id and typeof(value) == "Instance" and value:IsA("Model") then
			bridge("finish", nil, value) -- the last cut: the heavy chop and its effects (drawn by Client.lua)
			task.delay(Config.FinishWindup + 0.3, function() -- ...and then the sword arm sweeps out in the calm finishing pose
				local char = parts()
				local finishing = if char then Anim.new(char) else nil
				if finishing then
					finishing.finish()
					task.delay(FINISH_TIME, finishing.release)
				end
			end)
		end
	elseif kind == "end" then
		if mine and mine.seq == id then endGrab(mine) end
	elseif kind == "reject" then
		if mine and mine.seq == id then
			release(mine)
			if typeof(value) == "number" and value > 0 then -- the server says how long is left
				setGuess(workspace:GetServerTimeNow() + value)
			else
				giveBack(mine)
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Equip / unequip
--------------------------------------------------------------------------------
local function onEquipped()
	equipped = true
	ContextActionService:BindAction(ACTION, function(_, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then startCast() end
		return Enum.ContextActionResult.Sink
	end, true, KEY) -- (true = a touch button too)
	ContextActionService:SetTitle(ACTION, "Z")
end

local function onUnequipped()
	equipped = false
	ContextActionService:UnbindAction(ACTION)
	local mine = cast
	if mine then
		if mine.grabbing then
			endGrab(mine) -- the sequence is over for this player: unlock the normal attack
		elseif not mine.dashed then
			release(mine)
			giveBack(mine)
		end
	end
end

tool.Equipped:Connect(onEquipped)
tool.Unequipped:Connect(onUnequipped)
tool.Destroying:Connect(function()
	ContextActionService:UnbindAction(ACTION)
end)

if tool.Parent == player.Character then onEquipped() end
