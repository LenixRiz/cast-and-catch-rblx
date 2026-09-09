-- MoneyResetSystem.server.lua  (ServerScriptService)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local ServerStorage = game:GetService("ServerStorage")
local RodConfig = require(game.ServerScriptService:WaitForChild("RodConfig"))

-- DataStore untuk ownership rods (pakai nama yang sama dengan ShopServer.lua)
local OwnedDS = DataStoreService:GetDataStore("OwnedRods_V1")

local MASS_RESET_MAX = 200

-- === CONFIG: UserId admin yang boleh pakai UI ===
local ADMINS = {
	8852996612, -- ganti dengan UserId kamu
}

-- DataStore sesuai LeaderstatsScript kamu
local playerData = DataStoreService:GetDataStore("PlayerData")
local orderedDS  = DataStoreService:GetOrderedDataStore("TopMoney")

-- RemoteEvent (buat kalau belum ada)
local REMOTE = ReplicatedStorage:FindFirstChild("MoneyAdminRemote") :: RemoteEvent
if not REMOTE then
	local re = Instance.new("RemoteEvent")
	re.Name = "MoneyAdminRemote"
	re.Parent = ReplicatedStorage
	print("[MoneyAdmin] RemoteEvent created:", re:GetFullName())
end
local MoneyAdminRemote = ReplicatedStorage:WaitForChild("MoneyAdminRemote")

local Remotes = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder", ReplicatedStorage)
Remotes.Name = "Remotes"

local BE_AddRod = Remotes:FindFirstChild("Inventory_AddRodServer")
if not BE_AddRod or not BE_AddRod:IsA("BindableEvent") then
	if BE_AddRod then BE_AddRod:Destroy() end
	BE_AddRod = Instance.new("BindableEvent")
	BE_AddRod.Name = "Inventory_AddRodServer"
	BE_AddRod.Parent = Remotes
end

-- Util
local function isAdmin(plr)
	for _, id in ipairs(ADMINS) do
		if plr.UserId == id then return true end
	end
	return false
end

local function setMoneyOnline(plr, amount)
	amount = math.clamp(math.floor(tonumber(amount) or 0), 0, 2_000_000_000)
	-- root value (disimpan ke DS)
	local md = plr:FindFirstChild("MoneyData")
	if md then md.Value = amount end
	-- sinkron K$ kalau listener tidak sempat jalan
	local ls = plr:FindFirstChild("leaderstats")
	if ls then
		local k = ls:FindFirstChild("K$")
		if k and k.Value ~= amount then k.Value = amount end
	end
	-- simpan ke DS
	pcall(function()
		playerData:UpdateAsync(tostring(plr.UserId), function(old)
			old = old or {}
			old.Money = amount
			return old
		end)
	end)
	pcall(function()
		orderedDS:SetAsync("K$" .. plr.UserId, amount)
	end)
end

local function resetByUserId(userId, amount)
	amount = math.clamp(math.floor(tonumber(amount) or 0), 0, 2_000_000_000)
	-- set DS (offline/online)
	pcall(function()
		playerData:UpdateAsync(tostring(userId), function(old)
			old = old or {}
			old.Money = amount
			return old
		end)
	end)
	pcall(function()
		orderedDS:SetAsync("K$" .. userId, amount)
	end)
	-- kalau online, set juga live
	local online = Players:GetPlayerByUserId(userId)
	if online then setMoneyOnline(online, amount) end
end

-- Beri UI hanya ke admin saat join
Players.PlayerAdded:Connect(function(plr)
	if not isAdmin(plr) then return end
	-- kirimkan GUI dari ReplicatedStorage (dibuat client script-nya di bawah)
	local ui = ReplicatedStorage:FindFirstChild("AdminMoneyUI")
	if ui and ui:IsA("ScreenGui") then
		local clone = ui:Clone()
		clone.ResetOnSpawn = false
		clone.Parent = plr:WaitForChild("PlayerGui")
	else
		warn("[MoneyAdmin] AdminMoneyUI (ScreenGui) belum ada di ReplicatedStorage")
	end
end)

-- Reset semua userId yang tercatat di OrderedDataStore (TopMoney)
local function resetAllFromOrderedDS(amount, maxToReset)
	amount = math.clamp(math.floor(tonumber(amount) or 0), 0, 2_000_000_000)
	maxToReset = maxToReset or MASS_RESET_MAX

	local ok, pages = pcall(function()
		-- ascending/descending bebas untuk sweep
		return orderedDS:GetSortedAsync(true, 100)
	end)
	if not ok then
		warn("[MoneyAdmin] Gagal GetSortedAsync TopMoney")
		return
	end

	local processed = 0
	while pages and processed < maxToReset do
		local page = pages:GetCurrentPage()
		for _, entry in ipairs(page) do
			if processed >= maxToReset then break end
			local uid = tonumber(tostring(entry.key):match("^K%$(%d+)$"))
			if uid then
				resetByUserId(uid, amount)   -- sudah update PlayerData + TopMoney + online kalau ada
				processed += 1
				if processed % 25 == 0 then task.wait(0.2) end -- kecilkan tekanan ke DS
			end
		end
		if pages.IsFinished or processed >= maxToReset then break end
		local ok2, nxt = pcall(function() return pages:AdvanceToNextPageAsync() end)
		if not ok2 then break end
		pages = nxt
		task.wait(0.1)
	end
	print(("[MoneyAdmin] Reset massal: %d akun ? %d"):format(processed, amount))
