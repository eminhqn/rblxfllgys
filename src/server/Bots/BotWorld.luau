--!strict
-- The hazards, for bots.
--
-- Moving hazards only really move on players' screens (HazardController): every client moves its
-- own copy from the shared clock, and judges hits on its own player. The server's copies stay
-- where they were built. A player never notices, but bots are simulated on the server, so they'd
-- stand on platforms that aren't there and walk through spinning bars. This puts that right for
-- them, with the same maths (Shared/HazardMath) and rules the clients use:
--
--   * The server's still copies of moving parts go in the NoBots collision group: bots pass
--     through them (players aren't affected).
--   * Platforms a bot might stand on (movers, tilting planks, sinking jelly) get an invisible
--     copy in the BotsOnly group that the server moves in step with what players see. Only bots
--     collide with it. Falling tiles stop holding bots up the moment they drop.
--   * Conveyor belts carry bots along.
--   * Rising water (Rising Tide) is worked out from the same clock, so bots float and swim in it
--     just where players do (WaterSurfaceAt).
--   * Spinning bars, hammers, crates, balloons and spike traps knock bots over exactly as they
--     would a player (ActionService.Ragdoll), with the same hit cooldown.
--
-- BotBrain asks Threat what's about to hit a bot, so a sharp bot can jump a bar or step aside,
-- PathClear when to cross swinging hammers and spike traps, and RollerDodge which line to take
-- through rolling balloons and gumdrops (it knows where each one will be, from the same maths that
-- moves them). BotMotor asks HammerJump when to jump a hammer
-- swinging across a water slide, where it can't stop and wait.
--
-- Only hazards inside a match arena (Workspace.Arenas) are tracked; bots never leave matches.

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local HazardMath = require(Shared.HazardMath)
local MathUtil = require(Shared.MathUtil)
local Tags = require(Shared.Tags)

local ActionService = require(script.Parent.Parent.Services.ActionService)
local BotProfiler = require(script.Parent.BotProfiler)
local Bots = require(script.Parent.Bots)

local BotWorld = {}

-- A way through rolling balloons and gumdrops: step across to Offset (flat, from where it is),
-- and with Hold, stop going forwards meanwhile.
export type Dodge = { Offset: Vector3, Hold: boolean }

export type Threat = {
	Kind: string,
	Jump: boolean, -- jumping clears it
	Away: Vector3?, -- or step this way (flat, unit)
	Wait: boolean, -- or hold back a moment
}

type Copy = {
	Parts: { BasePart }, -- the invisible copies bots stand on
	Offsets: { CFrame }, -- from the hazard's reference pose
}

type Spinner = { Model: Model, Pivot: CFrame, ArmRest: CFrame, ArmSize: Vector3 }
-- (Each keeps its own copy of the attributes it moves by, kept up to date as they change, rather
-- than reading them every frame.)
type Mover = {
	Model: Model,
	Base: CFrame,
	Copy: Copy,
	Travel: Vector3,
	Speed: number,
	Phase: number,
	Reach: number, -- how far from Base it ever gets
	Watch: RBXScriptConnection,
}
type Wobbler = {
	Part: BasePart,
	Base: CFrame,
	Copy: Copy,
	Amplitude: number,
	Speed: number,
	Phase: number,
	Watch: RBXScriptConnection,
}
type Tile = { Model: Model, Parts: { BasePart }, Dropped: boolean, FallAt: number, Watch: RBXScriptConnection }
type Jelly = {
	Model: Model,
	Base: CFrame,
	Copy: Copy,
	Gone: boolean,
	Melted: boolean, -- its Gone attribute
	Level: number,
	Rate: number,
	At: number,
	Depth: number,
	Placed: number?, -- the level its copy was last put at (nil: needs placing)
	Watch: RBXScriptConnection,
}
type Swinger = { Model: Model, Base: CFrame, Head: BasePart?, HeadOffset: CFrame }
type Spikes = { Model: Model, Base: CFrame, PlateSize: Vector3 }
type Crate = { Model: Model, Base: CFrame, BoxSize: Vector3 }
type Roller = { Model: Model, Origin: Vector3, Radius: number }
type Water = { Part: BasePart, Base: CFrame }

local ROOT_RADIUS = BlobletRig.Dimensions.RootDiameter / 2
local HIT_MARGIN = 0.25
local HAMMER_SAMPLE = 0.05
local HAMMER_MIN_SPEED = 7
local SPIKE_FLING = 40
local SPIKE_PUSH = 18
local SLOW_PUSH = 1.1 -- a slow spinner bar pushes a bot along at this share of the bar's speed
local THREAT_SPINNER_LEAD = 0.35 -- seconds ahead a bot looks for a bar to jump
local THREAT_HAMMER_LEAD = 0.45
local HAMMER_JUMP_LOOK = 0.8 -- seconds ahead it looks for a hammer it's riding into on a water slide
local HAMMER_JUMP_STEP = 0.03
local HAMMER_JUMP_AFTER = 0.3 -- and how long after coming down that hammer must still miss it
local HAMMER_JUMP_SETTLE = 0.2 -- and any other: too soon after landing to jump again
-- Crossing swinging hammers and spike traps on foot (PathClear):
local PATH_NEAR = 18 -- studs: a hammer or timed trap this close (flat) is one to time
local PATH_HORIZON = 1.3 -- seconds of running (or standing) it looks ahead
local PATH_STEP = 0.05
local PATH_HEAD_ROOM = Vector3.one * 1.0 -- studs to spare round a hammer head
local PATH_TRAP_ROOM = Vector3.new(0.8, 0, 0.8) -- and round a spike trap
local HAMMER_JUMP_ROOM = Vector3.one * 1.2 -- studs to spare round the head
local THREAT_SPIKE_LEAD = 0.6
local THREAT_CRATE_LEAD = 0.5 -- seconds ahead a bot looks for a crate sliding along a belt into it
-- Studs across it might step, nearest first.
local COPY_RANGE = 80 -- copies further than this from every bot aren't moved (nobody's on them)
local DODGE_SHIFTS = { 0, 2, -2, 4, -4, 6, -6, 8, -8, 10, -10, 12, -12, 14, -14, 16, -16 }
local DODGE_ACROSS = 0.8 -- share of its speed it steps across at
local DODGE_ONWARDS = 0.55 -- ...and goes on forwards at meanwhile
local DODGE_ACCELERATION = 200 -- studs/s^2 it changes speed at, about (turning and stopping)
local DODGE_MIN_MARGIN = 0.2 -- when no way leaves the room it wants, one that's just clear
local DODGE_HOLD_COST = 5 -- stopping counts as stepping this much further across
local DODGE_SAMPLE = 0.1 -- seconds between the points it checks along each way
local DODGE_NEAR = 70 -- rollers further off than this (all the way ahead) don't matter yet

