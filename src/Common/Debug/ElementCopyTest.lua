-- 临时回归模块：验证服务端元件树复制、同步、整体移动和销毁。
local ElementCopyTest = {
    Name = "ElementCopyTest",
    FeatureFlag = "ElementCopyTest",
    Dependencies = {},
}

local SOURCE_ROOT_ID = 235
local START_DELAY_SECONDS = 1
local DESTROY_DELAY_SECONDS = 5
local TARGET_HEIGHT_OFFSET = 300

function ElementCopyTest:Start(context)
    -- 两端都登记同一个测试模块；只有服务端创建共享元件。
    if context.Side ~= "Server" then
        return
    end

    Log:PrintServerLog("[ElementCopyTest] 已启用，等待执行",
        "sourceRootId:", SOURCE_ROOT_ID,
        "startDelay:", START_DELAY_SECONDS)

    context.Timers:AddTimer(self.Name, START_DELAY_SECONDS, function()
        local playerIds = Character:GetAllPlayerIds() or {}
        local playerId = playerIds[1]
        if not playerId then
            Log:PrintError("[ElementCopyTest] 没有可用于定位的玩家，测试结束")
            return
        end

        local playerPos = Character:GetPosition(playerId)
        if not playerPos then
            Log:PrintError("[ElementCopyTest] 无法读取玩家位置，测试结束", "playerId:", playerId)
            return
        end

        local targetPos = Engine.Vector(playerPos.X, playerPos.Y, playerPos.Z + TARGET_HEIGHT_OFFSET)
        Log:PrintServerLog("[ElementCopyTest] 开始复制到玩家上方",
            "playerId:", playerId,
            "sourceRootId:", SOURCE_ROOT_ID,
            "target:", targetPos.X, targetPos.Y, targetPos.Z)

        context.ElementCopy:CopyTree(SOURCE_ROOT_ID, targetPos, "元件复制测试235", function(result)
            if not result.success then
                Log:PrintError("[ElementCopyTest] 复制失败，按规则保留已生成部分",
                    "failedSourceId:", tostring(result.failedSourceId),
                    "reason:", tostring(result.reason))
                return
            end

            Log:PrintServerLog("[ElementCopyTest] 复制成功，5 秒后销毁",
                "rootId:", result.rootId,
                "nodeCount:", #result.spawnedIds)
            context.Timers:AddTimer(self.Name, DESTROY_DELAY_SECONDS, function()
                context.ElementCopy:DestroyTree(result.rootId)
                Log:PrintServerLog("[ElementCopyTest] 已销毁测试元件树", "rootId:", result.rootId)
            end)
        end)
    end)
end

return ElementCopyTest
