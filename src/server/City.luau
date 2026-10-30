--!nocheck
-- The city simulation: land, roads, zones, buildings, money and growth.
-- A port of msp's scripts/city.gd (flat map). Traffic, services and catalog
-- buildings come later; the growth, demand and money rules match the Godot game.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Grid = require(ReplicatedStorage.Shared.Grid)

local W, H = Grid.W, Grid.H
local Z = Grid.Zone
local idx, inside = Grid.idx, Grid.inside
local DIRS = Grid.DIRS

local ROAD_UPKEEP = 0.5
local MINUTES_PER_SECOND = 6 -- at 1x speed: one game hour every 10 real seconds

-- People (RES) or jobs (COM, IND) per building: CAP[zone][stage], CAP_BIG for 2x2 towers.
local CAP = {
	[Z.RES] = { 6, 32, 140 },
	[Z.COM] = { 6, 28, 110 },
	[Z.IND] = { 10, 32, 70 },
}
local CAP_BIG = { [Z.RES] = 640, [Z.COM] = 520, [Z.IND] = 280 }
local STAGE_POP = { 0, 120, 1400 } -- population needed for stage 1, 2, 3
local STAGE_LV = { 0, 0.3, 0.6 } -- land value needed for stage 1, 2, 3

local City = {}
City.__index = City

local function fill(n, v)
	local t = table.create(n, v)
	return t
end

function City.new(seed)
	local self = setmetatable({}, City)
	self.seed = seed or 1337
	self.rng = Random.new(self.seed)
	local n = W * H
	self.land = fill(n, 0)
	self.road = fill(n, 0)
	self.zone = fill(n, 0)
	self.bld = fill(n, 0) -- building id per cell, 0 = none
	self.landValue = fill(n, 0)
	self.coastDist = fill(n, 0)
	self.buildings = {} -- id -> building table
	self.nextId = 1
	self.funds = 50000
	self.taxRate = 0.09
	self.minutes = 7 * 60
	self.population = 0
	self.jobsC = 0
	self.jobsI = 0
	self.demand = { [Z.RES] = 1.0, [Z.COM] = 0.4, [Z.IND] = 0.8 }
	self.lastIncome = 0
	self.lastExpense = 0
	self.animateGrowth = true
	self._zoned = nil
	-- Hooks for the renderer and UI; set by the server.
	self.onBuildingAdded = function(_b, _animate) end
	self.onBuildingRemoved = function(_b) end
	self.onCellsChanged = function(_x0, _y0, _x1, _y1) end
	self.onMessage = function(_text) end
	self:_makeIsland()
	return self
end

-- ------------------------------------------------------------------ terrain ---

function City:_makeIsland()
	local z = (self.seed % 997) + 0.37
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local dx = (x + 0.5 - W / 2) / (W / 2)
			local dy = (y + 0.5 - H / 2) / (H / 2)
			local d = math.sqrt(dx * dx + dy * dy)
			local n = math.noise(x * 0.09, y * 0.09, z) + 0.5 * math.noise(x * 0.25, y * 0.25, z + 11)
			if d + n * 0.22 < 0.9 then
				self.land[idx(x, y)] = 1
			end
		end
	end
	-- Distance (in tiles) to the nearest water, capped at 10: the coast adds land value.
	local q = {}
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = idx(x, y)
			if self.land[i] == 0 then
				self.coastDist[i] = 0
				table.insert(q, i)
			else
				self.coastDist[i] = 10
			end
		end
	end
	local head = 1
	while head <= #q do
		local i = q[head]
		head += 1
		local x, y = (i - 1) % W, (i - 1) // W
		local dd = self.coastDist[i] + 1
		if dd < 10 then
			for r = 0, 3 do
				local nx, ny = x + DIRS[r].X, y + DIRS[r].Y
				if inside(nx, ny) then
					local j = idx(nx, ny)
					if self.coastDist[j] > dd then
						self.coastDist[j] = dd
						table.insert(q, j)
					end
				end
			end
		end
	end
end

-- -------------------------------------------------------------------- basics ---

function City:isRoad(x, y)
	return inside(x, y) and self.road[idx(x, y)] == 1
end

