-- ServerScriptService/ShopServer.lua
local RS = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local DSS = game:GetService("DataStoreService")
local DS_OWNED = DSS:GetDataStore("RodShop_Owned_v1")
local DS_EQUIP = DSS:GetDataStore("RodShop_Equip_v1") -- optional

local function getMoneyObj(plr)
	-- root MoneyData (yang kamu simpan ke DataStore)
	local root = plr:FindFirstChild("MoneyData")
	if root and root:IsA("IntValue") then return root end

	-- fallback ke leaderstats (K$ / Coins / Money / Gold)
	local ls = plr:FindFirstChild("leaderstats")
	if not ls then return nil end
	return ls:FindFirstChild("K$") or ls:FindFirstChild("Coins") or ls:FindFirstChild("Money") or ls:FindFirstChild("Gold")
end

-- ====== CONFIG ======
local USE_DATASTORE = true
local DS_NAME = "OwnedRods_V1"

-- ====== Remotes ======
local Remotes = RS:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = RS
end

local RF_GetData = Remotes:FindFirstChild("Shop_GetData")
if not RF_GetData then
	RF_GetData = Instance.new("RemoteFunction")
	RF_GetData.Name = "Shop_GetData"
	RF_GetData.Parent = Remotes
end

local RE_Buy = Remotes:FindFirstChild("Shop_Buy")
if not RE_Buy then
	RE_Buy = Instance.new("RemoteEvent")
	RE_Buy.Name = "Shop_Buy"
	RE_Buy.Parent = Remotes
end

-- setelah blok: local Remotes = ...
local BE_AddRodServer = Remotes:FindFirstChild("Inventory_AddRodServer")
if not BE_AddRodServer or not BE_AddRodServer:IsA("BindableEvent") then
	if BE_AddRodServer then BE_AddRodServer:Destroy() end
	BE_AddRodServer = Instance.new("BindableEvent")
	BE_AddRodServer.Name = "Inventory_AddRodServer"
	BE_AddRodServer.Parent = Remotes
end

-- ====== Rod config ======
local RodConfig = require(game.ServerScriptService:WaitForChild("RodConfig"))

-- Build index map: rodId -> idx
local RodIndexById = {}
for idx, data in ipairs(RodConfig.List or {}) do
	if data and data.id then
		RodIndexById[data.id] = idx
		data.index = idx -- set juga di table agar konsisten
	end
end

-- ====== Harga 1..9 (Black = 0, Abyss Lantern = 1.00M) ======
local PRICE_TABLE = {
	0,
	5000, --1
	10000, --2
	25000, --3
	45000, --4
	70000, --5
	120000, --6
	220000, --7
	850000, --8
	1000000, --9
}

local function computePrice(idx: number)
	if idx < 1 then idx = 1 end
	if idx > #PRICE_TABLE then idx = #PRICE_TABLE end
	return PRICE_TABLE[idx]
end


-- ====== Ownership storage (Folder per player) ======
local function ownedFolder(plr: Player): Folder
	local f = plr:FindFirstChild("OwnedRods")
	if not f then
		f = Instance.new("Folder")
		f.Name = "OwnedRods"
		f.Parent = plr
	end
	return f
end

local function hasOwned(plr: Player, rodId: string): boolean
	local f = ownedFolder(plr)
	local b = f:FindFirstChild(rodId)
	return b and b:IsA("BoolValue") and b.Value or false
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

-- id starter fallback
local function starterId()
	return (RodConfig.List and RodConfig.List[1] and RodConfig.List[1].id) or "black"
end

-- kasih Tool berdasarkan rodId (sekali saja)
local function giveToolById(plr: Player, rodId: string)
	local data = (RodConfig.ById and RodConfig.ById[rodId])
	if not data then
		for _, d in ipairs(RodConfig.List or {}) do
			if d.id == rodId then data = d break end
		end
	end
	if not data then return end

	-- buang duplikat dengan nama yang sama di Backpack/Character
	local nameA = data.displayName or rodId
	for _, t in ipairs(plr.Backpack:GetChildren()) do
		if t:IsA("Tool") and (t.Name == nameA or t.Name == rodId) then t:Destroy() end
	end
	if plr.Character then
		for _, t in ipairs(plr.Character:GetChildren()) do
			if t:IsA("Tool") and (t.Name == nameA or t.Name == rodId) then t:Destroy() end
		end
	end

	local pool = ServerStorage:FindFirstChild("FishingRods")
	if not pool then return end
	local src = pool:FindFirstChild(nameA) or pool:FindFirstChild(rodId)
	if src then src:Clone().Parent = plr.Backpack end
