local GameConfig = require "Common.Config.GameConfig"

local ZoneService = {
    Name = "ZoneService",
    FeatureFlag = "Zone",
    Dependencies = {},
}

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

function ZoneService:ValidateConfig(context)
    if context.Side ~= "Server" then
        return true
    end
    local errors = {}
    local config = GameConfig.Zone
    if type(config) ~= "table" then
        errors[#errors + 1] = "GameConfig.Zone 必须是 table"
    else
        if not IsPositiveInteger(config.HomeTriggerBoxId) then
            errors[#errors + 1] = "HomeTriggerBoxId 必须是正整数"
        end
        if not IsPositiveInteger(config.StolenTriggerBoxId) then
            errors[#errors + 1] = "StolenTriggerBoxId 必须是正整数"
        end
        if config.HomeTriggerBoxId == config.StolenTriggerBoxId then
            errors[#errors + 1] = "家园区与偷取区触发盒不能相同"
        end
    end
    return #errors == 0, errors
end

function ZoneService:Start(context)
    if context.Side ~= "Server" then
        return
    end

    local config = GameConfig.Zone
    local runtime = {
        InStolenAreaByPlayer = {},
        EnterCallback = nil,
        PreleaveCallback = nil,
    }

    function runtime:IsInStolenArea(playerId)
        return self.InStolenAreaByPlayer[playerId] == true
    end

    function runtime:SetPlayerArea(playerId, inStolenArea, source)
        if not IsPositiveInteger(playerId) or type(inStolenArea) ~= "boolean" then
            return false, "invalid_area_arguments"
        end
        local previous = self.InStolenAreaByPlayer[playerId]
        self.InStolenAreaByPlayer[playerId] = inStolenArea
        System:SendToClient(playerId, context.NetMsg.Messages.ZoneState, {
            inStolenArea = inStolenArea,
        })
        if previous ~= inStolenArea then
            local snapshot = {
                playerId = playerId,
                inStolenArea = inStolenArea,
                source = source,
            }
            context.Events:Publish("ZoneChanged", snapshot)
            Log:PrintServerLog("[ZoneService] 玩家区域状态改变",
                "playerId:", playerId,
                "inStolenArea:", tostring(inStolenArea),
                "source:", tostring(source))
        end
        return true
    end

    runtime.EnterCallback = function(playerId, triggerBoxId)
        local ok, errorMessage = xpcall(function()
            if not IsPositiveInteger(playerId) or not IsPositiveInteger(triggerBoxId) then
                Log:PrintWarning("[ZoneService] 忽略无效进入事件",
                    "playerId:", tostring(playerId),
                    "triggerBoxId:", tostring(triggerBoxId))
                return
            end
            if triggerBoxId == config.StolenTriggerBoxId then
                runtime:SetPlayerArea(playerId, true, "entered_stolen_trigger")
            elseif triggerBoxId == config.HomeTriggerBoxId then
                runtime:SetPlayerArea(playerId, false, "entered_home_trigger")
            end
        end, Traceback)
        if not ok then
            context.Manager:FailModule(ZoneService.Name, errorMessage)
        end
    end

    runtime.PreleaveCallback = function(playerId)
        runtime.InStolenAreaByPlayer[playerId] = nil
    end

    context.Services.ZoneService = runtime
    System:RegisterEvent(Events.ON_CHARACTER_ENTER_SIGNAL_BOX, runtime.EnterCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    Log:PrintServerLog("[ZoneService] 正式区域模块已启动",
        "homeTriggerBoxId:", config.HomeTriggerBoxId,
        "stolenTriggerBoxId:", config.StolenTriggerBoxId)
end

function ZoneService:Stop(context)
    if context.Side ~= "Server" then
        return
    end
    local runtime = context.Services.ZoneService
    if not runtime then
        return
    end
    if runtime.EnterCallback then
        System:UnregisterEvent(Events.ON_CHARACTER_ENTER_SIGNAL_BOX, runtime.EnterCallback)
    end
    if runtime.PreleaveCallback then
        System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    end
    runtime.InStolenAreaByPlayer = {}
    context.Services.ZoneService = nil
end

return ZoneService
