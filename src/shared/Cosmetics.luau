--!strict
-- Everything players can unlock and wear, and the two currencies:
--   Crowns   - what items cost. You win one by winning a match...
--   Gumdrops - ...or earn them just by playing rounds and trade 500 of them for a Crown, so
--              everyone can unlock things, not only the best players.
--
-- Item ids are unique across slots. Items with Price 0 belong to everyone. Items with a Level
-- can't be bought: they're exclusive rewards on the reward track (Shared/Progression), unlocked by
-- reaching that player level, and each has a Rarity. Items with a Premium level are the same, but
-- on the PREMIUM track (you need the premium pass, Config.Premium). Everything that costs Crowns
-- has a Shop kind: it's only sold while it's in the cosmetic shop (Shared/ItemShop picks the
-- daily and weekly ones), never from the customise tabs; once bought it's yours to wear like any
-- other. The server is the only place that grants items, Crowns or Gumdrops; clients use this
-- list to draw the customise screen.
-- How each item looks is built in BlobletCosmetics (hats, outfits, patterns, lashes, slappers);
-- colours and eye shapes are applied by BlobletRig; emotes are animated by the client
-- BlobletAnimator. A Slapper is the skin of the slapper you hold in a round when you've picked
-- SLAPS (Shared/Items); it only shows then (and in the customise preview).

export type Slot = "Color" | "Pattern" | "Eyes" | "Hat" | "Outfit" | "Emote" | "Slapper"

export type Rarity = "Rare" | "Epic" | "Legendary"

export type ShopKind = "Daily" | "Weekly"

-- One item id per slot: what a player is wearing (and their emote).
export type Equipped = {
	Color: string,
	Pattern: string,
	Eyes: string,
	Hat: string,
	Outfit: string,
	Emote: string,
	Slapper: string,
}

