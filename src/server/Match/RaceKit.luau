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

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local ArenaUtil = require(script.Parent.ArenaUtil)
local Types = require(script.Parent.Types)

export type Options = {
	KillHeight: number, -- world Y: Bloblets that drop below this respawn
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

		if position.Y < options.KillHeight then
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
	}
end

return RaceKit
