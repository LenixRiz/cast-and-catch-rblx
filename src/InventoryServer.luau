-- InventoryServer.server.lua
-- Persist rods & fish ke DataStore + push UI + spawn active rod ke Backpack

local Players            = game:GetService("Players")
local RS                 = game:GetService("ReplicatedStorage")
local SSS                = game:GetService("ServerScriptService")
local ServerStorage      = game:GetService("ServerStorage")
local DataStoreService   = game:GetService("DataStoreService")
local HttpService       = game:GetService("HttpService")

local FishUtil = require(game.ReplicatedStorage.Shared.Util.FishUtil)

-- ==== FLAGS ====
local USE_ROBLOX_BACKPACK_FOR_INVENTORY = false
local SPAWN_FISH_AS_TOOLS_IN_BACKPACK   = false
-- di atas file (global), tambahkan sekali:
local ITEM_TOGGLE_BUSY: {[number]: boolean} = {}

-- ===== Remotes / Bindables (auto-ensure) =====
local Remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder", RS)
Remotes.Name = "Remotes"

-- Tambah BindableFunction untuk dipakai server lain (NPC, dsb)
local BF_SellAllFish = (function()
	local b = Remotes:FindFirstChild("Inventory_SellAllFish_Server")
	if not b then
		b = Instance.new("BindableFunction")
		b.Name = "Inventory_SellAllFish_Server"
		b.Parent = Remotes
	end
	return b
end)()

local function ensure(className: string, name: string)
	local r = Remotes:FindFirstChild(name)
	if r and r.ClassName ~= className then r:Destroy(); r = nil end
	if not r then r = Instance.new(className); r.Name = name; r.Parent = Remotes end
	return r
end

local RF_GetData     = ensure("RemoteFunction", "Inventory_GetData")
local RE_Push        = ensure("RemoteEvent",    "Inventory_Push")
local RE_EquipRod    = ensure("RemoteEvent",    "Inventory_EquipRod")
local RE_UseFish     = ensure("RemoteEvent",    "Inventory_UseFish")          -- optional (Use)
local BE_AddRod      = ensure("BindableEvent",  "Inventory_AddRodServer")     -- dipanggil Shop
local BE_AddFish     = ensure("BindableEvent",  "Inventory_AddFishServer")    -- dipanggil Fishing
local BE_RodHolsterUpdate = ensure("BindableEvent", "RodHolster_Update_Server")
local RE_ItemsAssign = ensure("RemoteEvent", "Items_AssignHotbar")
local ACTIVE_ITEM_SLOT4 = {}  -- [userId] = "Diving" | nil

-- ===== Config & sources =====
local RodConfig = nil
pcall(function() RodConfig = require(SSS:WaitForChild("RodConfig")) end)

-- Sumber template Tool ikan ada di ServerStorage/Tools/Fish
local FishToolsRoot = ServerStorage:WaitForChild("Tools"):WaitForChild("Fish")

-- Urutan bucket rarity yang dipakai di folder Tools/Fish
local RARITY_BUCKETS = { "Common", "Uncommon", "Rare", "Legendary", "Mythic" }

-- util kecil untuk normalisasi nama (hapus spasi, -, _; lowercase)
local function _normName(s: string): string
	s = string.lower(s or "")
	return (s:gsub("[%s_%-]+",""))
end

local RE_Assign = RS.Remotes:WaitForChild("FishAssignSlot")
local RE_Equip  = RS.Remotes:WaitForChild("EquipHotbarSlot")
local RE_Update = RS.Remotes:WaitForChild("FishHotbar_Update")

local SLOT_MIN, SLOT_MAX = 5, 8

local function iterFishHotbar(plr)
	local function yield(cont)
		if not cont then return end
		for _,it in ipairs(cont:GetChildren()) do
			if it:IsA("Tool") and it:GetAttribute("IsFishHotbar") == true then
				coroutine.yield(it)
			end
		end
	end
	return coroutine.wrap(function()
		yield(plr:FindFirstChildOfClass("Backpack"))
		yield(plr.Character)
	end)
end

local function toolIcon(tool: Tool)
	local handle = tool:FindFirstChild("Handle")
	if handle then
		local d = handle:FindFirstChildOfClass("Decal") or handle:FindFirstChildOfClass("Texture")
		if d and type(d.Texture)=="string" and d.Texture ~= "" then return d.Texture end
		if handle:IsA("MeshPart") and type(handle.TextureID)=="string" and handle.TextureID~="" then return handle.TextureID end
	end
	if type(tool.TextureId)=="string" and tool.TextureId~="" then return tool.TextureId end
	return ""
end

local function _clearAllHotbarFish(plr: Player)
	for it in iterFishHotbar(plr) do
		it:Destroy()
	end
end

-- ==== Items helpers ====
local function hasOwnedItem(plr: Player, id: string): boolean
	local f = plr:FindFirstChild("OwnedTools")
	local b = f and f:FindFirstChild(id)
	return b and b:IsA("BoolValue") and b.Value == true
end

local function findToolAnywhere(plr: Player, name: string): Tool?
	local char = plr.Character
	if char then
		local t = char:FindFirstChild(name)
		if t and t:IsA("Tool") then return t end
	end
	local bp = plr:FindFirstChildOfClass("Backpack")
	if bp then
		local t = bp:FindFirstChild(name)
		if t and t:IsA("Tool") then return t end
	end
	return nil
end

local function iterItemHotbar(plr)
	return coroutine.wrap(function()
		local function yieldFrom(cont)
			if not cont then return end
			for _,it in ipairs(cont:GetChildren()) do
				if it:IsA("Tool") and (it:GetAttribute("IsItemHotbar") == true) then
					coroutine.yield(it)
				end
			end
		end
		yieldFrom(plr:FindFirstChildOfClass("Backpack"))
		if plr.Character then yieldFrom(plr.Character) end
	end)
end

local function pushHotbarUpdate(plr)
	local map = {}

	-- ITEM SLOT 4
	local itemId = ACTIVE_ITEM_SLOT4[plr.UserId]
	if itemId then
		map[4] = { itemId = itemId }  -- client akan buat viewport dari ItemsModel
	end

	-- FISH SLOT 5..8 (kode kamu yang lama)
	for it in iterFishHotbar(plr) do
		local idx = tonumber(it:GetAttribute("HotbarSlot"))
		if idx and idx>=5 and idx<=8 then
			map[idx] = {
				fishId = it:GetAttribute("FishId") or it.Name,
				key    = it:GetAttribute("FishKey") or "",
				icon   = toolIcon(it) or ""
			}
		end
	end
	
	-- Slot 4 ? item (Diving) jika ada instancenya
	do
		local found = nil
		for it in iterItemHotbar(plr) do
			if it.Name == "Diving" then
				found = it
				break
			end
		end
		if found then
			map[4] = {
				itemId = "Diving",
				icon   = toolIcon(found) or "", -- kalau client pakai image; kalau viewport abaikan saja
			}
		end
	end

	RE_Update:FireClient(plr, map)
