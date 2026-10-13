local GameConfig = require "Common.Config.GameConfig"

local InventoryService = {
    Name = "InventoryService",
    FeatureFlag = "Inventory",
    Dependencies = {},
}

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function CopyItem(item)
    if not item then return nil end
    return {
        itemId = item.itemId,
        kind = item.kind,
        typeId = item.typeId,
        displayName = item.displayName,
        count = item.count,
        iconIndex = item.iconIndex,
        sequence = item.sequence,
    }
end

function InventoryService:ValidateConfig(context)
    if context.Side ~= "Server" then return true end
    local errors = {}
    if type(GameConfig.ChickenTypes) ~= "table" then
        errors[#errors + 1] = "ChickenTypes 必须是 table"
    end
    for typeId, config in pairs(GameConfig.ChickenTypes or {}) do
        if type(typeId) ~= "string" or typeId == "" or type(config) ~= "table" then
            errors[#errors + 1] = "鸡配置项无效: " .. tostring(typeId)
        elseif config.Enabled then
            if not IsPositiveInteger(config.TemplateRootId) then
                errors[#errors + 1] = typeId .. ".TemplateRootId 必须是正整数"
            end
            if not IsPositiveInteger(config.ChickenIconIndex) then
                errors[#errors + 1] = typeId .. ".ChickenIconIndex 必须是正整数"
            end
        end
    end
    return #errors == 0, errors
end

function InventoryService:Start(context)
    if context.Side ~= "Server" then return end

    local runtime = {
        Players = {},
        GlobalSequence = 0,
        PreleaveCallback = nil,
    }

    local function EnsurePlayer(playerId)
        local data = runtime.Players[playerId]
        if not data then
            data = { Chickens = {}, ChickenOrder = {}, Eggs = {} }
            runtime.Players[playerId] = data
        end
        return data
    end

    local function FindEggConfig(eggTypeId)
        for chickenType, chickenConfig in pairs(GameConfig.ChickenTypes) do
            local egg = chickenConfig.Egg
            if egg and egg.EggTypeId == eggTypeId then
                return chickenType, chickenConfig, egg
            end
        end
        return nil
    end

    function runtime:GetSnapshot(playerId)
        local result = {}
        local data = self.Players[playerId]
        if not data then return result end
        for _, itemId in ipairs(data.ChickenOrder) do
            local item = data.Chickens[itemId]
            if item then result[#result + 1] = CopyItem(item) end
        end
        for _, eggTypeId in ipairs(GameConfig.EggTypeOrder or {}) do
            local item = data.Eggs[eggTypeId]
            if item and item.count > 0 then result[#result + 1] = CopyItem(item) end
        end
        return result
    end

    function runtime:GetItem(playerId, itemId)
        local data = self.Players[playerId]
        if not data then return nil end
        local item = data.Chickens[itemId]
        if item then return CopyItem(item) end
        for _, egg in pairs(data.Eggs) do
            if egg.itemId == itemId then return CopyItem(egg) end
        end
        return nil
    end

    function runtime:HasItem(playerId, itemId)
        return self:GetItem(playerId, itemId) ~= nil
    end

    local function PublishChanged(playerId, reason)
        context.Events:Publish("InventoryChanged", {
            playerId = playerId,
            reason = reason,
            items = runtime:GetSnapshot(playerId),
        })
    end

    function runtime:AddChicken(playerId, chickenType)
        local config = GameConfig.ChickenTypes[chickenType]
        if not IsPositiveInteger(playerId) or not config or config.Enabled ~= true then
            return nil, "invalid_chicken_add"
        end
        self.GlobalSequence = self.GlobalSequence + 1
        local itemId = "chicken:" .. tostring(playerId) .. ":" .. tostring(self.GlobalSequence)
        local item = {
            itemId = itemId,
            kind = "Chicken",
            typeId = chickenType,
            displayName = config.DisplayName,
            count = 1,
            iconIndex = config.ChickenIconIndex,
            sequence = self.GlobalSequence,
        }
        local data = EnsurePlayer(playerId)
        data.Chickens[itemId] = item
        data.ChickenOrder[#data.ChickenOrder + 1] = itemId
        PublishChanged(playerId, "add_chicken")
        return CopyItem(item)
    end

    function runtime:AddEgg(playerId, eggTypeId, count)
        if not IsPositiveInteger(playerId) or not IsPositiveInteger(count) then
            return nil, "invalid_egg_add"
        end
        local _, chickenConfig, eggConfig = FindEggConfig(eggTypeId)
        if not chickenConfig or not eggConfig or eggConfig.Enabled ~= true then
            return nil, "egg_type_disabled_or_missing"
        end
        local data = EnsurePlayer(playerId)
        local item = data.Eggs[eggTypeId]
        if not item then
            self.GlobalSequence = self.GlobalSequence + 1
            item = {
                itemId = "egg:" .. eggTypeId,
                kind = "Egg",
                typeId = eggTypeId,
                displayName = eggTypeId,
                count = 0,
                iconIndex = eggConfig.IconIndex,
                sequence = self.GlobalSequence,
            }
            data.Eggs[eggTypeId] = item
        end
        item.count = item.count + count
        PublishChanged(playerId, "add_egg")
        return CopyItem(item)
    end

    function runtime:RemoveItem(playerId, itemId, reason)
        local data = self.Players[playerId]
        if not data or type(itemId) ~= "string" then return false, "item_not_found" end
        if data.Chickens[itemId] then
            data.Chickens[itemId] = nil
            for index = #data.ChickenOrder, 1, -1 do
                if data.ChickenOrder[index] == itemId then
                    table.remove(data.ChickenOrder, index)
                    break
                end
            end
            PublishChanged(playerId, reason or "remove_chicken")
            return true
        end
        for eggTypeId, item in pairs(data.Eggs) do
            if item.itemId == itemId then
                data.Eggs[eggTypeId] = nil
                PublishChanged(playerId, reason or "remove_egg_stack")
                return true
            end
        end
        return false, "item_not_found"
    end

    function runtime:ClearPlayer(playerId, reason)
        self.Players[playerId] = nil
        PublishChanged(playerId, reason or "clear_player")
    end

    runtime.PreleaveCallback = function(playerId)
        runtime:ClearPlayer(playerId, "player_preleave")
    end
    context.Services.InventoryService = runtime
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    Log:PrintServerLog("[InventoryService] 正式库存模块已启动")
end

function InventoryService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.InventoryService
    if not runtime then return end
    if runtime.PreleaveCallback then
        System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    end
    runtime.Players = {}
    context.Services.InventoryService = nil
end

return InventoryService
