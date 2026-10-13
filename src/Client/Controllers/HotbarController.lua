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
        Rendering = false,
        RenderedItems = {},
        SnapshotCallback = nil,
        SelectionCallback = nil,
        ZoneCallback = nil,
        ItemSetCallback = nil,
        ItemSelectionCallback = nil,
        RenderVersion = 0,
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

    local function SetItem(listViewId, itemId, itemData)
        if listViewId ~= config.TileViewId or type(itemData) ~= "table"
            or itemData.renderVersion ~= runtime.RenderVersion then return end
        Log:PrintLog("[HotbarController] 进入瓦片装填回调",
            "listViewId:", listViewId,
            "listItemId:", tostring(itemId), "listItemIdType:", type(itemId),
            "businessItemId:", tostring(type(itemData) == "table" and itemData.itemId),
            "renderVersion:", runtime.RenderVersion)
        local imageUid = UI:GetListViewItemUID(listViewId, itemId, config.ItemImageId)
        local quantityUid = UI:GetListViewItemUID(listViewId, itemId, config.QuantityTextId)
        Log:PrintLog("[HotbarController] 瓦片子控件查询结果",
            "listViewId:", listViewId,
            "listItemId:", tostring(itemId), "listItemIdType:", type(itemId),
            "businessItemId:", tostring(type(itemData) == "table" and itemData.itemId),
            "imageUid:", tostring(imageUid), "quantityUid:", tostring(quantityUid),
            "renderVersion:", runtime.RenderVersion)
        if not imageUid or imageUid == "" or not quantityUid or quantityUid == "" then
            error("无法取得快捷栏瓦片子控件，itemId=" .. tostring(itemId))
        end

        UI:SetImage({ imageUid }, itemData.imageId, true)
        UI:SetText({ quantityUid }, config.QuantityPrefix .. tostring(itemData.count), false)
    end

    local function Render()
        if not IsActive() or not runtime.Ready then return end
        runtime.RenderVersion = runtime.RenderVersion + 1
        local renderVersion = runtime.RenderVersion
        runtime.Rendering = true
        runtime.RenderedItems = {}
        UI:ClearListView(config.TileViewId)
        local records = {}
        for index, item in ipairs(runtime.Items) do
            if type(item) ~= "table" or type(item.itemId) ~= "string"
                or (item.kind ~= "Chicken" and item.kind ~= "Egg")
                or not IsPositiveInteger(item.count)
                or not IsPositiveInteger(item.iconIndex) then
                error("库存快照项目格式无效，index=" .. tostring(index))
            end
            records[index] = {
                itemId = item.itemId,
                kind = item.kind,
                count = item.count,
                imageId = ResolveImage(item),
                renderVersion = renderVersion,
            }
        end
        local listItemIds = UI:InitListView(config.TileViewId, records) or {}
        for index, listItemId in ipairs(listItemIds) do
            runtime.RenderedItems[listItemId] = records[index].itemId
        end
        context.Timers:AddFrame(
            HotbarController.Name,
            GameConfig.Runtime.EngineOperationDelayFrames,
            function()
                if not IsActive() or runtime.RenderVersion ~= renderVersion then return end
                for index, listItemId in ipairs(listItemIds) do
                    local itemData = records[index]
                    local borderUid = UI:GetListViewItemUID(
                        config.TileViewId,
                        listItemId,
                        config.SelectedBorderId
                    )
                    if not borderUid then
                        error("无法取得快捷栏选中框UID，itemIndex=" .. tostring(index))
                    end
                    UI:SetVisibility(
                        { borderUid },
                        itemData.itemId == runtime.SelectedItemId
                    )
                end
                -- 等装填落地后复位原生选择，清理刷新期间的选择事件。
                -- 业务选中框仍由服务端状态控制。
                UI:ClearListViewSelection(config.TileViewId)
                runtime.Rendering = false
            end
        )
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
            if runtime.Ready then SetVisible(runtime.Visible) end
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
                    Log:PrintLog("[HotbarController] 收到原生瓦片选择变化",
                        "listViewId:", tostring(listViewId),
                        "listItemId:", tostring(itemId), "listItemIdType:", type(itemId),
                        "itemDataType:", type(itemData),
                        "businessItemId:", tostring(type(itemData) == "table" and itemData.itemId),
                        "select:", tostring(select), "selectType:", type(select),
                        "ready:", tostring(runtime.Ready), "visible:", tostring(runtime.Visible),
                        "selectedItemId:", tostring(runtime.SelectedItemId),
                        "renderVersion:", runtime.RenderVersion)
                    if select ~= true then return end
                    if listViewId ~= config.TileViewId or not runtime.Ready
                        or not runtime.Visible or runtime.Rendering then return end
                    if type(itemData) ~= "table"
                        or itemData.renderVersion ~= runtime.RenderVersion
                        or type(itemData.itemId) ~= "string" or itemData.itemId == ""
                        or runtime.RenderedItems[itemId] ~= itemData.itemId then
                        Log:PrintLog("[HotbarController] 忽略旧列表或无效瓦片点击",
                            "listItemId:", tostring(itemId),
                            "renderVersion:", runtime.RenderVersion)
                        return
                    end
                    local businessItemId = itemData.itemId
                    -- 先复位输入状态；select=false 只记录，不发送第二次请求。
                    UI:ClearListViewSelection(listViewId)
                    if not IsActive() then return end
                    System:SendToServer(context.NetMsg.Messages.HotbarToggleSelection, {
                        itemId = businessItemId,
                    })
                    Log:PrintLog("[HotbarController] 快捷栏选择请求发送调用已返回",
                        "messageId:", context.NetMsg.Messages.HotbarToggleSelection,
                        "businessItemId:", businessItemId,
                        "listItemId:", itemId,
                        "renderVersion:", runtime.RenderVersion)
                end)
            end
            UI:SetListViewItemSelectionChangeCall(config.TileViewId, runtime.ItemSelectionCallback)
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
    runtime.RenderVersion = runtime.RenderVersion + 1
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
    context.Services.HotbarController = nil
end

return HotbarController
