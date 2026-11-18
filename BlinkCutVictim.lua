--!strict
-- ModuleScript "BlinkCutVictim" (parent: Tool "TrueKatana")
-- The hit animation that belongs only to BLINK CUT. Two parts:
--  1. While the enemy is held and cut, it SHAKES on the spot, harder with every cut, and rings out after the last one.
--     Science (PHYSICS): RESONANCE. Every joint is a spring (a damped harmonic oscillator, solved exactly each frame). The cuts push the body at a
--     steady rate, and hit 1 and hit 2 push in OPPOSITE directions, so one full swing of the push takes two cuts. If the natural frequency of the
--     spring is exactly that one (f0 = 1 / (2 * gap between the cuts)), every new push arrives just when the joint is swinging the same way, so the
--     swings ADD UP: the amplitude grows cut after cut (with a damping ratio z it settles near 1 / (2 z) times one push).
--  2. fling(): the last cut throws the enemy. In the air the body is arched back with the arms thrown up (the joints follow the waist through the
--     springs below), and it FLUTTERS: the air sheds vortices behind a body at the frequency f = St * v / D (Strouhal number St about 0.2, D the width
--     of a limb, about 1 stud), so a limb that flies at 52 studs/s trembles at about 10 Hz; neighbouring limbs shake in opposite phase.
-- RECOIL (the body as a whole): every cut gives the held enemy a push along the direction of the cut (momentum: the speed the body gets is the impulse
-- divided by its mass) and the hold pulls it back like a spring, so the whole body sways a little about its place instead of standing frozen. A cut
-- upward (hit 2) lifts it a little, a cut downward (hit 1) presses it down. It is shown through the root joint, so the anchored body can sway.
-- The waist is the driven joint; the neck, the arms and the legs follow it through a spring each, so they lag behind and whip like a rag doll.
-- Only R15 victims move (other rigs return nil: the effects on them still play).

local RunService = game:GetService("RunService")

