local Config = require "Common.Config.TheftDisplayPool"
local GameConfig = require "Common.Config.GameConfig"
local Pool = {}
Pool.__index = Pool

function Pool.new(context)
    return setmetatable({ Context = context, Entries = {}, Free = { Chicken = {}, Egg = {} }, Active = true }, Pool)
end

function Pool:Park(rootId)
    Element:UnBinding(rootId)
    Element:SetPosition(rootId, Engine.Vector(0, 0, -5000), Element.COORDINATE.World)
end

function Pool:Register(kind, typeId, rootId, authored, spawnedIds)
    local entry = { kind = kind, typeId = typeId, rootId = rootId, authored = authored,
        rotation = Element:GetRotation(rootId), spawnedIds = spawnedIds or { rootId }, operation = 0, lease = 0 }
    self.Entries[rootId] = entry
    self.Free[kind][typeId] = self.Free[kind][typeId] or {}
    return entry
end

function Pool:Initialize()
    if self.Initialized then return end
    -- 配置边界一次核对：池实例不得与其他条目或源模板共用根。
    local templates, seen = {}, {}
    for _, chicken in pairs(GameConfig.ChickenTypes) do
        templates[chicken.TemplateRootId] = true
        templates[chicken.Egg.TemplateRootId] = true
    end
    for _, group in ipairs({ { "Chicken", Config.Chickens }, { "Egg", Config.Eggs } }) do
        for typeId, roots in pairs(group[2]) do
            for _, rootId in ipairs(roots) do
                assert(not seen[rootId] and not templates[rootId], "展示池ID重复或与源模板重合: " .. tostring(rootId))
                seen[rootId] = true
            end
        end
    end
    for _, group in ipairs({ { "Chicken", Config.Chickens }, { "Egg", Config.Eggs } }) do
        for typeId, roots in pairs(group[2]) do
            for _, rootId in ipairs(roots) do
                self:Register(group[1], typeId, rootId, true)
                self:Release(rootId)
            end
        end
    end
    self.Initialized = true
end

function Pool:Has(rootId)
    return self.Entries[rootId] ~= nil
end

function Pool:Release(rootId, lease, operation)
    local entry = self.Entries[rootId]
    if not entry then return false end
    if not self.Active then return true end -- 停止已统一处理；迟到结果不能再销毁预放根。
    if lease and lease ~= entry.lease then return true end -- 旧复制结果不回收新借用。
    if entry.free then return true end
    if operation then entry.operation = math.max(entry.operation, operation) end
    self:Park(rootId)
    entry.free = true
    local free = self.Free[entry.kind][entry.typeId]
    free[#free + 1] = rootId
    return true
end

function Pool:DestroyResult(result)
    -- CopyTree失败时可能留下尚未附加的节点，逆序按已返回ID清理。
    for index = #(result.spawnedIds or {}), 1, -1 do Element:Destroy(result.spawnedIds[index]) end
end

function Pool:Acquire(kind, typeId, templateId, position, debugName, callback)
    self:Initialize()
    local free = self.Free[kind][typeId]
    local rootId = free and table.remove(free)
    if rootId then
        local entry = self.Entries[rootId]
        entry.free = false
        entry.lease = entry.lease + 1
        entry.operation = entry.operation + 1
        local ok, reason = pcall(function()
            Element:SetRotation(rootId, entry.rotation, Element.COORDINATE.World)
            Element:SetPosition(rootId, position, Element.COORDINATE.World)
        end)
        callback({ success = ok, reason = not ok and tostring(reason) or nil,
            rootId = rootId, spawnedIds = entry.spawnedIds,
            poolLease = entry.lease, poolOperation = entry.operation })
        return
    end
    self.Context.ElementCopy:CopyTree(templateId, position, debugName, function(result)
        if not self.Active then
            self:DestroyResult(result)
            callback({ success = false, reason = "display_pool_stopped", spawnedIds = {} })
            return
        end
        if result.success then
            local entry = self:Register(kind, typeId, result.rootId, false, result.spawnedIds)
            entry.lease, entry.operation = 1, 1
            result.poolLease, result.poolOperation = entry.lease, entry.operation
        end
        callback(result)
    end)
end

function Pool:TransferChicken(rootId, typeId)
    local entry = self.Entries[rootId]
    if not entry then return end -- 掉落后再次拾取不重复补池。
    self.Entries[rootId] = nil -- 原件所有权交给既有携带／掉落／入库流程。
    local templateId = GameConfig.ChickenTypes[typeId].TemplateRootId
    local ok, reason = pcall(function()
        self.Context.ElementCopy:CopyTree(templateId, Engine.Vector(0, 0, -5000), "偷取区展示池补鸡", function(result)
            if not self.Active or not result.success then
                self:DestroyResult(result)
                if self.Active then Log:PrintError("[TheftDisplayPool] 拾取后补池失败，不影响拾取", typeId, tostring(result.reason)) end
                return
            end
            self:Register("Chicken", typeId, result.rootId, false, result.spawnedIds)
            self:Release(result.rootId)
        end)
    end)
    if not ok then Log:PrintError("[TheftDisplayPool] 拾取后补池调用失败，不影响拾取", typeId, tostring(reason)) end
end

function Pool:Stop()
    self.Active = false
    for rootId, entry in pairs(self.Entries) do
        if entry.authored then self:Park(rootId)
        else self.Context.ElementCopy:DestroyTree(rootId) end
    end
    -- 保留已处理根的身份至在途回调释放本对象，避免迟到清理再次销毁预放实例。
    self.Free = { Chicken = {}, Egg = {} }
end

return Pool
