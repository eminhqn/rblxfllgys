--!strict
-- Your level in the lobby (under your Crowns and Gumdrops): a level badge and an XP bar towards the
-- next level. The reward track opens from the lobby's MENU (or D-pad down on a controller). When
-- you level up (anywhere, even mid-round) a LEVEL UP! pop-up shows, followed by what it unlocked.
-- See Shared/Progression.

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

local function rewardColor(reward: { [string]: any }): Color3
	if reward.Kind == "Item" and typeof(reward.ItemId) == "string" then
		local entry = Cosmetics.Get(reward.ItemId)
		if entry and entry.Rarity then
			return Cosmetics.RarityColors[entry.Rarity]
		end
	end
	return if reward.Kind == "Crowns" then Color3.fromRGB(255, 205, 64) else Theme.Colors.Pink
end

-- The server says we levelled up: LEVEL n!, then each reward it unlocked.
local function onLevelUp(level: unknown, rewards: unknown)
	if typeof(level) ~= "number" then
		return
	end
	RoundHud.Toast(`LEVEL {level}!`, Theme.Colors.Yellow)
	Sfx.Play("Crown")
	if typeof(rewards) ~= "table" then
		return
	end
	local shown = 0
	for _, raw in rewards :: { any } do
		if shown >= MAX_REWARD_POPUPS then
			break
		end
		local kind = if typeof(raw) == "table" then raw.Kind else nil
		if (kind ~= "Gumdrops" and kind ~= "Crowns" and kind ~= "Item") or typeof(raw.Amount) ~= "number" then
			continue
		end
		shown += 1
		local reward: Progression.Reward = {
			Kind = kind :: Progression.RewardKind,
			Amount = raw.Amount,
			ItemId = if typeof(raw.ItemId) == "string" then raw.ItemId else nil,
		}
		local text = if reward.Kind == "Item"
			then `UNLOCKED: {Progression.Describe(reward)}`
			else Progression.Describe(reward)
		task.delay(POPUP_GAP * shown, function()
			RoundHud.Toast(text, rewardColor(raw))
			Sfx.Play("Unlock")
		end)
	end
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
	refresh()
end

return LevelHud
