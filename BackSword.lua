--!strict
-- Script "BackSword" (parent: Tool "DarkV1")
-- The sword hangs on the back while the tool is in the Backpack. When the tool is equipped the sword leaves the back AT ONCE;
-- when the tool is dropped it goes too. The copy is welded to the torso, so nothing drifts with the camera or the body.
-- All the light effects change the COLOUR OF THE SWORD'S OWN TEXTURE (SurfaceAppearance.Color, SpecialMesh.VertexColor, Texture/Decal colour,
-- or the part colour that tints a mesh texture). There are no particles and no lights.
-- Science (EARTH SCIENCE / PHYSICS / OPTICS):
--   * Sunlight through the air (Rayleigh scattering + Beer-Lambert law): the air scatters short (blue) light far more than long (red) light
--     (optical depth ~ wavelength^-4). The lower the sun, the more air the light crosses (air mass, Kasten-Young formula), so each colour
--     channel keeps only exp(-tau * airMass) of its strength: white noon light, red sunset light. Haze (Atmosphere.Density) scales the depth.
--   * Night: the cool skylight tints the metal faintly blue (the eye also sees blue more in dim light: the Purkinje shift) and the metal gets
--     darker as the sun goes below the horizon (twilight ends at about 12 degrees below it).
--   * Dim places: a dark ambient light (its relative luminance, Rec.709 weights) darkens the metal too.
--   * Polished metal mirrors its surroundings, so the blade's reflectance follows how bright the sky is.

local Lighting = game:GetService("Lighting")

local tool = script.Parent :: Tool
local handleInstance = tool:WaitForChild("Handle", 10)
if not (handleInstance and handleInstance:IsA("BasePart")) then
	warn("[BackSword] the tool has no Handle")
	return
end
local toolHandle: BasePart = handleInstance

-- Estimated values: tune in game
local BACK_POS = Vector3.new(0, -0.2, 0.8) -- where the CENTER of the sword sits (relative to the torso)
local BACK_ROT = CFrame.Angles(0, 0, math.rad(45)) * CFrame.Angles(0, math.rad(90), 0) -- diagonal lean, then spin around the sword's own long axis
local SUN_TINT = 0.30 -- how much of the sunlight colour is mixed into the texture (0 = none)
local NIGHT_TINT = 0.15 -- the same for the cool night light
local NIGHT_DARKEN = 0.30 -- how much darker everything gets at full night
local AMBIENT_DARKEN = 0.35 -- how much darker everything gets when the ambient light is black
local BLADE_REFLECT = 0.2 -- the least reflectance of the blade (the largest part), so the sky shows in it
local CLOCK_STEP = 0.25 -- the light is recomputed only when ClockTime moved this much (hours)
local TORSO_WAIT = 3 -- seconds to wait for a character that is still loading

local BACK_CF = CFrame.new(BACK_POS) * BACK_ROT
local BLACK = Color3.new(0, 0, 0)
local KEEP: { [string]: boolean } = { SpecialMesh = true, SurfaceAppearance = true, Decal = true, Texture = true } -- only the look is kept

-- one colour that the light changes: the instance that holds it, and its original colour
type Tinted = { inst: Instance, base: Color3 }
type Back = {
	model: Model, root: BasePart, torso: BasePart, joint: Weld,
	tinted: { Tinted },
	blade: BasePart, bladeReflect: number,
	sig: string, -- the light that was applied last, so equal light is not written again
}
type Light = { tint: Color3, strength: number, darken: number, sheen: number }

local back: Back? = nil
local epoch = 0 -- grows with every change of state; work that waited (yielded) checks it afterwards and stops if it is out of date
local lastClock = -100
local connections: { RBXScriptConnection } = {}

--------------------------------------------------------------------------------
-- Colour of the texture
--------------------------------------------------------------------------------
-- writes a colour into whichever property of the instance carries the texture colour
local function paint(inst: Instance, color: Color3)
	if inst:IsA("SpecialMesh") then
		inst.VertexColor = Vector3.new(color.R, color.G, color.B) -- multiplies the mesh texture
	elseif inst:IsA("SurfaceAppearance") then
		inst.Color = color
	elseif inst:IsA("Decal") then -- (Texture is a Decal too)
		inst.Color3 = color
	elseif inst:IsA("BasePart") then
		inst.Color = color -- a MeshPart's colour multiplies its texture
	end
end

