--!strict
-- ModuleScript "BlinkCutAnim" (parent: Tool "TrueKatana")
-- The motion of BLINK CUT, drawn on top of the normal pose: a crouch and draw (windup), a long stride with the sword arm forward (dash),
-- a braking pose when the body arrives (brace), a cross cut (cut), a calm sweeping finish (finish), then a soft return (release).
-- Why it looks natural (PHYSICS of a living body):
--   * Every joint is a spring (a damped harmonic oscillator, solved exactly each frame) with a damping ratio of about 0.7: it overshoots a little
--     and settles, like a muscle that is pulled and let go, instead of stopping dead on the pose.
--   * The joints lower in the chain (elbows, wrists) are softer than the ones near the body, so they LAG behind it (a travelling wave from the
--     hips to the hand): the sword hand comes last, the way a whip follows its handle. The HEAD does the opposite: it is stiffer, so it LEADS (the
--     eyes turn to the target before the body does, as real people look first and move after).
--   * Each phase has its own damping: the dash overshoots (a snap), the stop and the cut are firm, the finish is calm and does not bounce.
--   * Each phase has its own speed: the coil is slow, the dash is snappy, the brace is firm.
-- It writes to the same joints as SwordRig, after it, and blends in and out so there is no pop. SIGNS: if a lean goes backwards, flip PITCH;
-- if a turn goes the wrong way, flip YAW. Only R15 is supported (R6 returns nil and the skill still works, without the motion).

local RunService = game:GetService("RunService")

local SIGN = { PITCH = 1, YAW = 1 }
local NAMES = {
	"RootJoint", "Waist", "Neck", "RightShoulder", "RightElbow", "RightWrist", "LeftShoulder", "LeftElbow", "LeftWrist",
	"RightHip", "RightKnee", "LeftHip", "LeftKnee",
}
-- how stiff each joint is compared with the speed of the phase (smaller = softer = it lags more)
local STIFF: { [string]: number } = {
	RootJoint = 1.0, Waist = 0.9, Neck = 1.15, RightShoulder = 0.8, RightElbow = 0.65, RightWrist = 0.5,
	LeftShoulder = 0.8, LeftElbow = 0.65, LeftWrist = 0.5, RightHip = 0.9, RightKnee = 0.75, LeftHip = 0.9, LeftKnee = 0.75,
}
-- OVERLAPPING ACTION: when the pose changes, the body does not move all at once: the core (hips, back) starts first and the parts farther out start later
-- (seconds): the head, the elbows and above all the wrists follow after it. This is the "heavier parts lag further" rule that makes a body look like a chain of
-- masses and not like a doll that changes pose.
local LAG: { [string]: number } = {
	RootJoint = 0, Waist = 0.025, Neck = 0.06, RightShoulder = 0.035, LeftShoulder = 0.035, RightElbow = 0.07, LeftElbow = 0.07,
	RightWrist = 0.1, LeftWrist = 0.1, RightHip = 0.015, LeftHip = 0.015, RightKnee = 0.045, LeftKnee = 0.045,
}
local DAMPING = 0.8 -- the default; every phase has its own (below): the dash overshoots more, the finish is almost critical (no bounce)
local MIN_JOINTS = 6
local ZERO = Vector3.zero
local rad = math.rad

type Pose = { [string]: Vector3 } -- degrees (x, y, z) per joint
type Joint = Motor6D | AnimationConstraint
export type Handle = { elbows: (number, number) -> (), fly: (number) -> (), spin: (number) -> (), walk: () -> (), clip: (string) -> (), push: () -> (), land: () -> (), motion: (string) -> (), kick: (string, Vector3) -> (), arm: (number) -> (), armL: (number) -> (), apex: () -> (), lean: (number) -> (), windup: () -> (), dash: () -> (), lunge: () -> (), grab: () -> (), drag: () -> (), drag2: () -> (), sweep: () -> (), swing: () -> (), heave: () -> (), lift: () -> (), load: () -> (), slam: () -> (), brace: () -> (), cut: () -> (), finish: () -> (), release: () -> () }

-- degrees: x = bend forward (negative = lean forward for the body, knees bend with negative), y = turn left, z = roll
local function ang(x: number, y: number, z: number): Vector3
	return Vector3.new(x * SIGN.PITCH, y * SIGN.YAW, z)
end

