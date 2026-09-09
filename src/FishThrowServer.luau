-- // ServerScriptService.FishThrowServer
local RS            = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players       = game:GetService("Players")
local Debris        = game:GetService("Debris")
local RunService    = game:GetService("RunService")
local Remotes       = RS:WaitForChild("Remotes")
local WS            = workspace

-- Sumber tool ikan (pindahan dari RS:Fishes ? ServerStorage/Tools/Fish)
local FishToolsRoot = ServerStorage:WaitForChild("Tools"):WaitForChild("Fish")

local FishingShared = require(RS:WaitForChild("FishingShared"))

-- ====== STATE CAST (posisi air per pemain) ======
local castState = {}   -- [player] = { waterPos: Vector3? }
local lastSeq   = {}   -- [player] = number

-- Simpan posisi klik air dari client (optional visual)
Remotes.BeginFishing.OnServerEvent:Connect(function(plr, waterPos: Vector3?)
	castState[plr] = castState[plr] or {}
	castState[plr].waterPos = waterPos
end)

-- ====== HELPERS ======

local function forceDefaultCollision(inst: Instance, canCollide: boolean)
	if inst:IsA("BasePart") then
		inst.CollisionGroup = "Default"
		inst.CanCollide = canCollide
		inst.CanQuery = true
		inst.CanTouch = true
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CollisionGroup = "Default"
			d.CanCollide = canCollide
			d.CanQuery = true
			d.CanTouch = true
		end
	end
end

-- Cari Y permukaan (terrain/part/air) di bawah (x,z)
local function groundYAt(x: number, z: number, hintY: number?, ignoreList: {Instance}? )
	local fromY = (hintY or 800)
	local rp = RaycastParams.new()
	rp.IgnoreWater = false
	rp.FilterType  = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignoreList or {}

	local origin = Vector3.new(x, fromY, z)
	local dir    = Vector3.new(0, -1, 0) * (fromY + 2000)
	local hit = workspace:Raycast(origin, dir, rp)
	if hit then
		return hit.Position.Y, hit.Instance
	end
	return nil, nil
end

