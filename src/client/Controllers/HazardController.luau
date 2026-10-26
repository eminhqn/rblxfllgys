--!strict
-- Animates moving hazards on this client and checks them against the local Bloblet.
--
-- Spinners: every client computes the same pose from the synced server clock, so all players see
-- the bar in the same place. Mid-round the server can change a spinner's speed (see
-- Hazards.SetSpinnerSpeed), add one that flashes for a while before it turns solid, or make one
-- harmless for a moment. Collision is judged against exactly what this player sees, which keeps
-- hits fair under lag. Getting knocked down only hurts the player who reports it, so the client
-- decides it and tells the server.
--
-- Risers (e.g. Rising Tide water), Wobblers (tilting planks), FallingTiles (Cloud Crown puffs,
-- Pinwheel Panic rings, Popcorn Plates; each can set its own WarningTime and burst into popcorn),
-- Conveyors (sliding slats plus a surface speed), Movers (platforms gliding back and forth) and
-- Crates (target circle, drop, slide, smash) and Rollers (giant balloons and gumdrops: arrows on
-- the floor, or up a slope, showing the way they'll go, then roll or hop, pop) are driven by
-- attributes plus the same clock, so they also line up with the server's rules. Crate and roller
-- hits are judged here, like spinner hits. Paint Grab power-ups burst in a team's colour when the server marks them grabbed.
--
-- Anchored parts that this client moves are also given the matching velocity, which is what lets
-- Bloblets ride conveyors and moving platforms.
--
-- With StreamingEnabled a hazard model can reach this client before the parts inside it, so models
-- are (re)registered whenever more of their parts arrive.
--
-- Swingers (candy hammers, the wobbling cake) turn about their pivot; hammer heads knock over
-- whoever they catch, harder the faster they're swinging. Spike traps pop up and sink on a timer
-- (peeking out just before they rise) and fling whoever they catch. Jelly tiles sink while
-- someone stands on them (the server sets how fast) and melt away at the bottom.
--
-- Bounce pads are detected by MovementController; this module only plays the squish.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
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
	GraceUntil: number, -- server time; until then the bar passes through Bloblets harmlessly
	Ghost: boolean, -- the arm's collision is switched off on this client
	AppearAt: number, -- server time a spinner added mid-round turns solid (it flashes until then)
	Fade: number, -- LocalTransparencyModifier last written to its bar
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
	Warning: number, -- seconds of flashing before it drops
	Popcorn: boolean, -- bursts into popcorn as it drops (Popcorn Plates)
	Popped: boolean,
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

type Arrow = {
	Parts: { Part },
	Along: number, -- distance from the balloon's starting point to this arrow's tip
	Index: number,
	Transparency: number, -- what was last written to its parts
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
	Arrows: { Arrow }, -- drawn locally, never replicated
	Color: Color3,
	Phase: HazardMath.RollerPhase,
}

type Swinger = {
	Base: CFrame, -- the pivot at rest
	Parts: { BasePart },
	Offsets: { CFrame },
	Amplitude: Vector3,
	Speed: number,
	Phase: number,
	Head: BasePart?, -- hammers: the part that hits
	HeadOffset: CFrame,
}

type SpikeTrap = {
	Base: CFrame, -- the plate
	PlateSize: Vector3,
	Spikes: { BasePart },
	Offsets: { CFrame },
	Period: number,
	UpTime: number,
	Phase: number,
	Height: number,
	Rise: number, -- what the spikes were last moved to
}

type JellyTile = {
	Base: CFrame, -- the pad at the top
	Pad: BasePart,
	Parts: { BasePart },
	Offsets: { CFrame },
	Level: number,
	Rate: number,
	At: number,
	Depth: number, -- how far it sinks
	Gone: boolean,
	Hidden: boolean, -- what was last written to its parts
	Seed: number,
}

local spinners: { [Model]: Spinner } = {}
local swingers: { [Model]: Swinger } = {}
local spikeTraps: { [Model]: SpikeTrap } = {}
local jellies: { [Model]: JellyTile } = {}
local attributeWatchers: { [Model]: RBXScriptConnection } = {}
local partWatchers: { [Model]: RBXScriptConnection } = {}
local risers: { [BasePart]: Riser } = {}
local wobblers: { [BasePart]: Wobbler } = {}
local fallingTiles: { [Model]: FallingTile } = {}
local conveyors: { [Model]: Conveyor } = {}
local movers: { [Model]: Mover } = {}
local crates: { [Model]: Crate } = {}
local rollers: { [Model]: Roller } = {}
local pickupWatchers: { [Model]: RBXScriptConnection } = {}
local spinnerWatchers: { [Model]: RBXScriptConnection } = {}
local arrowFolder: Folder? = nil
local lastHitTime = -math.huge
local squishing: { [BasePart]: boolean } = {}
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local ROOT_RADIUS = BlobletRig.Dimensions.RootDiameter / 2
local HIT_MARGIN = 0.25
local TILE_WARNING_COLOR = Color3.fromRGB(255, 72, 120)
local TILE_FALL_ACCELERATION = 70
local TILE_FADE_TIME = 1.2
local EFFECT_DISTANCE = 250 -- crate smashes further away than this are skipped
local MARKER_COLOR = Color3.fromRGB(255, 72, 120)
local MARKER_FLASH_COLOR = Color3.fromRGB(255, 220, 60)
local MARKER_START_SCALE = 1.5 -- the circle tightens from this size onto the landing spot
local ARROW_SPACING = 7 -- studs between balloon arrows
local ARROW_INSET = 3 -- first arrow this far in from the edge of the deck
local ARROW_MARCH_RATE = 9 -- arrows per second the lit one moves along while warning
local ARROW_LIT = 0.05
local ARROW_DIM = 0.6
local HAMMER_SAMPLE = 0.05 -- seconds ahead we look to see how fast a hammer head is moving
local HAMMER_MIN_SPEED = 7 -- a hammer barely moving at the end of its swing doesn't knock you over
local SPIKE_FLING = 40 -- studs/s upwards
local SPIKE_PUSH = 18 -- studs/s back the way you came

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
		GraceUntil = numberAttribute(instance, "GraceUntil", 0),
		Ghost = if previous then previous.Ghost else false,
		AppearAt = numberAttribute(instance, "AppearAt", 0),
		Fade = if previous then previous.Fade else 0,
	}
	-- The server can speed a spinner up mid-round (Hazards.SetSpinnerSpeed changes Speed and Phase
	-- together, so the bar carries on from where it is) or give it a grace period.
	if not spinnerWatchers[instance] then
		spinnerWatchers[instance] = instance.AttributeChanged:Connect(function(name: string)
			local spinner = spinners[instance]
			if not spinner then
				return
			end
			if name == "Speed" or name == "Phase" then
				spinner.Speed = numberAttribute(instance, "Speed", 1)
				spinner.Phase = numberAttribute(instance, "Phase", 0)
				spinner.Arm.AssemblyAngularVelocity = Vector3.new(0, spinner.Speed, 0)
			elseif name == "GraceUntil" then
				spinner.GraceUntil = numberAttribute(instance, "GraceUntil", 0)
			elseif name == "AppearAt" then
				spinner.AppearAt = numberAttribute(instance, "AppearAt", 0)
			end
		end)
	end
