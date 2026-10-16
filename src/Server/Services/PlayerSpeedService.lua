local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local PlayerSpeedService = { Name = "PlayerSpeedService", FeatureFlag = "Treadmill", Dependencies = { "EconomyService" } }

function PlayerSpeedService:ValidateConfig()
    local c = GameConfig.PlayerSpeed
    if c.DefaultLevel ~= 1 or c.MaxLevel ~= 20 or c.BaseWalkSpeed ~= 500 or c.WalkSpeedPerLevel ~= 178
        or c.MaxWalkSpeed ~= 3882 or not Decimal.IsValid(c.MaxExperience) or #GameConfig.RebirthLevels ~= 20 then
        return false, { "PlayerSpeed配置与已确认规则不一致" }
    end
    local previous = "0"
    for count, row in ipairs(GameConfig.RebirthLevels) do
        if row.Count ~= count or not Decimal.IsValid(row.ExperienceRequired) or Decimal.Compare(row.ExperienceRequired, previous) <= 0
            or row.Multiplier ~= 1 + count * 0.5 then return false, { "重生门槛/倍率配置无效: " .. count } end
        previous = row.ExperienceRequired
    end
    if previous ~= c.MaxExperience then return false, { "累计经验封顶必须等于最后重生门槛" } end
    return true
end

function PlayerSpeedService:Start(context)
    if context.Side ~= "Server" then return end
    local c, economy = GameConfig.PlayerSpeed, context.Services.EconomyService
    local rt = { Active = true, Ready = false, Players = {}, Departed = {}, Dead = {} }
    context.Services.PlayerSpeedService = rt
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
        return { sessionGeneration = state.generation, speedLevel = state.level, experience = state.experience,
            rebirthCount = state.rebirthCount, multiplier = 1 + state.rebirthCount * 0.5,
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
        if not Active() or not rt.Ready or rt.Departed[id] or not Online(id) then return nil end
        local generation = economy:GetSessionGeneration(id)
        if not generation or not economy:IsCurrent(id, generation) then return nil end
        local state = rt.Players[id]
        if not state or state.generation ~= generation then
            state = { generation = generation, level = c.DefaultLevel, experience = "0",
                rebirthCount = 0, applyVersion = 0 }
            rt.Players[id] = state
            Apply(id, state)
            Publish(id, state)
        end
        return state
    end
    function rt:GetSnapshot(id)
        local state = Ensure(id)
        return state and Snapshot(state) or nil
    end
    function rt:AddExperience(id, generation, amount)
        if not Decimal.IsValid(amount) then return false, "invalid_experience" end
        local state = Ensure(id)
        if not state or state.generation ~= generation or not Current(id, state) or rt.Dead[id] then
            return false, "session_unavailable"
        end
        if state.experience == c.MaxExperience then return true end
        state.experience = Decimal.Add(state.experience, amount)
        if Decimal.Compare(state.experience, c.MaxExperience) > 0 then state.experience = c.MaxExperience end
        local previousLevel = state.level
        while state.level < c.MaxLevel and Decimal.Compare(state.experience, GameConfig.RebirthLevels[state.level].ExperienceRequired) >= 0 do
            state.level = state.level + 1
        end
        if state.level ~= previousLevel then Apply(id, state) end
        Publish(id, state)
        return true
    end
    -- 倍率派生自同一成长记录，金额不转number；只做本玩法需要的小整数乘法/精确除2。
    function rt:GetExperiencePerTick(id, generation, base)
        local state = Ensure(id)
        if not state or state.generation ~= generation then return nil, "session_unavailable" end
        if not Decimal.IsValid(base) then return nil, "invalid_base_experience" end
        local total = "0"
        for _ = 1, 2 + state.rebirthCount do total = Decimal.Add(total, base) end
        local digits, carry = {}, 0
        for i = 1, #total do
            local value = carry * 10 + total:byte(i) - 48
            digits[#digits + 1] = string.char(48 + math.floor(value / 2)); carry = value % 2
        end
        if carry ~= 0 then return nil, "fractional_experience_config" end
        local result = table.concat(digits):gsub("^0+", "")
        return result == "" and "0" or result
    end
    function rt:CanRebirth(id, generation, expectedCount)
        local state = Ensure(id)
        if not state or state.generation ~= generation or not Current(id, state) or rt.Dead[id] then return false, "session_unavailable" end
        if state.rebirthCount ~= expectedCount then return false, "stale_count" end
        local row = GameConfig.RebirthLevels[expectedCount + 1]
        if not row then return false, "max_rebirth" end
        if Decimal.Compare(state.experience, row.ExperienceRequired) < 0 then return false, "insufficient_experience" end
        return true
    end
    -- 先完整校验并返回无引擎调用的提交闭包；协调方在跑步机准备好后直接连续提交。
    function rt:PrepareRebirthCommit(id, generation, expectedCount)
        local valid, reason = self:CanRebirth(id, generation, expectedCount)
        if not valid then return nil, reason end
        local state, committed = rt.Players[id], false
        return function()
            if committed or not Active() or rt.Players[id] ~= state or rt.Dead[id] or rt.Departed[id]
                or not economy:IsCurrent(id, generation) or state.rebirthCount ~= expectedCount then return false, "session_unavailable" end
            if Decimal.Compare(state.experience, GameConfig.RebirthLevels[expectedCount + 1].ExperienceRequired) < 0 then return false, "insufficient_experience" end
            committed = true
            state.rebirthCount = expectedCount + 1; state.experience = "0"; state.level = 1
            state.applyVersion = state.applyVersion + 1
            local notified = false
            return true, function()
                if notified then return end; notified = true
                if not Current(id, state) then return end
                Apply(id, state); Publish(id, state)
            end
        end
    end
    rt.Leave = function(id)
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
