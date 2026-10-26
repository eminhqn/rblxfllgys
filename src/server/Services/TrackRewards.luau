--!strict
-- Pays out reward track rewards (Shared/Progression): the free track's and, for players with the
-- premium pass, the PREMIUM track's. ProgressService pays them as you level up; PremiumService pays
-- the premium ones for every level you'd already reached when you get the pass. Each track
-- remembers the highest level it has paid (TrackClaimed / PremiumClaimed), so nothing is ever paid
-- twice.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Progression = require(Shared.Progression)

local DataService = require(script.Parent.DataService)
local ItemService = require(script.Parent.ItemService)

-- One reward that was paid out, as sent to the player's LEVEL UP / PREMIUM pop-ups.
export type Paid = {
	Level: number,
	Kind: Progression.RewardKind,
	Amount: number,
	ItemId: string?,
	PowerUp: string?,
	Premium: boolean,
}

local TrackRewards = {}

-- Adds one reward to a profile (call it inside DataService.Update).
local function grant(profile: DataService.Profile, reward: Progression.Reward)
	if reward.Kind == "Gumdrops" then
		DataService.GiveGumdrops(profile, reward.Amount)
	elseif reward.Kind == "Crowns" then
		profile.Crowns = math.min(profile.Crowns + reward.Amount, Config.Economy.MaxCurrency)
	elseif reward.Kind == "PowerUp" then
		local powerUp = reward.PowerUp
		if powerUp then
			ItemService.Give(profile, powerUp, reward.Amount)
		end
	elseif reward.ItemId then
		profile.Owned[reward.ItemId] = true
	end
end

local function record(paid: { Paid }, level: number, reward: Progression.Reward, premium: boolean)
	table.insert(paid, {
		Level = level,
		Kind = reward.Kind,
		Amount = reward.Amount,
		ItemId = reward.ItemId,
		PowerUp = reward.PowerUp,
		Premium = premium,
	})
end

-- Pays every free reward not paid yet up to `level` and, if the profile has the premium pass,
-- every premium one too. Adds what it paid to `paid`. Call it inside DataService.Update.
function TrackRewards.PayUpTo(profile: DataService.Profile, level: number, paid: { Paid })
	for step = profile.TrackClaimed + 1, level do
		local reward = Progression.RewardFor(step)
		if reward then
			grant(profile, reward)
			record(paid, step, reward, false)
		end
	end
	profile.TrackClaimed = math.max(profile.TrackClaimed, level)
	if not DataService.HasPremium(profile) then
		return
	end
	for step = profile.PremiumClaimed + 1, level do
		local reward = Progression.PremiumRewardFor(step)
		if reward then
			grant(profile, reward)
			record(paid, step, reward, true)
		end
	end
	profile.PremiumClaimed = math.max(profile.PremiumClaimed, level)
end

return TrackRewards
