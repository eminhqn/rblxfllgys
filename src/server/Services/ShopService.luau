--!strict
-- The customise screen's server side: buying items with Crowns, trading Gumdrops for Crowns, and
-- choosing what to wear.
--
-- Every request is checked here against the player's saved profile: the item must exist and
-- belong to that slot, a purchase needs enough Crowns and an item you don't own yet (and an item
-- shop item must be in today's or this week's shop: Shared/ItemShop), a trade needs enough
-- Gumdrops, and you can only wear what you own (or what's free). Outfits can't be changed
-- mid-match.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local ItemShop = require(Shared.ItemShop)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)

local CharacterService = require(script.Parent.CharacterService)
local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ShopService = {}

local equipLimiter = RateLimiter.new(8, 4)
local purchaseLimiter = RateLimiter.new(4, 1)
local tradeLimiter = RateLimiter.new(4, 1)

local function onRequestEquip(player: Player, slot: unknown, itemId: unknown)
	if not equipLimiter:Allow(player) then
		return
	end
	if not Cosmetics.IsSlot(slot) or typeof(itemId) ~= "string" then
		return
	end
	local entry = Cosmetics.Get(itemId)
	local profile = DataService.Get(player)
	if not entry or entry.Slot ~= slot or not profile or not DataService.Owns(profile, itemId) then
		return
	end
	local inMatch = player:GetAttribute(Match.PlayerAttr.InMatch) == true
	if inMatch and entry.Slot ~= "Emote" then
		return -- no costume changes in the middle of a match
	end
	if Cosmetics.InSlot(profile.Equipped, entry.Slot) == itemId then
		return
	end
	DataService.Update(player, function(updated: DataService.Profile)
		Cosmetics.SetSlot(updated.Equipped, entry.Slot, itemId)
	end)
	if entry.Slot ~= "Emote" then
		CharacterService.RefreshAppearance(player)
	end
end

local function onRequestPurchase(player: Player, itemId: unknown): (boolean, string)
	if not purchaseLimiter:Allow(player) then
		return false, "Slow down a little!"
	end
	if typeof(itemId) ~= "string" then
		return false, "That item doesn't exist."
	end
	local entry = Cosmetics.Get(itemId)
	if not entry then
		return false, "That item doesn't exist."
	end
	local profile = DataService.Get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	if DataService.Owns(profile, itemId) then
		return false, "You already have this."
	end
	if entry.Level then
		return false, `This one can't be bought: it's the level {entry.Level} reward.`
	end
	if entry.Shop and not ItemShop.IsFeatured(itemId, ItemShop.Time(os.time())) then
		return false, "That's left the item shop. Keep an eye out for it coming back!"
	end
	if profile.Crowns < entry.Price then
		return false, "Not enough Crowns. Win a match, or trade Gumdrops for one!"
	end
	DataService.Update(player, function(updated: DataService.Profile)
		updated.Crowns -= entry.Price
		updated.Owned[itemId] = true
	end)
	return true, "Unlocked!"
end

-- Swaps Config.Economy.GumdropsPerCrown Gumdrops for one Crown.
local function onRequestTrade(player: Player): (boolean, string)
	if not tradeLimiter:Allow(player) then
		return false, "Slow down a little!"
	end
	local profile = DataService.Get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local rate = Config.Economy.GumdropsPerCrown
	if profile.Gumdrops < rate then
		return false, `You need {rate} Gumdrops for a Crown. Keep playing!`
	end
	DataService.Update(player, function(updated: DataService.Profile)
		updated.Gumdrops -= rate
		updated.Crowns += 1
	end)
	return true, "+1 Crown!"
end

function ShopService.Init()
	Remotes.Event("RequestEquip").OnServerEvent:Connect(onRequestEquip)
	Remotes.Function("RequestPurchase").OnServerInvoke = function(player: Player, itemId: unknown): (boolean, string)
		return onRequestPurchase(player, itemId)
	end
	Remotes.Function("RequestTrade").OnServerInvoke = function(player: Player): (boolean, string)
		return onRequestTrade(player)
	end
end

return ShopService