-- the colours that carry the look of one cloned part
local function collectColors(p: BasePart, into: { Tinted })
	local appearance = p:FindFirstChildOfClass("SurfaceAppearance")
	local mesh = p:FindFirstChildOfClass("SpecialMesh")
	local textured = appearance ~= nil or (mesh ~= nil and mesh.TextureId ~= "")
	if not textured then
		table.insert(into, { inst = p, base = p.Color }) -- the part colour is what shows
	end
	for _, d in p:GetChildren() do
		if d:IsA("SpecialMesh") then
			if d.TextureId ~= "" then table.insert(into, { inst = d, base = Color3.new(d.VertexColor.X, d.VertexColor.Y, d.VertexColor.Z) }) end
		elseif d:IsA("SurfaceAppearance") then
			table.insert(into, { inst = d, base = d.Color })
		elseif d:IsA("Decal") then
			table.insert(into, { inst = d, base = d.Color3 })
		end
	end
end

--------------------------------------------------------------------------------
-- Light
--------------------------------------------------------------------------------
-- Rayleigh optical depth at sea level for a wavelength in micrometres (Hansen & Travis fit)
local function rayleighDepth(lambda: number): number
	local l2 = lambda ^ -2
	return 0.008569 * l2 * l2 * (1 + 0.0113 * l2 + 0.00013 * l2 * l2)
end

local TAU_R, TAU_G, TAU_B = rayleighDepth(0.65), rayleighDepth(0.55), rayleighDepth(0.45) -- red, green, blue (fixed: computed once)
local COOL_NIGHT = Color3.fromRGB(150, 175, 255)
local DEFAULT_DENSITY = 0.395 -- Atmosphere.Density of a new place

-- Kasten-Young air mass: how many "vertical airs" the light crosses; elevation in degrees above the horizon
local function airMass(elevation: number): number
	local h = math.max(elevation, 0)
	return 1 / (math.sin(math.rad(h)) + 0.50572 * (h + 6.07995) ^ -1.6364)
end

local function haze(): number
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	local density = atmosphere and atmosphere.Density or DEFAULT_DENSITY
	return math.clamp(density / DEFAULT_DENSITY, 0.4, 2.5)
end

-- 0 = bright ambient light, 1 = black ambient light (relative luminance, Rec.709 weights)
local function ambientDim(): number
	local c = Lighting.OutdoorAmbient
	return math.clamp(1 - (0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B) / 0.5, 0, 1)
end

local function lightNow(): Light
	local darkenAmbient = AMBIENT_DARKEN * ambientDim()
	local elevation = math.deg(math.asin(math.clamp(Lighting:GetSunDirection().Y, -1, 1))) -- degrees above the horizon
	if elevation > 0 then
		local m = airMass(elevation) * haze()
		local r, g, b = math.exp(-TAU_R * m), math.exp(-TAU_G * m), math.exp(-TAU_B * m) -- Beer-Lambert: what is left of each colour
		local peak = math.max(r, g, b)
		return {
			tint = Color3.new(r / peak, g / peak, b / peak), -- normalised: only the colour, the brightness is the game's job
			strength = SUN_TINT * math.clamp(elevation / 8, 0, 1),
			darken = darkenAmbient,
			sheen = 0.6 + 0.4 * math.clamp(elevation / 25, 0, 1),
		}
	end
	local night = math.clamp(-elevation / 12, 0, 1)
	return {
		tint = COOL_NIGHT,
		strength = NIGHT_TINT * night,
		darken = math.max(NIGHT_DARKEN * night, darkenAmbient),
		sheen = 0.6 - 0.3 * night,
	}
end

local function paintAll(b: Back, light: Light)
	for _, item in b.tinted do
		if item.inst.Parent then
			paint(item.inst, item.base:Lerp(light.tint, light.strength):Lerp(BLACK, light.darken))
		end
	end
	b.blade.Reflectance = b.bladeReflect * light.sheen
end

local function applyLight(b: Back)
	local ok, light = pcall(lightNow)
	if not ok then return end -- the sword just keeps its look
	local sig = string.format("%.2f|%.2f|%.2f|%.2f|%.2f|%.2f", light.tint.R, light.tint.G, light.tint.B, light.strength, light.darken, light.sheen)
	if sig == b.sig then return end -- nothing visible changed
	b.sig = sig
	local painted, err = pcall(paintAll, b, light)
	if not painted then
		b.sig = ""
		warn("[BackSword] could not colour the sword:", err)
	end
end

--------------------------------------------------------------------------------
-- Character helpers
--------------------------------------------------------------------------------
local function getCharacter(): Model?
	local parent = tool.Parent
	if parent and parent:IsA("Backpack") then
		local player = parent.Parent
		if player and player:IsA("Player") then return player.Character end
	end
	return nil
end

