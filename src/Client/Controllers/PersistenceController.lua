local GameConfig = require "Common.Config.GameConfig"
local PersistenceController = { Name = "PersistenceController", FeatureFlag = "Persistence", Dependencies = { "PromptController" } }
function PersistenceController:Start(context)
    if context.Side ~= "Client" or not GameConfig.Persistence.ProductionEnabled then return end
    local rt = { Active = true, Ready = false, Version = -1, Snapshot = nil, WriteFailureShown = false }
    context.Services.PersistenceController = rt
    local function Current() return rt.Active and context.Services.PersistenceController == rt end
    local function Diag(stage, data, reason)
        pcall(function()
            local ok, localId = pcall(function() return Character:GetLocalPlayerId() end)
            local state = type(data) == "table" and data or {}
            if type(reason) == "function" then reason = reason() end
            Log:PrintLog("[PersistenceStateDiag]", "side:", "C", "stage:", stage,
                "localPlayerId:", ok and tostring(localId) or "unavailable", "currentVersion:", rt.Version,
                "version:", tostring(state.version), "state:", tostring(state.state), "reason:", tostring(state.reason),
                "ready:", tostring(state.ready), "generation:", tostring(state.generation), "decision:", tostring(reason))
        end)
    end
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
            Diag("show_load_failure", data)
            context.Services.PromptController:Show("存档读取失败，请重新进入游戏")
        elseif data.state == "save_failed" and not rt.WriteFailureShown then
            rt.WriteFailureShown = true
            Diag("show_save_failure", data)
            context.Services.PromptController:Show("保存失败，请暂时不要退出")
        end
    end
    rt.Callback = function(_, data)
        Diag("received", data)
        if not Current() or type(data) ~= "table" or type(data.version) ~= "number" or data.version <= rt.Version then
            Diag("rejected", data, function()
                if not Current() then return "module_inactive" end
                if type(data) ~= "table" then return "invalid_payload" end
                if type(data.version) ~= "number" then return "invalid_version" end
                return "old_or_duplicate_version"
            end)
            return
        end
        rt.Version, rt.Snapshot = data.version, data
        Diag("accepted", data)
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
