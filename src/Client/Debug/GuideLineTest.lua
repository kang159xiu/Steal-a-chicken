local GameConfig = require "Common.Config.GameConfig"
local GuideLineTest = { Name = "GuideLineTest", FeatureFlag = "GuideLineTest", Dependencies = {} }
local function Integer(n) return type(n) == "number" and n > 0 and n < math.huge and n == math.floor(n) end
local function Position(p)
    if not p then error("位置不可用") end
    for _, axis in ipairs({ "X", "Y", "Z" }) do
        local n = p[axis]
        if type(n) ~= "number" or n ~= n or math.abs(n) == math.huge then error("位置分量无效: " .. axis) end
    end
    return Engine.Vector(p.X, p.Y, p.Z)
end
function GuideLineTest:ValidateConfig()
    local c = GameConfig.GuideLineTest
    if not c or not Integer(c.SourceElementId) or not Integer(c.TargetElementId) or c.SourceElementId == c.TargetElementId
        or c.EffectType ~= 337 or c.UpdateSeconds ~= 0.1 then return false, { "客户端引导线测试配置无效" } end
    return true
end
function GuideLineTest:Start(context)
    if context.Side ~= "Client" or context.Services.GuideLineTest then return end
    local c = GameConfig.GuideLineTest
    local rt = { Active = true, Generation = 1, Owned = {}, Settled = {}, Spawned = {} }
    context.Services.GuideLineTest = rt
    local function Active() return rt.Active and context.Services.GuideLineTest == rt end
    local function Error(stage, err)
        Log:PrintError("[GuideLineTest] 测试停止，不重试", "stage:", stage, "playerId:", tostring(rt.PlayerId), "error:", tostring(err))
    end
    local function Destroy(id)
        if not rt.Owned[id] then return end
        rt.Owned[id] = nil
        local ok, err = pcall(function() Element:Destroy(id) end)
        if not ok then Error("destroy:" .. id, err) end
    end
    rt.Cleanup = function()
        rt.Active = false; rt.Generation = rt.Generation + 1
        context.Timers:RemoveOwner(self.Name)
        if rt.EffectId then
            local effectId = rt.EffectId; rt.EffectId = nil
            local ok, err = pcall(function() Particle:StopParticle(effectId) end)
            if not ok then Error("stop_particle:" .. effectId, err) end
        end
        local ids = {}; for id in pairs(rt.Owned) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do Destroy(id) end
    end
    local function Run(stage, fn)
        if not Active() then return end
        rt.Stage = stage
        local ok, err = pcall(fn)
        if not ok then Error(stage, err); rt.Cleanup() end
    end
    local function After(stage, fn)
        local generation = rt.Generation
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() or rt.Generation ~= generation then return end
            Run(stage, fn)
        end)
    end
    local function AnchorPositions()
        if Character:GetLocalPlayerId() ~= rt.PlayerId or Element:GetAttachParentCharacter(rt.StartId) ~= rt.PlayerId then
            error("本地玩家或Root附加已失效")
        end
        return Position(Element:GetPosition(rt.StartId)), Position(Element:GetPosition(rt.EndId))
    end
    local function PrepareChain()
        if not rt.Settled.start or not rt.Settled.finish or rt.Preparing then return end
        rt.Preparing = true
        Element:SetPosition(rt.StartId, Position(Character:GetPosition(rt.PlayerId)), Element.COORDINATE.World)
        After("bind_root", function()
            Element:BindingToCharacterOrCreature(rt.StartId, rt.PlayerId, Character.SOCKET_NAME.Root, Character.SOCKET_MODE.SnapToTarget)
            After("create_chain", function()
                local startPos, endPos = AnchorPositions()
                local effectId = Particle:CreateChainParticle(c.EffectType, startPos, endPos, false, 0)
                if not Integer(effectId) then error("链式特效未返回有效ID: " .. tostring(effectId)) end
                rt.EffectId = effectId
                context.Timers:AddLoopTimer(self.Name, c.UpdateSeconds, function()
                    Run("update_chain", function()
                        local from, to = AnchorPositions()
                        Particle:UpdateChainParticle(rt.EffectId, from, to)
                    end)
                end)
                Log:PrintLog("[GuideLineTest] 客户端引导线已创建", "playerId:", rt.PlayerId,
                    "start:", rt.StartId, "finish:", rt.EndId, "effectId:", effectId)
            end)
        end)
    end
    local function Spawn(role, position)
        Run("spawn_request:" .. role, function()
        Element:SpawnElement(Element.SPAWN_SOURCE.Scene, c.SourceElementId, function(id)
            -- Stop/失败后异步生成仍需清理；只允许销毁本回调返回的独立副本。
            if not Integer(id) or id == c.SourceElementId or id == c.TargetElementId then
                Run("spawn_return:" .. role, function() error("生成未返回独立锚点: " .. tostring(id)) end); return
            end
            if rt.Spawned[role] then
                if rt.Spawned[role] ~= id then rt.Owned[id] = true; Destroy(id) end
                return
            end
            rt.Spawned[role] = id; rt.Owned[id] = true
            if not Active() then Destroy(id); return end
            Run("spawn_return:" .. role, function()
                if role == "start" then rt.StartId = id else rt.EndId = id end
                if rt.StartId == rt.EndId then error("两个锚点不能共用副本") end
                After("spawn_settled:" .. role, function()
                    Position(Element:GetPosition(id))
                    rt.Settled[role] = true
                    PrepareChain()
                end)
            end)
        end, position, Engine.Rotator(0, 0, 0), 1, false)
        end)
    end
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        Run("initialize", function()
            local id = Character:GetLocalPlayerId()
            if not Integer(id) then error("本地玩家不可用: " .. tostring(id)) end
            rt.PlayerId = id
            local startPos = Position(Character:GetPosition(id))
            rt.TargetPosition = Position(Element:GetPosition(c.TargetElementId))
            Spawn("start", startPos)
            if Active() then Spawn("finish", rt.TargetPosition) end
        end)
    end)
end
function GuideLineTest:Stop(context)
    local rt = context.Services.GuideLineTest
    if not rt then return end
    rt.Cleanup(); context.Services.GuideLineTest = nil
end
return GuideLineTest
