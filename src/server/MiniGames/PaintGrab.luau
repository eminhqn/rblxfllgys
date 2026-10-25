--!strict
-- PAINT GRAB (Team)
-- Players are split into random teams, each with its own colour. Run over floor tiles to paint
-- them your team's colour, and over the other team's tiles to paint them back. Floating paint
-- buckets turn up now and then: grab one to splash a big patch at once. A spinner sweeps the
-- middle. When time's up, the team with the most tiles goes through (a tie sends all tied teams
-- through).
--
-- Painting happens on the server about 10 times a second along the line each Bloblet moved since
-- the last check, so even a fast dive paints every tile it crosses. Jumping over tiles doesn't
-- paint them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local MathUtil = require(Shared.MathUtil)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 75
local GRID = 16 -- tiles per side
local TILE = 6 -- studs
local GROUT = 0.3 -- gap between tiles
local PAINT_HEIGHT = 1.2 -- you paint while your middle is at most this far above standing height
local PAINT_STEP = 2 -- studs between paint checks along a path
local MAX_PAINT_LINE = 30 -- longer moves between checks (e.g. a respawn) don't paint a line
local WALL_HEIGHT = 8
local KILL_DEPTH = 15

local BUCKET_FIRST = 8 -- seconds after GO
local BUCKET_EVERY = 11
local MAX_BUCKETS = 2
local BUCKET_REACH = 4 -- studs from the bucket's middle (flat)
local SPLASH_RADIUS = 2.6 -- in tiles
local CENTER_KEEP_OUT = 3 -- buckets don't appear this many tiles from the middle (the spinner hub)

local NEUTRAL = Color3.fromRGB(246, 242, 252)
local GROUT_COLOR = Color3.fromRGB(86, 70, 140)
local WALL_COLOR = Color3.fromRGB(196, 170, 255)

type Tile = {
	Part: Part,
	Owner: string?, -- team id
}

type Bucket = {
	Model: Model,
	Position: Vector3,
	Column: number,
	Row: number,
}

local PaintGrab = {}

PaintGrab.Info = {
	Id = "PaintGrab",
	DisplayName = "Paint Grab",
	Type = "Team",
	Rules = "Run over tiles to paint them your team's colour. Grab paint buckets for a big splash. Most tiles wins!",
	Duration = DURATION,
	MinPlayers = 4,
	TeamCount = 2,
} :: Types.MiniGameInfo

