local GameConfig = require "Common.Config.GameConfig"

local PickupController = {
    Name = "PickupController",
    FeatureFlag = "Theft",
    Dependencies = { "PromptController" },
}

local IsPositiveInteger = require("Common.Validation").IsPositiveInteger

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function IsFinitePosition(position)
    return IsFiniteNumber(position.X) and IsFiniteNumber(position.Y) and IsFiniteNumber(position.Z)
end

local function PickupDistanceSquared(first, second)
    local dx = first.X - second.X
    local dy = first.Y - second.Y
    local dz = first.Z - second.Z
    return dx * dx + dy * dy + dz * dz
end

local Traceback = require("Common.Core.SafeCall").Traceback


function PickupController:Start(context)
    if context.Side ~= "Client" then return end

    local config = GameConfig.Theft
    if not config.InteractionEnabled then
        UI:OnShow({ config.CarryUiGroupId }, false)
        UI:SetProgressCurrentValue({ config.PickupProgressId }, 0)
        UI:OnShow({ config.PickupUiGroupId }, false)
        Log:PrintLog("[PickupController] 4A-1 拾取交互关闭，未登记UI与网络回调")
        return
    end
    local runtime = {
        TargetToken = nil,
        WorldVersion = -1,
        WorldGeneration = 0,
        WorldModels = {},
        AvailableByRegion = {},
        DroppedModels = {},
        RegionId = 0,
        Generation = 0,
        RefreshBlocked = false,
        Holding = false,
        AwaitingResult = false,
        HoldStartTime = nil,
        ScanTimerId = nil,
        InStolenArea = false,
        IndicatorDisabled = false,
        IndicatorRoot = nil,
        IndicatorVisible = false,
        IndicatorPosition = nil,
        ProgressTimerId = nil,
        PressedCallback = nil,
        ReleasedCallback = nil,
        ResultCallback = nil,
        CarryVersion = -1,
        CarryRootId = nil,
        CarryOperation = nil,
        CarryReady = false,
        DropPending = false,
        BreakToken = nil,
        BreakRequestId = 0,
        BreakDenied = {},
    }
    context.Services.PickupController = runtime

    local function Run(actionName, callback)
        if context.Services.PickupController ~= runtime then return end
        local ok, errorMessage = xpcall(callback, Traceback)
        if not ok then
            context.Manager:FailModule(PickupController.Name,
                actionName .. ": " .. tostring(errorMessage))
        end
    end

    -- PICKUP_DIAG_BEGIN
    local function PickupDiagnostic(stage, message, reason, inspectWidget)
        pcall(function()
            local incoming = type(message) == "table" and message or {}
            local model = runtime.WorldModels[incoming.elementId or incoming.rootId]
            Log:PrintLog("[PickupDiag][C]", stage, "reason:", tostring(reason),
                "playerId:", tostring(Character:GetLocalPlayerId()), "root:", tostring(incoming.elementId or incoming.rootId),
                "requestGeneration:", tostring(incoming.generation), "requestOperation:", tostring(incoming.operation),
                "generation:", runtime.Generation, "worldGeneration:", runtime.WorldGeneration,
                "worldVersion:", runtime.WorldVersion, "refreshBlocked:", tostring(runtime.RefreshBlocked),
                "carryRoot:", tostring(runtime.CarryRootId), "target:", tostring(runtime.TargetToken and runtime.TargetToken.rootId),
                "targetOperation:", tostring(runtime.TargetToken and runtime.TargetToken.operation), "holding:", tostring(runtime.Holding),
                "awaiting:", tostring(runtime.AwaitingResult), "cachedState:", tostring(model and model.state),
                "cachedOperation:", tostring(model and model.operation), "cachedGeneration:", tostring(model and model.generation),
                "cachedPlayerId:", tostring(model and model.playerId))
            if inspectWidget then
                for _, id in ipairs({ config.PickupUiGroupId, config.PickupButtonId, config.PickupProgressId }) do
                    local ok, state = pcall(function() return UI:GetWidgetState(id) end)
                    Log:PrintLog("[PickupDiag][C] widget", "id:", id, "readOK:", tostring(ok),
                        "IsShow:", tostring(ok and type(state) == "table" and state.IsShow),
                        "IsVisible:", tostring(ok and type(state) == "table" and state.IsVisible))
                end
            end
        end)
    end
    -- PICKUP_DIAG_END

    -- DYNAMIC_DIAG_BEGIN
    runtime.DynamicChickenDiagnostic = { generation = -1, roots = {} }
    local function ProbeDynamicWorldRoots(message)
        pcall(function()
            local diagnostic = runtime.DynamicChickenDiagnostic
            if diagnostic.generation ~= message.generation then
                diagnostic.generation, diagnostic.roots = message.generation, {}
            end
            for _, model in ipairs(message.models) do
                if not diagnostic.roots[model.rootId] then
                    diagnostic.roots[model.rootId] = true -- 失败也已采样，不重试。
                    pcall(function()
                        local playerOK, playerId = pcall(function() return Character:GetLocalPlayerId() end)
                        local positionOK, position = pcall(function()
                            local value = model.position
                            return value and (tostring(value.X) .. "," .. tostring(value.Y) .. "," .. tostring(value.Z)) or "nil"
                        end)
                        local collisionOK, collision = pcall(function() return Element:IsOpenCollision(model.rootId) end)
                        Log:PrintLog("[DynamicChickenDiag][C] first_root", "localPlayerOK:", playerOK,
                            "localPlayerId:", tostring(playerId), "serverRoot:", model.rootId,
                            "generation:", message.generation, "state:", model.state, "operation:", model.operation,
                            "positionOK:", positionOK, "positionSource:", "world_snapshot_cache", "position:", tostring(position),
                            "collisionOK:", collisionOK, "collision:", tostring(collision))
                    end)
                end
            end
        end)
    end
    -- DYNAMIC_DIAG_END

    local function StopProgressTimer()
        local timerId = runtime.ProgressTimerId
        runtime.ProgressTimerId = nil
        if timerId then context.Timers:Remove(timerId) end
    end

    local function ResetProgress()
        StopProgressTimer()
        runtime.Holding = false
        runtime.HoldStartTime = nil
        UI:SetProgressCurrentValue({ config.PickupProgressId }, 0)
    end

    local function Current(token)
        return token ~= nil and context.Services.PickupController == runtime
            and runtime.TargetToken == token and runtime.Generation == token.generation
    end

    -- 指示诊断只读；失败逐项隔离，同一目标/显隐状态不重采样。
    local indicatorDiagnostic = { stateKey = nil, disabledReason = nil }
    local function IndicatorLog(stage, ...)
        local args = { ... }
        pcall(function()
            local playerOK, playerId = pcall(function() return Character:GetLocalPlayerId() end)
            local unpackArgs = table.unpack or unpack
            Log:PrintLog("[PickupIndicatorDiag][C]", stage, "localPlayerOK:", playerOK,
                "localPlayerId:", tostring(playerId), "source:", config.PickupIndicatorSourceId,
                unpackArgs(args))
        end)
    end
    local function DiagnosticRead(callback, vector)
        local ok, value = pcall(function()
            local result = callback()
            if vector and result then return tostring(result.X) .. "," .. tostring(result.Y) .. "," .. tostring(result.Z) end
            return tostring(result)
        end)
        return ok, value
    end
    local function IndicatorState(position)
        pcall(function()
            local token = runtime.TargetToken
            local model = token and runtime.WorldModels[token.rootId]
            local cached = model and model.position
            local reason = runtime.IndicatorDisabled and "disabled"
                or not runtime.IndicatorRoot and "not_ready"
                or not runtime.InStolenArea and "home"
                or runtime.CarryRootId and "carrying"
                or runtime.AwaitingResult and "awaiting_result"
                or runtime.RefreshBlocked and "refresh"
                or not position and "no_target" or "target"
            local key = table.concat({ tostring(token and token.rootId), tostring(token and token.generation),
                tostring(token and token.operation), tostring(runtime.IndicatorRoot), tostring(runtime.IndicatorVisible),
                reason, tostring(indicatorDiagnostic.disabledReason) }, "/")
            if indicatorDiagnostic.stateKey == key then return end
            indicatorDiagnostic.stateKey = key -- 读取/打印失败也不重试。
            local positionOK, targetPosition = DiagnosticRead(function() return cached end, true)
            IndicatorLog("state", "chickenRoot:", tostring(token and token.rootId),
                "generation:", tostring(token and token.generation), "operation:", tostring(token and token.operation),
                "cachedPositionOK:", positionOK, "cachedPosition:", targetPosition,
                "indicatorRoot:", tostring(runtime.IndicatorRoot), "visible:", runtime.IndicatorVisible,
                "reason:", reason, "disabledReason:", tostring(indicatorDiagnostic.disabledReason))
            local visited = {}
            local function Sample(rootId, parentId)
                if visited[rootId] then return end
                visited[rootId] = true
                local positionOK, actualPosition = DiagnosticRead(function() return Element:GetPosition(rootId) end, true)
                local scaleOK, scale = DiagnosticRead(function() return Element:GetScale(rootId) end, true)
                local visibleOK, visible = DiagnosticRead(function() return Element:IsVisible(rootId) end)
                IndicatorLog("sample", "indicatorRoot:", runtime.IndicatorRoot, "elementId:", rootId,
                    "parentId:", tostring(parentId), "positionOK:", positionOK, "actualPosition:", actualPosition,
                    "scaleOK:", scaleOK, "scale:", scale, "visibleOK:", visibleOK, "IsVisible:", visible)
                local childrenOK, children = pcall(function() return Element:GetChildElementsFromElement(rootId) end)
                pcall(function() IndicatorLog("children", "elementId:", rootId, "childrenOK:", childrenOK,
                    "childrenType:", type(children), "readError:", not childrenOK and tostring(children) or "nil") end)
                if childrenOK and type(children) == "table" then
                    for _, childId in ipairs(children) do
                        pcall(function()
                            IndicatorLog("edge", "parentId:", rootId, "childId:", childId,
                                "alreadyVisited:", visited[childId] == true)
                            if IsPositiveInteger(childId) then Sample(childId, rootId) end
                        end)
                    end
                end
            end
            if runtime.IndicatorRoot then Sample(runtime.IndicatorRoot, nil) end
        end)
    end

    local function DestroyIndicator(rootId)
        if rootId then
            IndicatorLog("destroy_begin", "indicatorRoot:", rootId)
            local ok, result = pcall(function() return context.ElementCopy:DestroyTree(rootId) end)
            pcall(function() IndicatorLog("destroy_result", "indicatorRoot:", rootId, "ok:", ok, "result:", tostring(result)) end)
        end
    end

    local function DisableIndicator(reason)
        pcall(function() indicatorDiagnostic.disabledReason = tostring(reason) end)
        pcall(function() IndicatorLog("disabled", "indicatorRoot:", tostring(runtime.IndicatorRoot), "reason:", tostring(reason)) end)
        runtime.IndicatorDisabled = true
        local rootId = runtime.IndicatorRoot
        runtime.IndicatorRoot, runtime.IndicatorPosition, runtime.IndicatorVisible = nil, nil, false
        DestroyIndicator(rootId)
        pcall(function() Log:PrintError("[PickupController] 目标指示停用，不重试", tostring(reason)) end)
    end

    local function RenderIndicator(position)
        if runtime.IndicatorDisabled or not runtime.IndicatorRoot then IndicatorState(position) return end
        local rootId = runtime.IndicatorRoot
        local ok, reason = pcall(function()
            local visible = position ~= nil and runtime.InStolenArea and not runtime.CarryRootId
                and not runtime.AwaitingResult and not runtime.RefreshBlocked
            if visible then
                local prior = runtime.IndicatorPosition
                if not prior or prior.X ~= position.X or prior.Y ~= position.Y or prior.Z ~= position.Z then
                    Element:SetPosition(rootId, Engine.Vector(position.X, position.Y, position.Z), Element.COORDINATE.World)
                    runtime.IndicatorPosition = { X = position.X, Y = position.Y, Z = position.Z }
                end
            end
            if runtime.IndicatorVisible ~= visible then
                Element:SetVisibility(rootId, visible)
                runtime.IndicatorVisible = visible
            end
        end)
        if not ok then DisableIndicator(reason) end
        IndicatorState(position)
    end
    runtime.CleanupIndicator = function()
        IndicatorLog("stop_cleanup", "indicatorRoot:", runtime.IndicatorRoot or "nil")
        runtime.IndicatorDisabled = true
        local rootId = runtime.IndicatorRoot
        runtime.IndicatorRoot = nil
        DestroyIndicator(rootId)
    end

    local function CreateIndicator()
        IndicatorLog("copy_begin", "indicatorRoot:", runtime.IndicatorRoot or "nil")
        local ok, reason = pcall(function()
            context.ElementCopy:CopyTree(config.PickupIndicatorSourceId, Engine.Vector(0, 0, -5000), "拾取目标指示", function(result)
                pcall(function() IndicatorLog("copy_result", "success:", result.success, "actualRoot:", tostring(result.rootId),
                    "reason:", tostring(result.reason), "currentRuntime:", context.Services.PickupController == runtime,
                    "disabled:", runtime.IndicatorDisabled) end)
                if context.Services.PickupController ~= runtime or runtime.IndicatorDisabled or not result.success then
                    if result.success then
                        IndicatorLog("late_copy_cleanup", "indicatorRoot:", result.rootId)
                        DestroyIndicator(result.rootId)
                    else
                        for i = #(result.spawnedIds or {}), 1, -1 do
                            local id = result.spawnedIds[i]
                            if id ~= config.PickupIndicatorSourceId then
                                IndicatorLog("partial_copy_cleanup", "elementId:", id)
                                pcall(function() Element:Destroy(id) end)
                            end
                        end
                    end
                    if context.Services.PickupController == runtime and not result.success then DisableIndicator(result.reason) end
                    return
                end
                runtime.IndicatorRoot = result.rootId
                local hidden, errorMessage = pcall(function() Element:SetVisibility(result.rootId, false) end)
                if not hidden then DisableIndicator(errorMessage) end
                IndicatorState(nil)
            end)
        end)
        if not ok then DisableIndicator(reason) end
    end

    local function StartProgressTimer(token, started)
        local timerId
        timerId = context.Timers:AddLoopTimer(
            PickupController.Name,
            config.ProgressTickSeconds,
            function()
                if runtime.ProgressTimerId ~= timerId or not Current(token) or not runtime.Holding
                    or runtime.HoldStartTime ~= started or runtime.AwaitingResult then return end
                local rootId = token.rootId
                local elapsedSeconds = TimerManager:GetTimeSeconds() - started
                if runtime.ProgressTimerId ~= timerId or not Current(token)
                    or not runtime.Holding or runtime.HoldStartTime ~= started then return end
                local progress = math.max(0, math.min(100, elapsedSeconds / config.HoldSeconds * 100))
                UI:SetProgressCurrentValue({ config.PickupProgressId }, progress)
                if runtime.ProgressTimerId ~= timerId or not Current(token)
                    or not runtime.Holding or runtime.HoldStartTime ~= started then return end
                if elapsedSeconds >= config.HoldSeconds then
                    StopProgressTimer()
                    runtime.Holding = false
                    runtime.HoldStartTime = nil
                    runtime.AwaitingResult = true
                    RenderIndicator(nil)
                    if not Current(token) then return end
                    System:SendToServer(context.NetMsg.Messages.PickupComplete, {
                        elementId = rootId,
                        generation = token.generation,
                        operation = token.operation,
                    })
                    Log:PrintLog("[PickupController] 按住时间已满，发送正式完成请求",
                        "elementId:", rootId,
                        "elapsedSeconds:", elapsedSeconds)
                end
            end
        )
        runtime.ProgressTimerId = timerId
    end

    local function HideInteraction(token)
        PickupDiagnostic("hide_enter", token, token and not Current(token) and "stale_token" or "hide") -- PICKUP_DIAG
        if token and not Current(token) then return end
        StopProgressTimer()
        runtime.TargetToken = nil
        runtime.AwaitingResult = false
        runtime.Holding, runtime.HoldStartTime = false, nil
        RenderIndicator(nil)
        UI:SetProgressCurrentValue({ config.PickupProgressId }, 0)
        if not runtime.TargetToken then UI:OnShow({ config.PickupUiGroupId }, false) end
        PickupDiagnostic("hide_return", token, "hidden_or_reentered", true) -- PICKUP_DIAG
    end

    local function SendCancel(token, reason)
        System:SendToServer(context.NetMsg.Messages.PickupCancel, {
            elementId = token.rootId, generation = token.generation,
            operation = token.operation, reason = reason,
        })
    end

    local function CancelInteraction(token, reason)
        PickupDiagnostic("cancel", token, reason) -- PICKUP_DIAG
        if not Current(token) then return end
        HideInteraction(token) -- 先失效；发送同步重入时不再关闭新目标。
        if runtime.TargetToken or context.Services.PickupController ~= runtime then return end
        SendCancel(token, reason)
    end

    local function ModelAllows(token, model)
        if not model or model.generation ~= token.generation then return false end
        if model.state == "Available" then return model.operation == token.operation end
        return model.state == "PendingBind" and runtime.AwaitingResult
            and model.playerId == Character:GetLocalPlayerId() and model.operation == token.operation + 1
    end

    local function CancelBreak()
        local token = runtime.BreakToken
        if not token then return end
        runtime.BreakToken = nil
        System:SendToServer(context.NetMsg.Messages.EggBreakCancel, {
            elementId = token.rootId, operation = token.operation, generation = token.generation, requestId = token.requestId })
    end
    runtime.CleanupEggAttack = function()
        CancelBreak()
    end
    runtime.EggBreakResultCallback = function(_, message)
        Run("处理破蛋结果", function()
            local token = runtime.BreakToken
            if not token or type(message) ~= "table" or message.requestId ~= token.requestId
                or message.elementId ~= token.rootId or message.generation ~= token.generation
                or message.operation ~= token.operation then return end
            if not message.success then
                runtime.BreakDenied[token.rootId] = runtime.WorldModels[token.rootId]
                runtime.BreakToken = nil
            end
        end)
    end

    runtime.ModelStateCallback = function(_, message)
        Run("处理世界鸡拾取状态", function()
            if type(message) ~= "table" or message.source ~= "world" or type(message.version) ~= "number"
                or message.version ~= math.floor(message.version) or message.version <= runtime.WorldVersion
                or type(message.generation) ~= "number" or message.generation < runtime.Generation
                or message.generation < runtime.WorldGeneration or type(message.models) ~= "table" then return end
            local models, byRegion, dropped, generation = {}, {}, {}, message.generation
            for _, model in ipairs(message.models) do
                if type(model) ~= "table" or not IsPositiveInteger(model.rootId)
                    or model.generation ~= generation or type(model.operation) ~= "number"
                    or type(model.state) ~= "string" or not IsPositiveInteger(model.regionId)
                    or type(model.isDropped) ~= "boolean" or type(model.position) ~= "table"
                    or not IsFinitePosition(model.position) or models[model.rootId] then return end
                models[model.rootId] = { generation = model.generation, operation = model.operation,
                    state = model.state, playerId = model.playerId, regionId = model.regionId,
                    eggRootId = model.eggRootId, eggTypeId = model.eggTypeId, attackPlayerId = model.attackPlayerId,
                    isDropped = model.isDropped, position = { X = model.position.X, Y = model.position.Y, Z = model.position.Z } }
                if model.state == "Available" or model.state == "Egg" or model.state == "EggAttacking" then
                    if model.isDropped then dropped[model.rootId] = models[model.rootId]
                    else
                        local region = byRegion[model.regionId] or {}
                        region[model.rootId] = models[model.rootId]
                        byRegion[model.regionId] = region
                    end
                end
            end
            if generation < runtime.Generation then return end
            runtime.WorldVersion, runtime.WorldGeneration, runtime.WorldModels = message.version, generation, models
            runtime.AvailableByRegion, runtime.DroppedModels = byRegion, dropped
            for rootId in pairs(runtime.BreakDenied) do
                if not models[rootId] then runtime.BreakDenied[rootId] = nil end
            end
            local breaking = runtime.BreakToken
            if breaking then
                local model = models[breaking.rootId]
                if not model or model.generation ~= breaking.generation or model.operation ~= breaking.operation
                    or (model.state ~= "Egg" and model.state ~= "EggAttacking")
                    or (model.state == "EggAttacking" and model.attackPlayerId ~= Character:GetLocalPlayerId()) then
                    CancelBreak()
                end
            end
            ProbeDynamicWorldRoots(message) -- DYNAMIC_DIAG
            local token = runtime.TargetToken
            if token and not ModelAllows(token, models[token.rootId]) and Current(token) then
                CancelInteraction(token, "target_not_available")
            end
        end)
    end

    local function SelectTarget(rootId, model)
        local old = runtime.TargetToken
        if old and old.rootId == rootId and old.operation == model.operation and old.generation == model.generation then return end
        if old then CancelInteraction(old, "target_not_available") end
        if context.Services.PickupController ~= runtime or runtime.TargetToken or not runtime.InStolenArea
            or runtime.CarryRootId or runtime.AwaitingResult or runtime.RefreshBlocked
            or runtime.WorldModels[rootId] ~= model then return end
        runtime.Generation = model.generation
        local token = { rootId = rootId, operation = model.operation, generation = model.generation }
        runtime.TargetToken = token
        UI:SetProgressMaxValue({ config.PickupProgressId }, 100)
        if Current(token) then UI:OnShow({ config.PickupUiGroupId }, true) end
    end

    local function ScanTargets(eggsOnly)
        if context.Services.PickupController ~= runtime then return end
        if eggsOnly and (not runtime.CarryReady or not runtime.InStolenArea or runtime.CarryRootId
            or runtime.RefreshBlocked or runtime.BreakToken or runtime.Holding or runtime.AwaitingResult) then return end
        if not runtime.CarryReady or not runtime.InStolenArea or runtime.CarryRootId or runtime.RefreshBlocked then
            CancelBreak()
            if runtime.TargetToken then CancelInteraction(runtime.TargetToken, "not_in_stolen_area") end
            RenderIndicator(nil)
            return
        end
        local token, generation, version = runtime.TargetToken, runtime.WorldGeneration, runtime.WorldVersion
        local ok, playerPosition = pcall(function() return Character:GetPosition(Character:GetLocalPlayerId()) end)
        if context.Services.PickupController ~= runtime or runtime.TargetToken ~= token
            or generation ~= runtime.WorldGeneration or version ~= runtime.WorldVersion then return end
        if not ok or not playerPosition then
            if eggsOnly then return end
            CancelBreak()
            if token then CancelInteraction(token, "position_unavailable") end
            RenderIndicator(nil)
            return
        end
        local maxDistanceSquared = config.MaxHorizontalDistance * config.MaxHorizontalDistance
        local breaking = runtime.BreakToken
        if breaking then
            local model = runtime.WorldModels[breaking.rootId]
            if not model or model.generation ~= breaking.generation or model.operation ~= breaking.operation
                or (model.state ~= "Egg" and model.state ~= "EggAttacking")
                or PickupDistanceSquared(playerPosition, model.position) > maxDistanceSquared then
                CancelBreak()
            else
                RenderIndicator(nil)
                return
            end
        end
        if token and (runtime.Holding or runtime.AwaitingResult) then
            local model = runtime.WorldModels[token.rootId]
            local position = model and model.position
            if not ModelAllows(token, model) then CancelInteraction(token, "target_not_available")
            elseif not position then CancelInteraction(token, "position_unavailable")
            elseif PickupDistanceSquared(playerPosition, position) > maxDistanceSquared then CancelInteraction(token, "distance_exceeded")
            elseif runtime.AwaitingResult then RenderIndicator(nil)
            else RenderIndicator(position) end
            return
        end
        if runtime.AwaitingResult then RenderIndicator(nil) return end
        local nearestDistance, nearestRoot, nearestModel, nearestPosition
        local function Consider(rootId, model)
            if eggsOnly and model.state ~= "Egg" then return end
            local distance = PickupDistanceSquared(playerPosition, model.position)
            if distance > maxDistanceSquared then runtime.BreakDenied[rootId] = nil; return end
            if model.state == "EggAttacking" or (not eggsOnly and runtime.BreakDenied[rootId] == model) then return end
            if distance <= maxDistanceSquared and (not nearestDistance or distance < nearestDistance
                or distance == nearestDistance and rootId < nearestRoot) then
                nearestDistance, nearestRoot, nearestModel, nearestPosition = distance, rootId, model, model.position
            end
        end
        -- 两个索引在合法完整快照到达时重建；普通鸡与掉落鸡按根身份互斥。
        for rootId, model in pairs(runtime.AvailableByRegion[runtime.RegionId] or {}) do Consider(rootId, model) end
        if not eggsOnly then
            for rootId, model in pairs(runtime.DroppedModels) do Consider(rootId, model) end
        end
        if context.Services.PickupController ~= runtime or runtime.TargetToken ~= token
            or generation ~= runtime.WorldGeneration or version ~= runtime.WorldVersion
            or not runtime.InStolenArea or runtime.CarryRootId or runtime.AwaitingResult or runtime.RefreshBlocked then return end
        if not nearestRoot then
            if eggsOnly then return end
            if token then CancelInteraction(token, "target_not_available") end
            RenderIndicator(nil)
            return
        end
        if nearestModel.state == "Egg" then
            if token then CancelInteraction(token, "target_not_available") end
            runtime.BreakRequestId = runtime.BreakRequestId + 1
            local request = { rootId = nearestRoot, operation = nearestModel.operation,
                generation = nearestModel.generation, requestId = runtime.BreakRequestId }
            runtime.BreakToken = request
            RenderIndicator(nil)
            System:SendToServer(context.NetMsg.Messages.EggBreakBegin, {
                elementId = request.rootId, operation = request.operation, generation = request.generation, requestId = request.requestId })
            return
        end
        SelectTarget(nearestRoot, nearestModel)
        if runtime.TargetToken and runtime.TargetToken.rootId == nearestRoot then RenderIndicator(nearestPosition) end
    end

    runtime.EggBreakScanCallback = function()
        Run("尖叫鸭开蛋扫描", function() ScanTargets(true) end)
    end

    runtime.ZoneCallback = function(_, message)
        Run("处理拾取区域状态", function()
            if type(message) ~= "table" or type(message.inStolenArea) ~= "boolean"
                or type(message.regionId) ~= "number" or message.regionId < 0
                or message.regionId ~= math.floor(message.regionId) then return end
            runtime.InStolenArea = message.inStolenArea
            runtime.RegionId = message.regionId
            if not runtime.InStolenArea then
                CancelBreak()
                if runtime.TargetToken then CancelInteraction(runtime.TargetToken, "not_in_stolen_area") end
                RenderIndicator(nil)
            end
        end)
    end

    runtime.ResultCallback = function(_, message)
        Run("处理拾取结果", function()
            if type(message) ~= "table" or type(message.success) ~= "boolean" then
                return
            end
            local rootId = message.elementId
            if message.generation ~= runtime.Generation or message.generation < runtime.WorldGeneration then return end
            if message.carryRetained then
                if rootId ~= runtime.CarryRootId or message.operation ~= runtime.CarryOperation then return end
                if message.reason == "inventory_capacity_full" then
                    context.Services.PromptController:Show("鸡库存已满，请先出售或放置")
                end
                return
            end
            local token = runtime.TargetToken
            if not Current(token) or rootId ~= token.rootId then return end
            if not message.success and message.requestOperation ~= token.operation then return end
            if message.success and message.operation ~= token.operation + 1 then return end
            if message.reason == "inventory_capacity_full" then context.Services.PromptController:Show("鸡库存已满，请先出售或放置") end
            HideInteraction(token)
            Log:PrintLog("[PickupController] 收到正式拾取结果",
                "success:", tostring(message.success),
                "elementId:", tostring(rootId),
                "reason:", tostring(message.reason))
        end)
    end

    runtime.PressedCallback = function()
        Run("拾取按钮按下", function()
            local token = runtime.TargetToken
            if not Current(token) or runtime.Holding or runtime.AwaitingResult then return end
            local rootId, started = token.rootId, TimerManager:GetTimeSeconds()
            if not Current(token) then return end
            runtime.Holding, runtime.HoldStartTime = true, started
            UI:SetProgressCurrentValue({ config.PickupProgressId }, 0)
            if not Current(token) or not runtime.Holding then return end
            System:SendToServer(context.NetMsg.Messages.PickupBegin, {
                elementId = rootId, generation = token.generation, operation = token.operation,
            })
            if Current(token) and runtime.Holding and runtime.HoldStartTime == started
                and not runtime.AwaitingResult and not runtime.ProgressTimerId then StartProgressTimer(token, started) end
            Log:PrintLog("[PickupController] 开始按住正式拾取",
                "elementId:", rootId)
        end)
    end

    local function RenderCarry()
        if context.Services.PickupController ~= runtime or not runtime.CarryReady then return end
        UI:OnShow({ config.CarryUiGroupId }, runtime.CarryRootId ~= nil
            and not runtime.RefreshBlocked and not runtime.DropPending)
    end

    runtime.CarryStateCallback = function(_, message)
        Run("处理偷鸡携带快照", function()
            if type(message) ~= "table" or type(message.version) ~= "number"
                or message.version <= runtime.CarryVersion or message.version ~= math.floor(message.version)
                or type(message.generation) ~= "number" or message.generation < runtime.Generation
                or message.generation < runtime.WorldGeneration or type(message.carrying) ~= "boolean" then return end
            if message.carrying and (not IsPositiveInteger(message.elementId)
                or not IsPositiveInteger(message.operation)) then return end
            if message.generation > runtime.Generation then HideInteraction() end
            runtime.Generation = message.generation
            runtime.CarryVersion = message.version
            runtime.CarryRootId = message.carrying and message.elementId or nil
            runtime.CarryOperation = message.carrying and message.operation or nil
            runtime.DropPending = false
            if runtime.CarryRootId then HideInteraction() end
            RenderCarry()
        end)
    end

    runtime.DropCallback = function()
        Run("主动放下按钮", function()
            if not runtime.CarryReady or not runtime.CarryRootId
                or runtime.RefreshBlocked or runtime.DropPending then return end
            runtime.DropPending = true
            RenderCarry()
            System:SendToServer(context.NetMsg.Messages.TheftManualDrop, {
                elementId = runtime.CarryRootId,
                operation = runtime.CarryOperation,
                generation = runtime.Generation,
            })
        end)
    end

    runtime.ReleasedCallback = function()
        Run("拾取按钮松开", function()
            if not runtime.Holding then return end
            local token = runtime.TargetToken
            if not Current(token) then return end
            local rootId = token.rootId
            ResetProgress()
            if not Current(token) then return end
            SendCancel(token, "button_released")
            Log:PrintLog("[PickupController] 按钮松开，进度归零",
                "elementId:", tostring(rootId))
        end)
    end

    context.Events:Subscribe(PickupController.Name, "RefreshPhaseChanged", function(snapshot)
        if context.Services.PickupController ~= runtime then return end
        if snapshot.generation < runtime.Generation then return end
        local changed = snapshot.generation > runtime.Generation
        runtime.Generation = snapshot.generation
        runtime.RefreshBlocked = snapshot.phase == "Countdown" or snapshot.phase == "Clearing"
        if changed or runtime.RefreshBlocked then CancelBreak(); HideInteraction() end
        if changed or runtime.RefreshBlocked then
            runtime.CarryRootId = nil
            runtime.CarryOperation = nil
            runtime.DropPending = false
        end
        RenderCarry()
    end)

    UI:SetProgressMaxValue({ config.PickupProgressId }, 100)
    UI:SetProgressCurrentValue({ config.PickupProgressId }, 0)
    UI:OnShow({ config.PickupUiGroupId }, false)
    System:BindNotify(context.NetMsg.Messages.ChickenModelState, runtime.ModelStateCallback)
    System:BindNotify(context.NetMsg.Messages.EggBreakResult, runtime.EggBreakResultCallback)
    System:BindNotify(context.NetMsg.Messages.EggBreakScan, runtime.EggBreakScanCallback)
    System:BindNotify(context.NetMsg.Messages.ZoneState, runtime.ZoneCallback)
    System:BindNotify(context.NetMsg.Messages.PickupResult, runtime.ResultCallback)
    System:BindNotify(context.NetMsg.Messages.TheftCarryState, runtime.CarryStateCallback)
    UI:RegisterPressed(config.PickupButtonId, runtime.PressedCallback)
    UI:RegisterReleased(config.PickupButtonId, runtime.ReleasedCallback)
    context.Timers:AddTimer(PickupController.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if context.Services.PickupController ~= runtime then return end
        CreateIndicator()
        runtime.CarryReady = true
        UI:RegisterClicked(config.ManualDropButtonId, runtime.DropCallback)
        runtime.DropRegistered = true
        RenderCarry()
        System:SendToServer(context.NetMsg.Messages.TheftCarrySnapshotRequest, {})
    end)

    runtime.ScanTimerId = context.Timers:AddLoopTimer(PickupController.Name, config.DistanceCheckSeconds, function()
        Run("范围拾取扫描", ScanTargets)
    end)


    Log:PrintLog("[PickupController] 正式拾取客户端已启动",
        "holdSeconds:", config.HoldSeconds,
        "tickSeconds:", config.ProgressTickSeconds,
        "maxHorizontalDistance:", config.MaxHorizontalDistance)