-- Bits: N (y-1) = 1, E (x+1) = 2, S (y+1) = 4, W (x-1) = 8.
function City:roadMask(x, y)
	local m = 0
	if self:isRoad(x, y - 1) then m += 1 end
	if self:isRoad(x + 1, y) then m += 2 end
	if self:isRoad(x, y + 1) then m += 4 end
	if self:isRoad(x - 1, y) then m += 8 end
	return m
end

-- Rotation (0..3) toward the nearest road within 2 tiles, or -1.
function City:roadAccessDir(x, y)
	for dist = 1, 2 do
		for r = 0, 3 do
			local d = DIRS[r]
			if self:isRoad(x + d.X * dist, y + d.Y * dist) then
				return r
			end
		end
	end
	return -1
end

function City:gameDay()
	return self.minutes // 1440
end

function City:timeOfDay()
	return (self.minutes % 1440) / 60
end

function City:spend(amount)
	if self.funds < amount then
		self.onMessage(string.format("Not enough money ($%d needed)", math.floor(amount)))
		return false
	end
	self.funds -= amount
	return true
end

-- ------------------------------------------------------------------- editing ---

function City:roadCost(path)
	local n = 0
	for _, c in path do
		local x, y = c[1], c[2]
		if inside(x, y) then
			local i = idx(x, y)
			if self.land[i] == 1 and self.road[i] == 0 then
				n += 1
			end
		end
	end
	return n * Grid.ROAD_COST
end

function City:placeRoad(path)
	local cost = self:roadCost(path)
	if cost == 0 or not self:spend(cost) then
		return false
	end
	local x0, y0, x1, y1 = W, H, -1, -1
	for _, c in path do
		local x, y = c[1], c[2]
		if inside(x, y) and self.land[idx(x, y)] == 1 then
			local i = idx(x, y)
			if self.bld[i] > 0 then
				self:removeBuilding(self.bld[i])
			end
			self.road[i] = 1
			self.zone[i] = Z.NONE
			x0, y0 = math.min(x0, x), math.min(y0, y)
			x1, y1 = math.max(x1, x), math.max(y1, y)
		end
	end
	self._zoned = nil
	self.onCellsChanged(x0 - 1, y0 - 1, x1 + 1, y1 + 1)
	return true
end

function City:zoneCost(x0, y0, x1, y1, z)
	local n = 0
	for y = y0, y1 do
		for x = x0, x1 do
			local i = idx(x, y)
			if self.land[i] == 1 and self.road[i] == 0 and self.zone[i] ~= z then
				n += 1
			end
		end
	end
	return n * Grid.ZONE_COST
end

function City:placeZone(x0, y0, x1, y1, z)
	local cost = self:zoneCost(x0, y0, x1, y1, z)
	if cost == 0 or not self:spend(cost) then
		return false
	end
	for y = y0, y1 do
		for x = x0, x1 do
			local i = idx(x, y)
			if self.land[i] == 1 and self.road[i] == 0 and self.zone[i] ~= z then
				if self.bld[i] > 0 then
					self:removeBuilding(self.bld[i])
				end
				self.zone[i] = z
			end
		end
	end
	self._zoned = nil
	self.onCellsChanged(x0, y0, x1, y1)
	return true
end

function City:bulldozeCost(x0, y0, x1, y1)
	local n = 0
	local seen = {}
	for y = y0, y1 do
		for x = x0, x1 do
			local i = idx(x, y)
			if self.road[i] == 1 then
				n += 1
			elseif self.bld[i] > 0 and not seen[self.bld[i]] then
				seen[self.bld[i]] = true
				n += 1
			end
		end
	end
	return n * Grid.BULLDOZE_COST
end

function City:bulldoze(x0, y0, x1, y1)
	local cost = self:bulldozeCost(x0, y0, x1, y1)
	local anyZone = false
	for y = y0, y1 do
		for x = x0, x1 do
			if self.zone[idx(x, y)] ~= Z.NONE then
				anyZone = true
			end
		end
	end
	if cost == 0 and not anyZone then
		return false
	end
	if cost > 0 and not self:spend(cost) then
		return false
	end
	for y = y0, y1 do
		for x = x0, x1 do
			local i = idx(x, y)
			if self.bld[i] > 0 then
				self:removeBuilding(self.bld[i])
			end
			self.road[i] = 0
			self.zone[i] = Z.NONE
		end
	end
	self._zoned = nil
	self.onCellsChanged(x0 - 1, y0 - 1, x1 + 1, y1 + 1)
	return true
