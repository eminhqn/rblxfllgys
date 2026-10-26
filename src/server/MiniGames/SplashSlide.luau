--!strict
-- SPLASH SLIDE (Race)
-- A giant water slide from a tower in the sky down to a pool. The water carries you along (a Flow
-- on every slide piece: MovementController); you steer, jump and dive, and a belly slide (dive
-- onto the water) beats the water's speed and lasts all the way down. The slides are smooth curved
-- troughs: rounded sides, gentle bends and no steps between pieces.
-- After the first stretch, each splash pool splits into routes that meet again at the next pool:
--   * LONG WAY: wide, walled and gentle, round big sweeping bends. Easy, but further.
--   * SHORTCUT: narrow, straight and steep, faster water, no walls and hammers. Quick, but hard.
--   * JUMP / SKI JUMP: a ramp that throws you over a gap. Miss and you're back at the pool.
-- The pools are checkpoints (the last one has a spinning bar). Fall off and you're back at the last
-- one. The first down to the finish deck at the bottom qualify.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.MathUtil)
local Theme = require(Shared.Theme)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local RaceKit = require(script.Parent.Parent.Match.RaceKit)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 120
local START_HEIGHT = 130 -- the start pad, above the arena origin
local FLOW_EASY = 36 -- studs/s the water carries you on the long ways
local FLOW_FAST = 42 -- and on the shortcuts and jumps
local THICKNESS = 2
local RAIL_HEIGHT = 3
local WALL_HEIGHT = 5 -- glass round the pools
local EASE = 14 -- studs at each end of a slide over which its slope eases in and out (no kinks)
local TRACE_STEP = 1 -- studs between the points a slide's curve is traced at
local MAX_TURN = math.rad(6) -- slides are built of straight pieces: a new one after this much turn
local MAX_PITCH = math.rad(2) -- or this much change in slope
local MAX_PIECE = 24 -- or this long
local POOL_DEPTH = 28
local FINISH_DEPTH = 30
local FALL_MARGIN = 16 -- this far below the slide under you counts as fallen off
local SAMPLE_SPACING = 4
local HAMMER_DROP = 16
local KICKER_LENGTH = 8
local KICKER_PIECES = 4
local SIGN_HEIGHT = 10

local WATER = Color3.fromRGB(80, 190, 255)
local WATER_LIGHT = Color3.fromRGB(170, 228, 255)
local GLASS = Color3.fromRGB(150, 230, 255)
local POOL_EDGE = Color3.fromRGB(255, 236, 246)
local WHITE = Color3.fromRGB(255, 255, 255)
local PEPPERMINT = Theme.Colors.Pink
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }
local WALL: Geometry.PartOptions = { Name = "Wall", Transparency = 0.55, CastShadow = false }

-- A trough's curved side, as strips going out from the floor's edge, each tilted up more.
type Bank = { Width: number, Angle: number }

local WALLED_BANKS: { Bank } = {
	{ Width = 3, Angle = math.rad(28) },
	{ Width = 3.2, Angle = math.rad(62) },
}
local OPEN_BANKS: { Bank } = { -- shortcuts: just a low rounded lip
	{ Width = 1.6, Angle = math.rad(24) },
}

type Jump = {
	At: number, -- share of the way down where the ramp starts (the route must be straight there)
	Gap: number, -- studs to fly
	Angle: number, -- degrees the ramp's lip points up
	Drop: number, -- how much lower the landing is, on top of the slide's own slope
}

type Route = {
	Name: string?, -- on the sign over where it leaves the pool (nil: the only way)
	Walls: boolean, -- rounded sides and glass rails, or just a low lip
	From: number, -- where it leaves the pool above (studs across from the middle)
	-- Its shape seen from above, as (degrees to turn, studs to go while turning; 0 degrees is
	-- straight on). The turns add up to 0, so it joins the pool below heading straight on. Bends
	-- are at least 30 studs round, so the water can carry you round them. nil: straight down.
	Path: { Vector2 }?,
	Width: number, -- the floor
	Flow: number,
	Color: Color3, -- its sides and sign
	Hammers: { number }?, -- shares of the way down
	Bumpers: { Vector2 }?, -- (studs across from the middle, share of the way down)
	Jump: Jump?,
}

