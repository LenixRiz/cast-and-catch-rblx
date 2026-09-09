-- ZoneService.lua
-- Deteksi spot berdasarkan Folder spot yang berisi Part "ZoneBox"

local ZoneService = {}
local FishingSpots = workspace:WaitForChild("FishingSpots")

-- Kumpulkan semua ZoneBox + meta dari FOLDERS spot (yang punya Attributes)
local spotParts = {}         -- { part, island, spotName, spotType, priority, volume }
local whitelist = {}

local function scan()
	table.clear(spotParts)
	table.clear(whitelist)

	for _, islandFolder in ipairs(FishingSpots:GetChildren()) do
		if islandFolder:IsA("Folder") then
			for _, spotFolder in ipairs(islandFolder:GetChildren()) do
				if spotFolder:IsA("Folder") and spotFolder:GetAttribute("Island") then
					local meta = {
						island   = spotFolder:GetAttribute("Island"),
						spotName = spotFolder:GetAttribute("SpotName") or spotFolder.Name,
						spotType = spotFolder:GetAttribute("SpotType") or "pond",
						priority = spotFolder:GetAttribute("Priority") or 5,
					}
					for _, obj in ipairs(spotFolder:GetChildren()) do
						if obj:IsA("BasePart") then
							local volume = obj.Size.X * obj.Size.Y * obj.Size.Z
							table.insert(spotParts, {
								part = obj, volume = volume,
								island = meta.island, spotName = meta.spotName,
								spotType = meta.spotType, priority = meta.priority,
							})
							table.insert(whitelist, obj)
						end
					end
				end
			end
		end
	end
end
scan()

-- Spatial query setup
local params = OverlapParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = whitelist

-- Cari spot di sekitar CFrame (HRP atau pelampung)
function ZoneService.GetZoneAtCFrame(cf: CFrame)
	if #whitelist == 0 then
		-- default global jika belum ada spot sama sekali
		return { island = "Moonwater Bay", spotName = "OpenSea", spotType = "ocean" }
	end

	local hits = workspace:GetPartBoundsInBox(cf, Vector3.new(2, 4, 2), params)
	if #hits == 0 then
		-- di air tapi bukan di spot mana pun ? OpenSea (default)
		return { island = "Moonwater Bay", spotName = "OpenSea", spotType = "ocean" }
	end

	-- pilih berdasarkan priority lalu volume terkecil (lebih spesifik menang)
	local best, bestPrio, bestVol
	for _, hit in ipairs(hits) do
		for _, info in ipairs(spotParts) do
			if info.part == hit then
				local p, v = info.priority, info.volume
				if (not best)
					or (p < bestPrio)
					or (p == bestPrio and v < bestVol) then
					best, bestPrio, bestVol = info, p, v
				end
			end
		end
	end
	return { island = best.island, spotName = best.spotName, spotType = best.spotType }
end

-- Helper untuk Character
function ZoneService.GetZoneForCharacter(char: Model)
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return { island = "Moonwater Bay", spotName = "OpenSea", spotType = "ocean" }
	end
	return ZoneService.GetZoneAtCFrame(hrp.CFrame)
end

return ZoneService
