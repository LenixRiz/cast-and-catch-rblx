local Players        = game:GetService("Players")
local ServerStorage  = game:GetService("ServerStorage")

local JACK           = workspace:WaitForChild("Jack")
local HRP            = JACK:WaitForChild("HumanoidRootPart")

-- === Pastikan prompt ada & properti tampilannya benar ===
local Prompt = HRP:FindFirstChildOfClass("ProximityPrompt")
if not Prompt then
	Prompt = Instance.new("ProximityPrompt")
	Prompt.Parent = HRP
end
-- set properti agar pasti kelihatan & mudah diaktifkan
Prompt.Name = "ProximityPrompt"              -- biar konsisten
Prompt.Enabled = true
Prompt.HoldDuration = 0                      -- tekan langsung
Prompt.MaxActivationDistance = 12            -- jarak aman
Prompt.RequiresLineOfSight = false           -- tidak perlu LOS
Prompt.KeyboardKeyCode = Enum.KeyCode.E
Prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
Prompt.ClickablePrompt = true                -- bisa di-klik (mobile/PC)
Prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
Prompt.ObjectText = "Diving equipment"
Prompt.ActionText = "Buy (K$70000)"


-- === Konfigurasi toko ===
local TOOLS_DIR      = ServerStorage:WaitForChild("Tools")
local TOOL_NAME      = "Diving"
local PRICE          = 70000

local function getMoneyValueObj(plr: Player): IntValue?
	return plr:FindFirstChild("MoneyData") :: IntValue?
end

local function getOwnedFolder(plr: Player): Folder
	local f = plr:FindFirstChild("OwnedTools")
	if not f then
		f = Instance.new("Folder")
		f.Name = "OwnedTools"
		f.Parent = plr
	end
	return f
end

local function isOwned(plr: Player): boolean
	return getOwnedFolder(plr):FindFirstChild(TOOL_NAME) ~= nil
end

local function markOwned(plr: Player)
	local f = getOwnedFolder(plr)
	if not f:FindFirstChild(TOOL_NAME) then
		local flag = Instance.new("BoolValue")
		flag.Name = TOOL_NAME
		flag.Value = true
		flag.Parent = f
	end
end

local function giveTool(plr: Player): boolean
	local src = TOOLS_DIR:FindFirstChild(TOOL_NAME)
	if not (src and src:IsA("Tool")) then
		warn("[JackShop] Tool '"..TOOL_NAME.."' tidak ada di ServerStorage/Tools")
		return false
	end
	-- bersihkan duplikat
	local function cleanup(container: Instance?)
		if not container then return end
		for _, t in ipairs(container:GetChildren()) do
			if t:IsA("Tool") and t.Name == TOOL_NAME then t:Destroy() end
		end
	end
	local char = plr.Character
	if char then cleanup(char) end
	cleanup(plr:FindFirstChildOfClass("Backpack"))

	local tool = src:Clone()
	tool.Parent = plr:WaitForChild("Backpack") -- kalau mau auto-equip: tool.Parent = char
	return true
end

local function flashAction(text: string, dura: number)
	local prev = Prompt.ActionText
	Prompt.ActionText = text
	task.delay(dura, function()
		if Prompt.ActionText == text then Prompt.ActionText = prev end
	end)
end

local busy: {[Player]: boolean} = {}

Prompt.Triggered:Connect(function(plr: Player)
	if busy[plr] then return end
	busy[plr] = true

	local money = getMoneyValueObj(plr)
	if not (money and money:IsA("IntValue")) then
		flashAction("MoneyData missing", 1.2)
		busy[plr] = nil
		return
	end

	if isOwned(plr) then
		if giveTool(plr) then flashAction("Owned ? Given", 1.0) else flashAction("Tool missing", 1.0) end
		busy[plr] = nil
		return
	end

	if (money.Value or 0) < PRICE then
		flashAction("Sorry need K$"..PRICE, 1.2)
		busy[plr] = nil
		return
	end

	money.Value = money.Value - PRICE
	markOwned(plr)
	if giveTool(plr) then flashAction("Bought!", 1.0) else flashAction("Bought (no tool?)", 1.2) end

	busy[plr] = nil
end)

-- Optional: re-give saat respawn jika sudah owned
Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function()
		if isOwned(plr) then task.defer(function() giveTool(plr) end) end
	end)
end)