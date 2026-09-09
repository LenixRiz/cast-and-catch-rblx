-- TimeSystem (Script) - Real Time Version (sesuai jam PC)

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- RemoteEvent untuk kirim waktu ke client
local timeEvent = ReplicatedStorage:FindFirstChild("TimeUpdated")
if not timeEvent then
	timeEvent = Instance.new("RemoteEvent")
	timeEvent.Name = "TimeUpdated"
	timeEvent.Parent = ReplicatedStorage
end

-- Deteksi pergantian waktu
local lastMinute = -1
local isNight = false

-- ?? Update pencahayaan siang/malam
local function updateLightingByTime(hour)
	if hour >= 18 or hour < 6 then
		if not isNight then
			isNight = true
			Lighting.Ambient = Color3.fromRGB(60, 60, 70)
			Lighting.OutdoorAmbient = Color3.fromRGB(90, 90, 100)
			Lighting.EnvironmentDiffuseScale = 0.5
			Lighting.EnvironmentSpecularScale = 0.5
		end
	else
		if isNight then
			isNight = false
			Lighting.Ambient = Color3.fromRGB(105, 105, 105)
			Lighting.OutdoorAmbient = Color3.fromRGB(140, 140, 140)
			Lighting.EnvironmentDiffuseScale = 0.5
			Lighting.EnvironmentSpecularScale = 0.5
		end
	end
end

-- ?? Update waktu dan lighting tiap frame
RunService.Heartbeat:Connect(function()
	local now = os.date("*t")
	local TIMEZONE_OFFSET = 7
	local hour = (now.hour + TIMEZONE_OFFSET) % 24
	local minute = now.min
	local second = now.sec

	local clockTime = hour + (minute / 60) + (second / 3600)
	Lighting.ClockTime = clockTime
	updateLightingByTime(hour)

	-- Broadcast waktu jika berubah
	if minute ~= lastMinute then
		lastMinute = minute
		local timeString = string.format("%02d:%02d", hour, minute)
		timeEvent:FireAllClients(timeString)
	end
end)

-- ????? Kirim jam ke player saat masuk
Players.PlayerAdded:Connect(function(player)
	local now = os.date("*t")
	local TIMEZONE_OFFSET = 7
	local hour = (now.hour + TIMEZONE_OFFSET) % 24
	local minute = now.min
	local timeString = string.format("%02d:%02d", hour, minute)
	timeEvent:FireClient(player, timeString)
end)
