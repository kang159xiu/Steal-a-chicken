local GameConfig = require "Common.Config.GameConfig"
local EggModelText = require "Common.EggModelText"
local SafeCall = require "Common.Core.SafeCall"
local AnimalEquipmentController = { Name = "AnimalEquipmentController", FeatureFlag = "Placement",
    Dependencies = { "PromptController" } }

function AnimalEquipmentController:Start(context)
    if context.Side ~= "Client" then return end
    local c, messages = GameConfig.AnimalEquipment, context.NetMsg.Messages
    local rt = { Active = true, Ready = false, Version = 0, RowVersion = 0,
        Rows = {}, ByListId = {}, Images = {}, RequestId = 0 }
    context.Services.AnimalEquipmentController = rt
    local function Active() return rt.Active and context.Services.AnimalEquipmentController == rt end
    local function Protect(callback)
        return SafeCall.Protect(Active, function(err) context.Manager:FailModule(self.Name, tostring(err)) end, callback)
    end
    local function Current(row, data)
        return Active() and rt.Ready and type(data) == "table" and rt.Rows[row.index] == row
            and row.data.rowVersion == data.rowVersion and row.data.animalId == data.animalId
    end
    rt.ItemSet = Protect(function(listId, listItemId, data)
        if listId ~= c.TileViewId or type(data) ~= "table" then
            return
        end
        local row = rt.Rows[data.index]
        if not row or not Current(row, data) or (row.listItemId and row.listItemId ~= listItemId) then
            return
        end
        row.listItemId = listItemId
        rt.ByListId[listItemId] = row
        row.landed = false
        row.binding = (row.binding or 0) + 1
        local binding = row.binding
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
            if not Current(row, data) or row.binding ~= binding then
                return
            end
            local image = UI:GetListViewItemUID(c.TileViewId, listItemId, c.ImageId)
            local price = UI:GetListViewItemUID(c.TileViewId, listItemId, c.PriceTextId)
            local status = UI:GetListViewItemUID(c.TileViewId, listItemId, c.StatusTextId)
            UI:SetImage({ image }, rt.Images[GameConfig.ChickenTypes[data.typeId].ChickenIconIndex], true)
            UI:SetText({ price }, EggModelText.FormatPrice(data.finalSellPrice), false)
            UI:SetText({ status }, data.equipped and "卸下" or "装备", false)
            row.landed = true
        end))
    end)
    local function Render()
        if not rt.Ready or not rt.State then return end
        if rt.HomeId ~= rt.State.homeId then
            rt.Rows, rt.ByListId = {}, {}
            UI:ClearListView(c.TileViewId)
            rt.HomeId = rt.State.homeId
        end
        local items = rt.State.items
        -- 瓦片API无移动接口：按排序后的位置复用行，仅更新变化的位置。
        for i = #rt.Rows, #items + 1, -1 do
            local row = rt.Rows[i]
            rt.Rows[i], rt.ByListId[row.listItemId] = nil, nil
            UI:RemoveListViewItem(c.TileViewId, row.listItemId)
        end
        for i, item in ipairs(items) do
            local row = rt.Rows[i]
            local old = row and row.data
            if not old or old.animalId ~= item.itemId or old.typeId ~= item.typeId
                or old.finalSellPrice ~= item.finalSellPrice or old.equipped ~= item.equipped then
                if not row then row = { index = i }; rt.Rows[i] = row end
                rt.RowVersion = rt.RowVersion + 1
                local data = { index = i, rowVersion = rt.RowVersion, animalId = item.itemId, typeId = item.typeId,
                    finalSellPrice = item.finalSellPrice, equipped = item.equipped }
                row.data, row.landed = data, false
                if row.listItemId then UI:UpdateListViewItem(c.TileViewId, row.listItemId, data)
                else
                    row.listItemId = UI:AddListViewItem(c.TileViewId, data)
                    rt.ByListId[row.listItemId] = row
                end
            end
        end
    end
    local function Request(action, itemId)
        if not rt.Ready or not rt.State or not rt.State.homeId or rt.State.busy or rt.Pending then
            return
        end
        rt.RequestId = rt.RequestId + 1
        rt.Pending = rt.RequestId
        System:SendToServer(messages.AnimalEquipmentAction, { requestId = rt.RequestId,
            version = rt.Version, homeId = rt.State.homeId, action = action, itemId = itemId })
    end
    rt.Selection = Protect(function(listId, listItemId, data, selected)
        if listId ~= c.TileViewId or selected ~= true then
            return
        end
        UI:ClearListViewSelection(c.TileViewId)
        local row = rt.ByListId[listItemId]
        if not row or not row.landed or row.listItemId ~= listItemId or not Current(row, row.data)
            or type(data) ~= "table" or data.animalId ~= row.data.animalId then
            return
        end
        -- 引擎选中回调可能保留更新前的数据；同一只鸡按当前行最新状态操作。
        Request(row.data.equipped and "unequip" or "equip", row.data.animalId)
    end)
    rt.Best = Protect(function() Request("best") end)
    rt.Receive = Protect(function(_, message)
        if type(message) ~= "table" or type(message.version) ~= "number" or message.version <= rt.Version
            or type(message.items) ~= "table" then
            return
        end
        rt.Version, rt.State = message.version, message
        Render()
    end)
    rt.Result = Protect(function(_, message)
        if type(message) ~= "table" or message.requestId ~= rt.Pending then
            return
        end
        rt.Pending = nil
        if not message.success then
            local text = message.reason == "inventory_capacity_full" and "动物库存已满，请先出售"
                or (message.reason == "operation_busy" and "正在装备，请稍候" or "装备操作未完成，请查看列表")
            context.Services.PromptController:Show(text)
            Log:PrintLog("[AnimalEquipment] 操作未完成", tostring(message.reason), message.failures)
        end
    end)
    rt.Leave = function(playerId)
        if playerId == Character:GetLocalPlayerId() then self:Stop(context) end
    end
    System:BindNotify(messages.AnimalEquipmentState, rt.Receive)
    System:BindNotify(messages.AnimalEquipmentResult, rt.Result)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, rt.Leave)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, Protect(function()
        rt.Images = CustomProperty:GetCustomPropertyArray(System:GetScriptParentID(),
            GameConfig.ImageGroups.ChickenPropertyName, CustomProperty.PROPERTY_TYPE.Image)
        UI:SetListViewItemSetCall(c.TileViewId, rt.ItemSet)
        UI:SetListViewItemSelectionChangeCall(c.TileViewId, rt.Selection)
        UI:RegisterClicked(c.BestButtonId, rt.Best)
        rt.Ready = true
        UI:ClearListView(c.TileViewId)
        UI:InitListView(c.TileViewId, {})
        Render()
        System:SendToServer(messages.AnimalEquipmentSnapshotRequest, {})
    end))
end

function AnimalEquipmentController:Stop(context)
    local rt = context.Services.AnimalEquipmentController
    if not rt then return end
    rt.Active = false
    if rt.Ready then
        local c = GameConfig.AnimalEquipment
        UI:SetListViewItemSetCall(c.TileViewId, function() end)
        UI:SetListViewItemSelectionChangeCall(c.TileViewId, function() end)
        UI:UnRegisterClicked(c.BestButtonId, rt.Best)
        UI:ClearListView(c.TileViewId)
    end
    System:UnbindNotify(context.NetMsg.Messages.AnimalEquipmentState, rt.Receive)
    System:UnbindNotify(context.NetMsg.Messages.AnimalEquipmentResult, rt.Result)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, rt.Leave)
    context.Timers:RemoveOwner(self.Name)
    context.Services.AnimalEquipmentController = nil
end

return AnimalEquipmentController
