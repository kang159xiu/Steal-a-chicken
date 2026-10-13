-- 独立客户端点击测试：只装填一个测试项，不接入库存、展示树或网络消息。
local GameConfig = require "Common.Config.GameConfig"
local FeatureFlags = require "Common.Config.FeatureFlags"

local HotbarClickTest = {
    Name = "HotbarClickTest",
    FeatureFlag = "HotbarClickTest",
    Dependencies = {},
}

function HotbarClickTest:ValidateConfig(context)
    if FeatureFlags.Values.Hotbar then
        return false, { "独立点击测试要求正式Hotbar关闭，避免共同管理同一瓦片视图" }
    end
    return true
end

function HotbarClickTest:Start(context)
    if context.Side ~= "Client" then return end
    local config = GameConfig.Hotbar
    local runtime = { Active = true, ClickCount = 0 }
    context.Services.HotbarClickTest = runtime

    local function IsActive()
        return runtime.Active and context.Services.HotbarClickTest == runtime
    end

    local function SetItem(listViewId, itemId, itemData)
        if not IsActive() then return end
        Log:PrintLog("[HotbarClickTest] 测试项已装填",
            "listViewId:", listViewId, "templateId:", config.TileTemplateId,
            "itemId:", itemId, "businessItemId:", tostring(itemData.itemId))
    end
    runtime.ItemSetCallback = function(listViewId, itemId, itemData)
        if not IsActive() then return end
        local ok, errorMessage = pcall(SetItem, listViewId, itemId, itemData)
        if not ok then
            context.Manager:FailModule(HotbarClickTest.Name, "测试项装填失败: " .. tostring(errorMessage))
        end
    end
    runtime.SelectionCallback = function(listViewId, itemId, itemData, selected)
        if not IsActive() then return end
        Log:PrintLog("[HotbarClickTest] 收到原生选择变化",
            "listViewId:", listViewId, "itemId:", tostring(itemId),
            "itemIdType:", type(itemId), "itemDataType:", type(itemData),
            "businessItemId:", tostring(type(itemData) == "table" and itemData.itemId),
            "selected:", tostring(selected), "selectedType:", type(selected))
        -- 沿用 di_tie/Client/WeaponShop.lua：选中时响应，再清除选择以支持重复点击。
        -- 清除选择会产生 selected=false 回调，该回调不计作点击。
        if not selected then return end
        local ok, errorMessage = pcall(function()
            runtime.ClickCount = runtime.ClickCount + 1
            Log:PrintLog("[HotbarClickTest] 收到瓦片点击",
                "listViewId:", listViewId, "itemId:", itemId,
                "clickCount:", runtime.ClickCount)
            UI:ShowMessageTip("瓦片点击测试成功，第" .. tostring(runtime.ClickCount) .. "次")
            UI:ClearListViewSelection(listViewId)
        end)
        if not ok then
            context.Manager:FailModule(HotbarClickTest.Name, "瓦片点击测试失败: " .. tostring(errorMessage))
        end
    end

    context.Timers:AddTimer(self.Name, 2, function()
        if not IsActive() then return end
        UI:SetVisibility({ config.UiGroupId, config.TileViewId }, true)
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not IsActive() then return end
            UI:SetListViewItemSetCall(config.TileViewId, runtime.ItemSetCallback)
            UI:SetListViewItemSelectionChangeCall(config.TileViewId, runtime.SelectionCallback)
            UI:ClearListView(config.TileViewId)
            local itemIds = UI:InitListView(config.TileViewId, { { itemId = "click-test", count = 1 } })
            Log:PrintLog("[HotbarClickTest] 独立测试已装填，请点击展示项",
                "listViewId:", config.TileViewId, "editorTemplateId:", config.TileTemplateId,
                "itemCount:", itemIds and #itemIds or 0)
        end)
    end)
    Log:PrintLog("[HotbarClickTest] 已启动，2秒后显示并装填一个测试项")
end

function HotbarClickTest:Stop(context)
    local runtime = context.Services.HotbarClickTest
    if not runtime then return end
    runtime.Active = false
    local config = GameConfig.Hotbar
    UI:SetListViewItemSetCall(config.TileViewId, function() end)
    UI:SetListViewItemSelectionChangeCall(config.TileViewId, function() end)
    UI:ClearListView(config.TileViewId)
    UI:SetVisibility({ config.UiGroupId }, false)
    context.Services.HotbarClickTest = nil
end

return HotbarClickTest
