-- 临时回归模块：验证元件先定位到玩家上方，再附加到角色 Root 并保持相对位置。
local CharacterBindingTest = {
    Name = "CharacterBindingTest",
    FeatureFlag = "CharacterBindingTest",
    Dependencies = {},
}

local TARGET_ELEMENT_ID = 325
local HEIGHT_OFFSET = 150
local START_DELAY_SECONDS = 1
local TEST_DURATION_SECONDS = 15
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

local function RelativeOffset(elementPosition, playerPosition)
    return Engine.Vector(
        elementPosition.X - playerPosition.X,
        elementPosition.Y - playerPosition.Y,
        elementPosition.Z - playerPosition.Z
    )
end

local function RemoveSampleTimer(context, runtime)
    if runtime.SampleTimerId then
        context.Timers:Remove(runtime.SampleTimerId)
        runtime.SampleTimerId = nil
    end
end

local function FinishTest(context, reason)
    local runtime = context.Services.CharacterBindingTest
    if not runtime or runtime.Finished or runtime.Stopping then
        return
    end
    runtime.Stopping = true
    RemoveSampleTimer(context, runtime)

    if runtime.Bound then
        Element:UnBinding(TARGET_ELEMENT_ID)
        runtime.Bound = false
    end

    runtime.ResetTimerId = context.Timers:AddFrame(CharacterBindingTest.Name, 1, function()
        runtime.ResetTimerId = nil
        Element:SetPosition(
            TARGET_ELEMENT_ID,
            runtime.ElementStartPosition,
            Element.COORDINATE.World
        )
        runtime.VerifyTimerId = context.Timers:AddFrame(CharacterBindingTest.Name, 1, function()
            runtime.VerifyTimerId = nil
            runtime.Finished = true
            local elementPosition = Element:GetPosition(TARGET_ELEMENT_ID)
            local attachedPlayerId = Element:GetAttachParentCharacter(TARGET_ELEMENT_ID)
            Log:PrintServerLog("[CharacterBindingTest] 测试结束，已解绑并复位",
                "reason:", reason,
                "elementId:", TARGET_ELEMENT_ID,
                "elementPosition:", FormatPosition(elementPosition),
                "expectedPosition:", FormatPosition(runtime.ElementStartPosition),
                "attachedPlayerId:", tostring(attachedPlayerId))
        end)
    end)
end

