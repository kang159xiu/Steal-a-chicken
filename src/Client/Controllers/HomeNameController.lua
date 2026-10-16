local GameConfig = require "Common.Config.GameConfig"

local HomeNameController = { Name = "HomeNameController", FeatureFlag = "Home", Dependencies = {} }

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end

function HomeNameController:Start(context)
    if context.Side ~= "Client" then return end
    local runtime = { Ready = false, StateByHome = {} }
    context.Services.HomeNameController = runtime

    local function Apply(state)
        local ok, errorMessage = pcall(function()
            FuncElement:SetTextBoardText(state.elementId, state.name)
        end)
        if not ok then
            Log:PrintError("[HomeNameController] 名称显示调用失败", "homeId:", state.homeId,
                "elementId:", state.elementId, "version:", state.version, "error:", tostring(errorMessage))
        else
            Log:PrintLog("[HomeNameController] 名称显示调用返回", "homeId:", state.homeId,
                "elementId:", state.elementId, "playerId:", state.playerId, "version:", state.version, "name:", state.name)
        end
    end

    runtime.StateCallback = function(_, message)
        if context.Services.HomeNameController ~= runtime or type(message) ~= "table"
            or not IsPositiveInteger(message.homeId) or not IsPositiveInteger(message.elementId)
            or not IsPositiveInteger(message.playerId) or not IsPositiveInteger(message.version)
            or type(message.name) ~= "string" or message.name == "" then return end
        local previous = runtime.StateByHome[message.homeId]
        if previous and message.version <= previous.version then return end
        local state = { homeId = message.homeId, elementId = message.elementId,
            playerId = message.playerId, name = message.name, version = message.version }
        runtime.StateByHome[state.homeId] = state
        if runtime.Ready then Apply(state) end
    end
    System:BindNotify(context.NetMsg.Messages.HomeNameState, runtime.StateCallback)
    context.Timers:AddTimer(HomeNameController.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if context.Services.HomeNameController ~= runtime then return end
        runtime.Ready = true
        for _, state in pairs(runtime.StateByHome) do Apply(state) end
        System:SendToServer(context.NetMsg.Messages.HomeNameSnapshotRequest, {})
    end)
end

function HomeNameController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.HomeNameController
    if not runtime then return end
    context.Services.HomeNameController = nil
    System:UnbindNotify(context.NetMsg.Messages.HomeNameState, runtime.StateCallback)
    context.Timers:RemoveOwner(HomeNameController.Name)
    -- 不清场景文字；空家园继续保留最后一次名称。
end

return HomeNameController
