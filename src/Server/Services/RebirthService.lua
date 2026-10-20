local GameConfig = require "Common.Config.GameConfig"
local RebirthService = { Name = "RebirthService", FeatureFlag = "Rebirth",
    Dependencies = { "PlayerSpeedService", "TreadmillService", "EconomyService", "HomeService" } }
local function Integer(value, zero)
    return type(value) == "number" and value >= (zero and 0 or 1) and value < math.huge and value == math.floor(value)
end
function RebirthService:ValidateConfig()
    if GameConfig.Rebirth.MaxCount ~= 20 then return false, { "重生最高20次" } end
    return true
end
function RebirthService:Start(context)
    if context.Side ~= "Server" then return end
    local speed, treadmill = context.Services.PlayerSpeedService, context.Services.TreadmillService
    local economy, home, messages = context.Services.EconomyService, context.Services.HomeService, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Locks = {}, Requests = {}, Version = 0 }
    context.Services.RebirthService = rt
    local persistence = context.Services.PersistenceService
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id))
    end
    local function PrepareLeave(id)
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(id) end
    end
    local function Active() return rt.Active and context.Services.RebirthService == rt end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Send(id)
        if not Active() or not rt.Ready then return end
        local snapshot = speed:GetSnapshot(id)
        rt.Version = rt.Version + 1
        System:SendToClient(id, messages.RebirthState, {
            version = rt.Version, sessionGeneration = snapshot and snapshot.sessionGeneration,
            expectedCount = snapshot and snapshot.rebirthCount, experience = snapshot and snapshot.experience,
            requirement = snapshot and snapshot.rebirthRequirement, multiplier = snapshot and snapshot.multiplier,
            nextMultiplier = snapshot and snapshot.nextMultiplier, busy = rt.Locks[id] ~= nil,
        })
    end
    local function Result(id, request, success, reason)
        if not Active() then return end
        System:SendToClient(id, messages.RebirthResult, { requestId = request.requestId,
            sessionGeneration = request.sessionGeneration, expectedCount = request.expectedCount, success = success, reason = reason })
    end
    local function Cancel(id)
        local lock = rt.Locks[id]
        rt.Locks[id] = nil
        if lock then
            lock.invalid = true
            if lock.token then treadmill:CancelReset(id, lock.token) end
        end
    end
    rt.Action = Protect(function(_, request, id)
        if not CanPlay(id) then return end
        if not rt.Ready or not Integer(id) or type(request) ~= "table" or not Integer(request.requestId)
            or not Integer(request.sessionGeneration) or not Integer(request.expectedCount, true)
            or request.expectedCount > GameConfig.Rebirth.MaxCount then return end
        local snapshot = speed:GetSnapshot(id)
        if not snapshot or snapshot.sessionGeneration ~= request.sessionGeneration or not economy:IsCurrent(id, request.sessionGeneration) then
            Result(id, request, false, "session_unavailable"); return
        end
        if rt.Locks[id] then Result(id, request, false, "rebirth_busy"); return end
        local previous = rt.Requests[id]
        if previous and previous.generation == request.sessionGeneration and request.requestId <= previous.id then
            Result(id, request, false, "stale_request"); return
        end
        rt.Requests[id] = { generation = request.sessionGeneration, id = request.requestId }
        local allowed, reason = speed:CanRebirth(id, request.sessionGeneration, request.expectedCount)
        if not allowed then Result(id, request, false, reason); Send(id); return end
        local homeId = home:GetPlayerHome(id)
        if not homeId or not home:IsOwner(id, homeId) then Result(id, request, false, "home_unavailable"); return end
        local lock = { request = request, homeId = homeId }
        rt.Locks[id] = lock
        local function Finish(success, value)
            if not Active() or rt.Locks[id] ~= lock or lock.invalid then
                if success then treadmill:CancelReset(id, value) end
                return
            end
            if not success then
                rt.Locks[id] = nil; Result(id, request, false, value); Send(id); return
            end
            lock.token = value
            if not economy:IsCurrent(id, request.sessionGeneration) or not home:IsOwner(id, lock.homeId) then
                Cancel(id); Result(id, request, false, "session_unavailable"); Send(id); return
            end
            local commitGrowth, why = speed:PrepareRebirthCommit(id, request.sessionGeneration, request.expectedCount)
            if not commitGrowth then Cancel(id); Result(id, request, false, why); Send(id); return end
            local committed, publish = treadmill:CommitReset(id, request.sessionGeneration, value, commitGrowth)
            if not committed then Cancel(id); Result(id, request, false, publish); Send(id); return end
            -- 两份业务状态已经提交，仍持有锁直到提交后通知结束。
            local ok, err = pcall(publish)
            if not ok then Log:PrintError("[Rebirth] 提交后通知异常，不重试", id, tostring(err)) end
            if not Active() or rt.Locks[id] ~= lock then return end
            rt.Locks[id] = nil
            Send(id); Result(id, request, true, "reborn")
        end
        local started, token = treadmill:PrepareReset(id, request.sessionGeneration, Finish)
        if not started then
            if rt.Locks[id] == lock then rt.Locks[id] = nil; Result(id, request, false, token); Send(id) end
            return
        end
        if rt.Locks[id] == lock then lock.token = token; Send(id) end
    end)
    rt.Snapshot = Protect(function(_, request, id)
        if rt.Ready and Integer(id) and type(request) == "table" and next(request) == nil then Send(id) end
    end)
    rt.Leave = Protect(function(id) PrepareLeave(id); Cancel(id); rt.Requests[id] = nil end)
    rt.Death = Protect(function(id) Cancel(id); if rt.Ready then Send(id) end end)
    rt.Bindings = { { Events.ON_PLAYER_PRELEAVE, rt.Leave }, { Events.ON_PLAYER_RECONNECTED, rt.Leave },
        { Events.ON_CHARACTER_KILLED, rt.Death }, { Events.ON_CHARACTER_DESTROYED, rt.Death } }
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    System:BindNotify(messages.RebirthAction, rt.Action)
    System:BindNotify(messages.RebirthSnapshotRequest, rt.Snapshot)
    context.Events:Subscribe(self.Name, "PlayerSpeedChanged", Protect(function(data)
        local lock = rt.Locks[data.playerId]
        if lock and lock.request.sessionGeneration ~= data.sessionGeneration then Cancel(data.playerId) end
        Send(data.playerId)
    end))
    context.Events:Subscribe(self.Name, "HomeReleased", Protect(function(data) Cancel(data.playerId) end))
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function()
        rt.Ready = true
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Send(id) end
    end))
    rt.Cleanup = function()
        rt.Active = false
        local ids = {}; for id in pairs(rt.Locks) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do Cancel(id) end
        rt.Requests = {}
    end
end
function RebirthService:Stop(context)
    local rt = context.Services.RebirthService
    if not rt then return end
    rt.Cleanup()
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    System:UnbindNotify(context.NetMsg.Messages.RebirthAction, rt.Action)
    System:UnbindNotify(context.NetMsg.Messages.RebirthSnapshotRequest, rt.Snapshot)
    context.Events:UnsubscribeOwner(self.Name); context.Timers:RemoveOwner(self.Name)
    context.Services.RebirthService = nil
end
return RebirthService
