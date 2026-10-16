local GameConfig = require "Common.Config.GameConfig"

local EggGrowthController = { Name = "EggGrowthController", FeatureFlag = "EggProduction", Dependencies = {} }
local function Integer(value, minimum)
    return type(value) == "number" and value >= minimum and value < math.huge and value == math.floor(value)
end
local units = { { 1e21, "Sx" }, { 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" },
    { 1e9, "B" }, { 1e6, "M" }, { 1e4, "w" }, { 1e3, "k" } }
local function MoneyText(value)
    for _, unit in ipairs(units) do
        if value >= unit[1] then
            return string.format("%.2f", math.floor(value / unit[1] * 100 + 0.5) / 100) .. unit[2]
        end
    end
    return string.format("%.0f", value)
end
local function MultiplierText(hundredths)
    local whole, fraction = math.floor(hundredths / 100), hundredths % 100
    if fraction == 0 then return "x" .. tostring(whole) end
    local decimals = string.format("%02d", fraction):gsub("0$", "")
    return "x" .. tostring(whole) .. "." .. decimals
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
    local function StopAnimation(entry)
        if entry.animating and runtime.RootOwners[entry.state.rootId] == entry then
            entry.animating = false
            local ok, errorMessage = pcall(function() Element:StopScaleTo(entry.state.rootId) end)
            if not ok then Error(entry, "StopScaleTo", errorMessage) end
        end
    end
    local function Discard(entry)
        StopAnimation(entry)
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
        local ok, errorMessage = pcall(function()
            local function Visit(elementId)
                if visited[elementId] then error("蛋文字树重复或循环") end
                visited[elementId] = true
                local purpose = CustomProperty:GetCustomProperty(elementId, "作用", CustomProperty.PROPERTY_TYPE.String)
                if matches[purpose] then matches[purpose][#matches[purpose] + 1] = elementId end
                for _, childId in ipairs(Element:GetChildElementsFromElement(elementId) or {}) do Visit(childId) end
            end
            Visit(entry.state.rootId)
        end)
        if not ok then Error(entry, "文字索引", errorMessage); return end
        for _, item in ipairs({ { purpose = config.ValuePurpose, field = "valueElementId" },
            { purpose = config.MultiplierPurpose, field = "multiplierElementId" } }) do
            local ids = matches[item.purpose]
            if #ids == 1 then entry[item.field] = ids[1]
            else Error(entry, item.purpose, "必须唯一，actual=" .. tostring(#ids)) end
        end
    end
    local function UpdateText(entry, price, multiplier)
        for _, item in ipairs({ { field = "valueElementId", text = MoneyText(price) },
            { field = "multiplierElementId", text = MultiplierText(multiplier) } }) do
            local elementId = entry[item.field]
            if elementId and entry[item.field .. "Text"] ~= item.text then
                local ok, errorMessage = pcall(function() FuncElement:SetTextBoardText(elementId, item.text) end)
                if ok then entry[item.field .. "Text"] = item.text
                else
                    entry[item.field] = nil -- 本次蛋状态不再尝试失败文字，避免0.2秒刷屏。
                    Error(entry, item.field, errorMessage)
                end
            end
        end
    end
    local function FinalScale(entry)
        if entry.scaleFailed then return end
        StopAnimation(entry)
        local target = entry.state.finalScale
        local ok, errorMessage = pcall(function()
            Element:SetScale(entry.state.rootId, Engine.Vector(target, target, target))
        end)
        if not ok then entry.scaleFailed = true; Error(entry, "SetScale", errorMessage) end
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
        local currentScale, price, multiplier, remaining = Progress(entry.state, MiscService:GetServerTimestamp())
        UpdateText(entry, price, multiplier)
        if remaining <= 0 then FinalScale(entry); return end
        local target = entry.state.finalScale
        local ok, errorMessage = pcall(function()
            Element:ScaleTo(entry.state.rootId, Engine.Vector(target, target, target), remaining, Element.CURVE.linear,
                Engine.Vector(currentScale, currentScale, currentScale))
        end)
        if ok then entry.animating = true
        else entry.scaleFailed = true; Error(entry, "ScaleTo", errorMessage) end
        if entry.valueElementId or entry.multiplierElementId or entry.animating then
            runtime.Refreshing[entry.state.eggId] = entry
        end
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
            "finalSellPrice", "spawnedAtMs", "hatchDeadlineMs", "version" }) do state[key] = message[key] end
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
                    FinalScale(entry)
                    runtime.Refreshing[eggId] = nil
                end
            end
        end
    end)
    runtime.Cleanup = function()
        runtime.Stopped = true
        for _, entry in pairs(runtime.Entries) do StopAnimation(entry) end
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