end

-- ===== Helpers: ownership & starter sync =====

local function starterId()
	-- fallback ke entri pertama di RodConfig
	return (RodConfig.List and RodConfig.List[1] and RodConfig.List[1].id) or "black"
end

local function ownedFolder(plr: Player)
	local f = plr:FindFirstChild("OwnedRods")
	if not f then
		f = Instance.new("Folder")
		f.Name = "OwnedRods"
		f.Parent = plr
	end
	return f
end

local function setOwned(plr: Player, rodId: string, v: boolean)
	local f = ownedFolder(plr)
	local b = f:FindFirstChild(rodId)
	if not b then
		b = Instance.new("BoolValue")
		b.Name = rodId
		b.Parent = f
	end
	b.Value = v and true or false
end

local function getRodDataById(rodId: string)
	local data = (RodConfig.ById and RodConfig.ById[rodId])
	if not data then
		for _, d in ipairs(RodConfig.List or {}) do
			if d.id == rodId then data = d break end
		end
	end
	return data
end

-- ===== [ADD] Helper: normalisasi string (lower, tanpa spasi)
local function _norm(s) return (string.gsub(string.lower(s or ""), "%s+", "")) end

-- Contoh input yang diterima: "abysslantern", "Abyss Lantern"
local function resolveRodIdByKey(key: string): string?
	local k = _norm(key)
	-- match id dulu
	for _, d in ipairs(RodConfig.List or {}) do
		if d.id and _norm(d.id) == k then return d.id end
	end
	-- match displayName
	for _, d in ipairs(RodConfig.List or {}) do
		if _norm(d.displayName or "") == k then return d.id end
	end
	return nil
end

-- ===== [ADD] Cari Tool di ServerStorage/FishingRods (coba displayName, id, dan versi tanpa spasi)
local function findToolInPool(pool: Instance, data, rodId: string)
	-- 1) coba nama persis
	if data and data.displayName and pool:FindFirstChild(data.displayName) then
		return pool:FindFirstChild(data.displayName)
	end
	if rodId and pool:FindFirstChild(rodId) then
		return pool:FindFirstChild(rodId)
	end
	-- 2) coba normalisasi (tanpa spasi)
	local wants = {}
	if data and data.displayName then wants[_norm(data.displayName)] = true end
	if rodId then wants[_norm(rodId)] = true end
	for _, ch in ipairs(pool:GetChildren()) do
		if wants[_norm(ch.Name)] then return ch end
	end
	return nil
end

local function syncStarterGearWithOwned(plr: Player)
	-- (DISABLED) Kita tidak sinkron ke StarterGear agar hotbar default tidak muncul.
	-- Biarkan InventoryServer + UI yang pegang state.
end

local function addRodToUserOnline(plr: Player, rodId: string)
	local data = getRodDataById(rodId)
	if not data then
		warn(("[AdminAddRod] Rod data not found for id=%s"):format(tostring(rodId)))
		return
	end

	-- 1) tandai owned (folder BoolValue tetap dipakai Shop)
	setOwned(plr, rodId, true)

	-- 2) persist ke DataStore kepemilikan (biar konsisten dengan Shop)
	pcall(function()
		local key = "u:" .. plr.UserId
		OwnedDS:UpdateAsync(key, function(old)
			old = old or {}
			old[rodId] = true
			return old
		end)
	end)

	-- 3) (DISABLED) JANGAN clone tool ke Backpack / StarterGear
	-- syncStarterGearWithOwned(plr) -- tidak dipakai

	-- 4) BERITAHU InventoryServer agar UI langsung update
	BE_AddRod:Fire(plr, rodId)

	print(("[AdminAddRod] Marked owned + pushed to Inventory: %s -> %s"):format(plr.Name, rodId))
end

-- ===== [ADD] Tambah rod ke user OFFLINE: update DS saja
local function addRodToUserOffline(userId: number, rodId: string)
	pcall(function()
		local key = "u:" .. userId
		OwnedDS:UpdateAsync(key, function(old)
			old = old or {}
			old[rodId] = true
			return old
		end)
	end)
	print(("[AdminAddRod] DS updated for uid=%d rodId=%s"):format(userId, rodId))
end

