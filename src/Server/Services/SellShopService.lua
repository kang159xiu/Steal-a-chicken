local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local SellShopService = { Name = "SellShopService", FeatureFlag = "SellShop", Dependencies = { "InventoryService", "EconomyService" } }
local function Integer(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value == math.floor(value)
end
function SellShopService:ValidateConfig()
    local c = GameConfig.SellShop
    local errors = {}
    if type(c) == "table" and c.TestMoneyEnabled == true then
        if not Integer(c.TestMoneyButtonId) or c.TestMoneyButtonId == 0
            or not Decimal.IsValid(c.TestMoneyAmount) or c.TestMoneyAmount == "0" then
            errors[#errors + 1] = "测试加钱按钮或金额配置无效"
        end
    end
    for _, key in ipairs({ "EggListId", "ChickenListId", "TemplateId", "ImageId", "PriceTextId",
        "AppearanceButtonId", "SelectedBorderId", "SellAllEggsButtonId", "SellAllChickensButtonId", "BalanceTextId" }) do
        if not c or not Integer(c[key]) or c[key] == 0 then errors[#errors + 1] = "SellShop." .. key .. " 必须是正整数" end
    end
    for typeId, config in pairs(GameConfig.ChickenTypes) do
        if config.Enabled and not Decimal.FromSafeInteger(config.ChickenSellPrice) then errors[#errors + 1] = typeId .. " 鸡售价无效" end
    end
    return #errors == 0, errors
end
function SellShopService:Start(context)
    if context.Side ~= "Server" then return end
    local inventory, economy = context.Services.InventoryService, context.Services.EconomyService
    local messages = context.NetMsg.Messages
    local runtime = { Active = true, States = {} }
    context.Services.SellShopService = runtime
    local function Active() return runtime.Active and context.Services.SellShopService == runtime end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function State(playerId)
        local generation = economy:GetSessionGeneration(playerId)
        if not generation then return nil end
        local state = runtime.States[playerId]
        if not state or state.generation ~= generation then
            state = { generation = generation, version = 0, lastRequestId = 0, busy = false }
            runtime.States[playerId] = state
        end
        return state
    end
    local function Current(playerId, state)
        return Active() and state and runtime.States[playerId] == state and economy:IsCurrent(playerId, state.generation)
    end
    local function SendState(playerId)
        if not Active() then return end
        local state = State(playerId)
        if not Current(playerId, state) then return end
        if state.batchSync then return end
        local chickens, eggs = {}, {}
        for _, item in ipairs(inventory:GetSnapshot(playerId)) do
            local price = economy:GetSalePrice(playerId, item)
            if price ~= nil then
                local row = { itemId = item.itemId, kind = item.kind, typeId = item.typeId,
                    iconIndex = item.iconIndex, sequence = item.sequence, count = 1, sellPrice = price }
                local list = item.kind == "Chicken" and chickens or eggs
                list[#list + 1] = row
            end
        end
        local function Sort(a, b) return a.sequence < b.sequence end
        table.sort(chickens, Sort); table.sort(eggs, Sort)
        state.version = state.version + 1
        System:SendToClient(playerId, messages.SellShopState, { sessionGeneration = state.generation,
            version = state.version, balance = economy:GetBalance(playerId), chickens = chickens, eggs = eggs })
    end
    runtime.SnapshotCallback = Protect(function(_, message, playerId)
        if Integer(playerId) and playerId > 0 and type(message) == "table" then SendState(playerId) end
    end)
    runtime.ActionCallback = Protect(function(_, message, playerId)
        if not Integer(playerId) or playerId == 0 or type(message) ~= "table"
            or not Integer(message.sessionGeneration) or not Integer(message.requestId) or message.requestId == 0
            or (message.action ~= "single" and message.action ~= "all_chickens" and message.action ~= "all_eggs" and message.action ~= "test_add_money")
            or (message.action == "single" and (type(message.itemId) ~= "string" or message.itemId == "")) then return end
        local state = State(playerId)
        if not Current(playerId, state) then return end
        local function Result(success, reason, results, total)
            if not Current(playerId, state) then return end
            System:SendToClient(playerId, messages.SellShopResult, { sessionGeneration = message.sessionGeneration,
                requestId = message.requestId, action = message.action, itemId = message.itemId,
                success = success, reason = reason, results = results or {}, total = total or "0",
                balance = economy:GetBalance(playerId) })
        end
        if message.sessionGeneration ~= state.generation then Result(false, "stale_session"); return end
        if message.requestId <= state.lastRequestId then Result(false, "stale_request"); return end
        state.lastRequestId = message.requestId
        if state.busy then Result(false, "sale_busy"); return end
        if message.action == "test_add_money" then
            state.busy = true
            local called, credited, reason = pcall(function() return economy:AddTestMoney(playerId, state.generation) end)
            state.busy = false
            if not called then
                Log:PrintError("[SellShopService] 测试加钱异常，不重试", "playerId:", playerId, "requestId:", message.requestId, "error:", tostring(credited))
                Result(false, "test_money_exception")
            else
                if not credited then Log:PrintWarning("[SellShopService] 测试加钱拒绝", "playerId:", playerId, "requestId:", message.requestId, "reason:", tostring(reason)) end
                Result(credited, credited and "test_money_added" or reason, {}, credited and reason or "0")
            end
            return
        end
        -- 固定接收时的集合；新入库不加入，失败项不重试，成功项不回滚。
        local batch = {}
        if message.action == "single" then batch[1] = { itemId = message.itemId }
        else
            local kind = message.action == "all_chickens" and "Chicken" or "Egg"
            for _, item in ipairs(inventory:GetSnapshot(playerId)) do
                if item.kind == kind then batch[#batch + 1] = item end
            end
            table.sort(batch, function(a, b) return a.sequence < b.sequence end)
        end
        state.busy = true
        local finishInventory, finishEconomy
        if message.action ~= "single" then
            local reason
            finishInventory, reason = inventory:BeginChangeBatch(playerId)
            if not finishInventory then state.busy = false; Result(false, reason); return end
            finishEconomy, reason = economy:BeginSaleBatch(playerId, state.generation)
            if not finishEconomy then pcall(finishInventory); state.busy = false; Result(false, reason); return end
            state.batchSync = true
        end
        local results, total, success = {}, "0", true
        local ok, err = pcall(function()
            for _, candidate in ipairs(batch) do
                if not Current(playerId, state) then return end
                local price
                local called, sold, reason = pcall(function()
                    local item = inventory:GetItem(playerId, candidate.itemId)
                    price = economy:GetSalePrice(playerId, item)
                    if not item then return false, "item_not_found" end
                    if price == nil then return false, "invalid_item_price" end
                    return economy:SettleSale(playerId, state.generation, inventory, item.itemId, price)
                end)
                if not called then
                    Log:PrintError("[SellShopService] 单项出售异常，不重试", "playerId:", playerId,
                        "requestId:", message.requestId, "itemId:", candidate.itemId, "error:", tostring(sold))
                    sold, reason = false, "sale_exception"
                end
                results[#results + 1] = { itemId = candidate.itemId, success = sold, reason = reason, sellPrice = sold and price or nil }
                if sold then total = Decimal.Add(total, price)
                else
                    success = false
                    Log:PrintWarning("[SellShopService] 出售失败", "playerId:", playerId,
                        "requestId:", message.requestId, "itemId:", candidate.itemId, "reason:", tostring(reason))
                end
            end
        end)

        -- 无论循环如何退出，都释放本批次；已提交资产不回滚或再次结算。
        local function Finish(callback, label)
            if not callback then return 0 end
            local finished, count = pcall(callback)
            if not finished then
                pcall(function() Log:PrintError("[SellShopService] 批次最终通知失败", "playerId:", playerId, "requestId:", message.requestId, "stage:", label, "error:", count) end)
                return 0
            end
            return count
        end
        Finish(finishInventory, "inventory")
        Finish(finishEconomy, "balance")
        state.batchSync = nil
        state.busy = false

        if finishInventory then
            if Current(playerId, state) then
                local sent, sendError = pcall(function() SendState(playerId) end)
                if not sent then pcall(function() Log:PrintError("[SellShopService] 批次最终通知失败", "playerId:", playerId, "requestId:", message.requestId, "stage:", "shop", "error:", sendError) end) end
            end
        end
        if not ok then
            Log:PrintError("[SellShopService] 出售批次异常，不重试", "playerId:", playerId,
                "requestId:", message.requestId, "error:", tostring(err))
            Result(false, "sale_exception", results, total)
        else Result(success, success and "sold" or "partial_failure", results, total) end
        if not finishInventory and Current(playerId, state) then SendState(playerId) end
    end)
    context.Events:Subscribe(self.Name, "InventoryChanged", function(snapshot)
        SendState(snapshot.playerId)
    end)
    context.Events:Subscribe(self.Name, "EconomyChanged", function(snapshot) SendState(snapshot.playerId) end)
    runtime.LeaveCallback = function(playerId)
        local persistence = context.Services.PersistenceService
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(playerId) end
        runtime.States[playerId] = nil
    end
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    System:BindNotify(messages.SellShopSnapshotRequest, runtime.SnapshotCallback)
    System:BindNotify(messages.SellShopAction, runtime.ActionCallback)
end
function SellShopService:Stop(context)
    local runtime = context.Services.SellShopService
    if not runtime then return end
    runtime.Active = false
    runtime.States = {}
    System:UnbindNotify(context.NetMsg.Messages.SellShopSnapshotRequest, runtime.SnapshotCallback)
    System:UnbindNotify(context.NetMsg.Messages.SellShopAction, runtime.ActionCallback)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Events:UnsubscribeOwner(self.Name)
    context.Services.SellShopService = nil
end
return SellShopService
