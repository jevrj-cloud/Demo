--!strict
local WallRunModule = {}
WallRunModule.__index = WallRunModule

---------------------------------------------------------------------
-- Services
---------------------------------------------------------------------
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")


---------------------------------------------------------------------
-- Modules
---------------------------------------------------------------------
local Signal = require(script.Parent.GoodSignal) 

---------------------------------------------------------------------
-- Events
---------------------------------------------------------------------
local getData = ReplicatedStorage:WaitForChild("ReplicatedModules").Events.retrieveWallrun 
local runState = ReplicatedStorage:WaitForChild("ReplicatedModules").Events.runStateChange 
local updatePermissions = ReplicatedStorage:WaitForChild("ReplicatedModules").Events.wallrunPerm 


---------------------------------------------------------------------
-- Default Variable Params DO NOT EDIT HERE
---------------------------------------------------------------------

WallRunModule.MIN_DIST = 5 :: number -- player must be x studs off ground to initiate wall run (cancels when dip)
WallRunModule.MOBILE_LOCATION = UDim2.new(0.8, 0, 0.7, 0) :: UDim2 
WallRunModule.JUMP_POWER = 50 :: number -- Adjust height
WallRunModule.DEBOUNCE = 0.2 :: number -- time between runs (cooldown)
WallRunModule.DURATION = 2 :: number -- max duration of run 
WallRunModule.MAX_APPROACH_ANGLE = 45 -- angle of approach to wall, smaller means more inline
WallRunModule.MIN_SPEED = 30 -- min speed to start run

WallRunModule.ANIMATIONS_LEFT = {
	[1] = {
		animId = "http://www.roblox.com/asset/?id=507767714",
		animWeight = 100,
		priority = Enum.AnimationPriority.Movement,
		speed = 2,
		looped = true
	}
} -- these are played all together during a wall run if wall is on left 
WallRunModule.ANIMATIONS_RIGHT = {
	[1] = {
		animId = "http://www.roblox.com/asset/?id=507767714",
		animWeight = 100,
		priority = Enum.AnimationPriority.Movement,
		speed = 2,
		looped = true
	}
} -- these are played all together during a wall run if wall is on right 


WallRunModule.SOUNDS = {
	[1] = {
		soundID = "rbxassetid://82357128779870",
		volume = 2,
		duration = 2, -- if sound ends faster, won't last whole duration
		looped = true,
		speed = 2
	}
} -- these are played all together during a wall run 

WallRunModule.STARTKEYBINDS = { -- ensure index sequentially (1,2,3, ...)
	[1] = Enum.KeyCode.Space,
	[2] = Enum.KeyCode.W
} -- keybinds to start (all must be pressed)

WallRunModule.ENDKEYBINDS = { -- ensure index sequentially (1,2,3, ...)
	[1] = Enum.KeyCode.Space,
	[2] = Enum.KeyCode.W,
} -- keybinds to end (any release will end skill )

---------------------------------------------------------------------
-- Helper functions 
---------------------------------------------------------------------

local function getUnion(list1: {Enum.KeyCode}, list2: {Enum.KeyCode}): {Enum.KeyCode}
	local seen: {[Enum.KeyCode]: boolean} = {}
	local result: {Enum.KeyCode} = {}

	for _, key in ipairs(list1) do
		if not seen[key] then
			seen[key] = true
			table.insert(result, key)
		end
	end

	for _, key in ipairs(list2) do
		if not seen[key] then
			seen[key] = true
			table.insert(result, key)
		end
	end

	return result
end



local Module = {["Cache"] = {}}

local function GetAnimator(Model)
	if not Model then
		return
	end
	local Controller = Model:FindFirstChild("Humanoid") or Model:FindFirstChild("AnimationController")
	if not Controller then
		return
	end
	return Controller:FindFirstChild("Animator")
end

local function LoadAnim(Model,Animation)
	if not Model or not Animation then
		return
	end
	local Animator = GetAnimator(Model) :: Animator?
	if not Animator then
		return
	end
	if not Module["Cache"][Animator] then
		Module["Cache"][Animator] = {}
	end
	if not Module["Cache"][Animator][Animation] then
		Module["Cache"][Animator][Animation] = Animator:LoadAnimation(Animation)
		--print("Wasn't cached, creating new Animation",Animation.Name);
	else
		--print("This animation was already cached",Animation.Name);
	end
	return Module["Cache"][Animator][Animation]
end

local function stopAnimations(model)
	local animator = GetAnimator(model) :: Animator?
	if not animator then
		return
	end

	local cachedAnims = Module["Cache"][animator]
	if not cachedAnims then
		return
	end

	for animKey, animTrack in pairs(cachedAnims) do
		if animTrack.IsPlaying then
			animTrack:Stop()
		end
		-- Remove the track from the cache to allow it to be garbage collected.
		cachedAnims[animKey] = nil
	end

