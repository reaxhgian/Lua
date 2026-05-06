-- Connected Discord-GitHub
-- Discord: @its7dx (1467321234558681269)
-- Roblox: Vlxnrs
--[[
Luau Scripter Application Demo

Evaluation-relevant features:
- Metatable-based classes (projectile pool, turret controller)
- Predictive aiming with CFrame math + interception solver
- Physics projectiles, raycast verification, and server-side target validation
- Runtime optimization via pooling and controlled update cadence
]]

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local CONFIG = {
	MAX_TRACK_DISTANCE = 260,
	FIRE_COOLDOWN = 0.33,
	PROJECTILE_SPEED = 170,
	PROJECTILE_LIFETIME = 5,
	TARGET_REACQUIRE_INTERVAL = 0.05,
	MAX_LEAD_TIME = 2.4,
	IDLE_SWEEP_RATE = math.rad(22),
	MAX_AIM_ERROR_RAD = math.rad(20),
	DAMAGE = 20,
	POOL_SIZE_PER_TURRET = 24,
	FIRE_RAYCAST_PADDING = 1.5,
	TARGET_REBUILD_INTERVAL = 1,
}

type TurretState = "Idle" | "Tracking" | "CoolingDown"

type ProjectileTrack = {
	LastPosition: Vector3,
	ExpireAt: number,
}

type ProjectilePool = {
	Container: {BasePart},
	InUse: {[BasePart]: boolean},
	TouchedConnections: {[BasePart]: RBXScriptConnection},
	Acquire: (self: ProjectilePool) -> BasePart?,
	Release: (self: ProjectilePool, projectile: BasePart) -> (),
	Destroy: (self: ProjectilePool) -> (),
}

type Turret = {
	Base: BasePart,
	MuzzleAttachment: Attachment,
	State: TurretState,
	CurrentTarget: Model?,
	LastFireTime: number,
	LastReacquireTime: number,
	SweepAngle: number,
	ProjectilePool: ProjectilePool,
	ActiveProjectiles: {[BasePart]: ProjectileTrack},
	Update: (self: Turret, deltaTime: number, possibleTargets: {Model}) -> (),
	Destroy: (self: Turret) -> (),
}

local function clamp(value: number, minValue: number, maxValue: number): number
	if value < minValue then
		return minValue
	elseif value > maxValue then
		return maxValue
	end
	return value
end

local function safeUnit(vector: Vector3): Vector3
	local magnitude = vector.Magnitude
	if magnitude <= 1e-5 then
		return Vector3.new(0, 0, -1)
	end
	return vector / magnitude
end

local function solveInterceptTime(origin: Vector3, targetPos: Vector3, targetVel: Vector3, projectileSpeed: number): number?
	local relativePos = targetPos - origin
	local a = targetVel:Dot(targetVel) - (projectileSpeed * projectileSpeed)
	local b = 2 * relativePos:Dot(targetVel)
	local c = relativePos:Dot(relativePos)

	if math.abs(a) < 1e-6 then
		if math.abs(b) < 1e-6 then
			return nil
		end
		local t = -c / b
		if t > 0 then
			return t
		end
		return nil
	end

	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then
		return nil
	end

	local sqrtDiscriminant = math.sqrt(discriminant)
	local t1 = (-b - sqrtDiscriminant) / (2 * a)
	local t2 = (-b + sqrtDiscriminant) / (2 * a)

	local best = math.huge
	if t1 > 0 then
		best = t1
	end
	if t2 > 0 and t2 < best then
		best = t2
	end

	if best == math.huge then
		return nil
	end
	return best
end

local function createProjectilePart(): BasePart
	local projectile = Instance.new("Part")
	projectile.Name = "AppProjectile"
	projectile.Shape = Enum.PartType.Ball
	projectile.Size = Vector3.new(0.7, 0.7, 0.7)
	projectile.Material = Enum.Material.Neon
	projectile.Color = Color3.fromRGB(255, 214, 102)
	projectile.CanCollide = false
	projectile.CanQuery = true
	projectile.CanTouch = true
	projectile.Massless = true
	projectile.CastShadow = false
	projectile.Anchored = false
	projectile.Transparency = 1
	projectile.Parent = Workspace
	return projectile
