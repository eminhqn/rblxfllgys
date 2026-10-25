--!strict
-- Helpers for building the soft, inflatable-looking world out of plain parts.
-- Everything is anchored and SmoothPlastic unless an option says otherwise.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Shared.Theme)
local Ui = require(ReplicatedStorage.Shared.Ui)

export type PartOptions = {
	Name: string?,
	Material: Enum.Material?,
	Transparency: number?,
	CanCollide: boolean?, -- default true; false also turns off CanQuery/CanTouch
	CastShadow: boolean?,
}

local Geometry = {}

local function applyOptions(part: Part, options: PartOptions?)
	local opts: PartOptions = options or {}
	part.Name = opts.Name or "Part"
	part.Material = opts.Material or Enum.Material.SmoothPlastic
	part.Transparency = opts.Transparency or 0
	local canCollide = if opts.CanCollide == nil then true else opts.CanCollide
	part.CanCollide = canCollide
	if not canCollide then
		part.CanQuery = false
		part.CanTouch = false
	end
	part.CastShadow = if opts.CastShadow == nil then true else opts.CastShadow
end

local function basePart(parent: Instance, shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.Shape = shape
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

function Geometry.model(parent: Instance, name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

-- A model that streams to clients in one piece. It starts with no parent: build everything inside
-- it, then parent it, so clients never receive the model before its parts.
function Geometry.atomicModel(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	return model
end

function Geometry.block(parent: Instance, size: Vector3, cframe: CFrame, color: Color3, options: PartOptions?): Part
	local part = basePart(parent, Enum.PartType.Block, size, cframe, color)
	applyOptions(part, options)
	return part
end

function Geometry.ball(
	parent: Instance,
	diameter: number,
	position: Vector3,
	color: Color3,
	options: PartOptions?
): Part
	local part = basePart(parent, Enum.PartType.Ball, Vector3.one * diameter, CFrame.new(position), color)
	applyOptions(part, options)
	return part
end

-- Cylinder standing upright with its bottom face centred on `bottom`.
function Geometry.column(
	parent: Instance,
	height: number,
	diameter: number,
	bottom: Vector3,
	color: Color3,
	options: PartOptions?
): Part
	local cframe = CFrame.new(bottom + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	local part = basePart(parent, Enum.PartType.Cylinder, Vector3.new(height, diameter, diameter), cframe, color)
	applyOptions(part, options)
	return part
end

-- A padded, inflatable-looking tube between two points, with rounded caps.
function Geometry.tube(
	parent: Instance,
	from: Vector3,
	to: Vector3,
	diameter: number,
	color: Color3,
	options: PartOptions?
): Part
	local offset = to - from
	local length = offset.Magnitude
	local middle = (from + to) / 2
	local cframe: CFrame
	if math.abs(offset.Unit.Y) > 0.99 then
		cframe = CFrame.new(middle) * CFrame.Angles(0, 0, math.pi / 2)
	else
		-- Cylinders run along their X axis; turn the look direction into the X axis.
		cframe = CFrame.lookAt(middle, to) * CFrame.Angles(0, math.pi / 2, 0)
	end
	local part = basePart(parent, Enum.PartType.Cylinder, Vector3.new(length, diameter, diameter), cframe, color)
	applyOptions(part, options)
	local capOptions: PartOptions = {
		Name = "TubeCap",
		CanCollide = if options then options.CanCollide else nil,
		CastShadow = false,
	}
	Geometry.ball(parent, diameter, from, color, capOptions)
	Geometry.ball(parent, diameter, to, color, capOptions)
	return part
end

-- A stretched sphere (a block part with a sphere SpecialMesh).
function Geometry.ellipsoid(parent: Instance, size: Vector3, cframe: CFrame, color: Color3, options: PartOptions?): Part
	local part = basePart(parent, Enum.PartType.Block, size, cframe, color)
	applyOptions(part, options)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

-- A post-mounted sign facing -Z (towards the team decks). Returns the board part.
function Geometry.sign(
	parent: Instance,
	text: string,
	bottom: Vector3,
	width: number,
	height: number,
	accent: Color3,
	postHeight: number
): Part
	Geometry.column(parent, postHeight, 0.7, bottom, Color3.fromRGB(255, 255, 255), { CastShadow = false })
	local boardCenter = bottom + Vector3.new(0, postHeight + height / 2, 0)
	local board = Geometry.block(parent, Vector3.new(width, height, 0.6), CFrame.new(boardCenter), accent, {
		Name = "Sign",
	})
	local gui: SurfaceGui = Ui.new("SurfaceGui", {
		Face = Enum.NormalId.Front,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 40,
		LightInfluence = 0.2,
		Parent = board,
	})
	local panel = Ui.panel(gui, UDim2.new(1, -24, 1, -24), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	local label = Ui.label(panel.Body, text, Theme.Fonts.Display, Theme.Colors.Ink, UDim2.fromScale(0.92, 0.8))
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	return board
end

return Geometry
