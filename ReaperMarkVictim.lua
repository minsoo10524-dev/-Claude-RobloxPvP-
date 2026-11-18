--!strict
-- ModuleScript "ReaperMarkVictim" (parent: Tool "TrueKatana"), used by ReaperMarkServer
-- The BODY LANGUAGE of the enemy that is grabbed, dragged, thrown up and slammed. It moves the joints of an R15 rig by their C0 (a server can
-- only replicate C0, not the animation Transform), so every player sees it. An R6 rig (or a rig with too few joints) gets nil and simply stays stiff.
-- Poses (degrees, in the PARENT's frame: +X lifts the front/the limb forward and up, +Z swings a limb to its own right):
--   grab    : the head lolls back, the arms dangle forward and a little out, the knees hang bent (held by the collar)
--   drag    : the body arched, the arms thrown back and the legs trailing straight; on top of this the limbs FLAIL (two sine waves of different
--             speeds on every joint, a different phase for each, so they never move together)
--   lift    : thrown up: the arms fly up over the head, the legs dangle down and a little bent, the head back
--   slam    : the impact: the back arches hard, the head whips back, the arms are flung wide, the legs kick up
--   rest    : sprawled on the floor, arms and legs apart
--   stagger : after the blow: the knees buckle, bent forward, the head down, the arms hanging (the stun)
-- PHYSICS of the joints: every joint is a damped spring (solved exactly each frame), softer at the elbows, knees and wrists, so the end of a limb
-- LAGS behind the body and overshoots when the pose changes (a whip). kick() hits all the springs with a random speed: at the moment of the
-- slam the limbs jiggle and settle like loose masses. Everything is put back exactly (C0 of every joint) at release() or destroy().

local RunService = game:GetService("RunService")

local rad = math.rad
local ZERO = Vector3.zero

local NAMES = {
	"Waist", "Neck", "RightShoulder", "RightElbow", "LeftShoulder", "LeftElbow",
	"RightHip", "RightKnee", "LeftHip", "LeftKnee", "RightWrist", "LeftWrist",
}
-- speed of the spring (rad/s) of each joint: the smaller, the more the joint lags
local SPEED: { [string]: number } = {
	Waist = 14, Neck = 12, RightShoulder = 11, LeftShoulder = 11, RightElbow = 8, LeftElbow = 8,
	RightHip = 12, LeftHip = 12, RightKnee = 8, LeftKnee = 8, RightWrist = 6, LeftWrist = 6,
}
local DAMPING = 0.5 -- loose and bouncy
local MIN_JOINTS = 6

type Pose = { [string]: Vector3 }

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local POSES: { [string]: Pose } = {
	grab = {
		Waist = v(-16, 0, 0), Neck = v(24, 0, 0),
		RightShoulder = v(-24, 0, 34), RightElbow = v(30, 0, 0), RightWrist = v(0, 0, 10),
		LeftShoulder = v(-24, 0, -34), LeftElbow = v(30, 0, 0), LeftWrist = v(0, 0, -10),
		RightHip = v(-10, 0, 4), RightKnee = v(-22, 0, 0), LeftHip = v(-10, 0, -4), LeftKnee = v(-22, 0, 0),
	},
	drag = {
		Waist = v(10, 0, 0), Neck = v(20, 0, 0),
		RightShoulder = v(-52, 0, 24), RightElbow = v(18, 0, 0), RightWrist = v(0, 0, 8),
		LeftShoulder = v(-52, 0, -24), LeftElbow = v(18, 0, 0), LeftWrist = v(0, 0, -8),
		RightHip = v(14, 0, 6), RightKnee = v(-8, 0, 0), LeftHip = v(14, 0, -6), LeftKnee = v(-8, 0, 0),
	},
	lift = {
		Waist = v(4, 0, 0), Neck = v(14, 0, 0),
		RightShoulder = v(168, 0, 14), RightElbow = v(12, 0, 0), RightWrist = v(0, 0, 6),
		LeftShoulder = v(168, 0, -14), LeftElbow = v(12, 0, 0), LeftWrist = v(0, 0, -6),
		RightHip = v(-6, 0, 4), RightKnee = v(-30, 0, 0), LeftHip = v(-10, 0, -4), LeftKnee = v(-38, 0, 0),
	},
	slam = {
		Waist = v(30, 0, 0), Neck = v(42, 0, 0),
		RightShoulder = v(46, 0, 72), RightElbow = v(8, 0, 0), RightWrist = v(0, 0, 14),
		LeftShoulder = v(46, 0, -72), LeftElbow = v(8, 0, 0), LeftWrist = v(0, 0, -14),
		RightHip = v(30, 0, 16), RightKnee = v(-10, 0, 0), LeftHip = v(26, 0, -16), LeftKnee = v(-14, 0, 0),
	},
	rest = {
		Waist = v(4, 0, 0), Neck = v(10, 0, 0),
		RightShoulder = v(26, 0, 52), RightElbow = v(14, 0, 0), RightWrist = v(0, 0, 10),
		LeftShoulder = v(18, 0, -56), LeftElbow = v(20, 0, 0), LeftWrist = v(0, 0, -10),
		RightHip = v(8, 0, 22), RightKnee = v(-8, 0, 0), LeftHip = v(4, 0, -24), LeftKnee = v(-14, 0, 0),
	},
	stagger = {
		Waist = v(-34, 0, 0), Neck = v(-22, 0, 0),
		RightShoulder = v(30, 0, 12), RightElbow = v(24, 0, 0), RightWrist = v(0, 0, 0),
		LeftShoulder = v(30, 0, -12), LeftElbow = v(24, 0, 0), LeftWrist = v(0, 0, 0),
		RightHip = v(-34, 0, 4), RightKnee = v(-56, 0, 0), LeftHip = v(-30, 0, -4), LeftKnee = v(-52, 0, 0),
	},
}

-- exact solution of the underdamped spring after dt seconds, for a whole Vector3 at once
local function advance(x: Vector3, vel: Vector3, target: Vector3, w: number, z: number, dt: number): (Vector3, Vector3)
	local wd = w * math.sqrt(1 - z * z)
	local e = math.exp(-z * w * dt)
	local c, s = math.cos(wd * dt), math.sin(wd * dt)
	local a = x - target
	local b = (vel + a * (z * w)) / wd
	local osc = a * c + b * s
	return target + osc * e, (osc * (-z * w) + (b * c - a * s) * wd) * e
end

export type Handle = { pose: (string) -> (), kick: () -> (), release: () -> (), destroy: () -> () }

local Victim = {}

function Victim.new(model: Model): Handle?
	if model:FindFirstChildOfClass("Humanoid") == nil or model:FindFirstChildOfClass("Humanoid").RigType ~= Enum.HumanoidRigType.R15 then return nil end
	local joints: { [string]: Motor6D } = {}
	local origin: { [string]: CFrame } = {}
	local count = 0
	for _, name in NAMES do
		local j = model:FindFirstChild(name, true)
		if j and j:IsA("Motor6D") then
			joints[name] = j
			origin[name] = j.C0
			count += 1
		end
	end
	if count < MIN_JOINTS then return nil end

	local cur: { [string]: Vector3 } = {}
	local vel: { [string]: Vector3 } = {}
	for name in joints do
		cur[name], vel[name] = ZERO, ZERO
	end
	local target: Pose = {}
	local poseName = ""
	local flailAmp = 0 -- how much the limbs flail on top of the pose (0 = not at all)
	local releasing = false
	local conn: RBXScriptConnection? = nil
	local clock = 0
	local phase: { [string]: number } = {}
	for name in joints do
		phase[name] = math.random() * 6.28
	end

	local function restore()
		for name, j in joints do
			if j.Parent then j.C0 = origin[name] end
		end
	end

	local function destroy()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		restore()
	end

	conn = RunService.Heartbeat:Connect(function(dt: number)
		local ok = pcall(function()
			dt = math.min(dt, 1 / 20)
			clock += dt
			local settledAll = true
			for name, j in joints do
				local want = target[name] or ZERO
				if flailAmp > 0 then -- two sine waves of different speeds, a different phase for every joint
					local p = phase[name]
					want += v(math.sin(clock * 15 + p) * 40 * flailAmp, 0, math.sin(clock * 9.5 + p * 2) * 24 * flailAmp)
				end
				local x, w = advance(cur[name], vel[name], want, SPEED[name] or 10, DAMPING, dt)
				cur[name], vel[name] = x, w
				if j.Parent then
					j.C0 = CFrame.new(origin[name].Position) * CFrame.Angles(rad(x.X), rad(x.Y), rad(x.Z)) * origin[name].Rotation
				end
				if x.Magnitude > 0.6 or w.Magnitude > 3 then settledAll = false end
			end
			if releasing and settledAll then destroy() end
		end)
		if not ok then destroy() end -- a failing motion lets go instead of keeping the body twisted
	end)

	local handle: Handle = {
		pose = function(name: string)
			if POSES[name] then
				target = POSES[name]
				poseName = name
				flailAmp = ({ drag = 1.4, lift = 0.7, grab = 0.45, rest = 0.2 })[name] or 0
				releasing = false
			end
		end,
		kick = function() -- the impact hits every joint with a random speed: the limbs jiggle and settle
			for name in joints do
				vel[name] += v((math.random() - 0.5) * 1700, (math.random() - 0.5) * 300, (math.random() - 0.5) * 1700)
			end
		end,
		release = function() -- back to the normal pose by the same springs, then everything is put back exactly
			target = {}
			poseName = ""
			flailAmp = 0
			releasing = true
		end,
		destroy = destroy,
	}
	return handle
end

return Victim
