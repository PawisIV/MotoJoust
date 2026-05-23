--!strict
-- ShieldService.server.luau
-- Runs independently outside Knit

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[ShieldService] Started")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShieldActivate = Remotes:WaitForChild("ShieldActivate")
local ShieldDeactivate = Remotes:WaitForChild("ShieldDeactivate")

local shieldFolder = ReplicatedStorage
	:WaitForChild("VFX")
	:WaitForChild("Shield")

local CONFIG = {
	SHIELD_HOLD_TIME = 5,       -- Slower shrink
	PARRY_WINDOW = 0.4,         -- Parry duration
	PARRY_EMIT_COUNT = 50,      -- Parry burst particles
	SHIELD_FULL_RATE = 0,       -- ✅ Rate 0 = emit once, not continuous
	SHIELD_MIN_RATE = 0,
	SHIELD_SIZE_FULL = 3,
	SHIELD_SIZE_MIN = 0.1,
}

local activeShields = {}

local function cloneExtras(attachment)
	local extras = {}
	local extrasFolder = shieldFolder:FindFirstChild("Extras")
	if not extrasFolder then return extras end
	for _, effect in ipairs(extrasFolder:GetChildren()) do
		if effect:IsA("ParticleEmitter") then
			local clone = effect:Clone()
			clone.Enabled = false
			clone.Parent = attachment
			table.insert(extras, clone)
		end
	end
	return extras
end

local function setExtrasEnabled(extras, enabled)
	for _, effect in ipairs(extras) do
		effect.Enabled = enabled
	end
end

local function startShrink(player, shieldBody, extras)
	local startTime = tick()
	local thread = task.spawn(function()
		while activeShields[player] and activeShields[player].isShielding do
			local elapsed = tick() - startTime
			local progress = math.clamp(elapsed / CONFIG.SHIELD_HOLD_TIME, 0, 1)

			local currentSize = CONFIG.SHIELD_SIZE_FULL
				+ (CONFIG.SHIELD_SIZE_MIN - CONFIG.SHIELD_SIZE_FULL) * progress
			local currentRate = CONFIG.SHIELD_FULL_RATE
				+ (CONFIG.SHIELD_MIN_RATE - CONFIG.SHIELD_FULL_RATE) * progress

			-- ✅ Correct — size fades out over particle lifetime
			shieldBody.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, currentSize),
				NumberSequenceKeypoint.new(1, 0),
			})
			shieldBody.Rate = currentRate

			if progress >= 1 then
				if activeShields[player] then
					activeShields[player].isShielding = false
					shieldBody.Enabled = false
					setExtrasEnabled(extras, false)
					print("[ShieldService] Shield broke for " .. player.Name)
				end
				break
			end

			task.wait(0.05)
		end
	end)
	return thread
end

local function spawnShield(player)
	local character = player.Character
	if not character then
		print("[ShieldService] ERROR: No character")
		return
	end

	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if not rootPart then
		print("[ShieldService] ERROR: No rootPart")
		return
	end

	-- ✅ Fix 3 — if shield already active do nothing
	if activeShields[player] and activeShields[player].isShielding then
		print("[ShieldService] Shield already active, ignoring")
		return
	end

	-- Clean existing just in case
	if activeShields[player] then
		if activeShields[player].attachment then
			activeShields[player].attachment:Destroy()
		end
		if activeShields[player].shrinkThread then
			task.cancel(activeShields[player].shrinkThread)
		end
		activeShields[player] = nil
	end

	local shieldBodyTemplate = shieldFolder:FindFirstChild("ShieldBody")
	if not shieldBodyTemplate then
		print("[ShieldService] ERROR: ShieldBody not found")
		return
	end

	-- Attachment — parent of all VFX
	local attachment = Instance.new("Attachment")
	attachment.Name = "ShieldAttachment"
	attachment.Position = Vector3.new(0, 0, 0)
	attachment.Parent = rootPart

	-- ✅ Fix 1 — Shield body emit once immediately (same time as parry)
	local shieldBody = shieldBodyTemplate:Clone()
	shieldBody.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, CONFIG.SHIELD_SIZE_FULL),
		NumberSequenceKeypoint.new(1, 0),
	})
	shieldBody.Rate = 0         -- No continuous emit
	shieldBody.Enabled = false
	shieldBody.Parent = attachment
	shieldBody:Emit(30)         -- Emit once on press

	-- Parry burst
	local parryBurst = nil
	local parryBurstTemplate = shieldFolder:FindFirstChild("ParryBurst")
	if parryBurstTemplate then
		parryBurst = parryBurstTemplate:Clone()
		parryBurst.Enabled = false
		parryBurst.Parent = attachment
		parryBurst:Emit(CONFIG.PARRY_EMIT_COUNT)
		print("[ShieldService] Parry burst emitted")
	end

	-- Extras
	local extras = cloneExtras(attachment)
	setExtrasEnabled(extras, true)

	-- Store data before delay
	activeShields[player] = {
		shieldBody = shieldBody,
		parryBurst = parryBurst,
		extras = extras,
		attachment = attachment,
		shrinkThread = nil,     -- Not started yet
		isParrying = true,
		isShielding = true,
	}

	-- ✅ Fix 4 — Wait for parry window to end before shrinking
	task.delay(CONFIG.PARRY_WINDOW, function()
		if not activeShields[player] then return end

		activeShields[player].isParrying = false
		print("[ShieldService] Parry window closed — starting shrink")

		-- ✅ Fix 2 — Start shrink only after parry window
		local shrinkThread = startShrink(player, shieldBody, extras)
		activeShields[player].shrinkThread = shrinkThread
	end)

	print("[ShieldService] Shield spawned for " .. player.Name)
end

local function removeShield(player)
	local data = activeShields[player]
	if not data then return end

	if data.shrinkThread then
		task.cancel(data.shrinkThread)
	end
	if data.attachment then
		data.attachment:Destroy()
	end

	activeShields[player] = nil
	print("[ShieldService] Shield removed for " .. player.Name)
end

-- Listeners
ShieldActivate.OnServerEvent:Connect(function(player)
	print("[ShieldService] Activate from " .. player.Name)
	spawnShield(player)
end)

ShieldDeactivate.OnServerEvent:Connect(function(player)
	print("[ShieldService] Deactivate from " .. player.Name)
	removeShield(player)
end)

Players.PlayerRemoving:Connect(function(player)
	removeShield(player)
end)

print("[ShieldService] Ready")