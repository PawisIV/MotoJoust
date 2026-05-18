--!strict
--[[
	BikeController
	Bike spawning/binding is fully server-authoritative (BikeService). This
	controller is intentionally minimal — the public spawn-request flow was
	removed. Client-side bike behavior will be added when a feature needs it
	(do not pre-scaffold).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local BikeController = Knit.CreateController({
	Name = "BikeController",
})

function BikeController:KnitInit() end

function BikeController:KnitStart() end

return BikeController