end

local function setSpinnerFade(spinner: Spinner, fade: number)
	if spinner.Fade == fade then
		return
	end
	spinner.Fade = fade
	spinner.Arm.LocalTransparencyModifier = fade
	for _, decor in spinner.Decor do
		decor.LocalTransparencyModifier = fade
	end
end

-- A spinner that's about to appear flashes, faster and faster, so everyone can see where it'll be.
local function flashSpinner(spinner: Spinner, serverTime: number)
	local left = spinner.AppearAt - serverTime
	if left <= 0 then
		setSpinnerFade(spinner, 0)
		return
	end
	local progress = 1 - math.clamp(left / Config.Hazards.SpinnerWarningTime, 0, 1)
	local flashesPerSecond = 2.5 + 7.5 * progress
	local lit = math.floor(serverTime * flashesPerSecond * 2) % 2 == 0
	setSpinnerFade(spinner, if lit then 0.15 else 0.8)
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
	MovementController.HazardHit(impulse, strength)
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
		Warning = numberAttribute(instance, "WarningTime", Config.Hazards.TileWarningTime),
		Popcorn = instance:GetAttribute("Popcorn") == true,
		Popped = if previous then previous.Popped else false,
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

local function getArrowFolder(): Folder
	local existing = arrowFolder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "WobbleArrows"
	created.Parent = Workspace
	arrowFolder = created
	return created