end

local ProjectilePoolClass = {}
ProjectilePoolClass.__index = ProjectilePoolClass

function ProjectilePoolClass.new(poolSize: number): ProjectilePool
	local self = setmetatable({}, ProjectilePoolClass)
	self.Container = {}
	self.InUse = {}
	self.TouchedConnections = {}

	for _ = 1, poolSize do
		table.insert(self.Container, createProjectilePart())
	end

	return self
end

function ProjectilePoolClass:Acquire(): BasePart?
	for i, projectile in ipairs(self.Container) do
		if projectile.Parent == nil then
			projectile = createProjectilePart()
			self.Container[i] = projectile
		end

		if not self.InUse[projectile] then
			self.InUse[projectile] = true
			projectile.Parent = Workspace
			projectile.Transparency = 0
			projectile.Anchored = false
			projectile.AssemblyLinearVelocity = Vector3.zero
			return projectile
		end
	end
	return nil
end

function ProjectilePoolClass:Release(projectile: BasePart)
	if self.TouchedConnections[projectile] then
		self.TouchedConnections[projectile]:Disconnect()
		self.TouchedConnections[projectile] = nil
	end

	self.InUse[projectile] = nil
	if projectile.Parent == nil then
		return
	end

	projectile.Anchored = true
	projectile.AssemblyLinearVelocity = Vector3.zero
	projectile.Transparency = 1
	projectile.CFrame = CFrame.new(0, 1000, 0)
end

function ProjectilePoolClass:Destroy()
	for projectile, connection in pairs(self.TouchedConnections) do
		connection:Disconnect()
		self.TouchedConnections[projectile] = nil
	end

	for _, projectile in ipairs(self.Container) do
		projectile:Destroy()
	end

	table.clear(self.Container)
	table.clear(self.InUse)
end

local function getPrimaryRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	if model.PrimaryPart then
		return model.PrimaryPart
	end

	for _, instance in ipairs(model:GetDescendants()) do
		if instance:IsA("BasePart") then
			return instance
		end
	end

	return nil
end

local TurretClass = {}
TurretClass.__index = TurretClass

function TurretClass.new(basePart: BasePart): Turret
	local self = setmetatable({}, TurretClass)
	self.Base = basePart
	self.State = "Idle"
	self.CurrentTarget = nil
	self.LastFireTime = 0
	self.LastReacquireTime = 0
	self.SweepAngle = 0
	self.ProjectilePool = ProjectilePoolClass.new(CONFIG.POOL_SIZE_PER_TURRET)
	self.ActiveProjectiles = {}

	local muzzle = basePart:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("Attachment") then
		self.MuzzleAttachment = muzzle
	else
		local newAttachment = Instance.new("Attachment")
		newAttachment.Name = "Muzzle"
		newAttachment.Position = Vector3.new(0, 0.6, -basePart.Size.Z * 0.45)
		newAttachment.Parent = basePart
		self.MuzzleAttachment = newAttachment
	end

	return self
end

function TurretClass:Destroy()
	self.ProjectilePool:Destroy()
	table.clear(self.ActiveProjectiles)
end

function TurretClass:_resolveHumanoidModel(fromInstance: Instance?): Model?
	if not fromInstance then
		return nil
	end

	local cursor: Instance? = fromInstance
	while cursor do
		if cursor:IsA("Model") then
			local model = cursor
			if model:FindFirstChildOfClass("Humanoid") then
				return model
			end
		end
		cursor = cursor.Parent
	end

	return nil
end

