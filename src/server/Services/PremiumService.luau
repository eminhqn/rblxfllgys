--!strict
-- The PREMIUM reward track's pass (Config.Premium.GamePassId), a Game Pass bought with Robux.
--
-- Owning it is remembered in the profile (PremiumPass) as well as checked with Roblox each time you
-- join, so a Roblox hiccup never takes it away. The moment you buy it (Roblox tells the server
-- through PromptGamePassPurchaseFinished) every premium reward for the levels you've already
-- reached is paid out and you get a PREMIUM UNLOCKED pop-up listing them; from then on
-- ProgressService pays each new level's premium reward along with the free one. Clients only ask
-- Roblox to show the purchase prompt: nothing here listens to them.
--
-- Config.Studio.ResetPremium takes it away again whenever you join in Studio, to test buying it.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Cosmetics = require(Shared.Cosmetics)
local Progression = require(Shared.Progression)
local Remotes = require(Shared.Remotes)

local CharacterService = require(script.Parent.CharacterService)
local DataService = require(script.Parent.DataService)
local TrackRewards = require(script.Parent.TrackRewards)

local PremiumService = {}

-- Pays every premium (and free) reward not paid yet up to the player's level. With `announce`, the
-- player gets the PREMIUM UNLOCKED pop-up listing them.
local function payOut(player: Player, announce: boolean)
	local paid: { TrackRewards.Paid } = {}
	DataService.Update(player, function(profile: DataService.Profile)
		TrackRewards.PayUpTo(profile, (Progression.LevelFor(profile.XP)), paid)
	end)
	if announce then
		Remotes.Event("PremiumUnlocked"):FireClient(player, paid)
	end
	if #paid > 0 or announce then
		task.spawn(DataService.SaveNow, player)
	end
end

local function grantPass(player: Player, announce: boolean)
	local profile = DataService.Get(player)
	if not profile then
		return
	end
	if not profile.PremiumPass then
		DataService.Update(player, function(updated: DataService.Profile)
			updated.PremiumPass = true
		end)
	end
	payOut(player, announce)
end

-- Studio testing (Config.Studio.ResetPremium): back to not having the premium track, premium-only
-- items included (anything wearing one goes back to the default).
local function resetForTest(player: Player)
	DataService.Update(player, function(profile: DataService.Profile)
		profile.PremiumPass = false
		profile.PremiumClaimed = 1
		for _, entry in Cosmetics.Items do
			if entry.Premium and profile.Owned[entry.Id] then
				profile.Owned[entry.Id] = nil
				if Cosmetics.InSlot(profile.Equipped, entry.Slot) == entry.Id then
					Cosmetics.SetSlot(profile.Equipped, entry.Slot, Cosmetics.InSlot(Cosmetics.Defaults, entry.Slot))
				end
			end
		end
	end)
	CharacterService.RefreshAppearance(player)
	warn(`[PremiumService] Studio: {player.Name}'s PREMIUM track was reset (Config.Studio.ResetPremium)`)
end

-- When a player's data is ready: do they own the pass (bought on the website, or in another
-- server)? Either way, catch up any premium rewards owed.
local function check(player: Player)
	local profile = DataService.Get(player)
	if not profile then
		return
	end
	if RunService:IsStudio() and Config.Studio.ResetPremium then
		resetForTest(player)
		return
	end
	local passId = Config.Premium.GamePassId
	if not profile.PremiumPass and passId ~= 0 then
		local ok, owns = pcall(function(): boolean
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if not ok then
			warn(`[PremiumService] Couldn't check {player.Name}'s premium pass: {owns}`)
		elseif owns and player.Parent == Players then
			grantPass(player, false)
			return
		end
	end
	if DataService.HasPremium(profile) then
		payOut(player, false)
	end
end

function PremiumService.Init()
	DataService.Loaded:Connect(function(player: Player)
		task.spawn(check, player)
	end)
	for _, player in Players:GetPlayers() do
		if DataService.Get(player) then
			task.spawn(check, player) -- loaded before this started
		end
	end
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			if passId == 0 or passId ~= Config.Premium.GamePassId then
				return
			end
			if purchased then
				grantPass(player, true)
				return
			end
			-- Studio testing (ResetPremium): Roblox won't sell a pass to someone who already owns it
			-- (the game's creator always does), so closing its prompt while owning the pass counts as
			-- buying it, to see the unlock. Never in a published game.
			if RunService:IsStudio() and Config.Studio.ResetPremium then
				local ok, owns = pcall(function(): boolean
					return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
				end)
				if ok and owns then
					grantPass(player, true)
				end
			end
		end
	)
end

return PremiumService
