local GameConfig = require "Common.Config.GameConfig"

local ZoneService = {
    Name = "ZoneService",
    FeatureFlag = "Zone",
    Dependencies = {},
}

local IsPositiveInteger = require("Common.Validation").IsPositiveInteger

local Traceback = require("Common.Core.SafeCall").Traceback


function ZoneService:Start(context)
    if context.Side ~= "Server" then
        return
    end

    local config = GameConfig.Zone
    local runtime = {
        InStolenAreaByPlayer = {},
        CurrentRegionByPlayer = {},
        TouchCallback = nil,
        EnterCallback = nil,
        PreleaveCallback = nil,
    }

    local function Diag(stage, playerId, triggerBoxId, previous, requested, source)
        pcall(function()
            local readOk, carriedRoot = pcall(function()
                local theft = context.Services.TheftService
                return theft and theft.CarriedByPlayer and theft.CarriedByPlayer[playerId]
            end)
            Log:PrintServerLog("[ZoneDiag]", "stage:", stage,
                "playerId:", tostring(playerId), "triggerBoxId:", tostring(triggerBoxId),
                "previous:", tostring(previous), "requested:", tostring(requested),
                "actual:", tostring(runtime.InStolenAreaByPlayer[playerId]),
                "source:", tostring(source), "changed:", tostring(previous ~= requested),
                "carriedReadOk:", tostring(readOk), "carriedRoot:", tostring(carriedRoot))
        end)
    end

    function runtime:IsInStolenArea(playerId)
        return self.InStolenAreaByPlayer[playerId] == true
    end

    function runtime:SendState(playerId)
        System:SendToClient(playerId, context.NetMsg.Messages.ZoneState, {
            inStolenArea = self:IsInStolenArea(playerId),
            regionId = self.CurrentRegionByPlayer[playerId] or 0,
        })
    end

    function runtime:SetPlayerArea(playerId, inStolenArea, source)
        if not IsPositiveInteger(playerId) or type(inStolenArea) ~= "boolean" then
            return false, "invalid_area_arguments"
        end
        local previous = self.InStolenAreaByPlayer[playerId]
        Diag("set_before", playerId, nil, previous, inStolenArea, source)
        self.InStolenAreaByPlayer[playerId] = inStolenArea
        if not inStolenArea then self.CurrentRegionByPlayer[playerId] = nil end
        Diag("set_after", playerId, nil, previous, inStolenArea, source)
        self:SendState(playerId)
        if previous ~= inStolenArea then
            local snapshot = {
                playerId = playerId,
                inStolenArea = inStolenArea,
                source = source,
            }
            Diag("publish_before", playerId, nil, previous, inStolenArea, source)
            context.Events:Publish("ZoneChanged", snapshot)
            Diag("publish_after", playerId, nil, previous, inStolenArea, source)
            Log:PrintServerLog("[ZoneService] 玩家区域状态改变",
                "playerId:", playerId,
                "inStolenArea:", tostring(inStolenArea),
                "source:", tostring(source))
        end
        return true
    end

    runtime.EnterCallback = function(playerId, triggerBoxId)
        local ok, errorMessage = xpcall(function()
            if triggerBoxId == config.HomeTriggerBoxId or triggerBoxId == config.StolenTriggerBoxId then
                Diag("enter_raw", playerId, triggerBoxId)
            end
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

    runtime.TouchCallback = function(elementId, playerId)
        local ok, errorMessage = xpcall(function()
            if not IsPositiveInteger(elementId) or not IsPositiveInteger(playerId) then return end
            local theft = context.Services.TheftService
            if theft and theft:IsWorldChickenRoot(elementId) then return end
            local readOk, regionId = pcall(function()
                return CustomProperty:GetCustomProperty(elementId,
                    GameConfig.Theft.RegionProperty, CustomProperty.PROPERTY_TYPE.Number)
            end)
            if not readOk or not IsPositiveInteger(regionId) or regionId > 15 then return end
            if runtime.CurrentRegionByPlayer[playerId] == regionId
                and runtime:IsInStolenArea(playerId) then return end
            runtime.CurrentRegionByPlayer[playerId] = regionId
            runtime:SetPlayerArea(playerId, true, "touched_region_floor")
        end, Traceback)
        if not ok then context.Manager:FailModule(ZoneService.Name, errorMessage) end
    end

    runtime.PreleaveCallback = function(playerId)
        local persistence = context.Services.PersistenceService
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(playerId) end
        runtime.InStolenAreaByPlayer[playerId] = nil
        runtime.CurrentRegionByPlayer[playerId] = nil
    end

    context.Services.ZoneService = runtime
    System:RegisterEvent(Events.ON_CHARACTER_ENTER_SIGNAL_BOX, runtime.EnterCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    System:RegisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
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
    if runtime.TouchCallback then
        System:UnregisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
    end
    runtime.InStolenAreaByPlayer = {}
    runtime.CurrentRegionByPlayer = {}
    context.Services.ZoneService = nil
end

return ZoneService
