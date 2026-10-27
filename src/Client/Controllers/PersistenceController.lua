local GameConfig = require "Common.Config.GameConfig"
local PersistenceController = { Name = "PersistenceController", FeatureFlag = "Persistence", Dependencies = { "PromptController" } }
function PersistenceController:Start(context)
    if context.Side ~= "Client" or not GameConfig.Persistence.ProductionEnabled then return end
    local rt = { Active = true, Ready = false, Version = -1, Snapshot = nil, WriteFailureShown = false }
    context.Services.PersistenceController = rt
    local function Current() return rt.Active and context.Services.PersistenceController == rt end
    local function LoadFailed(state)
        return state == "load_failed" or state == "previous_session_save_failed" or state == "leave_export_failed" or state == "leave_save_failed"
    end
    local function Render()
        if not Current() or not rt.Ready or not rt.Snapshot then return end
        local data = rt.Snapshot
        local failed = not data.ready and LoadFailed(data.state)
        if not failed then rt.LoadFailureShown = nil end
        if data.state ~= "save_failed" then rt.WriteFailureShown = false end
        if failed and not rt.LoadFailureShown then
            rt.LoadFailureShown = true
            context.Services.PromptController:Show("存档读取失败，请重新进入游戏")
        elseif data.state == "save_failed" and not rt.WriteFailureShown then
            rt.WriteFailureShown = true
            context.Services.PromptController:Show("保存失败，请暂时不要退出")
        end
    end
    rt.Callback = function(_, data)
        if not Current() or type(data) ~= "table" or type(data.version) ~= "number" or data.version <= rt.Version then return end
        rt.Version, rt.Snapshot = data.version, data
        Render()
    end
    System:BindNotify(context.NetMsg.Messages.PersistenceState, rt.Callback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Current() then return end
        rt.Ready = true
        System:SendToServer(context.NetMsg.Messages.PersistenceSnapshotRequest, {})
    end)
    context.Timers:AddLoopTimer(self.Name, 0.5, Render)
end
function PersistenceController:Stop(context)
    local rt = context.Services.PersistenceController
    if not rt then return end
    rt.Active = false
    System:UnbindNotify(context.NetMsg.Messages.PersistenceState, rt.Callback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.PersistenceController = nil
end
return PersistenceController
