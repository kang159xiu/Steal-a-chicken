local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local TrackShopService = { Name = "TrackShopService", FeatureFlag = "TrackShop",
    Dependencies = { "EconomyService", "PlayerSpeedService", "TreadmillService", "RebirthService" } }
local function Integer(n) return type(n) == "number" and n >= 0 and n < math.huge and n == math.floor(n) end
function TrackShopService:ValidateConfig()
    local c = GameConfig.TrackShop
    local multipliers = { 1.5, 2, 2.5, 3, 3.5, 4, 5, 7, 10 }
    local prices = { "100", "5000", "75000", "1500000", "30000000", "750000000", "20000000000", "300000000000", "1000000000000" }
    if type(c) ~= "table" or #c.Tracks ~= 9 or c.ImagePropertyName ~= "踪迹图片组" then return false, { "踪迹配置无效" } end
    for i, row in ipairs(c.Tracks) do
        if row.Name ~= "踪迹" .. i or row.Multiplier ~= multipliers[i] or row.Price ~= prices[i] or not Decimal.IsValid(row.Price) then
            return false, { "踪迹档位配置无效: " .. i }
        end
    end
    return true
end
function TrackShopService:Start(context)
    if context.Side ~= "Server" then return end
    local economy, speed = context.Services.EconomyService, context.Services.PlayerSpeedService
    local treadmill, rebirth = context.Services.TreadmillService, context.Services.RebirthService
    local persistence, messages = context.Services.PersistenceService, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Sent = {}, Requests = {}, Presentation = {}, Version = 0 }
    context.Services.TrackShopService = rt
    local function Active() return rt.Active and context.Services.TrackShopService == rt end
    local function Protect(fn)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() fn((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Snapshot(id)
        if not rt.Ready or (GameConfig.Persistence.ProductionEnabled and (not persistence or not persistence:IsReady(id))) then return nil end
        local s = speed:GetSnapshot(id)
        if not s or not economy:IsCurrent(id, s.sessionGeneration) then return nil end
        return { sessionGeneration = s.sessionGeneration, trackMask = s.trackMask,
            equippedTrack = s.equippedTrack, trackVersion = s.trackVersion }
    end
    local function Send(id, force)
        local s = Snapshot(id)
        if not s then return end
        local old = rt.Sent[id]
        if not force and old and old.sessionGeneration == s.sessionGeneration and old.trackVersion == s.trackVersion
            and old.trackMask == s.trackMask and old.equippedTrack == s.equippedTrack then return end
        rt.Version = rt.Version + 1; s.version = rt.Version; rt.Sent[id] = s
        System:SendToClient(id, messages.TrackShopState, s)
    end
    local function CancelPresentation(id)
        local old = rt.Presentation[id]
        rt.Presentation[id] = nil
        if old and old.timer then context.Timers:Remove(old.timer) end
    end
    local function Online(id)
        for _, playerId in ipairs(Character:GetAllPlayerIds() or {}) do if playerId == id then return true end end
        return false
    end
    local function PresentationCurrent(id, token)
        if not Active() or rt.Presentation[id] ~= token or not Online(id) then return false end
        local s = Snapshot(id)
        return s and s.sessionGeneration == token.sessionGeneration and s.trackVersion == token.trackVersion
            and s.equippedTrack == token.equippedTrack
    end
    local function SyncPresentation(id)
        local s = Snapshot(id)
        if not s or not Online(id) then return end
        local old = rt.Presentation[id]
        if old and old.sessionGeneration == s.sessionGeneration and old.trackVersion == s.trackVersion
            and old.equippedTrack == s.equippedTrack then return end
        CancelPresentation(id)
        local token = { sessionGeneration = s.sessionGeneration, trackVersion = s.trackVersion, equippedTrack = s.equippedTrack }
        rt.Presentation[id] = token
        if not PresentationCurrent(id, token) then return end
        local ok, err = pcall(function()
            CustomProperty:SetCustomProperty(id, "踪迹序号", CustomProperty.PROPERTY_TYPE.Number, token.equippedTrack)
        end)
        if not ok then
            Log:PrintError("[TrackShop] 踪迹序号写入异常，不发信号不重试", id, token.sessionGeneration, token.trackVersion, tostring(err))
            return
        end
        if not PresentationCurrent(id, token) then return end
        token.timer = context.Timers:AddTimer(self.Name, 1, Protect(function()
            token.timer = nil
            if not PresentationCurrent(id, token) then return end
            local signOk, signError = pcall(function() System:FireSignEvent("切换踪迹成功", { id }) end)
            if not signOk then
                Log:PrintError("[TrackShop] 切换踪迹成功信号异常，不重试", id, token.sessionGeneration, token.trackVersion, tostring(signError))
            end
        end))
    end
    rt.Action = Protect(function(_, request, id)
        if not Integer(id) or id == 0 or type(request) ~= "table" or not Integer(request.requestId) or request.requestId == 0
            or not Integer(request.sessionGeneration) or not Integer(request.trackVersion)
            or not Integer(request.trackIndex) or not GameConfig.TrackShop.Tracks[request.trackIndex] then return end
        local function Result(success, reason)
            System:SendToClient(id, messages.TrackShopResult, { sessionGeneration = request.sessionGeneration,
                requestId = request.requestId, trackIndex = request.trackIndex, trackVersion = request.trackVersion,
                success = success, reason = reason })
        end
        local s = Snapshot(id)
        if not s or s.sessionGeneration ~= request.sessionGeneration then Result(false, "session_unavailable"); return end
        local prior = rt.Requests[id]
        if not prior or prior.generation ~= s.sessionGeneration then prior = { generation = s.sessionGeneration, last = 0 }; rt.Requests[id] = prior end
        if request.requestId <= prior.last then Result(false, "stale_request"); return end
        prior.last = request.requestId
        local lock, reason = rebirth:TryAcquirePurchaseLock(id, s.sessionGeneration)
        if not lock then Result(false, reason); return end
        local function Reject(why)
            rebirth:ReleasePurchaseLock(id, lock)
            Send(id); Result(false, why)
        end
        local settled, settlementError = pcall(function()
            local allowed; allowed, reason = economy:CanPurchaseMultiplier(id, s.sessionGeneration)
            if not allowed then Reject(reason); return end
            allowed, reason = treadmill:CanPurchaseMultiplier(id, s.sessionGeneration)
            if not allowed then Reject(reason); return end
            if not rebirth:IsPurchaseLockCurrent(id, s.sessionGeneration, lock) then Reject("purchase_lock_expired"); return end
            local commit, owned, changed = speed:PrepareTrackCommit(id, s.sessionGeneration, request.trackVersion, request.trackIndex)
            if not commit then Reject(owned); return end
            -- 从此到commit均无等待、引擎调用或事件；TryDebit成功后仅执行已准备好的Lua赋值。
            local publishMoney
            if not owned then
                allowed, publishMoney = economy:TryDebit(id, s.sessionGeneration, GameConfig.TrackShop.Tracks[request.trackIndex].Price)
                if not allowed then Reject(publishMoney); return end
            end
            local publishGrowth = commit()
            local function Notify(kind, fn)
                if not fn then return end
                local ok, result, why = pcall(fn)
                if not ok or result == false then
                    Log:PrintError("[TrackShop] 提交后通知失败，不重扣", id, kind, tostring(ok and why or result))
                end
            end
            Notify("economy", publishMoney)
            Notify("growth", publishGrowth)
            Send(id); Result(true, not changed and "already_equipped" or (owned and "track_equipped" or "track_purchased"))
        end)
        rebirth:ReleasePurchaseLock(id, lock)
        if not settled then error(settlementError) end
    end)
    rt.Snapshot = Protect(function(_, request, id)
        if Integer(id) and type(request) == "table" and next(request) == nil then Send(id, true) end
    end)
    rt.Leave = Protect(function(id) CancelPresentation(id); rt.Sent[id] = nil; rt.Requests[id] = nil end)
    rt.Notifies = { { messages.TrackShopAction, rt.Action }, { messages.TrackShopSnapshotRequest, rt.Snapshot } }
    for _, pair in ipairs(rt.Notifies) do System:BindNotify(pair[1], pair[2]) end
    rt.Bindings = { { Events.ON_PLAYER_PRELEAVE, rt.Leave }, { Events.ON_PLAYER_RECONNECTED, rt.Leave } }
    for _, pair in ipairs(rt.Bindings) do System:RegisterEvent(pair[1], pair[2]) end
    for _, event in ipairs({ "PlayerSpeedChanged", "PersistenceReady" }) do
        context.Events:Subscribe(self.Name, event, Protect(function(data) Send(data.playerId); SyncPresentation(data.playerId) end))
    end
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ServerReadyDelaySeconds, Protect(function()
        rt.Ready = true
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do Send(id); SyncPresentation(id) end
    end))
end
function TrackShopService:Stop(context)
    local rt = context.Services.TrackShopService
    if not rt then return end
    rt.Active = false; rt.Requests = {}; rt.Sent = {}; rt.Presentation = {}
    for _, pair in ipairs(rt.Notifies) do System:UnbindNotify(pair[1], pair[2]) end
    for _, pair in ipairs(rt.Bindings) do System:UnregisterEvent(pair[1], pair[2]) end
    context.Events:UnsubscribeOwner(self.Name); context.Timers:RemoveOwner(self.Name)
    context.Services.TrackShopService = nil
end
return TrackShopService
