--!nocheck
-- The HUD (money, people, date, demand) and the mayor view: press M (or the button) for
-- a top-down camera, then drag with the left mouse to lay roads, zone, or bulldoze.
-- WASD / arrows pan, Q and E turn, the mouse wheel zooms, right click cancels a drag.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local Grid = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Grid"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local state = ReplicatedStorage:WaitForChild("CityState")
local mayorAction = remotes:WaitForChild("MayorAction")
local setSpeed = remotes:WaitForChild("SetSpeed")
local notify = remotes:WaitForChild("Notify")

local T, W, H = Grid.TILE, Grid.W, Grid.H

local controls = nil
task.spawn(function()
	local ok, mod = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
	end)
	if ok then
		controls = mod:GetControls()
	end
end)

-- -------------------------------------------------------------------- UI ---

local DARK = Color3.fromRGB(22, 26, 34)
local TEXT = Color3.fromRGB(236, 238, 242)
local MUTED = Color3.fromRGB(150, 158, 172)
local ACCENT = Color3.fromRGB(255, 196, 64)

local gui = Instance.new("ScreenGui")
gui.Name = "MayorHUD"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

local function corner(obj, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = obj
end

local function frame(parent, size, pos, anchor)
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = pos
	f.AnchorPoint = anchor or Vector2.zero
	f.BackgroundColor3 = DARK
	f.BackgroundTransparency = 0.2
	f.BorderSizePixel = 0
	f.Parent = parent
	corner(f, 10)
	return f
end

local function label(parent, text, size, pos, color, font, align)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Text = text
	l.TextColor3 = color or TEXT
	l.Font = font or Enum.Font.GothamMedium
	l.TextScaled = true
	l.TextXAlignment = align or Enum.TextXAlignment.Left
	l.Parent = parent
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = 18
	c.Parent = l
	return l
end

local function button(parent, text, size, pos)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = pos
	b.BackgroundColor3 = Color3.fromRGB(44, 50, 64)
	b.AutoButtonColor = true
	b.Text = text
	b.TextColor3 = TEXT
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 14
	b.TextWrapped = true
	b.Parent = parent
	corner(b, 8)
	return b
end

-- Top bar: money, people, jobs, date and time.
local bar = frame(gui, UDim2.new(0, 560, 0, 40), UDim2.new(0.5, 0, 0, 8), Vector2.new(0.5, 0))
local fundsLabel = label(bar, "$0", UDim2.new(0.27, 0, 0.6, 0), UDim2.new(0.03, 0, 0.2, 0), ACCENT, Enum.Font.GothamBold)
local popLabel = label(bar, "0 people", UDim2.new(0.24, 0, 0.6, 0), UDim2.new(0.3, 0, 0.2, 0))
local jobsLabel = label(bar, "0 jobs", UDim2.new(0.2, 0, 0.6, 0), UDim2.new(0.54, 0, 0.2, 0), MUTED)
local dateLabel = label(bar, "Day 1 09:00", UDim2.new(0.24, 0, 0.6, 0), UDim2.new(0.74, 0, 0.2, 0), TEXT, nil, Enum.TextXAlignment.Right)

-- Demand bars (R, C, I), like the Godot HUD.
local demandBox = frame(gui, UDim2.new(0, 96, 0, 92), UDim2.new(1, -12, 0, 8), Vector2.new(1, 0))
label(demandBox, "Demand", UDim2.new(1, -12, 0, 16), UDim2.new(0, 8, 0, 4), MUTED)
local demandBars = {}
for k, key in { "R", "C", "I" } do
	local x = 10 + (k - 1) * 28
	local track = Instance.new("Frame")
	track.Size = UDim2.new(0, 18, 0, 50)
	track.Position = UDim2.new(0, x, 0, 24)
	track.BackgroundColor3 = Color3.fromRGB(50, 56, 70)
	track.BorderSizePixel = 0
	track.Parent = demandBox
	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0, 1)
	fill.Position = UDim2.new(0, 0, 1, 0)
	fill.Size = UDim2.new(1, 0, 0, 0)
	fill.BackgroundColor3 = Grid.ZONE_COLORS[k]
	fill.BorderSizePixel = 0
	fill.Parent = track
	label(demandBox, key, UDim2.new(0, 18, 0, 14), UDim2.new(0, x, 0, 76), TEXT, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
	demandBars[key] = fill
end

-- Mayor view toggle.
local mayorButton = button(gui, "Mayor view (M)", UDim2.new(0, 150, 0, 36), UDim2.new(0, 12, 1, -48))

-- Toast for messages from the server.
local toast = label(gui, "", UDim2.new(0, 640, 0, 26), UDim2.new(0.5, -320, 0, 56), TEXT, Enum.Font.GothamMedium, Enum.TextXAlignment.Center)
toast.TextStrokeTransparency = 0.4
local toastSerial = 0
local function showToast(text)
	toastSerial += 1
	local mine = toastSerial
	toast.Text = text
	task.delay(5, function()
		if toastSerial == mine then
			toast.Text = ""
		end
	end)
end
notify.OnClientEvent:Connect(showToast)

-- Tool bar (mayor view only).
local TOOLS = {
	{ id = "road", name = "Road", hint = "$25 a tile", key = Enum.KeyCode.One, color = Color3.fromRGB(200, 200, 205) },
	{ id = "res", name = "Homes", hint = "$10 a tile", key = Enum.KeyCode.Two, color = Grid.ZONE_COLORS[1] },
	{ id = "com", name = "Shops", hint = "$10 a tile", key = Enum.KeyCode.Three, color = Grid.ZONE_COLORS[2] },
	{ id = "ind", name = "Industry", hint = "$10 a tile", key = Enum.KeyCode.Four, color = Grid.ZONE_COLORS[3] },
	{ id = "bulldoze", name = "Bulldoze", hint = "$10 each", key = Enum.KeyCode.Five, color = Color3.fromRGB(230, 70, 60) },
}
local toolbar = frame(gui, UDim2.new(0, 8 + 5 * 96 + 3 * 76 + 4, 0, 64), UDim2.new(0.5, 0, 1, -12), Vector2.new(0.5, 1))
toolbar.Visible = false
local toolButtons = {}
local currentTool = "road"
for k, tool in TOOLS do
	local b = button(toolbar, k .. "  " .. tool.name .. "\n" .. tool.hint, UDim2.new(0, 90, 0, 48), UDim2.new(0, 8 + (k - 1) * 96, 0, 8))
	local stripe = Instance.new("Frame")
	stripe.Size = UDim2.new(1, -16, 0, 3)
	stripe.Position = UDim2.new(0, 8, 1, -6)
	stripe.BackgroundColor3 = tool.color
	stripe.BorderSizePixel = 0
	stripe.Parent = b
	toolButtons[tool.id] = b
	b.MouseButton1Click:Connect(function()
		currentTool = tool.id
	end)
end
local speedButtons = {}
local SPEED_NAMES = { [0] = "Pause", "1x", "2x", "4x" }
for n = 0, 3 do
	local b = button(toolbar, SPEED_NAMES[n], UDim2.new(0, 70, 0, 22), UDim2.new(0, 8 + 5 * 96 + (n % 2) * 76, 0, if n < 2 then 8 else 34))
	speedButtons[n] = b
	b.MouseButton1Click:Connect(function()
		setSpeed:FireServer(n)
	end)
end
local saveButton = button(toolbar, "Save", UDim2.new(0, 70, 0, 48), UDim2.new(0, 8 + 5 * 96 + 2 * 76, 0, 8))
saveButton.MouseButton1Click:Connect(function()
	mayorAction:FireServer("save", 0, 0, 0, 0)
end)

local helpLabel = label(gui, "Drag to build  ·  WASD pan  ·  Q/E turn  ·  wheel zoom  ·  right click cancels  ·  M to walk", UDim2.new(0, 640, 0, 18), UDim2.new(0.5, -320, 1, -100), MUTED, nil, Enum.TextXAlignment.Center)
helpLabel.Visible = false

local costLabel = label(gui, "", UDim2.new(0, 220, 0, 20), UDim2.new(0, 0, 0, 0), TEXT, Enum.Font.GothamBold)
costLabel.TextStrokeTransparency = 0.3
costLabel.Visible = false

-- ------------------------------------------------------------- HUD update ---

local function money(n)
	local s = tostring(math.floor(math.abs(n)))
	s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return (if n < 0 then "-$" else "$") .. s
end

RunService.Heartbeat:Connect(function()
	local funds = state:GetAttribute("Funds") or 0
	local income = state:GetAttribute("Income") or 0
	fundsLabel.Text = money(funds) .. "  (" .. (if income >= 0 then "+" else "") .. money(income) .. "/day)"
	popLabel.Text = tostring(state:GetAttribute("Population") or 0) .. " people"
	jobsLabel.Text = tostring(state:GetAttribute("Jobs") or 0) .. " jobs"
	local minutes = state:GetAttribute("Minutes") or 0
	local day = minutes // 1440 + 1
	local m = minutes % 1440
	dateLabel.Text = string.format("Day %d  %02d:%02d", day, m // 60, m % 60)
	for _, key in { "R", "C", "I" } do
		local d = state:GetAttribute("Demand" .. key) or 0
		demandBars[key].Size = UDim2.new(1, 0, math.clamp((d + 1) / 2, 0.02, 1), 0)
	end
	local speed = state:GetAttribute("Speed") or 1
	for n, b in speedButtons do
		b.BackgroundColor3 = if n == speed then Color3.fromRGB(90, 110, 150) else Color3.fromRGB(44, 50, 64)
	end
	for id, b in toolButtons do
		b.BackgroundColor3 = if id == currentTool then Color3.fromRGB(90, 110, 150) else Color3.fromRGB(44, 50, 64)
	end
end)

-- ------------------------------------------------------------- mayor view ---

local camera = workspace.CurrentCamera
local mayorMode = false
local focus = Vector3.zero
local zoom = 320
local yaw = 0
local dragStart = nil

local preview = Instance.new("Folder")
preview.Name = "MayorPreview"
preview.Parent = camera
local rectPart = Instance.new("Part")
rectPart.Anchored = true
rectPart.CanCollide = false
rectPart.CanQuery = false
rectPart.CastShadow = false
rectPart.Material = Enum.Material.Neon
rectPart.Transparency = 0.6
local pool = {}

local function hidePreview()
	rectPart.Parent = nil
	for _, p in pool do
		p.Parent = nil
	end
end

local function cellUnderMouse()
	local m = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(m.X, m.Y)
	if ray.Direction.Y >= -1e-3 then
		return nil
	end
	local t = (0.5 - ray.Origin.Y) / ray.Direction.Y
	local p = ray.Origin + ray.Direction * t
	local x, y = Grid.worldToCell(p)
	return math.clamp(x, 0, W - 1), math.clamp(y, 0, H - 1)
end

local function setMayor(on)
	if on == mayorMode then
		return
	end
	mayorMode = on
	toolbar.Visible = on
	helpLabel.Visible = on
	mayorButton.Text = if on then "Walk (M)" else "Mayor view (M)"
	dragStart = nil
	if on then
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		focus = if root then Vector3.new(root.Position.X, 0, root.Position.Z) else Vector3.zero
		camera.CameraType = Enum.CameraType.Scriptable
		if controls then
			controls:Disable()
		end
	else
		hidePreview()
		costLabel.Visible = false
		camera.CameraType = Enum.CameraType.Custom
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			camera.CameraSubject = hum
		end
		if controls then
			controls:Enable()
		end
	end
end
mayorButton.MouseButton1Click:Connect(function()
	setMayor(not mayorMode)
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if input.KeyCode == Enum.KeyCode.M and not processed then
		setMayor(not mayorMode)
		return
	end
	if not mayorMode or processed then
		return
	end
	for _, tool in TOOLS do
		if input.KeyCode == tool.key then
			currentTool = tool.id
		end
	end
	if input.KeyCode == Enum.KeyCode.P then
		setSpeed:FireServer(if (state:GetAttribute("Speed") or 1) == 0 then 1 else 0)
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		local x, y = cellUnderMouse()
		if x then
			dragStart = { x, y }
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		dragStart = nil
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not mayorMode or input.UserInputType ~= Enum.UserInputType.MouseButton1 or not dragStart then
		return
	end
	local x, y = cellUnderMouse()
	if x then
		mayorAction:FireServer(currentTool, dragStart[1], dragStart[2], x, y)
	end
	dragStart = nil
end)

UserInputService.InputChanged:Connect(function(input, processed)
	if mayorMode and not processed and input.UserInputType == Enum.UserInputType.MouseWheel then
		zoom = math.clamp(zoom * (0.88 ^ input.Position.Z), 80, 1400)
	end
end)

local function toolColor()
	for _, tool in TOOLS do
		if tool.id == currentTool then
			return tool.color
		end
	end
	return Color3.new(1, 1, 1)
end

RunService.RenderStepped:Connect(function(dt)
	if not mayorMode then
		return
	end
	-- Camera.
	local back = Vector3.new(math.sin(yaw), 0, math.cos(yaw))
	local right = Vector3.new(back.Z, 0, -back.X)
	local move = Vector3.zero
	local function down(a, b)
		return UserInputService:IsKeyDown(a) or UserInputService:IsKeyDown(b)
	end
	if down(Enum.KeyCode.W, Enum.KeyCode.Up) then move -= back end
	if down(Enum.KeyCode.S, Enum.KeyCode.Down) then move += back end
	if down(Enum.KeyCode.A, Enum.KeyCode.Left) then move -= right end
	if down(Enum.KeyCode.D, Enum.KeyCode.Right) then move += right end
	if UserInputService:IsKeyDown(Enum.KeyCode.Q) then yaw += dt * 1.5 end
	if UserInputService:IsKeyDown(Enum.KeyCode.E) then yaw -= dt * 1.5 end
	if move.Magnitude > 0 then
		focus += move.Unit * zoom * 1.1 * dt
	end
	local half = W * T / 2
	focus = Vector3.new(math.clamp(focus.X, -half, half), 0, math.clamp(focus.Z, -half, half))
	camera.CFrame = CFrame.lookAt(focus + back * zoom * 0.7 + Vector3.new(0, zoom, 0), focus)

	-- Preview of what the drag will build.
	local x, y = cellUnderMouse()
	hidePreview()
	if not x then
		costLabel.Visible = false
		return
	end
	local color = toolColor()
	local ax, ay = x, y
	if dragStart then
		ax, ay = dragStart[1], dragStart[2]
	end
	local count
	if currentTool == "road" then
		local path = Grid.roadPath(ax, ay, x, y)
		count = #path
		for k, c in path do
			local p = pool[k]
			if not p then
				p = rectPart:Clone()
				pool[k] = p
			end
			p.Color = color
			p.Size = Vector3.new(T - 2, 1, T - 2)
			p.CFrame = CFrame.new(Grid.cellCenter(c[1], c[2]) + Vector3.new(0, 1, 0))
			p.Parent = preview
		end
	else
		local x0, y0, x1, y1 = Grid.rect(ax, ay, x, y)
		local a, b = Grid.cellCenter(x0, y0), Grid.cellCenter(x1, y1)
		count = (x1 - x0 + 1) * (y1 - y0 + 1)
		rectPart.Color = color
		rectPart.Size = Vector3.new((x1 - x0 + 1) * T - 2, 1, (y1 - y0 + 1) * T - 2)
		rectPart.CFrame = CFrame.new((a + b) / 2 + Vector3.new(0, 1, 0))
		rectPart.Parent = preview
	end
	local m = UserInputService:GetMouseLocation()
	local inset = game:GetService("GuiService"):GetGuiInset()
	costLabel.Position = UDim2.new(0, m.X + 18, 0, m.Y - inset.Y + 10)
	costLabel.Text = string.format("%d tile%s", count, if count == 1 then "" else "s")
	costLabel.Visible = true
end)

player.CharacterAdded:Connect(function()
	if mayorMode then
		setMayor(false)
	end
end)
