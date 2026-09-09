game.ReplicatedStorage:WaitForChild("RemoteEvents"):WaitForChild("DeviceCheck").OnServerEvent:Connect(function(player, deviceType)
	local tag = Instance.new("StringValue")
	tag.Name = "UserInputType"
	tag.Value = tostring(deviceType) -- ? Convert to string
	tag.Parent = player
end)
