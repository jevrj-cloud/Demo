--!strict

local Matchmaking = {}
-- Creating a metatable to allow multiple match instances (casual vs ranked for example)
Matchmaking.__index = Matchmaking

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local event = ReplicatedStorage.Events:FindFirstChild("changePlayerVis") :: RemoteEvent
local updateVoice = ReplicatedStorage.Events:FindFirstChild("updateVoice") :: RemoteEvent
local changeQueue = ReplicatedStorage.Events:FindFirstChild("changeQueue") :: RemoteEvent


type config = {
	roundtime: number,
	downtime: number,
	roundsToFinish: number,
	maxGroupSize: number,
	maxBlacklists: number
}

type playerDataTemplate = {
	prevMatchedPlayers: {[number]: boolean},
	blacklisted: {[number]: Players},
	joinTime: number
}

local DEFAULT_ROUNDTIME = 2 :: number
local DEFAULT_DOWNTIME = 1 :: number
local DEFAULT_ROUNDS_UNTIL_FINISH = 10 :: number
local DEFAULT_MAX_ROUND_SIZE = 10 :: number
local DEFAULT_BLACKLISTS = 10 :: number


function Matchmaking.new(config: config): any

	
	local self = setmetatable({}, Matchmaking)
	self.roundtime = (config.roundtime or DEFAULT_ROUNDTIME) :: number
	self.downtime = (config.downtime or DEFAULT_DOWNTIME) :: number
	self.roundsToFinish = (config.roundsToFinish or DEFAULT_ROUNDS_UNTIL_FINISH) :: number
	self.maxGroupSize = (config.maxGroupSize or DEFAULT_MAX_ROUND_SIZE) :: number
	self.maxBlacklists = (config.maxBlacklists or DEFAULT_BLACKLISTS) :: number

	self.queue = {} :: {Player}
	self.activePlayers = {} :: { {Player}}
	
	-- cleared every round end 
	self.preservedPlayers = {} :: {Player}
	self.previouslyPreservedPlayers = {} :: {Player}
	self.possiblePreservations = {} :: {Player}

	self.currentRound = 1 :: number
	
	self.unusedCollisionGroups = {} :: {string}
	self.nextCollisionGroup = 1 :: number
	self.activeCollisionGroups = {} :: {string}

	
	self.lastRoundStart = tick()
	
	
	self.playerData = {} :: {[number]: playerDataTemplate}
	self.playerDataTemplate = {
		prevMatchedPlayers = {} :: {[number]: boolean},
		blacklisted = {} :: {[number]: boolean},
		joinTime = math.huge :: number
	}

	
	
	return self 
end


--[[ UNIMPLEMENTED METHODS ]]--

-- Initializes downtime after match ends
function Matchmaking:InitDowntime(): nil
	warn("Downtime function not created")
	return
end

-- Handles players that are leftover after matching
function Matchmaking:HandleLeftovers(player: Player): nil
	warn(player.Name.." was left over after pairing")
	return
end

-- Handles when a match doesn't have enough in queue 
function Matchmaking:HandleNotEnoughPlayers(): nil
	warn("Not enough players to start match")
	return
end

-- Handles when a pair tries to continue a match before a group round 
function Matchmaking:HandleAttemptedContinue(): nil
	warn("Cannot preserve when next round is a group round!")
	return
end

function Matchmaking:HandleMaxBlacklist(): nil
	warn("Max blacklist count reached")
	return
end

--[[ PRIVATE METHODS ]]--

-- Validates player
function Matchmaking:PlayerExists(player: Player): boolean
	return Players:GetPlayerByUserId(player.UserId) ~= nil
end

-- Validates character
function Matchmaking:CharacterExists(player: Player): boolean
	return self:PlayerExists(player) and player.Character
end

local function doesCollisionGroupExist(groupName: string): boolean
	local allGroups = PhysicsService:GetRegisteredCollisionGroups() -- Returns a table of collision groups
	for _, group in ipairs(allGroups) do
		if group.name == groupName then
			return true
		end
	end
	return false
end

