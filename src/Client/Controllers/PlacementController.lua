local GameConfig = require "Common.Config.GameConfig"

local PlacementController = {
    Name = "PlacementController",
    FeatureFlag = "Placement",
    Dependencies = { "HotbarController" },
}

function PlacementController:Start(context)
    if context.Side ~= "Client" then return end
    local config = GameConfig.Placement
    local runtime = { Ready = false, Revision = -1, BlockedVersion = -1,
        Snapshot = nil, SelectedItemId = nil, SelectionBusy = false,
        PlaceVisible = false, RecallVisible = false, Awaiting = false }
    context.Services.PlacementController = runtime

    local function Active()
        return context.Services.PlacementController == runtime
    end

    local function Show(place, recall)
        if runtime.PlaceVisible ~= place then
            UI:SetVisibility({ config.UiGroupId }, place)
            runtime.PlaceVisible = place
        end
        if runtime.RecallVisible ~= recall then
            UI:SetVisibility({ config.RecallUiGroupId }, recall)
            runtime.RecallVisible = recall
        end
    end

    local function Render()
        local snapshot = runtime.Snapshot
        if not runtime.Ready or not snapshot or not snapshot.elementId then
            Show(false, false)
            return false
        end
        local playerId = Character:GetLocalPlayerId()
        local playerPosition = Character:GetPosition(playerId)
        local position = Element:GetPosition(snapshot.elementId)
        local inRange = false
        if playerPosition and position then
            local dx, dy, dz = playerPosition.X - position.X,
                playerPosition.Y - position.Y, playerPosition.Z - position.Z
            inRange = dx * dx + dy * dy + dz * dz <= config.MaxDistance ^ 2
        end
        if not inRange then
            -- 本地立即关闭且封锁此代次；服务端仍独立检查距离及取消代次。
            runtime.BlockedVersion = math.max(runtime.BlockedVersion, snapshot.version)
            runtime.Snapshot = nil
            runtime.Awaiting = false
            Show(false, false)
            System:SendToServer(context.NetMsg.Messages.PlacementCancel, {
                elementId = snapshot.elementId, version = snapshot.version,
            })
            return false
        end

        Show(snapshot.canPlace and runtime.SelectedItemId ~= nil
            and runtime.SelectedItemId == snapshot.selectedItemId and not runtime.SelectionBusy,
            snapshot.canRecall)
        return true
    end

    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, message = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(PlacementController.Name, tostring(message)) end
        end
    end

    runtime.StateCallback = Protect(function(_, message)
        if type(message) ~= "table" or type(message.revision) ~= "number"
            or message.revision <= runtime.Revision or type(message.version) ~= "number"
            or type(message.canPlace) ~= "boolean" or type(message.canRecall) ~= "boolean"
            or type(message.busy) ~= "boolean" then
            return
        end
        runtime.Revision = message.revision
        if message.elementId and message.version <= runtime.BlockedVersion then
            return
        end
        runtime.Snapshot = message
        runtime.Awaiting = message.busy
        Render()
    end)
    runtime.SelectionCallback = Protect(function(_, message)
        if type(message) ~= "table" or type(message.visible) ~= "boolean" then
            return
        end
        runtime.SelectedItemId = message.visible and message.selectedItemId or nil
        runtime.SelectionBusy = message.busy == true
        Render()
    end)
    runtime.ResultCallback = Protect(function(_, message)
        if type(message) ~= "table" or type(message.success) ~= "boolean" then return end
        if message.version ~= runtime.RequestVersion then return end
        if not runtime.Snapshot or runtime.Snapshot.elementId ~= runtime.RequestElementId then return end
        runtime.Awaiting = false
        if message.reason == "slot_locked" then UI:ShowMessageTip("升级家园解锁更多格子")
        elseif message.reason == "capacity_full" then UI:ShowMessageTip("鸡圈已满")
        elseif message.reason == "inventory_capacity_full" then UI:ShowMessageTip("库存已满，无法入库") end
        if not message.success then
            Log:PrintLog("[PlacementController] 放置交互结果", "action:", message.action,
                "success:", tostring(message.success), "reason:", tostring(message.reason))
        end
    end)

    local function Submit(action)
        if not Render() or runtime.Awaiting then return end
        if action == "place" and not runtime.PlaceVisible then return end
        if action == "recall" and not runtime.RecallVisible then return end
        local snapshot = runtime.Snapshot
        runtime.Awaiting = true
        runtime.RequestVersion = snapshot.version
        runtime.RequestElementId = snapshot.elementId
        System:SendToServer(context.NetMsg.Messages.PlacementAction, {
            action = action, version = snapshot.version, elementId = snapshot.elementId,
            itemId = action == "place" and runtime.SelectedItemId or nil,
        })
    end
    runtime.PlaceCallback = Protect(function() Submit("place") end)
    runtime.RecallCallback = Protect(function() Submit("recall") end)
    UI:SetVisibility({ config.UiGroupId }, false)
    UI:SetVisibility({ config.RecallUiGroupId }, false)
    UI:RegisterClicked(config.PlaceButtonId, runtime.PlaceCallback)
    UI:RegisterClicked(config.RecallButtonId, runtime.RecallCallback)
    System:BindNotify(context.NetMsg.Messages.PlacementState, runtime.StateCallback)
    System:BindNotify(context.NetMsg.Messages.PlacementResult, runtime.ResultCallback)
    -- 仅缓存服务端选择快照；注销时保留 HotbarController 的同消息监听。
    System:BindNotify(context.NetMsg.Messages.HotbarSelectionState, runtime.SelectionCallback)
    context.Timers:AddTimer(PlacementController.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if not Active() then return end
        runtime.Ready = true
        Render()
        System:SendToServer(context.NetMsg.Messages.PlacementSnapshotRequest, {})
    end)
    context.Timers:AddLoopFrame(PlacementController.Name, 1, Protect(function()
        if runtime.Ready then Render() end
    end))
end

function PlacementController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.PlacementController
    if not runtime then return end
    context.Services.PlacementController = nil
    local snapshot = runtime.Snapshot
    if snapshot and snapshot.elementId then
        local ok, errorMessage = pcall(function()
            System:SendToServer(context.NetMsg.Messages.PlacementCancel, {
                elementId = snapshot.elementId, version = snapshot.version,
            })
        end)
        if not ok then Log:PrintError("[PlacementController] 停止交互通知失败", tostring(errorMessage)) end
    end
    UI:UnRegisterClicked(GameConfig.Placement.PlaceButtonId, runtime.PlaceCallback)
    UI:UnRegisterClicked(GameConfig.Placement.RecallButtonId, runtime.RecallCallback)
    System:UnbindNotify(context.NetMsg.Messages.PlacementState, runtime.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.PlacementResult, runtime.ResultCallback)
    System:UnbindNotify(context.NetMsg.Messages.HotbarSelectionState, runtime.SelectionCallback)
    context.Timers:RemoveOwner(PlacementController.Name)
    UI:SetVisibility({ GameConfig.Placement.UiGroupId }, false)
    UI:SetVisibility({ GameConfig.Placement.RecallUiGroupId }, false)
end

return PlacementController