-- From one pool (or the start) down to the next, Drop lower. The first route is the long way: the
-- pool below is as far on as it goes, and the straight routes are that long.
type Section = {
	Drop: number,
	Routes: { Route },
	Spinner: boolean?, -- a spinning bar in the pool at its bottom
}

-- The long way out and back round a big bend: out to one side, along, and back.
local function swing(turn: number, arc: number, along: number, middle: number, ends: number): { Vector2 }
	return {
		Vector2.new(0, ends),
		Vector2.new(-turn, arc),
		Vector2.new(0, along),
		Vector2.new(turn, arc),
		Vector2.new(0, middle),
		Vector2.new(turn, arc),
		Vector2.new(0, along),
		Vector2.new(-turn, arc),
		Vector2.new(0, ends),
	}
end

local SECTIONS: { Section } = {
	{
		Drop = 24,
		Routes = {
			{
				Walls = true,
				From = 0,
				Path = {
					Vector2.new(0, 14),
					Vector2.new(-40, 32),
					Vector2.new(0, 16),
					Vector2.new(80, 60),
					Vector2.new(0, 16),
					Vector2.new(-40, 32),
					Vector2.new(0, 14),
				},
				Width = 16,
				Flow = FLOW_EASY,
				Color = Theme.Colors.Aqua,
				Bumpers = { Vector2.new(-3.5, 0.3), Vector2.new(3.5, 0.75) },
			},
		},
	},
	{
		Drop = 30,
		Routes = {
			{
				Name = "LONG WAY (EASY)",
				Walls = true,
				From = -16,
				Path = swing(60, 32, 22, 8, 12),
				Width = 14,
				Flow = FLOW_EASY,
				Color = Theme.Colors.Lime,
				Bumpers = { Vector2.new(0, 0.5) },
			},
			{
				Name = "SHORTCUT (HARD)",
				Walls = false,
				From = 16,
				Width = 8,
				Flow = FLOW_FAST,
				Color = Theme.Colors.Orange,
				Hammers = { 0.4, 0.72 },
			},
		},
	},
	{
		Drop = 32,
		Spinner = true,
		Routes = {
			{
				Name = "LONG WAY (EASY)",
				Walls = true,
				From = -27,
				Path = swing(65, 36, 24, 14, 12),
				Width = 14,
				Flow = FLOW_EASY,
				Color = Theme.Colors.Lime,
				Bumpers = { Vector2.new(-3, 0.45), Vector2.new(3, 0.55) },
			},
			{
				Name = "JUMP (MEDIUM)",
				Walls = true,
				From = 0,
				Width = 12,
				Flow = FLOW_FAST,
				Color = Theme.Colors.Yellow,
				Jump = { At = 0.45, Gap = 12, Angle = 22, Drop = 4 },
			},
			{
				Name = "SHORTCUT (HARD)",
				Walls = false,
				From = 24,
				Width = 7,
				Flow = FLOW_FAST,
				Color = Theme.Colors.Orange,
				Hammers = { 0.28, 0.52, 0.76 },
			},
		},
	},
	{
		Drop = 28,
		Routes = {
			{
				Name = "LONG WAY (EASY)",
				Walls = true,
				From = -20,
				Path = swing(60, 32, 18, 8, 10),
				Width = 14,
				Flow = FLOW_EASY,
				Color = Theme.Colors.Lime,
				Bumpers = { Vector2.new(-3, 0.3), Vector2.new(3, 0.7) },
			},
			{
				Name = "SKI JUMP (HARD)",
				Walls = false,
				From = 20,
				Width = 9,
				Flow = FLOW_FAST,
				Color = Theme.Colors.Purple,
				Jump = { At = 0.5, Gap = 16, Angle = 28, Drop = 6 },
			},
		},
	},
}

