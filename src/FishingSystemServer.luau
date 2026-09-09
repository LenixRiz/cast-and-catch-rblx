-- === Services ===
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local PhysicsService    = game:GetService("PhysicsService")
local HttpService       = game:GetService("HttpService")

-- === Helpers ===
local function _req(modInst: Instance, path: string)
	if not modInst then
		error("[FishingSystemServer] Module not found: "..path, 2)
	end
	if not modInst:IsA("ModuleScript") then
		error(("[FishingSystemServer] Expected ModuleScript at %s, got %s")
			:format(path, modInst.ClassName), 2)
	end
	return require(modInst)
end

-- === Paths ===
local RS          = ReplicatedStorage
local Shared      = RS:WaitForChild("Shared")            -- Folder
local Config      = Shared:WaitForChild("Config")        -- Folder
local Modules     = Shared:WaitForChild("Modules")       -- Folder

-- === Required modules (AMAN) ===
local FishingShared = _req(RS:WaitForChild("FishingShared"), "ReplicatedStorage/FishingShared")
local Remotes       = RS:WaitForChild("Remotes")
local BeamStyles = require(ReplicatedStorage.Shared.Modules.BeamStyles)

-- Zone & Pool
local ZoneService   = _req(game.ServerScriptService:WaitForChild("ZoneService"), "ServerScriptService/ZoneService")
local FishPool      = _req(Modules:WaitForChild("FishPool"), "ReplicatedStorage/Shared/Modules/FishPool")

-- Config opsional
local okRC, RodConfig = pcall(function() return _req(game.ServerScriptService:WaitForChild("RodConfig"), "ServerScriptService/RodConfig") end)
if not okRC then RodConfig = {} end

-- Tools ikan di ServerStorage (BUKAN RS.Fishes)
local FishToolsRoot = ServerStorage:WaitForChild("Tools"):WaitForChild("Fish")

local DEBUG_MINIGAME_EASY   = true   -- bikin minigame super gampang (sementara)
local DEBUG_AUTOCATCH_AFTER = 4      -- detik; auto-catch jika FinishFishing tidak datang (0 = nonaktif)

-- Shared config modules (baru)
local FishDB        = require(ReplicatedStorage.Shared.Config.FishDB)
local RarityConfig  = require(ReplicatedStorage.Shared.Config.RarityConfig)
local EconomyConfig = (function()
	local ok, cfg = pcall(function() return require(ReplicatedStorage.Shared.Config.EconomyConfig) end)
	return ok and cfg or { BaseSellMultiplier = 1.0 }
end)()
local FishUtil      = require(ReplicatedStorage.Shared.Util.FishUtil)

-- ==================================
--  Physics one-time setup
-- ==================================
local HOOK_GROUP = "Hook"
local __hookReady = false
local function ensureHookCollisionGroup()
	if __hookReady then return end
	pcall(function() PhysicsService:RegisterCollisionGroup(HOOK_GROUP) end)

	-- Izinkan tabrak Default & Terrain, ignore Characters
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(HOOK_GROUP, "Default",  true)
		PhysicsService:CollisionGroupSetCollidable(HOOK_GROUP, "Terrain",  true)
		PhysicsService:CollisionGroupSetCollidable(HOOK_GROUP, "Characters", false)
	end)

	__hookReady = true
end

-- ==================
--  STATE PER PLAYER
-- ==================
local P = {}
local function st(plr)
	local s = P[plr]
	if not s then
		s = { fishing=false, session=0, lastStart=0, hookConn=nil, pools = {}, activeKey = nil }
		P[plr] = s
	else
		s.pools = s.pools or {}
	end
	return s
end

-- Centralized helper to avoid leaked Heartbeat connections
local function disconnectHookConn(plr)
	local s = st(plr)
	if s.hookConn then
		local ok = pcall(function() s.hookConn:Disconnect() end)
		s.hookConn = nil
	end
end

-- ==================
--  HELPERS ROD & TIP
-- ==================
local function isSwimmingOrInWater(plr: Player): boolean
	local char = plr.Character
	if not char then return false end
	local hum  = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then return false end
	if hum:GetState() == Enum.HumanoidStateType.Swimming then return true end

	local rp = RaycastParams.new()
	rp.IgnoreWater = false
	rp.FilterType  = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(root.Position + Vector3.new(0,60,0), Vector3.new(0,-1,0)*180, rp)
	if hit and hit.Material == Enum.Material.Water then
		return root.Position.Y <= (hit.Position.Y + 1.0)
	end
	return false
end

local function getRodCfgFromTool(rod: Tool?)
	if not rod then return nil end
	if RodConfig.Get then return RodConfig.Get(rod.Name) end
	if RodConfig.ByName then return RodConfig.ByName[string.lower(rod.Name)] end
	return nil
end

local function ensureRodInCharacter(plr: Player): Tool?
	local char = plr.Character; if not char then return nil end
	local hum  = char:FindFirstChildOfClass("Humanoid")

	-- Sudah ada rod aktif?
	for _, inst in ipairs(char:GetChildren()) do
		if inst:IsA("Tool") and (inst:GetAttribute("IsFishingRod") or getRodCfgFromTool(inst)) then
			return inst
		end
	end

	local bp = plr:FindFirstChildOfClass("Backpack"); if not bp then return nil end
	local cand: Tool? = nil
	for _, t in ipairs(bp:GetChildren()) do
		if t:IsA("Tool") and (t:GetAttribute("IsFishingRod") or getRodCfgFromTool(t)) then
			if t:FindFirstChild("RodTipAttachment", true) then cand = t break end
			if not cand then cand = t end
		end
	end
	if not cand then return nil end

	if cand.Parent ~= bp then cand.Parent = bp; task.wait() end
	if hum then pcall(function() hum:EquipTool(cand) end) end
	task.wait()
	return cand
end

-- Cari Attachment "RodTipAttachment". Kalau tidak ada: BUAT di Rod01 (fallback ke Handle/BasePart lain).
local function ensureTipAttachmentServer(rod: Tool?): Attachment?
	if not (rod and rod:IsA("Tool")) then return nil end

	-- cache cepat
	local ref = rod:FindFirstChild("TipAttachmentRef")
	if ref and ref:IsA("ObjectValue") and ref.Value and ref.Value.Parent and ref.Value:IsA("Attachment") then
		return ref.Value
	end

	-- sudah ada?
	local found = rod:FindFirstChild("RodTipAttachment", true)
	if found and found:IsA("Attachment") and found.Parent and found.Parent:IsA("BasePart") then
		local r = ref or Instance.new("ObjectValue")
		r.Name="TipAttachmentRef"; r.Parent=rod; r.Value=found
		return found
	end

	-- tidak ada? BUAT.
	local basePart
	do
		local rod01 = rod:FindFirstChild("Rod01", true)
		if rod01 and rod01:IsA("BasePart") then basePart = rod01 end
		if not basePart then
			local handle = rod:FindFirstChild("Handle", true)
			if handle and handle:IsA("BasePart") then basePart = handle end
		end
		if not basePart then
			for _, d in ipairs(rod:GetDescendants()) do
				if d:IsA("BasePart") then basePart = d; break end
			end
		end
	end
	if not basePart then return nil end

	local att = Instance.new("Attachment")
	att.Name = "RodTipAttachment"
	att.Parent = basePart
	-- letakkan agak ke ujung visual (aman & konsisten)
	local offset = CFrame.new(0, 0, -(basePart.Size.Z * 0.5 - 0.05))
	att.WorldCFrame = basePart.CFrame * offset

	local r = ref or Instance.new("ObjectValue")
	r.Name="TipAttachmentRef"; r.Parent=rod; r.Value=att
	return att
