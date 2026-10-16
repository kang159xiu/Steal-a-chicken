local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local RebirthController = { Name = "RebirthController", FeatureFlag = "Rebirth", Dependencies = {} }
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
    for _, field in ipairs({ "MultiplierTextId", "ProgressId", "ExperienceTextId", "ButtonId" }) do
        if not Integer(GameConfig.Rebirth[field]) then return false, { "重生UI配置无效: " .. field } end
    end
    return true
end
function RebirthController:Start(context)
    if context.Side ~= "Client" then return end
    local c, messages = GameConfig.Rebirth, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Version = 0, Session = 0, RenderVersion = 0, RequestId = 0, UiFailed = {} }
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
                Ui(c.MultiplierTextId, function() UI:SetText({ c.MultiplierTextId }, "", false) end)
                Ui(c.ExperienceTextId, function() UI:SetText({ c.ExperienceTextId }, "", false) end)
                Ui(c.ProgressId, function() UI:SetProgressCurrentValue({ c.ProgressId }, 0) end)
                return
            end
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
                or data.expectedCount > c.MaxCount or not Decimal.IsValid(data.experience)
                or data.multiplier ~= 1 + data.expectedCount * 0.5
                or (data.expectedCount < c.MaxCount and (not Decimal.IsValid(data.requirement) or data.requirement == "0"
                    or data.nextMultiplier ~= data.multiplier + 0.5)) then return end
            rt.Session = data.sessionGeneration
        end
        local previous = rt.State
        if not previous or previous.sessionGeneration ~= data.sessionGeneration or previous.expectedCount ~= data.expectedCount then rt.Pending = nil end
        rt.Version = data.version; rt.State = data
        if not previous or previous.sessionGeneration ~= data.sessionGeneration or previous.expectedCount ~= data.expectedCount
            or previous.experience ~= data.experience or previous.requirement ~= data.requirement then Render() end
    end
    rt.ResultCallback = function(_, data)
        if not Active() or type(data) ~= "table" then return end
        local pending, state = rt.Pending, rt.State
        if not pending or not state or type(data.success) ~= "boolean" or data.requestId ~= pending.requestId or data.sessionGeneration ~= pending.sessionGeneration
            or data.expectedCount ~= pending.expectedCount or state.sessionGeneration ~= pending.sessionGeneration then return end
        rt.Pending = nil
        if not data.success then Log:PrintLog("[RebirthController] 重生未完成", tostring(data.reason)) end
    end
    rt.Click = function()
        if not Active() or not rt.Ready or not rt.Landed or not rt.State or rt.State.busy or rt.Pending then return end
        local state = rt.State
        if state.expectedCount >= c.MaxCount then return end
        rt.RequestId = rt.RequestId + 1
        rt.Pending = { requestId = rt.RequestId, sessionGeneration = state.sessionGeneration, expectedCount = state.expectedCount }
        System:SendToServer(messages.RebirthAction, rt.Pending)
    end
    System:BindNotify(messages.RebirthState, rt.StateCallback)
    System:BindNotify(messages.RebirthResult, rt.ResultCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        rt.Ready = true
        Ui(c.ButtonId, function() UI:RegisterClicked(c.ButtonId, rt.Click); rt.ClickRegistered = true end)
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
    System:UnbindNotify(context.NetMsg.Messages.RebirthState, rt.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.RebirthResult, rt.ResultCallback)
    context.Timers:RemoveOwner(self.Name); context.Services.RebirthController = nil
end
return RebirthController
