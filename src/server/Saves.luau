--!nocheck
-- City saves in a Roblox DataStore, one per mayor (keyed by their Roblox user id).
-- DataStores only work in a published place; in Studio, "Enable Studio Access to API
-- Services" must also be on. Without them the game still runs, just without saving.

local DataStoreService = game:GetService("DataStoreService")

local Saves = {}

local store = nil
pcall(function()
	store = DataStoreService:GetDataStore("MayorStreetCity_v1")
end)

local function key(userId)
	return "city_" .. tostring(userId)
end

-- Returns data (or nil for a new mayor), or nil plus an error message.
function Saves.load(userId)
	if not store then
		return nil, "DataStores are unavailable"
	end
	local ok, result = pcall(function()
		return store:GetAsync(key(userId))
	end)
	if ok then
		return result, nil
	end
	return nil, tostring(result)
end

function Saves.save(userId, data)
	if not store then
		return false, "DataStores are unavailable"
	end
	local ok, err = pcall(function()
		store:SetAsync(key(userId), data, { userId })
	end)
	return ok, if ok then nil else tostring(err)
end

return Saves
