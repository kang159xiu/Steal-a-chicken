local Config = require "Common.Config.GameConfig"
local SignInController = { Name = "SignInController", FeatureFlag = "SignIn", Dependencies = { "PromptController" } }
function SignInController:Start(context)
    if context.Side ~= "Client" then return end
    local rewards, messages = Config.SignIn.Rewards, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Version = 0, RequestId = 0, Clicks = {}, Texts = {}, RenderVersion = 0 }
    context.Services.SignInController = rt
    local function Active() return rt.Active and context.Services.SignInController == rt end
    local function Render()
        if not rt.Ready then return end
        rt.RenderVersion = rt.RenderVersion + 1
        local version = rt.RenderVersion
        context.Timers:AddFrame(self.Name, Config.Runtime.EngineOperationDelayFrames, function()
            if not Active() or rt.RenderVersion ~= version then return end
            for index, row in ipairs(rewards) do
                local text = rt.State and rt.State.ready and rt.State.statuses[index] or "未签到"
                if rt.Texts[index] ~= text then
                    local ok, err = pcall(function() UI:SetText({ row.ButtonId }, text, false) end)
                    if ok then rt.Texts[index] = text
                    else Log:PrintError("[SignIn] 按钮文字更新失败", row.ButtonId, tostring(err)) end
                end
            end
        end)
    end
    rt.StateCallback = function(_, data)
        if not Active() or type(data) ~= "table" or type(data.version) ~= "number" or data.version <= rt.Version
            or type(data.statuses) ~= "table" or type(data.count) ~= "number" or type(data.lastDay) ~= "number" then return end
        if data.ready then
            for index in ipairs(rewards) do
                local status = data.statuses[index]
                if status ~= "可签到" and status ~= "未签到" and status ~= "已签到" then return end
            end
        end
        rt.Version, rt.State = data.version, data
        if not data.ready then rt.Pending = nil end
        Render()
    end
    rt.Result = function(_, data)
        if not Active() or type(data) ~= "table" or rt.Pending ~= data.requestId then return end
        rt.Pending = nil
        local text = data.success and "签到成功" or data.reason == "already_claimed_today" and "今日已签到"
            or (data.reason == "stale_state" or data.reason == "wrong_day") and "签到状态已更新，请重新点击"
            or "暂时无法签到，请稍后再试"
        context.Services.PromptController:Show(text)
    end
    System:BindNotify(messages.SignInState, rt.StateCallback)
    System:BindNotify(messages.SignInResult, rt.Result)
    context.Timers:AddTimer(self.Name, Config.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        context.Timers:AddFrame(self.Name, Config.Runtime.EngineOperationDelayFrames, function()
            if not Active() then return end
            rt.Ready = true
            for index, row in ipairs(rewards) do
                local rewardIndex = index
                local callback = function()
                    local state = rt.State
                    if not Active() or not state or not state.ready or rt.Pending then return end
                    if state.statuses[rewardIndex] ~= "可签到" then return end
                    rt.RequestId = rt.RequestId + 1
                    rt.Pending = rt.RequestId
                    System:SendToServer(messages.SignInClaim, { requestId = rt.RequestId, index = rewardIndex,
                        count = state.count, lastDay = state.lastDay })
                end
                local ok, err = pcall(function() UI:RegisterClicked(row.ButtonId, callback) end)
                if ok then rt.Clicks[row.ButtonId] = callback
                else Log:PrintError("[SignIn] 按钮绑定失败", row.ButtonId, tostring(err)) end
            end
            Render()
            System:SendToServer(messages.SignInSnapshotRequest, {})
        end)
    end)
end
function SignInController:Stop(context)
    local rt = context.Services.SignInController
    if not rt then return end
    rt.Active = false
    for id, callback in pairs(rt.Clicks) do
        local ok, err = pcall(function() UI:UnRegisterClicked(id, callback) end)
        if not ok then Log:PrintError("[SignIn] 按钮解绑失败", id, tostring(err)) end
    end
    System:UnbindNotify(context.NetMsg.Messages.SignInState, rt.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.SignInResult, rt.Result)
    context.Timers:RemoveOwner(self.Name)
    context.Services.SignInController = nil
end
return SignInController
