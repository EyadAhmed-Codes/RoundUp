--[[
	RemoteHandler
	Location: ServerScriptService

	Responsibilities:
	- Process player deaths on the server and decrement round lives once per Humanoid.
	- Restore the minigame timer UI after a participant respawns.
	- Validate ability purchases and equipped-ability changes.

	PlayerDied remains as a backwards-compatible notification RemoteEvent. It is only
	accepted as a death notification when the server already sees the Humanoid as dead.
	The server-side Humanoid.Died connection is the primary source of truth.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local minigamesFolder = ReplicatedStorage:WaitForChild("Minigames")
local matchValues = ReplicatedStorage:WaitForChild("MValues")
local currentMinigameValue = matchValues:WaitForChild("CurrentMinigame") :: StringValue
local minigameStartTimeValue = matchValues:WaitForChild("MinigameSysTime") :: IntValue

local remotes = ReplicatedStorage
	:WaitForChild("EventsNFunctions")
	:WaitForChild("REvents")
local playerDiedEvent = remotes:WaitForChild("PlayerDied") :: RemoteEvent
local buyAbilityEvent = remotes:WaitForChild("BuyAbility") :: RemoteEvent
local changeEquippedAbilityEvent = remotes:WaitForChild("ChangeEquippedAbility") :: RemoteEvent
local updateTimerUiEvent = remotes:WaitForChild("UpdateUUI") :: RemoteEvent

local abilitiesDatabase = require(
	ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Abilities_DB")
)

local TEAM_LOBBY_NAME = "Lobby"
local MAX_ABILITY_NAME_LENGTH = 64

local characterConnections: { [Player]: RBXScriptConnection } = {}
local attachedCharacters = setmetatable({}, { __mode = "k" }) :: { [Model]: boolean }
local processedDeaths = setmetatable({}, { __mode = "k" }) :: { [Humanoid]: boolean }

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

local function logWarn(...: any)
	warn("[RemoteHandler]", ...)
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
end

local function getPlayerValue(player: Player, folderName: string, valueName: string): Instance?
	local folder = player:FindFirstChild(folderName)
	return folder and folder:FindFirstChild(valueName)
end

local function getMinigameConfiguration(): any?
	local minigameName = currentMinigameValue.Value
	if minigameName == "" then
		return nil
	end

	local moduleScript = minigamesFolder:FindFirstChild(minigameName)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		logWarn(`Could not find minigame module "{minigameName}"`)
		return nil
	end

	local ok, configuration = pcall(require, moduleScript)
	if not ok then
		logWarn(`Could not load minigame "{minigameName}" for the timer UI: {configuration}`)
		return nil
	end

	if type(configuration) ~= "table"
		or type(configuration.Name) ~= "string"
		or not isFiniteNumber(configuration.Duration)
		or type(configuration.PMode) ~= "string" then
		logWarn(`Minigame "{minigameName}" has incomplete timer UI configuration`)
		return nil
	end

	return configuration
end

local function sendTimerUi(player: Player)
	if player.Parent ~= Players then
		return
	end

	local inGameValue = getPlayerValue(player, "PlayerValues", "PlayerInGame")
	if not inGameValue or not inGameValue:IsA("BoolValue") or not inGameValue.Value then
		return
	end

	local configuration = getMinigameConfiguration()
	if not configuration then
		return
	end

	updateTimerUiEvent:FireClient(
		player,
		true,
		configuration.Name,
		minigameStartTimeValue.Value,
		configuration.Duration,
		configuration.PMode
	)
end

--------------------------------------------------------------------------------
-- Death and respawn handling
--------------------------------------------------------------------------------

local function processPlayerDeath(player: Player, humanoid: Humanoid)
	if processedDeaths[humanoid] then
		return
	end
	processedDeaths[humanoid] = true

	if player.Parent ~= Players then
		return
	end

	local inGameValue = getPlayerValue(player, "PlayerValues", "PlayerInGame")
	local livesValue = getPlayerValue(player, "PlayerValues", "RLives")

	if not inGameValue or not inGameValue:IsA("BoolValue") or not inGameValue.Value then
		return
	end
	if not livesValue or not livesValue:IsA("IntValue") then
		logWarn(`{player.Name} has no valid PlayerValues.RLives IntValue`)
		return
	end

	if livesValue.Value <= 0 then
		return
	end

	livesValue.Value = math.max(0, livesValue.Value - 1)
	print(`-GamePlay: {player.Name} has {livesValue.Value} live(s) left.`)

	if livesValue.Value == 0 then
		local lobbyTeam = Teams:FindFirstChild("Lobby")
		if lobbyTeam and lobbyTeam:IsA("Team") then
			player.Team = lobbyTeam
		else
			logWarn(`Team "{TEAM_LOBBY_NAME}" is missing; {player.Name} was not moved to the lobby team`)
		end

		inGameValue.Value = false
	end
end

local function attachDeathListener(player: Player, character: Model)
	if attachedCharacters[character] then
		return
	end
	attachedCharacters[character] = true

	local humanoidInstance = character:WaitForChild("Humanoid", 10)
	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		logWarn(`Could not find a Humanoid for {player.Name}'s character`)
		return
	end

	local humanoid = humanoidInstance :: Humanoid
	humanoid.Died:Connect(function()
		processPlayerDeath(player, humanoid)
	end)

	-- CharacterAdded happens when Roblox has created the new character. Delay the
	-- timer update slightly so the respawned PlayerGui has time to initialize.
	task.delay(math.max(0, Players.RespawnTime) + 1, function()
		sendTimerUi(player)

		-- Some clients recreate their ScreenGui shortly after CharacterAdded.
		-- Retry only when the expected UI has not appeared on the server yet.
		if player.Parent ~= Players then
			return
		end

		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		local mainUi = playerGui and playerGui:FindFirstChild("MainMiniGameUI")
		local upperUi = mainUi and mainUi:FindFirstChild("UpperUI")
		if not upperUi then
			task.delay(3, function()
				sendTimerUi(player)
			end)
		end
	end)
end

local function setupPlayer(player: Player)
	if characterConnections[player] then
		return
	end

	characterConnections[player] = player.CharacterAdded:Connect(function(character)
		task.spawn(attachDeathListener, player, character)
	end)

	if player.Character then
		task.spawn(attachDeathListener, player, player.Character)
	end
end

Players.PlayerAdded:Connect(setupPlayer)

for _, player in Players:GetPlayers() do
	setupPlayer(player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	local connection = characterConnections[player]
	if connection then
		connection:Disconnect()
		characterConnections[player] = nil
	end
end)

-- Backwards compatibility: older client scripts may still fire this event after
-- dying. A living character can never lose a life by firing the RemoteEvent.
playerDiedEvent.OnServerEvent:Connect(function(player: Player)
	local character = player.Character
	local humanoid: Humanoid? = nil
	if character then
		humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	end

	if humanoid and humanoid.Health <= 0 then
		processPlayerDeath(player, humanoid)
	end
end)

--------------------------------------------------------------------------------
-- Ability purchases
--------------------------------------------------------------------------------

buyAbilityEvent.OnServerEvent:Connect(function(player: Player, abilityName: any)
	if player:GetAttribute("PlayerDataLoaded") ~= true then
		return
	end

	if typeof(abilityName) ~= "string"
		or abilityName == ""
		or #abilityName > MAX_ABILITY_NAME_LENGTH then
		return
	end

	local configuration = abilitiesDatabase[abilityName]
	if type(configuration) ~= "table" then
		return
	end

	local price = configuration.Price
	if not isFiniteNumber(price) or price < 0 or price % 1 ~= 0 then
		logWarn(`Invalid price for ability "{abilityName}"`)
		return
	end

	local abilitiesFolder = player:FindFirstChild("Abilities")
	local ownedValue = abilitiesFolder and abilitiesFolder:FindFirstChild(abilityName)
	if not ownedValue or not ownedValue:IsA("BoolValue") or ownedValue.Value then
		return
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	local tokensValue = leaderstats and leaderstats:FindFirstChild("Tokens")
	if not tokensValue or not tokensValue:IsA("IntValue") then
		return
	end

	if tokensValue.Value < price then
		return
	end

	-- No yielding occurs between the balance check and these two assignments.
	tokensValue.Value -= price
	ownedValue.Value = true
end)

--------------------------------------------------------------------------------
-- Equipped ability changes
--------------------------------------------------------------------------------

changeEquippedAbilityEvent.OnServerEvent:Connect(function(player: Player, requestedAbility: any)
	if player:GetAttribute("PlayerDataLoaded") ~= true or currentMinigameValue.Value ~= "" then
		return
	end

	if typeof(requestedAbility) ~= "string"
		or requestedAbility == ""
		or #requestedAbility > MAX_ABILITY_NAME_LENGTH then
		return
	end

	local equippedValue = getPlayerValue(player, "PlayerValues", "EquippedAbility")
	if not equippedValue or not equippedValue:IsA("StringValue") then
		return
	end

	if requestedAbility == "None" then
		equippedValue.Value = "None"
		return
	end

	if type(abilitiesDatabase[requestedAbility]) ~= "table" then
		return
	end

	local abilitiesFolder = player:FindFirstChild("Abilities")
	local ownedValue = abilitiesFolder and abilitiesFolder:FindFirstChild(requestedAbility)
	if not ownedValue or not ownedValue:IsA("BoolValue") or not ownedValue.Value then
		return
	end

	equippedValue.Value = requestedAbility
end)
