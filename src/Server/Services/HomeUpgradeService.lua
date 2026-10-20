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
    if c.InitialUnlockedSlots ~= 5 or c.SlotColorArea ~= 1 or c.UnlockedSlotColor ~= "#BFB6DFFF" or c.LockedSlotColor ~= "#8C8C8CFF" then return false, { "放置位解锁配置不符合已确认规则" } end
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
    local persistence = context.Services.PersistenceService
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id))
    end
    local function PrepareLeave(id)
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(id) end
    end
    local function Active() return runtime.Active and context.Services.HomeUpgradeService == runtime end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function InitialSlots()
        local slots = {}
        for i = 1, config.InitialUnlockedSlots do slots[i] = true end
        return slots
    end
    local function SlotNumbers(state)
        local slots = {}
        for slot in pairs(state and state.unlocked or {}) do slots[#slots + 1] = slot end
        table.sort(slots)
        return slots
    end
    local function Ensure(playerId)
        if not Active() or runtime.Departed[playerId] then return nil end
        local homeId = home:GetPlayerHome(playerId)
        if not homeId or not home:IsOwner(playerId, homeId) then return nil end
        local generation = economy:GetSessionGeneration(playerId)
        local state = runtime.Players[playerId]
        if not state or state.homeId ~= homeId or (state.generation ~= nil and state.generation ~= generation) then
            state = { homeId = homeId, generation = generation, level = 1, unlocked = InitialSlots(), lastRequestId = 0, busy = false }
            runtime.Players[playerId] = state
        elseif state.generation == nil then state.generation = generation end
        return state
    end
    -- 独立只读容量查询；初始1级可在经济启动通知前读取，不建立第二份容量状态。
    function runtime:GetLevel(playerId)
        local state = Ensure(playerId)
        return state and state.level or 1
    end
    function runtime:GetUnlockedSlots(playerId) return SlotNumbers(Ensure(playerId)) end
    function runtime:IsSlotUnlocked(playerId, slotIndex)
        local state = Ensure(playerId)
        return state ~= nil and state.unlocked[slotIndex] == true
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
            entry = target and target.entry, slotIndex = target and target.slotIndex, unlockedSlots = SlotNumbers(state),
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
    local function DisplayHome(homeId, state)
        if not Active() or not runtime.Ready then return end
        local resources = home:GetUpgradeResources(homeId)
        local previous = runtime.LastDisplay[homeId]
        runtime.DisplayVersion = runtime.DisplayVersion + 1
        local message = { kind = "level", homeId = homeId, elementId = resources and resources.levelElementId,
            playerId = home.HomeToPlayer[homeId], level = state and state.level or (previous and previous.level or 1),
            unlockedSlots = SlotNumbers(state), slots = home:GetPlacementSlots(homeId), displayVersion = runtime.DisplayVersion }
        runtime.LastDisplay[homeId] = message
        System:SendToAllClients(messages.HomeUpgradeState, message)
    end
    local function Display(playerId)
        local state = Ensure(playerId)
        if state then DisplayHome(state.homeId, state) end
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
        local validTarget = false
        if state and target.entry == "home" then
            local resources = home:GetUpgradeResources(state.homeId)
            validTarget = resources ~= nil and resources.upgradeElementId == target.elementId
        elseif state and target.entry == "placement" then
            local slot = home:GetPlacementSlot(playerId, target.elementId)
            validTarget = slot ~= nil and slot.homeId == state.homeId and slot.slotIndex == target.slotIndex
                and not state.unlocked[target.slotIndex]
        end
        if not state or not CanPlay(playerId) or runtime.Dead[playerId] or target.generation ~= state.generation or target.homeId ~= state.homeId
            or not economy:IsCurrent(playerId, state.generation) or not validTarget or not InRange(playerId, target) then
            Clear(playerId); return nil
        end
        return target
    end
    runtime.TouchCallback = Protect(function(elementId, playerId)
        if not CanPlay(playerId) or not runtime.Ready or not Integer(playerId) or runtime.Dead[playerId] then return end
        local state = Ensure(playerId)
        local resources = state and home:GetUpgradeResources(state.homeId)
        if not resources or resources.upgradeElementId ~= elementId or not economy:IsCurrent(playerId, state.generation) then return end
        local target = { homeId = state.homeId, generation = state.generation, elementId = elementId, entry = "home" }
        if not InRange(playerId, target) then return end
        local previous = Refresh(playerId)
        if previous and previous.elementId == elementId then SendState(playerId); return end
        target.version = NextTarget()
        runtime.Targets[playerId] = target
        SendState(playerId)
    end)
    -- 放置服务仅请求打开界面；扣款/等级/解锁集合仍由本模块唯一提交。
    function runtime:OpenPlacementUpgrade(playerId, elementId, slotIndex)
        if not Active() or not self.Ready or not CanPlay(playerId) or self.Dead[playerId] then return false, "session_unavailable" end
        local state, slot = Ensure(playerId), home:GetPlacementSlot(playerId, elementId)
        if not state or not slot or slot.homeId ~= state.homeId or slot.slotIndex ~= slotIndex
            or not economy:IsCurrent(playerId, state.generation) then return false, "interaction_expired" end
        if state.unlocked[slotIndex] then return false, "slot_already_unlocked" end
        local target = { homeId = state.homeId, generation = state.generation, elementId = elementId,
            entry = "placement", slotIndex = slotIndex }
        if not InRange(playerId, target) then return false, "interaction_expired" end
        if state.busy then return false, "upgrade_busy" end
        target.version = NextTarget()
        self.Targets[playerId] = target
        SendState(playerId)
        return true
    end
    runtime.ActionCallback = Protect(function(_, message, playerId)
        if not CanPlay(playerId) then return end
        if not runtime.Ready or not Integer(playerId) or type(message) ~= "table"
            or not Integer(message.requestId) or not Integer(message.expectedLevel)
            or not Integer(message.sessionGeneration) or not Integer(message.homeId) or not Integer(message.targetVersion) then return end
        local state, target = Ensure(playerId), Refresh(playerId)
        local function Result(success, reason)
            if not Active() then return end
            System:SendToClient(playerId, messages.HomeUpgradeResult, {
                requestId = message.requestId, homeId = message.homeId, sessionGeneration = message.sessionGeneration,
                targetVersion = message.targetVersion, expectedLevel = message.expectedLevel, entry = message.entry, slotIndex = message.slotIndex, success = success, reason = reason,
            })
        end
        if not state or not target or state.homeId ~= message.homeId or state.generation ~= message.sessionGeneration
            or target.version ~= message.targetVersion or target.entry ~= message.entry or target.slotIndex ~= message.slotIndex then Result(false, "interaction_expired"); return end
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
        local unlockSlot = target.slotIndex
        if target.entry == "home" then
            for _, slot in ipairs(home:GetPlacementSlots(state.homeId)) do
                if not state.unlocked[slot.slotIndex] then unlockSlot = slot.slotIndex; break end
            end
        end
        if not unlockSlot or state.unlocked[unlockSlot] then state.busy = false; Result(false, "no_locked_slot"); return end
        local cost = GameConfig.HomeLevels[state.level].UpgradeCost
        local debited, notify = economy:TryDebit(playerId, state.generation, cost)
        if not debited then state.busy = false; Result(false, notify); return end
        state.level = state.level + 1 -- 与扣款和解锁提交之间无引擎调用、通知或等待。
        state.unlocked[unlockSlot] = true
        if CanPlay(playerId) and persistence then persistence:MarkDirty(playerId, "home_upgrade") end
        target.version = NextTarget() -- 旧expectedLevel/目标代次不能再次扣款。
        local ok, err = pcall(notify)
        if not ok then Log:PrintError("[HomeUpgrade] 已升级后的钱币通知异常，不重试", tostring(err)) end
        if Active() and runtime.Players[playerId] == state and economy:IsCurrent(playerId, state.generation) then
            Display(playerId)
            context.Events:Publish("HomeLevelChanged", { playerId = playerId, homeId = state.homeId,
                sessionGeneration = state.generation, level = state.level })
            state.busy = false
            if target.entry == "placement" then runtime.Targets[playerId] = nil end
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
        PrepareLeave(playerId)
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
        DisplayHome(state.homeId, nil)
    end))
    context.Events:Subscribe(self.Name, "EconomyChanged", Protect(function(state)
        local previous = runtime.Players[state.playerId]
        local generation = previous and previous.generation
        local current = Ensure(state.playerId)
        if current and generation ~= current.generation then Clear(state.playerId); Display(state.playerId) end
    end))
    local function InitializeDisplay()
        if not runtime.Ready or not home.UpgradeResourcesReady then return end
        for _, homeId in ipairs(GameConfig.Home.RootElementIds) do
            local playerId = home.HomeToPlayer[homeId]
            DisplayHome(homeId, playerId and Ensure(playerId) or nil)
        end
    end
    context.Events:Subscribe(self.Name, "HomeUpgradeResourcesReady", Protect(InitializeDisplay))
    context.Events:Subscribe(self.Name, "HomePlacementResourcesReady", Protect(InitializeDisplay))
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
    if GameConfig.Persistence.ProductionEnabled then
        assert(persistence:RegisterAdapter("home", {
            Export = function(id)
                local state = runtime.Players[id]
                if not state then return nil, "home_state_missing" end
                return { version = 2, level = state.level, unlockedSlots = SlotNumbers(state) }
            end,
            Restore = function(id, data, done)
                local level, unlocked = 1, InitialSlots()
                if data ~= nil then
                    if data.version ~= 2 then done(false, "home_snapshot_version_incompatible_requires_user_cleanup"); return end
                    level = data.level
                    if not Integer(level) or level > config.MaxLevel or type(data.unlockedSlots) ~= "table"
                        or #data.unlockedSlots ~= level + 4 then done(false, "invalid_home_unlock_snapshot"); return end
                    unlocked = {}
                    local validSlots, count = {}, 0
                    local homeId = home:GetPlayerHome(id)
                    for _, slot in ipairs(home:GetPlacementSlots(homeId)) do validSlots[slot.slotIndex] = true end
                    for key, slot in pairs(data.unlockedSlots) do
                        if not Integer(key) or key > #data.unlockedSlots or not Integer(slot) or not validSlots[slot] or unlocked[slot] then
                            done(false, "invalid_home_unlock_snapshot"); return
                        end
                        unlocked[slot] = true; count = count + 1
                    end
                    if count ~= #data.unlockedSlots then done(false, "invalid_home_unlock_snapshot"); return end
                    for i = 1, config.InitialUnlockedSlots do if not unlocked[i] then done(false, "missing_initial_unlocked_slot"); return end end
                else
                    local validSlots = {}
                    for _, slot in ipairs(home:GetPlacementSlots(home:GetPlayerHome(id))) do validSlots[slot.slotIndex] = true end
                    for i = 1, config.InitialUnlockedSlots do if not validSlots[i] then done(false, "initial_placement_slot_missing"); return end end
                end
                local state = Ensure(id)
                if not state then done(false, "home_unavailable"); return end
                state.level, state.unlocked = level, unlocked
                done(true, function() Display(id); SendState(id); return true end)
            end,
            Cleanup = function(id) runtime.LeaveCallback(id) end,
        }))
    end
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
