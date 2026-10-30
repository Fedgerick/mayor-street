--!nocheck
-- Runs the city sim outside Roblox with Lune: `lune run tests/city_test.luau`.
-- Stubs the few Roblox globals the sim needs, then checks growth, editing and saves.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- A small stand-in for Roblox's Random (only what City uses).
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
	local src = fs.readFile(path)
	local fn = luau.load(src, { debugName = path, environment = env })
	return fn()
end

local base = {
	Vector2 = roblox.Vector2,
	Vector3 = roblox.Vector3,
	Color3 = roblox.Color3,
	Random = Random,
}
local Grid = load("src/shared/Grid.luau", base)
local env = table.clone(base)
env.game = {
	GetService = function(_, name)
		return { Shared = { Grid = Grid } }
	end,
}
env.require = function(m)
	return m
end
local City = load("src/server/City.luau", env)

local fails = 0
local function check(ok, what)
	print((if ok then "PASS " else "FAIL ") .. what)
	if not ok then
		fails += 1
	end
end

local city = City.new(1337)
local land = 0
for i = 1, Grid.W * Grid.H do
	land += city.land[i]
end
check(land > Grid.W * Grid.H * 0.4 and land < Grid.W * Grid.H * 0.8, "island covers 40-80% of the map (" .. land .. ")")

local cx, cy = city:centerCell()
check(city.land[Grid.idx(cx, cy)] == 1, "centre cell is land")

city:buildStarterTown(14)
local n, stages = 0, { 0, 0, 0 }
for _, b in city.buildings do
	n += 1
	stages[b.stage] += 1
end
print(string.format("starter town: %d buildings (stage 1/2/3: %d/%d/%d), %d people, %d jobs, $%d",
	n, stages[1], stages[2], stages[3], city.population, city.jobsC + city.jobsI, city.funds))
check(n > 60, "starter town grew buildings")
check(city.population > 100, "starter town has people")
check(city.funds == 50000, "starter funds reset to 50,000")

-- Every building sits on its own cells, next to a road.
local okCells = true
for id, b in city.buildings do
	for dy = 0, b.size - 1 do
		for dx = 0, b.size - 1 do
			local i = Grid.idx(b.x + dx, b.y + dy)
			if city.bld[i] ~= id or city.road[i] == 1 then
				okCells = false
			end
		end
	end
end
check(okCells, "building cells match the grid and never sit on roads")

-- Editing: a road, a zone, then bulldozing.
local funds = city.funds
local path = Grid.roadPath(cx + 14, cy, cx + 14, cy + 6)
check(#path == 7, "road path is 7 tiles")
check(city:placeRoad(path), "placing a road works")
check(city.funds < funds, "roads cost money")
check(city:placeZone(cx + 15, cy + 1, cx + 16, cy + 5, Grid.Zone.RES), "zoning works")
check(city.zone[Grid.idx(cx + 15, cy + 2)] == Grid.Zone.RES, "zone stored")
local pop = city.population
for _ = 1, 24 * 6 do
	city:advance(10, 1)
end
local grown = 0
for y = cy + 1, cy + 5 do
	for x = cx + 15, cx + 16 do
		if city.bld[Grid.idx(x, y)] > 0 then
			grown += 1
		end
	end
end
check(grown > 0, "new zone grows homes in 6 game days (" .. grown .. " lots)")
check(city:gameDay() >= 6, "clock advanced")
check(city:bulldoze(cx + 15, cy + 1, cx + 16, cy + 5), "bulldozing works")
check(city.bld[Grid.idx(cx + 15, cy + 2)] == 0 and city.zone[Grid.idx(cx + 15, cy + 2)] == 0, "bulldozed cells are empty")
city.funds = 5
check(not city:placeRoad(Grid.roadPath(cx + 20, cy + 3, cx + 25, cy + 3)), "can't build without money")
city.funds = 20000

-- Saves round-trip.
local data = city:serialize()
local copy = City.new(1)
check(copy:deserialize(data), "save loads")
local count = 0
for _ in copy.buildings do
	count += 1
end
local orig = 0
for _ in city.buildings do
	orig += 1
end
check(count == orig, "same buildings after load")
check(copy.population == city.population and copy.funds == city.funds, "same people and money after load")
local same = true
for i = 1, Grid.W * Grid.H do
	if copy.road[i] ~= city.road[i] or copy.zone[i] ~= city.zone[i] or copy.land[i] ~= city.land[i] then
		same = false
	end
end
check(same, "same roads, zones and land after load")

print(if fails == 0 then "ALL PASS" else fails .. " FAILED")
if fails > 0 then
	error("tests failed")
end
