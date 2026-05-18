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
		TurnSpeed = 2.4, -- rad/sec at full lean
		RespawnSeconds = 3,
		MaxHealth = 100,
		RagdollPushForce = 1500, -- impulse (scaled by mass) shoving a dead bike so it tumbles
	},

	Combat = {
		-- Ram damage scales with relative speed between two bikes.
		RamMinSpeed = 25, -- below this, a collision does no damage
		RamDamagePerStud = 0.8, -- damage = (relativeSpeed - RamMinSpeed) * this
		RamDamageCap = 60,
		FriendlyFire = false,
	},

	World = {
		SpawnHeight = 5, -- studs above a SpawnLocation to place a bike
	},
}

table.freeze(Config.Bike)
table.freeze(Config.Combat)
table.freeze(Config.World)
return table.freeze(Config)
