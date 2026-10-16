-- 守护者追踪功能模板。
-- 只负责追踪、触发盒命中判定、位置运动及取消；不处理候选队列、击飞或归属。
local GuardianTrackingService = {}
GuardianTrackingService.__index = GuardianTrackingService

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function IsVector(value)
    return value ~= nil
        and type(value.X) == "number"
        and type(value.Y) == "number"
        and type(value.Z) == "number"
end

local function CopyVector(value)
    return Engine.Vector(value.X, value.Y, value.Z)
end

local function Distance(first, second)
    local deltaX = first.X - second.X
    local deltaY = first.Y - second.Y
    local deltaZ = first.Z - second.Z
    return math.sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
end

local function ValidateTrackRequest(request)
    assert(type(request) == "table", "GuardianTrackingService TrackTarget request 必须是 table")
    assert(type(request.debugName) == "string" and request.debugName ~= "",
        "GuardianTrackingService debugName 必须是非空字符串")
    assert(type(request.guardianElementId) == "number", "guardianElementId 必须是 number")
    assert(type(request.triggerBoxId) == "number", "triggerBoxId 必须是 number")
    assert(type(request.targetElementId) == "number", "targetElementId 必须是 number")
    assert(IsVector(request.guardianReturnPosition), "guardianReturnPosition 必须是 Engine.Vector")
    assert(IsVector(request.targetReturnPosition), "targetReturnPosition 必须是 Engine.Vector")
    assert(type(request.initialSpeed) == "number", "initialSpeed 必须是 number")
    assert(type(request.acceleration) == "number", "acceleration 必须是 number")
    assert(type(request.maxVelocity) == "number", "maxVelocity 必须是 number")
    assert(type(request.distanceKeep) == "number", "distanceKeep 必须是 number")
    assert(type(request.onCaught) == "function", "onCaught 必须是 function")
    assert(request.onReturned == nil or type(request.onReturned) == "function",
        "onReturned 必须是 function 或 nil")
end

local function BuildSnapshot(session, reason)
    return {
        debugName = session.DebugName,
        reason = reason,
        guardianElementId = session.GuardianElementId,
        triggerBoxId = session.TriggerBoxId,
        targetElementId = session.TargetElementId,
        guardianReturnPosition = CopyVector(session.GuardianReturnPosition),
        targetReturnPosition = CopyVector(session.TargetReturnPosition),
        guardianPosition = Element:GetPosition(session.GuardianElementId),
        targetPosition = Element:GetPosition(session.TargetElementId),
    }
end

function GuardianTrackingService.New(owner, timerRegistry, onError)
    assert(type(owner) == "string" and owner ~= "", "GuardianTrackingService owner 必须是非空字符串")
    assert(timerRegistry ~= nil, "GuardianTrackingService 需要 TimerRegistry")
    assert(type(onError) == "function", "GuardianTrackingService onError 必须是 function")

    return setmetatable({
        _owner = owner,
        _timers = timerRegistry,
        _onError = onError,
        _started = false,
        _stopped = false,
        _sequence = 0,
        _triggerCallback = nil,
        _sessionsByGuardian = {},
        _sessionsByTrigger = {},
        _movesByGuardian = {},
    }, GuardianTrackingService)
end

function GuardianTrackingService:_CleanupSession(session)
    if session.ResetTimerId then self._timers:Remove(session.ResetTimerId) end
    if session.VerifyTimerId then self._timers:Remove(session.VerifyTimerId) end
    if self._sessionsByGuardian[session.GuardianElementId] == session then
        self._sessionsByGuardian[session.GuardianElementId] = nil
    end
    if self._sessionsByTrigger[session.TriggerBoxId] == session then
        self._sessionsByTrigger[session.TriggerBoxId] = nil
    end
end

function GuardianTrackingService:_ScheduleReturn(session, returnTarget, reason)
    session.State = returnTarget and "ReturningBoth" or "ReturningGuardian"

    session.ResetTimerId = self._timers:AddFrame(self._owner, 2, function()
        session.ResetTimerId = nil
        if self._stopped or self._sessionsByGuardian[session.GuardianElementId] ~= session then
            return
        end

        Element:SetPosition(
            session.GuardianElementId,
            session.GuardianReturnPosition,
            Element.COORDINATE.World
        )
        if returnTarget then
            Element:SetPosition(
                session.TargetElementId,
                session.TargetReturnPosition,
                Element.COORDINATE.World
            )
        end

        session.VerifyTimerId = self._timers:AddFrame(self._owner, 2, function()
            session.VerifyTimerId = nil
            if self._stopped or self._sessionsByGuardian[session.GuardianElementId] ~= session then
                return
            end

            local result = BuildSnapshot(session, reason)
            result.returnedTarget = returnTarget
            result.guardianDistanceFromReturn = Distance(
                result.guardianPosition,
                session.GuardianReturnPosition
            )
            if returnTarget then
                result.targetDistanceFromReturn = Distance(
                    result.targetPosition,
                    session.TargetReturnPosition
                )
            end

            self:_CleanupSession(session)
            session.State = "Completed"
            if session.OnReturned then
                session.OnReturned(result)
            end
        end)
    end)
