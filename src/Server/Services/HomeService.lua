local GameConfig = require "Common.Config.GameConfig"
local FeatureFlags = require "Common.Config.FeatureFlags"

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
    if config.MidJoinTeleportDelaySeconds ~= 4 then
        errors[#errors + 1] = "MidJoinTeleportDelaySeconds 必须为已确认的4秒"
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
        PlacementSlotsByElement = {},
        EggResourcesByHome = {},
        EggResourcesReady = false,
        UpgradeResourcesByHome = {},
        UpgradeResourcesReady = false,
        TreadmillResourcesByHome = {},
        TreadmillResourcesReady = false,
        NameElementByHome = {},
        NameStateByHome = {}, -- 最后有效显示记录；离开保留，不用于归属校验。
        PlayerToHome = {},
        HomeToPlayer = {},
        PendingTeleportByPlayer = {},
        TeleportOperationByPlayer = {},
        EnterCallback = nil,
        JoinCallback = nil,
        ReconnectCallback = nil,
        PreleaveCallback = nil,
    }

    function runtime:GetPlayerHome(playerId)
        return self.PlayerToHome[playerId]
    end
    function runtime:GetUpgradeResources(homeId)
        local record = self.UpgradeResourcesByHome[homeId]
        if not self.Ready or not record then return nil end
        return { homeId = homeId, upgradeElementId = record.upgradeElementId, levelElementId = record.levelElementId }
    end

    function runtime:GetTreadmillResources(homeId)
        local record = self.TreadmillResourcesByHome[homeId]
        if not self.Ready or not self.TreadmillResourcesReady or not record then return nil end
        return { homeId = homeId, triggerId = record.triggerId, positionId = record.positionId }
    end

    function runtime:IsOwner(playerId, homeId)
        return self.PlayerToHome[playerId] == homeId
            and self.HomeToPlayer[homeId] == playerId
    end

    function runtime:GetReturnPoint(playerId)
        local homeId = self.PlayerToHome[playerId]
        return homeId and self.ReturnPointByHome[homeId] or nil
    end

    -- 只返回独立索引记录；占位及鸡资产由 PlacementService 管理。
    function runtime:GetPlacementSlot(playerId, elementId)
        local slot = self.PlacementSlotsByElement[elementId]
        if not self.Ready or not slot or not self:IsOwner(playerId, slot.homeId) then
            return nil
        end
        return { homeId = slot.homeId, slotIndex = slot.slotIndex, elementId = elementId }
    end

    -- 仅提供独立资源记录；鸡、蛋及容量占用不归家园模块管理。
    function runtime:GetEggResources(homeId)
        local record = self.EggResourcesByHome[homeId]
        if not self.Ready or not record then return nil end
        return { homeId = homeId, eggPositionElementId = record.eggPositionElementId,
            chickenElementId = record.chickenElementId, eggElementId = record.eggElementId }
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

    local function CancelTeleport(playerId, reason)
        local operation = runtime.TeleportOperationByPlayer[playerId]
        if not operation then return end
        operation.invalid = true
        runtime.TeleportOperationByPlayer[playerId] = nil
        runtime.PendingTeleportByPlayer[playerId] = nil
        if operation.timerId then
            context.Timers:Remove(operation.timerId)
            operation.timerId = nil
        end
    end
    runtime.CancelTeleport = CancelTeleport

    -- 根元件昵称仅供显示读取；独立于跑步机/名称显示器，权限仍来自双向映射。
    local function WriteHomeOwner(playerId, homeId, clear)
        local function Current()
            if context.Services.HomeService ~= runtime or not runtime.Ready or not IsPositiveInteger(homeId) then return false end
            if clear then return runtime.HomeToPlayer[homeId] == nil and runtime.PlayerToHome[playerId] ~= homeId end
            return runtime:IsOwner(playerId, homeId)
        end
        if not Current() then return end
        local ok, err = xpcall(function()
            local propertyName = config.OwnerNameProperty
            if type(propertyName) ~= "string" or propertyName == "" then error("家园归属昵称属性名无效") end
            local name = ""
            if not clear then
                name = Chat:GetCustomName(playerId)
                if type(name) ~= "string" or name == "" then error("家园主人昵称读取无效") end
            end
            if not Current() then return end
            CustomProperty:SetCustomProperty(homeId, propertyName, CustomProperty.PROPERTY_TYPE.String, name)
        end, Traceback)
        if not ok then
            Log:PrintError("[HomeOwner] 昵称标记写入失败，不重试", "playerId:", playerId,
                "homeId:", homeId, "error:", tostring(err))
        end
    end

    -- 昵称仅是触发盒标记；归属始终读取现有双向映射，不建立第二份权限状态。
    local function WriteTreadmillOwner(playerId, homeId, clear)
        local function Current()
            if context.Services.HomeService ~= runtime or not runtime.Ready or not runtime.TreadmillResourcesReady
                or not IsPositiveInteger(homeId) then return false end
            if clear then
                return runtime.HomeToPlayer[homeId] == nil
                    and (playerId == nil or runtime.PlayerToHome[playerId] ~= homeId)
            end
            return runtime:IsOwner(playerId, homeId)
        end
        if not Current() then return end -- 开局索引未就绪时，在索引完成后按当前归属补写。
        local resources = runtime.TreadmillResourcesByHome[homeId]
        local triggerId = resources and resources.triggerId
        local ok, err = xpcall(function()
            if not IsPositiveInteger(triggerId) then error("跑步机触发盒索引不可用") end
            local propertyName = GameConfig.Treadmill.OwnerNameProperty
            if type(propertyName) ~= "string" or propertyName == "" then error("跑步机归属昵称属性名无效") end
            local name = ""
            if not clear then
                name = Chat:GetCustomName(playerId)
                if type(name) ~= "string" or name == "" then error("跑步机主人昵称读取无效") end
            end
            -- 昵称读取期间归属可能变化；写入前再次拒绝旧模块、旧主人和旧资源。
            if not Current() or runtime.TreadmillResourcesByHome[homeId] ~= resources then return end
            CustomProperty:SetCustomProperty(triggerId, propertyName, CustomProperty.PROPERTY_TYPE.String, name)
        end, Traceback)
        if not ok then
            Log:PrintError("[TreadmillOwner] 昵称标记写入失败，不重试", "playerId:", playerId,
                "homeId:", homeId, "triggerId:", triggerId, "error:", tostring(err))
        end
    end

    local function ReleasePlayer(playerId, source)
        CancelTeleport(playerId, source)
        local homeId = runtime.PlayerToHome[playerId]
        if not homeId then
            return nil
        end
        runtime.PlayerToHome[playerId] = nil
        runtime.HomeToPlayer[homeId] = nil
        AuditMappings(source)
        WriteHomeOwner(playerId, homeId, true)
        WriteTreadmillOwner(playerId, homeId, true) -- 先清空再发布释放，避免覆盖事件中分配的新主人。
        context.Events:Publish("HomeReleased", {
            playerId = playerId,
            homeId = homeId,
            source = source,
        })
        return homeId
    end

    local function RefreshName(playerId, homeId)
        local elementId = runtime.NameElementByHome[homeId]
        if not elementId then return end
        local ok, errorMessage = xpcall(function()
            local name = Chat:GetCustomName(playerId)
            if type(name) ~= "string" or name == "" then
                error("昵称读取无效，value=" .. tostring(name) .. " type=" .. type(name))
            end
            local previous = runtime.NameStateByHome[homeId]
            local state = { homeId = homeId, elementId = elementId, playerId = playerId,
                name = name, version = previous and previous.version + 1 or 1 }
            runtime.NameStateByHome[homeId] = state
            System:SendToAllClients(context.NetMsg.Messages.HomeNameState, state)
            Log:PrintServerLog("[HomeName] 名称更新", "homeId:", homeId,
                "elementId:", elementId, "playerId:", playerId, "version:", state.version, "name:", name)
        end, Traceback)
        if not ok then
            Log:PrintError("[HomeName] 名称更新失败，保留最后有效显示", "homeId:", homeId,
                "playerId:", playerId, "error:", tostring(errorMessage))
        end
    end

    local function TeleportOperationValid(operation)
        return context.Services.HomeService == runtime and runtime.Ready and not operation.invalid
            and runtime.TeleportOperationByPlayer[operation.playerId] == operation
            and runtime:IsOwner(operation.playerId, operation.homeId)
    end

    local function TeleportPlayer(operation)
        if not TeleportOperationValid(operation) or operation.called then return end
        local playerId, position = operation.playerId, operation.position
        operation.called = true
        Character:CharacterTeleport(playerId, position)
    end

    local function AssignPlayer(playerId, source)
        if not IsPositiveInteger(playerId) then
            error("家园分配收到无效玩家ID: " .. tostring(playerId))
        end
        if runtime.PlayerToHome[playerId] then
            WriteHomeOwner(playerId, runtime.PlayerToHome[playerId], false)
            RefreshName(playerId, runtime.PlayerToHome[playerId])
            WriteTreadmillOwner(playerId, runtime.PlayerToHome[playerId], false)
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
        local operation = { playerId = playerId, homeId = homeId, returnPointId = returnPointId,
            position = position, source = source }
        runtime.TeleportOperationByPlayer[playerId] = operation
        if source == Events.ON_PLAYER_JOIN_MIDWAY then
            runtime.PendingTeleportByPlayer[playerId] = operation
            operation.timerId = context.Timers:AddTimer(HomeService.Name, config.MidJoinTeleportDelaySeconds, function()
                local ok, errorMessage = xpcall(function()
                    if not TeleportOperationValid(operation)
                        or runtime.PendingTeleportByPlayer[playerId] ~= operation then
                        return
                    end
                    operation.timerId = nil
                    local online = false
                    for _, onlineId in ipairs(Character:GetAllPlayerIds() or {}) do
                        if onlineId == playerId then online = true; break end
                    end
                    if not online then
                        CancelTeleport(playerId, "player_not_online")
                        return
                    end
                    runtime.PendingTeleportByPlayer[playerId] = nil
                    TeleportPlayer(operation)
                end, Traceback)
                if not ok then context.Manager:FailModule(HomeService.Name, "中途加入延迟传送: " .. tostring(errorMessage)) end
            end)
        else
            TeleportPlayer(operation)
        end
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
        WriteHomeOwner(playerId, homeId, false)
        RefreshName(playerId, homeId)
        WriteTreadmillOwner(playerId, homeId, false)
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
    runtime.JoinCallback = function(playerId, levelId)
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
    runtime.NameSnapshotCallback = function(_, _, playerId)
        if context.Services.HomeService ~= runtime or not runtime.Ready or not IsPositiveInteger(playerId) then return end
        local ok, errorMessage = xpcall(function()
            for _, homeId in ipairs(runtime.HomeIds) do
                local state = runtime.NameStateByHome[homeId]
                if state then System:SendToClient(playerId, context.NetMsg.Messages.HomeNameState, state) end
            end
        end, Traceback)
        if not ok then Log:PrintError("[HomeName] 快照发送失败", tostring(errorMessage)) end
    end
    System:BindNotify(context.NetMsg.Messages.HomeNameSnapshotRequest, runtime.NameSnapshotCallback)

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

        -- 每家园独立处理名称索引；失败不停止归属/传送，也不影响其他家园名称。
        for _, homeId in ipairs(runtime.HomeIds) do
            local ok, elementIdOrError = xpcall(function()
                local matches, visited = {}, {}
                local function Visit(parentId)
                    if visited[parentId] then error("名称显示器树重复或循环") end
                    visited[parentId] = true
                    for _, childId in ipairs(Element:GetChildElementsFromElement(parentId) or {}) do
                        if ReadPurpose(childId, config.PurposeProperty) == config.NamePurpose then
                            matches[#matches + 1] = childId
                        end
                        Visit(childId)
                    end
                end
                Visit(homeId)
                if #matches ~= 1 then
                    error("每家园必须且只能有一个作用=玩家名称显示器，actual=" .. tostring(#matches))
                end
                return matches[1]
            end, Traceback)
            if ok then
                runtime.NameElementByHome[homeId] = elementIdOrError
                local playerId = runtime.HomeToPlayer[homeId]
                if playerId then RefreshName(playerId, homeId) end
            else
                Log:PrintError("[HomeName] 名称索引失败，仅跳过该家园名称", "homeId:", homeId,
                    "error:", tostring(elementIdOrError))
            end
        end

        -- 新放置索引独立失败；不阻断已建立的家园归属、返回点与传送。
        if FeatureFlags.Values.Placement == true then
            local placementSlots = {}
            local ok, errorMessage = xpcall(function()
                for _, homeId in ipairs(runtime.HomeIds) do
                    local seenSlots, visited = {}, {}
                    local function Visit(parentId)
                        if visited[parentId] then error("家园放置位树重复或循环") end
                        visited[parentId] = true
                        for _, childId in ipairs(Element:GetChildElementsFromElement(parentId) or {}) do
                            local readOk, slotIndex = pcall(function()
                                return CustomProperty:GetCustomProperty(
                                    childId, config.PlacementSlotProperty, CustomProperty.PROPERTY_TYPE.Number
                                )
                            end)
                            if not readOk then
                                error("放置位属性读取失败，homeId=" .. tostring(homeId)
                                    .. " elementId=" .. tostring(childId) .. " error=" .. tostring(slotIndex))
                            end
                            if slotIndex ~= nil and slotIndex ~= 0 then
                                if not IsPositiveInteger(slotIndex) or slotIndex == math.huge or seenSlots[slotIndex] then
                                    error("家园放置位编号无效或重复，homeId=" .. tostring(homeId)
                                        .. " elementId=" .. tostring(childId)
                                        .. " value=" .. tostring(slotIndex) .. " type=" .. type(slotIndex))
                                end
                                seenSlots[slotIndex] = true
                                placementSlots[childId] = {
                                    homeId = homeId, slotIndex = slotIndex,
                                }
                            end
                            Visit(childId)
                        end
                    end
                    Visit(homeId)
                end
            end, Traceback)
            if ok then
                runtime.PlacementSlotsByElement = placementSlots
                Log:PrintServerLog("[HomeService] 放置索引已就绪", "homeCount:", #runtime.HomeIds)
            else
                runtime.PlacementSlotsByElement = {}
                Log:PrintError("[HomeService] 放置索引初始化失败，家园分配保留；停止放置",
                    tostring(errorMessage))
                context.Manager:FailModule("PlacementService", "放置索引初始化失败: " .. tostring(errorMessage))
            end
        end
        -- 原启动业务完成后独立索引；不写鸡/蛋业务状态。
        if FeatureFlags.Values.EggProduction == true then
            for _, homeId in ipairs(runtime.HomeIds) do
                local record = {}
                local ok, errorMessage = xpcall(function()
                    local matches, visited = {}, {}
                    for _, purpose in ipairs({ config.EggPositionPurpose, config.ChickenCountPurpose,
                        config.EggCountPurpose }) do matches[purpose] = {} end
                    local function Visit(parentId)
                        if visited[parentId] then error("蛋资源元件树重复或循环") end
                        visited[parentId] = true
                        for _, childId in ipairs(Element:GetChildElementsFromElement(parentId) or {}) do
                            local purpose = ReadPurpose(childId, config.PurposeProperty)
                            if matches[purpose] then matches[purpose][#matches[purpose] + 1] = childId end
                            Visit(childId)
                        end
                    end
                    Visit(homeId)
                    for _, entry in ipairs({
                        { purpose = config.EggPositionPurpose, field = "eggPositionElementId" },
                        { purpose = config.ChickenCountPurpose, field = "chickenElementId" },
                        { purpose = config.EggCountPurpose, field = "eggElementId" },
                    }) do
                        local ids = matches[entry.purpose]
                        if #ids == 1 then record[entry.field] = ids[1]
                        else
                            Log:PrintError("[HomeEggResources] 资源缺失或重复，仅跳过对应功能",
                                "homeId:", homeId, "purpose:", entry.purpose, "count:", #ids)
                        end
                    end
                end, Traceback)
                if not ok then
                    Log:PrintError("[HomeEggResources] 本家园资源读取失败，归属与放置保留",
                        "homeId:", homeId, "error:", tostring(errorMessage))
                end
                runtime.EggResourcesByHome[homeId] = record
            end
            runtime.EggResourcesReady = true
            context.Events:Publish("HomeEggResourcesReady")
        end
        -- 在原家园分配/传送链完成后独立扫描；缺失只影响该家园对应升级资源。
        if FeatureFlags.Values.HomeUpgrade == true then
            for _, homeId in ipairs(runtime.HomeIds) do
                local record = {}
                local ok, err = pcall(function()
                    local matches, visited = {}, {}
                    local upgrade = GameConfig.HomeUpgrade
                    matches[upgrade.InteractionPurpose], matches[upgrade.LevelPurpose] = {}, {}
                    local function Visit(parentId)
                        if visited[parentId] then error("升级资源元件树重复或循环") end
                        visited[parentId] = true
                        for _, id in ipairs(Element:GetChildElementsFromElement(parentId) or {}) do
                            local purpose = ReadPurpose(id, config.PurposeProperty)
                            if matches[purpose] then matches[purpose][#matches[purpose] + 1] = id end
                            Visit(id)
                        end
                    end
                    Visit(homeId)
                    for _, entry in ipairs({ { upgrade.InteractionPurpose, "upgradeElementId" },
                        { upgrade.LevelPurpose, "levelElementId" } }) do
                        local ids = matches[entry[1]]
                        if #ids == 1 then record[entry[2]] = ids[1]
                        else Log:PrintError("[HomeUpgrade] 资源缺失或重复，仅跳过对应功能", "homeId:", homeId,
                            "purpose:", entry[1], "count:", #ids) end
                    end
                end)
                if not ok then Log:PrintError("[HomeUpgrade] 资源扫描失败，家园分配保留", "homeId:", homeId, "error:", tostring(err)) end
                runtime.UpgradeResourcesByHome[homeId] = record
            end
            runtime.UpgradeResourcesReady = true
            context.Events:Publish("HomeUpgradeResourcesReady")
        end
        -- 独立跑步机静态索引；失败只关闭对应家园跑步机，不阻断分配/传送。
        if FeatureFlags.Values.Treadmill == true then
            for _, homeId in ipairs(runtime.HomeIds) do
                local record = {}
                local ok, err = pcall(function()
                    local treadmill = GameConfig.Treadmill
                    local matches = { [treadmill.TrainingPurpose] = {}, [treadmill.PositionPurpose] = {} }
                    local visited = {}
                    local function Visit(parentId)
                        if visited[parentId] then error("跑步机资源树重复或循环") end
                        visited[parentId] = true
                        for _, id in ipairs(Element:GetChildElementsFromElement(parentId) or {}) do
                            local purpose = ReadPurpose(id, config.PurposeProperty)
                            if matches[purpose] then table.insert(matches[purpose], id) end
                            Visit(id)
                        end
                    end
                    Visit(homeId)
                    for _, entry in ipairs({ { treadmill.TrainingPurpose, "triggerId" },
                        { treadmill.PositionPurpose, "positionId" } }) do
                        local ids = matches[entry[1]]
                        if #ids ~= 1 then error("跑步机资源缺失或重复 purpose=" .. entry[1] .. " count=" .. #ids) end
                        record[entry[2]] = ids[1]
                    end
                end)
                if ok then runtime.TreadmillResourcesByHome[homeId] = record
                else Log:PrintError("[Treadmill] 家园资源扫描失败", "homeId:", homeId, "error:", tostring(err)) end
            end
            runtime.TreadmillResourcesReady = true
            for _, homeId in ipairs(runtime.HomeIds) do
                local ownerId = runtime.HomeToPlayer[homeId]
                WriteTreadmillOwner(ownerId, homeId, ownerId == nil)
            end
            context.Events:Publish("HomeTreadmillResourcesReady")
        end
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
    runtime.Ready = false
    runtime.EggResourcesReady = false
    runtime.TreadmillResourcesReady = false
    runtime.TreadmillResourcesByHome = {}
    runtime.UpgradeResourcesReady = false
    runtime.UpgradeResourcesByHome = {}
    runtime.EggResourcesByHome = {}
    local teleportPlayerIds = {}
    for playerId in pairs(runtime.TeleportOperationByPlayer) do teleportPlayerIds[#teleportPlayerIds + 1] = playerId end
    for _, playerId in ipairs(teleportPlayerIds) do runtime.CancelTeleport(playerId, "home_stop") end
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
    runtime.PlacementSlotsByElement = {}
    System:UnbindNotify(context.NetMsg.Messages.HomeNameSnapshotRequest, runtime.NameSnapshotCallback)
    runtime.NameElementByHome = {}
    runtime.NameStateByHome = {}
    context.Services.HomeService = nil
end

return HomeService