function TurretClass:_tryDamageModel(hitModel: Model?): boolean
	if not hitModel then
		return false
	end

	local humanoid = hitModel:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid:TakeDamage(CONFIG.DAMAGE)
		return true
	end

	return false
end

function TurretClass:_releaseProjectile(projectile: BasePart)
	self.ActiveProjectiles[projectile] = nil
	self.ProjectilePool:Release(projectile)
end

function TurretClass:_updateProjectiles(deltaTime: number)
	for projectile, track in pairs(self.ActiveProjectiles) do
		if not projectile.Parent then
		self.ProjectilePool.InUse[projectile] = nil
		if self.ProjectilePool.TouchedConnections[projectile] then
			self.ProjectilePool.TouchedConnections[projectile]:Disconnect()
			self.ProjectilePool.TouchedConnections[projectile] = nil
		end
			self.ActiveProjectiles[projectile] = nil
			continue
		end

		if os.clock() >= track.ExpireAt then
			self:_releaseProjectile(projectile)
			continue
		end

		local velocity = projectile.AssemblyLinearVelocity
		local currentPos = projectile.Position
		local predictedPos = currentPos + velocity * deltaTime
		local travel = predictedPos - track.LastPosition
		local travelMagnitude = travel.Magnitude

		if travelMagnitude > 0 then
			local ignoreList = {projectile}
			if self.Base.Parent and self.Base.Parent:IsA("Model") then
				table.insert(ignoreList, self.Base.Parent)
			else
				table.insert(ignoreList, self.Base)
			end

			local raycastParams = RaycastParams.new()
			raycastParams.FilterType = Enum.RaycastFilterType.Exclude
			raycastParams.FilterDescendantsInstances = ignoreList

			local hit = Workspace:Raycast(track.LastPosition, travel, raycastParams)
			if hit then
				local hitModel = self:_resolveHumanoidModel(hit.Instance)
				self:_tryDamageModel(hitModel)
				self:_releaseProjectile(projectile)
				continue
			end
		end

		track.LastPosition = currentPos
	end
end

function TurretClass:_isTargetValid(targetModel: Model?): boolean
	if not targetModel then
		return false
	end
	if not targetModel.Parent then
		return false
	end

	local root = getPrimaryRoot(targetModel)
	if not root then
		return false
	end

	local humanoid = targetModel:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return false
	end

	local distance = (root.Position - self.Base.Position).Magnitude
	return distance <= CONFIG.MAX_TRACK_DISTANCE
end

function TurretClass:_pickBestTarget(possibleTargets: {Model}): Model?
	local bestTarget: Model? = nil
	local bestScore = math.huge
	local forward = self.Base.CFrame.LookVector

	for _, candidate in ipairs(possibleTargets) do
		if self:_isTargetValid(candidate) then
			local root = getPrimaryRoot(candidate)
			if root then
				local delta = root.Position - self.Base.Position
				local distance = delta.Magnitude
				local direction = safeUnit(delta)
				local facingDot = forward:Dot(direction)
				local score = distance - (facingDot * 20)
				if score < bestScore then
					bestScore = score
					bestTarget = candidate
				end
			end
		end
	end

	return bestTarget
end

function TurretClass:_predictAimPoint(targetModel: Model): Vector3?
	local muzzlePos = self.MuzzleAttachment.WorldPosition
	local root = getPrimaryRoot(targetModel)
	if not root then
		return nil
	end

	local targetPos = root.Position
	local targetVel = root.AssemblyLinearVelocity
	local interceptTime = solveInterceptTime(muzzlePos, targetPos, targetVel, CONFIG.PROJECTILE_SPEED)

	if not interceptTime then
		return targetPos
	end

	interceptTime = clamp(interceptTime, 0, CONFIG.MAX_LEAD_TIME)
	return targetPos + targetVel * interceptTime
end

