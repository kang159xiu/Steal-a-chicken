local GameConfig = require "Common.Config.GameConfig"

local TheftService = {
    Name = "TheftService",
    FeatureFlag = "Theft",
    Dependencies = { "ZoneService", "InventoryService" },
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

local function CopyPosition(value)
    return Engine.Vector(value.X, value.Y, value.Z)
end

local function HorizontalDistance(first, second)
    local dx = first.X - second.X
    local dy = first.Y - second.Y
    return math.sqrt(dx * dx + dy * dy)
end

local function ReadPurpose(elementId)
    local ok, value = pcall(function()
        return CustomProperty:GetCustomProperty(
            elementId,
            GameConfig.Theft.PurposeProperty,
            CustomProperty.PROPERTY_TYPE.String
        )
    end)
    return ok, value
end

local function ChooseChickenType(pool)
    local totalWeight = 0
    for _, entry in ipairs(pool) do totalWeight = totalWeight + entry.Weight end
    local value = math.random() * totalWeight
    local cumulative = 0
    for _, entry in ipairs(pool) do
        cumulative = cumulative + entry.Weight
        if value <= cumulative then return entry.ChickenType end
    end
    return pool[#pool].ChickenType
end

local function ChooseSpawnPoints(allSpawnPoints, count)
    local candidates = {}
    for index, spawnPointId in ipairs(allSpawnPoints) do
        candidates[index] = spawnPointId
    end
    local selected = {}
    for index = 1, count do
        local candidateIndex = math.random(1, #candidates)
        selected[index] = table.remove(candidates, candidateIndex)
    end
    return selected
end

local function FindSpawnPoints(region)
    local results = {}
    local visited = {}
    local function Visit(parentId)
        if visited[parentId] then
            error("区域元件树存在重复或循环，regionId=" .. tostring(region.RegionId))
        end
        visited[parentId] = true
        local children = Element:GetChildElementsFromElement(parentId) or {}
        for _, childId in ipairs(children) do
            local ok, purpose = ReadPurpose(childId)
            if not ok then
                error("读取区域子元件作用失败，elementId=" .. tostring(childId)
                    .. " error=" .. tostring(purpose))
            end
            if purpose == GameConfig.Theft.SpawnPointPurpose then
                results[#results + 1] = childId
            end
            Visit(childId)
        end
    end
    Visit(region.RegionRootId)
    return results
end

function TheftService:ValidateConfig(context)
    if context.Side ~= "Server" then return true end
    local errors = {}
    if type(GameConfig.Theft.InteractionEnabled) ~= "boolean" then
        errors[#errors + 1] = "Theft.InteractionEnabled 必须是 boolean"
    end
    local regionSpawnInterval = GameConfig.Theft.RegionSpawnIntervalSeconds
    if type(regionSpawnInterval) ~= "number" or regionSpawnInterval ~= regionSpawnInterval
        or regionSpawnInterval <= 0 or regionSpawnInterval == math.huge then
        errors[#errors + 1] = "Theft.RegionSpawnIntervalSeconds 必须是有限正数"
    end
    if type(GameConfig.Regions) ~= "table" or #GameConfig.Regions ~= 20 then
        errors[#errors + 1] = "Regions 必须显式包含20个区域"
    end
    for index, region in ipairs(GameConfig.Regions or {}) do
        if region.RegionId ~= index then
            errors[#errors + 1] = "区域编号必须与数组顺序一致，index=" .. tostring(index)
        end
        if region.Enabled then
            if not IsPositiveInteger(region.RegionRootId) then
                errors[#errors + 1] = "启用区域缺少 RegionRootId，region=" .. tostring(index)
            end
            if not IsPositiveInteger(region.SpawnPointCount) then
                errors[#errors + 1] = "启用区域 SpawnPointCount 必须是正整数，region=" .. tostring(index)
            end
            if type(region.ChickenPool) ~= "table" or #region.ChickenPool == 0 then
                errors[#errors + 1] = "启用区域鸡池不能为空，region=" .. tostring(index)
            else
                for poolIndex, entry in ipairs(region.ChickenPool) do
                    local chickenConfig = GameConfig.ChickenTypes[entry.ChickenType]
                    if not chickenConfig or chickenConfig.Enabled ~= true then
                        errors[#errors + 1] = "鸡池引用未启用鸡类型，region=" .. tostring(index)
                            .. " poolIndex=" .. tostring(poolIndex)
                    end
                    if type(entry.Weight) ~= "number" or entry.Weight <= 0 then
                        errors[#errors + 1] = "鸡池权重必须大于0，region=" .. tostring(index)
                    end
                end
            end
        end
    end
    return #errors == 0, errors
end

function TheftService:Start(context)
    if context.Side ~= "Server" then return end

    local config = GameConfig.Theft
    local zone = context.Services.ZoneService
    local inventory = context.Services.InventoryService
    local hotbar = context.Services.HotbarService
    local runtime = {
        Ready = false,
        Stopped = false,
        Generation = 0,
        Refreshing = false,
        Generating = false,
        CarryVersion = 0,
        ChickensByRoot = {},
        TouchedByPlayer = {},
        HoldByPlayer = {},
        CarriedByPlayer = {},
        PendingByPlayer = {},
        OwnedDisplayByPlayer = {},
        OwnedDisplayRoots = {},
        TouchCallback = nil,
        BeginCallback = nil,
        CompleteCallback = nil,
        CancelCallback = nil,
        FatalDamageCallback = nil,
        PreleaveCallback = nil,
    }

    local function SendResult(playerId, rootId, success, reason)
        System:SendToClient(playerId, context.NetMsg.Messages.PickupResult, {
            elementId = rootId,
            generation = runtime.Generation,
            success = success == true,
            reason = reason,
        })
    end

    local function SendCarryState(playerId)
        local rootId = runtime.CarriedByPlayer[playerId]
        local chicken = rootId and runtime.ChickensByRoot[rootId]
        local carrying = not runtime.Stopped and not runtime.Refreshing
            and chicken ~= nil and chicken.state == "Carried" and chicken.playerId == playerId
            and zone:IsInStolenArea(playerId)
        runtime.CarryVersion = runtime.CarryVersion + 1
        System:SendToClient(playerId, context.NetMsg.Messages.TheftCarryState, {
            version = runtime.CarryVersion,
            generation = runtime.Generation,
            carrying = carrying == true,
            elementId = carrying and rootId or nil,
            operation = carrying and chicken.operation or 0,
        })
    end

    local function Reject(playerId, rootId, reason)
        if IsPositiveInteger(playerId) then SendResult(playerId, rootId, false, reason) end
        Log:PrintServerLog("[TheftService] 拾取请求被拒绝",
            "playerId:", tostring(playerId),
            "rootId:", tostring(rootId),
            "reason:", tostring(reason))
        return false
    end

    local function ValidateDistance(playerId, rootId)
        local playerPosition = Character:GetPosition(playerId)
        local chickenPosition = Element:GetPosition(rootId)
        if not playerPosition or not chickenPosition then
            return false, nil, nil, nil, "position_unavailable"
        end
        local distance = HorizontalDistance(playerPosition, chickenPosition)
        if distance > config.MaxHorizontalDistance then
            return false, playerPosition, chickenPosition, distance, "distance_exceeded"
        end
        return true, playerPosition, chickenPosition, distance, nil
    end

    local function ClearPlayerInteraction(playerId)
        runtime.TouchedByPlayer[playerId] = nil
        runtime.HoldByPlayer[playerId] = nil
    end

    local function RegisterSpawnedChicken(region, spawnPointId, chickenType, result, generation)
        if runtime.Stopped or context.Services.TheftService ~= runtime
            or runtime.Generation ~= generation then
            if result.success then context.ElementCopy:DestroyTree(result.rootId) end
            return
        end
        if not result.success then
            error("正式鸡复制失败，regionId=" .. tostring(region.RegionId)
                .. " spawnPointId=" .. tostring(spawnPointId)
                .. " reason=" .. tostring(result.reason))
        end
        local chickenConfig = GameConfig.ChickenTypes[chickenType]
        local ok, purpose = ReadPurpose(result.rootId)
        if not ok or purpose ~= chickenConfig.RequiredPurpose then
            error("复制鸡根作用属性不匹配，rootId=" .. tostring(result.rootId)
                .. " actual=" .. tostring(purpose))
        end
        local spawnPosition = Element:GetPosition(spawnPointId)
        if not spawnPosition then
            error("无法读取生成点位置，spawnPointId=" .. tostring(spawnPointId))
        end
        runtime.ChickensByRoot[result.rootId] = {
            rootId = result.rootId,
            spawnedIds = result.spawnedIds,
            regionId = region.RegionId,
            spawnPointId = spawnPointId,
            spawnPosition = CopyPosition(spawnPosition),
            chickenType = chickenType,
            state = "Available",
            playerId = nil,
            operation = 0,
        }
        return true
    end

    local function SpawnRegion(region, generation, onComplete)
        local allSpawnPoints = FindSpawnPoints(region)
        if #allSpawnPoints < region.SpawnPointCount then
            error("启用区域的鸡生成点少于配置数量，regionId=" .. tostring(region.RegionId)
                .. " required=" .. tostring(region.SpawnPointCount)
                .. " actual=" .. tostring(#allSpawnPoints))
        end
        local spawnPoints = ChooseSpawnPoints(allSpawnPoints, region.SpawnPointCount)
        local registeredCount = 0
        for _, spawnPointId in ipairs(spawnPoints) do
            if runtime.Stopped or context.Services.TheftService ~= runtime
                or runtime.Generation ~= generation then return end
            local currentSpawnPointId = spawnPointId
            local position = Element:GetPosition(currentSpawnPointId)
            if not position then
                error("无法读取鸡生成点位置，spawnPointId=" .. tostring(currentSpawnPointId))
            end
            local currentChickenType = ChooseChickenType(region.ChickenPool)
            local chickenConfig = GameConfig.ChickenTypes[currentChickenType]
            context.ElementCopy:CopyTree(
                chickenConfig.TemplateRootId,
                CopyPosition(position),
                "区域" .. tostring(region.RegionId) .. "生成点" .. tostring(currentSpawnPointId) .. "鸡",
                function(result)
                    local ok, errorMessage = xpcall(function()
                        local registered = RegisterSpawnedChicken(
                            region,
                            currentSpawnPointId,
                            currentChickenType,
                            result,
                            generation
                        )
                        if not registered then return end
                        registeredCount = registeredCount + 1
                        if registeredCount == region.SpawnPointCount then
                            onComplete()
                        end
                    end, Traceback)
                    if not ok and not runtime.Stopped
                        and context.Services.TheftService == runtime
                        and runtime.Generation == generation then
                        context.Manager:FailModule(TheftService.Name, errorMessage)
                    end
                end
            )
        end
    end

    local function DropPlayerChicken(playerId, reason)
        local rootId = runtime.CarriedByPlayer[playerId]
            or runtime.PendingByPlayer[playerId]
        if not rootId then return false end
        local chicken = runtime.ChickensByRoot[rootId]
        if not chicken then
            runtime.CarriedByPlayer[playerId] = nil
            runtime.PendingByPlayer[playerId] = nil
            return false
        end
        local dropPosition = Element:GetPosition(rootId)
        local previousOperation = chicken.operation
        chicken.operation = chicken.operation + 1
        chicken.state = "Dropped"
        chicken.playerId = nil
        runtime.CarriedByPlayer[playerId] = nil
        runtime.PendingByPlayer[playerId] = nil
        ClearPlayerInteraction(playerId)
        SendCarryState(playerId)
        pcall(function() Element:UnBinding(rootId) end)
        context.Events:Publish("StolenChickenDropped", {
            playerId = playerId,
            chickenRootId = rootId,
            regionId = chicken.regionId,
            reason = reason,
            previousOperation = previousOperation,
            operation = chicken.operation,
            generation = runtime.Generation,
        })
        if dropPosition then
            context.Timers:AddFrame(TheftService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                if runtime.ChickensByRoot[rootId] == chicken and chicken.state == "Dropped" then
                    Element:SetPosition(rootId, dropPosition, Element.COORDINATE.World)
                end
            end)
        end
        Log:PrintServerLog("[TheftService] 携带鸡已原地掉落",
            "playerId:", playerId, "rootId:", rootId, "reason:", reason)
        return true
    end

    runtime.ManualDropCallback = function(_, message, playerId)
        if not IsPositiveInteger(playerId) or type(message) ~= "table" then return end
        local rootId = runtime.CarriedByPlayer[playerId]
        local chicken = rootId and runtime.ChickensByRoot[rootId]
        if runtime.Refreshing or not zone:IsInStolenArea(playerId) or not chicken
            or chicken.state ~= "Carried" or chicken.playerId ~= playerId
            or message.elementId ~= rootId or message.generation ~= runtime.Generation
            or message.operation ~= chicken.operation then
            SendCarryState(playerId)
            return
        end
        -- 请求仅携带身份；落点取服务端此刻的玩家世界位置，不使用客户端坐标。
        local position = Character:GetPosition(playerId)
        if not position then error("主动放下无法读取玩家世界位置") end
        local dropPosition = CopyPosition(position)
        local previousOperation = chicken.operation
        chicken.operation = chicken.operation + 1
        local operation, generation = chicken.operation, runtime.Generation
        chicken.state = "Dropping"
        chicken.playerId = nil
        runtime.CarriedByPlayer[playerId] = nil
        ClearPlayerInteraction(playerId)
        SendCarryState(playerId)
        Element:UnBinding(rootId)
        context.Events:Publish("StolenChickenDropped", {
            playerId = playerId, chickenRootId = rootId, regionId = chicken.regionId,
            reason = "manual", previousOperation = previousOperation,
            operation = operation, generation = generation,
        })
        local function IsCurrent()
            return not runtime.Stopped and context.Services.TheftService == runtime
                and runtime.Generation == generation and runtime.ChickensByRoot[rootId] == chicken
                and chicken.operation == operation and chicken.state == "Dropping"
        end
        context.Timers:AddFrame(TheftService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not IsCurrent() then return end
            Element:SetPosition(rootId, dropPosition, Element.COORDINATE.World)
            context.Timers:AddFrame(TheftService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                if not IsCurrent() then return end
                local actualPosition = Element:GetPosition(rootId)
                if not actualPosition then error("主动放下后无法读取鸡落地位置") end
                if IsPositiveInteger(Element:GetAttachParentCharacter(rootId)) then
                    error("主动放下后鸡仍附加在角色上")
                end
                chicken.manualRepickup = true
                chicken.state = "Available"
                Log:PrintServerLog("[TheftService] 主动放下已落地，可再次拾取",
                    "rootId:", rootId, "operation:", operation,
                    "requestedPosition:", tostring(dropPosition), "actualPosition:", tostring(actualPosition))
            end)
        end)
    end

    runtime.CarrySnapshotCallback = function(_, message, playerId)
        if not IsPositiveInteger(playerId) then return end
        for _, onlineId in ipairs(Character:GetAllPlayerIds() or {}) do
            if onlineId == playerId then SendCarryState(playerId) return end
        end
    end

    local function ClearOwnedDisplay(playerId, reason)
        local display = runtime.OwnedDisplayByPlayer[playerId]
        if not display then return false end
        runtime.OwnedDisplayByPlayer[playerId] = nil
        local rootId = display.rootId
        pcall(function() Element:UnBinding(rootId) end)
        context.Timers:AddFrame(
            TheftService.Name,
            GameConfig.Runtime.EngineOperationDelayFrames,
            function()
                if not runtime.OwnedDisplayRoots[rootId] then return end
                context.ElementCopy:DestroyTree(rootId)
                runtime.OwnedDisplayRoots[rootId] = nil
                Log:PrintServerLog("[TheftService] 已清除快捷栏关闭时的头顶库存鸡展示",
                    "playerId:", playerId,
                    "rootId:", rootId,
                    "itemId:", display.itemId,
                    "reason:", reason)
            end
        )
        return true
    end

    local function AcquireChicken(playerId, rootId)
        local chicken = runtime.ChickensByRoot[rootId]
        if not chicken or chicken.state ~= "Carried" or chicken.playerId ~= playerId then return end
        local item, reason = inventory:AddChicken(playerId, chicken.chickenType)
        if not item then error("鸡写入库存失败: " .. tostring(reason)) end
        chicken.state = "Owned"
        runtime.CarriedByPlayer[playerId] = nil
        chicken.playerId = nil
        SendCarryState(playerId)
        context.Events:Publish("StolenChickenOwned", {
            playerId = playerId,
            chickenRootId = rootId,
            regionId = chicken.regionId,
            itemId = item.itemId,
            operation = chicken.operation,
            generation = runtime.Generation,
        })
        if hotbar then
            local adopted, adoptReason = hotbar:AdoptExistingDisplay(playerId, item.itemId, rootId)
            if not adopted then error("快捷栏接管带回鸡树失败: " .. tostring(adoptReason)) end
        else
            if runtime.OwnedDisplayByPlayer[playerId] then
                error("快捷栏关闭时玩家已有头顶库存鸡展示，playerId=" .. tostring(playerId))
            end
            runtime.OwnedDisplayByPlayer[playerId] = {
                rootId = rootId,
                itemId = item.itemId,
            }
            runtime.OwnedDisplayRoots[rootId] = true
            Log:PrintServerLog("[TheftService] 快捷栏关闭，带回鸡继续留在玩家头顶",
                "playerId:", playerId,
                "rootId:", rootId,
                "itemId:", item.itemId)
        end
        runtime.ChickensByRoot[rootId] = nil
        SendResult(playerId, rootId, true, "owned")
        Log:PrintServerLog("[TheftService] 鸡已成功带回并写入库存",
            "playerId:", playerId,
            "rootId:", rootId,
            "itemId:", item.itemId,
            "chickenType:", chicken.chickenType)
    end

    runtime.TouchCallback = function(elementId, playerId)
        if runtime.Refreshing then return end
        local chicken = runtime.ChickensByRoot[elementId]
        if not chicken or chicken.state ~= "Available" or not IsPositiveInteger(playerId) then return end
        if not zone:IsInStolenArea(playerId) then return end
        if runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId] then return end
        runtime.TouchedByPlayer[playerId] = elementId
        System:SendToClient(playerId, context.NetMsg.Messages.PickupShow, {
            elementId = elementId,
            generation = runtime.Generation,
            operation = chicken.operation,
        })
    end

    runtime.BeginCallback = function(_, message, playerId)
        if runtime.Refreshing then Reject(playerId, nil, "refreshing") return end
        if type(message) ~= "table" or not IsPositiveInteger(playerId)
            or not IsPositiveInteger(message.elementId) then
            Reject(playerId, nil, "invalid_begin_message")
            return
        end
        local rootId = message.elementId
        if message.generation ~= runtime.Generation then return end
        local chicken = runtime.ChickensByRoot[rootId]
        if runtime.TouchedByPlayer[playerId] ~= rootId or not chicken
            or chicken.state ~= "Available" or message.operation ~= chicken.operation then
            Reject(playerId, rootId, "target_not_available")
            return
        end
        if not zone:IsInStolenArea(playerId) then
            Reject(playerId, rootId, "not_in_stolen_area")
            return
        end
        if runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId] then
            Reject(playerId, rootId, "player_already_carrying")
            return
        end
        local valid, _, _, _, reason = ValidateDistance(playerId, rootId)
        if not valid then Reject(playerId, rootId, reason) return end
        runtime.HoldByPlayer[playerId] = {
            rootId = rootId,
            operation = chicken.operation,
            startedAtMs = MiscService:GetServerTimestamp(),
        }
    end

    runtime.CancelCallback = function(_, message, playerId)
        if type(message) ~= "table" or not IsPositiveInteger(playerId)
            or not IsPositiveInteger(message.elementId)
            or (message.reason ~= "button_released"
                and message.reason ~= "horizontal_distance_exceeded") then
            Log:PrintWarning("[TheftService] 拒绝无效拾取取消请求",
                "playerId:", tostring(playerId),
                "messageType:", type(message))
            return
        end
        local rootId = message.elementId
        if message.generation ~= runtime.Generation then return end
        local hold = runtime.HoldByPlayer[playerId]
        if hold and hold.rootId == rootId and message.operation == hold.operation then
            runtime.HoldByPlayer[playerId] = nil
        end
        if message.reason == "horizontal_distance_exceeded"
            and runtime.TouchedByPlayer[playerId] == rootId then
            local chicken = runtime.ChickensByRoot[rootId]
            if not chicken or chicken.operation ~= message.operation then return end
            runtime.TouchedByPlayer[playerId] = nil
        end
    end

    runtime.CompleteCallback = function(_, message, playerId)
        if runtime.Refreshing then Reject(playerId, nil, "refreshing") return end
        if type(message) ~= "table" or not IsPositiveInteger(playerId)
            or not IsPositiveInteger(message.elementId) then
            Reject(playerId, nil, "invalid_complete_message")
            return
        end
        local rootId = message.elementId
        if message.generation ~= runtime.Generation then return end
        local hold = runtime.HoldByPlayer[playerId]
        local chicken = runtime.ChickensByRoot[rootId]
        if not chicken or message.operation ~= chicken.operation
            or (hold and hold.operation ~= chicken.operation) then return end
        if not hold or hold.rootId ~= rootId then Reject(playerId, rootId, "hold_not_started") return end
        local elapsedMs = MiscService:GetServerTimestamp() - hold.startedAtMs
        if elapsedMs < config.HoldSeconds * 1000 then
            runtime.HoldByPlayer[playerId] = nil
            Reject(playerId, rootId, "server_hold_time_not_reached")
            return
        end
        if not chicken or chicken.state ~= "Available" then
            ClearPlayerInteraction(playerId)
            Reject(playerId, rootId, "target_not_available")
            return
        end
        if runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId] then
            ClearPlayerInteraction(playerId)
            Reject(playerId, rootId, "player_already_carrying")
            return
        end
        if not zone:IsInStolenArea(playerId) then Reject(playerId, rootId, "not_in_stolen_area") return end
        local valid, playerPosition, chickenPosition, distance, distanceReason = ValidateDistance(playerId, rootId)
        if not valid then
            ClearPlayerInteraction(playerId)
            Reject(playerId, rootId, distanceReason)
            return
        end
        local propertyOk, purpose = ReadPurpose(rootId)
        local chickenConfig = GameConfig.ChickenTypes[chicken.chickenType]
        if not propertyOk or purpose ~= chickenConfig.RequiredPurpose then
            ClearPlayerInteraction(playerId)
            Reject(playerId, rootId, "chicken_purpose_mismatch")
            return
        end

        ClearPlayerInteraction(playerId)
        chicken.state = "PendingBind"
        chicken.playerId = playerId
        chicken.operation = chicken.operation + 1
        local operation = chicken.operation
        local generation = runtime.Generation
        local pickupPosition = CopyPosition(chickenPosition)
        local manualRepickup = chicken.manualRepickup == true
        runtime.PendingByPlayer[playerId] = rootId
        Element:SetPosition(rootId, Engine.Vector(
            playerPosition.X,
            playerPosition.Y,
            playerPosition.Z + config.CarryHeight
        ), Element.COORDINATE.World)
        context.Timers:AddFrame(TheftService.Name, config.BindDelayFrames, function()
            if runtime.ChickensByRoot[rootId] ~= chicken or chicken.operation ~= operation then return end
            Element:BindingToCharacterOrCreature(
                rootId,
                playerId,
                config.CharacterSocket,
                config.SocketMode
            )
            context.Timers:AddFrame(TheftService.Name, config.VerifyDelayFrames, function()
                if runtime.ChickensByRoot[rootId] ~= chicken or chicken.operation ~= operation then return end
                if Element:GetAttachParentCharacter(rootId) ~= playerId then
                    error("正式拾取附加验证失败，rootId=" .. tostring(rootId))
                end
                runtime.PendingByPlayer[playerId] = nil
                runtime.CarriedByPlayer[playerId] = rootId
                chicken.state = "Carried"
                chicken.manualRepickup = false
                SendResult(playerId, rootId, true, "carried")
                SendCarryState(playerId)
                context.Events:Publish("ChickenCarried", {
                    playerId = playerId,
                    chickenRootId = rootId,
                    regionId = chicken.regionId,
                    spawnPosition = CopyPosition(chicken.spawnPosition),
                    manualRepickup = manualRepickup,
                    pickupPosition = pickupPosition,
                    operation = operation,
                    generation = generation,
                })
                Log:PrintServerLog("[TheftService] 玩家成功拿取鸡",
                    "playerId:", playerId,
                    "rootId:", rootId,
                    "distance:", distance,
                    "serverHoldMs:", elapsedMs,
                    "height:", config.CarryHeight)
            end)
        end)
    end

    runtime.FatalDamageCallback = function(playerId)
        if IsPositiveInteger(playerId) then
            DropPlayerChicken(playerId, "fatal_damage")
            ClearOwnedDisplay(playerId, "fatal_damage")
        end
    end
    runtime.PreleaveCallback = function(playerId)
        if not IsPositiveInteger(playerId) then return end
        DropPlayerChicken(playerId, "player_preleave")
        ClearOwnedDisplay(playerId, "player_preleave")
        runtime.PendingByPlayer[playerId] = nil
        ClearPlayerInteraction(playerId)
    end

    local function ProtectCallback(actionName, callback)
        return function(...)
            if runtime.Stopped or context.Services.TheftService ~= runtime then return end
            local args = { n = select("#", ...), ... }
            local unpackArgs = table.unpack or unpack
            local ok, errorMessage = xpcall(function()
                callback(unpackArgs(args, 1, args.n))
            end, Traceback)
            if not ok then
                context.Manager:FailModule(
                    TheftService.Name,
                    actionName .. ": " .. tostring(errorMessage)
                )
            end
        end
    end

    runtime.TouchCallback = ProtectCallback("鸡碰撞回调失败", runtime.TouchCallback)
    runtime.BeginCallback = ProtectCallback("开始按住请求回调失败", runtime.BeginCallback)
    runtime.CompleteCallback = ProtectCallback("完成拾取请求回调失败", runtime.CompleteCallback)
    runtime.CancelCallback = ProtectCallback("取消拾取请求回调失败", runtime.CancelCallback)
    runtime.FatalDamageCallback = ProtectCallback("携鸡死亡回调失败", runtime.FatalDamageCallback)
    runtime.PreleaveCallback = ProtectCallback("携鸡离开回调失败", runtime.PreleaveCallback)
    runtime.ManualDropCallback = ProtectCallback("主动放下回调失败", runtime.ManualDropCallback)
    runtime.CarrySnapshotCallback = ProtectCallback("携带快照回调失败", runtime.CarrySnapshotCallback)

    context.Services.TheftService = runtime
    if config.InteractionEnabled then
        context.Events:Subscribe(TheftService.Name, "ZoneChanged", function(snapshot)
            if snapshot.inStolenArea == false and not runtime.Refreshing then
                local rootId = runtime.CarriedByPlayer[snapshot.playerId]
                if rootId then AcquireChicken(snapshot.playerId, rootId) end
            elseif snapshot.inStolenArea == true then
                ClearOwnedDisplay(snapshot.playerId, "entered_stolen_area")
            end
        end)
        context.Events:Subscribe(TheftService.Name, "GuardianCaughtChicken", function(snapshot)
            local chicken = runtime.ChickensByRoot[snapshot.chickenRootId]
            if not chicken then return end
            if snapshot.generation ~= runtime.Generation or snapshot.operation ~= chicken.operation then return end
            if chicken.playerId then
                runtime.CarriedByPlayer[chicken.playerId] = nil
                runtime.PendingByPlayer[chicken.playerId] = nil
                ClearPlayerInteraction(chicken.playerId)
                SendCarryState(chicken.playerId)
            end
            chicken.playerId = nil
            chicken.state = "Returning"
            chicken.operation = chicken.operation + 1
            Element:UnBinding(chicken.rootId)
        end)
        context.Events:Subscribe(TheftService.Name, "GuardianChickenReturned", function(snapshot)
            local chicken = runtime.ChickensByRoot[snapshot.chickenRootId]
            if not chicken then return end
            if snapshot.generation ~= runtime.Generation or snapshot.operation ~= chicken.operation
                or chicken.state ~= "Returning" then return end
            chicken.playerId = nil
            chicken.state = "Available"
            chicken.manualRepickup = false
            chicken.spawnPosition = CopyPosition(snapshot.spawnPosition)
            Log:PrintServerLog("[TheftService] 鸡已由守护者送回生成点",
                "regionId:", chicken.regionId, "rootId:", chicken.rootId)
        end)
        System:RegisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
        System:RegisterEvent(Events.ON_CHARACTER_TAKE_FATAL_DAMAGE, runtime.FatalDamageCallback)
        System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
        System:BindNotify(context.NetMsg.Messages.PickupBegin, runtime.BeginCallback)
        System:BindNotify(context.NetMsg.Messages.PickupComplete, runtime.CompleteCallback)
        System:BindNotify(context.NetMsg.Messages.PickupCancel, runtime.CancelCallback)
        System:BindNotify(context.NetMsg.Messages.TheftManualDrop, runtime.ManualDropCallback)
        System:BindNotify(context.NetMsg.Messages.TheftCarrySnapshotRequest, runtime.CarrySnapshotCallback)
    else
        runtime.TouchCallback = nil
        runtime.BeginCallback = nil
        runtime.CompleteCallback = nil
        runtime.CancelCallback = nil
        runtime.FatalDamageCallback = nil
        runtime.PreleaveCallback = nil
        runtime.ManualDropCallback = nil
        runtime.CarrySnapshotCallback = nil
        Log:PrintServerLog("[TheftService] 4A-1 仅启用鸡生成，拾取交互未登记")
    end


    function runtime:BeginRefresh(onCleared)
        if self.Stopped or self.Refreshing then error("偷鸡刷新入口状态无效") end
        self.Generation = self.Generation + 1
        local generation = self.Generation
        self.Ready = false
        self.Refreshing = true
        self.Generating = false
        self.TouchedByPlayer = {}
        self.HoldByPlayer = {}
        self.CarriedByPlayer = {}
        self.PendingByPlayer = {}
        if config.InteractionEnabled then
            for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do SendCarryState(playerId) end
        end
        local oldChickens = self.ChickensByRoot
        self.RefreshRoots = oldChickens
        self.ChickensByRoot = {}
        for rootId, chicken in pairs(oldChickens) do
            chicken.operation = chicken.operation + 1
            Element:UnBinding(rootId)
        end
        context.Timers:AddFrame(TheftService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if self.Stopped or context.Services.TheftService ~= self
                or self.Generation ~= generation then return end
            for rootId in pairs(oldChickens) do context.ElementCopy:DestroyTree(rootId) end
            self.RefreshRoots = nil
            context.Timers:AddFrame(TheftService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                if self.Stopped or context.Services.TheftService ~= self
                    or self.Generation ~= generation then return end
                onCleared()
            end)
        end)
    end

    function runtime:GenerateRegions()
        if self.Stopped or context.Services.TheftService ~= self
            or self.Generating or self.RefreshRoots then
            error("偷鸡生成入口已失效")
        end
        self.Generation = self.Generation + 1
        local generation = self.Generation
        self.Ready = false
        self.Refreshing = false
        self.Generating = true
        local nextRegionIndex = 1
        local completedRegionCount = 0
        local function IsCurrent()
            return not self.Stopped and context.Services.TheftService == self
                and self.Generation == generation
        end
        local function SpawnNextRegion()
            if not IsCurrent() then return end
            while nextRegionIndex <= #GameConfig.Regions
                and not GameConfig.Regions[nextRegionIndex].Enabled do
                nextRegionIndex = nextRegionIndex + 1
            end
            local region = GameConfig.Regions[nextRegionIndex]
            if not region then
                self.Ready = true
                self.Generating = false
                Log:PrintServerLog("[TheftService] 正式偷鸡模块已就绪",
                    "enabledRegionCount:", completedRegionCount,
                    "interactionEnabled:", config.InteractionEnabled)
                context.Events:Publish("TheftGenerationCompleted", { generation = generation })
                return
            end
            nextRegionIndex = nextRegionIndex + 1
            SpawnRegion(region, generation, function()
                if not IsCurrent() then return end
                completedRegionCount = completedRegionCount + 1
                while nextRegionIndex <= #GameConfig.Regions
                    and not GameConfig.Regions[nextRegionIndex].Enabled do
                    nextRegionIndex = nextRegionIndex + 1
                end
                if nextRegionIndex <= #GameConfig.Regions then
                    context.Timers:AddTimer(TheftService.Name,
                        config.RegionSpawnIntervalSeconds, SpawnNextRegion)
                else
                    SpawnNextRegion()
                end
            end)
        end
        SpawnNextRegion()
        return generation
    end
    context.Timers:AddTimer(TheftService.Name,
        GameConfig.Runtime.ServerReadyDelaySeconds, function()
            if runtime.Stopped or context.Services.TheftService ~= runtime then return end
            if runtime.Generation == 0 then runtime:GenerateRegions() end
        end)

end

function TheftService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.TheftService
    if not runtime then return end
    runtime.Stopped = true
    if GameConfig.Theft.InteractionEnabled then
        for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do
            runtime.CarryVersion = runtime.CarryVersion + 1
            System:SendToClient(playerId, context.NetMsg.Messages.TheftCarryState, {
                version = runtime.CarryVersion, generation = runtime.Generation, carrying = false, operation = 0,
            })
        end
    end
    for rootId in pairs(runtime.RefreshRoots or {}) do
        pcall(function() Element:UnBinding(rootId) end)
        context.ElementCopy:DestroyTree(rootId)
    end
    runtime.RefreshRoots = nil
    if runtime.TouchCallback then
        System:UnregisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
    end
    if runtime.FatalDamageCallback then
        System:UnregisterEvent(Events.ON_CHARACTER_TAKE_FATAL_DAMAGE, runtime.FatalDamageCallback)
    end
    if runtime.PreleaveCallback then
        System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
    end
    if runtime.BeginCallback then
        System:UnbindNotify(context.NetMsg.Messages.PickupBegin, runtime.BeginCallback)
    end
    if runtime.CompleteCallback then
        System:UnbindNotify(context.NetMsg.Messages.PickupComplete, runtime.CompleteCallback)
    end
    if runtime.CancelCallback then
        System:UnbindNotify(context.NetMsg.Messages.PickupCancel, runtime.CancelCallback)
    end
    if runtime.ManualDropCallback then
        System:UnbindNotify(context.NetMsg.Messages.TheftManualDrop, runtime.ManualDropCallback)
    end
    if runtime.CarrySnapshotCallback then
        System:UnbindNotify(context.NetMsg.Messages.TheftCarrySnapshotRequest, runtime.CarrySnapshotCallback)
    end
    for rootId in pairs(runtime.ChickensByRoot) do
        pcall(function() Element:UnBinding(rootId) end)
        context.ElementCopy:DestroyTree(rootId)
    end
    for rootId in pairs(runtime.OwnedDisplayRoots) do
        pcall(function() Element:UnBinding(rootId) end)
        context.ElementCopy:DestroyTree(rootId)
    end
    runtime.ChickensByRoot = {}
    runtime.OwnedDisplayByPlayer = {}
    runtime.OwnedDisplayRoots = {}
    context.Services.TheftService = nil
end

return TheftService
