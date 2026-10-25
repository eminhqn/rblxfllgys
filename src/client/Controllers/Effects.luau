--!strict
-- Little 3D bursts that exist only on this client: crate splinters, respawn puffs, confetti and
-- firework sparks. Pieces are simple anchored parts thrown with a bit of gravity, moved together
-- each frame and faded out, with a cap on how many can exist at once. Finished pieces are kept
-- (hidden) and reused, so busy moments don't keep creating and destroying parts.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Effects = {}

export type BurstOptions = {
	Count: number,
	Colors: { Color3 },
	Size: Vector3,
	Speed: number, -- launch speed (studs/s)
	Up: number?, -- extra upward launch speed
	Direction: Vector3?, -- throw this way (default: every direction)
	Spread: number?, -- with Direction: 0 = a straight line, 1 = a wide cone (default 0.35)
	Gravity: number?, -- studs/s^2 (default 120)
	Drag: number?, -- how fast pieces slow down in the air (0 = not at all, confetti ~1.5)
	Life: number?, -- seconds (default 0.9)
	Shape: Enum.PartType?,
	Material: Enum.Material?,
}

type Piece = {
	Part: Part,
	Velocity: Vector3,
	Spin: Vector3,
	Rotation: CFrame,
	Position: Vector3,
	Age: number,
	Life: number,
	Gravity: number,
	Drag: number,
}

local MAX_PIECES = 320
local SPARE_LIMIT = 160 -- hidden parts kept for reuse
local HIDDEN_CFRAME = CFrame.new(0, -10000, 0)

local pieces: { Piece } = {}
local spare: { Part } = {}
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local folder: Folder? = nil
local random = Random.new()

local function getFolder(): Folder
	local existing = folder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "WobbleEffects"
	created.Parent = Workspace
	folder = created
	table.clear(spare) -- they went with the old folder
	return created
end

local function randomUnit(): Vector3
	local vector = Vector3.new(random:NextNumber(-1, 1), random:NextNumber(-1, 1), random:NextNumber(-1, 1))
	return if vector.Magnitude > 1e-3 then vector.Unit else Vector3.yAxis
end

local function takePart(parent: Folder): Part
	local part = table.remove(spare)
	if part and part.Parent == parent then
		part.Transparency = 0
		return part
	end
	local created = Instance.new("Part")
	created.Anchored = true
	created.CanCollide = false
	created.CanQuery = false
	created.CanTouch = false
	created.CastShadow = false
	created.Parent = parent
	return created
end

local function releasePart(part: Part)
	if #spare < SPARE_LIMIT and part.Parent then
		part.Transparency = 1
		part.CFrame = HIDDEN_CFRAME
		table.insert(spare, part)
	else
		part:Destroy()
	end
end

-- Throws `options.Count` pieces out from `position`.
function Effects.Burst(position: Vector3, options: BurstOptions)
	local parent = getFolder()
	local count = math.min(options.Count, MAX_PIECES - #pieces)
	local direction = options.Direction
	local aim = if direction and direction.Magnitude > 1e-3 then direction.Unit else nil
	local spread = options.Spread or 0.35
	for _ = 1, count do
		local part = takePart(parent)
		part.Shape = options.Shape or Enum.PartType.Block
		part.Material = options.Material or Enum.Material.SmoothPlastic
		part.Size = options.Size * random:NextNumber(0.7, 1.2)
		part.Color = options.Colors[random:NextInteger(1, #options.Colors)]
		part.CFrame = CFrame.new(position)
		local launch = if aim then (aim + randomUnit() * spread).Unit else randomUnit()
		table.insert(pieces, {
			Part = part,
			Velocity = launch * options.Speed * random:NextNumber(0.5, 1)
				+ Vector3.new(0, (options.Up or 0) * random:NextNumber(0.7, 1.2), 0),
			Spin = randomUnit() * random:NextNumber(4, 12),
			Rotation = CFrame.Angles(random:NextNumber(0, 6), random:NextNumber(0, 6), random:NextNumber(0, 6)),
			Position = position,
			Age = 0,
			Life = (options.Life or 0.9) * random:NextNumber(0.8, 1.2),
			Gravity = options.Gravity or 120,
			Drag = options.Drag or 0,
		})
	end
end

local function step(dt: number)
	if #pieces == 0 then
		return
	end
	table.clear(moveParts)
	table.clear(moveCFrames)
	local index = 1
	while index <= #pieces do
		local piece = pieces[index]
		piece.Age += dt
		if piece.Age >= piece.Life then
			releasePart(piece.Part)
			-- Swap in the last piece instead of shifting the whole list down.
			pieces[index] = pieces[#pieces]
			pieces[#pieces] = nil
			continue
		end
		local velocity = piece.Velocity - Vector3.new(0, piece.Gravity * dt, 0)
		if piece.Drag > 0 then
			velocity *= math.exp(-piece.Drag * dt)
		end
		piece.Velocity = velocity
		piece.Position += velocity * dt
		local spin = piece.Spin * dt
		piece.Rotation = CFrame.Angles(spin.X, spin.Y, spin.Z) * piece.Rotation
		local fade = piece.Age / piece.Life
		if fade > 0.6 then
			piece.Part.Transparency = (fade - 0.6) / 0.4
		end
		table.insert(moveParts, piece.Part)
		table.insert(moveCFrames, CFrame.new(piece.Position) * piece.Rotation)
		index += 1
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function Effects.Init()
	RunService.RenderStepped:Connect(step)
end

return Effects
