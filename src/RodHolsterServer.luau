-- RodHolsterServer (Accessory + Debug v2)
-- Tempatkan file ini di ServerScriptService. Script server-only.
-- Flow yang DIINGINKAN (sesuai penjelasan kamu):
--  - Saat Tool di-EQUIP ? holster (aksesoris punggung) HILANG.
--  - Saat Tool di-UNEQUIP ? holster MUNCUL (clone dari ReplicatedStorage.FishingRodsClient/<HolsterId atau nama Tool>). 
--  - Posisi/rotasi bisa kamu atur di model sumber: Part bernama "HolsterPivot" (sudah kamu set). Script ini tidak memaksa offset tambahan.

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")

-- Folder sumber kosmetik (model per rod). Wajib ada Part "HolsterPivot" sebagai pivot/handle.
local SRC = RS:WaitForChild("FishingRodsClient")

-- Konfigurasi rig
local BACK_BONE_R15  = "UpperTorso"
local BACK_BONE_R6   = "Torso"
local ATTACH_NAME    = "BodyBackAttachment" -- attachment standar Roblox untuk punggung

-- --- Util dasar
local function isRod(tool: Instance): boolean
	if not tool or not tool:IsA("Tool") then return false end
	if tool:GetAttribute("IsFishingRod") == true then return true end
	local id = tool:GetAttribute("HolsterId") or tool.Name
	if SRC:FindFirstChild(id) then return true end
	local n = string.lower(tool.Name)
	return n:find("rod") ~= nil or n:find("fishing") ~= nil
end

local function getTorso(char: Model)
	return char:FindFirstChild(BACK_BONE_R15) or char:FindFirstChild(BACK_BONE_R6)
end

local function ensureBackAttachment(torso: Instance)
	local att = torso:FindFirstChild(ATTACH_NAME)
	if not att then
		att = Instance.new("Attachment")
		att.Name = ATTACH_NAME
		att.Parent = torso
	end
	return att
end

-- Hapus SEMUA holster di character (single-slot policy)
local function clearAllHolsters(char: Model)
	if not char then return end
	for _,acc in ipairs(char:GetChildren()) do
		if acc:IsA("Accessory") then
			if acc.Name == "HolsteredRod" or acc.Name:match("^Holster_") or acc:GetAttribute("IsHolster") == true then
				acc:Destroy()
			end
		end
	end
end


-- Bangun Accessory dari model sumber. Menggunakan HolsterPivot sebagai Handle.
local function buildAccessoryFromSource(tool: Tool)
	local id  = tool:GetAttribute("HolsterId") or tool.Name
	local src = SRC:FindFirstChild(id)
	if not (src and src:IsA("Model")) then
		return nil
	end

	local clone = src:Clone()
	local pivot = clone:FindFirstChild("HolsterPivot")
	if not (pivot and pivot:IsA("BasePart")) then
		clone:Destroy()
		return nil
	end

	-- Jadikan HolsterPivot sebagai Handle Accessory
	local accessory = Instance.new("Accessory")
	accessory.Name = "HolsteredRod"              -- <- NAMA KONSTAN
	accessory:SetAttribute("IsHolster", true)    -- <- PENANDA
	accessory.AttachmentPoint = CFrame.new() -- akan mengandalkan named attachment
	accessory.Archivable = true
	accessory.Parent = nil -- penting: jangan parent ke character sebelum AddAccessory

	-- Pastikan pivot bernama "Handle" dan berada langsung di bawah Accessory
	pivot.Name = "Handle"
	pivot.Parent = accessory

	-- Nonaktifkan collide, dsb pada seluruh part dalam clone
	for _,d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch   = false
			d.CanQuery   = false
			d.Massless   = true
		end
	end

	-- Weld semua BasePart lain ke Handle
	for _,d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") and d ~= pivot then
			local w = Instance.new("WeldConstraint")
			w.Part0 = pivot
			w.Part1 = d
			w.Parent = pivot
		end
		-- Parent semua node non-Handle ke Accessory agar ikut terbawa
		if d:IsA("Instance") and d ~= pivot and d.Parent ~= accessory then
			-- selamatkan hierarchy kosmetik di bawah Accessory
		end
	end
	-- Pindah semua child non-Handle dari clone ke Accessory
	for _,child in ipairs(clone:GetChildren()) do
		if child ~= pivot then
			child.Parent = accessory
		end
	end
	clone:Destroy()

	-- Attachment pada Handle yang namanya sama dengan attachment punggung rig
	local att = Instance.new("Attachment")
	att.Name = ATTACH_NAME
	att.Parent = pivot -- Handle

	-- buang jejak yang bisa bikin sistem lain salah paham
	pcall(function() accessory:SetAttribute("IsFishingRod", nil) end)
	local tip = accessory:FindFirstChild("RodTipAttachment", true)
	if tip then tip:Destroy() end

	return accessory
