--!strict
--[[
	InputController
	Translates raw input into intent (throttle/steer) and exposes it via
	GetMoveVector so rebinding lives in one place. Also owns the debug
	self-destruct bind used to exercise the death/respawn loop.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)

-- Set false to remove the debug "R = kill my bike" bind for playtests/release.
local DEBUG_SELF_DESTRUCT = true

local InputController = Knit.CreateController({
	Name = "InputController",
})

-- Returns throttle (-1..1) and steer (-1..1) from current keyboard state.
function InputController:GetMoveVector(): (number, number)
	local throttle = 0
	local steer = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		throttle += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		throttle -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		steer += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		steer -= 1
	end
	return throttle, steer
end

function InputController:KnitStart()
	if not DEBUG_SELF_DESTRUCT then
		return
	end
	local CombatService = Knit.GetService("CombatService")
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.R then
			CombatService:DebugKill()
		end
	end)
end

function InputController:KnitInit() end

return InputController
