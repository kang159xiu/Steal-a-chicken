local GameConfig = require "Common.Config.GameConfig"
local SafeCall = require "Common.Core.SafeCall"
local Decimal = require "Common.DecimalInteger"
local ReplicaDiag = require "Common.Debug.TreadmillReplicaDiag"
local RestoreDiag = require "Common.Debug.HomeModelRestoreDiag"
local PreplacedConfig = require "Common.Config.TreadmillPreplaced"
local PreplacedPool = require "Server.TreadmillPreplaced"
local TreadmillService = { Name = "TreadmillService", FeatureFlag = "Treadmill",
    Dependencies = { "HomeService", "EconomyService", "PlayerSpeedService" } }
local function Integer(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end
function TreadmillService:Start(context)
    if context.Side ~= "Server" then return end
    local c, rows, messages = GameConfig.Treadmill, GameConfig.TreadmillLevels, context.NetMsg.Messages
    local home, economy, speed = context.Services.HomeService, context.Services.EconomyService, context.Services.PlayerSpeedService
    local preplaced = PreplacedConfig.Enabled and PreplacedPool.new() or nil
    local rt = { Active = true, Ready = false, Players = {}, Departed = {}, Dead = {}, OwnedRoots = {},
        Version = 0, TargetVersion = 0, ReplicaVersion = 0, Replicas = {}, InitialQueue = {} }
    context.Services.TreadmillService = rt
    local persistence = context.Services.PersistenceService
    local function Diag(stage, id, state, op, reason)
        RestoreDiag.Log("Server", "treadmill", stage, function()
            return { playerId = id, homeId = state and state.homeId, level = state and state.level,
                operation = op and op.targetVersion, rootId = op and op.rootId or (state and state.rootId),
                templateId = state and rows[(op and op.level) or state.level].TemplateRootId,
                queueCount = #rt.InitialQueue, reason = reason }
        end)
    end
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id))
    end
    local function PrepareLeave(id)
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(id) end
    end
    local function Active() return rt.Active and context.Services.TreadmillService == rt end
    local function Protect(callback)
        return SafeCall.Protect(Active, function(err) context.Manager:FailModule(self.Name, tostring(err)) end, callback)
    end
    local function NextTarget() rt.TargetVersion = rt.TargetVersion + 1; return rt.TargetVersion end
    local function Online(id)
        for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do if playerId == id then return true end end
        return false
    end
    local function Current(id, state)
        return Active() and rt.Ready and rt.Players[id] == state and not rt.Departed[id] and Online(id)
            and economy:IsCurrent(id, state.generation) and home:IsOwner(id, state.homeId)
    end
    local function Inside(id, state)
        if not CanPlay(id) or not Current(id, state) or rt.Dead[id] or state.disabled then return false end
        local ok, result = pcall(function() return TriggerBox:IsCharacterInTriggerBox(id, state.triggerId) end)
        if not ok and not state.triggerError then
            state.triggerError = true; Log:PrintError("[Treadmill] 触发盒读取失败", "homeId:", state.homeId, tostring(result))
        end
        return ok and result == true
    end
    local function SendReplicas(recipient, entry)
        pcall(function()
            local models = {}
            if entry then models[1] = entry
            else for _, model in pairs(rt.Replicas) do models[#models + 1] = model end end
            if recipient then System:SendToClient(recipient, messages.TreadmillReplicaDiag, { models = models })
            else System:SendToAllClients(messages.TreadmillReplicaDiag, { models = models }) end
            RestoreDiag.Log("Server", "treadmill", "models_sent", function()
                local ids = {}; for _, model in ipairs(models) do ids[#ids + 1] = tostring(model.rootId) end
                return { recipient = recipient or "all", count = #models, rootIds = table.concat(ids, ",") }
            end)
        end)
    end
    local function CommitReplica(id, state, op)
        pcall(function()
            rt.ReplicaVersion = rt.ReplicaVersion + 1
            local entry = { playerId = id, homeId = state.homeId, level = state.level,
                sessionGeneration = state.generation, operation = op.targetVersion,
                version = rt.ReplicaVersion, rootId = state.rootId, positionId = state.positionId,
                templateId = rows[state.level].TemplateRootId, nodeIds = op.replicaNodeIds }
            rt.Replicas[state.homeId] = entry
            Diag("model_committed", id, state, op)
            ReplicaDiag.Sample("Server", entry, "committed")
            SendReplicas(nil, entry)
        end)
    end
    local function Destroy(rootId, reason, lease)
        if not rootId or not rt.OwnedRoots[rootId] then return end
        if preplaced and rt.OwnedRoots[rootId] ~= lease then return end
        RestoreDiag.Log("Server", "treadmill", preplaced and "model_recycled" or "model_destroy",
            { rootId = rootId, reason = reason or "owned_root_cleanup" })
        rt.OwnedRoots[rootId] = nil
        pcall(function()
            for homeId, entry in pairs(rt.Replicas) do
                if entry.rootId == rootId then
                    rt.ReplicaVersion = rt.ReplicaVersion + 1
                    local cleared = { homeId = homeId, version = rt.ReplicaVersion, cleared = true }
                    rt.Replicas[homeId] = cleared
                    SendReplicas(nil, cleared)
                end
            end
        end)
        local ok, result = pcall(function()
            if preplaced then return preplaced:Release(rootId, lease) end
            return context.ElementCopy:DestroyTree(rootId)
        end)
        if not ok or result ~= true then Log:PrintError("[Treadmill] 运行模型清理失败，不重试", rootId, tostring(result)) end
    end
    local function UpdatePreview(id, state, snapshot)
        snapshot = snapshot or speed:GetSnapshot(id)
        local level = state and state.level or 1
        local amount = snapshot and speed:GetExperiencePerTick(id, snapshot.sessionGeneration, rows[level].ExperiencePerTick)
        local nextAmount = snapshot and rows[level + 1] and speed:GetExperiencePerTick(id, snapshot.sessionGeneration, rows[level + 1].ExperiencePerTick)
        if state and amount then home:UpdateTreadmillExperienceText(state.homeId, level, amount) end
        return amount, nextAmount
    end
    local function Send(id)
        if not Active() or not rt.Ready then return end
        local state = rt.Players[id]
        local snapshot = speed:GetSnapshot(id)
        if state and (rt.Players[id] ~= state or not snapshot) then return end
        rt.Version = rt.Version + 1
        local level = state and state.level or 1
        local amount, nextAmount
        if snapshot then amount, nextAmount = UpdatePreview(id, state, snapshot) end
        System:SendToClient(id, messages.TreadmillState, {
            version = rt.Version, sessionGeneration = state and state.generation or (snapshot and snapshot.sessionGeneration), homeId = state and state.homeId,
            targetVersion = state and state.targetVersion or rt.TargetVersion, triggerId = state and state.triggerId,
            training = state ~= nil and state.training == true, busy = state ~= nil and state.operation ~= nil,
            expectedLevel = level, upgradeCost = rows[level].UpgradeCost, experiencePerTick = amount, nextExperiencePerTick = nextAmount,
            speedLevel = snapshot and snapshot.speedLevel, experience = snapshot and snapshot.experience,
            speedUpgradeExperience = snapshot and snapshot.speedUpgradeExperience,
            speedUpgradeRequirement = snapshot and snapshot.speedUpgradeRequirement,
            walkSpeed = snapshot and snapshot.walkSpeed, rebirthCount = snapshot and snapshot.rebirthCount,
            multiplier = snapshot and snapshot.multiplier,
        })
    end
    local function StartNextInitial()
        if not Active() or not rt.Ready or rt.InitialCurrent or rt.InitialTimer then return end
        local op = table.remove(rt.InitialQueue, 1)
        if not op then return end
        rt.InitialCurrent = op
        Diag("queue_start", op.playerId, op.state, op)
        op.start()
    end
    local function FinishInitial(op)
        if rt.InitialCurrent ~= op then return end
        Diag("queue_finished", op.playerId, op.state, op)
        rt.InitialCurrent = nil
        if not Active() then return end
        rt.InitialTimer = context.Timers:AddTimer(self.Name, c.InitialSpawnIntervalSeconds, function()
            rt.InitialTimer = nil
            StartNextInitial()
        end)
        if op.onInitialFinished then op.onInitialFinished() end
    end
    local function CancelOperation(state)
        local op = state.operation
        state.operation = nil
        if op then
            Diag("operation_cancelled", op.playerId, state, op)
            op.invalid = true
            if not op.reusesCurrent then Destroy(op.rootId, "operation_cancelled", op.modelLease) end
            for i, pending in ipairs(rt.InitialQueue) do
                if pending == op then
                    table.remove(rt.InitialQueue, i)
                    if op.onInitialFinished then op.onInitialFinished() end
                    break
                end
            end
            -- 在途复制没有取消接口；等待原回调/超时收尾后再释放队列，避免重叠。
            if op.reset and not op.initial and op.result then op.result(false, "reset_cancelled") end
        end
    end
    local function StopTraining(id, state)
        if not state then return end
        local changed = state.training or (state.operation and state.operation.upgrade)
        if state.training then speed:FlushExperience(id) end
        state.training = false
        if state.operation and state.operation.upgrade then CancelOperation(state) end
        if changed then state.targetVersion = NextTarget(); Send(id) end
    end
    local function Drop(id, reason)
        local state = rt.Players[id]
        Diag("player_model_cleanup", id, state, state and state.operation, reason)
        rt.Players[id] = nil
        if state then CancelOperation(state); Destroy(state.rootId, reason, state.modelLease); NextTarget() end
    end
    local function CopyDiagnosticId(id, state, level)
        return "Treadmill:" .. state.homeId .. ":" .. level .. ":player=" .. tostring(id)
            .. ":session=" .. tostring(state.generation) .. ":target=" .. tostring(state.targetVersion)
    end
    local function CopyModel(id, state, level, upgrade, result, reset, initial)
        local op = { level = level, upgrade = upgrade, targetVersion = state.targetVersion, reset = reset, result = result,
            playerId = id, state = state, initial = initial }
        state.operation = op
        local function Valid()
            return Current(id, state) and not rt.Dead[id] and state.operation == op and not op.invalid
                and (not upgrade or (state.training and state.targetVersion == op.targetVersion and Inside(id, state)))
        end
        local function FinishFailure(reason, disable, copyFailed)
            Diag("copy_failed", id, state, op, reason)
            if state.operation ~= op then FinishInitial(op); return end
            state.operation = nil
            if disable and not copyFailed then state.disabled = true; state.training = false; state.targetVersion = NextTarget() end
            Log:PrintError("[Treadmill] 模型操作失败，未扣款/未升级", "homeId:", state.homeId, "level:", level, "reason:", tostring(reason))
            if result and (reset or Current(id, state)) then result(false, reason, copyFailed) end
            Send(id)
            FinishInitial(op)
        end
        local function StartCopy()
            if initial and not Valid() then
                Diag("queue_skipped", id, state, op, "operation_not_current_or_player_unavailable")
                if state.operation == op then CancelOperation(state) end
                FinishInitial(op)
                return
            end
            local position, rotation
            local readOk, readError = pcall(function()
                position, rotation = Element:GetPosition(state.positionId), Element:GetRotation(state.positionId)
                if not position or not rotation then error("跑步机位置或旋转不可用") end
            end)
            if not readOk then FinishFailure(tostring(readError), not reset); return op end
            local ok, err = pcall(function()
                Diag(preplaced and "preplaced_requested" or "copy_requested", id, state, op)
                local function ModelReady(copy)
                    RestoreDiag.Log("Server", "treadmill", preplaced and "preplaced_acquired" or "copy_result", function()
                        return { playerId = id, homeId = state.homeId, operation = op.targetVersion,
                            templateId = rows[level].TemplateRootId, success = copy.success, rootId = copy.rootId,
                            reason = copy.reason, nodeCount = copy.spawnedIds and #copy.spawnedIds }
                    end)
                    -- 此回调不能使用Active包装：Stop后到达的完整复制也必须清理。
                    if type(copy) ~= "table" or copy.success ~= true or not Integer(copy.rootId) then
                        if Active() then FinishFailure(type(copy) == "table" and copy.reason or "copy_failed", not upgrade and not reset, true)
                        else FinishInitial(op) end
                        return -- 部分失败副本按ElementCopy契约保留，不重试。
                    end
                    local root = copy.rootId
                    if not preplaced then
                        for _, row in ipairs(rows) do
                            if row.TemplateRootId == root then FinishFailure("copy_returned_source", not upgrade and not reset); return end
                        end
                    end
                    op.modelLease, op.reusesCurrent = copy.modelLease, copy.reusesCurrent
                    rt.OwnedRoots[root] = preplaced and op.modelLease or true; op.rootId = root
                    op.replicaNodeIds = copy.spawnedIds
                    local function Discard()
                        if not op.reusesCurrent then Destroy(root, "operation_not_committed", op.modelLease) end
                    end
                    if not Valid() then Discard(); FinishInitial(op); return end
                    local rotated, rotationError = pcall(function()
                        Element:SetRotation(root, rotation, Element.COORDINATE.World)
                        if preplaced then Element:SetPosition(root, position, Element.COORDINATE.World) end
                    end)
                    if not rotated then Discard(); FinishFailure(tostring(rotationError), not upgrade and not reset); return end
                    if not Valid() then Discard(); FinishInitial(op); return end
                    context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                        if not Valid() then Discard(); FinishInitial(op); return end
                        local verified, verifyError = pcall(function()
                            local actual = Element:GetPosition(root)
                            if not actual or math.abs(actual.X-position.X) > 0.1 or math.abs(actual.Y-position.Y) > 0.1
                                or math.abs(actual.Z-position.Z) > 0.1 then error("模型实际位置不匹配") end
                            local actualRotation = Element:GetRotation(root)
                            if not actualRotation then error("模型实际旋转不可用") end
                            for _, axis in ipairs({ "X", "Y", "Z" }) do
                                local delta = (actualRotation[axis] - rotation[axis] + 180) % 360 - 180
                                if math.abs(delta) > 0.1 then error("模型实际旋转不匹配: " .. axis) end
                            end
                        end)
                        if not verified then Discard(); FinishFailure(tostring(verifyError), not upgrade and not reset); return end
                        RestoreDiag.Sample("Server", "treadmill", "transform_verified", { playerId = id,
                            homeId = state.homeId, operation = op.targetVersion, rootId = root, templateId = rows[level].TemplateRootId })
                        if not Valid() then Discard(); FinishInitial(op); return end
                        if reset then op.prepared = true; if result then result(true, op) end; FinishInitial(op); return end
                        local oldRoot, oldLease, notify = state.rootId, state.modelLease, nil
                        if upgrade then
                            if state.level + 1 ~= level then Discard(); FinishFailure("stale_level", false); return end
                            local debited, value = economy:TryDebit(id, state.generation, rows[state.level].UpgradeCost)
                            if not debited then Discard(); FinishFailure(value, false); return end
                            state.level = level -- 扣款后立即提交，无等待/引擎调用/通知。
                            notify = value
                        end
                        if upgrade and persistence then persistence:MarkDirty(id, "treadmill_upgrade") end
                        state.rootId = root; state.modelLease = op.modelLease; state.operation = nil; state.targetVersion = NextTarget()
                        CommitReplica(id, state, op)
                        UpdatePreview(id, state)
                        if upgrade then
                            local signOk, signError = pcall(function() System:FireSignEvent("跑步机升级", { id }) end)
                            if not signOk then Log:PrintError("[Treadmill] 升级成功信号发送失败", id, tostring(signError)) end
                        end
                        if not upgrade and Inside(id, state) then state.training = true end
                        if notify then
                            local notified, notifyError = pcall(notify)
                            if not notified then Log:PrintError("[Treadmill] 已提交升级通知失败，不重试", tostring(notifyError)) end
                        end
                        if oldRoot ~= root then Destroy(oldRoot, "model_replaced", oldLease) end
                        if Current(id, state) then
                            if upgrade then
                                context.Events:Publish("TreadmillLevelChanged", { playerId = id, homeId = state.homeId,
                                    sessionGeneration = state.generation, level = state.level })
                                if result then result(true, "upgraded") end
                            end
                            Send(id)
                        end
                        FinishInitial(op)
                    end)
                end
                if preplaced then
                    local model, reason = preplaced:Acquire(level, state.homeId, op, state.rootId)
                    if not model then FinishFailure(reason, not upgrade and not reset); return end
                    ModelReady(model)
                else
                    context.ElementCopy:CopyTree(rows[level].TemplateRootId, position, CopyDiagnosticId(id, state, level), ModelReady, true, id)
                end
            end)
            if not ok then
                if not op.reusesCurrent then Destroy(op.rootId, "model_operation_error", op.modelLease) end
                FinishFailure(tostring(err), not upgrade and not reset)
            end
        end
        if initial then
            op.start = StartCopy
            rt.InitialQueue[#rt.InitialQueue + 1] = op
            Diag("queue_enqueued", id, state, op)
            StartNextInitial()
        else
            StartCopy()
        end
        return op
    end
    local function Ensure(id)
        if not CanPlay(id) then Diag("ensure_blocked", id, nil, nil, "persistence_not_ready"); return nil end
        if not Active() then Diag("ensure_blocked", id, nil, nil, "module_inactive"); return nil end
        if not rt.Ready then Diag("ensure_blocked", id, nil, nil, "module_not_ready"); return nil end
        if rt.Departed[id] then Diag("ensure_blocked", id, nil, nil, "player_departed"); return nil end
        if not home.TreadmillResourcesReady then Diag("ensure_blocked", id, nil, nil, "home_resources_not_ready"); return nil end
        local homeId, generation = home:GetPlayerHome(id), economy:GetSessionGeneration(id)
        local state = rt.Players[id]
        if state and state.homeId ~= homeId then Drop(id); state = nil end
        if not homeId or not generation or not economy:IsCurrent(id, generation) or not home:IsOwner(id, homeId)
            or not Online(id) then
            RestoreDiag.Log("Server", "treadmill", "ensure_blocked", { playerId = id, homeId = homeId,
                generation = generation, reason = "home_or_economy_or_online_unavailable" }); return nil
        end
        if state then return state end
        local resources = home:GetTreadmillResources(homeId)
        if not resources or not resources.triggerId or not resources.positionId or not speed:GetSnapshot(id) then
            Diag("ensure_blocked", id, nil, nil, "transform_resources_or_speed_missing"); return nil
        end
        -- GetSnapshot首次建立速度状态时可能同步发布事件，由内层Ensure完成初始化。
        if rt.Players[id] then return rt.Players[id] end
        state = { homeId = homeId, generation = generation, level = 1, triggerId = resources.triggerId,
            positionId = resources.positionId, targetVersion = NextTarget(), training = false, lastRequestId = 0 }
        rt.Players[id] = state
        UpdatePreview(id, state)
        if not rt.Dead[id] then CopyModel(id, state, 1, false, nil, nil, true)
        else Diag("ensure_blocked", id, state, nil, "player_dead") end
        return state
    end
    function rt:GetLevel(id)
        local state = rt.Players[id]
        return state and state.level or 1
    end
    function rt:CanPurchaseMultiplier(id, generation)
        local state = rt.Players[id]
        if not CanPlay(id) or not economy:IsCurrent(id, generation) or rt.Dead[id] then return false, "session_unavailable" end
        if not state or not Current(id, state) then return false, "treadmill_unavailable" end
        if state.operation then return false, "treadmill_busy" end
        return true
    end
    function rt:PrepareReset(id, generation, callback)
        local state = Ensure(id)
        if not state or not Current(id, state) or rt.Dead[id]
            or state.disabled then return false, "treadmill_unavailable" end
        if state.operation then return false, "treadmill_busy" end
        local op = CopyModel(id, state, 1, false, callback, true)
        if state.operation == op then Send(id) end
        return true, op
    end
    function rt:CancelReset(id, token)
        local state = rt.Players[id]
        if state and state.operation == token and token.reset then CancelOperation(state); Send(id) end
    end
    function rt:PrepareResetCommit(id, generation, token, commitGrowth)
        local state = rt.Players[id]
        if not token or not state or state.operation ~= token or not token.reset or not token.prepared or token.invalid
            or token.playerId ~= id or not Current(id, state) or rt.Dead[id] then
            return nil, "reset_expired"
        end
        return function()
            if rt.Players[id] ~= state or state.operation ~= token or token.invalid or rt.Dead[id] then return false, "reset_expired" end
            -- Current中所有引擎读取已完成；两份状态连续提交，中间没有等待/通知/引擎调用。
            local committed, publishGrowth = commitGrowth()
            if not committed then return false, publishGrowth end
            local oldRoot, oldLease = state.rootId, state.modelLease
            state.level = 1; state.rootId = token.rootId; state.modelLease = token.modelLease
            state.operation = nil; state.targetVersion = NextTarget()
            token.committed = true
            local notified = false
            return true, function()
                if notified then return end; notified = true
                local ok, err = pcall(publishGrowth)
                if not ok then Log:PrintError("[Treadmill] 重生提交后成长通知失败", tostring(err)) end
                if oldRoot ~= token.rootId then Destroy(oldRoot, "rebirth_replaced", oldLease) end
                if Current(id, state) then
                    CommitReplica(id, state, token)
                    UpdatePreview(id, state)
                    Send(id)
                    context.Events:Publish("TreadmillLevelChanged", { playerId = id, homeId = state.homeId,
                        sessionGeneration = generation, level = 1 })
                end
            end
        end
        -- 返回的提交闭包只执行Lua状态提交，禁止引擎调用/等待/通知。
    end
    function rt:CommitReset(id, generation, token, commitGrowth)
        local commit, reason = self:PrepareResetCommit(id, generation, token, commitGrowth)
        if not commit then return false, reason end
        return commit()
    end
    rt.EnterBox = Protect(function(id, triggerId)
        if not rt.Ready then return end
        local state = Ensure(id)
        if not state or state.triggerId ~= triggerId or not CanPlay(id)
            or not Current(id, state) or rt.Dead[id] or state.disabled then return end
        if not state.training then state.training = true; state.targetVersion = NextTarget() end
        Send(id)
    end)
    rt.LeaveBox = Protect(function(id, triggerId)
        local state = rt.Players[id]
        if state and state.triggerId == triggerId then StopTraining(id, state) end
    end)
    rt.Action = Protect(function(_, message, id)
        if not rt.Ready or type(message) ~= "table" or not Integer(id) then return end
        for _, field in ipairs({ "requestId", "homeId", "targetVersion", "expectedLevel" }) do
            if not Integer(message[field]) then return end
        end
        local function Result(success, reason)
            if Active() then System:SendToClient(id, messages.TreadmillResult, {
                requestId = message.requestId, sessionGeneration = message.sessionGeneration, homeId = message.homeId,
                targetVersion = message.targetVersion, expectedLevel = message.expectedLevel, success = success, reason = reason }) end
        end
        local state = Ensure(id)
        if not state or not state.training or not Inside(id, state) or state.homeId ~= message.homeId
            or state.targetVersion ~= message.targetVersion then
            Result(false, "interaction_expired"); return
        end
        if state.operation then Result(false, "upgrade_busy"); return end
        if message.requestId <= state.lastRequestId then Result(false, "stale_request"); return end
        state.lastRequestId = message.requestId
        if message.expectedLevel ~= state.level then Result(false, "stale_level"); return end
        if state.level >= c.MaxLevel then Result(false, "max_level"); return end
        if Decimal.Compare(economy:GetBalance(id), rows[state.level].UpgradeCost) < 0 then
            Result(false, "insufficient_balance"); return
        end
        CopyModel(id, state, state.level + 1, true, Result)
        Send(id)
    end)
    rt.Snapshot = Protect(function(_, _, id)
        if not rt.Ready or not Integer(id) then return end
        Ensure(id); Send(id)
        home:SendTreadmillExperienceTexts(id)
        SendReplicas(id)
    end)
    rt.Leave = Protect(function(id) PrepareLeave(id); rt.Departed[id] = true; Drop(id, "player_leave"); rt.Dead[id] = nil end)
    rt.Enter = Protect(function(id) rt.Departed[id] = nil; if rt.Ready then Ensure(id) end end)
    rt.Death = Protect(function(id)
        rt.Dead[id] = true
        local state = rt.Players[id]
        if state then StopTraining(id, state); CancelOperation(state); state.targetVersion = NextTarget(); Send(id) end
    end)
    rt.Revive = Protect(function(id)
        rt.Dead[id] = nil
        if not rt.Ready then return end
        local state = Ensure(id)
        if state and not state.disabled and not state.rootId and not state.operation then CopyModel(id, state, 1, false, nil, nil, true) end
    end)
    rt.Bindings = {
        { Events.ON_CHARACTER_ENTER_SIGNAL_BOX, rt.EnterBox }, { Events.ON_CHARACTER_LEAVE_SIGNAL_BOX, rt.LeaveBox },
        { Events.ON_PLAYER_PRELEAVE, rt.Leave }, { Events.ON_PLAYER_ENTER, rt.Enter },
        { Events.ON_PLAYER_JOIN_MIDWAY, rt.Enter }, { Events.ON_PLAYER_RECONNECTED, rt.Enter },
        { Events.ON_CHARACTER_KILLED, rt.Death }, { Events.ON_CHARACTER_DESTROYED, rt.Death },
        { Events.ON_CHARACTER_RESPAWN, rt.Revive }, { Events.ON_CHARACTER_REVIVED, rt.Revive },
    }
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    System:BindNotify(messages.TreadmillAction, rt.Action)
    System:BindNotify(messages.TreadmillSnapshotRequest, rt.Snapshot)
    context.Events:Subscribe(self.Name, "HomeAssigned", Protect(function(data) rt.Departed[data.playerId] = nil; Ensure(data.playerId) end))
    context.Events:Subscribe(self.Name, "HomeReleased", Protect(function(data) Drop(data.playerId, "home_released"); Send(data.playerId) end))
    context.Events:Subscribe(self.Name, "EconomyChanged", Protect(function(data) if rt.Ready then Ensure(data.playerId) end end))
    context.Events:Subscribe(self.Name, "PlayerSpeedChanged", Protect(function(data)
        if rt.Ready then Ensure(data.playerId); Send(data.playerId) end
    end))
    local function Initialize()
        if not rt.Ready or not home.TreadmillResourcesReady then return end
        if PreplacedConfig.DiagnosticEnabled and not rt.PreplacedDiagnosed then
            rt.PreplacedDiagnosed = true
            local ok, err = pcall(PreplacedPool.Diagnose)
            if not ok then pcall(function() Log:PrintError("[TreadmillPreplacedDiag] diagnostic_failed", tostring(err)) end) end
        end
        if preplaced then preplaced:Initialize() end
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Ensure(id) end
        StartNextInitial()
    end
    context.Events:Subscribe(self.Name, "HomeTreadmillResourcesReady", Protect(Initialize))
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function() rt.Ready = true; Initialize() end))
    context.Timers:AddLoopTimer(self.Name, c.ExperienceTickSeconds, Protect(function()
        if not rt.Ready then return end
        for id, state in pairs(rt.Players) do
            if not Current(id, state) then Drop(id)
            elseif not CanPlay(id) then state.training = false
            elseif state.training then
                if not rt.Dead[id] and not state.disabled then
                    local amount, reason = speed:GetExperiencePerTick(id, state.generation, rows[state.level].ExperiencePerTick)
                    if not amount then error("跑步机倍率经验配置无效: " .. tostring(reason)) end
                    speed:AddExperience(id, state.generation, amount)
                else StopTraining(id, state) end
            end
        end
    end))
    if GameConfig.Persistence.ProductionEnabled then
        assert(persistence:RegisterAdapter("treadmill", {
            Export = function(id)
                local state = rt.Players[id]
                if not state then return nil, "treadmill_state_missing" end
                return { version = 1, level = state.level }
            end,
            Restore = function(id, data, done)
                RestoreDiag.Log("Server", "treadmill", "restore_enter", function()
                    return { playerId = id, hasData = data ~= nil, savedLevel = data and data.level }
                end)
                local level = 1
                if data ~= nil then
                    if data.version ~= 1 then Log:PrintServerLog("[Persistence] version mismatch", id, "treadmill", tostring(data.version), 1) end
                    if data.level ~= nil then level = data.level end
                end
                local homeId, generation = home:GetPlayerHome(id), economy:GetSessionGeneration(id)
                local resources = homeId and home:GetTreadmillResources(homeId)
                if not resources or not resources.triggerId or not resources.positionId or not generation then
                    Diag("restore_skipped", id, nil, nil, "treadmill_resources_missing"); done(false, "treadmill_resources_missing"); return
                end
                Drop(id, "restore_replace_state")
                local state = { homeId = homeId, generation = generation, level = level, triggerId = resources.triggerId,
                    positionId = resources.positionId, targetVersion = NextTarget(), training = false, lastRequestId = 0 }
                rt.Players[id], rt.Departed[id] = state, nil
                local restoreOp = CopyModel(id, state, level, false, function(ok, token, copyFailed)
                    if not ok then
                        if copyFailed then
                            if not Current(id, state) or state.operation ~= nil then done(false, "restore_expired"); return end
                            -- Keep the saved level and gameplay available when the copy callback fails.
                            Diag("restore_model_missing_level_retained", id, state, nil, token)
                            done(true, function() Send(id); return true end)
                            return
                        end
                        done(false, token); return
                    end
                    if not Current(id, state) or state.operation ~= token then
                        if not token.reusesCurrent then Destroy(token.rootId, "restore_expired", token.modelLease) end
                        done(false, "restore_expired"); return
                    end
                    state.rootId, state.operation = token.rootId, nil
                    state.modelLease = token.modelLease
                    token.committed = true
                    CommitReplica(id, state, token)
                    UpdatePreview(id, state)
                    done(true, function() Send(id); return true end)
                end, true, true)
                restoreOp.onInitialFinished = function()
                    if restoreOp.invalid or not Current(id, state) then done(false, "restore_expired") end
                end
            end,
            Cleanup = function(id) rt.Leave(id) end,
        }))
        context.Events:Subscribe(self.Name, "PersistenceReady", Protect(function(event)
            local id, state = event.playerId, rt.Players[event.playerId]
            if state and Current(id, state) then state.training = Inside(id, state); state.targetVersion = NextTarget(); Send(id) end
        end))
    end
    rt.Cleanup = function()
        rt.Active = false
        rt.InitialQueue = {}
        rt.InitialCurrent = nil
        if rt.InitialTimer then context.Timers:Remove(rt.InitialTimer); rt.InitialTimer = nil end
        for id in pairs(rt.Players) do Drop(id, "module_stop") end
        local roots = {}; for root in pairs(rt.OwnedRoots) do roots[#roots + 1] = root end
        for _, root in ipairs(roots) do Destroy(root, "module_stop", rt.OwnedRoots[root]) end
    end
end
function TreadmillService:Stop(context)
    local rt = context.Services.TreadmillService
    if not rt then return end
    rt.Cleanup()
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    System:UnbindNotify(context.NetMsg.Messages.TreadmillAction, rt.Action)
    System:UnbindNotify(context.NetMsg.Messages.TreadmillSnapshotRequest, rt.Snapshot)
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.TreadmillService = nil
end
return TreadmillService
