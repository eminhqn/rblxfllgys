--!strict
-- A Bloblet on a turning pedestal inside a ViewportFrame, for screens that show what items look
-- like (the customise screen and the reward track). It turns slowly by itself; drag it (mouse or
-- touch) or tilt a controller stick (SetStickSpin) to turn it yourself. FaceFront swings it back
-- round to face you for a moment (after picking an item), SetEmote plays an emote on a loop, and
-- SetSlapper puts a slapper in its hand and has it swing every couple of seconds.
--
-- The Bloblet is rebuilt only when its look changes. While the screen is hidden (SetActive false)
-- nothing is animated.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local BlobletRig = require(Shared.BlobletRig)
local Cosmetics = require(Shared.Cosmetics)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local BlobletAnimator = require(script.Parent.BlobletAnimator)

local PreviewStage = {}

export type Stage = {
	Frame: ViewportFrame,
	SetAppearance: (appearance: BlobletRig.Appearance) -> (),
	SetEmote: (emoteId: string?) -> (), -- nil stops it
	SetSlapper: (itemId: string?) -> (), -- a Slapper item id to hold, nil = none
	FaceFront: () -> (),
	SetStickSpin: (amount: number) -> (), -- -1 to 1 (0 = let it turn by itself)
	SetActive: (active: boolean) -> (),
}

local SPIN_SPEED = 0.6 -- radians per second
local DRAG_SPEED = 0.012 -- radians per pixel
local STICK_SPIN_SPEED = 3 -- radians per second at full tilt
local FACE_FRONT_TIME = 1.6 -- faces the front this long before turning on
local FACE_FRONT_RATE = 10 -- how quickly it turns back to the front
local EMOTE_LOOP_PAUSE = 0.5 -- rest between repeats of an emote
local SLAP_SWING_EVERY = 2 -- seconds between practice swings with a slapper
local SLAP_SWING_TIME = 0.4

local WHITE = Color3.fromRGB(255, 255, 255)
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)

-- The pink pedestal with studs round the rim (they show it turning).
local function buildPedestal(parent: Instance): Model
	local pedestal = Instance.new("Model")
	pedestal.Name = "Pedestal"
	local function part(name: string, shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3)
		local piece = Instance.new("Part")
		piece.Name = name
		piece.Shape = shape
		piece.Size = size
		piece.CFrame = cframe
		piece.Color = color
		piece.Material = Enum.Material.SmoothPlastic
		piece.Anchored = true
		piece.Parent = pedestal
	end
	part("Base", Enum.PartType.Cylinder, Vector3.new(1.2, 7, 7), CFrame.new(0, -0.6, 0) * UPRIGHT, Theme.Colors.Pink)
	part("Top", Enum.PartType.Cylinder, Vector3.new(0.1, 6.4, 6.4), CFrame.new(0, 0.02, 0) * UPRIGHT, WHITE)
	for index = 1, 8 do
		local angle = index / 8 * math.pi * 2
		part(
			"Stud",
			Enum.PartType.Ball,
			Vector3.one * 0.6,
			CFrame.new(math.cos(angle) * 3.3, -0.1, math.sin(angle) * 3.3),
			if index % 2 == 0 then Theme.Colors.Yellow else Theme.Colors.Aqua
		)
	end
	pedestal.WorldPivot = CFrame.new()
	pedestal.Parent = parent
	return pedestal
end

-- What a set of equipped items looks like on a Bloblet.
function PreviewStage.AppearanceFor(equipped: Cosmetics.Equipped): BlobletRig.Appearance
	local colorItem = Cosmetics.Get(equipped.Color)
	return {
		BodyColor = if colorItem and colorItem.Color then colorItem.Color else WHITE,
		Pattern = equipped.Pattern,
		Eyes = equipped.Eyes,
		Hat = equipped.Hat,
		Outfit = equipped.Outfit,
	}
end

local function appearanceKey(appearance: BlobletRig.Appearance): string
	return table.concat({
		appearance.BodyColor:ToHex(),
		appearance.Pattern,
		appearance.Eyes,
		appearance.Hat,
		appearance.Outfit,
	}, "|")
end

