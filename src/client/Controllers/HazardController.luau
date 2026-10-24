--!strict
-- Animates moving hazards on this client and checks them against the local Bloblet.
--
-- Spinners: every client computes the same pose from the synced server clock, so all players see
-- the bar in the same place. Collision is judged against exactly what this player sees, which
-- keeps hits fair under lag. Getting knocked down only hurts the player who reports it, so the
-- client decides it and tells the server.
--
-- Risers (e.g. Rising Tide water), Wobblers (tilting planks) and FallingTiles (Cloud Crown puffs)
-- are driven by attributes plus the same clock, so they also line up with the server's rules.
--
-- Bounce pads are detected by MovementController; this module only plays the squish.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local HazardMath = require(Shared.HazardMath)
local Tags = require(Shared.Tags)

local ClientEvents = require(script.Parent.ClientEvents)
local MovementController = require(script.Parent.MovementController)

local HazardController = {}

type Spinner = {
	Model: Model,
	Pivot: CFrame,
	Arm: BasePart,
	ArmRest: CFrame,
	Decor: { BasePart },
	DecorOffsets: { CFrame },
	Speed: number,
	Phase: number,
}

type Riser = {
	Part: BasePart,
	Base: CFrame,
}

type Wobbler = {
	Part: BasePart,
	Base: CFrame,
	Amplitude: number,
	Speed: number,
	Phase: number,
}

type FallingTile = {
	Model: Model,
	Pad: BasePart,
	Base: CFrame,
	BaseColor: Color3,
	Parts: { BasePart },
	Offsets: { CFrame },
	FallAt: number,
	Seed: number,
	Connection: RBXScriptConnection,
}

local spinners: { [Model]: Spinner } = {}
local risers: { [BasePart]: Riser } = {}
local wobblers: { [BasePart]: Wobbler } = {}
local fallingTiles: { [Model]: FallingTile } = {}
local lastHitTime = -math.huge
local squishing: { [BasePart]: boolean } = {}

local ROOT_RADIUS = BlobletRig.Dimensions.RootDiameter / 2
local HIT_MARGIN = 0.25
local TILE_WARNING_COLOR = Color3.fromRGB(150, 160, 190)
local TILE_FALL_ACCELERATION = 70
local TILE_FADE_TIME = 1.2

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function registerSpinner(instance: Instance)
	if not instance:IsA("Model") or spinners[instance] then
		return
	end
	local hub = instance:FindFirstChild("Hub")
	local arm = instance:FindFirstChild("Arm")
	if not (hub and hub:IsA("BasePart") and arm and arm:IsA("BasePart")) then
		warn(`[HazardController] Spinner {instance:GetFullName()} needs a Hub and an Arm part`)
		return
	end
	local pivot = CFrame.new(hub.Position.X, arm.Position.Y, hub.Position.Z)
	local decor: { BasePart } = {}
	local offsets: { CFrame } = {}
	for _, child in instance:GetChildren() do
		if child.Name == "ArmDecor" and child:IsA("BasePart") then
			table.insert(decor, child)
			table.insert(offsets, arm.CFrame:ToObjectSpace(child.CFrame))
		end
	end
	local speed = numberAttribute(instance, "Speed", 1)
	-- Lets the physics engine push touching Bloblets as if the anchored bar were really moving.
	arm.AssemblyAngularVelocity = Vector3.new(0, speed, 0)
	spinners[instance] = {
		Model = instance,
		Pivot = pivot,
		Arm = arm,
		ArmRest = pivot:ToObjectSpace(arm.CFrame),
		Decor = decor,
		DecorOffsets = offsets,
		Speed = speed,
		Phase = numberAttribute(instance, "Phase", 0),
	}
end

local function checkSpinnerHit(spinner: Spinner, armCFrame: CFrame, root: BasePart, now: number)
	local closest = HazardMath.ClosestPointOnBox(armCFrame, spinner.Arm.Size, root.Position)
	if (root.Position - closest).Magnitude > ROOT_RADIUS + HIT_MARGIN then
		return
	end
	local hazards = Config.Hazards
	if now - lastHitTime < hazards.HitCooldown then
		return
	end
	local contactVelocity = HazardMath.SpinnerVelocityAt(spinner.Pivot.Position, spinner.Speed, closest)
	local contactSpeed = contactVelocity.Magnitude
	if contactSpeed < hazards.KnockdownSpeed then
		return -- slow contact near the hub just pushes you (handled by physics)
	end
	lastHitTime = now
	local strength = math.clamp((contactSpeed - hazards.KnockdownSpeed) / 20, 0.15, 1)
	local impulse = contactVelocity * hazards.KnockbackMultiplier + Vector3.new(0, hazards.KnockbackLift, 0)
	MovementController.Knockdown(impulse, strength, true)
end

local function registerRiser(instance: Instance)
	if instance:IsA("BasePart") and not risers[instance] then
		risers[instance] = { Part = instance, Base = instance.CFrame }
	end
end

local function registerWobbler(instance: Instance)
	if instance:IsA("BasePart") and not wobblers[instance] then
		wobblers[instance] = {
			Part = instance,
			Base = instance.CFrame,
			Amplitude = numberAttribute(instance, "Amplitude", 0.2),
			Speed = numberAttribute(instance, "Speed", 1.5),
			Phase = numberAttribute(instance, "Phase", 0),
		}
	end
end

