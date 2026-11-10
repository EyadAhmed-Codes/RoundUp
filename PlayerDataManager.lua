--[[
	PlayerDataManager
	Server Script - ServerScriptService

	Responsibilities:
	- Create the Value objects used by the game.
	- Load player data without overwriting existing data after a failed load.
	- Save currencies, equipped ability, and owned abilities.
	- Save safely when a player leaves or the server shuts down.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local abilitiesDatabase = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Abilities_DB"))

local DATASTORE_NAME = "PlayerDatastore_V1.0"
local MAX_LOAD_ATTEMPTS = 3
local LOAD_RETRY_DELAY = 2
local SHUTDOWN_SAVE_TIMEOUT = 25

local playerDataStore = DataStoreService:GetDataStore(DATASTORE_NAME)

local initializedPlayers: { [Player]: boolean } = {}
local loadedPlayers: { [Player]: boolean } = {}
local savingPlayers: { [Player]: boolean } = {}

--------------------------------------------------------------------------------
-- Value creation
--------------------------------------------------------------------------------

local function logWarn(...: any)
	warn("[PlayerDataManager]", ...)
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureIntValue(parent: Instance, name: string, defaultValue: number): IntValue
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("IntValue") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local value = Instance.new("IntValue")
	value.Name = name
	value.Value = defaultValue
	value.Parent = parent
	return value
end

local function ensureBoolValue(parent: Instance, name: string, defaultValue: boolean): BoolValue
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("BoolValue") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local value = Instance.new("BoolValue")
	value.Name = name
	value.Value = defaultValue
	value.Parent = parent
	return value
end

local function ensureStringValue(parent: Instance, name: string, defaultValue: string): StringValue
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("StringValue") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local value = Instance.new("StringValue")
	value.Name = name
	value.Value = defaultValue
	value.Parent = parent
	return value
end

local function createPlayerData(player: Player)
	local playerValues = ensureFolder(player, "PlayerValues")
	ensureBoolValue(playerValues, "PlayerInGame", false)
	ensureIntValue(playerValues, "RLives", 0)
	ensureStringValue(playerValues, "EquippedAbility", "None")

	local leaderstats = ensureFolder(player, "leaderstats")
	ensureIntValue(leaderstats, "UpCoins", 0)
	ensureIntValue(leaderstats, "Tokens", 0)

	local abilitiesFolder = ensureFolder(player, "Abilities")
	for abilityName in abilitiesDatabase do
		if type(abilityName) == "string" then
			ensureBoolValue(abilitiesFolder, abilityName, false)
		end
	end
end

--------------------------------------------------------------------------------
-- Data validation and loading
--------------------------------------------------------------------------------

local function normalizeCurrency(value: any): number
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end

	return math.max(0, math.floor(value))
end

local function applyLoadedData(player: Player, data: any): boolean
	if type(data) ~= "table" then
		data = {}
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	local playerValues = player:FindFirstChild("PlayerValues")
	local abilitiesFolder = player:FindFirstChild("Abilities")

	if not leaderstats or not playerValues or not abilitiesFolder then
		logWarn(`Player data containers disappeared while loading {player.Name}`)
		return false
	end

	local upCoins = leaderstats:FindFirstChild("UpCoins")
	local tokens = leaderstats:FindFirstChild("Tokens")
	local equippedAbility = playerValues:FindFirstChild("EquippedAbility")

	if upCoins and upCoins:IsA("IntValue") then
		upCoins.Value = normalizeCurrency(data.UpCoins)
	end
	if tokens and tokens:IsA("IntValue") then
		tokens.Value = normalizeCurrency(data.Tokens)
	end

	local savedAbilities = data.Abilities
	if type(savedAbilities) == "table" then
		for _, abilityValue in abilitiesFolder:GetChildren() do
			if abilityValue:IsA("BoolValue") then
				abilityValue.Value = savedAbilities[abilityValue.Name] == true
			end
		end
	end

	if equippedAbility and equippedAbility:IsA("StringValue") then
		local savedEquipped = data.EquippedAbility
		if savedEquipped == "None" then
			equippedAbility.Value = "None"
		elseif typeof(savedEquipped) == "string" then
			local ownedValue = abilitiesFolder:FindFirstChild(savedEquipped)
			if ownedValue and ownedValue:IsA("BoolValue") and ownedValue.Value then
				equippedAbility.Value = savedEquipped
			else
				equippedAbility.Value = "None"
			end
		else
			equippedAbility.Value = "None"
		end
	end

	return true
end

local function loadData(player: Player): boolean
	local key = tostring(player.UserId)

	for attempt = 1, MAX_LOAD_ATTEMPTS do
		local success, data = pcall(function()
			return playerDataStore:GetAsync(key)
		end)

		if success then
			if player.Parent == Players then
				return applyLoadedData(player, data)
			end
			return false
		end

		logWarn(`Load attempt {attempt}/{MAX_LOAD_ATTEMPTS} failed for {player.Name}: {data}`)
		if attempt < MAX_LOAD_ATTEMPTS then
			task.wait(LOAD_RETRY_DELAY * attempt)
		end
	end

	-- Do not save default values when loading failed. Doing so could overwrite
	-- a player's existing DataStore record with zeros and empty ownership.
	return false
end

--------------------------------------------------------------------------------
-- Data saving
--------------------------------------------------------------------------------

local function buildSaveSnapshot(player: Player): { [string]: any }
	local data: { [string]: any } = {
		UpCoins = 0,
		Tokens = 0,
		EquippedAbility = "None",
		Abilities = {},
	}

	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local upCoins = leaderstats:FindFirstChild("UpCoins")
		local tokens = leaderstats:FindFirstChild("Tokens")

		if upCoins and upCoins:IsA("IntValue") then
			data.UpCoins = normalizeCurrency(upCoins.Value)
		end
		if tokens and tokens:IsA("IntValue") then
			data.Tokens = normalizeCurrency(tokens.Value)
		end
	end

	local playerValues = player:FindFirstChild("PlayerValues")
	if playerValues then
		local equippedAbility = playerValues:FindFirstChild("EquippedAbility")
		if equippedAbility and equippedAbility:IsA("StringValue") then
			data.EquippedAbility = equippedAbility.Value
		end
	end

	local abilitiesFolder = player:FindFirstChild("Abilities")
	if abilitiesFolder then
		for _, abilityValue in abilitiesFolder:GetChildren() do
			if abilityValue:IsA("BoolValue") then
				data.Abilities[abilityValue.Name] = abilityValue.Value
			end
		end
	end

	return data
end

local function saveData(player: Player): boolean
	if not loadedPlayers[player] then
		-- A failed or unfinished load must never be followed by a default-data save.
		return false
	end

	if savingPlayers[player] then
		local deadline = os.clock() + 20
		while savingPlayers[player] and os.clock() < deadline do
			task.wait(0.1)
		end
		return not savingPlayers[player]
	end

	savingPlayers[player] = true
	local snapshot = buildSaveSnapshot(player)
	local key = tostring(player.UserId)

	local success, err = pcall(function()
		playerDataStore:UpdateAsync(key, function(previousData)
			local updatedData: { [string]: any }
			if type(previousData) == "table" then
				updatedData = table.clone(previousData)
			else
				updatedData = {}
			end

			-- Preserve unrelated fields that may be added by future systems.
			updatedData.UpCoins = snapshot.UpCoins
			updatedData.Tokens = snapshot.Tokens
			updatedData.EquippedAbility = snapshot.EquippedAbility
			updatedData.Abilities = snapshot.Abilities

			return updatedData
		end)
	end)

	savingPlayers[player] = nil

	if not success then
		logWarn(`Failed to save data for {player.Name}: {err}`)
		return false
	end

	return true
end

--------------------------------------------------------------------------------
-- Player lifecycle
--------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if initializedPlayers[player] then
		return
	end
	initializedPlayers[player] = true

	player:SetAttribute("PlayerDataLoaded", false)
	createPlayerData(player)
	local dataLoaded = loadData(player)
	if player.Parent ~= Players then
		return
	end

	loadedPlayers[player] = dataLoaded
	player:SetAttribute("PlayerDataLoaded", dataLoaded)
	if dataLoaded then
		print(`[PlayerDataManager] Loaded data for {player.Name}`)
	else
		logWarn(`Data for {player.Name} could not be loaded; this session will not be saved`)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)

-- Also handle players who joined before this script connected.
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	saveData(player)
	loadedPlayers[player] = nil
	initializedPlayers[player] = nil
end)

game:BindToClose(function()
	local currentPlayers = Players:GetPlayers()
	local pendingSaves = #currentPlayers

	for _, player in currentPlayers do
		task.spawn(function()
			saveData(player)
			pendingSaves -= 1
		end)
	end

	local deadline = os.clock() + SHUTDOWN_SAVE_TIMEOUT
	while pendingSaves > 0 and os.clock() < deadline do
		task.wait(0.1)
	end

	if pendingSaves > 0 then
		logWarn(`Server shutdown reached the save timeout with {pendingSaves} save(s) unfinished`)
	end
end)
