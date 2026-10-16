local GameConfig = require "Common.Config.GameConfig"

local TheftRefreshService = {
    Name = "TheftRefreshService",
    Dependencies = { "TheftService", "GuardianService", "ZoneService", "HomeService" },
}

function TheftRefreshService:ValidateConfig(context)
    local config = GameConfig.Refresh
    local errors = {}
    for _, field in ipairs({ "IntervalSeconds", "CountdownSeconds", "CountdownUiId" }) do
        local value = config[field]
        if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
            errors[#errors + 1] = "Refresh." .. field .. " 必须是有限正数"
        end
    end
    if config.RestartIntervalAt ~= "GenerationCompleted" then
        errors[#errors + 1] = "Refresh.RestartIntervalAt 必须为 GenerationCompleted"
    end
    return #errors == 0, errors
end

function TheftRefreshService:Start(context)
    if context.Side ~= "Server" then return end
    local config = GameConfig.Refresh
    local theft = context.Services.TheftService
    local guardian = context.Services.GuardianService
    local zone = context.Services.ZoneService
    local home = context.Services.HomeService
    local runtime = { Phase = "Generating", Revision = 0, Cycle = 0, DeadlineMs = nil }
    context.Services.TheftRefreshService = runtime

    -- 业务模块执行完成回调时，协调操作的错误仍归刷新模块所有。
    local function Protect(callback)
        return function(...)
            if context.Services.TheftRefreshService ~= runtime then return end
            local ok, errorMessage = pcall(callback, ...)
            if not ok then context.Manager:FailModule(TheftRefreshService.Name, tostring(errorMessage)) end
        end
    end

    local function IsCurrent(cycle)
        return context.Services.TheftRefreshService == runtime and runtime.Cycle == cycle
            and context.Services.TheftService == theft and not theft.Stopped
            and context.Services.GuardianService == guardian
    end

    local function Snapshot()
        return { phase = runtime.Phase, revision = runtime.Revision,
            generation = theft.Generation, deadlineMs = runtime.DeadlineMs }
    end

    local function SetPhase(phase, seconds)
        runtime.Phase = phase
        runtime.DeadlineMs = seconds and MiscService:GetServerTimestamp() + seconds * 1000 or nil
        runtime.Revision = runtime.Revision + 1
        System:SendToAllClients(context.NetMsg.Messages.RefreshPhase, Snapshot())
    end

    local function BeginRefresh()
        local cycle = runtime.Cycle + 1
        runtime.Cycle = cycle
        if not IsCurrent(cycle) then error("刷新依赖模块已停止") end
        Log:PrintServerLog("[TheftRefreshService] 刷新开始", "cycle:", cycle)
        local cleared, reset, countdownEnded = false, false, false
        local function TryGenerate()
            if not IsCurrent(cycle) or not cleared or not reset or not countdownEnded then return end
            if runtime.Phase == "Generating" then return end
            runtime.Phase = "Generating"
            theft:GenerateRegions()
            if not theft.Ready then SetPhase("Generating") end
        end
        System:FireSignEvent(config.SignalName, Character:GetAllPlayerIds() or {})
        theft:BeginRefresh(Protect(function()
            if not IsCurrent(cycle) then return end
            local teleportedCount = 0
            for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do
                if zone:IsInStolenArea(playerId) then
                    local returnPointId = home:GetReturnPoint(playerId)
                    local position = returnPointId and Element:GetPosition(returnPointId)
                    if not position then error("刷新无法读取玩家自己的家园返回点: " .. tostring(playerId)) end
                    Character:CharacterTeleport(playerId, position)
                    zone:SetPlayerArea(playerId, false, "refresh")
                    teleportedCount = teleportedCount + 1
                end
            end
            Log:PrintServerLog("[TheftRefreshService] 未拥有鸡已清场并传送玩家",
                "cycle:", cycle, "teleportedCount:", teleportedCount)
            context.Timers:AddFrame(TheftRefreshService.Name,
                GameConfig.Runtime.EngineOperationDelayFrames, function()
                    if not IsCurrent(cycle) then return end
                    cleared = true
                    TryGenerate()
                end)
        end))
        SetPhase("Countdown", config.CountdownSeconds)
        guardian:ResetForRefresh(Protect(function()
            if not IsCurrent(cycle) then return end
            reset = true
            TryGenerate()
        end))
        context.Timers:AddTimer(TheftRefreshService.Name, config.CountdownSeconds, function()
            if not IsCurrent(cycle) then return end
            countdownEnded = true
            SetPhase("Clearing")
            TryGenerate()
        end)
    end

    local function StartInterval(snapshot)
        if not IsCurrent(runtime.Cycle) or not theft.Ready
            or snapshot.generation ~= theft.Generation
            or runtime.Phase ~= "Generating" then return end
        SetPhase("Waiting", config.IntervalSeconds)
        Log:PrintServerLog("[TheftRefreshService] 全区生成完成，开始下一周期",
            "generation:", snapshot.generation, "deadlineMs:", runtime.DeadlineMs)
        local cycle = runtime.Cycle
        context.Timers:AddTimer(TheftRefreshService.Name, config.IntervalSeconds, function()
            if not IsCurrent(cycle) then return end
            BeginRefresh()
        end)
    end
    context.Events:Subscribe(TheftRefreshService.Name, "TheftGenerationCompleted", StartInterval)
    runtime.RequestCallback = Protect(function(_, message, playerId)
        if not IsCurrent(runtime.Cycle) then return end
        if type(playerId) ~= "number" or playerId <= 0 or playerId ~= math.floor(playerId) then return end
        local online = false
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do
            if id == playerId then online = true break end
        end
        if online then System:SendToClient(playerId, context.NetMsg.Messages.RefreshPhase, Snapshot()) end
    end)
    System:BindNotify(context.NetMsg.Messages.RefreshSnapshotRequest, runtime.RequestCallback)
    if theft.Ready then StartInterval({ generation = theft.Generation }) end
end

function TheftRefreshService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.TheftRefreshService
    if not runtime then return end
    runtime.Cycle = runtime.Cycle + 1
    context.Services.TheftRefreshService = nil
    System:UnbindNotify(context.NetMsg.Messages.RefreshSnapshotRequest, runtime.RequestCallback)
end

return TheftRefreshService