local function registerFallingTile(instance: Instance)
	if not instance:IsA("Model") or fallingTiles[instance] then
		return
	end
	local pad = instance:FindFirstChild("Pad")
	if not pad or not pad:IsA("BasePart") then
		return
	end
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
			table.insert(offsets, pad.CFrame:ToObjectSpace(descendant.CFrame))
		end
	end
	local record: FallingTile
	record = {
		Model = instance,
		Pad = pad,
		Base = pad.CFrame,
		BaseColor = pad.Color,
		Parts = parts,
		Offsets = offsets,
		FallAt = numberAttribute(instance, "FallAt", 0),
		Seed = math.random() * 100,
		Connection = instance:GetAttributeChangedSignal("FallAt"):Connect(function()
			record.FallAt = numberAttribute(instance, "FallAt", 0)
		end),
	}
	fallingTiles[instance] = record
end

local function unregister(instance: Instance)
	if instance:IsA("Model") then
		spinners[instance] = nil
		local tile = fallingTiles[instance]
		if tile then
			tile.Connection:Disconnect()
			fallingTiles[instance] = nil
		end
	elseif instance:IsA("BasePart") then
		risers[instance] = nil
		wobblers[instance] = nil
	end
end

local function stepTiles(serverTime: number, parts: { BasePart }, cframes: { CFrame })
	local warning = Config.Hazards.TileWarningTime
	for model, tile in fallingTiles do
		local fallAt = tile.FallAt
		if fallAt <= 0 or serverTime < fallAt - warning then
			continue
		end
		local pose: CFrame
		if serverTime < fallAt then
			-- Shake harder and grey out as the drop gets close.
			local progress = 1 - (fallAt - serverTime) / warning
			local amount = 0.08 + 0.3 * progress
			local t = serverTime * 22
			pose = tile.Base + Vector3.new(math.noise(t, tile.Seed) * amount, 0, math.noise(tile.Seed, t) * amount)
			tile.Pad.Color = tile.BaseColor:Lerp(TILE_WARNING_COLOR, progress)
		else
			local falling = serverTime - fallAt
			pose = tile.Base - Vector3.new(0, 0.5 * TILE_FALL_ACCELERATION * falling * falling, 0)
			local fade = math.clamp(falling / TILE_FADE_TIME, 0, 1)
			for _, part in tile.Parts do
				part.LocalTransparencyModifier = fade
			end
			if fade >= 1 then
				tile.Connection:Disconnect()
				fallingTiles[model] = nil
				continue
			end
		end
		for index, part in tile.Parts do
			table.insert(parts, part)
			table.insert(cframes, pose * tile.Offsets[index])
		end
	end
end

local function step()
	if next(spinners) == nil and next(risers) == nil and next(wobblers) == nil and next(fallingTiles) == nil then
		return
	end
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	local serverTime = Workspace:GetServerTimeNow()
	local now = os.clock()
	local root = MovementController.GetRoot()
	local canBeHit = root ~= nil and not MovementController.IsRagdolled()

	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}
	for _, spinner in spinners do
		if (spinner.Pivot.Position - cameraPosition).Magnitude > Config.Hazards.UpdateDistance then
			continue
		end
		local angle = HazardMath.SpinnerAngle(spinner.Speed, spinner.Phase, serverTime)
		local armCFrame = spinner.Pivot * CFrame.Angles(0, angle, 0) * spinner.ArmRest
		table.insert(parts, spinner.Arm)
		table.insert(cframes, armCFrame)
		for index, decor in spinner.Decor do
			table.insert(parts, decor)
			table.insert(cframes, armCFrame * spinner.DecorOffsets[index])
		end
		if canBeHit and root then
			checkSpinnerHit(spinner, armCFrame, root, now)
		end
	end

	for part, riser in risers do
		local offset = HazardMath.RiserOffset(
			numberAttribute(part, "StartTime", 0),
			numberAttribute(part, "Rate", 0),
			numberAttribute(part, "MaxRise", 0),
			serverTime
		)
		table.insert(parts, part)
		table.insert(cframes, riser.Base + Vector3.new(0, offset, 0))
	end

	for part, wobbler in wobblers do
		if (wobbler.Base.Position - cameraPosition).Magnitude > Config.Hazards.UpdateDistance then
			continue
		end
		local angle = HazardMath.WobbleAngle(wobbler.Amplitude, wobbler.Speed, wobbler.Phase, serverTime)
		table.insert(parts, part)
		table.insert(cframes, wobbler.Base * CFrame.Angles(angle, 0, 0))
	end

	stepTiles(serverTime, parts, cframes)

	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function squishPad(pad: BasePart)
	if squishing[pad] then
		return
	end
	squishing[pad] = true
	local rest = pad.CFrame
	local down = TweenService:Create(
		pad,
		TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = rest - Vector3.new(0, 0.35, 0) }
	)
	local up = TweenService:Create(
		pad,
		TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
		{ CFrame = rest }
	)
	down.Completed:Once(function()
		up:Play()
	end)
	up.Completed:Once(function()
		squishing[pad] = nil
	end)
	down:Play()
end

function HazardController.Init()
	local registrations: { [string]: (Instance) -> () } = {
		[Tags.Spinner] = registerSpinner,
		[Tags.Riser] = registerRiser,
		[Tags.Wobbler] = registerWobbler,
		[Tags.FallingTile] = registerFallingTile,
	}
	for tag, register in registrations do
		CollectionService:GetInstanceAddedSignal(tag):Connect(register)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(unregister)
		for _, instance in CollectionService:GetTagged(tag) do
			register(instance)
		end
	end

	ClientEvents.Bounced:Connect(squishPad)

	-- Before physics, so collisions this frame use the pose the player is about to see.
	RunService.PreSimulation:Connect(step)
end

return HazardController
