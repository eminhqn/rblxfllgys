--!strict
-- Draws a thin team-coloured outline around Bloblets that are on a team (team rounds only;
-- nobody has a team in the lobby or in solo rounds). Bots' Bloblets too (Shared/Competitors).
--
-- Roblox renders at most 31 Highlights at once, so with 30 players we outline the nearest
-- MAX_OUTLINES characters (you are always nearest) and refresh the set twice a second.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Competitors = require(Shared.Competitors)
local Tags = require(Shared.Tags)

local TeamOutlines = {}

local MAX_OUTLINES = 28
local REFRESH_INTERVAL = 0.5

type Candidate = {
	Character: Model,
	Color: Color3,
	Distance: number,
}

local highlights: { [Model]: Highlight } = {}

local function refresh()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position

	local candidates: { Candidate } = {}
	for _, instance in CollectionService:GetTagged(Tags.Bloblet) do
		if not instance:IsA("Model") then
			continue
		end
		local character = instance
		local team = Competitors.TeamOf(character)
		local root = character.PrimaryPart
		if root and team and character:IsDescendantOf(Workspace) then
			table.insert(candidates, {
				Character = character,
				Color = team.Color,
				Distance = (root.Position - cameraPosition).Magnitude,
			})
		end
	end
	table.sort(candidates, function(a: Candidate, b: Candidate)
		return a.Distance < b.Distance
	end)

	local keep: { [Model]: boolean } = {}
	for index = 1, math.min(MAX_OUTLINES, #candidates) do
		local candidate = candidates[index]
		local character = candidate.Character
		keep[character] = true
		local existing = highlights[character]
		local highlight: Highlight
		if existing and existing.Parent == character then
			highlight = existing
		else
			highlight = Instance.new("Highlight")
			highlight.Name = "TeamOutline"
			highlight.FillTransparency = 1
			highlight.OutlineTransparency = 0.05
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Parent = character
			highlights[character] = highlight
		end
		highlight.OutlineColor = candidate.Color
	end

	for character, highlight in highlights do
		if not keep[character] then
			highlight:Destroy()
			highlights[character] = nil
		end
	end
end

function TeamOutlines.Init()
	task.spawn(function()
		while true do
			refresh()
			task.wait(REFRESH_INTERVAL)
		end
	end)
end

return TeamOutlines