local SplashSlide = {}

SplashSlide.Info = {
	Id = "SplashSlide",
	DisplayName = "Splash Slide",
	Type = "Race",
	Rules = "Ride the water slide to the bottom! Dive to slide faster. Long ways are easy, shortcuts are hard.",
	Duration = DURATION,
	MinPlayers = 1,
} :: Types.MiniGameInfo

local function banksOf(route: Route): { Bank }
	return if route.Walls then WALLED_BANKS else OPEN_BANKS
end

-- How far across a route's trough reaches from its middle, rails included.
local function halfWidth(route: Route): number
	local half = route.Width / 2
	for _, bank in banksOf(route) do
		half += bank.Width * math.cos(bank.Angle)
	end
	return half + (if route.Walls then 0.8 else 0)
end

-- A route's middle line seen from above (X across, Y forward from the pool above), traced every
-- TRACE_STEP studs along its arcs and straights (or straight on for `length`). Also returns how far
-- along each point is.
local function trace(route: Route, length: number): ({ Vector2 }, { number })
	local position = Vector2.new(route.From, 0)
	local points: { Vector2 } = { position }
	local distances: { number } = { 0 }
	local path: { Vector2 } = route.Path or { Vector2.new(0, length) }
	local heading = 0
	local travelled = 0
	for _, leg in path do
		local steps = math.max(1, math.round(leg.Y / TRACE_STEP))
		local turn = math.rad(leg.X) / steps
		local step = leg.Y / steps
		for _ = 1, steps do
			heading += turn / 2
			position += Vector2.new(math.sin(heading), math.cos(heading)) * step
			heading += turn / 2
			travelled += step
			table.insert(points, position)
			table.insert(distances, travelled)
		end
	end
	return points, distances
end