local POSES: { [string]: Pose } = {
	windup = { -- crouch, body coiled to the right, sword hand drawn back
		RootJoint = ang(-10, -22, 0), Waist = ang(-12, -16, 0), Neck = ang(8, 16, 0),
		RightShoulder = ang(-28, -18, 0), RightElbow = ang(48, 0, 0), RightWrist = ang(0, 0, 10),
		LeftShoulder = ang(38, 8, 8), LeftElbow = ang(36, 0, 0),
		RightHip = ang(-6, 0, 0), RightKnee = ang(-28, 0, 0), LeftHip = ang(20, 0, 0), LeftKnee = ang(-34, 0, 0),
	},
	dash = { -- one long stride, body flat forward, sword arm straight ahead
		RootJoint = ang(-30, 0, 0), Waist = ang(-10, 0, 0), Neck = ang(24, 0, 0),
		RightShoulder = ang(88, -6, 0), RightElbow = ang(4, 0, 0), RightWrist = ang(0, 0, 0),
		LeftShoulder = ang(-52, 0, -10), LeftElbow = ang(30, 0, 0),
		RightHip = ang(40, 0, 0), RightKnee = ang(-20, 0, 0), LeftHip = ang(-42, 0, 0), LeftKnee = ang(-70, 0, 0),
	},
	lunge = { -- the rush of the X skill: the body almost flat, the head low and forward, the sword arm thrown straight out, the other arm swept back, a huge stride
		RootJoint = ang(-52, 0, 0), Waist = ang(-14, 0, 0), Neck = ang(40, 0, 0),
		RightShoulder = ang(104, -4, 0), RightElbow = ang(2, 0, 0), RightWrist = ang(0, 0, 0),
		LeftShoulder = ang(-78, 0, -16), LeftElbow = ang(44, 0, 0),
		RightHip = ang(58, 0, 0), RightKnee = ang(-14, 0, 0), LeftHip = ang(-62, 0, 0), LeftKnee = ang(-86, 0, 0),
	},
	grab = { -- the X skill, the grab: both hands snap out and clamp, the body turns into it, the legs set wide and low
		RootJoint = ang(-18, -12, 0), Waist = ang(-10, -10, 0), Neck = ang(16, 10, 0),
		RightShoulder = ang(100, -16, 0), RightElbow = ang(26, 0, 0), RightWrist = ang(-14, 0, 0),
		LeftShoulder = ang(96, 18, 0), LeftElbow = ang(30, 0, 0), LeftWrist = ang(-14, 0, 0),
		RightHip = ang(26, 0, 0), RightKnee = ang(-46, 0, 0), LeftHip = ang(-16, 0, 0), LeftKnee = ang(-38, 0, 0),
	},
	drag = { -- the drag, a HEAVY WALK: upright and leaning only a little, the sword arm out in front and to the right holding the enemy off the floor, the other arm swung back, a long step
		RootJoint = ang(-24, -10, 0), Waist = ang(-10, -22, 0), Neck = ang(16, 18, 0),
		RightShoulder = ang(70, -26, 0), RightElbow = ang(10, 0, 0), RightWrist = ang(-10, 0, 12),
		LeftShoulder = ang(54, 26, 0), LeftElbow = ang(24, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(30, 0, 0), RightKnee = ang(-34, 0, 0), LeftHip = ang(-28, 0, 0), LeftKnee = ang(-22, 0, 0),
	},
	drag2 = { -- the other step: the legs swap and the body unwinds
		RootJoint = ang(-24, 10, 0), Waist = ang(-10, 18, 0), Neck = ang(16, -14, 0),
		RightShoulder = ang(70, -26, 0), RightElbow = ang(10, 0, 0), RightWrist = ang(-10, 0, 12),
		LeftShoulder = ang(-30, 10, -18), LeftElbow = ang(30, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(-28, 0, 0), RightKnee = ang(-22, 0, 0), LeftHip = ang(30, 0, 0), LeftKnee = ang(-34, 0, 0),
	},
	sweep = { -- the sweep to the left: the hips lead, the back and shoulders follow, the sword arm is carried right across the body to the left, the eyes stay on the target
		RootJoint = ang(-10, 46, 0), Waist = ang(-8, 58, 0), Neck = ang(8, -52, 0),
		RightShoulder = ang(48, 82, 0), RightElbow = ang(10, 0, 0), RightWrist = ang(0, 0, -16),
		LeftShoulder = ang(-34, 0, -18), LeftElbow = ang(30, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(34, 0, 0), RightKnee = ang(-40, 0, 0), LeftHip = ang(-24, 0, 0), LeftKnee = ang(-36, 0, 0),
	},
	swing = { -- the swing: a hammer thrower: the body leans back against the weight, both arms straight out in front holding it, the legs wide and bent
		RootJoint = ang(10, 0, 0), Waist = ang(6, -14, 0), Neck = ang(-6, 10, 0),
		RightShoulder = ang(82, -12, 0), RightElbow = ang(6, 0, 0), RightWrist = ang(-8, 0, 0),
		LeftShoulder = ang(82, 12, 0), LeftElbow = ang(6, 0, 0), LeftWrist = ang(-8, 0, 0),
		RightHip = ang(30, 0, 0), RightKnee = ang(-46, 0, 0), LeftHip = ang(-20, 0, 0), LeftKnee = ang(-40, 0, 0),
	},
	heave = { -- the heave: a sprinter's crouch before the jump: deep knees, the back flat, the arms pulled back and low, the head up on the sky
		RootJoint = ang(-34, 0, 0), Waist = ang(-14, 0, 0), Neck = ang(24, 0, 0),
		RightShoulder = ang(-30, -8, 0), RightElbow = ang(30, 0, 0), RightWrist = ang(0, 0, 0),
		LeftShoulder = ang(-30, 8, 0), LeftElbow = ang(30, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(44, 0, 0), RightKnee = ang(-78, 0, 0), LeftHip = ang(36, 0, 0), LeftKnee = ang(-72, 0, 0),
	},
	lift = { -- the jump with the BLADE AT THE NECK: the sword arm is bent and the forearm carries the blade flat under the enemy's chin, as if to cut through it; the other hand pulls the collar up; the legs trail
		RootJoint = ang(10, 0, 0), Waist = ang(8, 0, 0), Neck = ang(-8, 0, 0),
		RightShoulder = ang(66, -22, 0), RightElbow = ang(88, 0, 0), RightWrist = ang(0, 0, -24),
		LeftShoulder = ang(128, 12, 0), LeftElbow = ang(14, 0, 0), LeftWrist = ang(-8, 0, 0),
		RightHip = ang(-6, 0, 0), RightKnee = ang(-16, 0, 0), LeftHip = ang(-12, 0, 0), LeftKnee = ang(-30, 0, 0),
	},
	apex = { -- the top: the knees are TUCKED up (a high jump tucks at the top), the chest out, the blade still at the neck, the other hand holding the collar
		RootJoint = ang(10, 0, 0), Waist = ang(8, 0, 0), Neck = ang(-12, 0, 0),
		RightShoulder = ang(66, -22, 0), RightElbow = ang(88, 0, 0), RightWrist = ang(0, 0, -24),
		LeftShoulder = ang(132, 14, 0), LeftElbow = ang(12, 0, 0), LeftWrist = ang(-8, 0, 0),
		RightHip = ang(46, 0, 0), RightKnee = ang(-70, 0, 0), LeftHip = ang(38, 0, 0), LeftKnee = ang(-64, 0, 0),
	},
	push = { -- the push: the sword arm is driven out straight to shove the enemy away, the whole body lunges behind it with a long step
		RootJoint = ang(-40, 16, 0), Waist = ang(-18, 24, 0), Neck = ang(10, -18, 0),
		RightShoulder = ang(98, -6, 0), RightElbow = ang(0, 0, 0), RightWrist = ang(0, 0, 0),
		LeftShoulder = ang(-34, 0, -14), LeftElbow = ang(34, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(52, 0, 0), RightKnee = ang(-34, 0, 0), LeftHip = ang(-46, 0, 0), LeftKnee = ang(-26, 0, 0),
	},
	land = { -- the landing after the slam: a one-knee landing: the front knee deep, the other leg back, one hand planted, the other arm back, the head down
		RootJoint = ang(-52, 0, 0), Waist = ang(-26, 0, 0), Neck = ang(30, 0, 0),
		RightShoulder = ang(20, -14, 0), RightElbow = ang(8, 0, 0), RightWrist = ang(8, 0, 0),
		LeftShoulder = ang(-52, 10, -16), LeftElbow = ang(40, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(74, 0, 0), RightKnee = ang(-112, 0, 0), LeftHip = ang(-30, 0, 0), LeftKnee = ang(-60, 0, 0),
	},
	walkbase = { -- the pose a WALK is drawn on: upright, leaning a little into the pull, the sword arm out in front and a little to the right (the enemy hangs on it), the legs under the body
		RootJoint = ang(-8, 0, 0), Waist = ang(-4, 0, 0), Neck = ang(6, 0, 0),
		RightShoulder = ang(72, -24, 0), RightElbow = ang(10, 0, 0), RightWrist = ang(-8, 0, 8),
		LeftShoulder = ang(0, 8, -6), LeftElbow = ang(18, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(0, 0, 0), RightKnee = ang(-8, 0, 0), LeftHip = ang(0, 0, 0), LeftKnee = ang(-8, 0, 0),
	},
	recover = { -- half way up from the landing: the knees still bent, the back rounding up, the arms coming back to the sides
		RootJoint = ang(-30, 0, 0), Waist = ang(-14, 0, 0), Neck = ang(14, 0, 0),
		RightShoulder = ang(30, -10, 0), RightElbow = ang(30, 0, 0), RightWrist = ang(0, 0, 0),
		LeftShoulder = ang(14, 8, 0), LeftElbow = ang(24, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(50, 0, 0), RightKnee = ang(-70, 0, 0), LeftHip = ang(-14, 0, 0), LeftKnee = ang(-34, 0, 0),
	},
	ready = { -- the calm stance after the move: upright, the sword hand relaxed at the side with the elbow a little bent, the other arm loose (it is close to the normal hold, so letting go is not a jump)
		RootJoint = ang(0, 0, 0), Waist = ang(-2, 0, 0), Neck = ang(2, 0, 0),
		RightShoulder = ang(18, -8, 0), RightElbow = ang(40, 0, 0), RightWrist = ang(0, 0, 0),
		LeftShoulder = ang(6, 6, 4), LeftElbow = ang(14, 0, 0), LeftWrist = ang(0, 0, 0),
		RightHip = ang(2, 0, 0), RightKnee = ang(-6, 0, 0), LeftHip = ang(-2, 0, 0), LeftKnee = ang(-6, 0, 0),
	},
	load = { -- the wind-up of the blow: the arms swing back behind the head, the back arches hard, the knees tuck, the chin lifts
		RootJoint = ang(24, 0, 0), Waist = ang(16, 0, 0), Neck = ang(-26, 0, 0),
		RightShoulder = ang(190, -14, 0), RightElbow = ang(30, 0, 0), RightWrist = ang(-24, 0, 0),
		LeftShoulder = ang(190, 14, 0), LeftElbow = ang(30, 0, 0), LeftWrist = ang(-24, 0, 0),
		RightHip = ang(30, 0, 0), RightKnee = ang(-60, 0, 0), LeftHip = ang(20, 0, 0), LeftKnee = ang(-66, 0, 0),
	},
	slam = { -- the slam: the whole body folds forward, the arms are thrown down in front and the head follows; the knees take the shock
		RootJoint = ang(-64, 0, 0), Waist = ang(-40, 0, 0), Neck = ang(38, 0, 0),
		RightShoulder = ang(30, -8, 0), RightElbow = ang(8, 0, 0), RightWrist = ang(14, 0, 0),
		LeftShoulder = ang(30, 8, 0), LeftElbow = ang(8, 0, 0), LeftWrist = ang(14, 0, 0),
		RightHip = ang(66, 0, 0), RightKnee = ang(-88, 0, 0), LeftHip = ang(52, 0, 0), LeftKnee = ang(-84, 0, 0),
	},
	brace = { -- the body arrives: the weight goes back onto the rear leg, the front leg brakes, the arms come in (skidding to a stop)
		RootJoint = ang(7, 4, 0), Waist = ang(8, 8, 0), Neck = ang(-6, -6, 0),
		RightShoulder = ang(54, 6, 0), RightElbow = ang(28, 0, 0), RightWrist = ang(0, 0, 4),
		LeftShoulder = ang(-18, 0, -14), LeftElbow = ang(26, 0, 0),
		RightHip = ang(28, 0, 0), RightKnee = ang(-26, 0, 0), LeftHip = ang(-22, 0, 0), LeftKnee = ang(-48, 0, 0),
	},
	finish = { -- the clean finish (zanshin): the sword arm sweeps out wide to the right and down, the body turns after it, the eyes stay on the enemy
		RootJoint = ang(-5, -30, 0), Waist = ang(-4, -24, 0), Neck = ang(4, 24, 0),
		RightShoulder = ang(58, -72, 0), RightElbow = ang(10, 0, 0), RightWrist = ang(0, 0, 18),
		LeftShoulder = ang(-10, 0, -8), LeftElbow = ang(22, 0, 0),
		RightHip = ang(10, 0, 0), RightKnee = ang(-14, 0, 0), LeftHip = ang(-12, 0, 0), LeftKnee = ang(-22, 0, 0),
	},
	cut = { -- the cut ends across the body, turned to the left
		RootJoint = ang(-8, 42, 0), Waist = ang(-8, 28, 0), Neck = ang(8, -18, 0),
		RightShoulder = ang(36, 62, 0), RightElbow = ang(20, 0, 0), RightWrist = ang(0, 0, -12),
		LeftShoulder = ang(-22, 0, -14), LeftElbow = ang(26, 0, 0),
		RightHip = ang(30, 0, 0), RightKnee = ang(-34, 0, 0), LeftHip = ang(-20, 0, 0), LeftKnee = ang(-30, 0, 0),
	},
}
local EMPTY: Pose = {}

-- KEYFRAME CLIPS: a clip is a list of key poses with times (seconds). Between the keys the joints follow a CATMULL-ROM SPLINE (it passes through every key and has
-- no corners: the speed does not jump at a key, as it does when a spring is thrown from pose to pose). The spline is the TARGET of the joint springs, so the
-- overlap and the follow-through (the lag of the elbows, wrists and head, the settle after a hit) are kept on top of it. A key that is repeated is a HOLD.
local CLIPS: { [string]: { { any } } } = {
	-- the walk of the drag: step, step, step (one step every 0.29 s)
	drag = { { 0, "drag" }, { 0.32, "drag2" }, { 0.64, "drag" }, { 0.96, "drag2" }, { 1.28, "drag" }, { 1.6, "drag2" }, { 1.9, "drag" } },
	-- the FINISH: from the landing the body stands up in three moves: it holds the landing, rises through a half crouch and settles in a calm stance
	finish = { { 0, "land" }, { 0.15, "land" }, { 0.5, "recover" }, { 0.9, "ready" } },
	-- from the crouch to the landing (the times follow the timeline of ReaperMarkCarry: heave 0, jump 0.3, top 0.8, load 1.0, slam 1.2, blow 1.33)
	jump = {
		{ 0, "heave" }, { 0.22, "heave" }, -- anticipation: it sinks and HOLDS
		{ 0.38, "lift" }, { 0.55, "lift" }, -- the launch (the body leaves the floor at 0.3)
		{ 0.8, "apex" }, { 0.97, "apex" }, -- the top: it opens and floats
		{ 1.05, "load" }, { 1.16, "load" }, -- the wind-up of the blow
		{ 1.24, "slam" }, { 1.31, "slam" }, -- the dive
		{ 1.34, "land" }, { 1.5, "land" }, -- the landing: the one-knee landing is reached at the very moment of the blow (1.33) and held
	},
}

-- Catmull-Rom through p1 and p2 (p0 and p3 are the neighbours), s = 0..1
local function spline(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, s: number): Vector3
	local s2, s3 = s * s, s * s * s
	return ((p1 * 2) + (p2 - p0) * s + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * s2 + (p1 * 3 - p0 - p2 * 3 + p3) * s3) * 0.5
end

-- exact solution of the underdamped spring after dt seconds, for a whole Vector3 at once
local function advance(x: Vector3, v: Vector3, target: Vector3, w: number, z: number, dt: number): (Vector3, Vector3)
	local wd = w * math.sqrt(1 - z * z)
	local e = math.exp(-z * w * dt)
	local c, s = math.cos(wd * dt), math.sin(wd * dt)
	local a = x - target
	local b = (v + a * (z * w)) / wd
	local osc = a * c + b * s
	return target + osc * e, (osc * (-z * w) + (b * c - a * s) * wd) * e
end

local Anim = {}

function Anim.new(char: Model): Handle?
	local joints: { [string]: Joint } = {}
	local count = 0
	for _, name in NAMES do
		local j = char:FindFirstChild(name, true)
		if j and (j:IsA("Motor6D") or j:IsA("AnimationConstraint")) then
			joints[name] = j
			count += 1
		end
	end
	if count < MIN_JOINTS then return nil end

	local cur: { [string]: Vector3 } = {}
	local vel: { [string]: Vector3 } = {}
	for name in joints do
		cur[name], vel[name] = ZERO, ZERO
	end
	local target: Pose = EMPTY
	local clipKeys: { { any } }? = nil -- the clip that is playing (nil = none): the joints follow its spline
	local clipT0 = 0
	local prevTarget: Pose = EMPTY -- the pose before the last change (the joints that are still waiting for their turn keep following it)
	local changedAt = 0
	local speed = 18 -- the speed of the phase (rad/s of the springs)
	local damping = DAMPING -- the damping ratio of the phase
	local weight, weightTarget, weightRate = 0, 1, 28 -- how much of this motion is shown over the normal pose
	local released = false
	local elbowR, elbowL = 0, 0 -- degrees added to the bend of the elbows (the arms bend and straighten with the weight they lift)
	local flySpeed = 0 -- 0..1: how fast the body moves through the air (the arms trail more the faster it goes)
	local spinOmega = 0 -- the speed of the turn of the body in rad/s (set by the owner)
	local motionMode = "" -- "run": a layer of running motion on top of the pose (the legs swing, the back twists, the head counter-turns)
	local motionT0 = 0
	local armLExtra = 0 -- the same for the other shoulder
	local armExtra = 0 -- degrees added to the swing of the sword shoulder: 360 = the whole arm goes once round the shoulder (a windmill)
	local leanExtra = 0 -- degrees added to the lean of the whole body (the owner sets it from the acceleration)
	local bindName: string? = nil

	local function destroy()
		local n = bindName
		if n then
			bindName = nil
			pcall(function() RunService:UnbindFromRenderStep(n) end)
		end
	end

	local myName = "BlinkCutAnim" .. tostring(math.random(1, 1000000000))
	bindName = myName
	RunService:BindToRenderStep(myName, Enum.RenderPriority.Last.Value + 5, function(dt: number) -- at the very end of the frame: after SwordRig and the animations
		local ok, err = pcall(function()
			dt = math.min(dt, 1 / 20)
			weight += (weightTarget - weight) * (1 - math.exp(-weightRate * dt))
			for name, j in joints do
				local src = if os.clock() - changedAt >= (LAG[name] or 0) then target else prevTarget
				local want = src[name] or ZERO
				local keys = clipKeys
				if keys then
					local ct = os.clock() - clipT0
					local count = #keys
					local i = 1
					while i < count and (keys[i + 1][1] :: number) <= ct do i += 1 end
					local function at(k: { any }): Vector3
						local pose = POSES[k[2] :: string]
						return (pose and pose[name]) or ZERO
					end
					if i >= count then
						want = at(keys[count])
					else
						local k1, k2 = keys[i], keys[i + 1]
						local span = math.max((k2[1] :: number) - (k1[1] :: number), 1e-3)
						want = spline(at(keys[i - 1] or k1), at(k1), at(k2), at(keys[i + 2] or k2), math.clamp((ct - (k1[1] :: number)) / span, 0, 1))
					end
				end
				if name == "RootJoint" then want += Vector3.new(leanExtra * SIGN.PITCH, 0, 0) end
				if name == "RightShoulder" then want += Vector3.new(armExtra * SIGN.PITCH, 0, 0) end
				if name == "LeftShoulder" then want += Vector3.new(armLExtra * SIGN.PITCH, 0, 0) end
				if name == "RightElbow" then want += Vector3.new(elbowR * SIGN.PITCH, 0, 0) end
				if name == "LeftElbow" then want += Vector3.new(elbowL * SIGN.PITCH, 0, 0) end
				if motionMode == "fly" then -- THE ARMS IN THE AIR: they are not stiff. The faster the body goes, the more the arms TRAIL behind it (the free arm is swept back and its elbow bent by the
					-- air, the sword arm stays ahead as the lead), and the wrists and the free hand FLUTTER a little on top (small fast waves that never repeat in step).
					local t = os.clock() - motionT0
					local fs = flySpeed
					if name == "LeftShoulder" then
						want += Vector3.new((-30 * fs + 5 * math.sin(t * 9)) * SIGN.PITCH, 0, 0)
					elseif name == "RightShoulder" then
						want += Vector3.new(3 * math.sin(t * 7 + 1) * SIGN.PITCH, 0, 0)
					elseif name == "LeftElbow" then
						want += Vector3.new((16 * fs + 8 * math.sin(t * 11 + 2)) * SIGN.PITCH, 0, 0)
					elseif name == "RightElbow" then
						want += Vector3.new(6 * math.sin(t * 8) * SIGN.PITCH, 0, 0)
					elseif name == "LeftWrist" then
						want += Vector3.new(0, 0, (12 * fs + 4) * math.sin(t * 20))
					elseif name == "RightWrist" then
						want += Vector3.new(0, 0, (8 * fs + 3) * math.sin(t * 17 + 1))
					elseif name == "Neck" then
						want += Vector3.new(-8 * fs * SIGN.PITCH, 0, 0)
					end
				end
				if motionMode == "spin" then -- THE BODY OF A SPIN. The whole body turns, but its parts do not turn all at the same moment: the pelvis turns first, the back follows a moment later
					-- (so relative to the body it twists AGAINST the turn, in proportion to the speed of the turn), the sword arm lags behind the back, the head is turned AHEAD
					-- (the eyes find the target first: spotting, as a dancer does), and the free arm is flung outward by the speed. The feet make light cross steps.
					local om = spinOmega
					local ph = (os.clock() - motionT0) * 13
					local s1, c1 = math.sin(ph), math.cos(ph)
					if name == "RightHip" then
						want += Vector3.new(22 * s1 * SIGN.PITCH, 0, 0)
					elseif name == "LeftHip" then
						want += Vector3.new(-22 * s1 * SIGN.PITCH, 0, 0)
					elseif name == "RightKnee" then
						want += Vector3.new(-26 * math.max(0, c1) * SIGN.PITCH, 0, 0)
					elseif name == "LeftKnee" then
						want += Vector3.new(-26 * math.max(0, -c1) * SIGN.PITCH, 0, 0)
					elseif name == "Waist" then
						want += Vector3.new(0, -math.clamp(om * 0.012, -32, 32), 0)
					elseif name == "RootJoint" then
						want += Vector3.new(0, math.clamp(om * 0.006, -16, 16), 0)
					elseif name == "Neck" then
						want += Vector3.new(0, math.clamp(om * 0.014, -40, 40), 0)
					elseif name == "RightElbow" or name == "LeftElbow" then
						want = Vector3.new(4, 0, 0) -- the arms are straight while they circle
					elseif name == "RightShoulder" then
						want += Vector3.new(0, -math.clamp(om * 0.010, -28, 28), 0)
					elseif name == "LeftShoulder" then
						want += Vector3.new(0, 0, -math.clamp(math.abs(om) * 0.05, 0, 45))
					end
				end
				if motionMode == "walk" then -- a WALK CYCLE (one stride = 0.64 s): each hip swings against the other, the knee bends as the leg swings forward, the free arm swings against the
					-- leg on its side, the pelvis and the shoulders turn against each other (the pelvis one way, the back the other way)
					local ph = (os.clock() - motionT0) * 9.82
					local s1, c1 = math.sin(ph), math.cos(ph)
					if name == "RightHip" then
						want += Vector3.new(42 * s1 * SIGN.PITCH, 0, 0)
					elseif name == "LeftHip" then
						want += Vector3.new(-42 * s1 * SIGN.PITCH, 0, 0)
					elseif name == "RightKnee" then
						want += Vector3.new(-58 * math.max(0, c1) * SIGN.PITCH, 0, 0)
					elseif name == "LeftKnee" then
						want += Vector3.new(-58 * math.max(0, -c1) * SIGN.PITCH, 0, 0)
					elseif name == "LeftShoulder" then
						want += Vector3.new(34 * s1 * SIGN.PITCH, 0, 0)
					elseif name == "RightShoulder" then
						want += Vector3.new(-4 * s1 * SIGN.PITCH, 0, 0)
					elseif name == "RootJoint" then
						want += Vector3.new(0, 12 * s1, 0)
					elseif name == "Waist" then
						want += Vector3.new(0, -16 * s1, 0)
					elseif name == "Neck" then
						want += Vector3.new(0, 4 * s1, 0)
					end
				end
				if motionMode == "run" then -- one stride every 0.36 s: the hips swing against each other, the knee bends as the leg comes through, the back and the head twist against each other
					local ph = (os.clock() - motionT0) * 9.8
					local s1, s2 = math.sin(ph), math.cos(ph)
					if name == "RightHip" then
						want += Vector3.new(26 * s1 * SIGN.PITCH, 0, 0)
					elseif name == "LeftHip" then
						want += Vector3.new(-26 * s1 * SIGN.PITCH, 0, 0)
					elseif name == "RightKnee" then
						want += Vector3.new(-24 * math.max(0, -s1) * SIGN.PITCH, 0, 0)
					elseif name == "LeftKnee" then
						want += Vector3.new(-24 * math.max(0, s1) * SIGN.PITCH, 0, 0)
					elseif name == "Waist" then
						want += Vector3.new(0, 18 * s2, 0)
					elseif name == "RootJoint" then
						want += Vector3.new(5 * math.abs(s1) * SIGN.PITCH, -12 * s2, 0)
					elseif name == "Neck" then
						want += Vector3.new(0, -14 * s2, 0)
					end
				end
				local c0 = cur[name] -- the angles are brought to the turn nearest to the target (so 360 degrees of windmill that end back at 0 never spin the arm backwards)
				cur[name] = Vector3.new(c0.X - 360 * math.floor((c0.X - want.X) / 360 + 0.5), c0.Y - 360 * math.floor((c0.Y - want.Y) / 360 + 0.5), c0.Z - 360 * math.floor((c0.Z - want.Z) / 360 + 0.5))
				local x, v = advance(cur[name], vel[name], want, speed * (STIFF[name] or 0.8), damping, dt)
				cur[name], vel[name] = x, v
				j.Transform = j.Transform:Lerp(CFrame.Angles(rad(x.X), rad(x.Y), rad(x.Z)), weight)
			end
		end)
		if not ok then warn("[BlinkCutAnim] the motion stopped because of an error:", err) end -- (it used to stop without a word)
		if not ok or (released and weight < 0.02) then destroy() end -- a failing motion lets go instead of keeping the body stuck
	end)

	local function setPose(p: Pose, spd: number, damp: number)
		clipKeys = nil -- a pose ends a clip
		prevTarget = target
		changedAt = os.clock()
		target, speed, damping = p, spd, damp
	end

	local handle: Handle = {
		lean = function(degrees: number) leanExtra = degrees end,
		spin = function(omega: number) spinOmega = omega end,
		fly = function(speed01: number) flySpeed = speed01 end,
		elbows = function(r: number, l: number) elbowR, elbowL = r, l end,
		walk = function() -- the walk: the base pose, and the walk cycle switched on here (it does not depend on anyone calling motion())
			setPose(POSES.walkbase, 26, 0.85)
			motionMode = "walk"
			motionT0 = os.clock()
		end, -- (the walk cycle itself is the motion layer "walk")
		clip = function(name: string) -- play a keyframe clip from now
			clipKeys = CLIPS[name]
			clipT0 = os.clock()
			speed, damping = 32, 0.82
		end,
		arm = function(degrees: number) armExtra = degrees end,
		motion = function(mode: string)
			if mode ~= motionMode then
				motionMode = mode
				motionT0 = os.clock()
			end
		end,
		kick = function(name: string, speed: Vector3) -- a hit on one joint: it springs past its pose and settles (follow-through)
			if vel[name] then vel[name] += speed end
		end,
		armL = function(degrees: number) armLExtra = degrees end,
		windup = function() setPose(POSES.windup, 14, 0.85) end, -- the coil is slow
		dash = function() setPose(POSES.dash, 34, 0.62) end, -- the dash is snappy
		lunge = function() setPose(POSES.lunge, 52, 0.55) end, -- the rush: very fast and a little springy
		grab = function() setPose(POSES.grab, 42, 0.5) end, -- the hands snap on: fast and springy
		sweep = function() setPose(POSES.sweep, 44, 0.6) end, -- a fast whip, a little overshoot
		drag = function() setPose(POSES.drag, 30, 0.72) end, -- the run: heavy but quick
		drag2 = function() setPose(POSES.drag2, 30, 0.72) end,
		swing = function() setPose(POSES.swing, 26, 0.85) end, -- heavy: it leans into the turn
		heave = function() setPose(POSES.heave, 24, 0.85) end, -- the sinking: heavy and slow
		push = function() setPose(POSES.push, 56, 0.6) end, -- a hard shove with a little rebound
		land = function() setPose(POSES.land, 40, 0.78) end, -- heavy: it settles
		apex = function() setPose(POSES.apex, 18, 0.88) end, -- calm and open: it does not bounce
		lift = function() setPose(POSES.lift, 36, 0.74) end, -- the jump: snappy
		load = function() setPose(POSES.load, 36, 0.8) end, -- a quick draw back
		slam = function() setPose(POSES.slam, 64, 0.55) end, -- hard and fast, a little rebound
		brace = function() setPose(POSES.brace, 22, 0.78) end, -- the stop is firm
		cut = function() setPose(POSES.cut, 30, 0.7) end,
		finish = function() setPose(POSES.finish, 20, 0.92) end, -- the clean finish: calm, no snap
		release = function() -- the way back to the normal pose: first into the calm stance, then the overlay fades out slowly (a time constant of 0.3 s)
			clipKeys = nil
			setPose(POSES.ready, 14, 0.9)
			task.delay(0.3, function()
				released = true
				weightTarget = 0
				weightRate = 3.2
			end)
		end,
	}
	return handle
end

return Anim
