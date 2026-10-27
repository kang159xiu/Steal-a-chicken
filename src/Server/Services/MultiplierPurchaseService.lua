local GameConfig = require "Common.Config.GameConfig"
local MultiplierProducts = require "Common.MultiplierProducts"
local MultiplierPurchaseService = { Name = "MultiplierPurchaseService", FeatureFlag = "MultiplierPurchase",
    Dependencies = { "PurchaseService", "EconomyService", "PlayerSpeedService", "TreadmillService", "RebirthService" } }
local kinds = { "Coin", "Training" }
local function Integer(n) return type(n) == "number" and n > 0 and n < math.huge and n == math.floor(n) end
function MultiplierPurchaseService:ValidateConfig()
    local goods, items = {}, {}
    for _, kind in ipairs(kinds) do
        local c = GameConfig.MultiplierPurchase[kind]
        for _, field in ipairs({ "ButtonId", "GroupId", "NextTextId", "CurrentTextId" }) do
            if not Integer(c[field]) then return false, { "倍率购买UI配置无效" } end
        end
        if #c.Products ~= 3 then return false, { "倍率商品需要三档" } end
        local targets = kind == "Coin" and { 2, 3, 4 } or { 5, 10, 20 }
        for i, row in ipairs(c.Products) do
            if row.Multiplier ~= targets[i] or not Integer(row.GoodsId) or type(row.ItemId) ~= "string" or row.ItemId == ""
                or goods[row.GoodsId] or items[row.ItemId] then return false, { "倍率商品配置无效" } end
            goods[row.GoodsId], items[row.ItemId] = true, true
        end
    end
    return true
