--!strict
-- The winner's party at the lobby podium, for everyone in the server while the Winner phase lasts:
--   * a big gold crown floats and spins over the winner's head, sparkling, in a beam of light
--   * confetti cannons on both sides of the podium go off a few times
--   * fireworks launch from behind the podium and burst over it (Config.Cinematics.Fireworks)
-- Everything is local to this client (anchored parts nothing can touch) and is cleared away when
-- the phase ends. If nobody won the match, there's no party.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Competitors = require(Shared.Competitors)
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Theme = require(Shared.Theme)

local Effects = require(script.Parent.Effects)
local MatchClient = require(script.Parent.MatchClient)
local Sfx = require(script.Parent.Sfx)

local Celebration = {}

type Crown = {
	Parts: { BasePart },
	Offsets: { CFrame },
	CFrames: { CFrame }, -- reused every frame
	Sparkles: ParticleEmitter,
	Glow: PointLight,
}

local Attr = Match.Attr

local GOLD = Color3.fromRGB(255, 205, 64)
local GOLD_DARK = Color3.fromRGB(226, 160, 30)
local WHITE = Color3.new(1, 1, 1)
local PARTY_COLORS = {
	Theme.Colors.Pink,
	Theme.Colors.Aqua,
	Theme.Colors.Yellow,
	Theme.Colors.Purple,
	Theme.Colors.Lime,
	Theme.Colors.Orange,
}

local START_DELAY = 0.9 -- for players in the match: once the transition wipe has cleared
local CROWN_ABOVE_ROOT = 6.2 -- clears the tallest hat
local CROWN_SPIN = 1.6 -- radians per second
local FOLLOW_RANGE = 200 -- the crown follows the winner anywhere in the lobby
local BEAM_HEIGHT = 70
local BEAM_TRANSPARENCY = 0.88
local CANNON_TIMES = { 0, 2.4, 4.8 }
local CANNON_SIDE = 9 -- studs either side of the podium's centre
local FIREWORK_START = 0.4
local FIREWORK_SPACING = 0.55
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- stands a cylinder (axis X) on its end

local token = 0
local container: Folder? = nil
local crown: Crown? = nil
local crownShown = false
local winnerSpot = CFrame.identity
local winnerId = 0
local renderConnection: RBXScriptConnection? = nil
local random = Random.new()

