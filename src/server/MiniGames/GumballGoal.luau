--!strict
-- GUMBALL GOAL (Team)
-- Two teams on a big candy pitch with a handful of giant gumballs rolling about. Each team has a
-- gumball jar at its own end: push, dive into and kick gumballs into your jar, and stop the other
-- team stealing them for theirs. Every gumball you sink scores a point (it joins the pile in your
-- jar) and a new one drops into the middle. Most gumballs when time's up wins; a tie sends both
-- teams through.
--
-- The gumballs are light, bouncy physics balls run by the server, so nobody can cheat one into a
-- jar. Bumping into one pushes it along with a little hop, diving into one shoves it harder and
-- higher, a kick punts it up and away, and getting under one while it's in the air knocks it back
-- up (a header). The server adds those pushes itself (from where it sees each Bloblet), so they
-- work the same for everyone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local MathUtil = require(Shared.MathUtil)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Geometry = require(script.Parent.Parent.Builders.Geometry)
local Hazards = require(script.Parent.Parent.Builders.Hazards)
local ArenaUtil = require(script.Parent.Parent.Match.ArenaUtil)
local Types = require(script.Parent.Parent.Match.Types)

local DURATION = 90
local PITCH_LENGTH = 140 -- along Z, jar to jar
local PITCH_WIDTH = 84
local WALL_HEIGHT = 16 -- tall glass walls keep kicked gumballs in
local MOUTH_WIDTH = 28 -- each jar's opening in its end wall
local JAR_DEPTH = 16
local KILL_DEPTH = 20

local BALL_DIAMETER = 11
local BALL_RADIUS = BALL_DIAMETER / 2
local MIN_BALLS, MAX_BALLS = 3, 6
local PLAYERS_PER_BALL = 6 -- one more gumball for every this many players
local RESPAWN_DELAY = 1.5 -- after a goal, before a new gumball drops in
local DROP_HEIGHT = 30

-- Pushes the server adds on top of normal physics.
local ROOT_RADIUS = BlobletRig.Dimensions.RootDiameter / 2
local TOUCH_SLACK = 1.4 -- studs of gap that still count as touching (allows for lag)
local PUSH_FACTOR = 1.35 -- a gumball you run into rolls on at up to this times your speed
local DIVE_FACTOR = 1.9
local PUSH_HOP = 16 -- a gumball you bump along the ground hops a little
local DIVE_LIFT = 26 -- diving into one sends it up more
local HEADER_LIFT = 42 -- getting under a gumball that's in the air knocks it back up
local KICK_REACH = 6 -- from your edge to the gumball's edge
local KICK_SPEED = 70
local KICK_LIFT = 40
local MAX_BALL_SPEED = 85
local ROLL_DRAG = 0.2 -- per second: gumballs slowly roll to a stop
-- Light (about as heavy as a Bloblet) and bouncy: density, friction, elasticity, and how much the
-- gumball's own friction / bounciness count against whatever it touches.
local BALL_PHYSICS = PhysicalProperties.new(0.02, 0.3, 0.7, 1, 50)

local FIELD_COLOR = Color3.fromRGB(176, 238, 214)
local LINE_COLOR = Color3.fromRGB(255, 255, 255)
local GLASS_COLOR = Color3.fromRGB(220, 236, 255)
local GUMBALL_COLORS = {
	Color3.fromRGB(255, 84, 120),
	Color3.fromRGB(255, 196, 36),
	Color3.fromRGB(118, 218, 72),
	Color3.fromRGB(150, 110, 255),
	Color3.fromRGB(38, 206, 232),
	Color3.fromRGB(255, 132, 72),
}
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

type Jar = {
	Team: Teams.TeamDef,
	Zone: CFrame, -- a gumball whose middle is inside this box has scored
	ZoneSize: Vector3,
	Back: Vector3, -- floor point at the back of the jar, where the pile grows
	Outward: Vector3, -- from the pitch into the jar
	Pile: number,
}

local GumballGoal = {}

GumballGoal.Info = {
	Id = "GumballGoal",
	DisplayName = "Gumball Goal",
	Type = "Team",
	Rules = "Push, dive and kick the giant gumballs into your team's jar. Most gumballs wins!",
	Duration = DURATION,
	MinPlayers = 4,
	TeamCount = 2,
} :: Types.MiniGameInfo

