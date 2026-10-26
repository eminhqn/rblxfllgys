--!strict
-- TUG OF WOBBLE (Team)
-- Two teams at either end of a long wobbling bridge over goo, with a giant candy rope stretched
-- along it and a flag in the middle. Stand on your team's PULL pads (near your own end of the
-- bridge) to pull: the flag slides towards the team with more of its players pulling. Drag the
-- flag over your line to win. Run across and knock the other team off their pads (into the goo);
-- fall in and you're back on your team's platform. The bridge rocks harder as time goes on. When
-- time runs out the team the flag is nearer wins; dead centre is a tie, and both go through.
--
-- The server counts who's pulling and sets the rope's speed; the rope is a Slider, so clients slide
-- it smoothly between those updates.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local HazardMath = require(Shared.HazardMath)
local Tags = require(Shared.Tags)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 90
local SEGMENTS = 6
local SEGMENT_LENGTH = 20
local BRIDGE_WIDTH = 16
local BRIDGE_HALF = SEGMENTS * SEGMENT_LENGTH / 2 -- the bridge runs from -60 to 60 along Z
local PLATFORM_DEPTH = 26
local PLATFORM_WIDTH = 34
local PULL_FROM, PULL_TO = 38, 58 -- each team's pull pads: this far along from the middle
local WIN_DISTANCE = 22 -- the flag this far towards a team wins it for them
local PULL_SPEED = 5 -- studs/s the flag moves with all of one team pulling and none of the other
local ROPE_LENGTH = 2 * PULL_TO
local ROPE_HEIGHT = 1.6 -- above the bridge
local WOBBLE = { 0.05, 0.11 } -- radians the bridge rocks, at the start and by the end
local WOBBLE_RAMP = { 0.35, 0.8 } -- share of the round over which it grows
local GOO_DEPTH = 14
local KILL_DEPTH = 9

local PLANK = Color3.fromRGB(240, 196, 140)
local PLANK_DARK = Color3.fromRGB(214, 160, 104)
local ROPE = Color3.fromRGB(255, 120, 150)
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type Side = {
	Team: Teams.TeamDef,
	Ends: number, -- -1: the -Z end, 1: the +Z end
}

local TugOfWobble = {}

TugOfWobble.Info = {
	Id = "TugOfWobble",
	DisplayName = "Tug of Wobble",
	Type = "Team",
	Rules = "Stand on your team's PULL pads to drag the flag over your line. Knock the other team off theirs!",
	Duration = DURATION,
	MinPlayers = 4,
	TeamCount = 2,
} :: Types.MiniGameInfo

