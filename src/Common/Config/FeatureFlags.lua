-- 功能开关只在每局初始化时读取。
-- 正式模块完成接线后按本表启用；临时 API 测试模块保持关闭。
local FeatureFlags = {
    Names = {
        "ElementCopyTest",
        "GuardianTrackTest",
        "CharacterBindingTest",
        "GuardianCarryIntegrationTest",
        "ZoneTriggerTest",
        "PickupInteractionTest",
        "HomeAssignmentTest",
        "AvatarPictureBoardTest",
        "AvatarReadTest",
        "HotbarClickTest",
        "Persistence",
        "Zone",
        "Home",
        "Theft",
        "Guardian",
        "Inventory",
        "Hotbar",
        "Placement",
        "EggProduction",
        "EggCollection",
        "SellShop",
        "HomeUpgrade",
        "Treadmill",
        "Rebirth",
        "Purchase",
    },

    -- 仅用于避免共享开关在不需要该功能的端产生“未登记模块”警告。
    Scopes = {
        HotbarClickTest = { Server = false, Client = true },
        Persistence = { Server = true, Client = true },
        Zone = { Server = true, Client = false },
        Home = { Server = true, Client = true },
        Inventory = { Server = true, Client = false },
        Guardian = { Server = true, Client = false },
        Theft = { Server = true, Client = true },
        Hotbar = { Server = true, Client = true },
        Placement = { Server = true, Client = true },
        EggProduction = { Server = true, Client = true },
        EggCollection = { Server = true, Client = true },
        SellShop = { Server = true, Client = true },
        HomeUpgrade = { Server = true, Client = true },
        Treadmill = { Server = true, Client = true },
        Rebirth = { Server = true, Client = true },
    },

    Values = {
        -- 元件树复制测试已通过。
        ElementCopyTest = false,
        -- 守护者追踪、命中停止和双方复位测试已通过。
        GuardianTrackTest = false,
        -- Root + KeepWorld 角色附加测试已通过。
        CharacterBindingTest = false,
        -- 临时开启：验证守护者追踪附加在玩家 Root 上的目标并由触发盒捕获。
        GuardianCarryIntegrationTest = false,
        -- 232/233 边界触发盒进入事件测试已通过。
        ZoneTriggerTest = false,
        -- 动态复制鸡整树拾取测试已通过，保持关闭。
        PickupInteractionTest = false,
        -- 家园分配与归属测试暂时关闭，避免干扰固定图标显示器头像诊断。
        HomeAssignmentTest = false,
        -- 固定图标显示器头像测试暂时关闭，避免影响单独读取头像的结果。
        AvatarPictureBoardTest = false,
        -- 头像 API 返回0的问题暂时搁置，保留诊断代码但不运行。
        AvatarReadTest = false,
        -- 独立瓦片点击测试已通过，保留代码备用。
        HotbarClickTest = false,
        Persistence = true,
        Zone = true,
        Home = true,
        -- 已验收玩法与正式快捷栏保持开启。
        Theft = true,
        Guardian = true,
        -- TheftService 的正式数据依赖，成功带回的鸡通过 InventoryService 入库。
        Inventory = true,
        Hotbar = true,
        Placement = true,
        EggProduction = true,
        EggCollection = true,
        SellShop = true,
        HomeUpgrade = true,
        Treadmill = true,
        Rebirth = true,
        Purchase = false,
    },
}

return FeatureFlags
