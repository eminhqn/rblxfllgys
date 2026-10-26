--!strict
-- The tutorial island: a short course floating west of the plaza, one stretch for each step of
-- Shared/Tutorial (walk to a ring, jump onto a step, jump + dive over a gap, grab a dummy, kick
-- a dummy, bounce up to the finish). Built once when the server starts; TutorialService runs it.
-- The course runs along +Z from the start pad.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Geometry = require(script.Parent.Geometry)
local Hazards = require(script.Parent.Hazards)

local TutorialBuilder = {}

-- A box a Bloblet's middle has to be in to finish a step.
export type Zone = {
	CFrame: CFrame,
	Size: Vector3,
}

export type Course = {
	Zones: { [number]: Zone }, -- by step number, for the steps you finish by getting somewhere
	Spots: { [number]: CFrame }, -- by step number: where you're put back if you fall
	GrabDummy: Vector3,
	KickDummy: Vector3,
	Center: Vector3, -- of the whole course
}

local ORIGIN = Vector3.new(-160, 50, -40) -- the middle of the start pad's back edge
local PAD = Color3.fromRGB(255, 236, 246)
local PATH = Color3.fromRGB(200, 236, 255)
local STEP_COLOR = Color3.fromRGB(255, 205, 64)
local ISLAND = Color3.fromRGB(130, 220, 170)
local FINISH = Color3.fromRGB(255, 160, 200)
local CLOUD = Color3.fromRGB(250, 252, 255)
local DECOR: Geometry.PartOptions = { Name = "Decor", CanCollide = false, CastShadow = false }

-- A point on the course: `across` to the side, `up`, and `along` from the start.
local function at(across: number, up: number, along: number): Vector3
	return ORIGIN + Vector3.new(across, up, along)
end

local function floor(
	parent: Instance,
	from: number,
	to: number,
	width: number,
	top: number,
	color: Color3,
	name: string
)
	local middle = at(0, top, (from + to) / 2)
	Hazards.Platform(
		parent,
		CFrame.lookAt(middle, middle + Vector3.zAxis),
		Vector3.new(width, 4, to - from),
		color,
		name
	)
end

local function zone(across: number, up: number, along: number, size: Vector3): Zone
	return { CFrame = CFrame.new(at(across, up, along)), Size = size }
end

