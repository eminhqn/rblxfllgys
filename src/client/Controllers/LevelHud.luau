--!strict
-- Your level in the lobby (under your Crowns and Gumdrops): a level badge and an XP bar towards the
-- next level. The reward track opens from the lobby's MENU (or D-pad down on a controller). When
-- you level up (anywhere, even mid-round) a LEVEL UP! pop-up shows, followed by what it unlocked
-- (premium track rewards say PREMIUM). Getting the PREMIUM track shows a PREMIUM UNLOCKED! pop-up
-- and what it paid out for the levels you'd already reached. See Shared/Progression.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Cosmetics = require(Shared.Cosmetics)
local Progression = require(Shared.Progression)
local Remotes = require(Shared.Remotes)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Hud = require(script.Parent.Hud)
local MatchClient = require(script.Parent.MatchClient)
local ProfileClient = require(script.Parent.ProfileClient)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)

local LevelHud = {}

local PANEL_SIZE = Vector2.new(300, 58)
local POPUP_GAP = 1.4 -- seconds between the LEVEL UP! pop-up and each reward after it
local MAX_REWARD_POPUPS = 3
local WHITE = Theme.Colors.White
local TRACK_COLOR = Color3.fromRGB(226, 218, 246)

local panel: Ui.Panel
local levelLabel: TextLabel
local xpLabel: TextLabel
local fill: Frame

local function refresh()
	panel.Root.Visible = ProfileClient.IsReady() and not MatchClient.IsInMatchFlow()
	local level, into, needed = ProfileClient.GetLevel()
	levelLabel.Text = tostring(level)
	if needed > 0 then
		xpLabel.Text = `{into} / {needed} XP`
		fill.Size = UDim2.fromScale(math.clamp(into / needed, 0, 1), 1)
	else
		xpLabel.Text = "TOP LEVEL!"
		fill.Size = UDim2.fromScale(1, 1)
	end
end

local function rewardColor(reward: Progression.Reward): Color3
	if reward.Kind == "Item" and reward.ItemId then
		local entry = Cosmetics.Get(reward.ItemId)
		if entry and entry.Rarity then
			return Cosmetics.RarityColors[entry.Rarity]
		end
	end
	return if reward.Kind == "Crowns"
		then Color3.fromRGB(255, 205, 64)
		elseif reward.Kind == "PowerUp" then Theme.Colors.Orange
		else Theme.Colors.Pink
end

-- One reward from the server, checked; and whether it's from the premium track.
local function readReward(raw: unknown): (Progression.Reward?, boolean)
	if typeof(raw) ~= "table" then
		return nil, false
	end
	local data = raw :: any
	local kind = data.Kind
	if
		(kind ~= "Gumdrops" and kind ~= "Crowns" and kind ~= "Item" and kind ~= "PowerUp")
		or typeof(data.Amount) ~= "number"
	then
		return nil, false
	end
	return {
		Kind = kind :: Progression.RewardKind,
		Amount = data.Amount,
		ItemId = if typeof(data.ItemId) == "string" then data.ItemId else nil,
		PowerUp = if typeof(data.PowerUp) == "string" then data.PowerUp else nil,
	},
		data.Premium == true
end

-- A pop-up for each reward (the best first, up to a few), after the title pop-up.
local function showRewards(rewards: unknown)
	if typeof(rewards) ~= "table" then
		return
	end
	local list: { { Reward: Progression.Reward, Premium: boolean } } = {}
	for _, raw in rewards :: { any } do
		local reward, premium = readReward(raw)
		if reward then
			table.insert(list, { Reward = reward, Premium = premium })
		end
	end
	-- Items first, then Crowns and power-ups, then Gumdrops.
	local rank = { Item = 1, Crowns = 2, PowerUp = 3, Gumdrops = 4 }
	table.sort(list, function(a, b): boolean
		return rank[a.Reward.Kind] < rank[b.Reward.Kind]
	end)
	for index, entry in list do
		if index > MAX_REWARD_POPUPS then
			break
		end
		local reward = entry.Reward
		local text = if reward.Kind == "Item"
			then `UNLOCKED: {Progression.Describe(reward)}`
			else Progression.Describe(reward)
		if entry.Premium then
			text = `PREMIUM  {text}`
		end
		task.delay(POPUP_GAP * index, function()
			RoundHud.Toast(text, rewardColor(reward))
			Sfx.Play("Unlock")
		end)
	end
end

-- The server says we levelled up: LEVEL n!, then each reward it unlocked.
local function onLevelUp(level: unknown, rewards: unknown)
	if typeof(level) ~= "number" then
		return
	end
	RoundHud.Toast(`LEVEL {level}!`, Theme.Colors.Yellow)
	Sfx.Play("Crown")
	showRewards(rewards)
end

-- We got the PREMIUM track: everything it paid out for the levels we'd already reached.
local function onPremiumUnlocked(rewards: unknown)
	RoundHud.Toast("PREMIUM TRACK UNLOCKED!", Color3.fromRGB(255, 196, 40))
	Sfx.Play("Crown")
	showRewards(rewards)
end

local function build()
	panel = Ui.panel(Hud.GetTopStack(), UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y), UDim2.new(), Vector2.zero)
	panel.Root.LayoutOrder = Hud.TopOrder.Level
	panel.Root.Visible = false
	Hud.MoveRightOnTouch(panel.Root) -- clear of the thumbstick on phones and tablets
	local body = panel.Body

	-- Level badge.
	local badge: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(44, 44),
		Position = UDim2.new(0, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = body,
	})
	Ui.corner(badge, UDim.new(0.5, 0))
	Ui.stroke(badge, Theme.Colors.Yellow, 3)
	local small = Ui.label(
		badge,
		"LV",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, 0, 0, 12),
		UDim2.new(0.5, 0, 0, 5),
		Vector2.new(0.5, 0)
	)
	small.ZIndex = 4
	levelLabel = Ui.label(
		badge,
		"1",
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -8, 0, 22),
		UDim2.new(0.5, 0, 1, -4),
		Vector2.new(0.5, 1)
	)
	levelLabel.ZIndex = 4

	-- XP bar.
	xpLabel =
		Ui.label(body, "", Theme.Fonts.Display, Theme.Colors.Ink, UDim2.new(1, -80, 0, 18), UDim2.fromOffset(62, 9))
	xpLabel.TextXAlignment = Enum.TextXAlignment.Left
	local track: Frame = Ui.new("Frame", {
		Size = UDim2.new(1, -80, 0, 14),
		Position = UDim2.fromOffset(62, 33),
		BackgroundColor3 = TRACK_COLOR,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = body,
	})
	Ui.corner(track, UDim.new(0.5, 0))
	fill = Ui.new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Purple,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = track,
	})
	Ui.corner(fill, UDim.new(0.5, 0))
end

function LevelHud.Init()
	build()
	ProfileClient.Changed:Connect(refresh)
	MatchClient.LocalChanged:Connect(refresh)
	Remotes.Event("LevelUp").OnClientEvent:Connect(onLevelUp)
	Remotes.Event("PremiumUnlocked").OnClientEvent:Connect(onPremiumUnlocked)
	refresh()
end

return LevelHud