end

local function isNearGround(self, player: Player): boolean
	local character = player.Character
	if(not character) then
		warn("character "..player.Name.." doesn't exist")
		return true
	end
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	local rayOrigin: Vector3 = rootPart.Position
	local rayDirection: Vector3 = Vector3.new(0, -self.MIN_DIST, 0)

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(rayOrigin, rayDirection, rayParams)
	return result ~= nil
end

local function getOrthogonal(hrp: BasePart, wallPart: BasePart)
	local providedPoint = hrp.Position

	-- Choose a point on the wall (using its Position)
	local planePoint = wallPart.Position

	-- Get the wall's surface normal (assuming the front face normal is the LookVector)
	local normal = wallPart.CFrame.LookVector

	-- Compute the vector from the wall's point to the provided point
	local vectorToPoint = providedPoint - planePoint

	-- Compute the distance along the normal (dot product)
	local distance = vectorToPoint:Dot(normal)

	-- Subtract the offset to find the projection on the plane
	local closestPointOnWall = providedPoint - (distance * normal)

	return (providedPoint-closestPointOnWall).Unit


end

local function getParallel(hrp: BasePart, wallPart: BasePart)
	local providedPoint = hrp.Position

	-- Choose a point on the wall (using its Position)
	local planePoint = wallPart.Position

	-- Get the wall's surface normal (assuming the front face normal is the LookVector)
	local normal = wallPart.CFrame.LookVector

	local up = Vector3.yAxis
	local parallel = normal:Cross(up).Unit

	-- Ensure direction is consistent relative to HRP's facing
	if parallel:Dot(hrp.CFrame.LookVector) < 0 then
		parallel = -parallel
	end
	return parallel
end

---------------------------------------------------------------------
-- Main Functions
---------------------------------------------------------------------

local allowRun = false :: boolean

