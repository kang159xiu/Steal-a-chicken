-- 临时诊断：客户端启动 2 秒后，只读取一次本地玩家头像，不设置任何图片。
local AvatarReadTest = {
    Name = "AvatarReadTest",
    FeatureFlag = "AvatarReadTest",
    Dependencies = {},
}

local START_DELAY_SECONDS = 2

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

function AvatarReadTest:Start(context)
    if context.Side ~= "Client" then
        Log:PrintServerLog("[AvatarReadTest] 服务端不执行头像读取测试")
        return
    end

    local runtime = {
        TimerId = nil,
    }
    context.Services.AvatarReadTest = runtime

    Log:PrintLog("[AvatarReadTest] 测试已启动，等待2秒",
        "startDelaySeconds:", START_DELAY_SECONDS)

    runtime.TimerId = context.Timers:AddTimer(
        AvatarReadTest.Name,
        START_DELAY_SECONDS,
        function()
            runtime.TimerId = nil
            local playerId = Character:GetLocalPlayerId()
            Log:PrintLog("[AvatarReadTest] 2秒延迟结束，准备读取本地玩家头像",
                "playerSelection:", "Character:GetLocalPlayerId",
                "playerId:", tostring(playerId),
                "playerIdType:", type(playerId))

            local getOk, imageId, isCustom = xpcall(function()
                return Chat:GetCustomHeadIconImage(playerId)
            end, Traceback)
            Log:PrintLog("[AvatarReadTest] GetCustomHeadIconImage测试结果",
                "success:", tostring(getOk),
                "playerId:", tostring(playerId),
                "imageId:", tostring(imageId),
                "imageIdType:", type(imageId),
                "isCustom:", tostring(isCustom),
                "isCustomType:", type(isCustom))
            if not getOk then
                Log:PrintError("[AvatarReadTest] GetCustomHeadIconImage调用失败",
                    "playerId:", tostring(playerId),
                    "error:", tostring(imageId))
            end
        end
    )
end

function AvatarReadTest:Stop(context)
    context.Services.AvatarReadTest = nil
end

return AvatarReadTest
