--!strict
-- REVIVE, on this client: knocked out of a match, come back for the round after the one you went
-- out in (the server's MatchService decides when you can: the ReviveOpen attribute). It uses one
-- of your RESPAWNS; with none, the server offers you one revive a match to buy
-- (Config.Items.ReviveProductId), which brings you back as soon as it's bought. The lobby menu and
-- the spectate bar show a REVIVE button when Available says so, and call Revive when it's
-- pressed.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)

local ProfileClient = require(script.Parent.ProfileClient)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)

local ReviveClient = {}

-- What Available says may have changed.
ReviveClient.Changed = Signal.new() :: Signal.Signal<()>

-- The REVIVE button's colour (a RESPAWN's).
ReviveClient.Color = (Items.Get("Respawn") :: Items.Def).Color

local REQUEST_COOLDOWN = 0.8

local localPlayer = Players.LocalPlayer
local price: number? = nil
local fetching = false
local lastRequest = -math.huge

local function respawns(): number
	return ProfileClient.GetItemCount("Respawn")
end

local function canBuy(): boolean
	return Config.Items.ReviveProductId ~= 0 and localPlayer:GetAttribute(Match.PlayerAttr.ReviveBought) ~= true
end

-- Looks up the revive's Robux price (once).
local function fetchPrice()
	local productId = Config.Items.ReviveProductId
	if productId == 0 or price or fetching then
		return
	end
	fetching = true
	task.spawn(function()
		local ok, info = pcall(function(): any
			return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
		end)
		fetching = false
		if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
			price = info.PriceInRobux
			ReviveClient.Changed:Fire()
		end
	end)
end

-- Whether to show a REVIVE button right now, and what it says.
function ReviveClient.Available(): (boolean, string)
	if localPlayer:GetAttribute(Match.PlayerAttr.ReviveOpen) ~= true then
		return false, ""
	end
	if respawns() > 0 then
		return true, "REVIVE · 1 RESPAWN"
	end
	if canBuy() then
		fetchPrice()
		return true, if price then `REVIVE · R$ {price}` else "REVIVE"
	end
	return false, ""
end

-- The REVIVE button: the server uses a RESPAWN, or offers the revive to buy (holding the next
-- round while you decide).
function ReviveClient.Revive()
	local now = os.clock()
	if now - lastRequest < REQUEST_COOLDOWN or not ReviveClient.Available() then
		return
	end
	lastRequest = now
	Sfx.Play("UiClick")
	Remotes.Event("RequestRevive"):FireServer()
end

function ReviveClient.Init()
	localPlayer.AttributeChanged:Connect(function(name: string)
		if name == Match.PlayerAttr.ReviveOpen or name == Match.PlayerAttr.ReviveBought then
			ReviveClient.Changed:Fire()
		end
	end)
	ProfileClient.Changed:Connect(function()
		ReviveClient.Changed:Fire()
	end)
	Remotes.Event("ReviveEvent").OnClientEvent:Connect(function(kind: unknown)
		if kind == "Revived" then
			RoundHud.Toast("REVIVED! YOU'RE IN THE NEXT ROUND", ReviveClient.Color)
			Sfx.Play("Revive")
		elseif kind == "Returned" then
			RoundHud.Toast("NO NEXT ROUND: YOUR REVIVE IS A RESPAWN AGAIN", ReviveClient.Color)
		end
	end)
end

return ReviveClient
