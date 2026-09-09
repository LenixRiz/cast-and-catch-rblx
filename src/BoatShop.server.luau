local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local DSS = game:GetService("DataStoreService")

local Catalog = require(RS:WaitForChild("BoatShop"):WaitForChild("BoatCatalog"))
local CollectionService = game:GetService("CollectionService")

-- Remotes
local RE_Buy   = RS:FindFirstChild("RE_BoatShop_Buy")   or Instance.new("RemoteEvent", RS)
RE_Buy.Name    = "RE_BoatShop_Buy"
local RE_Spawn = RS:FindFirstChild("RE_BoatShop_Spawn") or Instance.new("RemoteEvent", RS)
RE_Spawn.Name  = "RE_BoatShop_Spawn"
local RE_Res   = RS:FindFirstChild("RE_BoatShop_Result") or Instance.new("RemoteEvent", RS)
RE_Res.Name    = "RE_BoatShop_Result"

-- DataStore (beli sekali seumur hidup)
local BoatStore = DSS:GetDataStore("OwnedBoats_V1") -- { [userIdStr] = { [boatName]=true, ... } }
local OwnedCache = {}  -- cache di server: [userId] = dict

-- Helpers
local function send(plr, ok, code, boatName, text)
	-- code: "purchased"|"spawned"|"not_enough"|"wallet_missing"|"not_owned"|"template_missing"|"spawn_fail"|"notfound"
	RE_Res:FireClient(plr, ok, code, boatName, text or "")
end

local function getEntry(name)
	for _, e in ipairs(Catalog.entries) do
		if e.name == name then return e end
	end
end

local function findZonePartByName(zoneName: string?): BasePart?
	if not zoneName or zoneName == "" then return nil end
	local folder = workspace:FindFirstChild("SpawnBoat")  -- sesuai screenshot-mu
	if folder then
		local p = folder:FindFirstChild(zoneName)
		if p and p:IsA("BasePart") then return p end
	end
	-- fallback: cari recursive di Workspace (kalau dipindah lokasi)
	local p = workspace:FindFirstChild(zoneName, true)
	if p and p:IsA("BasePart") then return p end
	return nil
end

local function getSpawnCFByName(zoneName: string, plr: Player?)
	-- Coba di folder khusus dulu
	local folder = workspace:FindFirstChild(Catalog.spawnFolderName or "SpawnBoat")
	local part = nil
	if folder then
		part = folder:FindFirstChild(zoneName)
	end
	-- Fallback: cari recursive di Workspace kalau tidak ketemu
	if not part then
		part = workspace:FindFirstChild(zoneName, true)
	end
	if part and part:IsA("BasePart") then
		return part.CFrame * CFrame.new(0, 3, 0)
	end
	return nil
end

local function ensureWorkspaceFolder()
	local dst = workspace:FindFirstChild(Catalog.workspaceFolderName or "Boat")
	if not dst then
		dst = Instance.new("Folder")
		dst.Name = Catalog.workspaceFolderName or "Boat"
		dst.Parent = workspace
	end
	return dst
end

local function getSpawnCF()
	local folder = workspace:FindFirstChild(Catalog.spawnFolderName or "SpawnBoat")
	local part   = folder and folder:FindFirstChild(Catalog.spawnPartName or "ZoneSpawnBoat")
	if part and part:IsA("BasePart") then
		-- spawn sedikit di atas permukaan part, menghadap arah part
		return part.CFrame * CFrame.new(0, 3, 0)
	end
	return nil
end

local function isNumVal(v) return v and (v:IsA("IntValue") or v:IsA("NumberValue")) end

local function getWallet(plr)
	-- Utama MoneyData (IntValue di root), cadangan leaderstats "K$"
	local moneyData = plr:FindFirstChild("MoneyData")
	local ls = plr:FindFirstChild("leaderstats")
	local stat = ls and ls:FindFirstChild(Catalog.currencyName or "K$")
	local wallet = isNumVal(moneyData) and moneyData or (isNumVal(stat) and stat or nil)
	return wallet, moneyData, stat
end

