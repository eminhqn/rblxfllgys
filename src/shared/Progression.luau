--!strict
-- Player levels and the reward track.
--
-- You earn XP just by playing (the server hands it out; see ProgressService): every round you
-- play, more for getting through, reaching a final, winning, and finishing daily challenges. Each
-- level needs a bit more XP than the last. Every level up to TrackLength pays out a reward:
-- Gumdrops, Crowns, or one of the exclusive items you can't buy (Shared/Cosmetics items with a
-- Level). Levels after that pay Gumdrops.
--
-- The PREMIUM track (a Game Pass, Config.Premium) runs alongside it on the same levels with a
-- bigger reward at each one: Crowns, packs of items (Shared/Items: slaps, shields, respawns,
-- boosts) and its own exclusive cosmetics (Shared/Cosmetics items with a Premium level), then
-- more Gumdrops every level after the track. Buying it pays out every premium reward for the
-- levels you've already reached straight away.

local Config = require(script.Parent.Config)
local Cosmetics = require(script.Parent.Cosmetics)
local Items = require(script.Parent.Items)

export type RewardKind = "Gumdrops" | "Crowns" | "Item" | "PowerUp"

export type Reward = {
	Kind: RewardKind,
	Amount: number, -- Gumdrops / Crowns / how many of the power-up (1 for an item)
	ItemId: string?, -- Item: a Shared/Cosmetics id
	PowerUp: string?, -- PowerUp: a Shared/Items id
}

local Progression = {}

-- XP for each thing you do.
Progression.XP = table.freeze({
	RoundPlayed = 25,
	RoundQualified = 35, -- on top of RoundPlayed
	FinalReached = 50,
	MatchWon = 200,
	ChallengeDone = 75,
})

Progression.TrackLength = 30 -- levels with a special reward each
Progression.MaxLevel = 99

-- Crowns on the track (every other level without an item pays Gumdrops).
local CROWN_LEVELS: { [number]: number } = {
	[5] = 1,
	[10] = 2,
	[22] = 2,
	[28] = 3,
}
local PAST_TRACK_GUMDROPS = 150

-- The premium track: Crowns, item packs (Shared/Items id, how many) and, at the other levels,
-- its exclusive items. Any level left over pays Gumdrops.
local PREMIUM_CROWNS: { [number]: number } = {
	[5] = 2,
	[10] = 3,
	[15] = 3,
	[20] = 4,
	[24] = 4,
	[27] = 5,
}
local PREMIUM_PACKS: { [number]: { Item: string, Amount: number } } = {
	[2] = { Item = "Slap", Amount = 5 },
	[3] = { Item = "Shield", Amount = 2 },
	[6] = { Item = "Respawn", Amount = 2 },
	[7] = { Item = "Speed", Amount = 2 },
	[9] = { Item = "DoubleRewards", Amount = 2 },
	[11] = { Item = "Jump", Amount = 2 },
	[13] = { Item = "DoubleJump", Amount = 2 },
	[14] = { Item = "Shield", Amount = 3 },
	[17] = { Item = "Slap", Amount = 10 },
	[18] = { Item = "Slide", Amount = 2 },
	[21] = { Item = "Respawn", Amount = 3 },
	[23] = { Item = "DoubleRewards", Amount = 2 },
	[26] = { Item = "Speed", Amount = 3 },
	[29] = { Item = "Shield", Amount = 5 },
}

local itemAtLevel: { [number]: string } = {}
local premiumItemAtLevel: { [number]: string } = {}
for _, entry in Cosmetics.Items do
	local level = entry.Level
	if level then
		assert(not itemAtLevel[level], `two reward track items at level {level}`)
		assert(not CROWN_LEVELS[level], `level {level} has both Crowns and an item`)
		itemAtLevel[level] = entry.Id
	end
	local premiumLevel = entry.Premium
	if premiumLevel then
		assert(not premiumItemAtLevel[premiumLevel], `two premium track items at level {premiumLevel}`)
		assert(
			not PREMIUM_CROWNS[premiumLevel] and not PREMIUM_PACKS[premiumLevel],
			`premium level {premiumLevel} has an item and something else`
		)
		premiumItemAtLevel[premiumLevel] = entry.Id
	end