-- A round training dummy on a post: a ball with eyes and target rings, and a label.
local function dummy(parent: Instance, spot: Vector3, color: Color3, text: string)
	local model = Geometry.model(parent, "Dummy")
	Geometry.column(model, 1.4, 1.2, spot, Color3.fromRGB(255, 255, 255), { Name = "Post" })
	local middle = spot + Vector3.new(0, 3.2, 0)
	Geometry.ball(model, 4.2, middle, color, { Name = "Body" })
	-- Target rings on its front (cylinders turned to face -Z).
	for index, size in { 3.2, 2.2, 1.2 } do
		local ring = Geometry.column(
			model,
			0.12,
			size,
			middle,
			if index % 2 == 1 then Color3.fromRGB(255, 255, 255) else Theme.Colors.Pink,
			DECOR
		)
		ring.CFrame = CFrame.new(middle - Vector3.new(0, 0, 2.06 + index * 0.02)) * CFrame.Angles(0, math.pi / 2, 0)
	end
	for _, side in { -1, 1 } do
		Geometry.ball(model, 0.9, middle + Vector3.new(side * 0.8, 0.9, -1.6), Color3.fromRGB(255, 255, 255), DECOR)
		Geometry.ball(model, 0.45, middle + Vector3.new(side * 0.8, 0.85, -2.0), Theme.Colors.Ink, DECOR)
	end
	local anchor = Geometry.block(model, Vector3.one * 0.4, CFrame.new(middle + Vector3.new(0, 4, 0)), color, {
		Name = "LabelAnchor",
		Transparency = 1,
		CanCollide = false,
	})
	local gui: BillboardGui = Ui.new("BillboardGui", {
		Size = UDim2.fromOffset(200, 50),
		LightInfluence = 0,
		MaxDistance = 120,
		Parent = anchor,
	})
	local label = Ui.label(
		gui,
		text,
		Theme.Fonts.Display,
		color,
		UDim2.fromScale(1, 1),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	Ui.stroke(label, Theme.Colors.Ink, 3)
end

function TutorialBuilder.Build(parent: Instance): Course
	local island = Geometry.model(parent, "TutorialIsland")
	island.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	-- 1. Start pad, and a path to a glowing ring.
	floor(island, 0, 20, 22, 0, PAD, "StartPad")
	floor(island, 20, 34, 12, 0, PATH, "Path")
	for index = 1, 16 do
		local angle = index / 16 * math.pi * 2
		local piece = Geometry.block(
			island,
			Vector3.new(1.6, 0.12, 0.6),
			CFrame.lookAt(at(math.cos(angle) * 3.4, 0.08, 27 + math.sin(angle) * 3.4), at(0, 0.08, 27)),
			Theme.Colors.Yellow,
			DECOR
		)
		piece.Material = Enum.Material.Neon
	end
	Geometry.sign(island, "1  WALK", at(-8, 0, 14), 10, 2.6, Theme.Colors.Aqua, 4)

	-- 2. A step to jump onto.
	floor(island, 34, 46, 12, 3, STEP_COLOR, "Step")
	Geometry.sign(island, "2  JUMP", at(-8, 0, 30), 10, 2.6, Theme.Colors.Yellow, 4)

	-- 3. A gap too far to jump: jump, then dive. Then a grassy island.
	floor(island, 62, 74, 14, 3, ISLAND, "Island")
	Geometry.sign(island, "3  JUMP + DIVE", at(-9, 3, 42), 12, 2.6, Theme.Colors.Pink, 4)

	-- 4 and 5. A path with two dummies: grab one, kick the other.
	floor(island, 74, 108, 14, 3, PATH, "DummyPath")
	local grabSpot = at(0, 3, 84)
	local kickSpot = at(0, 3, 96)
	dummy(island, grabSpot, Theme.Colors.Pink, "GRAB ME")
	dummy(island, kickSpot, Theme.Colors.Yellow, "KICK ME")
	Geometry.sign(island, "4  GRAB", at(-9, 3, 78), 9, 2.6, Theme.Colors.Purple, 4)
	Geometry.sign(island, "5  KICK", at(-9, 3, 91), 9, 2.6, Theme.Colors.Orange, 4)

	-- 6. A trampoline up to the finish.
	Hazards.BouncePad(island, at(0, 3, 102), { Power = 90 })
	floor(island, 110, 126, 20, 18, FINISH, "Finish")
	Geometry.sign(island, "6  BOUNCE UP!", at(-9, 3, 99), 11, 2.6, Theme.Colors.Lime, 4)
	Hazards.Crown(island, at(0, 26, 118), 0.8)

	-- Clouds under it all.
	local random = Random.new(11)
	for along = 0, 126, 9 do
		for _, side in { -1, 1 } do
			Geometry.ellipsoid(
				island,
				Vector3.new(random:NextNumber(12, 18), random:NextNumber(6, 9), random:NextNumber(10, 14)),
				CFrame.new(at(side * random:NextNumber(4, 9), -6, along)),
				CLOUD,
				DECOR
			)
		end
	end

	local standing = Vector3.new(0, 6, 0) -- zones reach from the floor up past a Bloblet's middle
	return {
		Zones = {
			[1] = zone(0, 2, 27, Vector3.new(8, 6, 8)),
			[2] = zone(0, 5, 40, Vector3.new(12, 0, 12) + standing),
			[3] = zone(0, 5, 68, Vector3.new(14, 0, 12) + standing),
			[6] = zone(0, 20, 118, Vector3.new(20, 0, 16) + standing),
		},
		Spots = {
			[1] = CFrame.lookAt(at(0, 0, 8), at(0, 0, 30)),
			[2] = CFrame.lookAt(at(0, 0, 28), at(0, 0, 40)),
			[3] = CFrame.lookAt(at(0, 3, 40), at(0, 3, 70)),
			[4] = CFrame.lookAt(at(0, 3, 77), at(0, 3, 90)),
			[5] = CFrame.lookAt(at(0, 3, 88), at(0, 3, 100)),
			[6] = CFrame.lookAt(at(0, 3, 92), at(0, 3, 110)),
		},
		GrabDummy = grabSpot + Vector3.new(0, 3.2, 0),
		KickDummy = kickSpot + Vector3.new(0, 3.2, 0),
		Center = at(0, 5, 63),
	}
end

return TutorialBuilder
