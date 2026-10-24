--!strict
-- Replaces every player's Roblox avatar with a Bloblet and handles (re)spawning.
-- Players.CharacterAutoLoads is off (see default.project.json), so the default avatar never loads.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ActionService = require(script.Parent.ActionService)
local LobbyService = require(script.Parent.LobbyService)
local PlayerState = require(script.Parent.PlayerState)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local CharacterService = {}

local appearances: { [Player]: BlobletRig.Appearance } = {}
local respawnLimiter = RateLimiter.new(2, 0.5)

local function appearanceFor(player: Player): BlobletRig.Appearance
	local existing = appearances[player]
	if existing then
		return existing
	end
	local colors = Config.DefaultBodyColors
	local appearance = { BodyColor = colors[math.random(#colors)] }
	appearances[player] = appearance
	return appearance
end

local function addNameTag(root: BasePart, player: Player)
	local gui: BillboardGui = Ui.new("BillboardGui", {
		Name = "NameTag",
		Size = UDim2.fromOffset(200, 34),
		StudsOffset = Vector3.new(0, 3.2, 0),
		MaxDistance = 80,
		LightInfluence = 0,
		PlayerToHideFrom = player, -- you don't need to see your own name
		Adornee = root,
		Parent = root,
	})
	local label = Ui.label(
		gui,
		player.DisplayName,
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.fromScale(1, 1),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	Ui.new("UIStroke", {
		Color = Theme.Colors.Ink,
		Thickness = 2.5,
		Transparency = 0.2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})
end

function CharacterService.Spawn(player: Player)
	if player.Parent ~= Players then
		return
	end
	ActionService.ReleaseInvolving(player)

	local model = BlobletRig.Build(appearanceFor(player))
	model.Name = player.Name
	-- Replicated state the animator and server read. Only the server writes these.
	model:SetAttribute("Action", "None")
	model:SetAttribute("Ragdolled", false)
	model:SetAttribute("Grabbing", 0)
	model:SetAttribute("GrabbedBy", 0)

	local root = model.PrimaryPart :: BasePart
	addNameTag(root, player)

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	for _, state in BlobletRig.DisabledStates do
		humanoid:SetStateEnabled(state, false)
	end

	local spawnCFrame = LobbyService.GetSpawnCFrame()
	model:PivotTo(spawnCFrame + Vector3.new(0, BlobletRig.Dimensions.RootHeight + 0.5, 0))

	local old = player.Character
	PlayerState.GrantTeleportGrace(player)
	player.Character = model
	model.Parent = Workspace
	if old and old ~= model then
		old:Destroy()
	end

	-- The owner simulates its own Bloblet; that's what makes movement instant on their screen.
	local ok, err = pcall(function()
		root:SetNetworkOwner(player)
	end)
	if not ok then
		warn(`[CharacterService] SetNetworkOwner failed for {player.Name}: {err}`)
	end

	CollectionService:AddTag(model, Tags.Bloblet)
end

-- Used when a character falls out of the world or a player asks to reset.
function CharacterService.Respawn(player: Player)
	CharacterService.Spawn(player)
end

local function onPlayerAdded(player: Player)
	CharacterService.Spawn(player)
end

function CharacterService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	-- Players who joined before this script ran (common in Studio play-testing).
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		appearances[player] = nil
		local character = player.Character
		if character then
			character:Destroy()
		end
	end)

	Remotes.Event("RequestRespawn").OnServerEvent:Connect(function(player: Player)
		if not respawnLimiter:Allow(player) then
			return
		end
		local state = PlayerState.Get(player)
		local now = os.clock()
		if now - state.LastRespawnRequest < Config.Validation.RespawnRequestCooldown then
			return
		end
		state.LastRespawnRequest = now
		CharacterService.Respawn(player)
	end)
end

return CharacterService