local function anySeatOccupied(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Seat") or d:IsA("VehicleSeat") then
			if d.Occupant then return true end
		end
	end
	return false
end

local function enforceOwnerOnly(boat)
	local ownerId = boat:GetAttribute("OwnerUserId")
	local function hook(seat)
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local hum = seat.Occupant
			if hum then
				local plr = Players:GetPlayerFromCharacter(hum.Parent)
				if not plr or plr.UserId ~= ownerId then
					-- eject non-owner
					task.defer(function()
						pcall(function() hum.Sit = false end)
						pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
					end)
					if plr then
						send(plr, false, "not_owner", boat:GetAttribute("BoatName") or boat.Name, "Bukan perahu milikmu.")
					end
				end
			end
		end)
	end
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("Seat") or d:IsA("VehicleSeat") then hook(d) end
	end
	boat.DescendantAdded:Connect(function(d)
		if d:IsA("Seat") or d:IsA("VehicleSeat") then hook(d) end
	end)
end

local function attachAutoDespawn(boat)
	local timeout = Catalog.autoDespawnSeconds or 1800
	if timeout <= 0 then return end

	local lastUsed = os.clock()
	local function refreshOnOccupy(seat)
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			if seat.Occupant then lastUsed = os.clock() end
		end)
	end
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("Seat") or d:IsA("VehicleSeat") then refreshOnOccupy(d) end
	end
	boat.DescendantAdded:Connect(function(d)
		if d:IsA("Seat") or d:IsA("VehicleSeat") then refreshOnOccupy(d) end
	end)

	task.spawn(function()
		while boat.Parent do
			if anySeatOccupied(boat) then lastUsed = os.clock() end
			if os.clock() - lastUsed >= timeout then
				boat:Destroy()
				break
			end
			task.wait(15)
		end
	end)
end

local function clearPreviousBoats(ownerUserId)
	local folder = ensureWorkspaceFolder()
	for _, m in ipairs(folder:GetChildren()) do
		if m:IsA("Model") and m:GetAttribute("OwnerUserId") == ownerUserId then
			m:Destroy()
		end
	end
end

-- sebelumnya: local function spawnBoat(plr, boatName, template)
local function spawnBoat(plr: Player, boatName: string, template: Model, zoneName: string)
	local dstFolder = ensureWorkspaceFolder()

	local zonePart = findZonePartByName(zoneName)
	if not zonePart then
		return false, ("Zona '%s' tidak ditemukan"):format(tostring(zoneName))
	end

	-- clone
	local ok, boatOrErr = pcall(function() return template:Clone() end)
	if not ok or not boatOrErr or not boatOrErr:IsA("Model") then
		return false, "Clone gagal."
	end
	local boat: Model = boatOrErr
	boat.Parent = dstFolder
	boat.Name = ("%s_%d"):format(boatName, plr.UserId)
	boat:SetAttribute("BoatName", boatName)
	boat:SetAttribute("OwnerUserId", plr.UserId)

	-- PrimaryPart & ukuran untuk offset tinggi
	if not boat.PrimaryPart then
		boat.PrimaryPart = boat:FindFirstChildWhichIsA("BasePart", true)
	end
	local _, bSize = boat:GetBoundingBox()
	local upOffset = (zonePart.Size.Y * 0.5) + (bSize.Y * 0.5) + 0.5
	local targetCF = zonePart.CFrame * CFrame.new(0, upOffset, 0)

	boat:PivotTo(targetCF)

	-- network owner + anti-curi + auto-despawn (pakai fungsi yang sudah kamu punya)
	for _, bp in ipairs(boat:GetDescendants()) do
		if bp:IsA("BasePart") then pcall(function() bp:SetNetworkOwner(plr) end) end
	end
	enforceOwnerOnly(boat)
	attachAutoDespawn(boat)

	return true, "Spawned."
end

-- ====== Load/Save Owned Boats ======
local function loadOwned(plr)
	local key = tostring(plr.UserId)
	local ok, data = pcall(function() return BoatStore:GetAsync(key) end)
	local dict = (ok and data) or {}
	OwnedCache[plr.UserId] = dict

	-- mirror ke Folder agar client tahu (BUY ? SPAWN)
	local ownedFolder = plr:FindFirstChild("OwnedBoats") or Instance.new("Folder")
	ownedFolder.Name = "OwnedBoats"
	ownedFolder.Parent = plr
	for boatName, has in pairs(dict) do
		if has then
			local v = ownedFolder:FindFirstChild(boatName) or Instance.new("BoolValue")
			v.Name = boatName
			v.Value = true
			v.Parent = ownedFolder
		end
	end
