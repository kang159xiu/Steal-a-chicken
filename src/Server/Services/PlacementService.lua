local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local RestoreDiag = require "Common.Debug.HomeModelRestoreDiag"

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


function PlacementService:Start(context)
    if context.Side ~= "Server" then return end
    local home = context.Services.HomeService
    local inventory = context.Services.InventoryService
    local hotbar = context.Services.HotbarService
    local runtime = { Ready = false, Stopped = false, Targets = {}, Homes = {}, Pending = {}, Sequence = 0,
        Revision = 0, Committing = false, PositionReadFailures = {}, PanelJobs = {}, PanelVersions = {} }
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
    local CancelPanel

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
                if record.rootId then
                    models[#models + 1] = { rootId = record.rootId, finalSellPrice = record.chicken.finalSellPrice,
                        chickenType = record.chicken.typeId }
                end
            end
        end
        modelVersion = modelVersion + 1
        local message = { source = "placement", playerId = playerId, version = modelVersion, models = models }
        RestoreDiag.Log("Server", "placement", "models_send", function()
            local ids = {}; for _, model in ipairs(models) do ids[#ids + 1] = tostring(model.rootId) end
            local missing = 0
            if house then for _, record in pairs(house.slots) do if not record.rootId then missing = missing + 1 end end end
            return { playerId = playerId, homeId = homeId, recipient = recipient or "all", version = modelVersion,
                count = #models, rootIds = table.concat(ids, ","), logicalCount = house and house.count or 0, missingModels = missing }
        end)
        if recipient then System:SendToClient(recipient, context.NetMsg.Messages.ChickenModelState, message)
        else System:SendToAllClients(context.NetMsg.Messages.ChickenModelState, message) end
        RestoreDiag.Log("Server", "placement", "models_sent", { playerId = playerId, homeId = homeId, version = modelVersion })
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
        RestoreDiag.Log("Server", "placement", "model_destroy", { rootId = rootId, reason = reason })
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
            busy = runtime.PanelJobs[playerId] ~= nil or (target ~= nil and target.operation ~= nil),
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
        if CancelPanel then CancelPanel(playerId, "home_released") end
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
        if runtime.PanelJobs[playerId] then return end
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
        if runtime.PanelJobs[playerId] then
            SendState(playerId)
            return
        end
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
                    Element:SetRotation(operation.rootId, rotation, Element.COORDINATE.World)
                    local scale = item.finalSellPrice / config.ChickenSellPrice
                    Element:SetScale(operation.rootId, Engine.Vector(scale, scale, scale))
                    context.Timers:AddFrame(PlacementService.Name, GameConfig.Runtime.EngineOperationDelayFrames,
                        Protect(function() CommitPlacement(operation) end))
                end)()
            end, nil, playerId)
    end)

    -- 面板入口与近身交互共用同一份家园记录；面板无需手持或碰撞目标。
    local function PanelItems(playerId)
        local items = {}
        for _, item in ipairs(inventory:GetSnapshot(playerId)) do
            if item.kind == "Chicken" then
                items[#items + 1] = { itemId = item.itemId, typeId = item.typeId,
                    finalSellPrice = item.finalSellPrice, equipped = false }
            end
        end
        local placed = runtime:GetPlacedSnapshot(playerId)
        for _, slot in ipairs(placed and placed.slots or {}) do
            local item = slot.chicken
            items[#items + 1] = { itemId = item.itemId, typeId = item.typeId,
                finalSellPrice = item.finalSellPrice, equipped = true, slotIndex = slot.slotIndex }
        end
        table.sort(items, function(a, b)
            if a.finalSellPrice ~= b.finalSellPrice then return a.finalSellPrice > b.finalSellPrice end
            return a.itemId < b.itemId
        end)
        return items
    end
    local function SendPanel(playerId)
        if not Active() or not runtime.Ready then
            return
        end
        local job = runtime.PanelJobs[playerId]
        local version = (runtime.PanelVersions[playerId] or 0) + 1
        runtime.PanelVersions[playerId] = version
        local message = {
            version = version, homeId = home:GetPlayerHome(playerId), busy = job ~= nil,
            items = job and job.initialItems or PanelItems(playerId),
        }
        System:SendToClient(playerId, context.NetMsg.Messages.AnimalEquipmentState, message)
    end
    local function FinishPanel(job, cancelled)
        if runtime.PanelJobs[job.playerId] ~= job then
            return
        end
        job.cancelled = cancelled
        if job.rootId then DestroyRoot(job.rootId, "panel_cancelled"); job.rootId = nil end
        for _, prepared in ipairs(job.prepared) do
            if prepared.rootId then DestroyRoot(prepared.rootId, "panel_uncommitted"); prepared.rootId = nil end
        end
        -- 批次结束时仍持有面板锁，避免自身库存通知重复刷新列表。
        job.endBatch()
        if job.changed and runtime.Homes[job.homeId] == job.house then
            PublishPlaced(job.playerId, job.homeId)
        end
        runtime.PanelJobs[job.playerId] = nil
        if not Active() then return end
        RefreshTarget(job.playerId)
        SendState(job.playerId)
        SendPanel(job.playerId)
        System:SendToClient(job.playerId, context.NetMsg.Messages.AnimalEquipmentResult, {
            requestId = job.requestId, success = not cancelled and job.failures == 0,
            reason = cancelled or (job.failures > 0 and "partial_failure" or "completed"),
            changed = job.changed == true, failures = job.failures,
        })
    end
    CancelPanel = function(playerId, reason)
        local job = runtime.PanelJobs[playerId]
        if job then FinishPanel(job, reason) end
    end
    local function PanelCurrent(job)
        return Active() and runtime.PanelJobs[job.playerId] == job and not job.cancelled
            and CanPlay(job.playerId) and home:GetPlayerHome(job.playerId) == job.homeId
            and runtime.Homes[job.homeId] == job.house
    end
    runtime.PanelSnapshotCallback = Protect(function(_, _, playerId) SendPanel(playerId) end)
    runtime.PanelActionCallback = Protect(function(_, message, playerId)
        if type(message) ~= "table" or not IsPositiveInteger(playerId)
            or not IsPositiveInteger(message.requestId) or not IsPositiveInteger(message.version)
            or (message.action ~= "best" and message.action ~= "equip" and message.action ~= "unequip")
            or (message.action ~= "best" and type(message.itemId) ~= "string") then
            return
        end
        local function Reject(reason)
            SendPanel(playerId)
            System:SendToClient(playerId, context.NetMsg.Messages.AnimalEquipmentResult, {
                requestId = message.requestId, success = false, reason = reason,
            })
        end
        local target = runtime.Targets[playerId]
        if not runtime.Ready or not CanPlay(playerId) then Reject("not_ready"); return end
        if runtime.PanelJobs[playerId] or (target and target.operation) then Reject("operation_busy"); return end
        local homeId = home:GetPlayerHome(playerId)
        if not homeId or message.homeId ~= homeId or message.version ~= runtime.PanelVersions[playerId] then
            Reject("interaction_expired"); return
        end
        local house = runtime.Homes[homeId]
        if not house then
            house = { playerId = playerId, slots = {}, count = 0 }
            runtime.Homes[homeId] = house
        end
        if house.playerId ~= playerId then Reject("home_unavailable"); return end
        local slots, byIndex = {}, {}
        for _, slot in ipairs(home:GetPlacementSlots(homeId)) do
            if SlotUnlocked(playerId, slot.slotIndex) then
                slots[#slots + 1] = slot
                byIndex[slot.slotIndex] = slot
            end
        end
        local items, tasks = PanelItems(playerId), {}
        if message.action == "best" then
            local ranking = {}
            for _, item in ipairs(items) do ranking[#ranking + 1] = item end
            table.sort(ranking, function(a, b)
                if a.finalSellPrice ~= b.finalSellPrice then return a.finalSellPrice > b.finalSellPrice end
                if a.equipped ~= b.equipped then return a.equipped end
                return a.itemId < b.itemId
            end)
            local wanted, incoming = {}, {}
            for i = 1, math.min(ChickenCapacity(playerId), #slots, #ranking) do
                local item = ranking[i]; wanted[item.itemId] = true
                if not item.equipped then incoming[#incoming + 1] = item end
            end
            local destinations = {}
            -- 先替换未入选的鸡，再填空位；副本失败时该位原鸡仍保留。
            for _, slot in ipairs(slots) do
                local previous = house.slots[slot.slotIndex]
                if previous and not wanted[previous.chicken.itemId] then destinations[#destinations + 1] = slot end
            end
            for _, slot in ipairs(slots) do
                if not house.slots[slot.slotIndex] then destinations[#destinations + 1] = slot end
            end
            for i, item in ipairs(incoming) do
                if destinations[i] then tasks[#tasks + 1] = { slot = destinations[i], item = item } end
            end
        else
            local selected
            for _, item in ipairs(items) do if item.itemId == message.itemId then selected = item; break end end
            if not selected or selected.equipped ~= (message.action == "unequip") then Reject("item_changed"); return end
            if selected.equipped then
                local slot = byIndex[selected.slotIndex]
                if not slot then Reject("slot_locked"); return end
                tasks[1] = { slot = slot, recall = true }
            else
                local destination
                if house.count < ChickenCapacity(playerId) then
                    for _, slot in ipairs(slots) do if not house.slots[slot.slotIndex] then destination = slot; break end end
                end
                if not destination then
                    for _, slot in ipairs(slots) do
                        local previous = house.slots[slot.slotIndex]
                        if previous and (not destination or previous.chicken.finalSellPrice < house.slots[destination.slotIndex].chicken.finalSellPrice) then
                            destination = slot
                        end
                    end
                end
                if not destination then Reject("capacity_full"); return end
                tasks[1] = { slot = destination, item = selected }
            end
        end
        local endBatch, reason = inventory:BeginChangeBatch(playerId)
        if not endBatch then Reject(reason); return end
        local job = { playerId = playerId, homeId = homeId, house = house, requestId = message.requestId,
            initialItems = items, endBatch = endBatch, failures = 0, prepared = {} }
        runtime.PanelJobs[playerId] = job
        SendState(playerId)
        SendPanel(playerId)
        local index = 0
        local function Next()
            if not PanelCurrent(job) then FinishPanel(job, "interaction_expired"); return end
            index = index + 1
            local task = tasks[index]
            if not task then
                -- 复制等待期间不改资产；所有可提交项在同一段Lua执行中完成交换。
                local replaced = {}
                for _, prepared in ipairs(job.prepared) do
                    local item, slot, previous = prepared.item, prepared.slot, prepared.previous
                    local current = inventory:GetItem(playerId, item.itemId)
                    local valid = current and current.kind == "Chicken" and current.typeId == item.typeId
                        and current.finalSellPrice == item.finalSellPrice and house.slots[slot.slotIndex] == previous
                        and SlotUnlocked(playerId, slot.slotIndex)
                        and (previous ~= nil or house.count < ChickenCapacity(playerId))
                    local transferred, removed
                    if valid then
                        transferred, removed = inventory:TransferChicken(playerId, item.itemId,
                            previous and previous.chicken or nil, "panel_equip")
                    end
                    if transferred then
                        house.slots[slot.slotIndex] = { chicken = removed, rootId = prepared.rootId }
                        if not previous then house.count = house.count + 1 end
                        prepared.rootId, job.changed = nil, true
                        if previous then replaced[#replaced + 1] = previous.rootId end
                    else
                        job.failures = job.failures + 1
                        Log:PrintError("[AnimalEquipment] 提交失败，保留原鸡", playerId, slot.slotIndex,
                            tostring(removed or "item_or_slot_changed"))
                    end
                end
                for _, rootId in ipairs(replaced) do DestroyRoot(rootId, "panel_replace") end
                FinishPanel(job); return
            end
            local previous = house.slots[task.slot.slotIndex]
            local step = {}
            job.step = step
            local function Fail(err)
                if not PanelCurrent(job) or job.step ~= step then return end
                if job.rootId then DestroyRoot(job.rootId, "panel_failed"); job.rootId = nil end
                job.failures = job.failures + 1
                Log:PrintError("[AnimalEquipment] 本项失败，保留原鸡并继续", playerId, task.slot.slotIndex, tostring(err))
                Next()
            end
            if task.recall then
                local ok, err = inventory:TransferChicken(playerId, nil, previous.chicken, "panel_recall")
                if not ok then Fail(err); return end
                house.slots[task.slot.slotIndex], house.count = nil, house.count - 1
                job.changed = true
                DestroyRoot(previous.rootId, "panel_recall")
                Next(); return
            end
            local item = inventory:GetItem(playerId, task.item.itemId)
            if not item or item.kind ~= "Chicken" or item.typeId ~= task.item.typeId
                or item.finalSellPrice ~= task.item.finalSellPrice then Fail("item_changed"); return end
            local config = GameConfig.ChickenTypes[item.typeId]
            local received = false
            local ok, err = pcall(function()
                local position = Element:GetPosition(task.slot.elementId)
                local rotation = Element:GetRotation(task.slot.elementId)
                if not position or not rotation then error("slot_transform_unavailable") end
                context.ElementCopy:CopyTree(config.TemplateRootId, position, "面板放鸡:" .. tostring(playerId), function(result)
                    if received then return end
                    received = true
                    if not PanelCurrent(job) or job.step ~= step then
                        if result.success then DestroyRoot(result.rootId, "late_panel_copy") end
                        FinishPanel(job, "interaction_expired")
                        return
                    end
                    if not result.success then Fail(result.reason); return end
                    job.rootId = result.rootId
                    local configured, configureError = pcall(function()
                        Element:SetRotation(job.rootId, rotation, Element.COORDINATE.World)
                        local scale = item.finalSellPrice / config.ChickenSellPrice
                        Element:SetScale(job.rootId, Engine.Vector(scale, scale, scale))
                        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                            if not PanelCurrent(job) then FinishPanel(job, "interaction_expired"); return end
                            if job.step ~= step then return end
                            local current = inventory:GetItem(playerId, item.itemId)
                            if not current or current.typeId ~= item.typeId or current.finalSellPrice ~= item.finalSellPrice
                                or house.slots[task.slot.slotIndex] ~= previous or not SlotUnlocked(playerId, task.slot.slotIndex)
                                or (not previous and house.count >= ChickenCapacity(playerId)) then Fail("item_or_slot_changed"); return end
                            local readOk, p, r = pcall(function()
                                return Element:GetPosition(job.rootId), Element:GetRotation(job.rootId)
                            end)
                            if not readOk or not p or not r then Fail("placement_transform_unavailable"); return end
                            job.prepared[#job.prepared + 1] = { item = item, slot = task.slot,
                                previous = previous, rootId = job.rootId }
                            job.rootId = nil
                            Next()
                        end)
                    end)
                    if not configured then Fail(configureError) end
                end, nil, playerId)
            end)
            if not ok then Fail(err) end
        end
        Next()
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
        CancelPanel(playerId, "player_preleave")
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
                RestoreDiag.Log("Server", "placement", "restore_enter", function()
                    return { playerId = id, hasData = data ~= nil, rowCount = data and data.slots and #data.slots }
                end)
                if data == nil then data = { version = 2, slots = {} } end
                if data.version ~= 2 then Log:PrintServerLog("[Persistence] version mismatch", id, "placement", tostring(data.version), 2) end
                if data.slots == nil then data.slots = {} end
                local homeId = home:GetPlayerHome(id)
                if not homeId then done(false, "home_missing"); return end
                local slotElements, rows = {}, {}
                for elementId, slot in pairs(home.PlacementSlotsByElement) do
                    if slot.homeId == homeId then slotElements[slot.slotIndex] = elementId end
                end
                for index, row in ipairs(data.slots) do
                    local ok, reason = pcall(function()
                        local config = GameConfig.ChickenTypes[row[3]]
                        if row[2] == nil or row[3] == nil or not config or not slotElements[row[1]] then error("placement_identity_type_or_slot_missing") end
                        if row[4] == nil then row[4] = tonumber(row[2]:match(":([0-9]+)$")) end
                        if row[4] == nil then error("placement_identity_missing") end
                        if row[5] == nil then row[5] = config.ChickenSellPrice end
                        inventory:RestoreSequenceHighWater(row[4])
                        rows[#rows + 1] = { slot = row[1], elementId = slotElements[row[1]], config = config,
                            item = { itemId = row[2], kind = "Chicken", typeId = row[3], sequence = row[4], finalSellPrice = row[5], count = 1,
                                displayName = config.DisplayName, iconIndex = config.ChickenIconIndex } }
                    end)
                    if not ok then Log:PrintError("[Persistence] placement row skipped", id, index, tostring(reason)) end
                end
                ClearHome(id, homeId)
                local house, token = { playerId = id, slots = {}, count = 0 }, {}
                runtime.Homes[homeId], restoreOperations[id] = house, token
                RestoreDiag.Log("Server", "placement", "restore_rows", { playerId = id, homeId = homeId,
                    operation = token, acceptedCount = #rows, rowCount = #data.slots })
                local function Valid()
                    return Active() and restoreOperations[id] == token and runtime.Homes[homeId] == house
                        and home:IsOwner(id, homeId)
                end
                local index, Next = 0, nil
                local function Fail(reason)
                    if not Valid() then return end
                    local row = rows[index]
                    local record = house.slots[row.slot]
                    DestroyRoot(record.rootId, "restore_model_failed")
                    record.rootId = nil
                    RestoreDiag.Log("Server", "placement", "model_missing_record_retained", { playerId = id,
                        homeId = homeId, operation = token, slot = row.slot, itemId = row.item.itemId,
                        templateId = row.config.TemplateRootId, reason = reason })
                    Log:PrintError("[Persistence] placement model skipped; chicken retained", id, row.item.itemId, tostring(reason))
                    Next()
                end
                Next = function()
                    if not Valid() then return end
                    index = index + 1
                    local row = rows[index]
                    if not row then
                        RestoreDiag.Log("Server", "placement", "restore_complete", function()
                            local missing = 0
                            for _, record in pairs(house.slots) do if not record.rootId then missing = missing + 1 end end
                            return { playerId = id, homeId = homeId, operation = token, logicalCount = house.count, missingModels = missing }
                        end)
                        restoreOperations[id] = nil
                        done(true, function() PublishPlaced(id, homeId); return true end)
                        return
                    end
                    house.slots[row.slot] = { chicken = row.item }
                    house.count = house.count + 1
                    local ok, err = pcall(function()
                        local position, rotation = Element:GetPosition(row.elementId), Element:GetRotation(row.elementId)
                        if not position or not rotation then Fail("slot_transform_missing"); return end
                        RestoreDiag.Log("Server", "placement", "copy_requested", { playerId = id, homeId = homeId,
                            operation = token, slot = row.slot, itemId = row.item.itemId, templateId = row.config.TemplateRootId })
                        context.ElementCopy:CopyTree(row.config.TemplateRootId, position, "RestorePlacement:" .. tostring(id), function(result)
                            RestoreDiag.Log("Server", "placement", "copy_result", function()
                                return { playerId = id, homeId = homeId, operation = token, slot = row.slot,
                                    itemId = row.item.itemId, templateId = row.config.TemplateRootId,
                                    rootId = result.rootId, success = result.success, reason = result.reason }
                            end)
                            if not Valid() then
                                if result.success then DestroyRoot(result.rootId, "late_restore") end
                                done(false, "restore_expired")
                                return
                            end
                            if not result.success then Fail(result.reason); return end
                            local rotated, why = pcall(function()
                                Element:SetRotation(result.rootId, rotation, Element.COORDINATE.World)
                                local scale = row.item.finalSellPrice / row.config.ChickenSellPrice
                                Element:SetScale(result.rootId, Engine.Vector(scale, scale, scale))
                            end)
                            if not rotated then DestroyRoot(result.rootId, "restore_rotation_failed"); Fail(why); return end
                            -- 将完整树登记到待恢复house，离开/Stop在两帧等待期间也能清理。
                            house.slots[row.slot].rootId = result.rootId
                            context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                                if not Valid() then done(false, "restore_expired"); return end
                                local okTransform, transformError = pcall(function()
                                    local p, r = Element:GetPosition(result.rootId), Element:GetRotation(result.rootId)
                                    if not p or not r then error("restore_transform_missing") end
                                    for _, axis in ipairs({ "X", "Y", "Z" }) do
                                        if math.abs(p[axis] - position[axis]) > 0.1 or math.abs((r[axis] - rotation[axis] + 180) % 360 - 180) > 0.1 then error("restore_transform_mismatch") end
                                    end
                                end)
                                if not okTransform then Fail(transformError); return end
                                RestoreDiag.Sample("Server", "placement", "transform_verified_committed", { playerId = id,
                                    homeId = homeId, operation = token, slot = row.slot, itemId = row.item.itemId,
                                    rootId = result.rootId, templateId = row.config.TemplateRootId })
                                Next()
                            end)
                        end, nil, id)
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
        local jobs = {}
        for _, job in pairs(runtime.PanelJobs) do jobs[#jobs + 1] = job end
        for _, job in ipairs(jobs) do FinishPanel(job, "module_stopped") end
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
    System:BindNotify(context.NetMsg.Messages.AnimalEquipmentSnapshotRequest, runtime.PanelSnapshotCallback)
    System:BindNotify(context.NetMsg.Messages.AnimalEquipmentAction, runtime.PanelActionCallback)
    context.Events:Subscribe(PlacementService.Name, "HomeReleased", Protect(function(snapshot)
        ClearHome(snapshot.playerId, snapshot.homeId)
    end))
    context.Events:Subscribe(PlacementService.Name, "InventoryChanged", Protect(function(snapshot)
        if runtime.Ready and not runtime.Committing and not runtime.PanelJobs[snapshot.playerId] then
            RefreshTarget(snapshot.playerId)
            SendState(snapshot.playerId)
            SendPanel(snapshot.playerId)
        end
    end))
    context.Events:Subscribe(PlacementService.Name, "PlacedChickensChanged", Protect(function(snapshot)
        if not runtime.PanelJobs[snapshot.playerId] then SendPanel(snapshot.playerId) end
    end))
    context.Timers:AddTimer(PlacementService.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if Active() then
            runtime.Ready = true
        end
    end)
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
    System:UnbindNotify(context.NetMsg.Messages.AnimalEquipmentSnapshotRequest, runtime.PanelSnapshotCallback)
    System:UnbindNotify(context.NetMsg.Messages.AnimalEquipmentAction, runtime.PanelActionCallback)
    context.Events:UnsubscribeOwner(PlacementService.Name)
    context.Timers:RemoveOwner(PlacementService.Name)
end

return PlacementService