end

-- ----------------------------------------------------------------- buildings ---

function City:capacity(b)
	if b.size == 2 then
		return CAP_BIG[b.zone]
	end
	return CAP[b.zone][b.stage]
end

function City:_count(b, sign)
	local c = self:capacity(b) * sign
	if b.zone == Z.RES then
		self.population += c
	elseif b.zone == Z.COM then
		self.jobsC += c
	else
		self.jobsI += c
	end
end

function City:addBuilding(x, y, size, z, stage, rot, animate, variant, born)
	local id = self.nextId
	self.nextId += 1
	local b = {
		id = id, x = x, y = y, size = size, zone = z, stage = stage, rot = rot,
		variant = variant or self.rng:NextInteger(1, 2 ^ 30),
		born = born or self.minutes,
	}
	self.buildings[id] = b
	for dy = 0, size - 1 do
		for dx = 0, size - 1 do
			self.bld[idx(x + dx, y + dy)] = id
		end
	end
	self:_count(b, 1)
	self.onBuildingAdded(b, animate)
	return id
end

function City:removeBuilding(id)
	local b = self.buildings[id]
	if not b then
		return
	end
	for dy = 0, b.size - 1 do
		for dx = 0, b.size - 1 do
			self.bld[idx(b.x + dx, b.y + dy)] = 0
		end
	end
	self.buildings[id] = nil
	self:_count(b, -1)
	self.onBuildingRemoved(b)
	self.onCellsChanged(b.x, b.y, b.x + b.size - 1, b.y + b.size - 1)
end

-- ---------------------------------------------------------------- simulation ---

-- Advance the clock. Returns true when at least one hour ticked.
function City:advance(realSeconds, speed)
	local before = self.minutes // 60
	self.minutes += realSeconds * MINUTES_PER_SECOND * speed
	local after = self.minutes // 60
	for h = before + 1, after do
		self:_hourTick()
		if h % 24 == 0 then
			self:_dayTick()
		elseif h % 24 == 12 then
			self:computeLandValue()
		end
	end
	return after > before
end

function City:_updateDemand()
	local workers = self.population * 0.55
	local jobs = self.jobsC + self.jobsI
	local taxPen = (self.taxRate - 0.09) * 6
	self.demand[Z.RES] = math.clamp(((jobs * 1.1 + 80) - workers) / math.max(40, workers * 0.2) - taxPen, -1, 1)
	local wantC = self.population * 0.24 + 15
	self.demand[Z.COM] = math.clamp((wantC - self.jobsC) / math.max(25, wantC * 0.3) - taxPen, -1, 1)
	local wantI = self.population * 0.34 + 40
	self.demand[Z.IND] = math.clamp((wantI - self.jobsI) / math.max(30, wantI * 0.3) - taxPen, -1, 1)
end

function City:_zonedCells()
	if not self._zoned then
		local t = {}
		for i = 1, W * H do
			if self.zone[i] ~= Z.NONE then
				table.insert(t, i)
			end
		end
		self._zoned = t
	end
	return self._zoned
end

