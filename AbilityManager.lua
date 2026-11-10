--[[
	AbilityManager
	Server Script - ServerScriptService

	Responsibilities:
	- Validate ability usage on the server.
	- Enforce ownership and per-ability cooldowns.
	- Apply ability effects and clean them up when they expire or the character is removed.

	Expected data:
	- ReplicatedStorage.Modules.Abilities_DB
	- ReplicatedStorage.EventsNFunctions.REvents.UseAbility (RemoteEvent)
	- Player.PlayerValues.EquippedAbility (StringValue)
	- Player.Abilities[abilityName] (BoolValue)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local modulesFolder = ReplicatedStorage:WaitForChild("Modules")
local abilitiesDatabase = require(modulesFolder:WaitForChild("Abilities_DB"))

local remotes = ReplicatedStorage
	:WaitForChild("EventsNFunctions")
	:WaitForChild("REvents")
local useAbilityEvent = remotes:WaitForChild("UseAbility") :: RemoteEvent

local STORED_TOOLS_FOLDER_NAME = "StoredTools"
local SHADOW_DASH_DURATION = 5
local SPEED_BOOST_DURATION = 5
local SHADOW_SPEED_BONUS = 15
local SPEED_BOOST_BONUS = 15
local DASH_EFFECT_DURATION = 0.8
local DASH_HORIZONTAL_SPEED = 100
local DASH_ANIMATION_ID = "rbxassetid://106890968822881"

type Cleanup = () -> ()
type EffectSetup = (addCleanup: (Cleanup) -> ()) -> ()
type AbilityHandler = (player: Player) -> boolean

local cooldowns: { [Player]: { [string]: number } } = {}
local activeEffects: { [Player]: Cleanup } = {}

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

local function logWarn(...: any)
	warn("[AbilityManager]", ...)
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
end

local function getCharacterAndHumanoid(player: Player): (Model?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid or humanoid.Health <= 0 then
		return character, nil
	end

	return character, humanoid
end

local function getBackpack(player: Player): Backpack?
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack and backpack:IsA("Backpack") then
		return backpack
	end

	local child = player:FindFirstChild("Backpack")
	if child and child:IsA("Backpack") then
		return child
	end

	return nil
end

-- Moves tools into a temporary folder while an ability is active. The returned
-- cleanup function restores them to the Backpack and re-equips previously equipped tools.
local function storeInventory(player: Player, originalCharacter: Model): Cleanup
	local existingStorage = player:FindFirstChild(STORED_TOOLS_FOLDER_NAME)
	local storage: Folder

	if existingStorage and existingStorage:IsA("Folder") then
		storage = existingStorage
	else
		storage = Instance.new("Folder")
		storage.Name = STORED_TOOLS_FOLDER_NAME
		storage.Parent = player
	end

	local originallyEquipped: { [Tool]: boolean } = {}
	local backpack = getBackpack(player)

	if backpack then
		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") then
				child.Parent = storage
			end
		end
	end

	for _, child in originalCharacter:GetChildren() do
		if child:IsA("Tool") then
			originallyEquipped[child] = true
			child.Parent = storage
		end
	end

	local restored = false
	local delayedRestoreConnection: RBXScriptConnection? = nil

	local function restoreInto(targetBackpack: Backpack)
		if restored then
			return
		end
		restored = true

		for _, child in storage:GetChildren() do
			if child:IsA("Tool") then
				child.Parent = targetBackpack
			end
		end

		if player.Character == originalCharacter then
			local humanoid = originalCharacter:FindFirstChildOfClass("Humanoid") :: Humanoid?
			if humanoid and humanoid.Health > 0 then
				for tool in originallyEquipped do
					if tool.Parent == targetBackpack then
						humanoid:EquipTool(tool)
					end
				end
			end
		end

		if delayedRestoreConnection then
			delayedRestoreConnection:Disconnect()
			delayedRestoreConnection = nil
		end

		if storage.Parent then
			storage:Destroy()
		end
	end

	return function()
		if restored or not storage.Parent then
			return
		end

		local currentBackpack = getBackpack(player)
		if currentBackpack then
			restoreInto(currentBackpack)
			return
		end

		-- A Backpack can briefly be unavailable during a respawn. Keep the tools
		-- safely stored and restore them when the player's next character appears.
		if not delayedRestoreConnection and player.Parent == Players then
			delayedRestoreConnection = player.CharacterAdded:Connect(function()
				local newBackpack = getBackpack(player)
				if newBackpack then
					restoreInto(newBackpack)
				end
			end)
		end
	end
end

-- Runs a timed effect and guarantees cleanup on expiry, death, character removal,
-- or an error during setup. Only one timed ability effect may run per player at once.
local function beginTimedEffect(
	player: Player,
	character: Model,
	humanoid: Humanoid,
	duration: number,
	setup: EffectSetup
): boolean
	if activeEffects[player] then
		return false
	end

	local cleanupFunctions: { Cleanup } = {}
	local cleaned = false

	local function addCleanup(callback: Cleanup)
		table.insert(cleanupFunctions, callback)
	end

	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true

		if activeEffects[player] == cleanup then
			activeEffects[player] = nil
		end

		for index = #cleanupFunctions, 1, -1 do
			local ok, err = pcall(cleanupFunctions[index])
			if not ok then
				logWarn(`Effect cleanup failed for {player.Name}: {err}`)
			end
		end
		table.clear(cleanupFunctions)
	end

	activeEffects[player] = cleanup

	local diedConnection = humanoid.Died:Connect(cleanup)
	addCleanup(function()
		diedConnection:Disconnect()
	end)

	local removingConnection = player.CharacterRemoving:Connect(function(removingCharacter)
		if removingCharacter == character then
			cleanup()
		end
	end)
	addCleanup(function()
		removingConnection:Disconnect()
	end)

	local ok, err = pcall(setup, addCleanup)
	if not ok then
		cleanup()
		logWarn(`Could not start an ability for {player.Name}: {err}`)
		return false
	end

	task.delay(duration, cleanup)
	return true
end

--------------------------------------------------------------------------------
-- Ability implementations
--------------------------------------------------------------------------------

local function shadowDash(player: Player): boolean
	local character, humanoid = getCharacterAndHumanoid(player)
	if not character or not humanoid then
		return false
	end

	return beginTimedEffect(player, character, humanoid, SHADOW_DASH_DURATION, function(addCleanup)
		local originalSpeed = humanoid.WalkSpeed
		local boostedSpeed = originalSpeed + SHADOW_SPEED_BONUS
		humanoid.WalkSpeed = boostedSpeed

		addCleanup(function()
			if humanoid.Parent and humanoid.WalkSpeed == boostedSpeed then
				humanoid.WalkSpeed = originalSpeed
			end
		end)

		local previousInvincible = humanoid:GetAttribute("Invincible")
		humanoid:SetAttribute("Invincible", true)

		addCleanup(function()
			if humanoid.Parent then
				humanoid:SetAttribute("Invincible", previousInvincible)
			end
		end)

		addCleanup(storeInventory(player, character))

		local originalTransparency: { [Instance]: number } = {}
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
				originalTransparency[descendant] = descendant.Transparency
				descendant.Transparency = math.max(descendant.Transparency, 0.325)
			elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
				originalTransparency[descendant] = descendant.Transparency
				descendant.Transparency = math.max(descendant.Transparency, 0.325)
			end
		end

		addCleanup(function()
			for instance, transparency in originalTransparency do
				if instance.Parent then
					if instance:IsA("BasePart") or instance:IsA("Decal") or instance:IsA("Texture") then
						instance.Transparency = transparency
					end
				end
			end
			table.clear(originalTransparency)
		end)
	end)
end

local function speedBoost(player: Player): boolean
	local character, humanoid = getCharacterAndHumanoid(player)
	if not character or not humanoid then
		return false
	end

	return beginTimedEffect(player, character, humanoid, SPEED_BOOST_DURATION, function(addCleanup)
		local originalSpeed = humanoid.WalkSpeed
		local boostedSpeed = originalSpeed + SPEED_BOOST_BONUS
		humanoid.WalkSpeed = boostedSpeed

		addCleanup(function()
			if humanoid.Parent and humanoid.WalkSpeed == boostedSpeed then
				humanoid.WalkSpeed = originalSpeed
			end
		end)
	end)
end

local function dash(player: Player): boolean
	local character, humanoid = getCharacterAndHumanoid(player)
	if not character or not humanoid then
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return false
	end

	return beginTimedEffect(player, character, humanoid, DASH_EFFECT_DURATION, function(addCleanup)
		-- Animation
		local animatorInstance = humanoid:FindFirstChildOfClass("Animator")
		local animator: Animator
		if animatorInstance and animatorInstance:IsA("Animator") then
			animator = animatorInstance
		else
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end

		local animation = Instance.new("Animation")
		animation.AnimationId = DASH_ANIMATION_ID

		local animationTrack: AnimationTrack? = nil
		local animationLoaded, animationError = pcall(function()
			animationTrack = animator:LoadAnimation(animation)
		end)

		if animationLoaded and animationTrack then
			animationTrack.Priority = Enum.AnimationPriority.Action
			animationTrack:Play(0)
		end

		addCleanup(function()
			if animationTrack then
				animationTrack:Stop(0.1)
				animationTrack:Destroy()
			end
			animation:Destroy()
		end)

		if not animationLoaded then
			logWarn(`Dash animation could not load: {animationError}`)
		end

		-- Trail
		local attachment0 = Instance.new("Attachment")
		attachment0.Name = "DashTrailAttachment0"
		attachment0.Position = Vector3.new(0, 0, -1.5)
		attachment0.Parent = rootPart

		local attachment1 = Instance.new("Attachment")
		attachment1.Name = "DashTrailAttachment1"
		attachment1.Position = Vector3.new(0, 0, 1.5)
		attachment1.Parent = rootPart

		local trail = Instance.new("Trail")
		trail.Name = "DashTrail"
		trail.Attachment0 = attachment0
		trail.Attachment1 = attachment1
		trail.Color = ColorSequence.new(
			Color3.fromRGB(255, 255, 255),
			Color3.fromRGB(182, 182, 182)
		)
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Lifetime = 0.2
		trail.MinLength = 0.1
		trail.Enabled = true
		trail.Parent = rootPart

		addCleanup(function()
			trail:Destroy()
			attachment0:Destroy()
			attachment1:Destroy()
		end)

		-- Dash impulse. Preserve vertical velocity so jumping/falling is not cancelled.
		local direction = rootPart.CFrame.LookVector
		local currentVelocity = rootPart.AssemblyLinearVelocity
		rootPart.AssemblyLinearVelocity = Vector3.new(
			direction.X * DASH_HORIZONTAL_SPEED,
			currentVelocity.Y,
			direction.Z * DASH_HORIZONTAL_SPEED
		)

		-- Smoke burst
		local particle = Instance.new("ParticleEmitter")
		particle.Name = "DashSmoke"
		particle.Texture = "rbxassetid://243660364"
		particle.Rate = 0
		particle.Speed = NumberRange.new(20, 40)
		particle.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2),
			NumberSequenceKeypoint.new(1, 0),
		})
		particle.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		particle.Lifetime = NumberRange.new(0.4, 0.6)
		particle.Rotation = NumberRange.new(0, 360)
		particle.RotSpeed = NumberRange.new(-200, 200)
		particle.EmissionDirection = Enum.NormalId.Back
		particle.Parent = rootPart
		particle:Emit(15)
		Debris:AddItem(particle, 1)
	end)
