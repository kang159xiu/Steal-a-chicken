local EventBus = {}
EventBus.__index = EventBus

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

function EventBus.New(onOwnerError)
    return setmetatable({
        _onOwnerError = onOwnerError,
        _nextToken = 0,
        _entries = {},
        _eventTokens = {},
        _ownerTokens = {},
    }, EventBus)
end


function EventBus:Subscribe(owner, eventName, callback)
    assert(type(owner) == "string" and owner ~= "", "EventBus owner 必须是非空字符串")
    assert(type(eventName) == "string" and eventName ~= "", "EventBus eventName 必须是非空字符串")
    assert(type(callback) == "function", "EventBus callback 必须是 function")

    self._nextToken = self._nextToken + 1
    local token = self._nextToken
    self._entries[token] = {
        Owner = owner,
        EventName = eventName,
        Callback = callback,
    }

    self._eventTokens[eventName] = self._eventTokens[eventName] or {}
    self._eventTokens[eventName][#self._eventTokens[eventName] + 1] = token
    self._ownerTokens[owner] = self._ownerTokens[owner] or {}
    self._ownerTokens[owner][token] = true
    return token
end


function EventBus:Unsubscribe(token)
    local entry = self._entries[token]
    if not entry then
        return false
    end

    self._entries[token] = nil
    local eventTokens = self._eventTokens[entry.EventName]
    if eventTokens then
        for index = #eventTokens, 1, -1 do
            if eventTokens[index] == token then
                table.remove(eventTokens, index)
                break
            end
        end
        if #eventTokens == 0 then
            self._eventTokens[entry.EventName] = nil
        end
    end
    local ownerTokens = self._ownerTokens[entry.Owner]
    if ownerTokens then
        ownerTokens[token] = nil
        if next(ownerTokens) == nil then
            self._ownerTokens[entry.Owner] = nil
        end
    end
    return true
end


function EventBus:UnsubscribeOwner(owner)
    local ownerTokens = self._ownerTokens[owner]
    if not ownerTokens then
        return
    end

    local tokens = {}
    for token in pairs(ownerTokens) do
        tokens[#tokens + 1] = token
    end
    for _, token in ipairs(tokens) do
        self:Unsubscribe(token)
    end
end


function EventBus:Publish(eventName, ...)
    local sourceTokens = self._eventTokens[eventName]
    if not sourceTokens then
        return
    end

    -- 使用快照，允许回调在发布过程中安全取消订阅。
    local tokens = {}
    for _, token in ipairs(sourceTokens) do
        if self._entries[token] then
            tokens[#tokens + 1] = token
        end
    end

    local args = { n = select("#", ...), ... }
    local unpackArgs = table.unpack or unpack
    for _, token in ipairs(tokens) do
        local entry = self._entries[token]
        if entry then
            local ok, errorMessage = xpcall(function()
                entry.Callback(unpackArgs(args, 1, args.n))
            end, Traceback)
            if not ok then
                if self._onOwnerError then
                    self._onOwnerError(entry.Owner, errorMessage)
                else
                    Log:PrintError("[EventBus] 回调错误", entry.Owner, eventName, errorMessage)
                end
            end
        end
    end
end


function EventBus:Clear()
    self._entries = {}
    self._eventTokens = {}
    self._ownerTokens = {}
end

return EventBus