end

-- ===== DataStore =====
-- Pakai DS yang sudah kamu punya untuk rods & equipped (kompatibel ShopServer)
local DS_RODS   = DataStoreService:GetDataStore("OwnedRods_V1")      -- map { [rodId]=true }
local DS_EQUIP  = DataStoreService:GetDataStore("RodShop_Equip_v1")  -- string rodId aktif
local DS_FISH   = DataStoreService:GetDataStore("PlayerFishInventory_V3") -- array {id, weights={}, category}
local DS_ITEMS = DataStoreService:GetDataStore("OwnedItems_V1") -- map { [id]=true }

-- ===== State in-memory =====
-- STORE[uid] = {
--   rods=set{[id]=true}, orderRods=array, activeRodId=string?,
--   fish = map[id] = {weights = {2.1, 0.74, ...}, category="Common"}
-- }
local STORE: {[number]: any} = {}

-- === Single active fish tool (per player) ===
local ACTIVE_FISH_TOOL   : {[number]: Tool?}   = {}
local ACTIVE_FISH_KEY    : {[number]: string?} = {}

local function destroyActiveFish(plr: Player)
	local t = ACTIVE_FISH_TOOL[plr.UserId]
	if t and t.Parent then pcall(function() t:Destroy() end) end
	ACTIVE_FISH_TOOL[plr.UserId] = nil
	ACTIVE_FISH_KEY[plr.UserId]  = nil
end


-- ===== Save debounce =====
local SAVE_FLAGS: {[number]: {rods:boolean, fish:boolean}} = {}
local SAVE_LOCK:  {[number]: boolean} = {}

local function markDirty(plr: Player, what: "rods"|"fish")
	local f = SAVE_FLAGS[plr.UserId] or {rods=false,fish=false}
	f[what] = true
	SAVE_FLAGS[plr.UserId] = f
end

local function doSave(plr: Player)
	if SAVE_LOCK[plr.UserId] then return end
	local flags = SAVE_FLAGS[plr.UserId]
	if not flags or (not flags.rods and not flags.fish) then return end
	SAVE_LOCK[plr.UserId] = true

	local st = STORE[plr.UserId]
	if st then
		if flags.rods then
			-- persist rods map
			local payload = {}
			for id,owned in pairs(st.rods) do if owned then payload[id] = true end end
			pcall(function() DS_RODS:SetAsync("u:"..plr.UserId, payload) end)
			-- persist active
			pcall(function() DS_EQUIP:SetAsync("u_"..plr.UserId, st.activeRodId or "") end)
		end
		if flags.fish then
			-- persist fish as array: {id, weights={}, category}
			local arr = {}
			for id,info in pairs(st.fish) do
				table.insert(arr, {
					id = id,
					weights = table.clone(info.weights or {}),
					category = info.category or "Common",
				})
			end
			pcall(function() DS_FISH:SetAsync("Fish_"..plr.UserId, arr) end)
		end
	end

	SAVE_FLAGS[plr.UserId] = {rods=false,fish=false}
	SAVE_LOCK[plr.UserId] = false
end

local function scheduleSave(plr: Player, what: "rods"|"fish")
	markDirty(plr, what)
	task.delay(1.2, function()
		-- kalau masih dirty setelah 1.2s, save
		doSave(plr)
	end)
end

-- ===== Helpers =====
local function ensurePlayer(plr: Player)
	if STORE[plr.UserId] then return end
	STORE[plr.UserId] = { rods = {}, orderRods = {}, activeRodId = nil, fish = {} }
end

-- ===== Items (OwnedTools) =====
local ITEM_DISPLAY = {
	Diving = "Diving equipment",
}

local function ensureOwnedTools(plr: Player): Folder
	local f = plr:FindFirstChild("OwnedTools")
	if not f then
		f = Instance.new("Folder")
		f.Name = "OwnedTools"
		f.Parent = plr
	end
	return f
end

local function snapshotOwnedItems(plr: Player)
	local map = {}
	local f = plr:FindFirstChild("OwnedTools")
	if not f then return map end
	for _, ch in ipairs(f:GetChildren()) do
		if ch:IsA("BoolValue") and ch.Value == true then
			map[ch.Name] = true
		end
	end
	return map
end

local function loadOwnedItems(plr: Player)
	local f = ensureOwnedTools(plr)
	local ok, data = pcall(function()
		return DS_ITEMS:GetAsync("items_u_"..plr.UserId)
	end)
	local map = ok and data or {}
	if type(map) ~= "table" then map = {} end
	for id, v in pairs(map) do
		if v == true then
			local b = f:FindFirstChild(id) :: BoolValue?
			if not b then b = Instance.new("BoolValue"); b.Name = id; b.Parent = f end
			b.Value = true
		end
	end
end

local function saveOwnedItems(plr: Player)
	local map = snapshotOwnedItems(plr)
	pcall(function()
		DS_ITEMS:SetAsync("items_u_"..plr.UserId, map)
	end)
end

local function buildItemsListFromOwned(plr: Player)
	local list = {}
	local f = plr:FindFirstChild("OwnedTools")
	if not f then return list end
	for _, ch in ipairs(f:GetChildren()) do
		if ch:IsA("BoolValue") and ch.Value == true then
			local id = ch.Name
			table.insert(list, {
				id    = id,
				name  = ITEM_DISPLAY[id] or id,
				owned = true,
			})
		end
	end
	return list
end

-- === INVENTORY TOOL HELPERS ===
local function hasInventoryTool(plr: Player): boolean
	local bp = plr:FindFirstChildOfClass("Backpack")
	if bp and bp:FindFirstChild("Inventory") then return true end
	local char = plr.Character
	if char and char:FindFirstChild("Inventory") then return true end
	return false
end

