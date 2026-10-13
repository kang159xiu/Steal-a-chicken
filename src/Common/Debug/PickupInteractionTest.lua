-- 临时测试：把鸡父元件树复制到生成点，碰撞复制鸡并按住一秒后附加到玩家 Root 上方。
local PickupInteractionTest = {
    Name = "PickupInteractionTest",
    FeatureFlag = "PickupInteractionTest",
    Dependencies = {},
}

local PURPOSE_PROPERTY_NAME = "作用"
local SPAWN_POINT_PURPOSE_VALUE = "生成鸡的点"
local CHICKEN_ROOT_PURPOSE_VALUE = "鸡父元件"
local CHICKEN_SOURCE_ROOT_ID = 411
local TEST_SPAWN_POINT_ID = 325
local COPY_DEBUG_NAME = "动态拾取测试鸡411"

local PICKUP_BUTTON_UI_ID = 100397
local PICKUP_GROUP_UI_ID = 100398
local PICKUP_PROGRESS_UI_ID = 100399

local CHECK_INTERVAL_SECONDS = 0.2
local MAX_HORIZONTAL_DISTANCE = 300
local REQUIRED_HOLD_SECONDS = 1
local REQUIRED_PROGRESS_STEPS = 5
local HEIGHT_OFFSET = 150
local BIND_DELAY_FRAMES = 2
local VERIFY_DELAY_FRAMES = 1

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function RunProtectedCallback(context, callbackName, callback)
    local ok, errorMessage = xpcall(callback, Traceback)
    if not ok then
        context.Manager:FailModule(
            PickupInteractionTest.Name,
            callbackName .. ": " .. tostring(errorMessage)
        )
    end
end

local function CopyPosition(position)
    return Engine.Vector(position.X, position.Y, position.Z)
end

local function FormatPosition(position)
    if not position then
        return "nil"
    end
    return string.format("(%.3f, %.3f, %.3f)", position.X, position.Y, position.Z)
end

local function HorizontalDistance(first, second)
    local deltaX = first.X - second.X
    local deltaY = first.Y - second.Y
    return math.sqrt(deltaX * deltaX + deltaY * deltaY)
end