end

function GuardianTrackingService:_HandleElementEnterTrigger(elementId, triggerBoxId)
    local session = self._sessionsByTrigger[triggerBoxId]
    if not session or session.State ~= "Tracking" then
        return
    end
    if elementId ~= session.TargetElementId then
        return
    end
    if TriggerBox:IsElementInTriggerBox(session.TargetElementId, session.TriggerBoxId) ~= true then
        return
    end

    self._sessionsByTrigger[session.TriggerBoxId] = nil
    session.State = "Caught"
    Element:StopTracking(session.GuardianElementId)

    local caughtSnapshot = BuildSnapshot(session, "target_entered_guardian_trigger")
    session.OnCaught(caughtSnapshot)
    if self._stopped or self._sessionsByGuardian[session.GuardianElementId] ~= session then return end
    self:_ScheduleReturn(session, true, "target_entered_guardian_trigger")
end

function GuardianTrackingService:Start()
    assert(not self._stopped, "GuardianTrackingService 已停止，不能再次启动")
    if self._started then
        return false, "already_started"
    end

    self._triggerCallback = function(elementId, triggerBoxId)
        local ok, errorMessage = xpcall(function()
            self:_HandleElementEnterTrigger(elementId, triggerBoxId)
        end, Traceback)
        if not ok then
            self._onError(errorMessage)
        end
    end
    System:RegisterEvent(Events.ON_ELEMENT_ENTER_TRIGGER, self._triggerCallback)
    self._started = true
    return true
end

function GuardianTrackingService:TrackTarget(request)
    assert(self._started and not self._stopped,
        "GuardianTrackingService 必须先 Start，且不能在 Stop 后继续使用")
    ValidateTrackRequest(request)

    if self._sessionsByGuardian[request.guardianElementId]
        or self._movesByGuardian[request.guardianElementId] then
        return false, "guardian_busy"
    end
    if self._sessionsByTrigger[request.triggerBoxId] then
        return false, "trigger_box_busy"
    end

    self._sequence = self._sequence + 1
    local session = {
        Sequence = self._sequence,
        State = "Tracking",
        DebugName = request.debugName,
        GuardianElementId = request.guardianElementId,
        TriggerBoxId = request.triggerBoxId,
        TargetElementId = request.targetElementId,
        GuardianReturnPosition = CopyVector(request.guardianReturnPosition),
        TargetReturnPosition = CopyVector(request.targetReturnPosition),
        OnCaught = request.onCaught,
        OnReturned = request.onReturned,
        ResetTimerId = nil,
        VerifyTimerId = nil,
    }
    self._sessionsByGuardian[session.GuardianElementId] = session
    self._sessionsByTrigger[session.TriggerBoxId] = session

    local ok, errorMessage = xpcall(function()
        Element:TrackTarget(
            session.GuardianElementId,
            session.TargetElementId,
            request.initialSpeed,
            request.acceleration,
            request.maxVelocity,
            request.distanceKeep
        )
    end, Traceback)
    if not ok then
        self:_CleanupSession(session)
        error(errorMessage)
    end

    Log:PrintServerLog("[GuardianTrackingService] 开始追踪",
        request.debugName,
        "guardianId:", session.GuardianElementId,
        "targetId:", session.TargetElementId,
        "triggerBoxId:", session.TriggerBoxId)
    return true
end

function GuardianTrackingService:StopTrackingOnly(guardianElementId, reason)
    local session = self._sessionsByGuardian[guardianElementId]
    if not session then
        return false, "guardian_not_tracking"
    end

    self:_CleanupSession(session)
    session.State = "Stopped"
    Element:StopTracking(session.GuardianElementId)
    Log:PrintServerLog("[GuardianTrackingService] 停止追踪",
        session.DebugName,
        "guardianId:", session.GuardianElementId,
        "reason:", tostring(reason))
    return true
end

