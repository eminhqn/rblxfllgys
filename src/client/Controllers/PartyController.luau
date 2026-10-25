--!strict
-- Parties and inviting friends (the server's PartyService decides everything).
--
--   * The PARTY screen (PARTY button, or LB on a controller): who's in your party (up to
--     Config.Social.PartyMaxSize) with a LEAVE button, every other player in the server with an
--     INVITE button (your Roblox friends first), and any invites you've been sent, with JOIN and
--     NO. It also has INVITE FRIENDS, which opens Roblox's invite screen, and explains the friend
--     bonus.
--   * An invite card pops up when someone invites you (JOIN / NO, or LB to answer).
--   * Pop-ups say when someone joins or leaves your party, says no, and so on.
-- Controller in the screen: up / down picks a button, A presses it, LB / RB change page, B closes.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Match = require(Shared.Match)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)
local Theme = require(Shared.Theme)
local Ui = require(Shared.Ui)

local Input = require(script.Parent.InputController)
local MatchClient = require(script.Parent.MatchClient)
local ResponsiveScale = require(script.Parent.ResponsiveScale)
local RoundHud = require(script.Parent.RoundHud)
local Sfx = require(script.Parent.Sfx)

local PartyController = {}

-- Someone's party changed (yours included), or a player joined or left the server.
PartyController.Changed = Signal.new() :: Signal.Signal<()>

type Row = {
	Frame: Frame,
	Headshot: ImageLabel,
	Name: TextLabel,
	Tag: TextLabel,
	Primary: TextButton,
	PrimaryLabel: TextLabel,
	PrimaryStroke: UIStroke,
	Secondary: TextButton,
	SecondaryStroke: UIStroke,
}

type ListItem = {
	Player: Player,
	Invite: boolean, -- they invited you (JOIN / NO) rather than someone you can invite
}

type Focusable = {
	Button: TextButton,
	Stroke: UIStroke,
	Press: () -> (),
}

local OPEN_ACTION = "WobblePartyOpen"
local CLOSE_ACTION = "WobblePartyClose"
local NAVIGATE_ACTION = "WobblePartyNavigate"
local PRESS_ACTION = "WobblePartyPress"
local SWALLOW_ACTION = "WobblePartySwallow"
local GAMEPAD_ACTIONS = { CLOSE_ACTION, NAVIGATE_ACTION, PRESS_ACTION, SWALLOW_ACTION }
local SWALLOWED_KEYS = {
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.ButtonL2,
	Enum.KeyCode.ButtonR2,
	Enum.KeyCode.ButtonL3,
	Enum.KeyCode.ButtonR3,
	Enum.KeyCode.ButtonSelect,
	Enum.KeyCode.DPadLeft,
	Enum.KeyCode.DPadRight,
	Enum.KeyCode.Thumbstick2,
}

local WINDOW_SIZE = Vector2.new(780, 480)
local LEFT_X, LEFT_WIDTH = 20, 330
local RIGHT_X = LEFT_X + LEFT_WIDTH + 24
local RIGHT_WIDTH = WINDOW_SIZE.X - RIGHT_X - 20
local ROW_HEIGHT = 46
local ROW_GAP = 6
local PAGE_SIZE = 6
local STICK_THRESHOLD = 0.6
local STICK_REPEAT = 0.2
local REQUEST_COOLDOWN = 0.4

local WHITE = Theme.Colors.White
local ROW_COLOR = Theme.Colors.PanelTint
local FOCUS_COLOR = Theme.Colors.Yellow

local PlayerAttr = Match.PlayerAttr
local localPlayer = Players.LocalPlayer

local gui: ScreenGui
local windowPanel: Frame
local memberTitle: TextLabel
local memberRows: { Row } = {}
local leaveButton: TextButton
local leaveStroke: UIStroke
local soloHint: TextLabel
local inviteFriendsButton: TextButton
local inviteFriendsStroke: UIStroke
local listTitle: TextLabel
local listRows: { Row } = {}
local emptyLabel: TextLabel
local pageLabel: TextLabel
local backButton: TextButton
local nextButton: TextButton
local card: Frame
local cardText: TextLabel
local cardHint: TextLabel