end

-- simpan & muat “rod ter-equip”
local function setEquipped(plr: Player, rodId: string)
	plr:SetAttribute("EquippedRod", rodId)
	pcall(function() DS_EQUIP:SetAsync("u_" .. plr.UserId, rodId) end)
end

local function loadEquipped(plr: Player): string
	local id: string? = nil
	pcall(function() id = DS_EQUIP:GetAsync("u_" .. plr.UserId) end)
	if not id or not hasOwned(plr, id) then id = starterId() end
	plr:SetAttribute("EquippedRod", id)
	return id
end

-- ====== (Opsional) DataStore persist ======
local OwnedDS = USE_DATASTORE and DataStoreService:GetDataStore(DS_NAME) or nil
local function loadOwned(plr: Player)
	if not USE_DATASTORE then return end
	local success, data = pcall(function()
		return OwnedDS:GetAsync("u:" .. plr.UserId)
	end)
	if success and typeof(data) == "table" then
		for rodId, val in pairs(data) do
			if val then setOwned(plr, rodId, true) end
		end
	end
end

local function saveOwned(plr: Player)
	if not USE_DATASTORE then return end
	local f = ownedFolder(plr)
	local payload = {}
	for _, ch in ipairs(f:GetChildren()) do
		if ch:IsA("BoolValue") and ch.Value then
			payload[ch.Name] = true
		end
	end
	pcall(function()
		OwnedDS:SetAsync("u:" .. plr.UserId, payload)
	end)
end

-- GANTI fungsi lama getMoneyObj() dengan ini:
local function getMoneyObjs(plr: Player)
	-- sumber utama (di root player)
	local rootMoney = plr:FindFirstChild("MoneyData")

	-- tampilan di leaderboard (Money/Coins/Gold/K$ didukung)
	local ls = plr:FindFirstChild("leaderstats")
	local statMoney = nil
	if ls then
		statMoney = ls:FindFirstChild("Money")
			or ls:FindFirstChild("Coins")
			or ls:FindFirstChild("Gold")
			or ls:FindFirstChild("K$")
	end
	return rootMoney, statMoney
end

-- ====== Cari rod by displayName (untuk Black Rod starter) ======
local function findRodByDisplayName(name: string)
	for i, d in ipairs(RodConfig.List or {}) do
		if d.displayName == name then
			return d, i
		end
	end
	return nil, nil
end

-- ambil data rod dari id
local function getRodDataById(rodId: string)
	local data = (RodConfig.ById and RodConfig.ById[rodId])
	if not data then
		for _, d in ipairs(RodConfig.List or {}) do
			if d.id == rodId then data = d break end
		end
	end
	return data
end

-- beri SEMUA tool yang dimiliki ke Backpack, tanpa duplikat
local function giveAllOwnedTools(plr: Player)
	local pool = ServerStorage:FindFirstChild("FishingRods")
	if not pool then return end

	-- hapus duplikat dulu (berdasar nama tool)
	local function clearToolByName(nameA: string)
		for _, t in ipairs(plr.Backpack:GetChildren()) do
			if t:IsA("Tool") and t.Name == nameA then t:Destroy() end
		end
		if plr.Character then
			for _, t in ipairs(plr.Character:GetChildren()) do
				if t:IsA("Tool") and t.Name == nameA then t:Destroy() end
			end
		end
	end

	for _, b in ipairs(ownedFolder(plr):GetChildren()) do
		if b:IsA("BoolValue") and b.Value then
			local id = b.Name
			local data = getRodDataById(id)
			if data then
				local nameA = data.displayName or id
				clearToolByName(nameA)
				local src = pool:FindFirstChild(nameA) or pool:FindFirstChild(id)
				if src then
					src:Clone().Parent = plr.Backpack
				end
			end
		end
	end
end


