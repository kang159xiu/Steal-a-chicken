local TimerRegistry = {}
TimerRegistry.__index = TimerRegistry

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

function TimerRegistry.New(onOwnerError)
    return setmetatable({
        _onOwnerError = onOwnerError,
        _timers = {},
        _ownerTimers = {},
    }, TimerRegistry)
end


function TimerRegistry:_Track(timerId, owner, isLoop)
    assert(timerId ~= nil, "TimerManager 没有返回 timerId")
    self._timers[timerId] = {
        Owner = owner,
        IsLoop = isLoop,
    }
    self._ownerTimers[owner] = self._ownerTimers[owner] or {}
    self._ownerTimers[owner][timerId] = true
end


function TimerRegistry:_Untrack(timerId)
    local record = self._timers[timerId]
    if not record then
        return nil
    end
    self._timers[timerId] = nil
    local ownerTimers = self._ownerTimers[record.Owner]
    if ownerTimers then
        ownerTimers[timerId] = nil
        if next(ownerTimers) == nil then
            self._ownerTimers[record.Owner] = nil
        end
    end
    return record
end


function TimerRegistry:_Add(methodName, owner, delay, callback, isLoop, ...)
    assert(type(owner) == "string" and owner ~= "", "TimerRegistry owner 必须是非空字符串")
    assert(type(delay) == "number" and delay >= 0, "TimerRegistry delay 必须是非负数")
    assert(type(callback) == "function", "TimerRegistry callback 必须是 function")

    local args = { n = select("#", ...), ... }
    local unpackArgs = table.unpack or unpack
    local timerId
    local function WrappedCallback()
        local record = timerId and self._timers[timerId] or nil
        if not record then
            return
        end
        if not record.IsLoop then
            self:_Untrack(timerId)
        end

        local ok, errorMessage = xpcall(function()
            callback(unpackArgs(args, 1, args.n))
        end, Traceback)
        if not ok then
            if record.IsLoop then
                self:Remove(timerId)
            end
            if self._onOwnerError then
                self._onOwnerError(owner, errorMessage)
            else
                Log:PrintError("[TimerRegistry] 定时器回调错误", owner, errorMessage)
            end
        end
    end

    timerId = TimerManager[methodName](TimerManager, delay, WrappedCallback)
    self:_Track(timerId, owner, isLoop)
    return timerId
end


function TimerRegistry:AddTimer(owner, delay, callback, ...)
    return self:_Add("AddTimer", owner, delay, callback, false, ...)
end


function TimerRegistry:AddLoopTimer(owner, delay, callback, ...)
    return self:_Add("AddLoopTimer", owner, delay, callback, true, ...)
end


function TimerRegistry:AddFrame(owner, delay, callback, ...)
    return self:_Add("AddFrame", owner, delay, callback, false, ...)
end


function TimerRegistry:AddLoopFrame(owner, delay, callback, ...)
    return self:_Add("AddLoopFrame", owner, delay, callback, true, ...)
end


function TimerRegistry:Remove(timerId)
    local record = self:_Untrack(timerId)
    if not record then
        return false
    end
    TimerManager:RemoveTimer(timerId)
    return true
end


function TimerRegistry:RemoveOwner(owner)
    local ownerTimers = self._ownerTimers[owner]
    if not ownerTimers then
        return
    end

    local timerIds = {}
    for timerId in pairs(ownerTimers) do
        timerIds[#timerIds + 1] = timerId
    end
    for _, timerId in ipairs(timerIds) do
        self:Remove(timerId)
    end
end


function TimerRegistry:Clear()
    local timerIds = {}
    for timerId in pairs(self._timers) do
        timerIds[#timerIds + 1] = timerId
    end
    for _, timerId in ipairs(timerIds) do
        self:Remove(timerId)
    end
end

return TimerRegistry
