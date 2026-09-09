-- RodConfig.lua
local RodConfig = {}

-- Urutan progresi dari awal ke akhir
RodConfig.List = {
	-- Common rods
	{ id="Wooden",   displayName="Wooden Rod", luck=0,  speed=0,  weight=10,  tier="Common" },
	{ id="red",     displayName="Red Rod",   luck=10,  speed=3,  weight=50,  tier="Common" },
	{ id="iron",    displayName="Iron Rod",  luck=20, speed=6,  weight=120, tier="Common" },

	-- Uncommon rods
	{ id="seafarerscane",    displayName="Seafarer's Cane",    luck=30, speed=10, weight=210, tier="Uncommon" },
	{ id="coralspinestar",       displayName="Coralspine Star",luck=40, speed=15, weight=750, tier="Uncommon" },
	{ id="tidesilvercaster", displayName="Tidesilver Caster",  luck=60, speed=18, weight=1500, tier="Uncommon" },

	-- Special rods
	{ id="dynamoarc",      displayName="Dynamo Arc",     luck=125, speed=25, weight=8000, tier="Special" },
	{ id="mysticaltornado", displayName="Mystical Tornado", luck=155, speed=30, weight=15000, tier="Special" },

	-- Legendary rods
	{ id="abysslantern",     displayName="Abyss Lantern",    luck=250,  speed=40, weight=50000, tier="Legendary" },
	{ id="poseidonstrident", displayName="Poseidon's Trident", luck=350, speed=50, weight=100000, tier="Legendary" },
}

-- Index cepat by id & by displayName
RodConfig.ById = {}
RodConfig.ByName = {}

for index, data in ipairs(RodConfig.List) do
	data.index = index -- simpan posisi progresi
	RodConfig.ById[data.id] = data
	RodConfig.ByName[string.lower(data.displayName)] = data
end

-- Helper: ambil data rod by id (string) atau index (number)
function RodConfig.Get(rodKey)
	if typeof(rodKey) == "number" then
		return RodConfig.List[rodKey]
	elseif typeof(rodKey) == "string" then
		return RodConfig.ById[rodKey] or RodConfig.ByName[string.lower(rodKey)]
	end
	return nil
end

-- Helper: next tier (berdasarkan urutan di List)
function RodConfig.GetNext(rodKey)
	local current = RodConfig.Get(rodKey)
	if not current then return nil end
	return RodConfig.List[current.index + 1]
end

-- Helper: previous tier
function RodConfig.GetPrev(rodKey)
	local current = RodConfig.Get(rodKey)
	if not current then return nil end
	return RodConfig.List[current.index - 1]
end

-- Optional: normalisasi luck jadi rasio (0–3.5 untuk 350%)
function RodConfig.GetLuckRatio(rodKey)
	local r = RodConfig.Get(rodKey)
	return r and (r.luck / 100) or nil
end

return RodConfig
