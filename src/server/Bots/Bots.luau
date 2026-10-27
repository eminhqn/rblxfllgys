--!strict
-- Which "players" are bots, and a few hooks other services use for them. It requires nothing from
-- the other services, so any of them can ask Bots.Is(player) without a require cycle.
--
-- A bot (made by BotRoster) is a stand-in for a Player: a small table with the Player fields and
-- methods the match code uses (Name, DisplayName, UserId, Character, Parent, Team,
-- Get/SetAttribute), typed as a Player so the rounds treat bots like anyone else. Bots have
-- negative UserIds. Where only a real player will do (messaging their client, their saved
-- profile, Roblox's player APIs), check Bots.Is first.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Signal)

local Bots = {}

-- Fires as a bot leaves for good (the match is over), like Players.PlayerRemoving does for a
-- player: anything keeping per-player state forgets the bot.
Bots.Removing = Signal.new() :: Signal.Signal<Player>

-- Collision groups (BotWorld registers them): bots' Bloblets; the server's copies of hazards that
-- only really move on players' screens (bots pass through those); and the copies the server
-- moves itself, which only bots stand on.
Bots.CollisionGroup = "Bots"
Bots.NoBotsGroup = "NoBots"
Bots.BotsOnlyGroup = "BotsOnly"

export type Info = {
	Skill: number, -- 0 (clumsy) to 1 (sharp), see Config.Bots
}

local infos: { [Player]: Info } = {}
local ordered: { Player } = {}

local spawner: ((bot: Player, groundCFrame: CFrame?) -> ())? = nil
local knocker: ((bot: Player, impulse: Vector3, duration: number) -> ())? = nil

function Bots.Register(bot: Player, info: Info)
	if infos[bot] then
		return
	end
	infos[bot] = info
	table.insert(ordered, bot)
end

function Bots.Unregister(bot: Player)
	if not infos[bot] then
		return
	end
	Bots.Removing:Fire(bot)
	infos[bot] = nil
	local index = table.find(ordered, bot)
	if index then
		table.remove(ordered, index)
	end
end

function Bots.Is(player: Player): boolean
	return infos[player] ~= nil
end

function Bots.Info(bot: Player): Info?
	return infos[bot]
end

-- A bot's skill (0 to 1); 0.5 for anyone who isn't a bot.
function Bots.SkillOf(player: Player): number
	local info = infos[player]
	return if info then info.Skill else 0.5
end

-- Every bot there is right now (in a match or about to be).
function Bots.All(): { Player }
	return table.clone(ordered)
end

-- The same list without copying it, for loops that run every frame. Don't add or remove bots
-- while going through it (nothing in a frame's bot work does).
function Bots.List(): { Player }
	return ordered
end

function Bots.Count(): number
	return #ordered
end

-- A real player or a bot, by user id.
function Bots.Competitor(userId: number): Player?
	if userId > 0 then
		return Players:GetPlayerByUserId(userId)
	end
	for _, bot in ordered do
		if bot.UserId == userId then
			return bot
		end
	end
	return nil
end

-- CharacterService hands bots to this (BotRoster.Spawn) instead of building a player character.
function Bots.SetSpawner(callback: (bot: Player, groundCFrame: CFrame?) -> ())
	spawner = callback
end

function Bots.Spawn(bot: Player, groundCFrame: CFrame?)
	local callback = spawner
	if callback then
		callback(bot, groundCFrame)
	end
end

-- ActionService knocks bots over through this (BotMotor), where it would message a player's client.
function Bots.SetKnocker(callback: (bot: Player, impulse: Vector3, duration: number) -> ())
	knocker = callback
end

function Bots.Knock(bot: Player, impulse: Vector3, duration: number)
	local callback = knocker
	if callback then
		callback(bot, impulse, duration)
	end
end

return Bots
