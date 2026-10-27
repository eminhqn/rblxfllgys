--!strict
-- Bots for matches: makes them, dresses them and puts their Bloblets in the world.
--
-- Fill(count) makes that many bots for the match about to start (MatchService), each with a name
-- from Config.Bots.Names that nobody in the match has, a random outfit and a random skill. Spawn
-- builds a bot's Bloblet (CharacterService.Spawn hands bots here), Despawn takes it away once the
-- bot is knocked out, and ReleaseAll gets rid of every bot when the match is over. The server
-- simulates bots' Bloblets: BotMotor moves them and BotBrain decides what they do.
--
-- A bot is a stand-in for a Player (see Bots). Its Bloblet carries what clients need to treat it
-- like anyone else's (Shared/Competitors): UserId, DisplayName, Bot, MatchStatus and, in team
-- rounds, TeamId.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Match = require(Shared.Match)
local Tags = require(Shared.Tags)

local Services = script.Parent.Parent.Services
local CharacterService = require(Services.CharacterService)
local PlayerState = require(Services.PlayerState)

local BotMotor = require(script.Parent.BotMotor)
local Bots = require(script.Parent.Bots)

local BotRoster = {}

local HAT_CHANCE = 0.7
local OUTFIT_CHANCE = 0.6
local PATTERN_CHANCE = 0.4
-- Before a round places it, a new Bloblet waits up here, frozen.
local HOLDING_SPOT = CFrame.new(Config.Match.ArenaOrigin + Vector3.new(0, 400, 0))

local random = Random.new()
local appearances: { [Player]: BlobletRig.Appearance } = {}
local nextUserId = -1

local function pick<T>(list: { T }): T
	return list[random:NextInteger(1, #list)]
end

-- Items a bot may wear: anything except the reward tracks' exclusives (those are earned).
local function wearable(slot: string): { Cosmetics.Item }
	local list: { Cosmetics.Item } = {}
	for _, entry in Cosmetics.ForSlot(slot) do
		if not entry.Level and not entry.Premium then
			table.insert(list, entry)
		end
	end
	return list
end

-- The slot's "nothing" item (Hat_None and so on), or the default.
local function plain(slot: string): string
	return Cosmetics.InSlot(Cosmetics.Defaults, slot)
end

local function randomAppearance(): BlobletRig.Appearance
	local colorItem = pick(wearable("Color"))
	return {
		BodyColor = colorItem.Color or Color3.fromRGB(255, 92, 168),
		Pattern = if random:NextNumber() < PATTERN_CHANCE then pick(wearable("Pattern")).Id else plain("Pattern"),
		Eyes = pick(wearable("Eyes")).Id,
		Hat = if random:NextNumber() < HAT_CHANCE then pick(wearable("Hat")).Id else plain("Hat"),
		Outfit = if random:NextNumber() < OUTFIT_CHANCE then pick(wearable("Outfit")).Id else plain("Outfit"),
	}
end

-- A stand-in for a Player: the fields and methods the match code uses.
local function newStandIn(name: string): Player
	local attributes: { [string]: any } = {}
	local userId = nextUserId
	nextUserId -= 1
	local bot: { [string]: any } = {
		Name = `Bot_{name}`,
		DisplayName = name,
		UserId = userId,
		Character = nil,
		Parent = Players,
		Team = nil,
		Neutral = true,
		ReplicationFocus = nil,
	}
	function bot.GetAttribute(_self: any, key: string): any
		return attributes[key]
	end
	function bot.SetAttribute(_self: any, key: string, value: any)
		attributes[key] = value
		-- Clients read a bot's status from its Bloblet (it isn't a Player they can see).
		if key == Match.PlayerAttr.Status then
			local character = bot.Character
			if character then
				character:SetAttribute(key, value)
			end
		end
	end
	function bot.GetAttributes(_self: any): { [string]: any }
		return table.clone(attributes)
	end
	-- Player methods that mean nothing for a bot.
	function bot.RequestStreamAroundAsync(_self: any, _position: Vector3, _timeout: number?) end
	function bot.Kick(_self: any, _message: string?) end
	function bot.IsFriendsWith(_self: any, _userId: number): boolean
		return false
	end
	return (bot :: any) :: Player
end

local function teamIdOf(bot: Player): string?
	local team = bot.Team
	local id = if team then team:GetAttribute("TeamId") else nil
	return if typeof(id) == "string" then id else nil
end

-- Builds the bot's Bloblet standing at `groundCFrame` (or waiting, frozen, out of sight).
function BotRoster.Spawn(bot: Player, groundCFrame: CFrame?)
	if not Bots.Is(bot) or bot.Parent ~= Players then
		return
	end
	local appearance = appearances[bot] or randomAppearance()
	appearances[bot] = appearance
	local model = BlobletRig.Build(appearance)
	model.Name = bot.Name
	model:SetAttribute("Action", "None")
	model:SetAttribute("Ragdolled", false)
	model:SetAttribute("Grabbing", 0)
	model:SetAttribute("GrabbedBy", 0)
	model:SetAttribute("Bot", true)
	model:SetAttribute("UserId", bot.UserId)
	model:SetAttribute("DisplayName", bot.DisplayName)
	model:SetAttribute(Match.PlayerAttr.Status, bot:GetAttribute(Match.PlayerAttr.Status))
	model:SetAttribute("TeamId", teamIdOf(bot))

	local root = model.PrimaryPart :: BasePart
	CharacterService.AddNameTag(root, bot.DisplayName, nil)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	for _, state in BlobletRig.DisabledStates do
		humanoid:SetStateEnabled(state, false)
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = Bots.CollisionGroup
		end
	end

	local spot = groundCFrame or HOLDING_SPOT
	root.Anchored = groundCFrame == nil
	model:PivotTo(spot + Vector3.new(0, BlobletRig.Dimensions.RootHeight + 0.5, 0))

	local old = bot.Character
	PlayerState.GrantTeleportGrace(bot);
	(bot :: any).Character = model
	model.Parent = Workspace
	if old and old ~= model then
		BotMotor.Detach(old)
		old:Destroy()
	end
	CollectionService:AddTag(model, Tags.Bloblet)
	BotMotor.Attach(bot, model)
end

-- Takes the bot's Bloblet away (knocked out of the match: bots don't spectate).
function BotRoster.Despawn(bot: Player)
	local character = bot.Character;
	(bot :: any).Character = nil
	if character then
		BotMotor.Detach(character)
		character:Destroy()
	end
end

-- Makes `count` bots for a match. `taken` are names already in use (the players'), so nobody
-- shares a name.
function BotRoster.Fill(count: number, taken: { [string]: boolean }): { Player }
	local names: { string } = {}
	for _, name in Config.Bots.Names do
		if not taken[name] then
			table.insert(names, name)
		end
	end
	local made: { Player } = {}
	local low, high = Config.Bots.SkillMin, Config.Bots.SkillMax
	for index = 1, count do
		local name: string
		if #names > 0 then
			name = table.remove(names, random:NextInteger(1, #names)) :: string
		else
			name = `Bloblet {index}`
		end
		local bot = newStandIn(name)
		Bots.Register(bot, { Skill = low + (high - low) * random:NextNumber() })
		table.insert(made, bot)
	end
	return made
end

-- Every bot leaves (the match is over).
function BotRoster.ReleaseAll()
	for _, bot in Bots.All() do
		BotRoster.Despawn(bot);
		(bot :: any).Parent = nil
		appearances[bot] = nil
		Bots.Unregister(bot)
	end
end

function BotRoster.Init()
	Bots.SetSpawner(BotRoster.Spawn)
end

return BotRoster
