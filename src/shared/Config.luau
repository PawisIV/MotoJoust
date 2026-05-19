--!strict
--[[
	Config
	Single source of truth for game-wide tuning values. Both client and server
	require this. Change balance/feel here, never hard-code magic numbers in
	services or controllers.
]]

local Config = {
	Bike = {
		MaxSpeed = 90, -- studs/sec
		Acceleration = 45, -- studs/sec^2
		DriveForcePerMass = 800, -- BikeDrive MaxForce per unit assembly mass; finite so walls overpower it
		TurnSpeed = 2.4, -- rad/sec yaw at full steer
		RespawnSeconds = 3,
		MaxHealth = 100,
		RagdollPushForce = 1500, -- impulse (scaled by mass) shoving a dead bike so it tumbles
		UprightResponsiveness = 30, -- AlignOrientation.Responsiveness while stable
		WobbleResponsiveness = 5, -- weakened responsiveness during a wobble
		WobbleAngularImpulse = 9000, -- angular impulse applied to PrimaryPart on a hard ram
		WobbleRecoverSeconds = 1.2, -- how long a wobble lasts before upright is restored
	},

	Combat = {
		-- Ram damage scales with relative speed between two bikes.
		RamMinSpeed = 25, -- below this, a collision does no damage
		RamDamagePerStud = 0.8, -- damage = (relativeSpeed - RamMinSpeed) * this
		RamDamageCap = 60,
		FriendlyFire = false,
		WobbleSpeed = 60, -- closing speed above which a ram also triggers a wobble
		RamDebounceSeconds = 0.5, -- per-pair cooldown so sustained contact doesn't spam ResolveRam
	},

	World = {
		SpawnHeight = 5, -- studs above a SpawnLocation to place a bike
	},
}

table.freeze(Config.Bike)
table.freeze(Config.Combat)
table.freeze(Config.World)
return table.freeze(Config)
