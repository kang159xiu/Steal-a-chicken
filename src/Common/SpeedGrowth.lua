local Decimal = require "Common.DecimalInteger"
local Config = require "Common.Config.GameConfig"
local SpeedGrowth = {}

-- 每级独立向上取整：逐位乘112后精确除100，不将完整经验转成浮点。
local function NextRequirement(value)
    local digits, carry = {}, 0
    for i = #value, 1, -1 do
        local product = (value:byte(i) - 48) * Config.PlayerSpeed.ExperienceGrowthPercent + carry
        digits[#digits + 1] = string.char(48 + product % 10)
        carry = math.floor(product / 10)
    end
    while carry > 0 do
        digits[#digits + 1] = string.char(48 + carry % 10)
        carry = math.floor(carry / 10)
    end
    local product = table.concat(digits):reverse()
    local quotient = product:sub(1, -3)
    if product:sub(-2) ~= "00" then quotient = Decimal.Add(quotient, "1") end
    return quotient
end

function SpeedGrowth.Advance(level, remaining, requirement)
    while Decimal.Compare(remaining, requirement) >= 0 do
        remaining = Decimal.Subtract(remaining, requirement)
        level = level + 1
        requirement = NextRequirement(requirement)
    end
    return level, remaining, requirement
end

return SpeedGrowth
