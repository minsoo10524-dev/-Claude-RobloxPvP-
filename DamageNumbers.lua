--!strict
-- LocalScript "DamageNumbers"  (parent: Tool "DarkV1", next to Client)
-- A small number above each enemy that is hit, fed by the "hit" / "blast" / "slam" messages the Server sends
-- (each entry carries damage and killed): it slams in, flies up fast and fades.
-- Only you (the attacker) see these; nothing is replicated and nothing is sent back.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local tool = script.Parent :: Tool
local player = Players.LocalPlayer
local feedback = tool:WaitForChild("FeedbackFX") :: RemoteEvent

type Colors = { text: Color3, stroke: Color3 }
type Popup = { bb: BillboardGui, label: TextLabel, stroke: UIStroke, scale: UIScale }
type Item = { popup: Popup, adornee: BasePart, t: number, heavy: boolean, sx: number, sy: number }
type Recent = { t: number, count: number }

local CONFIG = {
	Life = 0.7, -- seconds on screen
	Rise = 1.0, -- studs it floats up (a little, then it stops)
	PopTime = 0.1, -- seconds of the small pop-in
	FadeTime = 0.25,
	StackWindow = 0.35, -- hits on the same enemy inside this time are spread apart
	MaxActive = 40,
	MaxDistance = 150, -- studs
	Font = Enum.Font.FredokaOne, -- thick and rounded
	LightSize = 44,
	HeavySize = 76, -- the hit 3 slam
}
local STYLES: { [string]: Colors } = {
	Light = { text = Color3.fromRGB(255, 200, 210), stroke = Color3.fromRGB(20, 8, 12) }, -- pale pink with a dark outline
	Heavy = { text = Color3.fromRGB(255, 92, 104), stroke = Color3.fromRGB(20, 4, 8) },
	Kill = { text = Color3.fromRGB(255, 216, 150), stroke = Color3.fromRGB(30, 10, 6) },
}

local gui = Instance.new("ScreenGui")
gui.Name = "DarkDamageNumbers"
gui.ResetOnSpawn = false
gui.DisplayOrder = 50
gui.Parent = player:WaitForChild("PlayerGui")

local function outBack(x: number): number
	local c1 = 1.70158
	local c3 = c1 + 1
	return 1 + c3 * (x - 1) ^ 3 + c1 * (x - 1) ^ 2
end

local function outExpo(x: number): number
	if x >= 1 then return 1 end
	return 1 - 2 ^ (-10 * x)
end

local pool: { Popup } = {} -- popups are reused, never destroyed
local active: { Item } = {}
local recent: { [Model]: Recent } = setmetatable({}, { __mode = "k" }) :: any
local loopConn: RBXScriptConnection? = nil

local function makePopup(): Popup
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(320, 130)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = CONFIG.MaxDistance
	bb.ResetOnSpawn = false
	bb.Enabled = false

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.Font = CONFIG.Font
	label.Text = ""
	label.TextSize = CONFIG.LightSize

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3.5
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Parent = label

	label.Parent = bb
	bb.Parent = gui
	return { bb = bb, label = label, stroke = stroke, scale = scale }
end

local function release(item: Item)
	item.popup.bb.Enabled = false
	item.popup.bb.Adornee = nil
	table.insert(pool, item.popup)
end

local function stepNumbers(dt: number)
	local fadeStart = CONFIG.Life - CONFIG.FadeTime
	for i = #active, 1, -1 do
		local item = active[i]
		item.t += dt
		local t = item.t
		local p = item.popup
		if t >= CONFIG.Life or not item.adornee.Parent then
			release(item)
			active[i] = active[#active]
			active[#active] = nil
		else
			-- position: shoots up fast, then slows (exponential ease-out)
			local rise = CONFIG.Rise * outExpo(t / CONFIG.Life * 1.6)
			p.bb.StudsOffsetWorldSpace = Vector3.new(item.sx, item.sy + rise, 0)
			-- scale: slam in (big -> 1) for heavy, overshoot pop for light, then shrink slowly
			if t < CONFIG.PopTime then
				local a = t / CONFIG.PopTime
				if item.heavy then
					p.scale.Scale = 2.1 - 1.1 * outBack(a)
				else
					p.scale.Scale = 0.35 + 0.65 * outBack(a)
				end
			else
				p.scale.Scale = 1 - 0.15 * ((t - CONFIG.PopTime) / (CONFIG.Life - CONFIG.PopTime))
			end
			-- fade at the end
			if t > fadeStart then
				local a = (t - fadeStart) / CONFIG.FadeTime
				p.label.TextTransparency = a
				p.stroke.Transparency = a
			end
		end
	end
end

-- one loop, connected only while something is on screen
local function onFrame(dt: number)
	stepNumbers(math.min(dt, 1 / 15))
	if #active == 0 and loopConn then
		loopConn:Disconnect()
		loopConn = nil
	end
end

local function spawnNumber(model: Model, amount: number, style: string)
	-- on the body, not above the head
	local adornee = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso") or model:FindFirstChild("HumanoidRootPart")
	if not adornee or not adornee:IsA("BasePart") then return end

	if #active >= CONFIG.MaxActive then -- recycle the oldest if we are full
		release(active[1])
		table.remove(active, 1)
	end
	local popup = table.remove(pool) or makePopup()

	-- spread repeated hits on the same enemy so the numbers do not overlap
	local now = os.clock()
	local r = recent[model]
	if r and now - r.t < CONFIG.StackWindow then
		r.count += 1
	else
		r = { t = now, count = 0 }
		recent[model] = r
	end
	r.t = now
	local sy = 2.2 + (r.count % 3) * 0.9 -- repeated hits stack higher

	local colors = STYLES[style] or STYLES.Light
	local heavy = style ~= "Light"
	popup.label.Text = tostring(math.floor(amount + 0.5))
	popup.label.TextSize = if heavy then CONFIG.HeavySize else CONFIG.LightSize
	popup.label.TextColor3 = colors.text
	popup.label.TextTransparency = 0
	popup.stroke.Color = colors.stroke
	popup.stroke.Transparency = 0
	popup.scale.Scale = if heavy then 2.1 else 0.35
	popup.bb.Adornee = adornee
	popup.bb.StudsOffsetWorldSpace = Vector3.new(-1.8, sy, 0) -- up and to the left of the body
	popup.bb.Enabled = true

	table.insert(active, { popup = popup, adornee = adornee, t = 0, heavy = heavy, sx = -1.8, sy = sy })
	if not loopConn then
		loopConn = RunService.PreRender:Connect(onFrame)
	end
end

feedback.OnClientEvent:Connect(function(kind: string, _seq: number, entries: any)
	if kind ~= "hit" and kind ~= "blast" and kind ~= "slam" then return end
	if typeof(entries) ~= "table" then return end
	local seen: { [Instance]: boolean } = {} -- one number per target per message, even if the list repeats a target
	for _, e in entries do
		if type(e) == "table" and typeof(e.model) == "Instance" and e.model:IsA("Model") and e.model.Parent
			and type(e.damage) == "number" and e.damage > 0 and e.damage < 1e6 and not seen[e.model] then
			seen[e.model] = true
			-- the final hit (blast / slam) is always the big red one; other kills are gold
			local final = kind == "blast" or kind == "slam"
			spawnNumber(e.model, e.damage, if final then "Heavy" elseif e.killed then "Kill" else "Light")
		end
	end
end)