end
function MultiplierPurchaseService:Start(context)
    if context.Side ~= "Server" then return end
    local economy, speed, purchase = context.Services.EconomyService, context.Services.PlayerSpeedService, context.Services.PurchaseService
    local rebirth, treadmill, persistence = context.Services.RebirthService, context.Services.TreadmillService, context.Services.PersistenceService
    local messages, config = context.NetMsg.Messages, GameConfig.MultiplierPurchase
    local rt = { Active = true, Ready = false, Pending = {}, Halted = {}, Dead = {}, Revives = {}, Opens = {}, LastCommit = {}, Sent = {}, Version = 0, Receipt = 0 }
    context.Services.MultiplierPurchaseService = rt
    local function Active() return rt.Active and context.Services.MultiplierPurchaseService == rt end
    local function CanPlay(id) return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id)) end
    local function Protect(fn)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() fn((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Snapshot(id)
        if not CanPlay(id) then return nil end
        local s = speed:GetSnapshot(id)
        if not s or not economy:IsCurrent(id, s.sessionGeneration) then return nil end
        local coin = economy:GetCoinMultiplier(id)
        if not coin then return nil end
        return { sessionGeneration = s.sessionGeneration, coinMultiplier = coin, finalCoinMultiplier = economy:GetFinalCoinMultiplier(id),
            trainingPurchaseMultiplier = s.trainingPurchaseMultiplier, trainingMultiplier = s.trainingMultiplier }
    end
    local function Send(id, force)
        if not rt.Ready then return false end
        local s = Snapshot(id) or {}
        local old = rt.Sent[id]
        if not force and old and old.sessionGeneration == s.sessionGeneration and old.coinMultiplier == s.coinMultiplier
            and old.finalCoinMultiplier == s.finalCoinMultiplier
            and old.trainingPurchaseMultiplier == s.trainingPurchaseMultiplier and old.trainingMultiplier == s.trainingMultiplier then return false end
        rt.Sent[id] = s
        rt.Version = rt.Version + 1; s.version = rt.Version
        System:SendToClient(id, messages.MultiplierPurchaseState, s)
        return true
    end
    local function CurrentMultiplier(s, kind) return kind == "Coin" and s.coinMultiplier or s.trainingPurchaseMultiplier end
    local function Result(id, kind, generation, success, reason, target, requestId, expectedMultiplier)
        rt.Receipt = rt.Receipt + 1
        System:SendToClient(id, messages.MultiplierPurchaseResult, { receipt = rt.Receipt, kind = kind,
            sessionGeneration = generation, success = success, reason = reason, target = target,
            requestId = requestId, expectedMultiplier = expectedMultiplier })
    end
    local Scan, Wake
    local function Schedule(id, pending, frame)
        if pending.scheduled then return end
        pending.scheduled = true
        local callback = Protect(function()
            if rt.Pending[id] ~= pending then return end
            pending.scheduled = nil; Scan(id, pending)
        end)
        if frame then context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, callback)
        else context.Timers:AddTimer(self.Name, 0.5, callback) end
    end
    Wake = function(id)
        if not rt.Ready or not Integer(id) then return end
        local s = Snapshot(id)
        if not s or rt.Halted[id] == s.sessionGeneration then return end
        local pending = rt.Pending[id]
        if not pending or pending.generation ~= s.sessionGeneration then pending = { generation = s.sessionGeneration }; rt.Pending[id] = pending end
        Schedule(id, pending, true)
    end
    local function Available(id, generation)
        if not Active() or rt.Dead[id] or not CanPlay(id) then return false, "session_unavailable" end
        local allowed, reason = economy:CanPurchaseMultiplier(id, generation)
        if not allowed then return false, reason end
        return treadmill:CanPurchaseMultiplier(id, generation)
    end
    Scan = function(id, pending)
        if rt.Dead[id] or not CanPlay(id) then return end
        local s = Snapshot(id)
        if not s or s.sessionGeneration ~= pending.generation then rt.Pending[id] = nil; return end
        if rt.Halted[id] == pending.generation then rt.Pending[id] = nil; return end
        for _, kind in ipairs(kinds) do
            local current = CurrentMultiplier(s, kind)
            local row = MultiplierProducts.Next(kind, current) -- 仅当前下一档；不扫描其他入口或提前购买档位。
            if row then
                local count, why = purchase:GetVoucherCount(id, pending.generation, row.ItemId)
                if count == nil then
                    rt.Halted[id] = pending.generation
                    Log:PrintError("[MultiplierPurchase] 核票失败，不自动重试", id, pending.generation, kind, tostring(why)); return
                end
                if count > 0 then
                    local allowed, reason = Available(id, pending.generation)
                    if not allowed then
                        if reason == "sale_batch_busy" or reason == "treadmill_busy" or reason == "treadmill_unavailable" then Schedule(id, pending) end
                        return
                    end
                    local lock, lockReason = rebirth:TryAcquirePurchaseLock(id, pending.generation)
                    if not lock then
                        if lockReason == "rebirth_busy" then Schedule(id, pending) end
                        return
                    end
                    local commit
                    local function Validate()
                        if not rebirth:IsPurchaseLockCurrent(id, pending.generation, lock) then return false, "purchase_lock_expired" end
                        local valid, rejection = Available(id, pending.generation)
                        if not valid then return false, rejection end
                        local now = Snapshot(id)
                        if not now or now.sessionGeneration ~= pending.generation or CurrentMultiplier(now, kind) ~= current then return false, "multiplier_changed" end
                        if kind == "Coin" then commit, rejection = economy:PrepareCoinMultiplierCommit(id, pending.generation, row.Multiplier)
                        else commit, rejection = speed:PrepareTrainingMultiplierCommit(id, pending.generation, row.Multiplier) end
                        return commit ~= nil, rejection
                    end
                    local ok, publish, consumed, operationId = purchase:ConsumeVoucher(id, pending.generation, row.ItemId, Validate, function()
                        if not rebirth:IsPurchaseLockCurrent(id, pending.generation, lock) then return false, "purchase_lock_expired" end
                        return commit()
                    end)
                    Log:PrintLog("[MultiplierPurchase] consume_commit", id, pending.generation, kind, row.Multiplier,
                        "operation:", tostring(operationId), "consumed:", tostring(consumed), "committed:", tostring(ok))
                    if not ok then
                        rebirth:ReleasePurchaseLock(id, lock)
                        if consumed == false and (publish == "sale_batch_busy" or publish == "treadmill_busy" or publish == "treadmill_unavailable" or publish == "voucher_busy") then
                            Schedule(id, pending)
                        elseif consumed == false and publish == "voucher_missing" then Schedule(id, pending, true)
                        else
                            rt.Halted[id] = pending.generation
                            Log:PrintError("[MultiplierPurchase] 未兑现，不补偿不重扣", id, pending.generation, kind, tostring(publish), tostring(consumed))
                        end
                        return
                    end
                    rt.LastCommit[id] = { generation = pending.generation, archiveGeneration = persistence and persistence:GetState(id).generation,
                        kind = kind, target = row.Multiplier, operation = operationId }
                    local notified, err = pcall(publish)
                    if not notified then Log:PrintError("[MultiplierPurchase] 提交后通知异常，不重兑", id, kind, tostring(err)) end
                    rebirth:ReleasePurchaseLock(id, lock)
                    Send(id); Result(id, kind, pending.generation, true, "multiplier_purchased", row.Multiplier)
                    Schedule(id, pending, true)
                    return
                end
            end
        end
        rt.Pending[id] = nil
    end
    rt.Open = Protect(function(_, request, id)
        if not rt.Ready or not Integer(id) or type(request) ~= "table" or not config[request.kind]
            or not Integer(request.requestId) or not Integer(request.sessionGeneration) or not Integer(request.expectedMultiplier) then return end
        local function Reject(reason)
            Result(id, request.kind, request.sessionGeneration, false, reason, nil, request.requestId, request.expectedMultiplier)
        end
        local s = Snapshot(id)
        if not s or s.sessionGeneration ~= request.sessionGeneration then Reject("session_unavailable"); return end
        local previous = rt.Opens[id]
        if not previous or previous.generation ~= s.sessionGeneration then previous = { generation = s.sessionGeneration, id = 0 }; rt.Opens[id] = previous end
        if request.requestId <= previous.id then Reject("stale_request"); return end
        previous.id = request.requestId
        local current = CurrentMultiplier(s, request.kind)
        local row = MultiplierProducts.Next(request.kind, current)
        if not row then Reject("multiplier_max"); return end
        if rt.Dead[id] then Reject("session_unavailable"); return end
        if current ~= request.expectedMultiplier then Send(id, true); Reject("stale_multiplier"); return end
        System:SendToClient(id, messages.MultiplierPurchaseOffer, { kind = request.kind, requestId = request.requestId,
            sessionGeneration = s.sessionGeneration, expectedMultiplier = current, goodsId = row.GoodsId })
    end)
    rt.Check = Protect(function(_, request, id) if type(request) == "table" and next(request) == nil then Wake(id) end end)
    rt.Snapshot = Protect(function(_, request, id) if Integer(id) and type(request) == "table" and next(request) == nil then Send(id, true) end end)
    rt.GetItem = Protect(function(id, itemId, _, custom)
        if custom ~= true then return end
        for _, kind in ipairs(kinds) do for _, row in ipairs(config[kind].Products) do if row.ItemId == itemId then Wake(id); return end end end
    end)
    rt.Leave = Protect(function(id) rt.Pending[id] = nil; rt.Opens[id] = nil; rt.Dead[id] = nil; rt.Revives[id] = nil; rt.Sent[id] = nil end)
    rt.Death = Protect(function(id) rt.Dead[id] = true; rt.Revives[id] = nil end)
    rt.Revive = Protect(function(id)
        rt.Dead[id] = nil
        local generation = economy:GetSessionGeneration(id); if not generation then return end
        local token = {}; rt.Revives[id] = token
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            if rt.Revives[id] ~= token or rt.Dead[id] or not economy:IsCurrent(id, generation) then return end
            rt.Revives[id] = nil; Wake(id)
        end))
    end)
    rt.Bindings = { { Events.ON_PLAYER_GET_ITEM, rt.GetItem }, { Events.ON_PLAYER_PRELEAVE, rt.Leave }, { Events.ON_PLAYER_RECONNECTED, rt.Leave },
        { Events.ON_CHARACTER_KILLED, rt.Death }, { Events.ON_CHARACTER_DESTROYED, rt.Death },
        { Events.ON_CHARACTER_REVIVED, rt.Revive }, { Events.ON_CHARACTER_RESPAWN, rt.Revive } }
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    rt.Notifies = { { messages.MultiplierPurchaseOpen, rt.Open }, { messages.MultiplierVoucherCheck, rt.Check }, { messages.MultiplierPurchaseSnapshotRequest, rt.Snapshot } }
    for _, binding in ipairs(rt.Notifies) do System:BindNotify(binding[1], binding[2]) end
    context.Events:Subscribe(self.Name, "PersistenceReady", Protect(function(data) Send(data.playerId); Wake(data.playerId) end))
    for _, event in ipairs({ "EconomyChanged", "PlayerSpeedChanged" }) do
        context.Events:Subscribe(self.Name, event, Protect(function(data)
            if Send(data.playerId) then Wake(data.playerId) end
        end))
    end
    context.Events:Subscribe(self.Name, "TreadmillLevelChanged", Protect(function(data)
        Send(data.playerId)
        if rt.Pending[data.playerId] then Wake(data.playerId) end
    end))
    context.Events:Subscribe(self.Name, "PersistenceStateChanged", Protect(function(data)
        local last = rt.LastCommit[data.playerId]
        if last and data.generation == last.archiveGeneration and data.state:find("save_failed", 1, true) then
            Log:PrintError("[MultiplierPurchase] 提交后存档失败，不重新扣物", data.playerId, last.generation, last.kind, last.target, last.operation, data.reason)
        end
    end))
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function()
        rt.Ready = true
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Send(id); Wake(id) end
    end))
end
function MultiplierPurchaseService:Stop(context)
    local rt = context.Services.MultiplierPurchaseService
    if not rt then return end
    rt.Active = false; rt.Pending = {}; rt.Revives = {}
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    for _, binding in ipairs(rt.Notifies) do System:UnbindNotify(binding[1], binding[2]) end
    context.Events:UnsubscribeOwner(self.Name); context.Timers:RemoveOwner(self.Name)
    context.Services.MultiplierPurchaseService = nil
end
return MultiplierPurchaseService
