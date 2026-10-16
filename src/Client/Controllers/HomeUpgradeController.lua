local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local HomeUpgradeController = { Name = "HomeUpgradeController", FeatureFlag = "HomeUpgrade", Dependencies = {} }
local function Integer(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end
function HomeUpgradeController:Start(context)
    if context.Side ~= "Client" then return end
    local config, messages = GameConfig.HomeUpgrade, context.NetMsg.Messages
    local runtime = { Active = true, Ready = false, Version = 0, BlockedTarget = 0, RenderVersion = 0,
        RequestId = 0, Displays = {}, DisplayTokens = {}, DisplayFailed = {}, Pending = {}, UiFailed = {}, Landed = false }
    context.Services.HomeUpgradeController = runtime
    local function Active() return runtime.Active and context.Services.HomeUpgradeController == runtime end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Ui(action, id, callback)
        if runtime.UiFailed[id] then return end
        local ok, err = pcall(callback)
        if not ok then
            runtime.UiFailed[id] = true
            Log:PrintError("[HomeUpgradeController] UI失败，仅停该控件", "action:", action, "elementId:", id, "error:", tostring(err))
        end
    end
    local function Show(visible)
        if runtime.Visible == visible then return end
        Ui("visible", config.UiGroupId, function() UI:SetVisibility({ config.UiGroupId }, visible) end)
        runtime.Visible = visible
    end
    local function InRange(state)
        local ok, result = pcall(function()
            local p, q = Character:GetPosition(Character:GetLocalPlayerId()), Element:GetPosition(state.elementId)
            if not p or not q then error("升级元件或玩家位置不可用") end
            return (p.X-q.X)^2 + (p.Y-q.Y)^2 + (p.Z-q.Z)^2 <= config.MaxDistance^2
        end)
        if not ok and not runtime.PositionFailed then
            runtime.PositionFailed = true
            Log:PrintError("[HomeUpgradeController] 位置读取失败，仅关闭升级UI", tostring(result))
        end
        return ok and result == true
    end
    local function ValidateRange()
        local state = runtime.State
        if not runtime.Ready or not runtime.Landed or not state or not state.visible then return false end
        if state.targetVersion <= runtime.BlockedTarget or not InRange(state) then
            runtime.BlockedTarget = math.max(runtime.BlockedTarget, state.targetVersion)
            runtime.Landed = false
            Show(false)
            return false
        end
        return true
    end
    local function QueueDisplay(state)
        local homeId = state.homeId
        runtime.DisplayTokens[homeId] = (runtime.DisplayTokens[homeId] or 0) + 1
        local token = runtime.DisplayTokens[homeId]
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            if not runtime.Ready or runtime.Displays[homeId] ~= state or runtime.DisplayTokens[homeId] ~= token
                or runtime.DisplayFailed[homeId] then return end
            local ok, err = pcall(function() FuncElement:SetTextBoardText(state.elementId, "Lv." .. tostring(state.level)) end)
            if not ok then
                runtime.DisplayFailed[homeId] = true
                Log:PrintError("[HomeUpgradeController] 等级文字失败，仅停本家园文字", "homeId:", homeId,
                    "elementId:", state.elementId, "error:", tostring(err))
            end
        end))
    end
    local function QueueRender()
        if not runtime.Ready then return end
        runtime.RenderVersion = runtime.RenderVersion + 1
        local token, state = runtime.RenderVersion, runtime.State
        runtime.Landed = false
        if not state or not state.visible or state.targetVersion <= runtime.BlockedTarget then Show(false); return end
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            if token ~= runtime.RenderVersion or runtime.State ~= state then return end
            runtime.Landed = true
            if not ValidateRange() then return end
            local maximum = state.expectedLevel == config.MaxLevel
            local chickenText = tostring(state.chickenCapacity)
            local eggText = tostring(state.eggCapacity)
            if not maximum then
                chickenText = chickenText .. "->" .. tostring(state.nextChickenCapacity)
                eggText = eggText .. "->" .. tostring(state.nextEggCapacity)
            end
            for _, entry in ipairs({ { config.PriceTextId, maximum and "最高等级" or Decimal.Format(state.upgradeCost) },
                { config.LevelTextId, "Lv." .. tostring(state.expectedLevel) },
                { config.ChickenTextId, chickenText }, { config.EggTextId, eggText } }) do
                Ui("text", entry[1], function() UI:SetText({ entry[1] }, entry[2], false) end)
            end
            Show(true)
        end))
    end
    runtime.StateCallback = Protect(function(_, message)
        if type(message) ~= "table" then return end
        if message.kind == "level" then
            if not Integer(message.homeId) or not Integer(message.elementId) or not Integer(message.displayVersion)
                or not Integer(message.level) or message.level > config.MaxLevel then return end
            local previous = runtime.Displays[message.homeId]
            if previous and message.displayVersion <= previous.displayVersion then return end
            local state = { homeId = message.homeId, elementId = message.elementId, level = message.level,
                displayVersion = message.displayVersion }
            runtime.Displays[state.homeId] = state
            if runtime.Ready then QueueDisplay(state) end
            return
        end
        if message.kind ~= "interaction" or not Integer(message.version) or message.version <= runtime.Version
            or type(message.visible) ~= "boolean" or type(message.busy) ~= "boolean"
            or type(message.targetVersion) ~= "number" or message.targetVersion < 0
            or message.targetVersion >= math.huge or message.targetVersion ~= math.floor(message.targetVersion)
            or not Integer(message.expectedLevel) or message.expectedLevel > config.MaxLevel
            or not Integer(message.chickenCapacity) or not Integer(message.eggCapacity)
            or (message.visible and (not Integer(message.homeId) or not Integer(message.sessionGeneration) or not Integer(message.elementId)))
            or (message.expectedLevel < config.MaxLevel and (not Decimal.IsValid(message.upgradeCost)
                or not Integer(message.nextChickenCapacity) or not Integer(message.nextEggCapacity))) then return end
        runtime.Version = message.version
        local previous = runtime.State
        if not previous or previous.homeId ~= message.homeId or previous.sessionGeneration ~= message.sessionGeneration then
            runtime.Pending = {}
        end
        runtime.State = message
        QueueRender()
    end)
    runtime.ResultCallback = Protect(function(_, message)
        if type(message) ~= "table" then return end
        local request = runtime.Pending[message.requestId]
        local state = runtime.State
        if not request or not state or message.homeId ~= request.homeId or message.sessionGeneration ~= request.sessionGeneration
            or message.targetVersion ~= request.targetVersion or message.expectedLevel ~= request.expectedLevel
            or state.homeId ~= request.homeId or state.sessionGeneration ~= request.sessionGeneration
            or type(message.success) ~= "boolean" then return end
        runtime.Pending[message.requestId] = nil
        if message.reason == "insufficient_balance" then
            Ui("tip", config.ButtonId, function() UI:ShowMessageTip("钱币不足") end)
        elseif not message.success then
            Log:PrintLog("[HomeUpgradeController] 升级失败", "requestId:", message.requestId, "reason:", tostring(message.reason))
        end
    end)
    runtime.ClickCallback = Protect(function()
        if not ValidateRange() then return end
        local state = runtime.State
        if state.busy or state.expectedLevel >= config.MaxLevel or next(runtime.Pending) ~= nil then return end
        runtime.RequestId = runtime.RequestId + 1
        local request = { requestId = runtime.RequestId, sessionGeneration = state.sessionGeneration,
            homeId = state.homeId, targetVersion = state.targetVersion, expectedLevel = state.expectedLevel }
        runtime.Pending[request.requestId] = request
        System:SendToServer(messages.HomeUpgradeAction, request)
    end)
    runtime.LeaveCallback = Protect(function(playerId)
        if playerId == Character:GetLocalPlayerId() then self:Stop(context) end
    end)
    System:BindNotify(messages.HomeUpgradeState, runtime.StateCallback)
    System:BindNotify(messages.HomeUpgradeResult, runtime.ResultCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, Protect(function()
        runtime.Ready = true
        Ui("bind", config.ButtonId, function() UI:RegisterClicked(config.ButtonId, runtime.ClickCallback) end)
        runtime.ClickRegistered = not runtime.UiFailed[config.ButtonId]
        for _, state in pairs(runtime.Displays) do QueueDisplay(state) end
        QueueRender()
        System:SendToServer(messages.HomeUpgradeSnapshotRequest, {})
    end))
    context.Timers:AddLoopFrame(self.Name, 1, Protect(function()
        if runtime.Ready and runtime.Landed then ValidateRange() end
    end))
    runtime.Cleanup = function()
        runtime.Active = false
        runtime.RenderVersion = runtime.RenderVersion + 1
        runtime.State, runtime.Pending, runtime.Displays, runtime.DisplayTokens = nil, {}, {}, {}
        if runtime.Ready then
            if runtime.ClickRegistered then UI:UnRegisterClicked(config.ButtonId, runtime.ClickCallback) end
            Show(false)
        end
    end
end
function HomeUpgradeController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.HomeUpgradeController
    if not runtime then return end
    runtime.Cleanup()
    System:UnbindNotify(context.NetMsg.Messages.HomeUpgradeState, runtime.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.HomeUpgradeResult, runtime.ResultCallback)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.HomeUpgradeController = nil
end
return HomeUpgradeController
