--!strict
-- ModuleScript "BlinkCutConfig" (parent: Tool "TrueKatana")
-- The numbers that the server and the client must share (Z skill "BLINK CUT"). Changing one here changes both.
-- Estimated values: tune in game (the damage numbers are only a first guess: balance them later)
return {
	Range = 20, -- studs of the dash
	DashTime = 0.12, -- seconds of the dash itself
	Windup = 0.09, -- seconds of the draw before the dash (it also hides the network delay)
	Cooldown = 16.5, -- seconds until the skill can be used again
	HitWidth = 7, -- width of the path that looks for an enemy to catch
	HitHeight = 6,
	PositionSlack = 6, -- studs the final position may differ from the planned end before the server pulls the player back

	-- the catch: when the dash meets an enemy, it stops in front of it, holds it, and cuts it many times (hits 1 and 2 alternate)
	StopDistance = 4, -- studs in front of the enemy where the dash stops
	Slashes = 25, -- number of cuts
	SlashGap = 0.11, -- seconds between two cuts (25 cuts take about 2.8 s)
	SlashDamage = 1.75, -- damage of each cut: 24 cuts of 1.75 + the last cut of 9 = 51 in all, the same total as 15 cuts of 3 + 9 before
	FinalDamage = 9, -- damage of the last cut (it also throws the enemy, exactly like hit 3: the launch and the stun are Server.lua's)
	HoldRange = 18, -- the hold breaks if the two are farther apart than this
	FinishWindup = 0.32, -- seconds of the wind-up of the last cut (a heavier chop than the quick cuts): the damage and the knockback come after it
	FinishKnock = 22, -- studs of the (weak) knockback of the last cut
}
