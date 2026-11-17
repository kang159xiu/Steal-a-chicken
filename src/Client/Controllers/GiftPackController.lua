local GameConfig = require "Common.Config.GameConfig"
local GiftPackController = { Name = "GiftPackController", FeatureFlag = "GiftPacks", Dependencies = { "PromptController" } }
function GiftPackController:Start(context)
    if context.Side ~= "Client" then return end
    local products, messages = GameConfig.GiftPacks.Products, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Version = 0, RequestId = 0, Pending = {}, Clicks = {} }
    context.Services.GiftPackController = rt
    local function Active() return rt.Active and context.Services.GiftPackController == rt end
    local function Purchased(index) return math.floor((rt.Mask or 0) / 2^(index - 1)) % 2 == 1 end
    rt.State = function(_, data)
        if not Active() or type(data) ~= "table" or type(data.version) ~= "number" or data.version <= rt.Version
            or type(data.purchasedMask) ~= "number" or data.purchasedMask < 0 or data.purchasedMask > 15
            or data.purchasedMask ~= math.floor(data.purchasedMask) then return end
        rt.Version, rt.Mask, rt.ServerReady = data.version, data.purchasedMask, data.ready == true
        if not rt.ServerReady then rt.Pending = {} end
    end
    rt.Offer = function(_, data)
        if not Active() or type(data) ~= "table" then return end
        local pending = rt.Pending[data.index]
        if not pending or pending ~= data.requestId then return end
        rt.Pending[data.index] = nil
        if data.reason == "already_purchased" then context.Services.PromptController:Show("已购买"); return end
        if data.reason or not rt.ServerReady or Purchased(data.index) then return end
        local row = products[data.index]
        if data.goodsId ~= row.GoodsId then return end
        local ok, err = pcall(function() Shop:ShowGoodsForPlayer(row.GoodsId) end)
        if not ok then Log:PrintError("[GiftPacks] 打开购买界面失败", tostring(err)) end
    end
    rt.Bought = function(goodsId, _, itemId)
        if not Active() or not rt.Ready then return end
        for _, row in ipairs(products) do
            if goodsId == row.GoodsId and itemId == row.ItemId then
                System:SendToServer(messages.GiftPackVoucherCheck, {}); return
            end
        end
    end
    System:BindNotify(messages.GiftPackState, rt.State)
    System:BindNotify(messages.GiftPackOffer, rt.Offer)
    System:RegisterEvent(Events.ON_SHOP_BUY_SUCCESS, rt.Bought)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() then return end
            rt.Ready = true
            for index, row in ipairs(products) do
                local packIndex = index
                local callback = function()
                    if not Active() or not rt.Ready or not rt.ServerReady then return end
                    if Purchased(packIndex) then context.Services.PromptController:Show("已购买"); return end
                    if rt.Pending[packIndex] then return end
                    rt.RequestId = rt.RequestId + 1
                    rt.Pending[packIndex] = rt.RequestId
                    System:SendToServer(messages.GiftPackOpen, { index = packIndex, requestId = rt.RequestId })
                end
                local ok, err = pcall(function() UI:RegisterClicked(row.ButtonId, callback) end)
                if ok then rt.Clicks[row.ButtonId] = callback
                else Log:PrintError("[GiftPacks] 按钮绑定失败", row.ButtonId, tostring(err)) end
            end
            System:SendToServer(messages.GiftPackSnapshotRequest, {})
        end)
    end)
end
function GiftPackController:Stop(context)
    local rt = context.Services.GiftPackController
    if not rt then return end
    rt.Active = false
    for buttonId, callback in pairs(rt.Clicks) do
        local ok, err = pcall(function() UI:UnRegisterClicked(buttonId, callback) end)
        if not ok then Log:PrintError("[GiftPacks] 按钮解绑失败", buttonId, tostring(err)) end
    end
    System:UnbindNotify(context.NetMsg.Messages.GiftPackState, rt.State)
    System:UnbindNotify(context.NetMsg.Messages.GiftPackOffer, rt.Offer)
    System:UnregisterEvent(Events.ON_SHOP_BUY_SUCCESS, rt.Bought)
    context.Timers:RemoveOwner(self.Name)
    context.Services.GiftPackController = nil
end
return GiftPackController