end

local function saveOwned(plr)
	local dict = OwnedCache[plr.UserId] or {}
	local ok, err = pcall(function()
		BoatStore:SetAsync(tostring(plr.UserId), dict)
	end)
	if not ok then warn("[BoatShop] Save owned failed:", err) end
end

Players.PlayerAdded:Connect(loadOwned)
Players.PlayerRemoving:Connect(function(plr)
	clearPreviousBoats(plr.UserId)
	saveOwned(plr)
end)

-- ===== BUY =====
RE_Buy.OnServerEvent:Connect(function(plr, boatName)
	local entry = getEntry(boatName)
	if not entry then return send(plr, false, "notfound", boatName, "Boat tidak ditemukan.") end

	-- jika sudah punya, jangan potong saldo
	local dict = OwnedCache[plr.UserId] or {}
	if dict[boatName] then
		return send(plr, true, "purchased", boatName, "Kamu sudah memiliki boat ini. Gunakan tombol SPAWN.")
	end

	local wallet, moneyData, statVal = getWallet(plr)
	if not wallet then
		return send(plr, false, "wallet_missing", boatName,
			("Saldo tidak ditemukan (butuh 'MoneyData' atau leaderstats '%s')."):format(Catalog.currencyName or "K$"))
	end
	if wallet.Value < entry.price then
		return send(plr, false, "not_enough", boatName, "Uang tidak cukup.")
	end

	-- template ada?
	local srcFolder = RS:FindFirstChild(Catalog.sourceFolderNameRS or "Boat")
	local template = srcFolder and srcFolder:FindFirstChild(boatName)
	if not (template and template:IsA("Model")) then
		return send(plr, false, "template_missing", boatName,
			("Template '%s' tidak ada di ReplicatedStorage.%s"):format(boatName, Catalog.sourceFolderNameRS or "Boat"))
	end

	-- potong & tandai owned
	wallet.Value -= entry.price
	if moneyData and statVal and statVal ~= wallet and isNumVal(statVal) then
		statVal.Value = moneyData.Value
	end

	dict[boatName] = true
	OwnedCache[plr.UserId] = dict

	-- mirror ke Folder agar UI langsung ganti ke SPAWN
	local ownedFolder = plr:FindFirstChild("OwnedBoats") or Instance.new("Folder", plr)
	ownedFolder.Name = "OwnedBoats"
	local flag = ownedFolder:FindFirstChild(boatName) or Instance.new("BoolValue", ownedFolder)
	flag.Name = boatName
	flag.Value = true

	-- save (fire & forget)
	task.spawn(function() saveOwned(plr) end)

	return send(plr, true, "purchased", boatName, ("Berhasil membeli %s! (Gunakan tombol SPAWN)"):format(boatName))
end)

-- ===== SPAWN =====
RE_Spawn.OnServerEvent:Connect(function(plr, boatName, zoneName)
	local dict = OwnedCache[plr.UserId] or {}
	if not dict[boatName] then
		return send(plr, false, "not_owned", boatName, "Kamu belum memiliki boat ini.")
	end

	local srcFolder = RS:FindFirstChild(Catalog.sourceFolderNameRS or "Boat")
	local template = srcFolder and srcFolder:FindFirstChild(boatName)
	if not (template and template:IsA("Model")) then
		return send(plr, false, "template_missing", boatName, "Template tidak ada.")
	end

	clearPreviousBoats(plr.UserId)

	local ok, why = spawnBoat(plr, boatName, template, zoneName or "ZoneSpawnBoat")
	if ok then
		return send(plr, true, "spawned", boatName, ("Spawned di %s."):format(zoneName or "ZoneSpawnBoat"))
	else
		return send(plr, false, "spawn_fail", boatName, why or "Gagal spawn.")
	end
end)