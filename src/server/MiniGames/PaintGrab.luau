--!strict
-- PAINT GRAB (Team)
-- Players are split into random teams, each with its own colour. Run over floor tiles to paint
-- them your team's colour, and over the other team's tiles to paint them back. Floating power-ups
-- turn up now and then:
--   SPLASH (paint bucket): splashes a big round patch at once
--   GIANT (mushroom): you grow big for a few seconds and paint a 3x3 patch wherever you go
--   STRIPE (paint roller): paints the whole line of tiles you're on, wall to wall, the way you face
-- A spinner sweeps the middle. When time's up, the team with the most tiles goes through (a tie
-- sends all tied teams through).
--
-- Painting happens on the server about 10 times a second along the line each Bloblet moved since
-- the last check, so even a fast dive paints every tile it crosses. Jumping over tiles doesn't
-- paint them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local MathUtil = require(Shared.MathUtil)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)

local Bots = require(script.Parent.Parent.Bots.Bots)
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

local PICKUP_FIRST = 6 -- seconds after GO
local PICKUP_EVERY = 7
local MAX_PICKUPS = 3
local PICKUP_REACH = 4 -- studs from the pickup's middle (flat)
local CENTER_KEEP_OUT = 3 -- pickups don't appear this many tiles from the middle (the spinner hub)
-- How often each power-up turns up (out of the total).
local PICKUP_WEIGHTS: { { Kind: Hazards.PaintPickupKind, Weight: number } } = {
	{ Kind = "Splash", Weight = 4 },
	{ Kind = "Giant", Weight = 3 },
	{ Kind = "Stripe", Weight = 3 },
}
local SPLASH_RADIUS = 2.6 -- in tiles
local GIANT_BRUSH = 1 -- a giant paints this many tiles out from the one under it (1 = 3x3)
local STRIPE_SWEEP = 0.03 -- seconds per tile as a stripe races out to the walls

local NEUTRAL = Color3.fromRGB(246, 242, 252)
local GROUT_COLOR = Color3.fromRGB(86, 70, 140)
local WALL_COLOR = Color3.fromRGB(196, 170, 255)

type Tile = {
	Part: Part,
	Owner: string?, -- team id
}

type Pickup = {
	Model: Model,
	Kind: Hazards.PaintPickupKind,
	Position: Vector3,
	Column: number,
	Row: number,
}

-- Where a bot is heading: a tile to paint, or a power-up.
type BotTarget = {
	Point: Vector3,
	Column: number,
	Row: number,
	Pickup: Pickup?,
	GiveUpAt: number,
}

local PaintGrab = {}

