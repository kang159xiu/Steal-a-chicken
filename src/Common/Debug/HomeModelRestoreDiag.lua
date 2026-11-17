-- 仅观察现有恢复／通知路径，字段读取与打印失败均不参与业务结果。
local Diag = {}
function Diag.Log(side, module, stage, fields)
    pcall(function()
        if type(fields) == "function" then fields = fields() end
        local parts = { "side=" .. side, "module=" .. module, "stage=" .. stage }
        if side == "Client" then
            local ok, id = pcall(function() return Character:GetLocalPlayerId() end)
            parts[#parts + 1] = "localPlayerId=" .. (ok and tostring(id) or "unavailable")
        end
        for key, value in pairs(fields or {}) do parts[#parts + 1] = tostring(key) .. "=" .. tostring(value) end
        if side == "Server" then Log:PrintServerLog("[HomeModelRestoreDiag]", table.concat(parts, " "))
        else Log:PrintLog("[HomeModelRestoreDiag]", table.concat(parts, " ")) end
    end)
end
function Diag.Sample(side, module, stage, fields)
    pcall(function()
        if type(fields) == "function" then fields = fields() end
        local id = fields.rootId
        local function Read(callback)
            local ok, value = pcall(callback)
            return ok and tostring(value) or "read_failed:" .. tostring(value)
        end
        local function Vector(v) return tostring(v.X) .. "," .. tostring(v.Y) .. "," .. tostring(v.Z) end
        fields.position = Read(function() return Vector(Element:GetPosition(id)) end)
        fields.rotation = Read(function() return Vector(Element:GetRotation(id)) end)
        fields.visible = Read(function() return Element:IsVisible(id) end)
        fields.children = Read(function()
            local ids = {}; for _, child in ipairs(Element:GetChildElementsFromElement(id) or {}) do ids[#ids + 1] = tostring(child) end
            return "[" .. table.concat(ids, ",") .. "]"
        end)
        Diag.Log(side, module, stage, fields)
    end)
end
return Diag
