--!strict
-- Crown packs bought with Robux (Config.CrownPacks: Developer Products).
--
-- Roblox calls ProcessReceipt for every purchase, and keeps calling (even in later servers) until
-- it's told the purchase was granted. So a purchase is only reported granted once the Crowns are
-- in the player's profile and the profile is saved, and each receipt's PurchaseId is remembered in
-- the profile so a repeat call never grants it twice. If the player isn't here or their data
-- isn't ready, Roblox is told to try again later (it does, next time they join).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)

local PurchaseService = {}

local PROFILE_WAIT = 15 -- seconds to wait for a just-joined player's data before trying later

local function packFor(productId: number): { Crowns: number, ProductId: number }?
	for _, pack in Config.CrownPacks do
		if pack.ProductId ~= 0 and pack.ProductId == productId then
			return pack
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
	local pack = if typeof(productId) == "number" then packFor(productId) else nil
	if not pack or typeof(purchaseId) ~= "string" then
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
		updated.Crowns = math.min(updated.Crowns + pack.Crowns, Config.Economy.MaxCurrency)
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
	Remotes.Event("CrownsPurchased"):FireClient(player, pack.Crowns)
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
