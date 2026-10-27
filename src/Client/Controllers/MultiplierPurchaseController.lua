local GameConfig = require "Common.Config.GameConfig"
local MultiplierProducts = require "Common.MultiplierProducts"
local MultiplierPurchaseController = { Name = "MultiplierPurchaseController", FeatureFlag = "MultiplierPurchase", Dependencies = { "PromptController" } }
local kinds = { "Coin", "Training" }
local function Integer(n) return type(n) == "number" and n > 0 and n < math.huge and n == math.floor(n) end
function MultiplierPurchaseController:Start(context)
    if context.Side ~= "Client" then return end
    local config, messages = GameConfig.MultiplierPurchase, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Version = 0, Session = 0, RequestId = 0, Pending = {}, Buttons = {}, RenderVersion = 0, Receipt = 0 }
    context.Services.MultiplierPurchaseController = rt
    local function Active() return rt.Active and context.Services.MultiplierPurchaseController == rt end
    local function Ui(stage, fn)
        local ok, err = pcall(fn)
        if not ok then Log:PrintError("[MultiplierPurchaseController] UI失败，不重试", stage, tostring(err)) end
    end
    local function Current(kind) return kind == "Coin" and rt.State.coinMultiplier or rt.State.trainingPurchaseMultiplier end
    local function Render()
        if not rt.Ready then return end
        rt.RenderVersion = rt.RenderVersion + 1
        local version = rt.RenderVersion
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() or version ~= rt.RenderVersion then return end
            for _, kind in ipairs(kinds) do
                local c = config[kind]
                Ui(kind, function()
                    if not rt.State or not rt.State.sessionGeneration then
                        UI:SetText({ c.CurrentTextId }, "", false); UI:SetText({ c.NextTextId }, "", false)
                        UI:SetVisibility({ c.GroupId }, false); return
                    end
                    local current = Current(kind)
                    local display = kind == "Coin" and rt.State.finalCoinMultiplier or rt.State.trainingMultiplier
                    UI:SetText({ c.CurrentTextId }, tostring(display):gsub("%.0$", ""), false)
                    local nextProduct = MultiplierProducts.Next(kind, current)
                    UI:SetText({ c.NextTextId }, nextProduct and "x" .. nextProduct.Multiplier or "", false)
                    UI:SetVisibility({ c.GroupId }, nextProduct ~= nil)
                end)
            end
        end)
    end
    rt.StateCallback = function(_, data)
        if not Active() or type(data) ~= "table" or not Integer(data.version) or data.version <= rt.Version then return end
        if data.sessionGeneration ~= nil then
            if not Integer(data.sessionGeneration) or data.sessionGeneration < rt.Session
                or not Integer(data.coinMultiplier) or data.coinMultiplier > 4
                or type(data.finalCoinMultiplier) ~= "number" or data.finalCoinMultiplier < data.coinMultiplier
                or data.finalCoinMultiplier > data.coinMultiplier + 10 or data.finalCoinMultiplier * 2 ~= math.floor(data.finalCoinMultiplier * 2)
                or not MultiplierProducts.IsCurrent("Training", data.trainingPurchaseMultiplier)
                or type(data.trainingMultiplier) ~= "number" or data.trainingMultiplier < data.trainingPurchaseMultiplier
                or data.trainingMultiplier > data.trainingPurchaseMultiplier + 9 or data.trainingMultiplier * 2 ~= math.floor(data.trainingMultiplier * 2) then return end
            rt.Session = data.sessionGeneration
        end
        if not rt.State or rt.State.sessionGeneration ~= data.sessionGeneration then rt.Pending = {} end
        for _, kind in ipairs(kinds) do
            local p = rt.Pending[kind]
            local value = kind == "Coin" and data.coinMultiplier or data.trainingPurchaseMultiplier
            if p and p.expectedMultiplier ~= value then rt.Pending[kind] = nil end
        end
        rt.Version, rt.State = data.version, data
        Render()
    end
    local function Click(kind)
        if not Active() or not rt.Ready or not rt.State or not rt.State.sessionGeneration then return end
        if rt.Pending[kind] then return end
        local current = Current(kind)
        if not MultiplierProducts.Next(kind, current) then context.Services.PromptController:Show("已购买最高倍率"); return end
        rt.RequestId = rt.RequestId + 1
        local request = { requestId = rt.RequestId, kind = kind, sessionGeneration = rt.State.sessionGeneration, expectedMultiplier = current }
        rt.Pending[kind] = request
        System:SendToServer(messages.MultiplierPurchaseOpen, request)
    end
    rt.Offer = function(_, data)
        if not Active() or type(data) ~= "table" or not config[data.kind] or not rt.State then return end
        local p = rt.Pending[data.kind]
        if not p or data.requestId ~= p.requestId or data.sessionGeneration ~= p.sessionGeneration
            or data.expectedMultiplier ~= p.expectedMultiplier or rt.State.sessionGeneration ~= p.sessionGeneration
            or Current(data.kind) ~= p.expectedMultiplier then return end
        local row = MultiplierProducts.Next(data.kind, p.expectedMultiplier)
        if not row or data.goodsId ~= row.GoodsId then return end
        rt.Pending[data.kind] = nil
        Ui("open:" .. data.kind, function() Shop:ShowGoodsForPlayer(row.GoodsId) end)
    end
    rt.Bought = function(goodsId, _, itemId)
        if not Active() or not rt.Ready then return end
        for _, kind in ipairs(kinds) do for _, row in ipairs(config[kind].Products) do
            if row.GoodsId == goodsId and row.ItemId == itemId then System:SendToServer(messages.MultiplierVoucherCheck, {}); return end
        end end
    end
    rt.Result = function(_, data)
        if not Active() or type(data) ~= "table" or not config[data.kind] or data.sessionGeneration ~= rt.Session
            or not Integer(data.receipt) or type(data.success) ~= "boolean" then return end
        if data.success then
            if data.receipt <= rt.Receipt then return end
            if data.target == 1 or not MultiplierProducts.IsCurrent(data.kind, data.target) then return end
            rt.Receipt = data.receipt
            context.Services.PromptController:Show((data.kind == "Coin" and "金币倍率已提升至x" or "训练内购倍率已提升至x") .. data.target)
        else
            local pending = rt.Pending[data.kind]
            if pending and data.requestId == pending.requestId and data.sessionGeneration == pending.sessionGeneration
                and data.expectedMultiplier == pending.expectedMultiplier then rt.Pending[data.kind] = nil end
            if data.receipt <= rt.Receipt then return end
            rt.Receipt = data.receipt
            if data.reason == "multiplier_max" then context.Services.PromptController:Show("已购买最高倍率") end
        end
    end
    rt.Notifies = { { messages.MultiplierPurchaseState, rt.StateCallback }, { messages.MultiplierPurchaseOffer, rt.Offer }, { messages.MultiplierPurchaseResult, rt.Result } }
    for _, binding in ipairs(rt.Notifies) do System:BindNotify(binding[1], binding[2]) end
    System:RegisterEvent(Events.ON_SHOP_BUY_SUCCESS, rt.Bought)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        rt.Ready = true
        for _, kind in ipairs(kinds) do
            local selected = kind
            local callback = function() Click(selected) end
            rt.Buttons[kind] = callback
            Ui("bind:" .. kind, function() UI:RegisterClicked(config[kind].ButtonId, callback) end)
        end
        Render(); System:SendToServer(messages.MultiplierPurchaseSnapshotRequest, {})
    end)
end
function MultiplierPurchaseController:Stop(context)
    local rt = context.Services.MultiplierPurchaseController
    if not rt then return end
    rt.Active = false; rt.RenderVersion = rt.RenderVersion + 1; rt.Pending = {}
    for kind, fn in pairs(rt.Buttons) do
        local ok, err = pcall(function() UI:UnRegisterClicked(GameConfig.MultiplierPurchase[kind].ButtonId, fn) end)
        if not ok then Log:PrintError("[MultiplierPurchaseController] 解绑失败", kind, tostring(err)) end
    end
    for _, binding in ipairs(rt.Notifies) do System:UnbindNotify(binding[1], binding[2]) end
    System:UnregisterEvent(Events.ON_SHOP_BUY_SUCCESS, rt.Bought)
    context.Timers:RemoveOwner(self.Name); context.Services.MultiplierPurchaseController = nil
end
return MultiplierPurchaseController
