--!nocheck
-- On foot and behind the wheel: Shift to run, and arcade driving for the car you sit in
-- (W/S throttle and brake, A/D steer, Space to get out). Cars flipped on their roof
-- are put back on their wheels.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

local WALK, RUN = 16, 26
local MAX_FORWARD, MAX_REVERSE = 95, 30 -- studs per second
local ACCEL, BRAKE, DRAG = 38, 90, 14
local TURN_RATE = 1.7 -- radians per second at speed

local humanoid = nil
local function onCharacter(char)
	humanoid = char:WaitForChild("Humanoid")
	humanoid.WalkSpeed = WALK
end
if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.LeftShift and humanoid then
		humanoid.WalkSpeed = RUN
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift and humanoid then
		humanoid.WalkSpeed = WALK
	end
end)

local function approach(v, target, step)
	if v < target then
		return math.min(v + step, target)
	end
	return math.max(v - step, target)
end

RunService.Heartbeat:Connect(function(dt)
	local seat = humanoid and humanoid.SeatPart
	if not (seat and seat:IsA("VehicleSeat") and seat.Name == "DriverSeat") then
		return
	end
	local chassis = seat.Parent:FindFirstChild("Chassis")
	local lv = chassis and chassis:FindFirstChild("DriveVelocity")
	local av = chassis and chassis:FindFirstChild("DriveTurn")
	if not (lv and av) then
		return
	end
	local cf = chassis.CFrame
	if cf.UpVector.Y < 0.25 then
		local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		if look.Magnitude < 0.1 then
			look = Vector3.new(0, 0, -1)
		end
		chassis.CFrame = CFrame.lookAt(chassis.Position + Vector3.new(0, 5, 0), chassis.Position + Vector3.new(0, 5, 0) + look)
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
		return
	end
	local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z).Unit
	local speed = chassis.AssemblyLinearVelocity:Dot(fwd)
	local throttle = seat.ThrottleFloat
	local steer = seat.SteerFloat
	if throttle > 0 then
		speed = approach(speed, MAX_FORWARD, (if speed < 0 then BRAKE else ACCEL) * dt)
	elseif throttle < 0 then
		speed = approach(speed, -MAX_REVERSE, (if speed > 0 then BRAKE else ACCEL * 0.7) * dt)
	else
		speed = approach(speed, 0, DRAG * dt)
	end
	local grip = math.clamp(math.abs(speed) / 18, 0, 1)
	local direction = if speed >= 0 then 1 else -1
	local turn = -steer * TURN_RATE * grip * direction * (1 - 0.35 * math.clamp(math.abs(speed) / MAX_FORWARD, 0, 1))
	local v = fwd * speed
	lv.PlaneVelocity = Vector2.new(v.X, v.Z)
	av.AngularVelocity = Vector3.new(0, turn, 0)
end)
