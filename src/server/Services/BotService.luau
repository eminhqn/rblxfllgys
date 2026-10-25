--!strict
-- Studio-only load test. Set Config.Studio.LoadTestBots (e.g. 29) and press Play: that many dummy
-- Bloblets appear in the lobby, dressed in random items, and wander about, hop, dive, kick, get
-- bonked and emote. Every client animates them and plays their sounds exactly like other players'
-- Bloblets, so you can see how the game copes with a full server on your own.
--
-- Bots aren't players: they can't queue, play matches, or be grabbed. Published games never
-- spawn them, whatever the setting.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Tags = require(Shared.Tags)

local LobbyService = require(script.Parent.LobbyService)

local BotService = {}

local MAX_BOTS = 60
local WANDER_RADIUS = 30
-- The lobby plaza (see LobbyBuilder), kept a little in from the edges.
local PLAZA_MIN = Vector2.new(-68, -30)
local PLAZA_MAX = Vector2.new(68, 64)
local FALLEN_Y = -40

local random = Random.new()

local function pick<T>(list: { T }): T
	return list[random:NextInteger(1, #list)]
end

local function randomAppearance(): BlobletRig.Appearance
	local colorItem = pick(Cosmetics.ForSlot("Color"))
	return {
		BodyColor = colorItem.Color or Color3.fromRGB(255, 92, 168),
		Pattern = pick(Cosmetics.ForSlot("Pattern")).Id,
		Eyes = pick(Cosmetics.ForSlot("Eyes")).Id,
		Hat = pick(Cosmetics.ForSlot("Hat")).Id,
		Outfit = pick(Cosmetics.ForSlot("Outfit")).Id,
	}
end

local function spawnPoint(): CFrame
	return LobbyService.GetSpawnCFrame() + Vector3.new(0, BlobletRig.Dimensions.RootHeight + 0.5, 0)
end

-- Sets an action attribute for a moment, as ActionService does for players.
local function briefly(model: Model, name: string, value: any, reset: any, seconds: number)
	model:SetAttribute(name, value)
	task.delay(seconds, function()
		if model.Parent then
			model:SetAttribute(name, reset)
		end
	end)
end

local function wanderTarget(from: Vector3): Vector3
	local x = math.clamp(from.X + random:NextNumber(-WANDER_RADIUS, WANDER_RADIUS), PLAZA_MIN.X, PLAZA_MAX.X)
	local z = math.clamp(from.Z + random:NextNumber(-WANDER_RADIUS, WANDER_RADIUS), PLAZA_MIN.Y, PLAZA_MAX.Y)
	return Vector3.new(x, from.Y, z)
end

local function runBot(parent: Instance, index: number)
	local model = BlobletRig.Build(randomAppearance())
	model.Name = `LoadTestBot{index}`
	model:SetAttribute("Action", "None")
	model:SetAttribute("Ragdolled", false)
	model:SetAttribute("Grabbing", 0)
	model:SetAttribute("GrabbedBy", 0)
	local root = model.PrimaryPart :: BasePart
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	for _, state in BlobletRig.DisabledStates do
		humanoid:SetStateEnabled(state, false)
	end
	humanoid.WalkSpeed = Config.Movement.RunSpeed * 0.6
	model:PivotTo(spawnPoint())
	model.Parent = parent
	pcall(function()
		root:SetNetworkOwner(nil) -- the server moves bots
	end)
	CollectionService:AddTag(model, Tags.Bloblet)

	local emotes = Cosmetics.ForSlot("Emote")
	while model.Parent do
		if root.Position.Y < FALLEN_Y then
			model:PivotTo(spawnPoint())
		end
		local roll = random:NextNumber()
		if roll < 0.06 then
			-- Stand still and emote.
			humanoid:Move(Vector3.zero)
			local emote = pick(emotes)
			model:SetAttribute("Emote", emote.Id)
			model:SetAttribute("EmoteAt", Workspace:GetServerTimeNow())
			task.wait(emote.Duration or 2)
			continue
		elseif roll < 0.1 then
			briefly(model, "Ragdolled", true, false, 1.2)
			root:ApplyImpulse(
				(Vector3.new(random:NextNumber(-1, 1), 1.2, random:NextNumber(-1, 1))) * 30 * root.AssemblyMass
			)
		elseif roll < 0.2 then
			briefly(model, "Action", "Dive", "None", 0.6)
			root:ApplyImpulse((root.CFrame.LookVector * 40 + Vector3.new(0, 12, 0)) * root.AssemblyMass)
		elseif roll < 0.28 then
			briefly(model, "Action", "Kick", "None", 0.35)
		elseif roll < 0.45 then
			humanoid.Jump = true
		end
		humanoid:MoveTo(wanderTarget(root.Position))
		task.wait(random:NextNumber(1.2, 3.5))
	end
end

function BotService.Init()
	local count = math.min(Config.Studio.LoadTestBots, MAX_BOTS)
	if count <= 0 or not RunService:IsStudio() then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "LoadTestBots"
	folder.Parent = Workspace
	for index = 1, count do
		task.spawn(runBot, folder, index)
	end
	print(`[BotService] {count} load-test Bloblets are wandering the lobby (Config.Studio.LoadTestBots)`)
end

return BotService
