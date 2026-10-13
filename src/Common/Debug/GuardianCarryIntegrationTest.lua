-- 临时组合测试：目标附加玩家后，守护者追踪目标并用附加触发盒判定捕获。
local GuardianCarryIntegrationTest = {
    Name = "GuardianCarryIntegrationTest",
    FeatureFlag = "GuardianCarryIntegrationTest",
    Dependencies = {},
}

local GUARDIAN_ELEMENT_ID = 257
local TARGET_ELEMENT_ID = 325
local GUARDIAN_TRIGGER_BOX_ID = 404
local CARRY_HEIGHT_OFFSET = 150
local BIND_DELAY_FRAMES = 2
local POST_BIND_VERIFY_FRAMES = 1
local TRACK_DELAY_SECONDS = 3
local INITIAL_SPEED = 500
local ACCELERATION = 100
local MAX_VELOCITY = 800
local DISTANCE_KEEP = 0
local KNOCKBACK_HORIZONTAL_FORCE = 10000
local KNOCKBACK_UP_FORCE = 1000
local SAMPLE_INTERVAL_SECONDS = 1

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

local function BuildKnockbackImpulse(guardianPosition, playerPosition)
    local deltaX = playerPosition.X - guardianPosition.X
    local deltaY = playerPosition.Y - guardianPosition.Y
    local horizontalLength = math.sqrt(deltaX * deltaX + deltaY * deltaY)
    if horizontalLength <= 0 then
        error("守护者与玩家水平位置重合，无法计算击飞方向")
    end

    return Engine.Vector(
        deltaX / horizontalLength * KNOCKBACK_HORIZONTAL_FORCE,
        deltaY / horizontalLength * KNOCKBACK_HORIZONTAL_FORCE,
        KNOCKBACK_UP_FORCE
    )
end

local function RemoveSampleTimer(context, runtime)
    if runtime.SampleTimerId then
        context.Timers:Remove(runtime.SampleTimerId)
        runtime.SampleTimerId = nil
    end
end

