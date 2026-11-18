--!strict
-- ModuleScript "SwordRig"  (parent: Tool "DarkV1", next to Client, SwordSfx and CameraFx)
-- All body animation lives here: the poses, the combo table, the spring rig that drives the joints
-- (Motor6D / AnimationConstraint) and the victims' hit reactions.
--
--   local Anim = require(tool:WaitForChild("SwordRig")).new(CONFIG, {
--       player = player,                       -- your own character is never given a hit reaction
--       timing = require(ComboTiming),         -- shared with the Server: windup / strike / dash / ... per hit
--       onVictimHit = function(model, kind, dir) end, -- optional
--   })
--   Anim.Rig         equip(character) -> Actor?     freeze(duration) -> bool     setTurnHook(fn)   clearTurnHook(fn)
--   Actor (what equip returns), called with a colon:
--                    actor:unequip()   actor:playSwing(step, onStrike)   actor:playFinisher(step, onStrike)   actor:catch()   actor:slam()
--                    actor:cancel(time)   actor:recover(time)   actor:recoil(strength?)   actor:Destroy()
--   Anim.COMBO       the three steps (poses, timings, camera cues)
--   Anim.stepFor(index, variant)   a step or one of its variants (0 = main, 1.. = alternatives; the number wraps around)
--   Anim.variantCount(index)
--   Anim.Destroy()   releases every joint and closes the loop
--   Anim.HitReact.play(model, kind, dirWorld, power, opts)   kind: rise / chop / slam / grab / blast / fling
--
-- CONFIG fields used: PitchSign, YawSign, ElbowSign, RollSign, ArmCrossSign, AnticipateRatio, RecoverTime, SettleTime,
--   HitStopScale. Missing fields are filled with defaults
--   in the table you pass. The signs are baked into the poses when SwordRig.new runs, so change them BEFORE calling new.
--
-- Animation ideas used: anticipation -> strike -> follow-through as separate poses, slow-in / slow-out easing,
-- overlapping action (the waist leads, the wrist trails), critically damped springs on every joint, blending from the
-- CURRENT pose when a swing is cut short, and a hit pause on contact. (Buffered input and the cancel window are in Client.)

local RunService: RunService = game:GetService("RunService")

