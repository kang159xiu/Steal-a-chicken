local GameConfig = require "Common.Config.GameConfig"

local EggCollectionListController = { Name = "EggCollectionListController", FeatureFlag = "EggCollection", Dependencies = { "PromptController" } }
local function Integer(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == math.floor(value)
end
local function Time(value)
    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end
local function NonnegativeInteger(value)
    return Time(value) and value == math.floor(value)
end
-- 与场景蛋EggGrowthController的MoneyText/Progress保持相同取整及单位。
local units = { { 1e21, "Sx" }, { 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" },
    { 1e9, "B" }, { 1e6, "M" }, { 1e4, "w" }, { 1e3, "k" } }
local function MoneyText(value)
    for _, unit in ipairs(units) do
        if value >= unit[1] then
            local text = string.format("%.2f", math.floor(value / unit[1] * 100 + 0.5) / 100)
            return text:gsub("%.00$", "") .. unit[2]
        end
    end
    return string.format("%.0f", value)
end
local function CurrentPrice(data, now)
    local duration = data.hatchDeadlineMs - data.spawnedAtMs
    if duration <= 0 or now >= data.hatchDeadlineMs then return data.finalSellPrice, true end
    local elapsed = math.max(0, math.min(duration, now - data.spawnedAtMs))
    local deltaUnits = data.finalScaleUnits - GameConfig.EggGrowth.InitialScaleUnits
    return data.baseSellPrice
        + math.floor((data.baseSellPrice * deltaUnits * elapsed + 50 * duration) / (100 * duration)), false
end
function EggCollectionListController:ValidateConfig(context)
    local c = GameConfig.EggCollectionList
    if type(c) ~= "table" or c.TileViewId ~= 100218 or c.TemplateId ~= 100226 or c.ImageId ~= 100222
        or c.ProgressId ~= 100223 or c.StatusTextId ~= 100225 or c.PriceTextId ~= 103143 or c.CollectAllButtonId ~= 100227
        or c.CountTextId ~= 100406
        or c.ProgressRefreshSeconds ~= 0.2 then return false, { "EggCollectionList 编辑器ID或进度刷新配置不符合约定" } end
    return true
end

function EggCollectionListController:Start(context)
    if context.Side ~= "Client" then return end
    local config, messages = GameConfig.EggCollectionList, context.NetMsg.Messages
    local runtime = { Active = true, Ready = false, Version = 0, RowVersion = 0, RenderVersion = 0,
        Rows = {}, ByItem = {}, ProgressRows = {}, ProgressErrors = {}, PriceRows = {}, PriceErrors = {}, Pending = {}, RequestId = 0,
        Images = {}, Refreshing = false }
    context.Services.EggCollectionListController = runtime
    local function Active() return runtime.Active and context.Services.EggCollectionListController == runtime end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Current(row)
        return Active() and runtime.Ready and runtime.Rows[row.data.eggId] == row
            and runtime.ByItem[row.itemId] == row and row.homeVersion == runtime.HomeVersion
    end
    local function Percent(data, now)
        if data.mature or data.hatchDeadlineMs <= data.spawnedAtMs or now >= data.hatchDeadlineMs then return 100 end
        return math.max(0, math.min(100, (now - data.spawnedAtMs) * 100 / (data.hatchDeadlineMs - data.spawnedAtMs)))
    end
    local function ProgressFailed(row, err)
        row.progressDisabled = true
        runtime.ProgressRows[row.data.eggId] = nil
        if runtime.ProgressErrors[row.data.eggId] then return end
        runtime.ProgressErrors[row.data.eggId] = true
        Log:PrintError("[EggCollectionList] 本行进度不可用", "eggId:", row.data.eggId, "error:", tostring(err))
    end
    local function Progress(row, now, initialize)
        if not Current(row) or not row.landed or row.progressDisabled then return end
        local percentage = Percent(row.data, now)
        local ok, err = pcall(function()
            if not row.progressUid or row.progressUid == "" then error("无法取得进度条UID") end
            -- 官方返回的字符串UID原样传入，不转换、不构造替代UID。
            if initialize then UI:SetProgressMaxValue({ row.progressUid }, 100) end
            UI:SetProgressCurrentValue({ row.progressUid }, percentage)
        end)
        if not ok then ProgressFailed(row, err); return end
        if percentage >= 100 then runtime.ProgressRows[row.data.eggId] = nil
        else runtime.ProgressRows[row.data.eggId] = row end
    end
    local function Price(row, now, initialize)
        if not Current(row) or not row.landed or row.priceDisabled then return end
        local price, finished = CurrentPrice(row.data, now)
        local text = MoneyText(price)
        local ok, err = pcall(function()
            if initialize then
                row.priceUid = UI:GetListViewItemUID(config.TileViewId, row.itemId, config.PriceTextId)
            end
            if not row.priceUid or row.priceUid == "" then error("无法取得价格文字UID") end
            if initialize or row.priceText ~= text then UI:SetText({ row.priceUid }, text, false) end
        end)
        if not ok then
            row.priceDisabled = true
            runtime.PriceRows[row.data.eggId] = nil
            if not runtime.PriceErrors[row.data.eggId] then
                runtime.PriceErrors[row.data.eggId] = true
                Log:PrintError("[EggCollectionList] 本行价格不可用", "eggId:", row.data.eggId, "error:", tostring(err))
            end
            return
        end
        row.priceText = text
        if finished then runtime.PriceRows[row.data.eggId] = nil
        else runtime.PriceRows[row.data.eggId] = row end
    end
    local function Paint(row)
        if not Current(row) or not row.landed then return end
        local now = MiscService:GetServerTimestamp()
        local imageUid = UI:GetListViewItemUID(config.TileViewId, row.itemId, config.ImageId)
        local textUid = UI:GetListViewItemUID(config.TileViewId, row.itemId, config.StatusTextId)
        if not imageUid or imageUid == "" or not textUid or textUid == "" then
            error("无法取得蛋列表图片或文字UID，eggId=" .. tostring(row.data.eggId))
        end
        UI:SetImage({ imageUid }, row.data.imageId, true)
        UI:SetText({ textUid }, Percent(row.data, now) >= 100 and "收集" or "孵化中", false)
        if not row.progressDisabled then
            local ok, uid = pcall(function()
                return UI:GetListViewItemUID(config.TileViewId, row.itemId, config.ProgressId)
            end)
            if ok then row.progressUid = uid else ProgressFailed(row, uid) end
            Progress(row, now, true)
        end
        Price(row, now, true)
    end
    runtime.ItemSetCallback = Protect(function(listId, itemId, data)
        if listId ~= config.TileViewId or type(data) ~= "table" then
            return end
        local row = runtime.Rows[data.eggId]
        if not row or row.data.eggId ~= data.eggId or data.rowVersion ~= row.version
            or row.homeVersion ~= runtime.HomeVersion
            or (row.itemId ~= nil and (row.itemId ~= itemId or runtime.ByItem[itemId] ~= row))
            or (runtime.ByItem[itemId] ~= nil and runtime.ByItem[itemId] ~= row) then
            return end
        if row.itemId and row.itemId ~= itemId then runtime.ByItem[row.itemId] = nil end
        row.itemId = itemId
        runtime.ByItem[itemId] = row
        row.binding = (row.binding or 0) + 1
        local binding = row.binding
        row.landed = false
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            if not Current(row) or row.binding ~= binding or row.data.eggId ~= data.eggId or row.version ~= data.rowVersion then
                return end
            row.landed = true
            Paint(row)
        end))
    end)
    local function ResetRows()
        runtime.RenderVersion = runtime.RenderVersion + 1
        runtime.Refreshing = false
        runtime.Rows, runtime.ByItem, runtime.ProgressRows, runtime.PriceRows, runtime.Pending = {}, {}, {}, {}, {}
        if runtime.Ready then UI:ClearListView(config.TileViewId) end
    end
    local function Render()
        if not runtime.Ready or not runtime.Snapshot then
            return end

        UI:SetText({ config.CountTextId }, tostring(runtime.Snapshot.eggCount) .. "/"
            .. tostring(runtime.Snapshot.eggCapacity), false)
        local changed = false
        local function Changing()
            if changed then return end
            changed = true
            runtime.RenderVersion = runtime.RenderVersion + 1
            runtime.Refreshing = true
        end
        local present = {}
        for _, egg in ipairs(runtime.Snapshot.eggs) do present[egg.eggId] = true end
        for eggId, row in pairs(runtime.Rows) do
            if not present[eggId] then
                runtime.Rows[eggId], runtime.ByItem[row.itemId], runtime.ProgressRows[eggId] = nil, nil, nil
                runtime.PriceRows[eggId] = nil
                Changing()
                UI:RemoveListViewItem(config.TileViewId, row.itemId)
            end
        end
        -- eggId由服务端单调分配；新行按eggId升序追加，旧行只做必要更新。
        for _, egg in ipairs(runtime.Snapshot.eggs) do
            local row = runtime.Rows[egg.eggId]
            local prior = row and row.data
            if not prior or prior.chickenTypeId ~= egg.chickenTypeId or prior.spawnedAtMs ~= egg.spawnedAtMs
                or prior.hatchDeadlineMs ~= egg.hatchDeadlineMs or prior.mature ~= egg.mature
                or prior.baseSellPrice ~= egg.baseSellPrice or prior.finalScaleUnits ~= egg.finalScaleUnits
                or prior.finalSellPrice ~= egg.finalSellPrice then
                local chicken = GameConfig.ChickenTypes[egg.chickenTypeId]
                local image = chicken and runtime.Images[chicken.ChickenIconIndex]
                if not image or image == 0 then error("鸡图标配置缺失，eggId=" .. tostring(egg.eggId)) end
                -- 输入身份仅在新建行时分配；成熟刷新只替换显示快照。
                if not row then
                    runtime.RowVersion = runtime.RowVersion + 1
                    row = { homeVersion = runtime.HomeVersion, version = runtime.RowVersion }
                    runtime.Rows[egg.eggId] = row
                end
                local data = { eggId = egg.eggId, chickenTypeId = egg.chickenTypeId, spawnedAtMs = egg.spawnedAtMs,
                    hatchDeadlineMs = egg.hatchDeadlineMs, mature = egg.mature, imageId = image, rowVersion = row.version,
                    baseSellPrice = egg.baseSellPrice, finalScaleUnits = egg.finalScaleUnits, finalSellPrice = egg.finalSellPrice }
                Changing()
                row.data, row.landed = data, false
                if row.itemId then
                    UI:UpdateListViewItem(config.TileViewId, row.itemId, data)
                else
                    row.itemId = UI:AddListViewItem(config.TileViewId, data)
                    if not row.itemId then error("添加蛋列表项未返回ID，eggId=" .. tostring(egg.eggId)) end
                    runtime.ByItem[row.itemId] = row
                end
            end
        end
        local renderVersion = runtime.RenderVersion

        if not changed then return end
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            if runtime.RenderVersion ~= renderVersion then return end
            UI:ClearListViewSelection(config.TileViewId)
            runtime.Refreshing = false
        end))
    end
    local function Request(action, eggId)
        if not runtime.Ready or runtime.Refreshing or not runtime.HomeId then return end
        runtime.RequestId = runtime.RequestId + 1
        local request = { homeId = runtime.HomeId, homeVersion = runtime.HomeVersion,
            action = action, eggId = eggId, requestId = runtime.RequestId }
        runtime.Pending[request.requestId] = request

        System:SendToServer(messages.EggCollectionListAction, request)
    end
    runtime.SelectionCallback = Protect(function(listId, itemId, data, selected)
        if selected ~= true then
            return end

        if listId ~= config.TileViewId or not runtime.Ready or runtime.Refreshing or type(data) ~= "table" then return end
        local row = runtime.ByItem[itemId]
        if not row or not Current(row) or not row.landed or row.data.eggId ~= data.eggId or row.version ~= data.rowVersion then return end
        local version, eggId = row.version, row.data.eggId
        UI:ClearListViewSelection(listId)
        if Current(row) and row.version == version then Request("single", eggId)
        end
    end)
    runtime.AllCallback = Protect(function() Request("all") end)
    runtime.StateCallback = Protect(function(_, message)
        if type(message) ~= "table" or not Integer(message.version) or message.version <= runtime.Version
            or not Integer(message.homeVersion) or (message.homeId ~= nil and not Integer(message.homeId))
            or not NonnegativeInteger(message.eggCount) or not Integer(message.eggCapacity)
            or message.eggCount > message.eggCapacity
            or type(message.eggs) ~= "table" then return end
        local seen, previous = {}, 0
        for _, egg in ipairs(message.eggs) do
            if type(egg) ~= "table" or not Integer(egg.eggId) or seen[egg.eggId] or egg.eggId <= previous
                or type(egg.chickenTypeId) ~= "string" or not GameConfig.ChickenTypes[egg.chickenTypeId]
                or not Time(egg.spawnedAtMs) or not Time(egg.hatchDeadlineMs) or egg.hatchDeadlineMs < egg.spawnedAtMs
                or not NonnegativeInteger(egg.baseSellPrice) or not NonnegativeInteger(egg.finalSellPrice)
                or not Integer(egg.finalScaleUnits) or egg.finalScaleUnits < GameConfig.EggGrowth.MinFinalScaleUnits
                or egg.finalScaleUnits > GameConfig.EggGrowth.MaxFinalScaleUnits
                or type(egg.mature) ~= "boolean" or not message.homeId then return end
            seen[egg.eggId], previous = true, egg.eggId
        end
        if runtime.HomeVersion ~= message.homeVersion or runtime.HomeId ~= message.homeId then ResetRows() end
        runtime.Version, runtime.HomeId, runtime.HomeVersion = message.version, message.homeId, message.homeVersion
        runtime.Snapshot = message
        Render()
    end)
    runtime.ResultCallback = Protect(function(_, message)
        if type(message) ~= "table" then return end

        local request = runtime.Pending[message.requestId]
        if not request or request.homeId ~= message.homeId or request.homeVersion ~= message.homeVersion
            or request.action ~= message.action or request.eggId ~= message.eggId
            or runtime.HomeVersion ~= message.homeVersion or type(message.success) ~= "boolean" then return end

        runtime.Pending[message.requestId] = nil
        if not message.success then
            local full = message.reason == "inventory_capacity_full"
            for _, result in ipairs(message.results or {}) do
                if result.reason == "inventory_capacity_full" then full = true; break end
            end
            if full then context.Services.PromptController:Show("鸡蛋库存已满，请先出售")
            elseif message.reason == "egg_not_mature" then context.Services.PromptController:Show("鸡蛋还未孵化完成")
            else Log:PrintLog("[EggCollectionList] 收取失败", "requestId:", message.requestId, "reason:", tostring(message.reason)) end
        end
    end)
    runtime.LeaveCallback = Protect(function(playerId)
        if playerId ~= Character:GetLocalPlayerId() then return end
        self:Stop(context)
    end)
    System:BindNotify(messages.EggCollectionListState, runtime.StateCallback)
    System:BindNotify(messages.EggCollectionListResult, runtime.ResultCallback)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, Protect(function()
        runtime.Images = CustomProperty:GetCustomPropertyArray(System:GetScriptParentID(),
            GameConfig.ImageGroups.ChickenPropertyName, CustomProperty.PROPERTY_TYPE.Image) or {}
        UI:SetListViewItemSetCall(config.TileViewId, runtime.ItemSetCallback)
        UI:SetListViewItemSelectionChangeCall(config.TileViewId, runtime.SelectionCallback)
        UI:RegisterClicked(config.CollectAllButtonId, runtime.AllCallback)
        runtime.Ready = true
        UI:ClearListView(config.TileViewId)
        UI:InitListView(config.TileViewId, {})
        Render()
        System:SendToServer(messages.EggCollectionListSnapshotRequest, {})
    end))
    context.Timers:AddLoopTimer(self.Name, config.ProgressRefreshSeconds, Protect(function()
        if not runtime.Ready then return end
        local now = MiscService:GetServerTimestamp()
        for _, row in pairs(runtime.ProgressRows) do Progress(row, now, false) end
        for _, row in pairs(runtime.PriceRows) do Price(row, now, false) end
    end))
    runtime.Cleanup = function()
        runtime.Active = false
        runtime.RenderVersion = runtime.RenderVersion + 1
        runtime.Rows, runtime.ByItem, runtime.ProgressRows, runtime.PriceRows, runtime.Pending = {}, {}, {}, {}, {}
        if runtime.Ready then
            UI:SetListViewItemSelectionChangeCall(config.TileViewId, function() end)
            UI:SetListViewItemSetCall(config.TileViewId, function() end)
            UI:UnRegisterClicked(config.CollectAllButtonId, runtime.AllCallback)
            UI:ClearListView(config.TileViewId)
        end
    end
end

function EggCollectionListController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.EggCollectionListController
    if not runtime then return end
    runtime.Cleanup()
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionListState, runtime.StateCallback)
    System:UnbindNotify(context.NetMsg.Messages.EggCollectionListResult, runtime.ResultCallback)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.EggCollectionListController = nil
end

return EggCollectionListController
