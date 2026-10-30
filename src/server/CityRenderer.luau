--!nocheck
-- Draws the city in Workspace: island terrain, roads with sidewalks, lamps and benches,
-- zone tiles, and buildings made from parts. Buildings are generated from each
-- building's variant number, so the same save always looks the same.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Grid = require(ReplicatedStorage.Shared.Grid)

local T = Grid.TILE
local W, H = Grid.W, Grid.H
local Z = Grid.Zone
local DIRS = Grid.DIRS
local idx = Grid.idx

local ASPHALT = Color3.fromRGB(52, 54, 60)
local SIDEWALK = Color3.fromRGB(178, 176, 168)
local LINE = Color3.fromRGB(240, 200, 60)
local GLASS = Color3.fromRGB(72, 108, 145)
local LIT = Color3.fromRGB(255, 214, 140)
local LAMP_COLOR = Color3.fromRGB(255, 205, 140)

local WALLS = {
	[Z.RES] = {
		Color3.fromRGB(226, 214, 190), Color3.fromRGB(196, 120, 96), Color3.fromRGB(232, 230, 224),
		Color3.fromRGB(170, 190, 205), Color3.fromRGB(212, 190, 150), Color3.fromRGB(150, 110, 90),
	},
	[Z.COM] = {
		Color3.fromRGB(210, 210, 215), Color3.fromRGB(170, 180, 190), Color3.fromRGB(120, 130, 145),
		Color3.fromRGB(230, 225, 215), Color3.fromRGB(92, 100, 115),
	},
	[Z.IND] = {
		Color3.fromRGB(160, 160, 155), Color3.fromRGB(140, 120, 100), Color3.fromRGB(120, 132, 120),
		Color3.fromRGB(182, 170, 150),
	},
}
local ROOFS = { Color3.fromRGB(150, 60, 50), Color3.fromRGB(80, 80, 88), Color3.fromRGB(110, 80, 60), Color3.fromRGB(60, 90, 110) }
local ACCENTS = { Color3.fromRGB(220, 60, 50), Color3.fromRGB(40, 150, 90), Color3.fromRGB(240, 170, 40), Color3.fromRGB(50, 110, 210), Color3.fromRGB(180, 70, 170) }

local Renderer = {}
Renderer.__index = Renderer

local function folder(name, parent)
	local f = parent:FindFirstChild(name) or Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function newPart(class, parent, size, cf, color, material)
	local p = Instance.new(class or "Part")
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function Renderer.new(city)
	local self = setmetatable({}, Renderer)
	self.city = city
	self.root = folder("City", workspace)
	self.roads = folder("Roads", self.root)
	self.zones = folder("Zones", self.root)
	self.blds = folder("Buildings", self.root)
	self.roadModels = {}
	self.zoneTiles = {}
	self.models = {}
	self.night = false
	city.onBuildingAdded = function(b, animate)
		self:addBuilding(b, animate)
	end
	city.onBuildingRemoved = function(b)
		self:removeBuilding(b)
	end
	city.onCellsChanged = function(x0, y0, x1, y1)
		self:redrawCells(x0, y0, x1, y1)
	end
	return self
end

-- ------------------------------------------------------------------ terrain ---

function Renderer:drawTerrain()
	local terrain = workspace.Terrain
	terrain:Clear()
	local land = self.city.land
	local margin = 600
	terrain:FillBlock(CFrame.new(0, -18, 0), Vector3.new(W * T + margin * 2, 32, H * T + margin * 2), Enum.Material.Water)
	for y = 0, H - 1 do
		local x = 0
		while x < W do
			if land[idx(x, y)] == 1 then
				local x0 = x
				while x < W and land[idx(x, y)] == 1 do
					x += 1
				end
				local a, b = Grid.cellCenter(x0, y), Grid.cellCenter(x - 1, y)
				terrain:FillBlock(CFrame.new((a.X + b.X) / 2, -12, a.Z), Vector3.new((x - x0) * T, 24, T), Enum.Material.Grass)
			else
				x += 1
			end
		end
	end
	-- Beaches: the outer ring of land is sand, a little lower than the grass.
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = idx(x, y)
			if land[i] == 1 and self.city.coastDist[i] <= 1 then
				local c = Grid.cellCenter(x, y)
				terrain:FillBlock(CFrame.new(c.X, -12, c.Z), Vector3.new(T, 24, T), Enum.Material.Sand)
			end
		end
	end