local function findFishTool(rarity: string?, id: string): Tool?
	if not FishToolsRoot or type(id) ~= "string" or id == "" then return nil end
	local wantNorm = _normName(id)

	-- kalau ada rarity spesifik, coba di folder itu dulu
	if rarity and rarity ~= "" then
		if rarity == "Mythical" then rarity = "Mythic" end
		local bucket = FishToolsRoot:FindFirstChild(rarity)
		if bucket then
			-- exact match dulu
			local t = bucket:FindFirstChild(id)
			if t and t:IsA("Tool") then return t end
			-- lalu normalisasi
			for _, obj in ipairs(bucket:GetChildren()) do
				if obj:IsA("Tool") and _normName(obj.Name) == wantNorm then
					return obj
				end
			end
		end
	end

	-- scan semua bucket
	for _, bucket in ipairs(FishToolsRoot:GetChildren()) do
		if bucket:IsA("Folder") then
			local t = bucket:FindFirstChild(id)
			if t and t:IsA("Tool") then return t end
			for _, obj in ipairs(bucket:GetChildren()) do
				if obj:IsA("Tool") and _normName(obj.Name) == wantNorm then
					return obj
				end
			end
		end
	end
	return nil
end

local function firstFreeSlot(plr)
	local used = {}
	for it in iterFishHotbar(plr) do
		used[tonumber(it:GetAttribute("HotbarSlot"))] = true
	end
	for i=SLOT_MIN, SLOT_MAX do
		if not used[i] then return i end
	end
	return nil
end

-- REPLACE: hapus hanya instance tertentu (FishKey), bukan semua species
local function clearFishInstance(plr, fishKey)
	local removed = false
	for it in iterFishHotbar(plr) do
		if it:GetAttribute("FishKey") == fishKey then
			it:Destroy(); removed = true
		end
	end
	return removed
end

local function fishCategoryOf(id: string): string
	if not FishToolsRoot or type(id) ~= "string" or id == "" then return "Common" end
	-- exact di tiap bucket
	for _, cat in ipairs(RARITY_BUCKETS) do
		local folder = FishToolsRoot:FindFirstChild(cat)
		if folder and folder:FindFirstChild(id) then return cat end
	end
	-- fallback: normalisasi nama
	local want = _normName(id)
	for _, cat in ipairs(RARITY_BUCKETS) do
		local folder = FishToolsRoot:FindFirstChild(cat)
		if folder then
			for _, obj in ipairs(folder:GetChildren()) do
				if obj:IsA("Tool") and _normName(obj.Name) == want then
					return cat
				end
			end
		end
	end
	return "Common"
end

-- === FISH SCALE HELPERS (sama seperti rumus di FishingSystemServer) ===
local function _fishScaleFactor(weight: number, rarity: string): number
	local maxCapByRarity = {
		Common    = 2.0,
		Uncommon  = 2.2, -- baru
		Rare      = 2.4,
		Legendary = 2.8,
		Mythic   = 3.2
	}
	local base, perKg = 1.35, 1/60
	local cap = maxCapByRarity[rarity] or 3.0
	return math.clamp(base + (weight * perKg), 1.15, cap)
end

local function scaleFactorFrom(weight: number, rarity: string)
	local maxCapByRarity = {
		Common    = 2.0,
		Uncommon  = 2.2, -- baru
		Rare      = 2.4,
		Legendary = 2.8,
		Mythic   = 3.2
	}
	local base, perKg = 1.35, 1/60
	local cap = maxCapByRarity[rarity] or 3.0
	return math.clamp(base + (weight * perKg), 1.15, cap)
end

local function _applyFishScale(tool: Tool, scaleFactor: number)
	for _, d in ipairs(tool:GetDescendants()) do
		if d:IsA("MeshPart") then
			d.Size = d.Size * scaleFactor
			d.CanCollide = false
		elseif d:IsA("Part") then
			local sm = d:FindFirstChildOfClass("SpecialMesh")
			if sm then
				sm.Scale = sm.Scale * scaleFactor
				d.CanCollide = false
			end
		end
	end
end

RE_Assign.OnServerEvent:Connect(function(plr, payload)
	if type(payload) ~= "table" then return end

	-- key contoh: "Blue Tang#3"; species: "Blue Tang"
	local key     = tostring(payload.key or payload.instance or payload.id or "")
	if key == "" then return end
	local species = tostring(payload.species or payload.name or "")  -- kalau dikirim terpisah
	local spFromKey = key:match("^(.-)#%d+$")
	if species == "" then species = spFromKey or key end

	local rarity  = payload.rarity and tostring(payload.rarity) or fishCategoryOf(species)
	local weight  = tonumber(payload.weight) or nil


	-- toggle: kalau instance yg sama sudah ada ? hapus instance itu saja
	if clearFishInstance(plr, key) then
		pushHotbarUpdate(plr)
		return
	end

	-- cari slot kosong
	local slot = firstFreeSlot(plr); if not slot then return end

	-- ambil template dari species
	local src  = findFishTool(rarity, species) or findFishTool(nil, species)
	if not src then return end

	local tool = src:Clone()
	tool.Name = "FishHotbar_"..key
	tool:SetAttribute("IsFishHotbar", true)
	tool:SetAttribute("FishId",  species)   -- species (untuk grouping)
	tool:SetAttribute("FishKey", key)       -- identitas unik (instance)
	tool:SetAttribute("HotbarSlot", slot)
	tool:SetAttribute("CanBeDropped", false)
	if weight then tool:SetAttribute("Weight", weight) end
	if rarity then tool:SetAttribute("Rarity", rarity) end

	-- scaling sesuai berat/rarity (pakai helper yg sudah ada)
	if weight then
		local sf = scaleFactorFrom(weight, rarity or fishCategoryOf(species))
		_applyFishScale(tool, sf)
	end

	local bp = plr:FindFirstChildOfClass("Backpack"); if not bp then return end
	tool.Parent = bp

	pushHotbarUpdate(plr)
end)

-- Klik slot 4..8 ? equip/unequip
RE_Equip.OnServerEvent:Connect(function(plr, idx)
	if type(idx) ~= "number" then return end
	-- === SLOT 4: Item (Diving) ===
	if idx == 4 then
		local char = plr.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		local bp   = plr:FindFirstChildOfClass("Backpack")
		if not (char and hum and bp) then return end

		local inChar = char:FindFirstChild("Diving")
		local inBp   = bp:FindFirstChild("Diving")

		if inChar and inChar:IsA("Tool") then
			-- unequip ? balik ke Backpack (Tool.Unequipped akan cabut aksesori)
			inChar.Parent = bp
		elseif inBp and inBp:IsA("Tool") then
			hum:EquipTool(inBp)
		end

		pushHotbarUpdate(plr)
		return
	end

	-- === SLOT 5..8: IKAN (kode lama tetap) ===
	if idx < 5 or idx > 8 then return end
	local char = plr.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	for _,it in ipairs(char:GetChildren()) do
		if it:IsA("Tool") and it:GetAttribute("IsFishHotbar")==true and tonumber(it:GetAttribute("HotbarSlot"))==idx then
			it.Parent = plr:FindFirstChildOfClass("Backpack")
			pushHotbarUpdate(plr)
			return
		end
	end

	local bp = plr:FindFirstChildOfClass("Backpack"); if not bp then return end
	for _,it in ipairs(bp:GetChildren()) do
		if it:IsA("Tool") and it:GetAttribute("IsFishHotbar")==true and tonumber(it:GetAttribute("HotbarSlot"))==idx then
			pcall(function() hum:EquipTool(it) end)
			pushHotbarUpdate(plr)
			return
		end
	end
end)

