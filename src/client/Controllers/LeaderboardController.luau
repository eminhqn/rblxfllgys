--!strict
-- Draws the lobby leaderboards (Shared/Leaderboards) onto their screens along the plaza's west
-- side: each board's top players with their headshots, your own row highlighted, and your own
-- score at the bottom. The server sends the top players; the boards redraw when they change.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Leaderboards = require(Shared.Leaderboards)
local Tags = require(Shared.Tags)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ProfileClient = require(script.Parent.ProfileClient)

local LeaderboardController = {}

type Row = {
	Frame: Frame,
	Rank: TextLabel,
	Headshot: ImageLabel,
	Name: TextLabel,
	Value: TextLabel,
}

type Screen = {
	Board: Leaderboards.Board,
	Rows: { Row },
	Empty: TextLabel,
	Footer: TextLabel,
}

local PIXELS_PER_STUD = 25
local ROW_HEIGHT = 46
local ROWS_TOP = 104
local WHITE = Theme.Colors.White
local ROW_COLOR = Color3.fromRGB(62, 46, 112)
local YOU_COLOR = Color3.fromRGB(255, 92, 168)
local MEDALS = {
	Color3.fromRGB(255, 205, 64),
	Color3.fromRGB(210, 214, 230),
	Color3.fromRGB(226, 150, 92),
}

local localPlayer = Players.LocalPlayer
local screens: { Screen } = {}

local function decode(boardId: string): (boolean, { Leaderboards.Entry })
	local raw = Leaderboards.GetFolder():GetAttribute(boardId)
	if typeof(raw) ~= "string" or raw == "" then
		return true, {}
	end
	local ok, data = pcall(function(): any
		return HttpService:JSONDecode(raw)
	end)
	local entries: { Leaderboards.Entry } = {}
	if not ok or typeof(data) ~= "table" then
		return true, entries
	end
	if typeof(data.Entries) == "table" then
		for _, row in data.Entries do
			if typeof(row) == "table" and typeof(row.U) == "number" and typeof(row.V) == "number" then
				table.insert(entries, {
					UserId = row.U,
					Name = if typeof(row.N) == "string" then row.N else "Wobbler",
					Value = row.V,
				})
			end
		end
	end
	return data.Saved ~= false, entries
end

local function draw(screen: Screen)
	local board = screen.Board
	local saved, entries = decode(board.Id)
	for index, row in screen.Rows do
		local entry = entries[index]
		row.Frame.Visible = entry ~= nil
		if entry then
			local isYou = entry.UserId == localPlayer.UserId
			row.Frame.BackgroundColor3 = if isYou then YOU_COLOR else ROW_COLOR
			row.Rank.Text = tostring(index)
			row.Rank.BackgroundColor3 = MEDALS[index] or Theme.Colors.Purple
			row.Rank.TextColor3 = if MEDALS[index] then Theme.Colors.Ink else WHITE
			row.Headshot.Image = if entry.UserId > 0
				then `rbxthumb://type=AvatarHeadShot&id={entry.UserId}&w=48&h=48`
				else ""
			row.Name.Text = entry.Name
			row.Value.Text = Leaderboards.Format(board.Id, entry.Value)
		end
	end
	screen.Empty.Visible = #entries == 0
	local mine = ProfileClient.GetStat(board.Stat)
	screen.Footer.Text = if saved
		then `YOU: {Leaderboards.Format(board.Id, mine)}`
		else `YOU: {Leaderboards.Format(board.Id, mine)}  ·  showing this server`
end

