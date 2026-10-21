local GameConfig = require "Common.Config.GameConfig"
local FeatureFlags = require "Common.Config.FeatureFlags"

local EggProductionService = { Name = "EggProductionService", FeatureFlag = "EggProduction",
    Dependencies = { "HomeService", "PlacementService" } }

if FeatureFlags.Values.HomeUpgrade then table.insert(EggProductionService.Dependencies, "HomeUpgradeService") end

local function Copy(record)
    local result = {}
    for key, value in pairs(record) do result[key] = value end
    return result
end

function EggProductionService:ValidateConfig(context)
    local errors = {}
    if GameConfig.Home.DefaultEggCapacity ~= 6 then errors[#errors + 1] = "Home.DefaultEggCapacity 必须为6" end
    for _, field in ipairs({ "EggPositionPurpose", "ChickenCountPurpose", "EggCountPurpose" }) do
        if type(GameConfig.Home[field]) ~= "string" or GameConfig.Home[field] == "" then
            errors[#errors + 1] = "Home." .. field .. " 必须是非空字符串"
        end
    end
    local growth = GameConfig.EggGrowth
    if type(growth) ~= "table" or growth.InitialScaleUnits ~= 50
        or growth.MinFinalScaleUnits ~= 50 or growth.MaxFinalScaleUnits ~= 250
        or growth.TextRefreshSeconds ~= 0.2 then
        errors[#errors + 1] = "EggGrowth 必须使用初始50、最终50~250整数档及0.2秒文字周期"
    end
    for _, field in ipairs({ "ValuePurpose", "MultiplierPurpose" }) do
        if not growth or type(growth[field]) ~= "string" or growth[field] == "" then
            errors[#errors + 1] = "EggGrowth." .. field .. " 必须是非空字符串"
        end
    end
    return #errors == 0, errors
end

function EggProductionService:Start(context)
    if context.Side ~= "Server" then return end
    local home, placement = context.Services.HomeService, context.Services.PlacementService
    local function Capacity(playerId)
        local upgrades = context.Services.HomeUpgradeService
        return upgrades and upgrades:GetEggCapacity(playerId) or GameConfig.Home.DefaultEggCapacity
    end
    local function ChickenCapacity(playerId)
        local upgrades = context.Services.HomeUpgradeService
        return upgrades and upgrades:GetChickenCapacity(playerId) or GameConfig.Home.DefaultChickenCapacity
    end
    local runtime = { Homes = {}, LastStateByHome = {}, Sequence = 0, GrowthVersion = 0, Stopped = false }
    context.Services.EggProductionService = runtime
    local persistence = context.Services.PersistenceService
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id))
    end
    local function PrepareLeave(id)
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(id) end
    end
    local function Now() return MiscService:GetServerTimestamp() end
    -- 缩放只由服务端写入；操作记录不进入蛋快照或存档。
    local growthOperations = {}
    local function GrowthError(egg, stage, message)
        Log:PrintError("[EggProduction] 成长缩放失败，不自动重试", "eggId:", egg.eggId,
            "rootId:", egg.rootId, "stage:", stage, "error:", tostring(message))
    end
    local function StopGrowth(egg)
        local operation = growthOperations[egg.eggId]
        if not operation or operation.egg ~= egg then return end
        growthOperations[egg.eggId] = nil -- 先失效等待中的两帧回调。
        if operation.animating then
            operation.animating = false
            local ok, err = pcall(function() Element:StopScaleTo(egg.rootId) end)
            if not ok then GrowthError(egg, "StopScaleTo_cleanup", err) end
        end
    end
    local function GrowthState(egg)
        return { eggId = egg.eggId, homeId = egg.homeId, rootId = egg.rootId,
            baseSellPrice = egg.baseSellPrice, finalScaleUnits = egg.finalScaleUnits,
            finalScale = egg.finalScale, finalSellPrice = egg.finalSellPrice,
            spawnedAtMs = egg.spawnedAtMs, hatchDeadlineMs = egg.hatchDeadlineMs, version = egg.version }
    end
    local function RemoveGrowth(egg)
        StopGrowth(egg)
        runtime.GrowthVersion = runtime.GrowthVersion + 1
        System:SendToAllClients(context.NetMsg.Messages.EggGrowthRemoved, {
            eggId = egg.eggId, homeId = egg.homeId, rootId = egg.rootId, version = runtime.GrowthVersion,
        })
        context.Events:Publish("EggRemoved", { eggId = egg.eggId, homeId = egg.homeId,
            playerId = egg.playerId, rootId = egg.rootId })
    end
    local function Current(house)
        return not runtime.Stopped and context.Services.EggProductionService == runtime
            and runtime.Homes[house.homeId] == house and home:IsOwner(house.playerId, house.homeId)
    end
    local function FinishGrowth(egg, operation)
        if operation.failed or operation.finalized then return end
        if operation.animating then
            local ok, err = pcall(function() Element:StopScaleTo(egg.rootId) end)
            if not ok then
                operation.failed = true
                GrowthError(egg, "StopScaleTo_mature", err)
                return
            end
            operation.animating = false
        end
        local ok, err = pcall(function()
            Element:SetScale(egg.rootId, Engine.Vector(egg.finalScale, egg.finalScale, egg.finalScale))
        end)
        operation.finalized = true
        if not ok then operation.failed = true; GrowthError(egg, "SetScale_mature", err) end
    end
    local function MarkMature(egg)
        local operation = growthOperations[egg.eggId]
        -- 零孵化时间也先等待副本落地，再定型及发布成熟通知。
        if egg.mature or not operation or not operation.landed then return end
        FinishGrowth(egg, operation)
        egg.mature = true
        context.Events:Publish("EggHatched", Copy(egg))
    end
    local function QueueGrowth(house, egg)
        local operation = { egg = egg, rootId = egg.rootId, version = egg.version }
        growthOperations[egg.eggId] = operation
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Current(house) or house.eggs[egg.eggId] ~= egg
                or growthOperations[egg.eggId] ~= operation
                or egg.rootId ~= operation.rootId or egg.version ~= operation.version then return end
            operation.landed = true
            local now = Now()
            local duration = egg.hatchDeadlineMs - egg.spawnedAtMs
            local remaining = egg.hatchDeadlineMs - now
            if duration <= 0 or remaining <= 0 then MarkMature(egg); return end
            local elapsed = math.max(0, math.min(duration, now - egg.spawnedAtMs))
            local initial = GameConfig.EggGrowth.InitialScaleUnits
            local current = (initial + (egg.finalScaleUnits - initial) * elapsed / duration) / 100
            local ok, err = pcall(function()
                Element:ScaleTo(egg.rootId, Engine.Vector(egg.finalScale, egg.finalScale, egg.finalScale),
                    remaining / 1000, Element.CURVE.linear, Engine.Vector(current, current, current))
            end)
            if ok then operation.animating = true
            else operation.failed = true; GrowthError(egg, "ScaleTo", err) end
        end)
    end
    local function Destroy(rootId, reason)
        local ok, result = pcall(function() return context.ElementCopy:DestroyTree(rootId) end)
        if not ok or result ~= true then
            Log:PrintError("[EggProduction] 完整蛋树清理失败", "rootId:", rootId,
                "reason:", reason, "error:", tostring(result))
        end
    end
    local function SendCount(house)
        if not Current(house) then return end
        if house.countBatch then house.countBatch.changed = true; return end
        local resources = home:GetEggResources(house.homeId) or {}
        local previous = runtime.LastStateByHome[house.homeId]
        local state = { homeId = house.homeId, playerId = house.playerId,
            chickenElementId = resources.chickenElementId, eggElementId = resources.eggElementId,
            chickenCount = house.chickenCount, chickenCapacity = ChickenCapacity(house.playerId),
            eggCount = house.count, eggCapacity = Capacity(house.playerId), version = previous and previous.version + 1 or 1 }
        runtime.LastStateByHome[house.homeId] = state
        System:SendToAllClients(context.NetMsg.Messages.HomeCountState, Copy(state))
    end
    function runtime:BeginCountBatch(playerId, homeId)
        local house = self.Homes[homeId]
        if not house or not Current(house) or house.playerId ~= playerId then return nil, "stale_home" end
        if house.countBatch then return nil, "count_batch_busy" end
        local batch = {}
        house.countBatch = batch
        return function()
            if house.countBatch ~= batch then return 0 end
            house.countBatch = nil
            if not Current(house) or not batch.changed then return 0 end
            SendCount(house)
            return 1
        end
    end
    -- 先结算旧占用条件下的时间；满容量和复制中的鸡不扣生产剩余时间。
    local function Advance(house, now)
        local elapsed = math.max(0, now - house.lastMs)
        house.lastMs = now
        if house.count + house.reserved < Capacity(house.playerId) then
            for _, chicken in pairs(house.chickens) do
                if not chicken.paused and not chicken.pending then
                    chicken.remainingMs = math.max(0, chicken.remainingMs - elapsed)
                end
            end
        end
        for _, egg in pairs(house.eggs) do
            if not egg.mature and now >= egg.hatchDeadlineMs then
                MarkMature(egg)
            end
        end
    end
    -- 升级方先用旧等级容量结算；无等待/通知的等级提交在本调用返回后执行。
    function runtime:AdvanceBeforeCapacityChange(playerId, homeId)
        if self.Stopped or context.Services.EggProductionService ~= self or not home:IsOwner(playerId, homeId) then
            return false, "production_unavailable"
        end
        local house = self.Homes[homeId]
        if house and Current(house) then Advance(house, Now()) end
        return true
    end
    context.Events:Subscribe(EggProductionService.Name, "HomeLevelChanged", function(state)
        local house = runtime.Homes[state.homeId]
        if house and house.playerId == state.playerId then SendCount(house) end
    end)
    local function Release(playerId, homeId)
        local house = runtime.Homes[homeId]
        if not house or house.playerId ~= playerId then return end
        runtime.Homes[homeId] = nil -- 身份先失效；迟到完整副本只能清理。
        for _, egg in pairs(house.eggs) do
            RemoveGrowth(egg) -- 删除版本先广播，再销毁树；旧状态不能复活已删除的蛋。
            Destroy(egg.rootId, "home_released")
        end
        house.chickens, house.eggs = {}, {}
        -- 不发布清零：空家园保留最后一次数量文字。
    end
    local function Sync(snapshot)
        if runtime.Stopped or not home.EggResourcesReady or not snapshot
            or not home:IsOwner(snapshot.playerId, snapshot.homeId) then return end
        local house = runtime.Homes[snapshot.homeId]
        if house and house.playerId ~= snapshot.playerId then Release(house.playerId, house.homeId); house = nil end
        local now = Now()
        if not house then
            house = { homeId = snapshot.homeId, playerId = snapshot.playerId, chickens = {},
                eggs = {}, count = 0, reserved = 0, chickenCount = 0, lastMs = now }
            runtime.Homes[house.homeId] = house
        elseif CanPlay(house.playerId) then Advance(house, now)
        else house.lastMs = now end
        local nextChickens = {}
        for _, slot in ipairs(snapshot.slots) do
            local previous = house.chickens[slot.slotIndex]
            local item = slot.chicken
            if previous and previous.rootId == slot.rootId and previous.itemId == item.itemId
                and previous.typeId == item.typeId then
                nextChickens[slot.slotIndex] = previous
            else
                local config = GameConfig.ChickenTypes[item.typeId]
                local egg = config and config.Egg
                if egg and egg.Enabled == true then
                    local valid = type(egg.TemplateRootId) == "number" and egg.TemplateRootId > 0
                        and type(egg.ProductionIntervalSeconds) == "number" and egg.ProductionIntervalSeconds > 0
                        and egg.ProductionIntervalSeconds < math.huge
                        and type(egg.HatchDurationSeconds) == "number" and egg.HatchDurationSeconds >= 0
                        and egg.HatchDurationSeconds < math.huge
                        and type(egg.SellPrice) == "number" and egg.SellPrice >= 0
                        and egg.SellPrice < math.huge and egg.SellPrice == math.floor(egg.SellPrice)
                    nextChickens[slot.slotIndex] = { itemId = item.itemId, typeId = item.typeId,
                        rootId = slot.rootId, slotIndex = slot.slotIndex, config = egg,
                        remainingMs = valid and egg.ProductionIntervalSeconds * 1000 or 0, paused = not valid }
                    if not valid then
                        Log:PrintError("[EggProduction] 蛋配置无效，仅暂停该鸡", "homeId:", house.homeId,
                            "itemId:", item.itemId, "typeId:", item.typeId)
                    end
                end
            end
        end
        -- 不取消旧鸡已发起复制；回调持有旧鸡记录，完成后不会再进入此表。
        house.chickens = nextChickens
        house.chickenCount = snapshot.count
        SendCount(house)
    end
    local function Spawn(house, chicken)
        if not CanPlay(house.playerId) or not Current(house) or chicken.pending or chicken.paused or house.count + house.reserved >= Capacity(house.playerId) then return end
        local resources = home:GetEggResources(house.homeId)
        if not resources or not resources.eggPositionElementId then return end
        house.reserved = house.reserved + 1
        chicken.pending = true
        local completed = false
        local function Complete(result)
            if completed then return end
            completed = true
            if not Current(house) then
                if result.success then Destroy(result.rootId, "late_egg_copy") end
                return
            end
            local now = Now()
            Advance(house, now)
            house.reserved = house.reserved - 1
            chicken.pending = false
            if not result.success then
                chicken.paused = true
                Log:PrintError("[EggProduction] 复制失败，释放预约并仅暂停该鸡；不自动重试",
                    "homeId:", house.homeId, "itemId:", chicken.itemId, "reason:", tostring(result.reason))
                return
            end
            runtime.Sequence = runtime.Sequence + 1
            local growth = GameConfig.EggGrowth
            local finalScaleUnits = math.random(growth.MinFinalScaleUnits, growth.MaxFinalScaleUnits)
            local baseSellPrice = chicken.config.SellPrice
            -- 整数缩放档先算价格分子，避免2.XX浮点倍率导致半整数误舍入。
            local finalSellPrice = baseSellPrice
                + math.floor((baseSellPrice * (finalScaleUnits - growth.InitialScaleUnits) + 50) / 100)
            runtime.GrowthVersion = runtime.GrowthVersion + 1
            local egg = { eggId = runtime.Sequence, homeId = house.homeId, playerId = house.playerId,
                chickenItemId = chicken.itemId, chickenTypeId = chicken.typeId,
                eggTypeId = chicken.config.EggTypeId, rootId = result.rootId,
                spawnedAtMs = now, hatchDeadlineMs = now + chicken.config.HatchDurationSeconds * 1000,
                mature = false, baseSellPrice = baseSellPrice, finalScaleUnits = finalScaleUnits,
                finalScale = finalScaleUnits / 100, finalSellPrice = finalSellPrice, version = runtime.GrowthVersion }
            house.eggs[egg.eggId] = egg
            QueueGrowth(house, egg)
            house.count = house.count + 1
            chicken.remainingMs = chicken.config.ProductionIntervalSeconds * 1000
            if persistence then persistence:MarkDirty(house.playerId, "production_cycle_completed") end
            SendCount(house)
            context.Events:Publish("EggSpawned", Copy(egg))
            System:SendToAllClients(context.NetMsg.Messages.EggGrowthState, GrowthState(egg))
        end
        local ok, errorMessage = pcall(function()
            local boxId = resources.eggPositionElementId
            local randomPosition = TriggerBox:GetRandomPosition(boxId)
            local origin = Element:GetPosition(boxId)
            if not randomPosition or not origin then error("触发盒随机位置或世界原点不可用") end
            local target = Engine.Vector(randomPosition.X, randomPosition.Y, origin.Z)
            context.ElementCopy:CopyTree(chicken.config.TemplateRootId, target,
                "家园产蛋:" .. tostring(house.homeId) .. ":" .. tostring(chicken.itemId), Complete)
        end)
        if not ok then Complete({ success = false, reason = tostring(errorMessage) }) end
    end
    function runtime:GetSceneEgg(eggId)
        for _, house in pairs(self.Homes) do
            local egg = house.eggs[eggId]
            if egg and Current(house) then return Copy(egg) end
        end
        return nil
    end

    -- 所有未来收取入口共用此同步提交；库存写入只由 InventoryService 执行。
    function runtime:CollectEgg(playerId, eggId, inventory)
        if not CanPlay(playerId) then return nil, "persistence_not_ready" end
        if type(playerId) ~= "number" or playerId <= 0 or playerId >= math.huge or playerId ~= math.floor(playerId)
            or type(eggId) ~= "number" or eggId <= 0 or eggId >= math.huge or eggId ~= math.floor(eggId) then
            return nil, "invalid_collection"
        end
        local homeId = home:GetPlayerHome(playerId)
        local house = homeId and self.Homes[homeId]
        if not house or not Current(house) then return nil, "not_home_owner" end
        local egg = house.eggs[eggId]
        if not egg then return nil, "egg_not_found" end
        if egg.collecting then return nil, "egg_busy" end
        local online = false
        for _, onlineId in ipairs(Character:GetAllPlayerIds() or {}) do
            if onlineId == playerId then online = true; break end
        end
        if not online then return nil, "player_offline" end
        local now = Now()
        if now < egg.hatchDeadlineMs then return nil, "egg_not_mature" end
        if inventory ~= context.Services.InventoryService or not inventory or type(inventory.AddEgg) ~= "function" then
            return nil, "inventory_unavailable"
        end
        egg.collecting = true -- 在成熟事件及库存事件发布前封锁同蛋重入。

        Advance(house, now) -- 按释放前占用结算冻结时间，腾位后仅续计。

        if not Current(house) or house.eggs[eggId] ~= egg then return nil, "egg_not_found" end

        local ok, item, reason = pcall(function()
            return inventory:AddEgg(playerId, { eggId = egg.eggId, eggTypeId = egg.eggTypeId,
                baseSellPrice = egg.baseSellPrice, finalScaleUnits = egg.finalScaleUnits,
                finalScale = egg.finalScale, finalSellPrice = egg.finalSellPrice })
        end)

        if not ok then
            -- 未知异常可能已写库存，保留源蛋并封锁再领，不猜测回滚。
            Log:PrintError("[EggCollection] 入库调用异常，保留源蛋并封锁重复领取", "eggId:", eggId,
                "playerId:", playerId, "error:", tostring(item))
            return nil, "inventory_add_error"
        end
        if not item then egg.collecting = false; return nil, reason end
        if house.eggs[eggId] == egg then
            house.eggs[eggId] = nil
            house.count = house.count - 1

            RemoveGrowth(egg)

            SendCount(house)

            Destroy(egg.rootId, "egg_collected")
        end
        return item, "collected"
    end

    function runtime:GetEggSnapshot(playerId)
        local homeId = home:GetPlayerHome(playerId)
        local house = homeId and self.Homes[homeId]
        if not house or not Current(house) then return nil end
        local result = { homeId = homeId, playerId = playerId, count = house.count,
            reserved = house.reserved, capacity = Capacity(playerId), eggs = {}, chickens = {} }
        for _, egg in pairs(house.eggs) do result.eggs[#result.eggs + 1] = Copy(egg) end
        table.sort(result.eggs, function(a, b) return a.eggId < b.eggId end)
        for slotIndex, chicken in pairs(house.chickens) do
            result.chickens[#result.chickens + 1] = { slotIndex = slotIndex, itemId = chicken.itemId,
                typeId = chicken.typeId, remainingMs = chicken.remainingMs,
                pending = chicken.pending == true, paused = chicken.paused == true }
        end
        table.sort(result.chickens, function(a, b) return a.slotIndex < b.slotIndex end)
        return result
    end
    local function Initialize()
        if runtime.Stopped or not home.EggResourcesReady then return end
        for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do Sync(placement:GetPlacedSnapshot(playerId)) end
    end
    context.Events:Subscribe(EggProductionService.Name, "HomeEggResourcesReady", Initialize)
    context.Events:Subscribe(EggProductionService.Name, "HomeAssigned", function(state)
        Sync(placement:GetPlacedSnapshot(state.playerId))
    end)
    context.Events:Subscribe(EggProductionService.Name, "PlacedChickensChanged", Sync)
    context.Events:Subscribe(EggProductionService.Name, "HomeReleased", function(state) Release(state.playerId, state.homeId) end)
    runtime.SnapshotCallback = function(_, _, playerId)
        if runtime.Stopped or context.Services.EggProductionService ~= runtime
            or type(playerId) ~= "number" or playerId <= 0 or playerId >= math.huge
            or playerId ~= math.floor(playerId) then return end
        for _, state in pairs(runtime.LastStateByHome) do
            System:SendToClient(playerId, context.NetMsg.Messages.HomeCountState, Copy(state))
        end
    end
    System:BindNotify(context.NetMsg.Messages.HomeCountSnapshotRequest, runtime.SnapshotCallback)
    runtime.GrowthSnapshotCallback = function(_, _, playerId)
        if runtime.Stopped or context.Services.EggProductionService ~= runtime
            or type(playerId) ~= "number" or playerId <= 0 or playerId >= math.huge
            or playerId ~= math.floor(playerId) then return end
        for _, house in pairs(runtime.Homes) do
            if Current(house) then
                for _, egg in pairs(house.eggs) do
                    System:SendToClient(playerId, context.NetMsg.Messages.EggGrowthState, GrowthState(egg))
                end
            end
        end
    end
    System:BindNotify(context.NetMsg.Messages.EggGrowthSnapshotRequest, runtime.GrowthSnapshotCallback)
    context.Timers:AddLoopTimer(EggProductionService.Name, 0.1, function()
        if runtime.Stopped or context.Services.EggProductionService ~= runtime or not home.EggResourcesReady then return end
        local now = Now()
        for _, homeId in ipairs(GameConfig.Home.RootElementIds) do
            local house = runtime.Homes[homeId]
            if house and Current(house) and CanPlay(house.playerId) then
                Advance(house, now)
                local slots = {}
                for slotIndex in pairs(house.chickens) do slots[#slots + 1] = slotIndex end
                table.sort(slots)
                for _, slotIndex in ipairs(slots) do
                    local chicken = house.chickens[slotIndex]
                    if chicken.remainingMs <= 0 then Spawn(house, chicken) end
                end
            end
        end
    end)
    if GameConfig.Persistence.ProductionEnabled then
        assert(persistence:RegisterAdapter("production", {
            Export = function(id)
                local homeId = home:GetPlayerHome(id)
                local house = homeId and runtime.Homes[homeId]
                if not house then return nil, "production_state_missing" end
                Advance(house, Now())
                local rows = {}
                for slotIndex, chicken in pairs(house.chickens) do
                    rows[#rows + 1] = { slotIndex, chicken.itemId, math.ceil(chicken.remainingMs) }
                end
                table.sort(rows, function(a,b) return a[1] < b[1] end)
                return { version = 1, cycles = rows }
            end,
            Restore = function(id, data, done)
                if data == nil then data = { version = 1, cycles = {} } end
                if data.version ~= 1 or type(data.cycles) ~= "table" or not home.EggResourcesReady then done(false, "invalid_production_snapshot"); return end
                Sync(placement:GetPlacedSnapshot(id))
                local homeId = home:GetPlayerHome(id)
                local house = homeId and runtime.Homes[homeId]
                if not house then done(false, "production_home_missing"); return end
                local seen, count = {}, 0
                for key in pairs(data.cycles) do
                    if type(key) ~= "number" or key < 1 or key > #data.cycles or key ~= math.floor(key) then done(false, "invalid_production_rows"); return end
                    count = count + 1
                end
                if count ~= #data.cycles then done(false, "invalid_production_rows"); return end
                for _, row in ipairs(data.cycles) do
                    local chicken = type(row) == "table" and house.chickens[row[1]]
                    if not chicken or #row ~= 3 or seen[row[1]] or row[2] ~= chicken.itemId or type(row[3]) ~= "number"
                        or row[3] < 0 or row[3] ~= math.floor(row[3]) or row[3] > math.ceil(chicken.config.ProductionIntervalSeconds * 1000) then
                        done(false, "invalid_production_cycle"); return
                    end
                    seen[row[1]] = true; chicken.remainingMs = row[3]
                end
                for slot in pairs(house.chickens) do if not seen[slot] then done(false, "missing_production_cycle"); return end end
                house.lastMs = Now()
                done(true, function() SendCount(house); return true end)
            end,
            Cleanup = function(id)
                local homeId = home:GetPlayerHome(id)
                if homeId then Release(id, homeId) end
            end,
        }))
        context.Events:Subscribe(self.Name, "PersistenceReady", function(event)
            local homeId = home:GetPlayerHome(event.playerId)
            local house = homeId and runtime.Homes[homeId]
            if house then house.lastMs = Now(); SendCount(house) end
        end)
        -- 周期进度与经验一样定期合并；产出时立即另标脏，场景蛋从不导出。
        context.Timers:AddLoopTimer(self.Name, 10, function()
            for _, house in pairs(runtime.Homes) do
                if Current(house) and CanPlay(house.playerId) and next(house.chickens) then persistence:MarkDirty(house.playerId, "production_progress") end
            end
        end)
    end
    runtime.Cleanup = function()
        runtime.Stopped = true
        for homeId, house in pairs(runtime.Homes) do Release(house.playerId, homeId) end
        runtime.LastStateByHome = {}
    end
    Initialize()
end

function EggProductionService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.EggProductionService
    if not runtime then return end
    runtime.Cleanup()
    System:UnbindNotify(context.NetMsg.Messages.HomeCountSnapshotRequest, runtime.SnapshotCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggGrowthSnapshotRequest, runtime.GrowthSnapshotCallback)
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.EggProductionService = nil
end

return EggProductionService
