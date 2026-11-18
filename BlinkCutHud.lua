--!strict
-- ModuleScript "BlinkCutHud" (parent: Tool "TrueKatana")
-- The SIGNATURE of BLINK CUT on the screen. Text and thin lines only (no pictures), in the white, rose and crimson of the normal attack.
-- It is made the way good game UI is made: SMALL, with few parts, thin lines, one accent colour, and motion that eases (nothing pops or shouts).
--   * TITLE: the name appears letter by letter (each letter fades in a little after the one before), then the space between the letters WIDENS slowly
--     (tracking), a thin line draws itself out from the middle underneath, and everything fades. A name that "opens" reads as expensive.
--   * COUNTER: one small number with the total beside it ("17 / 25") and a thin progress bar under it. The number only breathes (a small, soft swell
--     with every cut, a little more on every fifth); the bar fills with the flurry, white to crimson. The eye can count the cuts without a big number
--     that screams.
--   * FINISH: the bar flashes full, the number swells once more, and both fade out.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local WHITE = Color3.fromRGB(255, 241, 241)
local ROSE = Color3.fromRGB(251, 129, 127)
local CRIMSON = Color3.fromRGB(219, 43, 51)
local NAME = "BLINK CUT"
local FONT = Enum.Font.GothamMedium

local player = Players.LocalPlayer
local Hud = {}

local gui: ScreenGui? = nil
local titleRow: Frame? = nil
local titleLayout: UIListLayout? = nil
local letters: { TextLabel } = {}
local titleLine: Frame? = nil
local panel: Frame? = nil
local number: TextLabel? = nil
local numberScale: UIScale? = nil
local barBack: Frame? = nil
local barFill: Frame? = nil
local token = 0 -- every new count cancels the fades of the old one
local titleToken = 0 -- (the title has its own, so that the counter does not cancel its fade)

local function rgb(c: Color3): string
	return string.format("rgb(%d,%d,%d)", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function ensure(): boolean
	if gui and gui.Parent then return true end
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if not pg then return false end
	local g = Instance.new("ScreenGui")
	g.Name = "BlinkCutHud"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 20
	g.Parent = pg
	gui = g
	table.clear(letters)

	-- the title: a row of letters, centred, with a thin line under it
	local row = Instance.new("Frame")
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.2)
	row.Size = UDim2.fromOffset(420, 34)
	row.BackgroundTransparency = 1
	row.Parent = g
	titleRow = row
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 2)
	layout.Parent = row
	titleLayout = layout
	for i = 1, #NAME do
		local ch = string.sub(NAME, i, i)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.AutomaticSize = Enum.AutomaticSize.X
		l.Size = UDim2.fromOffset(0, 30)
		l.Font = FONT
		l.TextSize = 24
		l.Text = if ch == " " then "  " else ch
		l.TextColor3 = WHITE
		l.TextTransparency = 1
		l.LayoutOrder = i
		l.Parent = row
		local stroke = Instance.new("UIStroke") -- a faint dark edge only for legibility on bright ground
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Thickness = 1
		stroke.Transparency = 1
		stroke.Parent = l
		table.insert(letters, l)
	end
	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0.5, 0)
	line.Position = UDim2.new(0.5, 0, 1, 4)
	line.Size = UDim2.fromOffset(0, 2)
	line.BackgroundColor3 = ROSE
	line.BackgroundTransparency = 1
	line.BorderSizePixel = 0
	line.Parent = row
	titleLine = line

	-- the counter: the number and the total in one label (rich text), a thin bar under it
	local pn = Instance.new("Frame")
	pn.AnchorPoint = Vector2.new(0.5, 0.5)
	pn.Position = UDim2.fromScale(0.5, 0.82)
	pn.Size = UDim2.fromOffset(240, 64)
	pn.BackgroundTransparency = 1
	pn.Parent = g
	panel = pn
	local num = Instance.new("TextLabel")
	num.AnchorPoint = Vector2.new(0.5, 0)
	num.Position = UDim2.fromScale(0.5, 0)
	num.Size = UDim2.fromOffset(240, 44)
	num.BackgroundTransparency = 1
	num.Font = FONT
	num.RichText = true
	num.TextSize = 40
	num.Text = ""
	num.TextColor3 = WHITE
	num.TextTransparency = 1
	num.Parent = pn
	number = num
	local ns = Instance.new("UIScale")
	ns.Parent = num
	numberScale = ns
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 1
	stroke.Transparency = 1
	stroke.Parent = num
	local back = Instance.new("Frame")
	back.AnchorPoint = Vector2.new(0.5, 0)
	back.Position = UDim2.new(0.5, 0, 0, 52)
	back.Size = UDim2.fromOffset(200, 2)
	back.BackgroundColor3 = WHITE
	back.BackgroundTransparency = 1
	back.BorderSizePixel = 0
	back.Parent = pn
	barBack = back
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = WHITE
	fill.BackgroundTransparency = 1
	fill.BorderSizePixel = 0
	fill.Parent = back
	local grad = Instance.new("UIGradient") -- the bar goes from white to crimson along its length
	grad.Color = ColorSequence.new(WHITE, CRIMSON)
	grad.Parent = fill
	barFill = fill
	return true
