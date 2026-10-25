--!strict
-- The lobby playground, a second yard through an opening in the plaza's east side:
--   * the PARKOUR TOWER: platforms spiralling up round a tall pillar to a finish on its top, in
--     four stages split by three checkpoints (hops, moving platforms and a beam, a trampoline, a
--     backwards conveyor and a spinner, then tiny pads). ParkourService runs the timer and pays
--     150 Gumdrops for your first finish. Beside the way in stands its FASTEST TODAY board
--     (ParkourBoardService; clients draw it).
--   * a trampoline park with clouds to bounce up to
--   * three treadmill lanes (conveyors running against you) to dash up
--   * a bonk pit with a big spinner
-- Everything is built from the usual hazard pieces, which clients animate.
--
-- Layout: the playground floor runs from X = 74 to 170 and Z = -60 to 72 (top at Y = 0).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Leaderboards = require(Shared.Leaderboards)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Geometry = require(script.Parent.Geometry)
local Hazards = require(script.Parent.Hazards)

export type Zone = {
	CFrame: CFrame, -- the box that counts as being there
	Size: Vector3,
	Spot: CFrame, -- ground-level spot to put a player back on
	FloorY: number,
}

export type ParkourCourse = {
	Start: Zone,
	Checkpoints: { Zone },
	Finish: Zone,
	AreaCFrame: CFrame, -- leaving this box ends a run
	AreaSize: Vector3,
}

export type Playground = {
	Parkour: ParkourCourse,
}

type StepKind = "Pad" | "Checkpoint" | "MoverAcross" | "MoverOut" | "Beam" | "Bounce" | "Conveyor" | "Spinner"

type Step = {
	Angle: number, -- degrees round the tower
	Radius: number,
	Top: number, -- height of the top surface
	Width: number, -- across (out from the tower)
	Length: number, -- along the way round
	Kind: StepKind,
}

local PlaygroundBuilder = {}

PlaygroundBuilder.MinX, PlaygroundBuilder.MaxX = 74, 170
PlaygroundBuilder.MinZ, PlaygroundBuilder.MaxZ = -60, 72
PlaygroundBuilder.EntranceHalfWidth = 14 -- the opening in the plaza's east side, either side of Z = 0

local WHITE = Color3.fromRGB(255, 255, 255)
local FLOOR = Color3.fromRGB(214, 202, 255)
local PINK = Theme.Colors.Pink
local PURPLE = Color3.fromRGB(170, 124, 255)
local YELLOW = Theme.Colors.Yellow
local AQUA = Theme.Colors.Aqua
local ORANGE = Theme.Colors.Orange
local CLOUD = Color3.fromRGB(250, 250, 255)

local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

local TOWER_CENTER = Vector3.new(140, 0, -28)
local FINISH_TOP = 65.5
local FINISH_DIAMETER = 18
local ZONE_HEIGHT = 10

