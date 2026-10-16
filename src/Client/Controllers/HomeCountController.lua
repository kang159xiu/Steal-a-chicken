local GameConfig = require "Common.Config.GameConfig"

local HomeCountController = { Name = "HomeCountController", FeatureFlag = "EggProduction", Dependencies = {} }
local function Integer(value, minimum)
    return type(value) == "number" and value >= minimum and value < math.huge and value == math.floor(value)
end

function HomeCountController:Start(context)
    if context.Side ~= "Client" then return end
    local runtime = { Ready = false, StateByHome = {} }
    context.Services.HomeCountController = runtime
    local function Apply(state)
        for _, entry in ipairs({
            { elementId = state.chickenElementId, count = state.chickenCount, capacity = state.chickenCapacity },
            { elementId = state.eggElementId, count = state.eggCount, capacity = state.eggCapacity },
        }) do
            if entry.elementId then
                local text = tostring(entry.count) .. "/" .. tostring(entry.capacity)
                local ok, errorMessage = pcall(function() FuncElement:SetTextBoardText(entry.elementId, text) end)
                if not ok then
                    Log:PrintError("[HomeCountController] 数量文字调用失败，仅跳过该文字",
                        "homeId:", state.homeId, "elementId:", entry.elementId, "error:", tostring(errorMessage))
                end
            end
        end
    end
    runtime.StateCallback = function(_, message)
        if context.Services.HomeCountController ~= runtime or type(message) ~= "table"
            or not Integer(message.homeId, 1) or not Integer(message.playerId, 1)
            or not Integer(message.version, 1) or not Integer(message.chickenCount, 0)
            or not Integer(message.eggCount, 0) or not Integer(message.chickenCapacity, 1)
            or not Integer(message.eggCapacity, 1) or message.chickenCount > message.chickenCapacity
            or message.eggCount > message.eggCapacity
            or (message.chickenElementId ~= nil and not Integer(message.chickenElementId, 1))
            or (message.eggElementId ~= nil and not Integer(message.eggElementId, 1)) then return end
        local previous = runtime.StateByHome[message.homeId]
        if previous and message.version <= previous.version then return end
        local state = {}
        for _, key in ipairs({ "homeId", "playerId", "chickenElementId", "eggElementId", "chickenCount",
            "chickenCapacity", "eggCount", "eggCapacity", "version" }) do state[key] = message[key] end
        runtime.StateByHome[state.homeId] = state
        if runtime.Ready then Apply(state) end
    end
    System:BindNotify(context.NetMsg.Messages.HomeCountState, runtime.StateCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if context.Services.HomeCountController ~= runtime then return end
        runtime.Ready = true
        for _, state in pairs(runtime.StateByHome) do Apply(state) end
        System:SendToServer(context.NetMsg.Messages.HomeCountSnapshotRequest, {})
    end)
end

function HomeCountController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.HomeCountController
    if not runtime then return end
    context.Services.HomeCountController = nil
    System:UnbindNotify(context.NetMsg.Messages.HomeCountState, runtime.StateCallback)
    context.Timers:RemoveOwner(self.Name)
    runtime.StateByHome = {}
    -- 场景文字保留最后有效值。
end

return HomeCountController