function City:_hourTick(tries)
	self:_updateDemand()
	local cells = self:_zonedCells()
	if #cells == 0 then
		return
	end
	tries = tries or math.min(#cells, 24 + #cells // 12)
	for _ = 1, tries do
		local i = cells[self.rng:NextInteger(1, #cells)]
		self:_tryGrow((i - 1) % W, (i - 1) // W)
	end
end

function City:_tryGrow(x, y)
	local i = idx(x, y)
	local z = self.zone[i]
	if z == Z.NONE or self.road[i] == 1 then
		return
	end
	local d = self.demand[z]
	if d <= 0.02 then
		return
	end
	local rot = self:roadAccessDir(x, y)
	if self.bld[i] == 0 then
		if rot < 0 then
			return
		end
		if self.rng:NextNumber() < 0.45 * d then
			self:addBuilding(x, y, 1, z, 1, rot, self.animateGrowth)
		end
		return
	end
	local b = self.buildings[self.bld[i]]
	if b.stage >= 3 or b.size == 2 then
		return
	end
	if self.minutes - b.born < 60 * 30 then -- at least 30 game hours old
		return
	end
	local nextStage = b.stage + 1
	local lvOk = z == Z.IND or self.landValue[i] >= STAGE_LV[nextStage]
	if self.population < STAGE_POP[nextStage] or not lvOk then
		return
	end
	if self.rng:NextNumber() > 0.18 * d then
		return
	end
	if nextStage == 3 and self:_tryMerge(b) then
		return
	end
	self:removeBuilding(b.id)
	self:addBuilding(x, y, 1, z, nextStage, if rot >= 0 then rot else b.rot, self.animateGrowth)
end

-- Grow a 2x2 tower when the three neighbouring lots are the same zone at stage >= 2.
function City:_tryMerge(b)
	if self.rng:NextNumber() > 0.5 then
		return false
	end
	for _, off in { { 0, 0 }, { -1, 0 }, { 0, -1 }, { -1, -1 } } do
		local ox, oy = b.x + off[1], b.y + off[2]
		local ok = true
		local ids = {}
		for dy = 0, 1 do
			for dx = 0, 1 do
				local cx, cy = ox + dx, oy + dy
				if not inside(cx, cy) then
					ok = false
					break
				end
				local j = idx(cx, cy)
				if self.zone[j] ~= b.zone or self.road[j] == 1 or self.bld[j] == 0 then
					ok = false
					break
				end
				local nb = self.buildings[self.bld[j]]
				if nb.size ~= 1 or nb.stage < 2 then
					ok = false
					break
				end
				ids[nb.id] = true
			end
			if not ok then
				break
			end
		end
		if ok then
			local rot = -1
			for dy = 0, 1 do
				for dx = 0, 1 do
					local r = self:roadAccessDir(ox + dx, oy + dy)
					if r >= 0 and rot < 0 then
						rot = r
					end
				end
			end
			if rot >= 0 then
				for id in ids do
					self:removeBuilding(id)
				end
				self:addBuilding(ox, oy, 2, b.zone, 3, rot, self.animateGrowth)
				return true
			end
		end
	end
	return false
end

function City:_dayTick()
	local income = (self.population + (self.jobsC + self.jobsI) * 0.8) * self.taxRate * 3
	local roads = 0
	for i = 1, W * H do
		roads += self.road[i]
	end
	local expense = roads * ROAD_UPKEEP
	self.funds += income - expense
	self.lastIncome = income
	self.lastExpense = expense
end

-- Separable box blur over a (2r+1)^2 window.
local function blur(src, r)
	local tmp = table.create(W * H, 0)
	local out = table.create(W * H, 0)
	local k = 1 / (2 * r + 1)
	for y = 0, H - 1 do
		local acc = 0
		for x = -r, r do
			if x >= 0 and x < W then
				acc += src[y * W + x + 1]
			end
		end
		for x = 0, W - 1 do
			tmp[y * W + x + 1] = acc * k
			local xo, xi = x - r, x + r + 1
			if xo >= 0 then acc -= src[y * W + xo + 1] end
			if xi < W then acc += src[y * W + xi + 1] end
		end
	end
	for x = 0, W - 1 do
		local acc = 0
		for y = -r, r do
			if y >= 0 and y < H then
				acc += tmp[y * W + x + 1]
			end
		end
		for y = 0, H - 1 do
			out[y * W + x + 1] = acc * k
			local yo, yi = y - r, y + r + 1
			if yo >= 0 then acc -= tmp[yo * W + x + 1] end
			if yi < H then acc += tmp[yi * W + x + 1] end
		end
	end
	return out
end

function City:computeLandValue()
	local n = W * H
	local com, ind, res = table.create(n, 0), table.create(n, 0), table.create(n, 0)
	for _, b in self.buildings do
		local w = b.stage * (if b.size == 2 then 2 else 1)
		local i = idx(b.x, b.y)
		if b.zone == Z.COM then
			com[i] += w
		elseif b.zone == Z.IND then
			ind[i] += w
		else
			res[i] += w
		end
	end
	com, ind, res = blur(com, 6), blur(ind, 5), blur(res, 5)
	for i = 1, n do
		if self.land[i] == 0 then
			self.landValue[i] = 0
		else
			local v = 0.28
			v += math.min(com[i] * 0.9, 0.3)
			v += math.min(res[i] * 0.5, 0.15)
			v += 0.18 * math.clamp(1 - (self.coastDist[i] - 2) / 6, 0, 1)
			v -= math.min(ind[i] * 1.6, 0.4) * (if self.zone[i] == Z.IND then 0.4 else 1)
			self.landValue[i] = math.clamp(v, 0, 1)
		end
	end
end

-- ------------------------------------------------------------------ starters ---

function City:centerCell()
	local cx, cy = W // 2, H // 2
	for r = 0, 20 do
		for y = cy - r, cy + r do
			for x = cx - r, cx + r do
				if inside(x, y) and self.land[idx(x, y)] == 1 then
					return x, y
				end
			end
		end
	end
	return cx, cy
end

function City:_freeRoad(x, y)
	if inside(x, y) and self.land[idx(x, y)] == 1 then
		self.road[idx(x, y)] = 1
	end
end

-- A small starter town (a shrunk version of msp's demo city): a street grid of 2-deep
-- blocks, shops in the middle, homes around them, a little industry to the west, grown
-- for a few weeks. Plus the main avenue across the island.
function City:buildStarterTown(growDays)
	local cx, cy = self:centerCell()
	for x = 0, W - 1 do
		self:_freeRoad(x, cy)
	end
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local dx, dy = x - cx, y - cy
			if math.abs(dx) <= 12 and math.abs(dy) <= 9 and (dx % 6 == 0 or dy % 3 == 0) then
				self:_freeRoad(x, y)
			end
		end
	end
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = idx(x, y)
			local dx, dy = x - cx, y - cy
			if self.land[i] == 1 and self.road[i] == 0 and math.abs(dx) <= 12 and math.abs(dy) <= 9 then
				local r = math.sqrt(dx * dx + dy * dy * 1.3)
				local z = Z.RES
				if r < 5 then
					z = Z.COM
				elseif dx < -7 then
					z = Z.IND
				elseif r < 8 and self.rng:NextNumber() < 0.3 then
					z = Z.COM
				end
				self.zone[i] = z
			end
		end
	end
	self._zoned = nil
	self:computeLandValue()
	local was = self.animateGrowth
	self.animateGrowth = false
	for h = 1, (growDays or 30) * 24 do
		self.minutes += 60
		self:_hourTick(60)
		if h % 24 == 0 then
			self:_dayTick()
		elseif h % 24 == 12 then
			self:computeLandValue()
		end
	end
	self.animateGrowth = was
	self.funds = 50000
	self.minutes = self:gameDay() * 1440 + 9 * 60
end

-- -------------------------------------------------------------------- saving ---

local SAVE_VERSION = 1

function City:serialize()
	local road, zone = table.create(W * H), table.create(W * H)
	for i = 1, W * H do
		road[i] = tostring(self.road[i])
		zone[i] = tostring(self.zone[i])
	end
	local blds = {}
	for _, b in self.buildings do
		table.insert(blds, { b.x, b.y, b.size, b.zone, b.stage, b.rot, b.variant, math.floor(b.born) })
	end
	return {
		v = SAVE_VERSION,
		seed = self.seed,
		funds = self.funds,
		tax = self.taxRate,
		minutes = self.minutes,
		road = table.concat(road),
		zone = table.concat(zone),
		blds = blds,
	}
end

-- Replace the city with saved data. The caller redraws everything afterwards.
function City:deserialize(d)
	if type(d) ~= "table" or d.v ~= SAVE_VERSION or #d.road ~= W * H then
		return false
	end
	local fresh = City.new(d.seed)
	for k, v in fresh do
		if k:sub(1, 2) ~= "on" then
			self[k] = v
		end
	end
	self._zoned = nil
	self.funds = d.funds
	self.taxRate = d.tax
	self.minutes = d.minutes
	for i = 1, W * H do
		self.road[i] = tonumber(d.road:sub(i, i)) or 0
		self.zone[i] = tonumber(d.zone:sub(i, i)) or 0
	end
	local hook = self.onBuildingAdded
	self.onBuildingAdded = function() end
	for _, e in d.blds do
		self:addBuilding(e[1], e[2], e[3], e[4], e[5], e[6], false, e[7], e[8])
	end
	self.onBuildingAdded = hook
	self:_updateDemand()
	self:computeLandValue()
	return true
end

return City
