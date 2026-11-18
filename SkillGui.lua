--!strict
-- LocalScript "SkillGuiMotion" (parent: Tool "DarkV1", next to the ScreenGui "SkillGui")
-- BUILDS its own ScreenGui "SkillGui" in code (nothing has to be made by hand in the tool; an old ScreenGui in the tool is simply not used) and shows it
-- while the tool is equipped. The names of the texts are the same as before: Title, Key, YName (the Z skill), Key, XName (the X skill). The gui springs in (one top-level element after the other) and springs out
-- when the tool is put away. Buttons swell when the mouse is over them, sink when pressed and spring back. Clicking any frame, text or
-- picture of the gui makes THAT element swell a little and settle (an impulse on a spring).
-- COOLDOWNS: the TextLabels "YName" (the Z skill) and "XName" show the seconds left (one decimal) while the skill is cooling down; with the mouse over
-- the label (or a touch on it, for 1.5 s) the skill's name comes back; when the cooldown ends the name returns with a small swell.
-- The time is the later of two numbers (server time): the player attribute ZReadyAt / XReadyAt (the server's, the one that counts) and
-- ZReadyAtLocal / XReadyAtLocal (the client's own guess that the skill script writes the moment a skill is pressed, so the number
-- appears with no delay).
-- Science (PHYSICS / PERCEPTION):
--   * Every motion is a DAMPED HARMONIC OSCILLATOR: x'' = -w^2 (x - target) - 2 z w x' (Hooke's law with friction). A damping ratio z below 1
--     overshoots a little and settles, like a real mass on a spring; z near 1 is crisp. It is solved exactly (not step by step), so the motion
--     is the same at 30 and at 240 frames per second, and it keeps its speed when it is turned around (equip, then quickly unequip).
--   * A click is an IMPULSE: the spring is hit with a starting speed and answers with a swell that dies out. Its size is chosen so the
--     edge moves about the same number of pixels (PULSE_PX) whatever the size of the element: the eye judges a displacement in pixels,
--     not in percent, so a big frame gets a smaller percentage than a small label.
--   * The elements start one after the other (a travelling wave): the eye follows a sequence more easily than everything at once.
--   * The hover brightening is 8%: the smallest change of brightness the eye notices is about 2% (Weber's law), so 8% is clearly seen
--     but still calm.
--   * Only what moves is drawn each frame: one Heartbeat connection exists only while something is still moving.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then return end
local toolParent = script.Parent
if not (toolParent and toolParent:IsA("Tool")) then return end
local tool: Tool = toolParent

-- Estimated values: tune in game
local GUI_NAME = "SkillGui"
local SLIDE = 18 -- pixels the elements rise while they appear
local APPEAR_SCALE = 0.9 -- the size they start at
local STAGGER = 0.05 -- seconds between two elements
local APPEAR_W, APPEAR_Z = 20, 0.62 -- appear: speed of the spring (rad/s) and damping ratio (a little overshoot)
local HIDE_W, HIDE_Z = 28, 0.9 -- disappear: faster and with almost no overshoot
local BTN_W, BTN_Z = 30, 0.5 -- buttons: snappy with a small bounce
local HOVER, PRESS = 1.06, 0.94 -- button size when the mouse is over it / when it is pressed
local HOVER_LIGHT = 0.08 -- brightening of a button at full hover
local PULSE_PX = 6 -- how many pixels the edge of a clicked element swells
local PULSE_MIN, PULSE_MAX = 0.015, 0.08 -- the swell never gets smaller or bigger than this (as a fraction of the size)
local PULSE_W, PULSE_Z = 34, 0.45 -- click swell: fast and springy
local FIND_WAIT = 3 -- seconds to wait for the SkillGui to arrive
local MAX_DT = 1 / 20 -- a long frame never throws the spring around

local REVEAL_TOUCH = 1.5 -- seconds the name stays after a touch on a cooling label
local COOL_DIM = 0.45 -- how much the number is dimmed toward grey while it counts down

-- the skills with a cooldown label: the label's name in the gui, and the attribute that holds the server time of "ready"
local SKILLS: { { label: string, attr: string, total: number } } = {
	{ label = "YName", attr = "ZReadyAt", total = 16.5 }, -- (the Z skill's label is called YName in the gui)
	{ label = "XName", attr = "XReadyAt", total = 12 }, -- (total = the length of the cooldown, for the progress line)
}

local WHITE = Color3.new(1, 1, 1)
local GREY = Color3.fromRGB(150, 150, 150)

type Spring = { x: number, v: number, target: number, w: number, z: number }
type Fade = { inst: Instance, prop: string, base: number }
type Item = { root: GuiObject, scale: UIScale, baseScale: number, basePos: UDim2, fades: { Fade }, spring: Spring, delay: number }
type Btn = { button: GuiButton, scale: UIScale, baseScale: number, base: Color3?, spring: Spring, over: boolean, down: boolean }
type Pulse = { scale: UIScale, baseScale: number, spring: Spring }
type Cd = {
	label: TextLabel, name: string, color: Color3, attr: string,
	hover: boolean, revealUntil: number, cooling: boolean, fill: Frame?, total: number,
}
type Session = {
	gui: ScreenGui, items: { Item }, buttons: { Btn }, pulses: { [GuiObject]: Pulse }, cds: { Cd },
	conns: { RBXScriptConnection }, hiding: boolean,
	ready: boolean, -- the appear motion has finished: clicks are answered only now
}

local session: Session? = nil
local loop: RBXScriptConnection? = nil
local token = 0 -- grows with every sync; work that waited (yielded) checks it afterwards
local warnedMissing = false
local warnedLoop = false
local warnedLabel: { [string]: boolean } = {}
local updateCooldowns: (s: Session) -> boolean -- (defined below; step needs it)

--------------------------------------------------------------------------------
-- Spring
--------------------------------------------------------------------------------
local function newSpring(x: number, target: number, w: number, z: number): Spring
	return { x = x, v = 0, target = target, w = w, z = math.clamp(z, 0.05, 0.99) }
end

-- exact solution of the underdamped spring after dt seconds
local function advance(s: Spring, dt: number)
	local w, z = s.w, s.z
	local wd = w * math.sqrt(1 - z * z)
	local e = math.exp(-z * w * dt)
	local c, sn = math.cos(wd * dt), math.sin(wd * dt)
	local a = s.x - s.target
	local b = (s.v + z * w * a) / wd
	local osc = a * c + b * sn
	s.x = s.target + e * osc
	s.v = e * (-z * w * osc + wd * (b * c - a * sn))
end

local function settled(s: Spring): boolean
	return math.abs(s.x - s.target) < 0.002 and math.abs(s.v) < 0.02
end

--------------------------------------------------------------------------------
-- Applying the springs to the gui
--------------------------------------------------------------------------------
local function applyItem(item: Item)
	local x = item.spring.x
	local alpha = math.clamp(x, 0, 1)
	for _, f in item.fades do
		(f.inst :: any)[f.prop] = 1 - (1 - f.base) * alpha
	end
	item.scale.Scale = item.baseScale * (APPEAR_SCALE + (1 - APPEAR_SCALE) * x)
	item.root.Position = item.basePos + UDim2.fromOffset(0, (1 - x) * SLIDE)
end

local function applyButton(b: Btn)
	local x = b.spring.x
	b.scale.Scale = b.baseScale * x
	local base = b.base
	if base then
		b.button.BackgroundColor3 = base:Lerp(WHITE, math.clamp((x - 1) / (HOVER - 1), 0, 1) * HOVER_LIGHT)
	end
end

--------------------------------------------------------------------------------
-- Session: build, run, end
--------------------------------------------------------------------------------
local function stopLoop()
	if loop then
		loop:Disconnect()
		loop = nil
	end
end

local function endSession(s: Session)
	if session == s then
		session = nil
		stopLoop()
	end
	for _, c in s.conns do c:Disconnect() end
	table.clear(s.conns)
	pcall(function() s.gui:Destroy() end)
end

local function snap(s: Session) -- the springs jump to their end (used when the animation fails)
	for _, item in s.items do
		item.spring.x, item.spring.v = item.spring.target, 0
		pcall(applyItem, item)
	end
	for _, b in s.buttons do
		b.spring.x, b.spring.v = b.spring.target, 0
		pcall(applyButton, b)
	end
	for _, p in s.pulses do
		p.scale.Scale = p.baseScale
	end
	s.ready = true
end

local function step(dt: number)
	local s = session
	if not s then
		stopLoop()
		return
	end
	dt = math.min(dt, MAX_DT)
	local busy = false
	local itemsBusy = false
	for _, item in s.items do
		if item.delay > 0 then
			item.delay -= dt
			itemsBusy = true
		else
			advance(item.spring, dt)
			applyItem(item)
			if not settled(item.spring) then itemsBusy = true end
		end
	end
	if not itemsBusy and not s.hiding then s.ready = true end
	busy = itemsBusy
	for _, b in s.buttons do
		if not settled(b.spring) then
			advance(b.spring, dt)
			applyButton(b)
			busy = true
		end
	end
	for _, p in s.pulses do
		if not settled(p.spring) then
			advance(p.spring, dt)
			p.scale.Scale = p.baseScale * p.spring.x
			busy = true
		end
	end
	if not s.hiding and updateCooldowns(s) then busy = true end
	if not busy then
		stopLoop()
		if s.hiding then endSession(s) end
	end
end

local function startLoop()
	if loop then return end
	loop = RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(step, dt)
		if not ok then
			if not warnedLoop then
				warnedLoop = true
				warn("[SkillGui] animation stopped:", err)
			end
			stopLoop()
			local s = session
			if s then
				snap(s)
				if s.hiding then endSession(s) end
			end
		end
	end)
end

local function fadesOf(root: GuiObject): { Fade }
	local list: { Fade } = {}
	local function add(inst: Instance, prop: string, base: number)
		if base < 1 then table.insert(list, { inst = inst, prop = prop, base = base }) end -- (an invisible element stays invisible)
	end
	local function scan(inst: Instance)
		if inst:IsA("GuiObject") then add(inst, "BackgroundTransparency", inst.BackgroundTransparency) end
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			add(inst, "ImageTransparency", inst.ImageTransparency)
		elseif inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			add(inst, "TextTransparency", inst.TextTransparency)
			add(inst, "TextStrokeTransparency", inst.TextStrokeTransparency)
		elseif inst:IsA("UIStroke") then
			add(inst, "Transparency", inst.Transparency)
		end
	end
	scan(root)
	for _, d in root:GetDescendants() do scan(d) end
	return list
end

-- the UIScale of an element: the one it already has, or a new one
local function scaleOf(inst: GuiObject): (UIScale, number)
	local existing = inst:FindFirstChildOfClass("UIScale")
	if existing then return existing, existing.Scale end
	local made = Instance.new("UIScale")
	made.Parent = inst
	return made, 1
end

local function wireButton(s: Session, button: GuiButton)
	local scale, baseScale = scaleOf(button)
	local hasFill = button.BackgroundTransparency < 1
	if hasFill then button.AutoButtonColor = false end -- the spring does the feedback
	local b: Btn = {
		button = button, scale = scale, baseScale = baseScale, base = hasFill and button.BackgroundColor3 or nil,
		spring = newSpring(1, 1, BTN_W, BTN_Z), over = false, down = false,
	}
	table.insert(s.buttons, b)

	local function aim()
		if s.hiding then return end
		b.spring.target = if b.down then PRESS elseif b.over then HOVER else 1
		startLoop()
	end
	table.insert(s.conns, button.MouseEnter:Connect(function() b.over = true aim() end))
	table.insert(s.conns, button.MouseLeave:Connect(function() b.over = false b.down = false aim() end))
	table.insert(s.conns, button.MouseButton1Down:Connect(function() b.down = true aim() end))
	table.insert(s.conns, button.MouseButton1Up:Connect(function() b.down = false aim() end))
end

-- a click on a frame, a text or a picture: that element gets a short swell
local function pulse(s: Session, g: GuiObject)
	local p = s.pulses[g]
	if not p then
		local scale, baseScale = scaleOf(g)
		p = { scale = scale, baseScale = baseScale, spring = newSpring(1, 1, PULSE_W, PULSE_Z) }
		s.pulses[g] = p
	end
	local size = math.max(g.AbsoluteSize.X, g.AbsoluteSize.Y, 1)
	local amplitude = math.clamp(PULSE_PX / size, PULSE_MIN, PULSE_MAX) -- the same number of pixels for every size
	p.spring.v = amplitude * PULSE_W -- the impulse (the swell reaches about the amplitude)
	startLoop()
end

--------------------------------------------------------------------------------
-- Cooldown labels
--------------------------------------------------------------------------------
-- the later of the server's value and the client's own guess (the skill script writes the guess as a client-only attribute)
local function readyAt(attr: string): number
	local server = player:GetAttribute(attr)
	local guess = player:GetAttribute(attr .. "Local")
	return math.max(if typeof(server) == "number" then server else 0, if typeof(guess) == "number" then guess else 0)
end

-- writes the right text into every cooldown label; returns true while any skill is still cooling down
updateCooldowns = function(s: Session): boolean
	local now = workspace:GetServerTimeNow()
	local clock = os.clock()
	local active = false
	for _, cd in s.cds do
		local remaining = readyAt(cd.attr) - now
		local fillBar = cd.fill -- the progress line under the skill: it fills while the skill cools down, and is full (pale) when it is ready
		if fillBar then
			fillBar.Size = UDim2.fromScale(if remaining > 0 then math.clamp(1 - remaining / cd.total, 0, 1) else 1, 1)
			fillBar.BackgroundColor3 = if remaining > 0 then Color3.fromRGB(251, 129, 127) else Color3.fromRGB(255, 241, 241)
		end
		local text = cd.name
		local color = cd.color
		if remaining > 0 then
			active = true
			cd.cooling = true
			if not (cd.hover or clock < cd.revealUntil) then
				text = string.format("%.1f", remaining) -- one decimal, always
				color = cd.color:Lerp(GREY, COOL_DIM)
			end
		elseif cd.cooling then
			cd.cooling = false
			pulse(s, cd.label) -- ready again: the name comes back with a small swell
		end
		if cd.label.Text ~= text then cd.label.Text = text end -- (written only when it changes)
		if cd.label.TextColor3 ~= color then cd.label.TextColor3 = color end
	end
	return active
end

local function wireCooldown(s: Session, gui: ScreenGui, def: { label: string, attr: string, total: number })
	-- the EXACT name, and only a TextLabel: other labels (or other things with the same name) are never touched
	local label: TextLabel? = nil
	local others: { string } = {}
	for _, d in gui:GetDescendants() do
		if d:IsA("TextLabel") then
			if d.Name == def.label then
				label = d
				break
			end
			table.insert(others, d.Name)
		end
	end
	if not label then
		if not warnedLabel[def.label] then
			warnedLabel[def.label] = true
			warn("[SkillGui] there is no TextLabel named " .. def.label .. " inside " .. GUI_NAME .. ". The TextLabels it has: " .. table.concat(others, ", "))
		end
		return
	end
	local cd: Cd = {
		label = label, name = label.Text, color = label.TextColor3, attr = def.attr,
		hover = false, revealUntil = 0, cooling = false,
		fill = (if label.Parent then label.Parent:FindFirstChild("Fill", true) else nil) :: Frame?, total = def.total,
	}
	table.insert(s.cds, cd)
	table.insert(s.conns, label.MouseEnter:Connect(function() cd.hover = true startLoop() end))
	table.insert(s.conns, label.MouseLeave:Connect(function() cd.hover = false startLoop() end))
	table.insert(s.conns, label.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then -- there is no "mouse over" on a phone: a touch shows the name for a moment
			cd.revealUntil = os.clock() + REVEAL_TOUCH
			startLoop()
		end
	end))
	table.insert(s.conns, player:GetAttributeChangedSignal(def.attr):Connect(startLoop)) -- a new cooldown starts the counting
	table.insert(s.conns, player:GetAttributeChangedSignal(def.attr .. "Local"):Connect(startLoop))
