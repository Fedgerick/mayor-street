--!nocheck
-- Map constants and grid helpers shared by the server sim and the client tools.
-- Cells are 0-based (x, y) like the Godot game; arrays use idx() = y * W + x + 1.

local Grid = {}

Grid.TILE = 40 -- studs per tile (msp uses 12 m; one stud is about 0.28 m)
Grid.W = 64
Grid.H = 64

Grid.Zone = { NONE = 0, RES = 1, COM = 2, IND = 3 }
Grid.ZONE_NAMES = { [0] = "None", "Residential", "Commercial", "Industrial" }
Grid.ZONE_COLORS = {
	[1] = Color3.fromRGB(92, 196, 92),
	[2] = Color3.fromRGB(82, 140, 230),
	[3] = Color3.fromRGB(235, 196, 70),
}

Grid.ROAD_COST = 25
Grid.ZONE_COST = 10
Grid.BULLDOZE_COST = 10

-- rot 0..3 = S, E, N, W (same order as msp's City.DIRS)
Grid.DIRS = { [0] = Vector2.new(0, 1), Vector2.new(1, 0), Vector2.new(0, -1), Vector2.new(-1, 0) }

function Grid.idx(x, y)
	return y * Grid.W + x + 1
end

function Grid.inside(x, y)
	return x >= 0 and y >= 0 and x < Grid.W and y < Grid.H
end

-- World position (ground level) of a cell's centre. The map is centred on the origin.
function Grid.cellCenter(x, y)
	local t = Grid.TILE
	return Vector3.new((x - Grid.W / 2 + 0.5) * t, 0, (y - Grid.H / 2 + 0.5) * t)
end

function Grid.worldToCell(p)
	local t = Grid.TILE
	return math.floor(p.X / t + Grid.W / 2), math.floor(p.Z / t + Grid.H / 2)
end

local function sign(n)
	if n > 0 then
		return 1
	elseif n < 0 then
		return -1
	end
	return 0
end

-- L-shaped road path from a to b, along the longer axis first. Returns a list of {x, y}.
function Grid.roadPath(ax, ay, bx, by)
	local out = {}
	local cx, cy
	if math.abs(bx - ax) >= math.abs(by - ay) then
		cx, cy = bx, ay
	else
		cx, cy = ax, by
	end
	local function walk(px, py, qx, qy)
		local sx, sy = sign(qx - px), sign(qy - py)
		local x, y = px, py
		while true do
			local last = out[#out]
			if not last or last[1] ~= x or last[2] ~= y then
				table.insert(out, { x, y })
			end
			if x == qx and y == qy then
				break
			end
			x += sx
			y += sy
		end
	end
	walk(ax, ay, cx, cy)
	walk(cx, cy, bx, by)
	return out
end

-- Clamped rectangle between two cells: x0, y0, x1, y1 (inclusive).
function Grid.rect(ax, ay, bx, by)
	local x0 = math.clamp(math.min(ax, bx), 0, Grid.W - 1)
	local y0 = math.clamp(math.min(ay, by), 0, Grid.H - 1)
	local x1 = math.clamp(math.max(ax, bx), 0, Grid.W - 1)
	local y1 = math.clamp(math.max(ay, by), 0, Grid.H - 1)
	return x0, y0, x1, y1
end

return Grid
