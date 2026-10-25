--!strict
-- Little 3D bursts that exist only on this client: crate splinters, respawn puffs and finish-line
-- confetti. Pieces are simple anchored parts thrown with a bit of gravity, moved together each
-- frame and faded out, with a cap on how many can exist at once.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Effects = {}

export type BurstOptions = {
	Count: number,
	Colors: { Color3 },
	Size: Vector3,
	Speed: number, -- outward launch speed (studs/s)
	Up: number?, -- extra upward launch speed
	Gravity: number?, -- studs/s^2 (default 120)
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
}

local MAX_PIECES = 220

local pieces: { Piece } = {}
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
	return created
end

local function randomUnit(): Vector3
	local vector = Vector3.new(random:NextNumber(-1, 1), random:NextNumber(-1, 1), random:NextNumber(-1, 1))
	return if vector.Magnitude > 1e-3 then vector.Unit else Vector3.yAxis
end

-- Throws `options.Count` pieces out from `position`.
function Effects.Burst(position: Vector3, options: BurstOptions)
	local parent = getFolder()
	local count = math.min(options.Count, MAX_PIECES - #pieces)
	for _ = 1, count do
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Shape = options.Shape or Enum.PartType.Block
		part.Material = options.Material or Enum.Material.SmoothPlastic
		part.Size = options.Size * random:NextNumber(0.7, 1.2)
		part.Color = options.Colors[random:NextInteger(1, #options.Colors)]
		part.CFrame = CFrame.new(position)
		part.Parent = parent
		local direction = randomUnit()
		table.insert(pieces, {
			Part = part,
			Velocity = direction * options.Speed * random:NextNumber(0.5, 1)
				+ Vector3.new(0, (options.Up or 0) * random:NextNumber(0.7, 1.2), 0),
			Spin = randomUnit() * random:NextNumber(4, 12),
			Rotation = CFrame.Angles(random:NextNumber(0, 6), random:NextNumber(0, 6), random:NextNumber(0, 6)),
			Position = position,
			Age = 0,
			Life = (options.Life or 0.9) * random:NextNumber(0.8, 1.2),
			Gravity = options.Gravity or 120,
		})
	end
end

local function step(dt: number)
	if #pieces == 0 then
		return
	end
	local parts: { BasePart } = {}
	local cframes: { CFrame } = {}
	for index = #pieces, 1, -1 do
		local piece = pieces[index]
		piece.Age += dt
		if piece.Age >= piece.Life then
			piece.Part:Destroy()
			table.remove(pieces, index)
			continue
		end
		piece.Velocity -= Vector3.new(0, piece.Gravity * dt, 0)
		piece.Position += piece.Velocity * dt
		local spin = piece.Spin * dt
		piece.Rotation = CFrame.Angles(spin.X, spin.Y, spin.Z) * piece.Rotation
		local fade = piece.Age / piece.Life
		piece.Part.Transparency = if fade > 0.6 then (fade - 0.6) / 0.4 else 0
		table.insert(parts, piece.Part)
		table.insert(cframes, CFrame.new(piece.Position) * piece.Rotation)
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function Effects.Init()
	RunService.RenderStepped:Connect(step)
end

return Effects