end

local function onInput(s: Session, input: InputObject)
	if s.hiding or not s.ready then return end
	local kind = input.UserInputType
	if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
	local pg = s.gui.Parent
	if not (pg and pg:IsA("PlayerGui")) then return end
	local ok, hits = pcall(function() return pg:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y) end)
	if not ok then return end
	for _, g in hits do -- the topmost first
		if g:IsDescendantOf(s.gui) and g.Visible then
			if g:IsA("GuiButton") or g:FindFirstAncestorWhichIsA("GuiButton") then return end -- buttons have their own press motion
			if g.BackgroundTransparency < 1 or g:IsA("TextLabel") or g:IsA("ImageLabel") then -- (an empty container is skipped)
				pulse(s, g)
				return
			end
		end
	end
end

local function build(gui: ScreenGui): Session
	local s: Session = { gui = gui, items = {}, buttons = {}, pulses = {}, cds = {}, conns = {}, hiding = false, ready = false }
	local i = 0
	for _, child in gui:GetChildren() do
		if child:IsA("GuiObject") then
			local scale, baseScale = scaleOf(child)
			local item: Item = {
				root = child, scale = scale, baseScale = baseScale, basePos = child.Position, fades = fadesOf(child),
				spring = newSpring(0, 1, APPEAR_W, APPEAR_Z), delay = i * STAGGER,
			}
			table.insert(s.items, item)
			applyItem(item) -- hidden at once, before the first frame is drawn
			i += 1
		end
	end
	if #s.items == 0 then s.ready = true end
	for _, d in gui:GetDescendants() do
		if d:IsA("GuiButton") then wireButton(s, d) end
	end
	for _, def in SKILLS do
		wireCooldown(s, gui, def)
	end
	pcall(updateCooldowns, s) -- the right text from the very first frame (a cooldown may still be running from before)
	table.insert(s.conns, UserInputService.InputBegan:Connect(function(input: InputObject)
		local ok, err = pcall(onInput, s, input)
		if not ok and not warnedLoop then
			warnedLoop = true
			warn("[SkillGui] click motion failed:", err)
		end
	end))
	table.insert(s.conns, gui.Destroying:Connect(function()
		if session == s then
			session = nil
			stopLoop()
		end
	end))
	return s
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------
-- THE GUI, made in code. The same language as the BLINK CUT hud: text and thin lines only, white and rose, GothamMedium.
-- Top level: "Title" and the two slots (they spring in one after the other). Names of the texts: Title, Key, YName / XName (the same as before).
local ROSE = Color3.fromRGB(251, 129, 127)
local PALE = Color3.fromRGB(255, 241, 241)
local FONT = Enum.Font.GothamMedium

