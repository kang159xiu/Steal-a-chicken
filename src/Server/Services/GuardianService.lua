local GameConfig = require "Common.Config.GameConfig"
local GuardianTrackingService = require "Server.Services.GuardianTrackingService"
local Diagnostic = require "Common.Debug.GuardianDiagnostic"

local GuardianService = {
    Name = "GuardianService",
    FeatureFlag = "Guardian",
    Dependencies = {},
}

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function CopyPosition(value)
    return Engine.Vector(value.X, value.Y, value.Z)
end

local function ReadPurpose(elementId)
    local ok, value = pcall(function()
        return CustomProperty:GetCustomProperty(
            elementId,
            GameConfig.Theft.PurposeProperty,
            CustomProperty.PROPERTY_TYPE.String
        )
    end)
    if not ok then
        error("读取元件作用属性失败，elementId=" .. tostring(elementId)
            .. " error=" .. tostring(value))
    end
    return value
end

local function FindUniquePurposeElement(rootId, purpose, debugName)
    local matches = {}
    local visited = {}
    local function Visit(parentId)
        if visited[parentId] then
            error(debugName .. "元件树存在重复或循环，elementId=" .. tostring(parentId))
        end
        visited[parentId] = true
        local children = Element:GetChildElementsFromElement(parentId) or {}
        for _, childId in ipairs(children) do
            if ReadPurpose(childId) == purpose then
                matches[#matches + 1] = childId
            end
            Visit(childId)
        end
    end
    Visit(rootId)
    if #matches ~= 1 then
        error(debugName .. "必须且只能找到一个作用=" .. purpose
            .. "，rootId=" .. tostring(rootId)
            .. " actual=" .. tostring(#matches))
    end
    return matches[1]
end

local function BuildImpulse(guardianPosition, playerPosition, horizontalForce, upForce)
    local dx = playerPosition.X - guardianPosition.X
    local dy = playerPosition.Y - guardianPosition.Y
    local length = math.sqrt(dx * dx + dy * dy)
    if length <= 0 then
        error("守护者与玩家水平位置重合，无法计算击飞方向")
    end
    return Engine.Vector(dx / length * horizontalForce, dy / length * horizontalForce, upForce)
end

function GuardianService:ValidateConfig(context)
    if context.Side ~= "Server" then return true end
    local errors = {}
    if not IsPositiveInteger(GameConfig.Theft.GuardianPlayerAnchorSourceId) then
        errors[#errors + 1] = "Theft.GuardianPlayerAnchorSourceId必须是正整数"
    end
    local moveSeconds = GameConfig.Theft.GuardianManualMoveSeconds
    if type(moveSeconds) ~= "number" or moveSeconds ~= moveSeconds
        or moveSeconds <= 0 or moveSeconds == math.huge then
        errors[#errors + 1] = "Theft.GuardianManualMoveSeconds必须是有限正数"
    end
    if type(GameConfig.Regions) ~= "table" or #GameConfig.Regions ~= 15 then
        errors[#errors + 1] = "Regions 必须显式包含15个区域"
    end
    for index, region in ipairs(GameConfig.Regions or {}) do
        if region.RegionId ~= index then
            errors[#errors + 1] = "区域编号必须与数组顺序一致，index=" .. tostring(index)
        end
        if region.Enabled then
            local guardian = region.Guardian
            if type(guardian) ~= "table" then
                errors[#errors + 1] = "启用区域缺少 Guardian，region=" .. tostring(index)
            elseif not IsPositiveInteger(region.RegionRootId) then
                errors[#errors + 1] = "启用区域缺少 RegionRootId，region=" .. tostring(index)
            end
        end
    end
    return #errors == 0, errors
end

function GuardianService:Start(context)
    if context.Side ~= "Server" then return end

    local runtime = {
        Ready = false,
        Regions = {},
        Sequence = 0,
        ResetGeneration = 0,
        Resetting = false,
        Tracker = nil,
        Players = {},
        OwnedAnchors = {},
        Departed = {},
    }
    context.Services.GuardianService = runtime

    runtime.Tracker = GuardianTrackingService.New(
        GuardianService.Name,
        context.Timers,
        function(errorMessage)
            context.Manager:FailModule(GuardianService.Name, errorMessage)
        end
    )
    runtime.Tracker:Start()

    local OnAnchorRebinding, OnAnchorReady, OnAnchorFailed
    local sourceId = GameConfig.Theft.GuardianPlayerAnchorSourceId
    local function CurrentPlayer(player)
        return context.Services.GuardianService == runtime and runtime.Players[player.playerId] == player
    end
    local function AnchorLog(player, stage, reason)
        Log:PrintError("[GuardianService] 玩家追踪锚点失败", "playerId:", player.playerId,
            "anchorId:", tostring(player.anchorId), "stage:", stage, "reason:", tostring(reason))
    end
    local function AnchorCall(player, stage, callback)
        local ok, reason = pcall(callback)
        if not ok then
            player.ready, player.pending, player.failed = false, false, true
            AnchorLog(player, stage, reason)
            if CurrentPlayer(player) and OnAnchorFailed then OnAnchorFailed(player) end
        end
        return ok
    end
    local function DestroyAnchor(player, id)
        if not id or id == sourceId or runtime.OwnedAnchors[id] ~= player then return end
        runtime.OwnedAnchors[id] = nil
        AnchorCall(player, "destroy", function() Element:Destroy(id) end)
    end
    local function BindAnchor(player)
        if not CurrentPlayer(player) or not player.anchorId then return end
        player.version = player.version + 1
        local version, id = player.version, player.anchorId
        player.ready = false
        player.pending, player.failed = true, false
        for _, field in ipairs({ "bindTimer", "verifyTimer" }) do
            if player[field] then context.Timers:Remove(player[field]); player[field] = nil end
        end
        local function Current()
            return CurrentPlayer(player) and player.version == version and player.anchorId == id
        end
        player.bindTimer = context.Timers:AddFrame(GuardianService.Name,
            GameConfig.Runtime.EngineOperationDelayFrames, function()
                player.bindTimer = nil
                if not Current() then return end
                if not AnchorCall(player, "bind_root", function()
                    if not Element:GetPosition(id) then error("无法读取锚点位置") end
                    Element:BindingToCharacterOrCreature(id, player.playerId,
                        Character.SOCKET_NAME.Root, Character.SOCKET_MODE.SnapToTarget)
                end) then return end
                player.verifyTimer = context.Timers:AddFrame(GuardianService.Name,
                    GameConfig.Runtime.EngineOperationDelayFrames, function()
                        player.verifyTimer = nil
                        if not Current() then return end
                        if not AnchorCall(player, "verify_root", function()
                            if Element:GetAttachParentCharacter(id) ~= player.playerId then
                                error("锚点Root附加校验不匹配")
                            end
                            player.ready = true
                            player.pending = false
                        end) then return end
                        if OnAnchorReady then OnAnchorReady(player) end
                    end)
            end)
    end
    local function SpawnAnchor(player)
        if not CurrentPlayer(player) or player.spawnRequested then return end
        player.spawnRequested = true
        player.pending = true
        AnchorCall(player, "spawn", function()
            local position = Character:GetPosition(player.playerId)
            if not position then error("无法读取玩家位置") end
            Element:SpawnElement(Element.SPAWN_SOURCE.Scene, sourceId, function(id)
                if not IsPositiveInteger(id) or id == sourceId then
                    player.pending, player.failed = false, true
                    if CurrentPlayer(player) and OnAnchorFailed then OnAnchorFailed(player) end
                    AnchorLog(player, "spawn_callback", "未返回独立副本: " .. tostring(id)); return
                end
                -- 只认领本请求生成的独立ID；重复/旧会话回调不得清理新会话或别人的副本。
                if runtime.OwnedAnchors[id] then
                    if runtime.OwnedAnchors[id] ~= player then
                        player.pending, player.failed = false, true
                        if CurrentPlayer(player) and OnAnchorFailed then OnAnchorFailed(player) end
                        AnchorLog(player, "spawn_callback", "副本ID已由其他会话持有: " .. tostring(id))
                    end
                    return
                end
                runtime.OwnedAnchors[id] = player
                if not CurrentPlayer(player) or player.anchorId then DestroyAnchor(player, id); return end
                player.anchorId = id
                BindAnchor(player)
            end, CopyPosition(position), Engine.Rotator(0, 0, 0), 1, false)
        end)
    end
    runtime.EnterCallback = function(playerId)
        if context.Services.GuardianService ~= runtime or not IsPositiveInteger(playerId) then return end
        runtime.Departed[playerId] = nil
        if runtime.Players[playerId] then return end
        local player = { playerId = playerId, version = 0, ready = false }
        runtime.Players[playerId] = player
        if runtime.Ready then SpawnAnchor(player) end
    end
    runtime.LeaveCallback = function(playerId)
        if context.Services.GuardianService ~= runtime then return end
        runtime.Departed[playerId] = true
        local player = runtime.Players[playerId]
        if not player then return end
        runtime.Players[playerId] = nil
        player.version = player.version + 1
        player.ready = false
        if player.bindTimer then context.Timers:Remove(player.bindTimer) end
        if player.verifyTimer then context.Timers:Remove(player.verifyTimer) end
        DestroyAnchor(player, player.anchorId)
    end
    runtime.ReviveCallback = function(playerId)
        if context.Services.GuardianService ~= runtime or runtime.Departed[playerId] then return end
        local player = runtime.Players[playerId]
        if not player then runtime.EnterCallback(playerId); return end
        player.ready = false
        if OnAnchorRebinding then OnAnchorRebinding(player) end
        if player.anchorId then BindAnchor(player) end
    end
    runtime.AnchorBindings = {
        { Events.ON_PLAYER_ENTER, runtime.EnterCallback },
        { Events.ON_PLAYER_JOIN_MIDWAY, runtime.EnterCallback },
        { Events.ON_PLAYER_RECONNECTED, runtime.EnterCallback },
        { Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback },
        { Events.ON_PLAYER_LEAVE, runtime.LeaveCallback },
        { Events.ON_CHARACTER_RESPAWN, runtime.ReviveCallback },
        { Events.ON_CHARACTER_REVIVED, runtime.ReviveCallback },
    }
    for _, binding in ipairs(runtime.AnchorBindings) do System:RegisterEvent(binding[1], binding[2]) end
    runtime.DestroyAnchor = DestroyAnchor

    local StartNext
    local function IsActive(regionRuntime, active)
        return context.Services.GuardianService == runtime and not runtime.Resetting
            and runtime.ResetGeneration == active.generation
            and runtime.Regions[regionRuntime.Config.RegionId] == regionRuntime
            and regionRuntime.Active == active
    end
    -- 诊断独立拥有计时器；不改变追踪模块的运动与取消入口。
    local diagnosticOwner = "GuardianDiagnosticServer"
    local diagnosticRevision = 0
    local function Sample(regionRuntime, active, phase)
        Diagnostic.Safe(function()
            diagnosticRevision = diagnosticRevision + 1
            local message = { regionId = regionRuntime.Config.RegionId, sequence = active.sequence,
                generation = active.generation, revision = diagnosticRevision, phase = phase,
                guardianId = regionRuntime.GuardianElementId, targetId = active.movementTargetId,
                playerId = active.playerId, anchorId = active.anchorId,
                chickenRootId = active.rootId, movementTargetId = active.movementTargetId,
                sentTime = Diagnostic.Time() }
            if phase ~= "invalidated" then Diagnostic.Sample("Server", message) end
            for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do
                Diagnostic.Safe(function()
                    System:SendToClient(playerId, context.NetMsg.Messages.GuardianDiagnosticSample, message)
                end)
            end
        end)
    end
    runtime.InvalidateDiagnostic = function(regionRuntime, active)
        if active then Sample(regionRuntime, active, "invalidated") end
    end
    local function ScheduleSample(regionRuntime, active, frames, delay, phase)
        local revision = active.trackingRevision
        Diagnostic.Safe(function()
            local function Read()
                Diagnostic.Safe(function()
                    if not IsActive(regionRuntime, active) or active.state ~= "Tracking"
                        or active.trackingRevision ~= revision then return end
                    Sample(regionRuntime, active, phase)
                end)
            end
            if frames then context.Timers:AddFrame(diagnosticOwner, delay, Read)
            else context.Timers:AddTimer(diagnosticOwner, delay, Read) end
        end)
    end

    local function RemoveCandidate(regionRuntime, rootId, operation, generation)
        for index = #regionRuntime.Candidates, 1, -1 do
            local candidate = regionRuntime.Candidates[index]
            if candidate.rootId == rootId
                and (operation == nil or candidate.operation == operation)
                and (generation == nil or candidate.chickenGeneration == generation) then
                table.remove(regionRuntime.Candidates, index)
            end
        end
    end

    local function FinishActive(regionRuntime, active, result)
        if not IsActive(regionRuntime, active) then return end
        Sample(regionRuntime, active, "returned")
        regionRuntime.Active = nil
        Log:PrintServerLog("[GuardianService] 守护者目标已结束",
            "regionId:", regionRuntime.Config.RegionId,
            "rootId:", active.rootId,
            "resolution:", tostring(active.resolution),
            "guardianPosition:", tostring(result and result.guardianPosition))
        StartNext(regionRuntime)
    end

    local BeginTracking, ReturnGuardian
    BeginTracking = function(regionRuntime, active)
        if not IsActive(regionRuntime, active)
            or (active.state ~= "Delay" and active.state ~= "Approaching")
            or active.firstTrackingWait then return end
        active.delayTimerId = nil
        local revision = active.trackingRevision
        if not regionRuntime.FirstTrackingReady then
            if not regionRuntime.FirstTrackingPositionSet then
                Sample(regionRuntime, active, "initial_position_before")
                Element:SetPosition(regionRuntime.GuardianElementId,
                    regionRuntime.GuardianReturnPosition, Element.COORDINATE.World)
                regionRuntime.FirstTrackingPositionSet = true
                Sample(regionRuntime, active, "initial_position_after")
            end
            -- 保留原Delay/Approaching取消分支；同一目标不可重复安排等待。
            active.firstTrackingWait = true
            local expectedState = active.state
            active.delayTimerId = context.Timers:AddFrame(GuardianService.Name,
                GameConfig.Runtime.EngineOperationDelayFrames, function()
                    if not IsActive(regionRuntime, active) or active.state ~= expectedState
                        or not active.firstTrackingWait or active.trackingRevision ~= revision then return end
                    active.delayTimerId = nil
                    active.firstTrackingWait = nil
                    regionRuntime.FirstTrackingReady = true
                    Sample(regionRuntime, active, "initial_position_after_two_frames")
                    BeginTracking(regionRuntime, active)
                end)
            return
        end
        local movementTargetId = active.rootId
        if active.playerId then
            local player = runtime.Players[active.playerId]
            if not player or not player.ready then
                if player and player.pending and not player.failed then
                    active.state = "AnchorPending"
                    return
                end
                active.state = "AnchorUnavailable"
                AnchorLog(player or { playerId = active.playerId }, "begin_tracking", "锚点未就绪，不改追其他目标")
                return
            end
            local ok, parentId = pcall(function() return Element:GetAttachParentCharacter(player.anchorId) end)
            if not ok or parentId ~= active.playerId then
                player.ready = false
                active.state = "AnchorUnavailable"
                AnchorLog(player, "begin_tracking", "Root附加失效: " .. tostring(parentId))
                return
            end
            active.anchorId = player.anchorId
            movementTargetId = player.anchorId
        else
            active.anchorId = nil
        end
        active.movementTargetId = movementTargetId
        active.state = "Tracking"
        local guardianConfig = regionRuntime.Config.Guardian
        Sample(regionRuntime, active, "before_tracking")
        local request = {
            debugName = "区域" .. tostring(regionRuntime.Config.RegionId)
                .. "守护者追踪鸡" .. tostring(active.rootId),
            guardianElementId = regionRuntime.GuardianElementId,
            triggerBoxId = regionRuntime.TriggerBoxId,
            targetElementId = active.rootId,
            movementTargetId = movementTargetId,
            returnTargetOnCaught = false,
            guardianReturnPosition = regionRuntime.GuardianReturnPosition,
            targetReturnPosition = active.spawnPosition,
            initialSpeed = guardianConfig.InitialSpeed,
            acceleration = guardianConfig.Acceleration,
            maxVelocity = guardianConfig.MaxSpeed,
            distanceKeep = guardianConfig.KeepDistance,
            onCaught = function(caughtResult)
                if not IsActive(regionRuntime, active) or active.state ~= "Tracking"
                    or active.trackingRevision ~= revision then return end
                Sample(regionRuntime, active, "invalidated")
                local caughtPlayerId = active.playerId
                active.state = "Caught"
                active.resolution = "caught"
                context.Events:Publish("GuardianCaughtChicken", {
                    regionId = regionRuntime.Config.RegionId,
                    chickenRootId = active.rootId,
                    playerId = active.playerId,
                    operation = active.operation,
                    generation = active.chickenGeneration,
                })
                if caughtPlayerId then
                    local playerPosition = Character:GetPosition(caughtPlayerId)
                    if not playerPosition then
                        error("守护者命中时无法读取玩家位置")
                    end
                    local impulse = BuildImpulse(
                        caughtResult.guardianPosition,
                        playerPosition,
                        guardianConfig.KnockbackHorizontalForce,
                        guardianConfig.KnockbackUpForce
                    )
                    Character:AddImpulse(caughtPlayerId, impulse)
                    Log:PrintServerLog("[GuardianService] 守护者命中并击飞玩家",
                        "regionId:", regionRuntime.Config.RegionId,
                        "playerId:", caughtPlayerId,
                        "chickenRootId:", active.rootId,
                        "horizontalForce:", guardianConfig.KnockbackHorizontalForce,
                        "upForce:", guardianConfig.KnockbackUpForce)
                end
                if IsActive(regionRuntime, active) and active.state == "Caught" then
                    ReturnGuardian(regionRuntime, active, "guardian_caught")
                end
            end,
            onReturned = function(result)
                if active.trackingRevision ~= revision then return end
                FinishActive(regionRuntime, active, result)
            end,
        }
        local ok, started, reason = pcall(function() return runtime.Tracker:TrackTarget(request) end)
        if not ok or not started then
            Sample(regionRuntime, active, "invalidated")
            active.state = "TrackingFailed"
            Log:PrintError("[GuardianService] 守护者开始追踪失败，不重试或改追其他目标",
                "regionId:", regionRuntime.Config.RegionId, "playerId:", tostring(active.playerId),
                "anchorId:", tostring(active.anchorId), "chickenRootId:", active.rootId,
                "movementTargetId:", movementTargetId, "reason:", tostring(ok and reason or started))
            return
        end
        active.hasTracked = true
        ScheduleSample(regionRuntime, active, true, GameConfig.Runtime.EngineOperationDelayFrames, "after_two_frames")
        ScheduleSample(regionRuntime, active, false, 1, "after_one_second")
    end

    -- 只替换运动会话；旧命中/返程/采样回调不能接管切换后的鸡。
    local function InvalidateTracking(regionRuntime, active)
        Sample(regionRuntime, active, "invalidated")
        active.trackingRevision = active.trackingRevision + 1
        if active.delayTimerId then context.Timers:Remove(active.delayTimerId) end
        active.delayTimerId, active.firstTrackingWait = nil, nil
        if active.state == "Tracking" then
            runtime.Tracker:CancelGuardian(regionRuntime.GuardianElementId, "movement_target_changed")
        end
    end
    local function ContinueTracking(regionRuntime, active)
        active.state = "Delay"
        local revision = active.trackingRevision
        local delay = math.max(0, (active.readyAtMs - MiscService:GetServerTimestamp()) / 1000)
        if delay == 0 then BeginTracking(regionRuntime, active); return end
        active.delayTimerId = context.Timers:AddTimer(GuardianService.Name, delay, function()
            if IsActive(regionRuntime, active) and active.trackingRevision == revision then
                BeginTracking(regionRuntime, active)
            end
        end)
    end
    OnAnchorRebinding = function(player)
        for _, regionRuntime in pairs(runtime.Regions) do
            local active = regionRuntime.Active
            if active and active.playerId == player.playerId
                and (active.state == "Tracking" or active.state == "Delay" or active.state == "AnchorUnavailable"
                    or active.state == "AnchorPending") then
                InvalidateTracking(regionRuntime, active)
                active.state = "AnchorRebinding"
            end
        end
    end
    OnAnchorReady = function(player)
        for _, regionRuntime in pairs(runtime.Regions) do
            local active = regionRuntime.Active
            if active and active.playerId == player.playerId
                and (active.state == "AnchorRebinding" or active.state == "AnchorPending")
                and IsActive(regionRuntime, active) then ContinueTracking(regionRuntime, active) end
        end
    end
    OnAnchorFailed = function(player)
        for _, regionRuntime in pairs(runtime.Regions) do
            local active = regionRuntime.Active
            if active and active.playerId == player.playerId
                and (active.state == "AnchorPending" or active.state == "AnchorRebinding") then
                active.state = "AnchorUnavailable"
            end
        end
    end

    ReturnGuardian = function(regionRuntime, active, reason)
        if not IsActive(regionRuntime, active) then return end
        if active.delayTimerId then context.Timers:Remove(active.delayTimerId) end
        active.delayTimerId = nil
        Sample(regionRuntime, active, "invalidated")
        active.trackingRevision = active.trackingRevision + 1
        active.state = "ManualReturning"
        active.resolution = reason
        active.playerId = nil
        runtime.Tracker:CancelGuardian(regionRuntime.GuardianElementId, reason)
        local started, failure = runtime.Tracker:MoveGuardian({
            guardianElementId = regionRuntime.GuardianElementId,
            position = regionRuntime.GuardianReturnPosition,
            seconds = GameConfig.Theft.GuardianManualMoveSeconds,
            reason = reason,
            onArrived = function(result)
                if not IsActive(regionRuntime, active) or active.state ~= "ManualReturning" then return end
                FinishActive(regionRuntime, active, result)
            end,
        })
        if not started then error("主动放下后守护者返程失败: " .. tostring(failure)) end
    end

    StartNext = function(regionRuntime)
        if runtime.Resetting or context.Services.GuardianService ~= runtime then return end
        if regionRuntime.Active or #regionRuntime.Candidates == 0 then return end
        local selectedIndex = 1
        for index = 2, #regionRuntime.Candidates do
            if regionRuntime.Candidates[index].sequence
                > regionRuntime.Candidates[selectedIndex].sequence then
                selectedIndex = index
            end
        end
        local active = table.remove(regionRuntime.Candidates, selectedIndex)
        regionRuntime.Active = active
        if active.manualRepickup then
            active.state = "Approaching"
            local started, failure = runtime.Tracker:MoveGuardian({
                guardianElementId = regionRuntime.GuardianElementId,
                position = active.pickupPosition,
                seconds = GameConfig.Theft.GuardianManualMoveSeconds,
                reason = "manual_repickup_approach",
                onArrived = function()
                    if not IsActive(regionRuntime, active) or active.state ~= "Approaching" then return end
                    BeginTracking(regionRuntime, active)
                end,
            })
            if not started then error("守护者接近再拾取位置失败: " .. tostring(failure)) end
            return
        end
        local delaySeconds = math.max(0, (active.readyAtMs - MiscService:GetServerTimestamp()) / 1000)
        ContinueTracking(regionRuntime, active)
        Log:PrintServerLog("[GuardianService] 守护者目标进入延迟",
            "regionId:", regionRuntime.Config.RegionId,
            "rootId:", active.rootId,
            "delaySeconds:", delaySeconds,
            "sequence:", active.sequence)
    end

    context.Events:Subscribe(GuardianService.Name, "ChickenCarried", function(snapshot)
        if context.Services.GuardianService ~= runtime then return end
        local regionRuntime = runtime.Regions[snapshot.regionId]
        if not runtime.Ready or runtime.Resetting or not regionRuntime then return end
        runtime.Sequence = runtime.Sequence + 1
        regionRuntime.Candidates[#regionRuntime.Candidates + 1] = {
            rootId = snapshot.chickenRootId,
            playerId = snapshot.playerId,
            spawnPosition = CopyPosition(snapshot.spawnPosition),
            manualRepickup = snapshot.manualRepickup == true,
            pickupPosition = snapshot.pickupPosition and CopyPosition(snapshot.pickupPosition),
            operation = snapshot.operation,
            chickenGeneration = snapshot.generation,
            generation = runtime.ResetGeneration,
            sequence = runtime.Sequence,
            readyAtMs = MiscService:GetServerTimestamp()
                + regionRuntime.Config.Guardian.TrackDelaySeconds * 1000,
            resolution = nil,
            trackingRevision = 0,
        }
        StartNext(regionRuntime)
    end)

    context.Events:Subscribe(GuardianService.Name, "StolenChickenDropped", function(snapshot)
        if context.Services.GuardianService ~= runtime or runtime.Resetting then return end
        local regionRuntime = runtime.Regions[snapshot.regionId]
        if not regionRuntime then return end
        RemoveCandidate(regionRuntime, snapshot.chickenRootId, snapshot.previousOperation, snapshot.generation)
        local active = regionRuntime.Active
        if active and active.rootId == snapshot.chickenRootId
            and active.operation == snapshot.previousOperation
            and active.chickenGeneration == snapshot.generation then
            ReturnGuardian(regionRuntime, active, snapshot.reason .. "_drop")
        end
    end)

    context.Events:Subscribe(GuardianService.Name, "StolenChickenRelocated", function(snapshot)
        if context.Services.GuardianService ~= runtime or runtime.Resetting then return end
        local regionRuntime = runtime.Regions[snapshot.regionId]
        if not regionRuntime then return end
        RemoveCandidate(regionRuntime, snapshot.chickenRootId, nil, snapshot.generation)
        local active = regionRuntime.Active
        if not active or active.rootId ~= snapshot.chickenRootId
            or active.chickenGeneration ~= snapshot.generation then return end
        -- 主动放下后的守护者可能仍在独立返程；不重启、也不取消这次返程。
        if active.state == "ManualReturning" then
            active.rootId = nil
            return
        end
        ReturnGuardian(regionRuntime, active, "countdown_relocated")
    end)

    context.Events:Subscribe(GuardianService.Name, "StolenChickenOwned", function(snapshot)
        if context.Services.GuardianService ~= runtime or runtime.Resetting then return end
        local regionRuntime = runtime.Regions[snapshot.regionId]
        if not regionRuntime then return end
        RemoveCandidate(regionRuntime, snapshot.chickenRootId, snapshot.operation, snapshot.generation)
        local active = regionRuntime.Active
        if not active or active.rootId ~= snapshot.chickenRootId or active.operation ~= snapshot.operation
            or active.chickenGeneration ~= snapshot.generation then return end
        Sample(regionRuntime, active, "invalidated")
        active.resolution = "owned"
        local withoutSession = active.state == "Delay" or active.state == "AnchorRebinding"
            or active.state == "AnchorUnavailable" or active.state == "AnchorPending"
            or active.state == "TrackingFailed"
        if withoutSession and not active.hasTracked then
            if active.delayTimerId then context.Timers:Remove(active.delayTimerId) end
            regionRuntime.Active = nil
            StartNext(regionRuntime)
        elseif active.state == "Tracking" or active.state == "Approaching" or withoutSession then
            local fromApproach = active.state == "Approaching" or withoutSession
            if active.delayTimerId then context.Timers:Remove(active.delayTimerId); active.delayTimerId = nil end
            active.state = "ReturningOwned"
            local stopped, reason = runtime.Tracker:StopAndReturnGuardian(
                regionRuntime.GuardianElementId,
                "chicken_owned",
                fromApproach and {
                    fromApproach = true,
                    debugName = "再拾取接近阶段成功带回",
                    triggerBoxId = regionRuntime.TriggerBoxId,
                    targetElementId = active.rootId,
                    guardianReturnPosition = regionRuntime.GuardianReturnPosition,
                    targetReturnPosition = active.spawnPosition,
                    onReturned = function(result) FinishActive(regionRuntime, active, result) end,
                } or nil
            )
            if not stopped then
                error("成功带回后守护者停止复位失败: " .. tostring(reason))
            end
        end
    end)

    function runtime:ResetForRefresh(onComplete)
        if not self.Ready or self.Resetting then error("守护者刷新入口状态无效") end
        self.Resetting = true
        self.ResetGeneration = self.ResetGeneration + 1
        local generation = self.ResetGeneration
        for _, regionRuntime in pairs(self.Regions) do
            local active = regionRuntime.Active
            runtime.InvalidateDiagnostic(regionRuntime, active)
            regionRuntime.Active = nil
            regionRuntime.Candidates = {}
            if active and active.delayTimerId then context.Timers:Remove(active.delayTimerId) end
            self.Tracker:CancelGuardian(regionRuntime.GuardianElementId, "refresh")
        end
        context.Timers:AddFrame(GuardianService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if context.Services.GuardianService ~= self or self.ResetGeneration ~= generation then return end
            for _, regionRuntime in pairs(self.Regions) do
                Element:SetPosition(regionRuntime.GuardianElementId,
                    regionRuntime.GuardianReturnPosition, Element.COORDINATE.World)
            end
            context.Timers:AddFrame(GuardianService.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                if context.Services.GuardianService ~= self or self.ResetGeneration ~= generation then return end
                local maxReturnDistance = 0
                for _, regionRuntime in pairs(self.Regions) do
                    local position = Element:GetPosition(regionRuntime.GuardianElementId)
                    if not position then error("刷新后无法读取守护者位置") end
                    local expected = regionRuntime.GuardianReturnPosition
                    local dx, dy, dz = position.X - expected.X,
                        position.Y - expected.Y, position.Z - expected.Z
                    maxReturnDistance = math.max(maxReturnDistance, math.sqrt(dx * dx + dy * dy + dz * dz))
                end
                Log:PrintServerLog("[GuardianService] 刷新复位验证完成",
                    "maxGuardianDistanceFromReturn:", maxReturnDistance)
                self.Resetting = false
                onComplete()
            end)
        end)
    end

    context.Timers:AddTimer(GuardianService.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if context.Services.GuardianService ~= runtime then return end
        local enabledCount = 0
        for _, region in ipairs(GameConfig.Regions) do
            if region.Enabled then
                local guardianId = FindUniquePurposeElement(
                    region.RegionRootId,
                    GameConfig.Theft.GuardianPurpose,
                    "区域" .. tostring(region.RegionId) .. "守护者"
                )
                local triggerBoxId = FindUniquePurposeElement(
                    guardianId,
                    GameConfig.Theft.GuardianTriggerPurpose,
                    "区域" .. tostring(region.RegionId) .. "守护者捕获触发盒"
                )
                local returnPosition = Element:GetPosition(guardianId)
                if not returnPosition then
                    error("无法读取守护者初始位置，region=" .. tostring(region.RegionId))
                end
                runtime.Regions[region.RegionId] = {
                    Config = region,
                    GuardianElementId = guardianId,
                    TriggerBoxId = triggerBoxId,
                    GuardianReturnPosition = CopyPosition(returnPosition),
                    FirstTrackingPositionSet = false,
                    FirstTrackingReady = false,
                    Active = nil,
                    Candidates = {},
                }
                enabledCount = enabledCount + 1
            end
        end
        runtime.Ready = true
        for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do
            if not runtime.Departed[playerId] then runtime.EnterCallback(playerId) end
        end
        for _, player in pairs(runtime.Players) do SpawnAnchor(player) end
        Log:PrintServerLog("[GuardianService] 正式守护者模块已就绪",
            "enabledRegionCount:", enabledCount)
    end)
end

function GuardianService:Stop(context)
    if context.Side ~= "Server" then return end
    local runtime = context.Services.GuardianService
    if not runtime then return end
    for _, region in pairs(runtime.Regions) do runtime.InvalidateDiagnostic(region, region.Active) end
    Diagnostic.Safe(function() context.Timers:RemoveOwner("GuardianDiagnosticServer") end)
    context.Services.GuardianService = nil
    for _, binding in ipairs(runtime.AnchorBindings) do System:UnregisterEvent(binding[1], binding[2]) end
    for _, player in pairs(runtime.Players) do
        player.version = player.version + 1
        player.ready = false
        if player.bindTimer then context.Timers:Remove(player.bindTimer) end
        if player.verifyTimer then context.Timers:Remove(player.verifyTimer) end
        runtime.DestroyAnchor(player, player.anchorId)
    end
    runtime.Players = {}
    runtime.ResetGeneration = runtime.ResetGeneration + 1
    runtime.Resetting = true
    if runtime.Tracker then runtime.Tracker:Stop() end
    for _, regionRuntime in pairs(runtime.Regions) do
        local guardianId = regionRuntime.GuardianElementId
        if IsPositiveInteger(guardianId) and regionRuntime.GuardianReturnPosition then
            pcall(function()
                Element:SetPosition(
                    guardianId,
                    regionRuntime.GuardianReturnPosition,
                    Element.COORDINATE.World
                )
            end)
        end
    end
    runtime.Regions = {}
end

return GuardianService
