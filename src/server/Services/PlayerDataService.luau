--!strict
--[[
	PlayerDataService
	In-memory player profile (kills, loadout). Swap the _profiles table for a
	DataStore/ProfileService-backed store later without touching callers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

export type Profile = {
	Kills: number,
	Deaths: number,
}

local function defaultProfile(): Profile
	return {
		Kills = 0,
		Deaths = 0,
	}
end

local PlayerDataService = Knit.CreateService({
	Name = "PlayerDataService",
	Client = {},

	_profiles = {} :: { [Player]: Profile },
})

function PlayerDataService:GetProfile(player: Player): Profile
	local profile = self._profiles[player]
	if not profile then
		profile = defaultProfile()
		self._profiles[player] = profile
	end
	return profile
end

function PlayerDataService:AddKill(player: Player)
	self:GetProfile(player).Kills += 1
end

function PlayerDataService:KnitStart()
	Players.PlayerRemoving:Connect(function(player)
		-- TODO: persist before clearing once a real datastore is wired in.
		self._profiles[player] = nil
	end)
end

function PlayerDataService:KnitInit() end

return PlayerDataService