-- The course, bottom to top. Checked so every gap is a comfortable jump (about 3 studs up and up
-- to 4.5 across), except the trampoline, which launches you up to the next platform.
local STEPS: { Step } = {
	-- Stage 1: hops.
	{ Angle = 170, Radius = 18, Top = 3.5, Width = 7, Length = 7, Kind = "Pad" },
	{ Angle = 203, Radius = 17, Top = 6.5, Width = 7, Length = 7, Kind = "Pad" },
	{ Angle = 237, Radius = 16, Top = 9.5, Width = 7, Length = 7, Kind = "Pad" },
	{ Angle = 271, Radius = 17, Top = 12.5, Width = 7, Length = 7, Kind = "Pad" },
	{ Angle = 305, Radius = 18, Top = 15.5, Width = 6, Length = 6, Kind = "Pad" },
	{ Angle = 341, Radius = 17, Top = 18.5, Width = 11, Length = 11, Kind = "Checkpoint" },
	-- Stage 2: moving platforms and a beam.
	{ Angle = 17, Radius = 17, Top = 21, Width = 6, Length = 6, Kind = "MoverAcross" },
	{ Angle = 50, Radius = 17, Top = 23.5, Width = 5, Length = 5, Kind = "Pad" },
	{ Angle = 83, Radius = 17, Top = 26, Width = 6, Length = 6, Kind = "MoverOut" },
	{ Angle = 118, Radius = 17, Top = 28.5, Width = 3, Length = 12, Kind = "Beam" },
	{ Angle = 153, Radius = 17, Top = 31, Width = 6, Length = 6, Kind = "Pad" },
	{ Angle = 186, Radius = 17, Top = 34, Width = 11, Length = 11, Kind = "Checkpoint" },
	-- Stage 3: a trampoline, a conveyor that runs backwards and a spinner.
	{ Angle = 219, Radius = 17, Top = 35, Width = 9, Length = 9, Kind = "Bounce" },
	{ Angle = 252, Radius = 16, Top = 45, Width = 9, Length = 9, Kind = "Pad" },
	{ Angle = 290, Radius = 16, Top = 46.5, Width = 6, Length = 16, Kind = "Conveyor" },
	{ Angle = 332, Radius = 16, Top = 48, Width = 13, Length = 13, Kind = "Spinner" },
	{ Angle = 9, Radius = 17, Top = 50.5, Width = 6, Length = 6, Kind = "Pad" },
	{ Angle = 42, Radius = 17, Top = 53, Width = 11, Length = 11, Kind = "Checkpoint" },
	-- Stage 4: tiny pads up to the top.
	{ Angle = 77, Radius = 17, Top = 55.5, Width = 4.5, Length = 4.5, Kind = "Pad" },
	{ Angle = 107, Radius = 18, Top = 58, Width = 4.5, Length = 4.5, Kind = "Pad" },
	{ Angle = 139, Radius = 17, Top = 58, Width = 4.5, Length = 4.5, Kind = "Pad" },
	{ Angle = 168, Radius = 16, Top = 60.5, Width = 4.5, Length = 4.5, Kind = "Pad" },
	{ Angle = 196, Radius = 14, Top = 63, Width = 5, Length = 5, Kind = "Pad" },
}
local START_ANGLE, START_RADIUS = 140, 21
local STAGE_COLORS = { YELLOW, AQUA, PINK, ORANGE }

