local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local CoinPurchaseController = { Name = "CoinPurchaseController", FeatureFlag = "CoinPurchase", Dependencies = {} }
function CoinPurchaseController:Start(context)
    if context.Side ~= "Client" then return end
    local config, messages = GameConfig.CoinPurchase, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Version = 0, RenderVersion = 0, Texts = {}, Failed = {} }
    context.Services.CoinPurchaseController = rt
    local function Active() return rt.Active and context.Services.CoinPurchaseController == rt end
    local function Render()
        if not rt.Ready then return end
        rt.RenderVersion = rt.RenderVersion + 1
        local token = rt.RenderVersion
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() or rt.RenderVersion ~= token then return end
            for index, row in ipairs(config.Products) do
                local text = rt.Rewards and Decimal.Format(rt.Rewards[index]) or ""
                if not rt.Failed[index] and rt.Texts[index] ~= text then
                    local ok, err = pcall(function() UI:SetText({ row.TextId }, text, false) end)
                    if ok then rt.Texts[index] = text
                    else
                        rt.Failed[index] = true
                        Log:PrintError("[CoinPurchase] 金额文字失败，不重试", row.TextId, tostring(err))
                    end
                end
            end
        end)
    end
    rt.State = function(_, data)
        if not Active() or type(data) ~= "table" or type(data.version) ~= "number" or data.version <= rt.Version then return end
        if data.rewards ~= nil then
            if type(data.rewards) ~= "table" then return end
            for index in ipairs(config.Products) do if not Decimal.IsValid(data.rewards[index]) then return end end
        end
        rt.Version, rt.Rewards = data.version, data.rewards
        Render()
    end
    System:BindNotify(messages.CoinPurchaseState, rt.State)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        rt.Ready = true
        Render()
        System:SendToServer(messages.CoinPurchaseSnapshotRequest, {})
    end)
end
function CoinPurchaseController:Stop(context)
    local rt = context.Services.CoinPurchaseController
    if not rt then return end
    rt.Active = false
    System:UnbindNotify(context.NetMsg.Messages.CoinPurchaseState, rt.State)
    context.Timers:RemoveOwner(self.Name)
    context.Services.CoinPurchaseController = nil
end
return CoinPurchaseController