end

-- -------------------------------------------------------------------- roads ---

function Renderer:_drawRoad(x, y)
	local i = idx(x, y)
	local old = self.roadModels[i]
	if old then
		old:Destroy()
		self.roadModels[i] = nil
	end
	local city = self.city
	if city.road[i] ~= 1 then
		return
	end
	local m = Instance.new("Model")
	m.Name = "Road" .. i
	local c = Grid.cellCenter(x, y)
	newPart("Part", m, Vector3.new(T, 0.5, T), CFrame.new(c + Vector3.new(0, 0.25, 0)), ASPHALT, Enum.Material.Asphalt).CastShadow = false
	local mask = city:roadMask(x, y)
	local edges = {}
	for r = 0, 3 do
		local d = DIRS[r]
		if not city:isRoad(x + d.X, y + d.Y) then
			table.insert(edges, r)
			local off = Vector3.new(d.X, 0, d.Y) * (T / 2 - 3)
			local size = if d.X ~= 0 then Vector3.new(6, 0.6, T) else Vector3.new(T, 0.6, 6)
			newPart("Part", m, size, CFrame.new(c + off + Vector3.new(0, 0.3, 0)), SIDEWALK, Enum.Material.Concrete).CastShadow = false
		end
	end
	if mask == 5 or mask == 10 then
		local size = if mask == 5 then Vector3.new(0.5, 0.05, T) else Vector3.new(T, 0.05, 0.5)
		local line = newPart("Part", m, size, CFrame.new(c + Vector3.new(0, 0.52, 0)), LINE)
		line.CanCollide = false
		line.CastShadow = false
	end
	if #edges > 0 and (x * 7 + y * 3) % 4 == 0 then
		self:_lamp(m, c, edges[1])
	end
	if #edges > 0 and (x * 3 + y * 5) % 5 == 0 then
		self:_bench(m, c, edges[#edges])
	end
	m.Parent = self.roads
	self.roadModels[i] = m
end

-- A street lamp on the sidewalk on side r, leaning over the road.
function Renderer:_lamp(m, c, r)
	local d = DIRS[r]
	local out = Vector3.new(d.X, 0, d.Y)
	local along = Vector3.new(-d.Y, 0, d.X)
	local base = c + out * (T / 2 - 4.5) + along * (T / 2 - 4)
	local pole = newPart("Part", m, Vector3.new(16, 0.7, 0.7), CFrame.new(base + Vector3.new(0, 8.6, 0)) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(60, 62, 66), Enum.Material.Metal)
	pole.Shape = Enum.PartType.Cylinder
	local arm = newPart("Part", m, Vector3.new(0.5, 0.5, 4), CFrame.lookAt(base + Vector3.new(0, 16.4, 0) - out * 2, base + Vector3.new(0, 16.4, 0) - out * 4), Color3.fromRGB(60, 62, 66), Enum.Material.Metal)
	arm.CastShadow = false
	local head = newPart("Part", m, Vector3.new(1.4, 0.5, 2.2), CFrame.new(base + Vector3.new(0, 16.1, 0) - out * 4), LAMP_COLOR, Enum.Material.Neon)
	head.CastShadow = false
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 120
	light.Range = 34
	light.Brightness = 2.2
	light.Color = LAMP_COLOR
	light.Enabled = self.night
	light.Parent = head
	CollectionService:AddTag(light, "StreetLight")
end

-- A park bench (a real Seat, so avatars can sit) on side r, facing the road.
function Renderer:_bench(m, c, r)
	local d = DIRS[r]
	local out = Vector3.new(d.X, 0, d.Y)
	local along = Vector3.new(-d.Y, 0, d.X)
	local pos = c + out * (T / 2 - 1.8) - along * 6 + Vector3.new(0, 1.9, 0)
	local seat = newPart("Seat", m, Vector3.new(6, 0.5, 2), CFrame.lookAt(pos, pos - out), Color3.fromRGB(130, 88, 54), Enum.Material.Wood)
	seat.Name = "Bench"
	newPart("Part", m, Vector3.new(6, 2, 0.4), seat.CFrame * CFrame.new(0, 1.2, 1), Color3.fromRGB(130, 88, 54), Enum.Material.Wood)
	for _, sx in { -2.6, 2.6 } do
		newPart("Part", m, Vector3.new(0.4, 1.7, 1.8), seat.CFrame * CFrame.new(sx, -1.1, 0), Color3.fromRGB(50, 50, 55), Enum.Material.Metal).CastShadow = false
	end
end

-- -------------------------------------------------------------------- zones ---

function Renderer:_drawZone(x, y)
	local i = idx(x, y)
	local city = self.city
	local want = city.zone[i] ~= Z.NONE and city.road[i] == 0 and city.bld[i] == 0
	local tile = self.zoneTiles[i]
	if tile and (not want or tile:GetAttribute("Zone") ~= city.zone[i]) then
		tile:Destroy()
		self.zoneTiles[i] = nil
		tile = nil
	end
	if want and not tile then
		local c = Grid.cellCenter(x, y)
		tile = newPart("Part", self.zones, Vector3.new(T - 8, 0.2, T - 8), CFrame.new(c + Vector3.new(0, 0.1, 0)), Grid.ZONE_COLORS[city.zone[i]])
		tile.Transparency = 0.55
		tile.CanCollide = false
		tile.CanQuery = false
		tile.CanTouch = false
		tile.CastShadow = false
		tile:SetAttribute("Zone", city.zone[i])
		self.zoneTiles[i] = tile
	end
end

function Renderer:redrawCells(x0, y0, x1, y1)
	for y = math.max(y0, 0), math.min(y1, H - 1) do
		for x = math.max(x0, 0), math.min(x1, W - 1) do
			self:_drawRoad(x, y)
			self:_drawZone(x, y)
		end
	end
end

-- ---------------------------------------------------------------- buildings ---

local function pick(rnd, list)
	return list[rnd:NextInteger(1, #list)]
end

-- Floors of window glass wrapped round a box. Some windows light up at night.
function Renderer:_bands(m, cf, w, d, floors, floorH, glassH, base, rnd)
	for f = 0, floors - 1 do
		local band = newPart("Part", m, Vector3.new(w + 0.3, glassH, d + 0.3), cf * CFrame.new(0, base + f * floorH + floorH / 2, 0), GLASS, Enum.Material.Glass)
		band.Reflectance = 0.15
		band.CastShadow = false
		if rnd:NextNumber() < 0.55 then
			CollectionService:AddTag(band, "Window")
			if self.night then
				band.Material = Enum.Material.Neon
				band.Color = LIT
			end
		end
	end
end

local function tree(m, pos, rnd)
	local h = rnd:NextNumber(7, 11)
	local trunk = newPart("Part", m, Vector3.new(h, 1.2, 1.2), CFrame.new(pos + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(95, 70, 50), Enum.Material.Wood)
	trunk.Shape = Enum.PartType.Cylinder
	local s = rnd:NextNumber(7, 10)
	local top = newPart("Part", m, Vector3.new(s, s, s), CFrame.new(pos + Vector3.new(0, h + s * 0.3, 0)), Color3.fromRGB(rnd:NextInteger(50, 80), rnd:NextInteger(120, 150), rnd:NextInteger(50, 70)), Enum.Material.Grass)
	top.Shape = Enum.PartType.Ball
end

function Renderer:_house(m, cf, rnd)
	local w, d, h = rnd:NextNumber(18, 24), rnd:NextNumber(16, 20), rnd:NextNumber(10, 13)
	newPart("Part", m, Vector3.new(w, h, d), cf * CFrame.new(0, h / 2, 2), pick(rnd, WALLS[Z.RES]), Enum.Material.Plaster)
	local a = math.rad(30)
	local len = (d / 2) / math.cos(a) + 1.5
	local roof = pick(rnd, ROOFS)
	local rise = (d / 4) * math.tan(a)
	newPart("Part", m, Vector3.new(w + 2, 0.8, len), cf * CFrame.new(0, h + rise, 2 - d / 4) * CFrame.Angles(-a, 0, 0), roof, Enum.Material.Slate)
	newPart("Part", m, Vector3.new(w + 2, 0.8, len), cf * CFrame.new(0, h + rise, 2 + d / 4) * CFrame.Angles(a, 0, 0), roof, Enum.Material.Slate)
	local front = 2 - d / 2 - 0.1
	newPart("Part", m, Vector3.new(4, 7, 0.3), cf * CFrame.new(0, 3.5, front), Color3.fromRGB(90, 60, 40), Enum.Material.Wood)
	for _, sx in { -w / 4 - 1, w / 4 + 1 } do
		local win = newPart("Part", m, Vector3.new(4, 3.5, 0.3), cf * CFrame.new(sx, 6.5, front), GLASS, Enum.Material.Glass)
		CollectionService:AddTag(win, "Window")
		if self.night then
			win.Material = Enum.Material.Neon
			win.Color = LIT
		end
	end
	for _ = 1, rnd:NextInteger(0, 2) do
		tree(m, (cf * CFrame.new(rnd:NextNumber(-14, 14), 0, rnd:NextNumber(13, 16))).Position, rnd)
	end
end

function Renderer:_shop(m, cf, rnd)
	local w, d, h = rnd:NextNumber(26, 30), rnd:NextNumber(20, 24), rnd:NextNumber(13, 16)
	newPart("Part", m, Vector3.new(w, h, d), cf * CFrame.new(0, h / 2, 0), pick(rnd, WALLS[Z.COM]), Enum.Material.Brick)
	local front = -d / 2 - 0.1
	local glass = newPart("Part", m, Vector3.new(w - 4, 7, 0.3), cf * CFrame.new(0, 4.5, front), GLASS, Enum.Material.Glass)
	CollectionService:AddTag(glass, "Window")
	local accent = pick(rnd, ACCENTS)
	newPart("Part", m, Vector3.new(w - 2, 0.4, 5), cf * CFrame.new(0, 9, front - 2.2) * CFrame.Angles(math.rad(-15), 0, 0), accent, Enum.Material.Fabric).CastShadow = false
	newPart("Part", m, Vector3.new(w * 0.6, 3, 0.5), cf * CFrame.new(0, h + 1.5, front + 1), accent, Enum.Material.Neon)
end

function Renderer:_tower(m, cf, rnd, z, w, floors, big)
	local d = w * rnd:NextNumber(0.8, 1)
	local floorH = if z == Z.RES then 11 else 12
	local glassH = if z == Z.COM then 7.5 else 4.5
	local h = floors * floorH + 2
	local wall = pick(rnd, WALLS[z])
	newPart("Part", m, Vector3.new(w, h, d), cf * CFrame.new(0, h / 2, 0), wall, if z == Z.COM then Enum.Material.Concrete else Enum.Material.Plaster)
	self:_bands(m, cf, w, d, floors, floorH, glassH, 1, rnd)
	newPart("Part", m, Vector3.new(w + 1, 1.2, d + 1), cf * CFrame.new(0, h + 0.6, 0), wall, Enum.Material.Concrete)
	newPart("Part", m, Vector3.new(5, 7, 0.4), cf * CFrame.new(0, 3.5, -d / 2 - 0.2), Color3.fromRGB(40, 45, 55), Enum.Material.Glass)
	if big and z == Z.COM then
		local top = rnd:NextNumber(0.55, 0.7)
		local th = floorH * rnd:NextInteger(3, 5)
		newPart("Part", m, Vector3.new(w * top, th, d * top), cf * CFrame.new(0, h + th / 2, 0), wall, Enum.Material.Concrete)
		self:_bands(m, cf, w * top, d * top, th // floorH, floorH, glassH, h, rnd)
		local mast = newPart("Part", m, Vector3.new(24, 0.8, 0.8), cf * CFrame.new(0, h + th + 12, 0) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(200, 200, 205), Enum.Material.Metal)
		mast.Shape = Enum.PartType.Cylinder
		local tip = newPart("Part", m, Vector3.new(1.2, 1.2, 1.2), cf * CFrame.new(0, h + th + 24.5, 0), Color3.fromRGB(255, 40, 40), Enum.Material.Neon)
		tip.Shape = Enum.PartType.Ball
	else
		newPart("Part", m, Vector3.new(6, 3, 5), cf * CFrame.new(rnd:NextNumber(-w / 4, w / 4), h + 2.7, rnd:NextNumber(-d / 4, d / 4)), Color3.fromRGB(150, 152, 155), Enum.Material.Metal)
	end
end

function Renderer:_factory(m, cf, rnd, stage, size)
	local s = if size == 2 then 2 * T - 12 else T - 10
	local w, d = s, s * rnd:NextNumber(0.8, 1)
	local h = 10 + stage * 4 + (if size == 2 then 6 else 0)
	local wall = pick(rnd, WALLS[Z.IND])
	newPart("Part", m, Vector3.new(w, h, d), cf * CFrame.new(0, h / 2, 0), wall, Enum.Material.Metal)
	newPart("Part", m, Vector3.new(w + 0.6, 1, d + 0.6), cf * CFrame.new(0, h + 0.5, 0), Color3.fromRGB(90, 92, 95), Enum.Material.Metal)
	newPart("Part", m, Vector3.new(10, 9, 0.4), cf * CFrame.new(-w / 5, 4.5, -d / 2 - 0.2), Color3.fromRGB(70, 75, 80), Enum.Material.DiamondPlate)
	local stacks = if stage == 1 then 1 else (if size == 2 then 3 else 2)
	for k = 1, stacks do
		local ch = h + rnd:NextNumber(10, 18) + stage * 4
		local p = newPart("Part", m, Vector3.new(ch, 3, 3), cf * CFrame.new(w / 2 - 4 - (k - 1) * 6, ch / 2, d / 2 - 5) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(150, 70, 55), Enum.Material.Brick)
		p.Shape = Enum.PartType.Cylinder
	end
	if stage >= 2 then
		local tank = newPart("Part", m, Vector3.new(12, 9, 9), cf * CFrame.new(-w / 2 + 6, h + 6, 0), Color3.fromRGB(205, 205, 200), Enum.Material.Metal)
		tank.Shape = Enum.PartType.Cylinder
	end
end

function Renderer:addBuilding(b, animate)
	self:removeBuilding(b)
	local size = b.size
	local center = Grid.cellCenter(b.x, b.y) + Vector3.new((size - 1) * T / 2, 0, (size - 1) * T / 2)
	local d = DIRS[b.rot]
	local cf = CFrame.lookAt(center, center + Vector3.new(d.X, 0, d.Y))
	local rnd = Random.new(b.variant)
	local m = Instance.new("Model")
	m.Name = Grid.ZONE_NAMES[b.zone] .. b.id
	if b.zone == Z.IND then
		self:_factory(m, cf, rnd, b.stage, size)
	elseif b.stage == 1 then
		if b.zone == Z.RES then
			self:_house(m, cf, rnd)
		else
			self:_shop(m, cf, rnd)
		end
	elseif b.stage == 2 then
		local floors = if b.zone == Z.RES then rnd:NextInteger(3, 5) else rnd:NextInteger(4, 7)
		self:_tower(m, cf, rnd, b.zone, rnd:NextNumber(24, 29), floors, false)
	elseif size == 2 then
		local floors = if b.zone == Z.RES then rnd:NextInteger(14, 20) else rnd:NextInteger(18, 26)
		self:_tower(m, cf, rnd, b.zone, rnd:NextNumber(58, 66), floors, true)
	else
		self:_tower(m, cf, rnd, b.zone, rnd:NextNumber(24, 28), rnd:NextInteger(8, 13), false)
	end
	m.WorldPivot = cf
	m.Parent = self.blds
	self.models[b.id] = m
	if animate then
		local _, ext = m:GetBoundingBox()
		local cv = Instance.new("CFrameValue")
		cv.Value = cf * CFrame.new(0, -ext.Y - 1, 0)
		m:PivotTo(cv.Value)
		cv.Changed:Connect(function(v)
			if m.Parent then
				m:PivotTo(v)
			end
		end)
		local tw = TweenService:Create(cv, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = cf })
		tw.Completed:Connect(function()
			cv:Destroy()
		end)
		tw:Play()
	end
	for dy = 0, size - 1 do
		for dx = 0, size - 1 do
			self:_drawZone(b.x + dx, b.y + dy)
		end
	end
end

function Renderer:removeBuilding(b)
	local m = self.models[b.id]
	if m then
		m:Destroy()
		self.models[b.id] = nil
	end
end

-- ------------------------------------------------------------------- global ---

function Renderer:rebuildAll()
	for _, f in { self.roads, self.zones, self.blds } do
		f:ClearAllChildren()
	end
	self.roadModels, self.zoneTiles, self.models = {}, {}, {}
	self:drawTerrain()
	self:redrawCells(0, 0, W - 1, H - 1)
	for _, b in self.city.buildings do
		self:addBuilding(b, false)
	end
end

-- Street lamps and lit windows at night.
function Renderer:setNight(on)
	if on == self.night then
		return
	end
	self.night = on
	for _, light in CollectionService:GetTagged("StreetLight") do
		light.Enabled = on
	end
	for _, win in CollectionService:GetTagged("Window") do
		win.Material = if on then Enum.Material.Neon else Enum.Material.Glass
		win.Color = if on then LIT else GLASS
	end
end

return Renderer
