--[[
	Sword Fight Teams
	ModuleScript - ReplicatedStorage.Minigames

	Responsibilities:
	- Gives each participant a ClassicSword and restores it after respawning.
	- Applies the configured movement speed to every participant character.
	- Tracks enemy kills on the server through Humanoid.Died and the sword's
	  server-created `creator` ObjectValue tag.
	- Awards PlayerValues.Points and leaderstats.UpCoins for valid enemy kills.
	- Spawns and cleans up this minigame's air drops.
	- Announces the TDM result and the match MVP when End() is called.

	The MinigameController owns the round timer, team assignment, player
	respawning, and returning players to the lobby. This module deliberately
	does not LoadCharacter(), change Players.RespawnTime, or listen to a
	client-fired death RemoteEvent.

	Required instances:
	ServerStorage
	  Tools
	    ClassicSword (Tool; normally contains SwordScript and MouseIcon)
	  AirDrop (Model or BasePart)

	Workspace (while the match is running)
	  Sword Fight Teams
	    Spawn (BasePart; defines the air-drop spawn area)
	    AirDrops (Folder; created automatically if missing)

	ReplicatedStorage
	  EventsNFunctions
	    REvents
	      AnnounceWinner (RemoteEvent)

	The sword's server damage script must set a Humanoid ObjectValue named
	`creator` to the attacking Player. This is the usual Roblox sword-tag pattern.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

--------------------------------------------------------------------------------
-- Minigame configuration (must match the MinigameController contract)
--------------------------------------------------------------------------------

type SwordFightModule = {
	Name: string,
	Duration: number,
	PlayersLives: number,
	PointsMultiplier: number,
	PMode: "TDM",
	HasMap: boolean,
	NumberOfMaps: number,
	PlayerSpeed: number,
	PointVariableType: string,
	Start: () -> (),
	End: () -> (),
}

local SwordFight: SwordFightModule = {
	Name = "Sword Fight Teams",
	Duration = 30,
	PlayersLives = 5,
	PointsMultiplier = 1,
	PMode = "TDM",
	HasMap = true,
	NumberOfMaps = 1,
	PlayerSpeed = 35,
	PointVariableType = "IntValue",
	Start = function() end,
	End = function() end,
}

--------------------------------------------------------------------------------
-- Internal configuration
--------------------------------------------------------------------------------

local TEAM_BLUE_NAME = "Blue"
local TEAM_RED_NAME = "Red"

local SWORD_NAME = "ClassicSword"
local SWORD_SCRIPT_NAME = "SwordScript"
local SWORD_ICON_SCRIPT_NAME = "MouseIcon"

local AIR_DROP_INTERVAL = 10
local AIR_DROP_HEIGHT_OFFSET = 2
local CHARACTER_WAIT_TIMEOUT = 10
local BACKPACK_WAIT_TIMEOUT = 10

local rng = Random.new()

--------------------------------------------------------------------------------
-- Session state
--------------------------------------------------------------------------------

-- A new session ID invalidates any delayed work left over from the previous game.
local sessionId = 0
local isActive = false

local participants: { [Player]: boolean } = {}
local participantTeams: { [Player]: Team } = {}
local participantOrder: { Player } = {}
local playerKills: { [Player]: number } = {}

local blueKills = 0
local redKills = 0

local characterConnections: { [Player]: RBXScriptConnection } = {}
local deathConnections: { [Player]: RBXScriptConnection } = {}
local trackedCharacters: { [Player]: Model } = {}
local swords: { [Player]: Tool } = {}

local playerRemovingConnection: RBXScriptConnection? = nil
local spawnedAirDrops: { Instance } = {}
local airDropFolder: Folder? = nil
local swordTemplate: Tool? = nil

-- Avoid repeating the same missing-value warning for every kill.
local warnedMissingValues: { [string]: boolean } = {}

--------------------------------------------------------------------------------
-- Logging and session helpers
--------------------------------------------------------------------------------

local function log(...: any)
	print("[SwordFight]", ...)
end

local function logWarn(...: any)
	warn("[SwordFight]", ...)
end

local function isCurrentSession(expectedSessionId: number): boolean
	return isActive and sessionId == expectedSessionId
end

local function isActiveParticipant(player: Player, expectedSessionId: number): boolean
	return isCurrentSession(expectedSessionId)
		and participants[player] == true
		and player.Parent == Players
end

local function warnMissingValueOnce(player: Player, valuePath: string)
	local key = `{player.UserId}:{valuePath}`
	if warnedMissingValues[key] then
		return
	end

	warnedMissingValues[key] = true
	logWarn(`{player.Name} is missing {valuePath}; that reward will be skipped`)
end

local function disconnect(connection: RBXScriptConnection?)
	if connection then
		connection:Disconnect()
	end
end

local function disconnectCharacterTracking(player: Player)
	disconnect(characterConnections[player])
	disconnect(deathConnections[player])

	characterConnections[player] = nil
	deathConnections[player] = nil
	trackedCharacters[player] = nil
end

--------------------------------------------------------------------------------
-- Participant and reward helpers
--------------------------------------------------------------------------------

local function isPlayingTeam(team: Team?): boolean
	if not team then
		return false
	end

	return team.Name == TEAM_BLUE_NAME or team.Name == TEAM_RED_NAME
end

local function getCreatorPlayer(humanoid: Humanoid): Player?
	local creatorTag = humanoid:FindFirstChild("creator")
	if not creatorTag or not creatorTag:IsA("ObjectValue") then
		return nil
	end

	local creator = creatorTag.Value
	if creator and creator:IsA("Player") then
		return creator
	end

	return nil
end

local function awardKillRewards(killer: Player)
	local playerValues = killer:FindFirstChild("PlayerValues")
	local points = playerValues and playerValues:FindFirstChild("Points")

	if points and points:IsA("IntValue") then
		points.Value += 1
	elseif points and points:IsA("NumberValue") then
		points.Value += 1
	else
		warnMissingValueOnce(killer, "PlayerValues.Points")
	end

	local leaderstats = killer:FindFirstChild("leaderstats")
	local upCoins = leaderstats and leaderstats:FindFirstChild("UpCoins")

	if upCoins and upCoins:IsA("IntValue") then
		upCoins.Value += math.max(0, math.floor(SwordFight.PointsMultiplier))
	elseif upCoins and upCoins:IsA("NumberValue") then
		upCoins.Value += math.max(0, SwordFight.PointsMultiplier)
	else
		warnMissingValueOnce(killer, "leaderstats.UpCoins")
	end
end

local function onHumanoidDied(
	victim: Player,
	humanoid: Humanoid,
	expectedSessionId: number
)
	if not isActiveParticipant(victim, expectedSessionId) then
		return
	end

	local killer = getCreatorPlayer(humanoid)
	if not killer or killer == victim or not isActiveParticipant(killer, expectedSessionId) then
		return
	end

	local killerTeam = participantTeams[killer]
	local victimTeam = participantTeams[victim]
	if not killerTeam or not victimTeam or killerTeam == victimTeam then
		-- Self-kills, environmental deaths, and friendly-fire deaths do not score.
		return
	end

	playerKills[killer] = (playerKills[killer] or 0) + 1

	if killerTeam.Name == TEAM_BLUE_NAME then
		blueKills += 1
	elseif killerTeam.Name == TEAM_RED_NAME then
		redKills += 1
	end

	awardKillRewards(killer)
	log(`{killer.Name} eliminated {victim.Name} ({killerTeam.Name})`)
end

--------------------------------------------------------------------------------
-- Sword management
--------------------------------------------------------------------------------

local function enableScriptIfPresent(container: Instance, scriptName: string)
	local object = container:FindFirstChild(scriptName, true)
	if object and (object:IsA("Script") or object:IsA("LocalScript")) then
		object.Enabled = true
	end
end

local function findExistingSword(player: Player): Tool?
	local character = player.Character
	if character then
		local equippedSword = character:FindFirstChild(SWORD_NAME)
		if equippedSword and equippedSword:IsA("Tool") then
			return equippedSword
		end
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		local storedSword = backpack:FindFirstChild(SWORD_NAME)
		if storedSword and storedSword:IsA("Tool") then
			return storedSword
		end
	end

	return nil
end

local function giveSword(player: Player, character: Model, expectedSessionId: number)
	if not isActiveParticipant(player, expectedSessionId) or player.Character ~= character then
		return
	end

	-- A sword may survive a character respawn in Backpack. Reuse it rather than
	-- creating duplicates every time CharacterAdded fires.
	if findExistingSword(player) then
		return
	end

	local template = swordTemplate
	if not template then
		logWarn("ClassicSword template is unavailable; cannot equip participants")
		return
	end

	local backpackInstance = player:FindFirstChildOfClass("Backpack")
	if not backpackInstance then
		local backpackCandidate = player:WaitForChild("Backpack", BACKPACK_WAIT_TIMEOUT)
		if backpackCandidate and backpackCandidate:IsA("Backpack") then
			backpackInstance = backpackCandidate
		end
	end

	if not backpackInstance
		or not isActiveParticipant(player, expectedSessionId)
		or player.Character ~= character
	then
		return
	end

	-- Re-check after yielding for the Backpack in case another callback equipped it.
	if findExistingSword(player) then
		return
	end

	local sword = template:Clone()
	sword:SetAttribute("SwordFightSessionId", expectedSessionId)
	enableScriptIfPresent(sword, SWORD_SCRIPT_NAME)
	enableScriptIfPresent(sword, SWORD_ICON_SCRIPT_NAME)
	sword.Parent = backpackInstance
	swords[player] = sword
end

--------------------------------------------------------------------------------
-- Character lifecycle
--------------------------------------------------------------------------------

local function setupCharacter(player: Player, character: Model, expectedSessionId: number)
	if not isActiveParticipant(player, expectedSessionId) then
		return
	end

	if trackedCharacters[player] == character then
		return
	end

	trackedCharacters[player] = character
	disconnect(deathConnections[player])
	deathConnections[player] = nil

	local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
		or character:WaitForChild("Humanoid", CHARACTER_WAIT_TIMEOUT)

	if not humanoidInstance or not humanoidInstance:IsA("Humanoid") then
		logWarn(`Could not find a Humanoid for {player.Name}'s character`)
		return
	end

	if not isActiveParticipant(player, expectedSessionId) or player.Character ~= character then
		return
	end

	humanoidInstance.WalkSpeed = SwordFight.PlayerSpeed
	deathConnections[player] = humanoidInstance.Died:Connect(function()
		onHumanoidDied(player, humanoidInstance, expectedSessionId)
	end)

	giveSword(player, character, expectedSessionId)
end

local function registerParticipant(player: Player, expectedSessionId: number)
	local team = player.Team
	if not isPlayingTeam(team) or not team then
		return
	end

	participants[player] = true
	participantTeams[player] = team
	playerKills[player] = 0
	table.insert(participantOrder, player)

	characterConnections[player] = player.CharacterAdded:Connect(function(character)
		task.spawn(setupCharacter, player, character, expectedSessionId)
	end)

	if player.Character then
		task.spawn(setupCharacter, player, player.Character, expectedSessionId)
	end
end

local function onPlayerRemoving(player: Player)
	-- Keep their already-earned kills for the team result, but they can no longer
	-- receive credit or be selected as the live MVP recipient.
	participants[player] = nil
	disconnectCharacterTracking(player)

	local sword = swords[player]
	if sword then
		sword:Destroy()
		swords[player] = nil
	end
end

--------------------------------------------------------------------------------
-- Air drops
--------------------------------------------------------------------------------

local function spawnAirDrop(expectedSessionId: number, spawnPart: BasePart)
	if not isCurrentSession(expectedSessionId) then
		return
	end

	local template = ServerStorage:FindFirstChild("AirDrop")
	if not template or (not template:IsA("Model") and not template:IsA("BasePart")) then
		return
	end

	local folder = airDropFolder
	if not folder or not folder.Parent then
		return
	end

	-- Generate the position in the Spawn part's local space so rotated spawn
	-- areas work correctly, too.
	local localX = rng:NextNumber(-spawnPart.Size.X / 2, spawnPart.Size.X / 2)
	local localZ = rng:NextNumber(-spawnPart.Size.Z / 2, spawnPart.Size.Z / 2)
	local localPosition = Vector3.new(
		localX,
		spawnPart.Size.Y / 2 + AIR_DROP_HEIGHT_OFFSET,
		localZ
	)
	local worldPosition = spawnPart.CFrame:PointToWorldSpace(localPosition)

	local drop = template:Clone()
	if not drop:IsA("Model") and not drop:IsA("BasePart") then
		drop:Destroy()
		return
	end

	drop:PivotTo(CFrame.new(worldPosition))
	drop:SetAttribute("SwordFightSessionId", expectedSessionId)
	drop.Parent = folder
	table.insert(spawnedAirDrops, drop)
end

local function startAirDropSpawner(expectedSessionId: number)
	local map = Workspace:FindFirstChild(SwordFight.Name)
	if not map then
		logWarn(`Map "{SwordFight.Name}" is not in Workspace; air drops are disabled`)
		return
	end

	local spawnInstance = map:FindFirstChild("Spawn")
	if not spawnInstance or not spawnInstance:IsA("BasePart") then
		logWarn(`Map "{SwordFight.Name}" needs a BasePart named Spawn; air drops are disabled`)
		return
	end

	local folderInstance = map:FindFirstChild("AirDrops")
	if folderInstance and not folderInstance:IsA("Folder") then
		logWarn(`Map "{SwordFight.Name}" has a non-Folder AirDrops object; air drops are disabled`)
		return
	end

	if not folderInstance then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "AirDrops"
		newFolder.Parent = map
		folderInstance = newFolder
	end

	airDropFolder = folderInstance :: Folder

	local template = ServerStorage:FindFirstChild("AirDrop")
	if not template or (not template:IsA("Model") and not template:IsA("BasePart")) then
		logWarn("ServerStorage.AirDrop must be a Model or BasePart; air drops are disabled")
		return
	end

	task.spawn(function()
		while isCurrentSession(expectedSessionId) do
			spawnAirDrop(expectedSessionId, spawnInstance)
			task.wait(AIR_DROP_INTERVAL)
		end
	end)
end

local function clearAirDrops()
	for _, drop in spawnedAirDrops do
		if drop.Parent then
			drop:Destroy()
		end
	end
	table.clear(spawnedAirDrops)
	airDropFolder = nil
end

--------------------------------------------------------------------------------
-- Result announcement
--------------------------------------------------------------------------------

local function getMvp(): (Player?, number)
	local mvp: Player? = nil
	local highestKills = 0

	-- Participant order makes the tie-break deterministic: the first participant
	-- in the controller's player snapshot keeps MVP when kill counts are tied.
	for _, player in participantOrder do
		local kills = playerKills[player] or 0
		if player.Parent == Players and kills > highestKills then
			highestKills = kills
			mvp = player
		end
	end

	return mvp, highestKills
end

local function announceResults()
	local eventsFolder = ReplicatedStorage:FindFirstChild("EventsNFunctions")
	local remoteEvents = eventsFolder and eventsFolder:FindFirstChild("REvents")
	local announceWinner = remoteEvents and remoteEvents:FindFirstChild("AnnounceWinner")

	local mvp, mvpKills = getMvp()
	local winner: string? = nil
	if blueKills > redKills then
		winner = TEAM_BLUE_NAME
	elseif redKills > blueKills then
		winner = TEAM_RED_NAME
	end

	if announceWinner and announceWinner:IsA("RemoteEvent") then
		announceWinner:FireAllClients(SwordFight.PMode, winner ~= nil, winner, mvp)
	else
		logWarn("ReplicatedStorage.EventsNFunctions.REvents.AnnounceWinner is missing or is not a RemoteEvent")
	end

	log(`Team totals — Red: {redKills}, Blue: {blueKills}`)
	if winner then
		log(`{winner} team wins`)
	else
		log("The match ended in a tie")
	end

	if mvp then
		log(`MVP: {mvp.Name} ({mvpKills} kills)`)
	else
		log("No online participant is available to receive MVP")
	end
end

--------------------------------------------------------------------------------
-- Public lifecycle
--------------------------------------------------------------------------------

function SwordFight.Start()
	if isActive then
		logWarn("Start() was called while a Sword Fight session was already active")
		return
	end

	-- Validate the required weapon before changing session state. If the asset is
	-- missing, the controller's protected call reports the setup error cleanly.
	local toolsFolder = ServerStorage:FindFirstChild("Tools")
	local swordInstance = toolsFolder and toolsFolder:FindFirstChild(SWORD_NAME)
	if not swordInstance or not swordInstance:IsA("Tool") then
		error("ServerStorage.Tools.ClassicSword must exist and be a Tool")
	end

	sessionId += 1
	local thisSessionId = sessionId
	isActive = true

	-- Reset all state before registering this session's participants.
	table.clear(participants)
	table.clear(participantTeams)
	table.clear(participantOrder)
	table.clear(playerKills)
	table.clear(characterConnections)
	table.clear(deathConnections)
	table.clear(trackedCharacters)
	table.clear(swords)
	table.clear(spawnedAirDrops)
	table.clear(warnedMissingValues)
	blueKills = 0
	redKills = 0
	airDropFolder = nil

	swordTemplate = swordInstance :: Tool

	for _, player in Players:GetPlayers() do
		registerParticipant(player, thisSessionId)
	end

	playerRemovingConnection = Players.PlayerRemoving:Connect(onPlayerRemoving)
	startAirDropSpawner(thisSessionId)

	if #participantOrder == 0 then
		logWarn("No participants were assigned to Blue or Red; check the controller's team setup")
	end
	log(`Started with {#participantOrder} participant(s)`)
end

function SwordFight.End()
	if not isActive then
		return
	end

	-- Invalidate all delayed CharacterAdded/Backpack/air-drop work immediately.
	isActive = false
	sessionId += 1

	disconnect(playerRemovingConnection)
	playerRemovingConnection = nil

	for _, player in participantOrder do
		disconnectCharacterTracking(player)
	end

	for player, sword in swords do
		if sword.Parent then
			sword:Destroy()
		end
		swords[player] = nil
	end

	clearAirDrops()
	announceResults()

	log("Ended")

	table.clear(participants)
	table.clear(participantTeams)
	table.clear(participantOrder)
	table.clear(playerKills)
	table.clear(characterConnections)
	table.clear(deathConnections)
	table.clear(trackedCharacters)
	table.clear(swords)
	table.clear(warnedMissingValues)
	blueKills = 0
	redKills = 0
	swordTemplate = nil
end

return SwordFight
