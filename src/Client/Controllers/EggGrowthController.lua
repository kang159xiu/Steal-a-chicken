local GameConfig = require "Common.Config.GameConfig"
local EggModelText = require "Common.EggModelText"

local EggGrowthController = { Name = "EggGrowthController", FeatureFlag = "EggProduction", Dependencies = {} }
local function Integer(value, minimum)
    return type(value) == "number" and value >= minimum and value < math.huge and value == math.floor(value)
end
local function EggConfig(eggTypeId)
    for _, chicken in pairs(GameConfig.ChickenTypes) do
        if chicken.Egg and chicken.Egg.EggTypeId == eggTypeId then return chicken.Egg end
    end
end

function EggGrowthController:Start(context)
    if context.Side ~= "Client" then return end
    local config = GameConfig.EggGrowth
    local runtime = { Ready = false, Stopped = false, Entries = {}, Versions = {}, RootOwners = {}, Refreshing = {} }
    context.Services.EggGrowthController = runtime
    local function Current(entry)
        return not runtime.Stopped and context.Services.EggGrowthController == runtime
            and runtime.Entries[entry.state.eggId] == entry
            and runtime.RootOwners[entry.state.rootId] == entry
            and runtime.Versions[entry.state.eggId] == entry.state.version
    end
    local function Error(entry, action, message)
        Log:PrintError("[EggGrowthController] 表现失败，仅跳过对应表现", "eggId:", entry.state.eggId,
            "rootId:", entry.state.rootId, "action:", action, "error:", tostring(message))
    end
    local function Discard(entry)
        runtime.Refreshing[entry.state.eggId] = nil
        if runtime.RootOwners[entry.state.rootId] == entry then runtime.RootOwners[entry.state.rootId] = nil end
        if runtime.Entries[entry.state.eggId] == entry then runtime.Entries[entry.state.eggId] = nil end
    end
    local function Progress(state, now)
        local duration = state.hatchDeadlineMs - state.spawnedAtMs
        if duration <= 0 or now >= state.hatchDeadlineMs then
            return state.finalScale, state.finalSellPrice, 100 + state.finalScaleUnits - config.InitialScaleUnits, 0
        end
        local elapsed = math.max(0, math.min(duration, now - state.spawnedAtMs))
        local deltaUnits = state.finalScaleUnits - config.InitialScaleUnits
        local numerator = 100 * duration + deltaUnits * elapsed
        local price = state.baseSellPrice
            + math.floor((state.baseSellPrice * deltaUnits * elapsed + 50 * duration) / (100 * duration))
        local multiplier = math.floor((numerator + duration / 2) / duration)
        local scale = (config.InitialScaleUnits + deltaUnits * elapsed / duration) / 100
        return scale, price, multiplier, (duration - elapsed) / 1000
    end
    local function IndexText(entry)
        local matches, visited = { [config.ValuePurpose] = {}, [config.MultiplierPurpose] = {} }, {}
        local function Visit(elementId)
            if not Current(entry) or visited[elementId] then return end
            visited[elementId] = true
            local ok, purpose = pcall(function()
                return CustomProperty:GetCustomProperty(elementId, "作用", CustomProperty.PROPERTY_TYPE.String)
            end)
            if not Current(entry) then return end
            if ok and matches[purpose] then matches[purpose][elementId] = {} end
            local childOk, children = pcall(function() return Element:GetChildElementsFromElement(elementId) end)
            if childOk then for _, childId in ipairs(children or {}) do Visit(childId) end end
        end
        Visit(entry.state.rootId)
        entry.valueElements, entry.nameElements = matches[config.ValuePurpose], matches[config.MultiplierPurpose]
    end
    local function UpdateText(entry, price, multiplier)
        for _, item in ipairs({ { elements = entry.valueElements, value = true }, { elements = entry.nameElements } }) do
            local formatted, text = pcall(function()
                if item.value then return EggModelText.FormatPrice(price) end
                return EggConfig(entry.state.eggTypeId).DisplayName
            end)
            if formatted then
                for elementId, cached in pairs(item.elements or {}) do
                    if not Current(entry) then return end
                    if cached.text ~= text then
                        cached.text = text
                        local ok = pcall(function() FuncElement:SetTextBoardText(elementId, text) end)
                        if not ok then item.elements[elementId] = nil end -- 本状态失败文字不重试。
                    end
                end
            end
        end
    end
    local function Apply(entry)
        if not Current(entry) then return end
        -- 两帧后再读取对象；不存在或读取失败只记录一次，不增加重试链。
        local exists, position = pcall(function() return Element:GetPosition(entry.state.rootId) end)
        if not exists or not position then
            Error(entry, "对象检查", exists and "元件不可用" or position)
            return
        end
        IndexText(entry)
        local _, price, multiplier, remaining = Progress(entry.state, MiscService:GetServerTimestamp())
        UpdateText(entry, price, multiplier)

        if remaining <= 0 then
            return
        end
        if next(entry.valueElements) then runtime.Refreshing[entry.state.eggId] = entry end
    end
    local function Queue(entry)
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if Current(entry) then Apply(entry) end
        end)
    end
    runtime.StateCallback = function(_, message)
        if runtime.Stopped or context.Services.EggGrowthController ~= runtime or type(message) ~= "table"
            or not Integer(message.eggId, 1) or not Integer(message.homeId, 1) or not Integer(message.rootId, 1)
            or not Integer(message.version, 1) or not Integer(message.baseSellPrice, 0)
            or not Integer(message.finalSellPrice, 0) or not Integer(message.finalScaleUnits, config.MinFinalScaleUnits)
            or type(message.eggTypeId) ~= "string" or not EggConfig(message.eggTypeId)
            or message.finalScaleUnits > config.MaxFinalScaleUnits
            or message.finalScale ~= message.finalScaleUnits / 100
            or not Integer(message.spawnedAtMs, 0) or not Integer(message.hatchDeadlineMs, 0)
            or message.hatchDeadlineMs < message.spawnedAtMs then return end
        local version = runtime.Versions[message.eggId]
        if version and message.version <= version then return end
        local old = runtime.Entries[message.eggId]
        if old then Discard(old) end
        local rootOwner = runtime.RootOwners[message.rootId]
        if rootOwner then
            if rootOwner.state.version >= message.version then return end
            Discard(rootOwner)
        end
        local state = {}
        for _, key in ipairs({ "eggId", "homeId", "rootId", "baseSellPrice", "finalScaleUnits", "finalScale",
            "finalSellPrice", "spawnedAtMs", "hatchDeadlineMs", "version", "eggTypeId" }) do state[key] = message[key] end
        local entry = { state = state }
        runtime.Entries[state.eggId] = entry
        runtime.Versions[state.eggId] = state.version
        runtime.RootOwners[state.rootId] = entry
        if runtime.Ready then Queue(entry) end
    end
    runtime.RemovedCallback = function(_, message)
        if runtime.Stopped or context.Services.EggGrowthController ~= runtime or type(message) ~= "table"
            or not Integer(message.eggId, 1) or not Integer(message.version, 1) then return end
        local version = runtime.Versions[message.eggId]
        if version and message.version <= version then return end
        runtime.Versions[message.eggId] = message.version -- 保留删除版本，拦截迟到的生成/快照。
        local entry = runtime.Entries[message.eggId]
        if entry then Discard(entry) end
    end
    System:BindNotify(context.NetMsg.Messages.EggGrowthState, runtime.StateCallback)
    System:BindNotify(context.NetMsg.Messages.EggGrowthRemoved, runtime.RemovedCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if runtime.Stopped or context.Services.EggGrowthController ~= runtime then return end
        runtime.Ready = true
        for _, entry in pairs(runtime.Entries) do Queue(entry) end
        System:SendToServer(context.NetMsg.Messages.EggGrowthSnapshotRequest, {})
    end)
    context.Timers:AddLoopTimer(self.Name, config.TextRefreshSeconds, function()
        if not runtime.Ready or runtime.Stopped or context.Services.EggGrowthController ~= runtime
            or next(runtime.Refreshing) == nil then return end
        local now = MiscService:GetServerTimestamp()
        for eggId, entry in pairs(runtime.Refreshing) do
            if not Current(entry) then runtime.Refreshing[eggId] = nil
            else
                local _, price, multiplier, remaining = Progress(entry.state, now)
                UpdateText(entry, price, multiplier)
                if remaining <= 0 then
                    runtime.Refreshing[eggId] = nil
                end
            end
        end
    end)
    runtime.Cleanup = function()
        runtime.Stopped = true
        runtime.Entries, runtime.Versions, runtime.RootOwners, runtime.Refreshing = {}, {}, {}, {}
    end
end

function EggGrowthController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.EggGrowthController
    if not runtime then return end
    runtime.Cleanup()
    System:UnbindNotify(context.NetMsg.Messages.EggGrowthState, runtime.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggGrowthRemoved, runtime.RemovedCallback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.EggGrowthController = nil
end

return EggGrowthController
