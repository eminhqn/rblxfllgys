--!strict
-- Everything players can unlock and wear, and the soft currency they buy it with.
--
-- Item ids are unique across slots. Items with Price 0 belong to everyone. The server is the only
-- place that grants items or Gumdrops; clients use this list to draw the customise screen.
-- How each item looks is built in BlobletCosmetics (hats, outfits, patterns, lashes); colours and
-- eye shapes are applied by BlobletRig; emotes are animated by the client BlobletAnimator.

export type Slot = "Color" | "Pattern" | "Eyes" | "Hat" | "Outfit" | "Emote"

-- One item id per slot: what a player is wearing (and their emote).
export type Equipped = {
	Color: string,
	Pattern: string,
	Eyes: string,
	Hat: string,
	Outfit: string,
	Emote: string,
}

export type Item = {
	Id: string,
	Slot: Slot,
	Name: string,
	Price: number, -- Gumdrops; 0 = free for everyone
	Color: Color3?, -- Color items: the body colour
	Swatch: Color3, -- colour of the item's card
	Duration: number?, -- Emote items: seconds
}

local Cosmetics = {}

Cosmetics.CurrencyName = "Gumdrops"

local SLOTS: { string } = { "Color", "Pattern", "Eyes", "Hat", "Outfit", "Emote" }
table.freeze(SLOTS)

Cosmetics.SlotLabels = table.freeze({
	Color = "COLOUR",
	Pattern = "PATTERN",
	Eyes = "EYES",
	Hat = "HAT",
	Outfit = "OUTFIT",
	Emote = "EMOTE",
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

local items: { Item } = {
	-- Body colours: the first ten are free (new players start with a random one).
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
	color("Snow", "Snow", Color3.fromRGB(246, 246, 252), 60),
	color("Cocoa", "Cocoa", Color3.fromRGB(150, 98, 72), 60),
	color("Cherry", "Cherry", Color3.fromRGB(226, 38, 72), 75),
	color("Midnight", "Midnight", Color3.fromRGB(58, 52, 112), 75),
	color("Charcoal", "Charcoal", Color3.fromRGB(72, 72, 84), 75),
	color("RoseGold", "Rose Gold", Color3.fromRGB(232, 164, 150), 100),
	color("Honey", "Honey", Color3.fromRGB(242, 168, 36), 100),

	item("Pattern", "None", "Plain", 0, Color3.fromRGB(235, 228, 245)),
	item("Pattern", "Belly", "Belly Patch", 0, Color3.fromRGB(255, 226, 238)),
	item("Pattern", "RosyCheeks", "Rosy Cheeks", 80, Color3.fromRGB(255, 150, 180)),
	item("Pattern", "Spots", "Spots", 120, Color3.fromRGB(255, 206, 230)),
	item("Pattern", "Stripes", "Stripes", 150, Color3.fromRGB(200, 236, 255)),

	item("Eyes", "Classic", "Classic", 0, Color3.fromRGB(245, 245, 255)),
	item("Eyes", "Big", "Big Eyes", 80, Color3.fromRGB(220, 240, 255)),
	item("Eyes", "Dot", "Dot Eyes", 80, Color3.fromRGB(235, 235, 245)),
	item("Eyes", "Sleepy", "Sleepy", 100, Color3.fromRGB(210, 205, 245)),
	item("Eyes", "Lashes", "Lashes", 150, Color3.fromRGB(255, 220, 240)),

	item("Hat", "None", "No Hat", 0, Color3.fromRGB(235, 228, 245)),
	item("Hat", "Beanie", "Beanie", 150, PURPLE),
	item("Hat", "Bow", "Big Bow", 180, PINK),
	item("Hat", "Flower", "Flower", 200, LIME),
	item("Hat", "TopHat", "Top Hat", 250, Color3.fromRGB(60, 48, 100)),
	item("Hat", "Propeller", "Propeller Cap", 300, YELLOW),
	item("Hat", "Crown", "Crown", 450, Color3.fromRGB(255, 205, 64)),

	item("Outfit", "None", "Nothing", 0, Color3.fromRGB(235, 228, 245)),
	item("Outfit", "BowTie", "Bow Tie", 120, Color3.fromRGB(230, 50, 80)),
	item("Outfit", "Scarf", "Scarf", 180, AQUA),
	item("Outfit", "Tutu", "Tutu", 220, Color3.fromRGB(255, 170, 214)),
	item("Outfit", "Cape", "Hero Cape", 300, Color3.fromRGB(226, 38, 72)),

	item("Emote", "Wave", "Wave", 0, YELLOW, 1.6),
	item("Emote", "Spin", "Spin", 100, AQUA, 1.2),
	item("Emote", "Wiggle", "Wiggle Dance", 150, PINK, 2.2),
	item("Emote", "Flop", "Belly Flop", 200, ORANGE, 2.0),
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

-- The free body colours, for picking a new player's starting colour.
function Cosmetics.FreeColors(): { Item }
	local list: { Item } = {}
	for _, entry in Cosmetics.ForSlot("Color") do
		if entry.Price == 0 then
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
