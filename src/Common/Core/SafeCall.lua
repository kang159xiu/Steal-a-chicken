-- 异常兜底公共实现；各模块不再各留一份相同副本。
local SafeCall = {}

function SafeCall.Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

---回调保护：模块失活后丢弃，异常统一交给模块管理器。
function SafeCall.Protect(active, onError, callback)
    local unpackArgs = table.unpack or unpack
    return function(...)
        if not active() then return end
        local args = { n = select("#", ...), ... }
        local ok, err = pcall(function() callback(unpackArgs(args, 1, args.n)) end)
        if not ok then onError(err) end
    end
end

return SafeCall
