--!strict
-- Items: things you buy with Robux in the ITEMS shop (never with Crowns) to use in matches. A
-- profile keeps how many of each you have (they stack). Two kinds:
--   * "Use" items are spent one at a time while you play: a SLAP that lands, a RESPAWN you take.
--   * "Match" items last a whole match: one is used when a match starts, if you have one and it's
--     switched ON in the ITEMS shop (they're ON unless you switch them OFF). So one of them is
--     one match's worth.
-- The numbers behind each one (how much faster, how long, ...) are in Config.Items and
-- Config.Slap; the Robux packs are Config.Items.Packs.

local Items = {}

export type ItemId = "Slap" | "Respawn" | "Speed" | "Jump" | "Slide" | "Shield" | "DoubleRewards"
export type Kind = "Use" | "Match"

export type Def = {
	Id: ItemId,
	Name: string, -- shown on its card, e.g. "SPEED BOOST"
	Short: string, -- a short name for the round HUD, e.g. "SPEED"
	Description: string, -- one short sentence for its card
	HowTo: string, -- "Use" items: how you use one (whole-match items show an ON / OFF switch)
	Unit: string, -- what one of them is, for "EACH BUY GIVES 1 SLAP"
	Units: string, -- and more than one: "EACH BUY GIVES 10 SLAPS"
	Kind: Kind,
	Color: Color3,
}

local DEFS: { Def } = {
	{
		Id = "Slap",
		Name = "SLAPS",
		Short = "SLAP",
		Description = "A big slap that sends players flying, further than a kick.",
		HowTo = "In a round: R, Y or the SLAP button",
		Unit = "SLAP",
		Units = "SLAPS",
		Kind = "Use",
		Color = Color3.fromRGB(255, 120, 70),
	},
	{
		Id = "Respawn",
		Name = "RESPAWNS",
		Short = "RESPAWN",
		Description = "Knocked out? Jump straight back into the round.",
		HowTo = "Offered when you're knocked out",
		Unit = "RESPAWN",
		Units = "RESPAWNS",
		Kind = "Use",
		Color = Color3.fromRGB(120, 210, 90),
	},
	{
		Id = "Speed",
		Name = "SPEED BOOST",
		Short = "SPEED",
		Description = "Run faster for a whole match.",
		HowTo = "",
		Unit = "MATCH",
		Units = "MATCHES",
		Kind = "Match",
		Color = Color3.fromRGB(255, 200, 40),
	},
	{
		Id = "Jump",
		Name = "JUMP BOOST",
		Short = "JUMP",
		Description = "Jump higher for a whole match.",
		HowTo = "",
		Unit = "MATCH",
		Units = "MATCHES",
		Kind = "Match",
		Color = Color3.fromRGB(80, 200, 255),
	},
	{
		Id = "Slide",
		Name = "SLIDE BOOST",
		Short = "SLIDE",
		Description = "Dive slides go further for a whole match.",
		HowTo = "",
		Unit = "MATCH",
		Units = "MATCHES",
		Kind = "Match",
		Color = Color3.fromRGB(255, 92, 168),
	},
	{
		Id = "Shield",
		Name = "SHIELD",
		Short = "SHIELD",
		Description = "A bubble that blocks the first kick, slap or grab each round of a match.",
		HowTo = "",
		Unit = "MATCH",
		Units = "MATCHES",
		Kind = "Match",
		Color = Color3.fromRGB(140, 120, 255),
	},
	{
		Id = "DoubleRewards",
		Name = "DOUBLE REWARDS",
		Short = "2X",
		Description = "Double Gumdrops and XP from a whole match.",
		HowTo = "",
		Unit = "MATCH",
		Units = "MATCHES",
		Kind = "Match",
		Color = Color3.fromRGB(255, 160, 40),
	},
}

local byId: { [string]: Def } = {}
for _, def in DEFS do
	table.freeze(def)
	byId[def.Id] = def
end

Items.List = table.freeze(DEFS)

function Items.Get(id: string): Def?
	return byId[id]
end

-- True for a real item id (checks what a client sends).
function Items.IsId(value: unknown): boolean
	return typeof(value) == "string" and byId[value] ~= nil
end

-- The ids of the items that last a whole match, in shop order.
function Items.MatchItems(): { ItemId }
	local list: { ItemId } = {}
	for _, def in DEFS do
		if def.Kind == "Match" then
			table.insert(list, def.Id)
		end
	end
	return list
end

return table.freeze(Items)