local function hardLandAtXZ(pXZ: Vector3, fishPart: BasePart, hookPart: BasePart?, beamObj: Beam?, weld: WeldConstraint?)
	-- siapkan daftar yang diabaikan saat raycast (jangan raycast ke diri sendiri/karakter)
	local ignore = { fishPart }
	local ch = fishPart:FindFirstAncestorOfClass("Model")
	if ch and ch:FindFirstChildOfClass("Humanoid") then
		table.insert(ignore, ch)
	end
	if hookPart and hookPart.Parent then
		table.insert(ignore, hookPart)
	end

	-- ring search di sekitar XZ untuk cari permukaan apapun
	local function findY(px, pz, hint)
		return groundYAt(px, pz, hint, ignore)
	end

	local hintY = fishPart.Position.Y + 100
	local y, hitInst = findY(pXZ.X, pXZ.Z, hintY)

	if not y then
		local radii = {2,4,6,8,10,14,18,24,30}
		local dirs = {
			Vector2.new( 1, 0), Vector2.new(-1, 0), Vector2.new(0, 1), Vector2.new(0,-1),
			Vector2.new( 1, 1), Vector2.new(-1, 1), Vector2.new(1,-1), Vector2.new(-1,-1),
		}
		for _, r in ipairs(radii) do
			for _, d in ipairs(dirs) do
				local px = pXZ.X + d.X * r
				local pz = pXZ.Z + d.Y * r
				local yy, inst = findY(px, pz, hintY)
				if yy then
					y, hitInst = yy, inst
					pXZ = Vector3.new(px, 0, pz)
					break
				end
			end
			if y then break end
		end
	end

	-- Matikan beam (dan lepas total dari ikan)
	if beamObj then
		beamObj.Enabled = false
		beamObj.CurveSize0 = 0
		beamObj.CurveSize1 = 0
		beamObj.Attachment1 = nil
	end

	-- Putus hubungan hook?fish (kalau masih ada)
	if weld and weld.Parent then weld:Destroy() end
	if hookPart and hookPart.Parent then
		forceDefaultCollision(hookPart, false)
		hookPart.Transparency = 1
		hookPart.AssemblyLinearVelocity  = Vector3.zero
		hookPart.AssemblyAngularVelocity = Vector3.zero
		hookPart.Anchored = true
		Debris:AddItem(hookPart, 4)
	end

	-- ? Kalau ketemu permukaan: snap & anchor di atasnya
	if y then
		local halfH = (fishPart.Size and fishPart.Size.Y or 1.2) * 0.5
		local landP = Vector3.new(pXZ.X, y + halfH + 0.12, pXZ.Z)

		forceDefaultCollision(fishPart, true)
		fishPart.CFrame = CFrame.new(landP)
		for _,d in ipairs(fishPart:GetDescendants()) do if d:IsA("BasePart") then d.Anchored = true end end
		fishPart.Anchored = true

		-- ? Kalau TIDAK ketemu permukaan: jangan anchor di udara!
	else
		forceDefaultCollision(fishPart, true)
		fishPart.Anchored = false
		local v = fishPart.AssemblyLinearVelocity
		if v.Y > -10 then
			fishPart.AssemblyLinearVelocity = Vector3.new(v.X * 0.9, -24, v.Z * 0.9)
		end
	end

	-- Bersih-bersih trail & auto-hapus
	task.delay(0.20, function()
		local trail = fishPart:FindFirstChild("FishTail")
		if trail and trail:IsA("Trail") then
			trail.Lifetime = 0.25
			task.delay(0.30, function()
				if trail then trail.Enabled = false end
				local a0 = fishPart:FindFirstChild("TailA0")
				local a1 = fishPart:FindFirstChild("TailA1")
				if trail then Debris:AddItem(trail, 0.2) end
				if a0 then Debris:AddItem(a0, 0.2) end
				if a1 then Debris:AddItem(a1, 0.2) end
			end)
		end
		if fishPart and fishPart.Parent then
			Debris:AddItem(fishPart, 10)
		end
	end)
end

local function getFishToolTemplate(fishName: string, rarity: string?): Tool?
	if type(fishName) ~= "string" or fishName == "" then return nil end

	local function norm(s: string): string
		s = string.lower(s)
		return (s:gsub("[%s_%-]+", ""))
	end
	local target = norm(fishName)

	local function findInFolder(folder: Instance): Tool?
		if not folder then return nil end
		-- coba exact name dulu
		local exact = folder:FindFirstChild(fishName)
		if exact and exact:IsA("Tool") then return exact end
		-- lalu coba normalisasi
		for _, obj in ipairs(folder:GetChildren()) do
			if obj:IsA("Tool") and norm(obj.Name) == target then
				return obj
			end
		end
		return nil
	end

	local root = FishToolsRoot

	-- kalau ada rarity, fokus di folder rarity itu dulu
	if rarity and rarity ~= "" then
		if rarity == "Mythical" then rarity = "Mythic" end  -- alias, kalau kamu pakai
		local bucket = root:FindFirstChild(rarity)
		local hit = bucket and findInFolder(bucket)
		if hit then return hit end
	end

	-- kalau belum ketemu: scan semua bucket rarity
	for _, bucket in ipairs(root:GetChildren()) do
		if bucket:IsA("Folder") then
			local hit = findInFolder(bucket)
			if hit then return hit end
		end
	end

	-- last resort: deep scan (lebih mahal)
	for _, obj in ipairs(root:GetDescendants()) do
		if obj:IsA("Tool") and norm(obj.Name) == target then
			return obj
		end
	end
	return nil
end

