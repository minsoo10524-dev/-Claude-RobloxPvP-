--!strict
-- ModuleScript "ComboTiming"  (parent: Tool "DarkV1", next to Client and Server)
-- The ONE place for the numbers that the client motion and the server hit check must share.
-- Client (through SwordRig) and Server both read this table, so changing a number here can never
-- leave the motion and the hit timing out of step.
--   windup = seconds from the click to the strike     strike = length of the strike
--   dash   = seconds of the dash (finisher only)      nextAt = seconds until the next click is accepted
--   hold / slam = hit 3 only: seconds the caught enemy is held up, and the slam itself
--   rollMax / rollMin = hit 3 only: the longest roll, and the earliest moment a catch is allowed
--   cooldown = hit 3 only: seconds after it starts until it can be used again (until then the combo starts over with hit 1)

export type HitTiming = {
	windup: number, strike: number, dash: number, nextAt: number,
	hold: number?, slam: number?, rollMax: number?, rollMin: number?, cooldown: number?,
}

local Timing: { HitTiming } = {
	{ windup = 0.30, strike = 0.10, dash = 0, nextAt = 0.61 }, -- hit 1: startup 7 frames, strike 3 frames, input accepted from frame 17
	{ windup = 0.31, strike = 0.11, dash = 0, nextAt = 0.70 }, -- hit 2
	-- hit 3 "Moonfall": windup = crouch, dash = one full turn of the spinning slash (30 studs per turn). The roll goes on until it
	-- catches something, at most rollMax seconds; a catch is allowed after rollMin seconds so a near enemy still gets the full turn.
	-- Then hold  + slam. No recovery after it.
	{ windup = 0.30, strike = 0.12, dash = 0.45, hold = 0.12, slam = 0.14, nextAt = 0.2, rollMax = 0.75, rollMin = 0.55, cooldown = 3.5 },
}

return Timing
