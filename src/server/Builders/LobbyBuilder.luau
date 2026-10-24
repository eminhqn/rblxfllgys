--!strict
-- Builds the waiting lobby:
--   * a bright plaza enclosed by inflatable bumpers
--   * one raised deck per team (north side) with tinted glass walls, a team sign, spawn pads and
--     real stairs down to the plaza
--   * a big screen (south side) that shows live lobby info
--   * a practice zone with a spinner, a bounce pad and a jump-and-dive course
--
-- Layout: +Z points from the decks towards the screen. The floor surface is at Y = 0.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Tags = require(Shared.Tags)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)
local Geometry = require(script.Parent.Geometry)

export type ScreenRefs = {
	PlayerCount: TextLabel,
	TeamCounts: { [string]: TextLabel },
}

export type Lobby = {
	Model: Model,
	Spawns: { [string]: { CFrame } },
	Screen: ScreenRefs,
}

local LobbyBuilder = {}

local WHITE = Color3.fromRGB(255, 255, 255)
local CREAM = Color3.fromRGB(255, 249, 252)
local FLOOR = Color3.fromRGB(150, 234, 226)
local PINK = Theme.Colors.Pink
local PINK_SOFT = Color3.fromRGB(255, 160, 206)
local PURPLE = Color3.fromRGB(170, 124, 255)
local PURPLE_SOFT = Color3.fromRGB(196, 170, 255)
local YELLOW = Theme.Colors.Yellow
local AQUA = Theme.Colors.Aqua

local PLAZA_MIN_X, PLAZA_MAX_X = -74, 74
local PLAZA_MIN_Z, PLAZA_MAX_Z = -60, 72

local DECK_TOP = 7.2
local DECK_BACK_Z, DECK_FRONT_Z = -58, -34
local DECK_WIDTH = 30
local DECK_SPACING = 36
local WALL_HEIGHT = 9

local STAIR_WIDTH = 10
local STEP_RISE, STEP_RUN = 0.6, 1.6

local SCREEN_Z = 66

local GLASS: Geometry.PartOptions = { Name = "Glass", Transparency = 0.55, CastShadow = false }
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

-- A ">"-shaped floor marking pointing towards +Z.
local function chevron(parent: Instance, apex: Vector3, armLength: number, color: Color3)
	for _, sideX in { -1, 1 } do
		local direction = Vector3.new(sideX, 0, -1).Unit
		local center = apex + direction * armLength / 2
		Geometry.block(
			parent,
			Vector3.new(1.4, 0.1, armLength + 0.7),
			CFrame.lookAt(center, center + direction),
			color,
			DECOR
		)
	end
end