end

local function getEquippedRod(player: Player): Tool?
	local char = player.Character
	if not char then return nil end
	for _, inst in ipairs(char:GetChildren()) do
		if inst:IsA("Tool") and (inst:GetAttribute("IsFishingRod") == true or getRodCfgFromTool(inst) ~= nil) then
			return inst
		end
	end
	return nil
end

local function getTipAttachment(plr: Player): Attachment?
	local char = plr.Character; if not char then return nil end
	local rod: Tool? = nil
	for _, inst in ipairs(char:GetChildren()) do
		if inst:IsA("Tool") and (inst:GetAttribute("IsFishingRod") == true or getRodCfgFromTool(inst)) then
			rod = inst; break
		end
	end
	if not rod then return nil end
	return ensureTipAttachmentServer(rod)
end

local function waitTipAttachment(plr: Player, timeoutSec: number?): Attachment?
	local t0 = os.clock()
	local limit = timeoutSec or 1.2
	repeat
		local a = getTipAttachment(plr)
		if a and a.Parent and a:IsA("Attachment") then return a end
		task.wait(0.05)
	until (os.clock() - t0) > limit
	return nil
end

local function getHookPartAndAttachment(plr: Player, _rodHint: Tool?): (BasePart?, Attachment?)
	-- Selalu pakai template RS
	local tpl = game.ReplicatedStorage:FindFirstChild("HookTemplate")
	if not tpl then return nil, nil end
	local hp = tpl:FindFirstChild("HookPart", true)
	if not (hp and hp:IsA("BasePart")) then return nil, nil end
	local att = hp:FindFirstChild("HookAttachment")
	if not att then
		att = Instance.new("Attachment"); att.Name = "HookAttachment"; att.Parent = hp
	end
	return hp, att
end


local function ensureAttachmentOn(part: BasePart?): Attachment?
	if not part then return nil end
	local att = part:FindFirstChild("HookAttachment")
	if att and att:IsA("Attachment") then return att end
	att = Instance.new("Attachment")
	att.Name = "HookAttachment"
	att.Parent = part
	return att
end

local function getBeamFolderFor(plr: Player)
	local name = ("FishingBeams_%d"):format(plr.UserId)
	local folder = workspace:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = workspace
	end
	return folder
end

local function createOrRebuildBeam(plr: Player, tip: Attachment, key: string, sessionNumber: number, rod: Tool?)
	local beamName = ("FishingLine_%s_%d"):format(key, sessionNumber)
	local holder = getBeamFolderFor(plr)

	-- kalau ada sisa beam bernama sama di holder, hapus
	local old = holder:FindFirstChild(beamName)
	if old then old:Destroy() end

	local beam = Instance.new("Beam")
	beam.Name = beamName
	beam.Attachment0 = tip
	beam.Segments = 1
	beam.Enabled = false
	beam.Parent = holder   -- << parent aman, bukan ke tip

	-- apply style per rod
	local style = BeamStyles.Resolve(rod, RodConfig)
	BeamStyles.Apply(beam, style)

	return beam
end

local function getRodKey(rod: Tool?)
	if rod then
		local rid = rod:GetAttribute("RodId")
		if typeof(rid) == "string" and #rid > 0 then return rid end
		if rod.Name then return rod.Name end
	end
	return "__default__"
end

-- ===================
--  CAST & PHYSICS MISC
-- ===================
local MAX_CAST     = 5

-- >>> THROW / AIR FEEL TUNING <<<
local THROW_TUNE = {
	-- waktu terbang ke target; lebih KECIL = lebih cepat sampai air
	TimeMin = 0.24,  -- dari 0.28
	TimeMax = 0.34,  -- dari 0.40
	UpBiasBase  = 0.05, -- dari 0.06
	UpBiasRange = 0.05,  -- dulu 0.06

	-- gravitasi efektif di UDARA; >1.0 = terasa lebih berat, jatuh lebih cepat
	GravityMulAir = 1.35,

	-- sesudah nyemplung, seberapa besar sisa XZ velocity yang dibawa
	-- makin kecil = cepat “tenang” di air (nggak ngelayang)
	WaterEntryXZMul = 0.18, -- dulu 0.25

	-- limit minimum Vy awal; turunin dikit biar busur nggak terlalu tinggi
	MinVy = 8,  -- dulu 10
}

-- =====================
--  POOL PER-ROD (INTI)
-- =====================
local function ensurePool(player: Player, tip: Attachment, rod: Tool?)
	local s   = st(player)
	local key = getRodKey(rod)
	local existing = s.pools[key]

	-- REUSE: pastikan beam ada & terhubung ke tip + hook
	if existing and existing.hook and existing.hook.Parent then
		if not (existing.beam and existing.beam.Parent) then
			existing.beam = createOrRebuildBeam(player, tip, key, s.session, rod)
		end
		existing.beam.Attachment0 = tip
		-- ?? nempel ke hook-nya
		existing.beam.Attachment1 = existing.hookAtt
		existing.beam.Enabled = true

		s.activeKey = key
		return existing
	end

	-- NEW pool
	local srcPart = select(1, getHookPartAndAttachment(player, rod))
	if not srcPart then return nil end

	local hookClone: BasePart = srcPart:Clone()
	hookClone.Name = ("Hook_%s_%d"):format(key, s.session)
	hookClone.Parent = workspace
	hookClone.CanCollide = true
	hookClone.Massless  = false
	hookClone.Anchored  = true
	hookClone.AssemblyLinearVelocity  = Vector3.zero
	hookClone.AssemblyAngularVelocity = Vector3.zero
	hookClone.Transparency = 1
	for _, d in ipairs(hookClone:GetDescendants()) do
		if d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D") or d:IsA("Constraint")
			or d:IsA("VectorForce") or d:IsA("BodyForce") or d:IsA("BodyVelocity") or d:IsA("BodyPosition") or d:IsA("BodyGyro")
			or d:IsA("LinearVelocity") or d:IsA("AngularVelocity") or d:IsA("AlignPosition") or d:IsA("AlignOrientation") then
			d:Destroy()
		elseif d:IsA("Attachment") and d.Name ~= "HookAttachment" then
			d:Destroy()
		end
	end
	local hookAtt = ensureAttachmentOn(hookClone)

	local beam = createOrRebuildBeam(player, tip, key, s.session, rod)
	beam.Attachment0 = tip
	beam.Attachment1 = hookAtt       -- ?? langsung ke hook
	beam.Enabled = true

	local poolTbl = { hook = hookClone, hookAtt = hookAtt, beam = beam, key = key }
	s.pools[key] = poolTbl
	s.activeKey  = key
	return poolTbl