-- optional: saat spawn, kirim keadaan awal (kosong)
Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function()
		task.defer(function() pushHotbarUpdate(plr) end)
	end)
end)

-- === GIVE INVENTORY TOOL (slot #2) ===
local function giveInventoryTool(plr: Player)
	if not USE_ROBLOX_BACKPACK_FOR_INVENTORY then
		return
	end
	task.spawn(function()
		local src = ServerStorage:FindFirstChild("Inventory")
		if not (src and src:IsA("Tool")) then
			return
		end

		-- tunggu Backpack siap
		local bp = plr:FindFirstChildOfClass("Backpack") or plr:WaitForChild("Backpack", 5)
		if not bp then
			return
		end

		-- hapus duplikat di Backpack/Character
		for _,c in ipairs(bp:GetChildren()) do
			if c:IsA("Tool") and c.Name=="Inventory" then c:Destroy() end
		end
		if plr.Character then
			for _,c in ipairs(plr.Character:GetChildren()) do
				if c:IsA("Tool") and c.Name=="Inventory" then c:Destroy() end
			end
		end

		-- kalau ternyata sudah ada (balapan dengan thread lain), stop
		if hasInventoryTool(plr) then return end

		-- clone ? Backpack
		local t = src:Clone()
		t.CanBeDropped = false
		t.RequiresHandle = false
		t.Parent = bp
	end)
end

local function ensureInventoryLater(plr: Player)
	if not USE_ROBLOX_BACKPACK_FOR_INVENTORY then
		return
	end
	-- coba sampai 20x tiap 0.25s (5 detik total) atau berhenti kalau sudah ada
	task.spawn(function()
		for _ = 1, 20 do
			if not plr.Parent then return end
			if hasInventoryTool(plr) then return end
			-- panggil pemberi tool (nanti kita replace fungsinya)
			pcall(function() giveInventoryTool(plr) end)
			task.wait(0.25)
			if hasInventoryTool(plr) then return end
		end
	end)
end

local function _getRodCfgById(id: string)
	if not RodConfig then return nil end
	if RodConfig.ById and RodConfig.ById[id] then return RodConfig.ById[id] end
	if RodConfig.List then
		for _,d in ipairs(RodConfig.List) do if d.id==id then return d end end
	end
	if RodConfig[id] then return RodConfig[id] end
	return nil
end

local function getRodStats(rodId: string)
	local t = _getRodCfgById(rodId)
	return {
		luck   = tonumber(t and (t.luck or t.Luck)) or 0,
		speed  = tonumber(t and (t.speed or t.Speed)) or 0,
		weight = tonumber(t and (t.weight or t.Weight)) or 0,
		displayName = (t and (t.displayName or t.DisplayName)) or rodId,
	}
end

local function resolveRodId(raw:string):string
	if not raw then return "" end
	local id = raw
	if id:lower():sub(-4) == "tool" then id = id:sub(1,#id-4) end
	if _getRodCfgById(id) then return id end
	if RodConfig and RodConfig.List then
		local low = id:lower()
		for _,d in ipairs(RodConfig.List) do
			if d.id and d.id:lower()==low then return d.id end
			if d.displayName and d.displayName:lower()==low then return d.id end
		end
	end
	for k,_ in pairs(RodConfig or {}) do
		if type(k)=="string" and k:lower()==id:lower() then return k end
	end
	return id
end

-- ===== Push to client =====
local function push(plr: Player)
	local st = STORE[plr.UserId]; if not st then return end

	-- rodsList
	local rodsList = {}
	if RodConfig and RodConfig.List then
		for _,d in ipairs(RodConfig.List) do
			if d.id and st.rods[d.id] then
				local s = getRodStats(d.id)
				table.insert(rodsList, {
					id = d.id, displayName = s.displayName,
					luck = s.luck, speed = s.speed, weight = s.weight, owned = true,
				})
			end
		end
	else
		for id,_ in pairs(st.rods) do
			local s = getRodStats(id)
			table.insert(rodsList, {
				id=id, displayName=s.displayName, luck=s.luck, speed=s.speed, weight=s.weight, owned=true,
			})
		end
	end

	-- fish per-item
	local fishList = {}
	for id,info in pairs(st.fish) do
		local ws = info.weights or {}
		for i, w in ipairs(ws) do
			table.insert(fishList, {
				id       = string.format("%s#%d", id, i),
				name     = id,
				weight   = tonumber(w) or 0,
				category = info.category or "Common",
			})
		end
	end

	-- items dari OwnedTools
	local itemsList = buildItemsListFromOwned(plr)

	RE_Push:FireClient(plr, {
		rods = rodsList,
		fish = fishList,
		items = itemsList,          -- <<<<<<<<<<<<<<<<<<<<<< tambahkan
		activeRodId = st.activeRodId
	})
end

-- Hapus semua rod tools di Backpack & Character
local function _clearRodTools(plr)
	local pool = ServerStorage:FindFirstChild("FishingRods")
	local function isRodTool(x)
		return x:IsA("Tool") and pool and pool:FindFirstChild(x.Name)
	end
	local bp = plr:FindFirstChildOfClass("Backpack")
	if bp then for _,t in ipairs(bp:GetChildren()) do if isRodTool(t) then t:Destroy() end end end
	if plr.Character then for _,t in ipairs(plr.Character:GetChildren()) do if isRodTool(t) then t:Destroy() end end end
end

local function _getOrCreateTipAttachment(tool: Tool): Attachment?
	-- PRIORITAS: Rod01 > RodTip > Handle > MeshPart/Part pertama
	local Rod01 = tool:FindFirstChild("Rod01", true) -- sesuai info: tip ada di MeshPart "Rod01"
	if Rod01 and Rod01:IsA("BasePart") then
		local a = Rod01:FindFirstChild("RodTipAttachment")
		if not a then
			a = Instance.new("Attachment")
			a.Name  = "RodTipAttachment"
			a.Parent = Rod01
			warn("[INV] RodTipAttachment dibuat di Rod01")
		end
		return a
	end

	-- fallback: node umum
	local tipPart = tool:FindFirstChild("RodTip", true)
		or tool:FindFirstChild("Tip", true)
		or tool:FindFirstChild("Handle", true)
	if tipPart and tipPart:IsA("BasePart") then
		local a = tipPart:FindFirstChild("RodTipAttachment")
		if not a then
			a = Instance.new("Attachment")
			a.Name  = "RodTipAttachment"
			a.Parent = tipPart
			warn("[INV] RodTipAttachment dibuat di "..tipPart:GetFullName())
		end
		return a
	end

	-- last resort: basepart/meshpart pertama
	local any = tool:FindFirstChildWhichIsA("BasePart", true)
	if any then
		local a = any:FindFirstChild("RodTipAttachment")
		if not a then
			a = Instance.new("Attachment")
			a.Name  = "RodTipAttachment"
			a.Parent = any
			warn("[INV] RodTipAttachment dibuat (fallback) di "..any:GetFullName())
		end
		return a
	end
	return nil
end

-- InventoryServer.lua — REPLACE: spawnActiveRodTool (versi fisch-simpel)
local function spawnActiveRodTool(plr: Player, rodId: string)
	if not rodId or rodId=="" then return end
	local pool = ServerStorage:FindFirstChild("FishingRods"); if not pool then return end

	-- resolve source tool
	local cfg = _getRodCfgById(rodId)
	local wantName = (cfg and (cfg.displayName or cfg.DisplayName)) or rodId
	local src = pool:FindFirstChild(wantName) or pool:FindFirstChild(rodId)
	if not src then warn("Rod tool src not found: "..tostring(rodId)); return end

	_clearRodTools(plr)

	local char = plr.Character or plr.CharacterAdded:Wait()
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if not (char and hum) then return end

	local tool: Tool = src:Clone()
	tool.CanBeDropped = false
	tool.RequiresHandle = tool:FindFirstChild("Handle") ~= nil
	tool:SetAttribute("IsFishingRod", true)
	tool:SetAttribute("RodId", rodId)

	-- pastikan ada Rod01.RodTipAttachment lalu simpan ref
	local rod01 = tool:FindFirstChild("Rod01", true)
	local tipAtt: Attachment? = nil
	if rod01 and rod01:IsA("BasePart") then
		tipAtt = rod01:FindFirstChild("RodTipAttachment")
		if not tipAtt then
			tipAtt = Instance.new("Attachment")
			tipAtt.Name = "RodTipAttachment"
			tipAtt.Parent = rod01
		end
	else
		-- fallback: basepart pertama
		local any = tool:FindFirstChildWhichIsA("BasePart", true)
		if any then
			tipAtt = any:FindFirstChild("RodTipAttachment")
			if not tipAtt then
				tipAtt = Instance.new("Attachment"); tipAtt.Name="RodTipAttachment"; tipAtt.Parent=any
			end
		end
	end

	-- buang ref lama, lalu buat TipAttachmentRef (wajib)
	do
		local old1 = tool:FindFirstChild("TipAttachmentRef"); if old1 then old1:Destroy() end
		local ref = Instance.new("ObjectValue")
		ref.Name = "TipAttachmentRef"
		ref.Value = tipAtt
		ref.Parent = tool
	end

	-- parent & equip
	tool.Parent = char
	pcall(function() hum:EquipTool(tool) end)

	-- safety: kalau engine sempat mindah ke Backpack, kembalikan, dan reassign ref (anti-race)
	task.defer(function()
		if tool.Parent and tool.Parent:IsA("Backpack") then
			tool.Parent = char
			pcall(function() hum:EquipTool(tool) end)
		end
		-- pastikan ref tetap valid (kalau ada rename/reparent internal)
		local rod01b = tool:FindFirstChild("Rod01", true)
		local tipb = rod01b and rod01b:FindFirstChild("RodTipAttachment")
		if tipb and tipb:IsA("Attachment") then
			local r = tool:FindFirstChild("TipAttachmentRef")
			if r and r:IsA("ObjectValue") then r.Value = tipb end
		end
	end)
end

-- ===== Mutators =====
local function addRod(plr: Player, toolOrId: any)
	ensurePlayer(plr)
	local raw = (typeof(toolOrId)=="Instance") and toolOrId.Name or tostring(toolOrId)
	local id  = resolveRodId(raw)
	local st  = STORE[plr.UserId]
	if not st.rods[id] then st.rods[id] = true end
	if not st.activeRodId then st.activeRodId = id end
	scheduleSave(plr, "rods")
	push(plr)
end

local function addFish(plr: Player, toolOrId: any, weight: number?)
	ensurePlayer(plr)
	local id = (typeof(toolOrId)=="Instance") and toolOrId.Name or tostring(toolOrId)
	local st = STORE[plr.UserId]
	local e = st.fish[id] or {weights={}, category=fishCategoryOf(id)}
	if weight and weight > 0 then
		table.insert(e.weights, weight)
	else
		table.insert(e.weights, 1)
	end
	e.category = e.category or fishCategoryOf(id)
	st.fish[id] = e
	scheduleSave(plr, "fish")
	push(plr)
end

local function getOwned(plr: Player, itemId: string): boolean
	local f = plr:FindFirstChild("OwnedTools")
	if not f then return false end
	local b = f:FindFirstChild(itemId)
	return b and b:IsA("BoolValue") and b.Value == true
end

-- ===== Remote handlers =====
RE_ItemsAssign.OnServerEvent:Connect(function(plr, payload)
	local itemId = (typeof(payload)=="table") and tostring(payload.itemId or payload.id or "") or tostring(payload)
	if itemId == "" then return end

	-- Saat ini kita support "Diving" saja
	if itemId ~= "Diving" then return end
	if not getOwned(plr, "Diving") then return end

	-- Cek apakah tool instance sudah ada (Backpack/Character)
	local bp   = plr:FindFirstChildOfClass("Backpack")
	local char = plr.Character
	if not bp then return end

	local existing = (char and char:FindFirstChild("Diving")) or bp:FindFirstChild("Diving")
	if existing and existing:IsA("Tool") then
		-- Toggle OFF ? hancurkan instance (kepemilikan tetap ada di OwnedTools)
		pcall(function() existing:Destroy() end)
		pushHotbarUpdate(plr)
		return
	end

	-- Toggle ON ? spawn tool dari ServerStorage.Tools.Diving ke Backpack
	local src = ServerStorage:FindFirstChild("Tools")
	src = src and src:FindFirstChild("Diving")
	if not (src and src:IsA("Tool")) then return end

	local t = src:Clone()
	t.CanBeDropped = false
	t:SetAttribute("IsItemHotbar", true)
	t:SetAttribute("HotbarSlot", 4)
	-- biar benar2 tercatat sebagai “item”, bukan ikan/rod
	t:SetAttribute("IsFishHotbar", false)
	t:SetAttribute("IsFishingRod", false)
	t.Parent = bp

	pushHotbarUpdate(plr)
end)

RF_GetData.OnServerInvoke = function(plr: Player)
	ensurePlayer(plr)
	local st = STORE[plr.UserId]

	-- rods
	local rodsList = {}
	if RodConfig and RodConfig.List then
		for _,d in ipairs(RodConfig.List) do
			if d.id and st.rods[d.id] then
				local s = getRodStats(d.id)
				table.insert(rodsList, {
					id=d.id, displayName=s.displayName, luck=s.luck, speed=s.speed, weight=s.weight, owned=true
				})
			end
		end
	else
		for id,_ in pairs(st.rods) do
			local s = getRodStats(id)
			table.insert(rodsList, {
				id=id, displayName=s.displayName, luck=s.luck, speed=s.speed, weight=s.weight, owned=true
			})
		end
	end

	-- fish per-item
	local fishList = {}
	for id,info in pairs(st.fish) do
		local ws = info.weights or {}
		for i, w in ipairs(ws) do
			table.insert(fishList, {
				id       = string.format("%s#%d", id, i),
				name     = id,
				weight   = tonumber(w) or 0,
				category = info.category or "Common",
			})
		end
	end

	return {
		rods = rodsList,
		fish = fishList,
		items = buildItemsListFromOwned(plr),  -- <<<<<< tambah ini
		activeRodId = st.activeRodId
	}
end

-- === FISH: spawn tool ke Backpack (target slot #3) ===
local function _findFishTemplate(fishId: string): Tool?
	if not FishToolsRoot or type(fishId) ~= "string" or fishId == "" then return nil end
	-- exact per bucket
	for _, cat in ipairs(RARITY_BUCKETS) do
		local folder = FishToolsRoot:FindFirstChild(cat)
		if folder then
			local t = folder:FindFirstChild(fishId)
			if t and t:IsA("Tool") then return t end
		end
	end
	-- fallback: normalisasi
	local want = _normName(fishId)
	for _, cat in ipairs(RARITY_BUCKETS) do
		local folder = FishToolsRoot:FindFirstChild(cat)
		if folder then
			for _, obj in ipairs(folder:GetChildren()) do
				if obj:IsA("Tool") and _normName(obj.Name) == want then
					return obj
				end
			end
		end
	end
	return nil
end

-- === HOTBAR HELPERS ===
local MAX_FISH_HOTBAR = 6  -- slot 3..8

local function _isFishToolInstance(x: Instance)
	if not (x and x:IsA("Tool")) then return false end
	return x:GetAttribute("Weight") ~= nil
		or x:GetAttribute("Sell_Price_Per_KG") ~= nil
		or x:GetAttribute("IsFishHotbar") == true         -- <<< tambahkan ini
end


local function _countFishToolsInBackpack(plr: Player): number
	local bp = plr:FindFirstChildOfClass("Backpack")
	if not bp then return 0 end
	local n = 0
	for _, t in ipairs(bp:GetChildren()) do
		if _isFishToolInstance(t) then n += 1 end
	end
	return n
end


local function _clearFishTools(plr: Player)
	local bp = plr:FindFirstChildOfClass("Backpack")
	if bp then
		for _, t in ipairs(bp:GetChildren()) do
			if _isFishToolInstance(t) then t:Destroy() end
		end
	end
	if plr.Character then
		for _, t in ipairs(plr.Character:GetChildren()) do
			if _isFishToolInstance(t) then t:Destroy() end
		end
	end
end

local function spawnFishInHand(plr: Player, fishId: string, weight: number, rarity: string): Tool?
	-- bersihkan sisa-sisa ikan di Char/Backpack agar pasti tunggal
	_clearFishTools(plr)

	local tpl = _findFishTemplate(fishId)
	if not tpl then
		return nil
	end

	local char = plr.Character or plr.CharacterAdded:Wait()
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if not (char and hum) then return nil end

	local tool = tpl:Clone()
	tool.CanBeDropped   = false
	tool.RequiresHandle = tool:FindFirstChild("Handle") ~= nil

	-- atribut + scale
	tool:SetAttribute("Weight", weight)
	tool:SetAttribute("Rarity", rarity)
	_applyFishScale(tool, _fishScaleFactor(weight, rarity))

	-- langsung ke Character (bukan Backpack)
	tool.Parent = char

	-- safety: kalau engine sempat taruh ke Backpack, balikin ke Character
	task.defer(function()
		if tool.Parent and tool.Parent:IsA("Backpack") then
			tool.Parent = char
		end
	end)

	return tool
end

-- Spawn 1 tool ikan ? DITAMBAHKAN ke Backpack (slot 3..8), TANPA equip
local function spawnFishTool(plr: Player, fishId: string, weight: number?)
	if not SPAWN_FISH_AS_TOOLS_IN_BACKPACK then
		return nil
	end
	
	local tpl = _findFishTemplate(fishId)
	if not tpl then
		return nil
	end

	-- Hitung ikan yang sudah ada di hotbar (slot 3..8)
	local existing = _countFishToolsInBackpack(plr)
	if existing >= MAX_FISH_HOTBAR then
		return nil
	end

	local bp = plr:FindFirstChildOfClass("Backpack")
	if not bp then return nil end

	-- Clone tool ikan + set atribut
	local tool = tpl:Clone()
	tool.CanBeDropped = false
	tool.Parent = bp   -- <<< urutan Parent menempati slot berikutnya

	local w = tonumber(weight) or 1
	tool:SetAttribute("Weight", w)
	-- ambil rarity dari template kalau ada; fallback ke folder
	local rarity = tpl:GetAttribute("Rarity") or fishCategoryOf(fishId)
	tool:SetAttribute("Rarity", rarity)

	-- APPLY SCALE (pakai rarity yang benar)
	local maxCapByRarity = {
		Common    = 2.0,
		Uncommon  = 2.2, -- baru
		Rare      = 2.4,
		Legendary = 2.8,
		Mythic   = 3.2
	}
	local base, perKg = 1.35, 1/60
	local cap  = maxCapByRarity[rarity] or 3.0
	local sf   = math.clamp(base + (w * perKg), 1.15, cap)

	for _, d in ipairs(tool:GetDescendants()) do
		if d:IsA("MeshPart") then
			d.Size = d.Size * sf
			d.CanCollide = false
		elseif d:IsA("Part") then
			local sm = d:FindFirstChildOfClass("SpecialMesh")
			if sm then
				sm.Scale = sm.Scale * sf
				d.CanCollide = false
			end
		end
	end

	return tool
end

-- Cari entry FishDB by id ATAU name (case-insensitive), sekaligus ketemu rarity-nya
local function _fishEntryById(idOrName)
	local key = string.lower(tostring(idOrName))
	for _, rarity in ipairs({ "Mythic","Legendary","Rare","Uncommon","Common" }) do
		local list = FishUtil.getFishList(rarity)
		for _, e in ipairs(list) do
			local idLower   = string.lower(tostring(e.id or ""))
			local nameLower = string.lower(tostring(e.name or ""))
			if idLower == key or nameLower == key then
				return e, rarity
			end
		end
	end
	return nil, nil
end

-- Ambil pricePerKg dari FishDB; fallback 10 jika tidak ketemu
local function _fishPricePerKg(idOrName)
	local entry = select(1, _fishEntryById(idOrName))
	return (entry and tonumber(entry.pricePerKg)) or 10
end

local function sellAllFishFor(plr: Player)
	ensurePlayer(plr)
	local st = STORE[plr.UserId]; if not st then return 0,0 end

	local total, count = 0, 0
	for id, info in pairs(st.fish) do
		local ws = info.weights or {}
		if #ws > 0 then
			local ppk = _fishPricePerKg(id)
			for _, w in ipairs(ws) do
				total += math.floor(ppk * (tonumber(w) or 0))
				count += 1
			end
		end
		st.fish[id] = nil
	end

	if total > 0 then
		local md = plr:FindFirstChild("MoneyData")
		if md then
			md.Value += total
			local ls = plr:FindFirstChild("leaderstats")
			if ls and ls:FindFirstChild("K$") then ls["K$"].Value = md.Value end
		else
			local ls = plr:FindFirstChild("leaderstats")
			if ls and ls:FindFirstChild("K$") then ls["K$"].Value += total end
		end
		_clearFishTools(plr)
		scheduleSave(plr, "fish")
		_clearAllHotbarFish(plr)  -- opsional
		pushHotbarUpdate(plr)
		push(plr)
	end

	return total, count
end

-- BindableFunction entry point (server?server)
BF_SellAllFish.OnInvoke = function(plr: Player)
	local total, count = sellAllFishFor(plr)
	destroyActiveFish(plr)
	return {total, count}
end

RE_EquipRod.OnServerEvent:Connect(function(plr: Player, rodOrPayload: any)
	ensurePlayer(plr)
	local st = STORE[plr.UserId]; if not st then return end

	-- normalisasi payload: terima string atau {rodId=...} (pertahankan false!)
	local rodId
	if typeof(rodOrPayload) == "table" then
		rodId = rawget(rodOrPayload, "rodId")  -- gunakan rawget agar nilai false tetap terbaca
	else
		rodId = rodOrPayload
	end
	-- === Toggle: UNEQUIP ===
	-- === Toggle: UNEQUIP ===
	if rodId == false or rodId == nil or rodId == "" then
		st.activeRodId = nil
		_clearRodTools(plr)
		if BE_RodHolsterUpdate then BE_RodHolsterUpdate:Fire(plr, false) end
		pcall(function() DS_EQUIP:SetAsync("u_"..plr.UserId, "") end)
		push(plr)
		return
	end

	if type(rodId) ~= "string" then return end
	rodId = resolveRodId(rodId)

	-- validasi kepemilikan
	if not st.rods[rodId] then return end

	-- jika sama dengan yang aktif ? cukup push (hindari spam/duplikat)
	if st.activeRodId == rodId then
		push(plr)
		return
	end

	-- set aktif + equip tool di tangan
	st.activeRodId = rodId
	spawnActiveRodTool(plr, rodId)

	-- beritahu holster server untuk copot/pasang aksesori punggung
	if BE_RodHolsterUpdate then
		BE_RodHolsterUpdate:Fire(plr, st.activeRodId or false)
	end

	-- persist + push UI
	pcall(function() DS_EQUIP:SetAsync("u_"..plr.UserId, rodId) end)
	push(plr)
end)

RE_UseFish.OnServerEvent:Connect(function(plr: Player, instanceKey: string)
	ensurePlayer(plr)
	local st = STORE[plr.UserId]; if not st then return end

	-- instanceKey format "FishId#index" (contoh Pufferfish#1)
	local fishId, idxStr = tostring(instanceKey or ""):match("^(.-)#(%d+)$")
	if not fishId then fishId = tostring(instanceKey or "") end

	local e = st.fish[fishId]
	if not e or type(e.weights) ~= "table" or #e.weights == 0 then return end

	local idx = tonumber(idxStr) or #e.weights
	local w   = tonumber(e.weights[idx]) or 1
	local rarity = e.category or fishCategoryOf(fishId)

	-- TOGGLE: kalau yang diklik sama dengan yang aktif -> matikan
	if ACTIVE_FISH_KEY[plr.UserId] == instanceKey then
		destroyActiveFish(plr)
		return
	end

	-- ganti ke yang baru (pastikan tunggal)
	destroyActiveFish(plr)
	local tool = spawnFishInHand(plr, fishId, w, rarity)
	if tool then
		ACTIVE_FISH_TOOL[plr.UserId] = tool
		ACTIVE_FISH_KEY[plr.UserId]  = instanceKey
		tool.Destroying:Connect(function()
			if ACTIVE_FISH_TOOL[plr.UserId] == tool then
				ACTIVE_FISH_TOOL[plr.UserId] = nil
				ACTIVE_FISH_KEY[plr.UserId]  = nil
			end
		end)
	end
end)

-- Bindables dari Shop/Fishing
BE_AddRod.Event:Connect(function(plr: Player, toolOrId: any) addRod(plr, toolOrId) end)
BE_AddFish.Event:Connect(function(plr: Player, toolOrId: any, weight: number?) addFish(plr, toolOrId, weight) end)

-- ===== Load / Save lifecycle =====
local function loadPlayer(plr: Player)
	ensurePlayer(plr)
	local st = STORE[plr.UserId]

	-- 1) RODS owned dari DataStore
	local ownedMap = {}
	pcall(function()
		ownedMap = DS_RODS:GetAsync("u:"..plr.UserId) or {}
	end)
	for id, v in pairs(ownedMap) do if v then st.rods[id] = true end end

	-- import juga dari folder OwnedRods (kalau ada), supaya sinkron dengan ShopServer
	local folder = plr:FindFirstChild("OwnedRods")
	if folder then
		for _,b in ipairs(folder:GetChildren()) do
			if b:IsA("BoolValue") and b.Value then st.rods[b.Name] = true end
		end
	end

	-- 2) ACTIVE rod dari DS_EQUIP (fallback ke rod pertama yang dimiliki)
	local active = nil
	pcall(function() active = DS_EQUIP:GetAsync("u_"..plr.UserId) end)
	if active and st.rods[active] then
		st.activeRodId = active
	else
		-- pilih pertama yang ada di RodConfig.List
		if RodConfig and RodConfig.List then
			for _,d in ipairs(RodConfig.List) do
				if d.id and st.rods[d.id] then st.activeRodId = d.id; break end
			end
		end
		-- fallback apapun
		if not st.activeRodId then
			for id,_ in pairs(st.rods) do st.activeRodId = id break end
		end
	end

	-- 3) FISH dari DS_FISH
		-- 3) FISH dari DS_FISH (V3). Jika ketemu format lama (V2), migrasikan.
		local fishArr = nil
		pcall(function() fishArr = DS_FISH:GetAsync("Fish_"..plr.UserId) end)
		if type(fishArr)=="table" then
			for _, row in ipairs(fishArr) do
				if row and row.id then
					local weights = {}
					-- V3
					if type(row.weights)=="table" then
						weights = row.weights
						-- V2 (qty + lastWeight) -> migrasi: duplikasi berat terakhir sebanyak qty
					elseif row.qty and row.lastWeight then
						local q = tonumber(row.qty) or 0
						local w = tonumber(row.lastWeight) or 0
						for i=1, math.max(0,q) do table.insert(weights, w) end
					end
					if #weights > 0 then
						st.fish[row.id] = {
							weights = weights,
							category = tostring(row.category or fishCategoryOf(row.id)),
						}
					end
				end
			end
		end

	if st.activeRodId then
		task.defer(function()
			_clearRodTools(plr)
			spawnActiveRodTool(plr, st.activeRodId)
		end)
	end
	-- dorong UI awal
	push(plr)
