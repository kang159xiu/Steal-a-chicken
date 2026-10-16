local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local HomeUpgradeService = { Name = "HomeUpgradeService", FeatureFlag = "HomeUpgrade",
    Dependencies = { "HomeService", "EconomyService" } }
local function Integer(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end
function HomeUpgradeService:ValidateConfig()
    local c, levels = GameConfig.HomeUpgrade, GameConfig.HomeLevels
    if type(c) ~= "table" or c.MaxLevel ~= 20 or c.MaxDistance ~= 300 or type(levels) ~= "table" or #levels ~= 20 then
        return false, { "HomeUpgrade需要20级及三维300范围" }
    end
    for _, field in ipairs({ "UiGroupId", "ButtonId", "PriceTextId", "LevelTextId", "ChickenTextId", "EggTextId" }) do
        if not Integer(c[field]) then return false, { "HomeUpgrade UI配置无效: " .. field } end
    end
    for level, row in ipairs(levels) do
        local expected = level == 1 and "100" or "1" .. string.rep("0", level + 2)
        if row.Level ~= level or row.ChickenCapacity ~= level + 4 or row.EggCapacity ~= level + 5
            or (level < 20 and (not Decimal.IsValid(row.UpgradeCost) or row.UpgradeCost ~= expected))
            or (level == 20 and row.UpgradeCost ~= nil) then return false, { "家园等级表不符合已确认数值，level=" .. tostring(level) } end
    end
    return true
end
function HomeUpgradeService:Start(context)
    if context.Side ~= "Server" then return end
    local home, economy = context.Services.HomeService, context.Services.EconomyService
    local config, messages = GameConfig.HomeUpgrade, context.NetMsg.Messages
    local runtime = { Active = true, Ready = false, Players = {}, Targets = {}, LastDisplay = {},
        Sequence = 0, Revision = 0, DisplayVersion = 0, Dead = {}, Departed = {}, PositionErrors = {} }
    context.Services.HomeUpgradeService = runtime
    local function Active() return runtime.Active and context.Services.HomeUpgradeService == runtime end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Ensure(playerId)
        if not Active() or runtime.Departed[playerId] then return nil end
        local homeId = home:GetPlayerHome(playerId)
        if not homeId or not home:IsOwner(playerId, homeId) then return nil end
        local generation = economy:GetSessionGeneration(playerId)
        local state = runtime.Players[playerId]
        if not state or state.homeId ~= homeId or (state.generation ~= nil and state.generation ~= generation) then
            state = { homeId = homeId, generation = generation, level = 1, lastRequestId = 0, busy = false }
            runtime.Players[playerId] = state
        elseif state.generation == nil then state.generation = generation end
        return state
    end
    -- 独立只读容量查询；初始1级可在经济启动通知前读取，不建立第二份容量状态。
    function runtime:GetLevel(playerId)
        local state = Ensure(playerId)
        return state and state.level or 1
    end
    function runtime:GetChickenCapacity(playerId) return GameConfig.HomeLevels[self:GetLevel(playerId)].ChickenCapacity end
    function runtime:GetEggCapacity(playerId) return GameConfig.HomeLevels[self:GetLevel(playerId)].EggCapacity end
    local function NextTarget() runtime.Sequence = runtime.Sequence + 1; return runtime.Sequence end
    local function SendState(playerId)
        if not Active() then return end
        local state, target = Ensure(playerId), runtime.Targets[playerId]
        local level = state and state.level or 1
        local row, nextRow = GameConfig.HomeLevels[level], GameConfig.HomeLevels[level + 1]
        runtime.Revision = runtime.Revision + 1
        System:SendToClient(playerId, messages.HomeUpgradeState, {
            kind = "interaction", version = runtime.Revision, sessionGeneration = state and state.generation,
            homeId = state and state.homeId, targetVersion = target and target.version or runtime.Sequence,
            elementId = target and target.elementId, visible = target ~= nil, busy = state ~= nil and state.busy,
            expectedLevel = level, chickenCapacity = row.ChickenCapacity, eggCapacity = row.EggCapacity,
            nextChickenCapacity = nextRow and nextRow.ChickenCapacity, nextEggCapacity = nextRow and nextRow.EggCapacity,
            upgradeCost = row.UpgradeCost,
        })
    end
    local function Clear(playerId)
        if not runtime.Targets[playerId] then return end
        runtime.Targets[playerId] = nil
        NextTarget()
        SendState(playerId)
    end
    local function Display(playerId)
        if not Active() or not runtime.Ready then return end
        local state = Ensure(playerId)
        if not state then return end
        local resources = home:GetUpgradeResources(state.homeId)
        if not resources or not resources.levelElementId then return end
        runtime.DisplayVersion = runtime.DisplayVersion + 1
        local message = { kind = "level", homeId = state.homeId, elementId = resources.levelElementId,
            level = state.level, displayVersion = runtime.DisplayVersion }
        runtime.LastDisplay[state.homeId] = message
        System:SendToAllClients(messages.HomeUpgradeState, message)
    end
    local function InRange(playerId, target)
        local ok, result = pcall(function()
            local p, q = Character:GetPosition(playerId), Element:GetPosition(target.elementId)
            if not p or not q then error("升级元件或玩家位置不可用") end
            return (p.X-q.X)^2 + (p.Y-q.Y)^2 + (p.Z-q.Z)^2 <= config.MaxDistance^2
        end)
        if not ok then
            local key = tostring(playerId) .. ":" .. tostring(target.elementId)
            if not runtime.PositionErrors[key] then
                runtime.PositionErrors[key] = true
                Log:PrintError("[HomeUpgrade] 位置读取失败，仅取消升级交互", "playerId:", playerId, "error:", tostring(result))
            end
        end
        return ok and result == true
    end
    local function Refresh(playerId)
        local target, state = runtime.Targets[playerId], Ensure(playerId)
        if not target then return nil end
        local resources = state and home:GetUpgradeResources(state.homeId)
        if not state or runtime.Dead[playerId] or target.generation ~= state.generation or target.homeId ~= state.homeId
            or not economy:IsCurrent(playerId, state.generation) or not resources
            or resources.upgradeElementId ~= target.elementId or not InRange(playerId, target) then
            Clear(playerId); return nil
        end
        return target
    end
    runtime.TouchCallback = Protect(function(elementId, playerId)
        if not runtime.Ready or not Integer(playerId) or runtime.Dead[playerId] then return end
        local state = Ensure(playerId)
        local resources = state and home:GetUpgradeResources(state.homeId)
        if not resources or resources.upgradeElementId ~= elementId or not economy:IsCurrent(playerId, state.generation) then return end
        local target = { homeId = state.homeId, generation = state.generation, elementId = elementId }
        if not InRange(playerId, target) then return end
        local previous = Refresh(playerId)
        if previous and previous.elementId == elementId then SendState(playerId); return end
        target.version = NextTarget()
        runtime.Targets[playerId] = target
        SendState(playerId)
    end)
    runtime.ActionCallback = Protect(function(_, message, playerId)
        if not runtime.Ready or not Integer(playerId) or type(message) ~= "table"
            or not Integer(message.requestId) or not Integer(message.expectedLevel)
            or not Integer(message.sessionGeneration) or not Integer(message.homeId) or not Integer(message.targetVersion) then return end
        local state, target = Ensure(playerId), Refresh(playerId)
        local function Result(success, reason)
            if not Active() then return end
            System:SendToClient(playerId, messages.HomeUpgradeResult, {
                requestId = message.requestId, homeId = message.homeId, sessionGeneration = message.sessionGeneration,
                targetVersion = message.targetVersion, expectedLevel = message.expectedLevel, success = success, reason = reason,
            })
        end
        if not state or not target or state.homeId ~= message.homeId or state.generation ~= message.sessionGeneration
            or target.version ~= message.targetVersion then Result(false, "interaction_expired"); return end
        if state.busy then Result(false, "upgrade_busy"); return end
        if message.requestId <= state.lastRequestId then Result(false, "stale_request"); return end
        state.lastRequestId = message.requestId
        if message.expectedLevel ~= state.level then Result(false, "stale_level"); return end
        if state.level >= config.MaxLevel then Result(false, "max_level"); return end
        local online = false
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do if id == playerId then online = true; break end end
        if not online or not economy:IsCurrent(playerId, state.generation) then Result(false, "session_unavailable"); return end
        state.busy = true
        local production = context.Services.EggProductionService
        if production then
            local ok, reason = production:AdvanceBeforeCapacityChange(playerId, state.homeId)
            if not ok then state.busy = false; Result(false, reason); return end
        end
        -- 旧容量推进可能发布成熟通知；再次校验，阻断通知重入和旧会话。
        if runtime.Players[playerId] ~= state or Ensure(playerId) ~= state or Refresh(playerId) ~= target
            or not economy:IsCurrent(playerId, state.generation) then
            state.busy = false; Result(false, "interaction_expired"); return
        end
        local cost = GameConfig.HomeLevels[state.level].UpgradeCost
        local debited, notify = economy:TryDebit(playerId, state.generation, cost)
        if not debited then state.busy = false; Result(false, notify); return end
        state.level = state.level + 1 -- 与扣款之间无引擎调用、通知或等待。
        target.version = NextTarget() -- 旧expectedLevel/目标代次不能再次扣款。
        local ok, err = pcall(notify)
        if not ok then Log:PrintError("[HomeUpgrade] 已升级后的钱币通知异常，不重试", tostring(err)) end
        if Active() and runtime.Players[playerId] == state and economy:IsCurrent(playerId, state.generation) then
            Display(playerId)
            context.Events:Publish("HomeLevelChanged", { playerId = playerId, homeId = state.homeId,
                sessionGeneration = state.generation, level = state.level })
            state.busy = false
            SendState(playerId)
            Result(true, "upgraded")
        end
    end)
    runtime.SnapshotCallback = Protect(function(_, _, playerId)
        if not runtime.Ready or not Integer(playerId) then return end
        for _, message in pairs(runtime.LastDisplay) do System:SendToClient(playerId, messages.HomeUpgradeState, message) end
        Refresh(playerId)
        SendState(playerId)
    end)
    runtime.LeaveCallback = Protect(function(playerId)
        Clear(playerId)
        runtime.Departed[playerId] = true
        runtime.Players[playerId], runtime.Dead[playerId] = nil, nil
    end)
    runtime.DeathCallback = Protect(function(playerId) runtime.Dead[playerId] = true; Clear(playerId) end)
    runtime.ReviveCallback = Protect(function(playerId) runtime.Dead[playerId] = nil; Clear(playerId) end)
    runtime.NativeBindings = {
        { Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback }, { Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback },
        { Events.ON_CHARACTER_KILLED, runtime.DeathCallback }, { Events.ON_CHARACTER_DESTROYED, runtime.DeathCallback },
        { Events.ON_CHARACTER_RESPAWN, runtime.ReviveCallback }, { Events.ON_CHARACTER_REVIVED, runtime.ReviveCallback },
    }
    for _, binding in ipairs(runtime.NativeBindings) do System:RegisterEvent(binding[1], binding[2]) end
    System:BindNotify(messages.HomeUpgradeAction, runtime.ActionCallback)
    System:BindNotify(messages.HomeUpgradeSnapshotRequest, runtime.SnapshotCallback)
    context.Events:Subscribe(self.Name, "HomeAssigned", Protect(function(state)
        runtime.Departed[state.playerId] = nil
        Clear(state.playerId)
        Ensure(state.playerId)
        Display(state.playerId)
    end))
    context.Events:Subscribe(self.Name, "HomeReleased", Protect(function(state)
        Clear(state.playerId)
        runtime.Players[state.playerId] = nil -- 场景最后等级显示保留。
    end))
    context.Events:Subscribe(self.Name, "EconomyChanged", Protect(function(state)
        local previous = runtime.Players[state.playerId]
        local generation = previous and previous.generation
        local current = Ensure(state.playerId)
        if current and generation ~= current.generation then Clear(state.playerId); Display(state.playerId) end
    end))
    local function InitializeDisplay()
        if not runtime.Ready or not home.UpgradeResourcesReady then return end
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Display(id) end
    end
    context.Events:Subscribe(self.Name, "HomeUpgradeResourcesReady", Protect(InitializeDisplay))
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function()
        runtime.Ready = true
        InitializeDisplay()
    end))
    context.Timers:AddLoopFrame(self.Name, 1, Protect(function()
        if not runtime.Ready then return end
        local ids = {}
        for id in pairs(runtime.Targets) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do Refresh(id) end
    end))
    runtime.Cleanup = function()
        for id in pairs(runtime.Targets) do Clear(id) end
        runtime.Active = false
        runtime.Players, runtime.Targets, runtime.LastDisplay = {}, {}, {}
    end
end
function HomeUpgradeService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.HomeUpgradeService
    if not runtime then return end
    runtime.Cleanup()
    for _, binding in ipairs(runtime.NativeBindings) do System:UnregisterEvent(binding[1], binding[2]) end
    System:UnbindNotify(context.NetMsg.Messages.HomeUpgradeAction, runtime.ActionCallback)
    System:UnbindNotify(context.NetMsg.Messages.HomeUpgradeSnapshotRequest, runtime.SnapshotCallback)
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.HomeUpgradeService = nil
end
return HomeUpgradeService
