local GameConfig = require "Common.Config.GameConfig"

local HotbarService = {
    Name = "HotbarService",
    FeatureFlag = "Hotbar",
    Dependencies = { "InventoryService", "ZoneService" },
}

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function CopyPosition(value)
    return Engine.Vector(value.X, value.Y, value.Z)
end

local function FindEggConfig(eggTypeId)
    for _, chickenConfig in pairs(GameConfig.ChickenTypes) do
        local eggConfig = chickenConfig.Egg
        if eggConfig and eggConfig.EggTypeId == eggTypeId then
            return eggConfig
        end
    end
    return nil
end

local function ResolveTemplate(item)
    if item.kind == "Chicken" then
        local config = GameConfig.ChickenTypes[item.typeId]
        return config and config.TemplateRootId or nil
    end
    if item.kind == "Egg" then
        local config = FindEggConfig(item.typeId)
        return config and config.Enabled and config.TemplateRootId or nil
    end
    return nil
end

function HotbarService:ValidateConfig(context)
    if context.Side ~= "Server" then return true end
    local errors = {}
    local config = GameConfig.Hotbar
    if type(config) ~= "table" then
        errors[#errors + 1] = "GameConfig.Hotbar 必须是 table"
    elseif type(config.DisplayHeight) ~= "number" then
        errors[#errors + 1] = "Hotbar.DisplayHeight 必须是 number"
    end
    return #errors == 0, errors
end

function HotbarService:Start(context)
    if context.Side ~= "Server" then return end

    local inventory = context.Services.InventoryService
    local zone = context.Services.ZoneService
    local delayFrames = GameConfig.Runtime.EngineOperationDelayFrames
    local runtime = {
        States = {},
        SnapshotRequestCallback = nil,
        ToggleCallback = nil,
        FatalDamageCallback = nil,
        PreleaveCallback = nil,
    }

    local function EnsureState(playerId)
        local state = runtime.States[playerId]
        if not state then
            state = {
                selectedItemId = nil,
                displayRootId = nil,
                busy = false,
                operation = 0,
            }
            runtime.States[playerId] = state
        end
        return state
    end

    local modelVersion = 0
    local function SendModel(playerId, recipient, cleared)
        local state = runtime.States[playerId]
        local item = state and state.selectedItemId and inventory:GetItem(playerId, state.selectedItemId)
        local models = {}
        if not cleared and state and state.displayRootId and item and item.kind == "Chicken" then
            models[1] = { rootId = state.displayRootId, finalSellPrice = item.finalSellPrice, chickenType = item.typeId }
        elseif not cleared and state and state.displayRootId and item and item.kind == "Egg" then
            models[1] = { kind = "Egg", rootId = state.displayRootId, eggTypeId = item.typeId, finalSellPrice = item.finalSellPrice }
        end
        modelVersion = modelVersion + 1
        local message = { source = "hotbar", playerId = playerId, version = modelVersion, models = models }
        if recipient then System:SendToClient(recipient, context.NetMsg.Messages.ChickenModelState, message)
        else System:SendToAllClients(context.NetMsg.Messages.ChickenModelState, message) end
    end
    runtime.ModelSnapshotCallback = function(_, _, playerId)
        if context.Services.HotbarService ~= runtime or not IsPositiveInteger(playerId) then return end
        for ownerId in pairs(runtime.States) do SendModel(ownerId, playerId) end
    end
    runtime.ClearModel = function(playerId) SendModel(playerId, nil, true) end
    local function SendSnapshot(playerId)
        SendModel(playerId)
        if not IsPositiveInteger(playerId) then return end
        local state = EnsureState(playerId)
        local visible = not zone:IsInStolenArea(playerId)
        local message = {
            items = inventory:GetSnapshot(playerId),
            selectedItemId = state.selectedItemId,
            visible = visible,
        }
        System:SendToClient(playerId, context.NetMsg.Messages.InventorySnapshot, message)
        System:SendToClient(playerId, context.NetMsg.Messages.HotbarSelectionState, {
            selectedItemId = state.selectedItemId,
            visible = visible,
            busy = state.busy,
        })
    end

    local function DestroyRootNow(rootId, reason)
        if not IsPositiveInteger(rootId) then return end
        local ok, errorMessage = pcall(function()
            context.ElementCopy:DestroyTree(rootId)
        end)
        if not ok then
            Log:PrintError("[HotbarService] 销毁头顶展示树失败",
                "rootId:", tostring(rootId),
                "reason:", tostring(reason),
                "error:", tostring(errorMessage))
        end
    end

    local function CancelSelection(playerId, reason, onComplete, sendSnapshot)
        local state = EnsureState(playerId)
        state.operation = state.operation + 1
        local operation = state.operation
        local rootId = state.displayRootId
        state.selectedItemId = nil
        state.displayRootId = nil
        state.busy = rootId ~= nil
        if sendSnapshot ~= false then SendSnapshot(playerId) else SendModel(playerId) end

        local function Complete()
            if state.operation ~= operation then return end
            state.busy = false
            if sendSnapshot ~= false then SendSnapshot(playerId) end
            if onComplete then onComplete() end
        end

        if not rootId then
            Complete()
            return true
        end

        local unbindOk, unbindError = pcall(function()
            Element:UnBinding(rootId)
        end)
        if not unbindOk then
            Log:PrintWarning("[HotbarService] 解绑展示树失败，仍按已确认流程继续销毁",
                "rootId:", rootId, "error:", tostring(unbindError))
        end
        context.Timers:AddFrame(HotbarService.Name, delayFrames, function()
            DestroyRootNow(rootId, reason)
            if onComplete then
                context.Timers:AddFrame(HotbarService.Name, delayFrames, Complete)
            else
                Complete()
            end
        end)
        Log:PrintServerLog("[HotbarService] 已取消快捷栏选择",
            "playerId:", playerId,
            "itemId:", tostring(state.selectedItemId),
            "rootId:", tostring(rootId),
            "reason:", tostring(reason))
        return true
    end

    local function SpawnAndSelect(playerId, itemId)
        local state = EnsureState(playerId)

        local item = inventory:GetItem(playerId, itemId)
        if not item then
            state.busy = false
            SendSnapshot(playerId)

            return false, "item_not_found"
        end
        local templateRootId = ResolveTemplate(item)
        if not IsPositiveInteger(templateRootId) then
            state.busy = false
            SendSnapshot(playerId)

            return false, "item_template_not_configured"
        end
        local playerPosition = Character:GetPosition(playerId)
        if not playerPosition then
            state.busy = false
            SendSnapshot(playerId)

            return false, "player_position_unavailable"
        end

        state.operation = state.operation + 1
        local operation = state.operation
        local generation = inventory:GetSessionGeneration(playerId)
        local function Current()
            local latest = inventory:GetItem(playerId, itemId)
            return context.Services.HotbarService == runtime and runtime.States[playerId] == state
                and state.operation == operation and inventory:GetSessionGeneration(playerId) == generation
                and latest ~= nil and latest.kind == item.kind and latest.typeId == item.typeId
                and latest.finalSellPrice == item.finalSellPrice
                and (item.kind ~= "Egg" or (latest.finalScale == item.finalScale
                    and latest.finalScaleUnits == item.finalScaleUnits))
                and not zone:IsInStolenArea(playerId)
        end
        state.busy = true
        local targetPosition = Engine.Vector(
            playerPosition.X,
            playerPosition.Y,
            playerPosition.Z + GameConfig.Hotbar.DisplayHeight
        )

        context.ElementCopy:CopyTree(
            templateRootId,
            targetPosition,
            "快捷栏展示:" .. itemId,
            function(result)
                if not result.success then
                    if state.operation == operation then
                        state.busy = false
                        SendSnapshot(playerId)
                    end
                    Log:PrintError("[HotbarService] 快捷栏展示复制失败",
                        "playerId:", playerId,
                        "itemId:", itemId,
                        "reason:", tostring(result.reason))
                    return
                end
                if not Current() then
                    DestroyRootNow(result.rootId, "stale_hotbar_copy")
                    return
                end

                local latestPosition = Character:GetPosition(playerId)
                if not latestPosition then
                    DestroyRootNow(result.rootId, "player_position_unavailable_after_copy")
                    state.busy = false
                    SendSnapshot(playerId)
                    return
                end
                Element:SetPosition(result.rootId, Engine.Vector(
                    latestPosition.X,
                    latestPosition.Y,
                    latestPosition.Z + GameConfig.Hotbar.DisplayHeight
                ), Element.COORDINATE.World)

                context.Timers:AddFrame(HotbarService.Name, delayFrames, function()
                    if not Current() then
                        DestroyRootNow(result.rootId, "selection_changed_before_bind")
                        return
                    end

                    Element:SetEnableCollision(result.rootId, false)
                    if item.kind == "Egg" then
                        Element:SetScale(result.rootId, Engine.Vector(item.finalScale, item.finalScale, item.finalScale))
                    end
                    Element:BindingToCharacterOrCreature(
                        result.rootId,
                        playerId,
                        GameConfig.Theft.CharacterSocket,
                        GameConfig.Theft.SocketMode
                    )

                    context.Timers:AddFrame(HotbarService.Name, delayFrames, function()
                        if not Current() then
                            DestroyRootNow(result.rootId, "selection_changed_after_bind")
                            return
                        end
                        local attachedPlayerId = Element:GetAttachParentCharacter(result.rootId)

                        if attachedPlayerId ~= playerId then
                            DestroyRootNow(result.rootId, "bind_verification_failed")
                            state.busy = false
                            SendSnapshot(playerId)
                            Log:PrintError("[HotbarService] 头顶展示附加验证失败",
                                "playerId:", playerId, "itemId:", itemId)
                            return
                        end
                        state.selectedItemId = itemId
                        state.displayRootId = result.rootId
                        state.busy = false
                        SendSnapshot(playerId)
                        Log:PrintServerLog("[HotbarService] 快捷栏物品已附加",
                            "playerId:", playerId,
                            "itemId:", itemId,
                            "rootId:", result.rootId,
                            "height:", GameConfig.Hotbar.DisplayHeight)
                    end)
                end)
            end
        )
        return true
    end

    function runtime:CancelSelection(playerId, reason)
        return CancelSelection(playerId, reason, nil, true)
    end

    function runtime:AdoptExistingDisplay(playerId, itemId, rootId)
        if not inventory:HasItem(playerId, itemId) or not IsPositiveInteger(rootId) then
            return false, "invalid_adopt_request"
        end
        Element:SetEnableCollision(rootId, false)
        local state = EnsureState(playerId)
        local function Adopt()
            state.operation = state.operation + 1
            state.selectedItemId = itemId
            state.displayRootId = rootId
            state.busy = false
            SendSnapshot(playerId)
            Log:PrintServerLog("[HotbarService] 已接管带回家园的鸡树",
                "playerId:", playerId, "itemId:", itemId, "rootId:", rootId)
        end
        if state.displayRootId then
            CancelSelection(playerId, "adopt_owned_chicken", Adopt, true)
        else
            state.operation = state.operation + 1
            Adopt()
        end
        return true
    end

    function runtime:GetSelectedItem(playerId)
        local state = self.States[playerId]
        return state and state.selectedItemId or nil
    end

    local function ToggleSelection(playerId, itemId)
        local persistence = context.Services.PersistenceService
        if GameConfig.Persistence.ProductionEnabled and (not persistence or not persistence:IsReady(playerId)) then return false, "persistence_not_ready" end
        if zone:IsInStolenArea(playerId) then
            SendSnapshot(playerId)
            return false, "hotbar_hidden_in_stolen_area"
        end
        local state = EnsureState(playerId)
        if state.busy then
            SendSnapshot(playerId)
            return false, "selection_operation_busy"
        end
        if not inventory:HasItem(playerId, itemId) then
            SendSnapshot(playerId)
            return false, "item_not_found"
        end
        if state.selectedItemId == itemId then
            CancelSelection(playerId, "clicked_selected_item", nil, true)
            return true
        end
        if state.displayRootId then
            state.busy = true
            CancelSelection(playerId, "switch_selection", function()
                SpawnAndSelect(playerId, itemId)
            end, true)
            return true
        end
        return SpawnAndSelect(playerId, itemId)
    end

    runtime.SnapshotRequestCallback = function(_, message, playerId)
        if type(message) ~= "table" or not IsPositiveInteger(playerId) then
            Log:PrintWarning("[HotbarService] 拒绝无效库存快照请求",
                "playerId:", tostring(playerId), "messageType:", type(message))
            return
        end
        SendSnapshot(playerId)
    end
    runtime.ToggleCallback = function(_, message, playerId)
        if type(message) ~= "table" or not IsPositiveInteger(playerId)
            or type(message.itemId) ~= "string" or message.itemId == "" then
            Log:PrintWarning("[HotbarService] 拒绝无效快捷栏选择请求",
                "playerId:", tostring(playerId), "messageType:", type(message))
            return
        end
        local success, reason = ToggleSelection(playerId, message.itemId)

        if not success then
            Log:PrintServerLog("[HotbarService] 快捷栏选择请求被拒绝",
                "playerId:", playerId, "itemId:", message.itemId, "reason:", reason)
        end
    end
    runtime.FatalDamageCallback = function(playerId)
        if IsPositiveInteger(playerId) then
            CancelSelection(playerId, "fatal_damage", nil, true)
        end
    end
    runtime.PreleaveCallback = function(playerId)
        local persistence = context.Services.PersistenceService
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(playerId) end
        if IsPositiveInteger(playerId) then
            CancelSelection(playerId, "player_preleave", nil, false)
            runtime.States[playerId] = nil
        end
    end

    local function ProtectCallback(actionName, callback)
        return function(...)
            local args = { n = select("#", ...), ... }
            local unpackArgs = table.unpack or unpack
            local ok, errorMessage = xpcall(function()
                callback(unpackArgs(args, 1, args.n))
            end, Traceback)
            if not ok then
                context.Manager:FailModule(
                    HotbarService.Name,
                    actionName .. ": " .. tostring(errorMessage)
                )
            end
        end
    end

    runtime.SnapshotRequestCallback = ProtectCallback(
        "库存快照请求回调失败",
        runtime.SnapshotRequestCallback
    )
    runtime.ToggleCallback = ProtectCallback(
        "快捷栏选择请求回调失败",
        runtime.ToggleCallback
    )
    runtime.FatalDamageCallback = ProtectCallback(
        "玩家死亡清理回调失败",
        runtime.FatalDamageCallback
    )
    runtime.PreleaveCallback = ProtectCallback(
        "玩家离开清理回调失败",
        runtime.PreleaveCallback
    )

    context.Services.HotbarService = runtime
    System:BindNotify(context.NetMsg.Messages.ChickenModelSnapshotRequest, runtime.ModelSnapshotCallback)
    context.Events:Subscribe(HotbarService.Name, "ZoneChanged", function(snapshot)
        if snapshot.inStolenArea == true then
            CancelSelection(snapshot.playerId, "entered_stolen_area", nil, true)
        else
            SendSnapshot(snapshot.playerId)
        end
    end)
    context.Events:Subscribe(HotbarService.Name, "InventoryChanged", function(snapshot)
        local state = EnsureState(snapshot.playerId)
        if state.selectedItemId and not inventory:HasItem(snapshot.playerId, state.selectedItemId) then
            CancelSelection(snapshot.playerId, "selected_item_removed", nil, true)
        else
            SendSnapshot(snapshot.playerId)
        end
    end)
    System:BindNotify(context.NetMsg.Messages.InventorySnapshotRequest, runtime.SnapshotRequestCallback)
    System:BindNotify(context.NetMsg.Messages.HotbarToggleSelection, runtime.ToggleCallback)
    System:RegisterEvent(Events.ON_CHARACTER_TAKE_FATAL_DAMAGE, runtime.FatalDamageCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    Log:PrintServerLog("[HotbarService] 正式快捷栏服务端模块已启动",
        "displayHeight:", GameConfig.Hotbar.DisplayHeight)
end

function HotbarService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.HotbarService
    if not runtime then return end
    if runtime.SnapshotRequestCallback then
        System:UnbindNotify(context.NetMsg.Messages.InventorySnapshotRequest, runtime.SnapshotRequestCallback)
    end
    if runtime.ToggleCallback then
        System:UnbindNotify(context.NetMsg.Messages.HotbarToggleSelection, runtime.ToggleCallback)
    end
    if runtime.FatalDamageCallback then
        System:UnregisterEvent(Events.ON_CHARACTER_TAKE_FATAL_DAMAGE, runtime.FatalDamageCallback)
    end
    if runtime.PreleaveCallback then
        System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    end
    System:UnbindNotify(context.NetMsg.Messages.ChickenModelSnapshotRequest, runtime.ModelSnapshotCallback)
    for playerId, state in pairs(runtime.States) do
        runtime.ClearModel(playerId)
        if state.displayRootId then
            pcall(function() Element:UnBinding(state.displayRootId) end)
            local rootId = state.displayRootId
            local ok, errorMessage = pcall(function()
                context.ElementCopy:DestroyTree(rootId)
            end)
            if not ok then
                Log:PrintError("[HotbarService] 停止模块时销毁头顶展示树失败",
                    "rootId:", tostring(rootId),
                    "error:", tostring(errorMessage))
            end
        end
    end
    runtime.States = {}
    context.Services.HotbarService = nil
end

return HotbarService
