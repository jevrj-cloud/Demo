local Turret = {}
-- Defines to look at Turret implementation structure when a key can't be found in an instance of Turret
Turret.__index = Turret

-- TODO prevent barrel from going into base | shoot at the position of character * velocity 

--[[
	Note to reviewer:

	File structure:
	
	TurretModule -> ServerStorage
	TurretScript -> StarterPlayerScripts
	BulletFired event -> Replicated Storage

]] 


-- Define the services for later use
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Local communication event
local BulletFiredEvent = ReplicatedStorage:FindFirstChild("BulletFired") 


-- Private functions

-- This event executed a shot 
local function Shoot(self)
	-- At any point (recurring through the code) check to ensure that the player has not left the game
	if not self.targetRootPart then 
		self:Deactivate()
		warn("Deactivating turret, character not found")
		return
	end

	-- Iterate over the number of bullets in spread
	for i = 1, self.NUM_BULLETS_IN_SPREAD do
		-- Idea, within SPREAD, generate n bullets uniformly heading towards the player
		-- Reason is to prevent floating point errors from accumulating on the relational CFrame parts that move around
		-- Barrel length is 15 studs
		local barrelLength = 15
		-- Take a slight prediction of char position by adding the normalized velocity scaled to 5 studs ahead of the current player 
		local predictedPos = (self.targetRootPart.Position) + self.targetRootPart.Velocity.Unit*5
		-- Get the unit vector direction of shooting by subtracting the vectors to get the lv from gun part and normalizing it
		local shootDirection = (predictedPos - self.gun_part.Position).Unit
		-- Get the unit right vector AKA xvector relational to the gunpart
		local xVector = self.gun_part.CFrame.RightVector
		-- Gets the multiplier spread / number bullets for use later. If only one bullet, ensure centering with a 0 mult using a ternary 
		local iterMult = self.NUM_BULLETS_IN_SPREAD == 1 and 0 or self.SPREAD/ self.NUM_BULLETS_IN_SPREAD
		-- Does some algebra with the goal of getting spread / 2 when i = 1 or i = n. 
		-- Goal is to apply that to the horizontal vector so we get exactly spread wide 
		-- Idea: take the absolute difference between n/2 and i, ceiling for even calc, multiply by our multiplier earlier
		-- To get spread / 2 verifiable with algebra
		local iterationAmount = math.ceil(math.abs(i - self.NUM_BULLETS_IN_SPREAD/2))*iterMult
		-- Get the sign to go left, right, or center by doing n+1/ 2 to consistently find if an i val is to the right or left
		-- of the centerpoint, the sign difference says to go left or right, the multiply by the iteration amount for the distance
		-- and x vector for the direction 
		local changeVector = math.sign(i-((self.NUM_BULLETS_IN_SPREAD+1)/2))*iterationAmount*xVector
		-- Add this new distance vector to the gun root after adding a offset for the barrel length
		local bulletPosition = self.gun_part.Position + barrelLength*shootDirection + changeVector
		
		-- Give this precalculated position to the client along with parameters to configure bullet motion so that bullet can be generated
		-- I chose to use client here for efficient replication and smooth bullet motion / accurate touch cancellation
		-- Firing on all clients, but damage does not propagate because connection is instantly severed on local
		BulletFiredEvent:FireAllClients(bulletPosition, shootDirection, self.BULLET_SPEED, self.BULLET_CLEAN_TIMER)
		

	end


end

