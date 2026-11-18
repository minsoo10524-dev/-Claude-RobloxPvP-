--!strict
-- ModuleScript "ReaperMarkCarry" (parent: Tool "TrueKatana")
-- The ONE timeline of the grab / drag / knock / re-grab / jump / slam part of the X skill. The server (which moves the enemy) and the owner's client
-- (which moves the owner) both read it, so the two bodies stay together. Everything is worked out in a base frame B: B stands where the dash ended and
-- looks at the enemy (so -Z is toward the enemy).
--   sample(t, dragLen) -> ownerLift (studs above the owner's floor point), enemyCF (the enemy's root relative to the owner's frame),
--                         phase, done, yaw (radians), offset (where the owner's floor point is, in B's space)
--   the owner is at   B * Translate(offset) * Angles(0, yaw, 0) * Translate(0, lift, 0)
--   the enemy is at   B * Translate(offset) * Angles(0, yaw, 0) * enemyCF
--   (the enemy's place is worked out in B's space and turned into the owner's frame, so when the owner SPINS the enemy does NOT go round with him)
--   t = seconds since T0 (a server time the server chooses, a little after the dash will have arrived). Before T0: phase "wait".
--   dragLen = how far the drag may go (the server shortens it when a wall is in the way; both sides get the same number)
--   final(dragLen) -> where the owner stands (offset) and which way he faces (yaw) when the enemy is slammed
-- Phases:
--   grab (pulled in) -> clamp (HIT STOP) -> hoist (lifted off the ground)
--   drag   : the owner RUNS about 30 studs in a STRAIGHT line and the enemy is pulled along the floor in a straight line in front of him, on the tip of the
--            sword; only the OWNER turns: two fast turns to the left (hips, back and the sword arm come round together), the enemy goes on straight
--   knock  : the enemy is knocked a little further on, straight ahead, off the tip: it hops and skids and slows down by friction; the owner holds the
--            follow-through, like the finish of the third hit
--   regrab : the owner lunges to the enemy, grabs it and lifts it
--   heave -> rise (a sudden, very high jump) -> hang -> load -> slam -> hit (HIT STOP, the moment of the damage) -> rest -> done

local Carry = {}

local PULL, CLAMP, HOIST = 0.22, 0.1, 0.23
local DRAG, KNOCK, REGRAB = 1.3, 0.42, 0.32 -- the drag is a WALK: 30 studs at about 16 studs/s (the normal walk speed)
local HEAVE, RISE, HANG, LOAD, SLAM, HIT, REST = 0.3, 0.5, 0.2, 0.2, 0.13, 0.1, 0.55 -- (the longer the anticipation, the stronger the blow: 0.3 s before the jump, 0.2 s before the slam; the hit stop is about 6 frames)
local HEIGHT = 40 -- studs of the jump
local DIP = 0.6 -- studs the owner sinks while loading the jump
local SPIN = 2 -- full turns to the left that the OWNER makes during the drag
local YEND = SPIN * math.pi * 2 -- the angle after the drag: the SAME NUMBER in every later phase (it looks like 0, but a jump from 720 degrees to 0 would be seen by anything that reads the angle)
local AHEAD = 3.7 -- studs the enemy is in front of the owner during the drag (the length of the arm and the sword)
local KNOCK_DIST = 9 -- studs the enemy is knocked on, straight ahead
local START = Vector3.new(0, 0, -5) -- the enemy before the grab (the dash ends BehindDistance = 5 studs behind it)
local HELD = Vector3.new(0, 0.4, -2.4) -- the enemy while it is held close
local HOISTED = Vector3.new(0, 1.3, -2.3) -- ... lifted off the ground by the clamp
local LAND = Vector3.new(0, -1.9, -3.0) -- the enemy lying on its back (its root is lower when it lies flat)
local LYING_Y = -1.9
local DRAG_Y = -0.1 -- the height of the enemy's root while it is dragged on the floor
local rad = math.rad
local ZERO = Vector3.zero

Carry.LEAD = 0.5
Carry.DRAG = 30 -- studs of the drag (the longest)
Carry.TOTAL = PULL + CLAMP + HOIST + DRAG + KNOCK + REGRAB + HEAVE + RISE + HANG + LOAD + SLAM + HIT + REST
Carry.IMPACT = PULL + CLAMP + HOIST + DRAG + KNOCK + REGRAB + HEAVE + RISE + HANG + LOAD + SLAM -- seconds after T0 when the enemy hits the floor
Carry.HANG = HANG + LOAD -- (the quiet before the blow, for the sound)
Carry.SLAM = SLAM
Carry.SWEEP_AT = PULL + CLAMP + HOIST -- seconds after T0 when the turning of the drag begins
Carry.SWEEPT = DRAG -- ... and how long it lasts
Carry.SPIN = SPIN

-- the walk: a short start, an even pace, a short stop (a trapezoid of speed): the distance covered as a function of u = 0..1
local function trap(u: number): number
	local a = 0.12
	local v = 1 / (1 - a)
	if u < a then return 0.5 * v * u * u / a end
	if u < 1 - a then return 0.5 * v * a + v * (u - a) end
	return 1 - 0.5 * v * (1 - u) * (1 - u) / a
end

local function easeOut(u: number): number
	return 1 - (1 - u) * (1 - u)
end
local function smooth(u: number): number
	return u * u * (3 - 2 * u)
end

local function body(pos: Vector3, pitch: number): CFrame
	-- the pitch turns the enemy about the X axis; the half turn about Y first makes it face the owner
	return CFrame.new(pos) * CFrame.Angles(rad(pitch), 0, 0) * CFrame.Angles(0, math.pi, 0)
end

-- where the owner stands and where the enemy lies when the drag ends and the knock is over (all in B's space)
local function places(L: number): (Vector3, Vector3, Vector3, Vector3)
	local off1 = Vector3.new(0, 0, -L)
	local release = off1 + Vector3.new(0, DRAG_Y, -AHEAD) -- the enemy at the end of the drag
	local landing = Vector3.new(0, LYING_Y, release.Z - KNOCK_DIST)
	local off2 = Vector3.new(0, 0, landing.Z + 2.6) -- the owner stops 2.6 studs short of the enemy, facing it (he looks along -Z all the time)
	return off1, release, landing, off2
end

function Carry.final(dragLen: number?): (Vector3, number)
	local _, _, _, off2 = places(math.clamp(dragLen or Carry.DRAG, 0, Carry.DRAG))
	return off2, YEND
end

function Carry.sample(t: number, dragLen: number?): (number, CFrame, string, boolean, number, Vector3)
	local L = math.clamp(dragLen or Carry.DRAG, 0, Carry.DRAG)
	if t < 0 then return 0, body(START, 0), "wait", false, 0, ZERO end

	if t < PULL then -- the enemy is pulled in
		local a = easeOut(t / PULL)
		return 0, body(START:Lerp(HELD, a), 12 * a), "grab", false, 0, ZERO
	end
	t -= PULL

	if t < CLAMP then -- HIT STOP: the clamp lands and everything holds (only a tremor, added by whoever moves the bodies)
		return 0, body(HELD, 12), "clamp", false, 0, ZERO
	end
	t -= CLAMP

	if t < HOIST then -- then the enemy is hoisted off the ground
		local h = smooth(t / HOIST)
		return 0, body(HELD:Lerp(HOISTED, h), 12 + 8 * h), "hoist", false, 0, ZERO
	end
	t -= HOIST

	local off1, release, landing, off2 = places(L)

	if t < DRAG then
		local u = t / DRAG
		local offset = Vector3.new(0, 0, -L * smooth(u)) -- the owner travels straight ahead
		local yaw = if u < 0.1 then -0.5 * smooth(u / 0.1) -- ANTICIPATION: first a small turn the OTHER way (to the right), as a dancer or a thrower winds up before the spin
			else -0.5 + (SPIN * math.pi * 2 + 0.5) * smooth((u - 0.1) / 0.9) -- then the spin to the left: it accelerates smoothly, and its speed fades out softly to nothing at the end
		local settle = smooth(math.min(u / 0.2, 1)) -- in the first fifth the enemy is swung down from the hoist onto the floor in front of the owner
		local ahead = 2.3 + (AHEAD - 2.3) * settle
		local bob = 0.22 * math.abs(math.sin(math.pi * t / 0.32 + 0.9)) -- the body bounces on the beat of the stride (every 0.32 s: one step, the same rhythm as the animation and the footfalls)
		local sway = 5 * math.sin(u * math.pi * 6) -- it flops from side to side as it is dragged (zero at both ends)
		local posB = Vector3.new(0.25 * math.sin(u * math.pi * 6), 1.3 + (DRAG_Y - 1.3) * settle + bob, offset.Z - ahead) -- a straight line in B's space
		local ownerCF = CFrame.new(offset) * CFrame.Angles(0, yaw, 0)
		return 0.16 * math.abs(math.sin(math.pi * t / 0.32)), ownerCF:ToObjectSpace(body(posB, 20 - 75 * settle + sway)), "drag", false, yaw, offset
	end
	t -= DRAG

	local ownerEnd = CFrame.new(off1) -- (two full turns: he faces forward again)
	local lying = body(landing, -90)

	if t < KNOCK then -- the enemy is knocked on, off the tip: one hop, a skid that slows down like friction (distance ~ easeOut)
		local u = t / KNOCK
		local k = easeOut(u)
		local x = release:Lerp(landing, k)
		local hop = 1.4 * math.sin(math.pi * math.min(u * 1.6, 1)) -- one hop, in the first part
		local pos = Vector3.new(x.X, release.Y + (LYING_Y - release.Y) * k + hop, x.Z)
		return 0, ownerEnd:ToObjectSpace(body(pos, -55 - 35 * k)), "knock", false, YEND, off1
	end
	t -= KNOCK

	if t < REGRAB then -- the owner lunges to the enemy, grabs it and lifts it
		local u = t / REGRAB
		local off = off1:Lerp(off2, smooth(u)) -- the lunge starts from rest (no jump in speed after the follow-through of the knock)
		local ownerCF = CFrame.new(off)
		local held = ownerCF * body(HELD, 20)
		local lift = smooth(math.max(0, (u - 0.35) / 0.65))
		return 0, ownerCF:ToObjectSpace(lying:Lerp(held, lift)), "regrab", false, YEND, off
	end
	t -= REGRAB

	local after = off2
	if t < HEAVE then
		local u = t / HEAVE
		local dip = -DIP * easeOut(u)
		return dip, body(HELD + Vector3.new(0, dip, 0), 20 - 15 * smooth(u)), "heave", false, YEND, after
	end
	t -= HEAVE

	if t < RISE then
		local u = t / RISE
		local s = (1 - (1 - u) ^ 3) * smooth(math.min(u / 0.2, 1)) -- sudden, but out of the crouch: the speed rises over the first 0.1 s instead of jumping, then it slows toward the top
		local lift = -DIP + (HEIGHT + DIP) * s
		return lift, body(HELD + Vector3.new(0, lift, 0), 5 - 15 * s), "rise", false, YEND, after
	end
	t -= RISE

	if t < HANG then
		local sway = math.sin(t / HANG * math.pi) * 2
		return HEIGHT, body(HELD + Vector3.new(0, HEIGHT, 0), -10 - 12 * (t / HANG) - sway), "hang", false, YEND, after
	end
	t -= HANG

	if t < LOAD then
		local u = smooth(t / LOAD)
		return HEIGHT + 0.8 * u, body(HELD + Vector3.new(0, HEIGHT + 0.8 * u, 0), -22 - 38 * u), "load", false, YEND, after
	end
	t -= LOAD

	if t < SLAM then
		local u = t / SLAM
		local e = u * u -- falling: slow at first, then fast
		local lift = (HEIGHT + 0.8) * (1 - e)
		local pos = (HELD + Vector3.new(0, lift, 0)):Lerp(LAND, e ^ 4) -- it stays in the owner's hands until just before the floor -- the enemy ends on the floor, in front of the owner's feet
		return lift, body(pos, -60 - 30 * e), "slam", false, YEND, after
	end
	t -= SLAM

	if t < HIT then -- HIT STOP at the blow: the enemy lies on its back and everything holds still for a moment
		return 0, body(LAND, -90), "hit", false, YEND, after
	end
	t -= HIT

	-- the landing is not dead: the enemy bounces once or twice (a damped |sin| bounce) and the owner is pushed up a little by the recoil
	local decay = math.exp(-9 * t)
	local bounce = 0.35 * decay * math.abs(math.sin(15 * t))
	local recoil = 0.5 * decay * math.abs(math.sin(17 * t))
	return recoil, body(LAND + Vector3.new(0, bounce, 0), -90 + 5 * decay * math.abs(math.sin(15 * t))), "rest", t >= REST, YEND, after
end

return Carry
