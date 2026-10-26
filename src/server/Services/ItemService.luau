--!strict
-- Items bought with Robux (Shared/Items): how many each player has, and the whole-match ones in
-- action.
--
--   * When a match starts, every whole-match item you have and haven't switched OFF is used: one
--     of each, for that match. The ones working for you are published as the MatchBoosts player
--     attribute, which the client's movement reads (SPEED, JUMP, SLIDE) and ProgressService
--     checks for DOUBLE REWARDS.
--   * SHIELD puts a bubble on your Bloblet at the start of every round of that match; the first
--     kick, slap or grab that would get you pops it instead (ActionService).
--   * SLAPS (ActionService) and RESPAWNS (MatchService) are used one at a time with Take.
--
-- Clients can only switch whole-match items ON or OFF here; everything else is decided by the
-- server.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ItemService = {}

-- The character attribute that shows (and is) the SHIELD bubble.
ItemService.ShieldAttribute = "Shield"

local PlayerAttr = Match.PlayerAttr

local toggleLimiter = RateLimiter.new(6, 4)
local active: { [Player]: { [string]: boolean } } = {} -- whole-match items working this match

local function publishBoosts(player: Player)
	local list: { string } = {}
	local set = active[player]
	if set then
		for _, def in Items.List do
			if set[def.Id] then
				table.insert(list, def.Id)
			end
		end
	end
	player:SetAttribute(PlayerAttr.MatchBoosts, HttpService:JSONEncode(list))
end

-- How many of an item the player has (0 while their profile is loading).
function ItemService.Count(player: Player, itemId: string): number
	local profile = DataService.Get(player)
	local count = if profile then profile.Items[itemId] else nil
	return count or 0
end

-- Uses one of an item. False if they don't have one.
function ItemService.Take(player: Player, itemId: string): boolean
	local taken = false
	DataService.Update(player, function(profile: DataService.Profile)
		local count = profile.Items[itemId] or 0
		if count > 1 then
			profile.Items[itemId] = count - 1
		elseif count == 1 then
			profile.Items[itemId] = nil -- only items you have are kept
		end
		taken = count > 0
	end)
	return taken
end

-- Adds items to a profile inside a DataService.Update (a Robux pack).
function ItemService.Give(profile: DataService.Profile, itemId: string, amount: number)
	if amount <= 0 then
		return
	end
	profile.Items[itemId] = math.min((profile.Items[itemId] or 0) + math.floor(amount), Config.Items.MaxStack)
end

-- True if a whole-match item is working for the player in the current match.
function ItemService.IsActive(player: Player, itemId: string): boolean
	local set = active[player]
	return set ~= nil and set[itemId] == true
end

-- A match is starting: each player's switched-on whole-match items are used for it.
function ItemService.MatchStarted(players: { Player })
	for _, player in players do
		local profile = DataService.Get(player)
		local set: { [string]: boolean } = {}
		if profile then
			for _, itemId in Items.MatchItems() do
				if not profile.ItemsOff[itemId] and ItemService.Take(player, itemId) then
					set[itemId] = true
				end
			end
		end
		active[player] = set
		publishBoosts(player)
	end
end

-- A round has started (GO!): shields go up for everyone who has one this match.
function ItemService.RoundStarted(players: { Player })
	for _, player in players do
		local character = player.Character
		if character and ItemService.IsActive(player, "Shield") then
			character:SetAttribute(ItemService.ShieldAttribute, true)
		end
	end
end

-- The round is over: shields that weren't popped go away (they come back next round).
function ItemService.RoundEnded(players: { Player })
	for _, player in players do
		local character = player.Character
		if character then
			character:SetAttribute(ItemService.ShieldAttribute, nil)
		end
	end
end

-- The match is over: nothing is working any more.
function ItemService.MatchEnded(players: { Player })
	for _, player in players do
		active[player] = nil
		if player.Parent == Players then
			player:SetAttribute(PlayerAttr.MatchBoosts, nil)
			local character = player.Character
			if character then
				character:SetAttribute(ItemService.ShieldAttribute, nil)
			end
		end
	end
end

-- Pops the player's shield if it's up. True if it was (and so blocked whatever hit them).
function ItemService.PopShield(player: Player): boolean
	local character = player.Character
	if not character or character:GetAttribute(ItemService.ShieldAttribute) ~= true then
		return false
	end
	character:SetAttribute(ItemService.ShieldAttribute, nil)
	local root = character.PrimaryPart
	if root then
		Remotes.Event("ItemEffect"):FireAllClients("ShieldPop", root.Position)
	end
	return true
end

-- ITEMS shop: switches a whole-match item ON or OFF for the next matches.
local function onRequestToggle(player: Player, itemId: unknown, on: unknown)
	if not toggleLimiter:Allow(player) or typeof(on) ~= "boolean" or typeof(itemId) ~= "string" then
		return
	end
	local def = Items.Get(itemId)
	if not def or def.Kind ~= "Match" then
		return
	end
	DataService.Update(player, function(profile: DataService.Profile)
		if on then
			profile.ItemsOff[def.Id] = nil
		else
			profile.ItemsOff[def.Id] = true
		end
	end)
end

function ItemService.Init()
	Remotes.Event("RequestItemToggle").OnServerEvent:Connect(onRequestToggle)
	Players.PlayerRemoving:Connect(function(player: Player)
		active[player] = nil
	end)
end

return ItemService
