--!nocheck
-- Drivable cars. Arcade handling: the chassis rides on four hidden low-friction balls,
-- and the driver's client steers it with a LinearVelocity (flat speed) and an
-- AngularVelocity (turning). The client script StreetPlayer drives it; the server only
-- hands the car to whoever sits in the driver's seat and parks it when they leave.

local Players = game:GetService("Players")

local Vehicles = {}

local function part(model, name, size, cf, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function weld(a, b)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

-- cf: where the car stands (ground level), facing its LookVector.
function Vehicles.spawn(cf, color, parent)
	local model = Instance.new("Model")
	model.Name = "Car"
	local base = cf * CFrame.new(0, 2.7, 0)

	local chassis = part(model, "Chassis", Vector3.new(7, 1.6, 15), base, Color3.fromRGB(30, 30, 34), Enum.Material.Metal)
	chassis.CustomPhysicalProperties = PhysicalProperties.new(1, 0, 0, 100, 1)
	model.PrimaryPart = chassis

	local function deco(name, size, offset, col, mat)
		local p = part(model, name, size, base * offset, col, mat)
		p.CanCollide = false
		p.Massless = true
		weld(chassis, p)
		return p
	end
	deco("Body", Vector3.new(7.2, 1.6, 15.2), CFrame.new(0, 1.2, 0), color, Enum.Material.SmoothPlastic)
	deco("Cabin", Vector3.new(6.4, 2.4, 7), CFrame.new(0, 3.2, 1), Color3.fromRGB(40, 55, 70), Enum.Material.Glass).Transparency = 0.25
	deco("Roof", Vector3.new(6.6, 0.4, 6.4), CFrame.new(0, 4.5, 1), color, Enum.Material.SmoothPlastic)
	for _, sx in { -2.4, 2.4 } do
		deco("Headlight", Vector3.new(1.4, 0.6, 0.2), CFrame.new(sx, 1.3, -7.65), Color3.fromRGB(255, 248, 220), Enum.Material.Neon)
		deco("Taillight", Vector3.new(1.4, 0.6, 0.2), CFrame.new(sx, 1.3, 7.65), Color3.fromRGB(200, 20, 20), Enum.Material.Neon)
	end

	for _, sx in { -3.3, 3.3 } do
		for _, sz in { -4.8, 4.8 } do
			local wheel = deco("Wheel", Vector3.new(1.2, 2.8, 2.8), CFrame.new(sx, -0.6, sz), Color3.fromRGB(25, 25, 25), Enum.Material.Rubber)
			wheel.Shape = Enum.PartType.Cylinder
			local skid = part(model, "Skid", Vector3.new(2.8, 2.8, 2.8), base * CFrame.new(sx * 0.9, -0.6, sz), Color3.new(0, 0, 0))
			skid.Shape = Enum.PartType.Ball
			skid.Transparency = 1
			skid.Massless = true
			skid.CustomPhysicalProperties = PhysicalProperties.new(0.5, 0, 0, 100, 1)
			weld(chassis, skid)
		end
	end

	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(2.4, 1, 2.4)
	seat.CFrame = base * CFrame.new(-1.4, 1.6, 1.2)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.Massless = true
	seat.HeadsUpDisplay = false
	seat.MaxSpeed = 0
	seat.Parent = model
	weld(chassis, seat)

	local att = Instance.new("Attachment")
	att.Name = "Drive"
	att.Parent = chassis
	local lv = Instance.new("LinearVelocity")
	lv.Name = "DriveVelocity"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.xAxis
	lv.SecondaryTangentAxis = Vector3.zAxis
	lv.PlaneVelocity = Vector2.zero
	lv.MaxForce = 60000
	lv.Parent = chassis
	local av = Instance.new("AngularVelocity")
	av.Name = "DriveTurn"
	av.Attachment0 = att
	av.RelativeTo = Enum.ActuatorRelativeTo.World
	av.AngularVelocity = Vector3.zero
	av.MaxTorque = 400000
	av.Parent = chassis

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Drive"
	prompt.ObjectText = "Car"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat
	prompt.Triggered:Connect(function(player)
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 and not seat.Occupant and not hum.SeatPart then
			seat:Sit(hum)
		end
	end)

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occ = seat.Occupant
		prompt.Enabled = occ == nil
		local player = occ and Players:GetPlayerFromCharacter(occ.Parent)
		if player then
			chassis:SetNetworkOwner(player)
		else
			lv.PlaneVelocity = Vector2.zero
			av.AngularVelocity = Vector3.zero
			if chassis:CanSetNetworkOwnership() then
				chassis:SetNetworkOwner(nil)
			end
		end
	end)

	model.Parent = parent or workspace
	return model
end

return Vehicles