export type Item = {
	Id: string,
	Slot: Slot,
	Name: string,
	Price: number, -- Crowns; 0 = free for everyone
	Color: Color3?, -- Color items: the body colour
	Swatch: Color3, -- colour of the item's card
	Duration: number?, -- Emote items: seconds
	Level: number?, -- reward track exclusives: the player level that unlocks it (can't be bought)
	Premium: number?, -- PREMIUM track exclusives: the level that unlocks it with the premium pass
	Rarity: Rarity?, -- reward track exclusives and the rarer shop items
	Shop: ShopKind?, -- item shop only: sold while it's in the day's or week's shop
}

local Cosmetics = {}

local SLOTS: { string } = { "Color", "Pattern", "Eyes", "Hat", "Outfit", "Emote", "Slapper" }
table.freeze(SLOTS)

Cosmetics.SlotLabels = table.freeze({
	Color = "COLOUR",
	Pattern = "PATTERN",
	Eyes = "EYES",
	Hat = "HAT",
	Outfit = "OUTFIT",
	Emote = "EMOTE",
	Slapper = "SLAPPER",
} :: { [string]: string })

local PINK = Color3.fromRGB(255, 92, 168)
local AQUA = Color3.fromRGB(64, 214, 230)
local PURPLE = Color3.fromRGB(132, 104, 255)
local YELLOW = Color3.fromRGB(255, 200, 48)
local LIME = Color3.fromRGB(116, 222, 92)
local ORANGE = Color3.fromRGB(255, 132, 72)

local function color(id: string, name: string, value: Color3, price: number): Item
	return { Id = "Color_" .. id, Slot = "Color", Name = name, Price = price, Color = value, Swatch = value }
end

local function item(slot: Slot, id: string, name: string, price: number, swatch: Color3, duration: number?): Item
	return { Id = slot .. "_" .. id, Slot = slot, Name = name, Price = price, Swatch = swatch, Duration = duration }
end

-- A reward track exclusive: unlocked at `level`, never sold.
local function exclusive(base: Item, level: number, rarity: Rarity): Item
	base.Price = 0
	base.Level = level
	base.Rarity = rarity
	return base
end

-- A PREMIUM track exclusive: unlocked at `level` by players with the premium pass, never sold.
local function premium(base: Item, level: number, rarity: Rarity): Item
	base.Price = 0
	base.Premium = level
	base.Rarity = rarity
	return base
end

-- Only sold in the item shop, on the days (or weeks) it's there.
local function shop(base: Item, kind: ShopKind, rarity: Rarity?): Item
	base.Shop = kind
	base.Rarity = rarity
	return base
end

local items: { Item } = {
	-- Body colours: the first ten are free (new players start with a random one); the others are
	-- sold in the cosmetic shop, like everything else that costs Crowns.
	color("Bubblegum", "Bubblegum", PINK, 0),
	color("Lagoon", "Lagoon", AQUA, 0),
	color("Grape", "Grape", PURPLE, 0),
	color("Lemon", "Lemon", YELLOW, 0),
	color("Apple", "Apple", LIME, 0),
	color("Tangerine", "Tangerine", ORANGE, 0),
	color("Ocean", "Ocean", Color3.fromRGB(80, 156, 255), 0),
	color("Coral", "Coral", Color3.fromRGB(255, 120, 120), 0),
	color("Violet", "Violet", Color3.fromRGB(190, 110, 255), 0),
	color("Mint", "Mint", Color3.fromRGB(40, 200, 160), 0),
	shop(color("Snow", "Snow", Color3.fromRGB(246, 246, 252), 1), "Daily"),
	shop(color("Cocoa", "Cocoa", Color3.fromRGB(150, 98, 72), 1), "Daily"),
	shop(color("Cherry", "Cherry", Color3.fromRGB(226, 38, 72), 1), "Daily"),
	shop(color("Midnight", "Midnight", Color3.fromRGB(58, 52, 112), 1), "Daily"),
	shop(color("Charcoal", "Charcoal", Color3.fromRGB(72, 72, 84), 1), "Daily"),
	shop(color("RoseGold", "Rose Gold", Color3.fromRGB(232, 164, 150), 2), "Daily"),
	shop(color("Honey", "Honey", Color3.fromRGB(242, 168, 36), 2), "Daily"),
	exclusive(color("Sunset", "Sunset", Color3.fromRGB(255, 118, 92), 0), 8, "Rare"),
	exclusive(color("Golden", "Golden", Color3.fromRGB(255, 196, 40), 0), 17, "Epic"),
	premium(color("Diamond", "Diamond", Color3.fromRGB(170, 236, 255), 0), 4, "Rare"),

	item("Pattern", "None", "Plain", 0, Color3.fromRGB(235, 228, 245)),
	item("Pattern", "Belly", "Belly Patch", 0, Color3.fromRGB(255, 226, 238)),
	shop(item("Pattern", "RosyCheeks", "Rosy Cheeks", 1, Color3.fromRGB(255, 150, 180)), "Daily"),
	shop(item("Pattern", "Spots", "Spots", 2, Color3.fromRGB(255, 206, 230)), "Daily"),
	shop(item("Pattern", "Stripes", "Stripes", 2, Color3.fromRGB(200, 236, 255)), "Daily"),
	exclusive(item("Pattern", "Stars", "Starry", 0, Color3.fromRGB(255, 226, 90)), 6, "Rare"),
	premium(item("Pattern", "Sparkles", "Sparkles", 0, Color3.fromRGB(200, 180, 255)), 16, "Epic"),

	item("Eyes", "Classic", "Classic", 0, Color3.fromRGB(245, 245, 255)),
	shop(item("Eyes", "Big", "Big Eyes", 1, Color3.fromRGB(220, 240, 255)), "Daily"),
	shop(item("Eyes", "Dot", "Dot Eyes", 1, Color3.fromRGB(235, 235, 245)), "Daily"),
	shop(item("Eyes", "Sleepy", "Sleepy", 2, Color3.fromRGB(210, 205, 245)), "Daily"),
	shop(item("Eyes", "Lashes", "Lashes", 2, Color3.fromRGB(255, 220, 240)), "Daily"),

	item("Hat", "None", "No Hat", 0, Color3.fromRGB(235, 228, 245)),
	shop(item("Hat", "Beanie", "Beanie", 2, PURPLE), "Daily"),
	shop(item("Hat", "Bow", "Big Bow", 2, PINK), "Daily"),
	shop(item("Hat", "Flower", "Flower", 3, LIME), "Daily"),
	shop(item("Hat", "TopHat", "Top Hat", 3, Color3.fromRGB(60, 48, 100)), "Daily"),
	shop(item("Hat", "Propeller", "Propeller Cap", 4, YELLOW), "Daily"),
	shop(item("Hat", "Crown", "Crown", 6, Color3.fromRGB(255, 205, 64)), "Daily"),
	exclusive(item("Hat", "PartyHat", "Party Hat", 0, Color3.fromRGB(255, 120, 200)), 3, "Rare"),
	exclusive(item("Hat", "UnicornHorn", "Unicorn Horn", 0, Color3.fromRGB(255, 236, 160)), 20, "Epic"),
	exclusive(item("Hat", "Halo", "Halo", 0, Color3.fromRGB(255, 240, 150)), 30, "Legendary"),
	premium(item("Hat", "Headphones", "Headphones", 0, Color3.fromRGB(80, 80, 120)), 12, "Rare"),
	premium(item("Hat", "PirateHat", "Pirate Hat", 0, Color3.fromRGB(50, 44, 60)), 22, "Epic"),

	item("Outfit", "None", "Nothing", 0, Color3.fromRGB(235, 228, 245)),
	shop(item("Outfit", "BowTie", "Bow Tie", 2, Color3.fromRGB(230, 50, 80)), "Daily"),
	shop(item("Outfit", "Scarf", "Scarf", 2, AQUA), "Daily"),
	shop(item("Outfit", "Tutu", "Tutu", 3, Color3.fromRGB(255, 170, 214)), "Daily"),
	shop(item("Outfit", "Cape", "Hero Cape", 4, Color3.fromRGB(226, 38, 72)), "Daily"),
	exclusive(item("Outfit", "Jetpack", "Jetpack", 0, Color3.fromRGB(150, 160, 190)), 11, "Epic"),
	exclusive(item("Outfit", "RubberRing", "Rubber Ring", 0, Color3.fromRGB(255, 120, 150)), 13, "Rare"),
	exclusive(item("Outfit", "FairyWings", "Fairy Wings", 0, Color3.fromRGB(200, 180, 255)), 25, "Legendary"),
	premium(item("Outfit", "Balloons", "Balloon Bunch", 0, Color3.fromRGB(255, 120, 190)), 25, "Epic"),
	premium(item("Outfit", "RoyalCape", "Royal Cape", 0, Color3.fromRGB(120, 60, 200)), 28, "Legendary"),
	premium(item("Outfit", "GoldenWings", "Golden Wings", 0, Color3.fromRGB(255, 196, 40)), 30, "Legendary"),

	-- More for the daily shop (Shared/ItemShop puts some of every Daily item on sale each day).
	shop(color("Lava", "Lava", Color3.fromRGB(255, 84, 40), 2), "Daily"),
	shop(color("Lilac", "Lilac", Color3.fromRGB(206, 170, 255), 2), "Daily"),
	shop(color("Seafoam", "Seafoam", Color3.fromRGB(130, 232, 200), 2), "Daily"),
	shop(item("Pattern", "Freckles", "Freckles", 3, Color3.fromRGB(214, 150, 120)), "Daily"),
	shop(item("Pattern", "Hearts", "Hearts", 3, Color3.fromRGB(255, 96, 140)), "Daily"),
	shop(item("Pattern", "Zigzag", "Zigzag", 3, Color3.fromRGB(255, 236, 160)), "Daily"),
	shop(item("Eyes", "Googly", "Googly Eyes", 2, Color3.fromRGB(250, 250, 255)), "Daily"),
	shop(item("Eyes", "Beady", "Beady Eyes", 2, Color3.fromRGB(225, 225, 240)), "Daily"),
	shop(item("Hat", "ChefHat", "Chef Hat", 4, Color3.fromRGB(250, 250, 255)), "Daily"),
	shop(item("Hat", "CatEars", "Cat Ears", 3, Color3.fromRGB(255, 180, 200)), "Daily"),
	shop(item("Outfit", "Backpack", "Backpack", 3, ORANGE), "Daily"),
	shop(item("Outfit", "Lei", "Flower Lei", 3, Color3.fromRGB(255, 120, 190)), "Daily"),

	-- Weekly item shop: two of these, Monday to Monday.
	shop(item("Hat", "WizardHat", "Wizard Hat", 7, Color3.fromRGB(96, 64, 200)), "Weekly", "Epic"),
	shop(item("Hat", "VikingHelmet", "Viking Helmet", 7, Color3.fromRGB(170, 176, 196)), "Weekly", "Epic"),
	shop(item("Hat", "Astronaut", "Space Helmet", 9, Color3.fromRGB(170, 220, 255)), "Weekly", "Legendary"),
	shop(item("Outfit", "DragonWings", "Dragon Wings", 10, Color3.fromRGB(220, 60, 70)), "Weekly", "Legendary"),
	shop(item("Outfit", "Shell", "Turtle Shell", 7, Color3.fromRGB(90, 170, 90)), "Weekly", "Epic"),
	shop(item("Pattern", "Rainbow", "Rainbow", 6, Color3.fromRGB(255, 160, 80)), "Weekly", "Epic"),

	item("Emote", "Wave", "Wave", 0, YELLOW, 1.6),
	shop(item("Emote", "Spin", "Spin", 1, AQUA, 1.2), "Daily"),
	shop(item("Emote", "Wiggle", "Wiggle Dance", 2, PINK, 2.2), "Daily"),
	shop(item("Emote", "Flop", "Belly Flop", 2, ORANGE, 2.0), "Daily"),
	exclusive(item("Emote", "Backflip", "Backflip", 0, PURPLE, 1.3), 15, "Epic"),
	premium(item("Emote", "Cartwheel", "Cartwheel", 0, AQUA, 1.4), 19, "Epic"),

	-- Slappers: what you slap with (SLAPS item). The foam hand is everyone's.
	item("Slapper", "Hand", "Foam Hand", 0, Color3.fromRGB(255, 120, 70)),
	shop(item("Slapper", "Spatula", "Spatula", 2, Color3.fromRGB(70, 70, 86)), "Daily"),
	shop(item("Slapper", "Spoon", "Wooden Spoon", 2, Color3.fromRGB(206, 150, 90)), "Daily"),
	shop(item("Slapper", "ButterKnife", "Butter Knife", 3, Color3.fromRGB(200, 206, 222)), "Daily"),
	shop(item("Slapper", "Fish", "Floppy Fish", 3, Color3.fromRGB(110, 170, 230)), "Daily"),
	shop(item("Slapper", "ToySword", "Toy Sword", 4, Color3.fromRGB(80, 150, 255)), "Daily"),
	shop(item("Slapper", "FryingPan", "Frying Pan", 4, Color3.fromRGB(60, 60, 72)), "Daily"),
	shop(item("Slapper", "Baguette", "Baguette", 3, Color3.fromRGB(226, 170, 90)), "Daily"),
	shop(item("Slapper", "PoolNoodle", "Pool Noodle", 3, Color3.fromRGB(80, 220, 120)), "Daily"),
	shop(item("Slapper", "CandyCane", "Candy Cane", 4, Color3.fromRGB(230, 50, 70)), "Daily"),
	shop(item("Slapper", "Lollipop", "Giant Lollipop", 7, Color3.fromRGB(255, 120, 200)), "Weekly", "Epic"),
	shop(item("Slapper", "GlowSword", "Glow Sword", 9, Color3.fromRGB(90, 230, 255)), "Weekly", "Legendary"),
	exclusive(item("Slapper", "RubberChicken", "Rubber Chicken", 0, Color3.fromRGB(255, 220, 60)), 9, "Rare"),
	exclusive(item("Slapper", "GoldenSpatula", "Golden Spatula", 0, Color3.fromRGB(255, 196, 40)), 27, "Legendary"),
	premium(item("Slapper", "GoldenFish", "Golden Fish", 0, Color3.fromRGB(255, 200, 60)), 8, "Rare"),
}

local byId: { [string]: Item } = {}
local bySlot: { [Slot]: { Item } } = {}
for _, entry in items do
	assert(not byId[entry.Id], `duplicate cosmetic id {entry.Id}`)
	byId[entry.Id] = table.freeze(entry)
	local list = bySlot[entry.Slot] or {}
	table.insert(list, entry)
	bySlot[entry.Slot] = list
end

Cosmetics.Items = table.freeze(items)

-- What everyone starts with (the starting colour is picked at random from the free ones).
Cosmetics.Defaults = table.freeze({
	Color = "Color_Bubblegum",
	Pattern = "Pattern_None",
	Eyes = "Eyes_Classic",
	Hat = "Hat_None",
	Outfit = "Outfit_None",
	Emote = "Emote_Wave",
	Slapper = "Slapper_Hand",
} :: Equipped)

-- The item in `slot` (Equipped is a plain record, so this is how to index it by slot name).
function Cosmetics.InSlot(equipped: Equipped, slot: string): string
	return (equipped :: any)[slot]
end

function Cosmetics.SetSlot(equipped: Equipped, slot: string, itemId: string)
	(equipped :: any)[slot] = itemId
end

-- Every slot, in the order the customise screen shows them.
function Cosmetics.AllSlots(): { string }
	return SLOTS
end

function Cosmetics.Get(id: string): Item?
	return byId[id]
end

function Cosmetics.ForSlot(slot: string): { Item }
	return bySlot[slot :: Slot] or {}
end

function Cosmetics.IsSlot(value: unknown): boolean
	return typeof(value) == "string" and Cosmetics.SlotLabels[value] ~= nil
end

-- Free for everyone (not a reward track exclusive, which also has Price 0).
function Cosmetics.IsFree(entry: Item): boolean
	return entry.Price == 0 and entry.Level == nil and entry.Premium == nil
end

-- Card and label colours for each rarity.
Cosmetics.RarityColors = table.freeze({
	Rare = Color3.fromRGB(64, 150, 255),
	Epic = Color3.fromRGB(170, 90, 255),
	Legendary = Color3.fromRGB(255, 176, 30),
} :: { [string]: Color3 })

-- The free body colours, for picking a new player's starting colour.
function Cosmetics.FreeColors(): { Item }
	local list: { Item } = {}
	for _, entry in Cosmetics.ForSlot("Color") do
		if Cosmetics.IsFree(entry) then
			table.insert(list, entry)
		end
	end
	return list
end

-- The short name an item goes by inside its slot ("Hat_Crown" -> "Crown").
function Cosmetics.Style(id: string): string
	local entry = byId[id]
	if not entry then
		return "None"
	end
	return string.sub(entry.Id, #entry.Slot + 2)
end

return table.freeze(Cosmetics)
