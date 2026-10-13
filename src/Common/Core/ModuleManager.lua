local ConfigValidator = require "Common.Core.ConfigValidator"

local ModuleManager = {}
ModuleManager.__index = ModuleManager

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function LogErrors(prefix, errors)
    if type(errors) ~= "table" then
        Log:PrintError(prefix, tostring(errors))
        return
    end
    for _, errorMessage in ipairs(errors or {}) do
        Log:PrintError(prefix, errorMessage)
    end
end

function ModuleManager.New(side, featureFlags, netMsg)
    assert(side == "Server" or side == "Client", "ModuleManager side 必须是 Server 或 Client")
    return setmetatable({
        Side = side,
        _featureFlagsConfig = featureFlags,
        _featureFlags = {},
        _netMsg = netMsg,
        _records = {},
        _registrationOrder = {},
        _executionOrder = {},
        _fatalErrors = {},
        _context = nil,
        _initialized = false,
        _started = false,
        _stopped = false,
    }, ModuleManager)
end


function ModuleManager:Register(module)
    if self._initialized then
        Log:PrintError("[ModuleManager] Init 后禁止注册模块", self.Side)
        return false
    end

    local valid, errors = ConfigValidator.ValidateModuleDefinition(module)
    if not valid then
        LogErrors("[ModuleManager] 模块定义错误", errors)
        return false
    end
    if self._records[module.Name] then
        local message = "模块名称重复: " .. module.Name
        self._fatalErrors[#self._fatalErrors + 1] = message
        Log:PrintError("[ModuleManager]", self.Side, message)
        return false
    end

    self._records[module.Name] = {
        Module = module,
        Status = "Registered",
    }
    self._registrationOrder[#self._registrationOrder + 1] = module.Name
    return true
end


function ModuleManager:_BuildExecutionOrder()
    local issues = ConfigValidator.ValidateModuleGraph(self._records)
    for _, issue in ipairs(issues) do
        if issue.Fatal then
            self._fatalErrors[#self._fatalErrors + 1] = issue.Message
        else
            local record = self._records[issue.Module]
            record.Status = "Invalid"
            Log:PrintError("[ModuleManager] 模块不启动", self.Side, issue.Module, issue.Message)
        end
    end
    if #self._fatalErrors > 0 then
        return false
    end

    local visited = {}
    local function Visit(name)
        if visited[name] then
            return
        end
        visited[name] = true
        local record = self._records[name]
        for _, dependency in ipairs(record.Module.Dependencies or {}) do
            if self._records[dependency] then
                Visit(dependency)
            end
        end
        self._executionOrder[#self._executionOrder + 1] = name
    end
    for _, name in ipairs(self._registrationOrder) do
        Visit(name)
    end
    return true
end


function ModuleManager:_CleanupOwner(name)
    if not self._context then
        return
    end
    if self._context.Events then
        self._context.Events:UnsubscribeOwner(name)
    end
    if self._context.Timers then
        self._context.Timers:RemoveOwner(name)
    end
end


function ModuleManager:_CallLifecycle(record, methodName, ...)
    local method = record.Module[methodName]
    if type(method) ~= "function" then
        return true
    end
    local args = { n = select("#", ...), ... }
    local unpackArgs = table.unpack or unpack
    local ok, errorMessage = xpcall(function()
        method(record.Module, unpackArgs(args, 1, args.n))
    end, Traceback)
    if not ok then
        self:FailModule(record.Module.Name, methodName .. " 失败: " .. tostring(errorMessage))
        return false
    end
    return true
end


function ModuleManager:_DependenciesReady(record, requiredStatus)
    for _, dependency in ipairs(record.Module.Dependencies or {}) do
        local dependencyRecord = self._records[dependency]
        if not dependencyRecord or dependencyRecord.Status ~= requiredStatus then
            return false, dependency
        end
    end
    return true
end


function ModuleManager:Init(context)
    if self._initialized then
        return #self._fatalErrors == 0
    end
    self._context = context

    local flagsValid, flagErrors = ConfigValidator.ValidateFeatureFlags(self._featureFlagsConfig)
    if not flagsValid then
        for _, message in ipairs(flagErrors) do
            self._fatalErrors[#self._fatalErrors + 1] = message
        end
    else
        self._featureFlags = ConfigValidator.SnapshotFeatureFlags(self._featureFlagsConfig)
    end

    local registeredFlags = {}
    for _, record in pairs(self._records) do
        if record.Module.FeatureFlag then
            registeredFlags[record.Module.FeatureFlag] = true
        end
    end
    for flagName, enabled in pairs(self._featureFlags) do
        local scopes = self._featureFlagsConfig.Scopes
        local scope = scopes and scopes[flagName] or nil
        local requiredOnCurrentSide = scope == nil or scope[self.Side] == true
        if enabled and requiredOnCurrentSide and not registeredFlags[flagName] then
            Log:PrintWarning("[ModuleManager] 功能开关已开启，但当前端没有登记对应模块",
                self.Side, flagName)
        end
    end

    local messagesValid, messageErrors = ConfigValidator.ValidateNetMessages(self._netMsg)
    if not messagesValid then
        for _, message in ipairs(messageErrors) do
            self._fatalErrors[#self._fatalErrors + 1] = message
        end
    end

    if not self:_BuildExecutionOrder() or #self._fatalErrors > 0 then
        LogErrors("[ModuleManager] 基础配置错误，当前端停止启动: " .. self.Side, self._fatalErrors)
        self._initialized = true
        return false
    end

    for _, name in ipairs(self._executionOrder) do
        local record = self._records[name]
        if record.Status == "Registered" then
            local flagName = record.Module.FeatureFlag
            if flagName and self._featureFlags[flagName] == nil then
                record.Status = "Invalid"
                Log:PrintError("[ModuleManager] 模块引用了未登记的功能开关，不启动",
                    self.Side, name, flagName)
            elseif flagName and self._featureFlags[flagName] ~= true then
                record.Status = "Disabled"
            else
                local dependenciesReady, dependency = self:_DependenciesReady(record, "Initialized")
                if not dependenciesReady then
                    record.Status = "Blocked"
                    Log:PrintWarning("[ModuleManager] 依赖未初始化，模块不启动", self.Side, name, dependency)
                else
                    local configValid = true
                    if type(record.Module.ValidateConfig) == "function" then
                        local ok, valid, errors = xpcall(function()
                            return record.Module:ValidateConfig(context)
                        end, Traceback)
                        if not ok then
                            configValid = false
                            errors = { tostring(valid) }
                        elseif valid ~= true then
                            configValid = false
                        end
                        if not configValid then
                            record.Status = "Invalid"
                            LogErrors("[ModuleManager] 模块配置错误，不启动 " .. name, errors or {
                                "ValidateConfig 未返回 true",
                            })
                        end
                    end

                    if configValid then
                        record.Status = "Initializing"
                        if self:_CallLifecycle(record, "Init", context) then
                            record.Status = "Initialized"
                        end
                    end
                end
            end
        end
    end

    self._initialized = true
    return true
end


function ModuleManager:Start()
    if not self._initialized or #self._fatalErrors > 0 or self._started then
        return false
    end
    self._started = true
    for _, name in ipairs(self._executionOrder) do
        local record = self._records[name]
        if record.Status == "Initialized" then
            local dependenciesReady, dependency = self:_DependenciesReady(record, "Started")
            if not dependenciesReady and #(record.Module.Dependencies or {}) > 0 then
                record.Status = "Blocked"
                self:_CleanupOwner(name)
                Log:PrintWarning("[ModuleManager] 依赖未启动，模块不启动", self.Side, name, dependency)
            else
                record.Status = "Starting"
                if self:_CallLifecycle(record, "Start", self._context) then
                    record.Status = "Started"
                end
            end
        end
    end
    return true
end


function ModuleManager:Update(deltaTime)
    if not self._started or self._stopped then
        return
    end
    for _, name in ipairs(self._executionOrder) do
        local record = self._records[name]
        if record.Status == "Started" and type(record.Module.Update) == "function" then
            self:_CallLifecycle(record, "Update", deltaTime, self._context)
        end
    end
end


function ModuleManager:HasActiveUpdates()
    if not self._started or self._stopped then
        return false
    end
    for _, name in ipairs(self._executionOrder) do
        local record = self._records[name]
        if record.Status == "Started" and type(record.Module.Update) == "function" then
            return true
        end
    end
    return false
end


function ModuleManager:FailModule(owner, errorMessage)
    local name = type(owner) == "table" and owner.Name or owner
    local record = self._records[name]
    if not record then
        Log:PrintError("[ModuleManager] 未登记资源所有者发生错误", self.Side, tostring(name), errorMessage)
        return
    end
    if record.Status == "Failed" or record.Status == "Stopped" then
        return
    end

    Log:PrintError("[ModuleManager] 模块运行错误，停止该模块", self.Side, name, errorMessage)
    local stopMethod = record.Module.Stop
    if type(stopMethod) == "function" then
        local ok, stopError = xpcall(function()
            stopMethod(record.Module, self._context)
        end, Traceback)
        if not ok then
            Log:PrintError("[ModuleManager] 模块错误清理失败", self.Side, name, stopError)
        end
    end
    self:_CleanupOwner(name)
    record.Status = "Failed"
end


function ModuleManager:Stop()
    if self._stopped then
        return
    end
    self._stopped = true
    for index = #self._executionOrder, 1, -1 do
        local name = self._executionOrder[index]
        local record = self._records[name]
        if record.Status == "Started" or record.Status == "Initialized" then
            local stopMethod = record.Module.Stop
            if type(stopMethod) == "function" then
                local ok, errorMessage = xpcall(function()
                    stopMethod(record.Module, self._context)
                end, Traceback)
                if not ok then
                    Log:PrintError("[ModuleManager] Stop 失败", self.Side, name, errorMessage)
                end
            end
            self:_CleanupOwner(name)
            record.Status = "Stopped"
        elseif record.Status == "Blocked" then
            self:_CleanupOwner(name)
            record.Status = "Stopped"
        end
    end
end

return ModuleManager
