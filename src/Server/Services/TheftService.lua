local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"

local TheftService = {
    Name = "TheftService",
    FeatureFlag = "Theft",
    Dependencies = { "ZoneService", "InventoryService" },
}

local Traceback = require("Common.Core.SafeCall").Traceback

local IsPositiveInteger = require("Common.Validation").IsPositiveInteger

local function CopyPosition(value)
    return Engine.Vector(value.X, value.Y, value.Z)
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function IsFinitePosition(position)
    return IsFiniteNumber(position.X) and IsFiniteNumber(position.Y) and IsFiniteNumber(position.Z)
end

local function PickupDistance(first, second)
    local dx = first.X - second.X
    local dy = first.Y - second.Y
    local dz = first.Z - second.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
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

local function ChooseChickenType(pool, field)
    field = field or "ChickenType"
    local totalWeight = 0
    for _, entry in ipairs(pool) do totalWeight = totalWeight + entry.Weight end
    local value = math.random() * totalWeight
    local cumulative = 0
    for _, entry in ipairs(pool) do
        cumulative = cumulative + entry.Weight
        if value <= cumulative then return entry[field] end
    end
    return pool[#pool][field]
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


local function StartupDiagnostic(stage, fields)
    pcall(function()
        local values = {}
        for name, read in pairs(fields or {}) do
            local readOK, value = pcall(read)
            local textOK, detail = pcall(tostring, value)
            values[#values + 1] = name .. "=" .. (textOK and detail or "<conversion_failed>")
                .. " readOK=" .. tostring(readOK)
        end
        pcall(function() Log:PrintServerLog("[TheftStartupDiag]", stage, table.concat(values, " | ")) end)
    end)
end

function TheftService:Start(context)
    StartupDiagnostic("start_enter", { side = function() return context.Side end })
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
        EggAttacks = {},
        Pickups = {},
        CarriedByPlayer = {},
        PendingByPlayer = {},
        OwnedDisplayByPlayer = {},
        OwnedDisplayRoots = {},
        BeginCallback = nil,
        CompleteCallback = nil,
        CancelCallback = nil,
        FatalDamageCallback = nil,
        PreleaveCallback = nil,
    }


    -- PICKUP_DIAG_BEGIN
    local function PickupDiagnostic(stage, read)
        pcall(function()
            Log:PrintServerLog("[PickupDiag][S]", stage, read())
        end)
    end
    -- PICKUP_DIAG_END

    -- DYNAMIC_DIAG_BEGIN
    runtime.DynamicChickenDiagnostic = { generation = -1, regions = {}, failures = {} }
    local function RecordDynamicChicken(chicken, templateId, generation, registration)
        pcall(function()
            local positionOK, position = pcall(function()
                local value = chicken.pickupPosition
                return value and (tostring(value.X) .. "," .. tostring(value.Y) .. "," .. tostring(value.Z)) or "nil"
            end)
            local collisionOK, collision = pcall(function() return Element:IsOpenCollision(chicken.rootId) end)
            local ids = {}
            for _, id in ipairs(chicken.spawnedIds or {}) do ids[#ids + 1] = tostring(id) end
            local row = "root=" .. tostring(chicken.rootId) .. " template=" .. tostring(templateId)
                .. " region=" .. tostring(chicken.regionId) .. " type=" .. tostring(chicken.chickenType)
                .. " spawnedIds=[" .. table.concat(ids, ",") .. "] positionOK=" .. tostring(positionOK)
                .. " positionSource=registration_actual_cache position=" .. tostring(position) .. " collisionOK=" .. tostring(collisionOK)
                .. " collision=" .. tostring(collision)
            if registration then
                local diagnostic = runtime.DynamicChickenDiagnostic
                if diagnostic.generation ~= generation then diagnostic.generation, diagnostic.regions, diagnostic.failures = generation, {}, {} end
                local rows = diagnostic.regions[chicken.regionId] or {}
                rows[#rows + 1] = row
                diagnostic.regions[chicken.regionId] = rows
            else
                Log:PrintServerLog("[DynamicChickenDiag][S] single", "generation:", generation, row)
            end
        end)
    end
    local function RecordDynamicChickenFailure(regionId, pointId, chickenType, templateId, generation, reason, result)
        pcall(function()
            if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation then return end
            local diagnostic = runtime.DynamicChickenDiagnostic
            if diagnostic.generation ~= generation then diagnostic.generation, diagnostic.regions, diagnostic.failures = generation, {}, {} end
            local fields = {}
            local function Field(name, read)
                local ok, value = pcall(function() return tostring(read()) end)
                fields[#fields + 1] = name .. "=" .. (ok and value or "unavailable")
            end
            local function Ids(name)
                if type(result) ~= "table" then return "unavailable" end
                local ids = {}
                for _, id in ipairs(result[name] or {}) do ids[#ids + 1] = tostring(id) end
                return "[" .. table.concat(ids, ",") .. "]"
            end
            Field("generation", function() return generation end)
            Field("region", function() return regionId end)
            Field("pointId", function() return pointId end)
            Field("type", function() return chickenType end)
            Field("template", function() return templateId end)
            Field("reason", function() return reason end)
            Field("failedSourceId", function() return type(result) == "table" and result.failedSourceId or "unavailable" end)
            Field("spawnedIds", function() return Ids("spawnedIds") end)
            Field("pendingSourceIds", function() return Ids("pendingSourceIds") end)
            local rows = diagnostic.failures[regionId] or {}
            rows[#rows + 1] = table.concat(fields, " ")
            diagnostic.failures[regionId] = rows
        end)
    end
    local function FlushDynamicChickenRegion(regionId, generation)
        pcall(function()
            local diagnostic = runtime.DynamicChickenDiagnostic
            local rows = diagnostic.generation == generation and diagnostic.regions[regionId] or {}
            rows = rows or {}
            local failures = diagnostic.generation == generation and diagnostic.failures[regionId] or {}
            failures = failures or {}
            if diagnostic.generation == generation then
                diagnostic.regions[regionId], diagnostic.failures[regionId] = nil, nil
            end
            Log:PrintServerLog("[DynamicChickenDiag][S] region", "generation:", generation,
                "region:", regionId, "successCount:", #rows, table.concat(rows, " | "),
                "failureCount:", #failures, "failures:", table.concat(failures, " | "))
        end)
    end
    -- DYNAMIC_DIAG_END

    local function SendResult(playerId, rootId, success, reason, operation, carryRetained, requestOperation)
        local chicken = runtime.ChickensByRoot[rootId]
        local currentOperation = operation or (chicken and chicken.operation)
        local failedRequestOperation = nil
        if not success then
            failedRequestOperation = requestOperation or currentOperation
        end
        System:SendToClient(playerId, context.NetMsg.Messages.PickupResult, {
            elementId = rootId,
            generation = runtime.Generation,
            success = success == true,
            reason = reason,
            operation = currentOperation,
            requestOperation = failedRequestOperation,
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

    local function Reject(playerId, rootId, reason, requestOperation)
        if IsPositiveInteger(playerId) then SendResult(playerId, rootId, false, reason, nil, nil, requestOperation) end
        Log:PrintServerLog("[TheftService] 拾取请求被拒绝",
            "playerId:", tostring(playerId),
            "rootId:", tostring(rootId),
            "reason:", tostring(reason))
        return false
    end

    local function ValidateDistance(playerId, rootId)
        local ok, playerPosition, chickenPosition = pcall(function()
            return Character:GetPosition(playerId), Element:GetPosition(rootId)
        end)
        if not ok or not playerPosition or not chickenPosition then
            return false, nil, nil, nil, "position_unavailable"
        end
        local distance = PickupDistance(playerPosition, chickenPosition)
        if distance > config.MaxHorizontalDistance then
            return false, playerPosition, chickenPosition, distance, "distance_exceeded"
        end
        return true, playerPosition, chickenPosition, distance, nil
    end

    local function ClearPlayerInteraction(playerId)
        runtime.Pickups[playerId] = nil
    end

    local function ClearRequest(playerId, rootId, operation)
        local record = runtime.Pickups[playerId]
        if not record or record.rootId ~= rootId or record.operation ~= operation then return end
        if record.generation == runtime.Generation then
            runtime.Pickups[playerId] = nil
        else
            -- 保留交互记录、只清按住计时；重建对象使重入复核能察觉这次变化。
            runtime.Pickups[playerId] = { rootId = record.rootId, operation = record.operation,
                generation = record.generation, inventorySession = record.inventorySession }
        end
    end

    local function IsPlayerReady(playerId)
        if not GameConfig.Persistence.ProductionEnabled then return true end
        local persistence = context.Services.PersistenceService
        return persistence ~= nil and persistence:IsReady(playerId)
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
                    countdownEndMs = chicken.countdownEndMs, state = chicken.state, playerId = chicken.playerId,
                    eggRootId = chicken.eggRootId, eggTypeId = chicken.eggTypeId, attackPlayerId = chicken.attackPlayerId,
                    regionId = chicken.regionId, position = { X = chicken.pickupPosition.X,
                        Y = chicken.pickupPosition.Y, Z = chicken.pickupPosition.Z }, isDropped = chicken.isDropped }
            end
        end
        runtime.ModelVersion = runtime.ModelVersion + 1
        local message = { source = "world", playerId = 0, version = runtime.ModelVersion, generation = runtime.Generation, models = models }
        local ok, reason = pcall(function()
            if recipient then System:SendToClient(recipient, context.NetMsg.Messages.ChickenModelState, message)
            else System:SendToAllClients(context.NetMsg.Messages.ChickenModelState, message) end
        end)
        if not ok then Log:PrintError("[TheftService] 世界鸡表现快照发送失败", tostring(reason)) end
    end
    runtime.SendWorldModels = SendWorldModels

    local function SendEggAttackSignal(playerId, signalName)
        local ok, reason = pcall(function() System:FireSignEvent(signalName, { playerId }) end)
        if not ok then Log:PrintError("[TheftService] 破蛋动作信号失败", playerId, signalName, tostring(reason)) end
    end

    local function CancelEggAttack(playerId, broadcast)
        local chicken = runtime.EggAttacks[playerId]
        if not chicken then return end
        runtime.EggAttacks[playerId] = nil
        if chicken.breakTimerId then context.Timers:Remove(chicken.breakTimerId); chicken.breakTimerId = nil end
        chicken.attackPlayerId = nil
        if chicken.state == "EggAttacking" then chicken.state = "Egg" end
        SendEggAttackSignal(playerId, "停止破蛋动作")
        if broadcast then SendWorldModels() end
    end
    local function ClearHatch(chicken)
        if chicken.attackPlayerId then CancelEggAttack(chicken.attackPlayerId, false) end
        if chicken.growthTimerId then context.Timers:Remove(chicken.growthTimerId); chicken.growthTimerId = nil end
        if chicken.state == "Hatching" then Element:StopScaleTo(chicken.rootId) end
        if chicken.eggRootId then context.ElementCopy:DestroyTree(chicken.eggRootId); chicken.eggRootId = nil end
    end
    runtime.ClearHatch = ClearHatch

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
        for playerId, record in pairs(runtime.Pickups) do
            if record.rootId == chicken.rootId and record.operation == operation then players[playerId] = record end
        end
        for playerId, request in pairs(players) do
            if runtime.Pickups[playerId] == request then
                ClearRequest(playerId, chicken.rootId, operation)
                SendResult(playerId, chicken.rootId, false, "chicken_relocated", chicken.operation, nil, operation)
            end
        end
    end

    local RegisterSpawnedChicken
    -- 每次请求独立完成一次；复制失败不影响区域进度，成功后的业务校验仍可停模块。
    local function CopyChicken(region, pointId, chickenType, position, generation, onFinished, reservation, registration)
        local templateId = GameConfig.ChickenTypes[chickenType].TemplateRootId
        local completed, accepted, cleaned = false, {}, {}
        local failureRecorded = false
        local function RecordFailure(reason, result)
            if not registration or failureRecorded then return end
            failureRecorded = true
            RecordDynamicChickenFailure(region.RegionId, pointId, chickenType, templateId, generation, reason, result)
        end
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
            local allIds = {}
            for _, id in ipairs(result.spawnedIds or {}) do allIds[#allIds + 1] = id end
            for _, id in ipairs(result.eggSpawnedIds or {}) do allIds[#allIds + 1] = id end
            for _, id in ipairs(allIds) do
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
        local function RegisterResult(result)
            if completed then Cleanup(result); return end
            if not Current() then
                completed = true
                Cleanup(result)
                ReleaseReservation()
                return
            end
            completed = true
            if type(result) == "table" and result.success == false then
                RecordFailure(result.reason, result)
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
                for _, id in ipairs(result.eggSpawnedIds or {}) do accepted[id] = true end
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
        local function Finish(result)
            if not Current() or not result.success or completed then RegisterResult(result); return end
            -- 同一点先备好鸡，再复制本区蛋；两者准备完毕才计为本次生成完成。
            local eggTypeId = ChooseChickenType(region.EggPool, "EggTypeId")
            local eggConfig
            for _, entry in pairs(GameConfig.ChickenTypes) do
                if entry.Egg.EggTypeId == eggTypeId then eggConfig = entry.Egg; break end
            end
            local ok, reason = pcall(function()
                Element:SetScale(result.rootId, Engine.Vector(config.HatchInitialScale, config.HatchInitialScale, config.HatchInitialScale))
                context.ElementCopy:CopyTree(eggConfig.TemplateRootId, CopyPosition(position), "偷取区蛋", function(eggResult)
                    result.eggSpawnedIds = eggResult.spawnedIds
                    if not Current() or completed then Cleanup(result); Cleanup(eggResult); return end
                    if not eggResult.success then
                        result.success, result.reason = false, "egg_copy_failed: " .. tostring(eggResult.reason)
                        result.failedSourceId, result.pendingSourceIds = eggResult.failedSourceId, eggResult.pendingSourceIds
                    else
                        result.eggRootId, result.eggTypeId = eggResult.rootId, eggTypeId
                    end
                    RegisterResult(result)
                end)
            end)
            if not ok and not completed then
                result.success, result.reason = false, "egg_copy_failed: " .. tostring(reason)
                RegisterResult(result)
            end
        end
        local ok, reason = pcall(function()
            context.ElementCopy:CopyTree(templateId, CopyPosition(position),
                "区域" .. tostring(region.RegionId) .. "生成点" .. tostring(pointId) .. "鸡", Finish)
        end)
        if not ok then
            LogFailure(reason)
            if completed then return end
            RecordFailure(reason, nil)
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
        local multiplier = 1
        if math.random(1, config.HighMultiplierChanceDenominator) == 1 then
            multiplier = config.HighMultiplierMin + math.random() * (config.HighMultiplierMax - config.HighMultiplierMin)
        end
        local finalSellPrice = math.floor(chickenConfig.ChickenSellPrice * multiplier)
        if not Decimal.FromSafeInteger(finalSellPrice) then error("生成鸡独立售价必须是非负安全整数") end
        CustomProperty:SetCustomProperty(result.rootId, config.RegionProperty, CustomProperty.PROPERTY_TYPE.Number, region.RegionId)
        local scale = finalSellPrice / chickenConfig.ChickenSellPrice
        Element:SetScale(result.eggRootId, Engine.Vector(scale, scale, scale))
        Element:SetEnableCollision(result.eggRootId, false)
        local pickupPosition = Element:GetPosition(result.rootId)
        if not pickupPosition or not IsFinitePosition(pickupPosition) then
            error("无法读取有效鸡根实际位置，rootId=" .. tostring(result.rootId))
        end
        runtime.ChickensByRoot[result.rootId] = {
            rootId = result.rootId,
            spawnedIds = result.spawnedIds,
            regionId = region.RegionId,
            spawnPointId = spawnPointId,
            spawnPosition = CopyPosition(spawnPosition),
            pickupPosition = CopyPosition(pickupPosition),
            isDropped = false,
            chickenType = chickenType,
            finalSellPrice = finalSellPrice,
            finalScale = scale,
            eggRootId = result.eggRootId,
            eggTypeId = result.eggTypeId,
            state = "Egg",
            playerId = nil,
            operation = 0,
        }
        ClaimPoint(runtime.ChickensByRoot[result.rootId])
        RecordDynamicChicken(runtime.ChickensByRoot[result.rootId], chickenConfig.TemplateRootId, generation, registration) -- DYNAMIC_DIAG
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
        local function SpawnNextPoint()
            if runtime.Stopped or context.Services.TheftService ~= runtime
                or runtime.Generation ~= generation then
                return end
            if completedCount == region.SpawnPointCount then
                SendWorldModels()
                FlushDynamicChickenRegion(region.RegionId, generation) -- DYNAMIC_DIAG
                onComplete()
                return
            end
            local currentSpawnPointId = spawnPoints[completedCount + 1]
            local position = Element:GetPosition(currentSpawnPointId)
            if not position then
                error("无法读取鸡生成点位置，spawnPointId=" .. tostring(currentSpawnPointId))
            end
            local remainingPool = {}
            for index, entry in ipairs(region.ChickenPool) do remainingPool[index] = entry end
            local function TryNextType()
                if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation then return end
                if #remainingPool == 0 then
                    completedCount = completedCount + 1
                    SpawnNextPoint()
                    return
                end
                local currentChickenType = ChooseChickenType(remainingPool)
                for index = #remainingPool, 1, -1 do
                    if remainingPool[index].ChickenType == currentChickenType then table.remove(remainingPool, index) end
                end
                CopyChicken(region, currentSpawnPointId, currentChickenType, position, generation, function(success)
                    if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation then return end
                    if success then
                        completedCount = completedCount + 1
                        SpawnNextPoint()
                    else
                        TryNextType()
                    end
                end, nil, registration)
            end
            TryNextType()
        end
        SpawnNextPoint()
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
        dropPosition.Z = chicken.pickupPosition.Z
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
                local landedPosition = Element:GetPosition(rootId)
                if not landedPosition or not IsFinitePosition(landedPosition) then error("原地掉鸡落地后无法读取有效位置") end
                if IsPositiveInteger(Element:GetAttachParentCharacter(rootId)) then error("掉落鸡仍附加角色") end
                chicken.pickupPosition = CopyPosition(landedPosition)
                chicken.isDropped = true
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

    function runtime:IsCarryingChicken(playerId, rootId, operation, generation)
        local chicken = self.ChickensByRoot[rootId]
        return context.Services.TheftService == self and self.Ready and not self.Stopped and not self.Refreshing
            and self.Generation == generation and self.CarriedByPlayer[playerId] == rootId
            and chicken ~= nil and chicken.state == "Carried" and chicken.playerId == playerId
            and chicken.operation == operation
    end

    function runtime:IsWorldChickenRoot(rootId)
        return self.ChickensByRoot[rootId] ~= nil
    end

    runtime.CarrySnapshotCallback = function(_, message, playerId)
        if not IsPositiveInteger(playerId) then return end
        for _, onlineId in ipairs(Character:GetAllPlayerIds() or {}) do
            if onlineId == playerId then
                zone:SendState(playerId)
                SendCarryState(playerId)
                return
            end
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
        PickupDiagnostic("acquire_enter", function() return "player=" .. tostring(playerId) .. " root=" .. tostring(rootId) .. " generation=" .. tostring(runtime.Generation) end) -- PICKUP_DIAG
        local chicken = runtime.ChickensByRoot[rootId]
        if not chicken or chicken.state ~= "Carried" or chicken.playerId ~= playerId then
            PickupDiagnostic("acquire_reject_identity", function() return "player=" .. tostring(playerId) .. " root=" .. tostring(rootId) .. " state=" .. tostring(chicken and chicken.state) .. " owner=" .. tostring(chicken and chicken.playerId) end) -- PICKUP_DIAG
            return
        end
        local allowed, admissionReason = CheckAdmission(playerId)
        PickupDiagnostic("acquire_admission", function() return "player=" .. tostring(playerId) .. " root=" .. tostring(rootId) .. " allowed=" .. tostring(allowed) .. " reason=" .. tostring(admissionReason) end) -- PICKUP_DIAG
        if not allowed then
            SendResult(playerId, rootId, false, admissionReason, chicken.operation, true)
            return
        end
        local item, reason = inventory:AddChicken(playerId, chicken.chickenType, chicken.finalSellPrice)
        PickupDiagnostic("acquire_add_return", function() return "player=" .. tostring(playerId) .. " root=" .. tostring(rootId) .. " itemId=" .. tostring(item and item.itemId) .. " accepted=" .. tostring(item ~= nil and item ~= false) .. " reason=" .. tostring(reason) end) -- PICKUP_DIAG
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

    local function ValidPickupRequest(message, playerId)
        return type(message) == "table" and IsPositiveInteger(playerId)
            and IsPositiveInteger(message.elementId) and type(message.operation) == "number"
            and message.operation >= 0 and message.operation == math.floor(message.operation)
            and message.generation == runtime.Generation
    end

    runtime.EggBreakBeginCallback = function(_, message, playerId)
        if not ValidPickupRequest(message, playerId) or not IsPositiveInteger(message.requestId) then return end
        local chicken = runtime.ChickensByRoot[message.elementId]
        local function Reply(success, reason)
            System:SendToClient(playerId, context.NetMsg.Messages.EggBreakResult, {
                elementId = message.elementId, operation = message.operation, generation = message.generation,
                requestId = message.requestId, success = success, reason = reason })
        end
        if runtime.Refreshing or not chicken or chicken.operation ~= message.operation or chicken.state ~= "Egg"
            or runtime.EggAttacks[playerId] or runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId]
            or runtime.Pickups[playerId] or not zone:IsInStolenArea(playerId) then Reply(false, "unavailable"); return end
        local valid, _, _, _, reason = ValidateDistance(playerId, chicken.rootId)
        if not valid then Reply(false, reason); return end
        runtime.EggAttacks[playerId] = chicken
        chicken.state, chicken.attackPlayerId = "EggAttacking", playerId
        chicken.attackRequestId = message.requestId
        SendEggAttackSignal(playerId, "播放破蛋动作")
        local generation, operation, requestId = runtime.Generation, chicken.operation, message.requestId
        chicken.breakTimerId = context.Timers:AddTimer(TheftService.Name, config.EggBreakSeconds, function()
            if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation
                or runtime.ChickensByRoot[chicken.rootId] ~= chicken or runtime.EggAttacks[playerId] ~= chicken
                or chicken.state ~= "EggAttacking" or chicken.operation ~= operation
                or chicken.attackRequestId ~= requestId then return end
            chicken.breakTimerId = nil
            local inRange = ValidateDistance(playerId, chicken.rootId)
            if not inRange or not zone:IsInStolenArea(playerId) or runtime.CarriedByPlayer[playerId]
                or runtime.PendingByPlayer[playerId] then CancelEggAttack(playerId, true); return end
            runtime.EggAttacks[playerId] = nil
            chicken.attackPlayerId = nil
            chicken.state = "Hatching"
            SendEggAttackSignal(playerId, "停止破蛋动作")
            context.ElementCopy:DestroyTree(chicken.eggRootId)
            chicken.eggRootId = nil
            Element:ScaleTo(chicken.rootId, Engine.Vector(chicken.finalScale, chicken.finalScale, chicken.finalScale),
                config.HatchGrowthSeconds, Element.CURVE.linear,
                Engine.Vector(config.HatchInitialScale, config.HatchInitialScale, config.HatchInitialScale))
            chicken.growthTimerId = context.Timers:AddTimer(TheftService.Name, config.HatchGrowthSeconds, function()
                if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation
                    or runtime.ChickensByRoot[chicken.rootId] ~= chicken or chicken.state ~= "Hatching" then return end
                chicken.growthTimerId = nil
                Element:StopScaleTo(chicken.rootId)
                Element:SetScale(chicken.rootId, Engine.Vector(chicken.finalScale, chicken.finalScale, chicken.finalScale))
                chicken.state = "Available"
                SendWorldModels()
            end)
            SendWorldModels()
        end)
        SendWorldModels()
        Reply(true, "attacking")
    end
    runtime.EggBreakCancelCallback = function(_, message, playerId)
        if not ValidPickupRequest(message, playerId) then return end
        local chicken = runtime.EggAttacks[playerId]
        if chicken and chicken.rootId == message.elementId and chicken.operation == message.operation
            and chicken.attackRequestId == message.requestId then CancelEggAttack(playerId, true) end
    end

    runtime.BeginCallback = function(_, message, playerId)
        if not ValidPickupRequest(message, playerId) then return end
        if runtime.EggAttacks[playerId] then return end
        local rootId, operation, generation = message.elementId, message.operation, message.generation
        local prior = runtime.Pickups[playerId]
        local function Refuse(reason)
            if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation
                or runtime.Pickups[playerId] ~= prior then return end
            ClearRequest(playerId, rootId, operation)
            Reject(playerId, rootId, reason, operation)
        end
        if runtime.Refreshing then Refuse("refreshing") return end
        local chicken = runtime.ChickensByRoot[rootId]
        if not chicken or chicken.operation ~= operation or chicken.state ~= "Available"
            then Refuse("target_not_available") return end
        if not CheckCountdown(chicken) then Refuse("target_expired") return end
        if not zone:IsInStolenArea(playerId) then Refuse("not_in_stolen_area") return end
        if runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId] then Refuse("player_already_carrying") return end
        local session = inventory:GetSessionGeneration(playerId)
        local valid, _, _, _, reason = ValidateDistance(playerId, rootId)
        local allowed, admissionReason = CheckAdmission(playerId)
        -- 引擎读取/依赖服务可能同步重入；旧检查不得覆盖后来建立的交互。
        if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation
            or runtime.Pickups[playerId] ~= prior then return end
        if runtime.ChickensByRoot[rootId] ~= chicken or chicken.operation ~= operation
            or chicken.state ~= "Available" then Refuse("target_not_available") return end
        if not valid then Refuse(reason) return end
        if not allowed then Refuse(admissionReason) return end
        local startedAtMs = MiscService:GetServerTimestamp()
        if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= generation
            or runtime.Pickups[playerId] ~= prior then return end
        runtime.Pickups[playerId] = { rootId = rootId, operation = operation,
            generation = generation, inventorySession = session, startedAtMs = startedAtMs }
    end

    runtime.CancelCallback = function(_, message, playerId)
        if not ValidPickupRequest(message, playerId) then return end
        if message.reason ~= "button_released" and message.reason ~= "distance_exceeded"
            and message.reason ~= "position_unavailable" and message.reason ~= "target_not_available"
            and message.reason ~= "not_in_stolen_area" then return end
        local rootId, operation = message.elementId, message.operation
        local record = runtime.Pickups[playerId]
        if record and record.rootId == rootId and record.operation == operation then
            if message.reason == "button_released" then
                -- 只清按住计时、保留交互记录；重建对象使重入复核能察觉这次变化。
                runtime.Pickups[playerId] = { rootId = record.rootId, operation = record.operation,
                    generation = record.generation, inventorySession = record.inventorySession }
            else
                ClearRequest(playerId, rootId, operation)
            end
        end
    end

    runtime.CompleteCallback = function(_, message, playerId)
        if not ValidPickupRequest(message, playerId) then return end
        local rootId, requestOperation, requestGeneration = message.elementId, message.operation, message.generation
        local prior = runtime.Pickups[playerId]
        local function Refuse(reason)
            if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= requestGeneration
                or runtime.Pickups[playerId] ~= prior then return end
            ClearRequest(playerId, rootId, requestOperation)
            Reject(playerId, rootId, reason, requestOperation)
        end
        if runtime.Refreshing then Refuse("refreshing") return end
        local record, chicken = runtime.Pickups[playerId], runtime.ChickensByRoot[rootId]
        if not chicken or chicken.operation ~= requestOperation or chicken.state ~= "Available" then Refuse("target_not_available") return end
        if not CheckCountdown(chicken) then Refuse("target_expired") return end
        if not record or not record.startedAtMs or record.rootId ~= rootId
            or record.operation ~= requestOperation then Refuse("hold_not_started") return end
        local allowed, admissionReason = CheckAdmission(playerId)
        if not allowed then Refuse(admissionReason) return end
        local elapsedMs = MiscService:GetServerTimestamp() - record.startedAtMs
        if elapsedMs < config.HoldSeconds * 1000 then Refuse("server_hold_time_not_reached") return end
        if runtime.CarriedByPlayer[playerId] or runtime.PendingByPlayer[playerId] then Refuse("player_already_carrying") return end
        if not zone:IsInStolenArea(playerId) then Refuse("not_in_stolen_area") return end
        local valid, playerPosition, chickenPosition, distance, distanceReason = ValidateDistance(playerId, rootId)
        if runtime.Stopped or context.Services.TheftService ~= runtime or runtime.Generation ~= requestGeneration
            or runtime.Pickups[playerId] ~= prior then return end
        if runtime.ChickensByRoot[rootId] ~= chicken or chicken.operation ~= requestOperation
            or chicken.state ~= "Available" then Refuse("target_not_available") return end
        if not valid then Refuse(distanceReason) return end

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
        local inventorySession = record.inventorySession
        chicken.inventorySession = inventorySession
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
            if not PendingCurrent() then return false end
            if validAdmission then return true end
            SendResult(playerId, rootId, false, pendingReason, operation, nil, requestOperation)
            if PendingCurrent() then DropPlayerChicken(playerId, "pickup_interrupted") end
            return false
        end
        SendWorldModels()
        if not PendingCurrent() then return end
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
                if not PendingCurrent() then return end
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
            CancelEggAttack(playerId, true)
            DropPlayerChicken(playerId, "fatal_damage")
            ClearOwnedDisplay(playerId, "fatal_damage")
        end
    end
    runtime.PreleaveCallback = function(playerId)
        if not IsPositiveInteger(playerId) then return end
        CancelEggAttack(playerId, true)
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

    runtime.BeginCallback = ProtectCallback("开始按住请求回调失败", runtime.BeginCallback)
    runtime.EggBreakBeginCallback = ProtectCallback("开始破蛋失败", runtime.EggBreakBeginCallback)
    runtime.EggBreakCancelCallback = ProtectCallback("取消破蛋失败", runtime.EggBreakCancelCallback)
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
            if snapshot.inStolenArea == false then CancelEggAttack(snapshot.playerId, true) end
            PickupDiagnostic("zone_changed", function() return "player=" .. tostring(snapshot.playerId) .. " inStolenArea=" .. tostring(snapshot.inStolenArea) .. " carriedRoot=" .. tostring(runtime.CarriedByPlayer[snapshot.playerId]) .. " refreshing=" .. tostring(runtime.Refreshing) .. " willAcquire=" .. tostring(snapshot.inStolenArea == false and not runtime.Refreshing and runtime.CarriedByPlayer[snapshot.playerId] ~= nil) end) -- PICKUP_DIAG
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
        System:RegisterEvent(Events.ON_BEFORE_CHARACTER_TAKE_HURT, runtime.BeforeHurtCallback)
        System:RegisterEvent(Events.ON_CHARACTER_TAKE_FATAL_DAMAGE, runtime.FatalDamageCallback)
        System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.PreleaveCallback)
        System:BindNotify(context.NetMsg.Messages.PickupBegin, runtime.BeginCallback)
        System:BindNotify(context.NetMsg.Messages.EggBreakBegin, runtime.EggBreakBeginCallback)
        System:BindNotify(context.NetMsg.Messages.EggBreakCancel, runtime.EggBreakCancelCallback)
        System:BindNotify(context.NetMsg.Messages.PickupComplete, runtime.CompleteCallback)
        System:BindNotify(context.NetMsg.Messages.PickupCancel, runtime.CancelCallback)
        System:BindNotify(context.NetMsg.Messages.TheftManualDrop, runtime.ManualDropCallback)
        System:BindNotify(context.NetMsg.Messages.TheftCarrySnapshotRequest, runtime.CarrySnapshotCallback)
    else
        runtime.BeginCallback = nil
        runtime.EggBreakBeginCallback, runtime.EggBreakCancelCallback = nil, nil
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
        for _, chicken in pairs(self.ChickensByRoot) do PauseCountdown(chicken); ClearHatch(chicken) end
        self.ReturnReservations = {}
        self.PointOccupants = {}
        self.Pickups = {}
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

    local function GenerationDiagnostic(stage, current)
        StartupDiagnostic(stage, {
            current = function() return context.Services.TheftService == current end,
            Generation = function() return current.Generation end,
            Ready = function() return current.Ready end,
            Generating = function() return current.Generating end,
            Refreshing = function() return current.Refreshing end,
            Stopped = function() return current.Stopped end,
            refreshRoots = function() return current.RefreshRoots ~= nil end,
        })
    end

    function runtime:GenerateRegions()
        GenerationDiagnostic("generate_enter", self)
        if self.Stopped or context.Services.TheftService ~= self
            or self.Generating or self.RefreshRoots then
            GenerationDiagnostic("generate_rejected", self)
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
    GenerationDiagnostic("startup_timer_register", runtime)
    context.Timers:AddTimer(TheftService.Name,
        GameConfig.Runtime.ServerReadyDelaySeconds, function()
            GenerationDiagnostic("startup_timer_fire", runtime)
            if runtime.Stopped or context.Services.TheftService ~= runtime then
                GenerationDiagnostic("startup_timer_skip_stopped_or_replaced", runtime)
                return end
            if runtime.Generation == 0 then runtime:GenerateRegions()
            else GenerationDiagnostic("startup_timer_skip_generation_not_zero", runtime) end
        end)
    GenerationDiagnostic("startup_timer_registered", runtime)

end

function TheftService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.TheftService
    if not runtime then return end
    runtime.Stopped = true
    runtime.DynamicChickenDiagnostic = nil -- DYNAMIC_DIAG
    for _, chicken in pairs(runtime.ChickensByRoot) do
        runtime.ClearHatch(chicken)
        if chicken.countdownTimerId then context.Timers:Remove(chicken.countdownTimerId) end
        chicken.countdownEndMs, chicken.countdownTimerId = nil, nil
    end
    runtime.ReturnReservations = {}
    runtime.PointOccupants = {}
    runtime.SendWorldModels(nil, true)
    if runtime.ModelSnapshotCallback then
        System:UnbindNotify(context.NetMsg.Messages.ChickenModelSnapshotRequest, runtime.ModelSnapshotCallback)
    end
    if runtime.EggBreakBeginCallback then
        System:UnbindNotify(context.NetMsg.Messages.EggBreakBegin, runtime.EggBreakBeginCallback)
        System:UnbindNotify(context.NetMsg.Messages.EggBreakCancel, runtime.EggBreakCancelCallback)
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
