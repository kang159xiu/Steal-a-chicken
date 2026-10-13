local GameConfig = require "Common.Config.GameConfig"

local HomeService = {
    Name = "HomeService",
    FeatureFlag = "Home",
    Dependencies = { "ZoneService" },
}

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function CopyArray(source)
    local result = {}
    for index, value in ipairs(source or {}) do
        result[index] = value
    end
    return result
end

local function ReadPurpose(elementId, propertyName)
    local ok, value = pcall(function()
        return CustomProperty:GetCustomProperty(
            elementId,
            propertyName,
            CustomProperty.PROPERTY_TYPE.String
        )
    end)
    if not ok then
        error("读取作用属性失败，elementId=" .. tostring(elementId)
            .. " error=" .. tostring(value))
    end
    return value
end

local function FindReturnPoint(homeId, config)
    local matches = {}
    local visited = {}
    local function Visit(parentId)
        if visited[parentId] then
            error("家园元件树存在重复或循环，homeId=" .. tostring(homeId))
        end
        visited[parentId] = true
        local childIds = Element:GetChildElementsFromElement(parentId) or {}
        for _, childId in ipairs(childIds) do
            if ReadPurpose(childId, config.PurposeProperty) == config.ReturnPointPurpose then
                matches[#matches + 1] = childId
            end
            Visit(childId)
        end
    end
    Visit(homeId)
    if #matches ~= 1 then
        error("每个家园必须且只能有一个作用=家园返回点，homeId="
            .. tostring(homeId) .. " actual=" .. tostring(#matches))
    end
    return matches[1]
end

function HomeService:ValidateConfig(context)
    if context.Side ~= "Server" then
        return true
    end
    local errors = {}
    local config = GameConfig.Home
    if type(config) ~= "table" then
        errors[#errors + 1] = "GameConfig.Home 必须是 table"
        return false, errors
    end
    if type(config.RootElementIds) ~= "table" or #config.RootElementIds ~= config.MaxPlayers then
        errors[#errors + 1] = "家园根元件数量必须等于 MaxPlayers"
    end
    local seen = {}
    for index, homeId in ipairs(config.RootElementIds or {}) do
        if not IsPositiveInteger(homeId) then
            errors[#errors + 1] = "家园根ID无效，index=" .. tostring(index)
        elseif seen[homeId] then
            errors[#errors + 1] = "家园根ID重复: " .. tostring(homeId)
        else
            seen[homeId] = true
        end
    end
    if type(config.PurposeProperty) ~= "string" or config.PurposeProperty == "" then
        errors[#errors + 1] = "PurposeProperty 必须是非空字符串"
    end
    if type(config.HomePurpose) ~= "string" or config.HomePurpose == "" then
        errors[#errors + 1] = "HomePurpose 必须是非空字符串"
    end
    if type(config.ReturnPointPurpose) ~= "string" or config.ReturnPointPurpose == "" then
        errors[#errors + 1] = "ReturnPointPurpose 必须是非空字符串"
    end
    return #errors == 0, errors
end

function HomeService:Start(context)
    if context.Side ~= "Server" then
        return
    end

    local config = GameConfig.Home
    local runtime = {
        Ready = false,
        HomeIds = CopyArray(config.RootElementIds),
        ReturnPointByHome = {},
        PlayerToHome = {},
        HomeToPlayer = {},
        EnterCallback = nil,
        JoinCallback = nil,
        ReconnectCallback = nil,
        PreleaveCallback = nil,
    }

    function runtime:GetPlayerHome(playerId)
        return self.PlayerToHome[playerId]
    end

    function runtime:IsOwner(playerId, homeId)
        return self.PlayerToHome[playerId] == homeId
            and self.HomeToPlayer[homeId] == playerId
    end

    function runtime:GetReturnPoint(playerId)
        local homeId = self.PlayerToHome[playerId]
        return homeId and self.ReturnPointByHome[homeId] or nil
    end

    local function AuditMappings(source)
        for playerId, homeId in pairs(runtime.PlayerToHome) do
            if runtime.HomeToPlayer[homeId] ~= playerId then
                error(source .. " 家园双向映射不一致")
            end
        end
        for homeId, playerId in pairs(runtime.HomeToPlayer) do
            if runtime.PlayerToHome[playerId] ~= homeId then
                error(source .. " 家园反向映射不一致")
            end
        end
    end

    local function ReleasePlayer(playerId, source)
        local homeId = runtime.PlayerToHome[playerId]
        if not homeId then
            return nil
        end
        runtime.PlayerToHome[playerId] = nil
        runtime.HomeToPlayer[homeId] = nil
        AuditMappings(source)
        context.Events:Publish("HomeReleased", {
            playerId = playerId,
            homeId = homeId,
            source = source,
        })
        Log:PrintServerLog("[HomeService] 家园已释放",
            "playerId:", playerId, "homeId:", homeId, "source:", source)
        return homeId
    end

    local function AssignPlayer(playerId, source)
        if not IsPositiveInteger(playerId) then
            error("家园分配收到无效玩家ID: " .. tostring(playerId))
        end
        if runtime.PlayerToHome[playerId] then
            return runtime.PlayerToHome[playerId]
        end
        local homeId
        for _, candidateId in ipairs(runtime.HomeIds) do
            if runtime.HomeToPlayer[candidateId] == nil then
                homeId = candidateId
                break
            end
        end
        if not homeId then
            error("没有空闲家园，玩家上限与家园数量配置不一致")
        end

        runtime.PlayerToHome[playerId] = homeId
        runtime.HomeToPlayer[homeId] = playerId
        AuditMappings(source)

        local returnPointId = runtime.ReturnPointByHome[homeId]
        local position = Element:GetPosition(returnPointId)
        if not position then
            error("无法读取家园返回点位置，returnPointId=" .. tostring(returnPointId))
        end
        Character:CharacterTeleport(playerId, position)
        local zone = context.Services.ZoneService
        if zone then
            zone:SetPlayerArea(playerId, false, "home_assigned")
        end
        System:SendToClient(playerId, context.NetMsg.Messages.HomeAssigned, {
            homeId = homeId,
            returnPointId = returnPointId,
        })
        context.Events:Publish("HomeAssigned", {
            playerId = playerId,
            homeId = homeId,
            returnPointId = returnPointId,
        })
        context.Timers:AddFrame(HomeService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            Log:PrintServerLog("[HomeService] 家园分配与传送完成",
                "playerId:", playerId,
                "homeId:", homeId,
                "returnPointId:", returnPointId,
                "actualPosition:", tostring(Character:GetPosition(playerId)))
        end)
        return homeId
    end

    local function Run(actionName, callback)
        local ok, errorMessage = xpcall(callback, Traceback)
        if not ok then
            context.Manager:FailModule(HomeService.Name, actionName .. ": " .. tostring(errorMessage))
        end
    end

    runtime.EnterCallback = function(playerId)
        if runtime.Ready then
            Run("玩家进入分配", function() AssignPlayer(playerId, Events.ON_PLAYER_ENTER) end)
        end
    end
    runtime.JoinCallback = function(playerId)
        if runtime.Ready then
            Run("中途加入分配", function() AssignPlayer(playerId, Events.ON_PLAYER_JOIN_MIDWAY) end)
        end
    end
    runtime.ReconnectCallback = function(playerId)
        if runtime.Ready then
            Run("重连重新分配", function()
                ReleasePlayer(playerId, Events.ON_PLAYER_RECONNECTED)
                AssignPlayer(playerId, Events.ON_PLAYER_RECONNECTED)
            end)
        end
    end
    runtime.PreleaveCallback = function(playerId)
        if runtime.Ready then
            Run("离开释放", function() ReleasePlayer(playerId, Events.ON_PLAYER_PRELEAVE) end)
        end
    end

    context.Services.HomeService = runtime
    System:RegisterEvent(Events.ON_PLAYER_ENTER, runtime.EnterCallback)
    System:RegisterEvent(Events.ON_PLAYER_JOIN_MIDWAY, runtime.JoinCallback)
    System:RegisterEvent(Events.ON_PLAYER_RECONNECTED, runtime.ReconnectCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)

    context.Timers:AddTimer(HomeService.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        for _, homeId in ipairs(runtime.HomeIds) do
            local purpose = ReadPurpose(homeId, config.PurposeProperty)
            if purpose ~= config.HomePurpose then
                error("家园作用属性不匹配，homeId=" .. tostring(homeId)
                    .. " actual=" .. tostring(purpose))
            end
            runtime.ReturnPointByHome[homeId] = FindReturnPoint(homeId, config)
        end
        local playerIds = Character:GetAllPlayerIds() or {}
        if #playerIds > config.MaxPlayers then
            error("在线玩家数量超过家园数量")
        end
        runtime.Ready = true
        for _, playerId in ipairs(playerIds) do
            AssignPlayer(playerId, "startup_scan")
        end
        Log:PrintServerLog("[HomeService] 正式家园模块已就绪",
            "homeCount:", #runtime.HomeIds,
            "onlinePlayerCount:", #playerIds)
    end)
end

function HomeService:Stop(context)
    if context.Side ~= "Server" then
        return
    end
    local runtime = context.Services.HomeService
    if not runtime then
        return
    end
    if runtime.EnterCallback then System:UnregisterEvent(Events.ON_PLAYER_ENTER, runtime.EnterCallback) end
    if runtime.JoinCallback then System:UnregisterEvent(Events.ON_PLAYER_JOIN_MIDWAY, runtime.JoinCallback) end
    if runtime.ReconnectCallback then
        System:UnregisterEvent(Events.ON_PLAYER_RECONNECTED, runtime.ReconnectCallback)
    end
    if runtime.PreleaveCallback then
        System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    end
    runtime.PlayerToHome = {}
    runtime.HomeToPlayer = {}
    context.Services.HomeService = nil
end

return HomeService