function Matchmaking:ChangeCharacterCollisionGroup(player: Player, groupName: string): nil
	if(doesCollisionGroupExist(groupName)) then
		local character = player and player.Character :: Model
		if(character and character:FindFirstChild("HumanoidRootPart")) then
			task.spawn(function()
				workspace:WaitForChild(character.Name, 3) -- wait for character to load in before running
				for  _, part in character:GetDescendants() do
					if part:IsA("BasePart") then
						part.CollisionGroup = groupName
					end
				end
			end)
		
		end
	else
		warn("Collision group not found")
	end
	return
end



-- Creates a match group based on how many per group
function Matchmaking:GetJoinTime(player: Player): number
	if(not player) then
		return math.huge
	end
	return (self.playerData[player.UserId] and self.playerData[player.UserId].joinTime) or math.huge
end

-- Finds the best player to match with a given player. Using greedy heuristic. Run this on queue. Returns player pairs and an leftover players
function Matchmaking:CreatePairs(players: {Player}): ({ {Player}}?, {Player}?)
	-- sort by earliest joiners 
	table.sort(players, function(a, b)
		return (self:GetJoinTime(a) or 0) < (self:GetJoinTime(b) or 0)
	end)
	
	local groups = {} :: {{ Player}}
	local unmatchedPlayers = table.clone(players) :: {Player}
	
	local leftovers = {} :: {Player}

	
	while #unmatchedPlayers >= 2 do
		local foundPair = false :: boolean
		local possiblePair = 0 :: number
		
		for i = 1, #unmatchedPlayers - 1 do
			local player1: Player = unmatchedPlayers[1]
			local player2: Player = unmatchedPlayers[i+1]
			if(not self:PlayerExists(player1) or not self:PlayerExists(player2)) then 
				warn("Players in matchmaking not initialized")
				continue 
			end
			local id1, id2 = player1.UserId, player2.UserId
			
			if(not self.playerData[id1] or not self.playerData[id2]) then 
				warn("Players in matchmaking not initialized")
				continue
			end

			local isblacklisted = (self.playerData[id1].blacklisted[id2] or self.playerData[id2].blacklisted[id1]) :: boolean
			if not isblacklisted then
				if(self.playerData[id1].prevMatchedPlayers[id2] and possiblePair == 0) then
					possiblePair = i+1
					continue
				end
				table.insert(groups, {player1, player2})

				table.remove(unmatchedPlayers, i + 1)
				table.remove(unmatchedPlayers, 1)
				foundPair = true
				break
			end

		end
		if not foundPair then -- player didn't find new connection 
			if(possiblePair == 0) then -- player matched with no one 
				table.insert(leftovers, unmatchedPlayers[1])
				table.remove(unmatchedPlayers, 1)
			else
				local player1: Player = unmatchedPlayers[1]
				local player2: Player = unmatchedPlayers[possiblePair]
				table.insert(groups, {player1, player2})
				table.remove(unmatchedPlayers, possiblePair)
				table.remove(unmatchedPlayers, 1)
			end
		end

	end
	
	for _, player in ipairs(unmatchedPlayers) do
		if(not table.find(leftovers, player)) then
			table.insert(leftovers, player)
		end
	end
	
	return groups, leftovers
end


