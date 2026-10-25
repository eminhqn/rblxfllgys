--!strict
-- Everything you see during a match:
--   * the round bar in the top stack: type, round number, game name, timer and the live counter
--     ("QUALIFIED 3 / 7")
--   * in team rounds, a team score bar under it (each team's share in its colour)
--   * the round card (name and rules) followed by the 3-2-1-GO countdown
--   * QUALIFIED! / ELIMINATED! stamps, with confetti when you qualify
--   * a CHECKPOINT! pop-up in race rounds, pop-ups for Paint Grab power-ups, and messages the
--     round announces to everyone (e.g. "CORAL SCORES!")
--   * a "get out of the water" countdown while you're floating (Rising Tide)
--   * the winner banner with confetti, shown to everyone in the server

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Teams = require(Shared.Teams)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local ClientEvents = require(script.Parent.ClientEvents)
local Effects = require(script.Parent.Effects)
local Hud = require(script.Parent.Hud)
local MatchClient = require(script.Parent.MatchClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local Sfx = require(script.Parent.Sfx)

local RoundHud = {}

local Attr = Match.Attr

local TYPE_COLORS: { [string]: Color3 } = {
	Race = Theme.Colors.Yellow,
	Survival = Theme.Colors.Aqua,
	Team = Theme.Colors.Purple,
	Final = Theme.Colors.Pink,
}
local CONFETTI_COLORS = {
	Theme.Colors.Pink,
	Theme.Colors.Aqua,
	Theme.Colors.Yellow,
	Theme.Colors.Purple,
	Theme.Colors.Lime,
	Theme.Colors.Orange,
}

local STAMP_HOLD = 1.9
local TOAST_HOLD = 1.1
local GO_HOLD = 0.8
local ROUND_OVER_HOLD = 2.6
local WINNER_DELAY_FOR_PLAYERS = 0.9 -- wait for the transition wipe to clear
local CONFETTI_PIECES = 90
local QUALIFY_CONFETTI_PIECES = 45

type Bar = {
	Panel: Ui.Panel,
	TypeChip: Frame,
	TypeLabel: TextLabel,
	Round: TextLabel,
	Name: TextLabel,
	Timer: TextLabel,
	Counter: TextLabel,
}

type ScoreBar = {
	Panel: Ui.Panel,
	LabelRow: Frame,
	Track: Frame,
	Labels: { [string]: TextLabel },
	Segments: { [string]: Frame },
	HasScores: boolean,
}

type TeamScore = {
	Id: string,
	Score: number,
}

type Card = {
	Holder: Frame,
	Group: CanvasGroup,
	TypeChip: Frame,
	TypeLabel: TextLabel,
	Round: TextLabel,
	Name: TextLabel,
	Rules: TextLabel,
}

type Winner = {
	Holder: Frame,
	Group: CanvasGroup,
	Title: TextLabel,
	Name: TextLabel,
}

local localPlayer = Players.LocalPlayer
local gui: ScreenGui
local bar: Bar
local scoreBar: ScoreBar
local card: Card
local winner: Winner
local countdownLabel: TextLabel
local stampLabel: TextLabel
local roundOverLabel: TextLabel
local drownLabel: TextLabel
local toastLabel: TextLabel
local confettiLayer: Frame

local cardVisible = false
local lastCountdownNumber = -1
local previousStatus: string = "None"
local stampToken = 0
local toastToken = 0
local lastCheckpoint = 0
local bigTextToken = 0

local function formatTime(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

local function leftAligned(label: TextLabel): TextLabel
	label.TextXAlignment = Enum.TextXAlignment.Left
	return label
end

local function rightAligned(label: TextLabel): TextLabel
	label.TextXAlignment = Enum.TextXAlignment.Right
	return label
end

local function outline(label: TextLabel, color: Color3, thickness: number)
	Ui.new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})
end

local function typeChip(parent: Instance, size: UDim2, position: UDim2, anchor: Vector2): (Frame, TextLabel)
	local chip: Frame = Ui.new("Frame", {
		Name = "TypeChip",
		Size = size,
		Position = position,
		AnchorPoint = anchor,
		BackgroundColor3 = Theme.Colors.Yellow,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(chip, UDim.new(0.5, 0))
	local label = Ui.label(
		chip,
		"",
		Theme.Fonts.Display,
		Theme.Colors.White,
		UDim2.new(1, -18, 1, -10),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 4
	return chip, label
end

local function setType(chip: Frame, label: TextLabel)
	local roundType = MatchClient.GetString(Attr.RoundType)
	chip.BackgroundColor3 = TYPE_COLORS[roundType] or Theme.Colors.Purple
	local typeText = (Match.TypeLabels :: { [string]: string })[roundType]
	label.Text = typeText or string.upper(roundType)
end

-------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------

local function buildBar()
	local panel = Ui.panel(Hud.GetTopStack(), UDim2.fromOffset(460, 86), UDim2.new(), Vector2.zero)
	panel.Root.LayoutOrder = Hud.TopOrder.RoundBar
	panel.Root.Visible = false
	local chip, typeLabel = typeChip(panel.Body, UDim2.fromOffset(116, 28), UDim2.fromOffset(16, 12), Vector2.zero)
	bar = {
		Panel = panel,
		TypeChip = chip,
		TypeLabel = typeLabel,
		Round = leftAligned(
			Ui.label(
				panel.Body,
				"",
				Theme.Fonts.Body,
				Theme.Colors.InkSoft,
				UDim2.fromOffset(130, 22),
				UDim2.fromOffset(142, 15)
			)
		),
		Name = leftAligned(
			Ui.label(
				panel.Body,
				"",
				Theme.Fonts.Display,
				Theme.Colors.Ink,
				UDim2.fromOffset(280, 32),
				UDim2.fromOffset(16, 46)
			)
		),
		Timer = rightAligned(
			Ui.label(
				panel.Body,
				"",
				Theme.Fonts.Display,
				Theme.Colors.Purple,
				UDim2.fromOffset(110, 36),
				UDim2.new(1, -16, 0, 9),
				Vector2.new(1, 0)
			)
		),
		Counter = rightAligned(
			Ui.label(
				panel.Body,
				"",
				Theme.Fonts.Body,
				Theme.Colors.InkSoft,
				UDim2.fromOffset(240, 22),
				UDim2.new(1, -16, 0, 52),
				Vector2.new(1, 0)
			)
		),
	}
end

local function buildScoreBar()
	local panel = Ui.panel(Hud.GetTopStack(), UDim2.fromOffset(460, 64), UDim2.new(), Vector2.zero)
	panel.Root.LayoutOrder = Hud.TopOrder.TeamScores
	panel.Root.Visible = false
	local labelRow: Frame = Ui.new("Frame", {
		Name = "Labels",
		Size = UDim2.new(1, -32, 0, 24),
		Position = UDim2.fromOffset(16, 8),
		BackgroundTransparency = 1,
		Parent = panel.Body,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 18),
		}),
	})
	-- Unpainted / unclaimed share shows as the pale track behind the team segments.
	local track: Frame = Ui.new("Frame", {
		Name = "Track",
		Size = UDim2.new(1, -32, 0, 16),
		Position = UDim2.fromOffset(16, 38),
		BackgroundColor3 = Theme.Colors.PanelTint,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = panel.Body,
	}, {
		Ui.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	Ui.corner(track, UDim.new(0.5, 0))
	track:SetAttribute("TouchTransparency", 0.5) -- see-through like its panel on touch screens
	scoreBar = {
		Panel = panel,
		LabelRow = labelRow,
		Track = track,
		Labels = {},
		Segments = {},
		HasScores = false,
	}
end

local function buildCard()
	local holder: Frame = Ui.new("Frame", {
		Name = "RoundCard",
		Size = UDim2.fromOffset(580, 280),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	local group: CanvasGroup = Ui.new("CanvasGroup", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	local panel = Ui.panel(group, UDim2.new(1, 0, 1, -Theme.ShadowOffset), UDim2.new(), Vector2.zero)
	local chip, typeLabel =
		typeChip(panel.Body, UDim2.fromOffset(170, 38), UDim2.new(0.5, 0, 0, 22), Vector2.new(0.5, 0))
	local rules = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Body,
		Theme.Colors.Ink,
		UDim2.new(1, -70, 0, 74),
		UDim2.new(0.5, 0, 0, 176),
		Vector2.new(0.5, 0)
	)
	rules.TextWrapped = true
	Ui.new("UITextSizeConstraint", { MaxTextSize = 30, Parent = rules })
	card = {
		Holder = holder,
		Group = group,
		TypeChip = chip,
		TypeLabel = typeLabel,
		Round = Ui.label(
			panel.Body,
			"",
			Theme.Fonts.Body,
			Theme.Colors.InkSoft,
			UDim2.fromOffset(200, 24),
			UDim2.new(0.5, 0, 0, 70),
			Vector2.new(0.5, 0)
		),
		Name = Ui.label(
			panel.Body,
			"",
			Theme.Fonts.Display,
			Theme.Colors.Ink,
			UDim2.new(1, -40, 0, 70),
			UDim2.new(0.5, 0, 0, 98),
			Vector2.new(0.5, 0)
		),
		Rules = rules,
	}
end

-- A big centred text. The holder scales with the screen; the label inside gets its own pop scale.
local function bigText(name: string, size: Vector2, position: UDim2, color: Color3, stroke: Color3): TextLabel
	local holder: Frame = Ui.new("Frame", {
		Name = name,
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	local label = Ui.label(
		holder,
		"",
		Theme.Fonts.Display,
		color,
		UDim2.fromScale(1, 1),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.Visible = false
	outline(label, stroke, 7)
	return label
end

local function buildCenterTexts()
	countdownLabel =
		bigText("Countdown", Vector2.new(420, 200), UDim2.fromScale(0.5, 0.42), Theme.Colors.White, Theme.Colors.Ink)
	stampLabel =
		bigText("Stamp", Vector2.new(680, 130), UDim2.fromScale(0.5, 0.42), Theme.Colors.Lime, Theme.Colors.White)
	stampLabel.Rotation = -6
	roundOverLabel =
		bigText("RoundOver", Vector2.new(420, 70), UDim2.fromScale(0.5, 0.27), Theme.Colors.Yellow, Theme.Colors.Ink)
	roundOverLabel.Text = "ROUND OVER!"
	drownLabel =
		bigText("DrownWarning", Vector2.new(560, 80), UDim2.fromScale(0.5, 0.64), Theme.Colors.Pink, Theme.Colors.White)
	toastLabel = bigText("Toast", Vector2.new(460, 72), UDim2.fromScale(0.5, 0.3), Theme.Colors.Aqua, Theme.Colors.Ink)
end

-- The server puts a DrownAt time on your Bloblet while you're in the water.
local function updateDrownWarning()
	local character = localPlayer.Character
	local drownAt = if character then character:GetAttribute("DrownAt") else nil
	local remaining = if typeof(drownAt) == "number" and drownAt > 0 then drownAt - MatchClient.ServerTime() else -1
	if remaining > 0 and MatchClient.GetStatus() == "Playing" then
		drownLabel.Text = string.format("GET OUT OF THE WATER! %.1f", remaining)
		-- Pulse faster as time runs out.
		local pulse = 0.5 + 0.5 * math.sin(os.clock() * (8 + 10 / math.max(remaining, 0.3)))
		drownLabel.TextColor3 = Theme.Colors.Pink:Lerp(Theme.Colors.Yellow, pulse)
		drownLabel.Visible = true
	elseif drownLabel.Visible then
		drownLabel.Visible = false
	end
end

local function buildWinner()
	local holder: Frame = Ui.new("Frame", {
		Name = "WinnerBanner",
		Size = UDim2.fromOffset(640, 210),
		-- Low on the screen, so it doesn't hide the winner in the middle of it.
		Position = UDim2.new(0.5, 0, 1, -56),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	ResponsiveScale.Attach(holder, "Hud")
	local group: CanvasGroup = Ui.new("CanvasGroup", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	local panel = Ui.panel(group, UDim2.new(1, 0, 1, -Theme.ShadowOffset), UDim2.new(), Vector2.zero)
	Ui.new("UIGradient", {
		Color = ColorSequence.new(Theme.Colors.White, Theme.Colors.PanelTint),
		Rotation = 90,
		Parent = panel.Body,
	})
	local title = Ui.label(
		panel.Body,
		"WINNER!",
		Theme.Fonts.Display,
		Theme.Colors.Yellow,
		UDim2.new(1, -40, 0, 80),
		UDim2.new(0.5, 0, 0, 20),
		Vector2.new(0.5, 0)
	)
	outline(title, Theme.Colors.Ink, 5)
	winner = {
		Holder = holder,
		Group = group,
		Title = title,
		Name = Ui.label(
			panel.Body,
			"",
			Theme.Fonts.Display,
			Theme.Colors.Purple,
			UDim2.new(1, -60, 0, 64),
			UDim2.new(0.5, 0, 0, 112),
			Vector2.new(0.5, 0)
		),
	}

	confettiLayer = Ui.new("Frame", {
		Name = "Confetti",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 20,
		Parent = gui,
	})
end

-------------------------------------------------------------------------------------------------
-- Behaviour
-------------------------------------------------------------------------------------------------

local function fillRoundInfo()
	local round = MatchClient.GetNumber(Attr.RoundNumber)
	local name = string.upper(MatchClient.GetString(Attr.RoundName))
	setType(bar.TypeChip, bar.TypeLabel)
	bar.Round.Text = `ROUND {round}`
	bar.Name.Text = name
	bar.Counter.Text = MatchClient.GetString(Attr.CounterText)
	setType(card.TypeChip, card.TypeLabel)
	card.Round.Text = `ROUND {round}`
	card.Name.Text = name
	card.Rules.Text = MatchClient.GetString(Attr.RoundRules)
end

local function showCard()
	if cardVisible then
		return
	end
	cardVisible = true
	card.Holder.Visible = true
	card.Group.GroupTransparency = 1
	card.Group.Position = UDim2.fromOffset(0, 50)
	Ui.tween(card.Group, Theme.Tweens.Pop, { GroupTransparency = 0, Position = UDim2.new() })
end

local function hideCard()
	if not cardVisible then
		return
	end
	cardVisible = false
	local tween =
		Ui.tween(card.Group, Theme.Tweens.Smooth, { GroupTransparency = 1, Position = UDim2.fromOffset(0, -40) })
	tween.Completed:Once(function()
		if not cardVisible then
			card.Holder.Visible = false
		end
	end)
end

-- Pops a big word in the middle of the screen (countdown numbers, GO!).
local function popBigText(text: string, color: Color3, hold: number?)
	bigTextToken += 1
	local token = bigTextToken
	countdownLabel.Text = text
	countdownLabel.TextColor3 = color
	countdownLabel.TextTransparency = 0
	countdownLabel.Visible = true
	local scale = Ui.scaleOf(countdownLabel)
	scale.Scale = 1.8
	Ui.tween(scale, Theme.Tweens.Pop, { Scale = 1 })
	if hold then
		task.delay(hold, function()
			if bigTextToken == token then
				local fade = Ui.tween(countdownLabel, Theme.Tweens.Smooth, { TextTransparency = 1 })
				fade.Completed:Once(function()
					if bigTextToken == token then
						countdownLabel.Visible = false
					end
				end)
			end
		end)
	end
end

local function hideBigText()
	bigTextToken += 1
	countdownLabel.Visible = false
end

local function stamp(text: string, color: Color3)
	stampToken += 1
	local token = stampToken
	stampLabel.Text = text
	stampLabel.TextColor3 = color
	stampLabel.TextTransparency = 0
	stampLabel.Visible = true
	local scale = Ui.scaleOf(stampLabel)
	scale.Scale = 2.4
	Ui.tween(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
	task.delay(STAMP_HOLD, function()
		if stampToken ~= token then
			return
		end
		local fade = Ui.tween(stampLabel, Theme.Tweens.Smooth, { TextTransparency = 1 })
		fade.Completed:Once(function()
			if stampToken == token then
				stampLabel.Visible = false
			end
		end)
	end)
end

-- A short pop-up above the middle of the screen (e.g. CHECKPOINT!).
local function toast(text: string, color: Color3)
	toastToken += 1
	local token = toastToken
	toastLabel.Text = text
	toastLabel.TextColor3 = color
	toastLabel.TextTransparency = 0
	toastLabel.Visible = true
	local scale = Ui.scaleOf(toastLabel)
	scale.Scale = 1.6
	Ui.tween(scale, Theme.Tweens.Pop, { Scale = 1 })
	task.delay(TOAST_HOLD, function()
		if toastToken ~= token then
			return
		end
		local fade = Ui.tween(toastLabel, Theme.Tweens.Smooth, { TextTransparency = 1 })
		fade.Completed:Once(function()
			if toastToken == token then
				toastLabel.Visible = false
			end
		end)
	end)
end

local function confetti(count: number)
	for _ = 1, count do
		task.delay(math.random() * 1.4, function()
			local startX = math.random()
			local piece: Frame = Ui.new("Frame", {
				Size = UDim2.fromOffset(math.random(8, 14), math.random(14, 22)),
				Position = UDim2.new(startX, 0, 0, -30),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Rotation = math.random(0, 360),
				BackgroundColor3 = CONFETTI_COLORS[math.random(#CONFETTI_COLORS)],
				BorderSizePixel = 0,
				ZIndex = 20,
				Parent = confettiLayer,
			})
			Ui.corner(piece, UDim.new(0, 3))
			local duration = 2.4 + math.random() * 1.8
			local tween =
				TweenService:Create(piece, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					Position = UDim2.new(startX + (math.random() - 0.5) * 0.3, 0, 1, 40),
					Rotation = piece.Rotation + (math.random() - 0.5) * 900,
				})
			tween.Completed:Once(function()
				piece:Destroy()
			end)
			tween:Play()
		end)
	end
end

local function showWinner()
	if MatchClient.GetPhase() ~= "Winner" then
		return
	end
	local winnerId = MatchClient.GetNumber(Attr.WinnerUserId)
	local winnerName = MatchClient.GetString(Attr.WinnerName)
	if winnerId ~= 0 and winnerId == localPlayer.UserId then
		winner.Title.Text = "YOU WIN!"
		winner.Name.Text = "You're the Wobble Rush champion!"
	elseif winnerName ~= "" then
		winner.Title.Text = "WINNER!"
		winner.Name.Text = winnerName
	else
		winner.Title.Text = "MATCH OVER"
		winner.Name.Text = "Nobody made it this time"
	end
	winner.Holder.Visible = true
	winner.Group.GroupTransparency = 1
	local scale = Ui.scaleOf(winner.Group)
	scale.Scale = 0.6
	Ui.tween(winner.Group, Theme.Tweens.Smooth, { GroupTransparency = 0 })
	Ui.tween(scale, Theme.Tweens.Bounce, { Scale = 1 })
	if winnerName ~= "" then
		confetti(CONFETTI_PIECES)
		Sfx.Play("WinnerJingle")
	end
end

local function hideWinner()
	if winner.Holder.Visible then
		local tween = Ui.tween(winner.Group, Theme.Tweens.Smooth, { GroupTransparency = 1 })
		tween.Completed:Once(function()
			if MatchClient.GetPhase() ~= "Winner" then
				winner.Holder.Visible = false
			end
		end)
	end
end

local function refreshBarVisibility()
	local phase = MatchClient.GetPhase()
	local roundPhase = phase == "Intro" or phase == "Playing" or phase == "RoundOver"
	bar.Panel.Root.Visible = MatchClient.IsInMatchFlow() and roundPhase
	scoreBar.Panel.Root.Visible = bar.Panel.Root.Visible and scoreBar.HasScores
end

local function decodeTeamScores(): (number?, { TeamScore })
	local raw = MatchClient.GetString(Attr.TeamScores)
	local scores: { TeamScore } = {}
	if raw == "" then
		return nil, scores
	end
	local ok, data = pcall(function(): any
		return HttpService:JSONDecode(raw)
	end)
	if not ok or typeof(data) ~= "table" or typeof(data.Scores) ~= "table" then
		return nil, scores
	end
	for _, entry in data.Scores do
		if typeof(entry) == "table" and typeof(entry.Id) == "string" and typeof(entry.Score) == "number" then
			table.insert(scores, { Id = entry.Id, Score = entry.Score })
		end
	end
	return if typeof(data.Total) == "number" then data.Total else nil, scores
end

-- Rebuilds the team score bar from the TeamScores attribute.
local function refreshTeamScores()
	local total, scores = decodeTeamScores()
	scoreBar.HasScores = #scores > 0
	local sum = 0
	for _, entry in scores do
		sum += math.max(entry.Score, 0)
	end
	local denominator = math.max(total or sum, 1)
	local ownTeam = Teams.FromPlayer(localPlayer)
	local seen: { [string]: boolean } = {}
	for order, entry in scores do
		local def = Teams.Get(entry.Id)
		if not def then
			continue
		end
		seen[entry.Id] = true
		local label = scoreBar.Labels[entry.Id]
		if not label then
			label = Ui.label(scoreBar.LabelRow, "", Theme.Fonts.Display, def.Color, UDim2.fromOffset(150, 24))
			Ui.new("UIStroke", {
				Color = Theme.Colors.Ink,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				Parent = label,
			})
			scoreBar.Labels[entry.Id] = label
		end
		label.LayoutOrder = order
		local mine = ownTeam ~= nil and ownTeam.Id == entry.Id
		label.Text = `{string.upper(def.Id)} {entry.Score}{if mine then " (YOU)" else ""}`

		local segment = scoreBar.Segments[entry.Id]
		if not segment then
			local created: Frame = Ui.new("Frame", {
				Name = entry.Id,
				Size = UDim2.fromScale(0, 1),
				BackgroundColor3 = def.Color,
				BorderSizePixel = 0,
				Parent = scoreBar.Track,
			})
			segment = created
			scoreBar.Segments[entry.Id] = created
		end
		if segment then
			segment.LayoutOrder = order
			local share = math.clamp(math.max(entry.Score, 0) / denominator, 0, 1)
			Ui.tween(segment, Theme.Tweens.Fast, { Size = UDim2.fromScale(share, 1) })
		end
	end
	for id, label in scoreBar.Labels do
		if not seen[id] then
			label:Destroy()
			scoreBar.Labels[id] = nil
		end
	end
	for id, segment in scoreBar.Segments do
		if not seen[id] then
			segment:Destroy()
			scoreBar.Segments[id] = nil
		end
	end
	refreshBarVisibility()
end

-- Runs once each time the phase changes (entry effects like the round card and GO!).
local function onPhaseChanged()
	local phase = MatchClient.GetPhase()
	local involved = MatchClient.IsInMatchFlow()
	refreshBarVisibility()

	if phase == "Intro" and involved then
		fillRoundInfo()
		lastCountdownNumber = -1
		showCard()
	else
		hideCard()
	end

	if phase == "Playing" and involved then
		popBigText("GO!", Theme.Colors.Lime, GO_HOLD)
		Sfx.Play("Go")
	elseif phase ~= "Intro" then
		hideBigText()
	end

	if phase == "RoundOver" and involved then
		roundOverLabel.Visible = true
		Ui.popIn(roundOverLabel)
		Sfx.Play("RoundOver")
		task.delay(ROUND_OVER_HOLD, function()
			roundOverLabel.Visible = false
		end)
	end

	if phase == "Winner" then
		task.delay(if involved then WINNER_DELAY_FOR_PLAYERS else 0, showWinner)
	else
		hideWinner()
	end
end

-- A burst of 3D confetti from your Bloblet, on top of the screen confetti.
local function celebrate()
	confetti(QUALIFY_CONFETTI_PIECES)
	Sfx.Play("Qualify")
	local character = localPlayer.Character
	local root = if character then character.PrimaryPart else nil
	if root then
		Effects.Burst(root.Position + Vector3.new(0, 2, 0), {
			Count = 40,
			Colors = CONFETTI_COLORS,
			Size = Vector3.new(0.6, 0.08, 0.9),
			Speed = 26,
			Up = 38,
			Gravity = 45,
			Life = 2.2,
		})
	end
end

local function onCheckpointChanged()
	local value = localPlayer:GetAttribute(Match.PlayerAttr.Checkpoint)
	local checkpoint = if typeof(value) == "number" then value else 0
	if checkpoint > lastCheckpoint and MatchClient.GetStatus() == "Playing" then
		toast("CHECKPOINT!", Theme.Colors.Aqua)
		Sfx.Play("Checkpoint")
	end
	lastCheckpoint = checkpoint
end

local POWER_UP_TOASTS: { [string]: { Text: string, Color: Color3 } } = {
	Splash = { Text = "SPLASH!", Color = Theme.Colors.Aqua },
	Giant = { Text = "GIANT PAINTER!", Color = Theme.Colors.Lime },
	Stripe = { Text = "STRIPE!", Color = Theme.Colors.Yellow },
}

local function onPowerUp(kind: string)
	local info = POWER_UP_TOASTS[kind]
	if info then
		toast(info.Text, info.Color)
	end
end

-- A round-wide message from the server (e.g. "CORAL SCORES!" in Gumball Goal).
local function onAnnouncement()
	local raw = MatchClient.GetString(Attr.Announcement)
	if raw == "" or not MatchClient.IsInMatchFlow() then
		return
	end
	local ok, data = pcall(function(): any
		return HttpService:JSONDecode(raw)
	end)
	if not ok or typeof(data) ~= "table" or typeof(data.Text) ~= "string" then
		return
	end
	local team = if typeof(data.Team) == "string" then Teams.Get(data.Team) else nil
	toast(data.Text, if team then team.Color else Theme.Colors.Yellow)
	Sfx.Play("Announce")
end

local function onStatusChanged()
	local status = MatchClient.GetStatus()
	if status == "Qualified" and previousStatus == "Playing" then
		stamp("QUALIFIED!", Theme.Colors.Lime)
		celebrate()
	elseif status == "Eliminated" and previousStatus ~= "Eliminated" then
		stamp("ELIMINATED!", Theme.Colors.Pink)
		Sfx.Play("Eliminated")
	end
	previousStatus = status
	refreshBarVisibility()
	if status == "None" then
		hideCard()
	end
end

local function onFrame()
	updateDrownWarning()
	local phase = MatchClient.GetPhase()
	if bar.Panel.Root.Visible then
		local timerText = if phase == "Playing" then formatTime(MatchClient.TimeLeft()) else ""
		if bar.Timer.Text ~= timerText then
			bar.Timer.Text = timerText
		end
	end
	if phase == "Intro" and MatchClient.IsInMatchFlow() then
		local remaining = MatchClient.TimeLeft()
		local countdown = Config.Match.CountdownSeconds
		if remaining <= countdown + 0.25 then
			hideCard()
		end
		if remaining <= countdown and remaining > 0 then
			local number = math.ceil(remaining)
			if number ~= lastCountdownNumber then
				lastCountdownNumber = number
				popBigText(tostring(number), Theme.Colors.White)
				Sfx.Play("CountdownTick")
			end
		end
	end
end

function RoundHud.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	gui = Ui.new("ScreenGui", {
		Name = "MatchHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 10,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	buildBar()
	buildScoreBar()
	buildCard()
	buildCenterTexts()
	buildWinner()

	MatchClient.Changed:Connect(function(name: string)
		if name == Attr.Phase then
			onPhaseChanged()
		elseif name == Attr.TeamScores then
			refreshTeamScores()
		elseif name == Attr.Announcement then
			onAnnouncement()
		elseif name == Attr.CounterText then
			bar.Counter.Text = MatchClient.GetString(Attr.CounterText)
			if bar.Panel.Root.Visible then
				Ui.pressBounce(bar.Counter)
			end
		end
	end)
	MatchClient.LocalChanged:Connect(function(name: string)
		if name == Match.PlayerAttr.Status then
			onStatusChanged()
		elseif name == Match.PlayerAttr.Checkpoint then
			onCheckpointChanged()
		end
	end)
	ClientEvents.PowerUp:Connect(onPowerUp)
	-- The "(YOU)" marker follows your team.
	localPlayer:GetPropertyChangedSignal("Team"):Connect(refreshTeamScores)
	previousStatus = MatchClient.GetStatus()
	refreshTeamScores()
	onPhaseChanged()
	RunService.RenderStepped:Connect(onFrame)
end

return RoundHud
