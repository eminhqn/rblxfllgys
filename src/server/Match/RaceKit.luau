--!strict
-- Everything Race rounds share:
--   * a start pad with a starting grid and a gate that drops into the floor at GO
--   * checkpoints: the furthest one you reach is where you respawn
--   * falling off the course (or pressing reset) respawns you instead of eliminating you
--   * the finish line under a spinning crown: crossing it qualifies you, and finishers celebrate
--     on a walled platform
--
-- A race mini-game builds its course, then calls BuildStart / AddCheckpoint / BuildFinish with
-- ground-level CFrames whose LookVector points along the course, and forwards Start, Update and
-- End to the race.
--
-- Clients own their Bloblet's physics, so progress is sanity-checked: reaching a checkpoint or
-- the finish only counts if you got there from where you were a moment ago at a believable speed.
-- A jump that isn't believable sends you back to your last checkpoint.
--
-- Bots (Server/Bots) follow a route the race lays with AddBotPoint, in course order (without one
-- they head from checkpoint to checkpoint). Where the course splits, the race gives each way a
-- Fork and Way name, and each bot picks one way per fork (sharper bots take the Hard ones more
-- often). A bot sent back to its checkpoint after setting off down a Hard way takes an easy way
-- there for the rest of the round. A point on a moving platform names its Mover (and any others in the same row, Also): the
-- bot goes for whichever will be nearest, and BotMotor times the jump from the platform's own
-- movement, waiting at the edge till a jump will land on it (with Ride, for trampolines it can't
-- stand and wait on, it just steers for where the pad will be). The race forwards BotGoal to the
-- round.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local MathUtil = require(Shared.MathUtil)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)
local HazardMath = require(Shared.HazardMath)

local Bots = require(script.Parent.Parent.Bots.Bots)
local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local ArenaUtil = require(script.Parent.ArenaUtil)
local Types = require(script.Parent.Types)

