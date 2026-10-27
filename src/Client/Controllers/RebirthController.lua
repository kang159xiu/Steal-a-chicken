local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local RebirthController = { Name = "RebirthController", FeatureFlag = "Rebirth", Dependencies = { "PromptController" } }
local function Integer(value, zero)
    return type(value) == "number" and value >= (zero and 0 or 1) and value < math.huge and value == math.floor(value)
end
local function Percent(experience, requirement)
    if Decimal.Compare(experience, requirement) >= 0 then return 100 end
    local remainder, units = experience, 0
    for _ = 1, 4 do
        if remainder ~= "0" then remainder = remainder .. "0" end
        local digit = 0
        while Decimal.Compare(remainder, requirement) >= 0 do remainder = Decimal.Subtract(remainder, requirement); digit = digit + 1 end
        units = units * 10 + digit
    end
    return units / 100
end
function RebirthController:ValidateConfig()
    for _, field in ipairs({ "MultiplierTextId", "ProgressId", "ExperienceTextId", "ButtonId", "CountTextId" }) do
        if not Integer(GameConfig.Rebirth[field]) then return false, { "重生UI配置无效: " .. field } end
    end
    return true
end
function RebirthController:Start(context)
    if context.Side ~= "Client" then return end
    local c, messages = GameConfig.Rebirth, context.NetMsg.Messages
    local paid = GameConfig.RebirthPurchase
    local rt = { Active = true, Ready = false, Version = 0, Session = 0, RenderVersion = 0, RequestId = 0, ResultRequests = {}, UiFailed = {} }
    context.Services.RebirthController = rt
    local function Active() return rt.Active and context.Services.RebirthController == rt end
    local function Ui(id, callback)
        if rt.UiFailed[id] then return end
        local ok, err = pcall(callback)
        if not ok then rt.UiFailed[id] = true; Log:PrintError("[RebirthController] 仅停对应控件", id, tostring(err)) end
    end
    local function Render()
        if not rt.Ready then return end
        rt.RenderVersion = rt.RenderVersion + 1; rt.Landed = false
        local token = rt.RenderVersion
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() or rt.RenderVersion ~= token then return end
            local state = rt.State
            local valid = state and Integer(state.sessionGeneration) and Decimal.IsValid(state.experience)
            if not valid then
                Ui(c.CountTextId, function() UI:SetText({ c.CountTextId }, "", false) end)
                Ui(c.MultiplierTextId, function() UI:SetText({ c.MultiplierTextId }, "", false) end)
                Ui(c.ExperienceTextId, function() UI:SetText({ c.ExperienceTextId }, "", false) end)
                Ui(c.ProgressId, function() UI:SetProgressCurrentValue({ c.ProgressId }, 0) end)
                return
            end
            Ui(c.CountTextId, function() UI:SetText({ c.CountTextId }, tostring(state.expectedCount), false) end)
            local maximum = state.expectedCount == c.MaxCount
            local multiplier = "x" .. tostring(state.multiplier):gsub("%.0$", "")
            if not maximum then multiplier = multiplier .. "->x" .. tostring(state.nextMultiplier):gsub("%.0$", "") end
            Ui(c.MultiplierTextId, function() UI:SetText({ c.MultiplierTextId }, multiplier, false) end)
            Ui(c.ExperienceTextId, function() UI:SetText({ c.ExperienceTextId }, maximum and "最高等级"
                or Decimal.Format(state.experience) .. "/" .. Decimal.Format(state.requirement), false) end)
            Ui(c.ProgressId, function()
                if not rt.ProgressReady then UI:SetProgressMaxValue({ c.ProgressId }, 100); rt.ProgressReady = true end
                UI:SetProgressCurrentValue({ c.ProgressId }, maximum and 100 or Percent(state.experience, state.requirement))
            end)
            rt.Landed = true
        end)
    end
    rt.StateCallback = function(_, data)
        if not Active() or type(data) ~= "table" or not Integer(data.version) or data.version <= rt.Version
            or type(data.busy) ~= "boolean" then return end
        if data.sessionGeneration ~= nil then
            if not Integer(data.sessionGeneration) or data.sessionGeneration < rt.Session or not Integer(data.expectedCount, true)
                or data.expectedCount > c.MaxCount or not Integer(data.redeemedMask, true) or data.redeemedMask > 1048575
                or not Decimal.IsValid(data.experience)
                or data.multiplier ~= 1 + data.expectedCount * 0.5
                or (data.expectedCount < c.MaxCount and (not Decimal.IsValid(data.requirement) or data.requirement == "0"
                    or data.nextMultiplier ~= data.multiplier + 0.5)) then return end
            rt.Session = data.sessionGeneration
        end
        local previous = rt.State
        if not previous or previous.sessionGeneration ~= data.sessionGeneration then rt.ResultRequests = {} end
        if not previous or previous.sessionGeneration ~= data.sessionGeneration or previous.expectedCount ~= data.expectedCount then rt.Pending = nil; rt.PendingOpen = nil end
        rt.Version = data.version; rt.State = data
        if not previous or previous.sessionGeneration ~= data.sessionGeneration or previous.expectedCount ~= data.expectedCount
            or previous.experience ~= data.experience or previous.requirement ~= data.requirement then Render() end
    end
    rt.ResultCallback = function(_, data)
        if not Active() or type(data) ~= "table" then return end
        local pending, state = rt.ResultRequests[data.requestId], rt.State
        if not pending or not state or type(data.success) ~= "boolean" or data.requestId ~= pending.requestId or data.sessionGeneration ~= pending.sessionGeneration
            or data.expectedCount ~= pending.expectedCount or state.sessionGeneration ~= pending.sessionGeneration then return end
        rt.ResultRequests[data.requestId] = nil
        if rt.Pending == pending then rt.Pending = nil end
        if data.success then context.Services.PromptController:Show("普通重生成功，金币倍率提升")
        elseif data.reason == "insufficient_experience" then context.Services.PromptController:Show("训练经验不足，继续训练后再来")
        else Log:PrintLog("[RebirthController] 重生未完成", tostring(data.reason)) end
    end
    rt.Click = function()
        if not Active() or not rt.Ready or not rt.Landed or not rt.State or rt.State.busy or rt.Pending then return end
        local state = rt.State
        if state.expectedCount >= c.MaxCount then return end
        rt.RequestId = rt.RequestId + 1
        rt.Pending = { requestId = rt.RequestId, sessionGeneration = state.sessionGeneration, expectedCount = state.expectedCount }
        rt.ResultRequests[rt.Pending.requestId] = rt.Pending
        System:SendToServer(messages.RebirthAction, rt.Pending)
    end
    rt.PaidClick = function()
        if not Active() or not rt.Ready or not rt.State then return end
        local state = rt.State
        if not Integer(state.sessionGeneration) or state.expectedCount >= c.MaxCount
            or math.floor(state.redeemedMask / 2^state.expectedCount) % 2 == 1 then return end
        rt.RequestId = rt.RequestId + 1
        rt.PendingOpen = { requestId = rt.RequestId, sessionGeneration = state.sessionGeneration, expectedCount = state.expectedCount }
        System:SendToServer(messages.RebirthPurchaseOpen, rt.PendingOpen)
    end
    rt.Offer = function(_, data)
        if not Active() or type(data) ~= "table" then return end
        local pending, state = rt.PendingOpen, rt.State
        if not pending or not state or data.requestId ~= pending.requestId or data.sessionGeneration ~= pending.sessionGeneration
            or data.expectedCount ~= pending.expectedCount or state.sessionGeneration ~= pending.sessionGeneration
            or state.expectedCount ~= pending.expectedCount or state.expectedCount >= c.MaxCount then return end
        local row = paid.Products[state.expectedCount + 1]
        if data.productIndex ~= state.expectedCount + 1 or data.goodsId ~= row.GoodsId
            or math.floor(state.redeemedMask / 2^state.expectedCount) % 2 == 1 then return end
        rt.PendingOpen = nil
        local ok, err = pcall(function() Shop:ShowGoodsForPlayer(row.GoodsId) end)
        if not ok then Log:PrintError("[RebirthController] 打开购买界面失败", tostring(err)) end
    end
    rt.Bought = function(goodsId, _, itemId)
        if not Active() or not rt.Ready then return end
        for _, row in ipairs(paid.Products) do
            if goodsId == row.GoodsId and itemId == row.ItemId then
                -- 客户端事件只是唤醒提示，不作为付款凭据，也不传数量或授权。
                System:SendToServer(messages.RebirthVoucherCheck, {}); return
            end
        end
    end
    rt.PaidResult = function(_, data)
        if not Active() or type(data) ~= "table" or data.success ~= true or data.sessionGeneration ~= rt.Session
            or not Integer(data.receipt) or data.receipt <= (rt.LastReceipt or 0) or not Integer(data.productIndex)
            or data.productIndex > #paid.Products or not Integer(data.count) or data.count > c.MaxCount then return end
        rt.LastReceipt = data.receipt
        local ok, err = pcall(function() context.Services.PromptController:Show("内购重生成功，金币倍率提升") end)
        if not ok then Log:PrintError("[RebirthController] 成功提示失败", tostring(err)) end
    end
    System:BindNotify(messages.RebirthPurchaseOffer, rt.Offer)
    System:BindNotify(messages.RebirthPurchaseResult, rt.PaidResult)
    System:RegisterEvent(Events.ON_SHOP_BUY_SUCCESS, rt.Bought)
    System:BindNotify(messages.RebirthState, rt.StateCallback)
    System:BindNotify(messages.RebirthResult, rt.ResultCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        rt.Ready = true
        Ui(c.ButtonId, function() UI:RegisterClicked(c.ButtonId, rt.Click); rt.ClickRegistered = true end)
        Ui(paid.ButtonId, function() UI:RegisterClicked(paid.ButtonId, rt.PaidClick); rt.PaidClickRegistered = true end)
        Render(); System:SendToServer(messages.RebirthSnapshotRequest, {})
    end)