end

local abilityHandlers: { [string]: AbilityHandler } = {
	["Shadow Dash"] = shadowDash,
	["Speed Boost"] = speedBoost,
	Dash = dash,
}

--------------------------------------------------------------------------------
-- Remote handling
--------------------------------------------------------------------------------

useAbilityEvent.OnServerEvent:Connect(function(player: Player)
	if player.Parent ~= Players
		or player:GetAttribute("PlayerDataLoaded") ~= true
		or activeEffects[player] then
		return
	end

	local playerValues = player:FindFirstChild("PlayerValues")
	local equippedValue = playerValues and playerValues:FindFirstChild("EquippedAbility")
	if not equippedValue or not equippedValue:IsA("StringValue") then
		return
	end

	local abilityName = equippedValue.Value
	if abilityName == "" or abilityName == "None" then
		return
	end

	-- Verify ownership on the server. Never trust a client-supplied ability name.
	local abilitiesFolder = player:FindFirstChild("Abilities")
	local ownedValue = abilitiesFolder and abilitiesFolder:FindFirstChild(abilityName)
	if not ownedValue or not ownedValue:IsA("BoolValue") or not ownedValue.Value then
		return
	end

	local handler = abilityHandlers[abilityName]
	if not handler then
		logWarn(`No implementation exists for equipped ability "{abilityName}"`)
		return
	end

	local configuration = abilitiesDatabase[abilityName]
	if type(configuration) ~= "table" then
		logWarn(`Abilities_DB has no configuration for "{abilityName}"`)
		return
	end

	local cooldownDuration = configuration.Cooldown
	if not isFiniteNumber(cooldownDuration) or cooldownDuration < 0 then
		logWarn(`Invalid cooldown for ability "{abilityName}"`)
		return
	end

	local now = os.clock()
	local playerCooldowns = cooldowns[player]
	if not playerCooldowns then
		playerCooldowns = {}
		cooldowns[player] = playerCooldowns
	end

	local cooldownEndsAt = playerCooldowns[abilityName]
	if cooldownEndsAt and cooldownEndsAt > now then
		return
	end

	local ok, activated = pcall(handler, player)
	if not ok then
		logWarn(`Ability "{abilityName}" failed for {player.Name}: {activated}`)
		return
	end

	if activated then
		playerCooldowns[abilityName] = now + cooldownDuration
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	local cleanup = activeEffects[player]
	if cleanup then
		cleanup()
	end

	cooldowns[player] = nil
	activeEffects[player] = nil
end)