function TugOfWobble.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local sides: { Side } = {}
	local teamOf: { [Player]: Side } = {}
	local spawnOf: { [Player]: CFrame } = {}
	local segments: { Model } = {}
	local rope: Model? = nil
	local offset, velocity, at = 0, 0, 0 -- the flag: + is towards the +Z team
	local wobble = 1
	local counterText = ""
	local winner: Side? = nil
	local running = false

	local function point(x: number, y: number, z: number): Vector3
		return center + Vector3.new(x, y, z)
	end

	-- The two teams in this round (testing alone still gets two ends).
	local function pickSides()
		local teams = context.Teams or {}
		local order: { Teams.TeamDef } = {}
		for _, def in Teams.List do
			if teams[def.Id] then
				table.insert(order, def)
			end
		end
		for _, def in Teams.List do
			if #order >= 2 then
				break
			end
			if not table.find(order, def) then
				table.insert(order, def)
			end
		end
		for index = 1, 2 do
			table.insert(sides, { Team = order[index], Ends = if index == 1 then -1 else 1 })
		end
	end

	local function sideOfZ(z: number): Side?
		for _, side in sides do
			if side.Ends * z > 0 then
				return side
			end
		end
		return nil
	end

	-- One rocking piece of bridge: planks, rope rails, and its share of the pull pads and lines.
	local function buildSegment(arena: Model, index: number)
		local z = -BRIDGE_HALF + (index - 0.5) * SEGMENT_LENGTH
		local top = point(0, 0, z)
		local segment = Hazards.Swinger(
			arena,
			CFrame.new(top),
			Vector3.new(0, 0, WOBBLE[1]),
			1.4,
			index * 0.9,
			function(model: Model)
				model.Name = "Bridge"
				Geometry.block(
					model,
					Vector3.new(BRIDGE_WIDTH, 2, SEGMENT_LENGTH + 0.4),
					CFrame.new(top - Vector3.new(0, 1, 0)),
					if index % 2 == 0 then PLANK else PLANK_DARK,
					{ Name = "Planks", Material = Enum.Material.WoodPlanks }
				)
				for slat = 0, 4 do
					local slatZ = z - SEGMENT_LENGTH / 2 + 2 + slat * 4
					Geometry.block(
						model,
						Vector3.new(BRIDGE_WIDTH, 0.12, 0.5),
						CFrame.new(point(0, 0.05, slatZ)),
						PLANK_DARK,
						DECOR
					)
				end
				-- Rope rails along both sides (low, so they don't stop anyone falling off).
				for _, edge in { -1, 1 } do
					Geometry.tube(
						model,
						point(edge * (BRIDGE_WIDTH / 2 - 0.3), 1.2, z - SEGMENT_LENGTH / 2),
						point(edge * (BRIDGE_WIDTH / 2 - 0.3), 1.2, z + SEGMENT_LENGTH / 2),
						0.5,
						ROPE,
						{ Name = "Rail", CanCollide = false, CastShadow = false }
					)
				end
				-- Pull pads and the winning lines, in each team's colour.
				for _, side in sides do
					local color = side.Team.Color
					local from, to = side.Ends * PULL_FROM, side.Ends * PULL_TO
					local low, high = math.min(from, to), math.max(from, to)
					local overlapLow = math.max(low, z - SEGMENT_LENGTH / 2)
					local overlapHigh = math.min(high, z + SEGMENT_LENGTH / 2)
					if overlapHigh > overlapLow then
						local pad = Geometry.block(
							model,
							Vector3.new(BRIDGE_WIDTH - 2, 0.16, overlapHigh - overlapLow),
							CFrame.new(point(0, 0.08, (overlapLow + overlapHigh) / 2)),
							color,
							DECOR
						)
						pad.Material = Enum.Material.Neon
						pad.Transparency = 0.35
					end
					local lineZ = side.Ends * WIN_DISTANCE
					if math.abs(lineZ - z) <= SEGMENT_LENGTH / 2 then
						Geometry.block(
							model,
							Vector3.new(BRIDGE_WIDTH, 0.18, 1),
							CFrame.new(point(0, 0.1, lineZ)),
							color,
							DECOR
						)
					end
				end
			end
		)
		table.insert(segments, segment)
	end

	-- A floating sign over a team's pull pads.
	local function pullSign(arena: Model, side: Side)
		local anchor = Geometry.block(
			arena,
			Vector3.one * 0.4,
			CFrame.new(point(0, 9, side.Ends * (PULL_FROM + PULL_TO) / 2)),
			side.Team.Color,
			{ Name = "SignAnchor", Transparency = 1, CanCollide = false }
		)
		local gui: BillboardGui = Ui.new("BillboardGui", {
			Size = UDim2.fromOffset(300, 60),
			LightInfluence = 0,
			MaxDistance = 300,
			Parent = anchor,
		})
		local label = Ui.label(
			gui,
			`{string.upper(side.Team.Id)} PULL!`,
			Theme.Fonts.Display,
			side.Team.Color,
			UDim2.fromScale(1, 1),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		Ui.stroke(label, Theme.Colors.Ink, 3)
	end

	-- The rope, its handles and the flag, built at offset 0 and slid along by clients.
	local function buildRope(arena: Model)
		local model = Geometry.atomicModel("Rope")
		local anchor = Geometry.block(model, Vector3.one * 0.4, CFrame.new(point(0, ROPE_HEIGHT, 0)), ROPE, {
			Name = "Anchor",
			Transparency = 1,
			CanCollide = false,
		})
		model.PrimaryPart = anchor
		local pieces = 8
		for index = 0, pieces - 1 do
			local from = -ROPE_LENGTH / 2 + index * ROPE_LENGTH / pieces
			local to = from + ROPE_LENGTH / pieces
			Geometry.tube(
				model,
				point(0, ROPE_HEIGHT, from),
				point(0, ROPE_HEIGHT, to),
				0.9,
				if index % 2 == 0 then ROPE else Color3.fromRGB(255, 255, 255),
				{ Name = "Rope", CanCollide = false, CastShadow = false }
			)
		end
		-- The flag: a pole and a big triangle-ish banner over the middle of the rope.
		Geometry.column(model, 9, 0.5, point(0, ROPE_HEIGHT, 0), Color3.fromRGB(255, 255, 255), DECOR)
		local flag = Geometry.block(
			model,
			Vector3.new(0.2, 3, 4.5),
			CFrame.new(point(0, ROPE_HEIGHT + 7.4, 2.3)),
			Theme.Colors.Yellow,
			DECOR
		)
		flag.Material = Enum.Material.Neon
		Geometry.ball(model, 1.1, point(0, ROPE_HEIGHT + 9.2, 0), Theme.Colors.Pink, DECOR)
		model:SetAttribute("Axis", Vector3.zAxis)
		model:SetAttribute("Offset", 0)
		model:SetAttribute("Velocity", 0)
		model:SetAttribute("At", 0)
		model:SetAttribute("Min", -WIN_DISTANCE - 1)
		model:SetAttribute("Max", WIN_DISTANCE + 1)
		CollectionService:AddTag(model, Tags.Slider)
		model.Parent = arena
		rope = model
	end

	local function buildEnds(arena: Model)
		for _, side in sides do
			local middleZ = side.Ends * (BRIDGE_HALF + PLATFORM_DEPTH / 2)
			Hazards.Platform(
				arena,
				CFrame.new(point(0, 0, middleZ)),
				Vector3.new(PLATFORM_WIDTH, 4, PLATFORM_DEPTH),
				side.Team.Color:Lerp(Color3.new(1, 1, 1), 0.55),
				`{side.Team.Id}Platform`
			)
			pullSign(arena, side)
		end
		Hazards.Goo(
			arena,
			CFrame.new(point(0, -GOO_DEPTH, 0)),
			Vector2.new(BRIDGE_WIDTH + 140, 2 * (BRIDGE_HALF + PLATFORM_DEPTH) + 40),
			context.Random
		)
	end

	-- Each team lines up on its platform, facing the bridge.
	local function placeTeams()
		local teams = context.Teams or {}
		for _, side in sides do
			local members = teams[side.Team.Id] or {}
			for slot, player in members do
				teamOf[player] = side
				local row = (slot - 1) // 6
				local inRow = math.min(6, #members - row * 6)
				local x = ((slot - 1) % 6 - (inRow - 1) / 2) * 5
				local position = point(x, 0, side.Ends * (BRIDGE_HALF + 6 + row * 5))
				spawnOf[player] = CFrame.lookAt(position, Vector3.new(position.X, position.Y, center.Z))
			end
		end
	end

	local function flagAt(now: number): number
		return HazardMath.SliderOffset(offset, velocity, at, -WIN_DISTANCE - 1, WIN_DISTANCE + 1, now)
	end

	-- Who's pulling for each side right now, and how many of each side are still in.
	local function countPullers(): ({ [Side]: number }, { [Side]: number })
		local pulling: { [Side]: number } = {}
		local present: { [Side]: number } = {}
		for _, side in sides do
			pulling[side], present[side] = 0, 0
		end
		for _, player in context.GetAlive() do
			local side = teamOf[player]
			local root = context.GetRoot(player)
			if not side or not root then
				continue
			end
			present[side] += 1
			local local_ = root.Position - center
			local along = local_.Z * side.Ends
			if
				along >= PULL_FROM - 1
				and along <= PULL_TO + 1
				and math.abs(local_.X) <= BRIDGE_WIDTH / 2 + 0.5
				and local_.Y > -1
				and local_.Y < 7
			then
				pulling[side] += 1
			end
		end
		return pulling, present
	end

	local function setCounter(text: string)
		if text ~= counterText then
			counterText = text
			context.SetCounterText(text)
		end
	end

	local function publishScores(flag: number)
		local scores: { [string]: number } = {}
		for _, side in sides do
			scores[side.Team.Id] = math.floor(math.clamp(flag * side.Ends / WIN_DISTANCE, 0, 1) * 100 + 0.5)
		end
		context.SetTeamScores(scores, 100)
	end

	local function updateWobble(t: number)
		local ramp = math.clamp((t - WOBBLE_RAMP[1]) / (WOBBLE_RAMP[2] - WOBBLE_RAMP[1]), 0, 1)
		local target = math.floor((1 + (WOBBLE[2] / WOBBLE[1] - 1) * ramp) * 10 + 0.5) / 10
		if target == wobble then
			return
		end
		wobble = target
		for _, segment in segments do
			segment:SetAttribute("Amplitude", Vector3.new(0, 0, WOBBLE[1] * wobble))
		end
	end

	local function update(_dt: number): boolean?
		-- Fell in the goo: back to your own platform.
		for _, player in context.GetAlive() do
			local root = context.GetRoot(player)
			local home = spawnOf[player]
			if root and home and root.Position.Y < center.Y - KILL_DEPTH then
				context.SpawnAt(player, home)
			end
		end
		if not running then
			return nil
		end
		local now = context.GetServerTime()
		updateWobble(math.clamp((now - context.GetStartTime()) / DURATION, 0, 1))

		local pulling, present = countPullers()
		local net = 0
		for _, side in sides do
			net += side.Ends * pulling[side] / math.max(present[side], 1)
		end
		local flag = flagAt(now)
		local wanted = net * PULL_SPEED
		if math.abs(wanted - velocity) > 0.01 then
			offset, velocity, at = flag, wanted, now
			local model = rope
			if model then
				model:SetAttribute("Offset", offset)
				model:SetAttribute("At", at)
				model:SetAttribute("Velocity", velocity)
			end
		end
		publishScores(flag)
		local first, second = sides[1], sides[2]
		setCounter(
			`{string.upper(first.Team.Id)} {pulling[first]} PULLING  ·  {string.upper(second.Team.Id)} {pulling[second]} PULLING`
		)
		if math.abs(flag) >= WIN_DISTANCE then
			winner = sideOfZ(flag)
			return true
		end
		return nil
	end

	local function setup()
		local arena = context.Arena
		pickSides()
		for index = 1, SEGMENTS do
			buildSegment(arena, index)
		end
		buildRope(arena)
		buildEnds(arena)
		placeTeams()
		local spots: { CFrame } = {}
		for index, player in context.Players do
			spots[index] = spawnOf[player] or CFrame.new(point(0, 0, -(BRIDGE_HALF + 8)))
		end
		context.SpawnAll(spots)
		setCounter("PULL THE FLAG OVER YOUR LINE!")
		publishScores(0)
	end

	-- Shown during ROUND OVER.
	local function resultText(): string
		local side = winner
		return if side then `{string.upper(side.Team.Id)} WINS!` else "IT'S A TIE!"
	end

	-- The team that won the tug (or the one the flag is nearer at the end) goes through; a dead
	-- heat sends both.
	local function getQualified(): { Player }
		local side = winner
		local qualified: { Player } = {}
		for _, player in context.GetAlive() do
			if not side or teamOf[player] == side then
				table.insert(qualified, player)
			end
		end
		return qualified
	end

	return {
		Setup = setup,
		Start = function()
			running = true
		end,
		Update = update,
		End = function()
			running = false
			local flag = flagAt(context.GetServerTime())
			if not winner and math.abs(flag) >= 1 then
				winner = sideOfZ(flag)
			end
			-- Stop the rope where it is.
			offset, velocity, at = flag, 0, context.GetServerTime()
			local model = rope
			if model then
				model:SetAttribute("Offset", offset)
				model:SetAttribute("At", at)
				model:SetAttribute("Velocity", 0)
			end
			publishScores(flag)
			context.SetCounterText(resultText())
		end,
		GetQualified = getQualified,
	}
end

return TugOfWobble