local DAMPING = 0.28 -- low damping: the swings add up (a little more than before, so the shaking is a tremble, not a convulsion)
local PUSH = 0.42 -- how hard one cut pushes the waist (the peak of one swing is about this, in units of the joint's range)
local MAX_AMOUNT = 1.1 -- the joints never swing farther than this many units
local RING_Z = 0.5 -- damping after the last cut: it rings out quickly
local RELEASE_TIME = 0.5 -- seconds until the joints are let go after the last cut
local FLY_W, FLY_Z = 22, 0.45 -- the springs in flight: stiffer than in the hold, damped more
local FLY_ARCH = -1.0 -- the waist's target in flight (negative = arched back; the limbs follow it)
local FLUTTER = 0.14 -- amplitude of the flutter at full speed (units of the joint's range)
local STROUHAL = 0.2
local LIMB_WIDTH = 1 -- studs
local REF_SPEED = 52 -- studs/s: the speed of a throw (the flutter is full at this speed)
local RECOIL_SPEED = 5 -- studs/s the body gets from one cut (the sway is about v / w = 0.25 studs)
local RECOIL_W, RECOIL_Z = 20, 0.5 -- the hold as a spring: speed and damping of the sway

type Spring = { x: number, v: number }
type Joint = Motor6D | AnimationConstraint
type Part = {
	joint: Joint, spring: Spring, scale: number, ax: number, ay: number, az: number,
	follow: string?, gain: number, -- follows another part: its target is that part's amount times gain
}
export type Handle = { hit: (index: number, strength: number?, dir: Vector3?) -> (), fling: () -> (), finish: () -> () }

-- degrees at amount 1, and the axis of the bend (x = forward / up, y = turn, z = roll); signs may need flipping on another rig
local SPEC: { [string]: { scale: number, ax: number, ay: number, az: number, follow: string?, gain: number? } } = {
	Waist = { scale = 24, ax = -1, ay = 0.35, az = 0.2 },
	Neck = { scale = 30, ax = 1, ay = -0.5, az = 0, follow = "Waist", gain = -1.2 },
	RightShoulder = { scale = 55, ax = 1, ay = 0, az = 0.5, follow = "Waist", gain = -1.3 },
	LeftShoulder = { scale = 55, ax = 1, ay = 0, az = -0.5, follow = "Waist", gain = -1.3 },
	RightElbow = { scale = 40, ax = 1, ay = 0, az = 0, follow = "RightShoulder", gain = 0.8 },
	LeftElbow = { scale = 40, ax = 1, ay = 0, az = 0, follow = "LeftShoulder", gain = 0.8 },
	RightHip = { scale = 20, ax = 1, ay = 0, az = 0.2, follow = "Waist", gain = 0.9 },
	LeftHip = { scale = 20, ax = -1, ay = 0, az = -0.2, follow = "Waist", gain = 0.9 },
	RightKnee = { scale = 26, ax = -1, ay = 0, az = 0, follow = "RightHip", gain = 0.9 },
	LeftKnee = { scale = 26, ax = -1, ay = 0, az = 0, follow = "LeftHip", gain = 0.9 },
}
local ORDER = { "Waist", "Neck", "RightShoulder", "LeftShoulder", "RightElbow", "LeftElbow", "RightHip", "LeftHip", "RightKnee", "LeftKnee" }

local Victim = {}

-- exact solution of the underdamped spring after dt seconds (x and v are measured from the target)
local function advance(s: Spring, target: number, w: number, z: number, dt: number)
	local wd = w * math.sqrt(1 - z * z)
	local e = math.exp(-z * w * dt)
	local c, sn = math.cos(wd * dt), math.sin(wd * dt)
	local a = s.x - target
	local b = (s.v + z * w * a) / wd
	local osc = a * c + b * sn
	s.x = target + e * osc
	s.v = e * (-z * w * osc + wd * (b * c - a * sn))
end

-- gap = seconds between two cuts
function Victim.new(model: Model, gap: number): Handle?
	local parts: { [string]: Part } = {}
	local count = 0
	for _, name in ORDER do
		local j = model:FindFirstChild(name, true)
		local spec = SPEC[name]
		if j and (j:IsA("Motor6D") or j:IsA("AnimationConstraint")) then
			parts[name] = {
				joint = j, spring = { x = 0, v = 0 }, scale = spec.scale, ax = spec.ax, ay = spec.ay, az = spec.az,
				follow = spec.follow, gain = spec.gain or 1,
			}
			count += 1
		end
	end
	if count < 4 then return nil end

	local root = model:FindFirstChild("HumanoidRootPart")
	local rootJoint = model:FindFirstChild("RootJoint", true)
	if not (rootJoint and (rootJoint:IsA("Motor6D") or rootJoint:IsA("AnimationConstraint"))) then rootJoint = nil end
	local sway: { Spring } = { { x = 0, v = 0 }, { x = 0, v = 0 }, { x = 0, v = 0 } } -- the offset of the body (x, y, z) in the space of the root
	local lastPos = if root and root:IsA("BasePart") then root.Position else Vector3.zero
	local speed = 0 -- measured from the position (the replicated velocity of a body the server simulates is not reliable on the client)
	local w = math.pi / math.max(gap, 0.05) -- f0 = 1 / (2 gap): one swing of the push takes two cuts
	local sign = 1 -- hit 1 pushes one way, hit 2 the other
	local flying = false
	local finishing = false
	local finishAt = 0
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil

	local function destroy()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		for _, p in parts do
			if p.joint.Parent then p.joint.Transform = CFrame.identity end
		end
		if rootJoint and rootJoint.Parent then (rootJoint :: Joint).Transform = CFrame.identity end
	end

	conn = RunService.Heartbeat:Connect(function(dt: number)
		local ok = pcall(function()
			dt = math.min(dt, 1 / 20)
			if root and root:IsA("BasePart") and dt > 0 then
				speed += ((root.Position - lastPos).Magnitude / dt - speed) * 0.5
				lastPos = root.Position
			end
			local now = os.clock() - t0
			local k = math.clamp(speed / REF_SPEED, 0, 1)
			local flutterHz = STROUHAL * speed / LIMB_WIDTH -- f = St * v / D
			local zeta = if finishing then RING_Z elseif flying then FLY_Z else DAMPING
			local freq = if flying then FLY_W else w
			for i, name in ORDER do
				local p = parts[name]
				if p then
					local target = 0
					if p.follow then
						local other = parts[p.follow]
						if other then target = other.spring.x * p.gain end
					elseif flying then
						target = FLY_ARCH -- the waist: arched back
					end
					if flying then
						target += FLUTTER * k * math.sin(2 * math.pi * flutterHz * now + i * math.pi) -- neighbours in opposite phase
					end
					advance(p.spring, target, freq, zeta, dt)
					p.spring.x = math.clamp(p.spring.x, -MAX_AMOUNT, MAX_AMOUNT)
					local a = p.spring.x * p.scale
					p.joint.Transform = CFrame.Angles(math.rad(a * p.ax), math.rad(a * p.ay), math.rad(a * p.az))
				end
			end
			if rootJoint and not flying then -- (in flight the body is moved by the physics, not by the sway)
				for _, s in sway do advance(s, 0, RECOIL_W, RECOIL_Z, dt) end
				(rootJoint :: Joint).Transform = CFrame.new(sway[1].x, sway[2].x, sway[3].x)
			end
		end)
		if not ok or (finishing and os.clock() > finishAt) then destroy() end -- a failing motion lets go instead of keeping the body twisted
	end)

	local handle: Handle = {
		hit = function(index: number, strength: number?, dir: Vector3?)
			local k = 0.7 + 0.6 * (strength or 0.6)
			if root and root:IsA("BasePart") and dir and dir.Magnitude > 0.01 then -- the push of the cut, in the space of the root
				local l = root.CFrame:VectorToObjectSpace(dir.Unit)
				sway[1].v += l.X * RECOIL_SPEED * k
				sway[3].v += l.Z * RECOIL_SPEED * k
			end
			sway[2].v += (if index == 2 then 1.8 else -0.8) * k -- up with the rising cut, down with the chop
			local waist = parts.Waist
			if not waist then return end
			sign = if index == 2 then -1 else 1
			waist.spring.v += sign * PUSH * w * (0.7 + 0.6 * (strength or 0.6)) -- the push is a sudden speed: the joint is hit, not moved
		end,
		fling = function() -- the last cut: from now on the springs hold the flying pose
			flying = true
			t0 = os.clock()
		end,
		finish = function()
			flying = false -- the targets go back to rest and the joints ring out
			finishing = true
			finishAt = os.clock() + RELEASE_TIME
		end,
	}
	return handle
end

return Victim
