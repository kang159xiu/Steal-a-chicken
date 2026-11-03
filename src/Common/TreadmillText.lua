local Decimal = require "Common.DecimalInteger"
local TreadmillText = {}

function TreadmillText.FormatExperience(current, nextAmount)
    local text = "+" .. Decimal.Format(current) .. "/次"
    if nextAmount then text = text .. "->+" .. Decimal.Format(nextAmount) .. "/次" end
    return text
end

return TreadmillText
