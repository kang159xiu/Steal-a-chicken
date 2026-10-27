local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local SpeedGrowth = require "Common.SpeedGrowth"
local TreadmillController = { Name = "TreadmillController", FeatureFlag = "Treadmill", Dependencies = { "PromptController" } }
local function Integer(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end
-- 与重生面板同样的有限长除法：仅取比值4位小数，不转换完整累计经验。
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
local function HasExperience(state)
    return state ~= nil and Integer(state.sessionGeneration) and (state.homeId == nil or Integer(state.homeId))
        and Integer(state.speedLevel)
        and Decimal.IsValid(state.experience) and Decimal.IsValid(state.speedUpgradeExperience)
end
function TreadmillController:ValidateConfig()
    local c = GameConfig.Treadmill
    for _, field in ipairs({ "ExperienceTextId", "FeedbackTextId", "ExperiencePreviewTextId", "SpeedProgressId", "SpeedProgressTextId" }) do
        if not Integer(c[field]) then return false, { "跑步机显示ID无效: " .. field } end
    end
    if c.FeedbackIntervalSeconds ~= 0.3 or c.FeedbackAnimationSeconds ~= 0.5 or c.FeedbackAnimationIndex ~= 1
        or c.FeedbackMinX ~= -700 or c.FeedbackMaxX ~= 400 or c.FeedbackMinY ~= -450 or c.FeedbackMaxY ~= 350 then
        return false, { "跑步机反馈时序/坐标配置不符合规则" }
    end
    return true
end
function TreadmillController:Start(context)
    if context.Side ~= "Client" then return end
    local c, messages = GameConfig.Treadmill, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Version = 0, BlockedTarget = 0, RenderVersion = 0,
        RequestId = 0, Pending = {}, ResultRequests = {}, Copies = {}, UiFailed = {}, Frame = 0, Session = 0 }
    context.Services.TreadmillController = rt
    local function Active() return rt.Active and context.Services.TreadmillController == rt end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Ui(id, callback)
        if rt.UiFailed[id] then return false end
        local ok, err = pcall(callback)
        if not ok then rt.UiFailed[id] = true; Log:PrintError("[TreadmillController] 控件失败，仅停对应表现", id, tostring(err)) end
        return ok
    end
    local function Destroy(uid)
        if not rt.Copies[uid] or uid == c.FeedbackGroupId then return end
        rt.Copies[uid] = nil
        local stopped, stopError = pcall(function() UI:StopUIAnimation(uid) end)
        if not stopped then Log:PrintError("[TreadmillController] 停止反馈动画失败", uid, tostring(stopError)) end
        local ok, err = pcall(function() UI:OnShow({ uid }, false) end)
        if not ok then Log:PrintError("[TreadmillController] 销毁反馈副本失败，不重试", uid, tostring(err)) end
    end
    local function ClearCopies()
        local ids = {}; for uid in pairs(rt.Copies) do ids[#ids + 1] = uid end
        for _, uid in ipairs(ids) do Destroy(uid) end
    end
    local function InvalidateFeedbackSource()
        rt.FeedbackSource = nil
    end
    local function SyncFeedbackSource()
        if not rt.Ready then return end
        local state, previous = rt.State, rt.FeedbackSource
        if not HasExperience(state) or not state.training or state.targetVersion <= rt.BlockedTarget then
            InvalidateFeedbackSource(); return
        end
        if not Decimal.IsValid(state.experiencePerTick) then
            InvalidateFeedbackSource()
            if not rt.FeedbackDataError then
                rt.FeedbackDataError = true
                Log:PrintError("[TreadmillController] 100243反馈数值不可用，缺少有效experiencePerTick")
            end
            return
        end
        if previous and previous.sessionGeneration == state.sessionGeneration and previous.homeId == state.homeId
            and previous.targetVersion == state.targetVersion and previous.level == state.expectedLevel
            and previous.amount == state.experiencePerTick then return end
        local source = { sessionGeneration = state.sessionGeneration, homeId = state.homeId,
            targetVersion = state.targetVersion, level = state.expectedLevel, amount = state.experiencePerTick }
        rt.FeedbackSource = source
        if Ui(c.FeedbackTextId, function() UI:SetText({ c.FeedbackTextId }, "+" .. Decimal.Format(source.amount), false) end)
            and Active() and rt.FeedbackSource == source then
            -- 同帧内启动计时器可能先于现有逐帧回调，额外计一帧保证完整等待至少2帧。
            source.dueFrame = rt.Frame + GameConfig.Runtime.EngineOperationDelayFrames + 1
        end
    end
    local function QueueExperience()
        if rt.Ready then rt.ExperienceDueFrame = rt.Frame + GameConfig.Runtime.EngineOperationDelayFrames + 1 end
    end
    local function RenderExperience()
        local state = rt.State
        if not HasExperience(state) then
            if rt.ExperienceDrawn then
                Ui(c.ExperienceTextId, function() UI:SetText({ c.ExperienceTextId }, "", false) end)
                Ui(c.SpeedProgressId, function() UI:SetProgressCurrentValue({ c.SpeedProgressId }, 0) end)
                Ui(c.SpeedProgressTextId, function() UI:SetText({ c.SpeedProgressTextId }, "", false) end)
                rt.ExperienceDrawn = false
            end
            return
        end
        Ui(c.ExperienceTextId, function() UI:SetText({ c.ExperienceTextId }, Decimal.Format(state.experience), false) end)
        local requirement = SpeedGrowth.GetRequirement(state.speedLevel)
        Ui(c.SpeedProgressId, function()
            if not rt.SpeedProgressReady then UI:SetProgressMaxValue({ c.SpeedProgressId }, 100); rt.SpeedProgressReady = true end
            UI:SetProgressCurrentValue({ c.SpeedProgressId }, Percent(state.speedUpgradeExperience, requirement))
        end)
        Ui(c.SpeedProgressTextId, function()
            UI:SetText({ c.SpeedProgressTextId }, Decimal.Format(state.speedUpgradeExperience) .. "/" .. Decimal.Format(requirement), false)
        end)
        rt.ExperienceDrawn = true
    end
    local function Show(visible)
        if rt.Visible == visible then return end
        Ui(c.UiGroupId, function() UI:SetVisibility({ c.UiGroupId }, visible) end)
        rt.Visible = visible
    end
    local function InBox(state)
        local ok, result = pcall(function()
            return TriggerBox:IsCharacterInTriggerBox(Character:GetLocalPlayerId(), state.triggerId)
        end)
        if not ok and not rt.TriggerFailed then
            rt.TriggerFailed = true; Log:PrintError("[TreadmillController] 训练区域读取失败，关闭交互", tostring(result))
        end
        return ok and result == true
    end
    local function Block()
        local state = rt.State
        if state then rt.BlockedTarget = math.max(rt.BlockedTarget, state.targetVersion) end
        rt.RenderVersion = rt.RenderVersion + 1; rt.Landed = false; rt.Pending = {}
        InvalidateFeedbackSource()
        Show(false); ClearCopies()
    end
    local function Valid()
        local state = rt.State
        if not rt.Ready or not state or not state.training or state.targetVersion <= rt.BlockedTarget then return false end
        if not InBox(state) then Block(); return false end
        return true
    end
    local function Render()
        if not rt.Ready then return end
        rt.RenderVersion = rt.RenderVersion + 1
        local token, state = rt.RenderVersion, rt.State
        rt.Landed = false
        if not state or not state.training or state.targetVersion <= rt.BlockedTarget then Show(false); ClearCopies(); return end
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            local current = rt.State
            if rt.RenderVersion ~= token or not current or current.homeId ~= state.homeId
                or current.sessionGeneration ~= state.sessionGeneration or current.targetVersion ~= state.targetVersion
                or current.expectedLevel ~= state.expectedLevel or not Valid() then return end
            local maximum = state.expectedLevel >= c.MaxLevel
            local text = "lv." .. state.expectedLevel
            if not maximum then text = text .. "->lv." .. (state.expectedLevel + 1) end
            Ui(c.LevelTextId, function() UI:SetText({ c.LevelTextId }, text, false) end)
            Ui(c.PriceTextId, function() UI:SetText({ c.PriceTextId }, maximum and "最高等级" or Decimal.Format(state.upgradeCost), false) end)
            Ui(c.ExperiencePreviewTextId, function()
                local preview = "+" .. Decimal.Format(current.experiencePerTick) .. "/次"
                if not maximum then preview = preview .. "->+" .. Decimal.Format(current.nextExperiencePerTick) .. "/次" end
                UI:SetText({ c.ExperiencePreviewTextId }, preview, false)
            end)
            rt.Landed = true; Show(true)
        end))
    end
    rt.StateCallback = Protect(function(_, data)
        if type(data) ~= "table" or not Integer(data.version) or data.version <= rt.Version
            or type(data.training) ~= "boolean" or type(data.busy) ~= "boolean"
            or type(data.targetVersion) ~= "number" or data.targetVersion < 0 or data.targetVersion >= math.huge
            or data.targetVersion ~= math.floor(data.targetVersion)
            or not Integer(data.expectedLevel) or data.expectedLevel > c.MaxLevel
            or (data.expectedLevel < c.MaxLevel and not Decimal.IsValid(data.upgradeCost)) then return end
        if data.sessionGeneration ~= nil then
            if not Integer(data.sessionGeneration) or data.sessionGeneration < rt.Session then return end
            rt.Session = data.sessionGeneration
        end
        if data.training and (not Integer(data.homeId) or not Integer(data.sessionGeneration) or not Integer(data.triggerId)
            or not Integer(data.speedLevel)
            or not Decimal.IsValid(data.experience) or not Decimal.IsValid(data.speedUpgradeExperience) or type(data.walkSpeed) ~= "number"
            or not Decimal.IsValid(data.experiencePerTick)
            or (data.expectedLevel < c.MaxLevel and not Decimal.IsValid(data.nextExperiencePerTick))) then return end
        local previous = rt.State
        if not previous or previous.homeId ~= data.homeId or previous.sessionGeneration ~= data.sessionGeneration then rt.ResultRequests = {} end
        if not previous or previous.homeId ~= data.homeId or previous.sessionGeneration ~= data.sessionGeneration
            or previous.targetVersion ~= data.targetVersion or not data.training then
            rt.Pending = {}; ClearCopies()
        end
        rt.Version = data.version; rt.State = data
        -- 经验面板显隐完全由编辑器管理；非训练状态也更新有效会话的数值。
        if not previous or previous.homeId ~= data.homeId or previous.sessionGeneration ~= data.sessionGeneration
            or previous.speedLevel ~= data.speedLevel or previous.experience ~= data.experience
            or previous.speedUpgradeExperience ~= data.speedUpgradeExperience then QueueExperience() end
        SyncFeedbackSource()
        if not previous or previous.homeId ~= data.homeId or previous.sessionGeneration ~= data.sessionGeneration
            or previous.targetVersion ~= data.targetVersion or previous.triggerId ~= data.triggerId
            or previous.expectedLevel ~= data.expectedLevel or previous.upgradeCost ~= data.upgradeCost
            or previous.training ~= data.training or previous.experiencePerTick ~= data.experiencePerTick
            or previous.nextExperiencePerTick ~= data.nextExperiencePerTick then Render() end
    end)
    rt.ResultCallback = Protect(function(_, data)
        if type(data) ~= "table" then return end
        local request, state = rt.ResultRequests[data.requestId], rt.State
        if not request or not state or data.sessionGeneration ~= request.sessionGeneration or data.homeId ~= request.homeId
            or data.targetVersion ~= request.targetVersion or data.expectedLevel ~= request.expectedLevel
            or state.sessionGeneration ~= request.sessionGeneration or state.homeId ~= request.homeId
            or type(data.success) ~= "boolean" or (not data.success and state.targetVersion ~= request.targetVersion) then return end
        rt.ResultRequests[data.requestId] = nil
        rt.Pending[data.requestId] = nil
        if data.success then context.Services.PromptController:Show("跑步机升级成功")
        elseif data.reason == "insufficient_balance" then Ui(c.UpgradeButtonId, function() context.Services.PromptController:Show("钱币不足") end)
        else Log:PrintLog("[TreadmillController] 升级未完成", tostring(data.reason)) end
    end)
    rt.Click = Protect(function()
        if not rt.Landed or not Valid() then return end
        local state = rt.State
        if state.busy or state.expectedLevel >= c.MaxLevel or next(rt.Pending) then return end
        rt.RequestId = rt.RequestId + 1
        local request = { requestId = rt.RequestId, homeId = state.homeId, sessionGeneration = state.sessionGeneration,
            targetVersion = state.targetVersion, expectedLevel = state.expectedLevel }
        rt.Pending[request.requestId] = request
        rt.ResultRequests[request.requestId] = request
        System:SendToServer(messages.TreadmillAction, request)
    end)
    rt.Feedback = Protect(function()
        if not rt.Landed or not Valid() or rt.UiFailed[c.FeedbackGroupId] then return end
        local state, source = rt.State, rt.FeedbackSource
        if not source or not source.landed then return end
        Ui(c.FeedbackGroupId, function()
            local uid = UI:DuplicateWidget(c.FeedbackGroupId, math.random(c.FeedbackMinX, c.FeedbackMaxX), math.random(c.FeedbackMinY, c.FeedbackMaxY))
            if not Integer(uid) or uid == c.FeedbackGroupId then error("反馈组复制未返回有效副本UID") end
            rt.Copies[uid] = true
            if not Active() then Destroy(uid); return end
            context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                if not Active() or not rt.Copies[uid] then Destroy(uid); return end
                if not Valid() or rt.State.sessionGeneration ~= state.sessionGeneration
                    or rt.State.targetVersion ~= state.targetVersion or rt.FeedbackSource ~= source then Destroy(uid); return end
                local ok, err = pcall(function() UI:PlayUIAnimation(uid, c.FeedbackAnimationIndex, 0) end)
                if not ok then
                    rt.UiFailed[c.FeedbackGroupId] = true; Destroy(uid)
                    Log:PrintError("[TreadmillController] 反馈动画失败", tostring(err)); return
                end
                context.Timers:AddTimer(self.Name, c.FeedbackAnimationSeconds, function()
                    if not Active() or not rt.Copies[uid] then Destroy(uid); return end
                    context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function() Destroy(uid) end)
                end)
            end)
        end)
    end)
    rt.LeaveBox = Protect(function(id, triggerId)
        if rt.Ready and rt.State and id == Character:GetLocalPlayerId() and triggerId == rt.State.triggerId then Block() end
    end)
    rt.Leave = Protect(function(id)
        if rt.Ready and id == Character:GetLocalPlayerId() then self:Stop(context) end
    end)
    -- 死亡/销毁事件仅服务端可收；客户端由training=false状态关闭表现。
    rt.Bindings = { { Events.ON_CHARACTER_LEAVE_SIGNAL_BOX, rt.LeaveBox }, { Events.ON_PLAYER_PRELEAVE, rt.Leave } }
    System:BindNotify(messages.TreadmillState, rt.StateCallback)
    System:BindNotify(messages.TreadmillResult, rt.ResultCallback)
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, Protect(function()
        rt.Ready = true
        rt.ClickRegistered = Ui(c.UpgradeButtonId, function() UI:RegisterClicked(c.UpgradeButtonId, rt.Click) end)
        Show(false); Render(); QueueExperience(); SyncFeedbackSource()
        System:SendToServer(messages.TreadmillSnapshotRequest, {})
    end))
    context.Timers:AddLoopTimer(self.Name, c.FeedbackIntervalSeconds, rt.Feedback)
    context.Timers:AddLoopFrame(self.Name, 1, Protect(function()
        rt.Frame = rt.Frame + 1
        if not rt.Ready then return end
        if rt.Ready and rt.State and rt.State.training then Valid() end
        local source = rt.FeedbackSource
        if source and source.dueFrame and rt.Frame >= source.dueFrame then source.landed = true; source.dueFrame = nil end
        if rt.ExperienceDueFrame and rt.Frame >= rt.ExperienceDueFrame then rt.ExperienceDueFrame = nil; RenderExperience() end
    end))
    rt.Cleanup = function()
        rt.Active = false; rt.RenderVersion = rt.RenderVersion + 1
        InvalidateFeedbackSource(); rt.ExperienceDueFrame = nil
        rt.Pending = {}; rt.ResultRequests = {}; ClearCopies()
        if rt.Ready then
            if rt.ClickRegistered then
                local ok, err = pcall(function() UI:UnRegisterClicked(c.UpgradeButtonId, rt.Click) end)
                if not ok then Log:PrintError("[TreadmillController] 解绑升级按钮失败", tostring(err)) end
            end
            Show(false)
        end
    end
end
function TreadmillController:Stop(context)
    local rt = context.Services.TreadmillController
    if not rt then return end
    rt.Cleanup()
    System:UnbindNotify(context.NetMsg.Messages.TreadmillState, rt.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.TreadmillResult, rt.ResultCallback)
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    context.Timers:RemoveOwner(self.Name)
    context.Services.TreadmillController = nil
end
return TreadmillController
