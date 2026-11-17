-- 仅采样，不参与模型就绪／成功判断；三端使用同一份副本节点ID。
local Diag = {}

function Diag.Sample(side, entry, stage)
    pcall(function()
        local function Read(getter)
            local ok, value = pcall(getter)
            local converted, text = pcall(tostring, value)
            if not converted then return "conversion_failed" end
            return ok and text or "read_failed:" .. text
        end
        local function Vector(value)
            return "X:" .. tostring(value.X) .. ",Y:" .. tostring(value.Y) .. ",Z:" .. tostring(value.Z)
        end
        local function Ids(values)
            local ids = {}
            for _, id in ipairs(values or {}) do ids[#ids + 1] = tostring(id) end
            return "[" .. table.concat(ids, ",") .. "]"
        end
        local identity = "side=" .. side
            .. " localPlayerId=" .. Read(function() return side == "Client" and Character:GetLocalPlayerId() or nil end)
            .. " ownerPlayerId=" .. tostring(entry.playerId) .. " homeId=" .. tostring(entry.homeId)
            .. " level=" .. tostring(entry.level) .. " version=" .. tostring(entry.version)
            .. " operation=" .. tostring(entry.operation) .. " session=" .. tostring(entry.sessionGeneration)
            .. " rootId=" .. tostring(entry.rootId) .. " templateId=" .. tostring(entry.templateId)
            .. " timestampMs=" .. Read(function() return MiscService:GetServerTimestamp() end)
        local function Print(kind, text)
            pcall(function()
                if side == "Server" then Log:PrintServerLog("[TreadmillReplicaDiag]", stage, kind, identity, text)
                else Log:PrintLog("[TreadmillReplicaDiag]", stage, kind, identity, text) end
            end)
        end
        Print("manifest", "positionId=" .. tostring(entry.positionId)
            .. " nodeIds=" .. Read(function() return Ids(entry.nodeIds) end))
        local function Node(kind, id)
            local fields = { "nodeId=" .. tostring(id) }
            for _, field in ipairs({
                { "position", function() return Vector(Element:GetPosition(id)) end },
                { "rotation", function() return Vector(Element:GetRotation(id)) end },
                { "scale", function() return Vector(Element:GetScale(id)) end },
                { "parent", function() return Element:GetAttachParentElement(id) end },
                { "visible", function() return Element:IsVisible(id) end },
                { "children", function() return Ids(Element:GetChildElementsFromElement(id)) end },
            }) do fields[#fields + 1] = field[1] .. "=" .. Read(field[2]) end
            Print(kind, table.concat(fields, " | "))
        end
        Node("position_marker", entry.positionId)
        for _, id in ipairs(entry.nodeIds) do Node(id == entry.rootId and "root" or "child", id) end
    end)
end

return Diag