export type Pose = { [string]: CFrame } -- joint key -> rotation (see KEYS)
type EaseFn = (number) -> number
-- what callers hand in: missing pose / ease are filled with EMPTY / linear, a missing speed scale is 1
export type Segment = { pose: Pose?, time: number, ease: EaseFn?, fs: number? }
-- what an actor stores: every field set, start = seconds from the start of the timeline
type Seg = { pose: Pose, time: number, ease: EaseFn, fs: number, start: number }
type SwingEvent = { t: number, fn: (() -> ())? }
-- the left hand on the sword grip: precomputed joint frames of both arms, where the left fist goes (in the right hand's frame), the solved left arm
type Guard = {
	A: { [string]: CFrame }, B: { [string]: CFrame }, -- link(joint, pose) = A * pose * B  (the joint's C0 / C1 with the C0 rotation taken out)
	gripInHand: Vector3, elbowAt: Vector3, pole: Vector3, v: { number },
}
type JointState = { rot: CFrame, wv: Vector3 } -- spring state: shown rotation and angular velocity (rad/s)
type Joint = Motor6D | AnimationConstraint
type Camera = { [string]: any } -- the camera cues are read by Client, not here

export type Config = {
	PitchSign: number, YawSign: number, ElbowSign: number, RollSign: number, ArmCrossSign: number,
	AnticipateRatio: number, RecoverTime: number, SettleTime: number, HitStopScale: number,
	[string]: any, -- Client keeps its own settings in the same table
}
export type Timing = { [number]: { [string]: number } } -- ComboTiming: [hit] = { windup, strike, dash, ... }
export type Deps = { player: Player?, timing: Timing, onVictimHit: ((Model, string, Vector3) -> ())? }
export type HitOpts = { strength: number?, chained: boolean? }

-- one step of the combo (or one of its variants; a variant only sets what differs from its base step)
export type Step = {
	anticipate: Pose?, windup: Pose?, mid: Pose?, strike: Pose?, follow: Pose?, reboundPose: Pose?,
	spring: Pose?, roll: Pose?, rollEnd: Pose?, grip: Pose?, lift: Pose?, raise: Pose?, top: Pose?, pullUp: Pose?,
	slam: Pose?, slamMid: Pose?, slamHold: Pose?, release: Pose?,
	windupTime: number?, strikeTime: number?, followTime: number?, hold: number?, rebound: number?,
	lunge: number?, lungeTime: number?, hitStop: number?, nextAt: number?, holdTime: number?, slamTime: number?,
	slide: boolean?, launch: boolean?, finisher: boolean?, reaction: string?, oneHand: boolean?,
	strikeCam: Camera?, hitCam: Camera?, grabCam: Camera?, slamCam: Camera?, releaseCam: Camera?,
	variants: { Step }?,
}

export type Anim = {
	Rig: {
		equip: (character: Model) -> Actor?,
		freeze: (duration: number) -> boolean,
		setTurnHook: (hook: (number) -> ()) -> (),
		clearTurnHook: (hook: (number) -> ()) -> (),
	},
	COMBO: { Step },
	HitReact: { play: (model: Model, kind: string, dirWorld: Vector3?, power: number?, opts: HitOpts?) -> () },
	stepFor: (index: number, variant: number?) -> Step,
	variantCount: (index: number) -> number,
	Destroy: () -> (),
}

export type Actor = {
	-- data
	model: Model, isLocal: boolean, joints: { [string]: Joint },
	hum: Humanoid?, animator: Animator?,
	rest: Pose, params: { [string]: { number } }, delay: { [string]: number },
	c0: { [string]: CFrame }, c0i: { [string]: CFrame },
	cursor: { [string]: number }, state: { [string]: JointState },
	written: { [string]: CFrame }, under: { [string]: CFrame },
	segs: { Seg }?, from: Pose, t: number, total: number, events: { SwingEvent }, evIdx: number,
	strain: { number }?, tremorUntil: number, toolTimer: number, idleFor: number, legW: number, errors: number, locoPhase: number, tiredUntil: number, breath: number, fin: boolean, locoSpd: number, locoAcc: number, locoGaze: number, airT: number, locoTurn: number, locoW: number,
	warned: boolean, dying: boolean, dead: boolean,
	chopPose: Pose?, -- hit 3: the pose of the leaping chop (see catch / slam)
	guard: Guard?, -- the left hand on the grip (see Actor.prepareGuard)
	oneHand: boolean, -- the current swing is a one-hand swing: the left arm does not grip (it swings free as a counterweight)
	-- methods
	isUsable: (self: Actor) -> boolean, isIdle: (self: Actor) -> boolean,
	sample: (self: Actor, key: string, t: number) -> CFrame, goalFor: (self: Actor, key: string) -> CFrame,
	speedScale: (self: Actor) -> number, setSegments: (self: Actor, segs: { Segment }, events: { SwingEvent }?) -> (),
	step: (self: Actor, dt: number, now: number) -> (), write: (self: Actor, now: number) -> (),
	restore: (self: Actor) -> (), stopToolAnimations: (self: Actor) -> (), retire: (self: Actor) -> (), Destroy: (self: Actor) -> (),
	restError: (self: Actor) -> number, kick: (self: Actor, key: string, axis: Vector3, radPerSec: number) -> (),
	update: (self: Actor, dt: number, now: number) -> (),
	prepareGuard: (self: Actor) -> boolean, solveLeftHand: (self: Actor, steps: { number }, sweeps: number) -> number,
	unequip: (self: Actor) -> (), playSwing: (self: Actor, step: Step, onStrike: (() -> ())?) -> (),
	playFinisher: (self: Actor, step: Step, onStrike: (() -> ())?) -> (), catch: (self: Actor) -> (), slam: (self: Actor) -> (),
	cancel: (self: Actor, time: number?) -> (), recover: (self: Actor, time: number?) -> (), recoil: (self: Actor, strength: number?) -> (), playDraw: (self: Actor) -> (),
	shift: (self: Actor, amount: number) -> (), loadLegs: (self: Actor) -> (), strikePhysics: (self: Actor, index: number) -> (),
}

local SwordRig = {}

function SwordRig.new(CONFIG: Config, deps: Deps): Anim
	assert(type(CONFIG) == "table" and type(deps) == "table" and type(deps.timing) == "table", "SwordRig.new(CONFIG, { timing = ..., player = ... })")
	-- missing settings get safe defaults (so a deleted line in CONFIG cannot break the maths)
	local DEFAULTS: { [string]: any } = {
		YawSign = 1, PitchSign = 1, ElbowSign = 1, RollSign = 1, ArmCrossSign = 1,
		AnticipateRatio = 0.35, RecoverTime = 0.4, SettleTime = 0.2, HitStopScale = 0.04,
	}
	local cfg = CONFIG :: { [string]: any }
	for k, v in DEFAULTS do
		if cfg[k] == nil then
			cfg[k] = v
		end
	end
	local T: Timing = deps.timing -- shared with the Server: { windup, strike, dash, nextAt } per hit
	--------------------------------------------------------------------------------
	-- Helpers and poses
	--------------------------------------------------------------------------------
	local rad: (number) -> number = math.rad
	-- Named tuning numbers (were magic numbers inside the functions)
	local SPRING_HZ: number = 120 -- spring sub-steps per second of animation time
	local MAX_SUBSTEPS_LOCAL: number, MAX_SUBSTEPS_VICTIM: number = 6, 3 -- victims need fewer steps (many at once)
	local DT_CAP: number = 1 / 20 -- a lag spike never advances the animation by more than this
	local LEG_STILL_SPEED: number = 3 -- studs/s: at this walking speed the leg offsets are fully faded out
	local LEG_BLEND: number = 0.25 -- how fast the leg weight follows (per frame)
	local MAX_ACTOR_ERRORS: number = 20 -- a local actor that fails this many frames in a row is released instead of staying stuck in a pose
	local LAG_MAX: number = rad(14) -- the most a limb may trail behind the limb above it (radians)
	local CARRY_GAIN: number = 0.4 -- at impact the moving joints get this much faster (times the hit weight): the follow-through of a heavy blow
	local CARRY_KEYS: { string } = { "w", "n", "rs", "re", "rw", "ls", "le", "lw" }
	local MIN_SEG_TIME: number = 0.001 -- a segment is never shorter (no division by zero in the easing)
	local TOOL_CHECK_EVERY: number = 0.25 -- s: how often the tool's own animation is stopped again
	local WATCHDOG_EVERY: number = 0.5 -- s idle before the pose is checked against the ready pose
	local WATCHDOG_ANGLE: number = 0.06 -- rad: a larger difference makes the rig glide back to ready
	local DYING_EXTRA: number = 0.12 -- s the release glide stays on after it ended
	local VICTIM_LINGER: number = 0.5 -- s a victim keeps its last pose after the reaction ended, then it is released

	local ID: CFrame = CFrame.identity
	-- law 107 (joint limits): a gait pose may never bend a knee backwards or an elbow the wrong way (raw x angle in degrees, before the rig sign)
	local JOINT_LIMIT: { [string]: { number } } = { lk = { -150, 3 }, rk = { -150, 3 }, le = { -3, 150 }, re = { -3, 150 } }

	local function ang(x: number, y: number, z: number): CFrame
		return CFrame.Angles(rad(x), rad(y), rad(z))
	end
	-- shoulder: raise forward by x, then yaw around the body (positive y = left), z = roll
	local function sw(x: number, y: number, z: number): CFrame
		return CFrame.fromEulerAnglesYXZ(rad(x), rad(y * CONFIG.YawSign), rad(z))
	end
	-- body: negative x = lean forward, positive y = turn left
	local function bd(x: number, y: number, z: number): CFrame
		return ang(x * CONFIG.PitchSign, y * CONFIG.YawSign, z * (CONFIG.RollSign or 1))
	end
	-- shoulder roll that crosses the arm over the body (negative z = toward the left side for the right arm)
	local function cross(z: number): number
		return z * (CONFIG.ArmCrossSign or 1)
	end
	local function el(d: number): CFrame
		return ang(d * CONFIG.ElbowSign, 0, 0)
	end
	local function wr(x: number, y: number, z: number): CFrame
		return ang(x, y, z)
	end

	local Ease: { [string]: EaseFn } = {
		-- the user's 3-section curve as an ease: almost a straight line at the start (slope 1.25), then a parabola with the SAME slope
		-- that lands softly at 1 (slope 0). Line y = s*u up to u0 = 0.6, then y = 1 - c*(1-u)^2 (s = 2/(1+u0), c = s/(2*(1-u0))).
		curveOut = function(a: number): number
			local u0 = 0.6
			local s = 2 / (1 + u0)
			if a <= u0 then return s * a end
			return 1 - (s / (2 * (1 - u0))) * (1 - a) * (1 - a)
		end,
		linear = function(a: number): number return a end,
		outQuad = function(a: number): number return 1 - (1 - a) * (1 - a) end,
		-- starts from rest and keeps speeding up: the blade is FASTEST at the end (the impact), then the follow-through slows it
		accel = function(a: number): number return a ^ 1.4 end, -- ends at 1.4 x the average speed; a middle key then sits at about 42% of the way, so the speed matches on both sides
		inOutSine = function(a: number): number return 0.5 - 0.5 * math.cos(math.pi * a) end, -- no sudden start or stop
		outSine = function(a: number): number return math.sin(a * math.pi / 2) end,
		-- the blade keeps its speed for the first 70 %, then brakes to about 60 % of it in the last 30 % (the edge bites into the target): tight spacing just before contact
		impactBrake = function(a: number): number
			if a <= 0.7 then return 1.06 * a end
			local x = a - 0.7
			return 0.742 + 1.06 * x - 0.667 * x * x
		end,
		outCubic = function(a: number): number return 1 - (1 - a) ^ 3 end,
		inOutQuad = function(a: number): number
			if a < 0.5 then return 2 * a * a end
			return 1 - ((-2 * a + 2) ^ 2) / 2
		end,
	}

	local KEYS: { string } = { "r", "w", "n", "rs", "re", "rw", "ls", "le", "lw", "lh", "rh", "lk", "rk", "la", "ra" }
	local LEG: { [string]: boolean } = { lh = true, rh = true, lk = true, rk = true, la = true, ra = true } -- victims only
	local JOINT_NAMES: { [string]: string } = {
		r = "Root", w = "Waist", n = "Neck",
		rs = "RightShoulder", re = "RightElbow", rw = "RightWrist",
		ls = "LeftShoulder", le = "LeftElbow", lw = "LeftWrist",
		lh = "LeftHip", rh = "RightHip", lk = "LeftKnee", rk = "RightKnee", la = "LeftAnkle", ra = "RightAnkle",
	}
	local JOINT_NAMES_R6: { [string]: string } = {
		r = "RootJoint", n = "Neck", rs = "Right Shoulder", ls = "Left Shoulder", lh = "Left Hip", rh = "Right Hip",
	}

	local function P(t: Pose): Pose
		for _, k in KEYS do
			if t[k] == nil then t[k] = ID end
		end
		return t
	end

	local EMPTY: Pose = P({})
	-- READY / SETTLE / FINISH: the stance you hold the sword in, the pose after a swing, and the pose between a swing and READY.
	-- LOW DIAGONAL carry: the right hand holds the hilt low in front of the right hip and the blade points forward, down and across the
	-- body to the left. The right-arm numbers here are only the fallback; they are solved at equip (see solveGuard). The left arm hangs
	-- loose and joins the grip during a swing (see Actor.prepareGuard). The body is turned a little, the weight on the back leg.
	local READY: Pose = P({ rs = sw(22, 20, 0), re = el(50), rw = wr(-10, 0, 8), ls = sw(4, 10, 0), le = el(20), w = bd(-1, -10, 0), r = bd(0, -6, 0), n = bd(1, 9, 0) })
	local SETTLE: Pose = P({ rs = sw(20, 18, 0), re = el(46), rw = wr(-8, 0, 6), ls = sw(3, 9, 0), le = el(18), w = bd(-1, -9, 0), r = bd(0, -5, 0), n = bd(0, 7, 0) })
	local FINISH: Pose = P({ rs = sw(30, 20, 0), re = el(56), rw = wr(-8, 0, 8), ls = sw(10, 10, 0), le = el(22), w = bd(-3, -9, 0), r = bd(0, -5, 0), n = bd(-1, 6, 0) })

	-- TWO-HANDED STARTUPS. Hit 1 (a steep cut from the top right): both hands rise together to above the right shoulder, the body turns away.
	-- Hit 2 (a rising cut from low left): both hands sink to the left hip, the body turns to the left and sinks.
	local H1A: Pose = P({ rs = sw(104, -24, 0), re = el(78), rw = wr(-14, 0, 4), ls = sw(92, -4, 0), le = el(76), w = bd(4, -22, 0), r = bd(2, -12, 0), n = bd(-2, 10, 0) })
	local H1W: Pose = P({ rs = sw(152, -38, cross(8)), re = el(68), rw = wr(-24, 0, 6), ls = sw(130, -18, 0), le = el(62), w = bd(14, -62, 0), r = bd(5, -42, 0), n = bd(-5, 34, 0) })
	local H2A: Pose = P({ rs = sw(52, 18, 0), re = el(70), rw = wr(-6, 0, 8), ls = sw(36, -44, 0), le = el(36), w = bd(-14, 36, 0), r = bd(-4, 24, 0), n = bd(5, -22, 0) })
	local H2W: Pose = P({ rs = sw(40, 36, 0), re = el(60), rw = wr(10, 0, 24), ls = sw(20, -66, 0), le = el(40), w = bd(-34, 80, 0), r = bd(-12, 54, 0), n = bd(10, -56, 0) })


	-- windup / strike / dash / hold / slam / nextAt come from the shared ComboTiming module, so the Server and this rig always agree.
	local COMBO: { Step } = {
		{ -- 1: STEEP DIAGONAL CHOP, high on the right down to the low left; the sword ends in front of the LEFT leg.
			-- Plane: steep (top to bottom). Body: folds FORWARD (about -54) and twists from -98 (right) to +104 (left).
			-- Arm: nearly straight, it passes high over the head (mid key = the arc), left arm swings out and back.
			-- the blade is drawn up in one flowing arc, behind the head (the elbow folds, the wrist cocks), the left arm points at the enemy as a guide
			anticipate = H1A,
			windup = H1W,
			mid = P({ rs = sw(135, -14, cross(6)), re = el(36), rw = wr(0, 0, 10), ls = sw(50, -34, 0), le = el(46), w = bd(0, -23, 0), r = bd(0, -16, 0), n = bd(2, 4, 0) }),
			strike = P({ rs = sw(84, 12, 0), re = el(14), rw = wr(10, 0, 22), ls = sw(34, -34, 0), le = el(40), w = bd(-24, 26, 0), r = bd(-6, 16, 0), n = bd(10, -12, 0) }),
			follow = P({ rs = sw(60, 12, 0), re = el(8), rw = wr(16, 0, 26), ls = sw(26, -52, 0), le = el(40), w = bd(-40, 62, 0), r = bd(-14, 42, 0), n = bd(20, -42, 0) }),
			windupTime = T[1].windup, strikeTime = T[1].strike,
			-- TIMELINE: startup (its last 2 frames are a full stop = the telegraph), strike, contact, hit stop, overshoot, rebound
			-- (the next click is accepted at nextAt), recovery. The times come from ComboTiming (1 frame = 1/30 s).
			hold = 2 / 30, followTime = 0.10, rebound = 0.07, -- hold 2/30 = a clear full stop at the top of the coil (the telegraph)
			lunge = 32, lungeTime = T[1].strike, hitStop = 0.11, nextAt = T[1].nextAt, slide = true, -- slide = the enemy skids (see the Server)
			-- rebound (F17): the blade springs back a little from the overshoot, the weight starts to come back
			reboundPose = P({ rs = sw(66, 12, 0), re = el(10), rw = wr(14, 0, 24), ls = sw(26, -48, 0), le = el(40), w = bd(-36, 56, 0), r = bd(-12, 38, 0), n = bd(16, -36, 0) }),
			reaction = "chop",
			variants = {
				{ -- 1b: wider, the arm starts far out on the right side and the twist is bigger (about 110 degrees at the end)
					anticipate = P({ rs = sw(100, -64, 0), re = el(64), ls = sw(66, -18, 0), le = el(48), w = bd(4, -24, 0), r = bd(0, -14, 0) }),
					windup = P({ rs = sw(132, -92, cross(12)), re = el(68), rw = wr(-14, 0, 0), ls = sw(112, -44, 0), le = el(60), w = bd(10, -64, 0), r = bd(4, -44, 0), n = bd(-6, 34, 0) }),
					mid = P({ rs = sw(110, -46, cross(6)), re = el(40), rw = wr(0, 0, 8), ls = sw(46, -36, 0), le = el(46), w = bd(-2, -25, 0), r = bd(0, -18, 0), n = bd(2, 8, 0) }),
					strike = P({ rs = sw(76, 14, 0), re = el(16), rw = wr(10, 0, 22), ls = sw(36, -32, 0), le = el(40), w = bd(-26, 28, 0), r = bd(-6, 18, 0), n = bd(10, -14, 0) }),
					follow = P({ rs = sw(60, 18, 0), re = el(8), rw = wr(16, 0, 26), ls = sw(28, -56, 0), le = el(40), w = bd(-44, 66, 0), r = bd(-14, 44, 0), n = bd(20, -46, 0) }),
				},
			},
			strikeCam = { kick = { -1.3, 1.5, 0.3 }, push = 0.3, fov = 3.5, sweep = { 1.6, -0.9, 0.25, 0.3 } }, -- pans left and tips down with the cut
			hitCam = { shake = 0.8, kick = { -2.8, 1.0, 0.9 }, push = 0.55, fov = 5, post = { tint = 0.34, flash = 0.34 } }, -- hit 1: a clear, heavy chop; flash steps go 1 : 1.6 : 2.6 (0.34 / 0.55 / 0.9) so the finisher is clearly the biggest
		},
		{ -- 2: RISING REVERSE CUT, low left up to high right. HELD IN ONE HAND (oneHand): the left arm lets go and swings out as a counterweight
			oneHand = true,
			-- Plane: rising (bottom to top). Body: ARCHES BACK (about +30) and untwists from +128 (left) to -120 (right).
			-- Arm: ELBOW-LED (tucked at first, then it snaps straight), left arm pulls in, the head looks up. Slower start, faster finish.
			-- the blade leaves the shoulder, swings down and around to low on the left side (the same coil as before, a smoother start)
			anticipate = H2A,
			windup = H2W,
			mid = P({ rs = sw(70, 19, 0), re = el(50), rw = wr(0, 0, 10), ls = sw(30, -20, 0), le = el(40), w = bd(-20, 42, 0), r = bd(-5, 28, 0), n = bd(6, -30, 0) }),
			strike = P({ rs = sw(118, -10, 0), re = el(12), rw = wr(-8, 0, -20), ls = sw(30, 18, 0), le = el(36), w = bd(0, -8, 0), r = bd(2, -4, 0), n = bd(-4, 6, 0) }),
			follow = P({ rs = sw(166, -54, cross(8)), re = el(8), rw = wr(-14, 0, -18), ls = sw(24, 34, 0), le = el(30), w = bd(30, -72, 0), r = bd(11, -48, 0), n = bd(-16, 34, 0) }), -- (the back arch was 22: it read small on video)
			windupTime = T[2].windup, strikeTime = T[2].strike, followTime = 0.12, hold = 2 / 30, rebound = 0.08,
			-- TIMELINE: as hit 1 (the last 2 frames of the startup are a full stop at the bottom of the coil); the times come from ComboTiming
			lunge = 24, lungeTime = T[2].strike, hitStop = 0.13, nextAt = T[2].nextAt, launch = true, -- launch = the enemy is cut upward (see the Server); slower and longer than hit 1: the combo gets heavier
			-- rebound: the blade springs back from the high overshoot, the hips start to come back
			reboundPose = P({ rs = sw(152, -46, cross(6)), re = el(10), rw = wr(-12, 0, -16), ls = sw(24, 30, 0), le = el(30), w = bd(18, -62, 0), r = bd(6, -42, 0), n = bd(-12, 30, 0) }),
			reaction = "rise",
			variants = {
				{ -- 2b: flat backhand sweep at chest height, spins from the left to the right
					oneHand = true,
					anticipate = P({ rs = sw(70, 40, 0), re = el(50), ls = sw(34, -30, 0), le = el(40), w = bd(-4, 40, 0), r = bd(0, 26, 0), n = bd(0, -26, 0) }),
					windup = P({ rs = sw(88, 82, 0), re = el(30), rw = wr(8, 0, 0), ls = sw(54, -26, 0), le = el(34), w = bd(-4, 66, 0), r = bd(0, 44, 0), n = bd(0, -44, 0) }),
					mid = P({ rs = sw(90, 43, 0), re = el(24), ls = sw(34, -24, 0), le = el(42), w = bd(-4, 38, 0), r = bd(0, 25, 0), n = bd(0, -26, 0) }),
					strike = P({ rs = sw(92, -10, 0), re = el(12), rw = wr(-8, 0, 0), ls = sw(36, 10, 0), le = el(40), w = bd(-6, 0, 0), r = bd(0, 0, 0), n = bd(0, 0, 0) }),
					follow = P({ rs = sw(96, -98, 0), re = el(10), ls = sw(32, 30, 0), le = el(44), w = bd(-8, -72, 0), r = bd(0, -48, 0), n = bd(0, 40, 0) }),
					reboundPose = P({ rs = sw(96, -88, 0), re = el(12), ls = sw(32, 26, 0), le = el(44), w = bd(-8, -64, 0), r = bd(0, -42, 0), n = bd(0, 34, 0) }),
				},
			},
			strikeCam = { kick = { 1.4, -1.6, -1.0 }, push = 0.2, fov = 3, sweep = { -1.5, 0.55, 0.4, 0.3 } }, -- pans right and rises with the cut
			hitCam = { shake = 0.7, kick = { 2.8, -1.3, -0.9 }, push = 0.3, fov = 4, post = { tint = 0.3, flash = 0.55 } }, -- hit 2: the view snaps UP with the cut (hit 1 snaps down)
		},
	{ -- 3: MOONFALL (finisher): crouch and coil, invulnerable forward ROLL, catch, lift the enemy and the sword overhead, SLAM it down.
		-- No recovery after the slam: the closing pose is short (the Server lets you act right away).
		anticipate = P({ rs = sw(40, -20, 0), re = el(60), ls = sw(30, -10, 0), le = el(50), w = bd(-10, -6, 0), r = bd(-6, -4, 0), n = bd(6, 0, 0) }), -- sink down
		windup = P({ rs = sw(20, -30, 0), re = el(70), rw = wr(-10, 0, 0), ls = sw(24, -16, 0), le = el(60), w = bd(-26, -10, 0), r = bd(-14, -6, 0), n = bd(14, 0, 0) }), -- coiled low, sword held back
		-- spring: the last 2 frames of the crouch: the coil is released, the body drops its weight forward into the roll
		spring = P({ rs = sw(14, -26, 0), re = el(76), ls = sw(26, -10, 0), le = el(64), w = bd(-34, -6, 0), r = bd(-18, -4, 0), n = bd(12, 0, 0) }),
		-- roll: the root turns a full somersault in four quarter turns, the arms and the sword are tucked in
		roll = P({ rs = sw(36, -24, 0), re = el(84), ls = sw(30, -8, 0), le = el(78), w = bd(-34, 0, 0), n = bd(22, 0, 0) }),
		rollEnd = P({ rs = sw(54, -14, 0), re = el(60), ls = sw(30, 10, 0), le = el(48), w = bd(-14, 0, 0), r = bd(-6, 0, 0), n = bd(4, 0, 0) }), -- comes up out of the roll
		-- THE LIFT, in five keys (the arms are never straight and locked: a held weight keeps the elbows bent and the hands close together)
		--   grip: both hands come together on the grip near the belly (the sword is still low)
		grip = P({ rs = sw(86, -18, 0), re = el(78), rw = wr(-10, 0, 4), ls = sw(80, -6, 0), le = el(80), w = bd(0, -8, 0), r = bd(0, -5, 0), n = bd(0, 4, 0) }),
		--   lift: the blade sweeps up from the low right side; the body turns a little and the weight sits on the back leg
		lift = P({ rs = sw(104, -34, cross(4)), re = el(70), rw = wr(-16, 0, 6), ls = sw(94, -14, 0), le = el(68), w = bd(4, -20, 0), r = bd(2, -12, 0), n = bd(-4, 12, 0) }),
		--   raise: the hands pass the shoulders, the elbows open
		raise = P({ rs = sw(134, -14, cross(5)), re = el(56), rw = wr(-18, 0, 4), ls = sw(124, -4, 0), le = el(54), w = bd(10, -6, 0), r = bd(5, -3, 0), n = bd(-8, 3, 0) }),
		--   top: the sword stands over the head, the elbows still soft, the chest open
		top = P({ rs = sw(158, -8, cross(4)), re = el(36), rw = wr(-26, 0, 0), ls = sw(148, 0, 0), le = el(36), w = bd(18, 0, 0), r = bd(9, 0, 0), n = bd(-14, 0, 0) }),
		--   pullUp: one last breath before the slam: the blade goes a little further back, the back arches (the last 2 frames of the hold)
		pullUp = P({ rs = sw(164, -6, cross(4)), re = el(30), rw = wr(-24, 0, 0), ls = sw(154, 2, 0), le = el(32), w = bd(18, 0, 0), r = bd(8, 0, 0), n = bd(-12, 0, 0) }),
		-- slam: the overhead sword falls in one arc (slamMid, then slam): the arms pass the shoulders, the chest comes forward a little, the front foot stamps
		slamMid = P({ rs = sw(116, -6, 0), re = el(30), rw = wr(2, 0, 0), ls = sw(110, -4, 0), le = el(32), w = bd(1, -2, 0), r = bd(0, -1, 0), n = bd(-2, 0, 0) }), -- the arc: the arms pass the shoulders, the chest comes forward
		slam = P({ rs = sw(64, -2, 0), re = el(16), rw = wr(14, 0, 0), ls = sw(60, -2, 0), le = el(18), w = bd(-5, 0, 0), r = bd(-2, 0, 0), n = bd(3, 0, 0) }),
		-- release: the enemy is let go; the sword eases out low and the body comes back up (no flick)
		release = P({ rs = sw(92, -34, 0), re = el(14), rw = wr(-12, 0, 6), ls = sw(62, 16, 0), le = el(22), w = bd(-8, -20, 0), r = bd(-3, -10, 0), n = bd(3, 8, 0) }),
		slamHold = P({ rs = sw(58, -2, 0), re = el(18), rw = wr(14, 0, 0), ls = sw(54, -2, 0), le = el(20), w = bd(-6, 0, 0), r = bd(-2, 0, 0), n = bd(4, 0, 0) }),
		windupTime = T[3].windup, strikeTime = T[3].strike,
		lunge = 30 / T[3].dash, lungeTime = T[3].dash, hitStop = 0.1, nextAt = T[3].nextAt, -- lunge = roll speed in studs per second (30 studs per dash time); the hit stop on the slam is 0.24 s
		holdTime = T[3].hold, slamTime = T[3].slam,
		finisher = true, reaction = "grab",
		strikeCam = { holdTime = 0.3, hold = 3, speed = 0.3, kick = { 0, 0, 0.8 }, shake = 0.12, sweep = { 0, 0.8, 0, 0.35 }, pushHold = 0.5 }, -- while rolling: the lens opens 3 degrees for speed
		grabCam = { shake = 1.0, kick = { -4.6, 0, 0.9 }, push = 1.0, fov = -4.5, post = { tint = 0.45, flash = 0.65 } }, -- the chop lands: the view snaps DOWN with it, zooms in and flashes
		slamCam = { shake = 0.6, kick = { -1.6, 0, 0.5 }, push = 0.4, fov = -2.5, post = { tint = 0.3, flash = 0.5 } }, -- the throw: a smaller second beat (the chop already took the big one)
		releaseCam = { shake = 0.25, kick = { 1.4, 0, 0 }, push = -0.5, fov = 3, post = { tint = 0.15 } }, -- the enemy is thrown away: the view eases back and tips up
	},
}

	-- HIT 3 AFTER THE ROLL = a hit-1 style cut. The caught enemy is held while you coil exactly like hit 1 (twist, sword high on the right),
	-- then the same steep diagonal cut sends it flying. The poses are COPIES of hit 1's (the leg values are set per pose below).
	do
		local c1, c3 = COMBO[1], COMBO[3]
		local function copy(p: Pose?): Pose
			return P(table.clone(p or EMPTY))
		end
		c3.grip, c3.lift, c3.raise, c3.top = copy(c1.anticipate), copy(c1.windup), copy(c1.windup), copy(c1.windup)
		local pull: Pose = copy(c1.windup)
		pull.w, pull.r, pull.n = bd(18, -70, 0), bd(6, -50, 0), bd(-8, 40, 0)
		c3.pullUp = pull
		c3.slamMid, c3.slam, c3.slamHold, c3.release = copy(c1.mid), copy(c1.strike), copy(c1.follow), copy(c1.reboundPose)
	end

	-- Spring settings: { frequency Hz, damping ratio }
	-- The torso is stiffer than the arms, so it moves FIRST and the arms are pulled behind it (a kinetic chain);
	-- the wrists are the loosest (lowest damping) and whip a little past the pose.
	local LOCAL_PARAMS: { [string]: { number } } = {
		r = { 6.4, 1.0 }, w = { 8, 0.95 }, n = { 7.5, 0.9 }, -- lower numbers = a heavier body that takes longer to get going and to stop
		rs = { 9.2, 0.85 }, ls = { 9, 0.9 }, re = { 9, 0.8 }, le = { 9, 0.85 },
		rw = { 11.5, 0.6 }, lw = { 11, 0.7 },
		lh = { 6, 0.9 }, rh = { 6, 0.9 }, lk = { 6, 0.9 }, rk = { 6, 0.9 }, la = { 6, 0.9 }, ra = { 6, 0.9 },
	}
	local VICTIM_PARAMS: { [string]: { number } } = {
		r = { 5, 0.6 }, w = { 6, 0.55 }, n = { 7, 0.45 },
		rs = { 7, 0.5 }, ls = { 7, 0.5 }, re = { 8, 0.5 }, le = { 8, 0.5 },
		rw = { 8, 0.5 }, lw = { 8, 0.5 },
		lh = { 6, 0.5 }, rh = { 6, 0.5 }, lk = { 7, 0.45 }, rk = { 7, 0.45 }, la = { 7, 0.5 }, ra = { 7, 0.5 },
	}
	-- Joint stagger as a time shift (seconds): the waist leads, the wrist trails.
	local LOCAL_DELAY: { [string]: number } = {
		r = 0, w = 0.012, n = 0.045, rs = 0.035, ls = 0.042, re = 0.062, le = 0.07, rw = 0.088, lw = 0.1,
	}

	-- Victims: the chain reacts root first, then waist, arms, head (whip effect)
	local VICTIM_DELAY: { [string]: number } = {
		r = 0, w = 0.012, n = 0.04, rs = 0.025, ls = 0.025, re = 0.04, le = 0.04, rw = 0.05, lw = 0.05,
		lh = 0.01, rh = 0.01, lk = 0.025, rk = 0.025, la = 0.04, ra = 0.04,
	}

	--------------------------------------------------------------------------------
	-- Actor: one animated character (you or a victim).
	-- A swing is a list of segments (pose, time, ease). Every joint samples that list, a spring follows the sample,
	-- and the result is written to the joint. One PreSimulation loop steps all actors.
	--------------------------------------------------------------------------------
	-- DRAG: a limb trails behind the one above it while that one is turning (the blade is heavy, the wrist is the last to follow).
	-- { source joint, seconds }: the offset is the source's angular velocity times these seconds, backwards.
	local DRAG: { [string]: { { src: string, secs: number } } } = {
		re = { { src = "rs", secs = 0.010 } },
		rw = { { src = "re", secs = 0.016 }, { src = "rs", secs = 0.010 } },
		le = { { src = "ls", secs = 0.008 } },
		lw = { { src = "le", secs = 0.014 }, { src = "ls", secs = 0.008 } },
		n = { { src = "w", secs = 0.016 } },
		rs = { { src = "w", secs = 0.006 } },
		ls = { { src = "w", secs = 0.006 } },
	}

	-- THE SWORD CARRY. The R15 hands sit 0.5 stud outside the shoulder axis, so fixed arm angles never put the fist in the same place for
	-- every avatar. Instead the right-arm angles of READY / SETTLE / FINISH are SOLVED for the avatar that equips the sword: the right fist
	-- goes to `hand` and the blade points along `blade` (both in the UpperTorso frame: x right, y up, -z forward). Joint frames (C0 / C1)
	-- are read from the rig, so no sign guessing. If the target cannot be reached, the fixed angles of the pose stay.
	local CARRY_TARGETS: { { pose: Pose, hand: Vector3, blade: Vector3 } } = {
		{ pose = READY, hand = Vector3.new(0.60, -0.80, -0.85), blade = Vector3.new(-0.45, -0.35, -0.82) },
		{ pose = SETTLE, hand = Vector3.new(0.60, -0.85, -0.80), blade = Vector3.new(-0.42, -0.40, -0.81) },
		{ pose = FINISH, hand = Vector3.new(0.60, -0.60, -0.95), blade = Vector3.new(-0.40, -0.20, -0.89) },
	}

	local function solveGuard(model: Model, joints: { [string]: Joint })
		local function motor(key: string): Motor6D?
			local j = joints[key]
			if j and j.ClassName == "Motor6D" then
				return j :: Motor6D
			end
			return nil
		end
		local rs, re, rw = motor("rs"), motor("re"), motor("rw")
		if not (rs and re and rw and motor("ls") and motor("le") and motor("lw")) then return end

		-- which way the blade leaves the right hand, in the HAND's frame: read from the sword's Handle (its longest side, pointing away from
		-- the grip); a Handle that is not long (or not welded yet) falls back to the hand's forward axis
		local bladeInHand = Vector3.new(0, 0, -1)
		local tool = model:FindFirstChildOfClass("Tool")
		local handle = if tool then tool:FindFirstChild("Handle") else nil
		local handPart = model:FindFirstChild("RightHand")
		if handle and handle:IsA("BasePart") and handPart and handPart:IsA("BasePart") then
			local size = handle.Size
			local longest = math.max(size.X, size.Y, size.Z)
			local rel = handPart.CFrame:ToObjectSpace(handle.CFrame)
			if longest >= 2.5 and rel.Position.Magnitude < 4 then
				local axis: Vector3 = Vector3.zAxis
				if size.X == longest then
					axis = Vector3.xAxis
				elseif size.Y == longest then
					axis = Vector3.yAxis
				end
				local dir = rel:VectorToWorldSpace(axis)
				if rel.Position:Dot(dir) < 0 then
					dir = -dir
				end
				bladeInHand = dir.Unit
			end
		end

		-- the hand's frame in the UpperTorso frame, for these joint angles (the same maths Roblox uses: C0 * Transform * C1^-1)
		local function link(j: Motor6D, pose: CFrame): CFrame
			local c0 = j.C0.Rotation
			return j.C0 * (c0:Inverse() * pose * c0) * j.C1:Inverse()
		end
		local function hand(pitch: number, yaw: number, bend: number, flick: number): CFrame
			return link(rs, sw(pitch, yaw, 0)) * link(re, el(bend)) * link(rw, wr(flick, 0, 0))
		end

		-- variables: right shoulder pitch / yaw, right elbow, right wrist
		local lo = { 0, -80, 0, -60 }
		local hi = { 150, 80, 140, 60 }
		local v: { number } = { 34, 20, 22, -4 }
		for _, g in CARRY_TARGETS do
			local function cost(x: { number }): number
				local hr = hand(x[1], x[2], x[3], x[4])
				local dr = hr.Position - g.hand
				local dd = hr:VectorToWorldSpace(bladeInHand) - g.blade
				return dr:Dot(dr) + dd:Dot(dd)
			end
			local best = cost(v)
			for _, step in { 16, 8, 4, 2, 1, 0.5 } do
				for _ = 1, 3 do
					for i = 1, #v do
						for _, dir in { 1, -1 } do
							local old = v[i]
							v[i] = math.clamp(old + dir * step, lo[i], hi[i])
							local c = cost(v)
							if c < best then
								best = c
							else
								v[i] = old
							end
						end
					end
				end
			end
			if best < 0.6 then
				local pose = g.pose
				pose.rs, pose.re, pose.rw = sw(v[1], v[2], 0), el(v[3]), wr(v[4], 0, 0)
			end
		end
	end

	local Actor = {}
	Actor.__index = Actor

	local Rig = {}
	local actors: { [Instance]: Actor } = {} -- [model] = Actor
	local turnHook: ((number) -> ())? = nil -- set while a swing turns the body (runs inside the single step loop)
	local frozenUntil = 0 -- hit stop (slow motion) until this os.clock()

	-- true when two rotations are the same (used to see whether the Animator wrote the joint this frame)
	local function sameRot(a: CFrame, b: CFrame): boolean
		return a.RightVector:Dot(b.RightVector) > 0.99999 and a.UpVector:Dot(b.UpVector) > 0.99999
	end

	-- joint key -> joint instance. Your own legs: hips + knees only, never ankles.
	local function findJoints(model: Instance, isLocal: boolean): { [string]: Joint }
		local joints: { [string]: Joint } = {}
		local hum = model:FindFirstChildOfClass("Humanoid")
		local names = (hum and hum.RigType == Enum.HumanoidRigType.R6) and JOINT_NAMES_R6 or JOINT_NAMES
		local wanted: { [string]: string } = {}
		for key, name in names do
			if (not isLocal) or (not LEG[key]) or (key ~= "la" and key ~= "ra") then
				wanted[name] = key
			end
		end
		-- one pass; joints inside accessories (hats, capes) are skipped even if the name matches
		for _, d in model:GetDescendants() do
			local key = wanted[d.Name]
			if key and not joints[key] and (d:IsA("Motor6D") or d:IsA("AnimationConstraint"))
				and not d:FindFirstAncestorOfClass("Accessory") then
				joints[key] = d :: Joint
			end
		end
		return joints
	end

	-- returns nil when the model has no usable rig
	function Actor.new(model: Model, isLocal: boolean): Actor?
		local joints = findJoints(model, isLocal)
		local shoulder = joints.rs
		if not shoulder or not (joints.w or joints.r) or (isLocal and not joints.w) then
			return nil
		end
		if isLocal then
			solveGuard(model, joints)
		end
		local hum = model:FindFirstChildOfClass("Humanoid")
		local rest: Pose = if isLocal then READY else EMPTY
		local fields = {
			model = model, isLocal = isLocal, joints = joints,
			hum = hum, animator = if hum then hum:FindFirstChildOfClass("Animator") else nil,
			rest = rest,
			params = if isLocal then LOCAL_PARAMS else VICTIM_PARAMS,
			delay = if isLocal then LOCAL_DELAY else VICTIM_DELAY,
			c0 = {} :: { [string]: CFrame }, c0i = {} :: { [string]: CFrame }, -- joint frames (never change while the actor lives)
			cursor = {} :: { [string]: number }, -- [key] = index of the segment this joint is in (time only moves forward, so no rescan)
			state = {} :: { [string]: JointState }, -- spring state per joint
			written = {} :: { [string]: CFrame }, under = {} :: { [string]: CFrame }, -- "multiply" mode: what we wrote last frame / what the animator had under it
			segs = nil :: { Seg }?, from = {} :: Pose, t = 0, total = 0, events = {} :: { SwingEvent }, evIdx = 1,
			strain = nil :: { number }?, -- { from, to }: the arm trembles with effort between these times
			tremorUntil = 0, toolTimer = 0, idleFor = 0, legW = 0, errors = 0, locoPhase = 0, tiredUntil = 0, breath = 0, fin = false, locoSpd = 0, locoAcc = 0, locoGaze = 0, airT = 0, locoTurn = 0, locoW = 0, oneHand = false,
			warned = false, dying = false, dead = false,
			guard = nil :: Guard?, chopPose = nil :: Pose?,
		}
		local self = (setmetatable(fields, Actor :: any) :: any) :: Actor
		for key, j in joints do
			self.state[key] = { rot = rest[key].Rotation, wv = Vector3.zero }
			-- poses are written in the parent part frame, Transform lives in the C0 frame
			local c0: CFrame = ID
			if j.ClassName == "Motor6D" then
				local motor = j :: Motor6D
				c0 = motor.C0.Rotation
			elseif j.ClassName == "AnimationConstraint" then
				local att0: Attachment? = (j :: AnimationConstraint).Attachment0
				if att0 then
					c0 = att0.CFrame.Rotation
				end
			end
			self.c0[key] = c0
			self.c0i[key] = c0:Inverse()
		end
		return self
	end

	function Actor.isIdle(self: Actor): boolean
		return self.segs == nil or self.t >= self.total
	end

	-- the pose of one joint at time t of the segment list (before the spring)
	function Actor.sample(self: Actor, key: string, t: number): CFrame
		local from = self.from[key] or ID
		if t <= 0 then
			return from
		end
		local segs = self.segs
		if not segs then
			return from
		end
		local i = self.cursor[key] or 1
		local s: Seg? = segs[i]
		while s and t >= s.start + s.time do
			i += 1
			s = segs[i]
		end
		self.cursor[key] = i
		if not s then
			local last = segs[#segs]
			return if last then (last.pose[key] or from) else from
		end
		local prev: CFrame = from
		if i > 1 then
			prev = segs[i - 1].pose[key] or ID
		end
		return prev:Lerp(s.pose[key] or ID, s.ease((t - s.start) / s.time))
	end

	function Actor.goalFor(self: Actor, key: string): CFrame
		if self.segs == nil then
			return self.rest[key] or ID
		end
		return self:sample(key, self.t - (self.delay[key] or 0))
	end

	-- spring speed scale of the segment that is playing now
	function Actor.speedScale(self: Actor): number
		local fs = 1
		local segs = self.segs
		if not segs then
			return fs
		end
		for _, s in segs do
			fs = s.fs
			if self.t < s.start + s.time then
				return fs
			end
		end
		return fs
	end

	-- start a new timeline from the CURRENT goal pose (so a swing that is cut short blends instead of snapping)
	function Actor.setSegments(self: Actor, segs: { Segment }, events: { SwingEvent }?)
		local from: Pose = {}
		for _, key in KEYS do
			from[key] = self:goalFor(key)
		end
		local start = 0
		local list: { Seg } = {} -- a normalised copy: the caller's tables are left alone
		for _, s in segs do
			local time = math.max(s.time, MIN_SEG_TIME)
			table.insert(list, { pose = s.pose or EMPTY, time = time, ease = s.ease or Ease.linear, fs = s.fs or 1, start = start })
			start += time
		end
		self.from = from
		self.segs = list
		self.cursor = {}
		self.t = 0
		self.total = start
		self.events = events or {}
		self.evIdx = 1
	end

	-- rotation spring on the axis*angle error, never on Euler angles
	local function springRot(st: JointState, goal: CFrame, f: number, zeta: number, h: number)
		local w: number = 2 * math.pi * f
		local cur: CFrame = st.rot
		local axis: Vector3, angle: number = (goal * cur:Inverse()):ToAxisAngle()
		if angle > math.pi then
			angle -= 2 * math.pi
		end
		local e = axis * angle
		if e.X ~= e.X or e.Y ~= e.Y or e.Z ~= e.Z or math.abs(angle) < 1e-6 then
			e = Vector3.zero -- NaN or no error
		end
		st.wv += (w * w * e - 2 * zeta * w * st.wv) * h
		local d = st.wv * h
		local m = d.Magnitude
		if m > 1e-7 then
			st.rot = CFrame.fromAxisAngle(d / m, m) * cur
		end
	end

	-- advance time, fire due events, move every joint spring toward its goal
	function Actor.step(self: Actor, dt: number, now: number)
		local sdt: number = dt * (if now < frozenUntil then CONFIG.HitStopScale else 1)
		local fs = 1
		if self.segs then
			self.t += sdt
			local evs = self.events
			local idx = self.evIdx -- a cursor instead of table.remove (a cancelled swing drops its pending events on purpose)
			local ev = evs[idx]
			while ev and self.t >= ev.t do
				idx += 1
				if ev.fn then task.spawn(ev.fn) end
				ev = evs[idx]
			end
			self.evIdx = idx
			fs = self:speedScale()
		end
		local idle = self:isIdle()
		local steps: number = math.clamp(math.ceil(sdt * SPRING_HZ), 1, if self.isLocal then MAX_SUBSTEPS_LOCAL else MAX_SUBSTEPS_VICTIM)
		local h = sdt / steps
		local isLocal = self.isLocal
		local state = self.state
		local guard = self.guard
		if guard and (idle or self.oneHand) then guard = nil end -- the left hand only grips during a two-hand swing
		if guard then
			-- follow the right hand; if the hand fell more than 0.25 stud behind (a fast swing), solve again from scratch
			if self:solveLeftHand({ 4, 1, 0.25 }, 2) > 0.25 then
				self:solveLeftHand({ 16, 8, 4, 2, 1, 0.5 }, 2)
			end
		end
		-- LOCOMOTION while holding the sword (walk / run). Only the upper body is added here (the legs belong to the walk animation).
		-- walk: the torso leans a little into the move and twists against the stride, the free arm swings opposite the legs, the body bobs
		-- run: more lean, a bigger swing, the sword arm pumps a little (it still holds the blade)
		-- FATIGUE (law 108): after the finisher the breathing is deeper and faster for about 3 seconds, then settles (the phase is summed, so a changing rate never jumps)
		local tk = math.clamp((self.tiredUntil - now) / 3, 0, 1)
		self.breath += dt * (1.6 + 1.6 * tk)
		local lw, lphase, lspeed = 0, 0, 0
		if isLocal then
			local hrp = self.model:FindFirstChild("HumanoidRootPart")
			local vel: Vector3 = if hrp and hrp:IsA("BasePart") then hrp.AssemblyLinearVelocity else Vector3.zero
			local rawSpeed = math.sqrt(vel.X * vel.X + vel.Z * vel.Z)
			-- smoothed speed: the raw physics speed jitters from frame to frame, which made the stride stutter and the arms stop
			local spdBefore = self.locoSpd
			self.locoSpd += (rawSpeed - self.locoSpd) * math.min(dt * 7, 1)
			-- laws 111/1 (acceleration lean): a body that speeds up leans forward, one that brakes leans back; angle = atan(a / g), g = 196 studs/s^2
			local accel = (self.locoSpd - spdBefore) / math.max(dt, 1e-3)
			self.locoAcc += (math.clamp(math.deg(math.atan(accel / 196)), -6, 6) - self.locoAcc) * math.min(dt * 5, 1)
			lspeed = self.locoSpd
			local hm = self.hum
			local offFloor = hm ~= nil and hm.FloorMaterial == Enum.Material.Air and hm.Health > 0
			-- in the air only after 0.1 s without floor (a bump or a ramp edge is not a jump)
			self.airT = if offFloor then self.airT + dt else 0
			local air = self.airT > 0.1 or (offFloor and vel.Y > 10) or (offFloor and vel.Y < -14)
			local wantW = if air or self.fin then 0 else math.clamp(lspeed / 14, 0, 1) -- in the air the gait fades out and the normal pose takes over
			self.locoW += (wantW - self.locoW) * math.min(dt * 6, 1) -- the gait fades in and out slowly: no sudden change of posture
			-- PHYSICS 3, leaning into a turn: centripetal acceleration a = v * omega, lean angle = atan(a / g)  (g = 196 studs/s^2)
			local turnRate = if hrp and hrp:IsA("BasePart") then hrp.AssemblyAngularVelocity.Y else 0
			local leanTarget = math.deg(math.atan(lspeed * turnRate / 196))
			self.locoTurn += (math.clamp(leanTarget, -9, 9) - self.locoTurn) * math.min(dt * 6, 1)
			-- law 110 (the eyes lead the turn): the head turns into the curve before the body follows, up to 16 degrees
			self.locoGaze += (math.clamp(math.deg(turnRate) * 0.12, -16, 16) - self.locoGaze) * math.min(dt * 8, 1)
			self.locoPhase += dt * 6.2832 * (0.62 + 0.04 * lspeed) -- cadence: a heavy, steady walk (about 1.2 stride cycles per second), about 1.5 at a sprint
			lw, lphase = self.locoW, self.locoPhase
			self.model:SetAttribute("DarkGaitPhase", self.locoPhase) -- the camera bob follows the same stride
			self.model:SetAttribute("DarkGaitW", lw)
			self.model:SetAttribute("DarkGaitRun", math.clamp((lspeed - 9) / 9, 0, 1))
		end
		for key, st in state do
			local goal: CFrame = self:goalFor(key)
			local fast = false -- locomotion: stiff springs, so every joint follows the gait with the same tiny lag (arms and legs stay in step)
			if isLocal then
				-- drag: trail behind the limb above (heavy blade, loose wrist)
				local src = DRAG[key]
				if src then
					local v: Vector3 = Vector3.zero
					for _, d in src do
						local p = state[d.src]
						if p then
							v += p.wv * d.secs
						end
					end
					local m = v.Magnitude
					if m > 1e-4 then
						goal = CFrame.fromAxisAngle(-v / m, math.min(m, LAG_MAX)) * goal
					end
				end
				if (idle or LEG[key]) and lw > 0.02 then
					local run = math.clamp((lspeed - 9) / 9, 0, 1) -- 0 = walking (<= 9), 1 = running (>= 18; the default 16 is already a run)
					local s1 = math.sin(lphase)
					local c1 = math.cos(lphase)
					local s2 = math.sin(lphase - 0.4) -- the arms follow the legs a beat late (a swing travels up the body), which looks more natural than exact sync
					fast = true
					local ps = CONFIG.PitchSign
					local speedK = math.clamp(lspeed / 14, 0.85, 1.25) -- PHYSICS 1: the arm swing cancels the leg swing, so it grows with the stride
					local A = (24 + 22 * run) * speedK -- MODERN JOG / RUN: a long drive of the legs (about 45 degrees of hip swing when running), calm and planted when walking -- hip swing (degrees)
					local legGoal: CFrame? = nil
					local fwdL = math.max(c1, 0) -- the left leg is swinging forward
					local fwdR = math.max(-c1, 0)
					-- GAIT: hips swing opposite each other; the knee of the swinging leg folds (more when running); the foot follows
					if key == "lh" then
						legGoal = ang(A * s1, 0, 5) -- the feet stay a little apart: a wide, steady stance
					elseif key == "rh" then
						legGoal = ang(-A * s1, 0, -5)
					elseif key == "lk" then
						legGoal = ang(-(9 + 4 * run + (12 + 54 * run) * fwdL + (6 + 10 * run) * fwdR), 0, 0) -- the swinging leg folds high under the body (a strong knee lift when running)
					elseif key == "rk" then
						legGoal = ang(-(9 + 4 * run + (12 + 54 * run) * fwdR + (6 + 10 * run) * fwdL), 0, 0)
					elseif key == "la" then
						legGoal = ang(-A * s1 * 0.15, 0, 0)
					elseif key == "ra" then
						legGoal = ang(A * s1 * 0.15, 0, 0)
					end
					if legGoal then
						goal = goal:Lerp(legGoal, lw) -- the gait pose fades in with the walking weight
					elseif key == "r" then -- lean into the move (forward more when running), twist against the stride
						-- WEIGHT: at every footfall (both legs far apart, s1 near +-1) the pelvis nods forward a little, like a heavy body landing on each step; the body
						-- also twists less and reacts less to speed changes, so the walk stays clean
						goal = goal * bd((-(3 + 9 * run) - (1.2 + 1.4 * run) * s1 * s1 - self.locoAcc * 0.6) * lw, s1 * (2 + 7 * run) * lw, self.locoTurn * lw) -- the pelvis twists against the stride (more when running)
					elseif key == "w" then
						goal = goal * bd((-(2 + 6 * run) - self.locoAcc * 0.3) * lw, -s1 * (1.5 + 5 * run) * lw, 0) -- the chest twists the other way: the shoulders counter-rotate against the hips
					elseif key == "n" then -- the head stays level and looks ahead
						goal = goal * bd((3 + 11 * run + (0.9 + 1.1 * run) * s1 * s1) * lw, self.locoGaze * lw, 0) -- the head stays level against the nod
					elseif key == "ls" then -- the free arm swings against the legs, bent and pumping when running
						goal = goal * sw((-s2 * (14 + 30 * run) * speedK - 4 - 18 * run) * lw, 0, 2 * run * lw) -- the free arm drives against the legs, bent, like a runner
					elseif key == "le" then
						goal = goal * el((25 + 55 * run) * lw)
					elseif key == "rs" then -- the sword arm holds the blade but follows the stride a little
						goal = goal * sw((s2 * (12 + 24 * run) * speedK - 3 - 14 * run) * lw, 0, 0)
					elseif key == "re" then
						goal = goal * el((25 + 55 * run) * lw)
					elseif key == "rw" then -- the heavy blade bobs and lags on the wrist
						goal = goal * wr((math.sin(lphase * 2 - 0.8) * (4 + 5 * run) - 2 * run) * lw, 0, math.sin(lphase - 0.4) * 3 * lw)
					end
				elseif idle then
					-- standing still: tiny, slow, uneven movements so the pose is never frozen
					if key == "w" then
						-- breathing
						goal = goal * ang(math.sin(self.breath) * (1.0 + 3.2 * tk), 0, 0)
					elseif key == "n" then
						-- the eyes keep looking at the target
						goal = goal * ang(math.noise(now * 0.5, 4) * 0.8, math.noise(now * 0.4, 5) * 1.2, 0)
					elseif key == "rs" or key == "ls" then
						-- the shoulders rise with the breath
						goal = goal * ang(math.sin(self.breath + 0.6) * (0.6 + 2.4 * tk), 0, 0)
					end
				end
			end
			local prm = self.params[key]
			local freq: number = prm[1] * fs
			if self.fin and LEG[key] then freq = math.min(20, 0.17 / h) end -- the legs of the spinning kick must keep up with 0.1 s poses (the normal leg springs are far too slow for them)
				if fast then freq = math.min(22, 0.17 / h) end -- never stiffer than the sub-step can integrate (omega * h must stay small, or the joint blows up at low fps)
			if guard and (key == "ls" or key == "le" or key == "lw") then
				-- the left arm is held on the grip: the solved angles are the goal, and the arm follows quickly
				local v = guard.v
				if key == "ls" then
					goal = sw(v[1], v[2], v[4])
				elseif key == "le" then
					goal = el(v[3])
				else
					goal = ID
				end
				freq *= 1.8
			end
			if fast and goal.X == goal.X and goal.Y == goal.Y and goal.Z == goal.Z then
				local lim = JOINT_LIMIT[key]
				if lim then -- law 107: keep the knee and the elbow inside their real range
					local lo, hi = lim[1], lim[2]
					if (key == "le" or key == "re") and CONFIG.ElbowSign < 0 then lo, hi = -hi, -lo end
					local ex, ey, ez = goal:ToEulerAnglesXYZ()
					local dx = math.deg(ex)
					local cx = math.clamp(dx, lo, hi)
					if cx ~= dx then goal = CFrame.Angles(rad(cx), ey, ez) end
				end
				-- locomotion: the gait pose is written directly (no spring), so it can never overshoot, ring or blow up
				st.rot = st.rot:Lerp(goal.Rotation, math.min(dt * 14, 1)) -- (smooth and a little heavy: the joints take about 1/14 s to follow the gait pose; it used to be 1/28 s)
				st.wv = Vector3.zero
			else
				for _ = 1, steps do
					springRot(st, goal, freq, prm[2], h)
				end
			end
			if fast then -- safety: a runaway joint (low frame rate, NaN) is reined in
				local m = st.wv.Magnitude
				if m ~= m or m > 25 then st.wv = if m ~= m then Vector3.zero else st.wv * (25 / m) end
				if st.rot ~= st.rot then st.rot = ID end
			end
		end
	end

	-- how one joint is written: "multiply" (on top of the animator), "set" (the pose is the whole Transform) or "attachment"
	local function driveOf(a: Actor, key: string): string
		if a.isLocal and (not LEG[key] or a.locoW > 0.02 or a.fin) then
			return "set" -- the pose is the whole Transform: your torso, arms and head always, the legs while the sword-carry gait runs
		end
		return "multiply" -- on top of the animator (victims, and your legs while you stand still)
	end

	local TREMOR_SEED: { [string]: number } = { w = 1.5, n = 2.5, rs = 3.5, ls = 4.5 } -- victims: noise seed per joint

	-- the shown pose = the spring state plus the little extra shakes, written to the joints
	function Actor.write(self: Actor, now: number)
		local isLocal = self.isLocal
		if isLocal then
			local hrp = self.model:FindFirstChild("HumanoidRootPart")
			local v: Vector3 = Vector3.zero
			if hrp and hrp:IsA("BasePart") then
				v = hrp.AssemblyLinearVelocity
			end
			local speed = math.sqrt(v.X * v.X + v.Z * v.Z) -- flat speed, no Vector3 allocated
			local target = math.clamp(1 - speed / LEG_STILL_SPEED, 0, 1)
			-- eased, so it never pops
			self.legW += (target - self.legW) * LEG_BLEND
		end
		local frozen = now < frozenUntil
		local tremor = (not isLocal) and now < self.tremorUntil
		local strain = self.strain
		local strainFrom, strainTo = 0, 0
		local straining = false
		if isLocal and strain and self.segs then
			strainFrom, strainTo = strain[1], strain[2]
			straining = self.t >= strainFrom and self.t < strainTo + 0.04
		end
		for key, j in self.joints do
			if j.Parent then
				local off: CFrame = self.state[key].rot
				if frozen and isLocal then
					if key == "w" then
						-- tremor while stuck in the target
						off *= ang(math.sin(now * 90) * 1.5, 0, 0)
					elseif key == "rs" or key == "re" then
						-- the arm strains against the target
						off *= ang(math.noise(now * 70, 7) * 3, math.noise(now * 70, 8) * 2, 0)
					end
				end
				if straining and (key == "rs" or key == "re" or key == "w") then
					-- effort: a fine shake that grows toward the end of the windup, like holding a heavy blade at full pull
					local k = math.clamp((self.t - strainFrom) / math.max(strainTo - strainFrom, 0.01), 0, 1)
					local n = now * 34
					off *= ang(math.noise(n, 11) * 1.6 * k, math.noise(n, 12) * 1.2 * k, 0)
				end
				if tremor and TREMOR_SEED[key] then
					local t = now * 55
					local sd = TREMOR_SEED[key]
					off *= ang(math.noise(t, sd) * 2.5, math.noise(t, sd + 10) * 2.5, math.noise(t, sd + 20) * 2)
				end
				if isLocal and LEG[key] and self.locoW <= 0.02 and not self.fin then
					-- walking owns the legs: the leg offset fades out as you move, so it never fights the walk
					off = ID:Lerp(off, self.legW)
				end
				off = self.c0i[key] * off * self.c0[key]
				local mode = driveOf(self, key)
				if mode == "multiply" then
					local cur = j.Transform
					local prevW = self.written[key]
					local base = cur
					if prevW and sameRot(cur, prevW) then
						base = self.under[key] -- the animator did not write this frame: do not stack on our own output
					end
					self.under[key] = base
					local new = base * off
					self.written[key] = new
					j.Transform = new
				elseif mode == "set" then
					j.Transform = off
				end
			end
		end
	end

	-- give the joints back to the animator
	function Actor.restore(self: Actor)
		for key, j in self.joints do
			if j.Parent then
				local mode = driveOf(self, key)
				if mode == "set" then
					j.Transform = ID
				else
					local w = self.written[key]
					if w and sameRot(j.Transform, w) then
						j.Transform = self.under[key] or ID
					end
				end
			end
		end
	end

	-- the equipped tool's own animation would fight the rig, so it is stopped
	function Actor.stopToolAnimations(self: Actor)
		if not self.animator then return end
		for _, tr in self.animator:GetPlayingAnimationTracks() do
			if string.find(string.lower(tr.Name), "tool", 1, true) then
				tr:Stop(0)
			end
		end
	end

	-- THE LEFT HAND ON THE GRIP. The left fist is put on the sword every frame from the SAME numbers that draw the right arm: the right
	-- hand's frame comes from the right arm's spring state (forward kinematics with the rig's own C0 / C1), the left fist target is a point on
	-- the Handle behind / above where the right hand holds it, and the left shoulder / elbow angles are solved (a few coordinate-descent
	-- steps from last frame's answer) to put the left hand there. Nothing depends on the engine's physics step or on Roblox's IK, so
	-- the hand cannot buzz. The left arm springs then smooth the answer. Returns false (and changes nothing) if the sword or rig does not allow it.
	function Actor.prepareGuard(self: Actor): boolean
		if not self.isLocal or self.guard then return false end
		local joints = self.joints
		local model = self.model
		local tool = model:FindFirstChildOfClass("Tool")
		local handle = if tool then tool:FindFirstChild("Handle") else nil
		local rightHand = model:FindFirstChild("RightHand")
		if not (handle and handle:IsA("BasePart") and rightHand) then return false end
		local weld = rightHand:FindFirstChild("RightGrip")
		if not (weld and weld:IsA("JointInstance")) then return false end
		local A: { [string]: CFrame } = {}
		local B: { [string]: CFrame } = {}
		for _, key in { "rs", "re", "rw", "ls", "le", "lw" } do
			local j = joints[key]
			if not (j and j.ClassName == "Motor6D") then return false end
			local m = j :: Motor6D
			local c0r = m.C0.Rotation
			A[key] = m.C0 * c0r:Inverse()
			B[key] = c0r * m.C1:Inverse()
		end
		-- where the right hand holds the handle (weld.C1, in the handle's space); the handle's longest side is the blade axis
		local grip = weld.C1.Position
		local size = handle.Size
		local axis = Vector3.zAxis
		local half = size.Z / 2
		local along = grip.Z
		if size.X >= size.Y and size.X >= size.Z then
			axis, half, along = Vector3.xAxis, size.X / 2, grip.X
		elseif size.Y >= size.X and size.Y >= size.Z then
			axis, half, along = Vector3.yAxis, size.Y / 2, grip.Y
		end
		if half * 2 < 2.5 then return false end -- not a long handle: the grip point cannot be told apart
		-- the pommel is the SHORTER side of the handle seen from the right hand (the blade is the longer one). The second hand goes
		-- toward the pommel when there is room for a fist there (0.9 stud); when the right hand already holds the very end of the
		-- handle, it goes the other way, right above the right hand
		local plusRoom, minusRoom = half - along, half + along
		local pommelIsPlus = plusRoom < minusRoom
		local room = math.min(plusRoom, minusRoom)
		local offset: Vector3
		if room >= 0.9 then
			offset = (if pommelIsPlus then axis else -axis) * math.clamp(room - 0.25, 0.3, 0.95)
		else
			offset = (if pommelIsPlus then -axis else axis) * 0.85
		end
		-- handle space -> the right hand's space: the handle sits at hand * C0 * C1^-1
		local handFromHandle = weld.C0 * weld.C1:Inverse()
		local leftElbow = joints.le :: Motor6D
		self.guard = {
			A = A, B = B,
			gripInHand = handFromHandle:PointToWorldSpace(grip + offset),
			elbowAt = leftElbow.C0.Position,
			pole = Vector3.new(-1.9, -0.9, -0.2), -- the elbow likes to hang out to the left and down (torso frame)
			v = { 30, -40, 40, 0 }, -- left shoulder pitch / yaw / roll and the elbow bend, in degrees
		}
		self:solveLeftHand({ 16, 8, 4, 2, 1, 0.5 }, 3)
		return true
	end

	-- one pass of coordinate descent on the left arm (v = pitch, yaw, elbow, roll); steps in degrees, from last frame's answer
	function Actor.solveLeftHand(self: Actor, steps: { number }, sweeps: number): number
		local g = self.guard
		if not g then return 0 end
		local state = self.state
		local A, B = g.A, g.B
		-- the right hand in the torso frame, from the right arm's spring state
		local right = (A.rs * state.rs.rot * B.rs) * (A.re * state.re.rot * B.re) * (A.rw * state.rw.rot * B.rw)
		local target = right:PointToWorldSpace(g.gripInHand)
		local wristLink = A.lw * B.lw
		local v = g.v
		local lo = { 0, -110, 0, -60 }
		local hi = { 150, 80, 140, 60 }
		-- distance of the left hand from the grip target; `withPole` adds a weak pull of the elbow toward the pole point
		local function miss(x: { number }, withPole: boolean): number
			local shoulder = A.ls * sw(x[1], x[2], x[4]) * B.ls
			local hand = shoulder * (A.le * el(x[3]) * B.le) * wristLink
			local d = hand.Position - target
			local total = d:Dot(d)
			if withPole then
				local e = shoulder:PointToWorldSpace(g.elbowAt) - g.pole
				total += 0.008 * e:Dot(e)
			end
			return total
		end
		local function cost(x: { number }): number
			return miss(x, true)
		end
		local best = cost(v)
		for _, step in steps do
			for _ = 1, sweeps do
				for i = 1, 4 do
					for _, dir in { 1, -1 } do
						local old = v[i]
						v[i] = math.clamp(old + dir * step, lo[i], hi[i])
						local c = cost(v)
						if c < best then
							best = c
						else
							v[i] = old
						end
					end
				end
			end
		end
		return math.sqrt(miss(v, false)) -- studs between the left hand and the grip
	end

	function Actor.retire(self: Actor)
		self.dead = true
		self:restore()
		actors[self.model] = nil
	end
	Actor.Destroy = Actor.retire -- the usual name for "I am done with this object"

	-- false once the actor is gone (retired / died) or being released: it takes no new timeline
	function Actor.isUsable(self: Actor): boolean
		return not self.dying and not self.dead
	end

	-- the biggest angle (radians) between the shown pose and the rest pose
	function Actor.restError(self: Actor): number
		local worst = 0
		for key, st in self.state do
			local _, angle = (self.rest[key].Rotation * st.rot:Inverse()):ToAxisAngle()
			if angle > math.pi then angle -= 2 * math.pi end
			if angle == angle then
				worst = math.max(worst, math.abs(angle))
			end
		end
		return worst
	end

	-- add angular velocity to a joint (the springs then overshoot and settle by themselves)
	function Actor.kick(self: Actor, key: string, axis: Vector3, radPerSec: number)
		if key == "w" and not self.state.w then key = "r" end -- R6 has no waist
		local st = self.state[key]
		if st and axis.Magnitude > 1e-3 then
			st.wv += axis.Unit * radPerSec
		end
	end

	-- one frame: step, housekeeping, write
	function Actor.update(self: Actor, dt: number, now: number)
		if not self.model.Parent then
			actors[self.model] = nil
			return
		end
		if (not self.isLocal) and self.hum and self.hum.Health <= 0 then
			self:retire()
			return
		end
		self:step(dt, now)
		if self.isLocal then
			self.toolTimer += dt
			if self.toolTimer > TOOL_CHECK_EVERY then
				self.toolTimer = 0
				if not self.dying then self:stopToolAnimations() end
			end
			if self.dying then
				if self.t >= self.total + DYING_EXTRA then
					self:retire()
					return
				end
			elseif self:isIdle() then
				self.fin = false
				-- watchdog: if the pose is still off after the timeline ended, glide back to ready
				self.idleFor += dt
				if self.idleFor > WATCHDOG_EVERY then
					self.idleFor = 0
					if self.locoW <= 0.02 and self:restError() > WATCHDOG_ANGLE then -- not while the gait is playing
						self:setSegments({ { pose = self.rest, time = 0.25, ease = Ease.inOutQuad, fs = 0.7 } })
					end
				end
			else
				self.idleFor = 0
			end
		elseif self.segs and self.t >= self.total + VICTIM_LINGER then
			self:retire()
			return
		end
		local animator = self.animator
		if not (animator and animator.EvaluationThrottled) then
			self:write(now)
		end
	end

	-- ONE PreSimulation connection for everything; it only exists while something needs it.
	local loopConn: RBXScriptConnection? = nil
	local function onStep(dt: number): ()
		dt = math.min(dt, DT_CAP)
		local now: number = os.clock() -- once per frame, not once per joint
		if turnHook then
			local ok, err = pcall(turnHook :: (number) -> (), dt) -- a broken hook is dropped, it must not stop every actor
			if not ok then
				warn("[DarkSword] turn hook error:", err)
				turnHook = nil
			end
		end
		for model, a in actors do
			-- one broken actor must never freeze the others (that left your arm stuck before)
			local ok, err = pcall(a.update, a, dt, now)
			if ok then
				a.errors = 0
			else
				a.errors += 1
				if not a.warned then
					a.warned = true
					warn("[DarkSword] actor error:", err)
				end
				if not a.isLocal then
					actors[model] = nil
				elseif a.errors >= MAX_ACTOR_ERRORS then
					pcall(a.retire, a) -- release the joints instead of leaving the arm stuck
				end
			end
		end
		if loopConn and next(actors) == nil and turnHook == nil then
			loopConn:Disconnect()
			loopConn = nil
		end
	end

	local function startLoop(): ()
		if not loopConn then
			loopConn = RunService.PreSimulation:Connect(onStep)
		end
	end

	local function register(a: Actor): ()
		actors[a.model] = a
		startLoop()
	end

	function Rig.equip(character: Model): Actor?
		if typeof(character) ~= "Instance" or not character.Parent then return nil end
		local old = actors[character]
		if old then old:retire() end -- a previous actor was still gliding out
		local a = Actor.new(character, true)
		if not a then
			warn("[DarkSword] R15 joints not found on", character.Name)
			return nil
		end
		a:stopToolAnimations()
		-- the left hand goes onto the grip; the tool's grip weld may not exist yet on the very first frame, so it is tried a few times
		-- (a failure only means the left arm stays on the poses)
		local ok, held = pcall(a.prepareGuard, a)
		if not (ok and held) then
			task.spawn(function()
				for _ = 1, 8 do
					task.wait(0.1)
					if a.dead or a.dying then return end
					local ok2, held2 = pcall(a.prepareGuard, a)
					if ok2 and held2 then return end
				end
			end)
		end
		register(a)
		return a
	end


	-- LEGS (only used while standing still, see Actor:write): a loaded crouch in the windup, then the front foot steps and the back leg pushes.
	-- Small angles on purpose: the root height is fixed, so a deep knee bend would lift the feet off the floor.
	-- (the SIGN of the hip angle is from the victim rig code: if a leg bends the wrong way, flip the sign of the first number)
	local function legs(pose: Pose, lh: number, lk: number, rh: number, rk: number, spread: number?, turn: number?)
		local open = spread or 0 -- degrees the feet are opened sideways (a wider, steadier stance)
		local toward = turn or 0 -- degrees the front hip is turned toward the target
		-- a positive z turns a leg toward the middle, so the feet open with the opposite signs
		pose.lh, pose.lk = ang(lh, toward, -open), ang(lk, 0, 0)
		pose.rh, pose.rk = ang(rh, -toward, open), ang(rk, 0, 0)
	end
	-- the ready stance has a stance too (shown only while you stand still): left foot a little forward, weight on the back leg, feet apart
	legs(READY, 8, -12, -4, -10, 13, 6, 3)
	legs(FINISH, 14, -20, -4, -14, 18, 10) -- the weight is coming back up between the lunge and the ready stance
	legs(SETTLE, 15, -22, -5, -16, 20, 11)
	for i, step in COMBO do
		local lists = { step }
		if step.variants then for _, v in step.variants do table.insert(lists, v) end end
		for _, st in lists do
			if i == 3 then
				if st.anticipate then legs(st.anticipate, 16, -32, 15, -30, 6) end -- sink: knees bend
				if st.spring then legs(st.spring, 30, -44, 14, -38, 10, 4) end
				if st.windup then legs(st.windup, 28, -52, 22, -46, 10) end -- deep, wide, low stance: the weight is gathered
				if st.roll then legs(st.roll, 70, -100, 70, -100, 0) end -- tucked
				if st.rollEnd then legs(st.rollEnd, 28, -36, 12, -22, 6, 4) end
				if st.grip then legs(st.grip, 16, -22, 2, -18, 10, 8) end
				if st.lift then legs(st.lift, 18, -34, -4, -26, 11, 8) end -- the weight sinks onto the back (right) leg, the left foot in front
				if st.pullUp then legs(st.pullUp, 14, -10, 4, -8, 13, 8) end -- up on a firm base for the last breath
				if st.raise then legs(st.raise, 20, -22, 6, -20, 12, 8) end -- a wide, planted stance: front leg long, back leg a little bent
				if st.top then legs(st.top, 16, -12, 2, -8, 13, 8) end -- up on a firm base, both legs nearly straight
				if st.slamMid then legs(st.slamMid, 22, -24, 6, -20, 11, 6) end
				if st.slam then legs(st.slam, 26, -30, 8, -26, 11, 6) end -- front foot stamps
				if st.slamHold then legs(st.slamHold, 28, -34, 8, -28, 11, 6) end
				if st.release then legs(st.release, 22, -26, 10, -28, 10, 8) end
			else
				local front = i == 1 and 1 or -1 -- hit 1 steps with the left leg, hit 2 with the right
				local function lr(f: { number }, b: { number }): (number, number, number, number) -- (left hip, left knee, right hip, right knee) from front / back values
					if front == 1 then return f[1], f[2], b[1], b[2] end
					return b[1], b[2], f[1], f[2]
				end
				if st.anticipate then legs(st.anticipate, lr({ 3, -7 }, { 3, -7 })) end
				if st.windup then legs(st.windup, lr({ 5, -13 }, { 8, -18 })) end
				-- hit 1 plants the front foot harder (deeper knee bend, the back leg drives): the weight of the cut lands on the floor
				local heavy = i == 1
				if st.strike then legs(st.strike, lr(heavy and { 22, -18 } or { 16, -10 }, heavy and { -10, -26 } or { -8, -20 })) end
				if st.follow then legs(st.follow, lr(heavy and { 19, -14 } or { 13, -8 }, heavy and { -8, -22 } or { -5, -15 })) end
				-- hit 2 is a SPRING: it starts from a deep crouch (the windup above) and the legs push straight up through the cut,
				-- so at the strike both legs are almost straight and the back foot comes off the floor
				if i == 2 then
					if st.windup then legs(st.windup, lr({ 12, -30 }, { 14, -34 })) end
					if st.strike then legs(st.strike, lr({ 4, -3 }, { -14, -8 })) end
					if st.follow then legs(st.follow, lr({ 2, -2 }, { -18, -6 })) end
				end
				if st.reboundPose then legs(st.reboundPose, lr({ 10, -8 }, { -2, -12 })) end
				-- the extra arguments of legs() (spread, turn) are not set for hits 1 and 2: a wide stance is only for the finisher
			end
		end
	end

	-- BOLDER SWINGS. The amounts below make the swings travel further (the tilt of the cut is not touched, only how far the body and
	-- the limbs travel). Every pose of the three hits is scaled around "no rotation": { gain at full boldness, largest angle in degrees }.
	-- The gain is the first number where the joint can take it; the largest angle keeps a limb from folding through the body. The arms get less gain because
	-- they already travel almost their whole range. READY / SETTLE / FINISH (the carry) and the roll of hit 3 are NOT scaled.
	local BOLD: { [string]: { number } } = {
		r = { 2.2, 45 }, w = { 2.6, 110 }, n = { 2, 55 }, -- the neck follows the chest, it does not whip far on its own
		rs = { 1.35, 175 }, ls = { 1.25, 155 }, rw = { 1.8, 55 }, lw = { 1.6, 50 }, -- wrists: smaller, so the blade does not flip
		re = { 1.15, 150 }, le = { 1.15, 150 },
		lh = { 2.0, 50 }, rh = { 2.0, 50 }, lk = { 2.0, 90 }, rk = { 2.0, 90 }, -- legs: a wide step, not a split
	}
	local function embolden(pose: Pose)
		for key, spec in BOLD do
			local cf = pose[key]
			if cf and cf ~= ID then
				local axis, angle = cf:ToAxisAngle()
				local gain = spec[1]
				local a = math.min(angle * gain, rad(spec[2]))
				if a > angle then -- never turns a smaller move into a bigger one than the limit allows
					pose[key] = CFrame.fromAxisAngle(axis, a)
				end
			end
		end
	end
	do
		local seen: { [Pose]: boolean } = {}
		local function walk(step: Step)
			for name, value in step :: any do
				if name ~= "roll" and name ~= "variants" and type(value) == "table" and (value :: any).rs ~= nil then
					local pose = value :: Pose
					if not seen[pose] and pose ~= READY and pose ~= SETTLE and pose ~= FINISH then
						seen[pose] = true
						embolden(pose)
					end
				end
			end
			if step.variants then
				for _, v in step.variants do walk(v) end
			end
		end
		for _, step in COMBO do walk(step) end
	end

	local function buildSegments(step: Step): { Segment }
		local W: number = step.windupTime or 0
		local S: number = step.strikeTime or 0
		local r: number = CONFIG.AnticipateRatio
		local segs: { Segment } = {
			{ pose = step.anticipate, time = W * r, ease = Ease.inOutSine, fs = 1.6 },
			-- slows down into the top of the coil: that small stop is the anticipation the eye reads
			{ pose = step.windup, time = W * (1 - r) - (step.hold or 0), ease = Ease.curveOut, fs = 1.0 },
		}
		if step.hold then -- one full-stop frame at the top of the coil: the eye reads it as "now it comes"
			table.insert(segs, { pose = step.windup, time = step.hold, ease = Ease.linear, fs = 1.0 })
		end
		if step.mid then
			-- the strike goes THROUGH a middle key (the arc): it speeds up, then goes on at the same speed
			-- (no stop on the middle key, so the swing never looks stepped)
			table.insert(segs, { pose = step.mid, time = S * 0.5, ease = Ease.accel, fs = 1.9 })
			table.insert(segs, { pose = step.strike, time = S * 0.5, ease = Ease.impactBrake, fs = 2.2 })
		else
			table.insert(segs, { pose = step.strike, time = S, ease = Ease.outQuad, fs = 2.2 })
		end
		-- follow-through starts fast (same speed as the strike ended) and slows down
		table.insert(segs, { pose = step.follow, time = step.followTime or 0.1, ease = Ease.curveOut, fs = 1.6 }) -- a sharp exit after contact: the contrast sells the weight
		if step.reboundPose then
			table.insert(segs, { pose = step.reboundPose, time = step.rebound or 0.07, ease = Ease.inOutSine, fs = 0.9 })
		end
		-- finish: let the weight come back (about 0.2 s), then settle into the ready stance
		table.insert(segs, { pose = FINISH, time = 0.26, ease = Ease.inOutSine, fs = 1.05 }) -- closing move: the blade arcs back up toward the shoulder
		table.insert(segs, { pose = SETTLE, time = CONFIG.SettleTime or 0.2, ease = Ease.inOutSine, fs = 0.7 })
		table.insert(segs, { pose = READY, time = CONFIG.RecoverTime, ease = Ease.inOutSine, fs = 0.6 })
		return segs
	end

	-- glide back to the neutral pose first, then let go of the joints (no snapping)
	function Actor.unequip(self: Actor)
		if not self:isUsable() then return end
		self.dying = true
		self.rest = EMPTY
		frozenUntil = 0
		self.guard = nil -- the left arm goes back to the poses for the release
		self:setSegments({ { pose = EMPTY, time = 0.18, ease = Ease.inOutQuad, fs = 0.8 } })
	end

	-- step = a COMBO entry, or one of its variants (see Anim.stepFor)
	function Actor.playSwing(self: Actor, step: Step, onStrike: (() -> ())?)
		if not self:isUsable() or type(step) ~= "table" then return end -- being released, or no step given: ignore
		local windup: number = step.windupTime or 0
		self.oneHand = step.oneHand == true -- hit 2 and its variants hold the sword in one hand
		self:setSegments(buildSegments(step), { { t = windup, fn = onStrike } })
		self.strain = { windup * CONFIG.AnticipateRatio, windup } -- the held top of the coil: the arm trembles with effort here
	end

	-- DRAW from the back (played when the sword is taken out): the right hand reaches back over the shoulder and takes the grip (the body turns a little
-- away), the blade is pulled forward in one clean arc, sweeps across the body in a short flourish, and settles in the ready stance. The sword in the
-- hand is hidden by the Client during the first part, while the copy on the back is still there, so it looks as if it comes off the back.
	function Actor.playDraw(self: Actor)
		if not self:isUsable() then return end
		self.oneHand = false
		local reach: Pose = P({ rs = sw(165, -30, cross(8)), re = el(48), rw = wr(-14, 0, 0), ls = sw(10, 14, 0), le = el(22), w = bd(6, -30, 0), r = bd(2, -20, 0), n = bd(-4, 14, 0) })
		local pull: Pose = P({ rs = sw(116, -10, 0), re = el(22), rw = wr(-8, 0, 10), ls = sw(30, -30, 0), le = el(36), w = bd(-10, 16, 0), r = bd(-3, 10, 0), n = bd(3, -8, 0) })
		local sweepPose: Pose = P({ rs = sw(64, 12, 0), re = el(30), rw = wr(-6, 0, 8), ls = sw(24, -40, 0), le = el(40), w = bd(-16, 34, 0), r = bd(-6, 22, 0), n = bd(5, -22, 0) })
		self:setSegments({
			{ pose = reach, time = 0.22, ease = Ease.outQuad, fs = 1.6 }, -- the hand goes back over the shoulder
			{ pose = reach, time = 0.05, ease = Ease.linear, fs = 1.0 }, -- the grip
			{ pose = pull, time = 0.14, ease = Ease.accel, fs = 2.4 }, -- the blade is pulled forward, fastest at the end
			{ pose = sweepPose, time = 0.18, ease = Ease.outCubic, fs = 1.4 }, -- the flourish across the body
			{ pose = SETTLE, time = 0.2, ease = Ease.inOutSine, fs = 0.8 },
			{ pose = READY, time = 0.3, ease = Ease.inOutSine, fs = 0.6 },
		})
		self.strain = nil
	end

	function Actor.cancel(self: Actor, time: number?)
		if not self:isUsable() then return end
		frozenUntil = 0
		self:setSegments({ { pose = self.rest, time = time or 0.1, ease = Ease.outCubic, fs = 1 } })
	end

	function Actor.recover(self: Actor, time: number?)
		if not self:isUsable() then return end
		self:setSegments({ { pose = self.rest, time = time or CONFIG.RecoverTime, ease = Ease.inOutSine, fs = 0.7 } })
	end

	-- hit 3, part 1: sink, coil, then the leap. The dash lasts at most rollMax seconds.
	-- HIT 3 = a LEAPING OVERHEAD CHOP (a big jumping strike like the kendo "men" and the jump cuts of sword arts): from the deep crouch the
-- body LEAPS at the enemy (the Client launches it, see onStrike), the blade is swung far back over the shoulder with the back arched and
-- the knees tucked up, and at the top of the leap it comes down in one huge steep arc from high on the right to low on the left while the
-- legs reach out to land in a deep lunge. The lunge is held until the Server catches something (then the blade is drawn back high for
-- the finishing slash).
function Actor.playFinisher(self: Actor, step: Step, onStrike: (() -> ())?)
	if not self:isUsable() or type(step) ~= "table" then return end
	local W: number = step.windupTime or 0
	local r: number = CONFIG.AnticipateRatio
	self.oneHand = false -- the finisher is a two-hand grip
	self.fin = true -- the leap owns the legs until the finisher is over
	local LEAP_TIME: number, HANG_TIME: number, CHOP_TIME: number = 0.34, 0.16, 0.1
	-- BOLD poses: at the top the arms are stretched straight up with the blade far behind the head and the back deeply arched; the chop
	-- throws the whole body forward and down, the arms driving down to the floor in front of the feet. The chop IS the slash that throws the
	-- enemy: nothing else moves the arms afterwards (catch / slam only hold this pose), so the landing keeps the arms of the chop.
	local air: Pose = P({ rs = sw(178, -8, 0), re = el(18), rw = wr(-24, 0, 0), ls = sw(174, -2, 0), le = el(22), w = bd(44, 0, 0), r = bd(18, 0, 0), n = bd(-24, 0, 0) })
	local chop: Pose = P({ rs = sw(22, 8, 0), re = el(2), rw = wr(22, 0, 0), ls = sw(18, 4, 0), le = el(4), w = bd(-54, 0, 0), r = bd(-28, 0, 0), n = bd(28, 0, 0) })
	local land: Pose = P(table.clone(chop)) -- the same arms and body as the chop, only the legs sink into the landing
	legs(air, 66, -116, 58, -106, 16) -- both knees pulled up high under the body
	legs(chop, 60, -10, -30, -40, 20) -- the legs reach out wide for the landing
	legs(land, 44, -72, -26, -16, 20) -- deep wide lunge
	self.chopPose = chop	local segs: { Segment } = {
		{ pose = step.anticipate, time = W * r, ease = Ease.inOutSine, fs = 1.3 },
		{ pose = step.windup, time = W * (1 - r) - 2 / 30, ease = Ease.outSine, fs = 1.0 },
		{ pose = step.spring, time = 2 / 30, ease = Ease.accel, fs = 1.8 }, -- the coil is released (the last 2 frames of the crouch), then the leap
		{ pose = air, time = LEAP_TIME, ease = Ease.outQuad, fs = 1.8 }, -- take-off: the blade goes back, the knees come up
		{ pose = air, time = HANG_TIME, ease = Ease.linear, fs = 1.0 }, -- hang at the top of the leap
		{ pose = chop, time = CHOP_TIME, ease = Ease.impactBrake, fs = 2.6 }, -- the huge chop: the fastest part of the whole move
		{ pose = land, time = math.max((T[3].rollMax or 0.75) - LEAP_TIME - HANG_TIME - CHOP_TIME, 0.1), ease = Ease.outSine, fs = 1.0 }, -- the lunge goes on
	}
		table.insert(segs, { pose = step.rollEnd, time = 0.2, ease = Ease.outSine, fs = 0.8 }) -- if nothing is caught the Server sends a miss and actor:recover takes over
		self:setSegments(segs, { { t = math.max(W - 0.07, 0), fn = function() self:loadLegs() end }, { t = W, fn = onStrike } }) -- the legs load 0.07 s before the coil releases
		self.strain = { W * r, W }
	end

	-- hit 3, part 2 (something was caught): the chop already is the hit, so the arms do not move again
	function Actor.catch(self: Actor)
		if not self:isUsable() then return end -- (an enemy can be caught after you put the sword away)
		self.strain = nil
	end

	-- hit 3, part 3: the enemy is thrown by the chop. The pose of the chop stays for the hit stop, then the body comes up and settles
	function Actor.slam(self: Actor)
		self.tiredUntil = os.clock() + 3.7 -- the breath comes hard after the chop (see the idle block)
		if not self:isUsable() then return end
				-- RISING FROM THE CHOP, HEAVY AND WITH EFFORT. The body does not pop up: (1) it pushes up slowly (the spine comes up from the hips, the arms hang
		-- low and tremble, the breath is deep), (2) the arms and the blade lift, (3) the body relaxes into the ready stance.
		local rise1: Pose = P({ rs = sw(46, 8, 0), re = el(22), rw = wr(14, 0, 0), ls = sw(40, 2, 0), le = el(20), w = bd(-24, -4, 0), r = bd(-10, -2, 0), n = bd(14, 0, 0) })
		local rise2: Pose = P({ rs = sw(48, 14, 0), re = el(44), rw = wr(-4, 0, 6), ls = sw(16, 8, 0), le = el(30), w = bd(-6, -8, 0), r = bd(-2, -4, 0), n = bd(2, 4, 0) })
		legs(rise1, 34, -42, -12, -26, 12) -- the knees push
		legs(rise2, 14, -16, -6, -12, 10)
		self:setSegments({
			{ pose = self.chopPose or COMBO[3].slam, time = 0.1, ease = Ease.linear, fs = 1.0 }, -- stays down for the hit stop (short: it must not look like a bow)
			{ pose = rise1, time = 0.26, ease = Ease.outQuad, fs = 0.9 }, -- the slow push up, with effort
			{ pose = rise2, time = 0.2, ease = Ease.inOutSine, fs = 0.9 }, -- the arms and the blade lift
			{ pose = SETTLE, time = 0.22, ease = Ease.inOutSine, fs = 0.7 }, -- the body relaxes
			{ pose = READY, time = 0.3, ease = Ease.inOutSine, fs = 0.6 },
		})
		self.strain = { 0.1, 0.4 } -- the arms and the back tremble with the effort while the body pushes up (the Actor adds the shake)
		task.delay(0.05, function()
			if self.dead or not self:isUsable() then return end
			for _, key in { "lk", "rk" } do
				local st = self.state[key]
				if st then st.wv += Vector3.new(-6.5, 0, 0) end -- the landing: the knees take the load
			end
			self:shift(4)
		end)
	end

		-- the moment of contact (Client calls it right after Rig.freeze): the swing goes on in the joints that are moving (follow-through),
	-- the waist rocks back and the knees take the load. strength defaults to the length of the hit stop: a heavier hit = more of everything.
	function Actor.recoil(self: Actor, strength: number?)
		if not self:isUsable() then return end
		local k: number = strength or math.clamp((frozenUntil - os.clock()) / 0.12, 0.6, 1.8)
		local state = self.state
		for _, key in CARRY_KEYS do
			local st = state[key]
			if st then
				st.wv = st.wv * (1 + CARRY_GAIN * k)
			end
		end
		local waist = state.w
		if waist then
			waist.wv += Vector3.new(5 * CONFIG.PitchSign * math.clamp(k, 0.7, 1.4), 0, 0)
		end
		for _, key in { "lk", "rk" } do
			-- the knees give a little under the weight (only visible while standing still)
			local st = state[key]
			if st then
				st.wv += Vector3.new(-2.5 * k, 0, 0)
			end
		end
	end

	-- WEIGHT SHIFT (law 12, centre of mass): the body moves its weight before and during a swing. amount < 0 = onto the back foot
	-- (the waist leans back, the knees bend a little), amount > 0 = onto the front foot (the waist leans forward, the knees straighten).
	function Actor.shift(self: Actor, amount: number)
		if not self:isUsable() then return end
		local state = self.state
		local waist = state.w
		if waist then
			waist.wv += Vector3.new(amount * CONFIG.PitchSign, 0, 0)
		end
		for _, key in { "lk", "rk" } do
			local st = state[key]
			if st then
				st.wv += Vector3.new(-amount * 0.4, 0, 0)
			end
		end
	end

	-- STRIKE PHYSICS (animation laws, applied once at the moment of the strike). Everything here only gives the joint springs a push
	-- (an angular velocity), so the springs make the motion; nothing is set directly and nothing can get stuck.
	--  1 + 9 (balance, landing absorption): the weight goes onto the front foot, the knees dip to take the load, then straighten
	--  2 (centre-of-mass arc): the dip and the rise are the up-and-down arc of the body
	--  8 (reaction torque): the torso turns a little AGAINST the swing (equal and opposite)
	--  14 (counter arm): the free arm swings the other way to balance the sword arm
	--  11 (arm weight): a moment later the free arm sags with its own weight
	--  15 (rebound): the body overshoots backwards a little, then settles
	-- LOAD (called about 0.07 s BEFORE the strike starts, at the end of the wind-up): the knees bend and the weight sinks onto the back
	-- foot, like a spring being compressed. Research hint (boxing, kendo): the legs do their work BEFORE the contact, so the load comes first.
	function Actor.loadLegs(self: Actor)
		if not self:isUsable() then return end
		for _, key in { "lk", "rk" } do
			local st = self.state[key]
			if st then st.wv += Vector3.new(-5, 0, 0) end -- the deeper dip (it used to come at the strike itself)
		end
		self:shift(-2)
	end

	-- STRIKE PHYSICS (called when the strike STARTS). Only pushes on the joint springs (angular velocities); nothing is set directly.
	--  DRIVE (now): the push-off. The weight goes onto the front foot, the knees straighten at once (the legs finish their work in the
	--   0.1 s of the strike, so they are already relaxed at contact: ground force is highest just before the contact and near zero at it)
	--  8 (reaction torque): the torso turns against the swing. There is NO hip lead any more (the research did not support it);
	--   the arm and the blade stay the fastest part
	--  14 (counter arm): the free arm swings the other way
	--  CONTACT (+0.09 s): the free arm sags, the weight rebounds
	function Actor.strikePhysics(self: Actor, index: number)
		if not self:isUsable() then return end
		local state = self.state
		local ps = CONFIG.PitchSign
		local sgn = if index == 2 then -1 else 1
		self:shift(6.5) -- onto the front foot
		for _, key in { "lk", "rk" } do
			local st = state[key]
			if st then st.wv += Vector3.new(4.2, 0, 0) end -- the push-off: the knees straighten now, not later
		end
		self:kick("r", Vector3.yAxis, -2.8 * sgn) -- the torso whips against the cut
		local ls = state.ls
		if ls then ls.wv += Vector3.new(-3.6 * ps, 0, 0) end -- the free arm throws out the other way
		if index == 3 then return end -- the finisher goes on into the roll: no relax at 0.09 s
		task.delay(0.09, function()
			if self.dead or not self:isUsable() then return end
			local l2 = self.state.ls
			if l2 then l2.wv += Vector3.new(-1.5 * ps, 0, 0) end -- the free arm sags
			for _, key in { "lk", "rk" } do
				local st = self.state[key]
				if st then st.wv += Vector3.new(-1, 0, 0) end -- the legs give a little at the contact (force is gone)
			end
			self:shift(-3) -- rebound
		end)
	end

	-- hit stop: returns false when one is already running (no stacking)
	function Rig.freeze(duration: number): boolean
		local now: number = os.clock()
		if now < frozenUntil then return false end
		frozenUntil = now + math.max(duration, 0)
		return true
	end

	-- a swing turns the body inside the single step loop; the hook is called every step
	function Rig.setTurnHook(hook: (number) -> ())
		if type(hook) ~= "function" then return end
		turnHook = hook
		startLoop()
	end
	function Rig.clearTurnHook(hook: (number) -> ())
		if turnHook == hook then turnHook = nil end
	end



	--------------------------------------------------------------------------------
	-- Hit reactions: the victim's body animation (local, cosmetic)
	-- Short snap pose + angular-velocity impulses, so the underdamped springs give the
	-- overshoot and settle by themselves. Joints react as a chain (root, waist, arms, head).
	--------------------------------------------------------------------------------
	local HitReact = {}
	do
		local function leanCF(axis: Vector3, deg: number): CFrame
			if axis.Magnitude < 1e-3 then return ID end
			return CFrame.fromAxisAngle(axis.Unit, rad(deg))
		end

		-- keeps the declared type {Segment} on a table literal (the checker would otherwise narrow it to the literal's own type)
		local function seq(list: { Segment }): { Segment }
			return list
		end

		-- leg offsets of a reaction pose (angles in degrees)
		local function legs(hipR: number, hipL: number, knee: number, ankle: number): Pose
			return {
				rh = ang(hipR, 0, 0), lh = ang(hipL, 0, 0),
				rk = ang(-knee, 0, 0), lk = ang(-knee * 0.8, 0, 0),
				ra = ang(ankle, 0, 0), la = ang(ankle * 0.9, 0, 0),
			}
		end
		local function withLegs(pose: Pose, l: Pose): Pose
			for k, v in l do pose[k] = v end
			return pose
		end

		-- opts (from the Server): { strength = 0..1 impact strength I, chained = true when hit 2 followed a hit 1 that landed }
		function HitReact.play(model: Model, kind: string, dirWorld: Vector3?, power: number?, opts: HitOpts?)
			if typeof(model) ~= "Instance" or not model.Parent then return end
			local dir: Vector3 = if typeof(dirWorld) == "Vector3" then dirWorld else Vector3.zero
			local pw: number = tonumber(power) or 1
			if deps.player and model == deps.player.Character then return end
			local root = model:FindFirstChild("HumanoidRootPart")
			if not root or not root:IsA("BasePart") then return end
			local a: Actor
			local existing = actors[model]
			if existing then
				a = existing
			else
				local created = Actor.new(model, false)
				if not created then return end
				register(created)
				a = created
			end

			local flat: Vector3 = Vector3.new(dir.X, 0, dir.Z)
			if flat.Magnitude < 1e-3 then
				flat = -root.CFrame.LookVector
			end
			flat = flat.Unit
			local dl: Vector3 = root.CFrame:VectorToObjectSpace(flat)
			local axis: Vector3 = Vector3.yAxis:Cross(dl) -- positive lean = away from the attacker
			local sl: Vector3 = root.CFrame:VectorToObjectSpace(Vector3.yAxis:Cross(flat))
			local twistSign: number = if sl.X >= 0 then -1 else 1
			local p: number = math.clamp(pw, 0.3, 1.6) * (0.9 + math.random() * 0.2) -- no two hits identical
			local strength: number? = if type(opts) == "table" then tonumber(opts.strength) else nil
			if strength then -- the Server's impact strength decides how big the reaction is: 0.55 .. 1.5 times
				p = (0.55 + 0.95 * math.clamp(strength, 0, 1)) * (0.95 + math.random() * 0.1)
			end
			local chained: boolean = type(opts) == "table" and opts.chained == true

			local function lean(d: number): CFrame return leanCF(axis, d) end
			local function twist(d: number): CFrame return ang(0, d * twistSign, 0) end

			local segs: { Segment }
			if kind == "rise" then -- bent back, knees buckle, one leg braces
				segs = seq {
					{ pose = withLegs(P({ r = lean(10 * p), w = lean(24 * p) * twist(18 * p), n = lean(-10 * p),
						rs = sw(24 * p, -14 * p, 12 * p), ls = sw(18 * p, 14 * p, -12 * p), re = el(22 * p), le = el(22 * p) }),
						legs(14 * p, 4 * p, 26 * p, 12 * p)),
						time = 0.08, ease = Ease.outQuad, fs = 1.4 },
					-- AIRBORNE: cut off the floor, the back arches, the arms fly up, the legs trail below, then it comes down
					{ pose = withLegs(P({ r = lean(16 * p), w = lean(34 * p) * twist(10 * p), n = lean(-16 * p),
						rs = sw(110 * p, -10 * p, 30 * p), ls = sw(110 * p, 10 * p, -30 * p), re = el(16 * p), le = el(16 * p) }),
						legs(-8 * p, 10 * p, 30 * p, 22 * p)),
						time = 0.24, ease = Ease.outSine, fs = 0.9 },
					{ pose = EMPTY, time = 0.45, ease = Ease.outCubic, fs = 0.8 },
				}
			elseif kind == "chop" then -- folded forward, knees give way
				segs = seq {
					{ pose = withLegs(P({ r = lean(-12 * p), w = lean(-34 * p), n = lean(-14 * p),
						rs = sw(34 * p, 0, 14 * p), ls = sw(34 * p, 0, -14 * p), re = el(28 * p), le = el(28 * p) }),
						legs(22 * p, 22 * p, 40 * p, 18 * p)),
						time = 0.08, ease = Ease.outQuad, fs = 1.4 },
					-- SKID: the feet are planted and slide, one foot braced out in front, the body leans back against the push, the arms fly out
					{ pose = withLegs(P({ r = lean(8 * p), w = lean(-14 * p), n = lean(-10 * p),
						rs = sw(50 * p, 0, 34 * p), ls = sw(50 * p, 0, -34 * p), re = el(26 * p), le = el(26 * p) }),
						legs(30 * p, -10 * p, 36 * p, 12 * p)),
						time = 0.28, ease = Ease.outSine, fs = 0.9 },
					{ pose = EMPTY, time = 0.50, ease = Ease.outCubic, fs = 0.8 },
				}
			elseif kind == "slam" then -- driven into the ground: folds, bounces once, lies still while stunned, then gets up slowly
				segs = seq {
					{ pose = withLegs(P({ r = lean(-20 * p), w = lean(-58 * p), n = lean(-26 * p),
						rs = sw(60 * p, 0, 22 * p), ls = sw(60 * p, 0, -22 * p), re = el(34 * p), le = el(34 * p) }),
						legs(42 * p, 42 * p, 72 * p, 26 * p)),
						time = 0.06, ease = Ease.outQuad, fs = 2.0 },
					{ pose = withLegs(P({ r = lean(-8 * p), w = lean(-30 * p), n = lean(-12 * p),
						rs = sw(40 * p, 0, 16 * p), ls = sw(40 * p, 0, -16 * p), re = el(24 * p), le = el(24 * p) }),
						legs(26 * p, 26 * p, 46 * p, 16 * p)),
						time = 0.10, ease = Ease.outSine, fs = 1.0 }, -- the bounce
					{ pose = withLegs(P({ r = lean(20 * p), w = lean(34 * p) * twist(8 * p), n = lean(26 * p),
						rs = sw(72 * p, -22 * p, 40 * p), ls = sw(72 * p, 22 * p, -40 * p), re = el(14 * p), le = el(14 * p) }),
						legs(-10 * p, 18 * p, 30 * p, 12 * p)),
						time = 0.14, ease = Ease.outQuad, fs = 1.4 }, -- thrown away: back arched, arms flung, legs trailing
					{ pose = withLegs(P({ r = lean(-14 * p), w = lean(-46 * p), n = lean(-20 * p),
						rs = sw(44 * p, 0, 18 * p), ls = sw(44 * p, 0, -18 * p), re = el(30 * p), le = el(30 * p) }),
						legs(32 * p, 32 * p, 58 * p, 20 * p)),
						time = 0.55, ease = Ease.inOutSine, fs = 0.8 }, -- stunned: stays down
					{ pose = EMPTY, time = 0.45, ease = Ease.inOutQuad, fs = 0.7 },
				}
			elseif kind == "fling" then -- cut by the slash and thrown: snapped back, tumbles in the air, lands sprawled, bounces, lies stunned, gets up
				segs = seq {
					-- the cut lands: the chest is snapped back along the blade, the arms and legs are thrown the other way (2 frames)
					{ pose = withLegs(P({ r = lean(24 * p), w = lean(42 * p) * twist(28 * p), n = lean(32 * p),
						rs = sw(100 * p, -30 * p, 50 * p), ls = sw(100 * p, 30 * p, -50 * p), re = el(10 * p), le = el(10 * p) }),
						legs(-6 * p, 30 * p, 44 * p, 20 * p)),
						time = 0.06, ease = Ease.outQuad, fs = 2.0 },
					-- flying backwards: the back arches, the arms trail over the head, the legs fold up behind
					{ pose = withLegs(P({ r = lean(55 * p), w = lean(30 * p) * twist(40 * p), n = lean(-18 * p),
						rs = sw(150 * p, -40 * p, 40 * p), ls = sw(140 * p, 40 * p, -40 * p), re = el(24 * p), le = el(30 * p) }),
						legs(-30 * p, 24 * p, 50 * p, 10 * p)),
						time = 0.18, ease = Ease.outSine, fs = 1.0 },
					-- the tumble turns over. ANGULAR MOMENTUM (L = I * omega is kept): the limbs are pulled IN (a smaller moment of inertia I),
					-- so the body must turn FASTER: the arms and legs fold close and this turn is shorter (0.22 -> 0.16 s)
					{ pose = withLegs(P({ r = lean(-34 * p), w = lean(-26 * p) * twist(90 * p), n = lean(-34 * p),
						rs = sw(25 * p, -8 * p, 28 * p), ls = sw(30 * p, 10 * p, -28 * p), re = el(85 * p), le = el(80 * p) }),
						legs(50 * p, 40 * p, 95 * p, 60 * p)),
						time = 0.11, ease = Ease.inOutSine, fs = 1.4 },
					-- the landing: folds and spreads out on the floor
					{ pose = withLegs(P({ r = lean(35 * p), w = lean(-40 * p), n = lean(-24 * p),
						rs = sw(70 * p, 0, 60 * p), ls = sw(70 * p, 0, -60 * p), re = el(30 * p), le = el(30 * p) }),
						legs(40 * p, 40 * p, 70 * p, 30 * p)),
						time = 0.12, ease = Ease.outQuad, fs = 1.8 },
					-- one small bounce, then it lies there stunned
					{ pose = withLegs(P({ r = lean(12 * p), w = lean(10 * p) * twist(10 * p), n = lean(10 * p),
						rs = sw(90 * p, -10 * p, 40 * p), ls = sw(90 * p, 10 * p, -40 * p), re = el(16 * p), le = el(16 * p) }),
						legs(10 * p, 20 * p, 36 * p, 16 * p)),
						time = 0.10, ease = Ease.outSine, fs = 1.0 },
					{ pose = withLegs(P({ r = lean(-10 * p), w = lean(-32 * p), n = lean(-16 * p),
						rs = sw(40 * p, 0, 25 * p), ls = sw(40 * p, 0, -25 * p), re = el(30 * p), le = el(30 * p) }),
						legs(30 * p, 30 * p, 54 * p, 22 * p)),
						time = 0.5, ease = Ease.inOutSine, fs = 0.8 },
					{ pose = EMPTY, time = 0.5, ease = Ease.inOutQuad, fs = 0.7 },
				}
			elseif kind == "grab" then -- held limp, legs dangling
				segs = seq {
					{ pose = withLegs(P({ r = lean(10), w = lean(20), n = lean(18),
						rs = sw(-8, -8, 16), ls = sw(-8, 8, -16), re = el(30), le = el(30) }),
						legs(8, 4, 24, 10)),
						time = 0.10, ease = Ease.outQuad, fs = 1.3 },
					{ pose = withLegs(P({ r = lean(12), w = lean(24), n = lean(20),
						rs = sw(-10, -10, 20), ls = sw(-10, 10, -20), re = el(34), le = el(34) }),
						legs(10, 6, 30, 12)),
						time = 1.0, ease = Ease.linear, fs = 1.0 },
					{ pose = EMPTY, time = 0.35, ease = Ease.outCubic, fs = 0.8 },
				}
			else -- "blast": big arch, arms thrown, legs folded
				segs = seq {
					{ pose = withLegs(P({ r = lean(18), w = lean(34) * twist(10), n = lean(26),
						rs = sw(70, -25, 45), ls = sw(70, 25, -45), re = el(12), le = el(12) }),
						legs(16, 24, 38, 14)),
						time = 0.08, ease = Ease.outQuad, fs = 1.8 },
					{ pose = EMPTY, time = 0.75, ease = Ease.outCubic, fs = 0.55 },
				}
			end
			if chained and (kind == "chop" or kind == "rise") and #segs >= 2 then
				-- chained hit: the body is still bent from the first hit, so it stays down a little longer (3 extra frames) before it recovers
				local hold: Segment = { pose = segs[1].pose, time = 0.1, ease = Ease.linear, fs = 1.0 }
				table.insert(segs, 2, hold)
			end
			if not a.joints.w then -- R6: no waist, so the root takes the waist bend
				for _, sg in segs do
					local pose = sg.pose
					if pose then
						pose.r = (pose.r or ID) * (pose.w or ID)
					end
				end
			end
			a:setSegments(segs)

			-- impulses: the head whips and the torso rocks after the pose snap
			if kind == "rise" then
				a:kick("n", axis, 7 * p)
				a:kick("w", axis, 4 * p)
			elseif kind == "chop" then
				a:kick("w", -axis, 6 * p)
				a:kick("n", -axis, 5 * p)
			elseif kind == "slam" then
				a.tremorUntil = os.clock() + 0.9
				a:kick("n", axis, 8 * p)
				a:kick("w", -axis, 5 * p)
			elseif kind == "fling" then
				a.tremorUntil = os.clock() + 0.9
				a:kick("n", axis, 12 * p)
				a:kick("w", axis, 8 * p)
				a:kick("rs", axis, 6 * p)
				a:kick("ls", axis, 6 * p)
			elseif kind == "grab" then
				a.tremorUntil = os.clock() + 1.1
				a:kick("n", axis, 6)
				a:kick("w", axis, 4)
			else
				a.tremorUntil = 0
				a:kick("n", axis, 10)
				a:kick("w", axis, 6)
			end
			-- PHYSICS OF BEING HIT (not for "grab"): (1) the knees absorb the load (they bend at once: a force pushes the body down
			-- into the floor and the legs give), then straighten as the body recovers; (2) KINETIC CHAIN: the blow reaches the torso first
			-- and the head only 0.04 s later, so the head WHIPS after the torso (it lags, then snaps); (3) the bigger the hit, the more of both
			if kind ~= "grab" then
				for _, key in { "lk", "rk" } do
					local st = a.state[key]
					if st then st.wv += Vector3.new(-4.5 * p, 0, 0) end
				end
				task.delay(0.04, function()
					if a.dead or actors[model] ~= a then return end
					a:kick("n", axis, 4.5 * p) -- the head whips after the torso
				end)
				task.delay(0.17, function()
					if a.dead or actors[model] ~= a then return end
					for _, key in { "lk", "rk" } do
						local st = a.state[key]
						if st then st.wv += Vector3.new(3 * p, 0, 0) end
					end
				end)
			end
			-- the second reaction, a beat later: the body catches itself (the torso comes back against the push, the arms swing)
			if kind ~= "grab" then
				task.delay(0.14, function()
					if a.dead or actors[model] ~= a then return end
					a:kick("w", -axis, 3 * p)
					a:kick("rs", -axis, 4 * p)
					a:kick("ls", axis, 4 * p)
				end)
				-- law 37 (shock transfer): the wave runs from the chest out to the arms, which swing a beat later against the push
				task.delay(0.08, function()
					if a.dead or actors[model] ~= a then return end
					a:kick("rs", -axis, 3.5 * p)
					a:kick("ls", -axis, 3.5 * p)
				end)
				-- law 244 (balance): the body hunts for its balance, one small swing back, then a smaller one forward (only hits that leave it standing)
				if kind == "rise" or kind == "chop" then
					task.delay(0.42, function()
						if a.dead or actors[model] ~= a then return end
						a:kick("w", -axis, 2.4 * p)
						a:kick("r", -axis, 1.6 * p)
					end)
					task.delay(0.62, function()
						if a.dead or actors[model] ~= a then return end
						a:kick("w", axis, 1.2 * p)
					end)
				end
			end
			if deps.onVictimHit then deps.onVictimHit(model, kind, flat) end
		end
	end

	-- variants share every value of their base step (timings, camera, reaction) unless they set it
	for _, step in COMBO do
		if step.variants then
			for _, v in step.variants do
				setmetatable(v, { __index = step })
			end
		end
	end

	-- variant 0 = the base step, 1.. = its variants; the pick wraps around
	local function variantCount(index: number): number
		local step: Step? = COMBO[index]
		local list = if step then step.variants else nil
		return 1 + (if list then #list else 0)
	end
	local function stepFor(index: number, variant: number?): Step
		local step: Step = COMBO[index] or COMBO[1]
		local list = step.variants
		local v: number = (variant or 0) % variantCount(index)
		if v == 0 or not list then return step end
		return list[v]
	end

	-- let go of every joint, drop the hook and close the loop (call it when the tool is destroyed)
	local function destroy(): ()
		turnHook = nil
		for _, a in actors do
			pcall(a.retire, a)
		end
		table.clear(actors)
		if loopConn then
			loopConn:Disconnect()
			loopConn = nil
		end
	end

	local anim: Anim = {
		Rig = Rig, COMBO = COMBO, HitReact = HitReact,
		stepFor = stepFor, variantCount = variantCount, Destroy = destroy,
	}
	return anim
end

return SwordRig

