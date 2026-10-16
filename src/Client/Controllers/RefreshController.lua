local GameConfig = require "Common.Config.GameConfig"

local RefreshController = { Name = "RefreshController", Dependencies = { "PickupController" } }

function RefreshController:Start(context)
    if context.Side ~= "Client" then return end
    local config = GameConfig.Refresh
    local runtime = { Revision = -1, Snapshot = nil, Ready = false }
    context.Services.RefreshController = runtime

    local function Render()
        if context.Services.RefreshController ~= runtime or not runtime.Ready then return end
        local snapshot = runtime.Snapshot
        local visible = snapshot and (snapshot.phase == "Waiting" or snapshot.phase == "Countdown"
            or snapshot.phase == "Generating")
        UI:OnShow({ config.CountdownUiId }, visible == true)
        if snapshot and snapshot.phase == "Generating" then
            UI:SetText({ config.CountdownUiId }, "刷新中", false)
        elseif visible then
            local seconds = math.max(0, math.ceil((snapshot.deadlineMs - MiscService:GetServerTimestamp()) / 1000))
            UI:SetText({ config.CountdownUiId }, tostring(seconds) .. "s", false)
        end
    end

    runtime.PhaseCallback = function(_, message)
        if context.Services.RefreshController ~= runtime then return end
        if type(message) ~= "table" or type(message.revision) ~= "number"
            or message.revision < runtime.Revision or type(message.generation) ~= "number" then return end
        if message.phase ~= "Waiting" and message.phase ~= "Countdown"
            and message.phase ~= "Generating" and message.phase ~= "Clearing" then return end
        if (message.phase == "Waiting" or message.phase == "Countdown")
            and type(message.deadlineMs) ~= "number" then return end
        runtime.Revision = message.revision
        runtime.Snapshot = message
        context.Events:Publish("RefreshPhaseChanged", message)
        Render()
    end
    local phaseCallback = runtime.PhaseCallback
    runtime.PhaseCallback = function(...)
        if context.Services.RefreshController ~= runtime then return end
        local ok, errorMessage = pcall(phaseCallback, ...)
        if not ok then context.Manager:FailModule(RefreshController.Name, tostring(errorMessage)) end
    end
    System:BindNotify(context.NetMsg.Messages.RefreshPhase, runtime.PhaseCallback)
    context.Timers:AddTimer(RefreshController.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if context.Services.RefreshController ~= runtime then return end
        runtime.Ready = true
        Render()
        System:SendToServer(context.NetMsg.Messages.RefreshSnapshotRequest, {})
    end)
    context.Timers:AddLoopTimer(RefreshController.Name, 0.2, Render)
end

function RefreshController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.RefreshController
    if not runtime then return end
    runtime.Ready = false
    context.Services.RefreshController = nil
    System:UnbindNotify(context.NetMsg.Messages.RefreshPhase, runtime.PhaseCallback)
    UI:OnShow({ GameConfig.Refresh.CountdownUiId }, false)
end

return RefreshController