end

local function cleanupHookAndBeam(plr: Player)
	local s = st(plr)
	disconnectHookConn(plr)

	local function resetPool(pool)
		if not pool then return end
		if pool.hook and pool.hook.Parent then
			pool.hook.Anchored = true
			pool.hook.AssemblyLinearVelocity  = Vector3.zero
			pool.hook.AssemblyAngularVelocity = Vector3.zero
			pool.hook.Transparency = 1
			local vf = pool.hook:FindFirstChild("BuoyancyForce"); if vf then vf:Destroy() end
			local att = pool.hook:FindFirstChild("BuoyancyAttachment"); if att then att:Destroy() end
		end
		if pool.beam and pool.beam.Parent then
			pool.beam.Enabled = false
			pool.beam.CurveSize0, pool.beam.CurveSize1 = 0, 0
		end
		-- ?? tidak ada lineEndPart lagi
	end

	if s.activeKey and s.pools[s.activeKey] then
		resetPool(s.pools[s.activeKey])
	end

	s.wasAboveSurface, s.buoyancyOn = false, false
	s.fishTugUntil = nil
	s.defaultDepth = 0.18
	s.tugDepth     = 0.38
	FishingShared.clearRig(plr)
end

-- =======================
--  RARITY/WEIGHT/PRICE
-- =======================
local function getRodStats(rod: Tool?)
	local stats = { Luck=0, LuckRaw=0, WeightBonusMinPct=0, WeightBonusMaxPct=0, MythicChanceCapPct=0.0, CapWeight=nil, Speed=0, LuckBonus=nil }
	if not rod then return stats end

	local cfg = getRodCfgFromTool(rod)
	if cfg then
		-- === GANTI: pakai Luck RAW & L efektif (0..100) ===
		local Lraw = tonumber(cfg.luck) or 0          -- 0..350
		stats.LuckRaw = math.max(Lraw, 0)
		stats.Luck    = RarityConfig.ToEffectiveL(stats.LuckRaw)   -- 0..100

		stats.CapWeight = tonumber(cfg.weight)
		stats.Speed     = tonumber(cfg.speed) or 0

		-- bonus berat kecil dari speed (biarkan seperti semula)
		local wb = 0; if stats.Speed > 0 then wb = (stats.Speed/5)*0.05 end
		stats.WeightBonusMinPct = math.max(0, wb*100); stats.WeightBonusMaxPct = stats.WeightBonusMinPct

		-- === GANTI: skema cap Mythic pakai LUCK RAW (maks 350) ===
		if     stats.LuckRaw >= 350 then stats.MythicChanceCapPct = 2.0   -- 2.0%
		elseif stats.LuckRaw >= 300 then stats.MythicChanceCapPct = 1.5
		elseif stats.LuckRaw >= 200 then stats.MythicChanceCapPct = 1.2
		elseif stats.LuckRaw >= 100 then stats.MythicChanceCapPct = 0.9
		else                              stats.MythicChanceCapPct = 0.5   -- 0.5%
		end
		return stats
	end

	-- === fallback jika rod pakai Attribute ===
	stats.LuckRaw = tonumber(rod:GetAttribute("Luck")) or 0
	stats.Luck    = RarityConfig.ToEffectiveL(stats.LuckRaw)
	stats.WeightBonusMinPct = tonumber(rod:GetAttribute("WeightBonusMinPct")) or 0
	stats.WeightBonusMaxPct = tonumber(rod:GetAttribute("WeightBonusMaxPct")) or stats.WeightBonusMinPct
	stats.MythicChanceCapPct = tonumber(rod:GetAttribute("MythicChanceCapPct")) or 0.5
	stats.CapWeight = tonumber(rod:GetAttribute("CapWeight"))
	stats.Speed     = tonumber(rod:GetAttribute("Speed")) or 0
	return stats
end

local function speedFrac(speed) return math.clamp((tonumber(speed) or 0)/50, 0, 1) end

local function adjustedRarityProbs(rod: Tool?)
	local stats = getRodStats(rod)
	local base  = RarityConfig.BaseProb
	-- === PAKAI L efektif 0..100 ===
	local L     = math.clamp(tonumber(stats.Luck) or 0, 0, 100)

	local fCommon    = RarityConfig.LuckCurve.Common(L)
	local fUncommon  = RarityConfig.LuckCurve.Uncommon(L)
	local fRare      = RarityConfig.LuckCurve.Rare(L)
	local fLegendary = RarityConfig.LuckCurve.Legendary(L)
	local fMythic    = RarityConfig.LuckCurve.Mythic(L)

	local p = {
		Common    = base.Common    * fCommon,
		Uncommon  = base.Uncommon  * fUncommon,
		Rare      = base.Rare      * fRare,
		Legendary = base.Legendary * fLegendary,
		Mythic    = base.Mythic    * fMythic,
	}

	-- 1) Normalisasi dulu
	local sum = 0; for _, v in pairs(p) do sum += v end
	for k, v in pairs(p) do p[k] = v / math.max(sum, 1e-9) end

	-- 2) Terapkan CAP Mythic SETELAH normalisasi (persen -> fraksi)
	local mythicCap = ((tonumber(stats.MythicChanceCapPct) or RarityConfig.MythicCapPctDefault or 0.1) / 100)
	if p.Mythic > mythicCap then
		local extra  = p.Mythic - mythicCap
		p.Mythic = mythicCap
		local other = p.Common + p.Uncommon + p.Rare + p.Legendary
		if other > 1e-9 then
			local shrink = extra / other
			p.Common    *= (1 - shrink)
			p.Uncommon  *= (1 - shrink)
			p.Rare      *= (1 - shrink)
			p.Legendary *= (1 - shrink)
		end
	end

	-- 3) (OPSIONAL) floor sederhana agar ikan mudah tetap sering
	--[[
	local COMMON_FLOOR = 0.50
	local CU_FLOOR     = 0.80
	if p.Common < COMMON_FLOOR then
		local need = COMMON_FLOOR - p.Common
		local pool = p.Uncommon + p.Rare + p.Legendary + p.Mythic
		if pool > 1e-9 then
			local f = need / pool
			p.Uncommon  *= (1 - f)
			p.Rare      *= (1 - f)
			p.Legendary *= (1 - f)
			p.Mythic    *= (1 - f)
			p.Common     = COMMON_FLOOR
		end
	end
	local cu = p.Common + p.Uncommon
	if cu < CU_FLOOR then
		local need = CU_FLOOR - cu
		local pool = p.Rare + p.Legendary + p.Mythic
		if pool > 1e-9 then
			local f = need / pool
			p.Rare      *= (1 - f)
			p.Legendary *= (1 - f)
			p.Mythic    *= (1 - f)
			local ratio = p.Common / math.max(cu, 1e-9)
			p.Common   = p.Common   + need * ratio
			p.Uncommon = p.Uncommon + need * (1 - ratio)
		end
	end
	]]

	-- 4) Normalisasi akhir (aman)
	sum = 0; for _, v in pairs(p) do sum += v end
	for k, v in pairs(p) do p[k] = v / math.max(sum, 1e-9) end

	return p