-- Lempar ikan menuju player TANPA weld (anti-teleport), beam hanya visual
local function throwHookAndFishToLand(plr: Player, toolTpl: Tool, waterPos: Vector3)
	local rig = FishingShared.getRig(plr)
	if not rig or not rig.hook or not rig.hook.Parent then
		warn("[FishThrow] rig tidak siap:", plr and plr.Name or "?"); return false
	end
	local hookPart: BasePart  = rig.hook
	local beamObj: Beam?      = rig.beam
	local tipAtt: Attachment? = rig.tip
	local lookXZ: Vector3     = rig.look or Vector3.new(0, 0, -1)

	-- Helper: set collide mass
	local function setCollide(inst: Instance, on: boolean)
		if inst:IsA("BasePart") then
			inst.CollisionGroup = "Default"
			inst.CanCollide = on
			inst.CanQuery  = true
			inst.CanTouch  = true
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CollisionGroup = "Default"
				d.CanCollide = on
				d.CanQuery  = true
				d.CanTouch  = true
			end
		end
	end

	-- Helper: reset state hook (tanpa memindahkan posisinya)
	local function resetHookSafe()
		if not hookPart or not hookPart.Parent then return end
		forceDefaultCollision(hookPart, false)
		hookPart.Transparency = 1
		hookPart.AssemblyLinearVelocity  = Vector3.zero
		hookPart.AssemblyAngularVelocity = Vector3.zero
		pcall(function() hookPart:SetAttribute("CatchHold", false) end)
	end

	-- Tahan watcher cast sementara
	hookPart:SetAttribute("CatchHold", true)

	-- Bersihkan gaya/constraint pada hook
	for _, d in ipairs(hookPart:GetDescendants()) do
		if d:IsA("BodyMover") or d:IsA("VectorForce") or d:IsA("BodyForce")
			or d:IsA("BodyPosition") or d:IsA("BodyGyro") or d:IsA("AlignPosition")
			or d:IsA("AlignOrientation") or d:IsA("LinearVelocity") or d:IsA("AngularVelocity")
			or (d:IsA("Constraint") and not d:IsA("WeldConstraint")) then
			d:Destroy()
		end
	end
	local bf = hookPart:FindFirstChild("BuoyancyForce")
	if bf then bf:Destroy() end

	-- Ambil part ikan dari tool
	local mesh: BasePart? = toolTpl:FindFirstChildWhichIsA("MeshPart", true) or toolTpl:FindFirstChildWhichIsA("BasePart", true)
	if not mesh then
		warn("[FishThrow] tool tanpa Mesh/BasePart:", toolTpl.Name)
		return false
	end

	-- Clone ikan
	local fishPart: BasePart = mesh:Clone()
	fishPart.Name = "CaughtFish"
	fishPart.Anchored = false
	fishPart.Parent = WS

	-- Bersihkan sambungan/constraint bawaan ikan
	for _, d in ipairs(fishPart:GetDescendants()) do
		if d:IsA("Weld") or d:IsA("Snap") or d:IsA("Motor6D") then
			d:Destroy()
		elseif d:IsA("WeldConstraint") then
			d:Destroy()
		elseif d:IsA("BodyMover") or d:IsA("AlignPosition") or d:IsA("AlignOrientation")
			or d:IsA("LinearVelocity") or d:IsA("AngularVelocity") then
			d:Destroy()
		end
	end

	-- Posisi awal ikan di hook (visual start)
	fishPart.CFrame = hookPart.CFrame * CFrame.new(0, 0.05, 0)

	-- Attachment untuk Beam di ikan
	local ropeAtt = fishPart:FindFirstChild("FishRopeAtt")
	if not ropeAtt then
		ropeAtt = Instance.new("Attachment")
		ropeAtt.Name = "FishRopeAtt"
		ropeAtt.Parent = fishPart
	end

	-- Trail ekor (opsional)
	do
		for _, n in ipairs({"FishTail","TailA0","TailA1"}) do local o=fishPart:FindFirstChild(n); if o then o:Destroy() end end
		local a0 = Instance.new("Attachment"); a0.Name="TailA0"; a0.Position = Vector3.new(0, 0.05, 0.35); a0.Parent = fishPart
		local a1 = Instance.new("Attachment"); a1.Name="TailA1"; a1.Position = Vector3.new(0,-0.05,-0.60); a1.Parent = fishPart
		local trail = Instance.new("Trail")
		trail.Name = "FishTail"
		trail.Attachment0, trail.Attachment1 = a0, a1
		trail.Color = ColorSequence.new(Color3.new(1,1,1))
		trail.Transparency = NumberSequence.new(0.08, 0.95)
		trail.Lifetime = 0.7
		trail.LightEmission = 1
		trail.MinLength = 0.05
		trail.FaceCamera = true
		trail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0.00, 0.75),
			NumberSequenceKeypoint.new(0.35, 0.65),
			NumberSequenceKeypoint.new(1.00, 0.15)
		})
		trail.Enabled = true
		trail.Parent = fishPart
	end

	-- Non-collide saat mulai terbang
	setCollide(hookPart, false)
	setCollide(fishPart, false)

	-- Beam visual: tip -> ikan
	if beamObj and tipAtt then
		beamObj.Enabled = true
		beamObj.Attachment0 = tipAtt
		beamObj.Attachment1 = ropeAtt
		beamObj.CurveSize0, beamObj.CurveSize1 = 0, 0
	end

	-- Target ke HRP (fallback arah look)
	local function playerTargetDirect(startPos: Vector3)
		local hrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			return hrp.Position + Vector3.new(0, 1.2, 0)
		end
		return startPos + lookXZ * 28 + Vector3.new(0, 1, 0)
	end

	-- Naikkan bila tepat di air
	do
		local rp = RaycastParams.new()
		rp.IgnoreWater = false
		rp.FilterType  = Enum.RaycastFilterType.Include
		rp.FilterDescendantsInstances = { WS.Terrain }
		local from = hookPart.Position + Vector3.new(0, 80, 0)
		local hit = WS:Raycast(from, Vector3.new(0, -1, 0) * 200, rp)
		if hit then
			local y = math.max(hookPart.Position.Y, hit.Position.Y + 0.8)
			local p = Vector3.new(hookPart.Position.X, y, hookPart.Position.Z)
			hookPart.CFrame = CFrame.new(p, p + Vector3.new(0, 0, 1))
			fishPart.CFrame = hookPart.CFrame * CFrame.new(0, 0.05, 0)
		end
	end

	-- === Balistik: tembak ke player ===
	local startPos = hookPart.Position
	local target   = playerTargetDirect(startPos)
	local dx       = target - startPos
	local distXZ   = (dx * Vector3.new(1, 0, 1)).Magnitude

	local function remap(v, a1, b1, a2, b2)
		return a2 + (math.clamp(v, a1, b1) - a1) * (b2 - a2) / (b1 - a1)
	end

	local T  = remap(distXZ, 10, 48, 0.56, 0.90) + (math.random(-12,12) * 0.001)
	local g  = workspace.Gravity
	local v0 = (dx - Vector3.new(0, -g, 0) * (0.5 * T * T)) / T
	if v0.Y < 20 then v0 = Vector3.new(v0.X, 20, v0.Z) end
	v0 = Vector3.new(v0.X * 1.12, v0.Y, v0.Z * 1.12)

	pcall(function() hookPart:SetNetworkOwner(nil) end)
	hookPart.AssemblyAngularVelocity = Vector3.new(0, 8, 0)
	hookPart.AssemblyLinearVelocity  = v0
	fishPart.AssemblyLinearVelocity  = v0

	-- Hook segera “dimatikan”
	resetHookSafe()

	-- === Natural landing tanpa anchor ===
	local enableCollideAt = os.clock() + 0.08
	local beamOffAt       = os.clock() + 0.60
	local done = false

	-- gate waktu untuk finalize di air
	local startT = os.clock()
	local waterFinalizeMinT = startT + 0.35

	local conn
	conn = RunService.Heartbeat:Connect(function()
		if done then conn:Disconnect(); return end
		if not fishPart or not fishPart.Parent then conn:Disconnect(); return end

		-- Aktifkan collide setelah sedikit waktu
		if os.clock() >= enableCollideAt then
			forceDefaultCollision(fishPart, true)
		end

		-- Raycast pendek ke bawah
		local p = fishPart.Position
		local rp = RaycastParams.new()
		rp.IgnoreWater = false
		rp.FilterType  = Enum.RaycastFilterType.Exclude
		local ignoreList = { fishPart }
		if plr.Character then table.insert(ignoreList, plr.Character) end
		if hookPart and hookPart.Parent then table.insert(ignoreList, hookPart) end
		rp.FilterDescendantsInstances = ignoreList

		local from = p + Vector3.new(0, 8, 0)
		local hit  = workspace:Raycast(from, Vector3.new(0, -1, 0) * 16, rp)

		local nearSolid = false
		local dist = math.huge
		if hit then
			dist = (p.Y - hit.Position.Y)
			if hit.Material ~= Enum.Material.Water then
				nearSolid = (dist <= 5.0)
			end
		end
		if beamObj and (nearSolid or os.clock() >= beamOffAt) then
			beamObj.Enabled = false
			beamObj.CurveSize0, beamObj.CurveSize1 = 0, 0
			beamObj.Attachment1 = nil
		end

		-- Finalize bila menyentuh air (aman)
		if hit and hit.Material == Enum.Material.Water then
			local vy = fishPart.AssemblyLinearVelocity.Y
			if os.clock() >= waterFinalizeMinT and dist <= 1.25 and vy <= -2.0 then
				if beamObj then
					beamObj.Enabled = false
					beamObj.CurveSize0, beamObj.CurveSize1 = 0, 0
					beamObj.Attachment1 = nil
				end
				forceDefaultCollision(fishPart, true)
				local v = fishPart.AssemblyLinearVelocity
				if v.Y > -12 then
					fishPart.AssemblyLinearVelocity = Vector3.new(v.X * 0.85, -18, v.Z * 0.85)
				end
				pcall(function()
					fishPart.CustomPhysicalProperties = PhysicalProperties.new(2, 0.6, 0, 1, 1)
				end)
				Debris:AddItem(fishPart, 8)
				done = true
				conn:Disconnect()
				return
			end
		end

		-- Finalize ketika menyentuh permukaan padat
		local touching = {}
		pcall(function() touching = fishPart:GetTouchingParts() end)
		if touching and #touching > 0 then
			Debris:AddItem(fishPart, 10)
			done = true
			conn:Disconnect()
			return
		end
	end)

	return true