function PaintGrab.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local half = GRID * TILE / 2
	local corner = center - Vector3.new(half, 0, half)
	local totalTiles = GRID * GRID

	local tiles: { Tile } = {}
	local counts: { [string]: number } = {}
	local teamOf: { [Player]: Teams.TeamDef } = {}
	local teamOrder: { Teams.TeamDef } = {}
	local spawnOf: { [Player]: CFrame } = {}
	local lastPoint: { [Player]: Vector3 } = {}
	local buckets: { Bucket } = {}
	local bucketTimer = 0
	local scoresDirty = true
	local running = false

	local function tileAt(column: number, row: number): Tile?
		if column < 0 or column >= GRID or row < 0 or row >= GRID then
			return nil
		end
		return tiles[column * GRID + row + 1]
	end

	local function gridPosition(position: Vector3): (number, number)
		return math.floor((position.X - corner.X) / TILE), math.floor((position.Z - corner.Z) / TILE)
	end

	local function tileCenter(column: number, row: number): Vector3
		return corner + Vector3.new((column + 0.5) * TILE, 0, (row + 0.5) * TILE)
	end

	local function paint(column: number, row: number, team: Teams.TeamDef)
		local tile = tileAt(column, row)
		if not tile or tile.Owner == team.Id then
			return
		end
		local previous = tile.Owner
		if previous then
			counts[previous] = (counts[previous] or 0) - 1
		end
		tile.Owner = team.Id
		counts[team.Id] = (counts[team.Id] or 0) + 1
		tile.Part.Color = team.Color
		scoresDirty = true
	end

	local function paintLine(from: Vector3, to: Vector3, team: Teams.TeamDef)
		local distance = MathUtil.flat(to - from).Magnitude
		local steps = math.max(1, math.ceil(distance / PAINT_STEP))
		for step = 0, steps do
			local column, row = gridPosition(from:Lerp(to, step / steps))
			paint(column, row, team)
		end
	end

	local function buildFloor(arena: Model)
		local floor = Geometry.model(arena, "PaintFloor")
		Geometry.block(
			floor,
			Vector3.new(GRID * TILE + 2, 2, GRID * TILE + 2),
			CFrame.new(center - Vector3.new(0, 1.15, 0)),
			GROUT_COLOR,
			{ Name = "Grout" }
		)
		for column = 0, GRID - 1 do
			for row = 0, GRID - 1 do
				local part = Geometry.block(
					floor,
					Vector3.new(TILE - GROUT, 1, TILE - GROUT),
					CFrame.new(tileCenter(column, row) - Vector3.new(0, 0.5, 0)),
					NEUTRAL,
					{ Name = "PaintTile" }
				)
				tiles[column * GRID + row + 1] = { Part = part, Owner = nil }
			end
		end
	end

	local function buildWalls(arena: Model)
		local walls = Geometry.model(arena, "Walls")
		local length = GRID * TILE + 2
		local sides = {
			{ Offset = Vector3.new(0, 0, -half - 1), Size = Vector3.new(length, WALL_HEIGHT, 1) },
			{ Offset = Vector3.new(0, 0, half + 1), Size = Vector3.new(length, WALL_HEIGHT, 1) },
			{ Offset = Vector3.new(-half - 1, 0, 0), Size = Vector3.new(1, WALL_HEIGHT, length) },
			{ Offset = Vector3.new(half + 1, 0, 0), Size = Vector3.new(1, WALL_HEIGHT, length) },
		}
		for _, side in sides do
			local wallCenter = center + side.Offset + Vector3.new(0, WALL_HEIGHT / 2, 0)
			Geometry.block(walls, side.Size, CFrame.new(wallCenter), WALL_COLOR, {
				Name = "Glass",
				Transparency = 0.55,
				CastShadow = false,
			})
		end
		local rim = half + 1
		local corners = {
			Vector3.new(-rim, 0, -rim),
			Vector3.new(rim, 0, -rim),
			Vector3.new(rim, 0, rim),
			Vector3.new(-rim, 0, rim),
		}
		for index, cornerOffset in corners do
			local nextCorner = corners[index % #corners + 1]
			local top = Vector3.new(0, WALL_HEIGHT, 0)
			Geometry.tube(walls, center + cornerOffset + top, center + nextCorner + top, 1.6, Theme.Colors.Pink, {
				Name = "Bumper",
				CastShadow = false,
			})
			Geometry.column(walls, WALL_HEIGHT + 1, 3, center + cornerOffset, Theme.Colors.Yellow, { Name = "Post" })
		end
	end

	-- Each team starts lined up along its own wall, facing the middle.
	local function placeTeams()
		local teams = context.Teams or {}
		for _, def in Teams.List do
			if teams[def.Id] then
				table.insert(teamOrder, def)
				counts[def.Id] = 0
			end
		end
		for index, def in teamOrder do
			local angle = (index - 1) / #teamOrder * math.pi * 2
			local outward = Vector3.new(math.sin(angle), 0, -math.cos(angle))
			local along = Vector3.new(-outward.Z, 0, outward.X)
			local members = teams[def.Id]
			for slot, player in members do
				teamOf[player] = def
				local row = (slot - 1) // 12
				local inRow = math.min(12, #members - row * 12)
				local x = ((slot - 1) % 12 - (inRow - 1) / 2) * 5
				local position = center + outward * (half - 5 - row * 5) + along * x
				spawnOf[player] = CFrame.lookAt(position, Vector3.new(center.X, position.Y, center.Z))
			end
		end
	end

	local function spawnBucket()
		local colors: { Color3 } = {}
		for _, def in teamOrder do
			table.insert(colors, def.Color)
		end
		if #colors == 0 then
			colors = { Theme.Colors.Pink, Theme.Colors.Aqua }
		end
		for _ = 1, 20 do
			local column = random:NextInteger(1, GRID - 2)
			local row = random:NextInteger(1, GRID - 2)
			local middle = (GRID - 1) / 2
			local nearMiddle = math.abs(column - middle) < CENTER_KEEP_OUT and math.abs(row - middle) < CENTER_KEEP_OUT
			local crowded = false
			for _, bucket in buckets do
				if math.abs(bucket.Column - column) < 4 and math.abs(bucket.Row - row) < 4 then
					crowded = true
				end
			end
			if not nearMiddle and not crowded then
				local position = tileCenter(column, row)
				local model = Hazards.PaintBucket(context.Arena, position, colors)
				table.insert(buckets, { Model = model, Position = position, Column = column, Row = row })
				return
			end
		end
	end

	local function splash(index: number, team: Teams.TeamDef)
		local bucket = table.remove(buckets, index)
		if not bucket then
			return
		end
		local reach = math.ceil(SPLASH_RADIUS)
		for column = bucket.Column - reach, bucket.Column + reach do
			for row = bucket.Row - reach, bucket.Row + reach do
				local dx, dz = column - bucket.Column, row - bucket.Row
				if dx * dx + dz * dz <= SPLASH_RADIUS * SPLASH_RADIUS then
					paint(column, row, team)
				end
			end
		end
		-- Clients burst it in the team's colour, then it's removed.
		bucket.Model:SetAttribute("SplashColor", team.Color)
		task.delay(0.3, function()
			if bucket.Model.Parent then
				bucket.Model:Destroy()
			end
		end)
	end

	local function updatePlayer(player: Player)
		local root = context.GetRoot(player)
		local team = teamOf[player]
		if not root then
			lastPoint[player] = nil
			return
		end
		local position = root.Position
		if position.Y < center.Y - KILL_DEPTH then
			-- Somehow got out of the arena: back to their team's wall.
			lastPoint[player] = nil
			local home = spawnOf[player]
			if home then
				context.SpawnAt(player, home)
			end
			return
		end
		if not team then
			return
		end

		local nearFloor = position.Y - center.Y <= BlobletRig.Dimensions.RootHeight + PAINT_HEIGHT
		if nearFloor then
			local last = lastPoint[player]
			if last and MathUtil.flat(position - last).Magnitude <= MAX_PAINT_LINE then
				paintLine(last, position, team)
			else
				local column, row = gridPosition(position)
				paint(column, row, team)
			end
			lastPoint[player] = position
		else
			lastPoint[player] = nil -- in the air: nothing under you gets painted
		end

		for index = #buckets, 1, -1 do
			local bucket = buckets[index]
			local offset = position - bucket.Position
			if MathUtil.flat(offset).Magnitude <= BUCKET_REACH and offset.Y < 8 then
				splash(index, team)
			end
		end
	end

	local function publishScores()
		context.SetTeamScores(counts, totalTiles)
		scoresDirty = false
	end

	local function setup()
		local arena = context.Arena
		buildFloor(arena)
		buildWalls(arena)
		Hazards.Spinner(arena, center, { ArmLength = 34, Speed = 1.1, Mat = false })
		placeTeams()

		local spots: { CFrame } = {}
		for index, player in context.Players do
			spots[index] = spawnOf[player] or CFrame.new(center + Vector3.new(0, 0, half - 8))
		end
		context.SpawnAll(spots)
		context.SetCounterText("MOST TILES WINS")
		publishScores()
	end

	local function start()
		running = true
		bucketTimer = BUCKET_EVERY - BUCKET_FIRST
	end

	local function update(dt: number): boolean?
		if not running then
			return nil
		end
		for _, player in context.GetAlive() do
			updatePlayer(player)
		end
		bucketTimer += dt
		if bucketTimer >= BUCKET_EVERY then
			bucketTimer -= BUCKET_EVERY
			if #buckets < MAX_BUCKETS then
				spawnBucket()
			end
		end
		if scoresDirty then
			publishScores()
		end
		return nil
	end

	local function bestScore(): number
		local best = 0
		for _, count in counts do
			best = math.max(best, count)
		end
		return best
	end

	-- Shown as the counter during ROUND OVER, e.g. "CORAL WINS!" or "IT'S A TIE!".
	local function resultText(): string
		local best = bestScore()
		local winners: { string } = {}
		for _, def in teamOrder do
			if best > 0 and counts[def.Id] == best then
				table.insert(winners, string.upper(def.Id))
			end
		end
		if #winners == 1 then
			return `{winners[1]} WINS!`
		end
		return "IT'S A TIE!"
	end

	-- The team(s) with the most tiles go through. If nobody painted anything, everyone does.
	local function getQualified(): { Player }
		local best = bestScore()
		local qualified: { Player } = {}
		for _, player in context.GetAlive() do
			local team = teamOf[player]
			if best == 0 or (team and counts[team.Id] == best) then
				table.insert(qualified, player)
			end
		end
		return qualified
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = function()
			running = false
			if scoresDirty then
				publishScores()
			end
			context.SetCounterText(resultText())
		end,
		GetQualified = getQualified,
	}
end

return PaintGrab