local function decorPart(
	parent: Instance,
	name: string,
	shape: Enum.PartType,
	size: Vector3,
	color: Color3,
	material: Enum.Material?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

-- A gold band with five round points and a ring of glowing gems.
local function buildCrown(parent: Instance): Crown
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local function add(part: BasePart, offset: CFrame)
		part.Transparency = 1 -- shown once the winner is in the lobby
		table.insert(parts, part)
		table.insert(offsets, offset)
	end
	local band = decorPart(parent, "CrownBand", Enum.PartType.Cylinder, Vector3.new(1.1, 3.2, 3.2), GOLD)
	band.Reflectance = 0.15
	add(band, UPRIGHT)
	add(
		decorPart(parent, "CrownRim", Enum.PartType.Cylinder, Vector3.new(0.3, 3.45, 3.45), GOLD_DARK),
		CFrame.new(0, -0.55, 0) * UPRIGHT
	)
	for index = 1, 5 do
		local angle = index / 5 * math.pi * 2
		local around = Vector3.new(math.cos(angle), 0, math.sin(angle))
		add(
			decorPart(parent, "CrownPoint", Enum.PartType.Ball, Vector3.one * 0.75, GOLD),
			CFrame.new(around * 1.45 + Vector3.new(0, 0.95, 0))
		)
		add(
			decorPart(
				parent,
				"CrownGem",
				Enum.PartType.Ball,
				Vector3.one * 0.5,
				PARTY_COLORS[index],
				Enum.Material.Neon
			),
			CFrame.new(around * 1.57)
		)
	end

	local attachment = Instance.new("Attachment")
	attachment.Parent = band
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Texture = SPARKLE_TEXTURE
	sparkles.Rate = 16
	sparkles.Lifetime = NumberRange.new(0.6, 1.2)
	sparkles.Speed = NumberRange.new(2, 4)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
	sparkles.LightEmission = 1
	sparkles.Color = ColorSequence.new(GOLD, WHITE)
	sparkles.Enabled = false
	sparkles.Parent = attachment
	local glow = Instance.new("PointLight")
	glow.Color = GOLD
	glow.Brightness = 2
	glow.Range = 14
	glow.Enabled = false
	glow.Parent = band
	return { Parts = parts, Offsets = offsets, CFrames = {}, Sparkles = sparkles, Glow = glow }
end

local function setCrownShown(current: Crown, shown: boolean)
	crownShown = shown
	for _, part in current.Parts do
		part.Transparency = if shown then 0 else 1
	end
	current.Sparkles.Enabled = shown
	current.Glow.Enabled = shown
end

local function winnerRoot(): BasePart?
	local character = Competitors.CharacterOf(winnerId) -- the winner may be a bot
	local root = if character then character.PrimaryPart else nil
	if root and (root.Position - winnerSpot.Position).Magnitude < FOLLOW_RANGE then
		return root
	end
	return nil
end

local function stepCrown()
	local current = crown
	if not current then
		return
	end
	local root = winnerRoot()
	if (root ~= nil) ~= crownShown then
		setCrownShown(current, root ~= nil)
	end
	if not root then
		return
	end
	local now = os.clock()
	local pose = CFrame.new(root.Position + Vector3.new(0, CROWN_ABOVE_ROOT + math.sin(now * 2.4) * 0.35, 0))
		* CFrame.Angles(0, (now * CROWN_SPIN) % (math.pi * 2), 0)
		* CFrame.Angles(math.sin(now * 1.7) * 0.08, 0, 0)
	for index, offset in current.Offsets do
		current.CFrames[index] = pose * offset
	end
	Workspace:BulkMoveTo(current.Parts, current.CFrames, Enum.BulkMoveMode.FireCFrameChanged)
end

-- A soft column of light standing on the podium.
local function buildBeam(parent: Instance)
	local beam = decorPart(
		parent,
		"LightBeam",
		Enum.PartType.Cylinder,
		Vector3.new(BEAM_HEIGHT, 10, 10),
		GOLD:Lerp(WHITE, 0.4),
		Enum.Material.Neon
	)
	beam.CFrame = CFrame.new(winnerSpot.Position + Vector3.new(0, BEAM_HEIGHT / 2, 0)) * UPRIGHT
	beam.Transparency = 1
	TweenService:Create(beam, TweenInfo.new(1.2), { Transparency = BEAM_TRANSPARENCY }):Play()
end

local function fireCannons()
	local right = winnerSpot.RightVector
	for _, side in { -1, 1 } do
		local origin = winnerSpot.Position + right * side * CANNON_SIDE + Vector3.new(0, 0.5, 0)
		-- Up, leaning in over the podium and a little towards the crowd.
		local aim = Vector3.yAxis - right * side * 0.35 + winnerSpot.LookVector * 0.2
		Effects.Burst(origin, {
			Count = 45,
			Colors = PARTY_COLORS,
			Size = Vector3.new(0.6, 0.08, 0.9),
			Speed = 75,
			Direction = aim,
			Spread = 0.3,
			Gravity = 35,
			Drag = 1.4,
			Life = 3.2,
		})
		Sfx.PlayAt("Cannon", origin)
	end
end

-- A quick flash of coloured light where a firework bursts.
local function flash(parent: Instance, position: Vector3, color: Color3)
	local holder = Instance.new("Attachment")
	holder.WorldPosition = position
	holder.Parent = Workspace.Terrain
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 6
	light.Range = 50
	light.Parent = holder
	local fade = TweenService:Create(light, TweenInfo.new(0.7, Enum.EasingStyle.Quad), { Brightness = 0 })
	fade.Completed:Once(function()
		holder:Destroy()
	end)
	fade:Play()
	-- Gone with the rest of the party if the phase ends first.
	parent.Destroying:Once(function()
		holder:Destroy()
	end)
end

local function launchFirework(myToken: number)
	local parent = container
	if not parent then
		return
	end
	local right = winnerSpot.RightVector
	local back = -winnerSpot.LookVector -- behind the podium, away from the crowd
	local launch = winnerSpot.Position + right * random:NextNumber(-28, 28) + back * random:NextNumber(6, 16)
	local burstAt = launch
		+ right * random:NextNumber(-8, 8)
		+ back * random:NextNumber(4, 14)
		+ Vector3.new(0, random:NextNumber(36, 54), 0)
	local color = PARTY_COLORS[random:NextInteger(1, #PARTY_COLORS)]

	local rocket = decorPart(parent, "Rocket", Enum.PartType.Ball, Vector3.one * 0.8, color, Enum.Material.Neon)
	rocket.CFrame = CFrame.new(launch)
	local left = Instance.new("Attachment")
	left.Position = Vector3.new(-0.3, 0, 0)
	left.Parent = rocket
	local rightEdge = Instance.new("Attachment")
	rightEdge.Position = Vector3.new(0.3, 0, 0)
	rightEdge.Parent = rocket
	local trail = Instance.new("Trail")
	trail.Attachment0 = left
	trail.Attachment1 = rightEdge
	trail.Lifetime = 0.45
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.Color = ColorSequence.new(color, WHITE)
	trail.Transparency = NumberSequence.new(0.1, 1)
	trail.Parent = rocket
	Sfx.PlayAt("FireworkLaunch", launch)

	local rise = TweenService:Create(
		rocket,
		TweenInfo.new(random:NextNumber(0.85, 1.15), Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = CFrame.new(burstAt) }
	)
	rise.Completed:Once(function()
		rocket:Destroy()
		if token ~= myToken then
			return
		end
		Effects.Burst(burstAt, {
			Count = 40,
			Colors = { color, color:Lerp(WHITE, 0.5), WHITE },
			Size = Vector3.one * 0.55,
			Speed = 38,
			Gravity = 16,
			Drag = 1.1,
			Life = 1.5,
			Shape = Enum.PartType.Ball,
			Material = Enum.Material.Neon,
		})
		Sfx.PlayAt("Firework", burstAt)
		flash(parent, burstAt, color)
	end)
	rise:Play()
end

local function stop()
	token += 1
	crown = nil
	crownShown = false
	local connection = renderConnection
	if connection then
		connection:Disconnect()
		renderConnection = nil
	end
	local current = container
	container = nil
	if current then
		current:Destroy()
	end
end

local function start()
	stop()
	local spot = MatchClient.Get(Attr.WinnerSpot)
	winnerId = MatchClient.GetNumber(Attr.WinnerUserId)
	if typeof(spot) ~= "CFrame" or winnerId == 0 then
		return
	end
	winnerSpot = spot
	local myToken = token
	local folder = Instance.new("Folder")
	folder.Name = "WobbleCelebration"
	folder.Parent = Workspace
	container = folder

	task.delay(if MatchClient.IsInMatchFlow() then START_DELAY else 0, function()
		if token ~= myToken then
			return
		end
		buildBeam(folder)
		crown = buildCrown(folder)
		renderConnection = RunService.RenderStepped:Connect(stepCrown)
		for _, at in CANNON_TIMES do
			task.delay(at, function()
				if token == myToken then
					fireCannons()
				end
			end)
		end
		for index = 1, Config.Cinematics.Fireworks do
			local at = FIREWORK_START + (index - 1) * FIREWORK_SPACING + random:NextNumber(0, 0.3)
			task.delay(at, function()
				if token == myToken then
					launchFirework(myToken)
				end
			end)
		end
	end)
end

function Celebration.Init()
	local function onPhaseChanged()
		if MatchClient.GetPhase() == "Winner" then
			start()
		else
			stop()
		end
	end
	MatchClient.Changed:Connect(function(name: string)
		if name == Attr.Phase then
			onPhaseChanged()
		end
	end)
	onPhaseChanged()
end

return Celebration
