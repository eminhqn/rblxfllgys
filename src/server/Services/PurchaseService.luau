--!strict
-- Things bought with Robux (Developer Products): Crown packs (Config.CrownPacks) and item packs
-- (Config.Items.Packs, Shared/Items).
--
-- Roblox calls ProcessReceipt for every purchase, and keeps calling (even in later servers) until
-- it's told the purchase was granted. So a purchase is only reported granted once the Crowns (or
-- items) are in the player's profile and the profile is saved, and each receipt's PurchaseId is
-- remembered in the profile so a repeat call never grants it twice. If the player isn't here or their data
-- isn't ready, Roblox is told to try again later (it does, next time they join).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local ItemService = require(script.Parent.ItemService)

local PurchaseService = {}

local PROFILE_WAIT = 15 -- seconds to wait for a just-joined player's data before trying later

-- What a product gives: Crowns, or some of one item.
type Grant = {
	Crowns: number,
	Item: string?, -- a Shared/Items id
	Amount: number,
}

local function grantFor(productId: number): Grant?
	if productId == 0 then
		return nil
	end
	for _, pack in Config.CrownPacks do
		if pack.ProductId == productId then
			return { Crowns = pack.Crowns, Amount = 0 }
		end
	end
	for _, pack in Config.Items.Packs do
		local def = Items.Get(pack.Item)
		if def and pack.ProductId == productId then
			local item: string = def.Id
			return { Crowns = 0, Item = item, Amount = pack.Amount }
		end
	end
	return nil
end

local function waitForProfile(player: Player): DataService.Profile?
	local deadline = os.clock() + PROFILE_WAIT
	while player.Parent == Players and os.clock() < deadline do
		local profile = DataService.Get(player)
		if profile then
			return profile
		end
		task.wait(0.5)
	end
	return nil
end

local function processReceipt(receipt: { [string]: any }): Enum.ProductPurchaseDecision
	local productId = receipt.ProductId
	local purchaseId = receipt.PurchaseId
	local grant = if typeof(productId) == "number" then grantFor(productId) else nil
	if not grant or typeof(purchaseId) ~= "string" then
		warn(`[PurchaseService] Receipt for unknown product {tostring(productId)}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- they'll get it next time they join
	end
	local profile = waitForProfile(player)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if table.find(profile.Purchases, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- already given
	end

	DataService.Update(player, function(updated: DataService.Profile)
		updated.Crowns = math.min(updated.Crowns + grant.Crowns, Config.Economy.MaxCurrency)
		local item = grant.Item
		if item then
			ItemService.Give(updated, item, grant.Amount)
		end
		table.insert(updated.Purchases, purchaseId)
		while #updated.Purchases > DataService.MaxPurchaseHistory do
			table.remove(updated.Purchases, 1)
		end
	end)
	-- Only say it's done once it's saved; otherwise Roblox asks again (and the id above stops it
	-- being given twice in this session).
	if not DataService.SaveNow(player) then
		warn(`[PurchaseService] Couldn't save {player.Name}'s purchase yet; Roblox will ask again`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local item = grant.Item
	if item then
		Remotes.Event("ItemsPurchased"):FireClient(player, item, grant.Amount)
	else
		Remotes.Event("CrownsPurchased"):FireClient(player, grant.Crowns)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function PurchaseService.Init()
	MarketplaceService.ProcessReceipt = function(receipt: { [string]: any }): Enum.ProductPurchaseDecision
		local ok, result = pcall(processReceipt, receipt)
		if ok then
			return result
		end
		warn(`[PurchaseService] {result}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

return PurchaseService
