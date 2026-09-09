local PhysicsService = game:GetService("PhysicsService")
local Players        = game:GetService("Players")

local GROUP = "Characters"

-- Buat group (aman walau sudah ada) & non-collidable dengan dirinya sendiri
pcall(function() PhysicsService:CreateCollisionGroup(GROUP) end)
PhysicsService:CollisionGroupSetCollidable(GROUP, GROUP, false)

-- Helper: pasang group ke semua BasePart di dalam model (karakter, aksesori, tool handle, dsb.)
local function tagAllParts(model: Instance)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CollisionGroup = GROUP
		end
	end
	-- parts baru yang muncul belakangan (aksesori/tool/rig rebuild)
	model.DescendantAdded:Connect(function(obj)
		if obj:IsA("BasePart") then
			obj.CollisionGroup = GROUP
		end
	end)
end

-- Ketika karakter player spawn
local function onCharacter(char: Model)
	-- pastikan benar-benar karakter humanoid
	if not char:FindFirstChildOfClass("Humanoid") then return end
	tagAllParts(char)
end

Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(onCharacter)
	if plr.Character then onCharacter(plr.Character) end
end)

-- Opsional: otomatis untuk NPC humanoid juga
workspace.ChildAdded:Connect(function(inst)
	if inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") then
		tagAllParts(inst)
	end
end)
