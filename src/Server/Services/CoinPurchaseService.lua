local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local SafeCall = require "Common.Core.SafeCall"
local CoinPurchaseService = { Name = "CoinPurchaseService", FeatureFlag = "CoinPurchase",
    Dependencies = { "PurchaseService", "EconomyService", "RebirthService" } }

function CoinPurchaseService:Start(context)
    if context.Side ~= "Server" then return end
    local economy, purchase = context.Services.EconomyService, context.Services.PurchaseService
    local persistence, rebirth = context.Services.PersistenceService, context.Services.RebirthService
    local config, messages = GameConfig.CoinPurchase, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Players = {}, Version = 0 }
    context.Services.CoinPurchaseService = rt
    local function Active() return rt.Active and context.Services.CoinPurchaseService == rt end
    local function Protect(callback)
        return SafeCall.Protect(Active, function(err) context.Manager:FailModule(self.Name, tostring(err)) end, callback)
    end
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id))
    end
    local function Send(id)
        rt.Version = rt.Version + 1
        local state = rt.Players[id]
        System:SendToClient(id, messages.CoinPurchaseState, { version = rt.Version,
            rewards = state and state.rewards or nil })
    end
    local function Ensure(id)
        if not rt.Ready or not CanPlay(id) then return nil end
        if rt.Players[id] then return rt.Players[id] end
        local balance = economy:GetBalance(id)
        if not balance then return nil end
        local base = balance
        if Decimal.Compare(base, config.MinimumBase) < 0 then base = config.MinimumBase end
        if #base > 1 and base:sub(2):find("[1-9]") then
            base = Decimal.Add(base:sub(1, 1), "1") .. string.rep("0", #base - 1)
        end
        local state = { generation = economy:GetSessionGeneration(id), rewards = {} }
        for index, row in ipairs(config.Products) do
            local amount = "0"
            for _ = 1, row.Multiplier do amount = Decimal.Add(amount, base) end
            state.rewards[index] = amount
        end
        rt.Players[id] = state
        Send(id)
        return state
    end
    local function Scan(id, state)
        if rt.Players[id] ~= state or not CanPlay(id) or state.halted or state.running then return end
        state.running = true
        state.deferred = nil
        for index, row in ipairs(config.Products) do
            local count, reason = purchase:GetVoucherCount(id, state.generation, row.ItemId)
            if count == nil then
                state.halted = true
                Log:PrintError("[CoinPurchase] 核票失败，不自动重试", id, row.GoodsId, tostring(reason))
                break
            end
            for _ = 1, count do
                if rt.Players[id] ~= state or not CanPlay(id) then state.running = nil; return end
                local lock, why = rebirth:TryAcquirePurchaseLock(id, state.generation)
                if not lock then
                    state.deferred = true
                    Log:PrintError("[CoinPurchase] 暂未兑现，保留凭证", id, row.GoodsId, tostring(why))
                    state.running = nil
                    return
                end
                local commit
                local ok, publish, consumed = purchase:ConsumeVoucher(id, state.generation, row.ItemId, function()
                    if rt.Players[id] ~= state or not CanPlay(id)
                        or not rebirth:IsPurchaseLockCurrent(id, state.generation, lock) then return false, "purchase_cancelled" end
                    commit, why = economy:PrepareCoinRewardCommit(id, state.generation, state.rewards[index])
                    return commit ~= nil, why
                end, function()
                    if rt.Players[id] ~= state or not rebirth:IsPurchaseLockCurrent(id, state.generation, lock) then
                        return false, "purchase_cancelled"
                    end
                    return commit()
                end)
                if ok then
                    local notified, err = pcall(publish)
                    if not notified then Log:PrintError("[CoinPurchase] 提交后通知失败，不重发", id, tostring(err)) end
                end
                rebirth:ReleasePurchaseLock(id, lock)
                if not ok then
                    if consumed == false and (publish == "sale_batch_busy" or publish == "voucher_busy") then
                        state.deferred = true
                        Log:PrintError("[CoinPurchase] 业务忙碌，保留凭证", id, row.GoodsId, tostring(publish))
                    else
                        state.halted = true
                        Log:PrintError("[CoinPurchase] 兑现失败，不重试不补偿", id, row.GoodsId, tostring(publish), tostring(consumed))
                    end
                    state.running = nil
                    return
                end
            end
        end
        state.running = nil
    end
    local function Wake(id)
        local state = Ensure(id)
        if not state or state.scheduled or state.halted then return end
        state.scheduled = true
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            state.scheduled = nil
            Scan(id, state)
        end))
    end
    rt.GetItem = Protect(function(id, itemId, _, custom)
        if custom ~= true then return end
        for _, row in ipairs(config.Products) do
            if row.ItemId == itemId then Wake(id); return end
        end
    end)
    rt.Snapshot = Protect(function(_, request, id)
        if type(request) ~= "table" or next(request) ~= nil then return end
        Ensure(id)
        Send(id)
    end)
    rt.Leave = Protect(function(id) rt.Players[id] = nil end)
    rt.Bindings = { { Events.ON_PLAYER_GET_ITEM, rt.GetItem }, { Events.ON_PLAYER_PRELEAVE, rt.Leave },
        { Events.ON_PLAYER_RECONNECTED, rt.Leave } }
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    System:BindNotify(messages.CoinPurchaseSnapshotRequest, rt.Snapshot)
    context.Events:Subscribe(self.Name, "PersistenceReady", Protect(function(event) Wake(event.playerId) end))
    -- 业务忙碌时保留凭证，由原状态完成通知唤醒，不增加重试定时器。
    for _, name in ipairs({ "EconomyChanged", "PlayerSpeedChanged", "TreadmillLevelChanged" }) do
        context.Events:Subscribe(self.Name, name, Protect(function(event)
            local state = rt.Players[event.playerId]
            if state and state.deferred then Wake(event.playerId) end
        end))
    end
    rt.Revive = Protect(function(id)
        local state = rt.Players[id]
        if state and state.deferred then Wake(id) end
    end)
    for _, name in ipairs({ Events.ON_CHARACTER_REVIVED, Events.ON_CHARACTER_RESPAWN }) do
        rt.Bindings[#rt.Bindings + 1] = { name, rt.Revive }
        System:RegisterEvent(name, rt.Revive)
    end
    context.Events:Subscribe(self.Name, "PlayerDataResetStarted", Protect(function(event)
        rt.Players[event.playerId] = nil
        Send(event.playerId)
    end))
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function()
        rt.Ready = true
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Wake(id) end
    end))
end
function CoinPurchaseService:Stop(context)
    local rt = context.Services.CoinPurchaseService
    if not rt then return end
    rt.Active = false
    rt.Players = {}
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    System:UnbindNotify(context.NetMsg.Messages.CoinPurchaseSnapshotRequest, rt.Snapshot)
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.CoinPurchaseService = nil
end
return CoinPurchaseService
