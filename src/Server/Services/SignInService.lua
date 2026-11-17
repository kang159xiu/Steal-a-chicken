local Config = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local SafeCall = require "Common.Core.SafeCall"
local SignInService = { Name = "SignInService", FeatureFlag = "SignIn",
    Dependencies = { "EconomyService", "InventoryService", "RebirthService" } }
local function Integer(n)
    return type(n) == "number" and n >= 0 and n <= 9007199254740991 and n == math.floor(n)
end
-- 服务器毫秒时间戳换算为北京时间自然日，不使用客户端时钟。
local function Today()
    return math.floor((MiscService:GetServerTimestamp() + 28800000) / 86400000)
end
function SignInService:Start(context)
    if context.Side ~= "Server" then return end
    local economy, inventory = context.Services.EconomyService, context.Services.InventoryService
    local persistence, rebirth = context.Services.PersistenceService, context.Services.RebirthService
    local rewards, messages = Config.SignIn.Rewards, context.NetMsg.Messages
    local rt = { Active = true, Players = {}, Version = 0 }
    context.Services.SignInService = rt
    local function Active() return rt.Active and context.Services.SignInService == rt end
    local function Protect(callback)
        return SafeCall.Protect(Active, function(err) context.Manager:FailModule(self.Name, tostring(err)) end, callback)
    end
    local function CanPlay(id)
        return not Config.Persistence.ProductionEnabled or persistence:IsReady(id)
    end
    local function Ensure(id)
        if not CanPlay(id) then return nil end
        if not rt.Players[id] and not Config.Persistence.ProductionEnabled then
            rt.Players[id] = { count = 0, lastDay = 0 }
        end
        return rt.Players[id]
    end
    function rt:ExportSnapshot(id)
        local state = self.Players[id]
        if not state then return nil, "sign_in_state_missing" end
        return { version = 1, count = state.count, lastDay = state.lastDay }
    end
    local function Send(id)
        local state, day = rt.Players[id], Today()
        local statuses = {}
        if state then
            local claimed = state.count
            if claimed == #rewards and day > state.lastDay then claimed = 0 end
            for index in ipairs(rewards) do
                statuses[index] = index <= claimed and "已签到"
                    or index == claimed + 1 and day > state.lastDay and "可签到" or "未签到"
            end
        end
        rt.Version = rt.Version + 1
        System:SendToClient(id, messages.SignInState, { version = rt.Version,
            ready = state ~= nil and CanPlay(id), statuses = statuses,
            count = state and state.count or 0, lastDay = state and state.lastDay or 0 })
    end
    local function Notify(callback)
        local ok, err = pcall(callback)
        if not ok then Log:PrintError("[SignIn] 领取后通知失败，不重复发奖", tostring(err)) end
    end
    local function Result(id, request, success, reason)
        Notify(function() Send(id) end)
        Notify(function() System:SendToClient(id, messages.SignInResult,
            { requestId = request.requestId, success = success, reason = reason }) end)
    end
    if Config.Persistence.ProductionEnabled then
        assert(persistence:RegisterAdapter("signIn", {
            Export = function(id) return rt:ExportSnapshot(id) end,
            Restore = function(id, data, done)
                local count, lastDay = 0, 0
                if data ~= nil then
                    if type(data) ~= "table" then done(false, "invalid_sign_in_archive"); return end
                    if data.version ~= 1 then Log:PrintServerLog("[Persistence] version mismatch", id, "signIn", tostring(data.version), 1) end
                    if data.count ~= nil then count = data.count end
                    if data.lastDay ~= nil then lastDay = data.lastDay end
                end
                if not Integer(count) or count > #rewards or not Integer(lastDay) then
                    done(false, "invalid_sign_in_archive"); return
                end
                rt.Players[id] = { count = count, lastDay = lastDay }
                done(true)
            end,
            Cleanup = function(id) rt.Players[id] = nil end,
        }))
    end
    rt.Snapshot = Protect(function(_, request, id)
        if type(request) ~= "table" or next(request) ~= nil then return end
        Ensure(id); Send(id)
    end)
    rt.Claim = Protect(function(_, request, id)
        if type(request) ~= "table" or not Integer(request.requestId) or request.requestId < 1
            or not Integer(request.index) or not rewards[request.index]
            or not Integer(request.count) or not Integer(request.lastDay) then return end
        local state, day = Ensure(id), Today()
        if not state then Result(id, request, false, "player_not_ready"); return end
        if state.count ~= request.count or state.lastDay ~= request.lastDay then
            Result(id, request, false, "stale_state"); return
        end
        if day <= state.lastDay then Result(id, request, false, "already_claimed_today"); return end
        local index = state.count % #rewards + 1
        if request.index ~= index then Result(id, request, false, "wrong_day"); return end
        local generation = economy:GetSessionGeneration(id)
        local lock, reason = rebirth:TryAcquirePurchaseLock(id, generation)
        if not lock then Result(id, request, false, reason); return end
        -- 准备阶段没有资产副作用；提交完成后才更新通知和关键存档。
        local called, success, value = pcall(function()
            local row, chickenCommit, saleTotal = rewards[index], nil, "0"
            if #row.Chickens > 0 then
                chickenCommit, saleTotal = inventory:PrepareGiftChickens(id, row.Chickens)
                if not chickenCommit then return false, saleTotal end
            end
            local coinCommit, why = economy:PrepareCoinRewardCommit(id, generation, Decimal.Add(row.Coins, saleTotal))
            if not coinCommit then return false, why end
            if not Active() or rt.Players[id] ~= state or not CanPlay(id)
                or state.count ~= request.count or state.lastDay ~= request.lastDay
                or not rebirth:IsPurchaseLockCurrent(id, generation, lock) then return false, "session_unavailable" end
            local chickenPublish
            if chickenCommit then
                local added
                added, chickenPublish = chickenCommit()
                if not added then return false, chickenPublish end
            end
            local credited, coinPublish = coinCommit()
            if not credited then return false, coinPublish end
            state.count, state.lastDay = index, day
            return true, function()
                -- 先登记关键保存；任一表现失败都不使已领取奖励再次可领。
                if Config.Persistence.ProductionEnabled then
                    Notify(function()
                        local saved, why = persistence:MarkDirty(id, "sign_in")
                        if not saved then Log:PrintError("[SignIn] 保存调度失败，不重复发奖", id, tostring(why)) end
                    end)
                end
                if chickenPublish then Notify(chickenPublish) end
                Notify(coinPublish)
            end
        end)
        rebirth:ReleasePurchaseLock(id, lock)
        if not called then
            Log:PrintError("[SignIn] 领取异常，不自动重试", id, tostring(success))
            Result(id, request, false, "claim_error"); return
        end
        if success then Notify(value) end
        if Active() and rt.Players[id] == state then
            if success then Result(id, request, true) else Result(id, request, false, value) end
        end
    end)
    rt.Leave = Protect(function(id)
        if Config.Persistence.ProductionEnabled then persistence:PrepareLeave(id) end
        rt.Players[id] = nil
    end)
    rt.Bindings = { { Events.ON_PLAYER_PRELEAVE, rt.Leave }, { Events.ON_PLAYER_RECONNECTED, rt.Leave } }
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    System:BindNotify(messages.SignInSnapshotRequest, rt.Snapshot)
    System:BindNotify(messages.SignInClaim, rt.Claim)
    context.Events:Subscribe(self.Name, "PersistenceReady", Protect(function(event) Ensure(event.playerId); Send(event.playerId) end))
    context.Events:Subscribe(self.Name, "PlayerDataResetStarted", Protect(function(event) Send(event.playerId) end))
    -- 只在北京时间下一次0点唤醒，在线跨日也更新按钮，不按帧轮询。
    local ScheduleMidnight
    ScheduleMidnight = function()
        local now = MiscService:GetServerTimestamp()
        local nextMidnight = (math.floor((now + 28800000) / 86400000) + 1) * 86400000 - 28800000
        rt.MidnightTimer = context.Timers:AddTimer(self.Name, (nextMidnight - now) / 1000, Protect(function()
            rt.MidnightTimer = nil
            for id in pairs(rt.Players) do if CanPlay(id) then Notify(function() Send(id) end) end end
            ScheduleMidnight()
        end))
    end
    context.Timers:AddTimer(self.Name, Config.Runtime.ServerReadyDelaySeconds, Protect(function()
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Ensure(id); Send(id) end
        ScheduleMidnight()
    end))
end
function SignInService:Stop(context)
    local rt = context.Services.SignInService
    if not rt then return end
    rt.Active, rt.Players = false, {}
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    System:UnbindNotify(context.NetMsg.Messages.SignInSnapshotRequest, rt.Snapshot)
    System:UnbindNotify(context.NetMsg.Messages.SignInClaim, rt.Claim)
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.SignInService = nil
end
return SignInService