function TurretClass:_applyAimRotation(desiredPoint: Vector3, deltaTime: number): number
	local baseCF = self.Base.CFrame
	local basePos = baseCF.Position
	local targetDirection = desiredPoint - basePos
	if targetDirection.Magnitude <= 1e-4 then
		return 0
	end

	local desiredCF = CFrame.lookAt(basePos, desiredPoint, Vector3.yAxis)
	local lerpAlpha = clamp(10 * deltaTime, 0, 1)
	self.Base.CFrame = baseCF:Lerp(desiredCF, lerpAlpha)

	local currentDir = self.Base.CFrame.LookVector
	local desiredDir = safeUnit(targetDirection)
	local dot = clamp(currentDir:Dot(desiredDir), -1, 1)
	return math.acos(dot)
end

function TurretClass:_applyIdleSweep(deltaTime: number)
	self.SweepAngle += CONFIG.IDLE_SWEEP_RATE * deltaTime
	local basePos = self.Base.Position
	self.Base.CFrame = CFrame.new(basePos) * CFrame.Angles(0, self.SweepAngle, 0)
end

function TurretClass:_canFireAt(aimError: number): boolean
	if aimError > CONFIG.MAX_AIM_ERROR_RAD then
		return false
	end
	if (os.clock() - self.LastFireTime) < CONFIG.FIRE_COOLDOWN then
		return false
	end
	return true
end

function TurretClass:_fire(aimPoint: Vector3, targetModel: Model)
	local projectile = self.ProjectilePool:Acquire()
	if not projectile then
		return
	end

	local muzzlePosition = self.MuzzleAttachment.WorldPosition
	local direction = safeUnit(aimPoint - muzzlePosition)

	projectile.CFrame = CFrame.lookAt(muzzlePosition, muzzlePosition + direction)
	projectile.AssemblyLinearVelocity = direction * CONFIG.PROJECTILE_SPEED

	local ignoreList = {projectile}
	if self.Base.Parent and self.Base.Parent:IsA("Model") then
		table.insert(ignoreList, self.Base.Parent)
	else
		table.insert(ignoreList, self.Base)
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = ignoreList

	local targetRoot = getPrimaryRoot(targetModel)
	if targetRoot then
		local toTarget = targetRoot.Position - muzzlePosition
		local toTargetMagnitude = toTarget.Magnitude
		if toTargetMagnitude > 0 then
			local losResult = Workspace:Raycast(muzzlePosition, toTarget, raycastParams)
			if losResult then
				local losModel = self:_resolveHumanoidModel(losResult.Instance)
				if losModel == targetModel then
					self:_tryDamageModel(losModel)
				end
			else
				self:_tryDamageModel(targetModel)
			end
		end
	end

	self.ProjectilePool.TouchedConnections[projectile] = projectile.Touched:Connect(function(hitPart)
		if not hitPart then
			return
		end

		local hitModel = self:_resolveHumanoidModel(hitPart)
		self:_tryDamageModel(hitModel)

		self:_releaseProjectile(projectile)
	end)

	-- Short forward raycast reduces missed hits on thin geometry at high projectile speed.
	local raycastResult = Workspace:Raycast(
		muzzlePosition,
		direction * (CONFIG.PROJECTILE_SPEED * (1 / 60) + CONFIG.FIRE_RAYCAST_PADDING),
		raycastParams
	)
	if raycastResult then
		local hitModel = self:_resolveHumanoidModel(raycastResult.Instance)
		self:_tryDamageModel(hitModel)
		self:_releaseProjectile(projectile)
		return
	end

	self.ActiveProjectiles[projectile] = {
		LastPosition = muzzlePosition,
		ExpireAt = os.clock() + CONFIG.PROJECTILE_LIFETIME,
	}

	self.LastFireTime = os.clock()
	self.State = "CoolingDown"
end

