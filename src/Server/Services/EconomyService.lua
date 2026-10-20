-- 在线会话钱币唯一所有者；由存档协调方导出/恢复，离开前统一冻结快照。
local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local EconomyService = { Name = "EconomyService", FeatureFlag = "SellShop", Dependencies = { "InventoryService" } }
local function Integer(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value == math.floor(value)
end
function EconomyService:ValidateConfig()
    return true
end
function EconomyService:Start(context)
    if context.Side ~= "Server" then return end
    local runtime = { Active = true, Sessions = {}, Departed = {}, Generation = 0 }
    context.Services.EconomyService = runtime
    local function Active() return runtime.Active and context.Services.EconomyService == runtime end
    local function CanMutate(playerId)
        if not GameConfig.Persistence.ProductionEnabled then return true end
        local persistence = context.Services.PersistenceService
        return persistence ~= nil and persistence:IsReady(playerId)
    end
    function runtime:BeginLoadSession(playerId)
        self.Generation = self.Generation + 1
        self.Departed[playerId] = nil
        self.Sessions[playerId] = { generation = self.Generation, balance = "0" }
        return self.Generation
    end
    function runtime:ClearPlayer(playerId)
        local persistence = context.Services.PersistenceService
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(playerId) end
        self.Departed[playerId], self.Sessions[playerId] = true, nil
    end
    function runtime:GetSessionGeneration(playerId)
        if not Active() then return nil end
        local session = self.Sessions[playerId]
        return session and session.generation or nil
    end
    function runtime:IsCurrent(playerId, generation)
        local session = self.Sessions[playerId]
        return Active() and session ~= nil and session.generation == generation and not self.Departed[playerId]
    end
    function runtime:GetBalance(playerId)
        local session = Active() and self.Sessions[playerId] or nil
        return session and session.balance or nil
    end
    function runtime:ExportSnapshot(playerId, generation)
        if not self:IsCurrent(playerId, generation) then return nil, "session_unavailable" end
        return { version = 1, balance = self:GetBalance(playerId) }
    end
    function runtime:RestoreSnapshot(playerId, generation, snapshot)
        if not self:IsCurrent(playerId, generation) then return false, "session_unavailable" end
        if type(snapshot) ~= "table" or snapshot.version ~= 1 or not Decimal.IsValid(snapshot.balance) then
            return false, "invalid_economy_snapshot"
        end
        local session = self.Sessions[playerId]
        if session.restored or session.balance ~= "0" then return false, "economy_not_pristine" end
        session.balance, session.restored = snapshot.balance, true
        local notified = false
        return true, function()
            if notified then return false, "already_notified" end
            notified = true
            if not self:IsCurrent(playerId, generation) then return false, "session_unavailable" end
            local ok, err = pcall(function()
                context.Events:Publish("EconomyChanged", { playerId = playerId, sessionGeneration = generation, balance = session.balance })
            end)
            if not ok then return false, "notification_failed:" .. tostring(err) end
            return true
        end
    end
    -- 金额由SellShop从权威物品读取；出售入账和升级扣款均由本模块修改余额。
    -- 扣库存和加钱之间没有事件、引擎调用或等待；发布通知时两者已提交。
    function runtime:SettleSale(playerId, generation, inventory, itemId, amount)
        if not CanMutate(playerId) then return false, "persistence_not_ready" end
        if not self:IsCurrent(playerId, generation) or context.Services.InventoryService ~= inventory then
            return false, "session_unavailable"
        end
        local session = self.Sessions[playerId]
        local amountText = Decimal.FromSafeInteger(amount)
        if not amountText then
            return false, "invalid_sale_amount"
        end
        local newBalance = Decimal.Add(session.balance, amountText)
        local removed, publish = inventory:RemoveItem(playerId, itemId, "sell_item", true)
        if not removed then return false, publish end
        session.balance = newBalance
        -- 后续发布异常不改变已经配对的结算，也不允许调用方重试。
        local ok, err = pcall(publish)
        if not ok then Log:PrintError("[EconomyService] 结算后库存通知失败", "playerId:", playerId, "itemId:", itemId, "error:", tostring(err)) end
        if self:IsCurrent(playerId, generation) then
            local notified, notifyError = pcall(function()
                context.Events:Publish("EconomyChanged", { playerId = playerId, sessionGeneration = generation, balance = session.balance })
            end)
            if not notified then Log:PrintError("[EconomyService] 结算后余额通知失败", "playerId:", playerId, "itemId:", itemId, "error:", tostring(notifyError)) end
        end
        return true
    end
    -- 测试金额只取服务端配置；请求去重及操作锁由出售入口管理。
    function runtime:AddTestMoney(playerId, generation)
        if GameConfig.SellShop.TestMoneyEnabled ~= true then return false, "test_money_disabled" end
        if not Active() or not self:IsCurrent(playerId, generation) then return false, "session_unavailable" end
        if not CanMutate(playerId) then return false, "persistence_not_ready" end
        local online = false
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do if id == playerId then online = true; break end end
        if not online then return false, "player_offline" end
        local amount = GameConfig.SellShop.TestMoneyAmount
        if not Decimal.IsValid(amount) or amount == "0" then return false, "invalid_test_amount" end
        local session = self.Sessions[playerId]
        session.balance = Decimal.Add(session.balance, amount)
        -- 提交之后通知失败不回滚，也不把本次请求变成可重试的未提交操作。
        local ok, err = pcall(function()
            context.Events:Publish("EconomyChanged", { playerId = playerId, sessionGeneration = generation, balance = session.balance })
        end)
        if not ok then Log:PrintError("[EconomyService] 测试加钱后通知失败，不重试", "playerId:", playerId, "error:", tostring(err)) end
        return true, amount
    end
    -- 升级方在本调用成功后无等待提交等级，再调用返回的单次通知函数。
    -- 已提交扣款不因通知失败回滚；调用方不得因通知失败重新扣款。
    function runtime:TryDebit(playerId, generation, amount)
        if not CanMutate(playerId) then return false, "persistence_not_ready" end
        if not Integer(playerId) or playerId == 0 or not Integer(generation) or generation == 0
            or not self:IsCurrent(playerId, generation) then return false, "session_unavailable" end
        if not Decimal.IsValid(amount) then return false, "invalid_debit_amount" end
        local session = self.Sessions[playerId]
        local balance, reason = Decimal.Subtract(session.balance, amount)
        if not balance then return false, reason end
        session.balance = balance
        local published = false
        return true, function()
            if published then return false, "already_notified" end
            published = true
            if not self:IsCurrent(playerId, generation) then return false, "session_unavailable" end
            local ok, err = pcall(function()
                context.Events:Publish("EconomyChanged", { playerId = playerId, sessionGeneration = generation,
                    balance = session.balance })
            end)
            if not ok then
                Log:PrintError("[EconomyService] 扣款后余额通知失败，不重试", "playerId:", playerId,
                    "sessionGeneration:", generation, "error:", tostring(err))
                return false, "notification_failed"
            end
            return true
        end
    end
    local function Join(playerId, reset)
        if not Active() or not Integer(playerId) or playerId == 0 then return end
        if runtime.Sessions[playerId] and not reset then return end
        runtime.Departed[playerId] = nil
        runtime.Generation = runtime.Generation + 1
        runtime.Sessions[playerId] = { generation = runtime.Generation, balance = "0" }
        context.Events:Publish("EconomyChanged", { playerId = playerId, sessionGeneration = runtime.Generation, balance = "0" })
    end
    runtime.EnterCallback = function(playerId) Join(playerId, false) end
    runtime.ReconnectCallback = function(playerId)
        runtime:ClearPlayer(playerId)
        Join(playerId, true)
    end
    runtime.LeaveCallback = function(playerId)
        if not Active() then return end
        runtime:ClearPlayer(playerId)
    end
    System:RegisterEvent(Events.ON_PLAYER_ENTER, runtime.EnterCallback)
    System:RegisterEvent(Events.ON_PLAYER_JOIN_MIDWAY, runtime.EnterCallback)
    System:RegisterEvent(Events.ON_PLAYER_RECONNECTED, runtime.ReconnectCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if not Active() then return end
        for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do
            if not runtime.Departed[playerId] then Join(playerId, false) end
        end
    end)
end
function EconomyService:Stop(context)
    local runtime = context.Services.EconomyService
    if not runtime then return end
    runtime.Active = false
    runtime.Sessions = {}
    System:UnregisterEvent(Events.ON_PLAYER_ENTER, runtime.EnterCallback)
    System:UnregisterEvent(Events.ON_PLAYER_JOIN_MIDWAY, runtime.EnterCallback)
    System:UnregisterEvent(Events.ON_PLAYER_RECONNECTED, runtime.ReconnectCallback)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.EconomyService = nil
end
return EconomyService
