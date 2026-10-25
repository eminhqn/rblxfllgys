--!strict
-- Animates moving hazards on this client and checks them against the local Bloblet.
--
-- Spinners: every client computes the same pose from the synced server clock, so all players see
-- the bar in the same place. Collision is judged against exactly what this player sees, which
-- keeps hits fair under lag. Getting knocked down only hurts the player who reports it, so the
-- client decides it and tells the server.
--
-- Risers (e.g. Rising Tide water), Wobblers (tilting planks), FallingTiles (Cloud Crown puffs),
-- Conveyors (sliding slats plus a surface speed), Movers (platforms gliding back and forth) and
-- Crates (target circle, drop, slide, smash) and Rollers (giant balloons: flashing lane, roll or
-- hop, pop) are driven by attributes plus the same clock, so they also line up with the server's
-- rules. Crate and balloon hits are judged here, like spinner hits. Paint buckets burst in a
-- team's colour when the server marks them grabbed.
--
-- Anchored parts that this client moves are also given the matching velocity, which is what lets
-- Bloblets ride conveyors and moving platforms.
--
-- With StreamingEnabled a hazard model can reach this client before the parts inside it, so models
-- are (re)registered whenever more of their parts arrive.
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
local MathUtil = require(Shared.MathUtil)
local Tags = require(Shared.Tags)

local ClientEvents = require(script.Parent.ClientEvents)
local Effects = require(script.Parent.Effects)
local MovementController = require(script.Parent.MovementController)
local Sfx = require(script.Parent.Sfx)
local WaterSurfaces = require(script.Parent.WaterSurfaces)

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
	BaseColors: { Color3 },
	Parts: { BasePart },
	Offsets: { CFrame },
	FallAt: number,
	Seed: number,
	Connection: RBXScriptConnection,
}

type Conveyor = {
	Belt: BasePart,
	Base: CFrame,
	Length: number,
	Speed: number,
	Slats: { BasePart },
	SlatOffsets: { CFrame }, -- from Base, as built
}

type Mover = {
	Base: CFrame, -- the reference part at home
	Parts: { BasePart },
	Offsets: { CFrame },
	Solid: { BasePart }, -- parts that carry whoever stands on them
	Travel: Vector3,
	Speed: number,
	Phase: number,
}

type Crate = {
	Base: CFrame, -- the box where it lands
	BoxSize: Vector3,
	Parts: { BasePart },
	Offsets: { CFrame },
	Markers: { BasePart }, -- the target circle on the landing spot
	MarkerSizes: { Vector3 },
	MarkerFlashes: { boolean }, -- false for the white fill, which keeps its colour
	Color: Color3,
	LandAt: number,
	DropHeight: number,
	SlideVelocity: Vector3,
	SlideTime: number,
	Phase: HazardMath.CratePhase,
}

type Roller = {
	Origin: Vector3,
	Velocity: Vector3,
	Axis: Vector3, -- what it spins round as it rolls
	StartAt: number,
	Duration: number,
	Radius: number,
	Hop: number,
	HopRate: number,
	Parts: { BasePart }, -- the balloon itself
	Offsets: { CFrame }, -- from its centre, unrotated
	Lanes: { BasePart },
	Color: Color3,
	Phase: HazardMath.RollerPhase,
}

local spinners: { [Model]: Spinner } = {}
local partWatchers: { [Model]: RBXScriptConnection } = {}
local risers: { [BasePart]: Riser } = {}
local wobblers: { [BasePart]: Wobbler } = {}
local fallingTiles: { [Model]: FallingTile } = {}
local conveyors: { [Model]: Conveyor } = {}
local movers: { [Model]: Mover } = {}
local crates: { [Model]: Crate } = {}
local rollers: { [Model]: Roller } = {}
local bucketWatchers: { [Model]: RBXScriptConnection } = {}
local lastHitTime = -math.huge
local squishing: { [BasePart]: boolean } = {}

