local GameConfig = require "Common.Config.GameConfig"
local SafeCall = require "Common.Core.SafeCall"
local Decimal = require "Common.DecimalInteger"
local TreadmillService = { Name = "TreadmillService", FeatureFlag = "Treadmill",
    Dependencies = { "HomeService", "EconomyService", "PlayerSpeedService" } }
local function Integer(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end
function TreadmillService:Start(context)
    if context.Side ~= "Server" then return end
    local c, rows, messages = GameConfig.Treadmill, GameConfig.TreadmillLevels, context.NetMsg.Messages
    local home, economy, speed = context.Services.HomeService, context.Services.EconomyService, context.Services.PlayerSpeedService
    local rt = { Active = true, Ready = false, Players = {}, Departed = {}, Dead = {}, OwnedRoots = {},
        Version = 0, TargetVersion = 0 }
    context.Services.TreadmillService = rt
    local persistence = context.Services.PersistenceService
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
    local function Destroy(rootId)
        if not rootId or not rt.OwnedRoots[rootId] then return end
        rt.OwnedRoots[rootId] = nil
        local ok, result = pcall(function() return context.ElementCopy:DestroyTree(rootId) end)
        if not ok or result ~= true then Log:PrintError("[Treadmill] 运行模型销毁失败，不重试", rootId, tostring(result)) end
    end
    local function UpdatePreview(id, state, snapshot)
        snapshot = snapshot or speed:GetSnapshot(id)
        local level = state and state.level or 1
        local amount = snapshot and speed:GetExperiencePerTick(id, snapshot.sessionGeneration, rows[level].ExperiencePerTick)
        local nextAmount = snapshot and rows[level + 1] and speed:GetExperiencePerTick(id, snapshot.sessionGeneration, rows[level + 1].ExperiencePerTick)
        if state and amount then home:UpdateTreadmillExperienceText(state.homeId, level, amount, nextAmount) end
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
    local function CancelOperation(state)
        local op = state.operation
        state.operation = nil
        if op then
            op.invalid = true; Destroy(op.rootId)
            if op.reset and op.result then op.result(false, "reset_cancelled") end
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
    local function Drop(id)
        local state = rt.Players[id]
        rt.Players[id] = nil
        if state then CancelOperation(state); Destroy(state.rootId); NextTarget() end
    end
    local function CopyDiagnosticId(id, state, level)
        return "Treadmill:" .. state.homeId .. ":" .. level .. ":player=" .. tostring(id)
            .. ":session=" .. tostring(state.generation) .. ":target=" .. tostring(state.targetVersion)
    end
    local function RestoreDiagnostic(stage, id, state, level, reason)
        pcall(function()
            local fields = {}
            local function Read(name, getter)
                local ok, value = pcall(getter)
                local converted, text = pcall(tostring, value)
                fields[#fields + 1] = name .. "=" .. (ok and converted and text or "unavailable")
            end
            Read("playerId", function() return id end)
            Read("session", function() return state.generation end)
            Read("homeId", function() return state.homeId end)
            Read("level", function() return level end)
            Read("templateId", function() return rows[level].TemplateRootId end)
            Read("copyContext", function() return CopyDiagnosticId(id, state, level) end)
            Read("timestampMs", function() return MiscService:GetServerTimestamp() end)
            Read("reason", function() return reason end)
            if stage ~= "restore_complete" then
                for _, key in ipairs({ "Ready", "Generating", "Refreshing", "Generation", "Stopped" }) do
                    Read("theft." .. key, function()
                        local theft = context.Services.TheftService
                        if not theft then return "module_missing" end
                        return theft[key]
                    end)
                end
            end
            pcall(function() Log:PrintServerLog("[TreadmillRestoreDiag]", stage, table.concat(fields, " | ")) end)
        end)
    end
    local function CopyModel(id, state, level, upgrade, result, reset)
        local op = { level = level, upgrade = upgrade, targetVersion = state.targetVersion, reset = reset, result = result,
            playerId = id, generation = state.generation, state = state }
        state.operation = op
        local function Valid()
            return Current(id, state) and not rt.Dead[id] and state.operation == op and not op.invalid
                and (not upgrade or (state.training and state.targetVersion == op.targetVersion and Inside(id, state)))
        end
        local function FinishFailure(reason, disable, copyFailed)
            if state.operation ~= op then return end
            state.operation = nil
            if disable and not copyFailed then state.disabled = true; state.training = false; state.targetVersion = NextTarget() end
            Log:PrintError("[Treadmill] 模型操作失败，未扣款/未升级", "homeId:", state.homeId, "level:", level, "reason:", tostring(reason))
            if result and (reset or Current(id, state)) then result(false, reason, copyFailed) end
            Send(id)
        end
        local position, rotation
        local readOk, readError = pcall(function()
            position, rotation = Element:GetPosition(state.positionId), Element:GetRotation(state.positionId)
            if not position or not rotation then error("跑步机位置或旋转不可用") end
        end)
        if not readOk then FinishFailure(tostring(readError), not reset); return op end
        local ok, err = pcall(function()
            context.ElementCopy:CopyTree(rows[level].TemplateRootId, position, CopyDiagnosticId(id, state, level), function(copy)
                -- 此回调不能使用Active包装：Stop后到达的完整复制也必须清理。
                if type(copy) ~= "table" or copy.success ~= true or not Integer(copy.rootId) then
                    if Active() then FinishFailure(type(copy) == "table" and copy.reason or "copy_failed", not upgrade and not reset, true) end
                    return -- 部分失败副本按ElementCopy契约保留，不重试。
                end
                local root = copy.rootId
                for _, row in ipairs(rows) do
                    if row.TemplateRootId == root then FinishFailure("copy_returned_source", not upgrade and not reset); return end
                end
                rt.OwnedRoots[root] = true; op.rootId = root
                if not Valid() then Destroy(root); return end
                local rotated, rotationError = pcall(function() Element:SetRotation(root, rotation, Element.COORDINATE.World) end)
                if not rotated then Destroy(root); FinishFailure(tostring(rotationError), not upgrade and not reset); return end
                if not Valid() then Destroy(root); return end
                context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                    if not Valid() then Destroy(root); return end
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
                    if not verified then Destroy(root); FinishFailure(tostring(verifyError), not upgrade and not reset); return end
                    if not Valid() then Destroy(root); return end
                    if reset then op.prepared = true; if result then result(true, op) end; return end
                    local oldRoot, notify = state.rootId, nil
                    if upgrade then
                        if state.level + 1 ~= level then Destroy(root); FinishFailure("stale_level", false); return end
                        local debited, value = economy:TryDebit(id, state.generation, rows[state.level].UpgradeCost)
                        if not debited then Destroy(root); FinishFailure(value, false); return end
                        state.level = level -- 扣款后立即提交，无等待/引擎调用/通知。
                        notify = value
                    end
                    if upgrade and persistence then persistence:MarkDirty(id, "treadmill_upgrade") end
                    state.rootId = root; state.operation = nil; state.targetVersion = NextTarget()
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
                    Destroy(oldRoot)
                    if Current(id, state) then
                        if upgrade then
                            context.Events:Publish("TreadmillLevelChanged", { playerId = id, homeId = state.homeId,
                                sessionGeneration = state.generation, level = state.level })
                            if result then result(true, "upgraded") end
                        end
                        Send(id)
                    end
                end)
            end)
        end)
        if not ok then
            Destroy(op.rootId)
            FinishFailure(tostring(err), not upgrade and not reset)
        end
        return op
    end
    local function Ensure(id)
        if not CanPlay(id) or not Active() or not rt.Ready or rt.Departed[id] or not home.TreadmillResourcesReady then return nil end
        local homeId, generation = home:GetPlayerHome(id), economy:GetSessionGeneration(id)
        local state = rt.Players[id]
        if state and state.homeId ~= homeId then Drop(id); state = nil end
        if not homeId or not generation or not economy:IsCurrent(id, generation) or not home:IsOwner(id, homeId)
            or not Online(id) then return nil end
        if state then return state end
        local resources = home:GetTreadmillResources(homeId)
        if not resources or not resources.triggerId or not resources.positionId or not speed:GetSnapshot(id) then return nil end
        -- GetSnapshot首次建立速度状态时可能同步发布事件，由内层Ensure完成初始化。
        if rt.Players[id] then return rt.Players[id] end
        state = { homeId = homeId, generation = generation, level = 1, triggerId = resources.triggerId,
            positionId = resources.positionId, targetVersion = NextTarget(), training = false, lastRequestId = 0 }
        rt.Players[id] = state
        UpdatePreview(id, state)
        if not rt.Dead[id] then CopyModel(id, state, 1, false) end
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
            local oldRoot = state.rootId
            state.level = 1; state.rootId = token.rootId; state.operation = nil; state.targetVersion = NextTarget()
            token.committed = true
            local notified = false
            return true, function()
                if notified then return end; notified = true
                local ok, err = pcall(publishGrowth)
                if not ok then Log:PrintError("[Treadmill] 重生提交后成长通知失败", tostring(err)) end
                Destroy(oldRoot)
                if Current(id, state) then
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
    end)
    rt.Leave = Protect(function(id) PrepareLeave(id); rt.Departed[id] = true; Drop(id); rt.Dead[id] = nil end)
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
        if state and not state.disabled and not state.rootId and not state.operation then CopyModel(id, state, 1, false) end
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
    context.Events:Subscribe(self.Name, "HomeReleased", Protect(function(data) Drop(data.playerId); Send(data.playerId) end))
    context.Events:Subscribe(self.Name, "EconomyChanged", Protect(function(data) if rt.Ready then Ensure(data.playerId) end end))
    context.Events:Subscribe(self.Name, "PlayerSpeedChanged", Protect(function(data)
        if rt.Ready then Ensure(data.playerId); Send(data.playerId) end
    end))
    local function Initialize()
        if not rt.Ready or not home.TreadmillResourcesReady then return end
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Ensure(id) end
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
                local level = 1
                if data ~= nil then
                    if data.version ~= 1 then Log:PrintServerLog("[Persistence] version mismatch", id, "treadmill", tostring(data.version), 1) end
                    if data.level ~= nil then level = data.level end
                end
                local homeId, generation = home:GetPlayerHome(id), economy:GetSessionGeneration(id)
                local resources = homeId and home:GetTreadmillResources(homeId)
                if not resources or not resources.triggerId or not resources.positionId or not generation then done(false, "treadmill_resources_missing"); return end
                Drop(id)
                local state = { homeId = homeId, generation = generation, level = level, triggerId = resources.triggerId,
                    positionId = resources.positionId, targetVersion = NextTarget(), training = false, lastRequestId = 0 }
                rt.Players[id], rt.Departed[id] = state, nil
                RestoreDiagnostic("restore_begin", id, state, level)
                CopyModel(id, state, level, false, function(ok, token, copyFailed)
                    if not ok then
                        RestoreDiagnostic("restore_failed", id, state, level, token)
                        if copyFailed then
                            if not Current(id, state) or state.operation ~= nil then done(false, "restore_expired"); return end
                            -- Keep the saved level and gameplay available when the copy callback fails.
                            RestoreDiagnostic("restore_skipped", id, state, level, token)
                            done(true, function() Send(id); return true end)
                            return
                        end
                        done(false, token); return
                    end
                    if not Current(id, state) or state.operation ~= token then
                        RestoreDiagnostic("restore_failed", id, state, level, "restore_expired")
                        Destroy(token.rootId); done(false, "restore_expired"); return
                    end
                    state.rootId, state.operation = token.rootId, nil
                    token.committed = true
                    UpdatePreview(id, state)
                    RestoreDiagnostic("restore_complete", id, state, level)
                    done(true, function() Send(id); return true end)
                end, true)
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
        for id in pairs(rt.Players) do Drop(id) end
        local roots = {}; for root in pairs(rt.OwnedRoots) do roots[#roots + 1] = root end
        for _, root in ipairs(roots) do Destroy(root) end
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
