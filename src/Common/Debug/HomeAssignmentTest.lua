-- 临时测试模块：验证六个家园的顺序分配、双向归属、离开释放和重连重分配。
local HomeAssignmentTest = {
    Name = "HomeAssignmentTest",
    FeatureFlag = "HomeAssignmentTest",
    Dependencies = {},
}

local HOME_ROOT_IDS = {
    228,
    568,
    588,
    608,
    628,
    648,
}

local PURPOSE_PROPERTY_NAME = "作用"
local HOME_PURPOSE_VALUE = "家园"
local RETURN_POINT_PURPOSE_VALUE = "家园返回点"
local AVATAR_PURPOSE_VALUE = "玩家头像"
local AVATAR_PICTURE_SIZE = 1
local SERVER_RUNTIME_DATA_DELAY_SECONDS = 2
local CLIENT_AVATAR_START_DELAY_SECONDS = 3
local AVATAR_RETRY_INTERVAL_SECONDS = 0.5
local AVATAR_MAX_RETRY_COUNT = 10
local TELEPORT_VERIFY_DELAY_FRAMES = 2

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function CopyArray(source)
    local result = {}
    for index, value in ipairs(source) do
        result[index] = value
    end
    return result
end

local function FormatIds(ids)
    local values = {}
    for _, id in ipairs(ids) do
        values[#values + 1] = tostring(id)
    end
    return "[" .. table.concat(values, ",") .. "]"
end

local function FormatAssignments(runtime)
    local values = {}
    for _, homeId in ipairs(HOME_ROOT_IDS) do
        values[#values + 1] = tostring(homeId)
            .. "=" .. tostring(runtime.HomeToPlayer[homeId])
    end
    return "[" .. table.concat(values, ",") .. "]"
end

local function FormatPosition(position)
    if not position then
        return "nil"
    end
    return string.format("(%.3f, %.3f, %.3f)", position.X, position.Y, position.Z)
end

local function IsPositiveInteger(value)
    return type(value) == "number"
        and value > 0
        and value == math.floor(value)
end

local function ReadPurposeProperty(elementId)
    local ok, value = xpcall(function()
        return CustomProperty:GetCustomProperty(
            elementId,
            PURPOSE_PROPERTY_NAME,
            CustomProperty.PROPERTY_TYPE.String
        )
    end, Traceback)
    return ok, value
end

local function FindPurposeElements(homeId)
    local returnPointIds = {}
    local avatarElementIds = {}
    local visited = {}

    local function Visit(parentId)
        if visited[parentId] then
            error("家园子树存在重复或循环元件，homeId=" .. tostring(homeId)
                .. " elementId=" .. tostring(parentId))
        end
        visited[parentId] = true

        local childIds = Element:GetChildElementsFromElement(parentId)
        if childIds == nil then
            childIds = {}
        elseif type(childIds) ~= "table" then
            error("读取家园子元件未返回数组，homeId=" .. tostring(homeId)
                .. " parentId=" .. tostring(parentId))
        end

        for _, childId in ipairs(childIds) do
            local readSuccess, purposeValue = ReadPurposeProperty(childId)
            if not readSuccess then
                error("读取家园子元件作用属性失败，homeId=" .. tostring(homeId)
                    .. " elementId=" .. tostring(childId)
                    .. " error=" .. tostring(purposeValue))
            end
            if purposeValue == RETURN_POINT_PURPOSE_VALUE then
                returnPointIds[#returnPointIds + 1] = childId
            elseif purposeValue == AVATAR_PURPOSE_VALUE then
                avatarElementIds[#avatarElementIds + 1] = childId
            end
            Visit(childId)
        end
    end

    Visit(homeId)
    return returnPointIds, avatarElementIds
end

local function ValidatePlayerId(playerId, eventName)
    if not IsPositiveInteger(playerId) then
        error(eventName .. " 返回无效玩家ID: " .. tostring(playerId))
    end
end

local function IsOwner(runtime, playerId, homeId)
    return runtime.PlayerToHome[playerId] == homeId
        and runtime.HomeToPlayer[homeId] == playerId
end

local function AuditMappings(runtime, actionName)
    local seenHomes = {}
    for playerId, homeId in pairs(runtime.PlayerToHome) do
        if runtime.HomeToPlayer[homeId] ~= playerId then
            error(actionName .. " 双向映射不一致: playerId=" .. tostring(playerId)
                .. " homeId=" .. tostring(homeId)
                .. " reversePlayerId=" .. tostring(runtime.HomeToPlayer[homeId]))
        end
        if seenHomes[homeId] then
            error(actionName .. " 多名玩家占用同一家园: homeId=" .. tostring(homeId))
        end
        seenHomes[homeId] = playerId
    end

    for homeId, playerId in pairs(runtime.HomeToPlayer) do
        if runtime.PlayerToHome[playerId] ~= homeId then
            error(actionName .. " 反向映射不一致: homeId=" .. tostring(homeId)
                .. " playerId=" .. tostring(playerId)
                .. " forwardHomeId=" .. tostring(runtime.PlayerToHome[playerId]))
        end
    end
end

local function VerifyOwnership(runtime, playerId, homeId)
    local ownCheck = IsOwner(runtime, playerId, homeId)
    local otherHomesCheck = true
    local unexpectedHomeId = nil

    for _, candidateHomeId in ipairs(HOME_ROOT_IDS) do
        if candidateHomeId ~= homeId and IsOwner(runtime, playerId, candidateHomeId) then
            otherHomesCheck = false
            unexpectedHomeId = candidateHomeId
            break
        end
    end

    if not ownCheck or not otherHomesCheck then
        error("家园归属校验失败: playerId=" .. tostring(playerId)
            .. " assignedHomeId=" .. tostring(homeId)
            .. " ownCheck=" .. tostring(ownCheck)
            .. " otherHomesCheck=" .. tostring(otherHomesCheck)
            .. " unexpectedHomeId=" .. tostring(unexpectedHomeId))
    end

    return ownCheck, otherHomesCheck
end

local function FindFirstFreeHome(runtime)
    for _, homeId in ipairs(HOME_ROOT_IDS) do
        if runtime.HomeToPlayer[homeId] == nil then
            return homeId
        end
    end
    return nil
end

local function BuildAvatarMessage(runtime, playerId, homeId)
    local avatarElementId = runtime.AvatarElementByHome[homeId]
    if not IsPositiveInteger(avatarElementId) then
        error("家园缺少已校验的玩家头像显示器，homeId=" .. tostring(homeId))
    end
    return {
        playerId = playerId,
        homeId = homeId,
        avatarElementId = avatarElementId,
        pictureSize = AVATAR_PICTURE_SIZE,
    }
end

local function BroadcastAvatarAssignment(runtime, playerId, homeId)
    System:SendToAllClients(
        runtime.NetMsg.HomeAssignmentTestAvatar,
        BuildAvatarMessage(runtime, playerId, homeId)
    )
end

local function SendAvatarSnapshot(runtime, recipientPlayerId)
    for _, homeId in ipairs(HOME_ROOT_IDS) do
        local ownerPlayerId = runtime.HomeToPlayer[homeId]
        if ownerPlayerId then
            System:SendToClient(
                recipientPlayerId,
                runtime.NetMsg.HomeAssignmentTestAvatar,
                BuildAvatarMessage(runtime, ownerPlayerId, homeId)
            )
        end
    end
end

local function TeleportPlayerToHome(context, runtime, playerId, homeId, source)
    local returnPointId = runtime.ReturnPointByHome[homeId]
    if not IsPositiveInteger(returnPointId) then
        error("家园缺少已校验的返回点，homeId=" .. tostring(homeId))
    end

    local targetPosition = Element:GetPosition(returnPointId)
    if not targetPosition then
        error("无法读取家园返回点位置，homeId=" .. tostring(homeId)
            .. " returnPointId=" .. tostring(returnPointId))
    end

    Character:CharacterTeleport(playerId, targetPosition)
    Log:PrintServerLog("[HomeAssignmentTest] 已调用传送到家园返回点",
        "source:", source,
        "playerId:", playerId,
        "homeId:", homeId,
        "returnPointId:", returnPointId,
        "targetPosition:", FormatPosition(targetPosition),
        "verifyDelayFrames:", TELEPORT_VERIFY_DELAY_FRAMES)

    context.Timers:AddFrame(
        HomeAssignmentTest.Name,
        TELEPORT_VERIFY_DELAY_FRAMES,
        function()
            Log:PrintServerLog("[HomeAssignmentTest] 传送后延迟帧位置",
                "source:", source,
                "playerId:", playerId,
                "homeId:", homeId,
                "returnPointId:", returnPointId,
                "targetPosition:", FormatPosition(targetPosition),
                "actualPosition:", FormatPosition(Character:GetPosition(playerId)))
        end
    )
end

local function AssignPlayer(context, runtime, playerId, source)
    ValidatePlayerId(playerId, source)

    local existingHomeId = runtime.PlayerToHome[playerId]
    if existingHomeId then
        AuditMappings(runtime, source .. "_already_assigned")
        Log:PrintServerLog("[HomeAssignmentTest] 玩家已经拥有家园，本次重复进入事件不重新分配",
            "source:", source,
            "playerId:", playerId,
            "homeId:", existingHomeId,
            "assignments:", FormatAssignments(runtime))
        return existingHomeId
    end

    local homeId = FindFirstFreeHome(runtime)
    if not homeId then
        error("没有空闲家园；编辑器玩家上限应为6且不允许替代分配，playerId="
            .. tostring(playerId))
    end

    runtime.PlayerToHome[playerId] = homeId
    runtime.HomeToPlayer[homeId] = playerId
    AuditMappings(runtime, source .. "_assigned")
    local ownCheck, otherHomesCheck = VerifyOwnership(runtime, playerId, homeId)

    Log:PrintServerLog("[HomeAssignmentTest] 家园分配完成",
        "source:", source,
        "playerId:", playerId,
        "homeId:", homeId,
        "ownOwnershipCheck:", tostring(ownCheck),
        "otherHomesOwnershipCheck:", tostring(otherHomesCheck),
        "assignments:", FormatAssignments(runtime))

    TeleportPlayerToHome(context, runtime, playerId, homeId, source)
    BroadcastAvatarAssignment(runtime, playerId, homeId)
    return homeId
end

local function ReleasePlayer(runtime, playerId, source)
    ValidatePlayerId(playerId, source)

    local homeId = runtime.PlayerToHome[playerId]
    if not homeId then
        Log:PrintServerLog("[HomeAssignmentTest] 玩家没有家园映射，无需释放",
            "source:", source,
            "playerId:", playerId,
            "assignments:", FormatAssignments(runtime))
        return nil
    end

    runtime.PlayerToHome[playerId] = nil
    runtime.HomeToPlayer[homeId] = nil
    AuditMappings(runtime, source .. "_released")

    local ownershipAfterRelease = IsOwner(runtime, playerId, homeId)
    if ownershipAfterRelease then
        error("玩家离开后家园归属仍然存在: playerId=" .. tostring(playerId)
            .. " homeId=" .. tostring(homeId))
    end

    Log:PrintServerLog("[HomeAssignmentTest] 玩家家园已立即释放",
        "source:", source,
        "playerId:", playerId,
        "releasedHomeId:", homeId,
        "ownershipAfterRelease:", tostring(ownershipAfterRelease),
        "assignments:", FormatAssignments(runtime))
    return homeId
end

local function RunProtected(context, actionName, callback)
    local ok, errorMessage = xpcall(callback, Traceback)
    if not ok then
        context.Manager:FailModule(
            HomeAssignmentTest.Name,
            actionName .. "失败: " .. tostring(errorMessage)
        )
    end
end

function HomeAssignmentTest:ValidateConfig(context)
    if context.Side ~= "Server" then
        return true
    end

    local errors = {}
    local seen = {}
    if #HOME_ROOT_IDS ~= 6 then
        errors[#errors + 1] = "家园根元件数量必须为6，actual=" .. tostring(#HOME_ROOT_IDS)
    end

    for index, homeId in ipairs(HOME_ROOT_IDS) do
        if not IsPositiveInteger(homeId) then
            errors[#errors + 1] = "家园根元件ID必须是正整数，index=" .. tostring(index)
                .. " value=" .. tostring(homeId)
        elseif seen[homeId] then
            errors[#errors + 1] = "家园根元件ID重复: " .. tostring(homeId)
        else
            seen[homeId] = true
            local readSuccess, purposeValue = ReadPurposeProperty(homeId)
            if not readSuccess then
                errors[#errors + 1] = "读取家园作用属性失败，homeId=" .. tostring(homeId)
                    .. " error=" .. tostring(purposeValue)
            elseif purposeValue ~= HOME_PURPOSE_VALUE then
                errors[#errors + 1] = "家园作用属性不匹配，homeId=" .. tostring(homeId)
                    .. " expected=" .. HOME_PURPOSE_VALUE
                    .. " actual=" .. tostring(purposeValue)
            else
                local scanSuccess, returnPointIds, avatarElementIds = xpcall(function()
                    return FindPurposeElements(homeId)
                end, Traceback)
                if not scanSuccess then
                    errors[#errors + 1] = "扫描家园功能子元件失败，homeId="
                        .. tostring(homeId) .. " error=" .. tostring(returnPointIds)
                else
                    if #returnPointIds ~= 1 then
                        errors[#errors + 1] = "每个家园必须且只能有一个作用=家园返回点，homeId="
                            .. tostring(homeId) .. " actualCount=" .. tostring(#returnPointIds)
                    elseif not Element:GetPosition(returnPointIds[1]) then
                        errors[#errors + 1] = "无法读取家园返回点位置，homeId="
                            .. tostring(homeId) .. " returnPointId=" .. tostring(returnPointIds[1])
                    end
                    if #avatarElementIds ~= 1 then
                        errors[#errors + 1] = "每个家园必须且只能有一个作用=玩家头像，homeId="
                            .. tostring(homeId) .. " actualCount=" .. tostring(#avatarElementIds)
                    end
                end
            end
        end
    end

    return #errors == 0, errors
end

local function BuildHomeElementMaps()
    local returnPointByHome = {}
    local avatarElementByHome = {}
    for _, homeId in ipairs(HOME_ROOT_IDS) do
        local returnPointIds, avatarElementIds = FindPurposeElements(homeId)
        if #returnPointIds ~= 1 or #avatarElementIds ~= 1 then
            error("家园功能子元件数量与配置校验结果不一致，homeId=" .. tostring(homeId)
                .. " returnPointCount=" .. tostring(#returnPointIds)
                .. " avatarCount=" .. tostring(#avatarElementIds))
        end
        returnPointByHome[homeId] = returnPointIds[1]
        avatarElementByHome[homeId] = avatarElementIds[1]
    end
    return returnPointByHome, avatarElementByHome
end


local function StartServer(context)
    local returnPointByHome, avatarElementByHome = BuildHomeElementMaps()

    local runtime = {
        HomeIds = CopyArray(HOME_ROOT_IDS),
        PlayerToHome = {},
        HomeToPlayer = {},
        ReturnPointByHome = returnPointByHome,
        AvatarElementByHome = avatarElementByHome,
        NetMsg = context.NetMsg.Messages,
        EnterCallback = nil,
        JoinMidwayCallback = nil,
        ReconnectedCallback = nil,
        PreleaveCallback = nil,
        SnapshotRequestCallback = nil,
        RuntimeDataReady = false,
        StartupTimerId = nil,
    }
    context.Services.HomeAssignmentTest = runtime

    runtime.EnterCallback = function(playerId)
        if not runtime.RuntimeDataReady then
            Log:PrintServerLog("[HomeAssignmentTest] 启动延迟期间收到玩家进入，等待延迟结束后统一扫描",
                "playerId:", tostring(playerId),
                "startupDelaySeconds:", SERVER_RUNTIME_DATA_DELAY_SECONDS)
            return
        end
        RunProtected(context, "玩家进入分配", function()
            AssignPlayer(context, runtime, playerId, Events.ON_PLAYER_ENTER)
        end)
    end
    runtime.JoinMidwayCallback = function(playerId)
        if not runtime.RuntimeDataReady then
            Log:PrintServerLog("[HomeAssignmentTest] 启动延迟期间收到中途加入，等待延迟结束后统一扫描",
                "playerId:", tostring(playerId),
                "startupDelaySeconds:", SERVER_RUNTIME_DATA_DELAY_SECONDS)
            return
        end
        RunProtected(context, "中途加入分配", function()
            AssignPlayer(context, runtime, playerId, Events.ON_PLAYER_JOIN_MIDWAY)
        end)
    end
    runtime.ReconnectedCallback = function(playerId, levelId)
        if not runtime.RuntimeDataReady then
            Log:PrintServerLog("[HomeAssignmentTest] 启动延迟期间收到断线重连，等待延迟结束后统一扫描",
                "playerId:", tostring(playerId),
                "levelId:", tostring(levelId),
                "startupDelaySeconds:", SERVER_RUNTIME_DATA_DELAY_SECONDS)
            return
        end
        RunProtected(context, "断线重连重新分配", function()
            ValidatePlayerId(playerId, Events.ON_PLAYER_RECONNECTED)
            local previousHomeId = ReleasePlayer(
                runtime,
                playerId,
                Events.ON_PLAYER_RECONNECTED .. "_release"
            )
            local newHomeId = AssignPlayer(
                context,
                runtime,
                playerId,
                Events.ON_PLAYER_RECONNECTED .. "_assign"
            )
            Log:PrintServerLog("[HomeAssignmentTest] 断线重连已重新分配",
                "playerId:", playerId,
                "levelId:", tostring(levelId),
                "previousHomeId:", tostring(previousHomeId),
                "newHomeId:", newHomeId,
                "assignments:", FormatAssignments(runtime))
        end)
    end
    runtime.PreleaveCallback = function(playerId)
        if not runtime.RuntimeDataReady then
            Log:PrintServerLog("[HomeAssignmentTest] 启动延迟期间玩家离开，当前尚无家园映射",
                "playerId:", tostring(playerId),
                "startupDelaySeconds:", SERVER_RUNTIME_DATA_DELAY_SECONDS)
            return
        end
        RunProtected(context, "玩家离开释放", function()
            ReleasePlayer(runtime, playerId, Events.ON_PLAYER_PRELEAVE)
        end)
    end
    runtime.SnapshotRequestCallback = function(_, message, playerId)
        if type(message) ~= "table" or not IsPositiveInteger(playerId) then
            Log:PrintWarning("[HomeAssignmentTest] 拒绝无效头像快照请求",
                "playerId:", tostring(playerId),
                "messageType:", type(message))
            return
        end
        if not runtime.RuntimeDataReady then
            Log:PrintWarning("[HomeAssignmentTest] 启动延迟尚未结束，拒绝头像快照请求",
                "playerId:", tostring(playerId),
                "startupDelaySeconds:", SERVER_RUNTIME_DATA_DELAY_SECONDS)
            return
        end
        RunProtected(context, "发送头像快照", function()
            SendAvatarSnapshot(runtime, playerId)
            Log:PrintServerLog("[HomeAssignmentTest] 已向客户端发送当前家园头像快照",
                "playerId:", playerId,
                "assignments:", FormatAssignments(runtime))
        end)
    end

    System:RegisterEvent(Events.ON_PLAYER_ENTER, runtime.EnterCallback)
    System:RegisterEvent(Events.ON_PLAYER_JOIN_MIDWAY, runtime.JoinMidwayCallback)
    System:RegisterEvent(Events.ON_PLAYER_RECONNECTED, runtime.ReconnectedCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    System:BindNotify(
        runtime.NetMsg.HomeAssignmentTestSnapshotRequest,
        runtime.SnapshotRequestCallback
    )

    Log:PrintServerLog("[HomeAssignmentTest] 服务端家园分配测试已启用，等待启动延迟",
        "homeIds:", FormatIds(HOME_ROOT_IDS),
        "avatarPictureSize:", AVATAR_PICTURE_SIZE,
        "startupDelaySeconds:", SERVER_RUNTIME_DATA_DELAY_SECONDS)
    runtime.StartupTimerId = context.Timers:AddTimer(
        HomeAssignmentTest.Name,
        SERVER_RUNTIME_DATA_DELAY_SECONDS,
        function()
            runtime.StartupTimerId = nil
            local onlinePlayerIds = Character:GetAllPlayerIds()
            if type(onlinePlayerIds) ~= "table" then
                error("Character:GetAllPlayerIds() 未返回玩家ID数组")
            end
            if #onlinePlayerIds > #HOME_ROOT_IDS then
                error("当前在线玩家数量超过6，不执行替代分配，onlinePlayerIds="
                    .. FormatIds(onlinePlayerIds))
            end

            runtime.RuntimeDataReady = true
            Log:PrintServerLog("[HomeAssignmentTest] 服务端启动延迟结束，开始扫描在线玩家",
                "startupDelaySeconds:", SERVER_RUNTIME_DATA_DELAY_SECONDS,
                "onlinePlayerIds:", FormatIds(onlinePlayerIds))
            for _, playerId in ipairs(onlinePlayerIds) do
                AssignPlayer(context, runtime, playerId, "startup_online_scan")
            end
        end
    )
end

local function IsKnownHomeId(homeId)
    for _, candidateHomeId in ipairs(HOME_ROOT_IDS) do
        if candidateHomeId == homeId then
            return true
        end
    end
    return false
end

local function StartClient(context)
    local runtime = {
        NetMsg = context.NetMsg.Messages,
        AvatarCallback = nil,
        AvatarNotifyBound = false,
        AvatarAttemptByHome = {},
    }
    context.Services.HomeAssignmentTest = runtime

    local trySetAvatar
    trySetAvatar = function(state)
        if runtime.AvatarAttemptByHome[state.HomeId] ~= state then
            return
        end

        state.TotalAttemptCount = state.TotalAttemptCount + 1
        local imageId, isCustom = Chat:GetCustomHeadIconImage(state.PlayerId)
        Log:PrintLog("[HomeAssignmentTest] 客户端读取家园玩家头像",
            "playerId:", state.PlayerId,
            "homeId:", state.HomeId,
            "avatarElementId:", state.AvatarElementId,
            "totalAttemptCount:", state.TotalAttemptCount,
            "retryCount:", state.RetryCount,
            "imageId:", tostring(imageId),
            "isCustom:", tostring(isCustom))

        if imageId == 0 then
            if state.RetryCount >= AVATAR_MAX_RETRY_COUNT then
                runtime.AvatarAttemptByHome[state.HomeId] = nil
                Log:PrintError("[HomeAssignmentTest] 玩家头像重试耗尽，本次不设置图片",
                    "playerId:", state.PlayerId,
                    "homeId:", state.HomeId,
                    "avatarElementId:", state.AvatarElementId,
                    "initialDelaySeconds:", CLIENT_AVATAR_START_DELAY_SECONDS,
                    "retryIntervalSeconds:", AVATAR_RETRY_INTERVAL_SECONDS,
                    "retryCount:", state.RetryCount,
                    "totalAttemptCount:", state.TotalAttemptCount,
                    "imageId:", tostring(imageId),
                    "isCustom:", tostring(isCustom))
                return
            end

            state.RetryCount = state.RetryCount + 1
            Log:PrintWarning("[HomeAssignmentTest] 玩家头像尚未就绪，等待后重试",
                "playerId:", state.PlayerId,
                "homeId:", state.HomeId,
                "nextRetryCount:", state.RetryCount,
                "maxRetryCount:", AVATAR_MAX_RETRY_COUNT,
                "retryIntervalSeconds:", AVATAR_RETRY_INTERVAL_SECONDS)
            context.Timers:AddTimer(
                HomeAssignmentTest.Name,
                AVATAR_RETRY_INTERVAL_SECONDS,
                function()
                    trySetAvatar(state)
                end
            )
            return
        end

        if not IsPositiveInteger(imageId) or type(isCustom) ~= "boolean" then
            error("玩家头像返回值无效，playerId="
                .. tostring(state.PlayerId)
                .. " imageId=" .. tostring(imageId)
                .. " isCustom=" .. tostring(isCustom))
        end

        FuncElement:SetPictureBoardImage(
            state.AvatarElementId,
            imageId,
            AVATAR_PICTURE_SIZE,
            isCustom
        )
        runtime.AvatarAttemptByHome[state.HomeId] = nil
        Log:PrintLog("[HomeAssignmentTest] 客户端已设置家园玩家头像",
            "playerId:", state.PlayerId,
            "homeId:", state.HomeId,
            "avatarElementId:", state.AvatarElementId,
            "imageId:", imageId,
            "isCustom:", tostring(isCustom),
            "pictureSize:", AVATAR_PICTURE_SIZE,
            "retryCount:", state.RetryCount,
            "totalAttemptCount:", state.TotalAttemptCount)
    end

    runtime.AvatarCallback = function(_, message)
        RunProtected(context, "客户端设置家园头像", function()
            if type(message) ~= "table" then
                error("头像同步消息必须是table，actual=" .. type(message))
            end

            local playerId = message.playerId
            local homeId = message.homeId
            local avatarElementId = message.avatarElementId
            local pictureSize = message.pictureSize
            if not IsPositiveInteger(playerId) then
                error("头像同步消息玩家ID无效: " .. tostring(playerId))
            end
            if not IsPositiveInteger(homeId) or not IsKnownHomeId(homeId) then
                error("头像同步消息家园ID无效: " .. tostring(homeId))
            end
            if not IsPositiveInteger(avatarElementId) then
                error("头像同步消息图标显示器ID无效: " .. tostring(avatarElementId))
            end
            if pictureSize ~= AVATAR_PICTURE_SIZE then
                error("头像同步消息图片大小不匹配: " .. tostring(pictureSize))
            end

            local state = {
                PlayerId = playerId,
                HomeId = homeId,
                AvatarElementId = avatarElementId,
                RetryCount = 0,
                TotalAttemptCount = 0,
            }
            runtime.AvatarAttemptByHome[homeId] = state
            trySetAvatar(state)
        end)
    end

    context.Timers:AddTimer(
        HomeAssignmentTest.Name,
        CLIENT_AVATAR_START_DELAY_SECONDS,
        function()
            System:BindNotify(
                runtime.NetMsg.HomeAssignmentTestAvatar,
                runtime.AvatarCallback
            )
            runtime.AvatarNotifyBound = true
            System:SendToServer(
                runtime.NetMsg.HomeAssignmentTestSnapshotRequest,
                {}
            )
            Log:PrintLog("[HomeAssignmentTest] 客户端启动延迟结束，已请求家园头像快照",
                "startDelaySeconds:", CLIENT_AVATAR_START_DELAY_SECONDS,
                "pictureSize:", AVATAR_PICTURE_SIZE,
                "retryIntervalSeconds:", AVATAR_RETRY_INTERVAL_SECONDS,
                "maxRetryCount:", AVATAR_MAX_RETRY_COUNT)
        end
    )
    Log:PrintLog("[HomeAssignmentTest] 客户端头像表现测试已启用，等待启动延迟",
        "startDelaySeconds:", CLIENT_AVATAR_START_DELAY_SECONDS,
        "pictureSize:", AVATAR_PICTURE_SIZE)
end


function HomeAssignmentTest:Start(context)
    if context.Side == "Server" then
        StartServer(context)
    else
        StartClient(context)
    end
end


local function StopServer(context, runtime)
    if runtime.EnterCallback then
        System:UnregisterEvent(Events.ON_PLAYER_ENTER, runtime.EnterCallback)
    end
    if runtime.JoinMidwayCallback then
        System:UnregisterEvent(Events.ON_PLAYER_JOIN_MIDWAY, runtime.JoinMidwayCallback)
    end
    if runtime.ReconnectedCallback then
        System:UnregisterEvent(Events.ON_PLAYER_RECONNECTED, runtime.ReconnectedCallback)
    end
    if runtime.PreleaveCallback then
        System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    end
    if runtime.SnapshotRequestCallback then
        System:UnbindNotify(
            runtime.NetMsg.HomeAssignmentTestSnapshotRequest,
            runtime.SnapshotRequestCallback
        )
    end

    Log:PrintServerLog("[HomeAssignmentTest] 测试停止，运行时家园映射已清除",
        "assignmentsBeforeClear:", FormatAssignments(runtime))
    runtime.PlayerToHome = {}
    runtime.HomeToPlayer = {}
end

local function StopClient(runtime)
    if runtime.AvatarNotifyBound and runtime.AvatarCallback then
        System:UnbindNotify(
            runtime.NetMsg.HomeAssignmentTestAvatar,
            runtime.AvatarCallback
        )
    end
    runtime.AvatarAttemptByHome = {}
end


function HomeAssignmentTest:Stop(context)
    local runtime = context.Services.HomeAssignmentTest
    if not runtime then
        return
    end

    if context.Side == "Server" then
        StopServer(context, runtime)
    else
        StopClient(runtime)
    end
    context.Services.HomeAssignmentTest = nil
end

return HomeAssignmentTest