end

-- Pasang holster ke character (dipanggil saat UNEQUIP)
local function attachHolster(char: Model, tool: Tool)
	if not char or not char.Parent then return end

	-- kalau tool sedang di tangan ? pastikan TIDAK ada holster
	if tool and tool.Parent == char then
		clearAllHolsters(char)
		return
	end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local torso = getTorso(char)
	if not humanoid or not torso then return end

	clearAllHolsters(char)
	ensureBackAttachment(torso)

	local accessory = buildAccessoryFromSource(tool)
	if not accessory then return end

	local ok, err = pcall(function()
		humanoid:AddAccessory(accessory)
	end)
	if ok then
	else
		accessory:Destroy()
	end
end

-- Event binding untuk satu Tool
local function bindTool(char: Model, backpack: Instance, tool: Tool)
	if not isRod(tool) then return end
	if tool:GetAttribute("HolsterBound") then return end
	tool:SetAttribute("HolsterBound", true)

	-- Seed state saat pertama kali dikenali
	task.defer(function()
		if tool.Parent == backpack then
			attachHolster(char, tool)
		elseif tool.Parent == char then
			clearAllHolsters(char)
		end
	end)

	-- Gunakan hanya Equipped/Unequipped
	tool.Equipped:Connect(function()
		clearAllHolsters(char)
	end)

	tool.Unequipped:Connect(function()
		task.defer(function()
			attachHolster(char, tool)
		end)
	end)

	-- Fallback (jangan duplicate kalau event utama sudah jalan)
	tool.AncestryChanged:Connect(function(_, newParent)
		if not char.Parent then return end
		if not tool:IsDescendantOf(char) and newParent == backpack then
			-- Tool balik ke backpack ? attach holster (single-slot: clear di dalam attach)
			task.defer(function()
				attachHolster(char, tool)
			end)
		end
	end)
end

local function onCharacterAdded(plr: Player, char: Model)
	local backpack = plr:WaitForChild("Backpack", 5)
	if not backpack then
		return
	end

	-- Bind semua tool yang sudah ada
	for _,t in ipairs(backpack:GetChildren()) do
		if t:IsA("Tool") then bindTool(char, backpack, t) end
	end
	-- Bind tool baru
	backpack.ChildAdded:Connect(function(inst)
		if inst:IsA("Tool") then bindTool(char, backpack, inst) end
	end)
	-- Clear saat tool hilang dari backpack
	backpack.ChildRemoved:Connect(function(inst)
		if inst:IsA("Tool") and isRod(inst) then
			clearAllHolsters(char)
		end
	end)

	-- Jika ada equip langsung (drag ke character)
	char.ChildAdded:Connect(function(inst)
		if inst:IsA("Tool") and isRod(inst) then
			clearAllHolsters(char)
		end
	end)
end

Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(char)
		onCharacterAdded(plr, char)
		clearAllHolsters(char)
	end)
end)

-- Pemain yang sudah ada (Play Solo)
for _,plr in ipairs(Players:GetPlayers()) do
	plr.CharacterAdded:Connect(function(char)
		onCharacterAdded(plr, char)
		clearAllHolsters(char)
	end)
end
