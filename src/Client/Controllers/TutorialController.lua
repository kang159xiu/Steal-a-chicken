local GameConfig = require "Common.Config.GameConfig"
local TutorialController = { Name = "TutorialController", FeatureFlag = "Tutorial", Dependencies = {} }

function TutorialController:Start(context)
    if context.Side ~= "Client" then return end
    local c = GameConfig.Tutorial
    local rt = { Active = true, Ready = false, Version = -1, Owned = {}, Settled = {} }
    context.Services.TutorialController = rt
    local function Active() return rt.Active and context.Services.TutorialController == rt end
    local function Error(stage, err) Log:PrintError("[Tutorial] 表现失败，不重试", stage, tostring(err)) end
    local function SetCollectArrow(visible)
        if rt.CollectArrowVisible == visible then return end
        local ok, err = pcall(function() UI:SetVisibility({ c.CollectArrowGroupId }, visible) end)
        rt.CollectArrowVisible = visible
        if not ok then Error("collect_arrow", err) end
    end
    local function StopLine()
        local effect = rt.EffectId
        rt.EffectId = nil
        if effect then
            local ok, err = pcall(function() Particle:StopParticle(effect) end)
            if not ok then Error("stop_chain", err) end
        end
    end
    local function Destroy(id)
        rt.Owned[id] = nil
        local ok, err = pcall(function() Element:Destroy(id) end)
        if not ok then Error("destroy_anchor", err) end
    end
    local function DisableLine(stage, err)
        rt.LineDisabled = true
        StopLine()
        local ids = {}; for id in pairs(rt.Owned) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do Destroy(id) end
        Error(stage, err)
    end
    local function LineCall(stage, callback)
        if not Active() or rt.LineDisabled then return end
        local ok, err = pcall(callback)
        if not ok then DisableLine(stage, err) end
    end
    local function After(stage, callback)
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            LineCall(stage, callback)
        end)
    end
    local function Prepare()
        if rt.Binding or not rt.Settled.start or not rt.Settled.finish then return end
        rt.Binding = true
        Element:SetPosition(rt.StartId, Character:GetPosition(rt.PlayerId), Element.COORDINATE.World)
        After("bind_root", function()
            Element:BindingToCharacterOrCreature(rt.StartId, rt.PlayerId, Character.SOCKET_NAME.Root, Character.SOCKET_MODE.SnapToTarget)
            After("bind_settled", function()
                if Element:GetAttachParentCharacter(rt.StartId) ~= rt.PlayerId then error("引导线Root附加未生效") end
                rt.AnchorsReady = true
            end)
        end)
    end
    local function Spawn(role, position)
        Element:SpawnElement(Element.SPAWN_SOURCE.Scene, c.SourceElementId, function(id)
            if type(id) ~= "number" or id <= 0 or id == c.SourceElementId then
                LineCall("spawn_return", function() error("引导锚点未返回独立ID") end)
                return
            end
            if not Active() or rt.LineDisabled then rt.Owned[id] = true; Destroy(id); return end
            if rt[role] then
                if rt[role] ~= id then rt.Owned[id] = true; Destroy(id) end
                return
            end
            rt[role], rt.Owned[id] = id, true
            if role == "start" then rt.StartId = id else rt.EndId = id end
            After("spawn_settled", function()
                if rt.StartId and rt.StartId == rt.EndId then error("引导锚点ID重复") end
                if not Element:GetPosition(id) then error("引导锚点位置不可用") end
                rt.Settled[role] = true
                Prepare()
            end)
        end, position, Engine.Rotator(0, 0, 0), 1, false)
    end
    local function Render()
        if not Active() or not rt.Ready or not rt.State then return end
        local state = rt.State
        if state.step ~= "Collect" then rt.CollectArrowDismissed = nil end
        SetCollectArrow(state.step == "Collect" and not rt.CollectArrowDismissed)
        if not rt.UiDisabled and rt.TextStep ~= state.step then
            local ok, err = pcall(function()
                local text = c.Text[state.step]
                if text then UI:SetText({ c.TextId }, text, false) end
                UI:SetVisibility({ c.GroupId }, text ~= nil)
            end)
            if not ok then rt.UiDisabled = true; Error("prompt", err)
            else
                rt.TextStep = state.step
                if state.step == "Done" then
                    context.Timers:AddTimer(self.Name, c.CompleteSeconds, function()
                        if not Active() or rt.State.step ~= "Done" then return end
                        local hidden, reason = pcall(function() UI:SetVisibility({ c.GroupId }, false) end)
                        if not hidden then Error("complete_hide", reason) end
                    end)
                end
            end
        end
        if state.position and not rt.Requested and not rt.LineDisabled then
            rt.Requested = true
            LineCall("spawn_anchors", function()
                Spawn("start", Character:GetPosition(rt.PlayerId))
                if Active() and not rt.LineDisabled then Spawn("finish", state.position) end
            end)
        end
        if not state.position then StopLine() end
    end
    rt.Receive = function(_, message)
        if not Active() or type(message) ~= "table" or type(message.version) ~= "number" or message.version <= rt.Version then return end
        rt.Version, rt.State = message.version, message
        Render()
    end
    System:BindNotify(context.NetMsg.Messages.TutorialState, rt.Receive)
    rt.CollectOpenClick = function()
        if not Active() or not rt.Ready or not rt.State or rt.State.step ~= "Collect" then return end
        rt.CollectArrowDismissed = true
        SetCollectArrow(false)
    end
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        rt.PlayerId, rt.Ready = Character:GetLocalPlayerId(), true
        local ok, err = pcall(function() UI:RegisterClicked(c.CollectOpenButtonId, rt.CollectOpenClick) end)
        rt.CollectClickRegistered = ok
        if not ok then Error("collect_open_bind", err) end
        if not rt.State then rt.State = { step = "Hidden" } end
        Render()
        System:SendToServer(context.NetMsg.Messages.TutorialSnapshotRequest, {})
    end)
    context.Timers:AddLoopTimer(self.Name, c.UpdateSeconds, function()
        if not Active() or not rt.AnchorsReady or rt.LineDisabled then return end
        local state = rt.State
        if not state or not state.position then return end
        LineCall("update_chain", function()
            local target = state.position
            if not rt.EndPosition or rt.EndPosition.X ~= target.X or rt.EndPosition.Y ~= target.Y or rt.EndPosition.Z ~= target.Z then
                Element:SetPosition(rt.EndId, Engine.Vector(target.X, target.Y, target.Z), Element.COORDINATE.World)
                rt.EndPosition, rt.EndSettled = target, false
                After("target_settled", function()
                    if rt.EndPosition == target then rt.EndSettled = true end
                end)
                return
            end
            if not rt.EndSettled then return end
            local from, to = Element:GetPosition(rt.StartId), Element:GetPosition(rt.EndId)
            if not rt.EffectId then
                local effect = Particle:CreateChainParticle(c.EffectType, from, to, false, 0)
                if type(effect) ~= "number" or effect <= 0 then error("引导特效未返回有效ID") end
                rt.EffectId = effect
            else Particle:UpdateChainParticle(rt.EffectId, from, to) end
        end)
    end)
    rt.Cleanup = function()
        rt.Active = false
        context.Timers:RemoveOwner(self.Name)
        System:UnbindNotify(context.NetMsg.Messages.TutorialState, rt.Receive)
        if rt.CollectClickRegistered then
            local ok, err = pcall(function() UI:UnRegisterClicked(c.CollectOpenButtonId, rt.CollectOpenClick) end)
            if not ok then Error("collect_open_unbind", err) end
        end
        SetCollectArrow(false)
        StopLine()
        local ids = {}; for id in pairs(rt.Owned) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do Destroy(id) end
        local ok, err = pcall(function() UI:SetVisibility({ c.GroupId }, false) end)
        if not ok then Error("stop_hide", err) end
    end
end
function TutorialController:Stop(context)
    local rt = context.Services.TutorialController
    if not rt then return end
    rt.Cleanup()
    context.Services.TutorialController = nil
end
return TutorialController
