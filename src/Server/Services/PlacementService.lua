local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"

local PlacementService = {
    Name = "PlacementService",
    FeatureFlag = "Placement",
    Dependencies = { "HomeService", "InventoryService", "HotbarService", "HomeUpgradeService" },
}
local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end

local function CopyChicken(chicken)
    return { itemId = chicken.itemId, typeId = chicken.typeId, sequence = chicken.sequence, finalSellPrice = chicken.finalSellPrice }
end

local function InRange(playerId, elementId, positionReadFailures)
    local playerPosition = Character:GetPosition(playerId)
    local position = Element:GetPosition(elementId)
    if not playerPosition or not position then
        local key = tostring(playerId) .. ":" .. tostring(elementId)
        local reason = "position_unavailable:" .. tostring(playerPosition == nil) .. ":" .. tostring(position == nil)
        if positionReadFailures[key] ~= reason then
            positionReadFailures[key] = reason
            Log:PrintServerLog("[PlacementService] 距离读取失败", "playerId:", playerId,
                "elementId:", elementId, "playerPosition:", tostring(playerPosition), "slotPosition:", tostring(position))
        end
        return false
    end
    local dx, dy, dz = playerPosition.X - position.X,
        playerPosition.Y - position.Y, playerPosition.Z - position.Z
    local distanceSquared = dx * dx + dy * dy + dz * dz
    positionReadFailures[tostring(playerId) .. ":" .. tostring(elementId)] = nil
    return distanceSquared <= GameConfig.Placement.MaxDistance ^ 2
end

