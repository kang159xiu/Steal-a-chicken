local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local SellShopController = { Name = "SellShopController", FeatureFlag = "SellShop", Dependencies = {} }
local function MoneyText(value)
    return Decimal.Format(value)
end
local function Integer(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value == math.floor(value)
end
function SellShopController:ValidateConfig()
    local c = GameConfig.SellShop
    local errors = {}
    if type(c) == "table" and c.TestMoneyEnabled == true
        and (not Integer(c.TestMoneyButtonId) or c.TestMoneyButtonId == 0) then
        errors[#errors + 1] = "测试加钱按钮配置无效"
    end
    for _, key in ipairs({ "EggListId", "ChickenListId", "TemplateId", "ImageId", "PriceTextId",
        "AppearanceButtonId", "SelectedBorderId", "SellAllEggsButtonId", "SellAllChickensButtonId", "BalanceTextId" }) do
        if not c or not Integer(c[key]) or c[key] == 0 then errors[#errors + 1] = "SellShop." .. key .. " 必须是正整数" end
    end
    return #errors == 0, errors
end
function SellShopController:Start(context)
    if context.Side ~= "Client" then return end
    local c, messages = GameConfig.SellShop, context.NetMsg.Messages
    local runtime = { Active = true, Ready = false, SessionGeneration = 0, Version = 0, RequestId = 0,
        RowGeneration = 0, Pending = {}, Images = {}, Lists = {} }
    for _, entry in ipairs({ { c.ChickenListId, "Chicken" }, { c.EggListId, "Egg" } }) do
        runtime.Lists[entry[1]] = { id = entry[1], kind = entry[2], rows = {}, byItem = {} }
    end
    context.Services.SellShopController = runtime
    local function Active() return runtime.Active and context.Services.SellShopController == runtime end
    local function Protect(callback)
        return function(...)
            if not Active() then return end
            local args = { n = select("#", ...), ... }
            local ok, err = pcall(function() callback((table.unpack or unpack)(args, 1, args.n)) end)
            if not ok then context.Manager:FailModule(self.Name, tostring(err)) end
        end
    end
    local function Current(list, row)
        return Active() and runtime.Ready and row.sessionGeneration == runtime.SessionGeneration
            and list.rows[row.data.itemId] == row and list.byItem[row.listItemId] == row
    end
    local function Paint(list, row)
        if not Current(list, row) or not row.landed then return end
        local imageUid = UI:GetListViewItemUID(list.id, row.listItemId, c.ImageId)
        local priceUid = UI:GetListViewItemUID(list.id, row.listItemId, c.PriceTextId)
        local borderUid = UI:GetListViewItemUID(list.id, row.listItemId, c.SelectedBorderId)
        if not imageUid or imageUid == "" or not priceUid or priceUid == "" or not borderUid or borderUid == "" then
            error("出售列表子控件UID缺失，itemId=" .. row.data.itemId)
        end
        UI:SetImage({ imageUid }, row.data.imageId, true)
        UI:SetText({ priceUid }, MoneyText(row.data.sellPrice), false)
        -- 引擎选择仅作为点击输入，不保留业务选中提示；显隐在回调外落地后设置。
        UI:SetVisibility({ borderUid }, false)
    end
    local function Reset()
        runtime.Pending = {}
        for _, list in pairs(runtime.Lists) do
            list.rows, list.byItem = {}, {}
            if runtime.Ready then UI:ClearListView(list.id) end
        end
    end
    local function RenderList(list, records)
        local present = {}
        for _, item in ipairs(records) do present[item.itemId] = true end
        for key, row in pairs(list.rows) do
            if not present[key] then
                list.rows[key] = nil
                if row.listItemId then list.byItem[row.listItemId] = nil; UI:RemoveListViewItem(list.id, row.listItemId) end
            end
        end
        for _, item in ipairs(records) do
            local row = list.rows[item.itemId]
            local image = runtime.Images[list.kind][item.iconIndex]
            if image == nil or image == 0 then error("出售图片配置缺失，itemId=" .. item.itemId) end
            if not row then
                runtime.RowGeneration = runtime.RowGeneration + 1
                row = { generation = runtime.RowGeneration, sessionGeneration = runtime.SessionGeneration }
                list.rows[item.itemId] = row
            end
            local prior = row.data
            -- 价格/图像更新不改变输入代次，旧同身份数据副本仍可输入。
            if not prior or prior.sellPrice ~= item.sellPrice or prior.imageId ~= image then
                row.data = { itemId = item.itemId, kind = item.kind, sellPrice = item.sellPrice,
                    imageId = image, rowGeneration = row.generation, sessionGeneration = row.sessionGeneration }
                row.landed = false
                if row.listItemId then UI:UpdateListViewItem(list.id, row.listItemId, row.data)
                else
                    row.listItemId = UI:AddListViewItem(list.id, row.data)
                    if not row.listItemId then error("出售列表添加未返回ID，itemId=" .. item.itemId) end
                    list.byItem[row.listItemId] = row
                end
            end
        end
    end
    local function Render()
        if not runtime.Ready or not runtime.Snapshot then return end
        UI:SetText({ c.BalanceTextId }, MoneyText(runtime.Snapshot.balance), false)
        RenderList(runtime.Lists[c.ChickenListId], runtime.Snapshot.chickens)
        RenderList(runtime.Lists[c.EggListId], runtime.Snapshot.eggs)
    end
    local function Request(action, itemId)
        if not runtime.Ready or runtime.SessionGeneration == 0 then return end
        runtime.RequestId = runtime.RequestId + 1
        local request = { sessionGeneration = runtime.SessionGeneration, requestId = runtime.RequestId, action = action, itemId = itemId }
        runtime.Pending[request.requestId] = request
        System:SendToServer(messages.SellShopAction, request)
    end
    for _, list in pairs(runtime.Lists) do
        list.SetCallback = Protect(function(listId, listItemId, data)
            if listId ~= list.id or type(data) ~= "table" then return end
            local row = list.rows[data.itemId]
            if not row or data.rowGeneration ~= row.generation or data.sessionGeneration ~= row.sessionGeneration
                or row.sessionGeneration ~= runtime.SessionGeneration
                or (row.listItemId and row.listItemId ~= listItemId)
                or (list.byItem[listItemId] and list.byItem[listItemId] ~= row) then return end
            row.listItemId = listItemId
            list.byItem[listItemId] = row
            row.binding = (row.binding or 0) + 1
            local binding = row.binding
            row.landed = false
            context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, Protect(function()
                if not Current(list, row) or row.binding ~= binding then return end
                row.landed = true
                Paint(list, row)
                -- 新建或更新时的原生选中不作为出售；复位后再允许输入。
                UI:ClearListViewSelection(list.id)
            end))
        end)
        list.SelectionCallback = Protect(function(listId, listItemId, data, selected)
            if selected ~= true or listId ~= list.id or type(data) ~= "table" then return end
            local row = list.rows[data.itemId]
            if not row or not Current(list, row) or not row.landed
                or row.listItemId ~= listItemId or row.generation ~= data.rowGeneration
                or row.sessionGeneration ~= data.sessionGeneration then return end
            local itemId = row.data.itemId
            UI:ClearListViewSelection(list.id)
            if Current(list, row) then Request("single", itemId) end
        end)
        -- 先保存回调引用；涉及UI实例的注册与初始化在启动延迟后执行。
    end
    runtime.StateCallback = Protect(function(_, message)
        if type(message) ~= "table" or not Integer(message.sessionGeneration) or message.sessionGeneration == 0
            or not Integer(message.version) or message.version == 0 or not Decimal.IsValid(message.balance)
            or type(message.chickens) ~= "table" or type(message.eggs) ~= "table" then error("出售快照格式无效") end
        if message.sessionGeneration < runtime.SessionGeneration
            or (message.sessionGeneration == runtime.SessionGeneration and message.version <= runtime.Version) then return end
        if runtime.DepartedGeneration and message.sessionGeneration <= runtime.DepartedGeneration then return end
        for _, group in ipairs({ { message.chickens, "Chicken" }, { message.eggs, "Egg" } }) do
            local seen = {}
            for _, item in ipairs(group[1]) do
                if type(item) ~= "table" or type(item.itemId) ~= "string" or item.itemId == "" or seen[item.itemId]
                    or item.kind ~= group[2] or item.count ~= 1 or not Integer(item.sequence) or item.sequence == 0
                    or not Integer(item.iconIndex) or item.iconIndex == 0 or not Decimal.IsValid(item.sellPrice) then error("出售行格式无效") end
                seen[item.itemId] = true
            end
        end
        if message.sessionGeneration ~= runtime.SessionGeneration then Reset() end
        runtime.SessionGeneration, runtime.Version = message.sessionGeneration, message.version
        runtime.Snapshot = message
        Render()
    end)
    runtime.ResultCallback = Protect(function(_, message)
        if type(message) ~= "table" or message.sessionGeneration ~= runtime.SessionGeneration then return end
        if not Decimal.IsValid(message.balance) or not Decimal.IsValid(message.total) then error("出售结果钱币格式无效") end
        local request = runtime.Pending[message.requestId]
        if not request or request.action ~= message.action or request.itemId ~= message.itemId then return end
        runtime.Pending[message.requestId] = nil
        if message.success == false then
            Log:PrintWarning("[SellShopController] 出售请求未全部完成", "requestId:", message.requestId,
                "itemId:", tostring(message.itemId), "reason:", tostring(message.reason))
        end
        -- 余额展示只采用带版本的状态消息，避免迟到结果覆盖新余额。
    end)
    runtime.AllEggsCallback = Protect(function() Request("all_eggs") end)
    runtime.TestMoneyCallback = Protect(function()
        if c.TestMoneyEnabled == true then Request("test_add_money") end
    end)
    runtime.AllChickensCallback = Protect(function() Request("all_chickens") end)
    System:BindNotify(messages.SellShopState, runtime.StateCallback)
    System:BindNotify(messages.SellShopResult, runtime.ResultCallback)
    runtime.LeaveCallback = Protect(function(playerId)
        if playerId ~= Character:GetLocalPlayerId() then return end
        runtime.DepartedGeneration = runtime.SessionGeneration
        runtime.Snapshot = nil
        Reset()
        if runtime.Ready then UI:SetText({ c.BalanceTextId }, "0", false) end
    end)
    System:RegisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, Protect(function()
        local parentId = System:GetScriptParentID()
        runtime.Images.Chicken = CustomProperty:GetCustomPropertyArray(parentId, GameConfig.ImageGroups.ChickenPropertyName, CustomProperty.PROPERTY_TYPE.Image) or {}
        runtime.Images.Egg = CustomProperty:GetCustomPropertyArray(parentId, GameConfig.ImageGroups.EggPropertyName, CustomProperty.PROPERTY_TYPE.Image) or {}
        for _, list in pairs(runtime.Lists) do
            list.bound = true
            UI:SetListViewItemSetCall(list.id, list.SetCallback)
            UI:SetListViewItemSelectionChangeCall(list.id, list.SelectionCallback)
            UI:ClearListView(list.id)
            UI:InitListView(list.id, {})
        end
        runtime.ButtonsBound = true
        UI:RegisterClicked(c.SellAllEggsButtonId, runtime.AllEggsCallback)
        UI:RegisterClicked(c.SellAllChickensButtonId, runtime.AllChickensCallback)
        if c.TestMoneyEnabled == true then
            UI:RegisterClicked(c.TestMoneyButtonId, runtime.TestMoneyCallback)
            runtime.TestMoneyBound = true
        end
        runtime.Ready = true
        if not runtime.Snapshot then UI:SetText({ c.BalanceTextId }, "0", false) end
        Render()
        System:SendToServer(messages.SellShopSnapshotRequest, {})
    end))
end
function SellShopController:Stop(context)
    local runtime = context.Services.SellShopController
    if not runtime then return end
    runtime.Active = false
    runtime.Pending = {}
    for _, list in pairs(runtime.Lists) do
        list.rows, list.byItem = {}, {}
        if list.bound then
            UI:SetListViewItemSetCall(list.id, function() end)
            UI:SetListViewItemSelectionChangeCall(list.id, function() end)
            UI:ClearListView(list.id)
        end
    end
    local c, m = GameConfig.SellShop, context.NetMsg.Messages
    if runtime.ButtonsBound then
        UI:UnRegisterClicked(c.SellAllEggsButtonId, runtime.AllEggsCallback)
        UI:UnRegisterClicked(c.SellAllChickensButtonId, runtime.AllChickensCallback)
    end
    if runtime.TestMoneyBound then UI:UnRegisterClicked(c.TestMoneyButtonId, runtime.TestMoneyCallback) end
    System:UnbindNotify(m.SellShopState, runtime.StateCallback)
    System:UnbindNotify(m.SellShopResult, runtime.ResultCallback)
    System:UnregisterEvent(Events.ON_PLAYER_PRELEAVE, runtime.LeaveCallback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.SellShopController = nil
end
return SellShopController