-- This is a internal helper to start tracking the character
local function StartTracking(self)
	
	-- If already tracking something, disconnect that connection so it doesn't cause issues
	if(self.trackingConnection) then
		self.trackingConnection:Disconnect()
	end
	
	-- Connect to the heartbeat function for fast calculations over time
	self.trackingConnection = RunService.Heartbeat:Connect(function()
		-- Validate that the character did not leave during the duration of this connection
		if not self.targetRootPart then 
			warn("Deactivating turret, character not found")
			self:Deactivate()
			return
		end
		-- Calculate the range of a bullet by doing speed (studs / seconds) by time (seconds) to get studs travelled
		local range = self.BULLET_SPEED * self.BULLET_CLEAN_TIMER
		-- Get the vector between target and gun and find magnitude to get distance between in studs. If the character exited the 
		-- effective travel distance of a bullet, stop firing. Adding 15 for the barrel size
		if((self.gun_part.Position - self.targetRootPart.Position).Magnitude > range+15) then
			self.isShooting = false
		elseif(not self.isShooting and self.tryingToShoot) then -- If trying to shoot (true when shooting is deactivated due to exiting range) shoot again
			self:StartShooting()
		end


		-- Get humanoid from target 
		local humanoid = self.targetRootPart.Parent:FindFirstChild("Humanoid")
		-- If humanoid exists in target (sanity check) and the humanoid is dead, set to idle state and break the function
		if(humanoid) then
			if(humanoid.Health <= 0)  then
				self:Idle()
				return
			end
		end
		
		
		-- Get a look vector from the origin to 3 studs below the target root part (for better visuals) and normalize
		local lv = ((self.targetRootPart.Position - Vector3.new(0, 3, 0)) - self.origin.Position).Unit
		
		-- Following math is borrowed, will go into higher detail than was offered in docs to show understanding
		-- Transition the previously calculated lookvector in the object space relative to the gun and base
		local gunlv = self.gun_part.CFrame:VectorToObjectSpace(lv)
		local bodylv = self.base_part.CFrame:VectorToObjectSpace(lv)
		
		
		-- X rotation is calculated by taking the sin of our object space gun LV. This works as follows:
		-- Gun is the only part that should be moving up and down. the triangle formed in 2D has a hypotenuse of 1 (since we previously set the lv as a unit vector - size 1)
		-- and a height of gunlv.Y because the vector is described by its end point, and taking the Y relative to gun will tell us how much the y is deviating from the
		-- current y position of the gun. Since sin = opposite / hypotenuse, we take the arcsin of opposite / 1 (hypotenuse) to get the angle to rotate the x, thus shifting y
		local xRotation = math.asin(gunlv.Y)
		-- atan2 works by taking the angle with respect to the positive Z. Mapping to a coordinate plane with Z as the y-axis and X as x-axis, we want to know the horizontal 
		-- rotation change. To do this, imagine a projected vector onto the first quadrant which represents the bodyLv X and Z. The angle between the positive z axis and the 
		-- vector is given by tan(X/Z) since opposite over adjacent. However this tells us the angle to move from the positive z direction, but our turret points in the neg z
		-- So adding pi will negate that offset to get the correct rotation. Note that atan2 is helpful since it always takes with respect to the pos z regardless of what quadrant
		local yRotation = math.atan2(bodylv.X, bodylv.Z) + math.pi

		-- Simply apply the calculated rotations to the cframe by applying the orientation. Not using pivotTo since it rotates along z 
		self.gun_part:PivotTo(self.gun_part.CFrame * CFrame.fromOrientation(xRotation, yRotation, 0))
		self.base_part:PivotTo(self.base_part.CFrame * CFrame.fromOrientation(0, yRotation, 0))
		--self.gun_part:PivotTo(CFrame.lookAt(self.gun_part.Position, self.targetRootPart.Position))


	end)
end


-- Public functions

