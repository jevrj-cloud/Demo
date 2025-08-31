--!strict

--[[
NOTE TO REVIEWER: 

This is part of a larger combat framework meant to modularize combat tasks and handle those interactions for a multiplayer combat
This specific file is the crux for server-side routing in this system

AVAILABLE FUNCTIONALITIES IN GAME:
1. Double jumping
2. Skillset1 which just wires to a double jump
3. Wall running (approach wall and jump + W + space)
4. Sword skill

Assets and anims are pretty unrefined - They also are not preloaded so first attempt might be strange
--]]

local ServerManager = {}
ServerManager.__index = ServerManager

---------------------------------------------------------------------
-- Services
---------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

---------------------------------------------------------------------
-- Modules
---------------------------------------------------------------------

-- Using opensource signal to provide custom signal handling for certain key events (skill ended, cancelled, permissions updated, etc)
local Signal = require(ReplicatedStorage.CombatReplicatedStorage.SharedModules.GoodSignal) 
-- Central config file for all parameter adjustments
local Config = require(ServerStorage.CombatServerStorage.Config) 
-- My custom player stats module for managing player state - tied with PlayerStore 
local PlayerStats = require(ServerStorage.CombatServerStorage.SharedModules.PlayerStats)
-- This is a generic server-side skill template to handle typical operations like cooldown checking, permissions checking, etc. It acts as a wrapper
local SkillTemplate = require(ServerStorage.CombatServerStorage.SkillModules.Skills.ServerSkillTemplate)

---------------------------------------------------------------------
-- Events
---------------------------------------------------------------------

local populateConfigEvent = ReplicatedStorage.CombatReplicatedStorage.Events.populateConfig :: RemoteFunction
local changePermissionsEvent = ReplicatedStorage.CombatReplicatedStorage.Events.changePermissions :: RemoteEvent
local effectListener = ReplicatedStorage.CombatReplicatedStorage.Events.effectListener :: RemoteEvent
local killSkills = ReplicatedStorage.CombatReplicatedStorage.Events.killSkills :: RemoteEvent

---------------------------------------------------------------------
-- Helper 
---------------------------------------------------------------------

-- Type checking for convenience and safety (sub fields will be explained later)

type CustomSkillFunctions = {
	AllowSkill: (player: Player) -> boolean,
	[string]: (player: Player, skillParams: any, ...any) -> any
}

type Signal = typeof((Signal))

export type ServerManager<T> = {
	_connections: {RBXScriptConnection},
	_config: any,
	_permissions_signal: Signal,
	_player_init: Signal,
	_character_added: Signal,
	_humanoid_died: Signal,
	_player_removing: Signal,
	configDefaults: any,
	ChangeSkillsetRequirement: (self: ServerManager<T>, player: Player, skillName: string, enabled: boolean) -> (),
	ChangeSkillRequirement: (self: ServerManager<T>, player: Player, skillName: string, enabled: boolean) -> (),
	Destroy: (self: ServerManager<T>) -> (),
	Perms: (self: ServerManager<T>) -> ()

}


-- Send the client-exposed version of config to client on request
populateConfigEvent.OnServerInvoke = function()
	local exposed = Config.clientExposed()
	return exposed
end

-- Handle death of player - for multiplayer 
local function onDeath(self, character: Model, player: Player)
	local humanoid = character:WaitForChild("Humanoid", 3) :: Humanoid
	if(humanoid) then
		-- Not concerned about maintaining death connection - will clean on humanoid instance destruction
		humanoid.Died:Connect(function()
			-- If skillset is a tool then disable it on death in case player has it equipped
			-- The way I handle skillsets is a variable TOOL_MODE = boolean either turns a skillset into a tool or not. This tool can be cloned into player backpack / starterplayer
			-- Note each skillset is comprised of many skills
			-- skillsetenabled means all the relevant GUI and skills are enabled, which is true when tool equipped for a skill set where toolmode is true. 
			-- Else it could just be a passive skillset (movement) only enabled for some people by server
			-- Here, if a player has a tool and its enabled we don't want it on death, so disable
			for item, data in pairs(self._config.GENERAL.TOOL_MODE) do
				-- For all tools, if it exists as a skillset and it is enabled, disable it for player 
				if(self._config.SKILLS[item] and data.ENABLED) then
					self:ChangeSkillsetRequirement(player, item, false)
				end
			end
			-- Custom signal for making custom actions. Fires the humanoid death
			-- I use custom signals instead of re-binding to them to prevent race conditions
			-- Any custom signal fired means that all the operations from the framework have completed, now the custom behavior can begin
			self._humanoid_died:Fire(character, player)

		end)
	end