local isOpen = false
local page = 1
local focusables: { Focusable } = {}
local focusIndex = 1
local lastStickMove = 0
local lastRequest = 0
local invitesFrom: { [Player]: number } = {} -- who invited you -> when it runs out (os.clock)
local sentTo: { [Player]: number } = {} -- who you've invited -> when it runs out
local friends: { [Player]: boolean } = {}
local friendChecked: { [Player]: boolean } = {}
local cardFrom: Player? = nil

local refresh: () -> ()

local function partyIdOf(player: Player): string
	local value = player:GetAttribute(PlayerAttr.Party)
	return if typeof(value) == "string" then value else ""
end

local function myParty(): { Player }
	local id = partyIdOf(localPlayer)
	if id == "" then
		return {}
	end
	local members: { Player } = {}
	for _, player in Players:GetPlayers() do
		if partyIdOf(player) == id then
			table.insert(members, player)
		end
	end
	table.sort(members, function(a: Player, b: Player): boolean
		if a == localPlayer or b == localPlayer then
			return a == localPlayer
		end
		return a.DisplayName < b.DisplayName
	end)
	return members
end

local function headshotFor(player: Player): string
	return if player.UserId > 0 then `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=48&h=48` else ""
end

local function request(action: string, player: Player?)
	local now = os.clock()
	if now - lastRequest < REQUEST_COOLDOWN then
		return
	end
	lastRequest = now
	Sfx.Play("UiClick")
	Remotes.Event("RequestParty"):FireServer(action, if player then player.UserId else nil)
end

-- Finds out (once) whether each player is one of your Roblox friends, to list them first.
local function checkFriend(player: Player)
	if friendChecked[player] or player == localPlayer then
		return
	end
	friendChecked[player] = true
	task.spawn(function()
		local ok, result = pcall(function(): boolean
			return localPlayer:IsFriendsWithAsync(player.UserId)
		end)
		if ok and result and player.Parent == Players then
			friends[player] = true
			if isOpen then
				refresh()
			end
		end
	end)
end

-- Opens Roblox's own screen for inviting friends into the game.
function PartyController.PromptGameInvite()
	Sfx.Play("UiClick")
	task.spawn(function()
		local ok, canSend = pcall(function(): boolean
			return SocialService:CanSendGameInviteAsync(localPlayer)
		end)
		if not ok or not canSend then
			RoundHud.Toast("INVITES DON'T WORK HERE", Theme.Colors.Orange)
			return
		end
		pcall(function()
			local options = Instance.new("ExperienceInviteOptions")
			options.PromptMessage = "Come and wobble with me in Wobble Rush!"
			SocialService:PromptGameInvite(localPlayer, options)
		end)
	end)
end

-------------------------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------------------------

local function listItems(): { ListItem }
	local items: { ListItem } = {}
	local now = os.clock()
	local myId = partyIdOf(localPlayer)
	-- Invites to you first, then everyone you could invite: friends first, then by name.
	for player, expires in invitesFrom do
		if expires > now and player.Parent == Players then
			table.insert(items, { Player = player, Invite = true })
		end
	end
	local others: { Player } = {}
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer and (myId == "" or partyIdOf(player) ~= myId) then
			checkFriend(player)
			table.insert(others, player)
		end
	end
	table.sort(others, function(a: Player, b: Player): boolean
		local aFriend, bFriend = friends[a] == true, friends[b] == true
		if aFriend ~= bFriend then
			return aFriend
		end
		return a.DisplayName < b.DisplayName
	end)
	for _, player in others do
		table.insert(items, { Player = player, Invite = false })
	end
	return items
end

local function setRowButton(button: TextButton, label: TextLabel?, text: string, color: Color3, enabled: boolean)
	button.BackgroundColor3 = if enabled then color else Color3.fromRGB(196, 190, 214)
	if label then
		label.Text = text
	end
end

local function addFocusable(button: TextButton, stroke: UIStroke, press: () -> ())
	table.insert(focusables, { Button = button, Stroke = stroke, Press = press })
end

