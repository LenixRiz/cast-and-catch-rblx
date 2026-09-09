-- ?? InventoryFishHandler (No-Backpack, sync dengan InventoryServer)
-- Tujuan: Inventory UI = penyimpanan utama. Ikan TIDAK dimasukkan ke Backpack.
-- Saat join: load dari DataStore -> beri tahu InventoryServer lewat BindableEvent.
-- Saat leave: minta snapshot ke InventoryServer -> simpan ke DataStore.

local Players            = game:GetService("Players")
local DataStoreService   = game:GetService("DataStoreService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local HttpService        = game:GetService("HttpService")

local inventoryStore = DataStoreService:GetDataStore("PlayerFishInventory")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Bindable yang disediakan InventoryServer (server->server)
--  - Inventory_AddFishServer:Fire(player, fishIdOrTool, weight?)
--  - Inventory_GetFishSnapshot:Invoke(player) -> { {Name, Rarity, Weight, SellPrice}, ... }
local BE_AddFishServer = Remotes:WaitForChild("Inventory_AddFishServer") -- BindableEvent (HARUS bindable)
local BF_GetSnapshot   = Remotes:FindFirstChild("Inventory_GetFishSnapshot") -- BindableFunction (opsional)

-- Util
local function saveFishTable(userId: number, fishTable: table)
	local ok, err = pcall(function()
		inventoryStore:SetAsync("Fish_" .. userId, fishTable)
	end)
	if not ok then warn("[FishDS] save error:", err) end
end

local function loadFishTable(userId: number): table
	local ok, data = pcall(function()
		return inventoryStore:GetAsync("Fish_" .. userId)
	end)
	if ok and typeof(data) == "table" then
		return data
	end
	return {}
end

-- Saat player join: ambil dari DS, simpan ke attribute (untuk debug), lalu replay ke InventoryServer
Players.PlayerAdded:Connect(function(player)
	local savedFish = loadFishTable(player.UserId)

	-- simpan juga ke attribute (opsional, buat debug atau UI lain)
	pcall(function()
		player:SetAttribute("SavedFishData", HttpService:JSONEncode(savedFish))
	end)

	-- catatan: InventoryServer akan menambah ke data dan memunculkan FishBasket dummy
	for _, fish in ipairs(savedFish) do
		local name   = fish.Name
		local weight = tonumber(fish.Weight)
		BE_AddFishServer:Fire(player, name, weight)
	end
end)

-- Saat player keluar: minta snapshot ke InventoryServer lalu simpan ke DS
Players.PlayerRemoving:Connect(function(player)
	local fishData = {}

	-- Kalau InventoryServer menyediakan snapshot, pakai itu (akurat, termasuk qty terakhir)
	if BF_GetSnapshot and BF_GetSnapshot:IsA("BindableFunction") then
		local ok, snapshot = pcall(function()
			return BF_GetSnapshot:Invoke(player)
		end)
		if ok and typeof(snapshot) == "table" then
			fishData = snapshot
		end
	end

	-- Fallback: kalau tidak ada snapshot, pakai attribute terakhir (mungkin kurang mutakhir)
	if (#fishData == 0) then
		local encoded = player:GetAttribute("SavedFishData")
		if typeof(encoded) == "string" and #encoded > 0 then
			local ok, parsed = pcall(function() return HttpService:JSONDecode(encoded) end)
			if ok and typeof(parsed) == "table" then fishData = parsed end
		end
	end

	-- simpan
	saveFishTable(player.UserId, fishData)

	-- optional: perbarui attribute agar konsisten
	pcall(function()
		player:SetAttribute("SavedFishData", HttpService:JSONEncode(fishData))
	end)
end)