-- ====== Player lifecycle ======
Players.PlayerAdded:Connect(function(plr)
	loadOwned(plr)

	-- pastikan starter selalu dimiliki
	local first = RodConfig.List and RodConfig.List[1]
	if first and first.id and not hasOwned(plr, first.id) then
		setOwned(plr, first.id, true)
	end

	--load “equipped” (kalau kamu sudah buat fungsi loadEquipped; opsional)
	 loadEquipped(plr)

	--setiap respawn: berikan semua tool yang dimiliki
	plr.CharacterAdded:Connect(function()
		task.wait(0.25)
		-- (opsional) equip salah satu:
		local humanoid = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
		 if humanoid then
		     local want = (plr:GetAttribute("EquippedRod") and getRodDataById(plr:GetAttribute("EquippedRod")) or first)
		     local nameA = want and (want.displayName or want.id)
		     local tool = nameA and (plr.Backpack:FindFirstChild(nameA))
		    if tool then humanoid:EquipTool(tool) end
		 end
	end)
end)

Players.PlayerRemoving:Connect(function(plr)
	saveOwned(plr)
end)

-- ====== RemoteFunction: data untuk UI ======
RF_GetData.OnServerInvoke = function(plr: Player)
	local items = {}
	for idx, data in ipairs(RodConfig.List or {}) do
		table.insert(items, {
			id = data.id,
			displayName = data.displayName,
			luck = data.luck,
			speed = data.speed,
			weight = data.weight,
			price = computePrice(idx),
			owned = hasOwned(plr, data.id),
			icon = data.icon,
		})
	end
	local rootMoney, statMoney = getMoneyObjs(plr)
	local coins = (statMoney and statMoney.Value) or (rootMoney and rootMoney.Value) or 0
	return { items = items, coins = coins }
end

-- ====== Anti-spam cooldown ======
local lastBuyAt: {[Player]: number} = {}
local function canBuy(plr: Player)
	local now = os.clock()
	local last = lastBuyAt[plr] or 0
	if now - last < 0.5 then
		return false
	end
	lastBuyAt[plr] = now
	return true
end

-- Sinkronkan StarterGear dengan semua rod yang dimiliki
local function syncStarterGearWithOwned(plr: Player)
	local pool = ServerStorage:FindFirstChild("FishingRods")
	if not pool then return end

	-- Bersihkan rod tools lama dari StarterGear (biarkan item lain tetap)
	for _, it in ipairs(plr.StarterGear:GetChildren()) do
		if it:IsA("Tool") and (pool:FindFirstChild(it.Name)) then
			it:Destroy()
		end
	end

	-- Tambahkan semua rod yang dimiliki
	for _, b in ipairs(ownedFolder(plr):GetChildren()) do
		if b:IsA("BoolValue") and b.Value then
			local data = getRodDataById(b.Name)
			if data then
				local nameA = data.displayName or b.Name
				local src = pool:FindFirstChild(nameA) or pool:FindFirstChild(b.Name)
				if src then
					src:Clone().Parent = plr.StarterGear
				else
					warn(("[Shop] Tool source not found for '%s' (displayName='%s')"):format(b.Name, tostring(nameA)))
				end
			end
		end
	end
end


-- ====== RemoteEvent: pembelian ======
RE_Buy.OnServerEvent:Connect(function(plr: Player, rodId: string)
	print("Remote dipanggil dari", plr.Name)
	if typeof(rodId) ~= "string" then return end
	if not canBuy(plr) then return end

	-- Validasi rodId lewat RodConfig
	local data = RodConfig.ById and RodConfig.ById[rodId]
	if not data then
		local idxTmp = RodIndexById[rodId]
		if idxTmp then data = RodConfig.List[idxTmp] end
	end
	if not data then return end

	-- Cek belum dimiliki
	if hasOwned(plr, rodId) then return end

	-- Harga berdasarkan index
	local idx = RodIndexById[rodId]
	if not idx then
		for i, d in ipairs(RodConfig.List or {}) do
			if d == data or d.id == rodId then idx = i break end
		end
	end
	if not idx then return end

	local price = computePrice(idx)

	-- Ambil sumber uang
	local rootMoney, statMoney = getMoneyObjs(plr)
	local current = (rootMoney and rootMoney.Value) or (statMoney and statMoney.Value) or 0
	if current < price then return end

	-- Potong saldo
	if rootMoney then
		rootMoney.Value -= price
		if statMoney then statMoney.Value = rootMoney.Value end
	else
		if not statMoney then return end
		statMoney.Value -= price
	end

	-- Tandai owned (Shop tetap pegang status owned untuk tampilan di Shop)
	setOwned(plr, rodId, true)
	if USE_DATASTORE then saveOwned(plr) end

	-- >>> NEW: serahkan ke InventoryServer
	BE_AddRodServer:Fire(plr, rodId)

	-- (hapus kode lama yang clone tool ke Backpack / sync StarterGear)
end)