local function CollectTreeIds(rootId)
    local ids = {}
    local visited = {}

    local function Visit(elementId)
        if visited[elementId] then
            error("复制鸡树存在重复或循环节点，elementId=" .. tostring(elementId))
        end
        visited[elementId] = true
        ids[#ids + 1] = elementId
        local childIds = Element:GetChildElementsFromElement(elementId) or {}
        for _, childId in ipairs(childIds) do
            Visit(childId)
        end
    end

    Visit(rootId)
    return ids
end

local function FormatIds(ids)
    local values = {}
    for _, elementId in ipairs(ids or {}) do
        values[#values + 1] = tostring(elementId)
    end
    return "[" .. table.concat(values, ",") .. "]"
end

local function ReadPurposeProperty(elementId)
    local ok, value = pcall(function()
        return CustomProperty:GetCustomProperty(
            elementId,
            PURPOSE_PROPERTY_NAME,
            CustomProperty.PROPERTY_TYPE.String
        )
    end)
    return ok, value
end

local function SendResult(runtime, playerId, elementId, success, reason)
    System:SendToClient(
        playerId,
        runtime.NetMsg.PickupTestResult,
        {
            elementId = elementId,
            success = success,
            reason = reason,
        }
    )
end

local function ResetClientInteraction(runtime, hideGroup)
    runtime.TargetElementId = nil
    runtime.Holding = false
    runtime.AwaitingResult = false
    runtime.ElapsedSeconds = 0
    runtime.ProgressStep = 0
    runtime.HoldStartTime = nil
    UI:SetProgressCurrentValue({ PICKUP_PROGRESS_UI_ID }, 0)
    if hideGroup then
        UI:OnShow({ PICKUP_GROUP_UI_ID }, false)
    end
end

local function CancelClientInteraction(runtime, reason, notifyServer)
    local elementId = runtime.TargetElementId
    ResetClientInteraction(runtime, true)
    if notifyServer and elementId then
        System:SendToServer(
            runtime.NetMsg.PickupTestCancel,
            { elementId = elementId }
        )
    end
    Log:PrintLog("[PickupInteractionTest] 客户端取消拾取",
        "reason:", reason,
        "elementId:", tostring(elementId))
end

local function StartServer(context)
    local runtime = {
        NetMsg = context.NetMsg.Messages,
        TouchedByPlayer = {},
        CarriedByPlayer = {},
        ElementCarrier = {},
        PendingByPlayer = {},
        PendingElementCarrier = {},
        SpawnedChickenRootId = nil,
        SpawnedChickenIds = {},
        SpawnedChickenDestroyed = false,
        TouchCallback = nil,
        CompleteCallback = nil,
        CancelCallback = nil,
    }
    context.Services.PickupInteractionTest = runtime

    runtime.TouchCallback = function(elementId, playerId)
        local ok, errorMessage = xpcall(function()
            local readSuccess, propertyValue = ReadPurposeProperty(elementId)
            local isSpawnedChickenRoot = elementId == runtime.SpawnedChickenRootId
            local propertyMatches = readSuccess and propertyValue == CHICKEN_ROOT_PURPOSE_VALUE
            Log:PrintServerLog("[PickupInteractionTest] 玩家碰撞元件",
                "elementId:", tostring(elementId),
                "elementType:", type(elementId),
                "playerId:", tostring(playerId),
                "playerType:", type(playerId),
                "spawnedChickenRootId:", tostring(runtime.SpawnedChickenRootId),
                "isSpawnedChickenRoot:", tostring(isSpawnedChickenRoot),
                "propertyName:", PURPOSE_PROPERTY_NAME,
                "propertyType:", "String",
                "readSuccess:", tostring(readSuccess),
                "propertyValue:", tostring(propertyValue),
                "propertyMatches:", tostring(propertyMatches))

            if not isSpawnedChickenRoot or not propertyMatches then
                return
            end
            if runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId] then
                Log:PrintServerLog("[PickupInteractionTest] 玩家已有携带或附加中的元件，不显示拾取UI",
                    "playerId:", playerId,
                    "carriedElementId:", tostring(runtime.CarriedByPlayer[playerId]),
                    "pendingElementId:", tostring(runtime.PendingByPlayer[playerId]),
                    "touchedElementId:", elementId)
                return
            end
            if runtime.ElementCarrier[elementId] or runtime.PendingElementCarrier[elementId] then
                Log:PrintServerLog("[PickupInteractionTest] 元件已由其他玩家携带或正在附加，不显示拾取UI",
                    "playerId:", playerId,
                    "elementId:", elementId,
                    "carrierPlayerId:", tostring(runtime.ElementCarrier[elementId]),
                    "pendingPlayerId:", tostring(runtime.PendingElementCarrier[elementId]))
                return
            end

            local elementPosition = Element:GetPosition(elementId)
            if not elementPosition then
                error("无法读取碰撞元件位置，elementId=" .. tostring(elementId))
            end

            runtime.TouchedByPlayer[playerId] = elementId
            System:SendToClient(
                playerId,
                runtime.NetMsg.PickupTestShow,
                { elementId = elementId }
            )
            Log:PrintServerLog("[PickupInteractionTest] 复制鸡根ID和属性均匹配，已通知客户端显示拾取UI",
                "playerId:", playerId,
                "elementId:", elementId,
                "elementPosition:", FormatPosition(elementPosition))
        end, Traceback)
        if not ok then
            context.Manager:FailModule(PickupInteractionTest.Name,
                "碰撞事件处理失败: " .. tostring(errorMessage))
        end
    end

    runtime.CompleteCallback = function(_, message, playerId)
        local ok, errorMessage = xpcall(function()
            local requestedElementId = tonumber(message and message.elementId)
            local touchedElementId = runtime.TouchedByPlayer[playerId]
            local failureReason

            if not requestedElementId
                or requestedElementId ~= runtime.SpawnedChickenRootId
                or touchedElementId ~= requestedElementId then
                failureReason = "完成请求与当前复制鸡根元件不一致"
            elseif runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId] then
                failureReason = "玩家已有携带或附加中的元件"
            elseif runtime.ElementCarrier[requestedElementId]
                or runtime.PendingElementCarrier[requestedElementId] then
                failureReason = "元件已由其他玩家携带或正在附加"
            end

            local readSuccess
            local propertyValue
            if not failureReason then
                readSuccess, propertyValue = ReadPurposeProperty(requestedElementId)
                if not readSuccess or propertyValue ~= CHICKEN_ROOT_PURPOSE_VALUE then
                    failureReason = "复制鸡根元件的作用属性不再匹配"
                end
            end

            local playerPosition
            local elementPosition
            local distance
            if not failureReason then
                playerPosition = Character:GetPosition(playerId)
                elementPosition = Element:GetPosition(requestedElementId)
                if not playerPosition or not elementPosition then
                    failureReason = "无法读取玩家或元件位置"
                else
                    distance = HorizontalDistance(playerPosition, elementPosition)
                    if distance > MAX_HORIZONTAL_DISTANCE then
                        failureReason = "玩家与元件的水平距离超过"
                            .. tostring(MAX_HORIZONTAL_DISTANCE)
                    end
                end
            end

            if failureReason then
                runtime.TouchedByPlayer[playerId] = nil
                SendResult(runtime, playerId, requestedElementId, false, failureReason)
                Log:PrintServerLog("[PickupInteractionTest] 拾取完成请求被拒绝",
                    "playerId:", playerId,
                    "requestedElementId:", tostring(requestedElementId),
                    "touchedElementId:", tostring(touchedElementId),
                    "propertyReadSuccess:", tostring(readSuccess),
                    "propertyValue:", tostring(propertyValue),
                    "horizontalDistance:", tostring(distance),
                    "reason:", failureReason)
                return
            end

            runtime.TouchedByPlayer[playerId] = nil
            runtime.PendingByPlayer[playerId] = requestedElementId
            runtime.PendingElementCarrier[requestedElementId] = playerId

            local carryPosition = Engine.Vector(
                playerPosition.X,
                playerPosition.Y,
                playerPosition.Z + HEIGHT_OFFSET
            )
            Element:SetPosition(
                requestedElementId,
                carryPosition,
                Element.COORDINATE.World
            )
            Log:PrintServerLog("[PickupInteractionTest] 完成请求校验通过，已设置头顶位置",
                "playerId:", playerId,
                "elementId:", requestedElementId,
                "horizontalDistance:", distance,
                "playerPosition:", FormatPosition(playerPosition),
                "carryPosition:", FormatPosition(carryPosition),
                "heightOffset:", HEIGHT_OFFSET,
                "bindDelayFrames:", BIND_DELAY_FRAMES)

            context.Timers:AddFrame(PickupInteractionTest.Name, BIND_DELAY_FRAMES, function()
                Element:BindingToCharacterOrCreature(
                    requestedElementId,
                    playerId,
                    Character.SOCKET_NAME.Root,
                    Character.SOCKET_MODE.KeepWorld
                )

                context.Timers:AddFrame(PickupInteractionTest.Name, VERIFY_DELAY_FRAMES, function()
                    local attachedPlayerId = Element:GetAttachParentCharacter(requestedElementId)
                    local attachedPosition = Element:GetPosition(requestedElementId)
                    local currentPlayerPosition = Character:GetPosition(playerId)
                    local currentTreeIds = CollectTreeIds(requestedElementId)
                    local expectedNodeCount = #runtime.SpawnedChickenIds
                    local treeComplete = #currentTreeIds == expectedNodeCount
                    local success = attachedPlayerId == playerId and treeComplete

                    runtime.PendingByPlayer[playerId] = nil
                    runtime.PendingElementCarrier[requestedElementId] = nil
                    if success then
                        runtime.CarriedByPlayer[playerId] = requestedElementId
                        runtime.ElementCarrier[requestedElementId] = playerId
                    end

                    local resultReason
                    if attachedPlayerId ~= playerId then
                        resultReason = "附加父玩家与预期不一致"
                    elseif not treeComplete then
                        resultReason = "附加后的复制鸡树节点数量不一致"
                    end
                    SendResult(
                        runtime,
                        playerId,
                        requestedElementId,
                        success,
                        resultReason
                    )
                    Log:PrintServerLog("[PickupInteractionTest] 附加后一帧验证",
                        "success:", tostring(success),
                        "playerId:", playerId,
                        "elementId:", requestedElementId,
                        "attachedPlayerId:", tostring(attachedPlayerId),
                        "elementPosition:", FormatPosition(attachedPosition),
                        "playerPosition:", FormatPosition(currentPlayerPosition),
                        "expectedNodeCount:", expectedNodeCount,
                        "currentTreeNodeCount:", #currentTreeIds,
                        "currentTreeIds:", FormatIds(currentTreeIds),
                        "treeComplete:", tostring(treeComplete),
                        "heightOffset:", HEIGHT_OFFSET,
                        "socket:", "Root",
                        "socketMode:", "KeepWorld")

                    if not success then
                        error("复制鸡附加验证失败，expectedPlayer=" .. tostring(playerId)
                            .. " actualPlayer=" .. tostring(attachedPlayerId)
                            .. " expectedNodeCount=" .. tostring(expectedNodeCount)
                            .. " actualNodeCount=" .. tostring(#currentTreeIds))
                    end
                end)
            end)
        end, Traceback)
        if not ok then
            context.Manager:FailModule(PickupInteractionTest.Name,
                "完成拾取请求处理失败: " .. tostring(errorMessage))
        end
    end

    runtime.CancelCallback = function(_, message, playerId)
        RunProtectedCallback(context, "距离取消消息处理失败", function()
            local requestedElementId = tonumber(message and message.elementId)
            local touchedElementId = runtime.TouchedByPlayer[playerId]
            if requestedElementId and touchedElementId == requestedElementId then
                runtime.TouchedByPlayer[playerId] = nil
            end
            Log:PrintServerLog("[PickupInteractionTest] 收到客户端距离取消",
                "playerId:", playerId,
                "requestedElementId:", tostring(requestedElementId),
                "touchedElementId:", tostring(touchedElementId),
                "cleared:", tostring(
                    requestedElementId ~= nil and touchedElementId == requestedElementId
                ))
        end)
    end

    System:RegisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
    System:BindNotify(
        runtime.NetMsg.PickupTestComplete,
        runtime.CompleteCallback
    )
    System:BindNotify(
        runtime.NetMsg.PickupTestCancel,
        runtime.CancelCallback
    )

    local spawnPointReadSuccess, spawnPointPurpose = ReadPurposeProperty(TEST_SPAWN_POINT_ID)
    if not spawnPointReadSuccess or spawnPointPurpose ~= SPAWN_POINT_PURPOSE_VALUE then
        error("测试生成点属性不匹配，elementId=" .. tostring(TEST_SPAWN_POINT_ID)
            .. " expected=" .. SPAWN_POINT_PURPOSE_VALUE
            .. " actual=" .. tostring(spawnPointPurpose))
    end
    local sourceReadSuccess, sourcePurpose = ReadPurposeProperty(CHICKEN_SOURCE_ROOT_ID)
    if not sourceReadSuccess or sourcePurpose ~= CHICKEN_ROOT_PURPOSE_VALUE then
        error("鸡源父元件属性不匹配，elementId=" .. tostring(CHICKEN_SOURCE_ROOT_ID)
            .. " expected=" .. CHICKEN_ROOT_PURPOSE_VALUE
            .. " actual=" .. tostring(sourcePurpose))
    end
    local spawnPosition = Element:GetPosition(TEST_SPAWN_POINT_ID)
    if not spawnPosition then
        error("无法读取测试生成点位置，elementId=" .. tostring(TEST_SPAWN_POINT_ID))
    end

    Log:PrintServerLog("[PickupInteractionTest] 服务端动态复制拾取测试已启用",
        "sourceRootId:", CHICKEN_SOURCE_ROOT_ID,
        "sourceProperty:", PURPOSE_PROPERTY_NAME .. "=" .. sourcePurpose,
        "spawnPointId:", TEST_SPAWN_POINT_ID,
        "spawnPointProperty:", PURPOSE_PROPERTY_NAME .. "=" .. spawnPointPurpose,
        "spawnPosition:", FormatPosition(spawnPosition),
        "maxHorizontalDistance:", MAX_HORIZONTAL_DISTANCE,
        "heightOffset:", HEIGHT_OFFSET)

    context.ElementCopy:CopyTree(
        CHICKEN_SOURCE_ROOT_ID,
        CopyPosition(spawnPosition),
        COPY_DEBUG_NAME,
        function(result)
            RunProtectedCallback(context, "动态鸡复制完成处理失败", function()
                if not result.success then
                    Log:PrintError("[PickupInteractionTest] 动态鸡复制失败，按复制规则保留已生成部分",
                        "sourceRootId:", CHICKEN_SOURCE_ROOT_ID,
                        "failedSourceId:", tostring(result.failedSourceId),
                        "spawnedIds:", FormatIds(result.spawnedIds),
                        "pendingSourceIds:", FormatIds(result.pendingSourceIds),
                        "reason:", tostring(result.reason))
                    error("动态鸡复制失败: " .. tostring(result.reason))
                end

                runtime.SpawnedChickenRootId = result.rootId
                runtime.SpawnedChickenIds = result.spawnedIds
                local copiedReadSuccess, copiedPurpose = ReadPurposeProperty(result.rootId)
                local copiedTreeIds = CollectTreeIds(result.rootId)
                local treeComplete = #copiedTreeIds == #result.spawnedIds
                Log:PrintServerLog("[PickupInteractionTest] 动态鸡复制完成",
                    "sourceRootId:", CHICKEN_SOURCE_ROOT_ID,
                    "spawnPointId:", TEST_SPAWN_POINT_ID,
                    "copiedRootId:", result.rootId,
                    "spawnedIds:", FormatIds(result.spawnedIds),
                    "copiedTreeIds:", FormatIds(copiedTreeIds),
                    "spawnedNodeCount:", #result.spawnedIds,
                    "copiedTreeNodeCount:", #copiedTreeIds,
                    "treeComplete:", tostring(treeComplete),
                    "propertyReadSuccess:", tostring(copiedReadSuccess),
                    "propertyValue:", tostring(copiedPurpose),
                    "expectedPropertyValue:", CHICKEN_ROOT_PURPOSE_VALUE,
                    "rootPosition:", FormatPosition(Element:GetPosition(result.rootId)))

                if not copiedReadSuccess or copiedPurpose ~= CHICKEN_ROOT_PURPOSE_VALUE then
                    error("复制鸡根没有保留作用=鸡父元件")
                end
                if not treeComplete then
                    error("复制鸡树节点数量不一致，spawned=" .. tostring(#result.spawnedIds)
                        .. " tree=" .. tostring(#copiedTreeIds))
                end
            end)
        end
    )
end

local function StartClient(context)
    local runtime = {
        NetMsg = context.NetMsg.Messages,
        TargetElementId = nil,
        Holding = false,
        AwaitingResult = false,
        ElapsedSeconds = 0,
        ProgressStep = 0,
        HoldStartTime = nil,
        CheckTimerId = nil,
        PressedCallback = nil,
        ReleasedCallback = nil,
        ShowCallback = nil,
        ResultCallback = nil,
    }
    context.Services.PickupInteractionTest = runtime

    UI:SetProgressMaxValue({ PICKUP_PROGRESS_UI_ID }, 100)
    UI:SetProgressCurrentValue({ PICKUP_PROGRESS_UI_ID }, 0)
    UI:OnShow({ PICKUP_GROUP_UI_ID }, false)

    runtime.ShowCallback = function(_, message)
        RunProtectedCallback(context, "显示拾取UI消息处理失败", function()
            local elementId = tonumber(message and message.elementId)
            if not elementId then
                error("显示拾取UI消息缺少 elementId")
            end
            runtime.TargetElementId = elementId
            runtime.Holding = false
            runtime.AwaitingResult = false
            runtime.ElapsedSeconds = 0
            runtime.ProgressStep = 0
            runtime.HoldStartTime = nil
            UI:SetProgressMaxValue({ PICKUP_PROGRESS_UI_ID }, 100)
            UI:SetProgressCurrentValue({ PICKUP_PROGRESS_UI_ID }, 0)
            UI:OnShow({ PICKUP_GROUP_UI_ID }, true)
            Log:PrintLog("[PickupInteractionTest] 已显示拾取UI",
                "elementId:", elementId,
                "groupUiId:", PICKUP_GROUP_UI_ID,
                "buttonUiId:", PICKUP_BUTTON_UI_ID,
                "progressUiId:", PICKUP_PROGRESS_UI_ID)
        end)
    end

    runtime.ResultCallback = function(_, message)
        RunProtectedCallback(context, "附加结果消息处理失败", function()
            local elementId = tonumber(message and message.elementId)
            local success = message and message.success == true
            local reason = message and message.reason
            ResetClientInteraction(runtime, true)
            Log:PrintLog("[PickupInteractionTest] 收到附加结果",
                "success:", tostring(success),
                "elementId:", tostring(elementId),
                "reason:", tostring(reason))
        end)
    end

    runtime.PressedCallback = function()
        RunProtectedCallback(context, "拾取按钮按下处理失败", function()
            if not runtime.TargetElementId or runtime.AwaitingResult then
                return
            end
            runtime.Holding = true
            runtime.ElapsedSeconds = 0
            runtime.ProgressStep = 0
            runtime.HoldStartTime = TimerManager:GetTimeSeconds()
            UI:SetProgressCurrentValue({ PICKUP_PROGRESS_UI_ID }, 0)
            Log:PrintLog("[PickupInteractionTest] 开始按住拾取",
                "elementId:", runtime.TargetElementId)
        end)
    end

    runtime.ReleasedCallback = function()
        RunProtectedCallback(context, "拾取按钮松开处理失败", function()
            if not runtime.Holding then
                return
            end
            runtime.Holding = false
            runtime.ElapsedSeconds = 0
            runtime.ProgressStep = 0
            runtime.HoldStartTime = nil
            UI:SetProgressCurrentValue({ PICKUP_PROGRESS_UI_ID }, 0)
            Log:PrintLog("[PickupInteractionTest] 按钮松开，进度归零",
                "elementId:", tostring(runtime.TargetElementId))
        end)
    end

    System:BindNotify(
        runtime.NetMsg.PickupTestShow,
        runtime.ShowCallback
    )
    System:BindNotify(
        runtime.NetMsg.PickupTestResult,
        runtime.ResultCallback
    )
    UI:RegisterPressed(PICKUP_BUTTON_UI_ID, runtime.PressedCallback)
    UI:RegisterReleased(PICKUP_BUTTON_UI_ID, runtime.ReleasedCallback)

    runtime.CheckTimerId = context.Timers:AddLoopTimer(
        PickupInteractionTest.Name,
        CHECK_INTERVAL_SECONDS,
        function()
            local targetElementId = runtime.TargetElementId
            if not targetElementId or runtime.AwaitingResult then
                return
            end

            local localPlayerId = Character:GetLocalPlayerId()
            local playerPosition = Character:GetPosition(localPlayerId)
            local elementPosition = Element:GetPosition(targetElementId)
            if not playerPosition or not elementPosition then
                error("无法读取本地玩家或交互元件位置")
            end

            local distance = HorizontalDistance(playerPosition, elementPosition)
            if distance > MAX_HORIZONTAL_DISTANCE then
                Log:PrintLog("[PickupInteractionTest] 水平距离超过限制",
                    "playerId:", localPlayerId,
                    "elementId:", targetElementId,
                    "horizontalDistance:", distance,
                    "maxHorizontalDistance:", MAX_HORIZONTAL_DISTANCE)
                CancelClientInteraction(runtime, "horizontal_distance_exceeded", true)
                return
            end

            if not runtime.Holding then
                return
            end

            local elapsedSeconds = TimerManager:GetTimeSeconds() - runtime.HoldStartTime
            local progressStep = math.min(
                REQUIRED_PROGRESS_STEPS,
                math.floor(elapsedSeconds / CHECK_INTERVAL_SECONDS)
            )
            if elapsedSeconds >= REQUIRED_HOLD_SECONDS then
                progressStep = REQUIRED_PROGRESS_STEPS
            end
            runtime.ElapsedSeconds = math.min(REQUIRED_HOLD_SECONDS, elapsedSeconds)
            if progressStep ~= runtime.ProgressStep then
                runtime.ProgressStep = progressStep
                local progress = runtime.ProgressStep * 20
                UI:SetProgressCurrentValue({ PICKUP_PROGRESS_UI_ID }, progress)
                Log:PrintLog("[PickupInteractionTest] 拾取进度",
                    "elementId:", targetElementId,
                    "elapsedSeconds:", runtime.ElapsedSeconds,
                    "progress:", progress,
                    "horizontalDistance:", distance)
            end

            if elapsedSeconds >= REQUIRED_HOLD_SECONDS then
                runtime.Holding = false
                runtime.AwaitingResult = true
                runtime.HoldStartTime = nil
                System:SendToServer(
                    runtime.NetMsg.PickupTestComplete,
                    { elementId = targetElementId }
                )
                Log:PrintLog("[PickupInteractionTest] 按住时间已满，发送完成请求",
                    "elementId:", targetElementId,
                    "elapsedSeconds:", runtime.ElapsedSeconds)
            end
        end
    )

    Log:PrintLog("[PickupInteractionTest] 客户端测试已启用",
        "checkIntervalSeconds:", CHECK_INTERVAL_SECONDS,
        "maxHorizontalDistance:", MAX_HORIZONTAL_DISTANCE,
        "requiredHoldSeconds:", REQUIRED_HOLD_SECONDS)
end

function PickupInteractionTest:Start(context)
    if context.Side == "Server" then
        StartServer(context)
    else
        StartClient(context)
    end
end

local function StopServer(context, runtime)
    if runtime.TouchCallback then
        System:UnregisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
    end
    if runtime.CompleteCallback then
        System:UnbindNotify(
            runtime.NetMsg.PickupTestComplete,
            runtime.CompleteCallback
        )
    end
    if runtime.CancelCallback then
        System:UnbindNotify(
            runtime.NetMsg.PickupTestCancel,
            runtime.CancelCallback
        )
    end

    local rootId = runtime.SpawnedChickenRootId
    if rootId and not runtime.SpawnedChickenDestroyed then
        local attachedPlayerId = Element:GetAttachParentCharacter(rootId)
        if attachedPlayerId then
            Element:UnBinding(rootId)
        end
        context.ElementCopy:DestroyTree(rootId)
        runtime.SpawnedChickenDestroyed = true
        Log:PrintServerLog("[PickupInteractionTest] 停止测试，动态复制鸡树已销毁",
            "rootId:", rootId,
            "attachedPlayerIdBeforeDestroy:", tostring(attachedPlayerId),
            "spawnedNodeCount:", #runtime.SpawnedChickenIds)
    end
end

local function StopClient(context, runtime)
    if runtime.CheckTimerId then
        context.Timers:Remove(runtime.CheckTimerId)
        runtime.CheckTimerId = nil
    end
    if runtime.PressedCallback then
        UI:UnRegisterPressed(PICKUP_BUTTON_UI_ID, runtime.PressedCallback)
    end
    if runtime.ReleasedCallback then
        UI:UnRegisterReleased(PICKUP_BUTTON_UI_ID, runtime.ReleasedCallback)
    end
    if runtime.ShowCallback then
        System:UnbindNotify(
            runtime.NetMsg.PickupTestShow,
            runtime.ShowCallback
        )
    end
    if runtime.ResultCallback then
        System:UnbindNotify(
            runtime.NetMsg.PickupTestResult,
            runtime.ResultCallback
        )
    end
    ResetClientInteraction(runtime, true)
end

function PickupInteractionTest:Stop(context)
    local runtime = context.Services.PickupInteractionTest
    if not runtime then
        return
    end
    if context.Side == "Server" then
        StopServer(context, runtime)
    else
        StopClient(context, runtime)
    end
    context.Services.PickupInteractionTest = nil
end

return PickupInteractionTest