end

-- On character add just connect the death signal function and fire custom signal 
local function onCharacterAdded(self, character: Model, player: Player)
	onDeath(self, character, player)
	-- Similar custom signal
	self._character_added:Fire(character, player)
	
end

local function onPlayerAdded(self, signal: Signal, player: Player, playerConns: {[number]: {RBXScriptConnection}})
	-- Player connection passed by reference - modifications will populate up
	-- Establish the new player here - not worried about dual session issues here, handled elsewhere
	playerConns[player.UserId] = {}
	table.insert(playerConns[player.UserId], player.CharacterAdded:Connect(function(character)
		onCharacterAdded(self, character, player)
	end))
	
	if(player.Character) then
		onCharacterAdded(self, player.Character, player)
	end
	
	
	-- On character added, setup player stats
	
	-- All of these variables are for ease of data parsing and reformatting
	local skillSetIdentification = {} :: {[any]: any}
	
	local internalData = Config.config.GENERAL.PLAYER_STATS.STATS
	
	-- Setup defaults for skill and skillsets if not defined, and if toolmode for skillsets
	for setName, setData in pairs(Config.config.SKILLS) do
		for skillName, skillData in pairs(setData) do
			skillSetIdentification[skillName] = setName
		end
	end
	

	-- Init player stats with config defaults for player
	PlayerStats.init(player, self.configDefaults)
	
	-- Setup listeners to all player stats, and fire custom signal on change. Signal fired to local as well if not hidden
	for stat, data in pairs(self.configDefaults) do
		local updatedData = PlayerStats.get(player, stat)
		-- Using my player stats observe function, hook up to the entire server framework with permissions events that populate permission changes
		PlayerStats.observe(player, stat, function(value, oldValue)
			if(not internalData[stat].HIDDEN) then
				-- Notify client about the permission change for the stat
				changePermissionsEvent:FireClient(player, stat, value, oldValue, skillSetIdentification)
			end
			-- Fire custom signal for custom info 
			signal:Fire(player, stat, value, oldValue, skillSetIdentification)
		end)
		-- Fire once for initialization
		if(not internalData[stat].HIDDEN) then
			changePermissionsEvent:FireClient(player, stat, updatedData, {}, skillSetIdentification)
		end
		signal:Fire(player, stat, updatedData, {}, skillSetIdentification)
	end
	
	-- Kill state is a state that, when set for a player, stops all skills. This is useful for multiplayer combat handling with stun locks, etc
	-- Each skill module has all connections tied up, calling a single function will instantly pause and clean all skills. This skill pipeline is triggered from local for a given player
	if(self._config.GENERAL.PLAYER_STATS.KILL_STATE ~= nil and self._config.GENERAL.PLAYER_STATS.KILL_STATE ~= '') then
		PlayerStats.observe(player, "activeState", function(value, oldValue)
			if(value == self._config.GENERAL.PLAYER_STATS.KILL_STATE) then
				-- Notify client to kill skills 
				killSkills:FireClient(player)
			end
		end)
	end

	-- Custom signal
	self._player_init:Fire(player)
end

