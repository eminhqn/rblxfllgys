--!strict
-- The customise screen's server side: buying items with Gumdrops and choosing what to wear.
--
-- Both requests are checked here against the player's saved profile: the item must exist and
-- belong to that slot, a purchase needs enough Gumdrops and an item you don't own yet, and you
-- can only wear what you own (or what's free). Outfits can't be changed mid-match.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Cosmetics = require(Shared.Cosmetics)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)

local CharacterService = require(script.Parent.CharacterService)
local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ShopService = {}

local equipLimiter = RateLimiter.new(8, 4)
local purchaseLimiter = RateLimiter.new(4, 1)

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
	if profile.Coins < entry.Price then
		return false, `Not enough {Cosmetics.CurrencyName}.`
	end
	DataService.Update(player, function(updated: DataService.Profile)
		updated.Coins -= entry.Price
		updated.Owned[itemId] = true
	end)
	return true, "Unlocked!"
end

function ShopService.Init()
	Remotes.Event("RequestEquip").OnServerEvent:Connect(onRequestEquip)
	Remotes.Function("RequestPurchase").OnServerInvoke = function(player: Player, itemId: unknown): (boolean, string)
		return onRequestPurchase(player, itemId)
	end
end

return ShopService