function CharacterBindingTest:Start(context)
    if context.Side ~= "Server" then
        return
    end

    local runtime = {
        Finished = false,
        Stopping = false,
        Bound = false,
        PlayerId = nil,
        ElementStartPosition = nil,
        SampleTimerId = nil,
        BindDelayTimerId = nil,
        PostBindVerifyTimerId = nil,
        ResetTimerId = nil,
        VerifyTimerId = nil,
        SampleIndex = 0,
    }
    context.Services.CharacterBindingTest = runtime

    Log:PrintServerLog("[CharacterBindingTest] 已启用，等待执行",
        "elementId:", TARGET_ELEMENT_ID,
        "heightOffset:", HEIGHT_OFFSET,
        "socket:", Character.SOCKET_NAME.Root,
        "socketMode:", Character.SOCKET_MODE.KeepWorld,
        "duration:", TEST_DURATION_SECONDS)

    context.Timers:AddTimer(self.Name, START_DELAY_SECONDS, function()
        local playerIds = Character:GetAllPlayerIds() or {}
        local playerId = playerIds[1]
        if not playerId then
            error("没有可用于附加测试的玩家")
        end

        local playerPosition = Character:GetPosition(playerId)
        local elementPosition = Element:GetPosition(TARGET_ELEMENT_ID)
        if not playerPosition then
            error("无法读取玩家位置，playerId=" .. tostring(playerId))
        end
        if not elementPosition then
            error("无法读取目标元件位置，elementId=" .. tostring(TARGET_ELEMENT_ID))
        end

        runtime.PlayerId = playerId
        runtime.ElementStartPosition = CopyPosition(elementPosition)
        local bindPosition = Engine.Vector(
            playerPosition.X,
            playerPosition.Y,
            playerPosition.Z + HEIGHT_OFFSET
        )

        Element:SetPosition(
            TARGET_ELEMENT_ID,
            bindPosition,
            Element.COORDINATE.World
        )
        local positionedElementPosition = Element:GetPosition(TARGET_ELEMENT_ID)
        Log:PrintServerLog("[CharacterBindingTest] 附加前已设置到玩家上方",
            "playerId:", playerId,
            "playerPosition:", FormatPosition(playerPosition),
            "elementId:", TARGET_ELEMENT_ID,
            "requestedPosition:", FormatPosition(bindPosition),
            "actualPosition:", FormatPosition(positionedElementPosition))

        runtime.BindDelayTimerId = context.Timers:AddFrame(self.Name, 2, function()
            runtime.BindDelayTimerId = nil
            local beforeBindPlayerPosition = Character:GetPosition(playerId)
            local beforeBindElementPosition = Element:GetPosition(TARGET_ELEMENT_ID)
            if not beforeBindPlayerPosition then
                error("附加前无法读取玩家位置，playerId=" .. tostring(playerId))
            end
            if not beforeBindElementPosition then
                error("附加前无法读取元件位置，elementId=" .. tostring(TARGET_ELEMENT_ID))
            end

            Log:PrintServerLog("[CharacterBindingTest] 设置位置后延迟两帧，准备附加",
                "playerPosition:", FormatPosition(beforeBindPlayerPosition),
                "elementPosition:", FormatPosition(beforeBindElementPosition),
                "relativeOffset:", FormatPosition(RelativeOffset(
                    beforeBindElementPosition,
                    beforeBindPlayerPosition
                )))

            Element:BindingToCharacterOrCreature(
                TARGET_ELEMENT_ID,
                playerId,
                Character.SOCKET_NAME.Root,
                Character.SOCKET_MODE.KeepWorld
            )
            runtime.Bound = true

            local immediatePlayerPosition = Character:GetPosition(playerId)
            local immediateElementPosition = Element:GetPosition(TARGET_ELEMENT_ID)
            if not immediatePlayerPosition then
                error("附加后立即无法读取玩家位置，playerId=" .. tostring(playerId))
            end
            if not immediateElementPosition then
                error("附加后立即无法读取元件位置，elementId=" .. tostring(TARGET_ELEMENT_ID))
            end
            Log:PrintServerLog("[CharacterBindingTest] KeepWorld 附加后立即检查",
                "elementId:", TARGET_ELEMENT_ID,
                "playerId:", playerId,
                "socket:", Character.SOCKET_NAME.Root,
                "socketMode:", Character.SOCKET_MODE.KeepWorld,
                "playerPosition:", FormatPosition(immediatePlayerPosition),
                "elementPosition:", FormatPosition(immediateElementPosition),
                "relativeOffset:", FormatPosition(RelativeOffset(
                    immediateElementPosition,
                    immediatePlayerPosition
                )),
                "attachedPlayerId:", tostring(Element:GetAttachParentCharacter(TARGET_ELEMENT_ID)))

            runtime.PostBindVerifyTimerId = context.Timers:AddFrame(self.Name, 1, function()
                runtime.PostBindVerifyTimerId = nil
                local postBindPlayerPosition = Character:GetPosition(playerId)
                local postBindElementPosition = Element:GetPosition(TARGET_ELEMENT_ID)
                if not postBindPlayerPosition then
                    error("附加后一帧无法读取玩家位置，playerId=" .. tostring(playerId))
                end
                if not postBindElementPosition then
                    error("附加后一帧无法读取元件位置，elementId=" .. tostring(TARGET_ELEMENT_ID))
                end

                Log:PrintServerLog("[CharacterBindingTest] KeepWorld 附加后一帧检查",
                    "playerPosition:", FormatPosition(postBindPlayerPosition),
                    "elementPosition:", FormatPosition(postBindElementPosition),
                    "relativeOffset:", FormatPosition(RelativeOffset(
                        postBindElementPosition,
                        postBindPlayerPosition
                    )),
                    "attachedPlayerId:", tostring(Element:GetAttachParentCharacter(TARGET_ELEMENT_ID)))

                runtime.SampleTimerId = context.Timers:AddLoopTimer(
                    self.Name,
                    SAMPLE_INTERVAL_SECONDS,
                    function()
                        runtime.SampleIndex = runtime.SampleIndex + 1
                        local currentPlayerPosition = Character:GetPosition(playerId)
                        local currentElementPosition = Element:GetPosition(TARGET_ELEMENT_ID)
                        if not currentPlayerPosition then
                            error("附加期间无法读取玩家位置，playerId=" .. tostring(playerId))
                        end
                        if not currentElementPosition then
                            error("附加期间无法读取元件位置，elementId=" .. tostring(TARGET_ELEMENT_ID))
                        end

                        local offset = RelativeOffset(currentElementPosition, currentPlayerPosition)
                        local attachedPlayerId = Element:GetAttachParentCharacter(TARGET_ELEMENT_ID)
                        Log:PrintServerLog("[CharacterBindingTest] 附加采样",
                            "second:", runtime.SampleIndex,
                            "playerPosition:", FormatPosition(currentPlayerPosition),
                            "elementPosition:", FormatPosition(currentElementPosition),
                            "relativeOffset:", FormatPosition(offset),
                            "attachedPlayerId:", tostring(attachedPlayerId))
                    end
                )

                context.Timers:AddTimer(self.Name, TEST_DURATION_SECONDS, function()
                    FinishTest(context, "duration_reached")
                end)
            end)
        end)
    end)
end

function CharacterBindingTest:Stop(context)
    if context.Side ~= "Server" then
        return
    end

    local runtime = context.Services.CharacterBindingTest
    if not runtime or runtime.Finished then
        return
    end
    if runtime.Bound then
        Element:UnBinding(TARGET_ELEMENT_ID)
        runtime.Bound = false
    end
    if runtime.ElementStartPosition then
        Element:SetPosition(
            TARGET_ELEMENT_ID,
            runtime.ElementStartPosition,
            Element.COORDINATE.World
        )
    end
    runtime.Finished = true
end

return CharacterBindingTest
