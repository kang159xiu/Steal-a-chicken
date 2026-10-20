local GameConfig = require "Common.Config.GameConfig"
local PersistenceController = { Name = "PersistenceController", FeatureFlag = "Persistence" }
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
        if not data.ready and LoadFailed(data.state) then
            UI:ShowMessageTip("读取存档失败，请重新进入")
        elseif data.state == "save_failed" and not rt.WriteFailureShown then
            rt.WriteFailureShown = true
            UI:ShowMessageTip("存档保存失败，数据待保存，下次正常保存时再试")
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
