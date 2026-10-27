local Decimal = require "Common.DecimalInteger"
local EggModelText = {}

function EggModelText.FormatPrice(value)
    local text = Decimal.Format(assert(Decimal.FromSafeInteger(value), "invalid egg model price"))
    -- 只去小数部分末尾的零，不改变单位及公共格式化规则。
    text = text:gsub("%.(%d+)", function(fraction)
        fraction = fraction:gsub("0+$", "")
        return fraction == "" and "" or "." .. fraction
    end)
    return "~" .. text .. "$"
end

return EggModelText
