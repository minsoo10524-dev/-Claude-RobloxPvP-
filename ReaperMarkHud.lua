--!strict
-- ModuleScript "ReaperMarkHud" (parent: Tool "TrueKatana")
-- The MARK on the enemy and its distance, in the same language as BlinkCutHud: thin lines and text only, white and rose, one soft motion, nothing shouts.
--   * MARK: four thin corner brackets around the enemy. They are drawn as a screen element (a fixed size in pixels, always on top), so the mark has the
--     same size near and far. It closes in from a wide frame to a tight one with an ease (Quint), then it only rests.
--   * DISTANCE: one number under the mark with a small "STUDS" beside it (rose), the way "17 / 25" is drawn in the counter. It is rounded to whole
--     studs and the text changes only when the number does.
--   * It fades out when the mark ends (a soft fade, no pop).
-- API: Hud.show(model) | Hud.clear()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local WHITE = Color3.fromRGB(255, 241, 241)
local ROSE = Color3.fromRGB(251, 129, 127)
local FONT = Enum.Font.GothamMedium
local BOX = 112 -- pixels: the size of the mark when it rests
local ARM = 16 -- pixels: the length of one arm of a bracket
local LINE = 2 -- pixels: the thickness of the lines

local player = Players.LocalPlayer
local Hud = {}

local gui: BillboardGui? = nil
local group: CanvasGroup? = nil
local scale: UIScale? = nil
local connection: RBXScriptConnection? = nil
local ancestry: RBXScriptConnection? = nil
local token = 0 -- every new mark or clear cancels the fade of the old one

local function bracket(parent: Instance, x: number, y: number) -- x, y = 0 or 1: the corner (left/right, top/bottom)
	local function bar(w: number, h: number)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(x, y)
		f.Position = UDim2.fromScale(x, y)
		f.Size = UDim2.fromOffset(w, h)
		f.BackgroundColor3 = WHITE
		f.BorderSizePixel = 0
		f.Parent = parent
	end
	bar(ARM, LINE) -- the horizontal arm
	bar(LINE, ARM) -- the vertical arm
end

local function disconnect()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if ancestry then
		ancestry:Disconnect()
		ancestry = nil
	end
end

function Hud.clear()
	token += 1
	disconnect()
	local g, grp = gui, group
	gui, group, scale = nil, nil, nil
	if g and grp then
		TweenService:Create(grp, TweenInfo.new(0.3, Enum.EasingStyle.Sine), { GroupTransparency = 1 }):Play()
		task.delay(0.35, function() -- (a new mark has its own gui, so this one can always go)
			if g.Parent then g:Destroy() end
		end)
	end
end

function Hud.show(model: Model)
	Hud.clear()
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return end

	local g = Instance.new("BillboardGui")
	g.Name = "ReaperMark"
	g.Adornee = root
	g.Size = UDim2.fromOffset(BOX + 60, BOX + 60) -- a little room for the closing animation and the number
	g.AlwaysOnTop = true
	g.ResetOnSpawn = false
	g.Parent = root

	local grp = Instance.new("CanvasGroup") -- one group: the whole mark fades together
	grp.BackgroundTransparency = 1
	grp.Size = UDim2.fromScale(1, 1)
	grp.GroupTransparency = 1
	grp.Parent = g

	local sc = Instance.new("UIScale")
	sc.Scale = 1.7 -- it starts wide and closes in
	sc.Parent = grp

	local box = Instance.new("Frame") -- the four brackets
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.fromOffset(BOX, BOX)
	box.BackgroundTransparency = 1
	box.Parent = grp
	bracket(box, 0, 0)
	bracket(box, 1, 0)
	bracket(box, 0, 1)
	bracket(box, 1, 1)

	local label = Instance.new("TextLabel") -- the distance, under the mark
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.5, BOX / 2 + 6)
	label.Size = UDim2.fromOffset(160, 26)
	label.BackgroundTransparency = 1
	label.Font = FONT
	label.RichText = true
	label.TextSize = 22
	label.TextColor3 = WHITE
	label.Text = ""
	label.Parent = grp
	local stroke = Instance.new("UIStroke") -- a faint dark edge only for legibility on bright ground
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 1
	stroke.Transparency = 0.6
	stroke.Parent = label

	gui, group, scale = g, grp, sc
	local myToken = token
	TweenService:Create(grp, TweenInfo.new(0.25, Enum.EasingStyle.Sine), { GroupTransparency = 0 }):Play()
	TweenService:Create(sc, TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	local lastShown = -1
	connection = RunService.Heartbeat:Connect(function()
		if myToken ~= token then return end
		local char = player and player.Character
		local mine = char and char:FindFirstChild("HumanoidRootPart")
		if not (mine and mine:IsA("BasePart")) or not root.Parent then return end
		local d = math.floor((mine.Position - root.Position).Magnitude + 0.5)
		if d ~= lastShown then -- the text changes only when the number does
			lastShown = d
			label.Text = string.format('%d <font size="13" color="rgb(%d,%d,%d)">STUDS</font>', d, 251, 129, 127)
		end
	end)
	ancestry = model.AncestryChanged:Connect(function() -- the enemy was removed: the mark goes with it
		if not model:IsDescendantOf(workspace) then Hud.clear() end
	end)
end

return Hud