local function onPlayerRemoving(self, player: Player, playerConns: {[number]: {RBXScriptConnection}})
	-- Clean player connections
	if( playerConns[player.UserId] and #playerConns[player.UserId] ~= 0 ) then
		for _, conn in pairs(playerConns[player.UserId]) do
			if( conn and conn.Connected ) then
				conn:Disconnect()
			end
		end
	end
	playerConns[player.UserId] = nil
	self._player_removing:Fire(player)
end

-- Provide tool for every tool-mode skillset, can be cloned into player 
local function initializeToolMode(self, skillset)

	-- If toolmode, clones tool template
	local toolConfig = self._config.GENERAL.TOOL_MODE
	if(toolConfig[skillset] and toolConfig[skillset].ENABLED) then
		local tool = ReplicatedStorage:FindFirstChild("CombatReplicatedStorage").Dependencies:FindFirstChild("ToolTemplate"):Clone()
		--local file = ServerStorage:FindFirstChild("CombatTools") or Instance.new("Folder", ServerStorage)

		-- Puts the tools in the requested location
		local parentPath = game
		for _, path in ipairs(Config.config.GENERAL.TOOL_MODE.STORAGE_PATH) do
			parentPath = parentPath and parentPath[path]
		end

		-- filename = "CombatTools" (example)
		if(not parentPath) then
			warn("Tool storage path not found")
			return
		end

		-- Sets attribute of tool so it can know which skillset is used
		tool.Parent = parentPath
		tool.Name = skillset
		tool:SetAttribute("skillset", skillset)

		-- Allows for custom tool changes from config
		if(toolConfig[skillset].CUSTOMIZATION) then
			-- This function is defined in config, allows the tool photo to be changed, or any other tool property
			toolConfig[skillset].CUSTOMIZATION(tool)
		end

	end
end

---------------------------------------------------------------------
-- Main Functions
---------------------------------------------------------------------

function ServerManager.Init<T>(ps: T): ServerManager<T>
	-- Create instanced server manager
	local self: ServerManager<T> = setmetatable({}, ServerManager) :: any
	-- Effects need to be called from third-party modules so defined on a global level (effects are global anyway)
	ServerManager.effect_signal = Signal.new()

	self._connections = {}
	self._config = Config.config
	
	-- Instanced signals defined
	self._permissions_signal = Signal.new()
	self._player_init = Signal.new()
	self._character_added = Signal.new()
	self._humanoid_died = Signal.new()
	self._player_removing = Signal.new()
	
	
	local internalData = Config.config.GENERAL.PLAYER_STATS.STATS

	local toolMode = Config.config.GENERAL.TOOL_MODE
	self.configDefaults = {}
	local configDatastore = {}
	
	-- Generate datastore entry values, pcall in case user malforms the config file
	local success, res = pcall(function()
		for statName, statData in pairs(internalData) do
			self.configDefaults[statName] = statData.DEFAULTS
			configDatastore[statName] = statData.DATASTORE
		end
	end)
	if(not success) then
		warn("Error setting up player stat ", res)
	end

	-- Setup defaults for skill and skillsets if not defined, and if toolmode for skillsets
	for setName, setData in pairs(Config.config.SKILLS) do
		if(self.configDefaults["unlockedSkillsets"][setName] == nil) then
			self.configDefaults["unlockedSkillsets"][setName] = false
		else
			if(toolMode[setName] and toolMode[setName].ENABLED) then
				self.configDefaults["unlockedSkillsets"][setName] = false
			end
		end
		for skillName, skillData in pairs(setData) do
			if(self.configDefaults["unlockedSkills"][skillName] == nil) then
				self.configDefaults["unlockedSkills"][skillName] = false
			end
		end
	end
	
	-- Setup player stats for persistent datastore on player store module
	PlayerStats.setDataStore(self.configDefaults, configDatastore, Config.config.GENERAL.PLAYER_STATS.DATASTORE_NAME())

	
	-- Connects to effect changes, and if the effect is impacting a third party client, notifies that client on the effect
	ServerManager.effect_signal:Connect(function(event: string, effectLevel: string, person: Player, params)	
		-- Effect level is either Recieved or Applied (for example of a damage effect, one player applies damage and another player recieves it)
		if(person) then
			local success, res = pcall(function()
				-- Send the player client the notification that they had an effect applied / recieved
				-- This fires the corresponding signal (useful for things like GUI damage indicators with custom implementations)
				effectListener:FireClient(person, event, params, effectLevel)
			end)
			if(not success) then
				warn("Failed to populate effect to player ", person, " with error: ", res)
			end
		end
	end)

	-- For each skill init toolmode, and creates the server-side skill templates for each skill based on custom data
	for skillsetName, skillsetData in pairs(self._config.SKILLS) do
		if(not skillsetData) then continue end
		
		initializeToolMode(self, skillsetName)
		-- Call the wrapper instance on the specified definitions for each skillset and skill
		for skillName, skillData in pairs(skillsetData) do
			-- This uses a naming convention where the filename is the skillset name
			local skillsetModule = ServerStorage.CombatServerStorage.SkillModules.Skills:FindFirstChild(skillsetName)
			-- Same naming convention for skills
			local skillModule = skillsetModule and skillsetModule:FindFirstChild(skillName) :: ModuleScript
			if(not skillModule or not skillModule:IsA("ModuleScript")) then continue end
			
			-- Wrap in pcall for a variety of errors which shouldn't stop generation of all server skills
			local success, res = pcall(function()
				-- First require the necessary skill module with custom implementation
				skillModule = require(skillModule :: ModuleScript) :: CustomSkillFunctions
				-- Next initialize it with the skill template, which handles things like cooldowns, requirements, validation, etc. Reduces boilerplate
				SkillTemplate.Init(self, {
					SkillName = skillName,
					SkillsetName = skillsetName,
					AllowSkill =  skillModule.AllowSkill,
					CustomFunctions = skillModule,
					params = skillData
				})
			end)
			if(not success) then
				warn("Serverside skill generation failed for skill ", skillName, res)
			end

		end
	end
	
	return self
end

-- Generates the handlers. This is called externally, therefore separated into a different method for race condition purposes
function ServerManager:Perms()
	local playerConns = {}
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player: Player)
		onPlayerAdded(self, self._permissions_signal, player, playerConns)
	end))
	-- In case players in server before this function call (edgecase for some unknown reason, handle it here)
	for _, player: Player in ipairs(Players:GetPlayers()) do 
		onPlayerAdded(self, self._permissions_signal, player, playerConns)
	end
	
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		onPlayerRemoving(self, player, playerConns)
	end))