end

-- Chevrons on the floor along a balloon's path, pointing the way it will roll. They're local
-- parts made from the balloon's attributes, so the server never sends them.
local function buildArrows(roller: Roller, laneFrom: Vector3, laneTo: Vector3, direction: Vector3): { Arrow }
	local arrows: { Arrow } = {}
	local laneLength = MathUtil.flat(laneTo - laneFrom).Magnitude
	if laneLength < 1 then
		return arrows
	end
	local folder = getArrowFolder()
	local startAlong = MathUtil.flat(laneFrom - roller.Origin):Dot(direction)
	local side = Vector3.new(-direction.Z, 0, direction.X)
	local armLength = math.clamp(roller.Radius * 0.7, 2.4, 4.2)
	local climb = (laneTo.Y - laneFrom.Y) / laneLength -- the lane can run up or down a slope
	-- A point just above the floor, `along` studs down the lane and `across` to its side.
	local function onLane(along: number, across: number): Vector3
		return Vector3.new(laneFrom.X, laneFrom.Y + 0.32 + climb * along, laneFrom.Z) -- clear of floor markings
			+ direction * along
			+ side * across
	end
	local distance = ARROW_INSET
	local index = 0
	while distance <= laneLength - 1 do
		index += 1
		local tip = onLane(distance, 0)
		local parts: { Part } = {}
		for _, sign in { -1, 1 } do
			-- Each arm runs 45 degrees back from the tip.
			local reach = armLength / 2 * math.sqrt(0.5)
			local center = onLane(distance - reach, sign * reach)
			local part = Instance.new("Part")
			part.Name = "Arrow"
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Material = Enum.Material.Neon
			part.Color = roller.Color
			part.Transparency = 1
			part.Size = Vector3.new(0.75, 0.12, armLength)
			part.CFrame = CFrame.lookAt(center, tip)
			part.Parent = folder
			table.insert(parts, part)
		end
		table.insert(arrows, { Parts = parts, Along = startAlong + distance, Index = index, Transparency = 1 })
		distance += ARROW_SPACING
	end
	return arrows
end

local function setArrowTransparency(arrow: Arrow, transparency: number)
	if arrow.Transparency == transparency then
		return
	end
	arrow.Transparency = transparency
	for _, part in arrow.Parts do
		part.Transparency = transparency
	end
end

local function destroyArrows(roller: Roller)
	for _, arrow in roller.Arrows do
		for _, part in arrow.Parts do
			part:Destroy()
		end
	end
	table.clear(roller.Arrows)
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
	for _, child in instance:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(parts, child)
			table.insert(offsets, CFrame.new(origin):ToObjectSpace(child.CFrame))
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
		Arrows = {},
		Color = ball.Color,
		Phase = "Waiting" :: HazardMath.RollerPhase,
	}
	roller.Arrows =
		buildArrows(roller, vectorAttribute(instance, "LaneFrom"), vectorAttribute(instance, "LaneTo"), direction)
	setRollerHidden(roller, true)
	rollers[instance] = roller
end

