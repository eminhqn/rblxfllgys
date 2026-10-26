--!strict
-- Items: things you buy with Robux in the ITEMS shop (never with Crowns) to use in matches. A
-- profile keeps how many of each you have (they stack).
--
-- At the start of every round (while it loads and during the round card) you're shown the items
-- you have and pick the ones you want for that round. Three kinds:
--   * "Round" items (boosts, shield, double rewards): picking one uses it up, and it works for
--     that whole round.
--   * "Slap": picking it puts your slapper (a Shared/Cosmetics Slapper skin) in your hand for the
--     round, for free; each slap that lands on someone uses one.
--   * "Respawn": not picked; you're offered one when you're knocked out of a round.
-- The numbers behind each one (how much faster, how long, ...) are in Config.Items and
-- Config.Slap; the Robux packs are Config.Items.Packs.

local Items = {}

export type ItemId = "Slap" | "Respawn" | "Speed" | "Jump" | "Slide" | "Shield" | "DoubleRewards"
export type Kind = "Round" | "Slap" | "Respawn"

export type Def = {
	Id: ItemId,
	Name: string, -- shown on its card, e.g. "SPEED BOOST"
	Short: string, -- a short name for the round picker and HUD, e.g. "SPEED"
	Description: string, -- one short sentence for its card
	HowTo: string, -- how you use one
	Unit: string, -- what one of them is, for "EACH BUY GIVES 1 SLAP"
	Units: string, -- and more than one: "EACH BUY GIVES 10 SLAPS"
	Kind: Kind,
	Color: Color3,
}

local PICK_IT = "Pick it at the start of a round"

local DEFS: { Def } = {
	{
		Id = "Slap",
		Name = "SLAPS",
		Short = "SLAP",
		Description = "Carry a slapper for a round and send players flying.",
		HowTo = "Pick it for a round. Each hit uses one.",
		Unit = "SLAP",
		Units = "SLAPS",
		Kind = "Slap",
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
		Kind = "Respawn",
		Color = Color3.fromRGB(120, 210, 90),
	},
	{
		Id = "Speed",
		Name = "SPEED BOOST",
		Short = "SPEED",
		Description = "Run faster for a whole round.",
		HowTo = PICK_IT,
		Unit = "ROUND",
		Units = "ROUNDS",
		Kind = "Round",
		Color = Color3.fromRGB(255, 200, 40),
	},
	{
		Id = "Jump",
		Name = "JUMP BOOST",
		Short = "JUMP",
		Description = "Jump higher for a whole round.",
		HowTo = PICK_IT,
		Unit = "ROUND",
		Units = "ROUNDS",
		Kind = "Round",
		Color = Color3.fromRGB(80, 200, 255),
	},
	{
		Id = "Slide",
		Name = "SLIDE BOOST",
		Short = "SLIDE",
		Description = "Dive slides go further for a whole round.",
		HowTo = PICK_IT,
		Unit = "ROUND",
		Units = "ROUNDS",
		Kind = "Round",
		Color = Color3.fromRGB(255, 92, 168),
	},
	{
		Id = "Shield",
		Name = "SHIELD",
		Short = "SHIELD",
		Description = "A bubble that blocks the first kick, slap or grab in a round.",
		HowTo = PICK_IT,
		Unit = "ROUND",
		Units = "ROUNDS",
		Kind = "Round",
		Color = Color3.fromRGB(140, 120, 255),
	},
	{
		Id = "DoubleRewards",
		Name = "DOUBLE REWARDS",
		Short = "2X",
		Description = "Double Gumdrops and XP from a round.",
		HowTo = PICK_IT,
		Unit = "ROUND",
		Units = "ROUNDS",
		Kind = "Round",
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

-- Can it be picked at the start of a round? (Respawns are offered when you're knocked out.)
function Items.IsPickable(def: Def): boolean
	return def.Kind ~= "Respawn"
end

return table.freeze(Items)
