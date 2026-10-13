-- 临时回归模块：验证服务端元件追踪、触发盒到达判定、停止追踪和延迟一帧复位。
local GuardianTrackTest = {
    Name = "GuardianTrackTest",
    FeatureFlag = "GuardianTrackTest",
    Dependencies = {},
}

local GUARDIAN_ELEMENT_ID = 257
local TARGET_ELEMENT_ID = 325
local GUARDIAN_TRIGGER_BOX_ID = 404
local INITIAL_SPEED = 500
local ACCELERATION = 100
local MAX_VELOCITY = 800
local DISTANCE_KEEP = 0
local START_DELAY_SECONDS = 1
local TEST_TIMEOUT_SECONDS = 15
local SAMPLE_INTERVAL_SECONDS = 1

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function CopyPosition(position)
    return Engine.Vector(position.X, position.Y, position.Z)
end

local function FormatPosition(position)
    if not position then
        return "nil"
    end
    return string.format("(%.3f, %.3f, %.3f)", position.X, position.Y, position.Z)
end

local function Distance(first, second)
    local deltaX = first.X - second.X
    local deltaY = first.Y - second.Y
    local deltaZ = first.Z - second.Z
    return math.sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
end

local function RemoveTimer(context, runtime, fieldName)
    local timerId = runtime[fieldName]
    if timerId then
        context.Timers:Remove(timerId)
        runtime[fieldName] = nil
    end
end

local function UnregisterTriggerEvent(runtime)
    if not runtime.TriggerCallback then
        return
    end
    System:UnregisterEvent(Events.ON_ELEMENT_ENTER_TRIGGER, runtime.TriggerCallback)
    runtime.TriggerCallback = nil
end

local function FinishAfterReset(context, runtime, reason)
    runtime.VerifyTimerId = context.Timers:AddFrame(GuardianTrackTest.Name, 1, function()
        runtime.VerifyTimerId = nil
        local guardianPosition = Element:GetPosition(GUARDIAN_ELEMENT_ID)
        local targetPosition = Element:GetPosition(TARGET_ELEMENT_ID)
        local guardianResetDistance = nil
        local targetResetDistance = nil
        if guardianPosition and runtime.GuardianStartPosition then
            guardianResetDistance = Distance(guardianPosition, runtime.GuardianStartPosition)
        end
        if targetPosition and runtime.TargetStartPosition then
            targetResetDistance = Distance(targetPosition, runtime.TargetStartPosition)
        end

        runtime.Finished = true
        Log:PrintServerLog("[GuardianTrackTest] 复位后隔一帧验证",
            "reason:", reason,
            "guardianId:", GUARDIAN_ELEMENT_ID,
            "guardianPosition:", FormatPosition(guardianPosition),
            "guardianExpectedPosition:", FormatPosition(runtime.GuardianStartPosition),
            "guardianDistanceFromExpected:", tostring(guardianResetDistance),
            "targetId:", TARGET_ELEMENT_ID,
            "targetPosition:", FormatPosition(targetPosition),
            "targetExpectedPosition:", FormatPosition(runtime.TargetStartPosition),
            "targetDistanceFromExpected:", tostring(targetResetDistance))
    end)
end

local function StopTrackingAndReset(context, runtime, reason)
    if runtime.Stopping or runtime.Finished then
        return
    end
    runtime.Stopping = true

    RemoveTimer(context, runtime, "SampleTimerId")
    RemoveTimer(context, runtime, "TimeoutTimerId")
    UnregisterTriggerEvent(runtime)

    local stopPosition = Element:GetPosition(GUARDIAN_ELEMENT_ID)
    if runtime.TrackingStarted then
        Element:StopTracking(GUARDIAN_ELEMENT_ID)
        runtime.TrackingStarted = false
    end
    Log:PrintServerLog("[GuardianTrackTest] 已调用 StopTracking，等待一帧复位",
        "reason:", reason,
        "guardianPosition:", FormatPosition(stopPosition),
        "expectedPosition:", FormatPosition(runtime.GuardianStartPosition))

    runtime.ResetTimerId = context.Timers:AddFrame(GuardianTrackTest.Name, 1, function()
        runtime.ResetTimerId = nil
        Element:SetPosition(
            GUARDIAN_ELEMENT_ID,
            runtime.GuardianStartPosition,
            Element.COORDINATE.World
        )
        Element:SetPosition(
            TARGET_ELEMENT_ID,
            runtime.TargetStartPosition,
            Element.COORDINATE.World
        )
        local guardianPosition = Element:GetPosition(GUARDIAN_ELEMENT_ID)
        local targetPosition = Element:GetPosition(TARGET_ELEMENT_ID)
        Log:PrintServerLog("[GuardianTrackTest] 停止追踪后一帧执行双方复位",
            "guardianPosition:", FormatPosition(guardianPosition),
            "guardianExpectedPosition:", FormatPosition(runtime.GuardianStartPosition),
            "targetPosition:", FormatPosition(targetPosition),
            "targetExpectedPosition:", FormatPosition(runtime.TargetStartPosition))
        FinishAfterReset(context, runtime, reason)
    end)
end

local function LogEventArguments(...)
    local arguments = { n = select("#", ...), ... }
    Log:PrintServerLog("[GuardianTrackTest] 收到 ON_ELEMENT_ENTER_TRIGGER",
        "argumentCount:", arguments.n)
    for index = 1, arguments.n do
        local value = arguments[index]
        Log:PrintServerLog("[GuardianTrackTest] 触发事件参数",
            "index:", index,
            "type:", type(value),
            "value:", tostring(value))
    end
end

