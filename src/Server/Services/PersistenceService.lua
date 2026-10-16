-- 双组影子分段；提交目录只是应用层协议，不是平台原子事务/持久落盘确认。
local Config = require "Common.Config.GameConfig"
local Codec = require "Common.PersistenceCodec"
local PersistenceService = { Name = "PersistenceService", FeatureFlag = "Persistence", Dependencies = {} }
local function Integer(n) return type(n) == "number" and n >= 1 and n <= 9007199254740991 and n == math.floor(n) end
local function Keys(prefix)
    local keys = { prefix .. "_DIR" }
    for _, group in ipairs({ "A", "B" }) do
        for i = 1, 49 do keys[#keys + 1] = prefix .. "_" .. group .. string.format("%02d", i) end
    end
    return keys
end
function PersistenceService:ValidateConfig()
    local c = Config.Persistence
    if c.SegmentCount ~= 49 or c.ValueLimit ~= 2048 or c.SegmentPayload ~= 1980
        or c.ProductionPrefix == c.ProbePrefix or not c.ProductionPrefix:match("^[A-Z0-9_]+$")
        or not c.ProbePrefix:match("^[A-Z0-9_]+$") or (c.ProbeMode ~= "read" and c.ProbeMode ~= "write") then
        return false, { "Persistence分段/Key/验证模式配置无效" }
    end
    return true
end
function PersistenceService:Start(context)
    if context.Side ~= "Server" then return end
    local c = Config.Persistence
    local runtime = { Active = true, Sessions = {}, NextGeneration = 0, Dirty = {}, Busy = {} }
    context.Services.PersistenceService = runtime
    local function Active() return runtime.Active and context.Services.PersistenceService == runtime end
    local function Online(playerId)
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do if id == playerId then return true end end
        return false
    end
    local function Begin(playerId, prefix)
        if not Active() or not Integer(playerId) or not Online(playerId) then return nil, "player_unavailable" end
        runtime.NextGeneration = runtime.NextGeneration + 1
        runtime.Sessions[playerId] = { generation = runtime.NextGeneration, prefix = prefix }
        return runtime.NextGeneration
    end
    function runtime:BeginSession(playerId, archiveReady)
        if not c.ProductionEnabled then return nil, "production_gate_closed" end
        if archiveReady ~= true then return nil, "archive_readiness_unconfirmed" end
        return Begin(playerId, c.ProductionPrefix)
    end
    function runtime:GetKeyList(probe)
        return Keys(probe and c.ProbePrefix or c.ProductionPrefix)
    end
    local function Session(playerId, generation)
        local session = runtime.Sessions[playerId]
        if not Active() or not session or session.generation ~= generation then error("stale_archive_session") end
        return session
    end
    local function ReadValue(playerId, generation, key)
        Session(playerId, generation)
        local has = Archive:HasPlayerData(playerId, Archive.TYPE.String, key)
        if has == false then return nil end
        assert(has == true, "archive_presence_invalid")
        local value = Archive:GetPlayerData(playerId, Archive.TYPE.String, key)
        Session(playerId, generation)
        assert(type(value) == "string" and #value <= c.ValueLimit and not value:find("[^\032-\126]"), "archive_value_invalid")
        return value
    end
    local function SetValue(playerId, generation, key, value)
        assert(#value <= c.ValueLimit and not value:find("[^\032-\126]"), "archive_value_over_limit")
        Session(playerId, generation)
        local result = Archive:SetPlayerData(playerId, Archive.TYPE.String, key, value)
        assert(result ~= false, "archive_write_rejected")
        Session(playerId, generation)
        assert(ReadValue(playerId, generation, key) == value, "archive_readback_mismatch")
    end
    local function ReadCommitted(playerId, generation)
        local prefix = Session(playerId, generation).prefix
        local directory = ReadValue(playerId, generation, prefix .. "_DIR")
        if not directory then return nil, "not_found" end
        local group, rev, count, length, hash = directory:match("^D1|([AB])|([1-9][0-9]*)|([1-9][0-9]*)|([1-9][0-9]*)|([0-9A-F]+)$")
        assert(group and #rev <= 16 and #count <= 2 and #length <= 6 and #hash == 8, "directory_corrupt")
        rev, count, length = tonumber(rev), tonumber(count), tonumber(length)
        assert(Integer(rev) and count <= 49 and length <= 49 * c.SegmentPayload, "directory_limit")
        local parts = {}
        for i = 1, count do
            local value = assert(ReadValue(playerId, generation, prefix .. "_" .. group .. string.format("%02d", i)), "segment_missing")
            local batch, index, total, checksum, payload = value:match("^P1|([0-9]+)|([0-9]+)|([0-9]+)|([0-9A-F]+)|(.*)$")
            assert(batch == tostring(rev) and index == tostring(i) and total == tostring(count)
                and #payload <= c.SegmentPayload and Codec.Checksum(payload) == checksum, "segment_corrupt_or_wrong_batch")
            parts[i] = payload
        end
        local text = table.concat(parts)
        assert(#text == length and Codec.Checksum(text) == hash, "snapshot_checksum_mismatch")
        local snapshot, err = Codec.Decode(text)
        assert(snapshot ~= nil and type(snapshot) == "table", err or "snapshot_root_invalid")
        return snapshot, nil, { group = group, revision = rev }
    end
    function runtime:ReadSnapshot(playerId, generation)
        local ok, snapshot, reason = pcall(ReadCommitted, playerId, generation)
        if not ok then return nil, tostring(snapshot) end
        return snapshot, reason
    end
    function runtime:WriteSnapshot(playerId, generation, snapshot)
        local session = self.Sessions[playerId]
        if not Active() or not session or session.generation ~= generation then return false, "stale_archive_session" end
        if self.Busy[playerId] then return false, "archive_busy" end
        self.Busy[playerId], self.Dirty[playerId] = true, true
        local committing = false
        local ok, err = pcall(function()
            assert(type(snapshot) == "table", "snapshot_root_invalid")
            local text, encodeError = Codec.Encode(snapshot)
            assert(text, encodeError)
            assert(#text <= 49 * c.SegmentPayload, "snapshot_over_capacity")
            local prior, missing, meta = ReadCommitted(playerId, generation)
            assert(prior ~= nil or missing == "not_found", "old_snapshot_unreadable")
            local group = meta and meta.group == "A" and "B" or "A"
            local revision = meta and meta.revision + 1 or 1
            assert(Integer(revision), "archive_revision_overflow")
            local count = math.ceil(#text / c.SegmentPayload)
            for i = 1, count do
                local payload = text:sub((i - 1) * c.SegmentPayload + 1, i * c.SegmentPayload)
                local value = "P1|" .. tostring(revision) .. "|" .. i .. "|" .. count .. "|" .. Codec.Checksum(payload) .. "|" .. payload
                SetValue(playerId, generation, session.prefix .. "_" .. group .. string.format("%02d", i), value)
            end
            -- 全组再次回读完成后才写目录；不读取另一组补缺。
            for i = 1, count do
                local payload = text:sub((i - 1) * c.SegmentPayload + 1, i * c.SegmentPayload)
                local expected = "P1|" .. tostring(revision) .. "|" .. i .. "|" .. count .. "|" .. Codec.Checksum(payload) .. "|" .. payload
                assert(ReadValue(playerId, generation, session.prefix .. "_" .. group .. string.format("%02d", i)) == expected, "staging_verify_failed")
            end
            local directory = "D1|" .. group .. "|" .. tostring(revision) .. "|" .. count .. "|" .. #text .. "|" .. Codec.Checksum(text)
            committing = true
            SetValue(playerId, generation, session.prefix .. "_DIR", directory)
        end)
        self.Busy[playerId] = nil
        if not ok then return false, (committing and "commit_uncertain:" or "write_failed:") .. tostring(err) end
        if Active() and self.Sessions[playerId] == session then self.Dirty[playerId] = nil end
        return true, "readback_verified_not_durability_confirmed"
    end
    runtime.LeaveCallback = function(playerId)
        runtime.Sessions[playerId], runtime.Busy[playerId], runtime.Dirty[playerId] = nil, nil, nil
    end
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    -- 验证只采用服务端枚举到的在线玩家ID和服务端构造内容；没有客户端写入协议。
    if c.ProbeEnabled then
        context.Timers:AddTimer(self.Name, Config.Runtime.ServerReadyDelaySeconds, function()
            if not Active() then return end
            for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do
                local generation = Begin(playerId, c.ProbePrefix)
                if generation then
                    local snapshot, readError = runtime:ReadSnapshot(playerId, generation)
                    Log:PrintServerLog("[PersistenceProbe] 读档结果", playerId, readError or "readback_ok", "keyCount:", #Keys(c.ProbePrefix))
                    if c.ProbeMode == "write" and readError == "not_found" then
                        -- 仅验证命名空间：原始边界探针随后被合法分段覆盖。
                        local boundaryKey = c.ProbePrefix .. "_A49"
                        local b2048, e2048 = pcall(function()
                            Archive:SetPlayerData(playerId, Archive.TYPE.String, boundaryKey, string.rep("X", 2048))
                            assert(Archive:GetPlayerData(playerId, Archive.TYPE.String, boundaryKey) == string.rep("X", 2048), "2048_readback_failed")
                        end)
                        local b2049, e2049 = pcall(function()
                            SetValue(playerId, generation, boundaryKey, string.rep("Y", 2049))
                        end)
                        Log:PrintServerLog("[PersistenceProbe] 平台长度边界", playerId, "2048:", b2048, tostring(e2048), "2049本地拒绝:", not b2049, tostring(e2049))
                        -- 足以占满49段，测试99个Key配置；独立边界探针见下方方法。
                        local ok, reason = runtime:WriteSnapshot(playerId, generation, { version = 1, marker = "probe-v1", padding = string.rep("X", 95000) })
                        Log:PrintServerLog("[PersistenceProbe] 写入结果", playerId, ok, reason)
                        if ok then
                            local second, secondReason = runtime:WriteSnapshot(playerId, generation, { version = 1, marker = "probe-v1", padding = string.rep("X", 95000) })
                            Log:PrintServerLog("[PersistenceProbe] 第二组写入结果", playerId, second, secondReason)
                        end
                    elseif snapshot then
                        Log:PrintServerLog("[PersistenceProbe] 跨局内容核对", playerId,
                            snapshot.marker == "probe-v1" and snapshot.padding == string.rep("X", 95000))
                    end
                end
            end
        end)
    end
end
function PersistenceService:Stop(context)
    local runtime = context.Services.PersistenceService
    if not runtime then return end
    runtime.Active = false
    runtime.Sessions, runtime.Busy, runtime.Dirty = {}, {}, {}
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.PersistenceService = nil
end
return PersistenceService