function TurretClass:Update(deltaTime: number, possibleTargets: {Model})
	if not self.Base.Parent then
		return
	end

	self:_updateProjectiles(deltaTime)

	if not self.CurrentTarget or not self:_isTargetValid(self.CurrentTarget) then
		self.CurrentTarget = self:_pickBestTarget(possibleTargets)
	end

	if os.clock() - self.LastReacquireTime >= CONFIG.TARGET_REACQUIRE_INTERVAL then
		if self.CurrentTarget and math.random() < 0.14 then
			local betterTarget = self:_pickBestTarget(possibleTargets)
			if betterTarget then
				self.CurrentTarget = betterTarget
			end
		end
		self.LastReacquireTime = os.clock()
	end

	if not self.CurrentTarget then
		self.State = "Idle"
		self:_applyIdleSweep(deltaTime)
		return
	end

	local aimPoint = self:_predictAimPoint(self.CurrentTarget)
	if not aimPoint then
		self.CurrentTarget = nil
		self.State = "Idle"
		return
	end

	self.State = "Tracking"
	local aimError = self:_applyAimRotation(aimPoint, deltaTime)
	if self:_canFireAt(aimError) then
		self:_fire(aimPoint, self.CurrentTarget)
	end

	if self.State == "CoolingDown" and (os.clock() - self.LastFireTime) >= CONFIG.FIRE_COOLDOWN then
		self.State = "Tracking"
	end
end

local turrets: {Turret} = {}
local trackedTargets: {Model} = {}
local trackedTargetSet: {[Model]: boolean} = {}
local lastTargetRebuild = 0

local function rebuildTargetList()
	trackedTargets = table.create(32)
	trackedTargetSet = {}
	for _, instance in ipairs(CollectionService:GetTagged("AppTarget")) do
		if instance:IsA("Model") then
			trackedTargetSet[instance] = true
			table.insert(trackedTargets, instance)
		end
	end
end

local function buildTurretList()
	for _, turret in ipairs(turrets) do
		turret:Destroy()
	end
	table.clear(turrets)

	for _, instance in ipairs(CollectionService:GetTagged("AppTurret")) do
		if instance:IsA("BasePart") then
			instance.Anchored = true
			table.insert(turrets, TurretClass.new(instance))
		end
	end
end

CollectionService:GetInstanceAddedSignal("AppTarget"):Connect(function(instance)
	if instance:IsA("Model") and not trackedTargetSet[instance] then
		trackedTargetSet[instance] = true
		table.insert(trackedTargets, instance)
	end
end)

CollectionService:GetInstanceRemovedSignal("AppTarget"):Connect(function(instance)
	if instance:IsA("Model") and trackedTargetSet[instance] then
		trackedTargetSet[instance] = nil
		for i = #trackedTargets, 1, -1 do
			if trackedTargets[i] == instance then
				table.remove(trackedTargets, i)
				break
			end
		end
	end
end)

CollectionService:GetInstanceAddedSignal("AppTurret"):Connect(function(instance)
	if instance:IsA("BasePart") then
		instance.Anchored = true
		table.insert(turrets, TurretClass.new(instance))
	end
end)

CollectionService:GetInstanceRemovedSignal("AppTurret"):Connect(function(instance)
	if instance:IsA("BasePart") then
		for i = #turrets, 1, -1 do
			if turrets[i].Base == instance then
				turrets[i]:Destroy()
				table.remove(turrets, i)
				break
			end
		end
	end
end)

rebuildTargetList()
buildTurretList()

RunService.Heartbeat:Connect(function(deltaTime)
	deltaTime = math.min(deltaTime, 1 / 20)
	lastTargetRebuild += deltaTime
	if lastTargetRebuild >= CONFIG.TARGET_REBUILD_INTERVAL then
		lastTargetRebuild = 0
		rebuildTargetList()
	end

	for i = #trackedTargets, 1, -1 do
		local target = trackedTargets[i]
		if not target.Parent then
			trackedTargetSet[target] = nil
			table.remove(trackedTargets, i)
		end
	end

	for _, turret in ipairs(turrets) do
		turret:Update(deltaTime, trackedTargets)
	end
end)
