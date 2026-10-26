--!strict
-- Items bought with Robux (Shared/Items): how many each player has, picking them at the start of
-- a round, and the ones working for the round.
--
--   * Before a round (while it loads and during the round card) MatchService opens the picks:
--     players in it pick items they have (RequestItemPick), shown back to them as the ItemPicks
--     player attribute.
--   * At GO the picks happen: each picked boost, shield or double rewards is used up and works
--     for that round; a picked SLAPS puts the player's slapper in their hand (each slap that lands
--     uses one, in ActionService). What's working is the RoundItems player attribute, which the
--     client's movement reads (SPEED, JUMP, SLIDE) and ProgressService checks (DOUBLE REWARDS).
--   * SHIELD puts a bubble on your Bloblet; the first kick, slap or grab that would get you pops it
--     instead (ActionService).
--   * RESPAWNS aren't picked: MatchService offers one when you're knocked out, and uses it with
--     Take.
--
-- Clients only ask to pick or unpick; the server checks it's the time to pick, that they're in the
-- round, and that they have one.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Items = require(Shared.Items)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ItemService = {}

-- The character attribute that shows (and is) the SHIELD bubble.
ItemService.ShieldAttribute = "Shield"

local PlayerAttr = Match.PlayerAttr

local pickLimiter = RateLimiter.new(10, 6)
local picking = false -- picks are open (the next round is loading)
local picks: { [Player]: { [string]: boolean } } = {} -- players in that round -> what they picked
local active: { [Player]: { [string]: boolean } } = {} -- items working this round

-- An item set as a JSON array, in shop order.
local function encode(set: { [string]: boolean }?): string
	local list: { string } = {}
	if set then
		for _, def in Items.List do
			if set[def.Id] then
				table.insert(list, def.Id)
			end
		end
	end
	return HttpService:JSONEncode(list)
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

-- True if an item is working for the player this round.
function ItemService.IsActive(player: Player, itemId: string): boolean
	local set = active[player]
	return set ~= nil and set[itemId] == true
end

local function setSlapper(player: Player, on: boolean)
	local character = player.Character
	if not character then
		return
	end
	local profile = DataService.Get(player)
	local skin = if profile then profile.Equipped.Slapper else Cosmetics.Defaults.Slapper
	BlobletRig.SetSlapper(character, if on then skin else nil)
end

-- Clears everything item-related for these players (between rounds, and when the match ends).
local function clearRound(players: { Player })
	picking = false
	table.clear(picks)
	for _, player in players do
		active[player] = nil
		if player.Parent == Players then
			player:SetAttribute(PlayerAttr.ItemPicks, nil)
			player:SetAttribute(PlayerAttr.RoundItems, nil)
			local character = player.Character
			if character then
				character:SetAttribute(ItemService.ShieldAttribute, nil)
				BlobletRig.SetSlapper(character, nil)
			end
		end
	end
end

-- A round is about to load with these players: they can pick their items until GO.
function ItemService.OpenPicks(players: { Player })
	picking = true
	table.clear(picks)
	for _, player in players do
		picks[player] = {}
		player:SetAttribute(PlayerAttr.ItemPicks, encode(nil))
	end
end

-- GO: what each player picked is used and starts working.
function ItemService.RoundStarted(players: { Player })
	picking = false
	for _, player in players do
		local chosen = picks[player]
		local set: { [string]: boolean } = {}
		if chosen then
			for _, def in Items.List do
				if not chosen[def.Id] then
					continue
				end
				if def.Kind == "Round" then
					if ItemService.Take(player, def.Id) then
						set[def.Id] = true
					end
				elseif def.Kind == "Slap" and ItemService.Count(player, def.Id) > 0 then
					set[def.Id] = true -- free to carry; each hit uses one
				end
			end
		end
		active[player] = set
		player:SetAttribute(PlayerAttr.ItemPicks, nil)
		player:SetAttribute(PlayerAttr.RoundItems, encode(set))
		local character = player.Character
		if character and set.Shield then
			character:SetAttribute(ItemService.ShieldAttribute, true)
		end
		setSlapper(player, set.Slap == true)
	end
	table.clear(picks)
end

-- The round is over: items stop working (and picks that never happened are dropped).
function ItemService.RoundEnded(players: { Player })
	clearRound(players)
end

function ItemService.MatchEnded(players: { Player })
	clearRound(players)
end

-- A slap landed: uses one, and puts the slapper away if that was the last.
function ItemService.UseSlap(player: Player): boolean
	if not ItemService.Take(player, "Slap") then
		return false
	end
	if ItemService.Count(player, "Slap") <= 0 then
		local set = active[player]
		if set then
			set["Slap"] = nil
			player:SetAttribute(PlayerAttr.RoundItems, encode(set))
		end
		setSlapper(player, false)
	end
	return true
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

-- The round picker: pick (or unpick) an item for the round that's about to start.
local function onRequestPick(player: Player, itemId: unknown, on: unknown)
	if not pickLimiter:Allow(player) or typeof(on) ~= "boolean" or typeof(itemId) ~= "string" then
		return
	end
	local chosen = picks[player]
	local def = Items.Get(itemId)
	if not picking or not chosen or not def or not Items.IsPickable(def) then
		return
	end
	if on and ItemService.Count(player, def.Id) <= 0 then
		return
	end
	if on then
		chosen[def.Id] = true
	else
		chosen[def.Id] = nil
	end
	player:SetAttribute(PlayerAttr.ItemPicks, encode(chosen))
end

function ItemService.Init()
	Remotes.Event("RequestItemPick").OnServerEvent:Connect(onRequestPick)
	Players.PlayerRemoving:Connect(function(player: Player)
		active[player] = nil
		picks[player] = nil
	end)
end

return ItemService