PaintGrab.Info = {
	Id = "PaintGrab",
	DisplayName = "Paint Grab",
	Type = "Team",
	Rules = "Run over tiles to paint them your team's colour. Grab power-ups to paint even more. Most tiles wins!",
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
	local pickups: { Pickup } = {}
	local pickupTimer = 0
	local giantUntil: { [Player]: number } = {}
	local botTargets: { [Player]: BotTarget } = {}
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

	-- Paints the tile under `position`, plus `brush` tiles out in every direction.
	local function paintAt(position: Vector3, team: Teams.TeamDef, brush: number)
		local column, row = gridPosition(position)
		for dc = -brush, brush do
			for dr = -brush, brush do
				paint(column + dc, row + dr, team)
			end
		end
	end

	local function paintLine(from: Vector3, to: Vector3, team: Teams.TeamDef, brush: number)
		local distance = MathUtil.flat(to - from).Magnitude
		local steps = math.max(1, math.ceil(distance / PAINT_STEP))
		for step = 0, steps do
			paintAt(from:Lerp(to, step / steps), team, brush)
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

	local function pickKind(): Hazards.PaintPickupKind
		local total = 0
		for _, entry in PICKUP_WEIGHTS do
			total += entry.Weight
		end
		local roll = random:NextNumber(0, total)
		for _, entry in PICKUP_WEIGHTS do
			roll -= entry.Weight
			if roll <= 0 then
				return entry.Kind
			end
		end
		return "Splash"
	end

	local function spawnPickup()
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
			for _, pickup in pickups do
				if math.abs(pickup.Column - column) < 4 and math.abs(pickup.Row - row) < 4 then
					crowded = true
				end
			end
			if not nearMiddle and not crowded then
				local kind: Hazards.PaintPickupKind = pickKind()
				local position = tileCenter(column, row)
				local model = Hazards.PaintPickup(context.Arena, position, kind, colors)
				table.insert(pickups, { Model = model, Kind = kind, Position = position, Column = column, Row = row })
				return
			end
		end
	end

	local function splash(pickup: Pickup, team: Teams.TeamDef)
		local reach = math.ceil(SPLASH_RADIUS)
		for column = pickup.Column - reach, pickup.Column + reach do
			for row = pickup.Row - reach, pickup.Row + reach do
				local dx, dz = column - pickup.Column, row - pickup.Row
				if dx * dx + dz * dz <= SPLASH_RADIUS * SPLASH_RADIUS then
					paint(column, row, team)
				end
			end
		end
	end

	-- The whole row or column you're on, racing out from you to both walls. It runs along
	-- whichever way you're facing more.
	local function stripe(root: BasePart, team: Teams.TeamDef)
		local column, row = gridPosition(root.Position)
		local look = root.CFrame.LookVector
		local alongX = math.abs(look.X) >= math.abs(look.Z)
		for distance = 0, GRID - 1 do
			task.delay(distance * STRIPE_SWEEP, function()
				if not running then
					return
				end
				if alongX then
					paint(column - distance, row, team)
					paint(column + distance, row, team)
				else
					paint(column, row - distance, team)
					paint(column, row + distance, team)
				end
			end)
		end
	end

	local function setGiant(player: Player, untilTime: number?)
		if untilTime then
			giantUntil[player] = untilTime
		else
			giantUntil[player] = nil
		end
		local character = player.Character
		if character then
			-- Clients grow the Bloblet from this (server time); it isn't any bigger physically.
			character:SetAttribute("GiantUntil", untilTime)
		end
	end

	local function grab(index: number, player: Player, root: BasePart, team: Teams.TeamDef)
		local pickup = table.remove(pickups, index)
		if not pickup then
			return
		end
		if pickup.Kind == "Splash" then
			splash(pickup, team)
		elseif pickup.Kind == "Giant" then
			setGiant(player, context.GetServerTime() + Config.PaintPowers.GiantTime)
		else
			stripe(root, team)
		end
		-- Clients burst it in the team's colour (and tell the grabber what they got).
		pickup.Model:SetAttribute("GrabbedBy", player.UserId)
		pickup.Model:SetAttribute("SplashColor", team.Color)
		task.delay(0.3, function()
			if pickup.Model.Parent then
				pickup.Model:Destroy()
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

		local giant = giantUntil[player]
		local brush = if giant and context.GetServerTime() < giant then GIANT_BRUSH else 0
		local nearFloor = position.Y - center.Y <= BlobletRig.Dimensions.RootHeight + PAINT_HEIGHT
		if nearFloor then
			local last = lastPoint[player]
			if last and MathUtil.flat(position - last).Magnitude <= MAX_PAINT_LINE then
				paintLine(last, position, team, brush)
			else
				paintAt(position, team, brush)
			end
			lastPoint[player] = position
		else
			lastPoint[player] = nil -- in the air: nothing under you gets painted
		end

		for index = #pickups, 1, -1 do
			local offset = position - pickups[index].Position
			if MathUtil.flat(offset).Magnitude <= PICKUP_REACH and offset.Y < 8 then
				grab(index, player, root, team)
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
		pickupTimer = PICKUP_EVERY - PICKUP_FIRST
	end

	local function update(dt: number): boolean?
		if not running then
			return nil
		end
		for _, player in context.GetAlive() do
			updatePlayer(player)
		end
		pickupTimer += dt
		if pickupTimer >= PICKUP_EVERY then
			pickupTimer -= PICKUP_EVERY
			if #pickups < MAX_PICKUPS then
				spawnPickup()
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

	-- A new target for a bot: a power-up nearby (sharp bots look further for them), else a tile
	-- that isn't its team's yet, near it and not one a team-mate is already after.
	local function pickBotTarget(bot: Player, position: Vector3, team: Teams.TeamDef): BotTarget?
		local now = os.clock()
		local reach = 12 + 30 * Bots.SkillOf(bot)
		local nearestPickup: Pickup? = nil
		local pickupDistance = reach
		for _, pickup in pickups do
			local distance = MathUtil.flat(pickup.Position - position).Magnitude
			if distance < pickupDistance then
				nearestPickup, pickupDistance = pickup, distance
			end
		end
		local pickup = nearestPickup
		if pickup then
			return {
				Point = pickup.Position,
				Column = pickup.Column,
				Row = pickup.Row,
				Pickup = pickup,
				GiveUpAt = now + 6,
			}
		end

		local claimed: { [number]: boolean } = {}
		for other, target in botTargets do
			if other ~= bot and teamOf[other] == team then
				claimed[target.Column * GRID + target.Row] = true
			end
		end
		local best: BotTarget? = nil
		local bestRank = math.huge
		for column = 0, GRID - 1 do
			for row = 0, GRID - 1 do
				local tile = tileAt(column, row)
				if not tile or tile.Owner == team.Id then
					continue
				end
				local point = tileCenter(column, row)
				local rank = MathUtil.flat(point - position).Magnitude
					+ (if tile.Owner then -3 else 0) -- painting theirs back counts twice
					+ (if claimed[column * GRID + row] then 20 else 0)
					+ random:NextNumber(0, 8)
				if rank < bestRank then
					bestRank = rank
					best = { Point = point, Column = column, Row = row, Pickup = nil, GiveUpAt = now + 5 }
				end
			end
		end
		return best
	end

	local function botGoal(bot: Player): Types.BotGoal?
		local root = context.GetRoot(bot)
		local team = teamOf[bot]
		if not root or not team or not running then
			return nil
		end
		local target: BotTarget? = botTargets[bot]
		if target then
			local pickup = target.Pickup
			local done = if pickup
				then not table.find(pickups, pickup)
				else (tileAt(target.Column, target.Row) :: Tile).Owner == team.Id
			if done or os.clock() > target.GiveUpAt then
				target = nil
			end
		end
		if not target then
			target = pickBotTarget(bot, root.Position, team)
		end
		if not target then
			botTargets[bot] = nil
			return { MoveTo = center, Wander = half - 6 }
		end
		botTargets[bot] = target
		return { MoveTo = target.Point, Within = 1 }
	end

	return {
		Setup = setup,
		Start = start,
		Update = update,
		End = function()
			running = false
			table.clear(botTargets)
			for _, player in context.Players do
				setGiant(player, nil)
			end
			if scoresDirty then
				publishScores()
			end
			context.SetCounterText(resultText())
		end,
		GetQualified = getQualified,
		BotGoal = botGoal,
	}
end

return PaintGrab