-- Generates a new turret instance
function Turret.new(gun_part: BasePart, params)
	
	-- If unable to get key turret parts, warn user and return no object
	if(not gun_part or not gun_part.Parent.body.base or not gun_part.Parent.base) then
		warn("turret part is nil. Cannot create turret.")
		return nil
	end
	
	-- Creates new instance of turret, assigns to self, sets instance to inherit from turret class stucture
	local self = setmetatable({}, Turret)
	
	-- Set class variables
	self.gun_part = gun_part.base
	self.base_part = gun_part.Parent.body.base
	self.origin = gun_part.Parent.base
	
	-- Set key constants, which are exposed externally for tweaking per instance  
	self.BULLET_SPEED = 100
	
	-- Bullets per second
	self.FIRE_RATE = 50
	self.BULLET_CLEAN_TIMER = 2
	self.DAMAGE = 0.1
	self.NUM_BULLETS_IN_SPREAD = 2
	self.SPREAD = 1
	
	-- Assign custom parameters if optionally passed into the init function
	if params then
		-- Checks with a simple ternary, if params nil just take original value
		self.BULLET_SPEED = params.BULLET_SPEED or self.BULLET_SPEED
		self.FIRE_RATE = params.FIRE_RATE or self.FIRE_RATE
		self.BULLET_CLEAN_TIMER = params.BULLET_CLEAN_TIMER or self.BULLET_CLEAN_TIMER
		self.DAMAGE = params.DAMAGE or self.DAMAGE
		self.NUM_BULLETS_IN_SPREAD = params.NUM_BULLETS_IN_SPREAD or self.NUM_BULLETS_IN_SPREAD
		self.SPREAD = params.SPREAD or self.SPREAD
	end
	
	-- Warns user for out of scope values 
	if(self.FIRE_RATE > 60) then
		warn("High fire rate, may cause irregularities")
	end
	if(self.BULLET_SPEED > 700) then
		warn("High speed, may cause irregularities")
	end
	
	-- Enter idle state
	self.isShooting = false
	
	self:Idle()
	
	return self
end

-- Exposed function to lock onto a player
function Turret:lockOn(player: Player)
	
	local character = player and player.Character
	local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")

	-- Check if humanoid root part, if so start tracking and set as a class var. If not warn
	if humanoidRootPart then
		-- Remove idle connection if in idle state
		if self.isIdleConnection then
			self.isIdleConnection:Disconnect()
			-- Set to nil to ensure efficient existence checks
			self.isIdleConnection = nil
		end
		
		self.targetRootPart = humanoidRootPart
		StartTracking(self)
	else
		warn("Failed to lock, character not found")
	end


end

-- Function exists to remove a character from the turret instance and then idle. Simply for convenience and intuitiveness
function Turret:lockOff()

	self.targetRootPart = nil
	self:Idle()

end


-- Exposed method to start shooting
function Turret:StartShooting()
	-- If character left, deactivate (typical)
	if(not self.trackingConnection) then
		warn("Deactivating turret, character not found")
		self:Deactivate()
		return
	end
	-- If already shooting, don't re-initialize shooting system
	if(self.isShooting) then return end
	self.isShooting = true
	self.tryingToShoot = true
	
	-- Commented debounce code in case for exploitation, but due to the nature of the fast hit timers it causes lag delay on hits
	--local db = false
	
	-- Before making bullet connection, disconnect if it already exists
	if self.bulletHitConnection then
		self.bulletHitConnection:Disconnect()
	end
	
	-- Create a local connection for when a touched event is fired and we want to create a hit effect
	self.bulletHitConnection = BulletFiredEvent.OnServerEvent:Connect(function(player, hit)
		--if db then return end
		--db = true
		--local dbTime = 1/self.FIRE_RATE
		--task.delay(dbTime - dbTime*0.3, function()
		--	db = false
		--end)
		if not hit then return end
		
		-- No need to error handle, tracking connection would be live and checking for this event
		if self.targetRootPart then
			-- Get range w/ same calculation earlier
			local range = self.BULLET_SPEED * self.BULLET_CLEAN_TIMER
			-- Do the same magnitude check as earlier, but this time give some leniency for server issues (10%)
			if((self.gun_part.Position - self.targetRootPart.Position).Magnitude < (range + range*0.1)) then
				-- Get humanoid from character class
				local model = hit:FindFirstAncestorWhichIsA("Model") 
				local humanoid =  model and model:FindFirstChildOfClass("Humanoid") 

				-- Deal damage on server side
				if humanoid then
					humanoid:TakeDamage(self.DAMAGE)  
				end
			end
			
		end
	end)

	-- Iterate over the effects and set the particles = true for effects
	local effects = {self.gun_part.Parent.effect.smoke, self.gun_part.Parent.effect2.smoke}
	for _, part in ipairs(effects) do
		if part then
			part.Enabled = true
		end
	end
	
	-- Create the shooting function for the period fire rate that runs the shoot helper method. When is shooting becomes false this turns off
	task.spawn(function()
		while self.isShooting do
			Shoot(self)
			task.wait(1/self.FIRE_RATE)
		end
	end)
