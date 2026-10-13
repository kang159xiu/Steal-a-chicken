local ConfigValidator = {}

local function AddError(errors, message)
    errors[#errors + 1] = message
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

---校验功能开关名称和值；不补任何默认值。
function ConfigValidator.ValidateFeatureFlags(featureFlags)
    local errors = {}
    if type(featureFlags) ~= "table" then
        return false, { "FeatureFlags 必须是 table" }
    end

    local names = featureFlags.Names
    local values = featureFlags.Values
    if type(names) ~= "table" then
        AddError(errors, "FeatureFlags.Names 必须是数组")
    end
    if type(values) ~= "table" then
        AddError(errors, "FeatureFlags.Values 必须是 table")
    end
    if #errors > 0 then
        return false, errors
    end

    local knownNames = {}
    for index, name in ipairs(names) do
        if type(name) ~= "string" or name == "" then
            AddError(errors, "FeatureFlags.Names[" .. tostring(index) .. "] 必须是非空字符串")
        elseif knownNames[name] then
            AddError(errors, "功能开关名称重复: " .. name)
        else
            knownNames[name] = true
            if type(values[name]) ~= "boolean" then
                AddError(errors, "功能开关缺失或不是 boolean: " .. name)
            end
        end
    end

    for name in pairs(values) do
        if not knownNames[name] then
            AddError(errors, "发现未登记的功能开关: " .. tostring(name))
        end
    end

    if featureFlags.Scopes ~= nil then
        if type(featureFlags.Scopes) ~= "table" then
            AddError(errors, "FeatureFlags.Scopes 必须是 table 或 nil")
        else
            for name, scope in pairs(featureFlags.Scopes) do
                if not knownNames[name] then
                    AddError(errors, "功能开关端范围引用了未登记名称: " .. tostring(name))
                elseif type(scope) ~= "table" then
                    AddError(errors, "功能开关端范围必须是 table: " .. tostring(name))
                elseif scope.Server ~= true and scope.Client ~= true then
                    AddError(errors, "功能开关端范围至少启用一端: " .. tostring(name))
                elseif scope.Server ~= nil and type(scope.Server) ~= "boolean" then
                    AddError(errors, "功能开关 Server 范围必须是 boolean: " .. tostring(name))
                elseif scope.Client ~= nil and type(scope.Client) ~= "boolean" then
                    AddError(errors, "功能开关 Client 范围必须是 boolean: " .. tostring(name))
                end
            end
        end
    end

    return #errors == 0, errors
end


---创建开局快照，防止运行中修改配置影响本局模块状态。
function ConfigValidator.SnapshotFeatureFlags(featureFlags)
    local snapshot = {}
    for _, name in ipairs(featureFlags.Names or {}) do
        snapshot[name] = featureFlags.Values[name]
    end
    return snapshot
end


---校验网络消息分区及消息 ID 唯一性。
function ConfigValidator.ValidateNetMessages(netMsg)
    local errors = {}
    if type(netMsg) ~= "table" then
        return false, { "NetMsg 必须是 table" }
    end

    local ranges = netMsg.Ranges
    local messages = netMsg.Messages
    if type(ranges) ~= "table" then
        AddError(errors, "NetMsg.Ranges 必须是 table")
    end
    if type(messages) ~= "table" then
        AddError(errors, "NetMsg.Messages 必须是 table")
    end
    if #errors > 0 then
        return false, errors
    end

    local rangeList = {}
    for rangeName, range in pairs(ranges) do
        if type(range) ~= "table" or not IsPositiveInteger(range.Min) or not IsPositiveInteger(range.Max)
            or range.Min > range.Max then
            AddError(errors, "网络消息分区无效: " .. tostring(rangeName))
        else
            rangeList[#rangeList + 1] = {
                Name = rangeName,
                Min = range.Min,
                Max = range.Max,
            }
        end
    end

    table.sort(rangeList, function(a, b)
        return a.Min < b.Min
    end)
    for index = 2, #rangeList do
        local previous = rangeList[index - 1]
        local current = rangeList[index]
        if current.Min <= previous.Max then
            AddError(errors, "网络消息分区重叠: " .. previous.Name .. " 与 " .. current.Name)
        end
    end

    local usedIds = {}
    for messageName, messageId in pairs(messages) do
        if not IsPositiveInteger(messageId) then
            AddError(errors, "网络消息 ID 必须是正整数: " .. tostring(messageName))
        else
            if usedIds[messageId] then
                AddError(errors, "网络消息 ID 重复: " .. tostring(messageId) .. "（" .. usedIds[messageId]
                    .. " / " .. tostring(messageName) .. "）")
            else
                usedIds[messageId] = tostring(messageName)
            end

            local inReservedRange = false
            for _, range in ipairs(rangeList) do
                if messageId >= range.Min and messageId <= range.Max then
                    inReservedRange = true
                    break
                end
            end
            if not inReservedRange then
                AddError(errors, "网络消息 ID 不在预留分区内: " .. tostring(messageName) .. "=" .. tostring(messageId))
            end
        end
    end

    return #errors == 0, errors
end


---校验单个模块的公共定义。
function ConfigValidator.ValidateModuleDefinition(module)
    local errors = {}
    if type(module) ~= "table" then
        return false, { "模块必须是 table" }
    end
    if type(module.Name) ~= "string" or module.Name == "" then
        AddError(errors, "模块 Name 必须是非空字符串")
    end
    if module.FeatureFlag ~= nil and (type(module.FeatureFlag) ~= "string" or module.FeatureFlag == "") then
        AddError(errors, "模块 FeatureFlag 必须是非空字符串或 nil")
    end
    if module.Dependencies ~= nil and type(module.Dependencies) ~= "table" then
        AddError(errors, "模块 Dependencies 必须是数组或 nil")
    elseif type(module.Dependencies) == "table" then
        local seen = {}
        for index, dependency in ipairs(module.Dependencies) do
            if type(dependency) ~= "string" or dependency == "" then
                AddError(errors, "模块 Dependencies[" .. tostring(index) .. "] 必须是非空字符串")
            elseif seen[dependency] then
                AddError(errors, "模块依赖重复: " .. dependency)
            else
                seen[dependency] = true
            end
        end
    end
    return #errors == 0, errors
end


---校验依赖缺失和循环；结构化错误供 ModuleManager 区分模块错误与基础错误。
function ConfigValidator.ValidateModuleGraph(records)
    local issues = {}
    for name, record in pairs(records) do
        for _, dependency in ipairs(record.Module.Dependencies or {}) do
            if not records[dependency] then
                issues[#issues + 1] = {
                    Fatal = false,
                    Module = name,
                    Message = "缺少依赖模块: " .. dependency,
                }
            end
        end
    end

    local state = {}
    local stack = {}
    local function Visit(name)
        if state[name] == 2 then
            return
        end
        if state[name] == 1 then
            local path = {}
            local beginCopy = false
            for _, stackName in ipairs(stack) do
                if stackName == name then
                    beginCopy = true
                end
                if beginCopy then
                    path[#path + 1] = stackName
                end
            end
            path[#path + 1] = name
            issues[#issues + 1] = {
                Fatal = true,
                Module = name,
                Message = "检测到循环依赖: " .. table.concat(path, " -> "),
            }
            return
        end

        state[name] = 1
        stack[#stack + 1] = name
        local record = records[name]
        if record then
            for _, dependency in ipairs(record.Module.Dependencies or {}) do
                if records[dependency] then
                    Visit(dependency)
                end
            end
        end
        stack[#stack] = nil
        state[name] = 2
    end

    for name in pairs(records) do
        Visit(name)
    end
    return issues
end

return ConfigValidator