-- hapus tools rod (berdasarkan nama yang ada di ServerStorage/FishingRods)
local function clearRodToolsFromInventory(plr: Player)
	local pool = ServerStorage:FindFirstChild("FishingRods")
	if not pool then return end
	local function isRodTool(x) return x:IsA("Tool") and pool:FindFirstChild(x.Name) ~= nil end
	for _, t in ipairs(plr.Backpack:GetChildren()) do
		if isRodTool(t) then t:Destroy() end
	end
	if plr.Character then
		for _, t in ipairs(plr.Character:GetChildren()) do
			if isRodTool(t) then t:Destroy() end
		end
	end
end

local function giveStarterNow(plr: Player)
	-- (DISABLED) Tidak memasukkan Tool ke Backpack.
	-- Starter tetap ditandai owned lewat BoolValue/DS; InventoryServer yang render UI.
end

local function resetPlayerRodsOnline(plr: Player)
	local sid = starterId()

	-- 1) clear OwnedRods kecuali starter
	local f = ownedFolder(plr)
	for _, ch in ipairs(f:GetChildren()) do
		if ch:IsA("BoolValue") and ch.Name ~= sid then
			ch:Destroy()
		end
	end
	if sid then setOwned(plr, sid, true) end

	-- 2) (DISABLED) StarterGear/Backpack tidak disentuh
	-- syncStarterGearWithOwned(plr)
	-- clearRodToolsFromInventory(plr)
	-- giveStarterNow(plr)

	-- 3) DS: simpan hanya starter
	if sid then
		pcall(function()
			OwnedDS:SetAsync("u:" .. plr.UserId, {[sid] = true})
		end)
	end

	-- 4) Beritahu InventoryServer supaya UI refresh (import starter)
	if sid then
		BE_AddRod:Fire(plr, sid)
	end

	print(("[AdminResetRods] %s -> starter=%s (Inventory pushed)"):format(plr.Name, tostring(sid)))
end


-- Reset rods untuk user OFFLINE: hanya update DataStore owned ? starter saja
local function resetPlayerRodsOffline(userId: number)
	local sid = starterId()
	pcall(function()
		OwnedDS:SetAsync("u:" .. userId, {[sid] = true})
	end)
end

-- Remote handler: semua perintah lewat sini (server-verified)
MoneyAdminRemote.OnServerEvent:Connect(function(sender, action, payload)
	if not isAdmin(sender) then return end
	action  = tostring(action or "")
	payload = payload or {}

	if action == "reset_selected" then
		local names  = payload.names
		local amount = tonumber(payload.amount) or 0
		if type(names) ~= "table" then return end
		for _, name in ipairs(names) do
			local p = Players:FindFirstChild(name)
			if p then setMoneyOnline(p, amount) end
		end

	elseif action == "reset_all_online" then
		local amount = tonumber(payload.amount) or 0
		-- 1) Online dulu
		for _, p in ipairs(Players:GetPlayers()) do
			setMoneyOnline(p, amount)
		end
		-- 2) Lanjut sapu DataStore
		resetAllFromOrderedDS(amount, MASS_RESET_MAX)

	elseif action == "reset_by_userid" then
		-- ? FIX: isi case reset uang by UserId
		local uid    = tonumber(payload.userId)
		local amount = tonumber(payload.amount) or 0
		if uid then resetByUserId(uid, amount) end

		-- ===== RODS: reset =====
	elseif action == "rods_reset_selected" then
		if type(payload) ~= "table" then return end
		for _, name in ipairs(payload.names or {}) do
			local p = Players:FindFirstChild(name)
			if p then resetPlayerRodsOnline(p) end
		end

	elseif action == "rods_reset_all_online" then
		for _, p in ipairs(Players:GetPlayers()) do
			resetPlayerRodsOnline(p)
		end

	elseif action == "rods_reset_by_userid" then
		-- ? FIX: hanya reset rods by UserId (tanpa menyentuh uang)
		local uid = tonumber(payload.userId)
		if not uid then return end
		local p = Players:GetPlayerByUserId(uid)
		if p then
			resetPlayerRodsOnline(p)
		else
			resetPlayerRodsOffline(uid)
		end

		-- ===== RODS: add (id/displayName lewat RodNameBox) =====
	elseif action == "rods_add_to_user" then
		payload = payload or {}
		local uid    = tonumber(payload.userId)
		local rodKey = tostring(payload.rod or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if not uid or rodKey == "" then
			warn("[AdminAddRod] Missing userId or rod key"); return
		end

		local rodId = resolveRodIdByKey(rodKey)
		if not rodId then
			warn("[AdminAddRod] Rod not found for key:", rodKey)
			return
		end

		local target = Players:GetPlayerByUserId(uid)
		if target then
			addRodToUserOnline(target, rodId)
		else
			addRodToUserOffline(uid, rodId)
		end
	end
end)