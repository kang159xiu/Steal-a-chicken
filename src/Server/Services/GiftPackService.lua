local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local SafeCall = require "Common.Core.SafeCall"
local GiftPackService = { Name = "GiftPackService", FeatureFlag = "GiftPacks",
    Dependencies = { "PurchaseService", "EconomyService", "InventoryService", "PlayerSpeedService", "RebirthService" } }

local function Purchased(state, index)
    return math.floor(state.purchasedMask / 2^(index - 1)) % 2 == 1
end
function GiftPackService:Start(context)
    if context.Side ~= "Server" then return end
    local economy, purchase = context.Services.EconomyService, context.Services.PurchaseService
    local inventory, speed = context.Services.InventoryService, context.Services.PlayerSpeedService
    local persistence, rebirth = context.Services.PersistenceService, context.Services.RebirthService
    local config, messages = GameConfig.GiftPacks, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Players = {}, Version = 0 }
    context.Services.GiftPackService = rt
    local function Active() return rt.Active and context.Services.GiftPackService == rt end
    local function Protect(callback)
        return SafeCall.Protect(Active, function(err) context.Manager:FailModule(self.Name, tostring(err)) end, callback)
    end
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or persistence:IsReady(id)
    end
    local function Send(id)
        rt.Version = rt.Version + 1
        local state = rt.Players[id]
        System:SendToClient(id, messages.GiftPackState, { version = rt.Version,
            ready = state ~= nil and CanPlay(id), purchasedMask = state and state.purchasedMask or 0 })
    end
    function rt:ExportPurchased(id)
        local state = self.Players[id]
        if not state then return nil, "gift_pack_state_missing" end
        return { version = 1, purchasedMask = state.purchasedMask }
    end
    local function Ensure(id)
        if not rt.Ready or not CanPlay(id) then return nil end
        if not rt.Players[id] and not GameConfig.Persistence.ProductionEnabled then
            rt.Players[id] = { purchasedMask = 0 }
        end
        return rt.Players[id]
    end
    local function Notify(callback)
        local ok, err = pcall(callback)
        if not ok then Log:PrintError("[GiftPacks] 提交后通知失败，不重发", tostring(err)) end
    end
    local function Scan(id, state)
        if rt.Players[id] ~= state or not CanPlay(id) or state.halted or state.running then return end
        state.running, state.deferred = true, nil
        local generation = economy:GetSessionGeneration(id)
        for index, row in ipairs(config.Products) do
            if not Purchased(state, index) then
                local count, reason = purchase:GetVoucherCount(id, generation, row.ItemId)
                if count == nil then
                    state.halted = true
                    Log:PrintError("[GiftPacks] 核票失败，不自动重试", id, row.GoodsId, tostring(reason))
                    break
                end
                if count > 0 then
                    local lock, why = rebirth:TryAcquirePurchaseLock(id, generation)
                    if not lock then state.deferred = true; break end
                    local inventoryCommit, coinCommit, experienceCommit
                    local ok, publish, consumed = purchase:ConsumeVoucher(id, generation, row.ItemId, function()
                        if rt.Players[id] ~= state or not CanPlay(id) or Purchased(state, index)
                            or not rebirth:IsPurchaseLockCurrent(id, generation, lock) then return false, "purchase_cancelled" end
                        local saleTotal
                        inventoryCommit, saleTotal = inventory:PrepareGiftChickens(id, row.Chickens)
                        if not inventoryCommit then return false, saleTotal end
                        coinCommit, why = economy:PrepareCoinRewardCommit(id, generation, Decimal.Add(row.Coins, saleTotal))
                        if not coinCommit then return false, why end
                        if row.Experience ~= "0" then
                            experienceCommit, why = speed:PrepareExperienceCommit(id, row.Experience)
                            if not experienceCommit then return false, why end
                        end
                        return true
                    end, function()
                        if rt.Players[id] ~= state or not rebirth:IsPurchaseLockCurrent(id, generation, lock) then
                            return false, "purchase_cancelled"
                        end
                        -- 扣票后此段无引擎调用、等待或通知；全部准备完成才进入。
                        local added, inventoryPublish = inventoryCommit()
                        if not added then return false, inventoryPublish end
                        local credited, coinPublish = coinCommit()
                        if not credited then return false, coinPublish end
                        local experiencePublish
                        if experienceCommit then
                            local advanced
                            advanced, experiencePublish = experienceCommit()
                            if not advanced then return false, experiencePublish end
                        end
                        state.purchasedMask = state.purchasedMask + 2^(index - 1)
                        return true, function()
                            Notify(inventoryPublish)
                            Notify(coinPublish)
                            if experiencePublish then Notify(experiencePublish) end
                            if Active() and rt.Players[id] == state and CanPlay(id) then
                                Notify(function() Send(id) end)
                                if GameConfig.Persistence.ProductionEnabled then
                                    Notify(function()
                                        local saved, why = persistence:MarkDirty(id, "gift_pack")
                                        if not saved then Log:PrintError("[GiftPacks] 保存调度失败，不重发奖励", id, tostring(why)) end
                                    end)
                                end
                            end
                        end
                    end)
                    rebirth:ReleasePurchaseLock(id, lock)
                    if ok then Notify(publish)
                    else
                        if consumed == false and (publish == "sale_batch_busy" or publish == "voucher_busy") then
                            state.deferred = true
                        else state.halted = true end
                        Log:PrintError("[GiftPacks] 兑现未完成", id, row.GoodsId, tostring(publish), tostring(consumed))
                        break
                    end
                end
            end
            if not Active() or rt.Players[id] ~= state or not CanPlay(id) then break end
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
    if GameConfig.Persistence.ProductionEnabled then
        assert(persistence:RegisterAdapter("giftPacks", {
            Export = function(id) return rt:ExportPurchased(id) end,
            Restore = function(id, data, done)
                local mask = 0
                if data ~= nil then
                    if type(data) ~= "table" then done(false, "invalid_gift_pack_archive"); return end
                    if data.version ~= 1 then Log:PrintServerLog("[Persistence] version mismatch", id, "giftPacks", tostring(data.version), 1) end
                    if data.purchasedMask ~= nil then mask = data.purchasedMask end
                end
                if type(mask) ~= "number" or mask < 0 or mask > 15 or mask ~= math.floor(mask) then
                    done(false, "invalid_gift_pack_mask"); return
                end
                rt.Players[id] = { purchasedMask = mask }
                done(true)
            end,
            Cleanup = function(id) rt.Players[id] = nil end,
        }))
    end
    rt.Open = Protect(function(_, request, id)
        if type(request) ~= "table" or type(request.index) ~= "number" or request.index ~= math.floor(request.index)
            or not config.Products[request.index] or type(request.requestId) ~= "number"
            or request.requestId < 1 or request.requestId > 9007199254740991 or request.requestId ~= math.floor(request.requestId) then return end
        local state = Ensure(id)
        local reason = not state and "player_not_ready" or Purchased(state, request.index) and "already_purchased" or nil
        System:SendToClient(id, messages.GiftPackOffer, { index = request.index, requestId = request.requestId,
            goodsId = config.Products[request.index].GoodsId, reason = reason })
    end)
    rt.Snapshot = Protect(function(_, request, id)
        if type(request) ~= "table" or next(request) ~= nil then return end
        Ensure(id); Send(id)
    end)
    rt.Check = Protect(function(_, request, id)
        if type(request) == "table" and next(request) == nil then Wake(id) end
    end)
    rt.GetItem = Protect(function(id, itemId, _, custom)
        if custom ~= true then return end
        for _, row in ipairs(config.Products) do if row.ItemId == itemId then Wake(id); return end end
    end)
    rt.Leave = Protect(function(id)
        -- 离场导出必须先于清理；初始化仅走适配器Cleanup，不调用离场保存。
        if GameConfig.Persistence.ProductionEnabled then persistence:PrepareLeave(id) end
        rt.Players[id] = nil
    end)
    rt.Revive = Protect(function(id)
        local state = rt.Players[id]
        if state and state.deferred then Wake(id) end
    end)
    rt.Bindings = { { Events.ON_PLAYER_GET_ITEM, rt.GetItem }, { Events.ON_PLAYER_PRELEAVE, rt.Leave },
        { Events.ON_PLAYER_RECONNECTED, rt.Leave }, { Events.ON_CHARACTER_REVIVED, rt.Revive },
        { Events.ON_CHARACTER_RESPAWN, rt.Revive } }
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    for _, pair in ipairs({ { messages.GiftPackOpen, rt.Open }, { messages.GiftPackSnapshotRequest, rt.Snapshot },
        { messages.GiftPackVoucherCheck, rt.Check } }) do System:BindNotify(pair[1], pair[2]) end
    context.Events:Subscribe(self.Name, "PersistenceReady", Protect(function(event) Send(event.playerId); Wake(event.playerId) end))
    context.Events:Subscribe(self.Name, "PlayerDataResetStarted", Protect(function(event)
        local state = rt.Players[event.playerId]
        if state then rt.Players[event.playerId] = { purchasedMask = state.purchasedMask } end
        Send(event.playerId)
    end))
    for _, name in ipairs({ "EconomyChanged", "PlayerSpeedChanged", "TreadmillLevelChanged", "InventoryChanged" }) do
        context.Events:Subscribe(self.Name, name, Protect(function(event) rt.Revive(event.playerId) end))
    end
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function()
        rt.Ready = true
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Send(id); Wake(id) end
    end))
end
function GiftPackService:Stop(context)
    local rt = context.Services.GiftPackService
    if not rt then return end
    rt.Active, rt.Players = false, {}
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    System:UnbindNotify(context.NetMsg.Messages.GiftPackOpen, rt.Open)
    System:UnbindNotify(context.NetMsg.Messages.GiftPackSnapshotRequest, rt.Snapshot)
    System:UnbindNotify(context.NetMsg.Messages.GiftPackVoucherCheck, rt.Check)
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.GiftPackService = nil
end
return GiftPackService