-- Constructor for wall run controller. Accepts the player character.
function WallRunModule.new(player: Player)
	local self = setmetatable({}, WallRunModule)
	self.player = player

	local character = player.Character :: Model
	local hrp = character and character:WaitForChild("HumanoidRootPart", 15) :: BasePart
	if(not hrp) then
		warn("Humanoid root part unable to render")
	end


	-- Create custom signals for wall run start and end.
	self.WallRunStarted = Signal.new()
	self.WallRunEnded = Signal.new()
	self.isWallRunning = false :: boolean
	self.currentWall = nil :: BasePart?

	self.enabled = false

	updatePermissions.OnClientEvent:Connect(function(enabled: boolean)
		self.enabled = enabled
	end)

	-- Allow server to stop execution at any time 
	runState.OnClientEvent:Connect(function()
		if(self.isWallRunning) then
			self:EndWallRun()
		end
	end)


	-- Setup hitbox 

	local hitbox = Instance.new("Part")
	hitbox.Size = Vector3.new(4, 6, 4) -- adjust for character size
	hitbox.CFrame = hrp.CFrame
	hitbox.Transparency = 1
	hitbox.CanCollide = false
	hitbox.Anchored = false
	hitbox.Name = "Hitbox"
	hitbox.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Parent = hitbox
	weld.Part0 = hitbox
	weld.Part1 = hrp

	-- Debounce
	local dbStart = false :: boolean 


	local keybinds = getUnion(self.STARTKEYBINDS, self.ENDKEYBINDS)
	local keyDown = {} :: {[any]: boolean} -- true if holding down 
	


	
	-- get data asynch 

	task.spawn(function()
		local success, res = pcall(function()
			return getData:InvokeServer()
		end)

		if(not success) then
			warn("Error retrieving data: "..res)
		else

			self.MIN_DIST = res.MIN_DIST or WallRunModule.MIN_DIST
			self.MOBILE_LOCATION = res.MOBILE_LOCATION or WallRunModule.MOBILE_LOCATION
			self.JUMP_POWER = res.JUMP_POWER or WallRunModule.JUMP_POWER
			self.DEBOUNCE = res.DEBOUNCE or WallRunModule.DEBOUNCE
			self.DURATION = res.DURATION or WallRunModule.DURATION
			self.MAX_APPROACH_ANGLE = res.MAX_APPROACH_ANGLE or WallRunModule.MAX_APPROACH_ANGLE
			self.MIN_SPEED = res.MIN_SPEED or WallRunModule.MIN_SPEED

			self.ANIMATIONS_LEFT = res.ANIMATIONS_LEFT or WallRunModule.ANIMATIONS_LEFT
			self.ANIMATIONS_RIGHT = res.ANIMATIONS_RIGHT or WallRunModule.ANIMATIONS_RIGHT

			self.SOUNDS = res.SOUNDS or WallRunModule.SOUNDS

			self.STARTKEYBINDS = res.STARTKEYBINDS or WallRunModule.STARTKEYBINDS

			self.ENDKEYBINDS = res.ENDKEYBINDS or WallRunModule.ENDKEYBINDS
			
			-- Connect to space usage w/ ContextActionService
			keybinds = getUnion(self.STARTKEYBINDS, self.ENDKEYBINDS)
			

			local function validateWallRun(actionName, inputState, inputObject)
				for i, bind in ipairs(keybinds) do
					if(inputObject.KeyCode == bind) then
						if(inputState == Enum.UserInputState.End and not UIS:IsKeyDown(bind)) then
							keyDown[bind] = false
						else
							keyDown[bind] = true
						end
						--keyDown[bind] = inputState == Enum.UserInputState.Begin
					end
					
					if(inputObject.UserInputType == bind) then
						keyDown[bind] = inputState == Enum.UserInputState.Begin

					end

				end


				local allowStart = true
				for key, bind in pairs(self.STARTKEYBINDS) do
					if(not keyDown[bind]) then
						allowStart = false
					end
				end
				
				local allowEnd = false
				for key, bind in pairs(self.ENDKEYBINDS) do

					if(not keyDown[bind]) then
						allowEnd = true
						if(self.isWallRunning) then
							allowRun = false
							if self.isWallRunning then
								self:EndWallRun()
							end
						end
					end
				end


				-- Start wall run when both keys are held
				if allowStart then
					if not dbStart then
						dbStart = true
						task.delay(0.1, function() dbStart = false end)

						allowRun = true
						local touching = hitbox:GetTouchingParts()


						for _, otherPart in ipairs(touching) do

							self:StartWallRun(otherPart)
						end
					end
				elseif(allowEnd) then
					-- If either key is no longer down
					allowRun = false
					if self.isWallRunning then
						self:EndWallRun()
					end
				end

				return Enum.ContextActionResult.Pass
			end

			
			ContextActionService:BindAction("WallRun", validateWallRun, true, table.unpack(keybinds))

			task.defer(function()
				local button = ContextActionService:GetButton("WallRun")
				if button then
					button.Position = self.MOBILE_LOCATION 
				end
			end)
			
			
		end
	end)



	local wallPart = nil :: BasePart?
	local renderSteppedConnection = nil :: RBXScriptConnection?
	hitbox.Touched:Connect(function(hit)
		if(not wallPart and CollectionService:HasTag(hit, "WallRun")) then
			wallPart = hit
			-- If player continues to be on part and jumps, wait for them to get high enough 
			-- Prevent mem leak
			if(renderSteppedConnection and renderSteppedConnection.Connected) then
				renderSteppedConnection:Disconnect()
				renderSteppedConnection = nil
			end

			renderSteppedConnection = RunService.RenderStepped:Connect(function()

				if self:CheckWall(hit) then
					local allowStart = true
					for key, bind in pairs(self.STARTKEYBINDS) do
						if(not keyDown[bind]) then
							allowStart = false
						end
					end

					if(allowStart) then
						self:StartWallRun(hit)
						if(renderSteppedConnection and renderSteppedConnection.Connected) then
							renderSteppedConnection:Disconnect()
							renderSteppedConnection = nil
						end

					end
				end
			end)
		end

		if self:CheckWall(hit) then
			local allowStart = true
			for key, bind in pairs(self.STARTKEYBINDS) do
				if(not keyDown[bind]) then
					allowStart = false
				end
			end
			if(allowStart) then
				self:StartWallRun(hit)
			end
		end
	end)

	hitbox.TouchEnded:Connect(function(hit)
		if(hit == wallPart) then
			wallPart = nil
			if(renderSteppedConnection and renderSteppedConnection.Connected) then
				renderSteppedConnection:Disconnect()
				renderSteppedConnection = nil
			end

		end
	end)


	return self
end

-- Uses CollectionService to check if a part is tagged "WallRun".
function WallRunModule:CheckWall(hitPart)
	-- General check 
	local check1 = hitPart and hitPart:IsA("BasePart") and CollectionService:HasTag(hitPart, "WallRun") and not isNearGround(self, self.player) and allowRun
	if(not check1) then
		return false
	end
	-- Get angle of approach
	local character = self.player.Character :: Model
	local hrp = character and character:WaitForChild("HumanoidRootPart", 15) :: BasePart
	if(not hrp) then
		warn("Humanoid root part unable to render")
		return false
	end
	
	local vec = getOrthogonal(hrp, hitPart) :: Vector3
	local angle = 90 - math.deg(math.acos(vec.Unit:Dot(hrp.CFrame.LookVector)))

	if(math.abs(angle) > self.MAX_APPROACH_ANGLE) then
		return false
	end

	-- min speed
	local velocity = hrp.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if(speed < self.MIN_SPEED) then
		return false
	end

	return true