function GuardianCarryIntegrationTest:Start(context)
    if context.Side ~= "Server" then
        return
    end

    local GuardianTrackingService = require "Server.Services.GuardianTrackingService"
    local runtime = {
        PlayerId = nil,
        GuardianStartPosition = nil,
        TargetStartPosition = nil,
        Bound = false,
        Completed = false,
        Tracker = nil,
        BindTimerId = nil,
        PostBindTimerId = nil,
        TrackDelayTimerId = nil,
        SampleTimerId = nil,
        SampleIndex = 0,
    }
    context.Services.GuardianCarryIntegrationTest = runtime

    runtime.Tracker = GuardianTrackingService.New(
        self.Name,
        context.Timers,
        function(errorMessage)
            context.Manager:FailModule(self.Name, errorMessage)
        end
    )
    runtime.Tracker:Start()

    local playerIds = Character:GetAllPlayerIds() or {}
    local playerId = playerIds[1]
    if not playerId then
        error("没有可用于守护者携带组合测试的玩家")
    end

    local playerPosition = Character:GetPosition(playerId)
    local guardianPosition = Element:GetPosition(GUARDIAN_ELEMENT_ID)
    local targetPosition = Element:GetPosition(TARGET_ELEMENT_ID)
    if not playerPosition then
        error("无法读取玩家位置，playerId=" .. tostring(playerId))
    end
    if not guardianPosition then
        error("无法读取守护者位置，guardianId=" .. tostring(GUARDIAN_ELEMENT_ID))
    end
    if not targetPosition then
        error("无法读取目标位置，targetId=" .. tostring(TARGET_ELEMENT_ID))
    end

    runtime.PlayerId = playerId
    runtime.GuardianStartPosition = CopyPosition(guardianPosition)
    runtime.TargetStartPosition = CopyPosition(targetPosition)

    local carryPosition = Engine.Vector(
        playerPosition.X,
        playerPosition.Y,
        playerPosition.Z + CARRY_HEIGHT_OFFSET
    )
    Element:SetPosition(
        TARGET_ELEMENT_ID,
        carryPosition,
        Element.COORDINATE.World
    )
    Log:PrintServerLog("[GuardianCarryIntegrationTest] 已设置携带目标位置，等待两帧附加",
        "playerId:", playerId,
        "playerPosition:", FormatPosition(playerPosition),
        "targetId:", TARGET_ELEMENT_ID,
        "targetPosition:", FormatPosition(Element:GetPosition(TARGET_ELEMENT_ID)),
        "heightOffset:", CARRY_HEIGHT_OFFSET)

    runtime.BindTimerId = context.Timers:AddFrame(self.Name, BIND_DELAY_FRAMES, function()
        runtime.BindTimerId = nil
        Element:BindingToCharacterOrCreature(
            TARGET_ELEMENT_ID,
            playerId,
            Character.SOCKET_NAME.Root,
            Character.SOCKET_MODE.KeepWorld
        )
        runtime.Bound = true

        runtime.PostBindTimerId = context.Timers:AddFrame(self.Name, POST_BIND_VERIFY_FRAMES, function()
            runtime.PostBindTimerId = nil
            local attachedPlayerId = Element:GetAttachParentCharacter(TARGET_ELEMENT_ID)
            local boundTargetPosition = Element:GetPosition(TARGET_ELEMENT_ID)
            local currentPlayerPosition = Character:GetPosition(playerId)
            Log:PrintServerLog("[GuardianCarryIntegrationTest] 携带目标附加完成",
                "targetId:", TARGET_ELEMENT_ID,
                "attachedPlayerId:", tostring(attachedPlayerId),
                "expectedPlayerId:", playerId,
                "targetPosition:", FormatPosition(boundTargetPosition),
                "playerPosition:", FormatPosition(currentPlayerPosition),
                "trackDelay:", TRACK_DELAY_SECONDS)

            if attachedPlayerId ~= playerId then
                error("目标元件没有附加到预期玩家")
            end

            runtime.TrackDelayTimerId = context.Timers:AddTimer(
                self.Name,
                TRACK_DELAY_SECONDS,
                function()
                    runtime.TrackDelayTimerId = nil
                    local started, failureReason = runtime.Tracker:TrackTarget({
                        debugName = "偷取区域1守护者追踪携带目标325",
                        guardianElementId = GUARDIAN_ELEMENT_ID,
                        triggerBoxId = GUARDIAN_TRIGGER_BOX_ID,
                        targetElementId = TARGET_ELEMENT_ID,
                        guardianReturnPosition = runtime.GuardianStartPosition,
                        targetReturnPosition = runtime.TargetStartPosition,
                        initialSpeed = INITIAL_SPEED,
                        acceleration = ACCELERATION,
                        maxVelocity = MAX_VELOCITY,
                        distanceKeep = DISTANCE_KEEP,
                        onCaught = function(caughtResult)
                            RemoveSampleTimer(context, runtime)
                            local playerPositionBeforeImpulse = Character:GetPosition(playerId)
                            if not playerPositionBeforeImpulse then
                                error("捕获时无法读取玩家位置，playerId=" .. tostring(playerId))
                            end
                            if not caughtResult.guardianPosition then
                                error("捕获结果缺少守护者位置")
                            end

                            if runtime.Bound then
                                Element:UnBinding(TARGET_ELEMENT_ID)
                                runtime.Bound = false
                            end

                            local impulseVector = BuildKnockbackImpulse(
                                caughtResult.guardianPosition,
                                playerPositionBeforeImpulse
                            )
                            Character:AddImpulse(playerId, impulseVector)
                            Log:PrintServerLog("[GuardianCarryIntegrationTest] 目标进入守护者触发盒，已停止追踪、解绑并击飞玩家",
                                "guardianId:", caughtResult.guardianElementId,
                                "guardianPosition:", FormatPosition(caughtResult.guardianPosition),
                                "targetId:", caughtResult.targetElementId,
                                "triggerBoxId:", caughtResult.triggerBoxId,
                                "playerId:", playerId,
                                "playerPositionBeforeImpulse:", FormatPosition(playerPositionBeforeImpulse),
                                "impulseVector:", FormatPosition(impulseVector),
                                "horizontalForce:", KNOCKBACK_HORIZONTAL_FORCE,
                                "upForce:", KNOCKBACK_UP_FORCE,
                                "attachedPlayerIdAfterUnbind:", tostring(
                                    Element:GetAttachParentCharacter(TARGET_ELEMENT_ID)
                                ))

                            context.Timers:AddFrame(self.Name, 1, function()
                                Log:PrintServerLog("[GuardianCarryIntegrationTest] 击飞后一帧玩家位置",
                                    "playerId:", playerId,
                                    "playerPosition:", FormatPosition(Character:GetPosition(playerId)))
                            end)
                        end,
                        onReturned = function(returnResult)
                            runtime.Completed = true
                            Log:PrintServerLog("[GuardianCarryIntegrationTest] 捕获流程完成，双方已复位",
                                "guardianId:", returnResult.guardianElementId,
                                "guardianPosition:", FormatPosition(returnResult.guardianPosition),
                                "guardianDistanceFromReturn:", returnResult.guardianDistanceFromReturn,
                                "targetId:", returnResult.targetElementId,
                                "targetPosition:", FormatPosition(returnResult.targetPosition),
                                "targetDistanceFromReturn:", returnResult.targetDistanceFromReturn,
                                "attachedPlayerId:", tostring(
                                    Element:GetAttachParentCharacter(TARGET_ELEMENT_ID)
                                ))
                        end,
                    })
                    if not started then
                        error("无法开始组合追踪测试: " .. tostring(failureReason))
                    end

                    Log:PrintServerLog("[GuardianCarryIntegrationTest] 守护者开始追踪玩家携带的目标",
                        "guardianId:", GUARDIAN_ELEMENT_ID,
                        "targetId:", TARGET_ELEMENT_ID,
                        "triggerBoxId:", GUARDIAN_TRIGGER_BOX_ID,
                        "initialSpeed:", INITIAL_SPEED,
                        "acceleration:", ACCELERATION,
                        "maxVelocity:", MAX_VELOCITY,
                        "distanceKeep:", DISTANCE_KEEP,
                        "knockbackHorizontalForce:", KNOCKBACK_HORIZONTAL_FORCE,
                        "knockbackUpForce:", KNOCKBACK_UP_FORCE)

                    runtime.SampleTimerId = context.Timers:AddLoopTimer(
                        self.Name,
                        SAMPLE_INTERVAL_SECONDS,
                        function()
                            runtime.SampleIndex = runtime.SampleIndex + 1
                            local currentGuardianPosition = Element:GetPosition(GUARDIAN_ELEMENT_ID)
                            local currentTargetPosition = Element:GetPosition(TARGET_ELEMENT_ID)
                            local currentPlayerPosition = Character:GetPosition(playerId)
                            if not currentGuardianPosition or not currentTargetPosition or not currentPlayerPosition then
                                error("组合追踪采样无法读取完整位置")
                            end
                            Log:PrintServerLog("[GuardianCarryIntegrationTest] 组合追踪采样",
                                "second:", runtime.SampleIndex,
                                "guardianPosition:", FormatPosition(currentGuardianPosition),
                                "targetPosition:", FormatPosition(currentTargetPosition),
                                "playerPosition:", FormatPosition(currentPlayerPosition),
                                "guardianTargetDistance:", Distance(
                                    currentGuardianPosition,
                                    currentTargetPosition
                                ),
                                "attachedPlayerId:", tostring(
                                    Element:GetAttachParentCharacter(TARGET_ELEMENT_ID)
                                ))
                        end
                    )
                end
            )
        end)
    end)
end

function GuardianCarryIntegrationTest:Stop(context)
    if context.Side ~= "Server" then
        return
    end

    local runtime = context.Services.GuardianCarryIntegrationTest
    if not runtime then
        return
    end
    RemoveSampleTimer(context, runtime)
    if runtime.Tracker then
        runtime.Tracker:Stop()
    end
    if runtime.Bound then
        Element:UnBinding(TARGET_ELEMENT_ID)
        runtime.Bound = false
    end
    if runtime.GuardianStartPosition then
        Element:SetPosition(
            GUARDIAN_ELEMENT_ID,
            runtime.GuardianStartPosition,
            Element.COORDINATE.World
        )
    end
    if runtime.TargetStartPosition then
        Element:SetPosition(
            TARGET_ELEMENT_ID,
            runtime.TargetStartPosition,
            Element.COORDINATE.World
        )
    end
end

return GuardianCarryIntegrationTest
