-- 平台自定义物品边界；不管理项目鸡蛋库存、商品映射、永久兑现记录或重生状态。
local GameConfig = require "Common.Config.GameConfig"
local PurchaseService = { Name = "PurchaseService", FeatureFlag = "Purchase", Dependencies = { "EconomyService" } }
local function Integer(n)
    return type(n) == "number" and n >= 0 and n <= 9007199254740991 and n == math.floor(n)
end
function PurchaseService:Start(context)
    if context.Side ~= "Server" then return end
    local economy = context.Services.EconomyService
    local runtime = { Active = true, Attempts = {} }
    context.Services.PurchaseService = runtime
    local function Current(playerId, generation)
        if not runtime.Active or context.Services.PurchaseService ~= runtime
            or context.Services.EconomyService ~= economy or not economy:IsCurrent(playerId, generation) then
            return false, "session_unavailable"
        end
        if GameConfig.Persistence.ProductionEnabled then
            local persistence = context.Services.PersistenceService
            if not persistence or not persistence:IsReady(playerId) then return false, "persistence_not_ready" end
        end
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do
            if id == playerId then return true end
        end
        return false, "player_offline"
    end
    -- 仅接收服务端商品配置中的完整字符串ID。平台数组可能按格拆分同种物品，累加合法自定义行。
    function runtime:GetVoucherCount(playerId, generation, itemId)
        if type(itemId) ~= "string" or itemId == "" then return nil, "invalid_voucher_id" end
        local valid, reason = Current(playerId, generation)
        if not valid then return nil, reason end
        local ok, items = pcall(function() return Inventory:GetAllItem(playerId) end)
        if not ok then return nil, "voucher_read_error:" .. tostring(items) end
        valid, reason = Current(playerId, generation)
        if not valid then return nil, reason end
        if type(items) ~= "table" then return nil, "invalid_platform_inventory" end
        local count = 0
        for _, item in pairs(items) do
            if type(item) ~= "table" then return nil, "invalid_platform_inventory" end
            if item.itemId == itemId then
                if item.isCustom ~= true or not Integer(item.count) or not Integer(count + item.count) then
                    return nil, "invalid_voucher_count"
                end
                count = count + item.count
            end
        end
        return count
    end
    -- 协调方已持共用重生锁、准备好模型与全部提交闭包后才调用。
    -- operationId在本边界内统一分配；所有购买协调器共用同一会话序号与忙碌保护。
    -- validate再次检查死亡/次数/永久限购/全部提交前提；commit不得等待、通知、调用引擎或再失败。
    -- 成功只返回提交后的通知函数，不返回可复用的“扣物许可”。不确定扣除/提交失败冻结本会话消费。
    function runtime:ConsumeVoucher(playerId, generation, itemId, validate, commit)
        if type(itemId) ~= "string" or itemId == ""
            or type(validate) ~= "function" or type(commit) ~= "function" then return false, "invalid_voucher_operation", false end
        local valid, reason = Current(playerId, generation)
        if not valid then return false, reason, false end
        local state = self.Attempts[playerId]
        if not state or state.generation ~= generation then
            state = { generation = generation, lastId = 0 }
            self.Attempts[playerId] = state
        end
        if state.busy then return false, "voucher_busy", false end
        if state.faulted then return false, "voucher_operation_uncertain", "unknown" end
        if state.lastId >= 9007199254740991 then return false, "voucher_operation_limit", false end
        local operationId = state.lastId + 1
        state.lastId, state.busy = operationId, true
        local stage, consumed = "read", false
        local called, success, value = pcall(function()
            local count, why = self:GetVoucherCount(playerId, generation, itemId)
            if count == nil then return false, why end
            if count < 1 then return false, "voucher_missing" end
            stage = "validate"
            local allowed, rejection = validate()
            if allowed ~= true then return false, rejection or "voucher_not_eligible" end
            local current, errorReason = Current(playerId, generation)
            if not current or self.Attempts[playerId] ~= state then return false, errorReason or "session_unavailable" end
            stage, consumed = "remove", "unknown"
            -- 官网和本地声明均支持RemoveItem(number|string)，完整字符串原值且仅扣1。
            local removed = Inventory:RemoveItem(playerId, itemId, 1)
            if removed == 0 then consumed = false; return false, "voucher_remove_failed" end
            if removed ~= 1 then return false, "invalid_removed_count:" .. tostring(removed) end
            consumed, stage = true, "commit"
            -- 扣物返回后仅作纯Lua实例/会话检查，随后直接提交，不再调用引擎读取。
            if not runtime.Active or context.Services.PurchaseService ~= runtime
                or context.Services.EconomyService ~= economy or not economy:IsCurrent(playerId, generation)
                or self.Attempts[playerId] ~= state then return false, "session_unavailable" end
            return commit()
        end)
        state.busy = nil
        if not called then success, value = false, "voucher_exception:" .. tostring(success) end
        if success ~= true then
            if consumed ~= false then state.faulted = true end
            Log:PrintError("[PurchaseService] 凭证操作未完成，不自动重试", "playerId:", tostring(playerId),
                "generation:", tostring(generation), "operationId:", tostring(operationId), "itemId:", itemId,
                "stage:", stage, "consumed:", tostring(consumed), "error:", tostring(value))
            return false, value, consumed, operationId
        end
        return true, value, true, operationId
    end
end
function PurchaseService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.PurchaseService
    if not runtime then return end
    runtime.Active = false
    runtime.Attempts = {}
    context.Services.PurchaseService = nil
end
return PurchaseService
