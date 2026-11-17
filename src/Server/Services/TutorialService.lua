local GameConfig = require "Common.Config.GameConfig"
local TutorialService = { Name = "TutorialService", FeatureFlag = "Tutorial",
    Dependencies = { "PersistenceService", "HomeService", "ZoneService", "TheftService",
        "PlacementService", "EggProductionService", "InventoryService", "TreadmillService", "TrackShopService",
        "HomeUpgradeService", "PlayerSpeedService" } }

function TutorialService:Start(context)
    if context.Side ~= "Server" then return end
    local c, services = GameConfig.Tutorial, context.Services
    local home, zone, theft = services.HomeService, services.ZoneService, services.TheftService
    local persistence, placement, production = services.PersistenceService, services.PlacementService, services.EggProductionService
    local rt = { Active = true, Players = {}, Completed = {}, Teleports = {}, Version = 0 }
    services.TutorialService = rt
    local function Active() return rt.Active and services.TutorialService == rt end
    local function Send(id, state, step, root, position, force)
        if state.sendDisabled then return end
        local previous = state.sent
        if not force and previous and previous.step == step and previous.root == root
            and ((not position and not previous.position) or (position and previous.position
                and position.X == previous.position.X and position.Y == previous.position.Y and position.Z == previous.position.Z)) then return end
        rt.Version = rt.Version + 1
        local message = { version = rt.Version, step = step, targetId = root, position = position }
        state.sent = { step = step, root = root, position = position }
        local ok, err = pcall(function() System:SendToClient(id, context.NetMsg.Messages.TutorialState, message) end)
        if not ok then
            state.sendDisabled = true
            Log:PrintError("[Tutorial] 状态发送失败，不重试", id, tostring(err))
        end
    end
    local function Finish(id, state)
        state.step = "Done"
        rt.Completed[id] = true
        persistence:MarkDirty(id, "tutorial_completed")
    end
    local function EmptySlot(id)
        local occupied = {}
        for _, slot in ipairs(placement:GetPlacedSnapshot(id).slots) do occupied[slot.slotIndex] = true end
        local homeId = home:GetPlayerHome(id)
        for _, slot in ipairs(home:GetPlacementSlots(homeId)) do
            if not occupied[slot.slotIndex] and services.HomeUpgradeService:IsSlotUnlocked(id, slot.slotIndex) then return slot.elementId end
        end
    end
    local function HasEgg(id)
        for _, item in ipairs(services.InventoryService:GetSnapshot(id)) do
            if item.kind == "Egg" then return true end
        end
        return false
    end
    local function WorldTarget(id, state)
        local models, count = theft:GetTutorialTargets()
        local playerPosition = Character:GetPosition(id)
        if not playerPosition then return end
        -- 自己已开始破的蛋、出壳中的鸡及刚掉落的鸡，继续指引同一个根。
        for _, model in ipairs(models) do
            if model.attackPlayerId == id or (model.rootId == state.worldRoot and (model.state == "Hatching"
                or (model.state == "Available" and (not model.pickupPlayerId or model.pickupPlayerId == id))))
                or (model.rootId == state.droppedRoot and model.state == "Available"
                    and (not model.pickupPlayerId or model.pickupPlayerId == id)) then
                return model, model.state == "EggAttacking" and "Find" or "Take"
            end
        end
        local nearest, distance, priority
        for _, model in ipairs(models) do
            if not model.isDropped and model.regionId == c.RegionId and (model.state == "Egg"
                or (model.state == "Available" and (not model.pickupPlayerId or model.pickupPlayerId == id)) or model.state == "Hatching") then
                local p = model.position
                local d = (p.X-playerPosition.X)^2 + (p.Y-playerPosition.Y)^2 + (p.Z-playerPosition.Z)^2
                local rank = model.state == "Egg" and 1 or 2
                if not nearest or rank < priority or (rank == priority and (d < distance or (d == distance and model.rootId < nearest.rootId))) then
                    nearest, distance, priority = model, d, rank
                end
            end
        end
        if nearest then return nearest, nearest.state == "Egg" and "Find" or "Take" end
        if count == 0 then theft:EnsureTutorialRegion() end
    end
    local function Update(id, force)
        if not Active() then return end
        if not persistence:IsReady(id) then return end
        local state = rt.Players[id]
        if not state then return end
        if rt.Completed[id] and state.step ~= "Done" then Send(id, state, "Hidden", nil, nil, force); return end
        if not state.step then
            if not persistence:IsReady(id) or not rt.Teleports[id] or not home:GetPlayerHome(id) or zone:IsInStolenArea(id) then return end
            state.step = "Find"
        end
        local root, position
        if state.step == "Find" or state.step == "Take" then
            local model, step = WorldTarget(id, state)
            if model then
                state.worldRoot, state.step = model.rootId, step
                root, position = model.rootId, model.position
                -- 蛋与预备鸡共用缓存位置，指引身份使用对应的蛋根。
                if model.state == "Egg" or model.state == "EggAttacking" then root = model.eggRootId end
            end
        end
        if state.step == "Return" and not zone:IsInStolenArea(id) then state.step = "Place" end
        if state.step == "Place" and placement:GetPlacedSnapshot(id).count > 0 then state.step = "Wait" end
        if state.step == "Wait" or state.step == "Collect" then
            if HasEgg(id) then state.step = "Sell"
            else
                local snapshot = production:GetEggSnapshot(id)
                if snapshot and #snapshot.eggs > 0 then
                    state.step = "Collect"
                else state.step = "Wait" end
            end
        end
        if state.step == "Upgrade" and services.TreadmillService:GetLevel(id) > 1 then state.step = "Track" end
        if state.step == "Track" then
            local growth = services.PlayerSpeedService:GetSnapshot(id)
            if growth and growth.trackMask > 0 then Finish(id, state) end
        end
        if state.step == "Return" or state.step == "Place" then root = EmptySlot(id)
        elseif state.step == "Sell" then root = c.SellTargetId
        elseif state.step == "Upgrade" then
            local resources = home:GetTreadmillResources(home:GetPlayerHome(id))
            root = resources and resources.positionId
        elseif state.step == "Track" then root = c.TrackTargetId end
        if root and not position then position = Element:GetPosition(root) end
        Send(id, state, state.step, root, position, force)
    end
    local function On(event, callback)
        context.Events:Subscribe(self.Name, event, callback)
    end
    On("PlayerDataResetStarted", function(event)
        local state = rt.Players[event.playerId]
        if state then Send(event.playerId, state, "Hidden", nil, nil, true) end
    end)
    persistence:RegisterAdapter("tutorial", {
        Export = function(id) return { completed = rt.Completed[id] == true } end,
        Restore = function(id, data, done)
            rt.Completed[id] = data ~= nil and data.completed == true
            rt.Players[id] = {}
            done(true)
        end,
        Cleanup = function(id) rt.Players[id], rt.Completed[id], rt.Teleports[id] = nil, nil, nil end,
    })
    On("HomeTeleportCalled", function(event)
        local operation = event.operationId
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if Active() and home:IsTeleportOperationCurrent(event.playerId, event.homeId, operation) then
                rt.Teleports[event.playerId] = true
                Update(event.playerId)
            end
        end)
    end)
    On("HomeTeleportInvalidated", function(event) rt.Teleports[event.playerId] = nil end)
    On("HomeReleased", function(event)
        rt.Teleports[event.playerId] = nil
        local state = rt.Players[event.playerId]
        if state then state.step = nil; Send(event.playerId, state, "Hidden") end
    end)
    On("ChickenCarried", function(event)
        local state = rt.Players[event.playerId]
        if state and (state.step == "Find" or state.step == "Take") then
            state.step, state.worldRoot, state.droppedRoot, state.carrying = "Return", nil, nil, true
            Update(event.playerId)
        end
    end)
    On("StolenChickenDropped", function(event)
        local state = rt.Players[event.playerId]
        if state and (state.step == "Return" or state.step == "Place") then
            state.step, state.droppedRoot, state.carrying = "Take", event.chickenRootId, false
            Update(event.playerId)
        end
    end)
    On("StolenChickenOwned", function(event)
        local state = rt.Players[event.playerId]
        if state then state.carrying = false end
    end)
    On("TutorialWorldReset", function()
        for id, state in pairs(rt.Players) do
            if state.step == "Find" or state.step == "Take" or state.carrying then
                state.step, state.worldRoot, state.droppedRoot, state.carrying = "Find", nil, nil, false
                Update(id)
            end
        end
    end)
    On("TutorialEggSold", function(event)
        local state = rt.Players[event.playerId]
        if state and state.step == "Sell" then state.step = "Upgrade"; Update(event.playerId) end
    end)
    for _, event in ipairs({ "PersistenceReady", "ZoneChanged", "PlacedChickensChanged", "EggSpawned", "EggRemoved",
        "EggHatched", "InventoryChanged", "HomeLevelChanged", "TreadmillLevelChanged", "TutorialTrackPurchased" }) do
        On(event, function(data) Update(data.playerId) end)
    end
    rt.Snapshot = function(_, _, id) Update(id, true) end
    System:BindNotify(context.NetMsg.Messages.TutorialSnapshotRequest, rt.Snapshot)
    context.Timers:AddLoopTimer(self.Name, c.TargetCheckSeconds, function()
        for id, state in pairs(rt.Players) do
            if (not state.step or state.step == "Find" or state.step == "Take") and not rt.Completed[id] then Update(id) end
        end
    end)
end

function TutorialService:Stop(context)
    local rt = context.Services.TutorialService
    if not rt then return end
    rt.Active = false
    for id, state in pairs(rt.Players) do
        rt.Version = rt.Version + 1
        local ok, err = pcall(function()
            System:SendToClient(id, context.NetMsg.Messages.TutorialState, { version = rt.Version, step = "Hidden" })
        end)
        if not ok then Log:PrintError("[Tutorial] 停止通知失败", id, tostring(err)) end
    end
    System:UnbindNotify(context.NetMsg.Messages.TutorialSnapshotRequest, rt.Snapshot)
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.TutorialService = nil
end
return TutorialService
