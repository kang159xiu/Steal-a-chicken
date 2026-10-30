-- 公共入参校验；各模块不再各留一份相同副本。
local Validation = {}

function Validation.IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

return Validation
