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
        PersistenceState = 1000,
        PersistenceSnapshotRequest = 1001,
        -- 临时家园分配测试：服务端同步头像目标，客户端启动后请求当前快照。
        HomeAssignmentTestAvatar = 1100,
        HomeAssignmentTestSnapshotRequest = 1101,
        ZoneState = 1110,
        HomeAssigned = 1111,
        HomeNameState = 1112,
        HomeNameSnapshotRequest = 1113,
        HomeCountState = 1114,
        HomeCountSnapshotRequest = 1115,
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
        TheftCarryState = 1215,
        TheftManualDrop = 1216,
        TheftCarrySnapshotRequest = 1217,
        RefreshPhase = 1220,
        RefreshSnapshotRequest = 1221,
        GuardianDiagnosticSample = 1222, -- 临时只读追踪诊断及失效通知。
        InventorySnapshot = 1310,
        InventorySnapshotRequest = 1311,
        HotbarToggleSelection = 1312,
        HotbarSelectionState = 1313,
        PlacementState = 1320,
        PlacementAction = 1321,
        PlacementCancel = 1322,
        PlacementResult = 1323,
        PlacementSnapshotRequest = 1324,
        ChickenModelState = 1330, -- 已放置/快捷栏模型身份及独立售价；仅供客户端文字表现。
        ChickenModelSnapshotRequest = 1331,
        EggGrowthState = 1400,
        EggGrowthRemoved = 1401,
        EggGrowthSnapshotRequest = 1402,
        EggCollectionState = 1410,
        EggCollectionAction = 1411,
        EggCollectionCancel = 1412,
        EggCollectionResult = 1413,
        EggCollectionSnapshotRequest = 1414,
        EggCollectionListState = 1420,
        EggCollectionListSnapshotRequest = 1421,
        EggCollectionListAction = 1422,
        EggCollectionListResult = 1423,
        -- 1500/1503 balance、1503 total：无前导零的非负十进制整数字符串（零为"0"）。
        -- 单项sellPrice同为精确非负十进制字符串；会话代次、版本及requestId使用安全整数number。
        SellShopState = 1500,
        SellShopSnapshotRequest = 1501,
        SellShopAction = 1502,
        -- 测试操作test_add_money复用会话/requestId；金额只取服务端配置，不扣库存。
        SellShopResult = 1503,
        -- 1510 kind=level附带slots(编号/场景显示ID)、unlockedSlots及displayVersion，广播所有客户端。
        -- interaction/action/result携带entry(home/placement)、slotIndex与原目标/会话代次。
        HomeUpgradeState = 1510,
        HomeUpgradeSnapshotRequest = 1511,
        HomeUpgradeAction = 1512,
        HomeUpgradeResult = 1513,
        -- 经验、需求及费用使用精确十进制整数字符串。
        TreadmillState = 1600,
        TreadmillSnapshotRequest = 1601,
        TreadmillAction = 1602,
        TreadmillResult = 1603,
        RebirthState = 1700,
        RebirthSnapshotRequest = 1701,
        RebirthAction = 1702,
        RebirthResult = 1703,
        RebirthPurchaseOpen = 1704,
        RebirthPurchaseOffer = 1705,
        RebirthVoucherCheck = 1706, -- 只唤醒服务端核票，不是购买凭据。
        RebirthPurchaseResult = 1707,
        MultiplierPurchaseState = 1710,
        MultiplierPurchaseSnapshotRequest = 1711,
        MultiplierPurchaseOpen = 1712,
        MultiplierPurchaseOffer = 1713,
        MultiplierVoucherCheck = 1714, -- 空请求只唤醒真实库存核票。
        MultiplierPurchaseResult = 1715,
        TrackShopState = 1720,
        TrackShopSnapshotRequest = 1721,
        TrackShopAction = 1722,
        TrackShopResult = 1723,
    },
}

return NetMsg