-- A board with the same text on both faces.
local function banner(parent: Instance, cframe: CFrame, size: Vector3, text: string, color: Color3)
	local board = Geometry.block(parent, size, cframe, color, { Name = "Banner", CanCollide = false })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui: SurfaceGui = Ui.new("SurfaceGui", {
			Face = face,
			SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
			PixelsPerStud = 30,
			LightInfluence = 0.2,
			Parent = board,
		})
		local label = Ui.label(
			gui,
			text,
			Theme.Fonts.Display,
			WHITE,
			UDim2.fromScale(0.9, 0.8),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		Ui.new("UIStroke", {
			Color = Theme.Colors.Ink,
			Thickness = 4,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			Parent = label,
		})
	end
end

-- Two posts and a banner across `line` (ground level; the banner faces along its LookVector).
local function arch(parent: Instance, line: CFrame, width: number, height: number, text: string, color: Color3)
	for _, side in { -1, 1 } do
		local foot = (line * CFrame.new(side * (width / 2 - 0.8), 0, 0)).Position
		Geometry.column(parent, height, 1.6, foot, WHITE, DECOR)
		Geometry.ball(parent, 2.4, foot + Vector3.new(0, height, 0), color, DECOR)
	end
	banner(parent, line * CFrame.new(0, height - 1.6, 0), Vector3.new(width - 2, 3.6, 0.8), text, color)
end

-- A sign on a post, readable from both sides, at ground position `bottom` facing `facing`.
local function sign(parent: Instance, text: string, bottom: Vector3, facing: Vector3, width: number, color: Color3)
	Geometry.column(parent, 4, 0.7, bottom, WHITE, { CastShadow = false })
	local center = bottom + Vector3.new(0, 4 + 1.6, 0)
	banner(parent, CFrame.lookAt(center, center + facing), Vector3.new(width, 3.2, 0.6), text, color)
end

local function zone(top: CFrame, width: number, length: number): Zone
	return {
		CFrame = top * CFrame.new(0, ZONE_HEIGHT / 2 - 1, 0),
		Size = Vector3.new(width, ZONE_HEIGHT, length),
		Spot = top,
		FloorY = top.Position.Y,
	}
end

-- The top-surface CFrame of a step: centred on it, facing the way round the tower.
local function topOf(angleDegrees: number, radius: number, height: number): CFrame
	local angle = math.rad(angleDegrees)
	local position = TOWER_CENTER + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
	local along = Vector3.new(-math.sin(angle), 0, math.cos(angle))
	return CFrame.lookAt(position, position + along)
end

local function buildFloor(parent: Instance)
	local minX, maxX = PlaygroundBuilder.MinX, PlaygroundBuilder.MaxX
	local minZ, maxZ = PlaygroundBuilder.MinZ, PlaygroundBuilder.MaxZ
	local width, depth = maxX - minX, maxZ - minZ
	Geometry.block(
		parent,
		Vector3.new(width, 2, depth),
		CFrame.new((minX + maxX) / 2, -1, (minZ + maxZ) / 2),
		FLOOR,
		{ Name = "Floor" }
	)
	-- Bumpers round the three outer sides (the plaza's own bumper, with its opening, is the fourth).
	local corners = {
		Vector3.new(minX, 0, minZ),
		Vector3.new(maxX, 0, minZ),
		Vector3.new(maxX, 0, maxZ),
		Vector3.new(minX, 0, maxZ),
	}
	for index = 1, 3 do
		local from, to = corners[index], corners[index + 1]
		Geometry.tube(parent, from + Vector3.new(0, 1.3, 0), to + Vector3.new(0, 1.3, 0), 2.6, PINK, {
			Name = "Bumper",
		})
		Geometry.tube(parent, from + Vector3.new(0, 3.8, 0), to + Vector3.new(0, 3.8, 0), 2.4, PURPLE, {
			Name = "Bumper",
		})
	end
	for _, corner in { corners[2], corners[3] } do
		Geometry.column(parent, 6.5, 4, corner, AQUA, { Name = "CornerPost" })
		Geometry.ball(parent, 4.4, corner + Vector3.new(0, 6.5, 0), AQUA, { Name = "CornerCap" })
	end
	-- The way in, under an arch facing the plaza.
	arch(parent, CFrame.lookAt(Vector3.new(minX, 0, 0), Vector3.new(minX - 1, 0, 0)), 30, 13, "PLAYGROUND", PINK)
end

local function buildParkour(parent: Instance): ParkourCourse
	local tower = Geometry.model(parent, "ParkourTower")

	-- The pillar, with a stripe every so often, and the finish on top.
	local pillarHeight = FINISH_TOP - 2
	Geometry.column(tower, pillarHeight, 8, TOWER_CENTER, WHITE, { Name = "Pillar" })
	for index, height in { 12, 26, 40, 54 } do
		Geometry.column(
			tower,
			1.2,
			8.4,
			TOWER_CENTER + Vector3.new(0, height, 0),
			STAGE_COLORS[index],
			{ Name = "Stripe", CastShadow = false }
		)
	end
	local finishCenter = TOWER_CENTER + Vector3.new(0, FINISH_TOP, 0)
	Geometry.column(tower, 2, FINISH_DIAMETER, finishCenter - Vector3.new(0, 2, 0), YELLOW, { Name = "FinishPad" })
	Geometry.column(tower, 0.1, FINISH_DIAMETER - 2, finishCenter, WHITE, DECOR)
	Hazards.Crown(tower, finishCenter + Vector3.new(0, 14, 0), 1.2)
	banner(
		tower,
		CFrame.lookAt(finishCenter + Vector3.new(0, 8, 0), finishCenter + Vector3.new(-1, 8, 0)),
		Vector3.new(14, 3.6, 0.8),
		"FINISH!",
		PINK
	)

	-- Start pad on the ground.
	local startTop = topOf(START_ANGLE, START_RADIUS, 1)
	Hazards.Platform(tower, startTop, Vector3.new(12, 1, 12), PURPLE, "StartPad")
	arch(tower, startTop * CFrame.new(0, 0, -5.4), 12, 11, "PARKOUR", PURPLE)
	local towardsEntrance = Vector3.new(-1, 0, 0.35).Unit
	sign(
		tower,
		`FIRST FINISH: +{Config.Parkour.FirstFinishGumdrops} GUMDROPS`,
		startTop.Position - Vector3.new(0, 1, 0) + towardsEntrance * 9,
		towardsEntrance,
		20,
		PINK
	)

	local checkpoints: { Zone } = {}
	local stage = 1
	for _, step in STEPS do
		local top = topOf(step.Angle, step.Radius, step.Top)
		local color = STAGE_COLORS[stage]
		local size = Vector3.new(step.Width, 2, step.Length)
		local kind = step.Kind
		if kind == "Pad" then
			Hazards.Platform(tower, top, size, color)
		elseif kind == "Checkpoint" then
			Hazards.Platform(tower, top, size, AQUA, "Checkpoint")
			-- A flag on the outer edge (RightVector points in at the pillar), with the number.
			local pole = (top * CFrame.new(-(step.Width / 2 - 1), 0, 0)).Position
			Geometry.column(tower, 7, 0.5, pole, WHITE, DECOR)
			local flagCenter = pole + Vector3.new(0, 5.6, 0)
			banner(
				tower,
				CFrame.lookAt(flagCenter, flagCenter + top.RightVector) * CFrame.Angles(0, math.pi / 2, 0),
				Vector3.new(6, 2.4, 0.3),
				`CHECKPOINT {#checkpoints + 1}`,
				AQUA
			)
			table.insert(checkpoints, zone(top, step.Width, step.Length))
			stage += 1
		elseif kind == "MoverAcross" or kind == "MoverOut" then
			local travel = if kind == "MoverAcross" then top.LookVector * 2.5 else top.RightVector * 3
			Hazards.MovingPlatform(tower, top, size, color, travel, 1.1, 0)
		elseif kind == "Beam" then
			Hazards.Platform(tower, top, Vector3.new(step.Width, 1.5, step.Length), color, "Beam")
		elseif kind == "Bounce" then
			Hazards.Platform(tower, top, size, color)
			Hazards.BouncePad(tower, top.Position, { Diameter = 6, Power = 66 })
		elseif kind == "Conveyor" then
			-- Runs back down the course: keep moving!
			local backwards = CFrame.lookAt(top.Position, top.Position - top.LookVector)
			Hazards.Conveyor(tower, backwards, Vector2.new(step.Width, step.Length), 9, { Rails = true })
		elseif kind == "Spinner" then
			Geometry.column(tower, 2, step.Width, top.Position - Vector3.new(0, 2, 0), color, { Name = "SpinnerPad" })
			Hazards.Spinner(tower, top.Position, { ArmLength = step.Width - 2, Speed = 1.4, Mat = false })
		end
	end

	local finishZone: Zone = {
		CFrame = CFrame.new(finishCenter + Vector3.new(0, ZONE_HEIGHT / 2 - 1, 0)),
		Size = Vector3.new(FINISH_DIAMETER, ZONE_HEIGHT, FINISH_DIAMETER),
		Spot = CFrame.new(finishCenter),
		FloorY = FINISH_TOP,
	}
	return {
		Start = zone(startTop, 12, 12),
		Checkpoints = checkpoints,
		Finish = finishZone,
		AreaCFrame = CFrame.new(TOWER_CENTER + Vector3.new(0, 50, 0)),
		AreaSize = Vector3.new(72, 120, 72),
	}
end

-- The FASTEST TODAY board, facing people as they come in from the plaza.
local function buildParkourBoard(parent: Instance)
	local board = Geometry.model(parent, "ParkourBoard")
	-- Always streamed in, so every client can draw on it.
	board.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	local foot = Vector3.new(112, 0, 6)
	local facing = (Vector3.new(PlaygroundBuilder.MinX, 0, 0) - foot).Unit
	local center = foot + Vector3.new(0, 12.2, 0)
	local orientation = CFrame.lookAt(center, center + facing)
	for _, side in { -1, 1 } do
		local leg = (orientation * CFrame.new(side * 6, 0, 0)).Position
		Geometry.column(board, 3.4, 1.2, Vector3.new(leg.X, 0, leg.Z), WHITE, { Name = "BoardLeg" })
	end
	local color = Leaderboards.ParkourToday.Color
	Geometry.block(board, Vector3.new(15.4, 18.4, 0.8), orientation, color, { Name = "BoardFrame" })
	local screen = Geometry.block(
		board,
		Vector3.new(14, 17, 0.2),
		orientation * CFrame.new(0, 0, -0.5),
		Theme.Colors.Ink,
		{ Name = "BoardScreen", CastShadow = false }
	)
	screen:SetAttribute("Board", Leaderboards.ParkourToday.Id)
	CollectionService:AddTag(screen, Tags.Leaderboard)
	Geometry.ball(board, 2.6, center + Vector3.new(0, 9.6, 0), YELLOW, DECOR)
end

local function buildTrampolines(parent: Instance)
	local park = Geometry.model(parent, "TrampolinePark")
	-- Three trampolines, each stronger than the last, under clouds to land on.
	for index, setup in
		{
			{ X = 90, Power = 62, CloudTop = 9 },
			{ X = 103, Power = 76, CloudTop = 14.5 },
			{ X = 116, Power = 92, CloudTop = 21 },
		}
	do
		local padBottom = Vector3.new(setup.X, 0, 32)
		Hazards.BouncePad(park, padBottom, { Diameter = 8, Power = setup.Power })
		local cloudTop = CFrame.new(setup.X, setup.CloudTop, 46)
		Hazards.Platform(park, cloudTop, Vector3.new(10, 2, 10), CLOUD, "Cloud")
		for _, offset in
			{ Vector3.new(-4, -1, -4), Vector3.new(4, -1, -4), Vector3.new(-4, -1, 4), Vector3.new(4, -1, 4) }
		do
			Geometry.ball(park, 5, cloudTop.Position + offset, CLOUD, DECOR)
		end
		if index == 3 then
			sign(park, "TOP OF THE CLOUDS!", cloudTop.Position + Vector3.new(0, 0, 4), -Vector3.zAxis, 12, AQUA)
		end
	end
	sign(park, "TRAMPOLINE PARK", Vector3.new(103, 0, 22), -Vector3.zAxis, 16, YELLOW)
end

local function buildTreadmills(parent: Instance)
	local lanes = Geometry.model(parent, "Treadmills")
	-- Belts run towards the south wall; dash north up them. Faster lanes need dives.
	for index, setup in
		{
			{ X = 136, Speed = 12, Label = "EASY", Color = Theme.Colors.Lime },
			{ X = 149, Speed = 18, Label = "HARD", Color = ORANGE },
			{ X = 162, Speed = 24, Label = "CRAZY", Color = PINK },
		}
	do
		local top = CFrame.lookAt(Vector3.new(setup.X, 0.15, 42), Vector3.new(setup.X, 0.15, 43))
		Hazards.Conveyor(lanes, top, Vector2.new(9, 44), setup.Speed, { Rails = index < 3 })
		sign(lanes, setup.Label, Vector3.new(setup.X, 0, 68), Vector3.zAxis, 8, setup.Color)
		Geometry.ball(lanes, 3, Vector3.new(setup.X, 4, 17), setup.Color, DECOR)
	end
	sign(lanes, "TREADMILL DASH: RUN TO THE END!", Vector3.new(149, 0, 14), -Vector3.zAxis, 26, PURPLE)
end

local function buildBonkPit(parent: Instance)
	local pit = Geometry.model(parent, "BonkPit")
	Hazards.Spinner(pit, Vector3.new(96, 0, -38), { ArmLength = 24, Speed = -1.8, Color = PURPLE })
	sign(pit, "BONK PIT: STAY ON YOUR FEET!", Vector3.new(96, 0, -20), Vector3.zAxis, 22, ORANGE)
end

function PlaygroundBuilder.Build(parent: Instance): Playground
	local model = Geometry.model(parent, "Playground")
	buildFloor(model)
	local parkour = buildParkour(model)
	buildParkourBoard(model)
	buildTrampolines(model)
	buildTreadmills(model)
	buildBonkPit(model)
	return { Parkour = parkour }
end

return PlaygroundBuilder