end

-- ====== TRIGGER SAAT BERHASIL MENANGKAP (via Attribute) ======
local function onPlayerAdded(plr: Player)
	lastSeq[plr] = plr:GetAttribute("CatchSeq") or 0

	-- Saat CatchSeq berubah & naik ? lakukan lempar visual
	plr:GetAttributeChangedSignal("CatchSeq"):Connect(function()
		local newSeq = plr:GetAttribute("CatchSeq") or 0
		if newSeq <= (lastSeq[plr] or 0) then return end
		lastSeq[plr] = newSeq

		-- Data hasil
		local fishName   = plr:GetAttribute("LastFishName")
		local fishRarity = plr:GetAttribute("LastFishRarity")
		if not fishName or not fishRarity then
			return
		end

		local tpl = getFishToolTemplate(tostring(fishName), tostring(fishRarity))
		if not tpl then
			return
		end

		-- Posisi air terakhir (opsional, hanya untuk arah)
		local waterPos = (castState[plr] and castState[plr].waterPos)
			or (plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") and plr.Character.HumanoidRootPart.Position)
			or Vector3.zero

		local ok = throwHookAndFishToLand(plr, tpl, waterPos)
		if not ok then
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	onPlayerAdded(p)
end

-- Ketika pemain keluar, bersihkan state
Players.PlayerRemoving:Connect(function(plr)
	castState[plr] = nil
	lastSeq[plr]   = nil
end)
