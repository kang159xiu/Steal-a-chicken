local GameConfig = require "Common.Config.GameConfig"

local EggCollectionService = { Name = "EggCollectionService", FeatureFlag = "EggCollection",
    Dependencies = { "HomeService", "EggProductionService", "InventoryService" } }
local function Integer(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end
function EggCollectionService:ValidateConfig(context)
    local config = GameConfig.EggCollection
    if type(config) ~= "table" or config.UiGroupId ~= 100084 or config.CollectButtonId ~= 100083
        or config.MaxDistance ~= 300 then return false, { "EggCollection 必须使用UI100084/100083及三维范围300" } end
    return true
end

function EggCollectionService:Start(context)
    if context.Side ~= "Server" then return end
    local home, eggs, inventory = context.Services.HomeService, context.Services.EggProductionService,
        context.Services.InventoryService
    local runtime = { Ready = false, Stopped = false, Targets = {}, IndexByEgg = {}, IndexByElement = {},
        Dead = {}, Sequence = 0, Revision = 0, ListSessions = {}, ListDeparted = {}, ListVersion = 0, HomeSequence = 0 }
    context.Services.EggCollectionService = runtime
    local function Active() return not runtime.Stopped and context.Services.EggCollectionService == runtime end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, errorMessage = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(errorMessage)) end
        end
    end
    local function NextVersion() runtime.Sequence = runtime.Sequence + 1; return runtime.Sequence end
    -- 仅保存输入代次；场景蛋始终读取产蛋服务快照。
    local function NewListSession(playerId, homeId)
        runtime.HomeSequence = runtime.HomeSequence + 1
        local session = { homeId = homeId, homeVersion = runtime.HomeSequence, lastRequestId = 0, busy = false }
        runtime.ListSessions[playerId] = session
        return session
    end
    local function SendList(playerId, released)
        if not Active() or not runtime.Ready then return end
        local snapshot = not released and not runtime.ListDeparted[playerId] and eggs:GetEggSnapshot(playerId) or nil
        local homeId = snapshot and snapshot.homeId or nil
        local session = runtime.ListSessions[playerId]
        if not session or session.homeId ~= homeId then session = NewListSession(playerId, homeId) end
        local rows = {}
        for _, egg in ipairs(snapshot and snapshot.eggs or {}) do
            rows[#rows + 1] = { eggId = egg.eggId, chickenTypeId = egg.chickenTypeId,
                spawnedAtMs = egg.spawnedAtMs, hatchDeadlineMs = egg.hatchDeadlineMs, mature = egg.mature == true,
                baseSellPrice = egg.baseSellPrice, finalScaleUnits = egg.finalScaleUnits, finalSellPrice = egg.finalSellPrice }
        end
        table.sort(rows, function(a, b) return a.eggId < b.eggId end)
        runtime.ListVersion = runtime.ListVersion + 1
        System:SendToClient(playerId, context.NetMsg.Messages.EggCollectionListState, {
            version = runtime.ListVersion, homeId = homeId, homeVersion = session.homeVersion, eggs = rows,
            eggCount = snapshot and snapshot.count or 0,
            eggCapacity = snapshot and snapshot.capacity or GameConfig.Home.DefaultEggCapacity,
        })
    end
    runtime.ListSnapshotCallback = Protect(function(_, _, playerId)
        if runtime.Ready and Integer(playerId) and not runtime.ListDeparted[playerId] then SendList(playerId) end
    end)
    runtime.ListActionCallback = Protect(function(_, message, playerId)
        if not runtime.Ready or not Integer(playerId) or runtime.ListDeparted[playerId] or type(message) ~= "table"
            or not Integer(message.homeId) or not Integer(message.homeVersion) or not Integer(message.requestId)
            or (message.action ~= "single" and message.action ~= "all")
            or (message.action == "single" and not Integer(message.eggId)) then
            return end
        local session = runtime.ListSessions[playerId]
        local function Result(success, reason, results)
            if not Active() or runtime.ListSessions[playerId] ~= session then
                return end
            System:SendToClient(playerId, context.NetMsg.Messages.EggCollectionListResult, {
                homeId = message.homeId, homeVersion = message.homeVersion, requestId = message.requestId,
                action = message.action, eggId = message.eggId, success = success, reason = reason, results = results or {},
            })
        end
        if not session or session.homeId ~= message.homeId or session.homeVersion ~= message.homeVersion
            or not home:IsOwner(playerId, message.homeId) then
            Result(false, "stale_home"); return end
        if message.requestId <= session.lastRequestId then
            Result(false, "stale_request"); return end
        session.lastRequestId = message.requestId
        if session.busy then
            Result(false, "collection_busy"); return end
        -- 固定请求接收时的成熟集合，不使用可能尚未刷新过的mature字段。
        local snapshot = eggs:GetEggSnapshot(playerId)
        if not snapshot or snapshot.homeId ~= message.homeId then
            Result(false, "stale_home"); return end
        local ids, now = {}, MiscService:GetServerTimestamp()
        if message.action == "single" then ids[1] = message.eggId
        else
            for _, egg in ipairs(snapshot.eggs) do
                if now >= egg.hatchDeadlineMs then ids[#ids + 1] = egg.eggId end
            end
            table.sort(ids)
        end
        session.busy = true
        local results, success = {}, true
        for _, eggId in ipairs(ids) do
            if not Active() or runtime.ListSessions[playerId] ~= session
                or not home:IsOwner(playerId, message.homeId) then
                return end
            local ok, item, reason = pcall(function() return eggs:CollectEgg(playerId, eggId, inventory) end)
            if not ok then
                Log:PrintError("[EggCollectionList] 收取调用异常，不重试", "eggId:", eggId, "error:", tostring(item))
                item, reason = nil, "collection_exception"
            end
            if not item then success = false end
            results[#results + 1] = { eggId = eggId, success = item ~= nil, reason = reason }
        end
        if not Active() or runtime.ListSessions[playerId] ~= session then
            return end
        session.busy = false
        Result(success, not success and (message.action == "single" and results[1].reason or "partial_failure") or "collected", results)
        SendList(playerId)
    end)
    local function SendState(playerId)
        if not Active() then return end
        local target = runtime.Targets[playerId]
        runtime.Revision = runtime.Revision + 1
        System:SendToClient(playerId, context.NetMsg.Messages.EggCollectionState, {
            revision = runtime.Revision, version = target and target.version or runtime.Sequence,
            eggId = target and target.eggId, rootId = target and target.rootId, homeId = target and target.homeId,
            visible = target ~= nil, busy = target ~= nil and target.busy == true,
        })
    end
    local function Clear(playerId)
        local target = runtime.Targets[playerId]
        if not target then return end
        runtime.Targets[playerId] = nil
        NextVersion()
        if Active() then SendState(playerId) end
    end
    local function InRange(playerId, target)
        local ok, result = pcall(function()
            local playerPosition, position = Character:GetPosition(playerId), Element:GetPosition(target.rootId)
            if not playerPosition or not position then error("玩家或蛋根位置不可用") end
            local dx, dy, dz = playerPosition.X - position.X, playerPosition.Y - position.Y, playerPosition.Z - position.Z
            return dx * dx + dy * dy + dz * dz <= GameConfig.EggCollection.MaxDistance ^ 2
        end)
        if not ok and not target.positionErrorLogged then
            target.positionErrorLogged = true
            Log:PrintError("[EggCollection] 位置读取失败，仅取消该目标", "playerId:", playerId,
                "eggId:", target.eggId, "rootId:", target.rootId, "error:", tostring(result))
        end
        return ok and result == true
    end
    local function Refresh(playerId)
        local target = runtime.Targets[playerId]
        if not target then return nil end
        local egg = eggs:GetSceneEgg(target.eggId)
        if runtime.Dead[playerId] or not egg or egg.rootId ~= target.rootId
            or egg.playerId ~= playerId or not home:IsOwner(playerId, target.homeId)
            or not InRange(playerId, target) then
            Clear(playerId)
            return nil
        end
        return target
    end
    local function RemoveIndex(eggId)
        local entry = runtime.IndexByEgg[eggId]
        if entry then
            runtime.IndexByEgg[eggId] = nil
            for _, id in ipairs(entry.elementIds or {}) do
                if runtime.IndexByElement[id] == entry then runtime.IndexByElement[id] = nil end
            end
        end
        local players = {}
        for playerId, target in pairs(runtime.Targets) do
            if target.eggId == eggId then players[#players + 1] = playerId end
        end
        for _, playerId in ipairs(players) do Clear(playerId) end
    end
    local function QueueIndex(egg)
        if not Active() or not runtime.Ready then return end
        local previous = runtime.IndexByEgg[egg.eggId]
        if previous and previous.rootId == egg.rootId and previous.version == egg.version then return end
        RemoveIndex(egg.eggId)
        local entry = { eggId = egg.eggId, rootId = egg.rootId, homeId = egg.homeId,
            playerId = egg.playerId, version = egg.version }
        runtime.IndexByEgg[egg.eggId] = entry
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() or not runtime.Ready or runtime.IndexByEgg[entry.eggId] ~= entry then return end
            local current = eggs:GetSceneEgg(entry.eggId)
            if not current or current.rootId ~= entry.rootId or current.version ~= entry.version then return end
            local ok, result = pcall(function()
                if not Element:GetPosition(entry.rootId) then error("蛋根对象不可用") end
                local ids, visited = {}, {}
                local function Visit(id)
                    if visited[id] then error("蛋碰撞树重复或循环") end
                    visited[id] = true
                    ids[#ids + 1] = id
                    for _, childId in ipairs(Element:GetChildElementsFromElement(id) or {}) do Visit(childId) end
                end
                Visit(entry.rootId)
                return ids
            end)
            if not ok then
                Log:PrintError("[EggCollection] 蛋碰撞索引失败，不自动重试", "eggId:", entry.eggId,
                    "rootId:", entry.rootId, "error:", tostring(result))
                return
            end
            entry.elementIds = result
            for _, id in ipairs(result) do runtime.IndexByElement[id] = entry end
        end)
    end
    runtime.TouchCallback = Protect(function(elementId, playerId)
        if not Active() or not runtime.Ready or not Integer(playerId) or runtime.Dead[playerId] then return end
        local entry = runtime.IndexByElement[elementId]
        if not entry then return end
        local egg = eggs:GetSceneEgg(entry.eggId)
        if not egg or egg.rootId ~= entry.rootId or egg.version ~= entry.version
            or egg.playerId ~= playerId or not home:IsOwner(playerId, egg.homeId) then return end
        if not InRange(playerId, entry) then return end
        local previous = runtime.Targets[playerId]
        if previous and previous.eggId == egg.eggId and previous.rootId == egg.rootId then return end
        local target = { eggId = egg.eggId, rootId = egg.rootId, homeId = egg.homeId,
            version = NextVersion(), busy = false }
        runtime.Targets[playerId] = target
        SendState(playerId)
    end)
    runtime.ActionCallback = Protect(function(_, message, playerId)
        if not Active() or not runtime.Ready or not Integer(playerId) or type(message) ~= "table"
            or not Integer(message.eggId) or not Integer(message.version) then return end
        local target = Refresh(playerId)
        if not target or target.eggId ~= message.eggId or target.version ~= message.version or target.busy then return end
        target.busy = true
        SendState(playerId)
        local item, reason = eggs:CollectEgg(playerId, target.eggId, inventory)
        if not Active() then return end
        if runtime.Targets[playerId] == target then
            target.busy = false
            if item then Clear(playerId) else SendState(playerId) end
        end
        System:SendToClient(playerId, context.NetMsg.Messages.EggCollectionResult, {
            eggId = target.eggId, version = target.version, success = item ~= nil, reason = reason,
        })
    end)
    runtime.CancelCallback = Protect(function(_, message, playerId)
        if not Active() or not Integer(playerId) or type(message) ~= "table" then return end
        local target = runtime.Targets[playerId]
        if target and target.eggId == message.eggId and target.version == message.version then Clear(playerId) end
    end)
    runtime.SnapshotCallback = Protect(function(_, _, playerId)
        if not Active() or not runtime.Ready or not Integer(playerId) then return end
        Refresh(playerId)
        SendState(playerId) -- 只返已有本人目标，不选择附近蛋。
    end)
    runtime.LeaveCallback = Protect(function(playerId)
        if Active() then
            Clear(playerId)
            runtime.ListDeparted[playerId] = true
            NewListSession(playerId, nil)
            SendList(playerId, true)
            runtime.Dead[playerId] = nil
        end
    end)
    runtime.DeathCallback = Protect(function(playerId)
        if not Active() then return end
        runtime.Dead[playerId] = true
        Clear(playerId)
    end)
    runtime.ReviveCallback = Protect(function(playerId)
        if not Active() then return end
        Clear(playerId)
        runtime.Dead[playerId] = nil
    end)
    System:RegisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    System:RegisterEvent(Events.ON_CHARACTER_KILLED, runtime.DeathCallback)
    System:RegisterEvent(Events.ON_CHARACTER_DESTROYED, runtime.DeathCallback)
    System:RegisterEvent(Events.ON_CHARACTER_RESPAWN, runtime.ReviveCallback)
    System:RegisterEvent(Events.ON_CHARACTER_REVIVED, runtime.ReviveCallback)
    System:BindNotify(context.NetMsg.Messages.EggCollectionAction, runtime.ActionCallback)
    System:BindNotify(context.NetMsg.Messages.EggCollectionCancel, runtime.CancelCallback)
    System:BindNotify(context.NetMsg.Messages.EggCollectionSnapshotRequest, runtime.SnapshotCallback)
    System:BindNotify(context.NetMsg.Messages.EggCollectionListSnapshotRequest, runtime.ListSnapshotCallback)
    System:BindNotify(context.NetMsg.Messages.EggCollectionListAction, runtime.ListActionCallback)
    context.Events:Subscribe(self.Name, "EggSpawned", function(state) QueueIndex(state); SendList(state.playerId) end)
    context.Events:Subscribe(self.Name, "HomeLevelChanged", function(state) SendList(state.playerId) end)
    context.Events:Subscribe(self.Name, "EggHatched", function(state) SendList(state.playerId) end)
    context.Events:Subscribe(self.Name, "EggRemoved", function(state) RemoveIndex(state.eggId); SendList(state.playerId) end)
    context.Events:Subscribe(self.Name, "HomeReleased", function(state)
        Clear(state.playerId)
        NewListSession(state.playerId, nil)
        SendList(state.playerId, true)
    end)
    context.Events:Subscribe(self.Name, "HomeAssigned", function(state)
        Clear(state.playerId)
        runtime.Dead[state.playerId] = nil
        runtime.ListDeparted[state.playerId] = nil
        NewListSession(state.playerId, state.homeId)
        SendList(state.playerId)
    end)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if not Active() then return end
        runtime.Ready = true
        for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do
            local snapshot = eggs:GetEggSnapshot(playerId)
            for _, egg in ipairs(snapshot and snapshot.eggs or {}) do QueueIndex(egg) end
            SendList(playerId)
        end
    end)
    context.Timers:AddLoopFrame(self.Name, 1, function()
        if not Active() or not runtime.Ready then return end
        local players = {}
        for playerId in pairs(runtime.Targets) do players[#players + 1] = playerId end
        for _, playerId in ipairs(players) do Refresh(playerId) end
    end)
    runtime.Cleanup = function()
        -- 关闭通知在失效前发送；之后旧碰撞、请求和两帧回调均无效。
        for playerId in pairs(runtime.Targets) do Clear(playerId) end
        for playerId in pairs(runtime.ListSessions) do
            NewListSession(playerId, nil)
            SendList(playerId, true)
        end
        runtime.Stopped = true
        runtime.Targets, runtime.IndexByEgg, runtime.IndexByElement, runtime.Dead = {}, {}, {}, {}
        runtime.ListSessions = {}
        runtime.ListDeparted = {}
    end
end

function EggCollectionService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.EggCollectionService
    if not runtime then return end
    runtime.Cleanup()
    System:UnregisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    System:UnregisterEvent(Events.ON_CHARACTER_KILLED, runtime.DeathCallback)
    System:UnregisterEvent(Events.ON_CHARACTER_DESTROYED, runtime.DeathCallback)
    System:UnregisterEvent(Events.ON_CHARACTER_RESPAWN, runtime.ReviveCallback)
    System:UnregisterEvent(Events.ON_CHARACTER_REVIVED, runtime.ReviveCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionAction, runtime.ActionCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionCancel, runtime.CancelCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionSnapshotRequest, runtime.SnapshotCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionListSnapshotRequest, runtime.ListSnapshotCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionListAction, runtime.ListActionCallback)
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.EggCollectionService = nil
end

return EggCollectionService
