--!strict
--[[
	CombatService
	Owns damage resolution for the sandbox: ram collisions between bikes and
	any future weapons. All health changes go through ApplyDamage so balance
	and death handling stay in one place. On death it fires BikeDied; it does
	not know or care who handles respawn.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Config = require(ReplicatedStorage.Shared.Config)

local CombatService = Knit.CreateService({
	Name = "CombatService",
	Client = {},

	-- Signal.Signal<Player, Model>, created in KnitInit.
	BikeDied = nil :: any,
})

-- Applies `amount` damage to a bike model, clamping and handling death.
function CombatService:ApplyDamage(bike: Model, amount: number, _source: Model?)
	if amount <= 0 then
		return
	end

	local health = (bike:GetAttribute("Health") :: number?) or Config.Bike.MaxHealth
	health = math.max(0, health - amount)
	bike:SetAttribute("Health", health)

	if health <= 0 then
		bike:SetAttribute("Dead", true)
		local ownerUserId = bike:GetAttribute("OwnerUserId") :: number?
		local owner = if ownerUserId then Players:GetPlayerByUserId(ownerUserId) else nil
		if owner then
			self.BikeDied:Fire(owner, bike)
		end
	end
end

-- Converts a bike-vs-bike collision into ram damage based on closing speed.
function CombatService:ResolveRam(bikeA: Model, bikeB: Model, relativeSpeed: number)
	if relativeSpeed < Config.Combat.RamMinSpeed then
		return
	end

	local damage = (relativeSpeed - Config.Combat.RamMinSpeed) * Config.Combat.RamDamagePerStud
	damage = math.min(damage, Config.Combat.RamDamageCap)

	self:ApplyDamage(bikeB, damage, bikeA)
	self:ApplyDamage(bikeA, damage, bikeB)
end

-- Debug-only: lets a client instantly destroy their own bike to exercise the
-- death/respawn loop without ramming. Gated client-side by DEBUG_SELF_DESTRUCT.
function CombatService.Client:DebugKill(player: Player)
	local BikeService = Knit.GetService("BikeService")
	local bike = BikeService:GetBike(player)
	if bike then
		self.Server:ApplyDamage(bike, math.huge)
	end
end

function CombatService:KnitInit()
	self.BikeDied = Signal.new()
end

function CombatService:KnitStart() end

return CombatService
