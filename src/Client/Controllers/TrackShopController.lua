local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local TrackShopController = { Name = "TrackShopController", FeatureFlag = "TrackShop", Dependencies = { "PromptController" } }
local function Integer(n) return type(n) == "number" and n >= 0 and n < math.huge and n == math.floor(n) end
function TrackShopController:Start(context)
    if context.Side ~= "Client" then return end
    local c, messages = GameConfig.TrackShop, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Version = 0, Session = 0, RequestId = 0, RowVersion = 0,
        Rows = {}, ByItem = {}, Images = {}, AddedCount = 0 }
    context.Services.TrackShopController = rt
    local function Active() return rt.Active and context.Services.TrackShopController == rt end
    local function Protect(fn)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() fn((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Current(row)
        return Active() and rt.Ready and rt.State and row.session == rt.Session
            and rt.Rows[row.index] == row and rt.ByItem[row.itemId] == row
    end
    local function Unbind(row)
        if row.click then UI:UnRegisterClicked(row.buttonUid, row.click); row.click = nil end
    end
    local function Reset(clearInitialized)
        for _, row in pairs(rt.Rows) do Unbind(row); row.binding = (row.binding or 0) + 1 end
        rt.Rows, rt.ByItem, rt.Pending, rt.AddedCount = {}, {}, nil, 0
        if rt.Ready or (clearInitialized and rt.ListInitialized) then UI:ClearListView(c.TileViewId) end
    end
    local function Request(row)
        if not Current(row) or not row.landed or rt.Pending or row.label == "已装备" then return end
        rt.RequestId = rt.RequestId + 1
        local request = { requestId = rt.RequestId, sessionGeneration = rt.Session,
            trackVersion = rt.State.trackVersion, trackIndex = row.index }
        rt.Pending = request
        System:SendToServer(messages.TrackShopAction, request)
    end
    local function Paint(row, binding)
        local function UID(child)
            local uid = UI:GetListViewItemUID(c.TileViewId, row.itemId, child)
            if not uid or uid == "" then error("踪迹列表缺少子UID: " .. tostring(child)) end
            return uid
        end
        local config = c.Tracks[row.index]
        UI:SetText({ UID(c.NameTextId) }, config.Name, false)
        UI:SetText({ UID(c.MultiplierTextId) }, "x" .. tostring(config.Multiplier):gsub("%.0$", ""), false)
        UI:SetText({ UID(c.ActionTextId) }, row.label, false)
        UI:SetImage({ UID(c.ImageId) }, rt.Images[row.index], true)
        row.buttonUid = UID(c.ButtonId)
        row.click = Protect(function()
            if not Current(row) or row.binding ~= binding or not row.landed then return end
            Request(row)
        end)
        UI:RegisterClicked(row.buttonUid, row.click)
    end
    rt.ItemSet = Protect(function(listId, itemId, data)
        if listId ~= c.TileViewId or type(data) ~= "table" then return end
        local row = rt.Rows[data.trackIndex]
        if not row or data.rowVersion ~= row.version or data.sessionGeneration ~= row.session
            or (row.itemId and row.itemId ~= itemId) or (rt.ByItem[itemId] and rt.ByItem[itemId] ~= row) then return end
        Unbind(row)
        row.itemId = itemId; rt.ByItem[itemId] = row
        row.binding = (row.binding or 0) + 1; row.landed = false
        local binding = row.binding
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            if not Current(row) or row.binding ~= binding or row.version ~= data.rowVersion then return end
            row.landed = true; Paint(row, binding)
        end))
    end)
    rt.Selection = Protect(function(listId, itemId, data, selected)
        if listId ~= c.TileViewId or selected ~= true or type(data) ~= "table" then return end
        local row = rt.ByItem[itemId]
        if not row or not Current(row) or not row.landed or data.rowVersion ~= row.version
            or data.trackIndex ~= row.index or data.sessionGeneration ~= row.session then return end
        -- 回调内不写显隐；清除原生选择允许同一行再次点击。
        UI:ClearListViewSelection(listId)
        Request(row)
    end)
    local function Render()
        if not rt.Ready or not rt.State then return end
        for index, config in ipairs(c.Tracks) do
            local owned = math.floor(rt.State.trackMask / 2^(index-1)) % 2 == 1
            local label = rt.State.equippedTrack == index and "已装备" or (owned and "装备" or Decimal.Format(config.Price))
            local row = rt.Rows[index]
            if not row or row.label ~= label then
                if not row then
                    rt.RowVersion = rt.RowVersion + 1
                    row = { index = index, session = rt.Session, version = rt.RowVersion }; rt.Rows[index] = row
                end
                Unbind(row); row.binding = (row.binding or 0) + 1; row.landed = false
                -- rowVersion只标识档位/会话；Update可能保留创建时原生选择数据，显示变化不改变输入身份。
                row.label = label
                local data = { trackIndex = index, rowVersion = row.version, sessionGeneration = row.session }
                if row.itemId then UI:UpdateListViewItem(c.TileViewId, row.itemId, data)
                else
                    local added, itemId = pcall(function() return UI:AddListViewItem(c.TileViewId, data) end)
                    if not added or not itemId then
                        error("添加踪迹列表项失败 trackIndex=" .. index .. " listId=" .. tostring(c.TileViewId)
                            .. " templateId=" .. tostring(c.TemplateId) .. " addedCount=" .. rt.AddedCount
                            .. " sessionGeneration=" .. tostring(rt.Session) .. " callSucceeded=" .. tostring(added)
                            .. " returnValue=" .. tostring(itemId))
                    end
                    row.itemId = itemId; rt.AddedCount = rt.AddedCount + 1
                    rt.ByItem[row.itemId] = row
                end
            end
        end
    end
    rt.StateCallback = Protect(function(_, data)
        if type(data) ~= "table" or not Integer(data.version) or data.version <= rt.Version
            or not Integer(data.sessionGeneration) or data.sessionGeneration == 0 or data.sessionGeneration < rt.Session
            or not Integer(data.trackVersion) or not Integer(data.trackMask) or data.trackMask > 511
            or not Integer(data.equippedTrack) or data.equippedTrack > 9
            or (data.equippedTrack > 0 and math.floor(data.trackMask / 2^(data.equippedTrack-1)) % 2 ~= 1)
            or (data.trackMask > 0 and data.equippedTrack == 0) then return end
        if data.sessionGeneration == rt.Session and rt.State and data.trackVersion < rt.State.trackVersion then return end
        if data.sessionGeneration ~= rt.Session then Reset() end
        rt.Session, rt.Version, rt.State = data.sessionGeneration, data.version, data
        Render()
    end)
    rt.Result = Protect(function(_, data)
        local p = rt.Pending
        if type(data) ~= "table" or not p or data.requestId ~= p.requestId or data.sessionGeneration ~= p.sessionGeneration
            or data.trackIndex ~= p.trackIndex or data.trackVersion ~= p.trackVersion or data.sessionGeneration ~= rt.Session
            or type(data.success) ~= "boolean" then return end
        rt.Pending = nil
        if data.success then
            if data.reason == "track_purchased" then context.Services.PromptController:Show("购买成功，已装备踪迹" .. p.trackIndex)
            elseif data.reason == "track_equipped" then context.Services.PromptController:Show("已装备踪迹" .. p.trackIndex) end
        else
            if data.reason == "insufficient_balance" then context.Services.PromptController:Show("金币不足")
            elseif data.reason == "stale_track_state" then context.Services.PromptController:Show("踪迹状态已更新，请重新选择")
            else context.Services.PromptController:Show("当前无法购买或装备踪迹，请稍后操作") end
        end
    end)
    rt.Leave = Protect(function(id) if id == Character:GetLocalPlayerId() then self:Stop(context) end end)
    System:BindNotify(messages.TrackShopState, rt.StateCallback)
    System:BindNotify(messages.TrackShopResult, rt.Result)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, rt.Leave)
    local function InitStage(stage, fn)
        local ok, err = pcall(fn)
        if not ok then error("踪迹列表初始化失败 stage=" .. stage .. " listId=" .. tostring(c.TileViewId)
            .. " templateId=" .. tostring(c.TemplateId) .. " error=" .. tostring(err)) end
    end
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, Protect(function()
        InitStage("images", function()
            rt.Images = CustomProperty:GetCustomPropertyArray(System:GetScriptParentID(), c.ImagePropertyName, CustomProperty.PROPERTY_TYPE.Image)
            for index = 1, 9 do
                if not rt.Images or not rt.Images[index] or rt.Images[index] == 0 then error("踪迹图片组缺少图片: " .. index) end
            end
        end)
        rt.ListBound = true
        InitStage("bind_item_set", function() UI:SetListViewItemSetCall(c.TileViewId, rt.ItemSet) end)
        InitStage("bind_selection", function() UI:SetListViewItemSelectionChangeCall(c.TileViewId, rt.Selection) end)
        InitStage("clear_list", function() UI:ClearListView(c.TileViewId) end)
        InitStage("init_empty_list", function() UI:InitListView(c.TileViewId, {}) end)
        rt.ListInitialized = true
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            rt.Ready = true
            InitStage("render_cached_state", Render)
            InitStage("request_snapshot", function() System:SendToServer(messages.TrackShopSnapshotRequest, {}) end)
        end))
    end))
    rt.Cleanup = function()
        rt.Active = false; Reset(true)
        if rt.ListBound then
            UI:SetListViewItemSetCall(c.TileViewId, function() end)
            UI:SetListViewItemSelectionChangeCall(c.TileViewId, function() end)
        end
    end
end
function TrackShopController:Stop(context)
    local rt = context.Services.TrackShopController
    if not rt then return end
    rt.Cleanup()
    System:UnbindNotify(context.NetMsg.Messages.TrackShopState, rt.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.TrackShopResult, rt.Result)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, rt.Leave)
    context.Timers:RemoveOwner(self.Name); context.Services.TrackShopController = nil
end
return TrackShopController