-- Paint Grab power-ups: burst in the grabbing team's colour, and tell the HUD if it was us.
local function registerPaintPickup(instance: Instance)
	if not instance:IsA("Model") or pickupWatchers[instance] then
		return
	end
	pickupWatchers[instance] = instance:GetAttributeChangedSignal("SplashColor"):Connect(function()
		local color = instance:GetAttribute("SplashColor")
		local camera = Workspace.CurrentCamera
		local position = instance:GetPivot().Position
		if typeof(color) ~= "Color3" or not camera then
			return
		end
		local kind = instance:GetAttribute("Kind")
		if instance:GetAttribute("GrabbedBy") == Players.LocalPlayer.UserId and typeof(kind) == "string" then
			ClientEvents.PowerUp:Fire(kind)
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

-- Re-reads a model's attributes into its record whenever the server changes them.
local function watchAttributes(model: Model, reread: () -> ())
	if attributeWatchers[model] then
		return
	end
	attributeWatchers[model] = model.AttributeChanged:Connect(reread)
end

local function registerSwinger(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	watchParts(instance, registerSwinger)
	local pivot = instance.PrimaryPart
	if not pivot then
		return -- not streamed in yet; tried again when more parts arrive
	end
	local previous = swingers[instance]
	local base = if previous then previous.Base else pivot.CFrame
	local parts, offsets = collectParts(
		instance,
		base,
		if previous then previous.Parts else nil,
		if previous then previous.Offsets else nil
	)
	local head: BasePart? = nil
	local headOffset = CFrame.identity
	if instance:GetAttribute("Hits") == true then
		for index, part in parts do
			if part.Name == "Head" then
				head = part
				headOffset = offsets[index]
			end
		end
	end
	local record: Swinger = {
		Base = base,
		Parts = parts,
		Offsets = offsets,
		Amplitude = vectorAttribute(instance, "Amplitude"),
		Speed = numberAttribute(instance, "Speed", 1),
		Phase = numberAttribute(instance, "Phase", 0),
		Head = head,
		HeadOffset = headOffset,
	}
	swingers[instance] = record
	-- The cake wobbles harder later in the round: the server changes Amplitude.
	watchAttributes(instance, function()
		local current = swingers[instance]
		if current then
			current.Amplitude = vectorAttribute(instance, "Amplitude")
			current.Speed = numberAttribute(instance, "Speed", 1)
			current.Phase = numberAttribute(instance, "Phase", 0)
		end
	end)
end

local function registerSpikes(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	watchParts(instance, registerSpikes)
	local plate = instance.PrimaryPart
	if not plate then
		return
	end
	local previous = spikeTraps[instance]
	local base = if previous then previous.Base else plate.CFrame
	local spikes: { BasePart } = {}
	local offsets: { CFrame } = {}
	for _, child in instance:GetChildren() do
		if child.Name == "Spike" and child:IsA("BasePart") then
			local known = if previous then table.find(previous.Spikes, child) else nil
			table.insert(spikes, child)
			table.insert(
				offsets,
				if previous and known then previous.Offsets[known] else base:ToObjectSpace(child.CFrame)
			)
		end
	end
	spikeTraps[instance] = {
		Base = base,
		PlateSize = plate.Size,
		Spikes = spikes,
		Offsets = offsets,
		Period = numberAttribute(instance, "Period", 0),
		UpTime = numberAttribute(instance, "UpTime", 1),
		Phase = numberAttribute(instance, "Phase", 0),
		Height = numberAttribute(instance, "Height", 2.4),
		Rise = if previous then previous.Rise else 1,
	}
end

local function readJelly(model: Model, tile: JellyTile)
	tile.Level = numberAttribute(model, "Level", 0)
	tile.Rate = numberAttribute(model, "Rate", 0)
	tile.At = numberAttribute(model, "At", 0)
	tile.Depth = numberAttribute(model, "SinkDepth", 6)
	tile.Gone = model:GetAttribute("Gone") == true
end

local function registerJelly(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	watchParts(instance, registerJelly)
	local pad = instance.PrimaryPart
	if not pad then
		return
	end
	local previous = jellies[instance]
	local base = if previous then previous.Base else pad.CFrame
	local parts, offsets = collectParts(
		instance,
		base,
		if previous then previous.Parts else nil,
		if previous then previous.Offsets else nil
	)
	local tile: JellyTile = {
		Base = base,
		Pad = pad,
		Parts = parts,
		Offsets = offsets,
		Level = 0,
		Rate = 0,
		At = 0,
		Depth = 6,
		Gone = false,
		Hidden = if previous then previous.Hidden else false,
		Seed = math.random() * 100,
	}
	readJelly(instance, tile)
	jellies[instance] = tile
	watchAttributes(instance, function()
		local current = jellies[instance]
		if current then
			readJelly(instance, current)
		end
	end)
end

local function unregister(instance: Instance)
	if instance:IsA("Model") then
		local watcher = partWatchers[instance]
		if watcher then
			watcher:Disconnect()
			partWatchers[instance] = nil
		end
		local attributeWatcher = attributeWatchers[instance]
		if attributeWatcher then
			attributeWatcher:Disconnect()
			attributeWatchers[instance] = nil
		end
		swingers[instance] = nil
		spikeTraps[instance] = nil
		jellies[instance] = nil
		spinners[instance] = nil
		local spinnerWatcher = spinnerWatchers[instance]
		if spinnerWatcher then
			spinnerWatcher:Disconnect()
			spinnerWatchers[instance] = nil
		end
		conveyors[instance] = nil
		movers[instance] = nil
		crates[instance] = nil
		local roller = rollers[instance]
		if roller then
			destroyArrows(roller)
			rollers[instance] = nil
		end
		local pickupWatcher = pickupWatchers[instance]
		if pickupWatcher then
			pickupWatcher:Disconnect()
			pickupWatchers[instance] = nil
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

local POPCORN_COLORS = { Color3.fromRGB(255, 252, 236), Color3.fromRGB(255, 236, 170), Color3.fromRGB(255, 214, 120) }

local function popTile(tile: FallingTile, cameraPosition: Vector3)
	local position = tile.Base.Position
	if (position - cameraPosition).Magnitude > EFFECT_DISTANCE then
		return
	end
	Effects.Burst(position + Vector3.new(0, 1, 0), {
		Count = 14,
		Colors = POPCORN_COLORS,
		Size = Vector3.one * 0.8,
		Speed = 14,
		Up = 26,
		Gravity = 90,
		Life = 1,
		Shape = Enum.PartType.Ball,
	})
	Sfx.PlayAt("PlatePop", position)
end

local function stepTiles(serverTime: number, cameraPosition: Vector3, parts: { BasePart }, cframes: { CFrame })
	for model, tile in fallingTiles do
		local warning = tile.Warning
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
			if tile.Popcorn and not tile.Popped then
				tile.Popped = true
				popTile(tile, cameraPosition)
			end
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
		MovementController.HazardHit(away * rules.FallKnockback + lift, rules.FallHitStrength)
	else
		local push = crate.SlideVelocity * rules.SlideKnockback + away * 8
		MovementController.HazardHit(push + lift, rules.SlideHitStrength)
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
	MovementController.HazardHit(impulse, rules.Strength)
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
			if phase == "Gone" then
				destroyArrows(roller)
				if previous == "Rolling" then
					popRoller(roller, position, cameraPosition)
				end
			end
		end
		if phase == "Warning" then
			-- A bright arrow marches along the path, the way the balloon is about to go.
			local lead = math.floor(serverTime * ARROW_MARCH_RATE)
			for _, arrow in roller.Arrows do
				setArrowTransparency(arrow, if (lead - arrow.Index) % 3 == 0 then ARROW_LIT else ARROW_DIM)
			end
		elseif phase == "Rolling" then
			-- Arrows stay lit ahead of the balloon and vanish as it rolls over them.
			for _, arrow in roller.Arrows do
				setArrowTransparency(arrow, if travelled >= arrow.Along - roller.Radius * 0.6 then 1 else ARROW_LIT)
			end
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

-- A hammer head hits whoever it touches, flinging them the way it's swinging. Near the end of its
-- swing it's hardly moving, and then it just nudges.
local function checkHammerHit(swinger: Swinger, pose: CFrame, serverTime: number, root: BasePart, now: number)
	local head = swinger.Head
	if not head then
		return
	end
	local headCFrame = pose * swinger.HeadOffset
	local closest = HazardMath.ClosestPointOnBox(headCFrame, head.Size, root.Position)
	if (root.Position - closest).Magnitude > ROOT_RADIUS + HIT_MARGIN then
		return
	end
	if now - lastHitTime < Config.Hazards.HitCooldown then
		return
	end
	local ahead = HazardMath.SwingAngles(swinger.Amplitude, swinger.Speed, swinger.Phase, serverTime + HAMMER_SAMPLE)
	local nextHead = swinger.Base * CFrame.Angles(ahead.X, ahead.Y, ahead.Z) * swinger.HeadOffset
	local velocity = (nextHead.Position - headCFrame.Position) / HAMMER_SAMPLE
	local speed = velocity.Magnitude
	if speed < HAMMER_MIN_SPEED then
		return
	end
	lastHitTime = now
	local push = MathUtil.flat(velocity)
	push = if push.Magnitude > 1e-3 then push.Unit else MathUtil.flat(root.Position - headCFrame.Position).Unit
	local hazards = Config.Hazards
	MovementController.HazardHit(
		push * (speed * hazards.KnockbackMultiplier + 8) + Vector3.new(0, hazards.KnockbackLift, 0),
		math.clamp(speed / 30, 0.3, 1)
	)
end

local function stepSwingers(
	serverTime: number,
	cameraPosition: Vector3,
	parts: { BasePart },
	cframes: { CFrame },
	root: BasePart?,
	now: number
)
	for _, swinger in swingers do
		if (swinger.Base.Position - cameraPosition).Magnitude > Config.Hazards.UpdateDistance then
			continue
		end
		local angles = HazardMath.SwingAngles(swinger.Amplitude, swinger.Speed, swinger.Phase, serverTime)
		local pose = swinger.Base * CFrame.Angles(angles.X, angles.Y, angles.Z)
		for index, part in swinger.Parts do
			table.insert(parts, part)
			table.insert(cframes, pose * swinger.Offsets[index])
		end
		if root then
			checkHammerHit(swinger, pose, serverTime, root, now)
		end
	end
end

local function stepSpikes(
	serverTime: number,
	cameraPosition: Vector3,
	parts: { BasePart },
	cframes: { CFrame },
	root: BasePart?,
	now: number
)
	for _, trap in spikeTraps do
		if (trap.Base.Position - cameraPosition).Magnitude > Config.Hazards.UpdateDistance then
			continue
		end
		local rise = HazardMath.SpikeRise(trap.Period, trap.UpTime, trap.Phase, serverTime)
		if rise ~= trap.Rise then
			trap.Rise = rise
			local pose = trap.Base * CFrame.new(0, (rise - 1) * trap.Height, 0)
			for index, spike in trap.Spikes do
				table.insert(parts, spike)
				table.insert(cframes, pose * trap.Offsets[index])
			end
		end
		if not root or rise < 0.6 or now - lastHitTime < Config.Hazards.HitCooldown then
			continue
		end
		local tall = trap.Height * rise
		local box = trap.Base * CFrame.new(0, trap.PlateSize.Y / 2 + tall / 2, 0)
		local closest =
			HazardMath.ClosestPointOnBox(box, Vector3.new(trap.PlateSize.X, tall, trap.PlateSize.Z), root.Position)
		if (root.Position - closest).Magnitude > ROOT_RADIUS + HIT_MARGIN then
			continue
		end
		lastHitTime = now
		-- Flung up and back the way you came.
		local back = -MathUtil.flat(root.AssemblyLinearVelocity)
		if back.Magnitude < 1 then
			back = -MathUtil.flat(root.CFrame.LookVector)
		end
		back = if back.Magnitude > 1e-3 then back.Unit else Vector3.zAxis
		MovementController.HazardHit(back * SPIKE_PUSH + trap.Base.UpVector * SPIKE_FLING, 0.45)
	end
end

local function stepJellies(serverTime: number, cameraPosition: Vector3, parts: { BasePart }, cframes: { CFrame })
	for _, tile in jellies do
		local hidden = tile.Gone
		if hidden ~= tile.Hidden then
			tile.Hidden = hidden
			for _, part in tile.Parts do
				part.LocalTransparencyModifier = if hidden then 1 else 0
			end
		end
		if hidden or (tile.Base.Position - cameraPosition).Magnitude > Config.Hazards.UpdateDistance then
			continue
		end
		local level = HazardMath.JellyLevel(tile.Level, tile.Rate, tile.At, serverTime)
		local pose = tile.Base - Vector3.new(0, level * tile.Depth, 0)
		if tile.Rate > 0 then
			-- Wobbling as it sinks.
			local t = serverTime * 9
			local amount = 0.08 + 0.12 * level
			pose += Vector3.new(math.noise(t, tile.Seed) * amount, 0, math.noise(tile.Seed, t) * amount)
		end
		for index, part in tile.Parts do
			table.insert(parts, part)
			table.insert(cframes, pose * tile.Offsets[index])
		end
		-- Sinking under whoever's standing on it.
		tile.Pad.AssemblyLinearVelocity = Vector3.new(0, if level < 1 then -tile.Rate * tile.Depth else 0, 0)
	end
end

local function step()
	if
		next(spinners) == nil
		and next(swingers) == nil
		and next(spikeTraps) == nil
		and next(jellies) == nil
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
	-- Frozen players (waiting for GO) can't be hit, even if a bar sweeps over them.
	local canBeHit = root ~= nil and not root.Anchored and not MovementController.IsRagdolled()

	-- Everything that moves this frame goes into one BulkMoveTo (the lists are reused).
	local parts = moveParts
	local cframes = moveCFrames
	table.clear(parts)
	table.clear(cframes)
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
		-- During a grace period (e.g. just after GO, when a bar may be lying across someone's spawn)
		-- the bar can't push or knock anyone: this client turns its collision off meanwhile.
		local ghost = serverTime < spinner.GraceUntil or serverTime < spinner.AppearAt
		if spinner.AppearAt > 0 then
			flashSpinner(spinner, serverTime)
		end
		if ghost ~= spinner.Ghost then
			spinner.Ghost = ghost
			spinner.Arm.CanCollide = not ghost
		end
		if canBeHit and root and not ghost then
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

	stepTiles(serverTime, cameraPosition, parts, cframes)
	stepConveyors(serverTime, cameraPosition, parts, cframes)
	stepMovers(serverTime, cameraPosition, parts, cframes)
	stepCrates(serverTime, cameraPosition, parts, cframes, if canBeHit then root else nil, now)
	stepRollers(serverTime, cameraPosition, parts, cframes, if canBeHit then root else nil, now)
	stepSwingers(serverTime, cameraPosition, parts, cframes, if canBeHit then root else nil, now)
	stepSpikes(serverTime, cameraPosition, parts, cframes, if canBeHit then root else nil, now)
	stepJellies(serverTime, cameraPosition, parts, cframes)

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
		[Tags.PaintPickup] = registerPaintPickup,
		[Tags.Swinger] = registerSwinger,
		[Tags.Spikes] = registerSpikes,
		[Tags.Jelly] = registerJelly,
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