local ROOT_RADIUS = BlobletRig.Dimensions.RootDiameter / 2
local HIT_MARGIN = 0.25
local TILE_WARNING_COLOR = Color3.fromRGB(255, 72, 120)
local TILE_FALL_ACCELERATION = 70
local TILE_FADE_TIME = 1.2
local EFFECT_DISTANCE = 250 -- crate smashes further away than this are skipped
local MARKER_COLOR = Color3.fromRGB(255, 72, 120)
local MARKER_FLASH_COLOR = Color3.fromRGB(255, 220, 60)
local MARKER_START_SCALE = 1.5 -- the circle tightens from this size onto the landing spot

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function vectorAttribute(instance: Instance, name: string): Vector3
	local value = instance:GetAttribute(name)
	return if typeof(value) == "Vector3" then value else Vector3.zero
end

-- Re-runs `register` whenever another part of `model` streams in, until the model goes away.
local function watchParts(model: Model, register: (Instance) -> ())
	if partWatchers[model] then
		return
	end
	partWatchers[model] = model.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("BasePart") then
			register(model)
		end
	end)
end

local function registerSpinner(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	watchParts(instance, registerSpinner)
	local hub = instance:FindFirstChild("Hub")
	local arm = instance:FindFirstChild("Arm")
	if not (hub and hub:IsA("BasePart") and arm and arm:IsA("BasePart")) then
		return -- not streamed in yet; tried again when more parts arrive
	end
	-- If we registered before, the arm has already been moved locally, so keep the original rest
	-- pose and offsets instead of reading the current (rotated) positions.
	local previous = spinners[instance]
	local pivot = if previous then previous.Pivot else CFrame.new(hub.Position.X, arm.Position.Y, hub.Position.Z)
	local armRest = if previous then previous.ArmRest else pivot:ToObjectSpace(arm.CFrame)
	local armHome = pivot * armRest
	local decor: { BasePart } = {}
	local offsets: { CFrame } = {}
	for _, child in instance:GetChildren() do
		if child.Name == "ArmDecor" and child:IsA("BasePart") then
			local known = if previous then table.find(previous.Decor, child) else nil
			table.insert(decor, child)
			table.insert(
				offsets,
				if previous and known then previous.DecorOffsets[known] else armHome:ToObjectSpace(child.CFrame)
			)
		end
	end
	local speed = numberAttribute(instance, "Speed", 1)
	-- Lets the physics engine push touching Bloblets as if the anchored bar were really moving.
	arm.AssemblyAngularVelocity = Vector3.new(0, speed, 0)
	spinners[instance] = {
		Model = instance,
		Pivot = pivot,
		Arm = arm,
		ArmRest = armRest,
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
	if not instance:IsA("Model") then
		return
	end
	watchParts(instance, registerFallingTile)
	local pad = instance:FindFirstChild("Pad")
	if not pad or not pad:IsA("BasePart") then
		return -- not streamed in yet; tried again when more parts arrive
	end
	-- Keep what we already know about parts that arrived earlier (they may be mid-flash).
	local previous = fallingTiles[instance]
	local base = if previous then previous.Base else pad.CFrame
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local colors: { Color3 } = {}
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			local known = if previous then table.find(previous.Parts, descendant) else nil
			table.insert(parts, descendant)
			if previous and known then
				table.insert(offsets, previous.Offsets[known])
				table.insert(colors, previous.BaseColors[known])
			else
				table.insert(offsets, base:ToObjectSpace(descendant.CFrame))
				table.insert(colors, descendant.Color)
			end
		end
	end
	if previous then
		previous.Connection:Disconnect()
	end
	local record: FallingTile
	record = {
		Model = instance,
		Pad = pad,
		Base = base,
		BaseColors = colors,
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

local function registerConveyor(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	watchParts(instance, registerConveyor)
	local belt = instance:FindFirstChild("Belt")
	if not belt or not belt:IsA("BasePart") then
		return -- not streamed in yet; tried again when more parts arrive
	end
	local previous = conveyors[instance]
	local base = if previous then previous.Base else belt.CFrame
	local speed = numberAttribute(instance, "Speed", 0)
	local slats: { BasePart } = {}
	local offsets: { CFrame } = {}
	for _, child in instance:GetChildren() do
		if child.Name == "Slat" and child:IsA("BasePart") then
			local known = if previous then table.find(previous.Slats, child) else nil
			table.insert(slats, child)
			table.insert(
				offsets,
				if previous and known then previous.SlatOffsets[known] else base:ToObjectSpace(child.CFrame)
			)
		end
	end
	-- The belt never moves, but its surface does: Bloblets standing on it are carried along.
	belt.AssemblyLinearVelocity = base.LookVector * speed
	conveyors[instance] = {
		Belt = belt,
		Base = base,
		Length = belt.Size.Z,
		Speed = speed,
		Slats = slats,
		SlatOffsets = offsets,
	}
end

-- Collects every part of a model with its offset from `base`, keeping what a previous
-- registration already knew (those parts may have been moved locally since).
local function collectParts(
	model: Model,
	base: CFrame,
	previousParts: { BasePart }?,
	previousOffsets: { CFrame }?
): ({ BasePart }, { CFrame })
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local known = if previousParts then table.find(previousParts, descendant) else nil
			table.insert(parts, descendant)
			table.insert(
				offsets,
				if previousOffsets and known then previousOffsets[known] else base:ToObjectSpace(descendant.CFrame)
			)
		end
	end
	return parts, offsets
end

local function registerMover(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	watchParts(instance, registerMover)
	local reference = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	if not reference then
		return -- not streamed in yet; tried again when more parts arrive
	end
	local previous = movers[instance]
	local base = if previous then previous.Base else reference.CFrame
	local parts, offsets = collectParts(
		instance,
		base,
		if previous then previous.Parts else nil,
		if previous then previous.Offsets else nil
	)
	local solid: { BasePart } = {}
	for _, part in parts do
		if part.CanCollide then
			table.insert(solid, part)
		end
	end
	movers[instance] = {
		Base = base,
		Parts = parts,
		Offsets = offsets,
		Solid = solid,
		Travel = vectorAttribute(instance, "Travel"),
		Speed = numberAttribute(instance, "Speed", 1),
		Phase = numberAttribute(instance, "Phase", 0),
	}
end

local function setCrateHidden(crate: Crate, hidden: boolean)
	local modifier = if hidden then 1 else 0
	for _, part in crate.Parts do
		part.LocalTransparencyModifier = modifier
	end
end

local function setMarkerHidden(crate: Crate, hidden: boolean)
	local modifier = if hidden then 1 else 0
	for _, part in crate.Markers do
		part.LocalTransparencyModifier = modifier
	end
end

local function registerCrate(instance: Instance)
	if not instance:IsA("Model") or crates[instance] then
		return
	end
	local box = instance:FindFirstChild("Box")
	if not box or not box:IsA("BasePart") then
		return -- crates stream in whole, so this only happens for a broken model
	end
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local markers: { BasePart } = {}
	local markerSizes: { Vector3 } = {}
	local markerFlashes: { boolean } = {}
	for _, child in instance:GetChildren() do
		if child:IsA("BasePart") then
			if child.Name == "Marker" or child.Name == "MarkerFill" then
				table.insert(markers, child)
				table.insert(markerSizes, child.Size)
				table.insert(markerFlashes, child.Name == "Marker")
			else
				table.insert(parts, child)
				table.insert(offsets, box.CFrame:ToObjectSpace(child.CFrame))
			end
		end
	end
	local crate: Crate = {
		Base = box.CFrame,
		BoxSize = box.Size,
		Parts = parts,
		Offsets = offsets,
		Markers = markers,
		MarkerSizes = markerSizes,
		MarkerFlashes = markerFlashes,
		Color = box.Color,
		LandAt = numberAttribute(instance, "LandAt", 0),
		DropHeight = numberAttribute(instance, "DropHeight", 0),
		SlideVelocity = vectorAttribute(instance, "SlideVelocity"),
		SlideTime = numberAttribute(instance, "SlideTime", 0),
		Phase = "Waiting" :: HazardMath.CratePhase,
	}
	setCrateHidden(crate, true)
	setMarkerHidden(crate, true)
	crates[instance] = crate
end

local function setRollerHidden(roller: Roller, hidden: boolean)
	local modifier = if hidden then 1 else 0
	for _, part in roller.Parts do
		part.LocalTransparencyModifier = modifier
	end
end

local function setLaneModifier(roller: Roller, modifier: number)
	for _, lane in roller.Lanes do
		lane.LocalTransparencyModifier = modifier
	end
end

local function registerRoller(instance: Instance)
	if not instance:IsA("Model") or rollers[instance] then
		return
	end
	local ball = instance:FindFirstChild("Ball")
	if not ball or not ball:IsA("BasePart") then
		return -- rollers stream in whole, so this only happens for a broken model
	end
	local origin = ball.Position
	local velocity = vectorAttribute(instance, "Velocity")
	local flat = MathUtil.flat(velocity)
	local direction = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.zAxis
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local lanes: { BasePart } = {}
	for _, child in instance:GetChildren() do
		if child:IsA("BasePart") then
			if child.Name == "Lane" then
				table.insert(lanes, child)
			else
				table.insert(parts, child)
				table.insert(offsets, CFrame.new(origin):ToObjectSpace(child.CFrame))
			end
		end
	end
	local roller: Roller = {
		Origin = origin,
		Velocity = velocity,
		-- Rolling forwards spins it round up x direction.
		Axis = Vector3.new(direction.Z, 0, -direction.X),
		StartAt = numberAttribute(instance, "StartAt", 0),
		Duration = numberAttribute(instance, "Duration", 0),
		Radius = numberAttribute(instance, "Diameter", ball.Size.X) / 2,
		Hop = numberAttribute(instance, "Hop", 0),
		HopRate = numberAttribute(instance, "HopRate", 1),
		Parts = parts,
		Offsets = offsets,
		Lanes = lanes,
		Color = ball.Color,
		Phase = "Waiting" :: HazardMath.RollerPhase,
	}
	setRollerHidden(roller, true)
	setLaneModifier(roller, 1)
	rollers[instance] = roller
end

-- Paint Grab buckets: burst in the grabbing team's colour.
local function registerPaintBucket(instance: Instance)
	if not instance:IsA("Model") or bucketWatchers[instance] then
		return
	end
	bucketWatchers[instance] = instance:GetAttributeChangedSignal("SplashColor"):Connect(function()
		local color = instance:GetAttribute("SplashColor")
		local camera = Workspace.CurrentCamera
		local position = instance:GetPivot().Position
		if typeof(color) ~= "Color3" or not camera then
			return
		end
		if (position - camera.CFrame.Position).Magnitude > EFFECT_DISTANCE then
			return
		end
		Effects.Burst(position + Vector3.new(0, 2, 0), {
			Count = 30,
			Colors = { color, color:Lerp(Color3.new(1, 1, 1), 0.35) },
			Size = Vector3.new(1.1, 1.1, 1.1),
			Speed = 30,
			Up = 22,
			Shape = Enum.PartType.Ball,
			Life = 1.1,
		})
		Sfx.PlayAt("PaintSplash", position)
	end)
end

local function unregister(instance: Instance)
	if instance:IsA("Model") then
		local watcher = partWatchers[instance]
		if watcher then
			watcher:Disconnect()
			partWatchers[instance] = nil
		end
		spinners[instance] = nil
		conveyors[instance] = nil
		movers[instance] = nil
		crates[instance] = nil
		rollers[instance] = nil
		local bucketWatcher = bucketWatchers[instance]
		if bucketWatcher then
			bucketWatcher:Disconnect()
			bucketWatchers[instance] = nil
		end
		local tile = fallingTiles[instance]
		if tile then
			tile.Connection:Disconnect()
			fallingTiles[instance] = nil
		end
	elseif instance:IsA("BasePart") then
		risers[instance] = nil
		wobblers[instance] = nil
		WaterSurfaces.Remove(instance)
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
			-- Flash faster and faster so everyone can see which puffs are about to go, and shake
			-- in the last moments.
			local elapsed = serverTime - (fallAt - warning)
			local progress = math.clamp(elapsed / warning, 0, 1)
			local flashesPerSecond = 2.5 + 7.5 * progress
			local lit = math.floor(elapsed * flashesPerSecond * 2) % 2 == 0
			for index, part in tile.Parts do
				part.Color = if lit then TILE_WARNING_COLOR else tile.BaseColors[index]
			end
			local amount = if progress > 0.6 then (progress - 0.6) * 0.9 else 0
			local t = serverTime * 22
			pose = tile.Base + Vector3.new(math.noise(t, tile.Seed) * amount, 0, math.noise(tile.Seed, t) * amount)
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

local function stepConveyors(serverTime: number, cameraPosition: Vector3, parts: { BasePart }, cframes: { CFrame })
	for _, conveyor in conveyors do
		if (conveyor.Base.Position - cameraPosition).Magnitude > Config.Hazards.UpdateDistance then
			continue
		end
		local length = conveyor.Length
		-- The surface moves along LookVector, which is the belt's -Z axis.
		local shift = (serverTime * conveyor.Speed) % length
		for index, slat in conveyor.Slats do
			local offset = conveyor.SlatOffsets[index]
			local along = (offset.Position.Z - shift + length / 2) % length - length / 2
			table.insert(parts, slat)
			table.insert(cframes, conveyor.Base * CFrame.new(offset.Position.X, offset.Position.Y, along))
		end
	end
end

local function stepMovers(serverTime: number, cameraPosition: Vector3, parts: { BasePart }, cframes: { CFrame })
	for _, mover in movers do
		if (mover.Base.Position - cameraPosition).Magnitude > Config.Hazards.UpdateDistance then
			continue
		end
		local offset = HazardMath.MoverOffset(mover.Travel, mover.Speed, mover.Phase, serverTime)
		local velocity = HazardMath.MoverVelocity(mover.Travel, mover.Speed, mover.Phase, serverTime)
		local pose = mover.Base + offset
		for index, part in mover.Parts do
			table.insert(parts, part)
			table.insert(cframes, pose * mover.Offsets[index])
		end
		for _, part in mover.Solid do
			part.AssemblyLinearVelocity = velocity
		end
	end
end

local function smashCrate(crate: Crate, position: Vector3, cameraPosition: Vector3)
	if (position - cameraPosition).Magnitude > EFFECT_DISTANCE then
		return
	end
	Effects.Burst(position, {
		Count = 10,
		Colors = { crate.Color, crate.Color:Lerp(Color3.new(1, 1, 1), 0.5) },
		Size = Vector3.new(0.5, 0.3, 1.8),
		Speed = 22,
		Up = 16,
		Material = Enum.Material.WoodPlanks,
	})
	Sfx.PlayAt("CrateSmash", position)
end

local function checkCrateHit(crate: Crate, pose: CFrame, phase: HazardMath.CratePhase, root: BasePart, now: number)
	local closest = HazardMath.ClosestPointOnBox(pose, crate.BoxSize, root.Position)
	if (root.Position - closest).Magnitude > ROOT_RADIUS + HIT_MARGIN then
		return
	end
	if now - lastHitTime < Config.Hazards.HitCooldown then
		return
	end
	lastHitTime = now
	local rules = Config.Crates
	local away = MathUtil.flat(root.Position - pose.Position)
	away = if away.Magnitude > 1e-3 then away.Unit else Vector3.xAxis
	local lift = Vector3.new(0, rules.HitLift, 0)
	if phase == "Falling" then
		MovementController.Knockdown(away * rules.FallKnockback + lift, rules.FallHitStrength, true)
	else
		local push = crate.SlideVelocity * rules.SlideKnockback + away * 8
		MovementController.Knockdown(push + lift, rules.SlideHitStrength, true)
	end
end

local function stepCrates(
	serverTime: number,
	cameraPosition: Vector3,
	parts: { BasePart },
	cframes: { CFrame },
	root: BasePart?,
	now: number
)
	local rules = Config.Crates
	local warningStart = rules.WarningTime + rules.FallTime
	for _, crate in crates do
		local phase: HazardMath.CratePhase, offset: Vector3 = HazardMath.CratePose(
			crate.LandAt,
			rules.FallTime,
			rules.WarningTime,
			crate.DropHeight,
			crate.SlideVelocity,
			crate.SlideTime,
			serverTime
		)
		local warning = phase == "Warning" or phase == "Falling"
		if phase ~= crate.Phase then
			local previous = crate.Phase
			crate.Phase = phase
			setCrateHidden(crate, phase ~= "Falling" and phase ~= "Sliding")
			setMarkerHidden(crate, not warning)
			if phase == "Gone" and (previous == "Falling" or previous == "Sliding") then
				smashCrate(crate, (crate.Base + offset).Position, cameraPosition)
			end
		end
		if warning then
			-- The target circle flashes pink and yellow, faster and faster, and tightens onto the
			-- landing spot as the crate comes down.
			local elapsed = serverTime - (crate.LandAt - warningStart)
			local progress = math.clamp(elapsed / warningStart, 0, 1)
			local flashesPerSecond = 3 + 7 * progress
			local lit = math.floor(elapsed * flashesPerSecond * 2) % 2 == 0
			local scale = MARKER_START_SCALE - (MARKER_START_SCALE - 1) * progress
			for index, marker in crate.Markers do
				local size = crate.MarkerSizes[index]
				marker.Size = Vector3.new(size.X, size.Y * scale, size.Z * scale)
				if crate.MarkerFlashes[index] then
					marker.Color = if lit then MARKER_COLOR else MARKER_FLASH_COLOR
				end
			end
		end
		if phase == "Falling" or phase == "Sliding" then
			local pose = crate.Base + offset
			for index, part in crate.Parts do
				table.insert(parts, part)
				table.insert(cframes, pose * crate.Offsets[index])
			end
			if root then
				checkCrateHit(crate, pose, phase, root, now)
			end
		end
	end
end

local function popRoller(roller: Roller, position: Vector3, cameraPosition: Vector3)
	if (position - cameraPosition).Magnitude > EFFECT_DISTANCE then
		return
	end
	Effects.Burst(position, {
		Count = 16,
		Colors = { roller.Color, Color3.new(1, 1, 1) },
		Size = Vector3.new(1.4, 0.15, 1.4),
		Speed = 28,
		Up = 10,
		Gravity = 60,
		Life = 1,
	})
	Sfx.PlayAt("Pop", position)
end

local function checkRollerHit(roller: Roller, position: Vector3, root: BasePart, now: number)
	local rules = Config.Balloons
	local reach = roller.Radius + ROOT_RADIUS - rules.HitMargin
	if (root.Position - position).Magnitude > reach then
		return
	end
	if now - lastHitTime < Config.Hazards.HitCooldown then
		return
	end
	lastHitTime = now
	local flatVelocity = MathUtil.flat(roller.Velocity)
	local along = if flatVelocity.Magnitude > 1e-3 then flatVelocity.Unit else Vector3.zero
	local away = MathUtil.flat(root.Position - position)
	away = if away.Magnitude > 1e-3 then away.Unit else along
	local impulse = along * rules.Knockback + away * rules.SideKnockback + Vector3.new(0, rules.Lift, 0)
	MovementController.Knockdown(impulse, rules.Strength, true)
end

local function stepRollers(
	serverTime: number,
	cameraPosition: Vector3,
	parts: { BasePart },
	cframes: { CFrame },
	root: BasePart?,
	now: number
)
	local warningTime = Config.Balloons.WarningTime
	for _, roller in rollers do
		local phase: HazardMath.RollerPhase, position: Vector3, travelled: number = HazardMath.RollerPose(
			roller.StartAt,
			roller.Origin,
			roller.Velocity,
			roller.Duration,
			roller.Hop,
			roller.HopRate,
			warningTime,
			serverTime
		)
		if phase ~= roller.Phase then
			local previous = roller.Phase
			roller.Phase = phase
			setRollerHidden(roller, phase == "Waiting" or phase == "Gone")
			-- The lane stays faintly visible while the balloon rolls along it.
			setLaneModifier(roller, if phase == "Warning" then 0 elseif phase == "Rolling" then 0.6 else 1)
			if phase == "Gone" and previous == "Rolling" then
				popRoller(roller, position, cameraPosition)
			end
		end
		if phase == "Warning" then
			-- The lane flashes faster and faster until the balloon sets off.
			local progress = math.clamp(1 - (roller.StartAt - serverTime) / warningTime, 0, 1)
			local lit = math.floor(serverTime * (3 + 7 * progress) * 2) % 2 == 0
			setLaneModifier(roller, if lit then 0 else 0.7)
		end
		if phase == "Warning" or phase == "Rolling" then
			local pose = CFrame.new(position) * CFrame.fromAxisAngle(roller.Axis, travelled / roller.Radius)
			for index, part in roller.Parts do
				table.insert(parts, part)
				table.insert(cframes, pose * roller.Offsets[index])
			end
			if phase == "Rolling" and root then
				checkRollerHit(roller, position, root, now)
			end
		end
	end
end

local function step()
	if
		next(spinners) == nil
		and next(risers) == nil
		and next(wobblers) == nil
		and next(fallingTiles) == nil
		and next(conveyors) == nil
		and next(movers) == nil
		and next(crates) == nil
		and next(rollers) == nil
	then
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
		local cframe = riser.Base + Vector3.new(0, offset, 0)
		table.insert(parts, part)
		table.insert(cframes, cframe)
		if part:GetAttribute("Water") == true then
			WaterSurfaces.Update(part, cframe)
		end
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
	stepConveyors(serverTime, cameraPosition, parts, cframes)
	stepMovers(serverTime, cameraPosition, parts, cframes)
	stepCrates(serverTime, cameraPosition, parts, cframes, if canBeHit then root else nil, now)
	stepRollers(serverTime, cameraPosition, parts, cframes, if canBeHit then root else nil, now)

	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- A pad is a cushion plus its rim; both bounce, so both squish together.
local function padParts(pad: BasePart): { BasePart }
	local parts = { pad }
	local parent = pad.Parent
	if parent then
		for _, sibling in parent:GetChildren() do
			if
				sibling ~= pad
				and sibling:IsA("BasePart")
				and CollectionService:HasTag(sibling, Tags.BouncePad)
				and MathUtil.flat(sibling.Position - pad.Position).Magnitude < 0.5
			then
				table.insert(parts, sibling)
			end
		end
	end
	return parts
end

local function squishPart(part: BasePart)
	if squishing[part] then
		return
	end
	squishing[part] = true
	local rest = part.CFrame
	local down = TweenService:Create(
		part,
		TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = rest - Vector3.new(0, 0.35, 0) }
	)
	local up = TweenService:Create(
		part,
		TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
		{ CFrame = rest }
	)
	down.Completed:Once(function()
		up:Play()
	end)
	up.Completed:Once(function()
		squishing[part] = nil
	end)
	down:Play()
end

local function squishPad(pad: BasePart)
	local model = pad:FindFirstAncestorOfClass("Model")
	if model and movers[model] then
		return -- a pad riding a mover is already being moved every frame
	end
	for _, part in padParts(pad) do
		squishPart(part)
	end
end

function HazardController.Init()
	local registrations: { [string]: (Instance) -> () } = {
		[Tags.Spinner] = registerSpinner,
		[Tags.Riser] = registerRiser,
		[Tags.Wobbler] = registerWobbler,
		[Tags.FallingTile] = registerFallingTile,
		[Tags.Conveyor] = registerConveyor,
		[Tags.Mover] = registerMover,
		[Tags.Crate] = registerCrate,
		[Tags.Roller] = registerRoller,
		[Tags.PaintBucket] = registerPaintBucket,
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