end

local function sampleRarityFromProbs(p, rngObj: Random?)
	local r = rngObj and rngObj:NextNumber() or math.random()
	if r <= p.Mythic then return "Mythic" end
	r -= p.Mythic
	if r <= p.Legendary then return "Legendary" end
	r -= p.Legendary
	if r <= p.Rare then return "Rare" end
	r -= p.Rare
	if r <= p.Uncommon then return "Uncommon" end
	return "Common"
end

local sessionRNG = Random.new()
local function applyRodWeightBonus(baseWeight: number, rarity: string, rod: Tool?)
	local stats = getRodStats(rod)
	local minPct = tonumber(stats.WeightBonusMinPct) or 0
	local maxPct = tonumber(stats.WeightBonusMaxPct) or minPct
	if maxPct < minPct then maxPct = minPct end
	local bonusPct = sessionRNG:NextNumber(minPct/100, maxPct/100)

	-- pertahankan desimal
	local w = baseWeight * (1 + bonusPct)

	-- cap oleh rarity & rod
	local list = FishUtil.getFishList(rarity)
	local maxByRarity = 0
	for _, e in ipairs(list) do
		maxByRarity = math.max(maxByRarity, (e.weight and e.weight[2]) or 0)
	end
	local capMul = 1.5
	local rarityCap = (maxByRarity > 0 and maxByRarity or baseWeight) * capMul
	if stats.CapWeight then rarityCap = math.min(rarityCap, stats.CapWeight) end

	-- bulatkan 2 desimal (kg)
	w = math.round(w * 100) / 100
	return math.clamp(w, 0.01, rarityCap)
end

local function easeMinigameByLuck(clicksRequired: number, rod: Tool?)
	local L = getRodStats(rod).Luck
	local factorLuck = 1 - 0.40 * (math.clamp((tonumber(L) or 0), 0, 100) / 100)
	return math.max(3, math.floor(clicksRequired * factorLuck))
end

local raritySettings = {
	Common    = {ClicksRequired={8,15},  FillSpeed={2.5,3.5}},
	Uncommon  = {ClicksRequired={12,18}, FillSpeed={2.0,3.0}}, -- baru
	Rare      = {ClicksRequired={15,20}, FillSpeed={1.2,1.8}},
	Legendary = {ClicksRequired={25,40}, FillSpeed={1.0,1.3}},
	Mythic   = {ClicksRequired={50,60}, FillSpeed={0.6,0.8}}
}

local function getRandomSettings(rarity, rngObj: Random?)
	local settings = raritySettings[rarity]
	if not settings then return {ClicksRequired=8, FillSpeed=2} end
	local ci, cj = settings.ClicksRequired[1], settings.ClicksRequired[2]
	local si, sj = settings.FillSpeed[1], settings.FillSpeed[2]
	local clicks = (rngObj and rngObj:NextInteger(ci, cj)) or math.random(ci, cj)
	local speed  = (rngObj and (rngObj:NextNumber() * (sj - si) + si)) or (math.random() * (sj - si) + si)
	return {ClicksRequired = clicks, FillSpeed = speed}
end

-- ======================
--  DATASTORE DUMMY (optional attr snapshot)
-- ======================
local function UpdateSavedFishData(player) -- snapshot ringan ke Attribute (opsional)
	player:SetAttribute("SavedFishData", "[]")
end

-- ======================
--  CATCH PIPELINE (server-authoritative)
-- ======================
local function OnCatchGiven(rodTool: Tool, plr: Player, rarity: string, fishToolModel: Tool, fishEntry)
	local s = st(plr); if not s.fishing then return end

	-- 1) base weight & price/image dari DB
	local baseMin, baseMax = 1, 1
	if fishEntry and fishEntry.weight then
		baseMin, baseMax = fishEntry.weight[1] or 1, fishEntry.weight[2] or 1
	end
	local baseWeight = (s.rng and s.rng:NextNumber(baseMin, baseMax)) or (math.random() * (baseMax - baseMin) + baseMin)

	local rodNow = getEquippedRod(plr)
	local finalWeight = applyRodWeightBonus(baseWeight, rarity, rodNow)

	local pricePerKg = ((fishEntry and fishEntry.pricePerKg) or 10) * (EconomyConfig.BaseSellMultiplier or 1.0)
	-- bulatkan 1 desimal biar UI rapi (20.0, 90.0, dst)
	pricePerKg = math.round(pricePerKg * 10) / 10

	local fishImage = fishEntry and fishEntry.image or ""

	-- 2) UI info
	local FishInfo = {
		Fish_Name     = fishEntry and (fishEntry.name or fishEntry.id) or fishToolModel.Name,
		FishImage     = fishImage,
		Sell_Price_KG = pricePerKg, -- (klien nanti diabaikan)
		Weight        = finalWeight,
		BaseN         = fishEntry and fishEntry.baseN,   -- << tambah ini
	}
	
	plr:SetAttribute("LastFishName", FishInfo.Fish_Name)
	plr:SetAttribute("LastFishRarity", tostring(rarity))
	plr:SetAttribute("CatchSeq", (plr:GetAttribute("CatchSeq") or 0)+1)
	Remotes.ShowCatchUI:FireClient(plr, FishInfo, rarity)

	-- 3) (opsional) scaling visual pada clone model jika diperlukan inventory 3D
	do
		local fishClone = fishToolModel:Clone()
		local maxCapByRarity = {
			Common    = 2.0,
			Uncommon  = 2.2, -- baru
			Rare      = 2.4,
			Legendary = 2.8,
			Mythic   = 3.2
		}
		local base=1.35; local perKg=1/60; local cap=maxCapByRarity[rarity] or 3.0
		local scaleFactor = math.clamp(base + (finalWeight*perKg), 1.15, cap)
		for _, part in ipairs(fishClone:GetDescendants()) do
			if part:IsA("MeshPart") then part.Size = part.Size * scaleFactor; part.CanCollide = true end
		end
		-- jika kamu tidak butuh clone fisik di world, abaikan fishClone
		fishClone:Destroy()
	end

	-- 4) Kirim ke Inventory (nama+berat saja; harga dihitung saat jual)
	local BE_AddFishServer = Remotes:WaitForChild("Inventory_AddFishServer")
	BE_AddFishServer:Fire(plr, FishInfo.Fish_Name, finalWeight)

	-- 5) Optional snapshot
	UpdateSavedFishData(plr)

	-- 6) Broadcast Mythic
	if rarity == "Mythic" then
		Remotes.BroadcastFishMessage:FireAllClients(string.format("?? %s just caught a BIG FISH: %s!", plr.Name, FishInfo.Fish_Name))
	end