end



-- Wrapper function for best practices and ease of use to stop shooting
function Turret:StopShooting()
	-- Reset possibly live connections and variables 
	self.isShooting = false
	self.tryingToShoot = false
	if(self.bulletHitConnection) then
		self.bulletHitConnection:Disconnect()
		self.bulletHitConnection = nil
	end
	-- Remove effects with a similar process from adding them before
	local effects = {self.gun_part.Parent.effect.smoke, self.gun_part.Parent.effect2.smoke}
	for _, part in ipairs(effects) do
		if part then
			part.Enabled = false
		end
	end
	
end

-- Idle function for preventing strange turret movements 
function Turret:Idle()

	-- Get the rotation calculation the same way from earlier, but this time use a look vector for the base part 
	-- this is recalculated since in the instant of deactivation the turret may move / lag and cause invariant behavior
	local lv = self.base_part.CFrame.LookVector
	local gunlv = self.gun_part.CFrame:VectorToObjectSpace(lv)
	local bodylv = self.base_part.CFrame:VectorToObjectSpace(lv)

	local xRotation = math.asin(gunlv.Y)
	local yRotation = math.atan2(bodylv.X, bodylv.Z) + math.pi
	
	local lastCFGun = self.gun_part.CFrame * CFrame.fromOrientation(xRotation, yRotation, 0)
	local lastCFBase = self.base_part.CFrame * CFrame.fromOrientation(0, yRotation, 0)

	-- Delay 2 seconds before removing effects to simulate a cooldown effect on the barrel
	task.delay(2, function()
		local effects = {self.gun_part.Parent.effect.smoke, self.gun_part.Parent.effect2.smoke}
		for _, part in ipairs(effects) do
			if part then
				part.Enabled = false
			end
		end
	end)
	-- Reset the rest of the vars and connections 
	self.isShooting = false 
	self.tryingToShoot = false
	if self.trackingConnection then
		self.trackingConnection:Disconnect()
		self.trackingConnection = nil
	end
	if(self.bulletHitConnection) then
		self.bulletHitConnection:Disconnect()
		self.bulletHitConnection = nil
	end
	
	-- Validate that the idle isnt already live
	if self.isIdleConnection then
		self.isIdleConnection:Disconnect()
	end
	
	-- No connections already exist, so create a new connection for idle and constantly train the gun on designated CFrame 
	if(not self.isIdleConnection) then
		self.isIdleConnection = RunService.Heartbeat:Connect(function()
			self.gun_part:PivotTo(lastCFGun)
			self.base_part:PivotTo(lastCFBase)
		end)
	end

end

-- Deactivate the turret by resetting all parameters if possible 
function Turret:Deactivate()
	-- Seen before, not annotated
	if self.trackingConnection then
		self.trackingConnection:Disconnect()
		self.trackingConnection = nil
	end
	
	if self.isIdleConnection then
		self.isIdleConnection:Disconnect()
		self.isIdleConnection = nil
	end
	
	if(self.bulletHitConnection) then
		self.bulletHitConnection:Disconnect()
		self.bulletHitConnection = nil
	end
	
	self.isShooting = false  
	self.tryingToShoot = false
	self.targetRootPart = nil
	
	local effects = {self.gun_part.Parent.effect.smoke, self.gun_part.Parent.effect2.smoke}
	for _, part in ipairs(effects) do
		if part then
			part.Enabled = false
		end
	end
	
end

-- Completely destroy turret by first deactivating it and then destroying all pieces to it 
function Turret:Destroy()
	self:Deactivate()
	if(self.origin and self.origin.Parent) then
		self.origin.Parent:Destroy()
	end
	-- Destroy all references by setting metatable reference to nil after destruction
	setmetatable(self, nil)
end




return Turret