end

-- Initiates wall running if the hit part qualifies.

local autoCancelTask = nil :: thread?
local wallRunDb = false :: boolean

local originalJumpPower = 0
local originalJumpHeight = 0


function WallRunModule:StartWallRun(hitPart)
	if(not self.enabled) then return end
	if not self.isWallRunning and self:CheckWall(hitPart) then


		if(wallRunDb) then return end
		wallRunDb = true


		local character = self.player.Character :: Model
		local hrp = character and character:WaitForChild("HumanoidRootPart", 15) :: BasePart
		if(not hrp) then
			warn("Humanoid root part unable to render")
			return
		end
		
		

		local rv = CFrame.new(hrp.Position, hrp.Position + getParallel(hrp, hitPart)).RightVector
		local dot = math.clamp(rv:Dot(getOrthogonal(hrp, hitPart)), -1, 1) 
		local angle = math.abs(math.deg(math.acos(dot)))

		

		-- Duration expire
		autoCancelTask = task.delay(self.DURATION, function()
			autoCancelTask = nil
			if(self.isWallRunning) then
				self:EndWallRun()
			end

		end)

		local humanoid = character:FindFirstChild("Humanoid") :: Humanoid

		if(humanoid) then
			originalJumpPower = humanoid.JumpPower
			humanoid.JumpPower = 0 -- R15
			-- or if using JumpHeight (R6 or newer systems)
			originalJumpHeight = humanoid.JumpHeight

			humanoid.JumpHeight = 0
		end


		hrp.CFrame = CFrame.new(hrp.Position, hrp.Position + getParallel(hrp, hitPart))




		-- determine if playing right or left anim 
		local anims = (angle > 100 and self.ANIMATIONS_RIGHT) or self.ANIMATIONS_LEFT

		for key, animList in pairs(anims) do
			if(animList) then
				local animation = Instance.new("Animation")
				animation.AnimationId = animList.animId
				local animTrack = LoadAnim(character, animation) :: AnimationTrack?
				if(animTrack) then
					animTrack:AdjustWeight(animList.animWeight, 0) -- 0 is the fade time (no fade)
					animTrack.Priority = animList.priority -- or Action if needed

					animTrack:Play()
					animTrack:AdjustSpeed(animList.speed)

				end

			end
		end


		runState:FireServer(hitPart, CFrame.new(hrp.Position, hrp.Position + getParallel(hrp, hitPart)))

		self.isWallRunning = true
		self.currentWall = hitPart  -- store the wall part in case you need it later (e.g. for directional impulses)
		self.WallRunStarted:Fire(hitPart, self.DURATION)
	end
end

-- Ends wall running, firing the appropriate signal.
function WallRunModule:EndWallRun()
	if self.isWallRunning then
		local character = self.player.Character :: Model
		local hrp = character and character:WaitForChild("HumanoidRootPart", 15) :: BasePart
		if(not hrp) then
			warn("Humanoid root part unable to render")
		end
		-- Cancel auto removal 

		if(autoCancelTask) then
			task.cancel(autoCancelTask)
			autoCancelTask = nil
		end

		stopAnimations(character)

		-- reset jump 

		local humanoid = character:FindFirstChild("Humanoid") :: Humanoid

		if(humanoid) then
			humanoid.JumpPower = (originalJumpPower == 0 and 50) or originalJumpPower

			humanoid.JumpHeight = (originalJumpHeight == 0 and 7.2) or originalJumpHeight
		end


		-- Start delay to recreate db
		task.delay(self.DEBOUNCE, function() wallRunDb = false end)

		-- Generate orthog vector 

		local orthog = Vector3.new(1,1,1)
		if(self.currentWall) then
			orthog = getOrthogonal(hrp, self.currentWall)
		end


		--local weld = (hrp:FindFirstChild("RunWeld")) :: WeldConstraint
		--if(weld) then
		--	weld:Destroy()
		--end

		local direction = Vector3.new(
			(self.JUMP_POWER) * orthog.X,
			self.JUMP_POWER,
			(self.JUMP_POWER) * orthog.Z
		) :: Vector3

		hrp.AssemblyLinearVelocity = direction

		runState:FireServer(self.currentWall, hrp.CFrame)

		self.isWallRunning = false
		self.WallRunEnded:Fire()
		self.currentWall = nil
	end
end


return WallRunModule

--TODO prevent jump anim when wallrunning 