local function getTorso(character: Model): BasePart?
	local found = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not found then found = character:WaitForChild("UpperTorso", TORSO_WAIT) end -- yields
	if found and found:IsA("BasePart") then return found end
	return nil
end

--------------------------------------------------------------------------------
-- Build the back copy once per character and reuse it
--------------------------------------------------------------------------------
local function build(torso: BasePart): Back?
	local copy = Instance.new("Model")
	copy.Name = "BackSword"
	local root: BasePart? = nil
	local blade: BasePart? = nil
	local bladeVolume = 0
	local tinted: { Tinted } = {}

	for _, child in tool:GetChildren() do
		if child:IsA("BasePart") then
			local p = child:Clone()
			for _, d in p:GetDescendants() do
				if not KEEP[d.ClassName] then d:Destroy() end
			end
			p.Anchored = false
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Massless = true -- the copy must never change how the character moves
			p.Parent = copy
			collectColors(p, tinted)
			if child == toolHandle then root = p end
			local volume = p.Size.X * p.Size.Y * p.Size.Z
			if volume > bladeVolume then
				blade, bladeVolume = p, volume
			end
		end
	end
	if not root or not blade then
		copy:Destroy()
		return nil
	end
	local rootPart: BasePart = root
	local bladePart: BasePart = blade

	-- the other parts of the sword are fixed to the handle
	for _, p in copy:GetChildren() do
		if p:IsA("BasePart") and p ~= rootPart then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = rootPart
			weld.Part1 = p
			weld.Parent = p
		end
	end

	-- the sword is welded to the torso: its CENTER sits on BACK_POS and it is turned by BACK_ROT around that center
	copy.PrimaryPart = rootPart
	local centerOffset = rootPart.CFrame:PointToObjectSpace(copy:GetBoundingBox().Position)
	local joint = Instance.new("Weld")
	joint.Name = "BackSwordJoint"
	joint.Part0 = torso
	joint.Part1 = rootPart
	joint.C0 = BACK_CF * CFrame.new(-centerOffset)
	joint.Parent = rootPart

	return {
		model = copy, root = rootPart, torso = torso, joint = joint, tinted = tinted,
		blade = bladePart, bladeReflect = math.max(bladePart.Reflectance, BLADE_REFLECT), sig = "",
	}
end

local function destroyBack()
	local b = back
	back = nil
	if b then b.model:Destroy() end
end

-- is the copy still whole and fixed to this torso? (a hidden copy counts: it is kept for reuse)
local function isIntact(b: Back, torso: BasePart): boolean
	return b.torso == torso and b.root.Parent == b.model and b.joint.Parent == b.root and b.joint.Part0 == torso
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------
local function hideSword()
	local b = back
	if b and b.model.Parent then b.model.Parent = nil end -- kept for reuse
end

local function showOnBack(myEpoch: number)
	local character = getCharacter()
	if not character or not character.Parent then return end
	local torso = getTorso(character) -- may yield
	if myEpoch ~= epoch then return end -- the tool was equipped or dropped while we waited: do nothing
	if not torso or not torso.Parent or not character.Parent then return end

	local current = back
	if current and not isIntact(current, torso) then
		destroyBack() -- a new body, or a broken copy: build a fresh one
	end
	if not back then
		local ok, result = pcall(build, torso)
		if not ok then
			warn("[BackSword] could not build the copy:", result)
			return
		end
		back = result
	end
	local b = back
	if not b then return end

	b.sig = "" -- the light may have changed while it was hidden
	applyLight(b)
	b.model.Parent = character
end

-- one event covers equip, unequip, drop and respawn
local function refresh()
	epoch += 1
	local parent = tool.Parent
	if parent and parent:IsA("Backpack") then
		task.spawn(showOnBack, epoch) -- (it may wait for the character to load)
	else
		hideSword() -- equipped or dropped: the sword leaves the back AT ONCE
	end
end

local function relight()
	local b = back
	if b and b.model.Parent then applyLight(b) end
end

table.insert(connections, tool.AncestryChanged:Connect(refresh))

-- the sun moves: the light on the metal follows (only when the time changed enough, so it costs almost nothing)
table.insert(connections, Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
	if math.abs(Lighting.ClockTime - lastClock) < CLOCK_STEP then return end
	lastClock = Lighting.ClockTime
	relight()
end))
table.insert(connections, Lighting:GetPropertyChangedSignal("OutdoorAmbient"):Connect(relight)) -- changes rarely

-- clean up when the tool is removed for good
table.insert(connections, tool.Destroying:Connect(function()
	epoch += 1
	destroyBack()
	for _, c in connections do c:Disconnect() end
	table.clear(connections)
end))

task.defer(refresh) -- first setup (the tool starts in the Backpack)
