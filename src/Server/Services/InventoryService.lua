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
        sourceEggId = item.sourceEggId,
        baseSellPrice = item.baseSellPrice,
        finalScaleUnits = item.finalScaleUnits,
        finalScale = item.finalScale,
        finalSellPrice = item.finalSellPrice,
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
        SessionIds = {},
        NextSession = 0,
        Departed = {},
        Restored = {},
        ChangeBatches = {},
    }

    local function CanMutate(playerId)
        if not GameConfig.Persistence.ProductionEnabled then return true end
        local persistence = context.Services.PersistenceService
        return persistence ~= nil and persistence:IsReady(playerId)
    end
    function runtime:BeginLoadSession(playerId)
        self.ChangeBatches[playerId] = nil
        self.NextSession = self.NextSession + 1
        self.SessionIds[playerId], self.Departed[playerId], self.Restored[playerId] = self.NextSession, nil, nil
        self.Players[playerId] = { Chickens = {}, ChickenOrder = {}, Eggs = {}, EggOrder = {} }
        return self.NextSession
    end
    local function EnsurePlayer(playerId)
        local data = runtime.Players[playerId]
        if not data then
            data = { Chickens = {}, ChickenOrder = {}, Eggs = {}, EggOrder = {} }
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
        for _, itemId in ipairs(data.EggOrder) do
            local item = data.Eggs[itemId]
            if item then result[#result + 1] = CopyItem(item) end
        end
        return result
    end

    function runtime:GetItem(playerId, itemId)
        local data = self.Players[playerId]
        if not data then return nil end
        local item = data.Chickens[itemId]
        if item then return CopyItem(item) end
        return CopyItem(data.Eggs[itemId])
    end

    function runtime:HasItem(playerId, itemId)
        return self:GetItem(playerId, itemId) ~= nil
    end

    local function PublishChanged(playerId, reason)
        local batch = runtime.ChangeBatches[playerId]
        if batch then
            batch.changed, batch.reason = true, reason
            return
        end

        local items = runtime:GetSnapshot(playerId)

        context.Events:Publish("InventoryChanged", {
            playerId = playerId,
            reason = reason,
            items = items,
        })
    end

    -- 仅由一键操作持有；结束前不生成全库存快照，不广播中间状态。
    function runtime:BeginChangeBatch(playerId)
        if context.Services.InventoryService ~= self or self.Departed[playerId] or not CanMutate(playerId) then
            return nil, "inventory_unavailable"
        end
        if self.ChangeBatches[playerId] then return nil, "inventory_batch_busy" end
        local data = EnsurePlayer(playerId)
        local batch = { data = data, session = self.SessionIds[playerId] }
        self.ChangeBatches[playerId] = batch
        return function()
            if self.ChangeBatches[playerId] ~= batch then return 0 end
            self.ChangeBatches[playerId] = nil
            if context.Services.InventoryService ~= self or self.Departed[playerId]
                or self.Players[playerId] ~= data or self.SessionIds[playerId] ~= batch.session then return 0 end
            if not batch.changed then return 0 end
            PublishChanged(playerId, batch.reason)
            return 1
        end
    end

    function runtime:GetSessionGeneration(playerId)
        if context.Services.InventoryService ~= self then return nil end
        return self.SessionIds[playerId]
    end
    function runtime:CheckCapacity(playerId, kind, removeCount, addCount)
        if not CanMutate(playerId) then return false, "persistence_not_ready" end
        if (kind ~= "Chicken" and kind ~= "Egg") or type(removeCount) ~= "number" or type(addCount) ~= "number"
            or removeCount < 0 or addCount < 0 or removeCount > 100 or addCount > 100
            or removeCount ~= math.floor(removeCount) or addCount ~= math.floor(addCount) then
            return false, "invalid_capacity_change"
        end
        local data = self.Players[playerId]
        local count = data and #(kind == "Chicken" and data.ChickenOrder or data.EggOrder) or 0
        if removeCount > count then return false, "invalid_capacity_change" end
        local limit = kind == "Chicken" and GameConfig.InventoryCapacity.Chickens or GameConfig.InventoryCapacity.Eggs
        if count - removeCount + addCount > limit then return false, "inventory_capacity_full" end
        return true
    end
    -- 紧凑行：itemId/C或E/typeId/sequence；蛋追加历史来源/baseSellPrice/finalScaleUnits/finalSellPrice。
    -- 显示名称、图标、count按配置重建；sourceEggId仅历史来源，不作跨局场景查找。
    -- finalScale由原整数档/100无损重建，避免编码浮点。
    function runtime:ExportSnapshot(playerId, generation)
        if generation == nil or self:GetSessionGeneration(playerId) ~= generation then return nil, "stale_inventory_session" end
        local rows = {}
        for _, item in ipairs(self:GetSnapshot(playerId)) do
            local row = { item.itemId, item.kind == "Chicken" and "C" or "E", item.typeId, item.sequence }
            if item.kind == "Egg" then
                row[5], row[6], row[7], row[8] = item.sourceEggId, item.baseSellPrice, item.finalScaleUnits, item.finalSellPrice
            end
            rows[#rows + 1] = row
        end
        return { version = 1, sequenceHighWater = self.GlobalSequence, items = rows }
    end
    function runtime:RestoreSnapshot(playerId, generation, snapshot)
        if generation == nil or self:GetSessionGeneration(playerId) ~= generation then return false, "stale_inventory_session" end
        if self.Restored[playerId] == generation then return false, "inventory_already_restored" end
        local function Dense(array)
            if type(array) ~= "table" then return false end
            local count = 0
            for key in pairs(array) do
                if type(key) ~= "number" or key < 1 or key > #array or key ~= math.floor(key) then return false end
                count = count + 1
            end
            return count == #array
        end
        if type(snapshot) ~= "table" or snapshot.version ~= 1 or type(snapshot.items) ~= "table"
            or not Dense(snapshot.items)
            or type(snapshot.sequenceHighWater) ~= "number" or snapshot.sequenceHighWater < 0
            or snapshot.sequenceHighWater > 9007199254740991 or snapshot.sequenceHighWater ~= math.floor(snapshot.sequenceHighWater) then
            return false, "invalid_inventory_snapshot"
        end
        local prior = self.Players[playerId]
        if prior and (#prior.ChickenOrder > 0 or #prior.EggOrder > 0) then return false, "inventory_not_empty" end
        local data, ids, sequences = { Chickens = {}, ChickenOrder = {}, Eggs = {}, EggOrder = {} }, {}, {}
        local function Safe(n, min)
            return type(n) == "number" and n >= min and n <= 9007199254740991 and n == math.floor(n)
        end
        for _, row in ipairs(snapshot.items) do
            if not Dense(row) or (row[2] ~= "C" and row[2] ~= "E") or type(row[1]) ~= "string"
                or type(row[3]) ~= "string" or not Safe(row[4], 1) or row[4] > snapshot.sequenceHighWater
                or ids[row[1]] or sequences[row[4]] then return false, "invalid_inventory_snapshot" end
            local prefix = row[2] == "C" and "chicken" or "egg"
            local owner, sequence = row[1]:match("^" .. prefix .. ":([1-9][0-9]*):([1-9][0-9]*)$")
            if not owner or sequence ~= string.format("%.0f", row[4]) then return false, "invalid_item_identity" end
            local item = { itemId = row[1], kind = row[2] == "C" and "Chicken" or "Egg", typeId = row[3], count = 1, sequence = row[4] }
            if item.kind == "Chicken" then
                local config = GameConfig.ChickenTypes[item.typeId]
                if #row ~= 4 or not config or not Safe(config.ChickenIconIndex, 1) then return false, "invalid_inventory_snapshot" end
                item.displayName, item.iconIndex = config.DisplayName, config.ChickenIconIndex
                data.Chickens[item.itemId] = item; data.ChickenOrder[#data.ChickenOrder + 1] = item.itemId
            else
                local _, _, egg = FindEggConfig(item.typeId)
                if #row ~= 8 or not egg or not Safe(egg.IconIndex, 1) or not Safe(row[5], 1) or not Safe(row[6], 0)
                    or not Safe(row[7], 1) or not Safe(row[8], 0) then return false, "invalid_inventory_snapshot" end
                item.displayName, item.iconIndex = item.typeId, egg.IconIndex
                item.sourceEggId, item.baseSellPrice, item.finalScaleUnits, item.finalScale, item.finalSellPrice = row[5], row[6], row[7], row[7] / 100, row[8]
                data.Eggs[item.itemId] = item; data.EggOrder[#data.EggOrder + 1] = item.itemId
            end
            ids[item.itemId], sequences[item.sequence] = true, true
        end
        if #data.ChickenOrder > 100 or #data.EggOrder > 100 then return false, "inventory_capacity_full" end
        self.Players[playerId] = data
        self.GlobalSequence = math.max(self.GlobalSequence, snapshot.sequenceHighWater)
        self.Restored[playerId] = generation
        local notified = false
        return true, function()
            if notified then return false, "already_notified" end
            notified = true
            if self:GetSessionGeneration(playerId) ~= generation then return false, "stale_inventory_session" end
            PublishChanged(playerId, "restore_inventory")
            return true
        end -- 恢复协调方提交所有模块后再通知，避免半恢复快照。
    end

    function runtime:AddChicken(playerId, chickenType)
        if not CanMutate(playerId) then return nil, "persistence_not_ready" end
        local config = GameConfig.ChickenTypes[chickenType]
        if not IsPositiveInteger(playerId) or not config or config.Enabled ~= true then
            return nil, "invalid_chicken_add"
        end
        if GameConfig.InventoryCapacity.Enabled then
            local ok, reason = self:CheckCapacity(playerId, "Chicken", 0, 1)
            if not ok then return nil, reason end
        end
        self.GlobalSequence = self.GlobalSequence + 1
        local itemId = "chicken:" .. string.format("%.0f", playerId) .. ":" .. string.format("%.0f", self.GlobalSequence)
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

    -- 仅接收产蛋服务的权威记录；成熟、归属、幂等与场景移除由收取事务负责。
    -- 保留场景身份与已结算价值，每枚生成独立库存身份，不按类型堆叠。
    function runtime:AddEgg(playerId, eggRecord)

        if not CanMutate(playerId) then return nil, "persistence_not_ready" end
        if context.Services.InventoryService ~= self then
            return nil, "inventory_unavailable"
        end
        if not IsPositiveInteger(playerId) or type(eggRecord) ~= "table"
            or not IsPositiveInteger(eggRecord.eggId) or eggRecord.eggId >= math.huge
            or type(eggRecord.eggTypeId) ~= "string" or eggRecord.eggTypeId == "" then
            return nil, "invalid_egg_add"
        end
        if type(eggRecord.baseSellPrice) ~= "number" or eggRecord.baseSellPrice < 0
            or eggRecord.baseSellPrice >= math.huge
            or eggRecord.baseSellPrice ~= math.floor(eggRecord.baseSellPrice)
            or not IsPositiveInteger(eggRecord.finalScaleUnits)
            or eggRecord.finalScaleUnits >= math.huge
            or eggRecord.finalScale ~= eggRecord.finalScaleUnits / 100
            or type(eggRecord.finalSellPrice) ~= "number" or eggRecord.finalSellPrice < 0
            or eggRecord.finalSellPrice >= math.huge
            or eggRecord.finalSellPrice ~= math.floor(eggRecord.finalSellPrice) then
            return nil, "invalid_egg_value"
        end
        local _, chickenConfig, eggConfig = FindEggConfig(eggRecord.eggTypeId)
        if not chickenConfig or not eggConfig or eggConfig.Enabled ~= true then
            return nil, "egg_type_disabled_or_missing"
        end
        if not IsPositiveInteger(eggConfig.IconIndex) then
            return nil, "invalid_egg_icon_config"
        end
        if GameConfig.InventoryCapacity.Enabled then
            local ok, reason = self:CheckCapacity(playerId, "Egg", 0, 1)
            if not ok then return nil, reason end
        end

        local data = EnsurePlayer(playerId)
        self.GlobalSequence = self.GlobalSequence + 1
        local itemId = "egg:" .. string.format("%.0f", playerId) .. ":" .. string.format("%.0f", self.GlobalSequence)
        local item = {
            itemId = itemId,
            kind = "Egg",
            typeId = eggRecord.eggTypeId,
            displayName = eggRecord.eggTypeId,
            count = 1,
            iconIndex = eggConfig.IconIndex,
            sequence = self.GlobalSequence,
            sourceEggId = eggRecord.eggId,
            baseSellPrice = eggRecord.baseSellPrice,
            finalScaleUnits = eggRecord.finalScaleUnits,
            finalScale = eggRecord.finalScale,
            finalSellPrice = eggRecord.finalSellPrice,
        }
        data.Eggs[itemId] = item
        data.EggOrder[#data.EggOrder + 1] = itemId

        PublishChanged(playerId, "add_egg")
        return CopyItem(item)
    end

    -- 仅供服务端放置模块使用：归还记录必须来自其持有的原鸡，不接受客户端资产记录。
    -- 放置仅传 removeItemId；收回仅传 returnedChicken；替换同时传两者。
    -- 全部预检通过后无等待提交；不生成身份，也不改变 GlobalSequence。
    function runtime:TransferChicken(playerId, removeItemId, returnedChicken, reason)
        if not CanMutate(playerId) then return false, "persistence_not_ready" end
        if context.Services.InventoryService ~= self or not IsPositiveInteger(playerId) then
            return false, "player_inventory_unavailable"
        end
        local data = self.Players[playerId]
        if not data then return false, "player_inventory_unavailable" end
        if removeItemId == nil and returnedChicken == nil then
            return false, "empty_chicken_transfer"
        end
        if reason ~= nil and (type(reason) ~= "string" or reason == "") then
            return false, "invalid_transfer_reason"
        end

        local removedChicken, removeIndex
        if removeItemId ~= nil then
            if type(removeItemId) ~= "string" or removeItemId == "" then
                return false, "invalid_remove_item_id"
            end
            removedChicken = data.Chickens[removeItemId]
            if not removedChicken then return false, "chicken_not_found" end
            if removedChicken.kind ~= "Chicken" then return false, "item_not_chicken" end
            for index, itemId in ipairs(data.ChickenOrder) do
                if itemId == removeItemId then removeIndex = index break end
            end
            if not removeIndex then return false, "chicken_order_missing" end
        end

        local returnedCopy
        if returnedChicken ~= nil then
            if type(returnedChicken) ~= "table" or returnedChicken.kind ~= "Chicken"
                or type(returnedChicken.typeId) ~= "string"
                or not GameConfig.ChickenTypes[returnedChicken.typeId]
                or type(returnedChicken.displayName) ~= "string"
                or returnedChicken.count ~= 1
                or not IsPositiveInteger(returnedChicken.iconIndex)
                or not IsPositiveInteger(returnedChicken.sequence)
                or returnedChicken.sequence > self.GlobalSequence
                or type(returnedChicken.itemId) ~= "string"
                or not returnedChicken.itemId:match("^chicken:[1-9][0-9]*:" .. string.format("%.0f", returnedChicken.sequence) .. "$") then
                return false, "invalid_returned_chicken"
            end
            if data.Chickens[returnedChicken.itemId] then
                return false, "returned_chicken_already_in_inventory"
            end
            returnedCopy = CopyItem(returnedChicken)
        end
        if GameConfig.InventoryCapacity.Enabled then
            local ok, reason = self:CheckCapacity(playerId, "Chicken", removedChicken and 1 or 0, returnedCopy and 1 or 0)
            if not ok then return false, reason end
        end

        -- 从此处开始只操作已验证的 Lua 数据，不调用引擎或其他业务模块。
        local removedCopy = CopyItem(removedChicken)
        if removedChicken then
            data.Chickens[removeItemId] = nil
            table.remove(data.ChickenOrder, removeIndex)
        end
        if returnedCopy then
            data.Chickens[returnedCopy.itemId] = returnedCopy
            local insertIndex = #data.ChickenOrder + 1
            for index, itemId in ipairs(data.ChickenOrder) do
                if data.Chickens[itemId].sequence > returnedCopy.sequence then
                    insertIndex = index
                    break
                end
            end
            table.insert(data.ChickenOrder, insertIndex, returnedCopy.itemId)
        end
        PublishChanged(playerId, reason or "transfer_chicken")
        return true, removedCopy
    end

    -- 结算方可延后通知：无等待完成余额提交后必须调用返回的单次发布函数。
    -- 默认调用保持原来的同步通知与返回值。
    function runtime:RemoveItem(playerId, itemId, reason, deferChanged)
        if not CanMutate(playerId) then return false, "persistence_not_ready" end
        local data = self.Players[playerId]
        if not data or type(itemId) ~= "string" then return false, "item_not_found" end
        local function Changed(defaultReason)
            if not deferChanged then PublishChanged(playerId, reason or defaultReason); return true end
            local published = false
            return true, function()
                if published then return end
                published = true
                PublishChanged(playerId, reason or defaultReason)
            end
        end
        if data.Chickens[itemId] then
            data.Chickens[itemId] = nil
            for index = #data.ChickenOrder, 1, -1 do
                if data.ChickenOrder[index] == itemId then
                    table.remove(data.ChickenOrder, index)
                    break
                end
            end
            return Changed("remove_chicken")
        end
        if data.Eggs[itemId] then
            data.Eggs[itemId] = nil
            for index = #data.EggOrder, 1, -1 do
                if data.EggOrder[index] == itemId then
                    table.remove(data.EggOrder, index)
                    break
                end
            end
            return Changed("remove_egg")
        end
        return false, "item_not_found"
    end

    function runtime:ClearPlayer(playerId, reason)
        local persistence = context.Services.PersistenceService
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(playerId) end
        self.ChangeBatches[playerId] = nil
        self.SessionIds[playerId] = nil
        self.Departed[playerId], self.Restored[playerId] = true, nil
        self.Players[playerId] = nil
        PublishChanged(playerId, reason or "clear_player")
    end

    runtime.PreleaveCallback = function(playerId)
        runtime:ClearPlayer(playerId, "player_preleave")
    end
    context.Services.InventoryService = runtime
    runtime.EnterCallback = function(playerId)
        if context.Services.InventoryService ~= runtime or not IsPositiveInteger(playerId) then return end
        runtime.Departed[playerId] = nil
        if not runtime.SessionIds[playerId] then
            runtime.NextSession = runtime.NextSession + 1
            runtime.SessionIds[playerId] = runtime.NextSession
        end
    end
    System:RegisterEvent(Events.ON_PLAYER_ENTER, runtime.EnterCallback)
    System:RegisterEvent(Events.ON_PLAYER_JOIN_MIDWAY, runtime.EnterCallback)
    runtime.ReconnectCallback = function(playerId)
        runtime:ClearPlayer(playerId, "player_reconnect")
        runtime.EnterCallback(playerId)
    end
    System:RegisterEvent(Events.ON_PLAYER_RECONNECTED, runtime.ReconnectCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if context.Services.InventoryService ~= runtime then return end
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do
            if not runtime.Departed[id] then runtime.EnterCallback(id) end
        end
    end)
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
    runtime.ChangeBatches = {}
    runtime.Players = {}
    runtime.SessionIds = {}
    System:UnregisterEvent(Events.ON_PLAYER_ENTER, runtime.EnterCallback)
    System:UnregisterEvent(Events.ON_PLAYER_JOIN_MIDWAY, runtime.EnterCallback)
    System:UnregisterEvent(Events.ON_PLAYER_RECONNECTED, runtime.ReconnectCallback)
    context.Services.InventoryService = nil
end

return InventoryService
