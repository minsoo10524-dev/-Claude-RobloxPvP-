--!strict
-- ModuleScript "ReaperMarkConfig" (parent: Tool "TrueKatana")
-- The numbers of the X skill (the mark, the dash, the grab and the slam). Read by the server script and the client script.

return {
	Range = 200, -- studs: an enemy farther than this cannot be MARKED
	Cone = 35, -- degrees: how far from the line of sight an enemy may be and still be picked / dashed to
	DashRange = 200, -- studs: the farthest a marked enemy may be for the dash
	BehindDistance = 5, -- studs: where the dash ends, BEHIND the enemy (on the far side from where the dash started)
	DashTime = 0.12, -- seconds: the shortest dash
	DashTimeMax = 0.24, -- seconds: the longest dash (the time grows with the distance: distance / DashSpeed, between the two)
	DashSpeed = 1100, -- studs per second used to pick the time of a long dash
	BraceTime = 0.1, -- seconds the braking pose is held after the dash
	Cooldown = 12, -- seconds, started by the DASH (placing a mark costs nothing)

	-- the blow (at the moment the enemy hits the floor)
	Damage = 30, -- health taken from the enemy
	KnockDistance = 22, -- studs the enemy is pushed away from the owner (Server.lua caps it at 30 and scales it by the masses)
	KnockTime = 0.5, -- seconds of the skid
	Stun = 1.4, -- seconds the enemy cannot act
}