end

-- ======================
--  PLAYER LIFECYCLE
-- ======================
Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(char)
		local s = st(plr)
		-- Ensure no leftover Heartbeat from previous character
		disconnectHookConn(plr)
		s.pools = {}
		s.fishing = false
		s.session += 1
		s.lastStart = 0
		task.defer(function()
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.Died:Connect(function()
					s.fishing=false
					s.session+=1
					cleanupHookAndBeam(plr) -- also disconnects hookConn
				end)
			end
		end)
	end)
end)

Players.PlayerRemoving:Connect(function(plr)
	disconnectHookConn(plr)
	local s = P[plr]
	if s and s.pools then
		for _, pool in pairs(s.pools) do
			if pool.beam then pcall(function() pool.beam:Destroy() end) end
			if pool.hook then pcall(function() pool.hook:Destroy() end) end
			if pool.lineEndPart then pcall(function() pool.lineEndPart:Destroy() end) end
		end
	end
	P[plr] = nil

	local f = workspace:FindFirstChild(("FishingBeams_%d"):format(plr.UserId))
	if f then pcall(function() f:Destroy() end) end
end)

local function missAndCleanup(plr: Player, msg: string?)
	local notice = Remotes:FindFirstChild("FishingNotice")
	if notice then notice:FireClient(plr, msg or "You missed the water") end
	FishingShared.clearRig(plr)
	cleanupHookAndBeam(plr)
	local s = st(plr)
	s.fishing, s.pending, s.miniExpire = false, nil, nil
end

-- Mendaratkan hook ke permukaan solid dengan sedikit offset
local function landOnSolidAndMiss(plr: Player, hook: BasePart, hitPos: Vector3, hitNormal: Vector3?)
	local up = (hitNormal and hitNormal.Unit) or Vector3.new(0,1,0)
	local place = hitPos + up * 0.03
	hook.Anchored = true
	hook.AssemblyLinearVelocity  = Vector3.zero
	hook.AssemblyAngularVelocity = Vector3.zero
	-- arahkan kira-kira ke depan agar rapi
	hook.CFrame = CFrame.new(place, place + (hook.CFrame.LookVector.Magnitude > 0 and hook.CFrame.LookVector or Vector3.new(0,0,-1)))
	hook.Transparency = 0

	-- kirim miss standard + cleanup
	disconnectHookConn(plr)
	missAndCleanup(plr, "You missed the water")
end

-- Anggap transparan >= 0.95 bukan solid
local TRANSP_SOLID = 0.95
local function isSolid(inst: Instance?): boolean
	if inst == nil then return false end
	if inst:IsA("Terrain") then
		-- Terrain solid kecuali voxel Water (dicek via RaycastResult.Material)
		return true
	end
	if not inst:IsA("BasePart") then return false end
	local p = inst :: BasePart
	return p.CanCollide and p.Transparency < TRANSP_SOLID
end


