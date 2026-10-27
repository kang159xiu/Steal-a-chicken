-- 无前导零的非负十进制整数。高额值始终按字符运算，不转number。
local Decimal = {}
function Decimal.IsValid(value)
    return type(value) == "string" and (value == "0" or value:match("^[1-9][0-9]*$") ~= nil)
end
function Decimal.FromSafeInteger(value)
    if type(value) ~= "number" or value < 0 or value > 9007199254740991
        or value ~= math.floor(value) then return nil end
    return string.format("%.0f", value)
end
function Decimal.Compare(a, b)
    assert(Decimal.IsValid(a) and Decimal.IsValid(b), "invalid decimal integer")
    if #a ~= #b then return #a < #b and -1 or 1 end
    if a == b then return 0 end
    return a < b and -1 or 1
end
function Decimal.Add(a, b)
    assert(Decimal.IsValid(a) and Decimal.IsValid(b), "invalid decimal integer")
    local result, carry, i, j = {}, 0, #a, #b
    while i > 0 or j > 0 or carry > 0 do
        local x = i > 0 and a:byte(i) - 48 or 0
        local y = j > 0 and b:byte(j) - 48 or 0
        local sum = x + y + carry
        result[#result + 1] = string.char(48 + sum % 10)
        carry = math.floor(sum / 10)
        i, j = i - 1, j - 1
    end
    return table.concat(result):reverse()
end
function Decimal.Subtract(a, b)
    if Decimal.Compare(a, b) < 0 then return nil, "insufficient_balance" end
    local result, borrow, j = {}, 0, #b
    for i = #a, 1, -1 do
        local digit = a:byte(i) - 48 - borrow - (j > 0 and b:byte(j) - 48 or 0)
        borrow = digit < 0 and 1 or 0
        if digit < 0 then digit = digit + 10 end
        result[#result + 1] = string.char(48 + digit)
        j = j - 1
    end
    local value = table.concat(result):reverse():gsub("^0+", "")
    return value == "" and "0" or value
end
local units = { { 21, "Sx" }, { 18, "Qi" }, { 15, "Qa" }, { 12, "T" },
    { 9, "B" }, { 6, "M" }, { 4, "w" }, { 3, "k" } }
function Decimal.Format(value)
    assert(Decimal.IsValid(value), "invalid decimal integer")
    for _, unit in ipairs(units) do
        local exponent, suffix = unit[1], unit[2]
        if #value > exponent then
            local integerLength = #value - exponent
            local cents = value:sub(1, integerLength + 2)
            local roundingDigit = value:byte(integerLength + 3)
            if roundingDigit and roundingDigit >= 53 then cents = Decimal.Add(cents, "1") end
            local fraction = cents:sub(-2)
            return cents:sub(1, -3) .. (fraction == "00" and "" or "." .. fraction) .. suffix
        end
    end
    return value
end
return Decimal
