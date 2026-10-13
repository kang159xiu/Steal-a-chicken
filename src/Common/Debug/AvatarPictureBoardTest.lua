-- 临时诊断：客户端启动 3 秒后，把本地玩家头像原始返回值直接设置到图标显示器 657。
local AvatarPictureBoardTest = {
    Name = "AvatarPictureBoardTest",
    FeatureFlag = "AvatarPictureBoardTest",
    Dependencies = {},
}

local PICTURE_BOARD_ELEMENT_ID = 658
local PICTURE_SIZE = 1
local FORCE_CUSTOM_IMAGE = true
local START_DELAY_SECONDS = 3
local POST_SET_LOG_DELAY_FRAMES = 2

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

function AvatarPictureBoardTest:Start(context)
    if context.Side ~= "Client" then
        Log:PrintServerLog("[AvatarPictureBoardTest] 服务端不执行头像显示器测试")
        return
    end

    local runtime = {
        TimerId = nil,
        PostSetTimerId = nil,
    }
    context.Services.AvatarPictureBoardTest = runtime

    Log:PrintLog("[AvatarPictureBoardTest] 测试已启动，等待3秒",
        "pictureBoardElementId:", PICTURE_BOARD_ELEMENT_ID,
        "pictureSize:", PICTURE_SIZE,
        "forceCustomImage:", tostring(FORCE_CUSTOM_IMAGE),
        "startDelaySeconds:", START_DELAY_SECONDS)

    runtime.TimerId = context.Timers:AddTimer(
        AvatarPictureBoardTest.Name,
        START_DELAY_SECONDS,
        function()
            runtime.TimerId = nil
            local playerId = Character:GetLocalPlayerId()
            Log:PrintLog("[AvatarPictureBoardTest] 3秒延迟结束，准备读取玩家1头像",
                "playerSelection:", "Character:GetLocalPlayerId",
                "playerId:", tostring(playerId),
                "playerIdType:", type(playerId),
                "pictureBoardElementId:", PICTURE_BOARD_ELEMENT_ID)

            local getOk, imageId, isCustom = xpcall(function()
                return Chat:GetCustomHeadIconImage(playerId)
            end, Traceback)
            Log:PrintLog("[AvatarPictureBoardTest] GetCustomHeadIconImage返回",
                "success:", tostring(getOk),
                "playerId:", tostring(playerId),
                "imageId:", tostring(imageId),
                "imageIdType:", type(imageId),
                "isCustom:", tostring(isCustom),
                "isCustomType:", type(isCustom))
            if not getOk then
                Log:PrintError("[AvatarPictureBoardTest] 获取玩家头像调用失败",
                    "playerId:", tostring(playerId),
                    "error:", tostring(imageId))
                return
            end

            local setOk, setResult = xpcall(function()
                return FuncElement:SetPictureBoardImage(
                    PICTURE_BOARD_ELEMENT_ID,
                    imageId,
                    PICTURE_SIZE,
                    FORCE_CUSTOM_IMAGE
                )
            end, Traceback)
            Log:PrintLog("[AvatarPictureBoardTest] SetPictureBoardImage调用结果",
                "success:", tostring(setOk),
                "result:", tostring(setResult),
                "pictureBoardElementId:", PICTURE_BOARD_ELEMENT_ID,
                "playerId:", tostring(playerId),
                "imageId:", tostring(imageId),
                "pictureSize:", PICTURE_SIZE,
                "apiReturnedIsCustom:", tostring(isCustom),
                "passedIsCustomImage:", tostring(FORCE_CUSTOM_IMAGE))
            if not setOk then
                Log:PrintError("[AvatarPictureBoardTest] 设置图标显示器调用失败",
                    "pictureBoardElementId:", PICTURE_BOARD_ELEMENT_ID,
                    "error:", tostring(setResult))
                return
            end

            runtime.PostSetTimerId = context.Timers:AddFrame(
                AvatarPictureBoardTest.Name,
                POST_SET_LOG_DELAY_FRAMES,
                function()
                    runtime.PostSetTimerId = nil
                    Log:PrintLog("[AvatarPictureBoardTest] 设置后已等待2帧，请观察657显示结果",
                        "pictureBoardElementId:", PICTURE_BOARD_ELEMENT_ID,
                        "playerId:", tostring(playerId),
                        "imageId:", tostring(imageId),
                        "pictureSize:", PICTURE_SIZE,
                        "apiReturnedIsCustom:", tostring(isCustom),
                        "passedIsCustomImage:", tostring(FORCE_CUSTOM_IMAGE),
                        "postSetDelayFrames:", POST_SET_LOG_DELAY_FRAMES)
                end
            )
        end
    )
end

function AvatarPictureBoardTest:Stop(context)
    context.Services.AvatarPictureBoardTest = nil
end

return AvatarPictureBoardTest