-- =========================
--  BEGIN CAST (SERVER-SIDE)
-- =========================
Remotes.BeginFishing.OnServerEvent:Connect(function(player, _unused, clientSession)
	ensureHookCollisionGroup()

	local s = st(player)

	-- session & rng (server-only)
	local clientSess = (typeof(clientSession) == "number") and clientSession or nil
	s.session += 1
	s.rng = Random.new(player.UserId + s.session + os.time())

	-- cooldown anti-spam
	if (time() - (s.lastStart or 0)) < 0.8 then return end
	s.lastStart = time()

	-- block memancing saat berenang
	if isSwimmingOrInWater(player) then
		missAndCleanup(player, "You can't fish while in water")
		return
	end

	if s.fishing and time() - (s.lastStart or 0) > 15 then s.fishing = false end
	
	ensureRodInCharacter(player)
	local tip = getTipAttachment(player)
	if not tip then
	else
	
		-- retry (anti-race)
		for i = 1, 12 do
			task.wait(0.016)
			tip = getTipAttachment(player)
			if tip then
				break
			end
			if i == 12 then
				local r = getEquippedRod(player)
				-- dump 1-lapis isi rod supaya kebaca strukturnya (tanpa helper)
				if r then
					for _,c in ipairs(r:GetChildren()) do
					end
				end
			end
		end
	end

	if not tip then
		local r = getEquippedRod(player)
		missAndCleanup(player, "Hook not ready")
		return
	end

	local rod = getEquippedRod(player)
	if rod then
		local tr = rod:FindFirstChild("TipAttachmentRef")
		if tr and tr:IsA("ObjectValue") and tr.Value then
		end
		local direct = rod:FindFirstChild("RodTipAttachment", true)
	end
	
	ensureRodInCharacter(player)
	local tip = waitTipAttachment(player, 1.2)
	if not tip then
		missAndCleanup(player, "Hook not ready")
		return
	end
	
	local pool = ensurePool(player, tip, rod)
	if not pool then
		missAndCleanup(player, "Hook pool error")
		return
	end

	if pool.beam then
		pool.beam.Attachment0 = tip
		pool.beam.Enabled = true
		pool.beam.CurveSize0, pool.beam.CurveSize1 = 0, 0
	end
	if pool.beam and pool.lineEndAtt then
		pool.beam.Attachment1 = pool.lineEndAtt
	end

	-- Rarity & fish selection (pakai DB)
	local probs = adjustedRarityProbs(rod)
	local chosenRarity = sampleRarityFromProbs(probs, s.rng)

	-- Sesuaikan dengan CapWeight rod (turunkan rarity jika over-cap)
	local stats = getRodStats(rod)

	local function rarityIsFeasibleForRod(rarity: string, capWeight)
		local list = FishUtil.getFishList(rarity)  -- gunakan untuk ambil rentang berat global
		local minW = math.huge
		for _, e in ipairs(list) do
			if e.weight and e.weight[1] then
				minW = math.min(minW, e.weight[1])
			end
		end
		if minW == math.huge then minW = 1 end
		return (type(capWeight)=="number") and (capWeight >= minW)
	end

	-- turunkan rarity jika rod cap tidak sanggup
	while chosenRarity ~= "Common" and not rarityIsFeasibleForRod(chosenRarity, stats.CapWeight) do
		if chosenRarity == "Mythic" then
			chosenRarity = "Legendary"
		elseif chosenRarity == "Legendary" then
			chosenRarity = "Rare"
		elseif chosenRarity == "Rare" then
			chosenRarity = "Uncommon"
		else
			chosenRarity = "Common"
		end
	end

	-- ======== PILIH IKAN BERDASARKAN ZONA ========
	-- tentukan island dari posisi pemain (di air kamu sudah cek di atas)
	local zone = ZoneService.GetZoneForCharacter(player.Character)
	local islandName = (zone and zone.island) or FishDB.Islands.Sea  -- fallback ke Sea
	-- zone.island = "Moonwater Bay" / "Lake Toba" / "Volcano Bay" / "Poseidon Tomb"

	-- coba roll ikan di rarity terpilih; jika kosong, turun rarity
	local entry = FishPool.Roll(zone.island, chosenRarity)
	local stepDown = function(r)
		if r == "Mythic" then return "Legendary"
		elseif r == "Legendary" then return "Rare"
		elseif r == "Rare" then return "Uncommon"
		else return "Common" end
	end
	while (not entry) and (chosenRarity ~= "Common") do
		chosenRarity = stepDown(chosenRarity)
		entry = FishPool.Roll(zone.island, chosenRarity)
	end
	if not entry then
		missAndCleanup(player, "No fish available in this area")
		return
	end

	local fishId = entry.id

	-- Ambil Tool ikan dari ServerStorage/Tools/Fish/<Rarity>/<ToolName>
	local rarityToUse = (entry.rarity or chosenRarity)
	local rarityFolder = FishToolsRoot:FindFirstChild(rarityToUse)
	local chosenFishTool = rarityFolder and rarityFolder:FindFirstChild(fishId)

	-- fallback: cari di seluruh tree Fish (kalau folder/tulisan beda)
	if not chosenFishTool then
		chosenFishTool = FishToolsRoot:FindFirstChild(fishId, true) -- true = recursive
	end

	-- fallback fuzzy (lowercase compare) jika masih belum ketemu
	if (not chosenFishTool) and rarityFolder then
		for _, t in ipairs(rarityFolder:GetChildren()) do
			if t:IsA("Tool") and string.lower(t.Name) == string.lower(fishId) then
				chosenFishTool = t; break
			end
		end
	end

	if not chosenFishTool then
		missAndCleanup(player, ("No fish model: %s"):format(fishId))
		return
	end
	
	-- Minigame settings
	local settings = getRandomSettings(chosenRarity, s.rng)
	local sp = speedFrac(getRodStats(rod).Speed)
	settings.FillSpeed = settings.FillSpeed * (1 + 0.25 * sp)
	settings.ClicksRequired = easeMinigameByLuck(settings.ClicksRequired, rod)

	-- Pending + token
	local token = HttpService:GenerateGUID(false)
	s.pending = {
		token = token,
		rarity = (entry.rarity or chosenRarity),
		fishId = fishId,
		expire = time()+20,
		session = s.session
	}

	-- Bite delay
	local biteTime = s.rng:NextInteger(5, 8)
	local sessionAtStart = s.session

	-- Param lempar (balistik ringan)
	local root = player.Character and player.Character.PrimaryPart
	local startPos = tip.WorldPosition
	local lookXZ = root and (root.CFrame.LookVector * Vector3.new(1,0,1)) or Vector3.new(0,0,-1)
	if lookXZ.Magnitude < 0.1 then lookXZ = Vector3.new(0,0,-1) end
	lookXZ = lookXZ.Unit

	local forwardClear, upClear = 2.0, 0.5
	local spawnPos = startPos + lookXZ * forwardClear + Vector3.new(0, upClear, 0)
	-- >>> CAST DISTANCE (dekat) <<<
	local MIN_CAST, MAX_CAST = 9, 14   -- rentang jarak lempar (stud) biar dekat
	local forwardClear, upClear = 1.2, 0.4

	local root = player.Character and player.Character.PrimaryPart
	local startPos = tip.WorldPosition
	local lookXZ = root and (root.CFrame.LookVector * Vector3.new(1,0,1)) or Vector3.new(0,0,-1)
	if lookXZ.Magnitude < 0.1 then lookXZ = Vector3.new(0,0,-1) end
	lookXZ = lookXZ.Unit

	local spawnPos = startPos + lookXZ * forwardClear + Vector3.new(0, upClear, 0)

	-- >>> opsional: rod cepat lempar sedikit lebih jauh (halus)
	local stats = getRodStats(rod)              -- sudah ada function-nya
	local speedMul = 1 + 0.35 * speedFrac(stats.Speed)  -- 0..1 -> +0..35%
	local dist = math.floor(s.rng:NextInteger(MIN_CAST, MAX_CAST) * speedMul)

	local target = spawnPos + lookXZ * dist

	-- ===== balistik (pakai dist baru) =====
	local dx = target - spawnPos
	local distXZ = (dx * Vector3.new(1,0,1)).Magnitude
	local function remap(v,a1,b1,a2,b2) return a2 + (math.clamp(v,a1,b1)-a1)*(b2-a2)/(b1-a1) end

	-- Map waktu terbang ke jarak baru (supaya “jatuh cepat”, tetap dekat)
	local T = remap(distXZ, MIN_CAST, MAX_CAST, THROW_TUNE.TimeMin, THROW_TUNE.TimeMax)
	T = T + (s.rng:NextInteger(-12, 12) * 0.001)

	local gAir = Vector3.new(0, -workspace.Gravity * (THROW_TUNE.GravityMulAir or 1), 0)
	local v0 = (dx - 0.5 * gAir * (T*T)) / T

	-- sedikit angkat (kecil biar busurnya datar)
	do
		local upBias = (THROW_TUNE.UpBiasBase or 0.06)
			+ math.clamp((distXZ - MIN_CAST)/(MAX_CAST - MIN_CAST), 0, 1) * (THROW_TUNE.UpBiasRange or 0.05)
		local upVec  = (root and root.CFrame.UpVector) or Vector3.new(0,1,0)
		v0 = v0 + upVec * (v0.Magnitude * upBias)
	end

	-- minimal Vy tetap rendah biar cepat turun
	do
		local minVy = THROW_TUNE.MinVy or 8
		if v0.Y < minVy then v0 = Vector3.new(v0.X, minVy, v0.Z) end
	end

	local hookClone, beamObj = pool.hook, pool.beam
	local lastPosForCast = spawnPos + lookXZ * 0.05  -- geser 5cm ke depan biar gak self-hit
	if not hookClone or not hookClone.Parent then missAndCleanup(player, "Hook missing"); return end

	for _, d in ipairs(hookClone:GetDescendants()) do
		if d:IsA("BodyMover") or d:IsA("VectorForce") or d:IsA("BodyForce")
			or d:IsA("BodyPosition") or d:IsA("BodyGyro") or d:IsA("AlignPosition")
			or d:IsA("LinearVelocity") or d:IsA("AngularVelocity") or d:IsA("Constraint") then
			d:Destroy()
		end
	end

	hookClone.Anchored = true
	hookClone.CanTouch, hookClone.CanCollide = true, true
	hookClone.CFrame = CFrame.new(spawnPos, spawnPos + lookXZ)
	hookClone.Transparency = 0
	hookClone.CollisionGroup = HOOK_GROUP

	if beamObj then
		local tipPos  = tip.WorldPosition
		local hookPos = hookClone.Position
		local dist    = (hookPos - tipPos).Magnitude
		local sag     = math.clamp(dist * 0.06, 0, 8)  -- tweak sesukamu
		beamObj.CurveSize0 = -sag
		beamObj.CurveSize1 =  sag
	end

	FishingShared.setRig(player, hookClone, beamObj, tip, lookXZ)

	local preflightOn = true
	local launchT0 = time()
	local preflightHard = 0.5
	local v0Ball = v0
	local x0Ball = spawnPos
	local inWater = false
	local landMissDeadline = time() + preflightHard + 0.10

	-- ALWAYS stop any previous Heartbeat before starting a new one
	disconnectHookConn(player)
	s.wasAboveSurface=false; s.buoyancyOn=false; s.fishTugUntil=nil
	s.defaultDepth=0.10; s.tugDepth=0.38

	s.hookConn = RunService.Heartbeat:Connect(function(dt)
		if not tip or not tip.Parent or not hookClone or not hookClone.Parent then
			disconnectHookConn(player)
			missAndCleanup(player, "Canceled fishing")
			return
		end
		
		-- timeout minigame
		if s.fishing and s.miniExpire and time() > s.miniExpire then
			s.miniExpire = nil
			disconnectHookConn(player)
			missAndCleanup(player, "The fish got away")
			return
		end

		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum:GetState() == Enum.HumanoidStateType.Swimming then
			disconnectHookConn(player)
			missAndCleanup(player, "You can't fish while in water")
			return
		end
		if not hookClone or not hookClone.Parent then
			disconnectHookConn(player)
			return
		end
		if hookClone:GetAttribute("CatchHold") == true then
			disconnectHookConn(player)
			return
		end

		-- PREFLIGHT trajectory
		if preflightOn then
			local t  = time() - launchT0
			local g  = Vector3.new(0, -workspace.Gravity * (THROW_TUNE.GravityMulAir or 1), 0)
			local posBall = x0Ball + v0Ball * t + 0.5 * g * (t*t)
			local vBall   = v0Ball + g * t

			local tipPosNow = tip.WorldPosition
			local vecTipToBall = posBall - tipPosNow
			local dist = vecTipToBall.Magnitude
			
			-- === RAYCAST MAJU (solid-only): tembus transparan/CanCollide=false ===
			-- === RAYCAST MAJU: tembus non-solid/transparent, mendarat saat solid ===
			do
				local origin = lastPosForCast
				local targetPos = posBall
				local dir = targetPos - origin
				local segLen = dir.Magnitude

				if segLen > 1e-4 then
					local rp = RaycastParams.new()
					rp.FilterType = Enum.RaycastFilterType.Exclude
					rp.FilterDescendantsInstances = { player.Character }
					rp.IgnoreWater = false

					for _ = 1, 12 do
						local rem = targetPos - origin
						if rem.Magnitude <= 1e-4 then break end

						local r = workspace:Raycast(origin, rem, rp)
						if not r then break end
						if r.Material == Enum.Material.Water then break end

						if isSolid(r.Instance) then
							landOnSolidAndMiss(player, hookClone, r.Position, r.Normal)
							return
						end

						local arr = rp.FilterDescendantsInstances
						arr[#arr+1] = r.Instance
						rp.FilterDescendantsInstances = arr

						local u = rem.Unit
						origin = r.Position + u * 0.02
					end
				end
			end

			local dirXZ = Vector3.new(vBall.X,0,vBall.Z)
			local fwd = (dirXZ.Magnitude > 0.01) and dirXZ.Unit or lookXZ
			hookClone.CFrame = CFrame.new(posBall, posBall + fwd)
			lastPosForCast = posBall
			hookClone.CanTouch, hookClone.CanCollide = true, true

			local rp = RaycastParams.new()
			rp.IgnoreWater = false
			rp.FilterType  = Enum.RaycastFilterType.Include
			rp.FilterDescendantsInstances = { workspace.Terrain }
			local hit = workspace:Raycast(posBall + Vector3.new(0,80,0), Vector3.new(0,-1,0)*200, rp)
			if hit and hit.Material == Enum.Material.Water then
				local surfY = hit.Position.Y
				if posBall.Y <= surfY + 0.30 then
					preflightOn = false
					inWater = true

					local yTarget = surfY - (s.defaultDepth or 0.10)
					hookClone.Anchored = false
					hookClone.CFrame  = CFrame.new(Vector3.new(posBall.X, yTarget, posBall.Z), posBall + lookXZ)

					local gAirNow = Vector3.new(0, -workspace.Gravity * (THROW_TUNE.GravityMulAir or 1), 0)
					local vBallNow = v0Ball + gAirNow * math.max(0, time() - launchT0)
					local kxz = THROW_TUNE.WaterEntryXZMul or 0.18  -- makin kecil ? makin cepat tenang
					hookClone.AssemblyLinearVelocity  = Vector3.new(vBallNow.X * kxz, 0, vBallNow.Z * kxz)

					-- Buoyancy components (once)
					s.buoyancyOn  = true
					s.bounceUntil = nil
					hookClone:SetAttribute("TargetDepth", s.defaultDepth or 0.10)
					hookClone:SetAttribute("BuoyancyK", 140)
					hookClone:SetAttribute("BuoyancyC", 26)
					s.anchorXZ = Vector3.new(posBall.X, 0, posBall.Z)

					local att = hookClone:FindFirstChild("BuoyancyAttachment") or Instance.new("Attachment")
					att.Name = "BuoyancyAttachment"; att.Parent = hookClone
					local vf = hookClone:FindFirstChild("BuoyancyForce") or Instance.new("VectorForce")
					vf.Name = "BuoyancyForce"; vf.Attachment0 = att; vf.RelativeTo = Enum.ActuatorRelativeTo.World; vf.Force = Vector3.new(0,0,0); vf.Parent = hookClone

					-- Start session
					if not s.fishing then
						s.fishing = true
						s.lastStart = time()
						Remotes.FishingStart:FireClient(player)
					end
				end
			end

			if (time() - launchT0) >= 1.20 and preflightOn then
				preflightOn = false
				hookClone.Anchored = false
				hookClone.AssemblyLinearVelocity  = vBall
				hookClone.AssemblyAngularVelocity = Vector3.new(0,4,0)
				hookClone.CanTouch = true

				local touchedConn
				touchedConn = hookClone.Touched:Connect(function(hitPart)
					if not hitPart or not hitPart.Parent then return end
					if hitPart.Material == Enum.Material.Water then return end
					if hitPart:IsA("Terrain") then
						-- terrain non-water dianggap solid
						if touchedConn then touchedConn:Disconnect() end
						landOnSolidAndMiss(player, hookClone, hookClone.Position, Vector3.new(0,1,0))
						return
					end
					if hitPart:IsA("BasePart") then
						local p = hitPart :: BasePart
						if p.CanCollide and p.Transparency < TRANSP_SOLID then
							hookClone.Anchored = true
							hookClone.AssemblyLinearVelocity = Vector3.zero
							if touchedConn then touchedConn:Disconnect() end
							landOnSolidAndMiss(player, hookClone, hookClone.Position, Vector3.new(0,1,0))
						end
					end
				end)
			end
		end

		-- Buoyancy + leash XZ
		local rp2 = RaycastParams.new()
		rp2.IgnoreWater = false
		rp2.FilterType  = Enum.RaycastFilterType.Include
		rp2.FilterDescendantsInstances = { workspace.Terrain }

		local p = hookClone.Position
		local hit2 = workspace:Raycast(p + Vector3.new(0,80,0), Vector3.new(0,-1,0)*200, rp2)

		-- Fallback darurat: kalau entah bagaimana belum menyentuh apa pun > 6 detik
		if (not inWater) and (time() - launchT0) > 6.0 then
			landOnSolidAndMiss(player, hookClone, hookClone.Position, Vector3.new(0,1,0))
			return
		end

		local vf = hookClone:FindFirstChild("BuoyancyForce")
		if not vf then return end

		if not hit2 or hit2.Material ~= Enum.Material.Water then
			vf.Force = Vector3.new(0,0,0)
			return
		end

		local surfY2 = hit2.Position.Y
		if s.buoyancyOn then
			local targetDepth = hookClone:GetAttribute("TargetDepth") or s.defaultDepth or 0.12
			local yTarget = surfY2 - targetDepth
			local mass = hookClone:GetMass()
			local kBase = hookClone:GetAttribute("BuoyancyK") or 180
			local c = hookClone:GetAttribute("BuoyancyC") or 24

			local vNow = hookClone.AssemblyLinearVelocity
			local vyNow = vNow.Y
			local err   = yTarget - p.Y
			local pen   = math.max(0, surfY2 - p.Y)
			local k     = kBase * (1 + math.clamp(pen*6.0, 0, 1.5))
			if pen > 0.14 and vyNow < 0 then vyNow = math.max(vyNow, -6) end

			local buoy = k*err - c*vyNow
			local F = mass*workspace.Gravity + buoy
			local maxUp = mass*workspace.Gravity*2.0
			local maxDn = -mass*workspace.Gravity*1.3
			if F>maxUp then F=maxUp end
			if F<maxDn then F=maxDn end
			vf.Force = Vector3.new(0, F, 0)

			-- leash XZ ringan
			s.anchorXZ = s.anchorXZ or Vector3.new(p.X,0,p.Z)
			local pxz  = Vector3.new(p.X,0,p.Z)
			local errXZ = s.anchorXZ - pxz
			local Kxz, Cxz = 16, 12
			local acc = errXZ * Kxz - Vector3.new(vNow.X,0,vNow.Z) * Cxz
			local newVX = math.clamp(vNow.X + acc.X*dt, -6, 6)
			local newVZ = math.clamp(vNow.Z + acc.Z*dt, -6, 6)
			hookClone.AssemblyLinearVelocity = Vector3.new(newVX, vyNow, newVZ)
		end
	end)

	-- Jadwalkan minigame
	task.delay(biteTime, function()
		local ss = st(player)
		if not player or not player.Parent then return end
		if not ss.fishing then return end
		if ss.session ~= sessionAtStart then return end

		ss.fishTugUntil = time() + 0.85
		if pool and pool.hook then
			pool.hook:SetAttribute("TargetDepth", ss.tugDepth)
			local rand = Vector3.new((s.rng:NextNumber()-0.5), 0, (s.rng:NextNumber()-0.5))
			local dir  = rand.Magnitude>0 and rand.Unit or Vector3.new(1,0,0)
			local nudge = dir * 3
			local v = pool.hook.AssemblyLinearVelocity
			pool.hook.AssemblyLinearVelocity = Vector3.new(v.X + nudge.X, v.Y, v.Z + nudge.Z)
		end

		local payload = {
			ClicksRequired = settings.ClicksRequired,
			FillSpeed      = settings.FillSpeed,
			Fish           = entry.name or entry.id,
			Rarity         = (entry.rarity or chosenRarity),
			Token          = s.pending and s.pending.token or nil,
			Session        = s.session,
			Image          = entry.image or "",
			PricePerKg     = entry.pricePerKg or 10,
		}

		Remotes.StartMinigame:FireClient(player, payload)

		ss.miniExpire = time() + 15
	end)
end)

-- ======================
--  FINISH / CANCEL CAST
-- ======================
Remotes.FinishFishing.OnServerEvent:Connect(function(player, a1, a2, a3)
	local s = st(player)
	-- Kompat: ambil token, session, tool dari posisi manapun (string/number/Tool)
	local tokenFromClient : string? =
		(typeof(a1)=="string" and a1) or
		(typeof(a2)=="string" and a2) or
		(typeof(a3)=="string" and a3) or
		nil

	local clientSession   : number? =
		(typeof(a1)=="number" and a1) or
		(typeof(a2)=="number" and a2) or
		(typeof(a3)=="number" and a3) or
		nil

	local rodTool : Tool? =
		(typeof(a1)=="Instance" and a1:IsA("Tool") and a1) or
		(typeof(a2)=="Instance" and a2:IsA("Tool") and a2) or
		(typeof(a3)=="Instance" and a3:IsA("Tool") and a3) or
		nil

	-- Validasi sesi & state dasar
	if typeof(clientSession) == "number" and clientSession ~= s.session then
		return
	end
	if not s.fishing then
		return
	end
	if not getEquippedRod(player) then
		return
	end

	-- Validasi pending/token
	local pend = s.pending
	if not pend then
		return
	end

	if not tokenFromClient then
		return
	end
	if tokenFromClient ~= pend.token then
		return
	end
	if time() > (pend.expire or 0) then
		return
	end
	if pend.session ~= s.session then
		return
	end

	-- Ambil model & entry ikan
	local rarityFolder = FishToolsRoot:FindFirstChild(pend.rarity)
	local fishToolModel = rarityFolder and rarityFolder:FindFirstChild(pend.fishId)

	if not fishToolModel then
		fishToolModel = FishToolsRoot:FindFirstChild(pend.fishId, true)
	end

	if not fishToolModel then
		missAndCleanup(player, ("No fish model: %s"):format(pend.fishId))
		return
	end

	local fishEntry = FishUtil.getFishEntry(pend.rarity, pend.fishId)
	if not fishEntry then
		missAndCleanup(player, "Fish data missing")
		return
	end

	-- Eksekusi hadiah
	OnCatchGiven(rodTool, player, pend.rarity, fishToolModel, fishEntry)

	-- FULL cleanup to avoid residual Heartbeat leaks
	s.pending    = nil
	s.fishing    = false
	s.miniExpire = nil
	cleanupHookAndBeam(player) -- also disconnects hookConn
end)


Remotes.CancelFishing.OnServerEvent:Connect(function(plr)
	local s = st(plr)
	s.fishing = false
	s.pending = nil
	s.miniExpire = nil

	cleanupHookAndBeam(plr)
	FishingShared.clearRig(plr)
end)
