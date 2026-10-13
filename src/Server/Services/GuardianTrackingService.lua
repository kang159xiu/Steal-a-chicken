-- 守护者追踪功能模板。
-- 只负责追踪、触发盒命中判定、停止追踪和返回位置；不处理候选队列、击飞或归属。
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
    }, GuardianTrackingService)
end

function GuardianTrackingService:_CleanupSession(session)
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

    if self._sessionsByGuardian[request.guardianElementId] then
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

    Element:StopTracking(session.GuardianElementId)
    self:_CleanupSession(session)
    session.State = "Stopped"
    Log:PrintServerLog("[GuardianTrackingService] 停止追踪",
        session.DebugName,
        "guardianId:", session.GuardianElementId,
        "reason:", tostring(reason))
    return true
end

function GuardianTrackingService:StopAndReturnGuardian(guardianElementId, reason)
    local session = self._sessionsByGuardian[guardianElementId]
    if not session then
        return false, "guardian_not_tracking"
    end
    if session.State ~= "Tracking" then
        return false, "guardian_not_in_tracking_state"
    end

    self._sessionsByTrigger[session.TriggerBoxId] = nil
    Element:StopTracking(session.GuardianElementId)
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

    for guardianElementId in pairs(self._sessionsByGuardian) do
        Element:StopTracking(guardianElementId)
    end
    self._sessionsByGuardian = {}
    self._sessionsByTrigger = {}
end

return GuardianTrackingService
