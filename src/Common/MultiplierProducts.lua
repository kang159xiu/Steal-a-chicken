local GameConfig = require "Common.Config.GameConfig"
local MultiplierProducts = {}

function MultiplierProducts.Next(kind, current)
    local previous = 1
    for _, row in ipairs(GameConfig.MultiplierPurchase[kind].Products) do
        if current == previous then return row end
        previous = row.Multiplier
    end
end

function MultiplierProducts.IsCurrent(kind, value)
    if value == 1 then return true end
    for _, row in ipairs(GameConfig.MultiplierPurchase[kind].Products) do
        if value == row.Multiplier then return true end
    end
    return false
end

return MultiplierProducts
