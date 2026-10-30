--!nocheck
-- Mayor Street (Roblox): starts the city, runs the clock, takes the mayor's build
-- orders, places cars, lights the day and night, and saves the city.
-- Solo first: the first player in the server is the mayor and owns the saved city.
-- Anyone else who joins can walk and drive, but not build.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Grid = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Grid"))
local City = require(script.Parent.City)
local Renderer = require(script.Parent.CityRenderer)
local Vehicles = require(script.Parent.Vehicles)
local Saves = require(script.Parent.Saves)

local Z = Grid.Zone
local T = Grid.TILE
local SPEEDS = { [0] = 0, 1, 2, 4 }
local AUTOSAVE_SECONDS = 90

-- --------------------------------------------------------------- remotes ---

local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
local function remote(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
	return r
end
local mayorAction = remote("MayorAction")
local setSpeed = remote("SetSpeed")
local notify = remote("Notify")
remotes.Parent = ReplicatedStorage

local state = Instance.new("Folder")
state.Name = "CityState"
state.Parent = ReplicatedStorage

-- -------------------------------------------------------------- lighting ---

Lighting.Brightness = 2.4
Lighting.Ambient = Color3.fromRGB(70, 72, 84)
Lighting.OutdoorAmbient = Color3.fromRGB(128, 130, 145)
Lighting.EnvironmentDiffuseScale = 1
Lighting.EnvironmentSpecularScale = 1
Lighting.GlobalShadows = true
Lighting.GeographicLatitude = 35
local function effect(class, props)
	local e = Lighting:FindFirstChildOfClass(class) or Instance.new(class)
	for k, v in props do
		e[k] = v
	end
	e.Parent = Lighting
end
effect("Atmosphere", { Density = 0.3, Offset = 0.2, Color = Color3.fromRGB(200, 210, 225), Decay = Color3.fromRGB(110, 120, 140), Glare = 0.25, Haze = 1.4 })
effect("BloomEffect", { Intensity = 0.7, Size = 26, Threshold = 1.6 })
effect("ColorCorrectionEffect", { Saturation = 0.12, Contrast = 0.06 })
effect("SunRaysEffect", { Intensity = 0.04, Spread = 0.6 })
if not Lighting:FindFirstChildOfClass("Sky") then
	Instance.new("Sky").Parent = Lighting
end

-- ------------------------------------------------------------------ city ---

local city = City.new(1337)
city:buildStarterTown(14)
local renderer = Renderer.new(city)
renderer:rebuildAll()
city.onMessage = function(text)
	notify:FireAllClients(text)
end

local cx, cy = city:centerCell()

local spawn = Instance.new("SpawnLocation")
spawn.Anchored = true
spawn.CanCollide = false
spawn.Transparency = 1
spawn.Size = Vector3.new(6, 1, 6)
spawn.Position = Grid.cellCenter(cx + 2, cy) + Vector3.new(0, 1.2, -(T / 2 - 3))
spawn.Duration = 0
spawn.Parent = workspace

local carFolder = Instance.new("Folder")
carFolder.Name = "Cars"
carFolder.Parent = workspace
local carColors = { Color3.fromRGB(200, 40, 40), Color3.fromRGB(40, 90, 200), Color3.fromRGB(235, 235, 235) }
for k, dx in { 3, -3, 9 } do
	local c = Grid.cellCenter(cx + dx, cy) + Vector3.new(0, 0.5, 8)
	Vehicles.spawn(CFrame.lookAt(c, c + Vector3.new(1, 0, 0)), carColors[k], carFolder)
end

-- ----------------------------------------------------------------- mayor ---

local mayorId = nil
local speedIndex = 1
local loaded = false

local function saveCity(reason)
	if not mayorId or not loaded then
		return
	end
	local ok, err = Saves.save(mayorId, city:serialize())
	if not ok and reason == "manual" then
		local p = Players:GetPlayerByUserId(mayorId)
		if p then
			notify:FireClient(p, "Could not save: " .. err)
		end
	end
end

local function onPlayerAdded(player)
	if mayorId then
		notify:FireClient(player, "You're visiting this mayor's city. Walk around, press E by a car to drive.")
		return
	end
	mayorId = player.UserId
	state:SetAttribute("Mayor", mayorId)
	local data, err = Saves.load(mayorId)
	if data and city:deserialize(data) then
		renderer:rebuildAll()
		notify:FireClient(player, "Welcome back, Mayor. Your city is loaded. Press M for the mayor view.")
	elseif err then
		notify:FireClient(player, "Saving is off here (publish the place and allow API access in Game Settings). Press M for the mayor view.")
	else
		notify:FireClient(player, "Welcome to New Harbor, Mayor. Press M for the mayor view.")
	end
	loaded = err == nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	task.spawn(onPlayerAdded, p)
end

Players.PlayerRemoving:Connect(function(player)
	if player.UserId == mayorId then
		saveCity("leave")
	end
end)

game:BindToClose(function()
	saveCity("close")
end)

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_SECONDS)
		saveCity("auto")
	end
end)

local function cellArg(v, max)
	if type(v) ~= "number" or v ~= v then
		return nil
	end
	return math.clamp(math.floor(v), 0, max - 1)
end

local ZONE_TOOLS = { res = Z.RES, com = Z.COM, ind = Z.IND }

mayorAction.OnServerEvent:Connect(function(player, tool, ax, ay, bx, by)
	if player.UserId ~= mayorId then
		notify:FireClient(player, "Only the mayor can build in this city.")
		return
	end
	ax, ay, bx, by = cellArg(ax, Grid.W), cellArg(ay, Grid.H), cellArg(bx, Grid.W), cellArg(by, Grid.H)
	if not (ax and ay and bx and by) then
		return
	end
	if tool == "road" then
		city:placeRoad(Grid.roadPath(ax, ay, bx, by))
	elseif ZONE_TOOLS[tool] then
		local x0, y0, x1, y1 = Grid.rect(ax, ay, bx, by)
		city:placeZone(x0, y0, x1, y1, ZONE_TOOLS[tool])
	elseif tool == "bulldoze" then
		local x0, y0, x1, y1 = Grid.rect(ax, ay, bx, by)
		city:bulldoze(x0, y0, x1, y1)
	elseif tool == "save" then
		saveCity("manual")
		notify:FireClient(player, if loaded then "City saved." else "Saving is off in this place.")
	end
end)

setSpeed.OnServerEvent:Connect(function(player, n)
	if player.UserId == mayorId and SPEEDS[n] then
		speedIndex = n
	end
end)

-- ----------------------------------------------------------------- clock ---

local publishTimer = 0
RunService.Heartbeat:Connect(function(dt)
	local speed = SPEEDS[speedIndex]
	if speed > 0 then
		city:advance(dt, speed)
	end
	publishTimer += dt
	if publishTimer < 0.25 then
		return
	end
	publishTimer = 0
	local tod = city:timeOfDay()
	Lighting.ClockTime = tod
	renderer:setNight(tod < 6.4 or tod > 19.2)
	state:SetAttribute("Funds", math.floor(city.funds))
	state:SetAttribute("Population", city.population)
	state:SetAttribute("Jobs", city.jobsC + city.jobsI)
	state:SetAttribute("Minutes", city.minutes)
	state:SetAttribute("Speed", speedIndex)
	state:SetAttribute("DemandR", city.demand[Z.RES])
	state:SetAttribute("DemandC", city.demand[Z.COM])
	state:SetAttribute("DemandI", city.demand[Z.IND])
	state:SetAttribute("Income", math.floor(city.lastIncome - city.lastExpense))
end)
