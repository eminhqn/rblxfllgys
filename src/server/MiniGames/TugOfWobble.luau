--!strict
-- TUG OF WOBBLE (Team)
-- Two teams at either end of a long wobbling bridge over goo, with a giant candy rope stretched
-- along it and a flag in the middle. GRAB the rope on your team's side of the flag to take hold,
-- then MASH JUMP to pull: the faster your team tugs (for its size), the faster the flag slides
-- your way. Drag the flag over your line to win. While you hold on you can't walk, and you're towed
-- along with the rope; GRAB again (or dive, or kick) to let go. Get knocked over, grabbed or shoved
-- away from the rope and you lose your grip, so run over and knock the other team off it (into the
-- goo: you're back on your team's platform). The bridge rocks harder as time goes on. When time
-- runs out the team the flag is nearer wins; dead centre is a tie, and both go through.
--
-- The rope is a Slider, so clients slide it smoothly. The server takes hold of the rope for you
-- (ActionService's grab hook), counts your tugs (RequestPull) and sets the rope's speed, and tells
-- each holder which way to face (OnRope) and how fast they're towed (Tow).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local HazardMath = require(Shared.HazardMath)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)
local Tags = require(Shared.Tags)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Bots = require(script.Parent.Parent.Bots.Bots)
local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local Types = require(script.Parent.Parent.Match.Types)
local ActionService = require(script.Parent.Parent.Services.ActionService)

local DURATION = 90
local SEGMENTS = 6
local SEGMENT_LENGTH = 20
local BRIDGE_WIDTH = 16
local BRIDGE_HALF = SEGMENTS * SEGMENT_LENGTH / 2 -- the bridge runs from -60 to 60 along Z
local PLATFORM_DEPTH = 26
local PLATFORM_WIDTH = 34
local WIN_DISTANCE = 24 -- the flag this far towards a team wins it for them
local ROPE_HALF = 52 -- the rope reaches this far either side of the flag
local ROPE_HEIGHT = 2.4 -- above the bridge: about where a Bloblet's hands are
local FLAG_GAP = 3 -- nobody can hold the rope this close to the flag
local ROPE_REACH = 6 -- sideways from the rope (to your middle) that a GRAB takes hold of it
local LET_GO_REACH = 9 -- shoved further than this from the rope and you lose your grip
local PROMPT_REACH = 12 -- this close to your part of the rope you're told to GRAB it
-- Pulling: each tug counts for TAP_MEMORY seconds. A team's pull is its holders' tugs a second
-- (each up to MAX_TAPS) shared over everyone on the team; the flag moves PULL_PER_TAP studs/s for
-- each tug a second of difference between the teams.
local TAP_MEMORY = 0.6
local MIN_TAP_GAP = 1 / 14 -- tugs closer together than this are ignored
local MAX_TAPS = 12
local PULL_PER_TAP = 0.6
local MAX_SPEED = 7 -- studs/s
local PULLING_RATE = 1.5 -- tugs a second that count as "pulling" on the counter
local WOBBLE = { 0.05, 0.11 } -- radians the bridge rocks, at the start and by the end
local WOBBLE_RAMP = { 0.35, 0.8 } -- share of the round over which it grows
local GOO_DEPTH = 14
local KILL_DEPTH = 9
local BOT_TUGS = { 4.5, MAX_TAPS } -- tugs a second a bot manages, clumsiest to sharpest

local PLANK = Color3.fromRGB(240, 196, 140)
local PLANK_DARK = Color3.fromRGB(214, 160, 104)
local ROPE = Color3.fromRGB(255, 120, 150)
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type Side = {
	Team: Teams.TeamDef,
	Ends: number, -- -1: the -Z end, 1: the +Z end
}

type Tugs = {
	Heat: number, -- recent tugs, each fading over TAP_MEMORY
	At: number, -- os.clock() Heat was worked out at
	Last: number, -- os.clock() of the last tug that counted
}

local TugOfWobble = {}

TugOfWobble.Info = {
	Id = "TugOfWobble",
	DisplayName = "Tug of Wobble",
	Type = "Team",
	Rules = "GRAB the rope on your side and MASH JUMP to pull the flag over your line!",
	Duration = DURATION,
	MinPlayers = 4,
	TeamCount = 2,
} :: Types.MiniGameInfo

function TugOfWobble.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local sides: { Side } = {}
	local teamOf: { [Player]: Side } = {}
	local spawnOf: { [Player]: CFrame } = {}
	local holders: { [Player]: Side } = {}
	local tugs: { [Player]: Tugs } = {}
	local prompts: { [Player]: string? } = {}
	local botSpots: { [Player]: Vector2 } = {} -- where along its part of the rope (X: from the flag, Y: sideways)
	local botTuggedAt: { [Player]: number } = {}
	local segments: { Model } = {}
	local rope: Model? = nil
	local offset, velocity, at = 0, 0, 0 -- the flag: + is towards the +Z team
	local wobble = 1
	local counterText = ""
	local winner: Side? = nil
	local running = false
	local pullConnection: RBXScriptConnection? = nil
	local actedConnection: Signal.Connection? = nil

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

	-- One rocking piece of bridge: planks, rope rails in the colour of the team at that end, and
	-- its share of the winning lines.
	local function buildSegment(arena: Model, index: number)
		local z = -BRIDGE_HALF + (index - 0.5) * SEGMENT_LENGTH
		local top = point(0, 0, z)
		local endSide = sideOfZ(z)
		local railColor = if endSide then endSide.Team.Color else ROPE
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
						railColor,
						{ Name = "Rail", CanCollide = false, CastShadow = false }
					)
				end
				-- The winning lines, in each team's colour.
				for _, side in sides do
					local lineZ = side.Ends * WIN_DISTANCE
					if math.abs(lineZ - z) <= SEGMENT_LENGTH / 2 then
						local line = Geometry.block(
							model,
							Vector3.new(BRIDGE_WIDTH, 0.18, 1.2),
							CFrame.new(point(0, 0.1, lineZ)),
							side.Team.Color,
							DECOR
						)
						line.Material = Enum.Material.Neon
					end
				end
			end
		)
		table.insert(segments, segment)
	end

	-- A floating sign over a team's half of the bridge.
	local function pullSign(arena: Model, side: Side)
		local anchor = Geometry.block(
			arena,
			Vector3.one * 0.4,
			CFrame.new(point(0, 10, side.Ends * (BRIDGE_HALF - 14))),
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

	-- The rope, its knots and the flag, built at offset 0 and slid along by clients.
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
			local from = -ROPE_HALF + index * 2 * ROPE_HALF / pieces
			local to = from + 2 * ROPE_HALF / pieces
			Geometry.tube(
				model,
				point(0, ROPE_HEIGHT, from),
				point(0, ROPE_HEIGHT, to),
				0.9,
				if index % 2 == 0 then ROPE else Color3.fromRGB(255, 255, 255),
				{ Name = "Rope", CanCollide = false, CastShadow = false }
			)
		end
		-- Knots along each team's half (handholds) and a big one at each end.
		for along = 8, ROPE_HALF - 4, 8 do
			for _, ends in { -1, 1 } do
				Geometry.ball(model, 1.3, point(0, ROPE_HEIGHT, ends * along), ROPE, DECOR)
			end
		end
		for _, ends in { -1, 1 } do
			Geometry.ball(model, 2, point(0, ROPE_HEIGHT, ends * ROPE_HALF), Color3.fromRGB(255, 255, 255), DECOR)
		end
		-- The flag: a pole and a big banner over the middle of the rope.
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

	-- Whether a Bloblet at `position` is next to `side`'s part of the rope (between the flag and
	-- that team's end of it), within `reach` of it sideways.
	local function besideRope(side: Side, position: Vector3, flag: number, reach: number): boolean
		local local_ = position - center
		local along = (local_.Z - flag) * side.Ends
		local height = local_.Y - ROPE_HEIGHT
		return along >= FLAG_GAP
			and along <= ROPE_HALF + 1
			and math.abs(local_.X) <= reach
			and height > -5
			and height < 4
	end

	local function grabbed(character: Model): boolean
		local by = character:GetAttribute("GrabbedBy")
		return typeof(by) == "number" and by ~= 0
	end

	local function setPrompt(player: Player, prompt: string?)
		if prompts[player] == prompt then
			return
		end
		prompts[player] = prompt
		player:SetAttribute(Match.PlayerAttr.RoundPrompt, prompt)
	end

	local function takeHold(player: Player, side: Side)
		holders[player] = side
		local character = player.Character
		if character then
			character:SetAttribute("OnRope", Vector3.new(0, 0, -side.Ends)) -- facing the flag
			character:SetAttribute("Tow", Vector3.new(0, 0, velocity))
		end
		setPrompt(player, "Pull")
	end

	local function letGo(player: Player)
		if not holders[player] then
			return
		end
		holders[player] = nil
		tugs[player] = nil
		local character = player.Character
		if character then
			character:SetAttribute("OnRope", nil)
			character:SetAttribute("Tow", nil)
		end
	end

	-- GRAB next to your part of the rope takes hold of it; GRAB again lets go. Anywhere else it's
	-- a normal grab (so you can grab the other team off the rope).
	local function onGrab(player: Player, root: BasePart, pressed: boolean): boolean
		if not running then
			return false
		end
		if holders[player] then
			if pressed then
				letGo(player)
			end
			return true
		end
		local side = teamOf[player]
		local character = player.Character
		if
			not side
			or not character
			or character:GetAttribute("Ragdolled") == true
			or grabbed(character)
			or not besideRope(side, root.Position, flagAt(context.GetServerTime()), ROPE_REACH)
		then
			return false
		end
		takeHold(player, side)
		return true
	end

	-- Diving, kicking or slapping lets go of the rope.
	local function onActed(player: Player, action: string)
		if action ~= "Grab" then
			letGo(player)
		end
	end

	-- One tug from a holder (a JUMP press while holding the rope).
	local function onPull(player: Player)
		if not running or not holders[player] then
			return
		end
		local now = os.clock()
		local record = tugs[player]
		if not record then
			record = { Heat = 0, At = now, Last = -math.huge }
			tugs[player] = record
		end
		if now - record.Last < MIN_TAP_GAP then
			return -- faster than anyone can mash
		end
		record.Last = now
		record.Heat = record.Heat * math.exp(-(now - record.At) / TAP_MEMORY) + 1
		record.At = now
	end

	-- Tugs a second a holder is managing right now (it fades away once they stop).
	local function tugRate(player: Player, now: number): number
		local record = tugs[player]
		if not record then
			return 0
		end
		local rate = record.Heat * math.exp(-(now - record.At) / TAP_MEMORY) / TAP_MEMORY
		return math.min(rate, MAX_TAPS)
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

	-- Starts the rope sliding at `speed` from `flag`, and tows everyone holding it along.
	local function setRopeSpeed(flag: number, speed: number, now: number)
		offset, velocity, at = flag, speed, now
		local model = rope
		if model then
			model:SetAttribute("Offset", offset)
			model:SetAttribute("At", at)
			model:SetAttribute("Velocity", velocity)
		end
		for player in holders do
			local character = player.Character
			if character then
				character:SetAttribute("Tow", Vector3.new(0, 0, velocity))
			end
		end
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
				letGo(player)
				context.SpawnAt(player, home)
			end
		end
		if not running then
			return nil
		end
		local now = context.GetServerTime()
		local clock = os.clock()
		local flag = flagAt(now)
		updateWobble(math.clamp((now - context.GetStartTime()) / DURATION, 0, 1))

		-- Who's holding on and how hard each team is pulling. Holders who've been knocked over,
		-- grabbed or shoved away from the rope lose their grip.
		local strength: { [Side]: number } = {}
		local present: { [Side]: number } = {}
		local pulling: { [Side]: number } = {}
		for _, side in sides do
			strength[side], present[side], pulling[side] = 0, 0, 0
		end
		for _, player in context.GetAlive() do
			local side = teamOf[player]
			local root = context.GetRoot(player)
			local character = player.Character
			if not side or not root or not character then
				letGo(player)
				setPrompt(player, nil)
				continue
			end
			present[side] += 1
			if
				holders[player]
				and (
					character:GetAttribute("Ragdolled") == true
					or grabbed(character)
					or not besideRope(side, root.Position, flag, LET_GO_REACH)
				)
			then
				letGo(player)
			end
			if holders[player] then
				local rate = tugRate(player, clock)
				strength[side] += rate
				if rate >= PULLING_RATE then
					pulling[side] += 1
				end
				setPrompt(player, "Pull")
			elseif besideRope(side, root.Position, flag, PROMPT_REACH) then
				setPrompt(player, "GrabRope")
			else
				setPrompt(player, nil)
			end
		end

		local wanted = 0
		for _, side in sides do
			wanted += side.Ends * strength[side] / math.max(present[side], 1) * PULL_PER_TAP
		end
		wanted = math.clamp(math.round(wanted * 10) / 10, -MAX_SPEED, MAX_SPEED)
		if wanted ~= velocity then
			setRopeSpeed(flag, wanted, now)
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

	-- Bots run to a spot beside their part of the rope, GRAB it and pull, steadily (sharper bots
	-- tug faster, though not quite as fast as a player mashing hard).
	local function botGoal(bot: Player): Types.BotGoal?
		local root = context.GetRoot(bot)
		local side = teamOf[bot]
		if not root or not side or not running then
			return nil
		end
		local clock = os.clock()
		if holders[bot] then
			local rate = BOT_TUGS[1] + (BOT_TUGS[2] - BOT_TUGS[1]) * Bots.SkillOf(bot)
			local record = tugs[bot]
			if not record then
				record = { Heat = 0, At = clock, Last = clock }
				tugs[bot] = record
			end
			local dt = math.min(clock - (botTuggedAt[bot] or clock), 0.5)
			record.Heat = record.Heat * math.exp(-(clock - record.At) / TAP_MEMORY) + rate * dt
			record.At = clock
			record.Last = clock
			botTuggedAt[bot] = clock
			return { Stop = true, Calm = true }
		end
		botTuggedAt[bot] = nil
		local spot = botSpots[bot]
		if not spot then
			local random = context.Random
			spot = Vector2.new(
				random:NextNumber(6, 30),
				random:NextNumber(1, 2.5) * (if random:NextNumber() < 0.5 then -1 else 1)
			)
			botSpots[bot] = spot
		end
		local flag = flagAt(context.GetServerTime())
		local along = math.clamp(spot.X, FLAG_GAP + 2, ROPE_HALF - 4)
		local target = point(spot.Y, 0, flag + side.Ends * along)
		-- Next to the rope: GRAB, letting go of the button now and then to try again.
		local beside = besideRope(side, root.Position, flag, ROPE_REACH - 1)
		local press = beside and math.floor(clock * 4) % 2 == 0
		return { MoveTo = target, Within = 1.5, Grab = press, Calm = beside }
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
		setCounter("GRAB THE ROPE AND MASH JUMP!")
		publishScores(0)
	end

	local function start()
		running = true
		ActionService.SetGrabHook(onGrab)
		actedConnection = ActionService.Acted:Connect(onActed)
		pullConnection = Remotes.Event("RequestPull").OnServerEvent:Connect(onPull)
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
		Start = start,
		Update = update,
		End = function()
			running = false
			ActionService.SetGrabHook(nil)
			local acted = actedConnection
			if acted then
				acted:Disconnect()
				actedConnection = nil
			end
			local pull = pullConnection
			if pull then
				pull:Disconnect()
				pullConnection = nil
			end
			for player in table.clone(holders) do
				letGo(player)
			end
			table.clear(botSpots)
			table.clear(botTuggedAt)
			for _, player in context.Players do
				setPrompt(player, nil)
			end
			local now = context.GetServerTime()
			local flag = flagAt(now)
			if not winner and math.abs(flag) >= 1 then
				winner = sideOfZ(flag)
			end
			setRopeSpeed(flag, 0, now) -- stop the rope where it is
			publishScores(flag)
			context.SetCounterText(resultText())
		end,
		GetQualified = getQualified,
		BotGoal = botGoal,
	}
end

return TugOfWobble
