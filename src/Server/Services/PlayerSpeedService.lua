local GameConfig = require "Common.Config.GameConfig"
local MultiplierProducts = require "Common.MultiplierProducts"
local Decimal = require "Common.DecimalInteger"
local SpeedGrowth = require "Common.SpeedGrowth"
local PlayerSpeedService = { Name = "PlayerSpeedService", FeatureFlag = "Treadmill", Dependencies = { "EconomyService" } }

function PlayerSpeedService:ValidateConfig()
    local c = GameConfig.PlayerSpeed
    if c.DefaultLevel ~= 1 or c.WalkSpeedPerLevel ~= 17 or c.BaseWalkSpeed ~= 500
        or c.FirstUpgradeExperience ~= "100" or c.ExperienceGrowthPercent ~= 112 or #GameConfig.RebirthLevels ~= 20 then
        return false, { "PlayerSpeed配置与已确认规则不一致" }
    end
    local previous = "0"
    for count, row in ipairs(GameConfig.RebirthLevels) do
        if row.Count ~= count or not Decimal.IsValid(row.ExperienceRequired) or Decimal.Compare(row.ExperienceRequired, previous) <= 0
            or row.Multiplier ~= 1 + count * 0.5 then return false, { "重生门槛/倍率配置无效: " .. count } end
        previous = row.ExperienceRequired
    end
    return true
end

