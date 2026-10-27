local GameConfig = require "Common.Config.GameConfig"
local RebirthService = { Name = "RebirthService", FeatureFlag = "Rebirth",
    Dependencies = { "PlayerSpeedService", "TreadmillService", "EconomyService", "HomeService", "PurchaseService" } }
local function Integer(value, zero)
    return type(value) == "number" and value >= (zero and 0 or 1) and value < math.huge and value == math.floor(value)
end
function RebirthService:ValidateConfig()
    local c = GameConfig.RebirthPurchase
    if GameConfig.Rebirth.MaxCount ~= 20 or not c or not Integer(c.ButtonId) or type(c.Products) ~= "table"
        or #c.Products ~= 20 then return false, { "重生商品需要完整20档" } end
    local goods, items = {}, {}
    for i, row in ipairs(c.Products) do
        if row.Count ~= i - 1 or not Integer(row.GoodsId) or type(row.ItemId) ~= "string" or row.ItemId == ""
            or goods[row.GoodsId] or items[row.ItemId] then return false, { "重生商品配置无效: " .. i } end
        goods[row.GoodsId], items[row.ItemId] = true, true
    end
    return true
end
function RebirthService:Start(context)
    if context.Side ~= "Server" then return end
    local speed, treadmill = context.Services.PlayerSpeedService, context.Services.TreadmillService
    local economy, home, messages = context.Services.EconomyService, context.Services.HomeService, context.NetMsg.Messages
    local purchase, products = context.Services.PurchaseService, GameConfig.RebirthPurchase.Products
    local rt = { Active = true, Ready = false, Locks = {}, Requests = {}, Opens = {}, Dead = {}, Revives = {}, Pending = {},
        Halted = {}, Faulted = {}, LastPaid = {}, Version = 0, Receipt = 0 }
    context.Services.RebirthService = rt
    local persistence = context.Services.PersistenceService
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id))
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
        local s = speed:GetSnapshot(id)
        rt.Version = rt.Version + 1
        System:SendToClient(id, messages.RebirthState, { version = rt.Version,
            sessionGeneration = s and s.sessionGeneration, expectedCount = s and s.rebirthCount,
            redeemedMask = s and s.redeemedMask, experience = s and s.experience,
            requirement = s and s.rebirthRequirement, multiplier = s and s.multiplier,
            nextMultiplier = s and s.nextMultiplier, busy = rt.Locks[id] ~= nil })
    end
    local function Result(id, request, success, reason)
        if request and Active() then
            System:SendToClient(id, messages.RebirthResult, { requestId = request.requestId,
                sessionGeneration = request.sessionGeneration, expectedCount = request.expectedCount, success = success, reason = reason })
        end
    end
    local function Cancel(id)
        local lock = rt.Locks[id]; rt.Locks[id] = nil
        if lock then lock.invalid = true; if lock.token then treadmill:CancelReset(id, lock.token) end end
    end
    local Wake, StartRebirth, Scan
    local function Schedule(id, pending, frames)
        local callback = Protect(function()
            if rt.Pending[id] ~= pending then return end
            pending.scheduled = nil
            Scan(id, pending)
        end)
        if pending.scheduled then return end
        pending.scheduled = true
        if frames then context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, callback)
        else context.Timers:AddTimer(self.Name, 0.5, callback) end
    end
    Wake = function(id)
        if not rt.Ready or not Integer(id) or not CanPlay(id) then return end
        local s = speed:GetSnapshot(id)
        if not s or not economy:IsCurrent(id, s.sessionGeneration) then return end
        local generation = s.sessionGeneration
        if rt.Faulted[id] == generation or rt.Halted[id] == generation then return end
        local pending = rt.Pending[id]
        if not pending or pending.generation ~= generation then pending = { generation = generation }; rt.Pending[id] = pending end
        Schedule(id, pending, true)
    end
    local function Eligible(id, lock)
        return Active() and rt.Ready and rt.Locks[id] == lock and not lock.invalid and not rt.Dead[id]
            and CanPlay(id) and economy:IsCurrent(id, lock.generation) and home:IsOwner(id, lock.homeId)
    end
    -- 倍率购买复用实际重生锁；不在弹窗期间持锁，也不暴露可写锁表给协调方。
    function rt:TryAcquirePurchaseLock(id, generation)
        if not Active() or not self.Ready or not CanPlay(id) or not economy:IsCurrent(id, generation) or self.Dead[id] then
            return nil, "session_unavailable"
        end
        if self.Locks[id] then return nil, "rebirth_busy" end
        local token = { generation = generation, multiplierPurchase = true }
        self.Locks[id] = token
        return token
    end
    function rt:IsPurchaseLockCurrent(id, generation, token)
        return Active() and self.Locks[id] == token and token.multiplierPurchase == true and not token.invalid
            and not self.Dead[id] and economy:IsCurrent(id, generation)
    end
    function rt:ReleasePurchaseLock(id, token)
        if self.Locks[id] ~= token then return end
        self.Locks[id] = nil
        if self.Pending[id] then Wake(id) end
    end
    StartRebirth = function(id, generation, count, paidIndex, request)
        local homeId = home:GetPlayerHome(id)
        if not homeId or not home:IsOwner(id, homeId) then return false, "home_unavailable" end
        if rt.Dead[id] or rt.Locks[id] then return false, "rebirth_busy" end
        local allowed, reason = speed:CanRebirth(id, generation, count, paidIndex)
        if not allowed then return false, reason end
        local lock = { request = request, generation = generation, count = count, homeId = homeId, paidIndex = paidIndex }
        rt.Locks[id] = lock
        local function Fail(why, consumed)
            if paidIndex and consumed ~= nil and consumed ~= false then rt.Faulted[id] = generation end
            if rt.Locks[id] ~= lock then return end
            if paidIndex and consumed ~= true and consumed ~= "unknown" then
                if why ~= "treadmill_busy" and why ~= "treadmill_unavailable" and why ~= "sale_batch_busy"
                    and why ~= "voucher_missing" then rt.Halted[id] = generation end
            end
            Cancel(id); Result(id, request, false, why); Send(id)
            if why == "treadmill_busy" or why == "treadmill_unavailable" or why == "sale_batch_busy" then
                local pending = rt.Pending[id]
                if pending and pending.generation == generation then Schedule(id, pending) end
            else Wake(id) end
        end
        local function Finish(success, token)
            if not Active() or rt.Locks[id] ~= lock or lock.invalid then
                if success then treadmill:CancelReset(id, token) end
                return
            end
            if not success then Fail(token); return end
            lock.token = token
            local commitAll
            -- 所有引擎读取、成长门槛、售卖批次和模型状态校验都在最终扣物前完成。
            local function Validate()
                if not Eligible(id, lock) then return false, "session_unavailable" end
                local growth, why = speed:PrepareRebirthCommit(id, generation, count, paidIndex)
                if not growth then return false, why end
                local money; money, why = economy:PrepareRebirthReset(id, generation)
                if not money then return false, why end
                commitAll, why = treadmill:PrepareResetCommit(id, generation, token, function()
                    -- 此段只提交Lua状态；通知、引擎应用与存档调度统一延后。
                    local okMoney, publishMoney = money()
                    if not okMoney then return false, publishMoney end
                    local okGrowth, publishGrowth = growth()
                    if not okGrowth then return false, publishGrowth end
                    return true, function()
                        local ok, err = pcall(publishMoney)
                        if not ok then Log:PrintError("[Rebirth] 钱币提交后通知异常", tostring(err)) end
                        publishGrowth()
                    end
                end)
                if not commitAll then return false, why end
                return true
            end
            local committed, publish, consumed
            if paidIndex then
                local operationId
                committed, publish, consumed, operationId = purchase:ConsumeVoucher(id, generation, products[paidIndex].ItemId,
                    Validate, function() return commitAll() end)
                Log:PrintLog("[RebirthPurchase] consume_commit", "playerId:", id, "generation:", generation,
                    "product:", paidIndex, "operation:", tostring(operationId), "consumed:", tostring(consumed), "committed:", tostring(committed))
            else
                local valid, why = Validate()
                if not valid then Fail(why); return end
                committed, publish = commitAll()
            end
            if not committed then Fail(publish, consumed); return end
            local signOk, signError = pcall(function() System:FireSignEvent("重生成功", { id }) end)
            if not signOk then Log:PrintError("[Rebirth] 重生成功信号发送失败", id, tostring(signError)) end
            if paidIndex then rt.LastPaid[id] = { generation = generation, product = paidIndex,
                archiveGeneration = persistence and persistence:GetState(id).generation } end
            -- 全部业务状态已提交，仍持锁直到通知结束；扣物与平台存档不是原子事务。
            local ok, err = pcall(publish)
            if not ok then Log:PrintError("[Rebirth] 提交后通知异常，不重试", id, tostring(err)) end
            if persistence and CanPlay(id) then persistence:MarkDirty(id, paidIndex and "paid_rebirth" or "rebirth") end
            if not Active() or rt.Locks[id] ~= lock then return end
            rt.Locks[id] = nil
            Send(id); Result(id, request, true, "reborn")
            if paidIndex then
                rt.Receipt = rt.Receipt + 1
                System:SendToClient(id, messages.RebirthPurchaseResult, { sessionGeneration = generation,
                    receipt = rt.Receipt, productIndex = paidIndex, count = count + 1, success = true })
            end
            Wake(id)
        end
        local started, token = treadmill:PrepareReset(id, generation, Finish)
        if not started then Fail(token); return false, token, true end
        if rt.Locks[id] == lock then lock.token = token; Send(id) end
        return true
    end
    Scan = function(id, pending)
        if not CanPlay(id) or rt.Dead[id] then return end -- 保留待兑现，读档/复活重新唤醒。
        local s = speed:GetSnapshot(id)
        if not s or s.sessionGeneration ~= pending.generation or not economy:IsCurrent(id, pending.generation) then
            rt.Pending[id] = nil; return
        end
        if rt.Faulted[id] == pending.generation or rt.Halted[id] == pending.generation then rt.Pending[id] = nil; return end
        if s.rebirthCount >= GameConfig.Rebirth.MaxCount then rt.Pending[id] = nil; return end
        if rt.Locks[id] then Schedule(id, pending); return end
        for index, row in ipairs(products) do
            if not speed:HasRedeemed(id, index) then
                local count, reason = purchase:GetVoucherCount(id, pending.generation, row.ItemId)
                if count == nil then
                    rt.Pending[id] = nil; rt.Halted[id] = pending.generation
                    Log:PrintError("[RebirthPurchase] 核票失败，保留凭证", id, pending.generation, tostring(reason)); return
                end
                if count > 0 then
                    local started, why = StartRebirth(id, pending.generation, s.rebirthCount, index)
                    if not started then
                        if why == "rebirth_busy" or why == "home_unavailable" or why == "treadmill_busy" or why == "treadmill_unavailable" then
                            Schedule(id, pending)
                        end
                    end
                    return
                end
            end
        end
        rt.Pending[id] = nil
    end
    local function RequestValid(request, id)
        return rt.Ready and CanPlay(id) and Integer(id) and type(request) == "table" and Integer(request.requestId)
            and Integer(request.sessionGeneration) and Integer(request.expectedCount, true) and request.expectedCount <= GameConfig.Rebirth.MaxCount
    end
    rt.Action = Protect(function(_, request, id)
        if not RequestValid(request, id) then return end
        local s = speed:GetSnapshot(id)
        if not s or s.sessionGeneration ~= request.sessionGeneration or not economy:IsCurrent(id, request.sessionGeneration) then
            Result(id, request, false, "session_unavailable"); return
        end
        local previous = rt.Requests[id]
        if previous and previous.generation == request.sessionGeneration and request.requestId <= previous.id then
            Result(id, request, false, "stale_request"); return
        end
        rt.Requests[id] = { generation = request.sessionGeneration, id = request.requestId }
        local started, reason, handled = StartRebirth(id, request.sessionGeneration, request.expectedCount, nil, request)
        if not started and not handled then Result(id, request, false, reason); Send(id) end
    end)
    rt.Open = Protect(function(_, request, id)
        if not RequestValid(request, id) then return end
        local s = speed:GetSnapshot(id)
        if not s or s.sessionGeneration ~= request.sessionGeneration or s.rebirthCount ~= request.expectedCount
            or not economy:IsCurrent(id, request.sessionGeneration) or rt.Dead[id] then return end
        local previous = rt.Opens[id]
        if previous and previous.generation == request.sessionGeneration and request.requestId <= previous.id then return end
        rt.Opens[id] = { generation = request.sessionGeneration, id = request.requestId }
        local index = s.rebirthCount + 1
        local row = products[index]
        if not row or speed:HasRedeemed(id, index) then return end
        System:SendToClient(id, messages.RebirthPurchaseOffer, { requestId = request.requestId,
            sessionGeneration = request.sessionGeneration, expectedCount = s.rebirthCount, goodsId = row.GoodsId, productIndex = index })
    end)
    rt.Check = Protect(function(_, request, id)
        if type(request) == "table" and next(request) == nil then Wake(id) end
    end)
    rt.Snapshot = Protect(function(_, request, id)
        if rt.Ready and Integer(id) and type(request) == "table" and next(request) == nil then Send(id) end
    end)
    rt.Leave = Protect(function(id)
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(id) end
        Cancel(id); rt.Requests[id] = nil; rt.Opens[id] = nil; rt.Pending[id] = nil; rt.Dead[id] = nil; rt.Revives[id] = nil
    end)
    rt.Death = Protect(function(id) rt.Dead[id] = true; rt.Revives[id] = nil; Cancel(id); if rt.Ready then Send(id) end end)
    rt.Revive = Protect(function(id)
        rt.Dead[id] = nil
        local generation = economy:GetSessionGeneration(id)
        if not generation then return end
        local token = {}; rt.Revives[id] = token
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            if rt.Revives[id] ~= token or rt.Dead[id] or not economy:IsCurrent(id, generation) then return end
            rt.Revives[id] = nil
            if rt.Halted[id] == generation then rt.Halted[id] = nil end
            Wake(id)
        end))
    end)
    rt.GetItem = Protect(function(id, itemId, _, isCustom)
        if isCustom ~= true then return end
        for _, row in ipairs(products) do if row.ItemId == itemId then Wake(id); return end end
    end)
    rt.Bindings = { { Events.ON_PLAYER_PRELEAVE, rt.Leave }, { Events.ON_PLAYER_RECONNECTED, rt.Leave },
        { Events.ON_CHARACTER_KILLED, rt.Death }, { Events.ON_CHARACTER_DESTROYED, rt.Death },
        { Events.ON_CHARACTER_RESPAWN, rt.Revive }, { Events.ON_CHARACTER_REVIVED, rt.Revive }, { Events.ON_PLAYER_GET_ITEM, rt.GetItem } }
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    rt.Notifies = { { messages.RebirthAction, rt.Action }, { messages.RebirthSnapshotRequest, rt.Snapshot },
        { messages.RebirthPurchaseOpen, rt.Open }, { messages.RebirthVoucherCheck, rt.Check } }
    for _, binding in ipairs(rt.Notifies) do System:BindNotify(binding[1], binding[2]) end
    context.Events:Subscribe(self.Name, "PlayerSpeedChanged", Protect(function(data)
        local lock = rt.Locks[data.playerId]
        if lock and lock.generation ~= data.sessionGeneration then Cancel(data.playerId) end
        Send(data.playerId)
    end))
    context.Events:Subscribe(self.Name, "HomeReleased", Protect(function(data) Cancel(data.playerId); rt.Pending[data.playerId] = nil end))
    context.Events:Subscribe(self.Name, "PersistenceReady", Protect(function(data) Wake(data.playerId) end))
    context.Events:Subscribe(self.Name, "PersistenceStateChanged", Protect(function(data)
        local paid = rt.LastPaid[data.playerId]
        if paid and (data.state == "save_failed" or data.state == "leave_save_failed" or data.state == "previous_session_save_failed")
            and data.generation == paid.archiveGeneration then
            Log:PrintError("[RebirthPurchase] 已提交后的存档失败，不重扣凭证", data.playerId, paid.generation, paid.product, tostring(data.reason))
        end
    end))
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function()
        rt.Ready = true
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Send(id); Wake(id) end
    end))
    rt.Cleanup = function()
        rt.Active = false
        local ids = {}; for id in pairs(rt.Locks) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do Cancel(id) end
        rt.Pending = {}; rt.Requests = {}; rt.Opens = {}
    end
end
function RebirthService:Stop(context)
    local rt = context.Services.RebirthService
    if not rt then return end
    rt.Cleanup()
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    for _, binding in ipairs(rt.Notifies) do System:UnbindNotify(binding[1], binding[2]) end
    context.Events:UnsubscribeOwner(self.Name); context.Timers:RemoveOwner(self.Name)
    context.Services.RebirthService = nil
end
return RebirthService
