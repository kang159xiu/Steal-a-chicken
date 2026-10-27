local GameConfig = require "Common.Config.GameConfig"

local PickupController = {
    Name = "PickupController",
    FeatureFlag = "Theft",
    Dependencies = { "PromptController" },
}

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function HorizontalDistance(first, second)
    local dx = first.X - second.X
    local dy = first.Y - second.Y
    return math.sqrt(dx * dx + dy * dy)
end

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

function PickupController:ValidateConfig(context)
    if context.Side ~= "Client" then return true end
    local errors = {}
    local config = GameConfig.Theft
    if type(config.InteractionEnabled) ~= "boolean" then
        errors[#errors + 1] = "Theft.InteractionEnabled 必须是 boolean"
    end
    for _, field in ipairs({ "PickupUiGroupId", "PickupButtonId", "PickupProgressId",
        "CarryUiGroupId", "ManualDropButtonId" }) do
        if not IsPositiveInteger(config[field]) then
            errors[#errors + 1] = "Theft." .. field .. " 必须是正整数"
        end
    end
    if type(config.HoldSeconds) ~= "number" or config.HoldSeconds <= 0 then
        errors[#errors + 1] = "Theft.HoldSeconds 必须大于0"
    end
    if type(config.ProgressTickSeconds) ~= "number" or config.ProgressTickSeconds <= 0 then
        errors[#errors + 1] = "Theft.ProgressTickSeconds 必须大于0"
    end
    if type(config.DistanceCheckSeconds) ~= "number" or config.DistanceCheckSeconds <= 0 then
        errors[#errors + 1] = "Theft.DistanceCheckSeconds 必须大于0"
    end
    if type(config.MaxHorizontalDistance) ~= "number" or config.MaxHorizontalDistance <= 0 then
        errors[#errors + 1] = "Theft.MaxHorizontalDistance 必须大于0"
    end
    return #errors == 0, errors
end

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
        TargetElementId = nil,
        TargetOperation = nil,
        Generation = 0,
        RefreshBlocked = false,
        Holding = false,
        AwaitingResult = false,
        HoldStartTime = nil,
        CheckTimerId = nil,
        ProgressTimerId = nil,
        PressedCallback = nil,
        ReleasedCallback = nil,
        ShowCallback = nil,
        ResultCallback = nil,
        CarryVersion = -1,
        CarryRootId = nil,
        CarryOperation = nil,
        CarryReady = false,
        DropPending = false,
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

    local function ResetProgress()
        runtime.Holding = false
        runtime.HoldStartTime = nil
        UI:SetProgressCurrentValue({ config.PickupProgressId }, 0)
    end

    local function HideInteraction()
        ResetProgress()
        runtime.TargetElementId = nil
        runtime.TargetOperation = nil
        runtime.AwaitingResult = false
        UI:OnShow({ config.PickupUiGroupId }, false)
    end

    local function SendCancel(rootId, reason)
        System:SendToServer(context.NetMsg.Messages.PickupCancel, {
            elementId = rootId,
            generation = runtime.Generation,
            operation = runtime.TargetOperation,
            reason = reason,
        })
    end

    runtime.ShowCallback = function(_, message)
        Run("显示拾取交互", function()
            if type(message) ~= "table" or not IsPositiveInteger(message.elementId) then
                error("PickupShow 消息缺少有效 elementId")
            end
            if type(message.generation) ~= "number" or message.generation < runtime.Generation
                or runtime.RefreshBlocked then return end
            if type(message.operation) ~= "number" or message.operation < 0
                or message.operation ~= math.floor(message.operation) then return end
            if runtime.CarryRootId then return end
            runtime.Generation = message.generation
            runtime.TargetElementId = message.elementId
            runtime.TargetOperation = message.operation
            runtime.AwaitingResult = false
            ResetProgress()
            UI:SetProgressMaxValue({ config.PickupProgressId }, 100)
            UI:OnShow({ config.PickupUiGroupId }, true)
            Log:PrintLog("[PickupController] 显示正式拾取UI",
                "elementId:", message.elementId)
        end)
    end

    runtime.ResultCallback = function(_, message)
        Run("处理拾取结果", function()
            if type(message) ~= "table" or type(message.success) ~= "boolean" then
                error("PickupResult 消息格式无效")
            end
            local rootId = message.elementId
            if message.generation ~= runtime.Generation then return end
            if message.carryRetained then
                if rootId ~= runtime.CarryRootId or message.operation ~= runtime.CarryOperation then return end
                if message.reason == "inventory_capacity_full" then
                    context.Services.PromptController:Show("鸡库存已满，请先出售或放置")
                end
                return
            end
            if rootId ~= runtime.TargetElementId then return end
            if not message.success and message.operation ~= runtime.TargetOperation then return end
            if message.reason == "inventory_capacity_full" then context.Services.PromptController:Show("鸡库存已满，请先出售或放置") end
            HideInteraction()
            Log:PrintLog("[PickupController] 收到正式拾取结果",
                "success:", tostring(message.success),
                "elementId:", tostring(rootId),
                "reason:", tostring(message.reason))
        end)
    end

    runtime.PressedCallback = function()
        Run("拾取按钮按下", function()
            local rootId = runtime.TargetElementId
            if not rootId or runtime.Holding or runtime.AwaitingResult then return end
            runtime.Holding = true
            runtime.HoldStartTime = TimerManager:GetTimeSeconds()
            UI:SetProgressCurrentValue({ config.PickupProgressId }, 0)
            System:SendToServer(context.NetMsg.Messages.PickupBegin, {
                elementId = rootId,
                generation = runtime.Generation,
                operation = runtime.TargetOperation,
            })
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
                or type(message.carrying) ~= "boolean" then return end
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
            local rootId = runtime.TargetElementId
            ResetProgress()
            SendCancel(rootId, "button_released")
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
        if changed or runtime.RefreshBlocked then HideInteraction() end
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
    System:BindNotify(context.NetMsg.Messages.PickupShow, runtime.ShowCallback)
    System:BindNotify(context.NetMsg.Messages.PickupResult, runtime.ResultCallback)
    System:BindNotify(context.NetMsg.Messages.TheftCarryState, runtime.CarryStateCallback)
    UI:RegisterPressed(config.PickupButtonId, runtime.PressedCallback)
    UI:RegisterReleased(config.PickupButtonId, runtime.ReleasedCallback)
    context.Timers:AddTimer(PickupController.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if context.Services.PickupController ~= runtime then return end
        runtime.CarryReady = true
        UI:RegisterClicked(config.ManualDropButtonId, runtime.DropCallback)
        runtime.DropRegistered = true
        RenderCarry()
        System:SendToServer(context.NetMsg.Messages.TheftCarrySnapshotRequest, {})
    end)

    runtime.CheckTimerId = context.Timers:AddLoopTimer(
        PickupController.Name,
        config.DistanceCheckSeconds,
        function()
            if context.Services.PickupController ~= runtime then return end
            local rootId = runtime.TargetElementId
            if not rootId or runtime.AwaitingResult then return end

            local playerId = Character:GetLocalPlayerId()
            local playerPosition = Character:GetPosition(playerId)
            local chickenPosition = Element:GetPosition(rootId)
            if not playerPosition or not chickenPosition then
                error("正式拾取无法读取玩家或鸡的位置")
            end
            local distance = HorizontalDistance(playerPosition, chickenPosition)
            if distance > config.MaxHorizontalDistance then
                SendCancel(rootId, "horizontal_distance_exceeded")
                HideInteraction()
                Log:PrintLog("[PickupController] 超出正式拾取水平距离，已取消",
                    "elementId:", rootId,
                    "horizontalDistance:", distance,
                    "maxHorizontalDistance:", config.MaxHorizontalDistance)
                return
            end
        end
    )

    runtime.ProgressTimerId = context.Timers:AddLoopTimer(
        PickupController.Name,
        config.ProgressTickSeconds,
        function()
            if context.Services.PickupController ~= runtime or not runtime.Holding then return end
            local rootId = runtime.TargetElementId
            if not rootId or runtime.AwaitingResult then return end
            local elapsedSeconds = TimerManager:GetTimeSeconds() - runtime.HoldStartTime
            local progress = math.max(0, math.min(100, elapsedSeconds / config.HoldSeconds * 100))
            UI:SetProgressCurrentValue({ config.PickupProgressId }, progress)

            if elapsedSeconds >= config.HoldSeconds then
                runtime.Holding = false
                runtime.HoldStartTime = nil
                runtime.AwaitingResult = true
                System:SendToServer(context.NetMsg.Messages.PickupComplete, {
                    elementId = rootId,
                    generation = runtime.Generation,
                    operation = runtime.TargetOperation,
                })
                Log:PrintLog("[PickupController] 按住时间已满，发送正式完成请求",
                    "elementId:", rootId,
                    "elapsedSeconds:", elapsedSeconds)
            end
        end
    )

    Log:PrintLog("[PickupController] 正式拾取客户端已启动",
        "holdSeconds:", config.HoldSeconds,
        "tickSeconds:", config.ProgressTickSeconds,
        "maxHorizontalDistance:", config.MaxHorizontalDistance)
end

function PickupController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.PickupController
    if not runtime then return end
    context.Services.PickupController = nil
    runtime.Holding = false
    runtime.HoldStartTime = nil
    runtime.CarryReady = false
    if runtime.CheckTimerId then context.Timers:Remove(runtime.CheckTimerId) end
    if runtime.ProgressTimerId then context.Timers:Remove(runtime.ProgressTimerId) end
    if runtime.PressedCallback then
        UI:UnRegisterPressed(GameConfig.Theft.PickupButtonId, runtime.PressedCallback)
    end
    if runtime.ReleasedCallback then
        UI:UnRegisterReleased(GameConfig.Theft.PickupButtonId, runtime.ReleasedCallback)
    end
    if runtime.ShowCallback then
        System:UnbindNotify(context.NetMsg.Messages.PickupShow, runtime.ShowCallback)
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
