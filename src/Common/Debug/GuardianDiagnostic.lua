-- 临时只读诊断；任何查询、日志或通知异常均不得影响业务。
local Diagnostic = {}
function Diagnostic.Safe(callback)
    local ok, err = pcall(callback)
    if not ok then pcall(function() Log:PrintError("[GuardianDiag] diagnostic_error", tostring(err)) end) end
end
function Diagnostic.Time()
    local ok, value = pcall(function() return MiscService:GetServerTimestamp() end)
    return ok and tostring(value) or "unavailable"
end
function Diagnostic.Sample(side, message)
    local function Write(...)
        local args = { ... }
        Diagnostic.Safe(function()
            local fields = { "[GuardianDiag/" .. side .. "]", "region:", tostring(message.regionId),
                "sequence:", tostring(message.sequence), "generation:", tostring(message.generation),
                "phase:", tostring(message.phase), "guardian:", tostring(message.guardianId),
                "target:", tostring(message.targetId), "sentTime:", tostring(message.sentTime),
                "sampleTime:", Diagnostic.Time() }
            if side == "Client" then
                fields[#fields + 1] = "localPlayerId:"
                fields[#fields + 1] = tostring(Character:GetLocalPlayerId())
                fields[#fields + 1] = "receivedTime:"
                fields[#fields + 1] = tostring(message.receivedTime)
            end
            for _, value in ipairs(args) do fields[#fields + 1] = tostring(value) end
            if side == "Server" then Log:PrintServerLog(table.concat(fields, " "))
            else Log:PrintLog(table.concat(fields, " ")) end
        end)
    end
    local function Read(id, label, callback, vector)
        local ok, value = pcall(callback)
        if ok and vector and value ~= nil then
            ok, value = pcall(function() return tostring(value.X) .. "," .. tostring(value.Y) .. "," .. tostring(value.Z) end)
        end
        Write("element:", tostring(id), "field:", label, "ok:", tostring(ok), "value:", tostring(value))
    end
    Read(message.targetId, "targetPosition", function() return Element:GetPosition(message.targetId) end, true)
    local visited = {}
    local function Visit(id, parent)
        if visited[id] then Write("tree_cycle_or_duplicate:", tostring(id)); return end
        visited[id] = true
        Write("element:", tostring(id), "parentInTree:", tostring(parent))
        Read(id, "position", function() return Element:GetPosition(id) end, true)
        Read(id, "scale", function() return Element:GetScale(id) end, true)
        Read(id, "visible", function() return Element:IsVisible(id) end, false)
        local ok, children = pcall(function() return Element:GetChildElementsFromElement(id) end)
        if not ok or type(children) ~= "table" then
            Write("element:", tostring(id), "childrenReadOk:", tostring(ok), "childrenValue:", tostring(children)); return
        end
        for _, child in ipairs(children) do Visit(child, id) end
    end
    Visit(message.guardianId, nil)
end
return Diagnostic