local function label(parent: Instance, name: string, text: string, size: number, pos: UDim2, dim: UDim2, color: Color3, align: Enum.TextXAlignment): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = pos
	l.Size = dim
	l.Font = FONT
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color
	l.TextXAlignment = align
	l.Parent = parent
	local stroke = Instance.new("UIStroke") -- a faint dark edge only for legibility on bright ground
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 1
	stroke.Transparency = 0.6
	stroke.Parent = l
	return l
end

-- one row, in the style of BlinkCutHud: NO panel, NO box: the key letter (rose), the name (white) and ONE thin line under them that fills while the skill cools down.
-- (the cooldown number replaces the name while it counts, see updateCooldowns)
local function row(gui: ScreenGui, y: number, key: string, labelName: string, skill: string)
	local f = Instance.new("Frame")
	f.Name = key .. "Slot"
	f.AnchorPoint = Vector2.new(1, 0)
	f.Position = UDim2.new(1, -28, 0.5, y)
	f.Size = UDim2.fromOffset(176, 38)
	f.BackgroundTransparency = 1
	f.Parent = gui
	label(f, "Key", key, 16, UDim2.fromOffset(0, 0), UDim2.fromOffset(22, 24), ROSE, Enum.TextXAlignment.Left)
	label(f, labelName, skill, 15, UDim2.fromOffset(26, 0), UDim2.fromOffset(150, 24), PALE, Enum.TextXAlignment.Left)
	local track = Instance.new("Frame") -- the thin line: a faint track and the fill that grows
	track.Name = "Track"
	track.Position = UDim2.fromOffset(26, 30)
	track.Size = UDim2.fromOffset(150, 2)
	track.BackgroundColor3 = PALE
	track.BackgroundTransparency = 0.85
	track.BorderSizePixel = 0
	track.Parent = f
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = PALE
	fill.BorderSizePixel = 0
	fill.Parent = track