function PlayerSpeedService:Start(context)
    if context.Side ~= "Server" then return end
    local c, economy = GameConfig.PlayerSpeed, context.Services.EconomyService
    local rt = { Active = true, Ready = false, Players = {}, Departed = {}, Dead = {} }
    context.Services.PlayerSpeedService = rt
    local persistence = context.Services.PersistenceService
    local function CanPlay(id)
        return not GameConfig.Persistence.ProductionEnabled or (persistence and persistence:IsReady(id))
    end
    local function PrepareLeave(id)
        if GameConfig.Persistence.ProductionEnabled and persistence then persistence:PrepareLeave(id) end
    end
    local function Active() return rt.Active and context.Services.PlayerSpeedService == rt end
    local function Online(id)
        for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do if playerId == id then return true end end
        return false
    end
    local function Current(id, state)
        return Active() and rt.Ready and rt.Players[id] == state and not rt.Departed[id]
            and economy:IsCurrent(id, state.generation) and Online(id)
    end
    local function Snapshot(state)
        local row = GameConfig.RebirthLevels[state.rebirthCount + 1]
        local track = GameConfig.TrackShop.Tracks[state.equippedTrack]
        return { sessionGeneration = state.generation, speedLevel = state.level, experience = state.experience,
            speedUpgradeExperience = state.speedUpgradeExperience,
            redeemedMask = state.redeemedMask, rebirthCount = state.rebirthCount, multiplier = 1 + state.rebirthCount * 0.5,
            trainingPurchaseMultiplier = state.trainingPurchaseMultiplier,
            trainingMultiplier = state.trainingPurchaseMultiplier + (track and track.Multiplier or 1) - 1,
            trackMask = state.trackMask, equippedTrack = state.equippedTrack, trackVersion = state.trackVersion,
            rebirthRequirement = row and row.ExperienceRequired, nextMultiplier = row and row.Multiplier,
            walkSpeed = c.BaseWalkSpeed + (state.level - 1) * c.WalkSpeedPerLevel }
    end
    local function Publish(id, state)
        local data = Snapshot(state); data.playerId = id
        context.Events:Publish("PlayerSpeedChanged", data)
    end
    local function Apply(id, state)
        state.applyVersion = state.applyVersion + 1
        local version = state.applyVersion
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Current(id, state) or rt.Dead[id] or state.applyVersion ~= version then return end
            local ok, err = pcall(function()
                Character:ChangeAttribute(id, Character.ATTR.MaxWalkSpeed, Snapshot(state).walkSpeed)
            end)
            if not ok then Log:PrintError("[PlayerSpeed] 速度应用失败", "playerId:", id, "error:", tostring(err)) end
        end)
    end
    local function Ensure(id)
        if not CanPlay(id) or not Active() or not rt.Ready or rt.Departed[id] or not Online(id) then return nil end
        local generation = economy:GetSessionGeneration(id)
        if not generation or not economy:IsCurrent(id, generation) then return nil end
        local state = rt.Players[id]
        if not state or state.generation ~= generation then
            state = { generation = generation, level = c.DefaultLevel, experience = "0", speedUpgradeExperience = "0",
                rebirthCount = 0, redeemedMask = 0, trainingPurchaseMultiplier = 1, applyVersion = 0,
                trackMask = 0, equippedTrack = 0, trackVersion = 0 }
            rt.Players[id] = state
            Apply(id, state)
            Publish(id, state)
        end
        return state
    end
    function rt:GetSnapshot(id)
        local state = rt.Players[id] or Ensure(id)
        return state and Snapshot(state) or nil
    end
    function rt:AddExperience(id, generation, amount)
        if not CanPlay(id) then return false, "persistence_not_ready" end
        if not Decimal.IsValid(amount) then return false, "invalid_experience" end
        local state = Ensure(id)
        if not state or state.generation ~= generation or not Current(id, state) or rt.Dead[id] then
            return false, "session_unavailable"
        end
        state.experience = Decimal.Add(state.experience, amount)
        state.speedUpgradeExperience = Decimal.Add(state.speedUpgradeExperience, amount)
        if amount ~= "0" then state.experienceDirty = true end
        local previousLevel = state.level
        state.level, state.speedUpgradeExperience = SpeedGrowth.Advance(state.level, state.speedUpgradeExperience)
        if state.level ~= previousLevel then Apply(id, state) end
        self:FlushExperience(id)
        Publish(id, state)
        return true
    end
    -- 倍率派生自同一成长记录，金额不转number；只做本玩法需要的小整数乘法/精确除2。
    function rt:GetExperiencePerTick(id, generation, base)
        local state = Ensure(id)
        if not state or state.generation ~= generation then return nil, "session_unavailable" end
        if not Decimal.IsValid(base) then return nil, "invalid_base_experience" end
        local total = "0"
        for _ = 1, 2 * Snapshot(state).trainingMultiplier do total = Decimal.Add(total, base) end
        local digits, carry = {}, 0
        for i = 1, #total do
            local value = carry * 10 + total:byte(i) - 48
            digits[#digits + 1] = string.char(48 + math.floor(value / 2)); carry = value % 2
        end
        if carry ~= 0 then return nil, "fractional_experience_config" end
        local result = table.concat(digits):gsub("^0+", "")
        return result == "" and "0" or result
    end
    function rt:PrepareTrainingMultiplierCommit(id, generation, target)
        if not CanPlay(id) then return nil, "persistence_not_ready" end
        local state = Ensure(id)
        if not state or state.generation ~= generation or not Current(id, state) or rt.Dead[id] then return nil, "session_unavailable" end
        local allowed, reason = economy:CanPurchaseMultiplier(id, generation)
        if not allowed then return nil, reason end
        local nextProduct = MultiplierProducts.Next("Training", state.trainingPurchaseMultiplier)
        if not nextProduct or target ~= nextProduct.Multiplier then return nil, "invalid_training_multiplier_step" end
        local expected, token, attempted = state.trainingPurchaseMultiplier, {}, false
        state.trainingPurchase = token
        return function()
            if attempted then return false, "training_purchase_already_attempted" end
            attempted = true
            if not Active() or rt.Players[id] ~= state or rt.Departed[id] or rt.Dead[id] or state.trainingPurchase ~= token
                or state.trainingPurchaseMultiplier ~= expected or not economy:IsCurrent(id, generation) then return false, "training_purchase_expired" end
            local valid, why = economy:CanPurchaseMultiplier(id, generation)
            if not valid then return false, why end
            state.trainingPurchase = nil; state.trainingPurchaseMultiplier = target
            local notified = false
            return true, function()
                if notified then return false, "already_notified" end
                notified = true
                if not Current(id, state) then return false, "session_unavailable" end
                if persistence and CanPlay(id) then persistence:MarkDirty(id, "training_multiplier_purchase") end
                Publish(id, state)
                return true
            end
        end
    end
    -- 协调方持共锁并完成所有检查后调用；返回闭包只做Lua赋值，扣款后没有可失败分支。
    function rt:PrepareTrackCommit(id, generation, expectedVersion, index)
        if not CanPlay(id) then return nil, "persistence_not_ready" end
        local state = Ensure(id)
        if not state or state.generation ~= generation or not Current(id, state) or rt.Dead[id] then return nil, "session_unavailable" end
        local allowed, reason = economy:CanPurchaseMultiplier(id, generation)
        if not allowed then return nil, reason end
        if state.trackVersion ~= expectedVersion then return nil, "stale_track_state" end
        if type(index) ~= "number" or index ~= math.floor(index) or not GameConfig.TrackShop.Tracks[index] then return nil, "invalid_track" end
        local owned = math.floor(state.trackMask / 2^(index-1)) % 2 == 1
        local changed = state.equippedTrack ~= index
        local committed = false
        return function()
            if committed then return end
            committed = true
            if not owned then state.trackMask = state.trackMask + 2^(index-1) end
            if changed then state.equippedTrack = index; state.trackVersion = state.trackVersion + 1 end
            local notified = false
            return function()
                if notified then return end; notified = true
                if not changed or not Current(id, state) then return end
                if persistence and CanPlay(id) then persistence:MarkDirty(id, "track_purchase_or_equip") end
                Publish(id, state)
            end
        end, owned, changed
    end
    function rt:HasRedeemed(id, index)
        local state = rt.Players[id]
        return state ~= nil and math.floor(state.redeemedMask / 2^(index-1)) % 2 == 1
    end
    function rt:CanRebirth(id, generation, expectedCount, paidIndex)
        if not CanPlay(id) then return false, "persistence_not_ready" end
        local state = Ensure(id)
        if not state or state.generation ~= generation or not Current(id, state) or rt.Dead[id] then return false, "session_unavailable" end
        if state.rebirthCount ~= expectedCount then return false, "stale_count" end
        local row = GameConfig.RebirthLevels[expectedCount + 1]
        if not row then return false, "max_rebirth" end
        if paidIndex then
            if type(paidIndex) ~= "number" or paidIndex < 1 or paidIndex > 20 or paidIndex ~= math.floor(paidIndex) then return false, "invalid_product" end
            if self:HasRedeemed(id, paidIndex) then return false, "product_already_redeemed" end
        elseif Decimal.Compare(state.experience, row.ExperienceRequired) < 0 then return false, "insufficient_experience" end
        return true
    end
    -- 先完整校验并返回无引擎调用的提交闭包；协调方在跑步机准备好后直接连续提交。
    function rt:PrepareRebirthCommit(id, generation, expectedCount, paidIndex)
        local valid, reason = self:CanRebirth(id, generation, expectedCount, paidIndex)
        if not valid then return nil, reason end
        local allowed, why = economy:CanPurchaseMultiplier(id, generation)
        if not allowed then return nil, why end
        local state, committed = rt.Players[id], false
        return function()
            if committed or not Active() or rt.Players[id] ~= state or rt.Dead[id] or rt.Departed[id]
                or not economy:IsCurrent(id, generation) or state.rebirthCount ~= expectedCount then return false, "session_unavailable" end
            if paidIndex then
                if self:HasRedeemed(id, paidIndex) then return false, "product_already_redeemed" end
            elseif Decimal.Compare(state.experience, GameConfig.RebirthLevels[expectedCount + 1].ExperienceRequired) < 0 then return false, "insufficient_experience" end
            local synced, syncReason = economy:SyncRebirthCoinBonus(id, generation, expectedCount + 1)
            if not synced then return false, syncReason end
            committed = true
            if paidIndex then state.redeemedMask = state.redeemedMask + 2^(paidIndex-1) end
            state.rebirthCount = expectedCount + 1; state.experience = "0"; state.level = 1
            state.speedUpgradeExperience = "0"
            state.trackMask = 0; state.equippedTrack = 0; state.trackVersion = state.trackVersion + 1
            state.applyVersion = state.applyVersion + 1
            local notified = false
            return true, function()
                if notified then return end; notified = true
                if not Current(id, state) then return end
                if persistence and CanPlay(id) then persistence:MarkDirty(id, "rebirth_growth") end
                Apply(id, state); Publish(id, state)
            end
        end
    end
    function rt:FlushExperience(id)
        local state = rt.Players[id]
        if state and state.experienceDirty and CanPlay(id) and persistence then
            state.experienceDirty = nil
            persistence:MarkDeferred(id, "training_experience")
        end
    end
    if GameConfig.Persistence.ProductionEnabled then
        assert(persistence:RegisterAdapter("speed", {
            Export = function(id)
                local state = rt.Players[id]
                if not state then return nil, "speed_state_missing" end
                return { version = 6, trackMask = state.trackMask, equippedTrack = state.equippedTrack,
                    trainingPurchaseMultiplier = state.trainingPurchaseMultiplier, redeemedMask = state.redeemedMask, experience = state.experience, speedUpgradeExperience = state.speedUpgradeExperience,
                    speedLevel = state.level, rebirthCount = state.rebirthCount }
            end,
            Restore = function(id, data, done)
                local experience, upgradeExperience, count, level, mask, purchaseMultiplier = "0", "0", 0, c.DefaultLevel, 0, 1
                local trackMask, equippedTrack = 0, 0
                if data then
                    if data.version ~= 6 or type(data.trackMask) ~= "number" or data.trackMask < 0 or data.trackMask > 511
                        or data.trackMask ~= math.floor(data.trackMask) or type(data.equippedTrack) ~= "number"
                        or data.equippedTrack < 0 or data.equippedTrack > 9 or data.equippedTrack ~= math.floor(data.equippedTrack)
                        or (data.equippedTrack > 0 and math.floor(data.trackMask / 2^(data.equippedTrack-1)) % 2 ~= 1)
                        or (data.trackMask > 0 and data.equippedTrack == 0) or type(data.trainingPurchaseMultiplier) ~= "number"
                        or not MultiplierProducts.IsCurrent("Training", data.trainingPurchaseMultiplier)
                        or data.trainingPurchaseMultiplier ~= math.floor(data.trainingPurchaseMultiplier) or type(data.redeemedMask) ~= "number" or data.redeemedMask < 0 or data.redeemedMask > 1048575
                        or data.redeemedMask ~= math.floor(data.redeemedMask) or not Decimal.IsValid(data.experience)
                        or not Decimal.IsValid(data.speedUpgradeExperience)
                        or type(data.speedLevel) ~= "number" or data.speedLevel < 1 or data.speedLevel >= math.huge
                        or data.speedLevel ~= math.floor(data.speedLevel)
                        or type(data.rebirthCount) ~= "number" or data.rebirthCount < 0 or data.rebirthCount > 20 or data.rebirthCount ~= math.floor(data.rebirthCount) then
                        done(false, "invalid_speed_snapshot"); return
                    end
                    local redeemed = 0
                    for i=1,20 do if math.floor(data.redeemedMask / 2^(i-1)) % 2 == 1 then redeemed = redeemed + 1 end end
                    if redeemed > data.rebirthCount then done(false, "invalid_paid_rebirth_count"); return end
                    mask = data.redeemedMask; purchaseMultiplier = data.trainingPurchaseMultiplier
                    trackMask, equippedTrack = data.trackMask, data.equippedTrack
                    experience, count = data.experience, data.rebirthCount
                    upgradeExperience, level = data.speedUpgradeExperience, data.speedLevel
                end
                local restoredLevel = level
                level, upgradeExperience = SpeedGrowth.Advance(level, upgradeExperience)
                local generation = economy:GetSessionGeneration(id)
                if not generation then done(false, "economy_session_missing"); return end
                local synced, reason = economy:SyncRebirthCoinBonus(id, generation, count)
                if not synced then done(false, reason); return end
                local state = { generation = generation, level = level, experience = experience,
                    speedUpgradeExperience = upgradeExperience, rebirthCount = count, redeemedMask = mask, trainingPurchaseMultiplier = purchaseMultiplier, applyVersion = 0,
                    trackMask = trackMask, equippedTrack = equippedTrack, trackVersion = 0, experienceDirty = level ~= restoredLevel }
                rt.Players[id], rt.Departed[id] = state, nil
                done(true, function() Apply(id, state); Publish(id, state); return true end)
            end,
            Cleanup = function(id) rt.Leave(id) end,
        }))
        context.Events:Subscribe(self.Name, "PersistenceReady", function(event)
            local state = rt.Players[event.playerId]
            if state then rt:FlushExperience(event.playerId); Apply(event.playerId, state); Publish(event.playerId, state) end
        end)
    end
    rt.Leave = function(id)
        PrepareLeave(id)
        if not Active() then return end
        rt.Departed[id] = true; rt.Players[id] = nil; rt.Dead[id] = nil
    end
    rt.Enter = function(id)
        if not Active() then return end
        rt.Departed[id] = nil
        if rt.Ready then Ensure(id) end
    end
    rt.Death = function(id)
        if not Active() then return end
        rt.Dead[id] = true
        local state = rt.Players[id]; if state then state.applyVersion = state.applyVersion + 1 end
    end
    rt.Revive = function(id)
        if not Active() then return end
        rt.Dead[id] = nil
        if rt.Ready then local state = Ensure(id); if state then Apply(id, state) end end
    end
    rt.Bindings = {
        { Events.ON_PLAYER_ENTER, rt.Enter }, { Events.ON_PLAYER_JOIN_MIDWAY, rt.Enter },
        { Events.ON_PLAYER_RECONNECTED, rt.Enter }, { Events.ON_PLAYER_PRELEAVE, rt.Leave },
        { Events.ON_CHARACTER_KILLED, rt.Death }, { Events.ON_CHARACTER_DESTROYED, rt.Death },
        { Events.ON_CHARACTER_RESPAWN, rt.Revive }, { Events.ON_CHARACTER_REVIVED, rt.Revive },
    }
    for _, binding in ipairs(rt.Bindings) do System:RegisterEvent(binding[1], binding[2]) end
    context.Events:Subscribe(self.Name, "EconomyChanged", function(data)
        if Active() and rt.Ready then Ensure(data.playerId) end
    end)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, function()
        if not Active() then return end
        rt.Ready = true
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Ensure(id) end
    end)
end
function PlayerSpeedService:Stop(context)
    local rt = context.Services.PlayerSpeedService
    if not rt then return end
    rt.Active = false; rt.Players = {}
    for _, binding in ipairs(rt.Bindings) do System:UnregisterEvent(binding[1], binding[2]) end
    context.Events:UnsubscribeOwner(self.Name)
    context.Timers:RemoveOwner(self.Name)
    context.Services.PlayerSpeedService = nil
end
return PlayerSpeedService
