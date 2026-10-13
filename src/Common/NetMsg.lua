-- 网络消息统一在此登记。
-- 新增消息时必须放入对应分区，并由 ConfigValidator 检查 ID 唯一性。
local NetMsg = {
    Ranges = {
        CorePersistence = { Min = 1000, Max = 1099 },
        ZoneHome = { Min = 1100, Max = 1199 },
        TheftGuardianRefresh = { Min = 1200, Max = 1299 },
        InventoryHotbarPlacement = { Min = 1300, Max = 1399 },
        Egg = { Min = 1400, Max = 1499 },
        EconomyHomeUpgrade = { Min = 1500, Max = 1599 },
        Treadmill = { Min = 1600, Max = 1699 },
        RebirthPurchase = { Min = 1700, Max = 1799 },
    },

    Messages = {
        -- 临时家园分配测试：服务端同步头像目标，客户端启动后请求当前快照。
        HomeAssignmentTestAvatar = 1100,
        HomeAssignmentTestSnapshotRequest = 1101,
        ZoneState = 1110,
        HomeAssigned = 1111,
        -- 临时拾取交互测试；验收结束后保留登记供正式偷鸡模块复用或调整。
        PickupTestShow = 1200,
        PickupTestComplete = 1201,
        PickupTestCancel = 1202,
        PickupTestResult = 1203,
        PickupShow = 1210,
        PickupBegin = 1211,
        PickupComplete = 1212,
        PickupCancel = 1213,
        PickupResult = 1214,
        RefreshPhase = 1220,
        RefreshSnapshotRequest = 1221,
        InventorySnapshot = 1310,
        InventorySnapshotRequest = 1311,
        HotbarToggleSelection = 1312,
        HotbarSelectionState = 1313,
    },
}

return NetMsg
