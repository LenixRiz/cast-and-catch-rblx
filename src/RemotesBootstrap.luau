-- RemotesBootstrap.server.lua
local RS = game:GetService("ReplicatedStorage")
local remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = RS

local function ensureRemote(name)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	return r
end

ensureRemote("Inventory_EquipRod")
ensureRemote("FishAssignSlot")      -- klik item di FishList
ensureRemote("EquipHotbarSlot")     -- klik slot 4..8
ensureRemote("FishHotbar_Update")   -- server -> client