end

local function createGui(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.IgnoreGuiInset = true
	local letters: { string } = {}
	local name = "TRUE KATANA"
	for i = 1, #name do
		letters[i] = string.sub(name, i, i)
	end
	local title = label(gui, "Title", table.concat(letters, "\u{2009}\u{200A}"), 11, UDim2.new(1, -204, 0.5, -30), UDim2.fromOffset(176, 16), ROSE, Enum.TextXAlignment.Left)
	title.TextTransparency = 0.2
	row(gui, -6, "Z", "YName", "BLINK CUT") -- (the Z skill's text is called YName)
	row(gui, 40, "X", "XName", "REAPER'S MARK")
	return gui
end

local function getPlayerGui(): PlayerGui?
	local found = player:FindFirstChildOfClass("PlayerGui")
	if found then return found end
	local ok, gui = pcall(function() return player:WaitForChild("PlayerGui", 2) end) -- yields
	if ok and gui and gui:IsA("PlayerGui") then return gui end
	return nil
end

local function isEquipped(): boolean
	local parent = tool.Parent
	return parent ~= nil and parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid") ~= nil
end

local function hideGui()
	local s = session
	if not s or s.hiding then return end
	s.hiding = true
	s.ready = false
	for _, item in s.items do
		item.delay = 0
		item.spring.target, item.spring.w, item.spring.z = 0, HIDE_W, HIDE_Z
	end
	for _, b in s.buttons do
		b.spring.target = 1
	end
	startLoop()
end

local function showGui(myToken: number)
	local s = session
	if s and s.gui.Parent then
		if s.hiding then -- it is on its way out: turn it around, keeping its speed
			s.hiding = false
			for _, item in s.items do
				item.delay = 0
				item.spring.target, item.spring.w, item.spring.z = 1, APPEAR_W, APPEAR_Z
			end
			startLoop()
		end
		return
	end

	local pg = getPlayerGui() -- may yield
	if myToken ~= token or not pg then return end
	if myToken ~= token then return end
	local made, clone = pcall(createGui)
	if not (made and clone and clone:IsA("ScreenGui")) then
		if not warnedMissing then
			warnedMissing = true
			warn("[SkillGui] could not build the gui:", clone)
		end
		return
	end
	clone.Name = GUI_NAME
	clone.Enabled = true
	clone.ResetOnSpawn = false

	local built, result = pcall(build, clone)
	if not built then -- the animation could not be prepared: the gui still shows, just without motion
		warn("[SkillGui] could not prepare the animation:", result)
		clone.Parent = pg
		session = { gui = clone, items = {}, buttons = {}, pulses = {}, cds = {}, conns = {}, hiding = false, ready = false }
		return
	end
	local newSession: Session = result
	session = newSession
	clone.Parent = pg
	if clone.Parent ~= pg then
		endSession(newSession)
		return
	end
	startLoop()
end

-- one function decides from the state of the tool: equip, unequip, death, respawn and removal all go through it
local function sync()
	token += 1
	if isEquipped() then
		task.spawn(showGui, token)
	else
		hideGui()
	end
end

tool.Equipped:Connect(sync)
tool.Unequipped:Connect(sync)
tool.AncestryChanged:Connect(function(_, parent)
	if parent == nil then -- removed for good: no animation, the gui goes at once
		token += 1
		local s = session
		if s then endSession(s) end
	else
		sync()
	end
end)

if isEquipped() then task.defer(sync) end
