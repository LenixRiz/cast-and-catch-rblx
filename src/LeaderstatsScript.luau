local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local playerData = DataStoreService:GetDataStore("PlayerData")
local orderedDS = DataStoreService:GetOrderedDataStore("TopMoney")


Players.PlayerAdded:Connect(function(player)
	local userId = tostring(player.UserId)

	-- Leaderstats folder
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	-- Level
	local level = Instance.new("IntValue")
	level.Name = "Level"
	level.Value = 1
	level.Parent = leaderstats

	-- Money (di leaderstats dan root player)
	local moneyValue = Instance.new("IntValue")
	moneyValue.Name = "K$" -- Tampil di leaderboard
	moneyValue.Parent = leaderstats

	local money = Instance.new("IntValue")
	money.Name = "MoneyData" -- Disimpan secara internal
	money.Parent = player

	-- Ambil dari DataStore
	local success, data = pcall(function()
		return playerData:GetAsync(userId)
	end)

	if success and data then
		money.Value = data.Money or 200
	else
		money.Value = 200
	end

	-- Sinkronkan ke leaderstats
	moneyValue.Value = money.Value
	local lastLeaderboardPush = 0
	money:GetPropertyChangedSignal("Value"):Connect(function()
		moneyValue.Value = money.Value
		local now = os.clock()
		if now - lastLeaderboardPush >= 30 then
			lastLeaderboardPush = now
			task.spawn(function()
				pcall(function()
					orderedDS:SetAsync("K$" .. player.UserId, money.Value)
				end)
			end)
		end
	end)

	-- ?? Tambahkan NameTag saat karakter muncul
	player.CharacterAdded:Connect(function(character)
		task.wait(0.2) -- beri waktu load

		local head = character:FindFirstChild("Head") or character:WaitForChild("Head", 5)
		if not head then return end

		-- Bersihkan semua NameTag lama (antisipasi double)
		for _, child in pairs(head:GetChildren()) do
			if child:IsA("BillboardGui") and child.Name == "NameTag" then
				child:Destroy()
			end
		end

		-- Clone dan setup NameTag
		local tag = ReplicatedStorage:WaitForChild("NameTag"):Clone()
		tag.Adornee = head
		tag.Parent = head

		local nameLabel = tag:FindFirstChild("NameLabel")
		local levelLabel = tag:FindFirstChild("LevelLabel")

		local function updateText()
			local levelValue = level.Value

			if nameLabel then
				nameLabel.Text = player.Name
			end

			if levelLabel then
				levelLabel.RichText = true
				levelLabel.Text = "<font color=\"rgb(255, 100, 0)\">Lv. " .. tostring(levelValue) .. "</font>"
			end
		end

		updateText()
		level:GetPropertyChangedSignal("Value"):Connect(updateText)
	end)
end)

-- ?? Simpan saat player keluar
Players.PlayerRemoving:Connect(function(player)
	local userId = tostring(player.UserId)
	local money = player:FindFirstChild("MoneyData")

	if money then
		-- Simpan ke DataStore utama
		pcall(function()
			playerData:SetAsync(userId, {
				Money = money.Value
			})
		end)

		-- Simpan ke OrderedDataStore
		pcall(function()
			orderedDS:SetAsync("K$" .. player.UserId, money.Value)
		end)
	end
end)