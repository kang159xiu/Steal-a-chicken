local GameConfig = require "Common.Config.GameConfig"
local ChickenObtainedController = { Name = "ChickenObtainedController", FeatureFlag = "Inventory", Dependencies = {} }

local function Integer(n)
    return type(n) == "number" and n > 0 and n <= 9007199254740991 and n == math.floor(n)
end

function ChickenObtainedController:Start(context)
    if context.Side ~= "Client" then return end
    local c, messages = GameConfig.ChickenObtained, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, SessionReady = false, Generation = 0,
        Version = -1, DepartedThrough = 0, Token = 0, Queue = {}, Seen = {}, Copies = {} }
    context.Services.ChickenObtainedController = rt
    local function Active() return rt.Active and context.Services.ChickenObtainedController == rt end
    local function Diag(stage, data, reason)
        pcall(function()
            local read, localId = pcall(function() return Character:GetLocalPlayerId() end)
            local record = type(data) == "table" and data or {}
            if type(reason) == "function" then reason = reason() end
            Log:PrintLog("[ChickenObtainedDiag]", "stage:", stage,
                "localPlayerId:", read and tostring(localId) or "unavailable",
                "itemId:", tostring(record.itemId), "chickenType:", tostring(record.chickenType),
                "eventGeneration:", tostring(record.generation), "uid:", tostring(record.uid),
                "Ready:", rt.Ready, "SessionReady:", rt.SessionReady, "generation:", rt.Generation,
                "queueCount:", #rt.Queue, "token:", rt.Token, "active:", rt.Active, "reason:", tostring(reason))
        end)
    end
    local function Sample(stage)
        -- 每个探针单独隔离，读取失败也不影响下一项；不改控件状态。
        for _, id in ipairs({ c.GroupId, c.ImageId, c.TextId }) do
            local function Probe(field, read)
                local ok, value = pcall(read)
                pcall(function()
                    local state = ok and type(value) == "table" and value or {}
                    Diag(stage, { uid = id }, field .. ":ok=" .. tostring(ok)
                        .. ",value=" .. tostring(value) .. ",IsShow=" .. tostring(state.IsShow)
                        .. ",IsVisible=" .. tostring(state.IsVisible))
                end)
            end
            Probe("GetWidgetState", function() return UI:GetWidgetState(id) end)
            Probe("GetUIName", function() return UI:GetUIName(id) end)
            Probe("GetParent", function() return UI:GetParent(id) end)
        end
    end
    rt.Diag = Diag
    Diag("start")
    local function Call(stage, callback)
        local ok, value = pcall(callback)
        Diag("ui_call_result", rt.Current, function() return stage .. ":ok=" .. tostring(ok) .. ",value=" .. tostring(value) end)
        if not ok then
            if stage == "source_paths" or stage:sub(1, 5) == "show:" then Sample("path_or_fill_failed") end
            pcall(function() Log:PrintError("[ChickenObtainedController] 提示失败，不重试", stage, tostring(value)) end)
        end
        return ok, value
    end
    local function CancelTask()
        rt.Token = rt.Token + 1
        if rt.Task then context.Timers:Remove(rt.Task); rt.Task = nil end
    end
    local function Destroy(copy)
        if not copy or rt.Copies[copy.uid] ~= copy then return end
        rt.Copies[copy.uid] = nil
        Diag("destroy_begin", copy)
        Call("stop:" .. copy.uid, function() UI:StopUIAnimation(copy.uid) end)
        Call("hide:" .. copy.uid, function() UI:SetVisibility({ copy.uid }, false) end)
        Call("delete:" .. copy.uid, function() UI:OnShow({ copy.uid }, false) end)
        Diag("destroy_finished", copy)
    end
    local function ClearCurrent()
        CancelTask()
        local copy = rt.Current
        rt.Current = nil
        Destroy(copy)
    end
    local function UniqueChild(parent, name)
        local found
        local children = UI:GetAllChildren(parent)
        if type(children) ~= "table" then error("提示子控件列表无效") end
        for _, child in ipairs(children) do
            if UI:GetUIName(child) == name then
                if found then
                    Diag("path_name_conflict", rt.Current, function()
                        local ids = {}; for _, id in ipairs(children) do ids[#ids + 1] = tostring(id) end
                        return "parent=" .. tostring(parent) .. ",name=" .. tostring(name) .. ",children=" .. table.concat(ids, ",")
                    end)
                    error("提示路径存在同名子控件: " .. name)
                end
                found = child
            end
        end
        local child = UI:FindChildWithName(parent, name)
        if not Integer(child) or child ~= found then error("提示路径不可用: " .. name) end
        return child
    end
    local function ReadPath(id)
        local path, seen = {}, {}
        while id ~= c.GroupId do
            if seen[id] then error("提示子控件路径循环") end
            seen[id] = true
            local name, parent = UI:GetUIName(id), UI:GetParent(id)
            if type(name) ~= "string" or name == "" or not Integer(parent)
                or UniqueChild(parent, name) ~= id then error("提示子控件不在源组内") end
            table.insert(path, 1, name); id = parent
        end
        return path
    end
    local function CopyChild(uid, path, sourceId)
        for _, name in ipairs(path) do uid = UniqueChild(uid, name) end
        if uid == sourceId then error("提示副本子控件返回源UID") end
        return uid
    end
    local function Current(entry, token)
        local current = Active() and rt.Ready and rt.SessionReady and rt.Current == entry
            and rt.Token == token
        if not current then Diag("callback_reject", entry, function()
            return "expectedToken=" .. tostring(token) .. ",moduleCurrent=" .. tostring(Active())
                .. ",entryCurrent=" .. tostring(rt.Current == entry) .. ",departedThrough=" .. tostring(rt.DepartedThrough)
        end) end
        return current
    end
    local Pump
    local function Finish(entry, token)
        if not Current(entry, token) then return end
        ClearCurrent()
        local nextToken = rt.Token
        rt.Task = context.Timers:AddFrame(ChickenObtainedController.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() or rt.Token ~= nextToken then
                Diag("next_callback_reject", entry, "module_or_token_changed"); return
            end
            rt.Task = nil; Pump()
        end)
    end
    Pump = function()
        if not Active() or not rt.Ready or not rt.SessionReady or rt.Current or rt.Task then
            Diag("pump_deferred", rt.Current, function()
                return "moduleCurrent=" .. tostring(Active()) .. ",hasCurrent=" .. tostring(rt.Current ~= nil) .. ",hasTask=" .. tostring(rt.Task ~= nil)
            end)
            return
        end
        local entry = table.remove(rt.Queue, 1)
        if not entry then return end
        rt.Current = entry; rt.Token = rt.Token + 1
        local token = rt.Token
        local copied, uid = Call("duplicate:" .. entry.itemId, function()
            local value = UI:DuplicateWidget(c.GroupId, c.X, c.Y)
            if not Integer(value) or value == c.GroupId or rt.Copies[value] then error("复制未返回独立UID") end
            return value
        end)
        if not copied then Finish(entry, token); return end
        entry.uid = uid; rt.Copies[uid] = entry
        Diag("copy_created", entry)
        if not Current(entry, token) then Destroy(entry); return end
        rt.Task = context.Timers:AddFrame(ChickenObtainedController.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Current(entry, token) then Destroy(entry); return end
            rt.Task = nil
            local shown = Call("show:" .. entry.itemId, function()
                local chicken = GameConfig.ChickenTypes[entry.chickenType]
                local image = rt.Images[chicken.ChickenIconIndex]
                if image == nil or image == 0 then error("鸡图标缺失: " .. entry.chickenType) end
                local imageUid = CopyChild(uid, rt.ImagePath, c.ImageId)
                local textUid = CopyChild(uid, rt.TextPath, c.TextId)
                Diag("fill_children", entry, "imageUid=" .. tostring(imageUid) .. ",textUid=" .. tostring(textUid))
                UI:SetImage({ imageUid }, image, true)
                UI:SetText({ textUid }, "获得" .. chicken.DisplayName, false)
                UI:SetTransparency({ uid }, 1)
                UI:SetVisibility({ uid }, true)
            end)
            Diag("show_result", entry, tostring(shown))
            if not shown then Finish(entry, token); return end
            if not Current(entry, token) then Destroy(entry); return end
            -- 从副本装填并显示后起计；启动及复制落地等待不占展示时间。
            rt.Task = context.Timers:AddTimer(ChickenObtainedController.Name, c.VisibleSeconds, function()
                if not Current(entry, token) then return end
                rt.Task = nil
                if not Call("animation:" .. entry.itemId, function() UI:PlayUIAnimation(uid, c.AnimationIndex, 0) end) then
                    Finish(entry, token); return
                end
                rt.Task = context.Timers:AddTimer(ChickenObtainedController.Name, c.HideSeconds, function()
                    if not Current(entry, token) then return end
                    rt.Task = nil; Finish(entry, token)
                end)
            end)
        end)
    end

    rt.Destroy = Destroy
    rt.ObtainedCallback = function(_, data)
        Diag("notify_received", data)
        if not Active() or type(data) ~= "table"
            or type(data.itemId) ~= "string" or data.itemId == ""
            or not GameConfig.ChickenTypes[data.chickenType] then
            Diag("notify_rejected", data, function()
                if not Active() then return "module_inactive" end
                if type(data) ~= "table" then return "invalid_payload" end
                if type(data.itemId) ~= "string" or data.itemId == "" then return "invalid_itemId" end
                return "unknown_chickenType"
            end)
            return
        end
        if rt.Seen[data.itemId] then Diag("notify_rejected", data, "duplicate_itemId"); return end
        rt.Seen[data.itemId] = true
        rt.Queue[#rt.Queue + 1] = { itemId = data.itemId, chickenType = data.chickenType, generation = data.generation }
        Diag("notify_accepted", data)
        Pump()
    end
    rt.StateCallback = function(_, data)
        Diag("state_received", data)
        if not Active() or type(data) ~= "table" or type(data.version) ~= "number" or data.version <= rt.Version then
            Diag("state_rejected", data, "inactive_or_invalid_or_old_version"); return
        end
        rt.Version = data.version
        if data.ready ~= true then ClearCurrent() end
        if data.generation ~= nil then rt.Generation = data.generation end
        rt.SessionReady = data.ready == true
        Diag("state_accepted", data)
        Pump()
    end
    rt.LeaveCallback = function(playerId)
        if not Active() or playerId ~= Character:GetLocalPlayerId() then return end
        rt.DepartedThrough = rt.Generation
        rt.SessionReady = false; ClearCurrent(); rt.Queue = {}; rt.Seen = {}
        Diag("local_leave_or_reconnect")
    end
    -- 注册不依赖引擎就绪；首个获得通知和早到的会话状态均可缓存。
    System:BindNotify(messages.ChickenObtained, rt.ObtainedCallback)
    System:BindNotify(messages.PersistenceState, rt.StateCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, rt.LeaveCallback)
    System:RegisterEvent(Events.ON_PLAYER_RECONNECTED, rt.LeaveCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then Diag("init_callback_reject", nil, "module_inactive"); return end
        Diag("init_begin")
        local ok, images = Call("images", function()
            local images = CustomProperty:GetCustomPropertyArray(System:GetScriptParentID(),
                GameConfig.ImageGroups.ChickenPropertyName, CustomProperty.PROPERTY_TYPE.Image)
            if type(images) ~= "table" then error("鸡图标数组无效") end
            return images
        end)
        if not ok then return end
        rt.Images = images
        Diag("images_loaded", nil, "count=" .. tostring(#images))
        for _, typeId in ipairs(GameConfig.ChickenTypeOrder) do
            local chicken = GameConfig.ChickenTypes[typeId]
            if images[chicken.ChickenIconIndex] == nil or images[chicken.ChickenIconIndex] == 0 then
                Diag("image_missing", { chickenType = typeId })
                pcall(function() Log:PrintError("[ChickenObtainedController] 鸡图标缺失，不重试", typeId) end)
                return
            end
        end
        Sample("source_before")
        local visible = Call("source", function()
            UI:SetTransparency({ c.GroupId }, 0)
            UI:SetVisibility({ c.GroupId }, true)
        end)
        Diag("source_prepared", nil, tostring(visible))
        if not visible then return end
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() then Diag("paths_callback_reject", nil, "module_inactive"); return end
            Sample("source_after_landing")
            local read = Call("source_paths", function()
                rt.ImagePath, rt.TextPath = ReadPath(c.ImageId), ReadPath(c.TextId)
            end)
            Diag("paths_result", nil, function()
                return "ok=" .. tostring(read) .. ",imagePath=" .. (rt.ImagePath and table.concat(rt.ImagePath, "/") or "nil")
                    .. ",textPath=" .. (rt.TextPath and table.concat(rt.TextPath, "/") or "nil")
            end)
            if not read then Sample("paths_failed"); return end
            rt.Ready = true; Diag("ready"); Pump()
        end)
    end)

end

function ChickenObtainedController:Stop(context)
    local rt = context.Services.ChickenObtainedController
    if not rt then return end
    rt.Diag("stop_begin")
    rt.Active = false; rt.Token = rt.Token + 1; rt.Queue = {}; rt.Seen = {}; rt.Current = nil
    context.Timers:RemoveOwner(self.Name)
    System:UnbindNotify(context.NetMsg.Messages.ChickenObtained, rt.ObtainedCallback)
    System:UnbindNotify(context.NetMsg.Messages.PersistenceState, rt.StateCallback)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, rt.LeaveCallback)
    System:UnregisterEvent(Events.ON_PLAYER_RECONNECTED, rt.LeaveCallback)
    local copies = {}
    for _, copy in pairs(rt.Copies) do copies[#copies + 1] = copy end
    for _, copy in ipairs(copies) do rt.Destroy(copy) end
    local ok, err = pcall(function() UI:SetVisibility({ GameConfig.ChickenObtained.GroupId }, false) end)
    rt.Diag("stop_source_hide_result", nil, tostring(ok))
    if not ok then pcall(function() Log:PrintError("[ChickenObtainedController] 停止隐藏源组失败", tostring(err)) end) end
    context.Services.ChickenObtainedController = nil
    rt.Diag("stop_finished")
end

return ChickenObtainedController
