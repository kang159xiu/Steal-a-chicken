local GameConfig = require "Common.Config.GameConfig"

-- 临时定向诊断：不读取额外业务状态，日志故障不进入资产流程。
local function ObtainedDiag(stage, playerId, chickenType, itemId, inventoryGeneration, archiveGeneration, reason)
    pcall(function()
        Log:PrintServerLog("[ChickenObtainedDiag]", "stage:", stage, "playerId:", playerId,
            "itemId:", tostring(itemId), "chickenType:", tostring(chickenType),
            "inventoryGeneration:", tostring(inventoryGeneration), "archiveGeneration:", tostring(archiveGeneration),
            "reason:", tostring(reason))
    end)
end

local InventoryService = {
    Name = "InventoryService",
    FeatureFlag = "Inventory",
    Dependencies = {},
}

local IsPositiveInteger = require("Common.Validation").IsPositiveInteger

-- 个体历史售价只接受可精确保存/结算的非负整数；不从当前类型配置补价。
local function IsSellPrice(value)
    return type(value) == "number" and value >= 0 and value <= 9007199254740991
        and value == math.floor(value)
end

-- itemId中的末段本来就是sequence的规范十进制文本；恢复前验证安全整数及无损往返。
local function ItemSequence(itemId, kind)
    if type(itemId) ~= "string" then return nil end
    local prefix = kind == "C" and "chicken" or "egg"
    local owner, text = itemId:match("^" .. prefix .. ":([1-9][0-9]*):([1-9][0-9]*)$")
    if not owner then return nil end
    local sequence = tonumber(text)
    if not IsPositiveInteger(sequence) or sequence > 9007199254740991
        or string.format("%.0f", sequence) ~= text then return nil end
    return sequence
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

    local eggConfigsByType = {}
    for chickenType, chickenConfig in pairs(GameConfig.ChickenTypes) do
        local egg = chickenConfig.Egg
        if egg and egg.EggTypeId ~= nil and not eggConfigsByType[egg.EggTypeId] then
            eggConfigsByType[egg.EggTypeId] = { chickenType = chickenType, chickenConfig = chickenConfig, egg = egg }
        end
    end
    local function FindEggConfig(eggTypeId)
        local entry = eggConfigsByType[eggTypeId]
        if entry then return entry.chickenType, entry.chickenConfig, entry.egg end
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
        local data = self.Players[playerId]
        return data ~= nil and (data.Chickens[itemId] ~= nil or data.Eggs[itemId] ~= nil)
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
               or self.Players[playerId] ~= data then return 0 end
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
    -- 库存v2紧凑行：鸡为itemId/C/typeId/finalSellPrice；蛋为itemId/E/typeId/来源/基础价/缩放整数档/最终价。
    -- sequence从itemId无损还原，不重复保存；sequenceHighWater仍保留供放置档及后续身份分配使用。
    -- 显示名称、图标、count按配置重建；sourceEggId仅历史来源，不作跨局场景查找。
    -- finalScale由原整数档/100无损重建，避免编码浮点。
    function runtime:ExportSnapshot(playerId, generation)
        local rows = {}
        for _, item in ipairs(self:GetSnapshot(playerId)) do
            local kind = item.kind == "Chicken" and "C" or "E"
            if ItemSequence(item.itemId, kind) ~= item.sequence then return nil, "invalid_item_identity" end
            local row = { item.itemId, kind, item.typeId }
            if item.kind == "Chicken" then
                if not IsSellPrice(item.finalSellPrice) then return nil, "invalid_chicken_price" end
                row[4] = item.finalSellPrice
            elseif item.kind == "Egg" then
                row[4], row[5], row[6], row[7] = item.sourceEggId, item.baseSellPrice, item.finalScaleUnits, item.finalSellPrice
            end
            rows[#rows + 1] = row
        end
        return { version = 2, sequenceHighWater = self.GlobalSequence, items = rows }
    end
    function runtime:RestoreSequenceHighWater(sequence)
        self.GlobalSequence = math.max(self.GlobalSequence, sequence)
    end
    function runtime:RestoreSnapshot(playerId, generation, snapshot)
        if snapshot.version ~= 2 then Log:PrintServerLog("[Persistence] version mismatch", playerId, "inventory", tostring(snapshot.version), 2) end
        if snapshot.items == nil then snapshot.items = {} end
        if snapshot.sequenceHighWater == nil then snapshot.sequenceHighWater = 0 end
        local data = { Chickens = {}, ChickenOrder = {}, Eggs = {}, EggOrder = {} }
        self.Players[playerId] = data
        self.GlobalSequence = math.max(self.GlobalSequence, snapshot.sequenceHighWater)
        for index, row in ipairs(snapshot.items) do
            local ok, reason = pcall(function()
                local kind, typeId, itemId = row[2], row[3], row[1]
                local sequence = ItemSequence(itemId, kind)
                if not itemId or not typeId or not sequence or (kind ~= "C" and kind ~= "E") then error("item_identity_or_type_missing") end
                local item = { itemId = itemId, kind = kind == "C" and "Chicken" or "Egg", typeId = typeId, count = 1, sequence = sequence }
                if kind == "C" then
                    local config = GameConfig.ChickenTypes[typeId]
                    if not config then error("chicken_type_missing") end
                    if row[4] == nil then row[4] = config.ChickenSellPrice end
                    item.finalSellPrice, item.displayName, item.iconIndex = row[4], config.DisplayName, config.ChickenIconIndex
                    data.Chickens[itemId] = item; data.ChickenOrder[#data.ChickenOrder + 1] = itemId
                else
                    local _, _, egg = FindEggConfig(typeId)
                    if not egg or row[4] == nil then error("egg_type_or_source_missing") end
                    if row[5] == nil then row[5] = egg.SellPrice end
                    if row[6] == nil then row[6] = GameConfig.EggGrowth.InitialScaleUnits end
                    if row[7] == nil then row[7] = row[5] end
                    item.displayName, item.iconIndex = egg.DisplayName, egg.IconIndex
                    item.sourceEggId, item.baseSellPrice, item.finalScaleUnits = row[4], row[5], row[6]
                    item.finalScale, item.finalSellPrice = row[6] / 100, row[7]
                    data.Eggs[itemId] = item; data.EggOrder[#data.EggOrder + 1] = itemId
                end
                self.GlobalSequence = math.max(self.GlobalSequence, sequence)
            end)
            if not ok then Log:PrintError("[Persistence] inventory row skipped", playerId, index, tostring(reason)) end
        end
        self.Restored[playerId] = generation
        local notified = false
        return true, function()
            if notified then return false, "already_notified" end
            notified = true
            PublishChanged(playerId, "restore_inventory")
            return true
        end
    end

    -- finalSellPrice由偷鸡服务在生成时抽取一次；缺失直接拒绝，不重新随机或补基础价。
    function runtime:AddChicken(playerId, chickenType, finalSellPrice)
        ObtainedDiag("add_enter", playerId, chickenType, nil, self.SessionIds[playerId], nil)
        if not CanMutate(playerId) then
            ObtainedDiag("add_reject", playerId, chickenType, nil, self.SessionIds[playerId], nil, "persistence_not_ready")
            return nil, "persistence_not_ready"
        end
        local config = GameConfig.ChickenTypes[chickenType]
        if not IsPositiveInteger(playerId) or not config or config.Enabled ~= true then
            ObtainedDiag("add_reject", playerId, chickenType, nil, self.SessionIds[playerId], nil, "invalid_chicken_add")
            return nil, "invalid_chicken_add"
        end
        if not IsSellPrice(finalSellPrice) then
            ObtainedDiag("add_reject", playerId, chickenType, nil, self.SessionIds[playerId], nil, "invalid_chicken_price")
            return nil, "invalid_chicken_price"
        end
        if GameConfig.InventoryCapacity.Enabled then
            local ok, reason = self:CheckCapacity(playerId, "Chicken", 0, 1)
            if not ok then
                ObtainedDiag("add_reject", playerId, chickenType, nil, self.SessionIds[playerId], nil, reason)
                return nil, reason
            end
        end
        self.GlobalSequence = self.GlobalSequence + 1
        local itemId = "chicken:" .. string.format("%.0f", playerId) .. ":" .. string.format("%.0f", self.GlobalSequence)
        local item = {
            itemId = itemId,
            kind = "Chicken",
            typeId = chickenType,
            finalSellPrice = finalSellPrice,
            displayName = config.DisplayName,
            count = 1,
            iconIndex = config.ChickenIconIndex,
            sequence = self.GlobalSequence,
        }
        local data = EnsurePlayer(playerId)
        local generation = self:GetSessionGeneration(playerId)
        local persistence = context.Services.PersistenceService
        local archive
        local captured, captureError = pcall(function()
            archive = persistence and persistence:GetState(playerId)
        end)
        if not captured then
            ObtainedDiag("archive_capture_failed", playerId, chickenType, itemId, generation, nil, captureError)
            pcall(function() Log:PrintError("[InventoryService] 获得鸡提示会话读取失败，不补发", tostring(captureError)) end)
        end
        data.Chickens[itemId] = item
        data.ChickenOrder[#data.ChickenOrder + 1] = itemId
        ObtainedDiag("add_committed", playerId, chickenType, itemId, generation, archive and archive.generation)
        PublishChanged(playerId, "add_chicken")
        -- 表现通知失败不改变已提交的库存；发布库存事件可能同步切换会话。
        local ok, errorMessage = pcall(function()
            if context.Services.InventoryService ~= self or self.Departed[playerId]
               or self.Players[playerId] ~= data then
                local reason = context.Services.InventoryService ~= self and "inventory_owner_changed"
                    or self.Departed[playerId] and "departed" or self.Players[playerId] ~= data and "inventory_data_changed"
                ObtainedDiag("notify_skip", playerId, chickenType, itemId, generation, archive and archive.generation, reason)
                return
            end
            if not archive or not archive.ready then
                ObtainedDiag("notify_skip", playerId, chickenType, itemId, generation, archive and archive.generation,
                    not archive and "archive_missing" or "archive_not_ready")
                return
            end
            local current = persistence:GetState(playerId)
            if context.Services.PersistenceService ~= persistence or not current.ready then
                ObtainedDiag("notify_skip", playerId, chickenType, itemId, generation, archive.generation,
                    context.Services.PersistenceService ~= persistence and "persistence_owner_changed"
                   or "archive_current_not_ready")
                return
            end
            ObtainedDiag("notify_send", playerId, chickenType, itemId, generation, archive.generation)
            System:SendToClient(playerId, context.NetMsg.Messages.ChickenObtained, {
                itemId = itemId, chickenType = chickenType, generation = archive.generation,
            })
            ObtainedDiag("notify_send_returned", playerId, chickenType, itemId, generation, archive.generation)
        end)
        if not ok then
            ObtainedDiag("notify_failed", playerId, chickenType, itemId, generation, archive and archive.generation, errorMessage)
            pcall(function() Log:PrintError("[InventoryService] 获得鸡提示通知失败，不补发", tostring(errorMessage)) end)
        end
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
            displayName = eggConfig.DisplayName,
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
                or not IsSellPrice(returnedChicken.finalSellPrice)
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
