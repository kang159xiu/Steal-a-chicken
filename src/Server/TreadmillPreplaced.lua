local Config = require "Common.Config.TreadmillPreplaced"
local GameConfig = require "Common.Config.GameConfig"
local Pool = {}
Pool.__index = Pool

function Pool.new()
    local self = setmetatable({ Entries = {}, HomeIndexes = {} }, Pool)
    local templates = {}
    for level, row in ipairs(GameConfig.TreadmillLevels) do templates[row.TemplateRootId] = level end
    for index, homeId in ipairs(GameConfig.Home.RootElementIds) do self.HomeIndexes[homeId] = index end
    assert(#Config.Levels == GameConfig.Treadmill.MaxLevel, "跑步机预放配置必须包含全部等级")
    for level = 1, GameConfig.Treadmill.MaxLevel do
        local roots = Config.Levels[level]
        assert(type(roots) == "table" and #roots == #GameConfig.Home.RootElementIds, "跑步机每级必须配置6个预放父元件ID")
        for homeIndex, root in ipairs(roots) do
            assert(type(root) == "number" and root > 0 and root <= 9007199254740991 and root == math.floor(root),
                "跑步机预放ID未填齐或无效，等级=" .. level)
            local ownTemplate = homeIndex == 1 and templates[root] == level
            assert(not self.Entries[root] and (not templates[root] or ownTemplate) and not self.HomeIndexes[root],
                "跑步机预放ID重复或与原模板/家园重合: " .. tostring(root))
            self.Entries[root] = {}
        end
    end
    return self
end
-- 只读一轮配置中的父级；每个字段及打印独立保护，不据读取成功认定实际外观完整。
function Pool.Diagnose()
    local total, readable, failed = 0, 0, 0
    local function Print(...)
        local args = { ... }
        pcall(function() Log:PrintServerLog("[TreadmillPreplacedDiag]", unpack(args)) end)
    end
    local function Vector(value)
        assert(value ~= nil, "nil_vector")
        for _, axis in ipairs({ "X", "Y", "Z" }) do
            local n = value[axis]
            assert(type(n) == "number" and n == n and math.abs(n) < math.huge, "invalid_vector_" .. axis)
        end
        return tostring(value.X) .. "," .. tostring(value.Y) .. "," .. tostring(value.Z)
    end
    local function Read(getter, format)
        local ok, value = pcall(function() return format(getter()) end)
        return ok, tostring(value)
    end
    local function Children(ids)
        assert(type(ids) == "table", "children_not_table")
        local values = {}
        for _, id in ipairs(ids) do values[#values + 1] = tostring(id) end
        return "[" .. table.concat(values, ",") .. "]"
    end
    for level, roots in ipairs(Config.Levels) do
        for index, root in ipairs(roots) do
            total = total + 1
            local posOK, position = Read(function() return Element:GetPosition(root) end, Vector)
            local rotOK, rotation = Read(function() return Element:GetRotation(root) end, Vector)
            local childrenOK, children = Read(function() return Element:GetChildElementsFromElement(root) end, Children)
            local allOK = posOK and rotOK and childrenOK
            if allOK then readable = readable + 1 else failed = failed + 1 end
            Print("stage=read", "level=" .. level, "homeIndex=" .. index,
                "homeId=" .. tostring(GameConfig.Home.RootElementIds[index]), "rootId=" .. tostring(root),
                "readable=" .. tostring(allOK), "positionOK=" .. tostring(posOK), "position=" .. position,
                "rotationOK=" .. tostring(rotOK), "rotation=" .. rotation,
                "childrenOK=" .. tostring(childrenOK), "children=" .. children)
        end
    end
    Print("stage=summary", "total=" .. total, "readable=" .. readable, "failed=" .. failed)
end
function Pool:Park(root)
    Element:UnBinding(root)
    Element:SetPosition(root, Engine.Vector(0, 0, -5000), Element.COORDINATE.World)
end
function Pool:Initialize()
    if self.Initialized then return end
    for root in pairs(self.Entries) do self:Park(root) end
    self.Initialized = true
end
function Pool:Acquire(level, homeId, operation, currentRoot)
    self:Initialize()
    local index = assert(self.HomeIndexes[homeId], "跑步机预放家园未配置")
    local root = Config.Levels[level][index]
    local entry = self.Entries[root]
    if entry.lease and root ~= currentRoot then return nil, "preplaced_instance_busy" end
    -- 同级重生借用正在显示的1级实例；取消准备不能回收这台当前模型。
    local reused = entry.lease ~= nil
    local nodeIds, seen = {}, {}
    local function Visit(id)
        assert(not seen[id], "跑步机预放子级重复或循环: " .. tostring(id))
        seen[id] = true
        assert(id == root or not self.Entries[id], "跑步机预放根不能互相附加")
        nodeIds[#nodeIds + 1] = id
        for _, child in ipairs(Element:GetChildElementsFromElement(id) or {}) do Visit(child) end
    end
    Visit(root)
    if not reused then entry.lease = operation end
    return { success = true, rootId = root, spawnedIds = nodeIds,
        modelLease = entry.lease, reusesCurrent = reused }
end
function Pool:Release(root, lease)
    local entry = self.Entries[root]
    if not entry or entry.lease ~= lease then return false end
    self:Park(root)
    entry.lease = nil
    return true
end
return Pool