end
for level, pack in PREMIUM_PACKS do
	assert(Items.IsId(pack.Item), `premium level {level} gives an unknown item {pack.Item}`)
	assert(not PREMIUM_CROWNS[level], `premium level {level} has Crowns and items`)
end

-- XP needed to go from `level` to the next one.
function Progression.XPForNextLevel(level: number): number
	return 100 + 20 * (math.max(level, 1) - 1)
end

-- Total XP needed to reach `level` from the start.
function Progression.TotalXPFor(level: number): number
	local total = 0
	for step = 1, math.min(level, Progression.MaxLevel) - 1 do
		total += Progression.XPForNextLevel(step)
	end
	return total
end

-- The level a total amount of XP reaches, how far into that level it is, and how much that level
-- needs in all.
function Progression.LevelFor(totalXP: number): (number, number, number)
	local level = 1
	local remaining = math.max(totalXP, 0)
	while level < Progression.MaxLevel do
		local needed = Progression.XPForNextLevel(level)
		if remaining < needed then
			return level, remaining, needed
		end
		remaining -= needed
		level += 1
	end
	return level, 0, 0 -- the top level: nothing more to fill
end

-- What reaching `level` pays out (nothing for level 1, where everyone starts).
function Progression.RewardFor(level: number): Reward?
	if level < 2 or level > Progression.MaxLevel then
		return nil
	end
	local itemId = itemAtLevel[level]
	if itemId then
		return { Kind = "Item", Amount = 1, ItemId = itemId }
	end
	local crowns = CROWN_LEVELS[level]
	if crowns then
		return { Kind = "Crowns", Amount = crowns }
	end
	if level > Progression.TrackLength then
		return { Kind = "Gumdrops", Amount = PAST_TRACK_GUMDROPS }
	end
	return { Kind = "Gumdrops", Amount = 40 + 10 * level }
end

-- What reaching `level` pays out on the PREMIUM track (for players with the premium pass).
function Progression.PremiumRewardFor(level: number): Reward?
	if level < 2 or level > Progression.MaxLevel then
		return nil
	end
	if level > Progression.TrackLength then
		return { Kind = "Gumdrops", Amount = Config.Premium.PastTrackGumdrops }
	end
	local itemId = premiumItemAtLevel[level]
	if itemId then
		return { Kind = "Item", Amount = 1, ItemId = itemId }
	end
	local crowns = PREMIUM_CROWNS[level]
	if crowns then
		return { Kind = "Crowns", Amount = crowns }
	end
	local pack = PREMIUM_PACKS[level]
	if pack then
		return { Kind = "PowerUp", Amount = pack.Amount, PowerUp = pack.Item }
	end
	return { Kind = "Gumdrops", Amount = 100 + 15 * level }
end

-- A short description of a reward, e.g. "+120 GUMDROPS", "+5 SLAPS" or "PARTY HAT".
function Progression.Describe(reward: Reward): string
	if reward.Kind == "Item" then
		local entry = if reward.ItemId then Cosmetics.Get(reward.ItemId) else nil
		return if entry then string.upper(entry.Name) else "AN ITEM"
	elseif reward.Kind == "PowerUp" then
		local def = if reward.PowerUp then Items.Get(reward.PowerUp) else nil
		if not def then
			return `+{reward.Amount} ITEMS`
		end
		-- Boosts are counted in rounds, so name the boost: "SHIELD x3".
		if def.Unit == "ROUND" then
			return `{def.Name} x{reward.Amount}`
		end
		return `+{reward.Amount} {if reward.Amount == 1 then def.Unit else def.Units}`
	elseif reward.Kind == "Crowns" then
		return `+{reward.Amount} {if reward.Amount == 1 then "CROWN" else "CROWNS"}`
	end
	return `+{reward.Amount} GUMDROPS`
end

return table.freeze(Progression)