end

Players.PlayerAdded:Connect(function(plr)
	loadPlayer(plr)
	
	-- Load kepemilikan Items dari DS
	loadOwnedItems(plr)

	-- Simpan otomatis kalau OwnedTools berubah
	local ownedFolder = ensureOwnedTools(plr)
	local function _saveOwnedDebounced()
		task.defer(function() saveOwnedItems(plr) end)
	end
	ownedFolder.ChildAdded:Connect(function(obj)
		if obj:IsA("BoolValue") then
			obj.Changed:Connect(function(prop)
				if prop == "Value" then _saveOwnedDebounced(); pushHotbarUpdate(plr) end
			end)
			_saveOwnedDebounced(); pushHotbarUpdate(plr)
		end
	end)
	ownedFolder.ChildRemoved:Connect(function()
		_saveOwnedDebounced(); pushHotbarUpdate(plr)
	end)

	-- Inisialisasi attribute assignment slot 4
	if plr:GetAttribute("ItemSlot4") == nil then
		plr:SetAttribute("ItemSlot4", "")
	end

	-- Refresh kalau OwnedTools berubah (mis. baru beli Diving)
	local ownedFolder = plr:FindFirstChild("OwnedTools") or Instance.new("Folder")
	ownedFolder.Name = "OwnedTools"
	ownedFolder.Parent = plr
	ownedFolder.ChildAdded:Connect(function(obj)
		if obj:IsA("BoolValue") and obj.Name == "Diving" and obj.Value == true then
			-- opsional: auto-assign pertama kali
			if tostring(plr:GetAttribute("ItemSlot4") or "") == "" then
				plr:SetAttribute("ItemSlot4", "Diving")
			end
			pushHotbarUpdate(plr)
		end
	end)
	ownedFolder.ChildRemoved:Connect(function()
		if tostring(plr:GetAttribute("ItemSlot4") or "") == "Diving" and not hasOwnedItem(plr,"Diving") then
			plr:SetAttribute("ItemSlot4","")
		end
		pushHotbarUpdate(plr)
	end)


	-- ?? Backpack Guard: cegah rod nongol di Backpack / adu parent
	task.defer(function()
		local bp = plr:WaitForChild("Backpack")

		bp.ChildAdded:Connect(function(child)
			if not (child and child:IsA("Tool")) then return end

			-- identifikasi rod
			local pool = ServerStorage:FindFirstChild("FishingRods")
			local isRod = child:GetAttribute("IsFishingRod") == true or (pool and pool:FindFirstChild(child.Name) ~= nil)
			if not isRod then return end

			-- beri kesempatan 0.35s untuk proses EquipTool
			task.delay(0.35, function()
				if not child.Parent or not child.Parent:IsA("Backpack") then return end
				local st = STORE[plr.UserId]
				if not (st and st.activeRodId) then
					-- biarkan saja di Backpack (jangan destroy). Player bisa unequip memang.
					return
				end
				-- kalau masih di Backpack, pindahkan sopan2 ke Character
				local char = plr.Character
				local hum  = char and char:FindFirstChildOfClass("Humanoid")
				if char and hum and child.Parent == bp and not char:FindFirstChild(child.Name) then
					child.Parent = char
					pcall(function() hum:EquipTool(child) end)
					warn("[INV] BackpackGuard: pindahkan", child.Name, "ke Character setelah grace period")
				end
			end)
		end)
	end)

	-- Equip ulang saat respawn
	plr.CharacterAdded:Connect(function()
		task.defer(function()
			local st = STORE[plr.UserId]
			if not (st and st.activeRodId) then return end
			_clearRodTools(plr)
			spawnActiveRodTool(plr, st.activeRodId)
		end)
	end)
end)


Players.PlayerRemoving:Connect(function(plr)
	-- simpan keduanya
	markDirty(plr, "rods"); markDirty(plr, "fish")
	doSave(plr)
	saveOwnedItems(plr)
	STORE[plr.UserId] = nil
	SAVE_FLAGS[plr.UserId] = nil
	SAVE_LOCK[plr.UserId]  = nil
	destroyActiveFish(plr)
	ACTIVE_FISH_TOOL[plr.UserId] = nil
	ACTIVE_FISH_KEY[plr.UserId]  = nil
end)
