local GameConfig = require "Common.Config.GameConfig"

local EggCollectionController = { Name = "EggCollectionController", FeatureFlag = "EggCollection", Dependencies = { "PromptController" } }
local function Integer(value, minimum)
    return type(value) == "number" and value >= minimum and value < math.huge and value == math.floor(value)
end

function EggCollectionController:Start(context)
    if context.Side ~= "Client" then return end
    local config = GameConfig.EggCollection
    local runtime = { Ready = false, Stopped = false, Revision = -1, BlockedVersion = -1,
        Snapshot = nil, Awaiting = false, Visible = nil }
    context.Services.EggCollectionController = runtime
    local function Active() return not runtime.Stopped and context.Services.EggCollectionController == runtime end
    local function Show(visible)
        if runtime.Visible ~= visible then
            UI:SetVisibility({ config.UiGroupId }, visible)
            runtime.Visible = visible
        end
    end
    local function Cancel(snapshot)
        runtime.BlockedVersion = math.max(runtime.BlockedVersion, snapshot.version)
        runtime.Snapshot, runtime.Request, runtime.Awaiting = nil, nil, false
        Show(false)
        System:SendToServer(context.NetMsg.Messages.EggCollectionCancel, {
            eggId = snapshot.eggId, version = snapshot.version,
        })
    end
    local function Render()
        if not Active() or not runtime.Ready then
            return false
        end
        local snapshot = runtime.Snapshot
        if not snapshot or not snapshot.visible then
            Show(false); return false
        end
        local ok, inRange = pcall(function()
            local playerId = Character:GetLocalPlayerId()
            local playerPosition, position = Character:GetPosition(playerId), Element:GetPosition(snapshot.rootId)
            if not playerPosition or not position then error("玩家或蛋根位置不可用") end
            local dx, dy, dz = playerPosition.X - position.X, playerPosition.Y - position.Y, playerPosition.Z - position.Z
            return dx * dx + dy * dy + dz * dz <= config.MaxDistance ^ 2
        end)
        if not ok then
            Log:PrintError("[EggCollectionController] 位置读取失败，取消本次目标", "eggId:", snapshot.eggId,
                "rootId:", snapshot.rootId, "error:", tostring(inRange))
        end
        if not ok or not inRange then
            Cancel(snapshot); return false
        end

        Show(true)
        return true
    end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, errorMessage = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(errorMessage)) end
        end
    end
    runtime.StateCallback = Protect(function(_, message)
        if type(message) ~= "table" or not Integer(message.revision, 1) or message.revision <= runtime.Revision
            or not Integer(message.version, 0) or type(message.visible) ~= "boolean" or type(message.busy) ~= "boolean"
            or (message.visible and (not Integer(message.eggId, 1) or not Integer(message.rootId, 1)
                or not Integer(message.homeId, 1))) then
            return
        end
        runtime.Revision = message.revision
        if message.visible and message.version <= runtime.BlockedVersion then
            return
        end
        local previous = runtime.Snapshot
        if not previous or previous.eggId ~= message.eggId or previous.version ~= message.version then runtime.Request = nil end
        runtime.Snapshot = { revision = message.revision, version = message.version, eggId = message.eggId,
            rootId = message.rootId, homeId = message.homeId, visible = message.visible, busy = message.busy }
        runtime.Awaiting = message.busy
        Render()
    end)
    runtime.ResultCallback = Protect(function(_, message)
        local request, snapshot = runtime.Request, runtime.Snapshot
        if type(message) ~= "table" or type(message.success) ~= "boolean" or not request or not snapshot
            or message.eggId ~= request.eggId or message.version ~= request.version
            or snapshot.eggId ~= request.eggId or snapshot.version ~= request.version then return end
        runtime.Request, runtime.Awaiting = nil, false
        if message.success then
            runtime.BlockedVersion = math.max(runtime.BlockedVersion, snapshot.version)
            runtime.Snapshot = nil
            Show(false)
        elseif message.reason == "inventory_capacity_full" then
            context.Services.PromptController:Show("鸡蛋库存已满，请先出售")
            Render()
        elseif message.reason == "egg_not_mature" then
            context.Services.PromptController:Show("鸡蛋还未孵化完成")
            Render()
        else
            Log:PrintLog("[EggCollectionController] 收取失败，等待当前目标状态",
                "eggId:", message.eggId, "reason:", tostring(message.reason))
            Render()
        end
    end)
    runtime.ClickCallback = Protect(function()
        if not Render() or runtime.Awaiting then return end
        local snapshot = runtime.Snapshot
        runtime.Request = { eggId = snapshot.eggId, version = snapshot.version }
        runtime.Awaiting = true
        System:SendToServer(context.NetMsg.Messages.EggCollectionAction, {
            eggId = snapshot.eggId, version = snapshot.version,
        })
    end)
    System:BindNotify(context.NetMsg.Messages.EggCollectionState, runtime.StateCallback)
    System:BindNotify(context.NetMsg.Messages.EggCollectionResult, runtime.ResultCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function()
        runtime.Ready = true

        UI:RegisterClicked(config.CollectButtonId, runtime.ClickCallback)
        runtime.ClickRegistered = true
        Render()
        System:SendToServer(context.NetMsg.Messages.EggCollectionSnapshotRequest, {})
    end))
    context.Timers:AddLoopFrame(self.Name, 1, Protect(function() if runtime.Ready then Render() end end))
    runtime.Cleanup = function()
        runtime.Stopped = true
        local snapshot = runtime.Snapshot
        if snapshot and snapshot.eggId then
            local ok, errorMessage = pcall(function()
                System:SendToServer(context.NetMsg.Messages.EggCollectionCancel,
                    { eggId = snapshot.eggId, version = snapshot.version })
            end)
            if not ok then Log:PrintError("[EggCollectionController] 停止取消通知失败", tostring(errorMessage)) end
        end
        runtime.Snapshot, runtime.Request, runtime.Awaiting = nil, nil, false
        if runtime.Ready then Show(false) end
    end
end

function EggCollectionController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.EggCollectionController
    if not runtime then return end
    runtime.Cleanup()
    if runtime.ClickRegistered then UI:UnRegisterClicked(GameConfig.EggCollection.CollectButtonId, runtime.ClickCallback) end
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionState, runtime.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionResult, runtime.ResultCallback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.EggCollectionController = nil
end

return EggCollectionController
