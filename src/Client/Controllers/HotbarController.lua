local GameConfig = require "Common.Config.GameConfig"

local HotbarController = {
    Name = "HotbarController",
    FeatureFlag = "Hotbar",
    Dependencies = {},
}

local function IsPositiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

function HotbarController:ValidateConfig(context)
    if context.Side ~= "Client" then return true end
    local errors = {}
    local config = GameConfig.Hotbar
    for _, field in ipairs({
        "UiGroupId", "TileViewId", "TileTemplateId", "ItemButtonId",
        "ItemImageId", "SelectedBorderId", "QuantityTextId",
    }) do
        if not IsPositiveInteger(config[field]) then
            errors[#errors + 1] = "Hotbar." .. field .. " 必须是正整数"
        end
    end
    return #errors == 0, errors
end

function HotbarController:Start(context)
    if context.Side ~= "Client" then return end

    local config = GameConfig.Hotbar
    local runtime = {
        Ready = false,
        Items = {},
        SelectedItemId = nil,
        Visible = false,
        ChickenImages = {},
        EggImages = {},
        Active = true,
        Rows = {},
        InputVersion = 0,
        RenderedItems = {},
        SnapshotCallback = nil,
        SelectionCallback = nil,
        ZoneCallback = nil,
        ItemSetCallback = nil,
        ItemSelectionCallback = nil,
    }
    context.Services.HotbarController = runtime

    local function IsActive()
        return runtime.Active and context.Services.HotbarController == runtime
    end

    local function Run(actionName, callback)
        if not IsActive() then return end
        local ok, errorMessage = xpcall(callback, Traceback)
        if not ok then
            context.Manager:FailModule(HotbarController.Name,
                actionName .. ": " .. tostring(errorMessage))
        end
    end

    local function SetVisible(visible)
        runtime.Visible = visible == true
        UI:SetVisibility({ config.UiGroupId }, runtime.Visible)
    end

    local function ResolveImage(item)
        local images = item.kind == "Chicken" and runtime.ChickenImages or runtime.EggImages
        local imageId = images[item.iconIndex]
        if imageId == nil or imageId == 0 then
            error("快捷栏物品图片配置缺失，itemId=" .. tostring(item.itemId)
                .. " kind=" .. tostring(item.kind)
                .. " iconIndex=" .. tostring(item.iconIndex))
        end
        return imageId
    end

    local function Current(row)
        return IsActive() and runtime.Ready and runtime.Rows[row.index] == row
            and runtime.RenderedItems[row.itemId] == row
    end

    local function Border(row)
        if not Current(row) or not row.landed then return end
        local selected = row.data.itemId == runtime.SelectedItemId
        if row.selected == selected then return end
        local uid = UI:GetListViewItemUID(config.TileViewId, row.itemId, config.SelectedBorderId)
        if not uid or uid == "" then error("无法取得快捷栏选中框UID") end
        UI:SetVisibility({ uid }, selected)
        row.selected = selected
    end

    local function UpdateBorders()
        for _, row in ipairs(runtime.Rows) do Border(row) end
    end

    local function SetItem(listViewId, itemId, itemData)
        if listViewId ~= config.TileViewId or type(itemData) ~= "table" then
            return end
        local row = runtime.Rows[itemData.position]

        if not row or row.data.itemId ~= itemData.itemId or row.version ~= itemData.inputVersion
            or (row.itemId ~= nil and (row.itemId ~= itemId or runtime.RenderedItems[itemId] ~= row))
            or (runtime.RenderedItems[itemId] ~= nil and runtime.RenderedItems[itemId] ~= row) then
            return end
        row.itemId = itemId
        runtime.RenderedItems[itemId] = row
        row.binding = (row.binding or 0) + 1
        local binding, version, businessItemId = row.binding, row.version, row.data.itemId
        row.landed, row.selected = false, nil
        context.Timers:AddFrame(HotbarController.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            Run("快捷栏瓦片落地", function()
                if not Current(row) or row.binding ~= binding or row.version ~= version
                    or row.data.itemId ~= businessItemId then
                    return end
                local imageUid = UI:GetListViewItemUID(listViewId, itemId, config.ItemImageId)
                local quantityUid = UI:GetListViewItemUID(listViewId, itemId, config.QuantityTextId)
                if not imageUid or imageUid == "" or not quantityUid or quantityUid == "" then
                    error("无法取得快捷栏瓦片子控件，itemId=" .. tostring(itemId))
                end
                -- 旧显示数据副本仍可装填同一输入身份；始终绘制最新快照。
                UI:SetImage({ imageUid }, row.data.imageId, true)
                UI:SetText({ quantityUid }, config.QuantityPrefix .. tostring(row.data.count), false)
                row.landed = true

                Border(row)
                UI:ClearListViewSelection(config.TileViewId)
            end)
        end)
    end

    local function Render()
        if not IsActive() or not runtime.Ready then return end
        local records = {}
        for index, item in ipairs(runtime.Items) do
            if type(item) ~= "table" or type(item.itemId) ~= "string"
                or (item.kind ~= "Chicken" and item.kind ~= "Egg")
                or not IsPositiveInteger(item.count) or not IsPositiveInteger(item.iconIndex) then
                error("库存快照项目格式无效，index=" .. tostring(index))
            end
            records[index] = { itemId = item.itemId, kind = item.kind,
                count = item.count, imageId = ResolveImage(item), position = index }
        end
        -- Update后原生点击可能仍携带创建时的数据。物品身份变化时重建该位置及尾部，
        -- 不把同一个物理列表项改绑给另一物品；保持鸡前蛋后与前部未变行。
        local removeFrom = #records + 1
        for index = 1, math.min(#runtime.Rows, #records) do
            if runtime.Rows[index].data.itemId ~= records[index].itemId then
                removeFrom = index
                break
            end
        end
        for index = #runtime.Rows, removeFrom, -1 do
            local row = runtime.Rows[index]
            runtime.Rows[index], runtime.RenderedItems[row.itemId] = nil, nil

            UI:RemoveListViewItem(config.TileViewId, row.itemId)
        end
        for index, data in ipairs(records) do
            local row = runtime.Rows[index]
            local prior = row and row.data
            if not prior or prior.kind ~= data.kind
                or prior.count ~= data.count or prior.imageId ~= data.imageId then
                local listItemId = row and row.itemId
                if not row then
                    runtime.InputVersion = runtime.InputVersion + 1
                    row = { index = index, version = runtime.InputVersion, itemId = listItemId }
                    runtime.Rows[index] = row
                end

                data.inputVersion = row.version
                row.binding = (row.binding or 0) + 1
                row.data, row.landed = data, false
                if listItemId then
                    UI:UpdateListViewItem(config.TileViewId, listItemId, data)
                else
                    row.itemId = UI:AddListViewItem(config.TileViewId, data)
                    if not row.itemId then error("添加快捷栏项未返回ID") end
                    runtime.RenderedItems[row.itemId] = row
                end
            end
        end
        UpdateBorders()
        SetVisible(runtime.Visible)
    end

    runtime.ItemSetCallback = function(listViewId, itemId, itemData)
        Run("设置快捷栏瓦片", function()
            SetItem(listViewId, itemId, itemData)
        end)
    end

    runtime.SnapshotCallback = function(_, message)
        Run("库存快照处理", function()
            if type(message) ~= "table" or type(message.items) ~= "table"
                or type(message.visible) ~= "boolean" then
                error("库存快照格式无效")
            end
            runtime.Items = message.items
            runtime.SelectedItemId = message.selectedItemId
            runtime.Visible = message.visible
            if runtime.Ready then Render() end
        end)
    end

    runtime.SelectionCallback = function(_, message)
        Run("快捷栏选择状态处理", function()
            if type(message) ~= "table" or type(message.visible) ~= "boolean" then
                error("快捷栏选择状态格式无效")
            end
            runtime.SelectedItemId = message.selectedItemId
            runtime.Visible = message.visible
            if runtime.Ready then UpdateBorders(); SetVisible(runtime.Visible) end
        end)
    end

    runtime.ZoneCallback = function(_, message)
        Run("区域状态控制快捷栏显隐", function()
            if type(message) ~= "table" or type(message.inStolenArea) ~= "boolean" then
                error("区域状态消息格式无效")
            end
            SetVisible(not message.inStolenArea)
        end)
    end

    UI:SetVisibility({ config.UiGroupId }, false)
    System:BindNotify(context.NetMsg.Messages.InventorySnapshot, runtime.SnapshotCallback)
    System:BindNotify(context.NetMsg.Messages.HotbarSelectionState, runtime.SelectionCallback)
    System:BindNotify(context.NetMsg.Messages.ZoneState, runtime.ZoneCallback)

    context.Timers:AddTimer(
        HotbarController.Name,
        GameConfig.Runtime.ClientSnapshotRequestDelaySeconds,
        function()
            if not IsActive() then return end
            local scriptElementId = System:GetScriptParentID()
            if not IsPositiveInteger(scriptElementId) then
                error("System:GetScriptParentID() 未返回有效编程元件ID")
            end
            runtime.ChickenImages = CustomProperty:GetCustomPropertyArray(
                scriptElementId,
                GameConfig.ImageGroups.ChickenPropertyName,
                CustomProperty.PROPERTY_TYPE.Image
            ) or {}
            runtime.EggImages = CustomProperty:GetCustomPropertyArray(
                scriptElementId,
                GameConfig.ImageGroups.EggPropertyName,
                CustomProperty.PROPERTY_TYPE.Image
            ) or {}
            for typeId, chickenConfig in pairs(GameConfig.ChickenTypes) do
                if chickenConfig.Enabled
                    and (runtime.ChickenImages[chickenConfig.ChickenIconIndex] == nil
                        or runtime.ChickenImages[chickenConfig.ChickenIconIndex] == 0) then
                    error("鸡图标数组缺少启用配置需要的索引，typeId=" .. tostring(typeId)
                        .. " index=" .. tostring(chickenConfig.ChickenIconIndex))
                end
                local eggConfig = chickenConfig.Egg
                if eggConfig and eggConfig.Enabled
                    and (runtime.EggImages[eggConfig.IconIndex] == nil
                        or runtime.EggImages[eggConfig.IconIndex] == 0) then
                    error("蛋图标数组缺少启用配置需要的索引，eggType="
                        .. tostring(eggConfig.EggTypeId))
                end
            end
            UI:SetListViewItemSetCall(config.TileViewId, runtime.ItemSetCallback)
            -- 沿用已验证的瓦片输入：选中时发送切换请求，清除原生选择以支持再次点击。
            runtime.ItemSelectionCallback = function(listViewId, itemId, itemData, select)
                if context.Services.HotbarController ~= runtime
                    or not runtime.ItemSelectionCallback then return end
                Run("快捷栏瓦片点击", function()
                    if select ~= true then return end

                    if listViewId ~= config.TileViewId or not runtime.Ready
                        or not runtime.Visible then
                        return end
                    if type(itemData) ~= "table" then
                        return end
                    local row = runtime.RenderedItems[itemId]
                    if not row or not Current(row) or not row.landed
                        or row.data.itemId ~= itemData.itemId or row.version ~= itemData.inputVersion
                        or row.index ~= itemData.position then
                        return end
                    local businessItemId, version, binding = row.data.itemId, row.version, row.binding
                    -- 先复位输入状态；select=false 直接返回，不发送第二次请求。
                    UI:ClearListViewSelection(listViewId)
                    if not Current(row) or not row.landed or row.version ~= version
                        or row.binding ~= binding or row.data.itemId ~= businessItemId then
                        return end

                    System:SendToServer(context.NetMsg.Messages.HotbarToggleSelection, {
                        itemId = businessItemId,
                    })
                end)
            end
            UI:SetListViewItemSelectionChangeCall(config.TileViewId, runtime.ItemSelectionCallback)
            UI:InitListView(config.TileViewId, {})
            runtime.Ready = true
            Render()
            System:SendToServer(context.NetMsg.Messages.InventorySnapshotRequest, {})
            Log:PrintLog("[HotbarController] 正式快捷栏客户端已就绪",
                "tileViewId:", config.TileViewId,
                "scriptElementId:", scriptElementId,
                "chickenImageCount:", #runtime.ChickenImages,
                "eggImageCount:", #runtime.EggImages)
        end
    )
end

function HotbarController:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services.HotbarController
    if not runtime then return end
    -- 先失效运行实例和装填版本，阻断清理期间及迟到的回调。
    runtime.Active = false
    runtime.Ready = false
    runtime.Rows = {}
    runtime.RenderedItems = {}
    runtime.ItemSelectionCallback = nil
    runtime.ItemSetCallback = nil
    UI:SetListViewItemSelectionChangeCall(GameConfig.Hotbar.TileViewId, function() end)
    UI:ClearListView(GameConfig.Hotbar.TileViewId)
    UI:SetListViewItemSetCall(GameConfig.Hotbar.TileViewId, function() end)
    UI:SetVisibility({ GameConfig.Hotbar.UiGroupId }, false)
    if runtime.SnapshotCallback then
        System:UnbindNotify(context.NetMsg.Messages.InventorySnapshot, runtime.SnapshotCallback)
    end
    if runtime.SelectionCallback then
        System:UnbindNotify(context.NetMsg.Messages.HotbarSelectionState, runtime.SelectionCallback)
    end
    if runtime.ZoneCallback then
        System:UnbindNotify(context.NetMsg.Messages.ZoneState, runtime.ZoneCallback)
    end
    context.Timers:RemoveOwner(HotbarController.Name)
    context.Services.HotbarController = nil
end

return HotbarController