end

function PickupController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.PickupController
    if not runtime then return end
    runtime.CleanupEggAttack()
    System:UnbindNotify(context.NetMsg.Messages.EggBreakResult, runtime.EggBreakResultCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggBreakScan, runtime.EggBreakScanCallback)
    context.Services.PickupController = nil
    runtime.DynamicChickenDiagnostic = nil -- DYNAMIC_DIAG
    runtime.TargetToken = nil
    runtime.Holding = false
    runtime.HoldStartTime = nil
    runtime.CarryReady = false
    if runtime.ScanTimerId then context.Timers:Remove(runtime.ScanTimerId); runtime.ScanTimerId = nil end
    runtime.CleanupIndicator()
    if runtime.ProgressTimerId then
        local timerId = runtime.ProgressTimerId
        runtime.ProgressTimerId = nil
        context.Timers:Remove(timerId)
    end
    if runtime.PressedCallback then
        UI:UnRegisterPressed(GameConfig.Theft.PickupButtonId, runtime.PressedCallback)
    end
    if runtime.ReleasedCallback then
        UI:UnRegisterReleased(GameConfig.Theft.PickupButtonId, runtime.ReleasedCallback)
    end
    if runtime.ModelStateCallback then
        System:UnbindNotify(context.NetMsg.Messages.ChickenModelState, runtime.ModelStateCallback)
    end
    if runtime.ZoneCallback then
        System:UnbindNotify(context.NetMsg.Messages.ZoneState, runtime.ZoneCallback)
    end
    if runtime.ResultCallback then
        System:UnbindNotify(context.NetMsg.Messages.PickupResult, runtime.ResultCallback)
    end
    if runtime.CarryStateCallback then
        System:UnbindNotify(context.NetMsg.Messages.TheftCarryState, runtime.CarryStateCallback)
    end
    if runtime.DropRegistered then
        UI:UnRegisterClicked(GameConfig.Theft.ManualDropButtonId, runtime.DropCallback)
    end
    UI:SetProgressCurrentValue({ GameConfig.Theft.PickupProgressId }, 0)
    UI:OnShow({ GameConfig.Theft.PickupUiGroupId }, false)
    UI:OnShow({ GameConfig.Theft.CarryUiGroupId }, false)
end

return PickupController
