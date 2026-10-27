local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"

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
    if GameConfig.Theft.ManualDropReturnSeconds ~= 30 then
        errors[#errors + 1] = "Theft.ManualDropReturnSeconds必须为30"
    end
    if type(regionSpawnInterval) ~= "number" or regionSpawnInterval ~= regionSpawnInterval
        or regionSpawnInterval <= 0 or regionSpawnInterval == math.huge then
        errors[#errors + 1] = "Theft.RegionSpawnIntervalSeconds 必须是有限正数"
    end
    if type(GameConfig.Regions) ~= "table" or #GameConfig.Regions ~= 15 then
        errors[#errors + 1] = "Regions 必须显式包含15个区域"
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
        ModelVersion = 0,
        ReturnReservations = {},
        PointOccupants = {},
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


    local function SendResult(playerId, rootId, success, reason, operation, carryRetained)
        local chicken = runtime.ChickensByRoot[rootId]
        System:SendToClient(playerId, context.NetMsg.Messages.PickupResult, {
            elementId = rootId,
            generation = runtime.Generation,
            success = success == true,
            reason = reason,
            operation = operation or (chicken and chicken.operation),
            carryRetained = carryRetained == true,
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

    local function IsPlayerReady(playerId)
        if not GameConfig.Persistence.ProductionEnabled then return true end
        local persistence = context.Services.PersistenceService
        return persistence ~= nil and persistence:IsReady(playerId)
    end

    local function IsSessionCurrent(playerId, session)
        return not GameConfig.Persistence.ProductionEnabled
            or (session ~= nil and inventory:GetSessionGeneration(playerId) == session)
    end

    local function CheckAdmission(playerId)
        if not IsPlayerReady(playerId) then return false, "persistence_not_ready" end
        if GameConfig.InventoryCapacity.Enabled then
            return inventory:CheckCapacity(playerId, "Chicken", 0, 1)
        end
        return true
    end

    -- 同一1330表现链的world源；每次更新为完整快照，客户端只写当前根身份。
    local function SendWorldModels(recipient, cleared)
        local models = {}
        if not cleared then
            for rootId, chicken in pairs(runtime.ChickensByRoot) do
                models[#models + 1] = { rootId = rootId, chickenType = chicken.chickenType, finalSellPrice = chicken.finalSellPrice,
                    operation = chicken.operation, generation = runtime.Generation,
                    countdownEndMs = chicken.countdownEndMs }
            end
        end
        runtime.ModelVersion = runtime.ModelVersion + 1
        local message = { source = "world", playerId = 0, version = runtime.ModelVersion, models = models }
        local ok, reason = pcall(function()
            if recipient then System:SendToClient(recipient, context.NetMsg.Messages.ChickenModelState, message)
            else System:SendToAllClients(context.NetMsg.Messages.ChickenModelState, message) end
        end)
        if not ok then Log:PrintError("[TheftService] 世界鸡表现快照发送失败", tostring(reason)) end
    end
    runtime.SendWorldModels = SendWorldModels

    -- 点位归属由业务迁移维护，不因引擎位置微小漂移而丢失。
    -- 拾取离点释放占用；到期新个体生成前同步预占，不为旧鸡保留返回点。
    local function ReleasePoint(chicken)
        for _, map in ipairs({ runtime.PointOccupants, runtime.ReturnReservations }) do
            for pointId, owner in pairs(map) do if owner == chicken then map[pointId] = nil end end
        end
    end

    local function ClaimPoint(chicken)
        ReleasePoint(chicken)
        runtime.PointOccupants[chicken.spawnPointId] = chicken
    end

    local function PauseCountdown(chicken)
        if chicken.countdownEndMs then
            chicken.countdownRemainingMs = math.max(0, chicken.countdownEndMs - MiscService:GetServerTimestamp())
        end
        chicken.countdownEndMs = nil
        if chicken.countdownTimerId then context.Timers:Remove(chicken.countdownTimerId) end
        chicken.countdownTimerId = nil
    end

    local function ClearRootInteraction(chicken, operation)
        local players = {}
        for playerId, rootId in pairs(runtime.TouchedByPlayer) do
            if rootId == chicken.rootId then players[playerId] = true end
        end
        for playerId, hold in pairs(runtime.HoldByPlayer) do
            if hold.rootId == chicken.rootId then players[playerId] = true end
        end
        for playerId in pairs(players) do
            ClearPlayerInteraction(playerId)
            SendResult(playerId, chicken.rootId, false, "chicken_relocated", operation)
        end
    end

    local RegisterSpawnedChicken
    -- 每次请求独立完成一次；复制失败不影响区域进度，成功后的业务校验仍可停模块。
    local function CopyChicken(region, pointId, chickenType, position, generation, onFinished, reservation, registration)
        local templateId = GameConfig.ChickenTypes[chickenType].TemplateRootId
        local completed, accepted, cleaned = false, {}, {}
        local function Current()
            return not runtime.Stopped and context.Services.TheftService == runtime
                and runtime.Generation == generation
                and (not reservation or runtime.ReturnReservations[pointId] == reservation)
        end
        local function ReleaseReservation()
            if reservation and runtime.ReturnReservations[pointId] == reservation then
                runtime.ReturnReservations[pointId] = nil
            end
        end
        local function LogFailure(reason)
            Log:PrintError("[TheftService] 鸡复制请求失败，仅跳过本请求",
                "regionId:", region.RegionId, "spawnPointId:", pointId,
                "templateRootId:", templateId, "reason:", tostring(reason))
        end
        local function Cleanup(result)
            if type(result) ~= "table" then return end
            local current = context.Services.TheftService
            if result.rootId and (accepted[result.rootId] or runtime.ChickensByRoot[result.rootId]
                or runtime.OwnedDisplayRoots[result.rootId]
                or (current and current.ChickensByRoot and current.ChickensByRoot[result.rootId])) then return end
            -- 底层失败仅返回仍由调用方持有的部分实例；按生成逆序销毁一次，避免整树/子级重复清理。
            local ids, seen = {}, {}
            if result.rootId then ids[1], seen[result.rootId] = result.rootId, true end
            for _, id in ipairs(result.spawnedIds or {}) do
                if not seen[id] then ids[#ids + 1], seen[id] = id, true end
            end
            for index = #ids, 1, -1 do
                local id = ids[index]
                if type(id) == "number" and id ~= templateId and not accepted[id] and not cleaned[id]
                    and not runtime.ChickensByRoot[id] and not runtime.OwnedDisplayRoots[id]
                    and not (current and current.ChickensByRoot and current.ChickensByRoot[id]) then
                    cleaned[id] = true
                    local ok, reason = pcall(function() Element:Destroy(id) end)
                    if not ok then LogFailure("清理副本失败 id=" .. tostring(id) .. ": " .. tostring(reason)) end
                end
            end
        end
        local function Complete(success)
            local ok, reason = xpcall(function() onFinished(success) end, Traceback)
            if not ok and not runtime.Stopped and context.Services.TheftService == runtime
                and runtime.Generation == generation then context.Manager:FailModule(TheftService.Name, reason) end
        end
        local function Finish(result)
            if completed then Cleanup(result); return end
            if not Current() then
                completed = true
                Cleanup(result)
                ReleaseReservation()
                return
            end
            completed = true
            if type(result) == "table" and result.success == false then
                Cleanup(result)
                LogFailure(result.reason)
                ReleaseReservation()
                Complete(false)
                return
            end
            local ok, reason = xpcall(function()
                assert(type(result) == "table" and result.success == true, "复制结果格式无效")
                local registered = RegisterSpawnedChicken(region, pointId, chickenType, result, generation, registration)
                if not registered then return end
                accepted[result.rootId] = true
                for _, id in ipairs(result.spawnedIds or {}) do accepted[id] = true end
            end, Traceback)
            ReleaseReservation()
            if not ok then
                Cleanup(result)
                if not runtime.Stopped and context.Services.TheftService == runtime and runtime.Generation == generation then
                    context.Manager:FailModule(TheftService.Name, reason)
                end
                return
            end
            if not runtime.Stopped and context.Services.TheftService == runtime and runtime.Generation == generation then
                Complete(true)
            end
        end
        local ok, reason = pcall(function()
            context.ElementCopy:CopyTree(templateId, CopyPosition(position),
                "区域" .. tostring(region.RegionId) .. "生成点" .. tostring(pointId) .. "鸡", Finish)
        end)
        if not ok then
            LogFailure(reason)
            if completed then return end
            completed = true
            ReleaseReservation()
            if not runtime.Stopped and context.Services.TheftService == runtime and runtime.Generation == generation then
                Complete(false)
            end
        end
    end
    local function ExpireCountdown(chicken)
        local rootId, previousOperation = chicken.rootId, chicken.operation
        PauseCountdown(chicken)
        chicken.operation = previousOperation + 1
        local generation = runtime.Generation
        chicken.state = "Expired"
        ClearRootInteraction(chicken, previousOperation)
        context.Events:Publish("StolenChickenRelocated", { chickenRootId = rootId,
            regionId = chicken.regionId, generation = generation })
        ReleasePoint(chicken)
        runtime.ChickensByRoot[rootId] = nil
        SendWorldModels()
        context.ElementCopy:DestroyTree(rootId)
        local region = GameConfig.Regions[chicken.regionId]
        local candidates = {}
        for _, pointId in ipairs(FindSpawnPoints(region)) do
            local position = Element:GetPosition(pointId)
            if not position then error("到期补鸡无法读取生成点位置") end
            local occupied = false
            for _, map in ipairs({ runtime.PointOccupants, runtime.ReturnReservations }) do
                for occupiedPoint in pairs(map) do
                    local other = Element:GetPosition(occupiedPoint)
                    if not other then error("到期补鸡无法读取占用点位置") end
                    if occupiedPoint == pointId or (other.X == position.X and other.Y == position.Y
                        and other.Z == position.Z) then occupied = true break end
                end
                if occupied then break end
            end
            if not occupied then
                for otherRoot in pairs(runtime.ChickensByRoot) do
                    local actual = Element:GetPosition(otherRoot)
                    if not actual then error("到期补鸡无法读取现有鸡位置") end
                    if actual.X == position.X and actual.Y == position.Y and actual.Z == position.Z then
                        occupied = true; break
                    end
                end
            end
            if not occupied then candidates[#candidates + 1] = { id = pointId, position = CopyPosition(position) } end
        end
        if #candidates == 0 then return end
        local selected = candidates[math.random(1, #candidates)]
        local reservation = {}
        runtime.ReturnReservations[selected.id] = reservation
        local chickenType = ChooseChickenType(region.ChickenPool)
        CopyChicken(region, selected.id, chickenType, selected.position, generation, function() end, reservation)
    end

    local function StartCountdown(chicken)
        PauseCountdown(chicken)
        local remaining = chicken.countdownRemainingMs or config.ManualDropReturnSeconds * 1000
        chicken.countdownEndMs = MiscService:GetServerTimestamp() + remaining
        local operation, generation = chicken.operation, runtime.Generation
        chicken.countdownTimerId = context.Timers:AddTimer(TheftService.Name, remaining / 1000, function()
            if runtime.Stopped or context.Services.TheftService ~= runtime
                or runtime.Generation ~= generation or runtime.ChickensByRoot[chicken.rootId] ~= chicken
                or chicken.operation ~= operation or chicken.state ~= "Available" then return end
            chicken.countdownTimerId = nil
            ExpireCountdown(chicken)
        end)
        SendWorldModels()
    end

    local function CheckCountdown(chicken)
        if chicken.countdownEndMs and MiscService:GetServerTimestamp() >= chicken.countdownEndMs then
            ExpireCountdown(chicken)
            return false
        end
        return true
    end

    RegisterSpawnedChicken = function(region, spawnPointId, chickenType, result, generation, registration)
        if runtime.Stopped or context.Services.TheftService ~= runtime
            or runtime.Generation ~= generation then
            if result.success then context.ElementCopy:DestroyTree(result.rootId) end
            return
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
        local finalSellPrice = math.floor(chickenConfig.ChickenSellPrice * (1 + math.random() * 4))
        if not Decimal.FromSafeInteger(finalSellPrice) then error("生成鸡独立售价必须是非负安全整数") end
        runtime.ChickensByRoot[result.rootId] = {
            rootId = result.rootId,
            spawnedIds = result.spawnedIds,
            regionId = region.RegionId,
            spawnPointId = spawnPointId,
            spawnPosition = CopyPosition(spawnPosition),
            chickenType = chickenType,
            finalSellPrice = finalSellPrice,
            state = "Available",
            playerId = nil,
            operation = 0,
        }
        ClaimPoint(runtime.ChickensByRoot[result.rootId])
        if not registration then SendWorldModels() end
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
        local registration = true -- 区域批量登记，仅区域全部请求结束后广播。
        local completedCount = 0
        for _, spawnPointId in ipairs(spawnPoints) do
            if runtime.Stopped or context.Services.TheftService ~= runtime
                or runtime.Generation ~= generation then
                return end
            local currentSpawnPointId = spawnPointId
            local position = Element:GetPosition(currentSpawnPointId)
            if not position then
                error("无法读取鸡生成点位置，spawnPointId=" .. tostring(currentSpawnPointId))
            end
            local currentChickenType = ChooseChickenType(region.ChickenPool)
            CopyChicken(region, currentSpawnPointId, currentChickenType, position, generation, function()
                if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation then return end
                completedCount = completedCount + 1
                if completedCount == region.SpawnPointCount then
                    SendWorldModels()
                    onComplete()
                end
            end, nil, registration)
        end
    end

    local function DropPlayerChicken(playerId, reason)
        local rootId = runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId]
        if not rootId then return false end
        local chicken = runtime.ChickensByRoot[rootId]
        if not chicken or chicken.playerId ~= playerId
            or (chicken.state ~= "Carried" and chicken.state ~= "PendingBind") then return false end
        local position = Character:GetPosition(playerId)
        if not position then error("原地掉鸡无法读取玩家世界位置") end
        local dropPosition = CopyPosition(position)
        PauseCountdown(chicken)
        ReleasePoint(chicken)
        local previousOperation = chicken.operation
        chicken.operation = chicken.operation + 1
        local operation, generation = chicken.operation, runtime.Generation
        chicken.state = "Dropping"
        chicken.playerId = nil
        runtime.CarriedByPlayer[playerId], runtime.PendingByPlayer[playerId] = nil, nil
        ClearPlayerInteraction(playerId)
        SendCarryState(playerId)
        SendWorldModels()
        Element:UnBinding(rootId)
        context.Events:Publish("StolenChickenDropped", {
            playerId = playerId, chickenRootId = rootId, regionId = chicken.regionId,
            reason = reason, previousOperation = previousOperation,
            operation = operation, generation = generation,
        })
        local function Current()
            return not runtime.Stopped and context.Services.TheftService == runtime
                and runtime.Generation == generation and runtime.ChickensByRoot[rootId] == chicken
                and chicken.operation == operation and chicken.state == "Dropping"
        end
        context.Timers:AddFrame(TheftService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Current() then return end
            Element:SetPosition(rootId, dropPosition, Element.COORDINATE.World)
            context.Timers:AddFrame(TheftService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                if not Current() then return end
                if not Element:GetPosition(rootId) then error("原地掉鸡落地后无法读取位置") end
                if IsPositiveInteger(Element:GetAttachParentCharacter(rootId)) then error("掉落鸡仍附加角色") end
                chicken.manualRepickup = true
                chicken.state = "Available"
                StartCountdown(chicken)
                Log:PrintServerLog("[TheftService] 原地掉鸡已落地，可公共拾取",
                    "playerId:", playerId, "rootId:", rootId, "reason:", reason, "operation:", operation)
            end)
        end)
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
        DropPlayerChicken(playerId, "manual")
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
        local allowed, admissionReason = CheckAdmission(playerId)
        if not IsSessionCurrent(playerId, chicken.inventorySession) then
            allowed, admissionReason = false, "persistence_not_ready"
        end
        if not allowed then
            SendResult(playerId, rootId, false, admissionReason, chicken.operation, true)
            return
        end
        local item, reason = inventory:AddChicken(playerId, chicken.chickenType, chicken.finalSellPrice)
        if not item then
            if reason == "inventory_capacity_full" or reason == "persistence_not_ready" then
                SendResult(playerId, rootId, false, reason, chicken.operation, true)
                return
            end
            error("鸡写入库存失败: " .. tostring(reason))
        end
        chicken.state = "Owned"
        PauseCountdown(chicken)
        ReleasePoint(chicken)
        -- 先撤销世界模型归属，Hotbar接管同根后旧world快照不会再写该根。
        runtime.ChickensByRoot[rootId] = nil
        SendWorldModels()
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
        Element:SetEnableCollision(rootId, false)
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
        if not CheckCountdown(chicken) then return end
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
        if chicken and message.operation ~= chicken.operation then return end
        if chicken and not CheckCountdown(chicken) then return end
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
        local allowed, admissionReason = CheckAdmission(playerId)
        if not allowed then
            ClearPlayerInteraction(playerId)
            Reject(playerId, rootId, admissionReason)
            return
        end
        runtime.HoldByPlayer[playerId] = {
            rootId = rootId,
            operation = chicken.operation,
            inventorySession = inventory:GetSessionGeneration(playerId),
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
        if not CheckCountdown(chicken) then return end
        if not hold or hold.rootId ~= rootId then Reject(playerId, rootId, "hold_not_started") return end
        local allowed, admissionReason = CheckAdmission(playerId)
        if not IsSessionCurrent(playerId, hold.inventorySession) then
            allowed, admissionReason = false, "persistence_not_ready"
        end
        if not allowed then
            ClearPlayerInteraction(playerId)
            Reject(playerId, rootId, admissionReason)
            return
        end
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
        PauseCountdown(chicken)
        ReleasePoint(chicken)
        chicken.state = "PendingBind"
        chicken.playerId = playerId
        chicken.operation = chicken.operation + 1
        local operation = chicken.operation
        local generation = runtime.Generation
        local pickupPosition = CopyPosition(chickenPosition)
        local manualRepickup = chicken.manualRepickup == true
        local inventorySession = hold.inventorySession
        chicken.inventorySession = inventorySession
        SendWorldModels()
        runtime.PendingByPlayer[playerId] = rootId
        local function PendingCurrent()
            return not runtime.Stopped and context.Services.TheftService == runtime
                and runtime.Generation == generation and runtime.ChickensByRoot[rootId] == chicken
                and chicken.operation == operation and chicken.state == "PendingBind"
                and runtime.PendingByPlayer[playerId] == rootId and chicken.playerId == playerId
        end
        local function ValidatePending()
            if not PendingCurrent() then return false end
            local validAdmission, pendingReason = CheckAdmission(playerId)
            if not IsSessionCurrent(playerId, inventorySession) then
                validAdmission, pendingReason = false, "persistence_not_ready"
            end
            if validAdmission then return true end
            SendResult(playerId, rootId, false, pendingReason, message.operation)
            DropPlayerChicken(playerId, "pickup_interrupted")
            return false
        end
        Element:SetPosition(rootId, Engine.Vector(
            playerPosition.X,
            playerPosition.Y,
            playerPosition.Z + config.CarryHeight
        ), Element.COORDINATE.World)
        context.Timers:AddFrame(TheftService.Name, config.BindDelayFrames, function()
            if not ValidatePending() then return end
            Element:BindingToCharacterOrCreature(
                rootId,
                playerId,
                config.CharacterSocket,
                config.SocketMode
            )
            context.Timers:AddFrame(TheftService.Name, config.VerifyDelayFrames, function()
                if not ValidatePending() then return end
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

    runtime.BeforeHurtCallback = function(playerId)
        if IsPositiveInteger(playerId) and zone:IsInStolenArea(playerId) then DropPlayerChicken(playerId, "before_hurt") end
    end
    runtime.FatalDamageCallback = function(playerId)
        if IsPositiveInteger(playerId) then
            DropPlayerChicken(playerId, "fatal_damage")
            ClearOwnedDisplay(playerId, "fatal_damage")
        end
    end
    runtime.PreleaveCallback = function(playerId)
        if not IsPositiveInteger(playerId) then return end
        local persistence = context.Services.PersistenceService
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(playerId) end
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
    runtime.BeforeHurtCallback = ProtectCallback("受伤前掉鸡回调失败", runtime.BeforeHurtCallback)
    runtime.FatalDamageCallback = ProtectCallback("携鸡死亡回调失败", runtime.FatalDamageCallback)
    runtime.PreleaveCallback = ProtectCallback("携鸡离开回调失败", runtime.PreleaveCallback)
    runtime.ManualDropCallback = ProtectCallback("主动放下回调失败", runtime.ManualDropCallback)
    runtime.CarrySnapshotCallback = ProtectCallback("携带快照回调失败", runtime.CarrySnapshotCallback)
    runtime.ModelSnapshotCallback = ProtectCallback("世界鸡模型快照失败", function(_, _, playerId)
        if not IsPositiveInteger(playerId) then return end
        SendWorldModels(playerId)
    end)

    context.Services.TheftService = runtime
    System:BindNotify(context.NetMsg.Messages.ChickenModelSnapshotRequest, runtime.ModelSnapshotCallback)
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
            if not chicken or snapshot.generation ~= runtime.Generation
                or snapshot.operation ~= chicken.operation or not chicken.playerId then return end
            DropPlayerChicken(chicken.playerId, "guardian_caught")
        end)
        System:RegisterEvent(Events.ON_ELEMENT_TOUCH_PLAYER, runtime.TouchCallback)
        System:RegisterEvent(Events.ON_BEFORE_CHARACTER_TAKE_HURT, runtime.BeforeHurtCallback)
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
        runtime.BeforeHurtCallback = nil
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
        for _, chicken in pairs(self.ChickensByRoot) do PauseCountdown(chicken) end
        self.ReturnReservations = {}
        self.PointOccupants = {}
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
        SendWorldModels()
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
            if not IsCurrent() then
                return end
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
                if not IsCurrent() then
                    return end
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
            if runtime.Stopped or context.Services.TheftService ~= runtime then
                return end
            if runtime.Generation == 0 then runtime:GenerateRegions() end
        end)

end

function TheftService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.TheftService
    if not runtime then return end
    runtime.Stopped = true
    for _, chicken in pairs(runtime.ChickensByRoot) do
        if chicken.countdownTimerId then context.Timers:Remove(chicken.countdownTimerId) end
        chicken.countdownEndMs, chicken.countdownTimerId = nil, nil
    end
    runtime.ReturnReservations = {}
    runtime.PointOccupants = {}
    runtime.SendWorldModels(nil, true)
    if runtime.ModelSnapshotCallback then
        System:UnbindNotify(context.NetMsg.Messages.ChickenModelSnapshotRequest, runtime.ModelSnapshotCallback)
    end
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
    if runtime.BeforeHurtCallback then
        System:UnregisterEvent(Events.ON_BEFORE_CHARACTER_TAKE_HURT, runtime.BeforeHurtCallback)
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