-- MoveTo没有到达回调：持续指定秒数，停止运动后等待两帧再读取落点并通知队列。
function GuardianTrackingService:MoveGuardian(request)
    assert(self._started and not self._stopped, "守护者运动模块未运行")
    assert(type(request) == "table" and type(request.guardianElementId) == "number",
        "MoveGuardian缺少守护者ID")
    assert(IsVector(request.position), "MoveGuardian缺少世界目标位置")
    assert(type(request.seconds) == "number" and request.seconds > 0, "MoveGuardian需要正秒数")
    assert(type(request.onArrived) == "function", "MoveGuardian缺少完成回调")
    local guardianId = request.guardianElementId
    if self._sessionsByGuardian[guardianId] or self._movesByGuardian[guardianId] then
        return false, "guardian_busy"
    end
    self._sequence = self._sequence + 1
    local move = { Sequence = self._sequence, Position = CopyVector(request.position) }
    self._movesByGuardian[guardianId] = move
    local function IsCurrent()
        return not self._stopped and self._movesByGuardian[guardianId] == move
    end
    move.StartTimerId = self._timers:AddFrame(self._owner, 2, function()
        move.StartTimerId = nil
        if not IsCurrent() then return end
        move.Moving = true
        Element:MoveTo(guardianId, move.Position, request.seconds, Element.CURVE.linear)
        move.EndTimerId = self._timers:AddTimer(self._owner, request.seconds, function()
            move.EndTimerId = nil
            if not IsCurrent() then return end
            Element:StopMoveTo(guardianId)
            move.Moving = false
            move.VerifyTimerId = self._timers:AddFrame(self._owner, 2, function()
                move.VerifyTimerId = nil
                if not IsCurrent() then return end
                local position = Element:GetPosition(guardianId)
                if not position then error("守护者MoveTo后无法读取位置") end
                self._movesByGuardian[guardianId] = nil
                Log:PrintServerLog("[GuardianTrackingService] 守护者移动结束",
                    "guardianId:", guardianId, "reason:", request.reason,
                    "distanceFromDestination:", Distance(position, move.Position))
                request.onArrived({ guardianPosition = position })
            end)
        end)
    end)
    return true
end

function GuardianTrackingService:CancelGuardian(guardianElementId, reason)
    local move = self._movesByGuardian[guardianElementId]
    if move then
        self._movesByGuardian[guardianElementId] = nil
        for _, field in ipairs({ "StartTimerId", "EndTimerId", "VerifyTimerId" }) do
            if move[field] then self._timers:Remove(move[field]) end
        end
        if move.Moving then Element:StopMoveTo(guardianElementId) end
    end
    local stopped = self:StopTrackingOnly(guardianElementId, reason)
    return move ~= nil or stopped
end

function GuardianTrackingService:StopAndReturnGuardian(guardianElementId, reason, moveReturn)
    local session = self._sessionsByGuardian[guardianElementId]
    -- 接近阶段尚无追踪会话；成功带回仍复用原两帧复位、两帧验证链。
    if not session and self._movesByGuardian[guardianElementId] and moveReturn then
        assert(IsVector(moveReturn.guardianReturnPosition), "接近取消后缺少守护者返回位置")
        self:CancelGuardian(guardianElementId, reason)
        self._sequence = self._sequence + 1
        session = {
            Sequence = self._sequence, State = "Tracking",
            DebugName = moveReturn.debugName, GuardianElementId = guardianElementId,
            TriggerBoxId = moveReturn.triggerBoxId, TargetElementId = moveReturn.targetElementId,
            GuardianReturnPosition = CopyVector(moveReturn.guardianReturnPosition),
            TargetReturnPosition = CopyVector(moveReturn.targetReturnPosition),
            OnReturned = moveReturn.onReturned,
        }
        self._sessionsByGuardian[guardianElementId] = session
    end
    if not session then
        return false, "guardian_not_tracking"
    end
    if session.State ~= "Tracking" then
        return false, "guardian_not_in_tracking_state"
    end

    self._sessionsByTrigger[session.TriggerBoxId] = nil
    if not moveReturn or not moveReturn.fromApproach then Element:StopTracking(session.GuardianElementId) end
    self:_ScheduleReturn(session, false, reason)
    return true
end

function GuardianTrackingService:StopAndReturnBoth(guardianElementId, reason)
    local session = self._sessionsByGuardian[guardianElementId]
    if not session then
        return false, "guardian_not_tracking"
    end
    if session.State ~= "Tracking" then
        return false, "guardian_not_in_tracking_state"
    end

    self._sessionsByTrigger[session.TriggerBoxId] = nil
    Element:StopTracking(session.GuardianElementId)
    self:_ScheduleReturn(session, true, reason)
    return true
end

function GuardianTrackingService:Stop()
    if self._stopped then
        return
    end
    self._stopped = true

    if self._triggerCallback then
        System:UnregisterEvent(Events.ON_ELEMENT_ENTER_TRIGGER, self._triggerCallback)
        self._triggerCallback = nil
    end

    local guardianIds = {}
    for guardianId in pairs(self._sessionsByGuardian) do guardianIds[guardianId] = true end
    for guardianId in pairs(self._movesByGuardian) do guardianIds[guardianId] = true end
    for guardianId in pairs(guardianIds) do self:CancelGuardian(guardianId, "stop") end
    self._sessionsByGuardian = {}
    self._sessionsByTrigger = {}
end

return GuardianTrackingService
