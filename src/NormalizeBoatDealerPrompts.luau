local CollectionService = game:GetService("CollectionService")

local function normalizePrompt(pp: ProximityPrompt)
	pp.Name = "BoatDealerPrompt"
	pp.Enabled = true
	pp.ActionText = "Open Shop"
	pp.ObjectText = "Boat Dealer"
	pp.HoldDuration = 0
	pp.RequiresLineOfSight = false
	pp.MaxActivationDistance = math.max(16, pp.MaxActivationDistance)
	pp.UIOffset = Vector2.new(0, -20)
	pp.KeyboardKeyCode = Enum.KeyCode.E
	pp.GamepadKeyCode = Enum.KeyCode.ButtonX
	pp.ClickablePrompt = true
	pp.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	pp:SetAttribute("BoatShop", true) -- << penanda yang dipakai client
end

local function isDealerModel(inst: Instance): boolean
	return inst:IsA("Model")
		and (
			inst.Name:match("^Morgan")               -- Morgan, Morgan (1), Morgan_2, dll
			or inst:GetAttribute("IsBoatDealer") == true
			or CollectionService:HasTag(inst, "BoatDealer")
		)
end

local function setupDealer(model: Model)
	local hrp = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart", true)
	if not hrp then return end

	-- pakai prompt yang sudah ada di HRP; kalau belum ada, buat baru
	local found = false
	for _, ch in ipairs(hrp:GetChildren()) do
		if ch:IsA("ProximityPrompt") then
			normalizePrompt(ch)
			found = true
		end
	end
	if not found then
		local pp = Instance.new("ProximityPrompt")
		pp.Parent = hrp
		normalizePrompt(pp)
	end
end

-- scan awal semua Morgan* di Workspace
for _, inst in ipairs(workspace:GetDescendants()) do
	if isDealerModel(inst) then
		setupDealer(inst :: Model)
	end
end

-- tangani copy/paste atau prompt baru
workspace.DescendantAdded:Connect(function(inst)
	if isDealerModel(inst) then
		setupDealer(inst :: Model)
	elseif inst:IsA("ProximityPrompt") then
		local m = inst:FindFirstAncestorOfClass("Model")
		if m and isDealerModel(m) then
			normalizePrompt(inst)
		end
	end
end)