end
function RebirthController:Stop(context)
    local rt = context.Services.RebirthController
    if not rt then return end
    rt.Active = false; rt.RenderVersion = rt.RenderVersion + 1; rt.Pending = nil
    if rt.ClickRegistered then
        local ok, err = pcall(function() UI:UnRegisterClicked(GameConfig.Rebirth.ButtonId, rt.Click) end)
        if not ok then Log:PrintError("[RebirthController] 按钮解绑失败", tostring(err)) end
    end
    rt.PendingOpen = nil; rt.ResultRequests = {}
    if rt.PaidClickRegistered then
        local ok, err = pcall(function() UI:UnRegisterClicked(GameConfig.RebirthPurchase.ButtonId, rt.PaidClick) end)
        if not ok then Log:PrintError("[RebirthController] 购买按钮解绑失败", tostring(err)) end
    end
    System:UnregisterEvent(Events.ON_SHOP_BUY_SUCCESS, rt.Bought)
    System:UnbindNotify(context.NetMsg.Messages.RebirthPurchaseOffer, rt.Offer)
    System:UnbindNotify(context.NetMsg.Messages.RebirthPurchaseResult, rt.PaidResult)
    System:UnbindNotify(context.NetMsg.Messages.RebirthState, rt.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.RebirthResult, rt.ResultCallback)
    context.Timers:RemoveOwner(self.Name); context.Services.RebirthController = nil
end
return RebirthController
