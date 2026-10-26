--!strict
-- The music for the lobby and every round. Each song is a short recipe (tempo, key, four chords,
-- and a style for the drums, the bass and the tune on top) that Compile turns into a four-bar loop
-- of notes; MusicController plays the loop with Roblox's built-in sounds, so nothing needs
-- uploading. Every round has its own recipe (a round without one uses its type's), and a few have
-- background sounds too (water, wind, bubbling syrup).
--
-- To change a round's music, change its recipe below: Seed picks a different tune with the same
-- feel. To use your own uploaded music instead, see Config.Music.

local MusicSongs = {}

export type DrumStyle = "Chill" | "Bouncy" | "Driving" | "Tense" | "March"
export type BassStyle = "Roots" | "Pulse" | "Octaves" | "Walk" | "Bounce"
export type LeadStyle = "Melody" | "Arp" | "Stabs" | "Slow"
export type Ambience = "Water" | "Wind" | "Bubbles"
export type Instrument = "Lead" | "Bass" | "Chord" | "Kick" | "Snare" | "Hat"

export type Recipe = {
	Tempo: number, -- beats per minute
	Key: number, -- semitones up (or down) from the base note
	Minor: boolean,
	Chords: { number }, -- the scale degree (1 to 7) of the chord in each of the four bars
	Drums: DrumStyle,
	Bass: BassStyle,
	Lead: LeadStyle,
	Seed: number, -- picks the tune
	Ambience: Ambience?,
}

export type Note = {
	Step: number, -- sixteenth notes from the start of the loop (0 to 63)
	Instrument: Instrument,
	Semitones: number, -- above the base note (drums: unused)
	Volume: number,
}

export type Song = {
	Tempo: number,
	Notes: { Note }, -- in order of Step
	Ambience: Ambience?,
}

MusicSongs.LoopSteps = 64 -- four bars of sixteen sixteenth notes

local function recipe(
	tempo: number,
	key: number,
	minor: boolean,
	chords: { number },
	drums: DrumStyle,
	bass: BassStyle,
	lead: LeadStyle,
	seed: number,
	ambience: Ambience?
): Recipe
	return {
		Tempo = tempo,
		Key = key,
		Minor = minor,
		Chords = chords,
		Drums = drums,
		Bass = bass,
		Lead = lead,
		Seed = seed,
		Ambience = ambience,
	}
end

-- By round id (Info.Id), then the fallbacks by round type, and the lobby's.
local RECIPES: { [string]: Recipe } = {
	Lobby = recipe(104, 0, false, { 1, 6, 4, 5 }, "Chill", "Roots", "Melody", 11),

	Race = recipe(138, 0, false, { 1, 5, 6, 4 }, "Driving", "Octaves", "Arp", 2),
	Survival = recipe(120, 0, true, { 1, 4, 6, 5 }, "Tense", "Pulse", "Melody", 4),
	Team = recipe(126, 0, false, { 1, 4, 5, 4 }, "Bouncy", "Walk", "Stabs", 6),
	Final = recipe(132, 0, true, { 1, 6, 7, 5 }, "March", "Octaves", "Melody", 8),

	ConveyorCanyon = recipe(134, 2, false, { 1, 4, 5, 1 }, "Driving", "Pulse", "Arp", 3),
	BouncePadGauntlet = recipe(142, -3, false, { 1, 5, 6, 4 }, "Bouncy", "Octaves", "Melody", 5),
	SugarSlopes = recipe(136, 5, false, { 1, 6, 4, 5 }, "Driving", "Walk", "Arp", 7, "Wind"),
	TumbleTower = recipe(128, 0, false, { 6, 4, 1, 5 }, "Driving", "Pulse", "Melody", 9, "Wind"),
	SplashSlide = recipe(146, 4, false, { 1, 5, 4, 5 }, "Bouncy", "Octaves", "Arp", 13, "Water"),

	RisingTide = recipe(116, -2, true, { 1, 7, 6, 7 }, "Tense", "Pulse", "Slow", 17, "Water"),
	BalloonBarrage = recipe(124, 1, false, { 1, 4, 1, 5 }, "Bouncy", "Bounce", "Stabs", 19),
	PinwheelPanic = recipe(130, 3, true, { 1, 6, 3, 7 }, "Driving", "Octaves", "Arp", 23),
	JigglyJelly = recipe(112, -5, false, { 1, 3, 4, 5 }, "Chill", "Bounce", "Melody", 29, "Bubbles"),

	PaintGrab = recipe(128, 2, false, { 1, 4, 6, 5 }, "Bouncy", "Walk", "Stabs", 31),
	GumballGoal = recipe(122, -1, false, { 1, 5, 4, 4 }, "Bouncy", "Bounce", "Melody", 37),
	TugOfWobble = recipe(118, 0, true, { 1, 4, 5, 1 }, "March", "Pulse", "Stabs", 41, "Wind"),
	EggScramble = recipe(132, 6, false, { 1, 6, 2, 5 }, "Bouncy", "Walk", "Arp", 43),
	SprinkleHills = recipe(126, 1, false, { 4, 5, 1, 6 }, "Driving", "Octaves", "Melody", 47),

	CloudCrown = recipe(128, 0, false, { 1, 5, 6, 4 }, "March", "Octaves", "Melody", 53, "Wind"),
	PopcornPlates = recipe(136, -4, true, { 1, 6, 7, 5 }, "Driving", "Pulse", "Arp", 59),
	KingOfTheCake = recipe(124, 3, false, { 1, 4, 5, 6 }, "March", "Walk", "Melody", 61),
}

local MAJOR = { 0, 2, 4, 5, 7, 9, 11 }
local MINOR = { 0, 2, 3, 5, 7, 8, 10 }

-- Sixteen-step patterns: "x" plays, "." rests.
local DRUMS: { [DrumStyle]: { Kick: string, Snare: string, Hat: string } } = {
	Chill = { Kick = "x.........x.....", Snare = "........x.......", Hat = "..x...x...x...x." },
	Bouncy = { Kick = "x.....x.x.......", Snare = "....x.......x...", Hat = "x.x.x.x.x.x.x.x." },
	Driving = { Kick = "x...x...x...x...", Snare = "....x.......x...", Hat = "xxxxxxxxxxxxxxxx" },
	Tense = { Kick = "x..x..x.x..x....", Snare = "........x.......", Hat = "..x...x...x...x." },
	March = { Kick = "x.......x.......", Snare = "....x.......x.xx", Hat = "x...x...x...x..." },
}

-- A tune's rhythm for one bar.
local RHYTHMS = {
	"x..x..x.x...x...",
	"x.x.x...x.x.x...",
	"x...x.x.x...x.x.",
	"x.....x.x.x.x...",
	"x..x..x...x.x...",
}

local function hits(pattern: string): { number }
	local list: { number } = {}
	for index = 1, #pattern do
		if string.sub(pattern, index, index) == "x" then
			table.insert(list, index - 1)
		end
	end
	return list
end

-- Semitones of a scale degree (1 = the key note; 8 = an octave up; 0 or less = below).
local function degree(scale: { number }, value: number): number
	local index = (value - 1) % 7
	local octave = (value - 1 - index) // 7
	return scale[index + 1] + 12 * octave
end

-- The nearest of the chord's notes (scale degrees) to `value`.
local function nearestChordTone(root: number, value: number): number
	local best, bestGap = value, math.huge
	for octave = -2, 2 do
		for _, offset in { 0, 2, 4 } do
			local tone = root + offset + 7 * octave
			local gap = math.abs(tone - value)
			if gap < bestGap then
				best, bestGap = tone, gap
			end
		end
	end
	return best
end

-- Turns a recipe into a loop of notes.
function MusicSongs.Compile(source: Recipe): Song
	local random = Random.new(source.Seed)
	local scale = if source.Minor then MINOR else MAJOR
	local notes: { Note } = {}
	local function add(step: number, instrument: Instrument, semitones: number, volume: number)
		table.insert(notes, {
			Step = step,
			Instrument = instrument,
			Semitones = semitones + source.Key,
			Volume = volume,
		})
	end

	local drums = DRUMS[source.Drums]
	for bar = 0, 3 do
		local base = bar * 16
		local root = source.Chords[bar + 1] or 1
		-- Drums (a little fill at the end of the loop).
		for _, step in hits(drums.Kick) do
			add(base + step, "Kick", 0, 1)
		end
		for _, step in hits(drums.Snare) do
			add(base + step, "Snare", 0, 1)
		end
		for _, step in hits(drums.Hat) do
			add(base + step, "Hat", 0, if step % 4 == 0 then 1 else 0.6)
		end
		if bar == 3 then
			for _, step in { 13, 14, 15 } do
				add(base + step, "Snare", 0, 0.6)
			end
		end

		-- Bass, two octaves down.
		local style = source.Bass
		if style == "Roots" then
			for _, step in { 0, 8 } do
				add(base + step, "Bass", degree(scale, root) - 24, 1)
			end
		elseif style == "Pulse" then
			for step = 0, 14, 2 do
				add(base + step, "Bass", degree(scale, root) - 24, if step % 4 == 0 then 1 else 0.7)
			end
		elseif style == "Octaves" then
			for step = 0, 14, 2 do
				add(base + step, "Bass", degree(scale, root) - 24 + (if step % 4 == 2 then 12 else 0), 0.9)
			end
		elseif style == "Walk" then
			for index, offset in { 0, 2, 4, 5 } do
				add(base + (index - 1) * 4, "Bass", degree(scale, root + offset) - 24, 0.9)
			end
		else -- Bounce: root and fifth, skipping along
			for index, step in { 0, 3, 6, 8, 11, 14 } do
				add(base + step, "Bass", degree(scale, root + (if index % 2 == 0 then 4 else 0)) - 24, 0.85)
			end
		end
	end

	-- The tune on top, an octave up. A tune repeats its first bar's shape (A A' B A'').
	local lead = source.Lead
	if lead == "Arp" then
		local orders = { { 0, 2, 4, 7 }, { 7, 4, 2, 0 }, { 0, 4, 7, 4 }, { 0, 2, 4, 2 } }
		local order = orders[random:NextInteger(1, #orders)]
		for bar = 0, 3 do
			local root = source.Chords[bar + 1] or 1
			for step = 0, 14, 2 do
				local tone = root + order[(step // 2) % #order + 1]
				add(bar * 16 + step, "Lead", degree(scale, tone) + 12, if step % 4 == 0 then 0.9 else 0.65)
			end
		end
	elseif lead == "Stabs" then
		for bar = 0, 3 do
			local root = source.Chords[bar + 1] or 1
			for _, step in { 2, 6, 10, 14 } do
				for _, offset in { 0, 2, 4 } do
					add(bar * 16 + step, "Chord", degree(scale, root + offset), 0.8)
				end
			end
		end
	else
		local slow = lead == "Slow"
		local first = if slow then "x.......x......." else RHYTHMS[random:NextInteger(1, #RHYTHMS)]
		local second = if slow then "x...x...x......." else RHYTHMS[random:NextInteger(1, #RHYTHMS)]
		local shapes: { { number } } = {}
		local function shapeFor(rhythm: string): { number }
			local moves: { number } = {}
			for _ in hits(rhythm) do
				table.insert(moves, random:NextInteger(-2, 2))
			end
			return moves
		end
		shapes[1] = shapeFor(first)
		shapes[2] = shapeFor(second)
		local barRhythms = { first, first, second, first }
		local barShapes = { 1, 1, 2, 1 }
		local pitch = 8 -- scale degree, an octave up
		for bar = 0, 3 do
			local root = (source.Chords[bar + 1] or 1) + 7
			local shape = shapes[barShapes[bar + 1]]
			local steps = hits(barRhythms[bar + 1])
			for index, step in steps do
				if bar == 3 and index == #steps then
					pitch = nearestChordTone(source.Chords[1] + 7, pitch) -- end the loop at home
				elseif step % 8 == 0 then
					pitch = nearestChordTone(root, pitch + shape[index])
				else
					pitch = math.clamp(pitch + shape[index], 5, 14)
				end
				add(bar * 16 + step, "Lead", degree(scale, pitch), if step % 8 == 0 then 1 else 0.8)
			end
		end
	end

	table.sort(notes, function(a: Note, b: Note): boolean
		return a.Step < b.Step
	end)
	return { Tempo = source.Tempo, Notes = notes, Ambience = source.Ambience }
end

local compiled: { [string]: Song } = {}

-- The song for a round id (or round type, or "Lobby"), compiled the first time it's asked for.
function MusicSongs.Get(id: string, roundType: string?): Song
	local key = if RECIPES[id] then id elseif roundType and RECIPES[roundType] then roundType else "Lobby"
	local song = compiled[key]
	if not song then
		song = MusicSongs.Compile(RECIPES[key])
		compiled[key] = song
	end
	return song
end

return MusicSongs