export type Options = {
	KillHeight: number, -- world Y: Bloblets that drop below this respawn
	-- Optional: also true for anyone who has clearly fallen off the course (e.g. well below the
	-- part of a tall course they're over), so they're sent back without falling all the way down.
	Fallen: ((position: Vector3) -> boolean)?,
}

-- A spot on the course, riding a moving platform or not.
export type BotSpot = {
	Position: Vector3, -- where it is (for a mover: when the mover is at home)
	Mover: Model?,
}

export type BotPointOptions = {
	Mover: Model?, -- the point rides on this moving platform (a Hazards.Mover)
	Also: { BotSpot }?, -- other platforms (the rest of the row) that do just as well
	-- Steer at where it is now without waiting for it (with Mover), and it's passed whatever the
	-- height: for trampolines, which bounce bots on before they could stand and wait.
	Ride: boolean?,
	Within: number?, -- reached when this close, flat (default 3)
	Fork: string?, -- where the course splits: the point is on one of the ways
	Way: string?, -- which way (with Fork)
	Hard: boolean?, -- the harder way: sharper bots take it more often
}

export type Race = {
	-- Start pad centred on `top` (its top surface), gate on the forward edge.
	BuildStart: (top: CFrame, width: number, depth: number) -> (),
	-- A checkpoint covering `size` (width, depth) of floor centred on `top`. Add them in course
	-- order. The mini-game builds the floor itself.
	AddCheckpoint: (top: CFrame, size: Vector2) -> (),
	-- Finish platform centred on `top`; the finish line is its back (entry) edge.
	BuildFinish: (top: CFrame, width: number, depth: number) -> (),
	SpawnPlayers: () -> (), -- call at the end of Setup
	Start: () -> (),
	Update: () -> (),
	Stop: () -> (),
	-- A point on the bots' route (on the floor), in course order: see the top of this file.
	AddBotPoint: (position: Vector3, options: BotPointOptions?) -> (),
	BotGoal: (bot: Player) -> Types.BotGoal?, -- give this to the round's BotGoal
}

type BotPoint = {
	Position: Vector3, -- where it is (for a mover: when the mover is at home)
	Stage: number, -- how many checkpoints come before it
	Mover: Model?,
	Ride: boolean,
	Within: number,
	Fork: string?,
	Way: string?,
	Hard: boolean,
	Choices: { BotSpot }, -- the point itself, then its Also
}

type BotRun = {
	Index: number, -- the point it's heading for
	Ways: { [string]: string }, -- the way it picked at each fork
	Respawns: number, -- how many times it had been sent back when the index was last set
	Picks: { [number]: number }, -- which of a point's Choices it's going for
	WaitingSince: number?, -- os.clock() it started going for the moving platform it's after
}

type Zone = {
	CFrame: CFrame,
	Size: Vector3,
	Spots: { CFrame },
}

type Sample = {
	Time: number,
	Position: Vector3,
}

local ZONE_HEIGHT = 16
local BOT_PICK_AHEAD = 0.7 -- seconds ahead it compares where a row's platforms will be
local BOT_PICK_MARGIN = 3 -- studs nearer another platform must be before it switches
-- Seconds a bot waits at an edge for its moving platform before it counts as stuck (and gets
-- reset). Every platform comes round well within this.
local BOT_PATIENCE = 15
local SPOT_SPACING = 6
local SPEED_SLACK = 1.2 -- progress must come from a move slower than MaxHorizontalSpeed * this
local DISTANCE_SLACK = 15 -- plus this many studs, for network jitter
local STREAM_TIMEOUT = 1

local WHITE = Color3.fromRGB(255, 255, 255)
local START_COLOR = Color3.fromRGB(196, 170, 255)
local FINISH_COLOR = Color3.fromRGB(255, 230, 120)
local CHECKPOINT_COLOR = Theme.Colors.Aqua

local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

local RaceKit = {}

-- Spots for respawning, spread over a floor area.
local function areaSpots(top: CFrame, width: number, depth: number): { CFrame }
	local columns = math.max(1, math.floor((width - 6) / SPOT_SPACING) + 1)
	local rows = math.max(1, math.floor((depth - 6) / SPOT_SPACING) + 1)
	return ArenaUtil.GridSpots(top, columns * rows, columns, SPOT_SPACING)
end

local function zoneFor(top: CFrame, width: number, depth: number): Zone
	return {
		CFrame = top * CFrame.new(0, ZONE_HEIGHT / 2 - 2, 0),
		Size = Vector3.new(width, ZONE_HEIGHT, depth),
		Spots = areaSpots(top, width, depth),
	}
end

-- A banner board with the same text on both faces.
local function banner(parent: Instance, cframe: CFrame, size: Vector3, text: string, color: Color3, textColor: Color3)
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
			textColor,
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

-- Two posts and a banner over a line across the course. `line` is ground level, LookVector along
-- the course.
local function arch(parent: Instance, line: CFrame, width: number, height: number, text: string, color: Color3)
	for _, side in { -1, 1 } do
		local foot = (line * CFrame.new(side * (width / 2 - 0.8), 0, 0)).Position
		Geometry.column(parent, height, 1.6, foot, WHITE, DECOR)
		Geometry.ball(parent, 2.4, foot + Vector3.new(0, height, 0), color, DECOR)
	end
	banner(parent, line * CFrame.new(0, height - 1.6, 0), Vector3.new(width - 2, 3.6, 0.8), text, color, WHITE)
end

-- A strip of squares across the course (start / finish lines).
local function checkerLine(parent: Instance, line: CFrame, width: number, colorA: Color3, colorB: Color3)
	local square = 2
	local count = math.floor(width / square)
	for row = 0, 1 do
		for index = 0, count - 1 do
			local x = -width / 2 + square / 2 + index * square
			local z = (row - 0.5) * square
			Geometry.block(
				parent,
				Vector3.new(square, 0.1, square),
				line * CFrame.new(x, 0.06, z),
				if (index + row) % 2 == 0 then colorA else colorB,
				DECOR
			)
		end
	end
end

function RaceKit.new(context: Types.RoundContext, options: Options): Race
	local arena = context.Arena
	local random = context.Random
	local startZone: Zone? = nil
	local finishZone: Zone? = nil
	local checkpoints: { Zone } = {}
	local gateParts: { BasePart } = {}
	local reached: { [Player]: number } = {} -- checkpoint index, 0 = start pad
	local samples: { [Player]: Sample } = {} -- where each Bloblet was on the last update
	local respawnedAt: { [Player]: number } = {}
	local startTop: CFrame? = nil
	local running = false
	local botPoints: { BotPoint } = {}
	local botRuns: { [Player]: BotRun } = {}
	local respawnCounts: { [Player]: number } = {}

	local function setCheckpointAttribute(player: Player, index: number)
		if player.Parent == Players then
			player:SetAttribute(Match.PlayerAttr.Checkpoint, index)
		end
	end

	local function zoneAt(index: number): Zone?
		if index <= 0 then
			return startZone
		end
		return checkpoints[index]
	end

	local function respawn(player: Player, zone: Zone?)
		local now = os.clock()
		local last = respawnedAt[player]
		if not zone or (last and now - last < Config.Race.RespawnCooldown) then
			return
		end
		respawnedAt[player] = now
		respawnCounts[player] = (respawnCounts[player] or 0) + 1
		local spot = zone.Spots[random:NextInteger(1, #zone.Spots)]
		task.spawn(function()
			pcall(function()
				player:RequestStreamAroundAsync(spot.Position, STREAM_TIMEOUT)
			end)
			if running and context.IsAlive(player) then
				context.SpawnAt(player, spot)
			end
		end)
	end

	local function respawnAtCheckpoint(player: Player)
		if context.IsQualified(player) then
			respawn(player, finishZone)
		else
			respawn(player, zoneAt(reached[player] or 0))
		end
	end

	-- Could they really have moved here from where they were on the last update?
	local function plausible(player: Player, position: Vector3, now: number): boolean
		local sample = samples[player]
		if not sample then
			return true
		end
		local elapsed = now - sample.Time
		local allowed = Config.Validation.MaxHorizontalSpeed * SPEED_SLACK * elapsed + DISTANCE_SLACK
		local distance = MathUtil.flat(position - sample.Position).Magnitude
		if distance <= allowed then
			return true
		end
		warn(`[RaceKit] {player.Name} jumped {math.floor(distance)} studs in {string.format("%.2f", elapsed)} s`)
		return false
	end

	-- Returns true if the player was sent back to a checkpoint.
	local function checkProgress(player: Player, position: Vector3, now: number): boolean
		if context.IsQualified(player) then
			if position.Y < options.KillHeight then
				respawn(player, finishZone)
				return true
			end
			return false
		end

		local finish = finishZone
		if finish and ArenaUtil.InBox(finish.CFrame, finish.Size, position) then
			if not plausible(player, position, now) then
				respawnAtCheckpoint(player)
				return true
			end
			context.Qualify(player)
			return false
		end

		for index = #checkpoints, (reached[player] or 0) + 1, -1 do
			local zone = checkpoints[index]
			if ArenaUtil.InBox(zone.CFrame, zone.Size, position) then
				if not plausible(player, position, now) then
					respawnAtCheckpoint(player)
					return true
				end
				reached[player] = index
				setCheckpointAttribute(player, index)
				return false
			end
		end

		local fallen = options.Fallen
		if position.Y < options.KillHeight or (fallen and fallen(position)) then
			respawnAtCheckpoint(player)
			return true
		end
		return false
	end

	local function updatePlayer(player: Player, now: number)
		local root = context.GetRoot(player)
		if not root then
			return
		end
		local position = root.Position
		local lastRespawn = respawnedAt[player]
		if lastRespawn and now - lastRespawn < Config.Race.RespawnCooldown then
			-- The teleport is still reaching their client and positions jump about meanwhile, so
			-- nothing counts yet; keep sampling so the first check afterwards has a recent point.
			samples[player] = { Time = now, Position = position }
			return
		end
		if checkProgress(player, position, now) then
			samples[player] = nil
		else
			samples[player] = { Time = now, Position = position }
		end
	end

	local function buildStart(top: CFrame, width: number, depth: number)
		local start = Geometry.model(arena, "Start")
		Hazards.Platform(start, top, Vector3.new(width, 4, depth), START_COLOR, "StartPad")
		local frontLine = top * CFrame.new(0, 0, -depth / 2 + 2)
		checkerLine(start, frontLine, width - 2, WHITE, Theme.Colors.Ink)

		-- The gate: glass panel and bar across the front edge, dropping into the floor at GO.
		local gateLine = top * CFrame.new(0, 0, -depth / 2 + 0.5)
		local panel = Geometry.block(
			start,
			Vector3.new(width - 3.4, 6, 0.6),
			gateLine * CFrame.new(0, 3, 0),
			Theme.Colors.Pink,
			{ Name = "Gate", Transparency = 0.55, CastShadow = false }
		)
		local bar = Geometry.block(
			start,
			Vector3.new(width - 3.4, 1.4, 1.4),
			gateLine * CFrame.new(0, 6.4, 0),
			Theme.Colors.Yellow,
			{ Name = "GateBar" }
		)
		for _, part in { panel, bar } do
			part:SetAttribute("StartTime", 0)
			part:SetAttribute("Rate", Config.Race.GateSinkRate)
			part:SetAttribute("MaxRise", Config.Race.GateSinkDepth)
			CollectionService:AddTag(part, Tags.Riser)
			table.insert(gateParts, part)
		end
		for _, side in { -1, 1 } do
			local foot = (gateLine * CFrame.new(side * (width / 2 - 0.8), 0, 0)).Position
			Geometry.column(start, 8, 1.6, foot, WHITE, { Name = "GatePost" })
			Geometry.ball(start, 2.4, foot + Vector3.new(0, 8, 0), Theme.Colors.Pink, DECOR)
		end
		startZone = zoneFor(top * CFrame.new(0, 0, 2), width - 4, depth - 6)
		startTop = top * CFrame.new(0, 0, 2)
	end

	local function addCheckpoint(top: CFrame, size: Vector2)
		local marker = Geometry.model(arena, `Checkpoint{#checkpoints + 1}`)
		local entry = top * CFrame.new(0, 0, size.Y / 2 - 1)
		Geometry.block(marker, Vector3.new(size.X, 0.1, 1.2), entry * CFrame.new(0, 0.06, 0), CHECKPOINT_COLOR, DECOR)
		arch(marker, entry, size.X, 11, "CHECKPOINT", CHECKPOINT_COLOR)
		table.insert(checkpoints, zoneFor(top, size.X, size.Y))
	end

	local function buildFinish(top: CFrame, width: number, depth: number)
		local finish = Geometry.model(arena, "Finish")
		Hazards.Platform(finish, top, Vector3.new(width, 4, depth), FINISH_COLOR, "FinishPad")
		local line = top * CFrame.new(0, 0, depth / 2 - 1.5)
		checkerLine(finish, line, width, WHITE, Theme.Colors.Ink)
		arch(finish, line, width, 16, "FINISH", Theme.Colors.Pink)
		Hazards.Crown(arena, (line * CFrame.new(0, 24, 0)).Position, 1.3)

		-- Glass walls round the sides and far end keep finishers on the platform.
		local wallHeight = 9
		local walls = {
			{
				CFrame = top * CFrame.new(-width / 2 + 0.3, wallHeight / 2, 0),
				Size = Vector3.new(0.6, wallHeight, depth),
			},
			{
				CFrame = top * CFrame.new(width / 2 - 0.3, wallHeight / 2, 0),
				Size = Vector3.new(0.6, wallHeight, depth),
			},
			{
				CFrame = top * CFrame.new(0, wallHeight / 2, -depth / 2 + 0.3),
				Size = Vector3.new(width, wallHeight, 0.6),
			},
		}
		for _, wall in walls do
			Geometry.block(finish, wall.Size, wall.CFrame, Theme.Colors.Yellow, {
				Name = "Glass",
				Transparency = 0.6,
				CastShadow = false,
			})
		end

		-- Everything past the line counts as finished.
		local lineToFront = depth - 1.5
		local zoneCenter = top * CFrame.new(0, 0, depth / 2 - 1.5 - lineToFront / 2)
		finishZone = {
			CFrame = zoneCenter * CFrame.new(0, ZONE_HEIGHT / 2 - 2, 0),
			Size = Vector3.new(width, ZONE_HEIGHT, lineToFront),
			Spots = areaSpots(top * CFrame.new(0, 0, -depth / 4), width - 4, depth / 2 - 4),
		}
	end

	local function spawnPlayers()
		local top = startTop
		local zone = startZone
		if not top or not zone then
			warn(`[RaceKit] {context.Info.Id} has no start pad`)
			return
		end
		local spacing = 5.5
		local columns = math.max(1, math.floor((zone.Size.X - 4) / spacing) + 1)
		context.SpawnAll(ArenaUtil.GridSpots(top, #context.Players, columns, spacing))
	end

	local function start()
		running = true
		for _, part in gateParts do
			part:SetAttribute("StartTime", context.GetStartTime())
			part.CanCollide = false
		end
		for _, player in context.GetAlive() do
			reached[player] = 0
			setCheckpointAttribute(player, 0)
		end
	end

	local function update()
		if not running then
			return
		end
		local now = os.clock()
		for _, player in context.GetAlive() do
			updatePlayer(player, now)
		end
	end

	local function stop()
		running = false
		for _, player in context.Players do
			setCheckpointAttribute(player, 0)
		end
	end

	-------------------------------------------------------------------------------------------------
	-- Bots
	-------------------------------------------------------------------------------------------------

	local function addBotPoint(position: Vector3, pointOptions: BotPointOptions?)
		local opts: BotPointOptions = pointOptions or {}
		local choices: { BotSpot } = { { Position = position, Mover = opts.Mover } }
		local also: { BotSpot } = opts.Also or {}
		for _, other in also do
			table.insert(choices, other)
		end
		table.insert(botPoints, {
			Position = position,
			Stage = #checkpoints,
			Choices = choices,
			Mover = opts.Mover,
			Ride = opts.Ride == true,
			Within = opts.Within or 3,
			Fork = opts.Fork,
			Way = opts.Way,
			Hard = opts.Hard == true,
		})
	end

	-- Where a spot is at server time `at` (a moving platform's moves with it).
	local function pointAt(point: BotSpot, at: number): Vector3
		local mover = point.Mover
		if not mover then
			return point.Position
		end
		local travel = mover:GetAttribute("Travel")
		local speed = mover:GetAttribute("Speed")
		local phase = mover:GetAttribute("Phase")
		return point.Position
			+ HazardMath.MoverOffset(
				if typeof(travel) == "Vector3" then travel else Vector3.zero,
				if typeof(speed) == "number" then speed else 1,
				if typeof(phase) == "number" then phase else 0,
				at
			)
	end

	-- The way a bot takes at `fork`: picked the first time it gets there.
	local function wayAt(run: BotRun, bot: Player, fork: string): string?
		local chosen = run.Ways[fork]
		if chosen then
			return chosen
		end
		local easy: { string } = {}
		local hard: { string } = {}
		for _, point in botPoints do
			local way = point.Way
			if point.Fork == fork and way and not table.find(easy, way) and not table.find(hard, way) then
				table.insert(if point.Hard then hard else easy, way)
			end
		end
		local info = Bots.Info(bot)
		local skill = if info then info.Skill else 0.5
		local list = if #hard > 0 and (#easy == 0 or random:NextNumber() < skill) then hard else easy
		if #list == 0 then
			return nil
		end
		local picked = list[random:NextInteger(1, #list)]
		run.Ways[fork] = picked
		return picked
	end

	-- An easy way at `fork` (one at random if there are several), or nil if every way is hard.
	local function easyWayAt(fork: string): string?
		local easy: { string } = {}
		for _, point in botPoints do
			local way = point.Way
			if point.Fork == fork and way and not point.Hard and not table.find(easy, way) then
				table.insert(easy, way)
			end
		end
		return if #easy > 0 then easy[random:NextInteger(1, #easy)] else nil
	end

	-- The next point on this bot's route from `index` on (skipping the ways it didn't pick).
	local function nextPoint(run: BotRun, bot: Player, index: number): (BotPoint?, number)
		local at = index
		while at <= #botPoints do
			local point = botPoints[at]
			local fork = point.Fork
			if not fork or wayAt(run, bot, fork) == point.Way then
				return point, at
			end
			at += 1
		end
		return nil, at
	end

	-- Which of a point's platforms the bot goes for: whichever will be nearest, changing its mind
	-- only while it's standing (never mid-jump) and only for a clearly nearer one.
	local function chosenSpot(run: BotRun, index: number, point: BotPoint, root: BasePart, now: number): BotSpot
		local choices = point.Choices
		local picked = run.Picks[index] or 1
		if #choices > 1 and math.abs(root.AssemblyLinearVelocity.Y) < 2 then
			local position = root.Position
			local soon = now + BOT_PICK_AHEAD
			local best = picked
			local bestDistance = MathUtil.flat(pointAt(choices[picked], soon) - position).Magnitude - BOT_PICK_MARGIN
			for choice, spot in choices do
				local distance = MathUtil.flat(pointAt(spot, soon) - position).Magnitude
				if distance < bestDistance then
					best, bestDistance = choice, distance
				end
			end
			picked = best
			run.Picks[index] = picked
		end
		return choices[picked] or choices[1]
	end

	local function groundOf(zone: Zone): Vector3
		return (zone.CFrame * CFrame.new(0, -(ZONE_HEIGHT / 2 - 2), 0)).Position
	end

	local function botGoal(bot: Player): Types.BotGoal?
		local root = context.GetRoot(bot)
		local finish = finishZone
		if not root or not finish then
			return nil
		end
		if context.IsQualified(bot) then
			return { MoveTo = groundOf(finish), Wander = 6, Calm = true }
		end
		local existing = botRuns[bot]
		local respawns = respawnCounts[bot] or 0
		local run: BotRun
		if existing and existing.Respawns == respawns then
			run = existing
		else
			-- Starting out, or sent back to a checkpoint: pick up the route from there.
			local stage = reached[bot] or 0
			local index = #botPoints + 1
			for at, point in botPoints do
				if point.Stage >= stage then
					index = at
					break
				end
			end
			local ways: { [string]: string } = if existing then existing.Ways else {}
			if existing then
				-- Sent back after setting off down a hard way on this stretch (it had got to that
				-- way's first point or past it): it failed, so the easy way from now on.
				for at, point in botPoints do
					if at > existing.Index then
						break
					end
					local fork = point.Fork
					if fork and point.Hard and point.Stage == stage and ways[fork] == point.Way then
						ways[fork] = easyWayAt(fork) or ways[fork]
					end
				end
			end
			run = {
				Index = index,
				Ways = ways,
				Respawns = respawns,
				Picks = {},
				WaitingSince = nil,
			}
			botRuns[bot] = run
		end

		local now = context.GetServerTime()
		local position = root.Position
		local feet = position.Y - 2.1
		local point: BotPoint?, index: number
		while true do
			point, index = nextPoint(run, bot, run.Index)
			run.Index = index
			if not point then
				break
			end
			local target = pointAt(chosenSpot(run, index, point, root, now), now)
			local away = MathUtil.flat(target - position)
			-- (Bouncing over a trampoline counts, whatever the height.)
			local done = away.Magnitude <= point.Within and (point.Ride or math.abs(feet - target.Y) < 5)
			if not done and not point.Mover and away.Magnitude < 20 and math.abs(feet - target.Y) < 8 then
				-- Already past it, heading for the one after.
				local after = nextPoint(run, bot, index + 1)
				local ahead = if after then MathUtil.flat(pointAt(after, now) - target) else Vector3.zero
				done = ahead.Magnitude > 1e-3 and MathUtil.flat(position - target):Dot(ahead.Unit) > 0
			end
			if not done then
				break
			end
			run.Index = index + 1
			run.WaitingSince = nil
		end

		local progress = `route {math.min(run.Index, #botPoints)}/{#botPoints}`
		if not point then
			-- Past the last point (or there's no route): the next checkpoint, then the finish.
			local nextZone = checkpoints[(reached[bot] or 0) + 1] or finish
			return { MoveTo = groundOf(nextZone), Within = 3, Note = "to the finish" }
		end
		local spot = chosenSpot(run, index, point, root, now)
		if not spot.Mover then
			-- Straight on through to the point after, unless that one moves (it waits for those).
			local after = nextPoint(run, bot, index + 1)
			local onward = if after and not after.Mover then after.Position else nil
			return { MoveTo = pointAt(spot, now), Then = onward, Within = point.Within, Note = progress }
		end
		local function track(at: number): Vector3
			return pointAt(spot, at)
		end
		if point.Ride then
			return { MoveTo = track(now), Track = track, Within = point.Within, Note = progress }
		end
		-- A moving platform: BotMotor times the jump on (waiting at the edge till a jump will land),
		-- so standing there waiting is fine; for a while.
		local since = run.WaitingSince or os.clock()
		run.WaitingSince = since
		local patient = os.clock() - since < BOT_PATIENCE
		return {
			MoveTo = track(now),
			Track = track,
			Within = point.Within,
			Careful = true,
			Waiting = patient,
			Note = `{progress} {if patient then "timing a jump" else "can't time the jump"}`,
		}
	end

	context.OnResetRequested(function(player: Player)
		if running and context.IsAlive(player) then
			respawnAtCheckpoint(player)
		end
	end)

	return {
		BuildStart = buildStart,
		AddCheckpoint = addCheckpoint,
		BuildFinish = buildFinish,
		SpawnPlayers = spawnPlayers,
		Start = start,
		Update = update,
		Stop = stop,
		AddBotPoint = addBotPoint,
		BotGoal = botGoal,
	}
end

return RaceKit
