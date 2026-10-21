-- 双组影子分段；提交目录只是应用层协议，不是平台原子事务/持久落盘确认。
local Config = require "Common.Config.GameConfig"
local Codec = require "Common.PersistenceCodec"
local PersistenceService = { Name = "PersistenceService", FeatureFlag = "Persistence", Dependencies = {} }
local function Integer(n) return type(n) == "number" and n >= 1 and n <= 9007199254740991 and n == math.floor(n) end
local function Keys(prefix, separator, segmentCount)
    local keys = { prefix .. separator .. "DIR" }
    for _, group in ipairs({ "A", "B" }) do
        for i = 1, segmentCount do keys[#keys + 1] = prefix .. separator .. group .. string.format("%02d", i) end
    end
    return keys
end
function PersistenceService:ValidateConfig()
    local c = Config.Persistence
    if c.ProbeSegmentCount ~= 25 or c.ProbePaddingLength ~= 48000 or c.SegmentCount ~= 14 or c.ValueLimit ~= 2048 or c.SegmentPayload ~= 1980
        or c.ProductionPrefix == c.ProbePrefix or not c.ProductionPrefix:match("^[A-Z0-9_]+$")
        or not c.ProbePrefix:match("^[A-Z0-9_]+$") or (c.ProbeMode ~= "read" and c.ProbeMode ~= "write") then
        return false, { "Persistence分段/Key/验证模式配置无效" }
    end
    return true
end
function PersistenceService:Start(context)
    if context.Side ~= "Server" then return end
    local c = Config.Persistence
    local function Failure(operation, playerId, generation, trace, err)
        Log:PrintServerLog("[PersistenceDiag] failure", "operation:", tostring(operation),
            "playerId:", tostring(playerId), "generation:", tostring(generation), "stage:", tostring(trace.stage),
            "key:", tostring(trace.key), "valueType:", type(trace.value),
            "length:", type(trace.value) == "string" and tostring(#trace.value) or "no_string_value", "error:", tostring(err))
    end
    local runtime = { Active = true, Sessions = {}, NextGeneration = 0, Dirty = {}, Busy = {} }
    context.Services.PersistenceService = runtime
    local function Active() return runtime.Active and context.Services.PersistenceService == runtime end
    local function Online(playerId)
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do if id == playerId then return true end end
        return false
    end
    local function Begin(playerId, prefix, probe)
        local reason
        if not Active() then reason = "module_invalid"
        elseif type(playerId) ~= "number" or playerId <= 0 or playerId ~= math.floor(playerId) then reason = "id_invalid"
        elseif not Online(playerId) then reason = "not_online" end
        if reason then
            Log:PrintServerLog("[PersistenceDiag] Begin rejected", "playerId:", tostring(playerId),
                "idType:", type(playerId), "prefix:", tostring(prefix), "reason:", tostring(reason))
            return nil, "player_unavailable"
        end
        runtime.NextGeneration = runtime.NextGeneration + 1
        runtime.Sessions[playerId] = { generation = runtime.NextGeneration, prefix = prefix, probe = probe == true, separator = "",
            segmentCount = probe == true and c.ProbeSegmentCount or c.SegmentCount }
        return runtime.NextGeneration
    end
    function runtime:BeginSession(playerId, archiveReady)
        if self.Busy[playerId] then return nil, "archive_busy" end
        if not c.ProductionEnabled or archiveReady ~= true then
            local reason = not c.ProductionEnabled and "production_gate_closed" or "archive_readiness_unconfirmed"
            Log:PrintServerLog("[PersistenceDiag] Begin rejected", "playerId:", tostring(playerId),
                "idType:", type(playerId), "prefix:", tostring(c.ProductionPrefix), "reason:", tostring(reason))
            return nil, reason
        end
        return Begin(playerId, c.ProductionPrefix)
    end
    function runtime:GetKeyList(probe)
        return Keys(probe and c.ProbePrefix or c.ProductionPrefix, "", probe and c.ProbeSegmentCount or c.SegmentCount)
    end
    local function Session(playerId, generation)
        local session = runtime.Sessions[playerId]
        if not Active() or not session or session.generation ~= generation then error("stale_archive_session") end
        return session
    end
    local function Key(session, suffix)
        return session.prefix .. session.separator .. suffix
    end
    local function SampleKey(key)
        return key:sub(-3) == "DIR" or key:match("[AB]01$") or key:match("[AB]" .. string.format("%02d", c.ProbeSegmentCount) .. "$")
    end
    local function ProbeRead(session, playerId, generation, key, has, value, trace, expected)
        if not session.probe or not SampleKey(key) then return end
        Log:PrintServerLog("[PersistenceProbe] read", "playerId:", tostring(playerId), "generation:", tostring(generation),
            "context:", tostring(trace.context), "key:", tostring(key), "has:", tostring(has), "type:", type(value),
            "length:", type(value) == "string" and tostring(#value) or "no_string_value",
            "equal:", expected == nil and "notCompared" or tostring(value == expected))
        if type(value) == "string" and key:sub(-3) == "DIR" then
            Log:PrintServerLog("[PersistenceProbe] directory", "context:", tostring(trace.context), "key:", tostring(key), "value:", value)
        elseif type(value) == "string" and key:match("[AB]01$") then
            Log:PrintServerLog("[PersistenceProbe] first segment", "context:", tostring(trace.context), "key:", tostring(key), "preview120:", value:sub(1, 120))
        end
    end
    local function ReadValue(playerId, generation, key, trace, expected)
        trace.stage, trace.key, trace.value = "read_session", key, nil
        local session = Session(playerId, generation)
        trace.stage = "has_player_data"
        local has = Archive:HasPlayerData(playerId, Archive.TYPE.String, key)
        local diagnoseDirectory = session.probe and key == Key(session, "DIR")
        if diagnoseDirectory then
            Log:PrintServerLog("[PersistenceProbe] directory presence", "playerId:", tostring(playerId), "generation:", tostring(generation),
                "context:", tostring(trace.context), "key:", tostring(key), "has:", tostring(has), "hasType:", type(has))
        end
        if has ~= true then ProbeRead(session, playerId, generation, key, has, nil, trace, expected) end
        if has == false then
            if diagnoseDirectory then
                -- 仅诊断Has/Get分歧；返回值不参与加载，保持has=false的原返回。
                local ok, result = pcall(function() return Archive:GetPlayerData(playerId, Archive.TYPE.String, key) end)
                Log:PrintServerLog("[PersistenceProbe] directory diagnostic Get", "playerId:", tostring(playerId), "generation:", tostring(generation),
                    "context:", tostring(trace.context), "key:", tostring(key), "has:", tostring(has), "ok:", tostring(ok),
                    "raw:", ok and tostring(result) or "no_return_value", "type:", ok and type(result) or "no_return_value",
                    "length:", ok and type(result) == "string" and tostring(#result) or "no_string_value",
                    "error:", ok and "nil" or tostring(result), "loadDecision:", "not_found")
            end
            return nil
        end
        assert(has == true, "archive_presence_invalid")
        trace.stage = "get_player_data"
        local value = Archive:GetPlayerData(playerId, Archive.TYPE.String, key)
        if diagnoseDirectory then
            Log:PrintServerLog("[PersistenceProbe] directory normal Get", "playerId:", tostring(playerId), "generation:", tostring(generation),
                "context:", tostring(trace.context), "key:", tostring(key), "has:", tostring(has), "raw:", tostring(value),
                "type:", type(value), "length:", type(value) == "string" and tostring(#value) or "no_string_value", "error:", "nil")
        end
        trace.value, trace.stage = value, "read_validate"
        ProbeRead(session, playerId, generation, key, has, value, trace, expected)
        Session(playerId, generation)
        assert(type(value) == "string" and #value <= c.ValueLimit and not value:find("[^\032-\126]"), "archive_value_invalid")
        return value
    end
    local function SetValue(playerId, generation, key, value)
        local trace = { stage = "set_validate", key = key, value = value, context = "set_readback" }
        local firstWriteIndex
        local ok, err = pcall(function()
            assert(type(value) == "string" and #value > 0, "archive_value_empty_or_invalid")
            assert(#value <= c.ValueLimit and not value:find("[^\032-\126]"), "archive_value_over_limit")
            trace.stage = "set_session"
            local session = Session(playerId, generation)
            if session.probe then
                trace.stage = "probe_underscore_guard"
                local keyHasUnderscore, valueHasUnderscore = key:find("_", 1, true) ~= nil, value:find("_", 1, true) ~= nil
                if SampleKey(key) or keyHasUnderscore or valueHasUnderscore then
                    Log:PrintServerLog("[PersistenceProbe] preSet", "playerId:", tostring(playerId), "generation:", tostring(generation),
                        "key:", tostring(key), "keyHasUnderscore:", tostring(keyHasUnderscore), "valueHasUnderscore:", tostring(valueHasUnderscore), "length:", tostring(#value))
                end
                assert(not keyHasUnderscore and not valueHasUnderscore, "probe_key_or_value_contains_underscore")
            end
            trace.stage = "set_player_data"
            local result = Archive:SetPlayerData(playerId, Archive.TYPE.String, key, value)
            assert(result ~= false, "archive_write_rejected")
            if session.probe then
                session.probeWrittenKeys = session.probeWrittenKeys or {}
                if not session.probeWrittenKeys[key] then
                    session.probeWrittenKeyCount = (session.probeWrittenKeyCount or 0) + 1
                    firstWriteIndex = session.probeWrittenKeyCount
                    session.probeWrittenKeys[key] = firstWriteIndex
                end
            end
            trace.stage = "set_readback_session"
            Session(playerId, generation)
            local actual = ReadValue(playerId, generation, key, trace, value)
            trace.stage = "set_readback_compare"
            assert(actual == value, "archive_readback_mismatch")
        end)
        if firstWriteIndex then
            Log:PrintServerLog("[PersistenceProbe] first distinct Key Set", "playerId:", tostring(playerId),
                "generation:", tostring(generation), "index:", tostring(firstWriteIndex), "key:", tostring(key),
                "length:", tostring(#value), "immediateReadEqual:", tostring(ok), "error:", ok and "nil" or tostring(err))
        end
        if not ok then
            Failure("Set", playerId, generation, trace, err)
            error(err, 0)
        end
    end
    local function ReadCommitted(playerId, generation, trace)
        trace.stage = "read_committed_session"
        local validateIntegrity = c.ValidateReadIntegrity ~= false
        local session = Session(playerId, generation)
        local directory = ReadValue(playerId, generation, Key(session, "DIR"), trace)
        if not directory then return nil, "not_found" end
        trace.stage = "directory_validate"
        local group, rev, count, length, hash = directory:match("^D1|([AB])|([1-9][0-9]*)|([1-9][0-9]*)|([1-9][0-9]*)|([0-9A-F]+)$")
        assert(group and #rev <= 16 and #count <= 2 and #length <= 6 and #hash == 8, "directory_corrupt")
        rev, count, length = tonumber(rev), tonumber(count), tonumber(length)
        assert(Integer(rev) and count <= session.segmentCount
            and (not validateIntegrity or length <= session.segmentCount * c.SegmentPayload), "directory_limit")
        local parts = {}
        for i = 1, count do
            local value = assert(ReadValue(playerId, generation, Key(session, group .. string.format("%02d", i)), trace), "segment_missing")
            trace.stage = "segment_validate"
            local batch, index, total, checksum, payload = value:match("^P1|([0-9]+)|([0-9]+)|([0-9]+)|([0-9A-F]+)|(.*)$")
            assert(payload ~= nil, "segment_header_invalid")
            if validateIntegrity then
                assert(batch == tostring(rev) and index == tostring(i) and total == tostring(count)
                    and #payload <= c.SegmentPayload and Codec.Checksum(payload) == checksum, "segment_corrupt_or_wrong_batch")
            end
            parts[i] = payload
        end
        local text = table.concat(parts)
        trace.stage, trace.value = "snapshot_validate", text
        if validateIntegrity then
            assert(#text == length and Codec.Checksum(text) == hash, "snapshot_checksum_mismatch")
        end
        trace.stage = "snapshot_decode"
        local snapshot, err = Codec.Decode(text)
        assert(snapshot ~= nil and type(snapshot) == "table", err or "snapshot_root_invalid")
        if session.probe then
            Log:PrintServerLog("[PersistenceProbe] decoded", "playerId:", tostring(playerId), "generation:", tostring(generation),
                "context:", tostring(trace.context), "paddingLength:", type(snapshot.padding) == "string" and tostring(#snapshot.padding) or "no_string_value")
        end
        return snapshot, nil, { group = group, revision = rev }
    end
    function runtime:ReadSnapshot(playerId, generation)
        local trace = { context = "normal_read" }
        local ok, snapshot, reason = pcall(ReadCommitted, playerId, generation, trace)
        if not ok then
            Failure("Read", playerId, generation, trace, snapshot)
            return nil, tostring(snapshot)
        end
        return snapshot, reason
    end
    -- 正式写入只持有编码后的独立文本；离场后不依赖在线列表或业务对象。
    local function WriteEncoded(playerId, generation, text, completed)
        local session = runtime.Sessions[playerId]
        if not Active() or not session or session.generation ~= generation then return false, "stale_archive_session" end
        if session.probe then return false, "probe_requires_async_write" end
        if runtime.Busy[playerId] then return false, "archive_busy" end
        if type(text) ~= "string" or #text == 0 or #text > session.segmentCount * c.SegmentPayload then return false, "snapshot_over_capacity" end
        local job = { session = session, generation = generation, text = text, index = 1 }
        runtime.Busy[playerId] = job
        local trace = { context = "production_write", stage = "read_previous_directory" }
        local priorOk, prior, missing, meta = pcall(ReadCommitted, playerId, generation, trace)
        if not priorOk or (not prior and missing ~= "not_found") then
            runtime.Busy[playerId] = nil
            return false, "old_snapshot_unreadable:" .. tostring(priorOk and missing or prior)
        end
        local group = meta and meta.group == "A" and "B" or "A"
        local revision = meta and meta.revision + 1 or 1
        if not Integer(revision) then runtime.Busy[playerId] = nil; return false, "archive_revision_overflow" end
        local count = math.ceil(#text / c.SegmentPayload)
        local function CurrentJob()
            return Active() and runtime.Sessions[playerId] == session and runtime.Busy[playerId] == job
        end
        local function Finish(ok, reason)
            if runtime.Busy[playerId] ~= job then return end
            runtime.Busy[playerId] = nil
            Log:PrintServerLog("[Persistence] write_result", "playerId:", playerId, "success:", ok,
                "reason:", tostring(reason), "jsonLength:", #text, "segments:", count, "group:", group,
                "revision:", revision, "snapshotVersion:", 1)
            if completed then completed(ok, reason) end
        end
        local function Value(i)
            local payload = text:sub((i - 1) * c.SegmentPayload + 1, i * c.SegmentPayload)
            return "P1|" .. revision .. "|" .. i .. "|" .. count .. "|" .. Codec.Checksum(payload) .. "|" .. payload
        end
        local function Next()
            job.timerId = nil
            if not CurrentJob() then return end
            local committing = job.index > count
            local ok, err = pcall(function()
                if not committing then
                    trace.stage, trace.key, trace.value = "write_segment", Key(session, group .. string.format("%02d", job.index)), Value(job.index)
                    SetValue(playerId, generation, trace.key, trace.value)
                else
                    for i = 1, count do
                        local expected = Value(i)
                        assert(ReadValue(playerId, generation, Key(session, group .. string.format("%02d", i)), trace, expected) == expected, "staging_verify_failed")
                    end
                    trace.stage, trace.key, trace.value = "write_directory", Key(session, "DIR"), "D1|" .. group .. "|" .. revision .. "|" .. count .. "|" .. #text .. "|" .. Codec.Checksum(text)
                    SetValue(playerId, generation, trace.key, trace.value)
                end
            end)
            if not ok then
                Failure("Write", playerId, generation, trace, err)
                Finish(false, (committing and "commit_uncertain:" or "write_failed:") .. tostring(err))
            elseif committing then
                Finish(true, "readback_verified_not_durability_confirmed")
            elseif CurrentJob() then
                job.index = job.index + 1
                job.timerId = context.Timers:AddFrame(self.Name, 1, Next)
            end
        end
        Next()
        return true, "save_started"
    end
    function runtime:WriteSnapshot(playerId, generation, snapshot, completed)
        local text, reason = Codec.Encode(snapshot)
        if not text then return false, reason end
        return WriteEncoded(playerId, generation, text, completed)
    end
    -- 适配器只通过导出/恢复接口接入；七个模块全部登记前玩法保持闭锁。
    local adapterOrder = { "production", "placement", "treadmill", "speed", "home", "economy", "inventory" }
    local restoreOrder = { "inventory", "economy", "home", "speed", "treadmill", "placement", "production" }
    local adapters, productionStates, loadTriggers = {}, {}, {}
    local sealed, startupReady = false, false
    local statusVersion = 0
    local function SendStatus(playerId, state, reason, ready)
        statusVersion = statusVersion + 1
        System:SendToClient(playerId, context.NetMsg.Messages.PersistenceState, { version = statusVersion,
            state = state, reason = tostring(reason), ready = ready == true })
    end
    runtime.StateSnapshotCallback = function(_, _, playerId)
        local record = productionStates[playerId]
        SendStatus(playerId, record and record.state or "loading", record and record.reason or "waiting_load", runtime:IsReady(playerId))
    end
    System:BindNotify(context.NetMsg.Messages.PersistenceSnapshotRequest, runtime.StateSnapshotCallback)
    local function Status(record, state, reason)
        record.state, record.reason = state, reason
        SendStatus(record.playerId, state, reason, record.ready == true and not record.frozen)
        if state:find("failed", 1, true) then
            Log:PrintServerLog("[Persistence] state", tostring(record.playerId), tostring(state), tostring(reason))
        elseif state == "ready" and (reason == "restored" or reason == "new_player") then
            Log:PrintServerLog("[Persistence] load_result", "playerId:", record.playerId,
                "success:", true, "reason:", reason)
        end
        context.Events:Publish("PersistenceStateChanged", { playerId = record.playerId, state = state,
            reason = tostring(reason), ready = record.ready == true and not record.frozen, generation = record.generation })
    end
    function runtime:RegisterAdapter(name, adapter)
        if sealed then return false, "adapters_sealed" end
        local known = false
        for _, key in ipairs(adapterOrder) do if key == name then known = true end end
        if not known or adapters[name] or type(adapter) ~= "table" or type(adapter.Export) ~= "function"
            or type(adapter.Restore) ~= "function" then return false, "invalid_adapter" end
        adapters[name] = adapter
        return true
    end
    function runtime:SealAdapters()
        for _, name in ipairs(adapterOrder) do if not adapters[name] then return false, "missing_adapter:" .. name end end
        sealed = true
        return true
    end
    function runtime:IsReady(playerId)
        local record = productionStates[playerId]
        return Active() and c.ProductionEnabled and sealed and record ~= nil and record.ready == true and not record.frozen
    end
    function runtime:GetState(playerId)
        local record = productionStates[playerId]
        return { state = record and record.state or "integration_pending", reason = record and tostring(record.reason) or "adapters_not_sealed",
            ready = self:IsReady(playerId), generation = record and record.generation,
            dirty = record and record.changeVersion ~= record.savedVersion or false, saving = record and record.saving == true or false }
    end
    local function ExportRecord(record)
        local snapshot = { version = 1 }
        for _, name in ipairs(adapterOrder) do
            local ok, value, reason = pcall(adapters[name].Export, record.playerId)
            if not ok or type(value) ~= "table" then return nil, "export_failed:" .. name .. ":" .. tostring(ok and reason or value) end
            snapshot[name] = value
        end
        local text, err = Codec.Encode(snapshot)
        if not text then return nil, err end
        if #text > c.SegmentCount * c.SegmentPayload then return nil, "snapshot_over_capacity:" .. #text end
        return text
    end
    local SaveRecord
    local function QueueSave(record)
        if record.saveTimer or record.saving or record.frozen then return end
        record.saveTimer = context.Timers:AddFrame(self.Name, 1, function()
            record.saveTimer = nil
            if Active() and productionStates[record.playerId] == record and record.ready and not record.frozen then
                runtime:RequestSave(record.playerId)
            end
        end)
    end
    SaveRecord = function(record, completed)
        if record.saving then return false, "archive_busy" end
        record.saving = true
        local capturedVersion, text = record.pendingVersion, record.pendingText
        Status(record, record.frozen and "leaving_saving" or "saving", "save_started")
        local function Done(ok, reason)
            if not Active() or productionStates[record.playerId] ~= record then return end
            record.saving = false
            if ok then
                record.savedVersion = capturedVersion
                if record.pendingText == text and record.pendingVersion == capturedVersion then record.pendingText = nil end
                Status(record, record.leaveExportError and "leave_export_failed" or (record.frozen and "left_saved" or "ready"), record.leaveExportError or reason)
            else
                record.saveFinalAfterCurrent = nil
                Status(record, record.frozen and "leave_save_failed" or "save_failed", reason)
            end
            if ok and record.saveFinalAfterCurrent then
                record.saveFinalAfterCurrent = nil
                SaveRecord(record)
                return
            end
            if completed then completed(ok and not record.leaveExportError, record.leaveExportError or reason) end
            if productionStates[record.playerId] ~= record then return end
            if ok and not record.frozen and record.changeVersion ~= record.savedVersion then QueueSave(record) end
            if record.nextLoad then
                record.nextLoad = nil
                if ok and not record.leaveExportError then runtime:LoadPlayer(record.playerId, true)
                else Status(record, "previous_session_save_failed", reason) end
            end
        end
        local ok, reason = WriteEncoded(record.playerId, record.generation, text, Done)
        if not ok then Done(false, reason) end
        return ok, reason
    end
    function runtime:RequestSave(playerId)
        local record = productionStates[playerId]
        if not self:IsReady(playerId) then return false, "player_not_ready" end
        if record.saving then return true, "save_already_running_dirty_retained" end
        if record.changeVersion == record.savedVersion then return true, "unchanged" end
        local text, reason = ExportRecord(record)
        if not text then Status(record, "save_failed", reason); return false, reason end
        record.pendingText, record.pendingVersion = text, record.changeVersion
        return SaveRecord(record)
    end
    function runtime:MarkDirty(playerId, reason)
        if not self:IsReady(playerId) then return false, "player_not_ready" end
        local record = productionStates[playerId]
        record.changeVersion = record.changeVersion + 1
        record.dirtyReason = reason
        QueueSave(record) -- 合并本次无等待事务的全部业务通知后再导出。
        return true
    end
    function runtime:PrepareLeave(playerId)
        local record = productionStates[playerId]
        if not c.ProductionEnabled or not record then return false, "no_loaded_session" end
        if record.frozen then return true, "already_frozen" end
        local wasReady = record.ready == true
        record.frozen, record.ready = true, false
        loadTriggers[playerId] = nil
        if record.saveTimer then context.Timers:Remove(record.saveTimer); record.saveTimer = nil end
        local text, reason
        if wasReady then text, reason = ExportRecord(record) end -- Export不依赖玩法门禁，冻结后仍能读取权威数据。
        if text then
            record.changeVersion = record.changeVersion + 1
            record.pendingText, record.pendingVersion = text, record.changeVersion
        end
        Status(record, "frozen", reason or (wasReady and "leave_snapshot_captured" or "unloaded_no_save"))
        -- 所有组件导出完成后才清理，Cleanup中的重复PrepareLeave直接返回。
        for _, name in ipairs(adapterOrder) do
            if adapters[name] and adapters[name].Cleanup then
                local ok, err = pcall(adapters[name].Cleanup, playerId)
                if not ok then Log:PrintError("[Persistence] cleanup failed", name, playerId, tostring(err)) end
            end
        end
        if not text then
            if wasReady then record.leaveExportError = reason; Status(record, "leave_export_failed", reason) end
            return false, reason or "unloaded_no_save"
        end
        if record.saving then
            record.saveFinalAfterCurrent = true
            return true, "final_snapshot_queued"
        end
        return SaveRecord(record)
    end
    function runtime:LoadPlayer(playerId, archiveReady)
        if not Active() or not c.ProductionEnabled or not sealed or not startupReady or archiveReady ~= true then return false, "load_gate_closed" end
        if not Online(playerId) then return false, "player_not_online" end
        local previous = productionStates[playerId]
        if previous and previous.state == "load_failed" and not previous.frozen then return false, "load_failed_session_locked" end
        if previous and previous.frozen then
            if previous.saving then previous.nextLoad = true; return true, "waiting_previous_save" end
            if previous.leaveExportError then return false, previous.leaveExportError end
            if previous.pendingText then
                return SaveRecord(previous, function(ok) if ok then runtime:LoadPlayer(playerId, true) end end)
            end
            if previous.state == "leave_export_failed" or previous.state == "previous_session_save_failed" then return false, previous.state end
        elseif previous and (previous.loading or previous.ready) then return true, "session_already_loading_or_ready" end
        local generation, beginError = self:BeginSession(playerId, true)
        if not generation then return false, beginError end
        local record = { playerId = playerId, generation = generation, loading = true, ready = false, changeVersion = 0, savedVersion = 0 }
        local archiveSession = runtime.Sessions[playerId]
        productionStates[playerId] = record
        Status(record, "loading", "archive_read")
        local snapshot, readError = self:ReadSnapshot(playerId, generation)
        if not snapshot and readError ~= "not_found" then record.loading = false; Status(record, "load_failed", readError); return false, readError end
        if snapshot then
            for _, name in ipairs(adapterOrder) do
                if type(snapshot[name]) ~= "table" then record.loading = false; Status(record, "load_failed", "missing_component:" .. name); return false, "missing_component:" .. name end
            end
        end
        local index, notifications = 1, {}
        local function RestoreNext()
            if not Active() or productionStates[playerId] ~= record or record.frozen or runtime.Sessions[playerId] ~= archiveSession then return end
            local name = restoreOrder[index]
            if not name then
                for _, notify in ipairs(notifications) do
                    local ok, result, reason = pcall(notify)
                    if not ok or result == false then record.loading, record.ready = false, false; Status(record, "load_failed", "restore_notify_failed:" .. tostring(ok and reason or result)); return end
                end
                record.loading, record.ready = false, true
                Status(record, "ready", snapshot and "restored" or "new_player")
                context.Events:Publish("PersistenceReady", { playerId = playerId, generation = generation, restored = snapshot ~= nil })
                if not snapshot then runtime:MarkDirty(playerId, "new_player_initial_snapshot") end
                return
            end
            local called = false
            local function Done(ok, result)
                if called or not Active() or productionStates[playerId] ~= record or record.frozen or runtime.Sessions[playerId] ~= archiveSession then return end
                called = true
                if ok ~= true then record.loading = false; Status(record, "load_failed", "restore_failed:" .. name .. ":" .. tostring(result)); return end
                if type(result) == "function" then notifications[#notifications + 1] = result end
                index = index + 1
                RestoreNext()
            end
            local ok, err = pcall(adapters[name].Restore, playerId, snapshot and snapshot[name] or nil, Done)
            if not ok then Done(false, err) end
        end
        RestoreNext()
        return true, "restore_started"
    end
    for _, entry in ipairs({ { "inventory", "InventoryService" }, { "economy", "EconomyService" } }) do
        local name, serviceName = entry[1], entry[2]
        runtime:RegisterAdapter(name, {
            Export = function(playerId)
                local service = context.Services[serviceName]
                if not service then return nil, "service_unavailable" end
                return service:ExportSnapshot(playerId, service:GetSessionGeneration(playerId))
            end,
            Restore = function(playerId, snapshot, done)
                local service = context.Services[serviceName]
                if not service then done(false, "service_unavailable"); return end
                local generation = service:BeginLoadSession(playerId)
                if snapshot == nil then done(true); return end
                done(service:RestoreSnapshot(playerId, generation, snapshot))
            end,
            Cleanup = function(playerId)
                local service = context.Services[serviceName]
                if service then service:ClearPlayer(playerId, "persistence_leave") end
            end,
        })
    end
    if c.ProductionEnabled then
        for _, eventName in ipairs({ "InventoryChanged", "EconomyChanged" }) do
            context.Events:Subscribe(self.Name, eventName, function(event)
                runtime:MarkDirty(event.playerId, eventName)
            end)
        end
        context.Timers:AddTimer(self.Name, Config.Runtime.ServerReadyDelaySeconds, function() if Active() then startupReady = true end end)
        context.Events:Subscribe(self.Name, "HomeTeleportCalled", function(event)
            local home = context.Services.HomeService
            local trigger = { playerId = event.playerId, homeId = event.homeId, operationId = event.operationId, home = home }
            loadTriggers[event.playerId] = trigger
            local function CurrentTrigger()
                return Active() and loadTriggers[event.playerId] == trigger and home == context.Services.HomeService and home and home.Ready
                    and Online(event.playerId) and home:IsTeleportOperationCurrent(event.playerId, event.homeId, event.operationId)
            end
            context.Timers:AddFrame(self.Name, 2, function()
                if not CurrentTrigger() then return end
                context.Timers:AddTimer(self.Name, 1, function() if CurrentTrigger() then runtime:LoadPlayer(event.playerId, true) end end)
            end)
        end)
    end
    local probeOperations = {}
    local function ProbeLog(action, record, reason)
        Log:PrintServerLog("[PersistenceProbe] home trigger", "action:", tostring(action),
            "playerId:", tostring(record.playerId), "homeId:", tostring(record.homeId),
            "operationId:", tostring(record.operationId), "source:", tostring(record.source), "reason:", tostring(reason))
    end
    local function CancelProbe(playerId, reason, expected)
        local record = probeOperations[playerId]
        if not record or (expected and record ~= expected) then return end
        probeOperations[playerId] = nil
        if record.timerId then context.Timers:Remove(record.timerId); record.timerId = nil end
        if runtime.Busy[playerId] == record then runtime.Busy[playerId] = nil end
        if record.generation and runtime.Sessions[playerId]
            and runtime.Sessions[playerId].generation == record.generation then runtime.Sessions[playerId] = nil end
        ProbeLog("cancel", record, reason)
    end
    local function Current(record)
        if not Active() then return false, "persistence_invalid" end
        if probeOperations[record.playerId] ~= record then return false, "probe_operation_replaced" end
        local home = context.Services.HomeService
        if home ~= record.home or not home or not home.Ready then return false, "home_invalid" end
        if not Online(record.playerId) then return false, "player_not_online" end
        if not home:IsTeleportOperationCurrent(record.playerId, record.homeId, record.operationId) then return false, "teleport_or_owner_invalid" end
        return true
    end
    local function ProbeSessionCurrent(record)
        local valid, reason = Current(record)
        if not valid then return false, reason end
        local session = runtime.Sessions[record.playerId]
        if not session or session ~= record.session or session.generation ~= record.generation then
            return false, "stale_archive_session"
        end
        return true
    end
    local function DiagnoseProbeKeys(record, source)
        -- 全量只读诊断不参与加载判断；逐Key捕获错误，不因首个缺失而中断。
        for _, key in ipairs(Keys(record.session.prefix, record.session.separator, record.session.segmentCount)) do
            local valid, reason = ProbeSessionCurrent(record)
            if not valid then CancelProbe(record.playerId, reason, record); return false end
            local hasOk, has = pcall(function() return Archive:HasPlayerData(record.playerId, Archive.TYPE.String, key) end)
            local getOk, value = pcall(function() return Archive:GetPlayerData(record.playerId, Archive.TYPE.String, key) end)
            Log:PrintServerLog("[PersistenceProbe] all Key diagnostic", "playerId:", tostring(record.playerId),
                "generation:", tostring(record.generation), "context:", tostring(source), "key:", tostring(key),
                "hasOk:", tostring(hasOk), "has:", hasOk and tostring(has) or "no_return_value",
                "presence:", hasOk and (has == true and "present" or (has == false and "missing" or "invalid")) or "unavailable",
                "hasType:", hasOk and type(has) or "no_return_value", "hasError:", hasOk and "nil" or tostring(has),
                "getOk:", tostring(getOk), "rawPreview120:", getOk and (type(value) == "string" and value:sub(1, 120) or tostring(value)) or "no_return_value",
                "type:", getOk and type(value) or "no_return_value",
                "length:", getOk and type(value) == "string" and tostring(#value) or "no_string_value",
                "error:", getOk and "nil" or tostring(value))
        end
        return true
    end
    local function ScheduleProbeReadback(record)
        local valid, reason = ProbeSessionCurrent(record)
        if not valid then CancelProbe(record.playerId, reason, record); return end
        ProbeLog("schedule_1_second_readback", record, "probe_completed")
        record.timerId = context.Timers:AddTimer(self.Name, 1, function()
            record.timerId = nil
            local current, why = ProbeSessionCurrent(record)
            if not current then CancelProbe(record.playerId, why, record); return end
            if not DiagnoseProbeKeys(record, "one_second_readback") then return end
            local snapshot, readError = runtime:ReadSnapshot(record.playerId, record.generation)
            local equal = snapshot ~= nil and snapshot.version == 1 and snapshot.marker == "probe-v1"
                and snapshot.padding == string.rep("X", c.ProbePaddingLength)
            Log:PrintServerLog("[PersistenceProbe] 1秒后内容核对", "playerId:", tostring(record.playerId),
                "operationId:", tostring(record.operationId), "generation:", tostring(record.generation),
                "equal:", tostring(equal), "reason:", tostring(readError or (equal and "same_round_content_match" or "content_mismatch")))
        end)
    end
    local function WriteProbeAsync(record)
        local playerId, generation, session = record.playerId, record.generation, record.session
        if runtime.Busy[playerId] then ProbeLog("skip", record, "archive_busy"); return end
        runtime.Busy[playerId], runtime.Dirty[playerId] = record, true
        local trace = { context = "probe_async", stage = "snapshot_encode" }
        local committing = false
        -- 边界及A/B组逐条测试；每步实际Set及即时回读成功后，下一步至少间隔一帧。
        local step, text, count, boundaryKey, totalSteps = 1, nil, nil, nil, nil
        local function WriteStep()
            if step == 1 then
                local encodeError
                text, encodeError = Codec.Encode({ version = 1, marker = "probe-v1", padding = string.rep("X", c.ProbePaddingLength) })
                trace.value = text
                assert(text, encodeError)
                count = math.ceil(#text / c.SegmentPayload)
                totalSteps = 1 + 2 * (count + 1)
                assert(count == c.ProbeSegmentCount and #text <= session.segmentCount * c.SegmentPayload, "probe_snapshot_capacity")
                local keyHasUnderscore = false
                for _, key in ipairs(Keys(session.prefix, session.separator, session.segmentCount)) do
                    if key:find("_", 1, true) then keyHasUnderscore = true end
                end
                Log:PrintServerLog("[PersistenceProbe] encoded", "totalLength:", tostring(#text), "segmentCount:", tostring(count),
                    "keyCount:", tostring(#Keys(session.prefix, session.separator, session.segmentCount)),
                    "allKeysHaveNoUnderscore:", tostring(not keyHasUnderscore),
                    "paddingLength:", tostring(c.ProbePaddingLength), "valueHasUnderscore:", tostring(text:find("_", 1, true) ~= nil))
                boundaryKey = Key(session, "A" .. string.format("%02d", c.ProbeSegmentCount))
                trace.stage, trace.key, trace.value = "boundary_2048", boundaryKey, string.rep("X", 2048)
                SetValue(playerId, generation, boundaryKey, trace.value)
                return
            end
            if step == 2 then
                local b2049, e2049 = pcall(function() SetValue(playerId, generation, boundaryKey, string.rep("Y", 2049)) end)
                Log:PrintServerLog("[PersistenceProbe] 平台长度边界", "2048:", "readback_verified", "2049本地拒绝:", tostring(not b2049), "error:", tostring(e2049))
                assert(not b2049, "probe_2049_not_rejected")
            end
            local revision = step <= count + 2 and 1 or 2
            local group = revision == 1 and "A" or "B"
            local index = revision == 1 and step - 1 or step - count - 2
            local function SegmentValue(i)
                local payload = text:sub((i - 1) * c.SegmentPayload + 1, i * c.SegmentPayload)
                return "P1|" .. revision .. "|" .. i .. "|" .. count .. "|" .. Codec.Checksum(payload) .. "|" .. payload
            end
            if index <= count then
                trace.stage, trace.key, trace.value = "write_segment", Key(session, group .. string.format("%02d", index)), SegmentValue(index)
                SetValue(playerId, generation, trace.key, trace.value)
            else
                for i = 1, count do
                    local key, expected = Key(session, group .. string.format("%02d", i)), SegmentValue(i)
                    assert(ReadValue(playerId, generation, key, trace, expected) == expected, "staging_verify_failed")
                end
                local directory = "D1|" .. group .. "|" .. revision .. "|" .. count .. "|" .. #text .. "|" .. Codec.Checksum(text)
                trace.stage, trace.key, trace.value = "write_directory", Key(session, "DIR"), directory
                committing = true
                SetValue(playerId, generation, trace.key, directory)
                committing = false
            end
        end
        local function Continue()
            record.timerId = nil
            local valid, reason = ProbeSessionCurrent(record)
            if not valid then CancelProbe(playerId, reason, record); return end
            if runtime.Busy[playerId] ~= record then CancelProbe(playerId, "probe_lock_replaced", record); return end
            local ok, err = pcall(WriteStep)
            if not ok then
                if runtime.Busy[playerId] == record then runtime.Busy[playerId] = nil end
                Failure("ProbeWrite", playerId, generation, trace, (committing and "commit_uncertain:" or "write_failed:") .. tostring(err))
                return
            end
            if step == totalSteps then
                local current, why = ProbeSessionCurrent(record)
                if not current then CancelProbe(playerId, why, record); return end
                if runtime.Busy[playerId] == record then runtime.Busy[playerId], runtime.Dirty[playerId] = nil, nil end
                ProbeLog("save_completed", record, "A_B_readback_verified_not_durability_confirmed")
                ScheduleProbeReadback(record)
            else
                local current, why = ProbeSessionCurrent(record)
                if not current then CancelProbe(playerId, why, record); return end
                step = step + 1
                record.timerId = context.Timers:AddFrame(self.Name, 1, Continue)
            end
        end
        Continue()
    end
    local function RunProbe(record)
        local playerId = record.playerId
        local generation = Begin(playerId, c.ProbePrefix, true)
        if not generation then return end
        record.generation, record.session = generation, runtime.Sessions[playerId]
        if not DiagnoseProbeKeys(record, "initial_or_reentry") then return end
        local snapshot, readError = runtime:ReadSnapshot(playerId, generation)
        Log:PrintServerLog("[PersistenceProbe] 读档结果", playerId, tostring(readError or "readback_ok"), "keyCount:", #Keys(c.ProbePrefix, "", c.ProbeSegmentCount))
        if c.ProbeMode == "write" and readError == "not_found" then
            WriteProbeAsync(record)
        elseif snapshot then
            Log:PrintServerLog("[PersistenceProbe] 已有内容核对", playerId,
                snapshot.version == 1 and snapshot.marker == "probe-v1" and snapshot.padding == string.rep("X", c.ProbePaddingLength))
            ScheduleProbeReadback(record)
        end
    end
    runtime.LeaveCallback = function(playerId)
        if c.ProductionEnabled then runtime:PrepareLeave(playerId); return end
        CancelProbe(playerId, "player_preleave")
        runtime.Sessions[playerId], runtime.Busy[playerId], runtime.Dirty[playerId] = nil, nil, nil
    end
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    if c.ProbeEnabled then
        context.Events:Subscribe(self.Name, "HomeTeleportCalled", function(event)
            local home = context.Services.HomeService
            local record = { playerId = event.playerId, homeId = event.homeId, operationId = event.operationId,
                source = event.source, home = home }
            if not Active() or not home or not home.Ready or not Online(record.playerId)
                or not home:IsTeleportOperationCurrent(record.playerId, record.homeId, record.operationId) then
                ProbeLog("skip", record, "invalid_teleport_event")
                return
            end
            local previous = probeOperations[event.playerId]
            if previous and previous.home == home and previous.operationId == event.operationId then
                ProbeLog("skip", record, "duplicate_event")
                return
            end
            CancelProbe(event.playerId, "new_teleport")
            probeOperations[event.playerId] = record
            local valid, reason = Current(record)
            if not valid then CancelProbe(event.playerId, reason); return end
            ProbeLog("schedule_two_frames", record, "then_probe_then_1_second_readback")
            record.timerId = context.Timers:AddFrame(self.Name, 2, function()
                record.timerId = nil
                local current, skip = Current(record)
                if not current then CancelProbe(record.playerId, skip, record); return end
                if record.executed then ProbeLog("skip", record, "already_executed"); return end
                record.executed = true
                ProbeLog("execute", record, "two_frames_elapsed_teleport_called_not_arrival_confirmed")
                RunProbe(record)

            end)
        end)
        context.Events:Subscribe(self.Name, "HomeTeleportInvalidated", function(event)
            local record = probeOperations[event.playerId]
            if record and record.home == context.Services.HomeService and record.operationId == event.operationId then
                CancelProbe(event.playerId, event.reason)
            end
        end)
    end
end
function PersistenceService:Stop(context)
    local runtime = context.Services.PersistenceService
    if not runtime then return end
    runtime.Active = false
    context.Events:UnsubscribeOwner(self.Name)
    runtime.Sessions, runtime.Busy, runtime.Dirty = {}, {}, {}
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    System:UnbindNotify(context.NetMsg.Messages.PersistenceSnapshotRequest, runtime.StateSnapshotCallback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.PersistenceService = nil
end
return PersistenceService