local function buildPlaza(parent: Instance)
	local plaza = Geometry.model(parent, "Plaza")
	local width = PLAZA_MAX_X - PLAZA_MIN_X
	local depth = PLAZA_MAX_Z - PLAZA_MIN_Z
	local centerX = (PLAZA_MIN_X + PLAZA_MAX_X) / 2
	local centerZ = (PLAZA_MIN_Z + PLAZA_MAX_Z) / 2

	Geometry.block(plaza, Vector3.new(width, 2, depth), CFrame.new(centerX, -1, centerZ), FLOOR, { Name = "Floor" })

	-- Pink and white checkerboard band across the plaza.
	local tile = 4
	for ix = 0, math.floor(width / tile) - 1 do
		for iz = 0, 1 do
			local color = if (ix + iz) % 2 == 0 then PINK_SOFT else WHITE
			local position = Vector3.new(PLAZA_MIN_X + tile / 2 + ix * tile, 0.05, -4 + tile / 2 + iz * tile)
			Geometry.block(plaza, Vector3.new(tile, 0.1, tile), CFrame.new(position), color, DECOR)
		end
	end

	-- Inflatable bumpers around the edge: a purple tube with a pink one on top.
	local corners = {
		Vector3.new(PLAZA_MIN_X, 0, PLAZA_MIN_Z),
		Vector3.new(PLAZA_MAX_X, 0, PLAZA_MIN_Z),
		Vector3.new(PLAZA_MAX_X, 0, PLAZA_MAX_Z),
		Vector3.new(PLAZA_MIN_X, 0, PLAZA_MAX_Z),
	}
	for index, corner in corners do
		local nextCorner = corners[index % #corners + 1]
		Geometry.tube(plaza, corner + Vector3.new(0, 1.3, 0), nextCorner + Vector3.new(0, 1.3, 0), 2.6, PURPLE, {
			Name = "Bumper",
		})
		Geometry.tube(plaza, corner + Vector3.new(0, 3.8, 0), nextCorner + Vector3.new(0, 3.8, 0), 2.4, PINK, {
			Name = "Bumper",
		})
		Geometry.column(plaza, 6.5, 4, corner, YELLOW, { Name = "CornerPost" })
		Geometry.ball(plaza, 4.4, corner + Vector3.new(0, 6.5, 0), YELLOW, { Name = "CornerCap" })
	end
end

local function teamSign(parent: Instance, team: Teams.TeamDef, center: Vector3)
	local board = Geometry.block(parent, Vector3.new(20, 4.4, 0.8), CFrame.new(center), WHITE, { Name = "TeamSign" })
	local gui: SurfaceGui = Ui.new("SurfaceGui", {
		Face = Enum.NormalId.Back, -- the +Z face, looking out over the plaza
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 40,
		LightInfluence = 0.2,
		Parent = board,
	})
	local panel = Ui.panel(gui, UDim2.new(1, -20, 1, -20), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5), team.Color)
	local label = Ui.label(
		panel.Body,
		string.upper(team.DisplayName),
		Theme.Fonts.Display,
		WHITE,
		UDim2.fromScale(0.9, 0.72),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	local outline = Instance.new("UIStroke")
	outline.Color = Theme.Colors.Ink
	outline.Thickness = 4
	outline.Transparency = 0.5
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	outline.Parent = label
end

local function buildDeck(parent: Instance, team: Teams.TeamDef, x: number): { CFrame }
	local deck = Geometry.model(parent, team.Id .. "Deck")
	local tint = team.Color:Lerp(WHITE, 0.55)
	local depth = DECK_FRONT_Z - DECK_BACK_Z
	local zCenter = (DECK_BACK_Z + DECK_FRONT_Z) / 2

	-- Solid podium so nobody gets stuck underneath.
	local podiumHeight = DECK_TOP - 0.4
	Geometry.block(
		deck,
		Vector3.new(DECK_WIDTH, podiumHeight, depth),
		CFrame.new(x, podiumHeight / 2, zCenter),
		tint,
		{ Name = "Podium" }
	)
	Geometry.block(
		deck,
		Vector3.new(DECK_WIDTH + 0.6, 0.4, depth + 0.6),
		CFrame.new(x, DECK_TOP - 0.2, zCenter),
		CREAM,
		{ Name = "DeckFloor" }
	)
	for _, stripeY in { 2.0, 4.4 } do
		Geometry.block(
			deck,
			Vector3.new(DECK_WIDTH + 0.1, 0.8, 0.2),
			CFrame.new(x, stripeY, DECK_FRONT_Z + 0.05),
			team.Color,
			DECOR
		)
	end

	-- Tinted glass walls with padded rails on top.
	local wallY = DECK_TOP + WALL_HEIGHT / 2
	local railY = DECK_TOP + WALL_HEIGHT
	Geometry.block(
		deck,
		Vector3.new(DECK_WIDTH, WALL_HEIGHT, 0.6),
		CFrame.new(x, wallY, DECK_BACK_Z + 0.3),
		team.Color,
		GLASS
	)
	Geometry.tube(
		deck,
		Vector3.new(x - DECK_WIDTH / 2, railY, DECK_BACK_Z + 0.3),
		Vector3.new(x + DECK_WIDTH / 2, railY, DECK_BACK_Z + 0.3),
		0.9,
		team.Color,
		{ Name = "Rail", CastShadow = false }
	)
	for _, side in { -1, 1 } do
		local wallX = x + side * (DECK_WIDTH / 2 - 0.3)
		Geometry.block(deck, Vector3.new(0.6, WALL_HEIGHT, depth), CFrame.new(wallX, wallY, zCenter), team.Color, GLASS)
		Geometry.tube(
			deck,
			Vector3.new(wallX, railY, DECK_BACK_Z),
			Vector3.new(wallX, railY, DECK_FRONT_Z),
			0.9,
			team.Color,
			{ Name = "Rail", CastShadow = false }
		)

		-- Low glass railing either side of the stairs.
		local railWidth = (DECK_WIDTH - STAIR_WIDTH) / 2
		local railCenterX = x + side * (STAIR_WIDTH / 2 + railWidth / 2)
		Geometry.block(
			deck,
			Vector3.new(railWidth, 2.6, 0.5),
			CFrame.new(railCenterX, DECK_TOP + 1.3, DECK_FRONT_Z - 0.25),
			team.Color,
			GLASS
		)
		Geometry.tube(
			deck,
			Vector3.new(railCenterX - railWidth / 2, DECK_TOP + 2.7, DECK_FRONT_Z - 0.25),
			Vector3.new(railCenterX + railWidth / 2, DECK_TOP + 2.7, DECK_FRONT_Z - 0.25),
			0.8,
			team.Color,
			{ Name = "Rail", CastShadow = false }
		)

		Geometry.column(deck, 2.2, 0.6, Vector3.new(x + side * 7, railY, DECK_BACK_Z + 0.3), WHITE, DECOR)
	end
	teamSign(deck, team, Vector3.new(x, railY + 2.2 + 2.2, DECK_BACK_Z + 0.3))

	-- Spawn pads (decorative; CharacterService places Bloblets on them).
	local spawns: { CFrame } = {}
	local padColor = tint:Lerp(team.Color, 0.5)
	for _, offset in { Vector2.new(-7, -51), Vector2.new(7, -51), Vector2.new(-7, -42), Vector2.new(7, -42) } do
		local position = Vector3.new(x + offset.X, DECK_TOP, offset.Y)
		Geometry.column(deck, 0.2, 5, position, padColor, { Name = "SpawnPad", CanCollide = false, CastShadow = false })
		table.insert(spawns, CFrame.lookAt(position, position + Vector3.zAxis))
	end

	-- Stairs: the steps are visual; an invisible ramp underneath is what you actually walk on, which
	-- keeps the round Bloblet from snagging on step edges.
	local stairs = Geometry.model(deck, "Stairs")
	local stepCount = math.round(DECK_TOP / STEP_RISE) - 1
	for index = 0, stepCount - 1 do
		local top = DECK_TOP - STEP_RISE * (index + 1)
		local zStart = DECK_FRONT_Z + STEP_RUN * index
		local color = if index % 2 == 0 then CREAM else tint
		Geometry.block(
			stairs,
			Vector3.new(STAIR_WIDTH, top, STEP_RUN),
			CFrame.new(x, top / 2, zStart + STEP_RUN / 2),
			color,
			{ Name = "Step", CanCollide = false }
		)
	end
	-- The ramp surface passes through the middle of every tread.
	local rampTop = Vector3.new(x, DECK_TOP, DECK_FRONT_Z - STEP_RUN / 2)
	local rampBottom = Vector3.new(x, 0, DECK_FRONT_Z + STEP_RUN * (stepCount + 0.5))
	local rampDirection = (rampBottom - rampTop).Unit
	local rampMiddle = (rampTop + rampBottom) / 2
	Geometry.block(
		stairs,
		Vector3.new(STAIR_WIDTH, 1, (rampBottom - rampTop).Magnitude + 2),
		CFrame.lookAt(rampMiddle, rampMiddle + rampDirection) * CFrame.new(0, -0.5, 0),
		WHITE,
		{ Name = "StairRamp", Transparency = 1, CastShadow = false }
	)
	for _, side in { -1, 1 } do
		local railX = x + side * (STAIR_WIDTH / 2 + 0.4)
		Geometry.tube(
			stairs,
			Vector3.new(railX, DECK_TOP + 1.6, DECK_FRONT_Z),
			Vector3.new(railX, 1.6, rampBottom.Z),
			0.8,
			team.Color,
			{ Name = "StairRail", CastShadow = false }
		)
		Geometry.column(stairs, 1.6, 0.9, Vector3.new(railX, 0, rampBottom.Z), team.Color, { Name = "StairPost" })
	end

	chevron(deck, Vector3.new(x, 0.06, -9), 3, PINK)
	return spawns
end

local function buildScreen(parent: Instance): ScreenRefs
	local screen = Geometry.model(parent, "LobbyScreen")
	for _, side in { -1, 1 } do
		Geometry.column(screen, 15, 2.6, Vector3.new(side * 19, 0, SCREEN_Z), WHITE, { Name = "ScreenLeg" })
	end
	Geometry.block(screen, Vector3.new(40, 22, 2), CFrame.new(0, 26, SCREEN_Z), PURPLE, { Name = "ScreenFrame" })

	local frontZ = SCREEN_Z - 1.2
	local frameCorners = {
		Vector3.new(-20, 15, frontZ),
		Vector3.new(20, 15, frontZ),
		Vector3.new(20, 37, frontZ),
		Vector3.new(-20, 37, frontZ),
	}
	for index, corner in frameCorners do
		Geometry.tube(screen, corner, frameCorners[index % #frameCorners + 1], 1.6, PINK, {
			Name = "ScreenTrim",
			CastShadow = false,
		})
	end

	local panel = Geometry.block(
		screen,
		Vector3.new(37, 19, 0.3),
		CFrame.new(0, 26, SCREEN_Z - 1.1),
		Theme.Colors.Ink,
		{ Name = "ScreenPanel" }
	)
	local gui: SurfaceGui = Ui.new("SurfaceGui", {
		Face = Enum.NormalId.Front, -- faces -Z, towards the decks
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 30,
		LightInfluence = 0,
		Brightness = 1.3,
		Parent = panel,
	})
	local background: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Parent = gui,
	})
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Theme.Colors.Ink, Theme.Colors.Purple),
		Rotation = 90,
		Parent = background,
	})

	local title = Ui.label(
		background,
		"WOBBLE RUSH",
		Theme.Fonts.Display,
		Theme.Colors.Yellow,
		UDim2.fromScale(0.8, 0.22),
		UDim2.fromScale(0.5, 0.05),
		Vector2.new(0.5, 0)
	)
	Ui.new("UIStroke", {
		Color = Theme.Colors.Pink,
		Thickness = 6,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = title,
	})

	Ui.label(
		background,
		"PLAYERS IN LOBBY",
		Theme.Fonts.Body,
		Color3.fromRGB(220, 210, 255),
		UDim2.fromScale(0.6, 0.08),
		UDim2.fromScale(0.5, 0.32),
		Vector2.new(0.5, 0)
	)
	local playerCount = Ui.label(
		background,
		`0 / {Config.MaxPlayers}`,
		Theme.Fonts.Display,
		WHITE,
		UDim2.fromScale(0.5, 0.24),
		UDim2.fromScale(0.5, 0.4),
		Vector2.new(0.5, 0)
	)
	Ui.label(
		background,
		"Warm up in the practice zone!",
		Theme.Fonts.Body,
		Theme.Colors.Aqua,
		UDim2.fromScale(0.8, 0.08),
		UDim2.fromScale(0.5, 0.66),
		Vector2.new(0.5, 0)
	)

	local teamCounts: { [string]: TextLabel } = {}
	local pillWidth = 0.21
	local gap = (1 - pillWidth * #Teams.List) / (#Teams.List + 1)
	for index, team in Teams.List do
		local pill: Frame = Ui.new("Frame", {
			Name = team.Id,
			Size = UDim2.fromScale(pillWidth, 0.12),
			Position = UDim2.fromScale(gap + (index - 1) * (pillWidth + gap), 0.82),
			BackgroundColor3 = team.Color,
			BorderSizePixel = 0,
			Parent = background,
		})
		Ui.corner(pill, UDim.new(0.5, 0))
		teamCounts[team.Id] = Ui.label(
			pill,
			`{string.upper(team.Id)}  0`,
			Theme.Fonts.Display,
			WHITE,
			UDim2.fromScale(0.86, 0.7),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
	end

	return { PlayerCount = playerCount, TeamCounts = teamCounts }
end

local function buildSpinner(parent: Instance, center: Vector3)
	local spinner = Geometry.model(parent, "BonkSpinner")
	spinner.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	Geometry.column(spinner, 0.1, 40, center, PINK_SOFT, { Name = "Mat", CanCollide = false, CastShadow = false })
	Geometry.column(spinner, 0.12, 37, center, CREAM, { Name = "Mat", CanCollide = false, CastShadow = false })
	Geometry.column(spinner, 4.6, 3.2, center, WHITE, { Name = "Hub" })
	Geometry.ball(spinner, 3.4, center + Vector3.new(0, 4.6, 0), PINK, { Name = "HubCap" })

	-- The client rotates "Arm" (and anything named "ArmDecor") around the hub's vertical axis.
	local armLength = 36
	local armCFrame = CFrame.new(center + Vector3.new(0, 2.2, 0))
	Geometry.block(spinner, Vector3.new(armLength, 1.6, 1.6), armCFrame, PINK, { Name = "Arm" })
	for _, offset in { -14, -9, -4, 4, 9, 14 } do
		Geometry.block(
			spinner,
			Vector3.new(1, 1.75, 1.75),
			armCFrame * CFrame.new(offset, 0, 0),
			WHITE,
			{ Name = "ArmDecor", CanCollide = false, CastShadow = false }
		)
	end
	for _, side in { -1, 1 } do
		local tip = armCFrame * CFrame.new(side * (armLength / 2 + 0.6), 0, 0)
		Geometry.ball(spinner, 2.4, tip.Position, YELLOW, { Name = "ArmDecor", CanCollide = false })
	end

	spinner:SetAttribute("Speed", 1.3)
	spinner:SetAttribute("Phase", 0)
	CollectionService:AddTag(spinner, Tags.Spinner)

	Geometry.sign(parent, "DODGE THE BONK BAR!", center + Vector3.new(0, 0, -23), 16, 3.2, PINK, 4)
end

local function buildBouncePad(parent: Instance, center: Vector3)
	local pad = Geometry.model(parent, "BouncePad")
	Geometry.column(pad, 1.0, 9.6, center, YELLOW, { Name = "PadRing" })
	local cushion = Geometry.column(pad, 1.25, 8, center, PINK, { Name = "Cushion" })
	cushion:SetAttribute("Power", 85)
	CollectionService:AddTag(cushion, Tags.BouncePad)

	-- A floating platform you can only reach by bouncing.
	local platformCenter = center + Vector3.new(0, 14.4, 22)
	Geometry.block(pad, Vector3.new(12, 1.2, 12), CFrame.new(platformCenter), CREAM, { Name = "BounceTarget" })
	local top = platformCenter.Y + 0.6
	local half = 6
	local edges = {
		Vector3.new(-half, top, -half),
		Vector3.new(half, top, -half),
		Vector3.new(half, top, half),
		Vector3.new(-half, top, half),
	}
	for index, corner in edges do
		local nextCorner = edges[index % #edges + 1]
		Geometry.tube(
			pad,
			Vector3.new(platformCenter.X, 0, platformCenter.Z) + corner,
			Vector3.new(platformCenter.X, 0, platformCenter.Z) + nextCorner,
			1,
			PINK,
			{ Name = "Padding", CastShadow = false }
		)
	end

	Geometry.sign(parent, "BOUNCE UP THERE!", center + Vector3.new(0, 0, -10), 15, 3.2, YELLOW, 4)
end

local function buildJumpCourse(parent: Instance, x: number)
	local course = Geometry.model(parent, "JumpCourse")
	local colors = { YELLOW, AQUA, PURPLE_SOFT }
	local stepSize = 7
	local lastFrontZ = 0
	for index, height in { 2, 4, 6 } do
		local z = 14 + (index - 1) * stepSize
		Geometry.block(course, Vector3.new(stepSize, height, stepSize), CFrame.new(x, height / 2, z), colors[index], {
			Name = "FoamStep",
		})
		lastFrontZ = z + stepSize / 2
	end

	-- Too far to jump, close enough to jump and then dive.
	local gap = 20
	local landingSize = 10
	Geometry.block(
		course,
		Vector3.new(landingSize, 6, landingSize),
		CFrame.new(x, 3, lastFrontZ + gap + landingSize / 2),
		PINK_SOFT,
		{ Name = "FoamLanding" }
	)

	Geometry.sign(parent, "JUMP + DIVE THE GAP!", Vector3.new(x, 0, 5), 15, 3.2, AQUA, 4)
end

function LobbyBuilder.Build(parent: Instance): Lobby
	local model = Geometry.model(parent, "Lobby")

	buildPlaza(model)

	local spawns: { [string]: { CFrame } } = {}
	local firstDeckX = -DECK_SPACING * (#Teams.List - 1) / 2
	for index, team in Teams.List do
		spawns[team.Id] = buildDeck(model, team, firstDeckX + (index - 1) * DECK_SPACING)
	end

	local screen = buildScreen(model)

	local practice = Geometry.model(model, "PracticeZone")
	buildSpinner(practice, Vector3.new(0, 0, 26))
	buildBouncePad(practice, Vector3.new(-44, 0, 22))
	buildJumpCourse(practice, 40)

	return { Model = model, Spawns = spawns, Screen = screen }
end

return LobbyBuilder
