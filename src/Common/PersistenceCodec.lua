-- 版本化紧凑JSON。大数使用字符串；个体缩放使用整数档；只接受安全整数number。
local Codec = {}
local function Validate(value, depth, seen)
    assert(depth <= 32, "snapshot nesting limit")
    local t = type(value)
    if t == "string" or t == "boolean" then return end
    if t == "number" then
        assert(value >= 0 and value <= 9007199254740991 and value == math.floor(value), "unsafe snapshot number")
        return
    end
    assert(t == "table" and not seen[value] and getmetatable(value) == nil, "unsupported snapshot value")
    seen[value] = true
    local count, array = 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key > #value or key ~= math.floor(key) then array = false end
    end
    if array then assert(count == #value, "sparse snapshot array")
    else for key in pairs(value) do assert(type(key) == "string", "mixed snapshot keys") end end
    for _, v in pairs(value) do Validate(v, depth + 1, seen) end
    seen[value] = nil
end
local function ASCII(json)
    return (json:gsub("[\128-\255][\128-\191]*", function(bytes)
        local b1, b2, b3, b4 = bytes:byte(1, 4)
        local code
        if #bytes == 2 and b1 >= 194 and b1 <= 223 then code = (b1 - 192) * 64 + b2 - 128
        elseif #bytes == 3 and b1 >= 224 and b1 <= 239 then code = (b1 - 224) * 4096 + (b2 - 128) * 64 + b3 - 128
        elseif #bytes == 4 and b1 >= 240 and b1 <= 244 then code = (b1 - 240) * 262144 + (b2 - 128) * 4096 + (b3 - 128) * 64 + b4 - 128 end
        assert(code and code <= 1114111 and not (code >= 55296 and code <= 57343)
            and (#bytes ~= 3 or code >= 2048) and (#bytes ~= 4 or code >= 65536), "invalid UTF8")
        if code <= 65535 then return string.format("\\u%04X", code) end
        code = code - 65536
        return string.format("\\u%04X\\u%04X", 55296 + math.floor(code / 1024), 56320 + code % 1024)
    end))
end
function Codec.Encode(snapshot)
    local ok, result = pcall(function()
        assert(type(snapshot) == "table" and snapshot.version == 1, "snapshot_version_invalid")
        Validate(snapshot, 0, {})
        local json = MiscService:Table2JsonStr(snapshot)
        assert(type(json) == "string" and #json > 0, "json_encode_failed")
        json = ASCII(json)
        assert(not json:find("[^\032-\126]"), "json_not_ascii")
        return json
    end)
    if not ok then return nil, tostring(result) end
    return result
end
function Codec.Decode(text)
    if type(text) ~= "string" or text:find("[^\032-\126]") then return nil, "invalid_snapshot_ascii" end
    local ok, result = pcall(function()
        local snapshot = MiscService:JsonStr2Table(text)
        assert(type(snapshot) == "table" and snapshot.version == 1, "snapshot_version_invalid")
        Validate(snapshot, 0, {})
        return snapshot
    end)
    if not ok then return nil, tostring(result) end
    return result
end
-- 差错校验，不是加密认证；业务模块另行校验快照字段。
function Codec.Checksum(s)
    local a, b = 1, 0
    for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
    return string.format("%08X", b * 65536 + a)
end
return Codec