function PreviewStage.new(parent: Instance, size: UDim2, position: UDim2): Stage
	local viewport: ViewportFrame = Ui.new("ViewportFrame", {
		Name = "Preview",
		Size = size,
		Position = position,
		BackgroundColor3 = Color3.fromRGB(214, 236, 255),
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(200, 190, 225),
		LightColor = WHITE,
		LightDirection = Vector3.new(-0.5, -1, -0.6),
		Parent = parent,
	})
	Ui.corner(viewport, UDim.new(0, 18))
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 236, 248), Color3.fromRGB(205, 232, 255)),
		Rotation = 90,
		Parent = viewport,
	})
	local camera = Instance.new("Camera")
	camera.FieldOfView = 38
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 4.4, -11), Vector3.new(0, 2.4, 0))
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local pedestal = buildPedestal(viewport)

	local model: Model? = nil
	local key = ""
	local active = false
	local angle = 0
	local faceFrontUntil = 0
	local stickSpin = 0
	local dragInput: InputObject? = nil
	local dragLastX = 0
	local wantedEmote: string? = nil
	local shownEmote: string? = nil
	local emoteStartedAt = 0
	local wantedSlapper: string? = nil
	local lastSwing = 0

	local function place()
		local spin = CFrame.Angles(0, angle, 0)
		pedestal:PivotTo(spin)
		local current = model
		if current then
			current:PivotTo(CFrame.new(0, BlobletRig.Dimensions.RootHeight, 0) * spin)
		end
	end

	-- Plays the wanted emote, starting it again a moment after each time it finishes.
	local function updateEmote()
		local current = model
		if not current then
			return
		end
		local serverNow = Workspace:GetServerTimeNow()
		local entry = if wantedEmote then Cosmetics.Get(wantedEmote) else nil
		if wantedEmote ~= shownEmote then
			shownEmote = wantedEmote
			emoteStartedAt = serverNow
			current:SetAttribute("Emote", wantedEmote)
			current:SetAttribute("EmoteAt", if wantedEmote then serverNow else nil)
		elseif entry and entry.Duration and serverNow - emoteStartedAt > entry.Duration + EMOTE_LOOP_PAUSE then
			emoteStartedAt = serverNow
			current:SetAttribute("EmoteAt", serverNow)
		end
	end

	local function applySlapper()
		local current = model
		if current then
			BlobletRig.SetSlapper(current, wantedSlapper)
		end
	end

	-- With a slapper in hand it takes a practice swing now and then.
	local function updateSwing()
		local current = model
		if not current or not wantedSlapper then
			return
		end
		local now = os.clock()
		if now - lastSwing >= SLAP_SWING_EVERY then
			lastSwing = now
			current:SetAttribute("Action", "Slap")
		elseif now - lastSwing >= SLAP_SWING_TIME and current:GetAttribute("Action") == "Slap" then
			current:SetAttribute("Action", "None")
		end
	end

	local stage: Stage
	stage = {
		Frame = viewport,
		SetAppearance = function(appearance: BlobletRig.Appearance)
			local newKey = appearanceKey(appearance)
			if newKey == key and model then
				return
			end
			key = newKey
			local old = model
			if old then
				BlobletAnimator.RemovePreview(old)
				old:Destroy()
			end
			local built = BlobletRig.Build(appearance)
			built.Name = "Preview"
			built.Parent = viewport
			model = built
			shownEmote = nil -- the new Bloblet starts the emote again
			applySlapper()
			if active then
				BlobletAnimator.AddPreview(built)
			end
			place()
		end,
		SetEmote = function(emoteId: string?)
			wantedEmote = emoteId
		end,
		SetSlapper = function(itemId: string?)
			if itemId == wantedSlapper then
				return
			end
			wantedSlapper = itemId
			lastSwing = os.clock() - SLAP_SWING_EVERY + 0.5 -- first swing shortly after it appears
			applySlapper()
			local current = model
			if current and not itemId then
				current:SetAttribute("Action", "None")
			end
		end,
		FaceFront = function()
			faceFrontUntil = os.clock() + FACE_FRONT_TIME
		end,
		SetStickSpin = function(amount: number)
			stickSpin = if math.abs(amount) > 0.2 then math.clamp(amount, -1, 1) else 0
		end,
		SetActive = function(isActive: boolean)
			if active == isActive then
				return
			end
			active = isActive
			local current = model
			if current then
				if isActive then
					BlobletAnimator.AddPreview(current)
				else
					BlobletAnimator.RemovePreview(current) -- no need to animate it while it's hidden
				end
			end
			if not isActive then
				dragInput = nil
				stickSpin = 0
			end
		end,
	}

	-- Drag it to spin it.
	viewport.InputBegan:Connect(function(input: InputObject)
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
			dragInput = input
			dragLastX = input.Position.X
			faceFrontUntil = 0
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local drag = dragInput
		if not drag then
			return
		end
		local moved = input == drag
			or (
				drag.UserInputType == Enum.UserInputType.MouseButton1
				and input.UserInputType == Enum.UserInputType.MouseMovement
			)
		if moved then
			angle += (input.Position.X - dragLastX) * DRAG_SPEED
			dragLastX = input.Position.X
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input == dragInput then
			dragInput = nil
		end
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		if not active then
			return
		end
		if stickSpin ~= 0 then
			faceFrontUntil = 0
			angle += stickSpin * STICK_SPIN_SPEED * dt
		elseif dragInput then
			faceFrontUntil = 0
		elseif os.clock() < faceFrontUntil then
			-- Ease round to the nearest front-facing angle.
			local front = math.round(angle / (math.pi * 2)) * math.pi * 2
			angle += (front - angle) * (1 - math.exp(-FACE_FRONT_RATE * dt))
		else
			angle += dt * SPIN_SPEED
		end
		place()
		updateEmote()
		updateSwing()
	end)

	return stage
end

return PreviewStage
