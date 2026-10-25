--!strict
-- Draws the lobby leaderboards (Shared/Leaderboards) onto their screens: the three along the
-- plaza's west side, and the parkour tower's FASTEST TODAY board in the playground. Each shows the
-- top players with their headshots and your own row highlighted. At the bottom: your own score,
-- or on the parkour board your best time today and ever, with the day's prize and how long until
-- the board starts again. The server sends the top players; the boards redraw when they change.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Leaderboards = require(Shared.Leaderboards)
local Match = require(Shared.Match)
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
	Subtitle: TextLabel?, -- the parkour board's prize and countdown line
}

type BoardData = {
	Saved: boolean,
	Entries: { Leaderboards.Entry },
	Day: number,
	NextReset: number,
	Prize: number,
}

local CANVAS_HEIGHT = 625 -- every board is drawn this many pixels tall, whatever its size
local ROW_HEIGHT = 44
local ROWS_TOP = 104
local ROWS_TOP_WITH_SUBTITLE = 124
local WHITE = Theme.Colors.White
local ROW_COLOR = Color3.fromRGB(62, 46, 112)
local YOU_COLOR = Color3.fromRGB(255, 92, 168)
local MEDALS = {
	Color3.fromRGB(255, 205, 64),
	Color3.fromRGB(210, 214, 230),
	Color3.fromRGB(226, 150, 92),
}

local PlayerAttr = Match.PlayerAttr
local localPlayer = Players.LocalPlayer
local screens: { Screen } = {}

local function decode(boardId: string): BoardData
	local data: BoardData = { Saved = true, Entries = {}, Day = 0, NextReset = 0, Prize = 0 }
	local raw = Leaderboards.GetFolder():GetAttribute(boardId)
	if typeof(raw) ~= "string" or raw == "" then
		return data
	end
	local ok, decoded = pcall(function(): any
		return HttpService:JSONDecode(raw)
	end)
	if not ok or typeof(decoded) ~= "table" then
		return data
	end
	data.Saved = decoded.Saved ~= false
	for _, field in { "Day", "NextReset", "Prize" } do
		if typeof(decoded[field]) == "number" then
			(data :: any)[field] = decoded[field]
		end
	end
	if typeof(decoded.Entries) == "table" then
		for _, row in decoded.Entries do
			if typeof(row) == "table" and typeof(row.U) == "number" and typeof(row.V) == "number" then
				table.insert(data.Entries, {
					UserId = row.U,
					Name = if typeof(row.N) == "string" then row.N else "Wobbler",
					Value = row.V,
				})
			end
		end
	end
	return data
end

local function attributeNumber(name: string): number
	local value = localPlayer:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

-- 5h 12m / 4m 05s until the parkour board starts again.
local function countdown(secondsLeft: number): string
	local seconds = math.max(0, math.floor(secondsLeft))
	if seconds >= 3600 then
		return `{seconds // 3600}h {string.format("%02d", (seconds % 3600) // 60)}m`
	end
	return `{seconds // 60}m {string.format("%02d", seconds % 60)}s`
end

local function updateSubtitle(screen: Screen, data: BoardData)
	local subtitle = screen.Subtitle
	if not subtitle then
		return
	end
	local prize = Leaderboards.WithCommas(data.Prize)
	local left = data.NextReset - Workspace:GetServerTimeNow()
	subtitle.Text = if data.NextReset > 0 and left > 0
		then `Fastest today wins {prize} Gumdrops! · New board in {countdown(left)}`
		else `Fastest today wins {prize} Gumdrops!`
end

local function footerText(screen: Screen, data: BoardData): string
	local board = screen.Board
	local text: string
	if board.Id == "ParkourToday" then
		local todayBest = if attributeNumber(PlayerAttr.ParkourDay) == data.Day
			then attributeNumber(PlayerAttr.ParkourDayBest)
			else 0
		local best = attributeNumber(PlayerAttr.ParkourBest)
		local todayText = if todayBest > 0 then Leaderboards.FormatTime(todayBest) else "--"
		local bestText = if best > 0 then Leaderboards.FormatTime(best) else "--"
		text = `YOUR BEST  TODAY {todayText}  ·  EVER {bestText}`
	else
		text = `YOU: {Leaderboards.Format(board.Id, ProfileClient.GetStat(board.Stat))}`
	end
	return if data.Saved then text else `{text}  ·  this server`
end

local function draw(screen: Screen)
	local board = screen.Board
	local data = decode(board.Id)
	local entries = data.Entries
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
	screen.Footer.Text = footerText(screen, data)
	updateSubtitle(screen, data)
end

local function buildRow(parent: Instance, index: number, top: number): Row
	local frame: Frame = Ui.new("Frame", {
		Name = `Row{index}`,
		Size = UDim2.new(1, -28, 0, ROW_HEIGHT - 6),
		Position = UDim2.new(0.5, 0, 0, top + (index - 1) * ROW_HEIGHT),
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
		UDim2.fromOffset(30, 30),
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
		Size = UDim2.fromOffset(32, 32),
		Position = UDim2.new(0, 44, 0.5, 0),
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
		UDim2.new(1, -226, 0, 24),
		UDim2.new(0, 86, 0.5, 0),
		Vector2.new(0, 0.5)
	)
	name.TextXAlignment = Enum.TextXAlignment.Left
	local value = Ui.label(
		frame,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Yellow,
		UDim2.fromOffset(130, 24),
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
	local isParkour = board.Id == "ParkourToday"
	local rowCount = if isParkour then Config.Parkour.BoardRows else Config.Leaderboards.Rows
	local gui: SurfaceGui = Ui.new("SurfaceGui", {
		Name = `Leaderboard_{board.Id}`,
		Adornee = part,
		Face = Enum.NormalId.Front,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = CANVAS_HEIGHT / part.Size.Y,
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
	Ui.textOutline(title, Theme.Colors.Ink, 4)
	local subtitle: TextLabel? = nil
	if isParkour then
		local line = Ui.label(
			background,
			"",
			Theme.Fonts.Display,
			Theme.Colors.Yellow,
			UDim2.new(1, -30, 0, 24),
			UDim2.new(0.5, 0, 0, 94),
			Vector2.new(0.5, 0)
		)
		subtitle = line
	end
	local rowsTop = if isParkour then ROWS_TOP_WITH_SUBTITLE else ROWS_TOP
	local rows: { Row } = {}
	for index = 1, rowCount do
		rows[index] = buildRow(background, index, rowsTop)
	end
	local empty = Ui.label(
		background,
		if isParkour then "Nobody has finished today. Be the first!" else "No scores yet. Be the first!",
		Theme.Fonts.Body,
		Color3.fromRGB(220, 210, 255),
		UDim2.new(1, -60, 0, 30),
		UDim2.new(0.5, 0, 0, rowsTop + 40),
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
	local screen: Screen = { Board = board, Rows = rows, Empty = empty, Footer = footer, Subtitle = subtitle }
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
	localPlayer.AttributeChanged:Connect(function(name: string)
		if name == PlayerAttr.ParkourDayBest or name == PlayerAttr.ParkourBest or name == PlayerAttr.ParkourDay then
			drawAll()
		end
	end)
	-- The parkour board's countdown.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, screen in screens do
				if screen.Subtitle then
					updateSubtitle(screen, decode(screen.Board.Id))
				end
			end
		end
	end)
end

return LeaderboardController
