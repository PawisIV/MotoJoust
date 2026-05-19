--!strict
--[[
	BikeController
	Drives the local player's bike (server-spawned, named Bike_<Name>) via the
	rig BikeService built: sets BikeDrive (LinearVelocity) and BikeUpright
	(AlignOrientation) every Heartbeat from InputController:GetMoveVector.
	Steering rotates the upright target heading (no AngularVelocity, so the
	upright constraint never fights steering). Handles the Wobble signal.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Config = require(ReplicatedStorage.Shared.Config)

local BikeController = Knit.CreateController({
	Name = "BikeController",
})

BikeController._bike = nil :: Model?
BikeController._heading = 0 -- radians, world yaw
BikeController._speed = 0 -- current forward speed (studs/sec)
BikeController._wobbleUntil = 0 -- os.clock() time the wobble ends (0 = none)

function BikeController:_acquire(): Model?
	local player = Players.LocalPlayer
	local bike = workspace:FindFirstChild(`Bike_{player.Name}`)
	if not bike or not bike:IsA("Model") then
		self._bike = nil
		return nil
	end
	if bike ~= self._bike then
		-- New bike (join/respawn): seed heading from its current facing.
		self._bike = bike
		self._speed = 0
		self._wobbleUntil = 0
		local primary = bike.PrimaryPart
		if primary then
			local _, y = primary.CFrame:ToOrientation()
			self._heading = y
		end
	end
	return bike
end

function BikeController:_step(dt: number)
	local bike = self:_acquire()
	if not bike then
		return
	end
	local primary = bike.PrimaryPart
	local drive = primary and primary:FindFirstChild("BikeDrive") :: LinearVelocity?
	local upright = primary and primary:FindFirstChild("BikeUpright") :: AlignOrientation?
	if not primary or not drive or not upright then
		return
	end

	local InputController = Knit.GetController("InputController")
	local throttle, steer = InputController:GetMoveVector()

	self._heading += steer * Config.Bike.TurnSpeed * dt

	local target = throttle * Config.Bike.MaxSpeed
	local step = Config.Bike.Acceleration * dt
	if self._speed < target then
		self._speed = math.min(self._speed + step, target)
	elseif self._speed > target then
		self._speed = math.max(self._speed - step, target)
	end

	local facing = CFrame.Angles(0, self._heading, 0)
	local fwd = facing.LookVector
	drive.VectorVelocity = Vector3.new(fwd.X * self._speed, primary.AssemblyLinearVelocity.Y, fwd.Z * self._speed)
	upright.CFrame = facing

	if self._wobbleUntil ~= 0 and os.clock() >= self._wobbleUntil then
		self._wobbleUntil = 0
		upright.Responsiveness = Config.Bike.UprightResponsiveness
	end
end

function BikeController:_onWobble()
	local bike = self._bike
	local primary = bike and bike.PrimaryPart
	local upright = primary and primary:FindFirstChild("BikeUpright") :: AlignOrientation?
	if not primary or not upright then
		return
	end
	upright.Responsiveness = Config.Bike.WobbleResponsiveness
	self._wobbleUntil = os.clock() + Config.Bike.WobbleRecoverSeconds
	local axis = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
	if axis.Magnitude > 0 then
		primary:ApplyAngularImpulse(axis.Unit * Config.Bike.WobbleAngularImpulse)
	end
end

function BikeController:KnitStart()
	local CombatService = Knit.GetService("CombatService")
	CombatService.Wobble:Connect(function()
		self:_onWobble()
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		self:_step(dt)
	end)
end

function BikeController:KnitInit() end

return BikeController