end

-- Destroy, never really used but implemented in case it is required moving forward
function ServerManager:Destroy()
	if(self._connections) then
		for _, connection in ipairs(self._connections) do
			if(connection and connection.Connected) then
				connection:Disconnect()
			end
		end
	end
	self._connections = {}
	setmetatable(self, nil)
end

-- Next two functions are similar, they toggle the permissions for a given user to use a skill / skillset
function ServerManager:ChangeSkillRequirement(player: Player, skillName: string, enabled: boolean)
	-- Player stats is my stat handler, here we see which unlocked skills a player has and toggle the given skill 
	local currSkills = PlayerStats.get(player, "unlockedSkills")
	if(currSkills[skillName] == nil) then
		warn(`{skillName} not found`)
		return
	end
	currSkills[skillName] = enabled
	-- This set will update all of the PlayerStats.observe("unlockedSkills") instances, immediately allowing a user to access / use skill
	PlayerStats.set(player, "unlockedSkills", currSkills)
end

-- This is almost identical to the skill implementation but for skillsets
function ServerManager:ChangeSkillsetRequirement(player: Player, skillsetName: string, enabled: boolean)
	local currSkillsets = PlayerStats.get(player, "unlockedSkillsets")
	if(currSkillsets[skillsetName] == nil) then
		warn(`{skillsetName} not found`)
		return
	end
	currSkillsets[skillsetName] = enabled
	PlayerStats.set(player, "unlockedSkillsets", currSkillsets)
end

return ServerManager