function PlacementService:ValidateConfig(context)
    local errors = {}
    local config = GameConfig.Placement
    if type(config) ~= "table" then return false, { "GameConfig.Placement 必须是 table" } end
    for _, field in ipairs({ "UiGroupId", "PlaceButtonId", "RecallUiGroupId", "RecallButtonId" }) do
        if not IsPositiveInteger(config[field]) then errors[#errors + 1] = "Placement." .. field .. " 无效" end
    end
    if config.MaxDistance ~= 300 then errors[#errors + 1] = "Placement.MaxDistance 必须为已确认的300" end
    if not IsPositiveInteger(GameConfig.Home.DefaultChickenCapacity) then
        errors[#errors + 1] = "家园初始容量无效"
    end
    if type(GameConfig.Home.PlacementSlotProperty) ~= "string" or GameConfig.Home.PlacementSlotProperty == "" then
        errors[#errors + 1] = "家园放置位属性名无效"
    end
    return #errors == 0, errors
end

function PlacementService:Start(context)
    if context.Side ~= "Server" then return end
    local home = context.Services.HomeService
    local inventory = context.Services.InventoryService
    local hotbar = context.Services.HotbarService
    local runtime = { Ready = false, Stopped = false, Targets = {}, Homes = {}, Pending = {}, Sequence = 0,
        Revision = 0, Committing = false, PositionReadFailures = {} }
    context.Services.PlacementService = runtime

    local persistence = context.Services.PersistenceService
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id))
    end
    local function PrepareLeave(id)
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(id) end
    end
    local restoreOperations = {}
    local function Active()
        return not runtime.Stopped and context.Services.PlacementService == runtime
    end

    function runtime:GetPlacedSnapshot(playerId)
        local homeId = home:GetPlayerHome(playerId)
        if not homeId then return nil end
        local house = self.Homes[homeId]
        local snapshot = { playerId = playerId, homeId = homeId, count = 0, slots = {} }
        if house and house.playerId == playerId then
            snapshot.count = house.count
            for slotIndex, record in pairs(house.slots) do
                local chicken = record.chicken
                snapshot.slots[#snapshot.slots + 1] = { slotIndex = slotIndex, rootId = record.rootId,
                    chicken = CopyChicken(chicken) }
            end
            table.sort(snapshot.slots, function(a, b) return a.slotIndex < b.slotIndex end)
        end
        return snapshot
    end

    local function SlotUnlocked(playerId, slotIndex)
        local upgrades = context.Services.HomeUpgradeService
        return upgrades ~= nil and upgrades:IsSlotUnlocked(playerId, slotIndex)
    end
    local function ChickenCapacity(playerId)
        local upgrades = context.Services.HomeUpgradeService
        if upgrades then return upgrades:GetChickenCapacity(playerId) end
        return GameConfig.Home.DefaultChickenCapacity
    end

    local modelVersion = 0
    local function SendModels(playerId, homeId, recipient, cleared)
        local house = not cleared and runtime.Homes[homeId] or nil
        local models = {}
        if house and house.playerId == playerId then
            for _, record in pairs(house.slots) do
                models[#models + 1] = { rootId = record.rootId, finalSellPrice = record.chicken.finalSellPrice,
                    chickenType = record.chicken.typeId }
            end
        end
        modelVersion = modelVersion + 1
        local message = { source = "placement", playerId = playerId, version = modelVersion, models = models }
        if recipient then System:SendToClient(recipient, context.NetMsg.Messages.ChickenModelState, message)
        else System:SendToAllClients(context.NetMsg.Messages.ChickenModelState, message) end
    end
    runtime.ModelSnapshotCallback = function(_, _, playerId)
        if not Active() or not runtime.Ready or not IsPositiveInteger(playerId) then return end
        for homeId, house in pairs(runtime.Homes) do SendModels(house.playerId, homeId, playerId) end
    end
    System:BindNotify(context.NetMsg.Messages.ChickenModelSnapshotRequest, runtime.ModelSnapshotCallback)
    local function PublishPlaced(playerId, homeId, cleared)
        SendModels(playerId, homeId, nil, cleared)
        if not cleared and CanPlay(playerId) and persistence then persistence:MarkDirty(playerId, "placement") end
        local snapshot = not cleared and runtime:GetPlacedSnapshot(playerId)
            or { playerId = playerId, homeId = homeId, count = 0, slots = {} }
        if snapshot then context.Events:Publish("PlacedChickensChanged", snapshot) end
    end

    local function NextVersion()
        runtime.Sequence = runtime.Sequence + 1
        return runtime.Sequence
    end

    local function DestroyRoot(rootId, reason)
        if not rootId then return end
        local ok, result = pcall(function() return context.ElementCopy:DestroyTree(rootId) end)
        if not ok or result ~= true then
            Log:PrintError("[PlacementService] 放置树清理失败，不重复结算",
                "rootId:", rootId, "reason:", reason, "error:", tostring(result))
        end
    end

    local function InvalidateOperation(target)
        local operation = target and target.operation
        if not operation then return end
        target.operation = nil
        operation.invalid = true
        if operation.rootId then
            DestroyRoot(operation.rootId, "invalidated_placement")
            operation.rootId = nil
            runtime.Pending[operation] = nil
        end
    end

    local function SelectedChicken(playerId)
        local itemId = hotbar:GetSelectedItem(playerId)
        local item = itemId and inventory:GetItem(playerId, itemId)
        if item and item.kind == "Chicken" then return item end
        return nil
    end

    local function Occupant(target)
        local house = runtime.Homes[target.homeId]
        return house and house.playerId == target.playerId and house.slots[target.slotIndex] or nil
    end

    local function SendState(playerId)
        if not Active() or runtime.Committing then return end
        local target = runtime.Targets[playerId]
        runtime.Revision = runtime.Revision + 1
        local message = {
            revision = runtime.Revision,
            version = target and target.version or runtime.Sequence,
            elementId = target and target.elementId or nil,
            homeId = target and target.homeId or nil,
            slotIndex = target and target.slotIndex or nil,
            selectedItemId = target and target.selectedItemId or nil,
            canPlace = target ~= nil and target.selectedItemId ~= nil,
            canRecall = target ~= nil and Occupant(target) ~= nil,
            busy = target ~= nil and target.operation ~= nil,
        }

        System:SendToClient(playerId, context.NetMsg.Messages.PlacementState, message)
    end

    local function ClearTarget(playerId)
        local target = runtime.Targets[playerId]
        if not target then return end
        InvalidateOperation(target)
        runtime.Targets[playerId] = nil
        NextVersion()
        SendState(playerId)
    end

    local function RefreshTarget(playerId)
        local target = runtime.Targets[playerId]
        if not target then return nil end
        local slot = home:GetPlacementSlot(playerId, target.elementId)
        if not slot or slot.homeId ~= target.homeId or slot.slotIndex ~= target.slotIndex
            or not InRange(playerId, target.elementId, runtime.PositionReadFailures) then
            ClearTarget(playerId)
            return nil
        end
        local item = SelectedChicken(playerId)
        local selectedItemId = item and item.itemId or nil
        if selectedItemId ~= target.selectedItemId then
            InvalidateOperation(target)
            target.selectedItemId = selectedItemId
            target.version = NextVersion()
            SendState(playerId)
        end
        return target
    end

    local function Result(playerId, action, version, success, reason)
        System:SendToClient(playerId, context.NetMsg.Messages.PlacementResult, {
            action = action, version = version, success = success, reason = reason,
        })
        if not success then
            Log:PrintServerLog("[PlacementService] 操作结果", "playerId:", playerId,
                "action:", action, "version:", version, "success:", tostring(success), "reason:", tostring(reason))
        end
    end

    local function ClearHome(playerId, homeId)
        ClearTarget(playerId)
        local house = runtime.Homes[homeId]
        if not house or house.playerId ~= playerId then return end
        runtime.Homes[homeId] = nil
        for _, record in pairs(house.slots) do DestroyRoot(record.rootId, "home_released") end
        PublishPlaced(playerId, homeId, true)
    end

    local function FinishOperation(operation, success, reason)
        runtime.Pending[operation] = nil
        local target = runtime.Targets[operation.playerId]
        if not Active() or target ~= operation.target or target.operation ~= operation then return end
        target.operation = nil
        target.version = NextVersion()
        local item = SelectedChicken(operation.playerId)
        target.selectedItemId = item and item.itemId or nil
        Result(operation.playerId, "place", operation.requestVersion, success, reason)
        RefreshTarget(operation.playerId)
        SendState(operation.playerId)
    end

    local function ValidateOperation(operation)
        if not CanPlay(operation.playerId) or not Active() or operation.invalid then return false end
        local target = RefreshTarget(operation.playerId)
        if target ~= operation.target or target.operation ~= operation or target.version ~= operation.version
            or runtime.Homes[target.homeId] ~= operation.house
            or Occupant(target) ~= operation.previous then return false end
        local item = SelectedChicken(operation.playerId)
        if not item then return false end
        for _, field in ipairs({ "itemId", "kind", "typeId", "displayName", "count", "iconIndex", "sequence", "finalSellPrice" }) do
            if item[field] ~= operation.item[field] then return false end
        end
        return SlotUnlocked(operation.playerId, target.slotIndex)
            and (operation.previous ~= nil or operation.house.count < ChickenCapacity(operation.playerId))
    end

    local function CommitPlacement(operation)
        if not ValidateOperation(operation) then
            DestroyRoot(operation.rootId, "stale_placement_before_commit")
            operation.rootId = nil
            FinishOperation(operation, false, "interaction_expired")
            return
        end
        local actualPosition = Element:GetPosition(operation.rootId)
        local actualRotation = Element:GetRotation(operation.rootId)
        if not actualPosition or not actualRotation then
            DestroyRoot(operation.rootId, "placement_transform_unavailable")
            operation.rootId = nil
            FinishOperation(operation, false, "placement_transform_unavailable")
            return
        end
        -- InventoryChanged 同步发布；本模块在库存与占位连续提交期间不刷新交互。
        runtime.Committing = true
        local ok, removed = inventory:TransferChicken(operation.playerId, operation.item.itemId,
            operation.previous and operation.previous.chicken or nil, "placement")
        if ok then
            operation.house.slots[operation.target.slotIndex] = { chicken = removed, rootId = operation.rootId }
            if not operation.previous then operation.house.count = operation.house.count + 1 end
            operation.rootId = nil -- 完整树的责任已移交给本模块的已放置记录。
        end
        runtime.Committing = false
        if not ok then
            DestroyRoot(operation.rootId, "inventory_transfer_rejected")
            operation.rootId = nil
            FinishOperation(operation, false, removed)
            return
        end
        if operation.previous then DestroyRoot(operation.previous.rootId, "replaced_chicken") end
        PublishPlaced(operation.playerId, operation.target.homeId)
        FinishOperation(operation, true, "placed")
    end

    local function Protect(callback)
        return function(...)
            if not Active() then
                return
            end
            local args = { n = select("#", ...), ... }
            local ok, message = xpcall(function()
                callback((table.unpack or unpack)(args, 1, args.n))
            end, function(errorMessage)
                return debug and debug.traceback and debug.traceback(tostring(errorMessage), 2)
                    or tostring(errorMessage)
            end)
            if not ok then context.Manager:FailModule(PlacementService.Name, tostring(message)) end
        end
    end

    runtime.TouchCallback = Protect(function(elementId, playerId)
        if not CanPlay(playerId) or not runtime.Ready or not IsPositiveInteger(playerId) then
            return
        end
        local slot = home:GetPlacementSlot(playerId, elementId)

        if not slot then
            return
        end
        local previousTarget = runtime.Targets[playerId]
        if previousTarget and previousTarget.elementId == elementId then
            RefreshTarget(playerId)
            SendState(playerId)
            return
        end
        ClearTarget(playerId)
        if not InRange(playerId, elementId, runtime.PositionReadFailures) then
            return
        end
        local house = runtime.Homes[slot.homeId]
        if not house then
            house = { playerId = playerId, slots = {}, count = 0 }
            runtime.Homes[slot.homeId] = house
        end
        if house.playerId ~= playerId then
            error("放置家园归属记录不一致")
        end
        local item = SelectedChicken(playerId)

        runtime.Targets[playerId] = { playerId = playerId, homeId = slot.homeId,
            slotIndex = slot.slotIndex, elementId = elementId, version = NextVersion(),
            selectedItemId = item and item.itemId or nil }
        SendState(playerId)
    end)

    runtime.ActionCallback = Protect(function(_, message, playerId)
        if not CanPlay(playerId) then return end
        if not runtime.Ready or not IsPositiveInteger(playerId) or type(message) ~= "table"
            or not IsPositiveInteger(message.version) or not IsPositiveInteger(message.elementId)
            or (message.action ~= "place" and message.action ~= "recall") then return end
        local target = RefreshTarget(playerId)
        if not target or target.version ~= message.version or target.elementId ~= message.elementId then
            Result(playerId, message.action, message.version, false, "interaction_expired")
            SendState(playerId)
            return
        end
        if target.operation then return end
        local house = runtime.Homes[target.homeId]
        local previous = Occupant(target)
        if message.action == "recall" then
            if not previous then Result(playerId, "recall", message.version, false, "slot_empty") return end
            runtime.Committing = true
            local ok, reason = inventory:TransferChicken(playerId, nil, previous.chicken, "placement_recall")
            if ok then house.slots[target.slotIndex] = nil; house.count = house.count - 1 end
            runtime.Committing = false
            if ok then
                DestroyRoot(previous.rootId, "recalled_chicken")
                PublishPlaced(playerId, target.homeId)
            end
            target.version = NextVersion()
            RefreshTarget(playerId)
            Result(playerId, "recall", message.version, ok, ok and "recalled" or reason)
            SendState(playerId)
            return
        end
        local item = SelectedChicken(playerId)
        if not item or item.itemId ~= target.selectedItemId or message.itemId ~= item.itemId then
            Result(playerId, "place", message.version, false, "selected_chicken_required") return
        end
        if not SlotUnlocked(playerId, target.slotIndex) then
            local upgrades = context.Services.HomeUpgradeService
            local opened, reason = upgrades:OpenPlacementUpgrade(playerId, target.elementId, target.slotIndex)
            Result(playerId, "place", message.version, false, opened and "slot_locked" or reason)
            return
        end
        if not previous and house.count >= ChickenCapacity(playerId) then
            Result(playerId, "place", message.version, false, "capacity_full") return
        end
        local config = GameConfig.ChickenTypes[item.typeId]
        if not config or not config.Enabled or not IsPositiveInteger(config.TemplateRootId) then
            Result(playerId, "place", message.version, false, "chicken_template_unavailable") return
        end
        local position = Element:GetPosition(target.elementId)
        local rotation = Element:GetRotation(target.elementId)
        if not position or not rotation then
            Result(playerId, "place", message.version, false, "slot_transform_unavailable") return
        end
        target.version = NextVersion()
        local operation = { playerId = playerId, target = target, house = house, previous = previous,
            item = item, version = target.version, requestVersion = message.version }
        target.operation = operation
        runtime.Pending[operation] = true
        SendState(playerId)
        context.ElementCopy:CopyTree(config.TemplateRootId, position,
            "家园放鸡:" .. tostring(playerId) .. ":" .. tostring(operation.version), function(result)
                -- 完整成功副本即使在 Stop 后到达也必须清理；失败部分保持原复制工具契约。
                if not result.success then
                    runtime.Pending[operation] = nil
                    if Active() then FinishOperation(operation, false, result.reason) end
                    Log:PrintError("[PlacementService] 放置复制失败，库存与原位未变", tostring(result.reason))
                    return
                end
                operation.rootId = result.rootId
                if not ValidateOperation(operation) then
                    DestroyRoot(operation.rootId, "late_placement_copy")
                    operation.rootId = nil
                    FinishOperation(operation, false, "interaction_expired")
                    return
                end
                Protect(function()
                    Element:SetEnableCollision(operation.rootId, false)
                    Element:SetRotation(operation.rootId, rotation, Element.COORDINATE.World)
                    context.Timers:AddFrame(PlacementService.Name, GameConfig.Runtime.EngineOperationDelayFrames,
                        Protect(function() CommitPlacement(operation) end))
                end)()
            end)
    end)

    runtime.CancelCallback = Protect(function(_, message, playerId)
        if type(message) ~= "table" then return end
        local target = runtime.Targets[playerId]
        if target and target.elementId == message.elementId
            and (target.version == message.version
                or (target.operation and target.operation.requestVersion == message.version)) then
            ClearTarget(playerId)
        end
    end)
    runtime.SnapshotCallback = Protect(function(_, _, playerId)
        if not IsPositiveInteger(playerId) then return end
        if runtime.Ready then RefreshTarget(playerId) end
        SendState(playerId)
    end)
    runtime.PreleaveCallback = Protect(function(playerId)
        PrepareLeave(playerId)
        restoreOperations[playerId] = nil
        ClearTarget(playerId)
        local homeIds = {}
        for homeId, house in pairs(runtime.Homes) do
            if house.playerId == playerId then homeIds[#homeIds + 1] = homeId end
        end
        for _, homeId in ipairs(homeIds) do ClearHome(playerId, homeId) end
    end)
    if GameConfig.Persistence.ProductionEnabled then
        assert(persistence:RegisterAdapter("placement", {
            Export = function(id)
                local snapshot = runtime:GetPlacedSnapshot(id)
                if not snapshot then return nil, "home_missing" end
                local rows = {}
                for _, slot in ipairs(snapshot.slots) do
                    local item = slot.chicken
                    if not Decimal.FromSafeInteger(item.finalSellPrice) then return nil, "invalid_placed_chicken_price" end
                    rows[#rows + 1] = { slot.slotIndex, item.itemId, item.typeId, item.sequence, item.finalSellPrice }
                end
                return { version = 2, slots = rows }
            end,
            Restore = function(id, data, done)
                -- nil仅是协调器定义的新玩家；旧版本/缺价格一律拒绝，不补档。
                if data == nil then
                    local homeId = home:GetPlayerHome(id)
                    if not homeId then done(false, "home_missing"); return end
                    ClearHome(id, homeId)
                    runtime.Homes[homeId] = { playerId = id, slots = {}, count = 0 }
                    done(true, function() PublishPlaced(id, homeId); return true end)
                    return
                end
                if type(data) ~= "table" or data.version ~= 2 or type(data.slots) ~= "table" or #data.slots > ChickenCapacity(id) then done(false, "invalid_placement_snapshot"); return end
                local homeId = home:GetPlayerHome(id)
                if not homeId then done(false, "home_missing"); return end
                local generation = inventory:GetSessionGeneration(id)
                local inv = inventory:ExportSnapshot(id, generation)
                if not inv then done(false, "inventory_missing"); return end
                local usedIds, usedSequences, usedSlots, rows = {}, {}, {}, {}
                for _, item in ipairs(inventory:GetSnapshot(id)) do usedIds[item.itemId], usedSequences[item.sequence] = true, true end
                local slotElements = {}
                for elementId, slot in pairs(home.PlacementSlotsByElement) do
                    if slot.homeId == homeId then slotElements[slot.slotIndex] = elementId end
                end
                local count = 0
                for key in pairs(data.slots) do
                    if not IsPositiveInteger(key) or key > #data.slots then done(false, "invalid_placement_rows"); return end
                    count = count + 1
                end
                if count ~= #data.slots then done(false, "invalid_placement_rows"); return end
                for _, row in ipairs(data.slots) do
                    if type(row) ~= "table" or #row ~= 5 or not Decimal.FromSafeInteger(row[5]) or not IsPositiveInteger(row[1]) or not slotElements[row[1]]
                        or type(row[2]) ~= "string" or type(row[3]) ~= "string" or not IsPositiveInteger(row[4])
                        or row[4] > inv.sequenceHighWater or not SlotUnlocked(id, row[1]) or usedIds[row[2]] or usedSequences[row[4]] or usedSlots[row[1]] then
                        done(false, "invalid_placement_identity"); return
                    end
                    local owner, seq = row[2]:match("^chicken:([1-9][0-9]*):([1-9][0-9]*)$")
                    local config = GameConfig.ChickenTypes[row[3]]
                    if not owner or seq ~= string.format("%.0f", row[4]) or not config or not config.Enabled or not IsPositiveInteger(config.TemplateRootId) then
                        done(false, "invalid_placement_chicken"); return
                    end
                    usedIds[row[2]], usedSequences[row[4]], usedSlots[row[1]] = true, true, true
                    rows[#rows + 1] = { slot = row[1], elementId = slotElements[row[1]], config = config,
                        item = { itemId = row[2], kind = "Chicken", typeId = row[3], sequence = row[4], finalSellPrice = row[5], count = 1,
                            displayName = config.DisplayName, iconIndex = config.ChickenIconIndex } }
                end
                ClearHome(id, homeId)
                local house, token = { playerId = id, slots = {}, count = 0 }, {}
                runtime.Homes[homeId], restoreOperations[id] = house, token
                local function Valid()
                    return Active() and restoreOperations[id] == token and runtime.Homes[homeId] == house
                        and home:IsOwner(id, homeId) and inventory:GetSessionGeneration(id) == generation
                end
                local function Fail(reason)
                    if Valid() then
                        restoreOperations[id] = nil
                        ClearHome(id, homeId)
                        done(false, reason)
                    end
                end
                local index = 0
                local function Next()
                    if not Valid() then return end
                    index = index + 1
                    local row = rows[index]
                    if not row then
                        restoreOperations[id] = nil
                        done(true, function() PublishPlaced(id, homeId); return true end)
                        return
                    end
                    local position, rotation = Element:GetPosition(row.elementId), Element:GetRotation(row.elementId)
                    if not position or not rotation then Fail("slot_transform_missing"); return end
                    local ok, err = pcall(function()
                        context.ElementCopy:CopyTree(row.config.TemplateRootId, position, "RestorePlacement:" .. tostring(id), function(result)
                            if not result.success then Fail(result.reason); return end
                            if not Valid() then DestroyRoot(result.rootId, "late_restore"); return end
                            local rotated, why = pcall(function()
                                Element:SetEnableCollision(result.rootId, false)
                                Element:SetRotation(result.rootId, rotation, Element.COORDINATE.World)
                            end)
                            if not rotated then DestroyRoot(result.rootId, "restore_rotation_failed"); Fail(why); return end
                            -- 将完整树登记到待恢复house，离开/Stop在两帧等待期间也能清理。
                            house.slots[row.slot] = { chicken = row.item, rootId = result.rootId }
                            house.count = house.count + 1
                            context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                                if not Valid() then return end
                                local okTransform, transformError = pcall(function()
                                    local p, r = Element:GetPosition(result.rootId), Element:GetRotation(result.rootId)
                                    if not p or not r then error("restore_transform_missing") end
                                    for _, axis in ipairs({ "X", "Y", "Z" }) do
                                        if math.abs(p[axis] - position[axis]) > 0.1 or math.abs((r[axis] - rotation[axis] + 180) % 360 - 180) > 0.1 then error("restore_transform_mismatch") end
                                    end
                                end)
                                if not okTransform then Fail(transformError); return end
                                Next()
                            end)
                        end)
                    end)
                    if not ok then Fail(err) end
                end
                Next()
            end,
            Cleanup = function(id) runtime.PreleaveCallback(id) end,
        }))
    end
    runtime.Cleanup = function()
        restoreOperations = {}
        runtime.Stopped = true
        for playerId, target in pairs(runtime.Targets) do
            InvalidateOperation(target)
            runtime.Revision = runtime.Revision + 1
            local ok, errorMessage = pcall(function()
                System:SendToClient(playerId, context.NetMsg.Messages.PlacementState, {
                    revision = runtime.Revision, version = NextVersion(),
                    canPlace = false, canRecall = false, busy = false,
                })
            end)
            if not ok then Log:PrintError("[PlacementService] 停止时关闭交互通知失败", tostring(errorMessage)) end
        end
        local clearedHomes = runtime.Homes
        runtime.Targets, runtime.Homes = {}, {}
        for homeId, house in pairs(clearedHomes) do
            for _, record in pairs(house.slots) do DestroyRoot(record.rootId, "placement_stop") end
            PublishPlaced(house.playerId, homeId, true)
        end
    end

    System:RegisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    System:BindNotify(context.NetMsg.Messages.PlacementAction, runtime.ActionCallback)
    System:BindNotify(context.NetMsg.Messages.PlacementCancel, runtime.CancelCallback)
    System:BindNotify(context.NetMsg.Messages.PlacementSnapshotRequest, runtime.SnapshotCallback)
    context.Events:Subscribe(PlacementService.Name, "HomeReleased", Protect(function(snapshot)
        ClearHome(snapshot.playerId, snapshot.homeId)
    end))
    context.Events:Subscribe(PlacementService.Name, "InventoryChanged", Protect(function(snapshot)
        if runtime.Ready and not runtime.Committing then
            RefreshTarget(snapshot.playerId)
            SendState(snapshot.playerId)
        end
    end))
    context.Timers:AddTimer(PlacementService.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if Active() then
            runtime.Ready = true
        end
    end)
    context.Timers:AddLoopFrame(PlacementService.Name, 1, Protect(function()
        if not runtime.Ready or runtime.Committing then return end
        local playerIds = {}
        for playerId in pairs(runtime.Targets) do playerIds[#playerIds + 1] = playerId end
        for _, playerId in ipairs(playerIds) do RefreshTarget(playerId) end
    end))
end

function PlacementService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.PlacementService
    if not runtime then return end
    runtime.Cleanup()
    context.Services.PlacementService = nil
    System:UnbindNotify(context.NetMsg.Messages.ChickenModelSnapshotRequest, runtime.ModelSnapshotCallback)
    System:UnregisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    System:UnbindNotify(context.NetMsg.Messages.PlacementAction, runtime.ActionCallback)
    System:UnbindNotify(context.NetMsg.Messages.PlacementCancel, runtime.CancelCallback)
    System:UnbindNotify(context.NetMsg.Messages.PlacementSnapshotRequest, runtime.SnapshotCallback)
    context.Events:UnsubscribeOwner(PlacementService.Name)
    context.Timers:RemoveOwner(PlacementService.Name)
end

return PlacementService
