--!strict
-- Player levels and the reward track.
--
-- You earn XP just by playing (the server hands it out; see ProgressService): every round you
-- play, more for getting through, reaching a final, winning, and finishing daily challenges. Each
-- level needs a bit more XP than the last. Every level up to TrackLength pays out a reward:
-- Gumdrops, Crowns, or one of the exclusive items you can't buy (Shared/Cosmetics items with a
-- Level). Levels after that pay Gumdrops.

local Cosmetics = require(script.Parent.Cosmetics)

export type RewardKind = "Gumdrops" | "Crowns" | "Item"

export type Reward = {
	Kind: RewardKind,
	Amount: number, -- Gumdrops / Crowns (1 for an item)
	ItemId: string?,
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

local itemAtLevel: { [number]: string } = {}
for _, entry in Cosmetics.Items do
	local level = entry.Level
	if level then
		assert(not itemAtLevel[level], `two reward track items at level {level}`)
		assert(not CROWN_LEVELS[level], `level {level} has both Crowns and an item`)
		itemAtLevel[level] = entry.Id
	end
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

-- A short description of a reward, e.g. "+120 GUMDROPS" or "PARTY HAT".
function Progression.Describe(reward: Reward): string
	if reward.Kind == "Item" then
		local entry = if reward.ItemId then Cosmetics.Get(reward.ItemId) else nil
		return if entry then string.upper(entry.Name) else "AN ITEM"
	elseif reward.Kind == "Crowns" then
		return `+{reward.Amount} {if reward.Amount == 1 then "CROWN" else "CROWNS"}`
	end
	return `+{reward.Amount} GUMDROPS`
end

return table.freeze(Progression)