-- How far on (forward) the pool below a section is: where its long way ends.
local function sectionLength(section: Section): number
	for _, route in section.Routes do
		if route.Path then
			local points = trace(route, 0)
			return points[#points].Y
		end
	end
	return 150
end

-- How far down a slide is `along` studs from its top: the slope eases in from flat and back out to
-- flat at the bottom, so it meets each pool without a kink.
local function easedDrop(along: number, length: number, drop: number): number
	local ease = math.min(EASE, length / 3)
	local slope = drop / (length - ease)
	if along <= ease then
		return slope * along * along / (2 * ease)
	elseif along <= length - ease then
		return slope * (along - ease / 2)
	end
	local left = length - along
	return drop - slope * left * left / (2 * ease)
end

local function headingOf(from: Vector3, to: Vector3): number
	return math.atan2(to.X - from.X, to.Z - from.Z)
end

local function pitchOf(from: Vector3, to: Vector3): number
	return math.atan2(from.Y - to.Y, MathUtil.flat(to - from).Magnitude)
end

local function turnBetween(a: number, b: number): number
	return math.abs((a - b + math.pi) % (2 * math.pi) - math.pi)
end

function SplashSlide.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local samples: { Vector3 } = {} -- points on the course's surface, for "fallen off"

	-- The course point nearest `position` seen from above, and how far away (flat) it is.
	local function nearestSample(position: Vector3): (Vector3?, number)
		local best: Vector3? = nil
		local bestDistance = math.huge
		for _, point in samples do
			local distance = MathUtil.flat(point - position).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = point
			end
		end
		return best, bestDistance
	end

	local race = RaceKit.new(context, {
		KillHeight = center.Y - 80,
		Fallen = function(position: Vector3): boolean
			local surface = nearestSample(position)
			return surface ~= nil and position.Y < surface.Y - FALL_MARGIN
		end,
	})

	local function addGridSamples(middle: Vector3, width: number, depth: number)
		for x = -width / 2 + 2, width / 2 - 2, 8 do
			for z = -depth / 2 + 2, depth / 2 - 2, 8 do
				table.insert(samples, middle + Vector3.new(x, 0, z))
			end
		end
	end

	-- One straight piece of trough from `from` to `to` (the middle of its floor at each end): a
	-- water floor carrying you along, rounded sides and, on walled routes, glass rails. Pieces
	-- overlap a little so bends have no gaps or lips.
	local function buildPiece(parent: Instance, from: Vector3, to: Vector3, route: Route, floorColor: Color3?)
		local flow = MathUtil.flat(to - from).Unit * route.Flow
		local top = CFrame.lookAt((from + to) / 2, to)
		local overlap = 0.3 + halfWidth(route) * math.tan(MAX_TURN)
		local length = (to - from).Magnitude + overlap * 2
		local floor = Geometry.block(
			parent,
			Vector3.new(route.Width, THICKNESS, length),
			top * CFrame.new(0, -THICKNESS / 2, 0),
			floorColor or WATER,
			{ Name = "Slide" }
		)
		floor.Reflectance = 0.15
		floor:SetAttribute("Flow", flow)
		for _, side in { -1, 1 } do
			local x, y = route.Width / 2, 0
			for _, bank in banksOf(route) do
				local dx, dy = bank.Width * math.cos(bank.Angle), bank.Width * math.sin(bank.Angle)
				local strip = Geometry.block(
					parent,
					Vector3.new(bank.Width + 0.3, THICKNESS, length),
					top
						* CFrame.new(side * (x + dx / 2), y + dy / 2, 0)
						* CFrame.Angles(0, 0, side * bank.Angle)
						* CFrame.new(0, -THICKNESS / 2, 0),
					route.Color,
					{ Name = "Side" }
				)
				strip:SetAttribute("Flow", flow)
				x += dx
				y += dy
			end
			if route.Walls then
				Geometry.block(
					parent,
					Vector3.new(0.8, RAIL_HEIGHT, length),
					top * CFrame.new(side * (x + 0.4), y + RAIL_HEIGHT / 2 - 0.3, 0),
					GLASS,
					WALL
				)
			end
		end
		-- White foam chevrons pointing downhill on the longer pieces.
		if length > 10 then
			for _, side in { -1, 1 } do
				Geometry.block(
					parent,
					Vector3.new(0.4, 0.1, 2.6),
					top * CFrame.new(side * 0.9, 0.05, 0) * CFrame.Angles(0, side * 0.6, 0),
					WATER_LIGHT,
					DECOR
				)
			end
		end
	end

	-- A peppermint bumper standing on the slide.
	local function bumper(parent: Instance, ground: CFrame)
		local bottom = ground.Position - Vector3.new(0, 0.8, 0)
		Geometry.column(parent, 4.4, 4, bottom, WHITE, { Name = "Bumper" })
		for index = 0, 3 do
			local angle = index / 4 * math.pi * 2
			Geometry.block(
				parent,
				Vector3.new(1.8, 0.12, 0.8),
				CFrame.new(bottom + Vector3.new(math.cos(angle) * 1, 4.45, math.sin(angle) * 1))
					* CFrame.Angles(0, -angle, 0),
				PEPPERMINT,
				DECOR
			)
		end
	end

	-- A route from `top` (the middle of the pool above's front edge, or the start pad's) down to
	-- the pool `length` further on and `drop` lower. Returns where it joins that pool (studs across).
	local function buildRoute(parent: Instance, route: Route, top: Vector3, length: number, drop: number): number
		local flatPoints, distances = trace(route, length)
		local total = distances[#distances]
		local jump = route.Jump
		local gapFrom, gapTo, jumpDrop = math.huge, math.huge, 0
		if jump then
			gapFrom = total * jump.At
			gapTo = gapFrom + KICKER_LENGTH + jump.Gap
			jumpDrop = jump.Drop
		end
		local points: { Vector3 } = {}
		local lastBefore, firstAfter = #flatPoints, #flatPoints + 1
		for index, flatPoint in flatPoints do
			local along = distances[index]
			local down = easedDrop(along, total, drop - jumpDrop) + (if along >= gapTo then jumpDrop else 0)
			points[index] = top + Vector3.new(flatPoint.X, -down, flatPoint.Y)
			if along <= gapFrom then
				lastBefore = index
			elseif along >= gapTo and firstAfter > #flatPoints then
				firstAfter = index
			end
		end

		-- Straight pieces along the curve: a new one whenever it has turned or changed slope enough.
		local function buildRun(first: number, last: number)
			local a = first
			while a < last do
				local heading = headingOf(points[a], points[a + 1])
				local pitch = pitchOf(points[a], points[a + 1])
				local b = a + 1
				while b < last do
					if
						turnBetween(headingOf(points[b], points[b + 1]), heading) > MAX_TURN
						or math.abs(pitchOf(points[b], points[b + 1]) - pitch) > MAX_PITCH
						or distances[b + 1] - distances[a] > MAX_PIECE
					then
						break
					end
					b += 1
				end
				buildPiece(parent, points[a], points[b], route)
				a = b
			end
			for index = first, last, SAMPLE_SPACING do
				table.insert(samples, points[index])
			end
			table.insert(samples, points[last])
		end

		buildRun(1, lastBefore)
		if jump and firstAfter <= #points then
			-- A ramp curving up to its lip, then a gap to fly over.
			local from = points[lastBefore]
			local direction = MathUtil.flat(from - points[lastBefore - 1]).Unit
			local upStart = -pitchOf(points[lastBefore - 1], from)
			local step = KICKER_LENGTH / KICKER_PIECES
			for piece = 1, KICKER_PIECES do
				local angle = upStart + (math.rad(jump.Angle) - upStart) * piece / KICKER_PIECES
				local to = from + direction * step + Vector3.new(0, step * math.tan(angle), 0)
				buildPiece(parent, from, to, route, Theme.Colors.Yellow)
				from = to
			end
			buildRun(firstAfter, #points)
		end

		local function frameAt(share: number): CFrame
			local index = math.clamp(math.floor(share * total / TRACE_STEP + 0.5) + 1, 1, #points - 1)
			return CFrame.lookAt(points[index], points[index + 1])
		end
		local hammers = route.Hammers
		if hammers then
			for _, share in hammers do
				local ground = frameAt(share)
				local pivot = ground.Position + Vector3.new(0, HAMMER_DROP, 0)
				local forward = MathUtil.flat(ground.LookVector).Unit
				Hazards.Hammer(parent, CFrame.lookAt(pivot, pivot + forward), {
					Amplitude = 1.1,
					Speed = 2.1,
					Phase = random:NextNumber(0, math.pi * 2),
					FrameSpan = halfWidth(route) * 2 + 3,
					Color = Theme.Colors.Purple,
				})
			end
		end
		local bumpers = route.Bumpers
		if bumpers then
			for _, spot in bumpers do
				bumper(parent, frameAt(spot.Y) * CFrame.new(spot.X, 0, 0))
			end
		end
		return flatPoints[#flatPoints].X
	end

	-- Glass along a pool's back or front edge (at `z`), leaving gaps for the slides at `gaps` (each
	-- (studs across, half its width)).
	local function edgeWall(parent: Instance, surface: number, z: number, half: number, gaps: { Vector2 })
		table.sort(gaps, function(a: Vector2, b: Vector2): boolean
			return a.X < b.X
		end)
		local cursor = -half - 1
		local function wall(to: number)
			if to - cursor > 0.5 then
				Geometry.block(
					parent,
					Vector3.new(to - cursor, WALL_HEIGHT, 1),
					CFrame.new(center.X + (cursor + to) / 2, surface + WALL_HEIGHT / 2, z),
					GLASS,
					WALL
				)
			end
		end
		for _, gap in gaps do
			wall(gap.X - gap.Y)
			cursor = gap.X + gap.Y
		end
		wall(half + 1)
	end

	-- How wide a pool (or the finish deck) needs to be for the slides coming in and going out
	-- (each (studs across, half its width)).
	local function poolWidth(entrances: { Vector2 }, exits: { Vector2 }): number
		local reach = 0
		for _, list in { entrances, exits } do
			for _, gap in list do
				reach = math.max(reach, math.abs(gap.X) + gap.Y)
			end
		end
		return math.ceil(reach) * 2 + 8
	end

	-- A flat splash pool to catch your breath and pick a way down: a checkpoint, walled in, with a
	-- sign over every way out. `back` is the middle of its back edge (on its surface); `entrances`
	-- are where the slides come in.
	local function buildPool(
		parent: Instance,
		back: Vector3,
		entrances: { Vector2 },
		exits: { Route },
		spinner: boolean?
	): (CFrame, number)
		local ways: { Vector2 } = {}
		for _, route in exits do
			table.insert(ways, Vector2.new(route.From, halfWidth(route) + 0.4))
		end
		local width = poolWidth(entrances, ways)
		local middle = back + Vector3.new(0, 0, POOL_DEPTH / 2)
		local top = CFrame.lookAt(middle, middle + Vector3.zAxis)
		Hazards.Platform(parent, top, Vector3.new(width, 4, POOL_DEPTH), POOL_EDGE, "Pool")
		Geometry.block(
			parent,
			Vector3.new(width - 4, 0.2, POOL_DEPTH - 4),
			top * CFrame.new(0, 0.1, 0),
			WATER_LIGHT,
			DECOR
		)
		for _, side in { -1, 1 } do
			Geometry.block(
				parent,
				Vector3.new(1, WALL_HEIGHT, POOL_DEPTH + 2),
				CFrame.new(middle + Vector3.new(side * (width / 2 + 0.5), WALL_HEIGHT / 2, 0)),
				GLASS,
				WALL
			)
		end
		edgeWall(parent, back.Y, back.Z - 0.5, width / 2, entrances)
		edgeWall(parent, back.Y, back.Z + POOL_DEPTH + 0.5, width / 2, ways)

		for _, route in exits do
			local name = route.Name
			if name then
				local half = halfWidth(route)
				local foot = back + Vector3.new(route.From, 0, POOL_DEPTH - 1.5)
				Geometry.sign(parent, name, foot + Vector3.new(0, SIGN_HEIGHT, 0), half * 2 - 1, 3, route.Color, 0.1)
				for _, side in { -1, 1 } do
					Geometry.column(
						parent,
						SIGN_HEIGHT + 1.5,
						0.9,
						foot + Vector3.new(side * (half + 0.6), 0, 0),
						WHITE,
						{ Name = "SignPost" }
					)
				end
			end
		end
		if spinner then
			Hazards.Spinner(parent, middle, {
				ArmLength = 24,
				Speed = 1.3,
				Mat = false,
				Color = Theme.Colors.Orange,
			})
		end
		addGridSamples(middle, width, POOL_DEPTH)
		return top, width
	end

	-- Returns the middle of the finish deck.
	local function buildCourse(arena: Model): Vector3
		local course = Geometry.model(arena, "Slide")
		local edge = center + Vector3.new(0, START_HEIGHT, 0) -- middle of the start pad's front edge
		race.BuildStart(CFrame.lookAt(edge - Vector3.zAxis * 14, edge), 40, 28)
		addGridSamples(edge - Vector3.zAxis * 14, 40, 28)
		-- Glass that funnels the start pad onto the first slide.
		local firstHalf = halfWidth(SECTIONS[1].Routes[1])
		for _, side in { -1, 1 } do
			local from = edge + Vector3.new(side * 20, 0, -3)
			local to = edge + Vector3.new(side * (firstHalf + 0.4), 0, 0.5)
			local middle = (from + to) / 2 + Vector3.new(0, WALL_HEIGHT / 2, 0)
			Geometry.block(
				course,
				Vector3.new(1, WALL_HEIGHT, (to - from).Magnitude),
				CFrame.lookAt(middle, middle + (to - from)),
				GLASS,
				WALL
			)
		end

		for index, section in SECTIONS do
			local length = sectionLength(section)
			local entrances: { Vector2 } = {}
			for _, route in section.Routes do
				local joins = buildRoute(course, route, edge, length, section.Drop)
				table.insert(entrances, Vector2.new(joins, halfWidth(route) + 0.4))
			end
			local back = edge + Vector3.new(0, -section.Drop, length)
			local following = SECTIONS[index + 1]
			if not following then
				-- The finish: a pool deck at the bottom.
				local width = poolWidth(entrances, {})
				local middle = back + Vector3.zAxis * (FINISH_DEPTH / 2)
				race.BuildFinish(CFrame.lookAt(middle, middle + Vector3.zAxis), width, FINISH_DEPTH)
				addGridSamples(middle, width, FINISH_DEPTH)
				return middle
			end
			local top, width = buildPool(course, back, entrances, following.Routes, section.Spinner)
			race.AddCheckpoint(top, Vector2.new(width, POOL_DEPTH))
			edge = back + Vector3.zAxis * POOL_DEPTH
		end
		return edge
	end

	-- A big pool round the bottom, rubber rings floating about, the start tower and clouds (none of
	-- it collides).
	local function buildScenery(arena: Model, finish: Vector3)
		local scenery = Geometry.model(arena, "Scenery")
		local poolCenter = finish - Vector3.new(0, 7, 0)
		Geometry.column(scenery, 1, 170, poolCenter - Vector3.new(0, 1, 0), WATER, {
			Name = "Decor",
			CanCollide = false,
			CastShadow = false,
			Transparency = 0.25,
		})
		for _ = 1, 8 do
			local angle = random:NextNumber(0, math.pi * 2)
			local distance = random:NextNumber(40, 75)
			local ringCenter = poolCenter + Vector3.new(math.cos(angle) * distance, 0.6, math.sin(angle) * distance)
			for index = 1, 10 do
				local around = index / 10 * math.pi * 2
				Geometry.ball(
					scenery,
					1.6,
					ringCenter + Vector3.new(math.cos(around) * 2.4, 0, math.sin(around) * 2.4),
					if index % 2 == 0 then WHITE else Theme.Colors.Pink,
					DECOR
				)
			end
		end
		-- The tower the slide starts from.
		local top = center + Vector3.new(0, START_HEIGHT, -14)
		Geometry.column(
			scenery,
			START_HEIGHT + 40,
			26,
			top - Vector3.new(0, START_HEIGHT + 44, 0),
			Color3.fromRGB(255, 196, 222),
			DECOR
		)
		for _ = 1, 30 do
			local spot = center
				+ Vector3.new(
					random:NextNumber(-200, 160),
					random:NextNumber(-20, START_HEIGHT + 30),
					random:NextNumber(-60, 720)
				)
			local near, distance = nearestSample(spot)
			if near and distance < 45 and math.abs(spot.Y - near.Y) < 35 then
				continue -- not in the way of the slides
			end
			Geometry.ellipsoid(
				scenery,
				Vector3.new(random:NextNumber(18, 32), random:NextNumber(8, 12), random:NextNumber(14, 24)),
				CFrame.new(spot),
				WHITE,
				DECOR
			)
		end
	end

	local function setup()
		local arena = context.Arena
		local finish = buildCourse(arena)
		buildScenery(arena, finish)
		race.SpawnPlayers()
	end

	return {
		Setup = setup,
		Start = race.Start,
		Update = function(): boolean?
			race.Update()
			return nil
		end,
		End = race.Stop,
		GetQualified = context.DefaultQualified,
	}
end

return SplashSlide