local function buildRow(parent: Instance, index: number): Row
	local frame: Frame = Ui.new("Frame", {
		Name = `Row{index}`,
		Size = UDim2.new(1, -28, 0, ROW_HEIGHT - 6),
		Position = UDim2.new(0.5, 0, 0, ROWS_TOP + (index - 1) * ROW_HEIGHT),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = ROW_COLOR,
		BorderSizePixel = 0,
		Visible = false,
		Parent = parent,
	})
	Ui.corner(frame, UDim.new(0, 12))
	local rank = Ui.label(
		frame,
		"",
		Theme.Fonts.Display,
		WHITE,
		UDim2.fromOffset(32, 32),
		UDim2.new(0, 6, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	rank.BackgroundTransparency = 0
	Ui.corner(rank, UDim.new(0.5, 0))
	Ui.new("UIPadding", {
		PaddingTop = UDim.new(0, 5),
		PaddingBottom = UDim.new(0, 5),
		Parent = rank,
	})
	local headshot: ImageLabel = Ui.new("ImageLabel", {
		Size = UDim2.fromOffset(34, 34),
		Position = UDim2.new(0, 46, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = Color3.fromRGB(96, 80, 150),
		BorderSizePixel = 0,
		Parent = frame,
	})
	Ui.corner(headshot, UDim.new(0.5, 0))
	local name = Ui.label(
		frame,
		"",
		Theme.Fonts.Body,
		WHITE,
		UDim2.new(1, -230, 0, 26),
		UDim2.new(0, 90, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	name.TextXAlignment = Enum.TextXAlignment.Left
	local value = Ui.label(
		frame,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Yellow,
		UDim2.fromOffset(130, 26),
		UDim2.new(1, -10, 0.5, 0),
		Vector2.new(1, 0.5)
	)
	value.TextXAlignment = Enum.TextXAlignment.Right
	return { Frame = frame, Rank = rank, Headshot = headshot, Name = name, Value = value }
end

local function buildScreen(part: BasePart)
	local board = Leaderboards.Get(tostring(part:GetAttribute("Board")))
	if not board then
		return
	end
	local gui: SurfaceGui = Ui.new("SurfaceGui", {
		Name = `Leaderboard_{board.Id}`,
		Adornee = part,
		Face = Enum.NormalId.Front,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = PIXELS_PER_STUD,
		LightInfluence = 0,
		Brightness = 1.2,
		ResetOnSpawn = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	local background: Frame = Ui.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Parent = gui,
	})
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Theme.Colors.Ink, Color3.fromRGB(88, 60, 170)),
		Rotation = 90,
		Parent = background,
	})
	local header: Frame = Ui.new("Frame", {
		Size = UDim2.new(1, 0, 0, 88),
		BackgroundColor3 = board.Color,
		BorderSizePixel = 0,
		Parent = background,
	})
	local title = Ui.label(
		header,
		board.Title,
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -30, 0, 52),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	Ui.new("UIStroke", {
		Color = Theme.Colors.Ink,
		Thickness = 4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = title,
	})
	local rows: { Row } = {}
	for index = 1, Config.Leaderboards.Rows do
		rows[index] = buildRow(background, index)
	end
	local empty = Ui.label(
		background,
		"No scores yet. Be the first!",
		Theme.Fonts.Body,
		Color3.fromRGB(220, 210, 255),
		UDim2.new(1, -60, 0, 30),
		UDim2.new(0.5, 0, 0, ROWS_TOP + 40),
		Vector2.new(0.5, 0)
	)
	local footer = Ui.label(
		background,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Aqua,
		UDim2.new(1, -40, 0, 26),
		UDim2.new(0.5, 0, 1, -14),
		Vector2.new(0.5, 1)
	)
	local screen: Screen = { Board = board, Rows = rows, Empty = empty, Footer = footer }
	table.insert(screens, screen)
	draw(screen)
end

local function drawAll()
	for _, screen in screens do
		draw(screen)
	end
end

function LeaderboardController.Init()
	local folder = Leaderboards.GetFolder()
	CollectionService:GetInstanceAddedSignal(Tags.Leaderboard):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			buildScreen(instance)
		end
	end)
	for _, instance in CollectionService:GetTagged(Tags.Leaderboard) do
		if instance:IsA("BasePart") then
			buildScreen(instance)
		end
	end
	folder.AttributeChanged:Connect(function(name: string)
		for _, screen in screens do
			if screen.Board.Id == name then
				draw(screen)
			end
		end
	end)
	ProfileClient.Changed:Connect(drawAll)
end

return LeaderboardController
