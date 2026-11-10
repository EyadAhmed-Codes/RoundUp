--[[
	MinigameController
	Script - ServerScriptService

	Server-side game loop for the lobby. Every round plays each minigame once, in
	random order:

	  wait for players -> intermission -> pick a minigame -> load map -> build teams
	  -> spawn players -> run until the timer ends (or one player is left) -> tear down

	Minigames are ModuleScripts under ReplicatedStorage.Minigames that return a table
	matching the `Minigame` type below, so adding a game never touches this script.

	Instances this script expects
	  ReplicatedStorage  Minigames/                 one ModuleScript per minigame
	                     MValues/                   CurrentMinigame (StringValue), MinigameSysTime (IntValue)
	                     EventsNFunctions/REvents/  SendIntermissionData, FSendStart, UpdateUUI (RemoteEvents)
	  ServerStorage      Maps/                      "<Name>" or "<Name><index>" for each minigame
	                     Teams/                     parking spot for whichever teams are inactive
	  Teams              Lobby, plus In-Game (FFA) or Blue + Red (TDM) while a game is active
	  Each Player        PlayerValues/              RLives, PlayerInGame (+ Points during a game)
	                     PlayerGui/GameUI/WaitingForPlayers
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

-- "FFA" puts everyone on the In-Game team; any other mode splits players across Blue and Red.
type PlayerMode = "FFA" | "TDM"

-- The contract every minigame ModuleScript must fulfil.
type Minigame = {
	Name: string,
	Duration: number, -- seconds
	PlayersLives: number, -- written to each player's PlayerValues.RLives
	PlayerSpeed: number, -- Humanoid.WalkSpeed for the duration of the game
	PMode: PlayerMode,
	HasMap: boolean,
	NumberOfMaps: number?, -- maps are named "<Name>" for one map, "<Name><index>" for several
	PointVariableType: string?, -- "IntValue" gives every player a Points counter
	Start: () -> (),
	End: () -> (),
}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local MIN_PLAYERS = 1 -- players needed before a round starts
local INTERMISSION_SECONDS = 30
local JOIN_GRACE_SECONDS = 3 -- lets freshly joined clients finish loading before we fire remotes

-- Usernames allowed to start a round alone (solo testing).
local SOLO_TESTERS: { [string]: boolean } = {
	eyado2122_1 = true,
}

-- Pacing of the loading screen and of the hand-off back to the lobby.
local MAP_STREAM_SECONDS = 3 -- time for clients to stream the map in
local SPAWN_SETTLE_SECONDS = 2
local CHARACTER_SETTLE_SECONDS = 1
local POST_GAME_SECONDS = 3
local LOBBY_RETURN_SECONDS = 1

-- Safety nets, so one broken asset or slow client can never hang the loop.
local SPAWN_LOCATION_TIMEOUT = 10
local PLAYER_VALUE_TIMEOUT = 5
local GAME_UI_TIMEOUT = 10
local RESPAWN_TIMEOUT = 15
local NO_MINIGAMES_RETRY_SECONDS = 10
local CRASH_RECOVERY_SECONDS = 5

local TEAM_LOBBY = "Lobby"
local TEAM_IN_GAME = "In-Game"
local TEAM_BLUE = "Blue"
local TEAM_RED = "Red"
local POINTS_VALUE_NAME = "Points"

-- Every field a minigame module has to provide, and its type.
local REQUIRED_FIELDS: { [string]: string } = {
	Name = "string",
	Duration = "number",
	PlayersLives = "number",
	PlayerSpeed = "number",
	Start = "function",
	End = "function",
}

--------------------------------------------------------------------------------
-- Shared instances
--------------------------------------------------------------------------------

local minigamesFolder = ReplicatedStorage:WaitForChild("Minigames")
local remotes = ReplicatedStorage:WaitForChild("EventsNFunctions"):WaitForChild("REvents")
local intermissionDataEvent = remotes:WaitForChild("SendIntermissionData") :: RemoteEvent
local startEvent = remotes:WaitForChild("FSendStart") :: RemoteEvent
local timerUiEvent = remotes:WaitForChild("UpdateUUI") :: RemoteEvent

local matchValues = ReplicatedStorage:WaitForChild("MValues")
local currentMinigameValue = matchValues:WaitForChild("CurrentMinigame") :: StringValue
local minigameStartTimeValue = matchValues:WaitForChild("MinigameSysTime") :: IntValue

local mapStorage = ServerStorage:WaitForChild("Maps")
local teamStorage = ServerStorage:WaitForChild("Teams")
local lobbyTeam = Teams:WaitForChild(TEAM_LOBBY) :: Team

local rng = Random.new()

--------------------------------------------------------------------------------
-- Logging & small utilities
--------------------------------------------------------------------------------

local function log(...: any)
	print("[MGC]", ...)
end

local function logWarn(...: any)
	warn("[MGC]", ...)
end

-- Runs `callback` without letting an error escape; the traceback is logged instead.
local function runProtected(label: string, callback: () -> ())
	local ok, err = pcall(callback)
	if not ok then
		logWarn(`{label} failed:\n{err}`)
	end
end

-- WaitForChild with a timeout, normalised to always return `Instance?`.
local function waitFor(parent: Instance, name: string, timeout: number): Instance?
	return parent:WaitForChild(name, timeout)
end

local function waitForHumanoid(character: Model, timeout: number): Humanoid?
	local humanoid = waitFor(character, "Humanoid", timeout)
	if humanoid and humanoid:IsA("Humanoid") then
		return humanoid
	end
	return nil
end

--------------------------------------------------------------------------------
-- Player helpers
--------------------------------------------------------------------------------

local function isConnected(player: Player): boolean
	return player.Parent == Players
end

local function findPlayerValue(player: Player, name: string): Instance?
	local container = player:FindFirstChild("PlayerValues")
	return container and container:FindFirstChild(name)
end

local function setInGame(player: Player, isInGame: boolean)
	local flag = findPlayerValue(player, "PlayerInGame") :: BoolValue?
	if flag then
		flag.Value = isInGame
	end
end

local function countPlayersInGame(): number
	local count = 0
	for _, player in Players:GetPlayers() do
		local flag = findPlayerValue(player, "PlayerInGame") :: BoolValue?
		if flag and flag.Value then
			count += 1
		end
	end
	return count
end

-- Respawns the given players in parallel and waits (bounded) for their characters to load.
local function respawnPlayers(players: { Player })
	local pending = 0
	for _, player in players do
		if isConnected(player) then
			pending += 1
			task.spawn(function()
				local ok, err = pcall(function()
					player:LoadCharacterAsync()
				end)
				if not ok then
					logWarn(`Could not respawn {player.Name}: {err}`)
				end
				pending -= 1
			end)
		end
	end

	local deadline = os.clock() + RESPAWN_TIMEOUT
	while pending > 0 and os.clock() < deadline do
		task.wait()
	end
end

-- Resets a player's per-game state once their character exists.
local function preparePlayer(player: Player, minigame: Minigame)
	local values = waitFor(player, "PlayerValues", PLAYER_VALUE_TIMEOUT)
	if values then
		local lives = waitFor(values, "RLives", PLAYER_VALUE_TIMEOUT) :: IntValue?
		local inGame = waitFor(values, "PlayerInGame", PLAYER_VALUE_TIMEOUT) :: BoolValue?
		if lives then
			lives.Value = minigame.PlayersLives
		end
		if inGame then
			inGame.Value = true
		end
	else
		logWarn(`{player.Name} has no PlayerValues; lives and in-game flag not set`)
	end

	local character = player.Character
	local humanoid = if character then waitForHumanoid(character, PLAYER_VALUE_TIMEOUT) else nil
	if humanoid then
		humanoid.WalkSpeed = minigame.PlayerSpeed
	end
end

local function createPointCounters(players: { Player })
	for _, player in players do
		local values = player:FindFirstChild("PlayerValues")
		if values and isConnected(player) then
			local points = Instance.new("IntValue")
			points.Name = POINTS_VALUE_NAME
			points.Value = 0
			points.Parent = values
		end
	end
end

local function removePointCounters()
	for _, player in Players:GetPlayers() do
		local points = findPlayerValue(player, POINTS_VALUE_NAME)
		if points then
			points:Destroy()
		end
	end
end

--------------------------------------------------------------------------------
-- Teams
--------------------------------------------------------------------------------

local OPTIONAL_TEAMS = { TEAM_IN_GAME, TEAM_BLUE, TEAM_RED }

local function findTeam(name: string): Team?
	local team = Teams:FindFirstChild(name)
	if team and team:IsA("Team") then
		return team
	end
	return nil
end

-- Only the Lobby team is permanent. The others live in Teams while they are in use and are
-- parked in ServerStorage.Teams otherwise, so only the teams for the current mode exist.
-- Returns true if any team had to be moved.
local function activateTeams(activeNames: { string }): boolean
	local changed = false
	for _, name in OPTIONAL_TEAMS do
		local team = Teams:FindFirstChild(name) or teamStorage:FindFirstChild(name)
		if team then
			local destination: Instance = if table.find(activeNames, name) then Teams else teamStorage
			if team.Parent ~= destination then
				team.Parent = destination
				changed = true
			end
		else
			logWarn(`Team "{name}" is missing from both Teams and ServerStorage.Teams`)
		end
	end
	return changed
end

-- Legacy workaround (originally labelled "smol reset"): re-parenting the Lobby team kicks
-- Roblox's team bookkeeping. Kept as-is because the game depends on it.
local function refreshLobbyTeam()
	lobbyTeam.Parent = Workspace
	lobbyTeam.Parent = Teams
end

-- Shuffles the players and alternates them between the two teams, so sizes differ by at
-- most one. A coin flip decides which team gets the extra player.
local function assignBalancedTeams(players: { Player }, teamA: Team, teamB: Team)
	local shuffled = table.clone(players)
	for i = #shuffled, 2, -1 do
		local j = rng:NextInteger(1, i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	if rng:NextInteger(0, 1) == 1 then
		teamA, teamB = teamB, teamA
	end
	for index, player in shuffled do
		player.Team = if index % 2 == 1 then teamA else teamB
	end
end

local function assignTeams(minigame: Minigame, players: { Player })
	if minigame.PMode == "FFA" then
		activateTeams({ TEAM_IN_GAME })
		local inGameTeam = findTeam(TEAM_IN_GAME)
		for _, player in players do
			player.Team = inGameTeam
		end
	else
		activateTeams({ TEAM_BLUE, TEAM_RED })
		local blue, red = findTeam(TEAM_BLUE), findTeam(TEAM_RED)
		if blue and red then
			assignBalancedTeams(players, blue, red)
		else
			logWarn("Blue/Red teams are unavailable; players were not assigned")
		end
	end
end

--------------------------------------------------------------------------------
-- Waiting for players
--------------------------------------------------------------------------------

local function setWaitingScreenVisible(player: Player, visible: boolean)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end

	local gameUi = waitFor(playerGui, "GameUI", GAME_UI_TIMEOUT)
	local waitingFrame = if gameUi then gameUi:FindFirstChild("WaitingForPlayers") else nil
	if waitingFrame and waitingFrame:IsA("GuiObject") then
		waitingFrame.Visible = visible
	end
end

-- Blocks until a round may start: enough players are present, or a solo tester is alone.
local function waitForPlayers()
	local hadToWait = false

	while #Players:GetPlayers() == 0 do
		hadToWait = true
		Players.PlayerAdded:Wait()
	end

	local players = Players:GetPlayers()
	local lonePlayer = if #players == 1 then players[1] else nil
	if lonePlayer and not SOLO_TESTERS[lonePlayer.Name] then
		log("Only one player in the server, waiting for more")
		setWaitingScreenVisible(lonePlayer, true)
		while #Players:GetPlayers() < MIN_PLAYERS do
			hadToWait = true
			Players.PlayerAdded:Wait()
		end
		setWaitingScreenVisible(lonePlayer, false)
		log("Enough players, continuing")
	end

	if hadToWait then
		task.wait(JOIN_GRACE_SECONDS)
	end
end

local function runIntermission()
	intermissionDataEvent:FireAllClients("Intermission", os.time(), INTERMISSION_SECONDS)
	task.wait(INTERMISSION_SECONDS)
end

--------------------------------------------------------------------------------
-- Minigame discovery
--------------------------------------------------------------------------------

-- Returns a human-readable problem, or nil if `candidate` satisfies the Minigame contract.
local function findContractViolation(candidate: any): string?
	if type(candidate) ~= "table" then
		return "the module must return a table"
	end
	for field, expectedType in REQUIRED_FIELDS do
		if type(candidate[field]) ~= expectedType then
			return `field "{field}" must be a {expectedType}`
		end
	end
	return nil
end

local function loadMinigame(moduleScript: ModuleScript): Minigame?
	local result = require(moduleScript)

	local violation = findContractViolation(result)
	if violation then
		logWarn(`Ignoring minigame "{moduleScript.Name}": {violation}`)
		return nil
	end
	return result :: Minigame
end

local function collectMinigameModules(): { ModuleScript }
	local modules: { ModuleScript } = {}
	for _, child in minigamesFolder:GetChildren() do
		if child:IsA("ModuleScript") then
			table.insert(modules, child)
		else
			logWarn(`Ignoring "{child.Name}" in Minigames: not a ModuleScript`)
		end
	end
	return modules
end

-- Removes a random module from `remaining` and loads it; keeps going past broken ones.
local function takeRandomMinigame(remaining: { ModuleScript }): Minigame?
	while #remaining > 0 do
		local index = rng:NextInteger(1, #remaining)
		local moduleScript = table.remove(remaining, index) :: ModuleScript
		local minigame = loadMinigame(moduleScript)
		if minigame then
			return minigame
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- A single match
--------------------------------------------------------------------------------

local function loadMap(minigame: Minigame): Instance?
	if not minigame.HasMap then
		return nil
	end

	local mapCount = minigame.NumberOfMaps or 1
	local mapName = if mapCount <= 1 then minigame.Name else `{minigame.Name}{rng:NextInteger(1, mapCount)}`
	local map = mapStorage:FindFirstChild(mapName)
	if not map then
		logWarn(`Map "{mapName}" not found in ServerStorage.Maps`)
		return nil
	end

	map.Parent = Workspace
	return map
end

local function waitForMatchEnd(minigame: Minigame)
	-- A game that starts with a single player (solo testing) runs its full duration;
	-- otherwise it ends early as soon as only one player is still in the game.
	local canEndEarly = #Players:GetPlayers() ~= 1
	local deadline = os.clock() + minigame.Duration

	while os.clock() < deadline do
		task.wait(1)
		if canEndEarly and countPlayersInGame() == 1 then
			log("Only one player left, ending the minigame early")
			return
		end
	end
end

local function runMatch(minigame: Minigame, map: Instance?)
	-- The loading screen is up while clients stream the map in.
	task.wait(MAP_STREAM_SECONDS)
	if map and not map:WaitForChild("SpawnLocation", SPAWN_LOCATION_TIMEOUT) then
		logWarn(`"{map.Name}" has no SpawnLocation; continuing anyway`)
	end
	task.wait(SPAWN_SETTLE_SECONDS)

	-- Everyone present now plays; anyone joining later waits in the lobby for the next game.
	local participants = Players:GetPlayers()
	assignTeams(minigame, participants)
	intermissionDataEvent:FireAllClients("Loading", false)

	respawnPlayers(participants)
	task.wait(CHARACTER_SETTLE_SECONDS)

	for _, player in participants do
		task.spawn(preparePlayer, player, minigame)
	end
	refreshLobbyTeam()
	if minigame.PointVariableType == "IntValue" then
		createPointCounters(participants)
	end

	currentMinigameValue.Value = minigame.Name
	startEvent:FireAllClients()
	task.spawn(runProtected, `{minigame.Name}.Start`, minigame.Start)

	minigameStartTimeValue.Value = os.time()
	timerUiEvent:FireAllClients(
		true,
		minigame.Name,
		minigameStartTimeValue.Value,
		minigame.Duration,
		minigame.PMode
	)

	waitForMatchEnd(minigame)
end

-- Always runs after a match, even if the match crashed, so the lobby is never left in a bad state.
local function tearDownMatch(minigame: Minigame, map: Instance?)
	runProtected(`{minigame.Name}.End`, minigame.End)

	timerUiEvent:FireAllClients(false)
	currentMinigameValue.Value = ""
	removePointCounters()

	-- Back to the lobby layout (Lobby + In-Game); only needed after a team game.
	if activateTeams({ TEAM_IN_GAME }) then
		refreshLobbyTeam()
	end

	task.wait(POST_GAME_SECONDS)
	for _, player in Players:GetPlayers() do
		player.Team = lobbyTeam
		setInGame(player, false)
	end

	task.wait(LOBBY_RETURN_SECONDS)
	respawnPlayers(Players:GetPlayers())

	if map then
		map.Parent = mapStorage
	end
	log(`Minigame "{minigame.Name}" finished`)
end

local function playMinigame(minigame: Minigame)
	log(`Starting minigame "{minigame.Name}"`)
	intermissionDataEvent:FireAllClients("Loading", true, minigame.Name)

	local map = loadMap(minigame)
	if minigame.HasMap and not map then
		logWarn(`Skipping "{minigame.Name}": its map could not be loaded`)
		intermissionDataEvent:FireAllClients("Loading", false)
		return
	end

	local ok, err = pcall(function()
		runMatch(minigame, map)
	end)
	if not ok then
		logWarn(`"{minigame.Name}" crashed, cleaning up:\n{err}`)
	end

	tearDownMatch(minigame, map)
end

--------------------------------------------------------------------------------
-- Rounds
--------------------------------------------------------------------------------

-- One round: every minigame is played exactly once, in random order.
local function runRound()
	local remaining = collectMinigameModules()
	if #remaining == 0 then
		logWarn("No minigames found in ReplicatedStorage.Minigames; retrying shortly")
		task.wait(NO_MINIGAMES_RETRY_SECONDS)
		return
	end

	log(`Starting a new round ({#remaining} minigames)`)
	while #remaining > 0 do
		waitForPlayers()
		runIntermission()

		local minigame = takeRandomMinigame(remaining)
		if minigame then
			playMinigame(minigame)
		end
	end
	log("Round finished")
end

log("Controller started")
while true do
	local ok, err = pcall(runRound)
	if not ok then
		logWarn(`Round crashed, restarting:\n{err}`)
		task.wait(CRASH_RECOVERY_SECONDS)
	end
end