function GuardianTrackTest:Start(context)
    if context.Side ~= "Server" then
        return
    end

    local runtime = {
        Finished = false,
        Stopping = false,
        CatchDetected = false,
        TrackingStarted = false,
        GuardianStartPosition = nil,
        TargetStartPosition = nil,
        SampleTimerId = nil,
        TimeoutTimerId = nil,
        ResetTimerId = nil,
        VerifyTimerId = nil,
        TriggerCallback = nil,
        SampleIndex = 0,
    }
    context.Services.GuardianTrackTest = runtime

    Log:PrintServerLog("[GuardianTrackTest] 已启用，等待执行",
        "guardianId:", GUARDIAN_ELEMENT_ID,
        "targetId:", TARGET_ELEMENT_ID,
        "triggerBoxId:", GUARDIAN_TRIGGER_BOX_ID,
        "startDelay:", START_DELAY_SECONDS,
        "timeout:", TEST_TIMEOUT_SECONDS)

    context.Timers:AddTimer(self.Name, START_DELAY_SECONDS, function()
        local guardianPosition = Element:GetPosition(GUARDIAN_ELEMENT_ID)
        local targetPosition = Element:GetPosition(TARGET_ELEMENT_ID)
        if not guardianPosition then
            error("无法读取守护者元件位置，guardianId=" .. tostring(GUARDIAN_ELEMENT_ID))
        end
        if not targetPosition then
            error("无法读取追踪目标元件位置，targetId=" .. tostring(TARGET_ELEMENT_ID))
        end

        runtime.GuardianStartPosition = CopyPosition(guardianPosition)
        runtime.TargetStartPosition = CopyPosition(targetPosition)
        runtime.TriggerCallback = function(...)
            local eventArguments = { n = select("#", ...), ... }
            local unpackArguments = table.unpack or unpack
            local ok, errorMessage = xpcall(function()
                LogEventArguments(unpackArguments(eventArguments, 1, eventArguments.n))
                local targetIsInside = TriggerBox:IsElementInTriggerBox(
                    TARGET_ELEMENT_ID,
                    GUARDIAN_TRIGGER_BOX_ID
                )
                Log:PrintServerLog("[GuardianTrackTest] 触发事件后检查目标是否在守护者触发盒内",
                    "targetId:", TARGET_ELEMENT_ID,
                    "triggerBoxId:", GUARDIAN_TRIGGER_BOX_ID,
                    "isInside:", tostring(targetIsInside))

                if targetIsInside == true and not runtime.CatchDetected then
                    runtime.CatchDetected = true
                    StopTrackingAndReset(context, runtime, "target_entered_guardian_trigger")
                end
            end, Traceback)
            if not ok then
                context.Manager:FailModule(GuardianTrackTest.Name,
                    "ON_ELEMENT_ENTER_TRIGGER 回调失败: " .. tostring(errorMessage))
            end
        end
        System:RegisterEvent(Events.ON_ELEMENT_ENTER_TRIGGER, runtime.TriggerCallback)

        Log:PrintServerLog("[GuardianTrackTest] 调用 TrackTarget",
            "guardianId:", GUARDIAN_ELEMENT_ID,
            "guardianStartPosition:", FormatPosition(runtime.GuardianStartPosition),
            "targetId:", TARGET_ELEMENT_ID,
            "targetStartPosition:", FormatPosition(targetPosition),
            "triggerBoxId:", GUARDIAN_TRIGGER_BOX_ID,
            "initialSpeed:", INITIAL_SPEED,
            "acceleration:", ACCELERATION,
            "maxVelocity:", MAX_VELOCITY,
            "distanceKeep:", DISTANCE_KEEP,
            "initialDistance:", Distance(guardianPosition, targetPosition))

        Element:TrackTarget(
            GUARDIAN_ELEMENT_ID,
            TARGET_ELEMENT_ID,
            INITIAL_SPEED,
            ACCELERATION,
            MAX_VELOCITY,
            DISTANCE_KEEP
        )
        runtime.TrackingStarted = true

        runtime.SampleTimerId = context.Timers:AddLoopTimer(self.Name, SAMPLE_INTERVAL_SECONDS, function()
            runtime.SampleIndex = runtime.SampleIndex + 1
            local currentGuardianPosition = Element:GetPosition(GUARDIAN_ELEMENT_ID)
            local currentTargetPosition = Element:GetPosition(TARGET_ELEMENT_ID)
            if not currentGuardianPosition then
                error("追踪期间无法读取守护者位置，guardianId=" .. tostring(GUARDIAN_ELEMENT_ID))
            end
            if not currentTargetPosition then
                error("追踪期间无法读取目标位置，targetId=" .. tostring(TARGET_ELEMENT_ID))
            end

            Log:PrintServerLog("[GuardianTrackTest] 追踪采样",
                "second:", runtime.SampleIndex,
                "guardianPosition:", FormatPosition(currentGuardianPosition),
                "targetPosition:", FormatPosition(currentTargetPosition),
                "distance:", Distance(currentGuardianPosition, currentTargetPosition))
        end)

        runtime.TimeoutTimerId = context.Timers:AddTimer(self.Name, TEST_TIMEOUT_SECONDS, function()
            runtime.TimeoutTimerId = nil
            StopTrackingAndReset(context, runtime, "trigger_not_detected_before_timeout")
        end)
    end)
end

function GuardianTrackTest:Stop(context)
    if context.Side ~= "Server" then
        return
    end

    local runtime = context.Services.GuardianTrackTest
    if not runtime then
        return
    end
    UnregisterTriggerEvent(runtime)
    if runtime.TrackingStarted then
        Element:StopTracking(GUARDIAN_ELEMENT_ID)
        runtime.TrackingStarted = false
    end
end

return GuardianTrackTest