local arenas: Instance? = nil
local colliderFolders: { [Instance]: Folder } = {}

local spinners: { [Model]: Spinner } = {}
local movers: { [Model]: Mover } = {}
local wobblers: { [BasePart]: Wobbler } = {}
local tiles: { [Model]: Tile } = {}
local jellies: { [Model]: Jelly } = {}
local swingers: { [Model]: Swinger } = {}
local spikeTraps: { [Model]: Spikes } = {}
local crates: { [Model]: Crate } = {}
local rollers: { [Model]: Roller } = {}
local conveyors: { [Model]: boolean } = {}
local waters: { [BasePart]: Water } = {}

local lastHit: { [Player]: number } = {}
local floorParams = RaycastParams.new()
floorParams.RespectCanCollide = true
floorParams.CollisionGroup = Bots.CollisionGroup
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function vectorAttribute(instance: Instance, name: string): Vector3
	local value = instance:GetAttribute(name)
	return if typeof(value) == "Vector3" then value else Vector3.zero
end

-- The match arena this is in (nil if it isn't in one).
local function arenaOf(instance: Instance): Instance?
	local folder = arenas
	if not folder then
		return nil
	end
	local current: Instance? = instance
	while current and current.Parent ~= folder do
		current = current.Parent
	end
	return current
end

local function noBots(part: BasePart)
	part.CollisionGroup = Bots.NoBotsGroup
end

local function noBotsAll(model: Instance)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			noBots(descendant)
		end
	end
end

-- Invisible copies of the solid parts in `parts` that only bots collide with, placed (and later
-- moved) relative to `base`.
local function makeCopy(source: Instance, parts: { BasePart }, base: CFrame): Copy
	local arena = arenaOf(source)
	local folder = if arena then colliderFolders[arena] else nil
	if arena and not folder then
		local created = Instance.new("Folder")
		created.Name = "BotColliders"
		created.Parent = arena
		colliderFolders[arena] = created
		created.Destroying:Connect(function()
			colliderFolders[arena] = nil
		end)
		folder = created
	end
	local copy: Copy = { Parts = {}, Offsets = {} }
	for _, part in parts do
		if not part.CanCollide then
			continue
		end
		local clone = Instance.new("Part")
		clone.Name = "BotCollider"
		clone.Shape = if part:IsA("Part") then part.Shape else Enum.PartType.Block
		clone.Size = part.Size
		clone.CFrame = part.CFrame
		clone.Anchored = true
		clone.CanCollide = true
		clone.CanTouch = false
		clone.CastShadow = false
		clone.Transparency = 1
		clone.CollisionGroup = Bots.BotsOnlyGroup
		clone.CustomPhysicalProperties = part.CustomPhysicalProperties
		for _, name in { "Grip", "Flow" } do
			local value = part:GetAttribute(name)
			if value ~= nil then
				clone:SetAttribute(name, value)
			end
		end
		if CollectionService:HasTag(part, Tags.BouncePad) then
			clone:SetAttribute("Power", part:GetAttribute("Power"))
			CollectionService:AddTag(clone, Tags.BouncePad)
		end
		clone.Parent = folder or Workspace
		table.insert(copy.Parts, clone)
		table.insert(copy.Offsets, base:ToObjectSpace(part.CFrame))
	end
	return copy
end

local function moveCopy(copy: Copy, pose: CFrame, velocity: Vector3?)
	for index, part in copy.Parts do
		table.insert(moveParts, part)
		table.insert(moveCFrames, pose * copy.Offsets[index])
		if velocity then
			part.AssemblyLinearVelocity = velocity
		end
	end
end

local function destroyCopy(copy: Copy)
	for _, part in copy.Parts do
		part:Destroy()
	end
	table.clear(copy.Parts)
end

local function partsOf(model: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-------------------------------------------------------------------------------------------------
-- Registering hazards as they're built
-------------------------------------------------------------------------------------------------

local function registerSpinner(instance: Instance)
	if not instance:IsA("Model") or spinners[instance] then
		return
	end
	local hub = instance:FindFirstChild("Hub")
	local arm = instance:FindFirstChild("Arm")
	if not (hub and hub:IsA("BasePart") and arm and arm:IsA("BasePart")) then
		return
	end
	local pivot = CFrame.new(hub.Position.X, arm.Position.Y, hub.Position.Z)
	noBots(arm)
	for _, child in instance:GetChildren() do
		if child.Name == "ArmDecor" and child:IsA("BasePart") then
			noBots(child)
		end
	end
	spinners[instance] =
		{ Model = instance, Pivot = pivot, ArmRest = pivot:ToObjectSpace(arm.CFrame), ArmSize = arm.Size }
end

local function registerMover(instance: Instance)
	if not instance:IsA("Model") or movers[instance] then
		return
	end
	local reference = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	if not reference then
		return
	end
	local base = reference.CFrame
	local parts = partsOf(instance)
	local copy = makeCopy(instance, parts, base)
	for _, part in parts do
		noBots(part)
	end
	local mover: Mover
	local function refresh()
		mover.Travel = vectorAttribute(instance, "Travel")
		mover.Speed = numberAttribute(instance, "Speed", 1)
		mover.Phase = numberAttribute(instance, "Phase", 0)
		mover.Reach = mover.Travel.Magnitude
	end
	mover = {
		Model = instance,
		Base = base,
		Copy = copy,
		Travel = Vector3.zero,
		Speed = 1,
		Phase = 0,
		Reach = 0,
		Watch = instance.AttributeChanged:Connect(refresh),
	}
	refresh()
	movers[instance] = mover
end

local function registerWobbler(instance: Instance)
	if not instance:IsA("BasePart") or wobblers[instance] then
		return
	end
	local base = instance.CFrame
	local copy = makeCopy(instance, { instance }, base)
	noBots(instance)
	local wobbler: Wobbler
	local function refresh()
		wobbler.Amplitude = numberAttribute(instance, "Amplitude", 0.2)
		wobbler.Speed = numberAttribute(instance, "Speed", 1.5)
		wobbler.Phase = numberAttribute(instance, "Phase", 0)
	end
	wobbler = {
		Part = instance,
		Base = base,
		Copy = copy,
		Amplitude = 0.2,
		Speed = 1.5,
		Phase = 0,
		Watch = instance.AttributeChanged:Connect(refresh),
	}
	refresh()
	wobblers[instance] = wobbler
end

local function registerTile(instance: Instance)
	if not instance:IsA("Model") or tiles[instance] then
		return
	end
	local tile: Tile
	tile = {
		Model = instance,
		Parts = partsOf(instance),
		Dropped = false,
		FallAt = numberAttribute(instance, "FallAt", 0),
		Watch = instance:GetAttributeChangedSignal("FallAt"):Connect(function()
			tile.FallAt = numberAttribute(instance, "FallAt", 0)
		end),
	}
	tiles[instance] = tile
end

local function registerJelly(instance: Instance)
	if not instance:IsA("Model") or jellies[instance] then
		return
	end
	local pad = instance.PrimaryPart
	if not pad then
		return
	end
	local base = pad.CFrame
	local parts = partsOf(instance)
	local copy = makeCopy(instance, parts, base)
	for _, part in parts do
		noBots(part)
	end
	local jelly: Jelly
	local function refresh()
		jelly.Level = numberAttribute(instance, "Level", 0)
		jelly.Rate = numberAttribute(instance, "Rate", 0)
		jelly.At = numberAttribute(instance, "At", 0)
		jelly.Depth = numberAttribute(instance, "SinkDepth", 6)
		jelly.Melted = instance:GetAttribute("Gone") == true
		jelly.Placed = nil
	end
	jelly = {
		Model = instance,
		Base = base,
		Copy = copy,
		Gone = false,
		Melted = false,
		Level = 0,
		Rate = 0,
		At = 0,
		Depth = 6,
		Placed = nil,
		Watch = instance.AttributeChanged:Connect(refresh),
	}
	refresh()
	jellies[instance] = jelly
end

local function registerSwinger(instance: Instance)
	if not instance:IsA("Model") or swingers[instance] then
		return
	end
	local pivot = instance.PrimaryPart
	if not pivot or instance:GetAttribute("Hits") ~= true then
		-- Floors that tilt (a rocking bridge, the wobbling cake) stay where they are for bots:
		-- close enough, as they only tip a little.
		return
	end
	local base = pivot.CFrame
	local head: BasePart? = nil
	local headOffset = CFrame.identity
	for _, part in partsOf(instance) do
		noBots(part)
		if part.Name == "Head" then
			head = part
			headOffset = base:ToObjectSpace(part.CFrame)
		end
	end
	swingers[instance] = { Model = instance, Base = base, Head = head, HeadOffset = headOffset }
end

local function registerSpikes(instance: Instance)
	if not instance:IsA("Model") or spikeTraps[instance] then
		return
	end
	local plate = instance.PrimaryPart
	if not plate then
		return
	end
	for _, child in instance:GetChildren() do
		if child.Name == "Spike" and child:IsA("BasePart") then
			noBots(child)
		end
	end
	spikeTraps[instance] = { Model = instance, Base = plate.CFrame, PlateSize = plate.Size }
end

local function registerCrate(instance: Instance)
	if not instance:IsA("Model") or crates[instance] then
		return
	end
	local box = instance:FindFirstChild("Box")
	if not box or not box:IsA("BasePart") then
		return
	end
	noBotsAll(instance)
	crates[instance] = { Model = instance, Base = box.CFrame, BoxSize = box.Size }
end

local function registerRoller(instance: Instance)
	if not instance:IsA("Model") or rollers[instance] then
		return
	end
	local ball = instance:FindFirstChild("Ball")
	if not ball or not ball:IsA("BasePart") then
		return
	end
	noBotsAll(instance)
	rollers[instance] = {
		Model = instance,
		Origin = ball.Position,
		Radius = numberAttribute(instance, "Diameter", ball.Size.X) / 2,
	}
end

local function registerConveyor(instance: Instance)
	if not instance:IsA("Model") or conveyors[instance] then
		return
	end
	local belt = instance:FindFirstChild("Belt")
	if not belt or not belt:IsA("BasePart") then
		return
	end
	-- Its surface carries whoever stands on it (clients do the same for players).
	belt.AssemblyLinearVelocity = belt.CFrame.LookVector * numberAttribute(instance, "Speed", 0)
	conveyors[instance] = true
end

-- Water that rises (a Riser part with a Water attribute): bots float on it.
local function registerWater(instance: Instance)
	if not instance:IsA("BasePart") or waters[instance] or instance:GetAttribute("Water") ~= true then
		return
	end
	waters[instance] = { Part = instance, Base = instance.CFrame }
end

local function unregister(instance: Instance)
	if instance:IsA("Model") then
		spinners[instance] = nil
		local mover = movers[instance]
		if mover then
			mover.Watch:Disconnect()
			destroyCopy(mover.Copy)
			movers[instance] = nil
		end
		local tile = tiles[instance]
		if tile then
			tile.Watch:Disconnect()
			tiles[instance] = nil
		end
		local jelly = jellies[instance]
		if jelly then
			jelly.Watch:Disconnect()
			destroyCopy(jelly.Copy)
			jellies[instance] = nil
		end
		swingers[instance] = nil
		spikeTraps[instance] = nil
		crates[instance] = nil
		rollers[instance] = nil
		conveyors[instance] = nil
	elseif instance:IsA("BasePart") then
		waters[instance] = nil
		local wobbler = wobblers[instance]
		if wobbler then
			wobbler.Watch:Disconnect()
			destroyCopy(wobbler.Copy)
			wobblers[instance] = nil
		end
	end
end

-------------------------------------------------------------------------------------------------
-- Moving the bots' copies
-------------------------------------------------------------------------------------------------

-- Whether any bot is near enough a copy at `spot` (that moves up to `reach` from it) to matter.
local function anyBotNear(spot: Vector3, reach: number, botSpots: { Vector3 }): boolean
	local range = COPY_RANGE + reach
	for _, botSpot in botSpots do
		if (botSpot - spot).Magnitude <= range then
			return true
		end
	end
	return false
end

local function stepCopies(serverTime: number, botSpots: { Vector3 })
	table.clear(moveParts)
	table.clear(moveCFrames)
	for _, mover in movers do
		if not anyBotNear(mover.Base.Position, mover.Reach, botSpots) then
			continue
		end
		local offset = HazardMath.MoverOffset(mover.Travel, mover.Speed, mover.Phase, serverTime)
		moveCopy(
			mover.Copy,
			mover.Base + offset,
			HazardMath.MoverVelocity(mover.Travel, mover.Speed, mover.Phase, serverTime)
		)
	end
	for _, wobbler in wobblers do
		if not anyBotNear(wobbler.Base.Position, 0, botSpots) then
			continue
		end
		local angle = HazardMath.WobbleAngle(wobbler.Amplitude, wobbler.Speed, wobbler.Phase, serverTime)
		moveCopy(wobbler.Copy, wobbler.Base * CFrame.Angles(angle, 0, 0), nil)
	end
	for _, jelly in jellies do
		local gone = jelly.Melted
		if gone ~= jelly.Gone then
			-- Melted away (nothing left to stand on), or grown back.
			jelly.Gone = gone
			jelly.Placed = nil
			for _, part in jelly.Copy.Parts do
				part.CanCollide = not gone
			end
		end
		if gone then
			continue
		end
		-- Only squares that are sinking or bobbing back up move (and only near a bot).
		local level = HazardMath.JellyLevel(jelly.Level, jelly.Rate, jelly.At, serverTime)
		local placed = jelly.Placed
		if placed and math.abs(placed - level) < 0.02 then
			continue
		end
		if placed and not anyBotNear(jelly.Base.Position, 0, botSpots) then
			continue
		end
		jelly.Placed = level
		local sinking = Vector3.new(0, if level < 1 then -jelly.Rate * jelly.Depth else 0, 0)
		moveCopy(jelly.Copy, jelly.Base - Vector3.new(0, level * jelly.Depth, 0), sinking)
	end
	-- A tile stops holding bots up the moment it drops (players see it fall away).
	for _, tile in tiles do
		if tile.Dropped or tile.FallAt <= 0 or serverTime < tile.FallAt then
			continue
		end
		tile.Dropped = true
		for _, part in tile.Parts do
			if part.Parent then
				noBots(part)
			end
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-------------------------------------------------------------------------------------------------
-- Knocking bots over
-------------------------------------------------------------------------------------------------

local function knock(bot: Player, impulse: Vector3, strength: number, now: number)
	lastHit[bot] = now
	ActionService.Ragdoll(bot, impulse, strength)
end

local function touching(cframe: CFrame, size: Vector3, position: Vector3): (boolean, Vector3)
	local closest = HazardMath.ClosestPointOnBox(cframe, size, position)
	return (position - closest).Magnitude <= ROOT_RADIUS + HIT_MARGIN, closest
end

local function spinnerArm(spinner: Spinner, serverTime: number): CFrame
	local model = spinner.Model
	local angle =
		HazardMath.SpinnerAngle(numberAttribute(model, "Speed", 1), numberAttribute(model, "Phase", 0), serverTime)
	return spinner.Pivot * CFrame.Angles(0, angle, 0) * spinner.ArmRest
end

local function spinnerHarmless(spinner: Spinner, serverTime: number): boolean
	local model = spinner.Model
	return serverTime < numberAttribute(model, "GraceUntil", 0) or serverTime < numberAttribute(model, "AppearAt", 0)
end

local function hammerHead(swinger: Swinger, serverTime: number): CFrame
	local model = swinger.Model
	local angles = HazardMath.SwingAngles(
		vectorAttribute(model, "Amplitude"),
		numberAttribute(model, "Speed", 1),
		numberAttribute(model, "Phase", 0),
		serverTime
	)
	return swinger.Base * CFrame.Angles(angles.X, angles.Y, angles.Z) * swinger.HeadOffset
end

local function spikeBox(trap: Spikes, rise: number): (CFrame, Vector3)
	local height = numberAttribute(trap.Model, "Height", 2.4)
	local tall = height * rise
	local box = trap.Base * CFrame.new(0, trap.PlateSize.Y / 2 + tall / 2, 0)
	return box, Vector3.new(trap.PlateSize.X, tall, trap.PlateSize.Z)
end

local function spikeRise(trap: Spikes, serverTime: number): number
	local model = trap.Model
	return HazardMath.SpikeRise(
		numberAttribute(model, "Period", 0),
		numberAttribute(model, "UpTime", 1),
		numberAttribute(model, "Phase", 0),
		serverTime
	)
end

local function checkBot(bot: Player, root: BasePart, serverTime: number, now: number)
	local hazards = Config.Hazards
	if now - (lastHit[bot] or -math.huge) < hazards.HitCooldown then
		return
	end
	local position = root.Position

	for _, spinner in spinners do
		if spinnerHarmless(spinner, serverTime) then
			continue
		end
		local hit, closest = touching(spinnerArm(spinner, serverTime), spinner.ArmSize, position)
		if not hit then
			continue
		end
		local contact =
			HazardMath.SpinnerVelocityAt(spinner.Pivot.Position, numberAttribute(spinner.Model, "Speed", 1), closest)
		local speed = contact.Magnitude
		if speed < hazards.KnockdownSpeed then
			-- Near the hub the bar only pushes (a player's physics does this on their screen).
			local velocity = root.AssemblyLinearVelocity
			local push = contact * SLOW_PUSH
			root.AssemblyLinearVelocity = Vector3.new(push.X, velocity.Y, push.Z)
			continue
		end
		local strength = math.clamp((speed - hazards.KnockdownSpeed) / 20, 0.15, 1)
		knock(bot, contact * hazards.KnockbackMultiplier + Vector3.new(0, hazards.KnockbackLift, 0), strength, now)
		return
	end

	local crateRules = Config.Crates
	for _, crate in crates do
		local model = crate.Model
		local phase, offset = HazardMath.CratePose(
			numberAttribute(model, "LandAt", 0),
			crateRules.FallTime,
			crateRules.WarningTime,
			numberAttribute(model, "DropHeight", 0),
			vectorAttribute(model, "SlideVelocity"),
			numberAttribute(model, "SlideTime", 0),
			serverTime
		)
		if phase ~= "Falling" and phase ~= "Sliding" then
			continue
		end
		local pose = crate.Base + offset
		if not touching(pose, crate.BoxSize, position) then
			continue
		end
		local away = MathUtil.flat(position - pose.Position)
		away = if away.Magnitude > 1e-3 then away.Unit else Vector3.xAxis
		local lift = Vector3.new(0, crateRules.HitLift, 0)
		if phase == "Falling" then
			knock(bot, away * crateRules.FallKnockback + lift, crateRules.FallHitStrength, now)
		else
			local push = vectorAttribute(model, "SlideVelocity") * crateRules.SlideKnockback + away * 8
			knock(bot, push + lift, crateRules.SlideHitStrength, now)
		end
		return
	end

	local balloons = Config.Balloons
	for _, roller in rollers do
		local model = roller.Model
		local velocity = vectorAttribute(model, "Velocity")
		local phase, center = HazardMath.RollerPose(
			numberAttribute(model, "StartAt", 0),
			roller.Origin,
			velocity,
			numberAttribute(model, "Duration", 0),
			numberAttribute(model, "Hop", 0),
			numberAttribute(model, "HopRate", 1),
			balloons.WarningTime,
			serverTime
		)
		if phase ~= "Rolling" or (position - center).Magnitude > roller.Radius + ROOT_RADIUS - balloons.HitMargin then
			continue
		end
		local flatVelocity = MathUtil.flat(velocity)
		local along = if flatVelocity.Magnitude > 1e-3 then flatVelocity.Unit else Vector3.zero
		local away = MathUtil.flat(position - center)
		away = if away.Magnitude > 1e-3 then away.Unit else along
		knock(
			bot,
			along * balloons.Knockback + away * balloons.SideKnockback + Vector3.new(0, balloons.Lift, 0),
			balloons.Strength,
			now
		)
		return
	end

	for _, swinger in swingers do
		local head = swinger.Head
		if not head then
			continue
		end
		local headCFrame = hammerHead(swinger, serverTime)
		if not touching(headCFrame, head.Size, position) then
			continue
		end
		local nextHead = hammerHead(swinger, serverTime + HAMMER_SAMPLE)
		local velocity = (nextHead.Position - headCFrame.Position) / HAMMER_SAMPLE
		local speed = velocity.Magnitude
		if speed < HAMMER_MIN_SPEED then
			continue
		end
		local push = MathUtil.flat(velocity)
		push = if push.Magnitude > 1e-3 then push.Unit else MathUtil.flat(position - headCFrame.Position).Unit
		knock(
			bot,
			push * (speed * hazards.KnockbackMultiplier + 8) + Vector3.new(0, hazards.KnockbackLift, 0),
			math.clamp(speed / 30, 0.3, 1),
			now
		)
		return
	end

	for _, trap in spikeTraps do
		local rise = spikeRise(trap, serverTime)
		if rise < 0.6 then
			continue
		end
		local box, size = spikeBox(trap, rise)
		if not touching(box, size, position) then
			continue
		end
		local back = -MathUtil.flat(root.AssemblyLinearVelocity)
		if back.Magnitude < 1 then
			back = -MathUtil.flat(root.CFrame.LookVector)
		end
		back = if back.Magnitude > 1e-3 then back.Unit else Vector3.zAxis
		knock(bot, back * SPIKE_PUSH + trap.Base.UpVector * SPIKE_FLING, 0.45, now)
		return
	end
end

local botSpots: { Vector3 } = {}

local function step()
	if Bots.Count() == 0 then
		return
	end
	BotProfiler.Begin("BotWorld")
	local serverTime = Workspace:GetServerTimeNow()
	local now = os.clock()
	table.clear(botSpots)
	for _, bot in Bots.List() do
		local character = bot.Character
		local root = if character then character.PrimaryPart else nil
		if root then
			table.insert(botSpots, root.Position)
		end
	end
	local ok, err = pcall(function(): any
		stepCopies(serverTime, botSpots)
		for _, bot in Bots.List() do
			local character = bot.Character
			local root = if character then character.PrimaryPart else nil
			if
				not character
				or not root
				or root.Anchored
				or character:GetAttribute("Ragdolled") == true
				or not character:IsDescendantOf(Workspace)
			then
				continue
			end
			checkBot(bot, root, serverTime, now)
		end
		return nil
	end)
	if not ok then
		warn(`[BotWorld] {err}`)
	end
	BotProfiler.End("BotWorld")
end

-------------------------------------------------------------------------------------------------
-- Water (BotMotor)
-------------------------------------------------------------------------------------------------

-- The height of the water's surface over `position` right now, or nil if there's no water there
-- (what a player's client works out for itself: WaterSurfaces).
function BotWorld.WaterSurfaceAt(position: Vector3, serverTime: number?): number?
	if next(waters) == nil then
		return nil
	end
	local at = serverTime or Workspace:GetServerTimeNow()
	local best: number? = nil
	for part, water in waters do
		local rise = HazardMath.RiserOffset(
			numberAttribute(part, "StartTime", 0),
			numberAttribute(part, "Rate", 0),
			numberAttribute(part, "MaxRise", 0),
			at
		)
		local middle = water.Base.Position + Vector3.new(0, rise, 0)
		local offset = position - middle
		if math.abs(offset.X) <= part.Size.X / 2 and math.abs(offset.Z) <= part.Size.Z / 2 then
			local top = middle.Y + part.Size.Y / 2
			if not best or top > best then
				best = top
			end
		end
	end
	return best
end

-------------------------------------------------------------------------------------------------
-- Rolling balloons and gumdrops (BotBrain)
-------------------------------------------------------------------------------------------------

type RollerTrack = { Radius: number, Points: { [number]: Vector3 } }

-- Where each roller that matters will be over the next `samples` steps.
local function rollerTracks(position: Vector3, serverTime: number, samples: number): { RollerTrack }
	local warning = Config.Balloons.WarningTime
	local tracks: { RollerTrack } = {}
	for _, roller in rollers do
		local model = roller.Model
		local velocity = vectorAttribute(model, "Velocity")
		local startAt = numberAttribute(model, "StartAt", 0)
		local duration = numberAttribute(model, "Duration", 0)
		local hop = numberAttribute(model, "Hop", 0)
		local hopRate = numberAttribute(model, "HopRate", 1)
		if serverTime > startAt + duration then
			continue
		end
		local points: { [number]: Vector3 } = {}
		local near = false
		for index = 1, samples do
			local at = serverTime + (index - 1) * DODGE_SAMPLE
			local phase, center =
				HazardMath.RollerPose(startAt, roller.Origin, velocity, duration, hop, hopRate, warning, at)
			if phase == "Rolling" or phase == "Warning" then
				points[index] = center
				near = near or MathUtil.flat(center - position).Magnitude < DODGE_NEAR
			end
		end
		if near then
			table.insert(tracks, { Radius = roller.Radius, Points = points })
		end
	end
	return tracks
end

-- Whether there's floor to stand on at `spot` (about level with `feet`).
local function floorAt(spot: Vector3, feet: number): boolean
	local hit = Workspace:Raycast(Vector3.new(spot.X, feet + 4, spot.Z), Vector3.new(0, -9, 0), floorParams)
	return hit ~= nil
end

-- How a way through the rollers goes: stepping `shift` studs across (`across`) and, unless `hold`,
-- on forwards along `heading`, flown with the Bloblet's own acceleration from `velocity`. The
-- time (seconds from now) the first roller comes within `margin` of it, or nil if none does.
local function wayHit(
	tracks: { RollerTrack },
	samples: number,
	position: Vector3,
	velocity: Vector3,
	heading: Vector3,
	across: Vector3,
	runSpeed: number,
	shift: number,
	hold: boolean,
	margin: number
): number?
	local at = position
	local speed = velocity
	for index = 1, samples do
		if index > 1 then
			local left = shift - (at - position):Dot(across)
			local wanted = if math.abs(left) > 0.5
				then across * (DODGE_ACROSS * runSpeed * math.sign(left)) + heading * (if hold
					then 0
					else DODGE_ONWARDS * runSpeed)
				else heading * (if hold then 0 else runSpeed)
			speed = MathUtil.moveTowards(speed, wanted, DODGE_ACCELERATION * DODGE_SAMPLE)
			at += speed * DODGE_SAMPLE
		end
		for _, track in tracks do
			local center = track.Points[index]
			if center and MathUtil.flat(center - at).Magnitude < track.Radius + ROOT_RADIUS + margin then
				return (index - 1) * DODGE_SAMPLE
			end
		end
	end
	return nil
end

-- The line to take through rolling balloons and gumdrops for a Bloblet at `position`, heading
-- along `heading` (flat, unit), moving at `velocity` (flat) and able to run at `runSpeed`. It
-- tries carrying straight on, and stepping across (going on forwards slower, or stopping) up to
-- 16 studs either way, each flown with its own acceleration, and takes the least change that
-- keeps every roller at least `margin` studs off it for the next `horizon` seconds (or, if none
-- does, just clear of them). nil: straight on is clear. If nothing is clear, the way that gets
-- hit last.
function BotWorld.RollerDodge(
	position: Vector3,
	heading: Vector3,
	velocity: Vector3,
	runSpeed: number,
	horizon: number,
	margin: number
): Dodge?
	if next(rollers) == nil then
		return nil
	end
	local samples = math.max(1, math.floor(horizon / DODGE_SAMPLE) + 1)
	local tracks = rollerTracks(position, Workspace:GetServerTimeNow(), samples)
	if #tracks == 0 then
		return nil
	end
	local feet = position.Y - BlobletRig.Dimensions.RootHeight
	local across = Vector3.new(-heading.Z, 0, heading.X)
	local open: { number } = {}
	for _, shift in DODGE_SHIFTS do
		if shift == 0 or floorAt(position + across * shift, feet) then
			table.insert(open, shift)
		end
	end
	local fallback: Dodge? = nil
	local fallbackHit = -1
	for _, room in { margin, DODGE_MIN_MARGIN } do
		local best: Dodge? = nil
		local bestCost = math.huge
		for _, shift in open do
			if math.abs(shift) >= bestCost then
				break -- (shifts come nearest first: nothing further on can be cheaper)
			end
			for _, hold in { false, true } do
				local cost = math.abs(shift) + (if hold then DODGE_HOLD_COST else 0)
				if cost >= bestCost then
					continue
				end
				local hit = wayHit(tracks, samples, position, velocity, heading, across, runSpeed, shift, hold, room)
				if not hit then
					best, bestCost = { Offset = across * shift, Hold = hold }, cost
				elseif hit > fallbackHit then
					fallback, fallbackHit = { Offset = across * shift, Hold = hold }, hit
				end
			end
		end
		local chosen = best
		if chosen then
			if chosen.Offset.Magnitude < 0.1 and not chosen.Hold then
				return nil -- straight on is clear
			end
			return chosen
		end
	end
	return fallback
end

-------------------------------------------------------------------------------------------------
-- What's about to hit a bot (BotBrain)
-------------------------------------------------------------------------------------------------

-- `distance` (flat) studs along `path` (points from where the bot is, at its middle's height).
local function alongPath(path: { Vector3 }, distance: number): Vector3
	local left = distance
	for index = 1, #path - 1 do
		local from, to = path[index], path[index + 1]
		local length = MathUtil.flat(to - from).Magnitude
		if left <= length then
			return if length < 1e-3 then to else from + (to - from) * (left / length)
		end
		left -= length
	end
	return path[#path]
end

-- On foot, about to cross swinging hammers or timed spike traps along `path` (from where the bot
-- is, through the points it's heading for): whether there are any to time (Near), and whether to
-- go now (Go). It runs the crossing in its head from where each head and trap will be at every
-- moment: running on from `speed` gets it through untouched, so go; or it doesn't but standing
-- (stopping where it is) is safe, so wait; or neither, so whichever gets hit later. Spikes that
-- never go down aren't timed: the route goes round those.
function BotWorld.PathClear(path: { Vector3 }, speed: number, runSpeed: number): (boolean, boolean)
	local start = path[1]
	local heading = if #path >= 2 then MathUtil.flat(path[2] - start) else Vector3.zero
	local function ahead(spot: Vector3): boolean
		local offset = MathUtil.flat(spot - start)
		return offset.Magnitude < PATH_NEAR and (heading.Magnitude < 0.1 or offset:Dot(heading.Unit) > -4)
	end
	local hammers: { Swinger } = {}
	for _, swinger in swingers do
		if swinger.Head and ahead(swinger.Base.Position) then
			table.insert(hammers, swinger)
		end
	end
	local traps: { Spikes } = {}
	for _, trap in spikeTraps do
		if numberAttribute(trap.Model, "Period", 0) > 0 and ahead(trap.Base.Position) then
			table.insert(traps, trap)
		end
	end
	if #hammers == 0 and #traps == 0 then
		return false, true
	end
	local serverTime = Workspace:GetServerTimeNow()
	-- The first moment (seconds from now) one hits it, going `travelled(t)` studs along the path.
	local function firstHit(travelled: (number) -> number): number?
		for moment = 0, math.floor(PATH_HORIZON / PATH_STEP) do
			local t = moment * PATH_STEP
			local spot = alongPath(path, travelled(t))
			for _, swinger in hammers do
				local head = swinger.Head
				if head and touching(hammerHead(swinger, serverTime + t), head.Size + PATH_HEAD_ROOM, spot) then
					return t
				end
			end
			for _, trap in traps do
				if spikeRise(trap, serverTime + t) >= 0.5 then
					local box, size = spikeBox(trap, 1)
					if touching(box, size + PATH_TRAP_ROOM, spot) then
						return t
					end
				end
			end
		end
		return nil
	end
	local movement = Config.Movement
	local speedUp = math.max(runSpeed - speed, 0) / movement.GroundAcceleration
	local runHit = firstHit(function(t: number): number
		if t <= speedUp then
			return speed * t + movement.GroundAcceleration * t * t / 2
		end
		return speed * speedUp + movement.GroundAcceleration * speedUp * speedUp / 2 + runSpeed * (t - speedUp)
	end)
	if not runHit then
		return true, true
	end
	local stopIn = speed / movement.GroundDeceleration
	local stayHit = firstHit(function(t: number): number
		local moving = math.min(t, stopIn)
		return speed * moving - movement.GroundDeceleration * moving * moving / 2
	end)
	if not stayHit then
		return true, false
	end
	return true, runHit >= stayHit
end

-- The first hazard about to reach a Bloblet at `position` (moving at `velocity`), if any. With
-- `skipTimed`, hammers and spike traps are left out (PathClear is timing those).
function BotWorld.Threat(position: Vector3, velocity: Vector3, skipTimed: boolean?): Threat?
	local serverTime = Workspace:GetServerTimeNow()

	-- A spinning bar sweeping round: jump it.
	local ahead = serverTime + THREAT_SPINNER_LEAD
	local predicted = position + velocity * THREAT_SPINNER_LEAD
	for _, spinner in spinners do
		if spinnerHarmless(spinner, ahead) then
			continue
		end
		local arm = spinnerArm(spinner, ahead)
		local size = spinner.ArmSize + Vector3.new(1.5, 0, 1.5)
		if touching(arm, size, predicted) or touching(arm, size, position) then
			local top = arm.Position.Y + spinner.ArmSize.Y / 2
			-- Low bars can be jumped; a tall one can only be dodged.
			local jumpable = top - (position.Y - BlobletRig.Dimensions.RootHeight) < 4.5
			local away = MathUtil.flat(position - spinner.Pivot.Position)
			return {
				Kind = "Spinner",
				Jump = jumpable,
				Away = if not jumpable and away.Magnitude > 1e-3 then away.Unit else nil,
				Wait = false,
			}
		end
	end

	-- (Rolling balloons and gumdrops: see RollerDodge.)

	-- A crate's target circle under us: get off it. A crate sliding along a belt into us: step out
	-- of its way.
	local crateRules = Config.Crates
	local crateAt = serverTime + THREAT_CRATE_LEAD
	local cratePredicted = position + velocity * THREAT_CRATE_LEAD
	for _, crate in crates do
		local model = crate.Model
		local landAt = numberAttribute(model, "LandAt", 0)
		local dropHeight = numberAttribute(model, "DropHeight", 0)
		local slide = vectorAttribute(model, "SlideVelocity")
		local slideTime = numberAttribute(model, "SlideTime", 0)
		local phase, shift = HazardMath.CratePose(
			landAt,
			crateRules.FallTime,
			crateRules.WarningTime,
			dropHeight,
			slide,
			slideTime,
			serverTime
		)
		if phase == "Warning" or phase == "Falling" then
			local offset = MathUtil.flat(position - crate.Base.Position)
			if offset.Magnitude < crate.BoxSize.X + 1.5 then
				return {
					Kind = "Crate",
					Jump = false,
					Away = if offset.Magnitude > 1e-3 then offset.Unit else Vector3.xAxis,
					Wait = false,
				}
			end
		elseif phase == "Sliding" and slide.Magnitude > 0.5 then
			local _, soonShift = HazardMath.CratePose(
				landAt,
				crateRules.FallTime,
				crateRules.WarningTime,
				dropHeight,
				slide,
				slideTime,
				crateAt
			)
			local size = crate.BoxSize + Vector3.new(1, 0, 1)
			local current = crate.Base + shift
			if touching(crate.Base + soonShift, size, cratePredicted) or touching(current, size, position) then
				local along = MathUtil.flat(slide).Unit
				local across = Vector3.new(-along.Z, 0, along.X)
				if MathUtil.flat(position - current.Position):Dot(across) < 0 then
					across = -across
				end
				return { Kind = "SlidingCrate", Jump = false, Away = across, Wait = false }
			end
		end
	end

	if skipTimed then
		return nil
	end

	-- A hammer swinging through just ahead: wait for it to pass.
	local hammerAt = serverTime + THREAT_HAMMER_LEAD
	local hammerPredicted = position + velocity * THREAT_HAMMER_LEAD
	for _, swinger in swingers do
		local head = swinger.Head
		if not head then
			continue
		end
		local size = head.Size + Vector3.new(2, 2, 2)
		local headNow = hammerHead(swinger, serverTime)
		local headSoon = hammerHead(swinger, hammerAt)
		if touching(headSoon, size, hammerPredicted) or touching(headNow, size, hammerPredicted) then
			return { Kind = "Hammer", Jump = false, Away = nil, Wait = true }
		end
	end

	-- Spikes about to pop up where we're stepping: wait at the edge.
	local spikeAt = serverTime + THREAT_SPIKE_LEAD
	local spikePredicted = position + velocity * THREAT_SPIKE_LEAD
	for _, trap in spikeTraps do
		local rise = math.max(spikeRise(trap, serverTime), spikeRise(trap, spikeAt))
		if rise < 0.3 then
			continue
		end
		local box, size = spikeBox(trap, 1)
		if touching(box, size + Vector3.new(1, 0, 1), spikePredicted) then
			return { Kind = "Spikes", Jump = false, Away = nil, Wait = true }
		end
	end
	return nil
end

-- Riding a water slide (where it can't stop) towards a swinging hammer: whether carrying straight
-- on gets it hit (Threatened), and whether jumping right now takes it over the head and clear of it
-- (Jump), from where each head will be at every moment (the same maths that swings them). Jumping
-- too soon would bring it down in front of the hammer (or right in front of the next one, too
-- close to jump again), so this says jump only at a moment that works.
function BotWorld.HammerJump(position: Vector3, velocity: Vector3, serverTime: number): (boolean, boolean)
	local flat = MathUtil.flat(velocity)
	local speed = flat.Magnitude
	if speed < 5 or next(swingers) == nil then
		return false, false
	end
	local reach = speed * HAMMER_JUMP_LOOK + 10
	local near: { Swinger } = {}
	for _, swinger in swingers do
		local offset = MathUtil.flat(swinger.Base.Position - position)
		if swinger.Head and offset.Magnitude < reach and offset:Dot(flat) > -6 then
			table.insert(near, swinger)
		end
	end
	if #near == 0 then
		return false, false
	end
	-- The first hammer (of `only`, if given) that the path `at` (seconds on -> where its middle is)
	-- runs into between `from` and `to` seconds from now.
	local function firstHit(at: (number) -> Vector3, from: number, to: number, only: Swinger?): Swinger?
		for t = from, to, HAMMER_JUMP_STEP do
			local spot = at(t)
			for _, swinger in near do
				local head = swinger.Head
				if head and (not only or swinger == only) then
					if touching(hammerHead(swinger, serverTime + t), head.Size + HAMMER_JUMP_ROOM, spot) then
						return swinger
					end
				end
			end
		end
		return nil
	end
	local function riding(t: number): Vector3
		return position + velocity * t
	end
	local hammer = firstHit(riding, 0, HAMMER_JUMP_LOOK)
	if not hammer then
		return false, false
	end
	-- Jumping now: up and down (falling faster than it rises, as everyone does) at the speed it's
	-- going, till it's back down on the slide.
	local movement = Config.Movement
	local gravity = Workspace.Gravity
	local up = movement.JumpVelocity
	local apexTime = up / gravity
	local apex = up * up / (2 * gravity)
	local fall = gravity * movement.FallGravityMultiplier
	local function rise(t: number): number
		if t <= apexTime then
			return up * t - gravity * t * t / 2
		end
		return apex - fall * (t - apexTime) ^ 2 / 2
	end
	local landAt = apexTime
	while landAt < 2 and rise(landAt) > velocity.Y * landAt do
		landAt += 0.01
	end
	local function jumping(t: number): Vector3
		return position + flat * t + Vector3.new(0, rise(t), 0)
	end
	local landed = jumping(landAt)
	local function afterwards(t: number): Vector3
		return landed + velocity * (t - landAt)
	end
	local clear = firstHit(jumping, 0, landAt) == nil
		and firstHit(afterwards, landAt, landAt + HAMMER_JUMP_AFTER, hammer) == nil
		and firstHit(afterwards, landAt, landAt + HAMMER_JUMP_SETTLE) == nil
	return true, clear
end

-------------------------------------------------------------------------------------------------

function BotWorld.Init()
	for _, group in { Bots.CollisionGroup, Bots.NoBotsGroup, Bots.BotsOnlyGroup } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	-- Bots go through the still copies of moving hazards; only bots touch the moving copies.
	PhysicsService:CollisionGroupSetCollidable(Bots.CollisionGroup, Bots.NoBotsGroup, false)
	PhysicsService:CollisionGroupSetCollidable(Bots.BotsOnlyGroup, "Default", false)
	PhysicsService:CollisionGroupSetCollidable(Bots.BotsOnlyGroup, Bots.NoBotsGroup, false)
	PhysicsService:CollisionGroupSetCollidable(Bots.BotsOnlyGroup, Bots.BotsOnlyGroup, false)
	PhysicsService:CollisionGroupSetCollidable(Bots.BotsOnlyGroup, Bots.CollisionGroup, true)

	local existing = Workspace:FindFirstChild("Arenas")
	if existing then
		arenas = existing
	else
		local folder = Instance.new("Folder")
		folder.Name = "Arenas"
		folder.Parent = Workspace
		arenas = folder
	end

	local registrations: { [string]: (Instance) -> () } = {
		[Tags.Spinner] = registerSpinner,
		[Tags.Mover] = registerMover,
		[Tags.Wobbler] = registerWobbler,
		[Tags.FallingTile] = registerTile,
		[Tags.Jelly] = registerJelly,
		[Tags.Swinger] = registerSwinger,
		[Tags.Spikes] = registerSpikes,
		[Tags.Crate] = registerCrate,
		[Tags.Roller] = registerRoller,
		[Tags.Conveyor] = registerConveyor,
		[Tags.Riser] = registerWater,
	}
	for tag, register in registrations do
		local function inArena(instance: Instance)
			if arenaOf(instance) then
				-- Builders tag a model before filling it in, so wait for the next frame.
				task.defer(function()
					if instance.Parent and arenaOf(instance) then
						register(instance)
					end
				end)
			end
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(inArena)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(unregister)
		for _, instance in CollectionService:GetTagged(tag) do
			inArena(instance)
		end
	end
	Bots.Removing:Connect(function(bot: Player)
		lastHit[bot] = nil
	end)
	RunService.Heartbeat:Connect(step)
end

return BotWorld