function GumballGoal.new(context: Types.RoundContext): Types.MiniGame
	local center = context.Origin.Position
	local random = context.Random
	local halfLength = PITCH_LENGTH / 2
	local halfWidth = PITCH_WIDTH / 2

	local balls: { Part } = {}
	local jars: { Jar } = {}
	local counts: { [string]: number } = {}
	local teamOf: { [Player]: Teams.TeamDef } = {}
	local spawnOf: { [Player]: CFrame } = {}
	local lastAction: { [Player]: string } = {}
	local heartbeat: RBXScriptConnection? = nil
	local scoresDirty = true
	local running = false

	local function point(x: number, y: number, z: number): Vector3
		return center + Vector3.new(x, y, z)
	end

	-- The two teams in this round, in a fixed order (the first plays towards -Z). Testing alone
	-- still gets two jars.
	local function pickTeams(): { Teams.TeamDef }
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
		return order
	end

	local function buildPitch(arena: Model)
		local pitch = Geometry.model(arena, "Pitch")
		Hazards.Platform(pitch, CFrame.new(center), Vector3.new(PITCH_WIDTH, 4, PITCH_LENGTH), FIELD_COLOR, "Field")
		-- Halfway line and centre circle.
		Geometry.block(pitch, Vector3.new(PITCH_WIDTH - 2, 0.1, 1), CFrame.new(point(0, 0.08, 0)), LINE_COLOR, DECOR)
		for index = 0, 23 do
			local angle = index / 24 * math.pi * 2
			local spot = point(math.cos(angle) * 16, 0.08, math.sin(angle) * 16) -- just above the team tints
			Geometry.block(
				pitch,
				Vector3.new(1, 0.1, 4.4),
				CFrame.lookAt(spot, spot + Vector3.new(-math.sin(angle), 0, math.cos(angle))),
				LINE_COLOR,
				DECOR
			)
		end

		-- Tall glass walls with candy bumpers along the top, open where the jars are.
		local glass: Geometry.PartOptions = { Name = "Glass", Transparency = 0.6, CastShadow = false }
		for _, side in { -1, 1 } do
			local x = side * (halfWidth + 1)
			Geometry.block(
				pitch,
				Vector3.new(2, WALL_HEIGHT, PITCH_LENGTH + 4),
				CFrame.new(point(x, WALL_HEIGHT / 2, 0)),
				GLASS_COLOR,
				glass
			)
			Geometry.tube(
				pitch,
				point(x, WALL_HEIGHT, -halfLength - 2),
				point(x, WALL_HEIGHT, halfLength + 2),
				2,
				Theme.Colors.Pink,
				{ Name = "Bumper", CastShadow = false }
			)
		end
		local endWidth = (PITCH_WIDTH - MOUTH_WIDTH) / 2
		for _, ends in { -1, 1 } do
			local z = ends * (halfLength + 1)
			for _, side in { -1, 1 } do
				local x = side * (MOUTH_WIDTH / 2 + endWidth / 2)
				Geometry.block(
					pitch,
					Vector3.new(endWidth, WALL_HEIGHT, 2),
					CFrame.new(point(x, WALL_HEIGHT / 2, z)),
					GLASS_COLOR,
					glass
				)
				Geometry.tube(
					pitch,
					point(side * MOUTH_WIDTH / 2, WALL_HEIGHT, z),
					point(side * (halfWidth + 1), WALL_HEIGHT, z),
					2,
					Theme.Colors.Pink,
					{ Name = "Bumper", CastShadow = false }
				)
				-- A slanted block in each corner so gumballs roll out instead of getting stuck.
				Geometry.block(
					pitch,
					Vector3.new(12, WALL_HEIGHT, 2),
					CFrame.new(point(side * (halfWidth - 3.5), WALL_HEIGHT / 2, ends * (halfLength - 3.5)))
						* CFrame.Angles(0, side * ends * math.pi / 4, 0),
					GLASS_COLOR,
					glass
				)
			end
		end
	end

	-- A team's jar behind the opening at one end: a glass box in the team's colour, a floor that
	-- carries on from the pitch, and the team's name floating over it.
	local function buildJar(arena: Model, team: Teams.TeamDef, ends: number): Jar
		local jar = Geometry.model(arena, `{team.Id}Jar`)
		local mouthZ = ends * (halfLength + 2)
		local middleZ = mouthZ + ends * JAR_DEPTH / 2
		-- The floor starts at the pitch's edge so there's no gap under the opening.
		Hazards.Platform(
			jar,
			CFrame.new(point(0, 0, ends * (halfLength + (JAR_DEPTH + 2) / 2))),
			Vector3.new(MOUTH_WIDTH + 4, 4, JAR_DEPTH + 2),
			team.Color:Lerp(Color3.new(1, 1, 1), 0.55),
			"JarFloor"
		)
		local tinted: Geometry.PartOptions = { Name = "JarGlass", Transparency = 0.55, CastShadow = false }
		local glassColor = team.Color:Lerp(Color3.new(1, 1, 1), 0.35)
		for _, side in { -1, 1 } do
			Geometry.block(
				jar,
				Vector3.new(2, WALL_HEIGHT, JAR_DEPTH + 2),
				CFrame.new(point(side * (MOUTH_WIDTH / 2 + 1), WALL_HEIGHT / 2, middleZ)),
				glassColor,
				tinted
			)
		end
		Geometry.block(
			jar,
			Vector3.new(MOUTH_WIDTH + 4, WALL_HEIGHT, 2),
			CFrame.new(point(0, WALL_HEIGHT / 2, mouthZ + ends * (JAR_DEPTH + 1))),
			glassColor,
			tinted
		)
		-- A lid rim round the top of the jar.
		local rimY = WALL_HEIGHT + 0.8
		local corners = {
			point(-MOUTH_WIDTH / 2 - 1, rimY, mouthZ),
			point(MOUTH_WIDTH / 2 + 1, rimY, mouthZ),
			point(MOUTH_WIDTH / 2 + 1, rimY, mouthZ + ends * (JAR_DEPTH + 1)),
			point(-MOUTH_WIDTH / 2 - 1, rimY, mouthZ + ends * (JAR_DEPTH + 1)),
		}
		for index, corner in corners do
			Geometry.tube(jar, corner, corners[index % #corners + 1], 1.8, team.Color, {
				Name = "JarRim",
				CanCollide = false,
				CastShadow = false,
			})
		end
		-- The team's name over the jar.
		local anchor =
			Geometry.block(jar, Vector3.one * 0.4, CFrame.new(point(0, WALL_HEIGHT + 7, middleZ)), team.Color, {
				Name = "LabelAnchor",
				Transparency = 1,
				CanCollide = false,
			})
		local gui: BillboardGui = Ui.new("BillboardGui", {
			Size = UDim2.fromOffset(320, 70),
			LightInfluence = 0,
			MaxDistance = 400,
			Parent = anchor,
		})
		local label = Ui.label(
			gui,
			`{string.upper(team.Id)} JAR`,
			Theme.Fonts.Display,
			team.Color,
			UDim2.fromScale(1, 1),
			UDim2.fromScale(0.5, 0.5),
			Vector2.new(0.5, 0.5)
		)
		Ui.stroke(label, Theme.Colors.Ink, 3)
		-- The team's half of the pitch is tinted its colour.
		Geometry.block(
			jar,
			Vector3.new(PITCH_WIDTH - 4, 0.1, halfLength - 4),
			CFrame.new(point(0, 0.05, ends * halfLength / 2)),
			team.Color:Lerp(FIELD_COLOR, 0.65),
			DECOR
		)

		counts[team.Id] = 0
		return {
			Team = team,
			Zone = CFrame.new(point(0, WALL_HEIGHT / 2, mouthZ + ends * (JAR_DEPTH / 2 + 1))),
			ZoneSize = Vector3.new(MOUTH_WIDTH + 2, WALL_HEIGHT + 10, JAR_DEPTH),
			Back = point(0, 0, mouthZ + ends * (JAR_DEPTH - 1)),
			Outward = Vector3.new(0, 0, ends),
			Pile = 0,
		}
	end

	-- Each team lines up in front of its own jar, facing the middle.
	local function placeTeams(order: { Teams.TeamDef })
		local teams = context.Teams or {}
		for index, def in order do
			local ends = if index == 1 then -1 else 1
			local members = teams[def.Id] or {}
			for slot, player in members do
				teamOf[player] = def
				local row = (slot - 1) // 8
				local inRow = math.min(8, #members - row * 8)
				local x = ((slot - 1) % 8 - (inRow - 1) / 2) * 6
				local position = point(x, 0, ends * (halfLength - 14 - row * 6))
				spawnOf[player] = CFrame.lookAt(position, Vector3.new(position.X, position.Y, center.Z))
			end
		end
	end

	local function makeBall(position: Vector3, anchored: boolean): Part
		local ball = Instance.new("Part")
		ball.Name = "Gumball"
		ball.Shape = Enum.PartType.Ball
		ball.Size = Vector3.one * BALL_DIAMETER
		ball.Color = GUMBALL_COLORS[random:NextInteger(1, #GUMBALL_COLORS)]
		ball.Material = Enum.Material.SmoothPlastic
		ball.Reflectance = 0.2
		ball.TopSurface = Enum.SurfaceType.Smooth
		ball.BottomSurface = Enum.SurfaceType.Smooth
		ball.CustomPhysicalProperties = BALL_PHYSICS
		ball.CFrame = CFrame.new(position)
		ball.Anchored = anchored
		-- A white shine stuck to it shows it rolling.
		local shine = Instance.new("Part")
		shine.Name = "Shine"
		shine.Shape = Enum.PartType.Ball
		shine.Size = Vector3.one * 2.2
		shine.Color = Color3.new(1, 1, 1)
		shine.Material = Enum.Material.SmoothPlastic
		shine.CanCollide = false
		shine.CanQuery = false
		shine.CanTouch = false
		shine.Massless = true
		shine.CastShadow = false
		shine.CFrame = ball.CFrame * CFrame.new(-1.8, BALL_RADIUS - 1.4, -2.6)
		shine.Parent = ball
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = ball
		weld.Part1 = shine
		weld.Parent = ball
		ball.Parent = context.Arena
		if not anchored then
			pcall(function()
				ball:SetNetworkOwner(nil) -- the server runs every gumball
			end)
		end
		table.insert(balls, ball)
		return ball
	end

	local function dropBall()
		if not running then
			return
		end
		makeBall(point(random:NextNumber(-20, 20), DROP_HEIGHT, random:NextNumber(-10, 10)), false)
	end

	-- A little gumball joins the pile in the jar (decoration).
	local function addToPile(jar: Jar, color: Color3)
		local slot = jar.Pile
		jar.Pile += 1
		local perRow = 7
		local layer = slot // (perRow * 3)
		local inLayer = slot % (perRow * 3)
		local x = (inLayer % perRow - (perRow - 1) / 2) * 3.4
		local back = (inLayer // perRow) * 3.2
		local position = jar.Back - jar.Outward * back + Vector3.new(x, 1.6 + layer * 3, 0)
		Geometry.ball(context.Arena, 3.2, position, color, DECOR)
	end

	local function score(jar: Jar, index: number)
		local ball = balls[index]
		table.remove(balls, index)
		counts[jar.Team.Id] += 1
		scoresDirty = true
		addToPile(jar, ball.Color)
		ball:Destroy()
		context.Announce(`{string.upper(jar.Team.Id)} SCORES!`, jar.Team.Id)
		task.delay(RESPAWN_DELAY, dropBall)
	end

	local function kick(root: BasePart)
		local look = MathUtil.flat(root.CFrame.LookVector)
		if look.Magnitude < 1e-3 then
			return
		end
		look = look.Unit
		for _, ball in balls do
			local offset = MathUtil.flat(ball.Position - root.Position)
			local gap = offset.Magnitude - BALL_RADIUS - ROOT_RADIUS
			if gap <= KICK_REACH and offset.Magnitude > 0.1 and offset.Unit:Dot(look) > 0.3 then
				local direction = (offset.Unit + look).Unit
				ball.AssemblyLinearVelocity = direction * KICK_SPEED + Vector3.new(0, KICK_LIFT, 0)
			end
		end
	end

	-- Every frame on the server: scoring, rolling drag, and the pushes from Bloblets.
	local function stepBalls(dt: number)
		local alive = context.GetAlive()
		for _, player in alive do
			local character = player.Character
			local action = if character then character:GetAttribute("Action") else nil
			local actionName = if typeof(action) == "string" then action else "None"
			if actionName == "Kick" and lastAction[player] ~= "Kick" then
				local root = context.GetRoot(player)
				if root then
					kick(root)
				end
			end
			lastAction[player] = actionName
		end

		for index = #balls, 1, -1 do
			local ball = balls[index]
			if not ball.Parent then
				table.remove(balls, index)
				continue
			end
			local position = ball.Position
			if position.Y < center.Y - KILL_DEPTH then
				-- Somehow got out: a new one drops in instead.
				table.remove(balls, index)
				ball:Destroy()
				task.delay(RESPAWN_DELAY, dropBall)
				continue
			end
			local scored = false
			for _, jar in jars do
				if ArenaUtil.InBox(jar.Zone, jar.ZoneSize, position) then
					score(jar, index)
					scored = true
					break
				end
			end
			if scored or ball.Anchored then
				continue
			end

			local velocity = ball.AssemblyLinearVelocity
			local changed = false
			local rolling = MathUtil.flat(velocity)
			if rolling.Magnitude > 0.1 then
				velocity -= rolling * (1 - math.exp(-ROLL_DRAG * dt))
				changed = true
			end
			local onGround = position.Y - center.Y < BALL_RADIUS + 0.6
			for _, player in alive do
				local root = context.GetRoot(player)
				if not root then
					continue
				end
				local rootPosition = root.Position
				local gap = (position - rootPosition).Magnitude - BALL_RADIUS - ROOT_RADIUS
				if gap > TOUCH_SLACK then
					continue
				end
				local rootVelocity = root.AssemblyLinearVelocity
				local character = player.Character
				local diving = character ~= nil and character:GetAttribute("Action") == "Dive"

				-- A header: the gumball is in the air above you, so it bounces back up off you.
				if position.Y - BALL_RADIUS > rootPosition.Y - 0.5 then
					local lift = HEADER_LIFT + math.max(rootVelocity.Y, 0) * 0.5
					if velocity.Y < lift then
						velocity = Vector3.new(velocity.X, lift, velocity.Z)
						changed = true
					end
				end

				-- Running (or diving) into it: it rolls on ahead of you, with a little hop.
				local offset = MathUtil.flat(position - rootPosition)
				local distance = offset.Magnitude
				if distance < 0.1 then
					continue
				end
				local toward = offset / distance
				local along = MathUtil.flat(rootVelocity):Dot(toward)
				local wanted = along * (if diving then DIVE_FACTOR else PUSH_FACTOR)
				local current = MathUtil.flat(velocity):Dot(toward)
				if along > 1 and current < wanted then
					velocity += toward * (wanted - current)
					local hop = if diving then DIVE_LIFT elseif onGround then PUSH_HOP else 0
					if velocity.Y < hop then
						velocity = Vector3.new(velocity.X, hop, velocity.Z)
					end
					changed = true
				end
			end
			if changed then
				ball.AssemblyLinearVelocity = MathUtil.clampMagnitude(velocity, MAX_BALL_SPEED)
			end
		end
	end

	local function setup()
		local arena = context.Arena
		buildPitch(arena)
		local order = pickTeams()
		for index, def in order do
			table.insert(jars, buildJar(arena, def, if index == 1 then -1 else 1))
		end
		placeTeams(order)

		-- Gumballs wait on the halfway line (held still until GO).
		local count = math.clamp(MIN_BALLS + #context.Players // PLAYERS_PER_BALL, MIN_BALLS, MAX_BALLS)
		for index = 1, count do
			local x = (index - (count + 1) / 2) * (PITCH_WIDTH - 20) / math.max(count - 1, 1)
			makeBall(point(x, BALL_RADIUS + 0.1, 0), true)
		end

		local spots: { CFrame } = {}
		for index, player in context.Players do
			spots[index] = spawnOf[player] or CFrame.new(point(0, 0, -halfLength + 14))
		end
		context.SpawnAll(spots)
		context.SetCounterText("MOST GUMBALLS WINS")
		context.SetTeamScores(counts)
		scoresDirty = false
	end

	local function start()
		running = true
		for _, ball in balls do
			ball.Anchored = false
			pcall(function()
				ball:SetNetworkOwner(nil)
			end)
		end
		heartbeat = RunService.Heartbeat:Connect(stepBalls)
	end

	local function update(_dt: number): boolean?
		for _, player in context.GetAlive() do
			local root = context.GetRoot(player)
			local home = spawnOf[player]
			if root and home and root.Position.Y < center.Y - KILL_DEPTH then
				context.SpawnAt(player, home)
			end
		end
		if scoresDirty then
			scoresDirty = false
			context.SetTeamScores(counts)
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
		for _, jar in jars do
			if best > 0 and counts[jar.Team.Id] == best then
				table.insert(winners, string.upper(jar.Team.Id))
			end
		end
		return if #winners == 1 then `{winners[1]} WINS!` else "IT'S A TIE!"
	end

	-- The team(s) with the most gumballs go through. If nobody scored, everyone does.
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
			local connection = heartbeat
			if connection then
				connection:Disconnect()
				heartbeat = nil
			end
			for _, ball in balls do
				ball.Anchored = true
			end
			context.SetTeamScores(counts)
			context.SetCounterText(resultText())
		end,
		GetQualified = getQualified,
	}
end

return GumballGoal