-- Creates a larger group 
function Matchmaking:CreateMatchGroup(players: {Player}): { {Player}}?
	local numChunks = 1 :: number
	-- Greedy choose chunks 
	while(math.ceil(#players / numChunks) > self.maxGroupSize ) do
		numChunks += 1
	end
	
	local peoplePerChunk = math.floor(#players / numChunks) :: number
	local remainingPeople = #players % numChunks
	local groups = {} :: { { Player}}
	local currIndex = 1 :: number
	
	for i = 1, numChunks do
		local group = {} :: {Player}
		if(i == (numChunks-remainingPeople+1)) then
			peoplePerChunk += 1
		end
		
		for j = 1, peoplePerChunk do
			table.insert(group, players[currIndex])
			currIndex += 1
		end
		table.insert(groups, group)
	end
	-- Ensure every player finds an assignment
	assert(currIndex == #players+1)	
	return groups
end

-- Records match history of each player
function Matchmaking:UpdateHistory(matchGroup: {Player}): nil
	for _, p1 in pairs(matchGroup) do
		if(not self.playerData[p1.UserId]) then
			warn("Player data not generating properly")
			return
		end
		
		local matchPlayers: {boolean} = self.playerData[p1.UserId].prevMatchedPlayers
		
		for _, p2 in pairs(matchGroup) do
			if p1 == p2 then continue end
			
			matchPlayers[p2.UserId] = true
			
		end
	end
	return
end


function Matchmaking:GroupPlayers(playerGroups: {{Player}}): nil
	for _, group in pairs(playerGroups) do
		local characters = {} :: {string?}
		for _, pl in group do
			table.insert(characters, (pl.Character and pl.Character.Name))

		end
		
		for _, player in group do
			event:FireClient(player, characters, true)
		end
	end
	
	-- Team chat and VC:
	
	-- VoiceChatService config (enable Audio API, disable default voice) should be done in Studio beforehand
	for _, group in ipairs(playerGroups) do
		local groupIndex = group[1].UserId
		local channelName = ("Group"..groupIndex) :: string

		-- Create a new text chat channel for this group
		local chatChannel = Instance.new("TextChannel") :: TextChannel
		chatChannel.Name = channelName
		chatChannel.Parent = TextChatService:WaitForChild("TextChannels", 3)

		for _, player in ipairs(group) do
			chatChannel:AddUserAsync(player.UserId)

		end
		
		-- Create voice grouping by naming inputs
		for _, player in ipairs(group) do
			local micInput = player:FindFirstChildOfClass("AudioDeviceInput") :: AudioDeviceInput
			if not micInput then
				micInput = Instance.new("AudioDeviceInput") :: AudioDeviceInput
			end
			micInput.Parent = player
			micInput.Player = player
			micInput.Name = channelName .. "Input"
			updateVoice:FireClient(player, false, channelName, group)

			
		end

	end
		

	
	return
end

function Matchmaking:UnGroupActivePlayers(playerGroups: {{Player}}): nil
	for _, group in pairs(playerGroups) do
		local characters = {} :: {string?}
		for _, pl in group do
			table.insert(characters, (pl.Character and pl.Character.Name))
		end
		if(group) then
			for _, groupPlayer in group do
				if(table.find(self.preservedPlayers, groupPlayer)) then
					continue 
				end
				self:LeaveQueue(groupPlayer)
				event:FireClient(groupPlayer, characters, false) -- resets visibility
			end

		end
		
	end
	
	-- Team VC and chat cleaning:
	
	for _, group in ipairs(playerGroups) do
		local groupIndex = group[1].UserId
		local skip = false :: boolean
		local channelName = ("Group"..groupIndex) :: string
		local chatChannel = TextChatService.TextChannels:FindFirstChild(channelName) :: TextChannel
		if chatChannel then
			for _, player in ipairs(group) do
				if(table.find(self.preservedPlayers, player)) then
					skip = true
					updateVoice:FireClient(player, true, nil, group, true)
					continue 
				end
				
				-- Restore voice input name (general)
				local micInput = player:FindFirstChildOfClass("AudioDeviceInput") :: AudioDeviceInput
				if micInput then micInput.Name = "GeneralInput" end
				-- Remove from group text channel
				local source = chatChannel:FindFirstChild(player.Name) :: Player
				if source then source:Destroy() end
				-- Re-add to general text channel
				--local general = TextChatService.TextChannels:FindFirstChild("RBXGeneral") :: TextChannel
				--if general then general:AddUserAsync(player.UserId) end
				
				updateVoice:FireClient(player, true, nil, group) -- tell client to clean
				
			end
			if(not skip) then
				chatChannel:Destroy()
			end
		end
	end
	

	return
end


--[[ PUBLIC METHODS ]]--

-- Starts match 
function Matchmaking:StartMatch(): nil
	local outerGroup = nil :: {{ Player}}?
	if(#self.queue < 2) then
		self:HandleNotEnoughPlayers()
		self.currentRound += 1

		return
	end
	if(self.currentRound % self.roundsToFinish == 0) then
		outerGroup = self:CreateMatchGroup(self.queue) 
	else
		local groupRet: { { Player}}, leftovers: {Player} = self:CreatePairs(self.queue) 
		outerGroup = groupRet
		self.queue = leftovers or {}
		if(leftovers) then
			for _, player in pairs(leftovers) do
				self:HandleLeftovers(player)
			end
		end

	end

	
	if(outerGroup) then
		self.activePlayers = table.clone(outerGroup)
		for _, group in outerGroup do
			self:UpdateHistory(group)
			for _, player in group do
				changeQueue:FireClient(player, false)
				if(self.currentRound % self.roundsToFinish == 0) then
					updateVoice:FireClient(player, true, nil, group, true) -- remove preserve GUI

				end

			end
		end

		self:GroupPlayers(outerGroup)
		
		
		for _, group in outerGroup do
			for _, player in group do
				-- Disable click if next round or current round is a group round 
				if(self.currentRound % self.roundsToFinish == 0 or ((self.currentRound+1) % self.roundsToFinish == 0)) then
					updateVoice:FireClient(player, true, nil, group, true) -- remove preserve GUI

				end
			end
		end
		
		
		self.lastRoundStart = tick()
	end

	self.currentRound += 1
	return
end

-- Ends match
function Matchmaking:EndMatch(): nil
	self:InitDowntime()
	self:UnGroupActivePlayers(self.activePlayers)
	for _, group in ipairs(self.activePlayers) do
		for _, player in ipairs(group) do
			if(not table.find(self.preservedPlayers, player)) then
				local queuePos = table.find(self.queue, player)
				if(queuePos) then
					table.remove(self.queue, queuePos)
					changeQueue:FireClient(player, false)

				end
				
			end
		end
	end
	-- Remove active players who are not in the preserved list 
	--self.activePlayers = {}
	for i = #self.activePlayers, 1, -1 do
		local group = self.activePlayers[i]
		local keep = false
		for _, player in ipairs(group) do
			if table.find(self.preservedPlayers, player) then
				keep = true
				break
			end
		end
		if not keep then
			table.remove(self.activePlayers, i)
		end
	end	
	
	
	self.previouslyPreservedPlayers = table.clone(self.preservedPlayers)
	self.preservedPlayers = {}
	self.possiblePreservations = {}

	return nil
end


-- Adds player to queue
function Matchmaking:JoinQueue(player: Player): nil
	if(not self:PlayerExists(player)) then return end

	if(not self.playerData[player.UserId]) then
		self.playerData[player.UserId] = table.clone(self.playerDataTemplate)
	end

	if(table.find(self.queue, player)) then
		return
	end
	self.playerData[player.UserId].joinTime = tick()
	table.insert(self.queue, player)
	changeQueue:FireClient(player, true)


	return
end

-- Removes player from queue
function Matchmaking:LeaveQueue(player: Player): nil
	if(not self:PlayerExists(player)) then return end

	local pos = table.find(self.queue, player) :: number
	if(pos) then
		table.remove(self.queue, pos)
	end
	changeQueue:FireClient(player, false)

	
	
	return
end

-- Adds player to their own collision group and makes every other player invis, puts in solo VC
function Matchmaking:AddCharacter(player: Player): nil
	
	-- Remove player from general text channel
	local general = TextChatService.TextChannels:FindFirstChild("RBXGeneral")
	if general then
		local source = general:FindFirstChild(player.Name)
		if source then source:Destroy() end
	end
	
	
	if(not self:CharacterExists(player)) then return end

	local character = player.Character :: Model
	if(not self.playerData[player.UserId]) then
		self.playerData[player.UserId] = table.clone(self.playerDataTemplate)
	end
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: Part

	if(rootPart and rootPart.CollisionGroup and rootPart.CollisionGroup == "Default") then
		local nextCollisionName = "collisiongroup_"..tostring(self.nextCollisionGroup) :: string

		if(#self.unusedCollisionGroups == 0) then
			self.nextCollisionGroup += 1 
			PhysicsService:RegisterCollisionGroup(nextCollisionName)

		else
			nextCollisionName = self.unusedCollisionGroups[1]
			table.remove(self.unusedCollisionGroups, 1)
		end
		
		self:ChangeCharacterCollisionGroup(player, nextCollisionName)

		for _, colgroup in pairs(self.activeCollisionGroups) do
			PhysicsService:CollisionGroupSetCollidable(nextCollisionName, colgroup, false)
		end
		
		table.insert(self.activeCollisionGroups, nextCollisionName)

	end
	local name = player.Character and player.Character.Name
	event:FireAllClients({name}, false)
	return
end

local function deepEquals(t1, t2)
	if t1 == t2 then
		return true
	end
	if type(t1) ~= "table" or type(t2) ~= "table" then
		return false
	end
	local n1 = #t1
	local n2 = #t2
	if n1 ~= n2 then
		return false
	end
	for i = 1, n1 do
		if t1[i] ~= t2[i] then
			return false
		end
	end
	return true
end


function Matchmaking:HandleDeath(player: Player): nil

	
	
	local group = self:GetGroup(player) :: {Player}?
	

	if(group) then
		
		for _, player2 in ipairs(group) do
			local pos = table.find(self.preservedPlayers, player2) :: number?
			if(pos) then
				table.remove(self.preservedPlayers, pos)
			end
			
			local pos2 = table.find(self.possiblePreservations, player2) :: number?
			if(pos2) then
				table.remove(self.possiblePreservations, pos)
			end
			
			local pos3 = table.find(self.previouslyPreservedPlayers, player2) :: number?
			if(pos3) then
				table.remove(self.previouslyPreservedPlayers, pos)
			end
		end
		
		
		self:UnGroupActivePlayers({group})
		
		local rmv = nil :: number?
		for pos, activeGroup in ipairs(self.activePlayers) do
			if( deepEquals(activeGroup, group)) then
				rmv = pos
			end
			local queuePos = table.find(self.queue, player)
			if(queuePos) then
				table.remove(self.queue, queuePos)
				changeQueue:FireClient(player, false)

			end

		end
		if(rmv) then
			table.remove(self.activePlayers, rmv)

		end
	

	end


	return
end

function Matchmaking:LeaveMatch(player: Player): nil
	self:HandleDeath(player)
	return
end



-- Cleans player on leave
function Matchmaking:RemovePlayer(player: Player): nil
	if(not self:PlayerExists(player)) then return end
	self:HandleDeath(player)
	self:CleanPlayerInstance(player)

	if(self.playerData[player.UserId]) then
		self.playerData[player.UserId] = nil
	end
	
	
	return
end

local function getDictionarySize(dict: {[number]: boolean}): number
	local count = 0
	for _, val in pairs(dict) do
		if(val) then
			count += 1
		end
		
	end
	return count
end


-- Blacklists a player
function Matchmaking:BlacklistPlayer(player: Player, blacklisted: Player): nil
	if(not self:PlayerExists(player) or not self:PlayerExists(blacklisted)) then return end
	if(not self.playerData[player.UserId]) then
		self.playerData[player.UserId] = table.clone(self.playerDataTemplate)
	end
	if((getDictionarySize(self.playerData[player.UserId].blacklisted)+1) > self.maxBlacklists) then
		self:HandleMaxBlacklist()
		return
	end
	print("blacklisted")
	self.playerData[player.UserId].blacklisted[blacklisted.UserId] = true

	local group = self:GetGroup(player) :: {Player}
	if(group) then
		for _, pl in pairs(group) do
			if(pl == blacklisted) then
				if(#group == 2) then
					self:LeaveMatch(player)
				end
				return
			end
		end
	end

	
	
	return 
end

-- Removes player from blacklist
function Matchmaking:RemoveBlacklist(player: Player, blacklisted: Player): nil
	if(not self:PlayerExists(player) or not self:PlayerExists(blacklisted)) then return end
	if(not self.playerData[player.UserId]) then
		self.playerData[player.UserId] = table.clone(self.playerDataTemplate)
		return
	end
	
	self.playerData[player.UserId].blacklisted[blacklisted.UserId] = false

	return
end

-- Checks if a player blacklisted another player
function Matchmaking:Isblacklisted(player: Player, blacklisted: Player): boolean
	if(not self:PlayerExists(player) or not self:PlayerExists(blacklisted)) then return false end
	if(not self.playerData[player.UserId]) then
		self.playerData[player.UserId] = table.clone(self.playerDataTemplate)
		return false
	end
	
	local isBL = (self.playerData[player.UserId].blacklisted[blacklisted.UserId] or false) :: boolean
	
	return isBL

end

-- Continues match for two players 
function Matchmaking:ContinueMatch(player1: Player, player2: Player): nil
	if(not self:PlayerExists(player1) or not self:PlayerExists(player2)) then return end
	if(table.find(self.previouslyPreservedPlayers, player1) or table.find(self.previouslyPreservedPlayers, player2)) then
		self:HandleAttemptedContinue()
		return 
	end
	local group = self:GetGroup(player1)
	if(table.find(group, player1) and table.find(group, player2) and #group == 2) then
		table.insert(self.preservedPlayers, player1)
		table.insert(self.preservedPlayers, player2)
	end


	return
end



-- gets group of players given a player in group 
function Matchmaking:GetGroup(player: Player): {Player}?

	for key, playerGroup in pairs(self.activePlayers) do
		local group = table.find(playerGroup, player) :: number?
		if(group) then
			return playerGroup
		end
	end
	return 
end

-- Add player to preservation and if all group members say yes, preserve group 
function Matchmaking:PossiblePreserve(player: Player): nil
	local group = self:GetGroup(player) :: {Player}
	if(not group or #group ~= 2) then return end
	if((self.currentRound) % self.roundsToFinish == 0) then
		self:HandleAttemptedContinue()
		return
	end
	for _, player2 in ipairs(group) do
		if(self:Isblacklisted(player, player2)) then
			return
		end
	end
	
	
	local loc = table.find(self.possiblePreservations, player) :: number?
	if(not loc) then
		table.insert(self.possiblePreservations, player)
	end
	for _, player2 in ipairs(group) do
		loc = table.find(self.possiblePreservations, player2)
		if(not loc) then
			return
		end
	end
	self:ContinueMatch(table.unpack(group))
	return
end

-- Remove player from preservation list and if they are already planning on preserving, remove them from that too 
function Matchmaking:RemovePreservation(player: Player): nil
	local loc = table.find(self.possiblePreservations, player) :: number?
	if(not loc) then return end
	table.remove(self.possiblePreservations, loc)
	local group = self:GetGroup(player) :: {Player}
	
	if(group) then
		for _, player in ipairs(group) do
			local loc2 = table.find(self.preservedPlayers, player) :: number?
			if(loc2) then
				table.remove(self.preservedPlayers, loc2)
			end

		end
	end


	return
end



function Matchmaking:CleanPlayerInstance(player: Player): nil
	local character = player and player.Character :: Model
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: Part
	self:LeaveQueue(player)

	if(rootPart and rootPart.CollisionGroup and rootPart.CollisionGroup ~= "Default") then
		table.insert(self.unusedCollisionGroups, rootPart.CollisionGroup)
		
		local loc = table.find(self.activeCollisionGroups, rootPart.CollisionGroup) :: number?
		if(loc) then
			table.remove(self.activeCollisionGroups, loc)
		end
		
		self:ChangeCharacterCollisionGroup(player, "Default")


	end

	return
end

-- Returns time left in seconds in current round
function Matchmaking:TimeUntilEnd(): number
	local timeElapsed = (tick() - self.lastRoundStart)
	return (self.roundtime*60) - timeElapsed
end

-- Returns time until the next round
function Matchmaking:TimeUntilNext(): number
	local timeElapsed = (tick() - self.lastRoundStart)
	return (self.roundtime * 60 + (self.downtime * 60)) - timeElapsed
end

-- Deletes this matchmaking instance (for future use only)
function Matchmaking:DeleteInstance(): nil
	setmetatable(self, nil)
	for k in pairs(self) do
		self[k] = nil 
	end
	return
end


return Matchmaking

