-- 元件树复制工具：所有节点先在各自源位置生成并恢复附加关系，
-- 全树成功后同时等待 0.1 秒和 2 帧，只移动复制根到目标位置。
local ElementCopy = {}
ElementCopy.__index = ElementCopy

local NODE_TIMEOUT_SECONDS = 3
local ROOT_MOVE_DELAY_SECONDS = 0.1
local ROOT_MOVE_DELAY_FRAMES = 2
local ROOT_MOVE_SETTLE_FRAMES = 2

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function CopyArray(source)
    local result = {}
    for index, value in ipairs(source or {}) do
        result[index] = value
    end
    return result
end

local function SortedKeys(set)
    local keys = {}
    for key in pairs(set or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function FormatIds(ids)
    local values = {}
    for _, id in ipairs(ids or {}) do
        values[#values + 1] = tostring(id)
    end
    return "[" .. table.concat(values, ",") .. "]"
end

local function FormatPosition(position)
    if not position then
        return "nil"
    end
    return string.format("(%.3f, %.3f, %.3f)", position.X, position.Y, position.Z)
end

local function SafeComplete(debugName, onComplete, result)
    local ok, errorMessage = xpcall(function()
        onComplete(result)
    end, Traceback)
    if not ok then
        Log:PrintError("[ElementCopy] 完成回调报错", debugName, errorMessage)
    end
end

local function SnapshotTree(sourceId)
    local nodes = {}
    local nodeCount = 0
    local visiting = {}

    local function Visit(currentId, parentSourceId)
        if visiting[currentId] then
            error("源元件树存在循环附加，sourceId=" .. tostring(currentId))
        end
        if nodes[currentId] then
            error("源元件在树中重复出现，sourceId=" .. tostring(currentId))
        end

        local pos = Element:GetPosition(currentId)
        local rot = Element:GetRotation(currentId)
        local scale = Element:GetScale(currentId)
        if not pos then
            error("无法读取源元件位置，sourceId=" .. tostring(currentId))
        end
        if not rot then
            error("无法读取源元件旋转，sourceId=" .. tostring(currentId))
        end
        if not scale then
            error("无法读取源元件缩放，sourceId=" .. tostring(currentId))
        end

        local childIds = Element:GetChildElementsFromElement(currentId) or {}
        local node = {
            SourceId = currentId,
            ParentSourceId = parentSourceId,
            Position = pos,
            Rotation = rot,
            Scale = scale,
            ChildIds = {},
        }
        nodes[currentId] = node
        nodeCount = nodeCount + 1
        visiting[currentId] = true

        for _, childId in ipairs(childIds) do
            node.ChildIds[#node.ChildIds + 1] = childId
            Visit(childId, currentId)
        end
        visiting[currentId] = nil
    end

    Visit(sourceId, nil)
    return nodes, nodeCount
end

---创建分端复制器。Server 固定 Replicate=true，Client 固定 Replicate=false。
function ElementCopy.New(side, timerRegistry)
    assert(side == "Server" or side == "Client", "ElementCopy side 必须是 Server 或 Client")
    assert(timerRegistry ~= nil, "ElementCopy 需要 TimerRegistry")
    return setmetatable({
        _side = side,
        _replicate = side == "Server",
        _timers = timerRegistry,
        _operationSequence = 0,
    }, ElementCopy)
end


---复制完整元件树。
---@param sourceRootId number
---@param targetPos Engine.Vector
---@param debugName string
---@param onComplete fun(result: table)
function ElementCopy:CopyTree(sourceRootId, targetPos, debugName, onComplete)
    assert(type(onComplete) == "function", "ElementCopy onComplete 必须是 function")

    if type(debugName) ~= "string" or debugName == "" then
        local result = {
            success = false,
            rootId = nil,
            spawnedIds = {},
            failedSourceId = sourceRootId,
            pendingSourceIds = {},
            reason = "debug_name_invalid",
        }
        Log:PrintError("[ElementCopy] debugName 必须是非空字符串", tostring(sourceRootId))
        SafeComplete(tostring(debugName), onComplete, result)
        return
    end

    if type(sourceRootId) ~= "number" or not targetPos then
        local result = {
            success = false,
            rootId = nil,
            spawnedIds = {},
            failedSourceId = sourceRootId,
            pendingSourceIds = {},
            reason = "argument_invalid",
        }
        Log:PrintError("[ElementCopy] 参数无效", debugName, "sourceRootId:", tostring(sourceRootId))
        SafeComplete(debugName, onComplete, result)
        return
    end

    local snapshotOk, nodes, nodeCount = xpcall(function()
        return SnapshotTree(sourceRootId)
    end, Traceback)
    if not snapshotOk then
        local result = {
            success = false,
            rootId = nil,
            spawnedIds = {},
            failedSourceId = sourceRootId,
            pendingSourceIds = {},
            reason = "snapshot_failed: " .. tostring(nodes),
        }
        Log:PrintError("[ElementCopy] 读取源元件树失败", debugName, nodes)
        SafeComplete(debugName, onComplete, result)
        return
    end

    self._operationSequence = self._operationSequence + 1
    local operation = {
        Owner = "ElementCopy:" .. self._side .. ":" .. tostring(self._operationSequence),
        Completed = false,
        RootCopyId = nil,
        SpawnedIds = {},
        SourceToCopy = {},
        PendingSourceIds = {},
        TimeoutIds = {},
        RemainingCount = nodeCount,
    }

    local function RemoveOutstandingTimeouts()
        local timeoutIds = {}
        for _, timerId in pairs(operation.TimeoutIds) do
            timeoutIds[#timeoutIds + 1] = timerId
        end
        operation.TimeoutIds = {}
        for _, timerId in ipairs(timeoutIds) do
            self._timers:Remove(timerId)
        end
    end

    local function FinishFailure(failedSourceId, reason)
        if operation.Completed then
            return
        end
        operation.Completed = true
        RemoveOutstandingTimeouts()

        local pendingSourceIds = SortedKeys(operation.PendingSourceIds)
        local result = {
            success = false,
            rootId = operation.RootCopyId,
            spawnedIds = CopyArray(operation.SpawnedIds),
            failedSourceId = failedSourceId,
            pendingSourceIds = pendingSourceIds,
            reason = reason,
        }
        Log:PrintError("[ElementCopy] 复制失败，保留已生成部分", debugName,
            "failedSourceId:", tostring(failedSourceId),
            "reason:", tostring(reason),
            "spawnedIds:", FormatIds(result.spawnedIds),
            "pendingSourceIds:", FormatIds(result.pendingSourceIds))
        SafeComplete(debugName, onComplete, result)
    end

    local function MoveRootAfterDelay()
        if operation.Completed then
            return
        end
        local moveOk, moveError = xpcall(function()
            Element:SetPosition(
                operation.RootCopyId,
                targetPos,
                Element.COORDINATE.World
            )
        end, Traceback)
        if not moveOk then
            FinishFailure(sourceRootId, "move_root_failed: " .. tostring(moveError))
            return
        end

        local settleOk, settleTimerOrError = xpcall(function()
            return self._timers:AddFrame(
                operation.Owner,
                ROOT_MOVE_SETTLE_FRAMES,
                function()
                    if operation.Completed then
                        return
                    end
                    operation.Completed = true
                    local actualPosition = Element:GetPosition(operation.RootCopyId)
                    local result = {
                        success = true,
                        rootId = operation.RootCopyId,
                        spawnedIds = CopyArray(operation.SpawnedIds),
                        failedSourceId = nil,
                        pendingSourceIds = {},
                        reason = nil,
                    }
                    SafeComplete(debugName, onComplete, result)
                end
            )
        end, Traceback)
        if not settleOk then
            FinishFailure(
                sourceRootId,
                "move_settle_timer_failed: " .. tostring(settleTimerOrError)
            )
        end
    end

    local function FinishSuccessAfterDelay()
        local timerOk, timerOrError = xpcall(function()
            return self._timers:AddTimer(operation.Owner, ROOT_MOVE_DELAY_SECONDS, function()
                if operation.Completed then
                    return
                end
                local frameOk, frameTimerOrError = xpcall(function()
                    return self._timers:AddFrame(
                        operation.Owner,
                        ROOT_MOVE_DELAY_FRAMES,
                        MoveRootAfterDelay
                    )
                end, Traceback)
                if not frameOk then
                    FinishFailure(
                        sourceRootId,
                        "move_frame_delay_failed: " .. tostring(frameTimerOrError)
                    )
                end
            end)
        end, Traceback)
        if not timerOk then
            FinishFailure(sourceRootId, "move_timer_failed: " .. tostring(timerOrError))
        end
    end

    local SpawnNode
    SpawnNode = function(sourceId, parentCopyId)
        if operation.Completed then
            return
        end

        local node = nodes[sourceId]
        operation.PendingSourceIds[sourceId] = true

        local timeoutOk, timeoutOrError = xpcall(function()
            return self._timers:AddTimer(operation.Owner, NODE_TIMEOUT_SECONDS, function()
                operation.TimeoutIds[sourceId] = nil
                if operation.Completed or not operation.PendingSourceIds[sourceId] then
                    return
                end
                FinishFailure(sourceId, "spawn_timeout_3s")
            end)
        end, Traceback)
        if not timeoutOk then
            operation.PendingSourceIds[sourceId] = nil
            FinishFailure(sourceId, "timeout_timer_failed: " .. tostring(timeoutOrError))
            return
        end
        operation.TimeoutIds[sourceId] = timeoutOrError

        local spawnOk, spawnError = xpcall(function()
            Element:SpawnElement(Element.SPAWN_SOURCE.Scene, sourceId, function(copyId)
                local callbackOk, callbackError = xpcall(function()
                    if operation.Completed then
                        Log:PrintWarning("[ElementCopy] 操作结束后收到回调，仅记录迟到实例", debugName,
                            "sourceId:", sourceId, "copyId:", tostring(copyId))
                        return
                    end

                    local timeoutId = operation.TimeoutIds[sourceId]
                    operation.TimeoutIds[sourceId] = nil
                    if timeoutId then
                        self._timers:Remove(timeoutId)
                    end
                    operation.PendingSourceIds[sourceId] = nil

                    if not copyId then
                        FinishFailure(sourceId, "spawn_callback_empty_id")
                        return
                    end

                    operation.SourceToCopy[sourceId] = copyId
                    operation.SpawnedIds[#operation.SpawnedIds + 1] = copyId
                    if sourceId == sourceRootId then
                        operation.RootCopyId = copyId
                    end
                    if parentCopyId then
                        Element:BindingToElement(copyId, parentCopyId)
                    end

                    operation.RemainingCount = operation.RemainingCount - 1
                    for _, childSourceId in ipairs(node.ChildIds) do
                        SpawnNode(childSourceId, copyId)
                    end
                    if operation.RemainingCount == 0 then
                        FinishSuccessAfterDelay()
                    end
                end, Traceback)

                if not callbackOk and not operation.Completed then
                    FinishFailure(sourceId, "spawn_callback_error: " .. tostring(callbackError))
                end
            end, node.Position, node.Rotation, node.Scale, self._replicate)
        end, Traceback)

        if not spawnOk and not operation.Completed then
            local timeoutId = operation.TimeoutIds[sourceId]
            operation.TimeoutIds[sourceId] = nil
            if timeoutId then
                self._timers:Remove(timeoutId)
            end
            operation.PendingSourceIds[sourceId] = nil
            FinishFailure(sourceId, "spawn_call_error: " .. tostring(spawnError))
        end
    end

    SpawnNode(sourceRootId, nil)
end


local function DestroyOne(elementId, visited)
    if visited[elementId] then
        Log:PrintWarning("[ElementCopy] 销毁时发现重复/循环节点", elementId)
        return
    end
    visited[elementId] = true

    local childIds = Element:GetChildElementsFromElement(elementId) or {}
    for _, childId in ipairs(childIds) do
        DestroyOne(childId, visited)
    end
    Element:Destroy(elementId)
end


---按最深子节点到根节点的顺序销毁当前附加树。
function ElementCopy:DestroyTree(rootId)
    if type(rootId) ~= "number" then
        Log:PrintError("[ElementCopy] DestroyTree rootId 必须是 number", tostring(rootId))
        return false
    end
    DestroyOne(rootId, {})
    return true
end

return ElementCopy