local function showFocus()
	local gamepad = Input.GetScheme() == "Gamepad"
	focusIndex = math.clamp(focusIndex, 1, math.max(#focusables, 1))
	for index, entry in focusables do
		local focused = gamepad and index == focusIndex
		entry.Stroke.Color = if focused then FOCUS_COLOR else WHITE
		entry.Stroke.Thickness = if focused then 5 else 3
	end
end

function refresh()
	table.clear(focusables)
	local now = os.clock()

	-- Your party.
	local members = myParty()
	memberTitle.Text = if #members > 0 then `YOUR PARTY  {#members} / {Config.Social.PartyMaxSize}` else "YOUR PARTY"
	for index, row in memberRows do
		local member: Player? = members[index]
		row.Frame.Visible = member ~= nil
		if member then
			row.Headshot.Image = headshotFor(member)
			row.Name.Text = if member == localPlayer then `{member.DisplayName} (you)` else member.DisplayName
			row.Tag.Visible = friends[member] == true
		end
	end
	leaveButton.Visible = #members > 0
	soloHint.Visible = #members == 0
	if #members > 0 then
		addFocusable(leaveButton, leaveStroke, function()
			request("Leave")
		end)
	end
	addFocusable(inviteFriendsButton, inviteFriendsStroke, PartyController.PromptGameInvite)

	-- Everyone else, a page at a time.
	local items = listItems()
	local pages = math.max(1, math.ceil(#items / PAGE_SIZE))
	page = math.clamp(page, 1, pages)
	listTitle.Text = `PLAYERS HERE ({#items})`
	pageLabel.Text = `{page} / {pages}`
	pageLabel.Visible = pages > 1
	backButton.Visible = pages > 1
	nextButton.Visible = pages > 1
	emptyLabel.Visible = #items == 0
	local full = #members >= Config.Social.PartyMaxSize
	for index, row in listRows do
		local item = items[(page - 1) * PAGE_SIZE + index]
		row.Frame.Visible = item ~= nil
		if not item then
			continue
		end
		local player = item.Player
		row.Headshot.Image = headshotFor(player)
		row.Name.Text = player.DisplayName
		row.Tag.Visible = friends[player] == true
		row.Secondary.Visible = item.Invite
		if item.Invite then
			row.Tag.Visible = true
			row.Tag.Text = "INVITED YOU"
			setRowButton(row.Primary, row.PrimaryLabel, "JOIN", Theme.Colors.Lime, true)
			addFocusable(row.Primary, row.PrimaryStroke, function()
				invitesFrom[player] = nil
				request("Accept", player)
				refresh()
			end)
			addFocusable(row.Secondary, row.SecondaryStroke, function()
				invitesFrom[player] = nil
				request("Decline", player)
				refresh()
			end)
		else
			row.Tag.Text = "FRIEND"
			local sent = (sentTo[player] or 0) > now
			local canInvite = not sent and not full
			setRowButton(
				row.Primary,
				row.PrimaryLabel,
				if sent then "SENT" else "INVITE",
				Theme.Colors.Purple,
				canInvite
			)
			addFocusable(row.Primary, row.PrimaryStroke, function()
				if (sentTo[player] or 0) <= os.clock() and #myParty() < Config.Social.PartyMaxSize then
					request("Invite", player)
				end
			end)
		end
	end
	showFocus()
end

-------------------------------------------------------------------------------------------------
-- Opening, closing and the controller
-------------------------------------------------------------------------------------------------

local setOpen: (open: boolean) -> ()

local function moveFocus(step: number)
	if #focusables == 0 then
		return
	end
	focusIndex = math.clamp(focusIndex + step, 1, #focusables)
	Sfx.Play("UiClick")
	showFocus()
end

local function turnPage(step: number)
	page += step
	focusIndex = 1
	refresh()
end

local function bindGamepad()
	local high = Enum.ContextActionPriority.High.Value + 10
	ContextActionService:BindActionAtPriority(
		CLOSE_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				setOpen(false)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonB,
		Enum.KeyCode.ButtonStart
	)
	ContextActionService:BindActionAtPriority(
		NAVIGATE_ACTION,
		function(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
			local key = input.KeyCode
			if key == Enum.KeyCode.Thumbstick1 then
				local now = os.clock()
				if math.abs(input.Position.Y) >= STICK_THRESHOLD and now - lastStickMove >= STICK_REPEAT then
					lastStickMove = now
					moveFocus(if input.Position.Y > 0 then -1 else 1)
				end
			elseif state == Enum.UserInputState.Begin then
				if key == Enum.KeyCode.DPadUp then
					moveFocus(-1)
				elseif key == Enum.KeyCode.DPadDown then
					moveFocus(1)
				elseif key == Enum.KeyCode.ButtonL1 then
					turnPage(-1)
				elseif key == Enum.KeyCode.ButtonR1 then
					turnPage(1)
				end
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.ButtonL1,
		Enum.KeyCode.ButtonR1,
		Enum.KeyCode.Thumbstick1
	)
	ContextActionService:BindActionAtPriority(
		PRESS_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				local entry = focusables[focusIndex]
				if entry and entry.Button.Visible then
					Ui.pressBounce(entry.Button)
					entry.Press()
				end
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		high,
		Enum.KeyCode.ButtonA
	)
	ContextActionService:BindActionAtPriority(SWALLOW_ACTION, function(): Enum.ContextActionResult
		return Enum.ContextActionResult.Sink
	end, false, high, table.unpack(SWALLOWED_KEYS))
end

function setOpen(open: boolean)
	if open == isOpen or (open and MatchClient.GetStatus() ~= "None") then
		return
	end
	isOpen = open
	gui.Enabled = open
	Input.SetBlocked("Party", open)
	if open then
		page = 1
		focusIndex = 1
		card.Visible = false
		bindGamepad()
		Ui.popIn(windowPanel)
		refresh()
	else
		for _, action in GAMEPAD_ACTIONS do
			ContextActionService:UnbindAction(action)
		end
	end
end

function PartyController.Open()
	setOpen(true)
end

function PartyController.IsOpen(): boolean
	return isOpen
end

-- How many players are in your party (0 if you aren't in one).
function PartyController.GetPartySize(): number
	return #myParty()
end

-------------------------------------------------------------------------------------------------
-- Invites and pop-ups
-------------------------------------------------------------------------------------------------

local function showCard(from: Player)
	cardFrom = from
	cardText.Text = `{from.DisplayName} invited you to their party!`
	cardHint.Visible = Input.GetScheme() == "Gamepad"
	card.Visible = not isOpen
	Ui.popIn(card)
	local expires = invitesFrom[from] or 0
	task.delay(math.max(0, expires - os.clock()), function()
		if cardFrom == from and (invitesFrom[from] or 0) <= os.clock() then
			card.Visible = false
			cardFrom = nil
		end
	end)
end

local function answerCard(accept: boolean)
	local from = cardFrom
	card.Visible = false
	cardFrom = nil
	if from then
		invitesFrom[from] = nil
		request(if accept then "Accept" else "Decline", from)
	end
end

local function onPartyEvent(kind: unknown, userId: unknown)
	if typeof(kind) ~= "string" or typeof(userId) ~= "number" then
		return
	end
	local other = Players:GetPlayerByUserId(userId)
	local name = if other then other.DisplayName else "Someone"
	if kind == "Invited" and other then
		invitesFrom[other] = os.clock() + Config.Social.PartyInviteTime
		Sfx.Play("Announce")
		showCard(other)
	elseif kind == "InviteSent" and other then
		sentTo[other] = os.clock() + Config.Social.PartyInviteTime
		RoundHud.Toast(`INVITE SENT TO {string.upper(name)}`, Theme.Colors.Purple)
	elseif kind == "Joined" then
		if userId == localPlayer.UserId then
			RoundHud.Toast("YOU'RE IN THE PARTY!", Theme.Colors.Lime)
		else
			RoundHud.Toast(`{string.upper(name)} JOINED YOUR PARTY!`, Theme.Colors.Lime)
		end
		if other then
			sentTo[other] = nil
		end
		Sfx.Play("Unlock")
	elseif kind == "Left" then
		RoundHud.Toast(`{string.upper(name)} LEFT YOUR PARTY`, Theme.Colors.Orange)
	elseif kind == "Declined" then
		if other then
			sentTo[other] = nil
		end
		RoundHud.Toast(`{string.upper(name)} SAID NO`, Theme.Colors.Orange)
	elseif kind == "Full" then
		RoundHud.Toast(
			if userId == localPlayer.UserId then "YOUR PARTY IS FULL" else "THAT PARTY IS FULL",
			Theme.Colors.Orange
		)
	elseif kind == "Expired" then
		RoundHud.Toast("THAT INVITE HAS RUN OUT", Theme.Colors.Orange)
	end
	if isOpen then
		refresh()
	end
end

-------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------

local function pillButton(
	parent: Instance,
	text: string,
	size: UDim2,
	position: UDim2,
	anchor: Vector2,
	color: Color3
): (TextButton, TextLabel, UIStroke)
	local button: TextButton = Ui.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = size,
		Position = position,
		AnchorPoint = anchor,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = parent,
	})
	Ui.corner(button, UDim.new(0.5, 0))
	local stroke = Ui.stroke(button, WHITE, 3)
	local label = Ui.label(
		button,
		text,
		Theme.Fonts.Display,
		WHITE,
		UDim2.new(1, -18, 1, -14),
		UDim2.fromScale(0.5, 0.5),
		Vector2.new(0.5, 0.5)
	)
	label.ZIndex = 5
	return button, label, stroke
end

local function buildRow(parent: Instance, y: number, width: number, withButtons: boolean): Row
	local frame: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(width, ROW_HEIGHT),
		Position = UDim2.fromOffset(0, y),
		BackgroundColor3 = ROW_COLOR,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
		Parent = parent,
	})
	Ui.corner(frame, UDim.new(0, 14))
	local headshot: ImageLabel = Ui.new("ImageLabel", {
		Size = UDim2.fromOffset(36, 36),
		Position = UDim2.new(0, 6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = Color3.fromRGB(214, 204, 240),
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = frame,
	})
	Ui.corner(headshot, UDim.new(0.5, 0))
	local buttonsWidth = if withButtons then 160 else 0
	local name = Ui.label(
		frame,
		"",
		Theme.Fonts.Body,
		Theme.Colors.Ink,
		UDim2.new(1, -(56 + buttonsWidth), 0, 20),
		UDim2.fromOffset(50, 4)
	)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 4
	local tag = Ui.label(
		frame,
		"FRIEND",
		Theme.Fonts.Display,
		Theme.Colors.Pink,
		UDim2.new(1, -(56 + buttonsWidth), 0, 14),
		UDim2.fromOffset(50, 26)
	)
	tag.TextXAlignment = Enum.TextXAlignment.Left
	tag.ZIndex = 4
	local primary, primaryLabel, primaryStroke = pillButton(
		frame,
		"INVITE",
		UDim2.fromOffset(92, 34),
		UDim2.new(1, -6, 0.5, 0),
		Vector2.new(1, 0.5),
		Theme.Colors.Purple
	)
	local secondary, _, secondaryStroke = pillButton(
		frame,
		"NO",
		UDim2.fromOffset(56, 34),
		UDim2.new(1, -104, 0.5, 0),
		Vector2.new(1, 0.5),
		Theme.Colors.Pink
	)
	primary.Visible = withButtons
	secondary.Visible = false
	return {
		Frame = frame,
		Headshot = headshot,
		Name = name,
		Tag = tag,
		Primary = primary,
		PrimaryLabel = primaryLabel,
		PrimaryStroke = primaryStroke,
		Secondary = secondary,
		SecondaryStroke = secondaryStroke,
	}
end

local function buildWindow(body: Frame)
	local title = Ui.label(
		body,
		"PARTY",
		Theme.Fonts.Display,
		Theme.Colors.Purple,
		UDim2.fromOffset(300, 40),
		UDim2.fromOffset(LEFT_X, 16)
	)
	title.TextXAlignment = Enum.TextXAlignment.Left
	local subtitle = Ui.label(
		body,
		`Play together: a party queues together and is always on the same team. Up to {Config.Social.PartyMaxSize} players.`,
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(WINDOW_SIZE.X - 100, 18),
		UDim2.fromOffset(LEFT_X, 56)
	)
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	local close =
		pillButton(body, "X", UDim2.fromOffset(42, 42), UDim2.new(1, -18, 0, 18), Vector2.new(1, 0), Theme.Colors.Pink)
	close.Activated:Connect(function()
		setOpen(false)
	end)

	-- Left: your party, LEAVE, INVITE FRIENDS and the friend bonus.
	local left: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(LEFT_WIDTH, 380),
		Position = UDim2.fromOffset(LEFT_X, 86),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = body,
	})
	memberTitle = Ui.label(left, "YOUR PARTY", Theme.Fonts.Display, Theme.Colors.Ink, UDim2.new(1, 0, 0, 22))
	memberTitle.TextXAlignment = Enum.TextXAlignment.Left
	for index = 1, Config.Social.PartyMaxSize do
		memberRows[index] = buildRow(left, 28 + (index - 1) * (ROW_HEIGHT + ROW_GAP), LEFT_WIDTH, false)
	end
	local afterMembers = 28 + Config.Social.PartyMaxSize * (ROW_HEIGHT + ROW_GAP)
	soloHint = Ui.label(
		left,
		"You're not in a party yet. Invite someone from the list!",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, 0, 0, 40),
		UDim2.fromOffset(0, 40)
	)
	soloHint.TextWrapped = true
	local leave, _, leaveRim = pillButton(
		left,
		"LEAVE PARTY",
		UDim2.new(1, 0, 0, 38),
		UDim2.fromOffset(0, afterMembers + 2),
		Vector2.zero,
		Theme.Colors.Pink
	)
	leaveButton, leaveStroke = leave, leaveRim
	leaveButton.Activated:Connect(function()
		request("Leave")
	end)
	local inviteFriends, _, inviteFriendsRim = pillButton(
		left,
		"INVITE FRIENDS TO THE GAME",
		UDim2.new(1, 0, 0, 40),
		UDim2.fromOffset(0, afterMembers + 48),
		Vector2.zero,
		Theme.Colors.Aqua
	)
	inviteFriendsButton, inviteFriendsStroke = inviteFriends, inviteFriendsRim
	inviteFriendsButton.Activated:Connect(PartyController.PromptGameInvite)
	local bonus = Ui.label(
		left,
		`Friends in your match: +{math.floor(Config.Social.FriendBonusOne * 100 + 0.5)}% Gumdrops with one, +{math.floor(
			Config.Social.FriendBonusMore * 100 + 0.5
		)}% with two or more!`,
		Theme.Fonts.Body,
		Theme.Colors.Lime:Lerp(Theme.Colors.Ink, 0.35),
		UDim2.new(1, 0, 0, 36),
		UDim2.fromOffset(0, afterMembers + 96)
	)
	bonus.TextWrapped = true

	-- Right: invites to you, then everyone you can invite.
	local right: Frame = Ui.new("Frame", {
		Size = UDim2.fromOffset(RIGHT_WIDTH, 380),
		Position = UDim2.fromOffset(RIGHT_X, 86),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = body,
	})
	listTitle = Ui.label(right, "PLAYERS HERE", Theme.Fonts.Display, Theme.Colors.Ink, UDim2.new(1, -120, 0, 22))
	listTitle.TextXAlignment = Enum.TextXAlignment.Left
	for index = 1, PAGE_SIZE do
		listRows[index] = buildRow(right, 28 + (index - 1) * (ROW_HEIGHT + ROW_GAP), RIGHT_WIDTH, true)
	end
	for index, row in listRows do
		row.Primary.Activated:Connect(function()
			-- Find this row's button among the focusables and press it.
			for _, entry in focusables do
				if entry.Button == row.Primary then
					Ui.pressBounce(row.Primary)
					entry.Press()
					return
				end
			end
		end)
		row.Secondary.Activated:Connect(function()
			for _, entry in focusables do
				if entry.Button == row.Secondary then
					entry.Press()
					return
				end
			end
		end)
		row.Frame.Name = `Player{index}`
	end
	emptyLabel = Ui.label(
		right,
		"Nobody else is here yet. Use INVITE FRIENDS!",
		Theme.Fonts.Body,
		Theme.Colors.InkSoft,
		UDim2.new(1, 0, 0, 24),
		UDim2.fromOffset(0, 40)
	)
	local pagerY = 28 + PAGE_SIZE * (ROW_HEIGHT + ROW_GAP) + 4
	backButton =
		pillButton(right, "<", UDim2.fromOffset(40, 34), UDim2.fromOffset(0, pagerY), Vector2.zero, Theme.Colors.Purple)
	nextButton = pillButton(
		right,
		">",
		UDim2.fromOffset(40, 34),
		UDim2.new(1, 0, 0, pagerY),
		Vector2.new(1, 0),
		Theme.Colors.Purple
	)
	pageLabel = Ui.label(
		right,
		"1 / 1",
		Theme.Fonts.Display,
		Theme.Colors.InkSoft,
		UDim2.fromOffset(120, 24),
		UDim2.new(0.5, 0, 0, pagerY + 5),
		Vector2.new(0.5, 0)
	)
	backButton.Activated:Connect(function()
		turnPage(-1)
	end)
	nextButton.Activated:Connect(function()
		turnPage(1)
	end)
end

local function buildCard(playerGui: Instance)
	local cardGui: ScreenGui = Ui.new("ScreenGui", {
		Name = "PartyInvite",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		DisplayOrder = 26,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	card = Ui.new("Frame", {
		Name = "Card",
		Size = UDim2.fromOffset(420, 120),
		Position = UDim2.new(0.5, 0, 0, 124),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = cardGui,
	})
	ResponsiveScale.Attach(card, "Hud")
	local panel = Ui.panel(card, UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero)
	cardText = Ui.label(
		panel.Body,
		"",
		Theme.Fonts.Display,
		Theme.Colors.Ink,
		UDim2.new(1, -28, 0, 40),
		UDim2.new(0.5, 0, 0, 10),
		Vector2.new(0.5, 0)
	)
	cardText.TextWrapped = true
	local join = pillButton(
		panel.Body,
		"JOIN",
		UDim2.fromOffset(140, 42),
		UDim2.new(0.5, -8, 1, -12),
		Vector2.new(1, 1),
		Theme.Colors.Lime
	)
	local no = pillButton(
		panel.Body,
		"NO",
		UDim2.fromOffset(110, 42),
		UDim2.new(0.5, 8, 1, -12),
		Vector2.new(0, 1),
		Theme.Colors.Pink
	)
	join.Activated:Connect(function()
		answerCard(true)
	end)
	no.Activated:Connect(function()
		answerCard(false)
	end)
	cardHint = Ui.label(
		card,
		"LB to answer",
		Theme.Fonts.Body,
		WHITE,
		UDim2.new(1, 0, 0, 18),
		UDim2.new(0.5, 0, 1, 6),
		Vector2.new(0.5, 0)
	)
	Ui.new("UIStroke", {
		Color = Theme.Colors.Ink,
		Thickness = 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = cardHint,
	})
end

local function build()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	gui = Ui.new("ScreenGui", {
		Name = "Party",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 31,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = playerGui,
	})
	local dim: TextButton = Ui.new("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Shadow,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Parent = gui,
	})
	dim.Activated:Connect(function()
		setOpen(false)
	end)
	local window: Frame = Ui.new("Frame", {
		Name = "Window",
		Size = UDim2.fromOffset(WINDOW_SIZE.X, WINDOW_SIZE.Y),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	ResponsiveScale.Attach(window, "Hud")
	local panel = Ui.panel(window, UDim2.fromScale(1, 1), UDim2.new(), Vector2.zero)
	windowPanel = panel.Root
	buildWindow(panel.Body)
	buildCard(playerGui)
end

function PartyController.Init()
	build()
	Remotes.Event("PartyEvent").OnClientEvent:Connect(onPartyEvent)

	-- Anyone joining, leaving or changing party changes the lists.
	local function watch(player: Player)
		player:GetAttributeChangedSignal(PlayerAttr.Party):Connect(function()
			PartyController.Changed:Fire()
			if isOpen then
				refresh()
			end
		end)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		watch(player)
		PartyController.Changed:Fire()
		if isOpen then
			refresh()
		end
	end)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		invitesFrom[player] = nil
		sentTo[player] = nil
		friends[player] = nil
		friendChecked[player] = nil
		if cardFrom == player then
			card.Visible = false
			cardFrom = nil
		end
		task.defer(function()
			PartyController.Changed:Fire()
			if isOpen then
				refresh()
			end
		end)
	end)
	Input.SchemeChanged:Connect(function()
		cardHint.Visible = Input.GetScheme() == "Gamepad"
		if isOpen then
			showFocus()
		end
	end)
	-- Closes if a match pulls you in.
	MatchClient.LocalChanged:Connect(function(name: string)
		if name == PlayerAttr.Status and MatchClient.GetStatus() ~= "None" then
			setOpen(false)
		end
	end)

	-- LB opens it (and answers an invite card) while you're in the lobby. Spectating uses LB too,
	-- so it passes the button on anywhere else.
	ContextActionService:BindAction(
		OPEN_ACTION,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin and MatchClient.GetStatus() == "None" and not isOpen then
				setOpen(true)
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.KeyCode.ButtonL1
	)
	-- Keeps "SENT" and expired invites up to date while it's open.
	task.spawn(function()
		while true do
			task.wait(1)
			if isOpen then
				refresh()
			end
		end
	end)
end

return PartyController
