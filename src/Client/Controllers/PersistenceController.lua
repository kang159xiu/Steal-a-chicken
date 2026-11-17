local GameConfig = require "Common.Config.GameConfig"
local PersistenceController = { Name = "PersistenceController", FeatureFlag = "Persistence", Dependencies = { "PromptController" } }
local FailureReasons = {
    archive_session_unavailable = "存档读取或写入上下文不可用",
    archive_presence_invalid = "平台返回的存档存在状态异常",
    archive_busy = "存档正在处理中",
    archive_write_rejected = "平台拒绝写入存档",
    archive_readback_mismatch = "写入后回读内容不一致",
    archive_value_invalid = "平台返回的存档内容不符合接口要求",
    archive_value_empty_or_invalid = "待写入的存档内容为空或无效",
    archive_value_over_limit = "待写入的存档内容超出接口限制",
    archive_revision_overflow = "存档修订编号超出范围",
    snapshot_over_capacity = "存档数据超过容量限制",
    staging_verify_failed = "存档分段回读核对失败",
    service_unavailable = "功能服务不可用",
    json_encode_failed = "存档转换为JSON失败",
    snapshot_version_invalid = "待保存的存档版本无效",
}
local FailurePrefixes = {
    export_failed = "模块导出失败",
    old_snapshot_unreadable = "写入前无法读取旧存档",
    write_failed = "存档写入失败",
    commit_uncertain = "存档提交结果无法确认",
    snapshot_over_capacity = "存档数据超过容量限制",
}
local function FailureText(data)
    local reason = tostring(data.reason)
    local prefix, detail = reason:match("^([^:]+):(.*)$")
    local title
    if data.state == "leave_export_failed" or (data.state == "save_failed" and prefix == "export_failed") then
        title = "存档导出失败"
    elseif data.state == "previous_session_save_failed" or data.state == "leave_save_failed" then
        title = "上次退出保存失败"
    elseif data.state == "load_failed" then
        title = "存档读取失败"
    else
        title = "存档保存失败"
    end
    local description = FailureReasons[reason]
    if not description and FailurePrefixes[prefix] then
        description = FailurePrefixes[prefix] .. "：" .. (FailureReasons[detail] or detail)
    end
    return title .. "：" .. (description or reason)
end
function PersistenceController:Start(context)
    if context.Side ~= "Client" or not GameConfig.Persistence.ProductionEnabled then return end
    local rt = { Active = true, Ready = false, Version = -1, Snapshot = nil, WriteFailureShown = false, ResetRequestId = 0 }
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
            context.Services.PromptController:Show(FailureText(data), 5)
        elseif data.state == "save_failed" and not rt.WriteFailureShown then
            rt.WriteFailureShown = true
            Diag("show_save_failure", data)
            context.Services.PromptController:Show(FailureText(data), 5)
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
        if data.state == "frozen" or data.state == "loading" then rt.ResetPending = nil end
        Diag("accepted", data)
        Render()
    end
    System:BindNotify(context.NetMsg.Messages.PersistenceState, rt.Callback)
    rt.ResetClick = function()
        if not Current() or not rt.Ready or rt.ResetPending then return end
        if not rt.Snapshot or not rt.Snapshot.ready then
            context.Services.PromptController:Show("存档尚未就绪，暂时无法初始化", 5)
            return
        end
        rt.ResetRequestId = rt.ResetRequestId + 1
        rt.ResetPending = rt.ResetRequestId
        context.Services.PromptController:Show("正在初始化")
        System:SendToServer(context.NetMsg.Messages.PersistenceResetRequest, { requestId = rt.ResetRequestId })
    end
    rt.ResetResult = function(_, data)
        if not Current() or type(data) ~= "table" or data.requestId ~= rt.ResetPending then return end
        if data.pending then return end
        rt.ResetPending = nil
        if data.success then
            context.Services.PromptController:Show("初始化完成")
        elseif data.reason == "player_not_ready" or data.reason == "reset_in_progress" then
            context.Services.PromptController:Show("当前无法初始化：数据尚未就绪或正在初始化", 5)
        else
            if not rt.WriteFailureShown then
                rt.WriteFailureShown = true
                context.Services.PromptController:Show(FailureText({ state = "save_failed", reason = data.reason }), 5)
            end
        end
    end
    System:BindNotify(context.NetMsg.Messages.PersistenceResetResult, rt.ResetResult)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Current() then return end
        rt.Ready = true
        local ok, reason = pcall(function() UI:RegisterClicked(GameConfig.Persistence.ResetButtonId, rt.ResetClick) end)
        rt.ResetClickRegistered = ok
        if not ok then Log:PrintError("[Persistence] 初始化按钮绑定失败", tostring(reason)) end
        System:SendToServer(context.NetMsg.Messages.PersistenceSnapshotRequest, {})
    end)
    context.Timers:AddLoopTimer(self.Name, 0.5, Render)
end
function PersistenceController:Stop(context)
    local rt = context.Services.PersistenceController
    if not rt then return end
    rt.Active = false
    System:UnbindNotify(context.NetMsg.Messages.PersistenceState, rt.Callback)
    System:UnbindNotify(context.NetMsg.Messages.PersistenceResetResult, rt.ResetResult)
    if rt.ResetClickRegistered then UI:UnRegisterClicked(GameConfig.Persistence.ResetButtonId, rt.ResetClick) end
    context.Timers:RemoveOwner(self.Name)
    context.Services.PersistenceController = nil
end
return PersistenceController
