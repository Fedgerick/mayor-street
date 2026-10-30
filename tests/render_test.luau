--!nocheck
-- Builds the starter city and a car with real Roblox instances under Lune
-- (`lune run tests/render_test.luau`), which checks every class, property and enum the
-- renderer sets. Terrain, tags and tweens are stubbed.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Random = {}
Random.__index = Random
function Random.new(seed)
	return setmetatable({ s = (math.floor(seed or 1) % 2147483646) + 1 }, Random)
end
function Random:_next()
	self.s = (self.s * 48271) % 2147483647
	return self.s / 2147483647
end
function Random:NextNumber(a, b)
	a, b = a or 0, b or 1
	return a + (b - a) * self:_next()
end
function Random:NextInteger(a, b)
	return a + math.floor(self:_next() * (b - a + 1))
end

local function load(path, env)
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local ws = roblox.Instance.new("Folder")
ws.Name = "Workspace"
local fills = 0
local terrain = { FillBlock = function() fills += 1 end, Clear = function() end }
local tags = {}
local services = {
	CollectionService = {
		AddTag = function(_, inst, tag)
			tags[tag] = (tags[tag] or 0) + 1
		end,
		GetTagged = function()
			return {}
		end,
	},
	TweenService = {},
	Players = {},
}
local base = {
	Vector2 = roblox.Vector2, Vector3 = roblox.Vector3, Color3 = roblox.Color3, CFrame = roblox.CFrame,
	Enum = roblox.Enum, Instance = roblox.Instance, PhysicalProperties = roblox.PhysicalProperties,
	UDim2 = roblox.UDim2, TweenInfo = nil, Random = Random,
}
local Grid = load("src/shared/Grid.luau", base)
local env = table.clone(base)
env.workspace = ws
env.game = {
	GetService = function(_, name)
		return services[name] or { Shared = { Grid = Grid } }
	end,
}
env.require = function(m) return m end
local City = load("src/server/City.luau", env)
local renderEnv = table.clone(env)
renderEnv.workspace = ws
local Renderer = load("src/server/CityRenderer.luau", renderEnv)
local Vehicles = load("src/server/Vehicles.luau", renderEnv)

local city = City.new(1337)
city:buildStarterTown(14)
local r = Renderer.new(city)
r.drawTerrain = function() fills += 1 end -- Terrain:FillBlock isn't available outside Roblox
r:rebuildAll()

local parts, models = 0, 0
for _, d in r.root:GetDescendants() do
	if d:IsA("BasePart") then
		parts += 1
	end
end
for _ in r.models do
	models += 1
end
local seats = 0
for _, d in r.roads:GetDescendants() do
	if d:IsA("Seat") then seats += 1 end
end
print(string.format("rendered: %d buildings, %d parts, %d benches, %d terrain fills, tags:",
	models, parts, seats, fills))
for k, v in tags do
	print("  tag", k, v)
end
-- Lune has no events, so the car is checked up to its first :Connect().
local ok, err = pcall(Vehicles.spawn, roblox.CFrame.new(0, 0.5, 0), roblox.Color3.new(1, 0, 0), ws)
assert(ok or tostring(err):find("Triggered is not a valid member"), tostring(err))
print("car built up to its event hookups")

-- Night switch and a live edit through the hooks.
r:setNight(true)
city.animateGrowth = false -- growth tweens need TweenService
city.funds = 1e6
local cx, cy = city:centerCell()
assert(city:placeRoad(Grid.roadPath(cx + 14, cy, cx + 14, cy + 6)), "road")
assert(city:placeZone(cx + 15, cy + 1, cx + 16, cy + 5, Grid.Zone.COM), "zone")
for _ = 1, 24 * 6 do
	city:advance(10, 1)
end
assert(city:bulldoze(cx + 15, cy + 1, cx + 16, cy + 5), "bulldoze")
assert(parts < 20000, "too many parts")
print("ALL PASS")