end

local function textFade(l: TextLabel, to: number, seconds: number, style: Enum.EasingStyle?)
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	TweenService:Create(l, info, { TextTransparency = to }):Play()
	local stroke = l:FindFirstChildOfClass("UIStroke")
	if stroke then TweenService:Create(stroke, info, { Transparency = if to >= 1 then 1 else 0.6 }):Play() end
end

-- the name: letter by letter, the tracking widens, the line draws out, then it fades
function Hud.title()
	if not ensure() or not titleLayout or not titleLine then return end
	titleToken += 1
	local myToken = titleToken
	local layout, line = titleLayout, titleLine
	layout.Padding = UDim.new(0, 2)
	line.Size = UDim2.fromOffset(0, 2)
	line.BackgroundTransparency = 1
	for i, l in letters do
		l.TextTransparency = 1
		task.delay((i - 1) * 0.035, function() -- each letter a little after the one before
			if myToken == titleToken then textFade(l, 0, 0.28) end
		end)
	end
	TweenService:Create(layout, TweenInfo.new(1.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Padding = UDim.new(0, 9) }):Play() -- tracking
	line.BackgroundTransparency = 0.2
	TweenService:Create(line, TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(240, 2) }):Play()
	task.delay(1.1, function()
		if myToken ~= titleToken then return end
		for _, l in letters do textFade(l, 1, 0.45) end
		TweenService:Create(line, TweenInfo.new(0.45), { BackgroundTransparency = 1 }):Play()
	end)
end

-- one cut: n of total
function Hud.count(n: number, total: number)
	if not ensure() or not number or not numberScale or not barBack or not barFill then return end
	token += 1
	local myToken = token
	local num, ns, back, fill = number, numberScale, barBack, barFill
	local p = math.clamp(n / math.max(total, 1), 0, 1)
	-- the number in white, the total beside it small and rose
	num.Text = string.format('%d <font size="18" color="%s">/ %d</font>', n, rgb(ROSE), total)
	num.TextColor3 = WHITE:Lerp(ROSE, p * 0.5)
	textFade(num, 0, 0.08)
	back.BackgroundTransparency = 0.8
	fill.BackgroundTransparency = 0
	TweenService:Create(fill, TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Size = UDim2.fromScale(p, 1) }):Play()
	-- the breath: a small, soft swell that settles (a little more on every fifth cut)
	ns.Scale = if n % 5 == 0 then 1.18 else 1.08
	TweenService:Create(ns, TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(0.9, function() -- (it fades by itself if the flurry is interrupted)
		if myToken ~= token then return end
		textFade(num, 1, 0.3)
		TweenService:Create(back, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(fill, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
	end)
end

-- the last cut: the bar flashes full, the number swells once more, both fade
function Hud.finish()
	if not ensure() or not number or not numberScale or not barBack or not barFill then return end
	token += 1
	local num, ns, back, fill = number, numberScale, barBack, barFill
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundTransparency = 0
	back.BackgroundTransparency = 0.6
	ns.Scale = 1
	TweenService:Create(ns, TweenInfo.new(0.6, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Scale = 1.3 }):Play()
	task.delay(0.12, function()
		textFade(num, 1, 0.5)
		TweenService:Create(back, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(fill, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
	end)
end

-- LETTERBOX (cinema bars): two black bars slide in from the top and the bottom for `seconds` and slide out again. A wide, bar-framed picture reads as
-- "a film shot": it tells the eye that this is the big moment (the ultimate cut). It eases in and out (Quint).
function Hud.bars(seconds: number)
	if not ensure() or not gui then return end
	local g = gui
	local function bar(top: boolean): Frame
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0, if top then 0 else 1)
		f.Position = UDim2.fromScale(0, if top then 0 else 1)
		f.Size = UDim2.fromScale(1, 0)
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BorderSizePixel = 0
		f.ZIndex = 0
		f.Parent = g
		return f
	end
	local top, bottom = bar(true), bar(false)
	local into = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenService:Create(top, into, { Size = UDim2.fromScale(1, 0.11) }):Play()
	TweenService:Create(bottom, into, { Size = UDim2.fromScale(1, 0.11) }):Play()
	task.delay(seconds, function()
		local out = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
		TweenService:Create(top, out, { Size = UDim2.fromScale(1, 0) }):Play()
		TweenService:Create(bottom, out, { Size = UDim2.fromScale(1, 0) }):Play()
		task.delay(0.45, function()
			top:Destroy()
			bottom:Destroy()
		end)
	end)
end

-- everything is hidden at once (the sword is put away, or the skill was interrupted)
function Hud.clear()
	token += 1
	titleToken += 1
	for _, l in letters do
		l.TextTransparency = 1
		local stroke = l:FindFirstChildOfClass("UIStroke")
		if stroke then stroke.Transparency = 1 end
	end
	if titleLine then titleLine.BackgroundTransparency = 1 end
	if number then number.TextTransparency = 1 end
	if barBack then barBack.BackgroundTransparency = 1 end
	if barFill then barFill.BackgroundTransparency = 1 end
end

return Hud
