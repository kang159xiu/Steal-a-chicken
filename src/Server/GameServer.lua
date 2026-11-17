local TutorialService = require "Server.Services.TutorialService"
local GameConfig = require "Common.Config.GameConfig"
local TheftRefreshService = require "Server.Services.TheftRefreshService"
local FeatureFlags = require "Common.Config.FeatureFlags"
local NetMsg = require "Common.NetMsg"
local ElementCopy = require "Common.ElementCopy"
local EventBus = require "Common.Core.EventBus"
local TimerRegistry = require "Common.Core.TimerRegistry"
local ModuleManager = require "Common.Core.ModuleManager"
local AvatarPictureBoardTest = require "Common.Debug.AvatarPictureBoardTest"
local AvatarReadTest = require "Common.Debug.AvatarReadTest"
local ZoneService = require "Server.Services.ZoneService"
local HomeService = require "Server.Services.HomeService"
local HomeUpgradeService = require "Server.Services.HomeUpgradeService"
local PlayerSpeedService = require "Server.Services.PlayerSpeedService"
local TreadmillService = require "Server.Services.TreadmillService"
local RebirthService = require "Server.Services.RebirthService"
local PurchaseService = require "Server.Services.PurchaseService"
local GiftPackService = require "Server.Services.GiftPackService"
local SignInService = require "Server.Services.SignInService"
local CoinPurchaseService = require "Server.Services.CoinPurchaseService"
local MultiplierPurchaseService = require "Server.Services.MultiplierPurchaseService"
local TrackShopService = require "Server.Services.TrackShopService"
local PlacementService = require "Server.Services.PlacementService"
local EggProductionService = require "Server.Services.EggProductionService"
local EggCollectionService = require "Server.Services.EggCollectionService"
local InventoryService = require "Server.Services.InventoryService"
local PersistenceService = require "Server.Services.PersistenceService"
local EconomyService = require "Server.Services.EconomyService"
local SellShopService = require "Server.Services.SellShopService"
local HotbarService = require "Server.Services.HotbarService"
local GuardianService = require "Server.Services.GuardianService"
local TheftService = require "Server.Services.TheftService"

local GameServer = {
    Context = nil,
}

local function StartupDiagnostic(stage, fields)
    pcall(function()
        local values = {}
        for name, read in pairs(fields or {}) do
            local readOK, value = pcall(read)
            local textOK, detail = pcall(tostring, value)
            values[#values + 1] = name .. "=" .. (textOK and detail or "<conversion_failed>")
                .. " readOK=" .. tostring(readOK)
        end
        pcall(function() Log:PrintServerLog("[ServerStartupDiag]", stage, table.concat(values, " | ")) end)
    end)
end

local function CreateServerContext()
    local manager = ModuleManager.New("Server", FeatureFlags, NetMsg)
    local events = EventBus.New(function(owner, errorMessage)
        manager:FailModule(owner, errorMessage)
    end)
    local timers = TimerRegistry.New(function(owner, errorMessage)
        manager:FailModule(owner, errorMessage)
    end)

    return {
        Side = "Server",
        Manager = manager,
        Events = events,
        Timers = timers,
        ElementCopy = ElementCopy.New("Server", timers),
        NetMsg = NetMsg,
        Services = {},
    }
end


function GameServer:Init()
    Log:PrintServerLog("[GameServer:Init]")
    self.Context = CreateServerContext()

    self.Context.Manager:Register(AvatarPictureBoardTest)
    self.Context.Manager:Register(AvatarReadTest)
    self.Context.Manager:Register(ZoneService)
    self.Context.Manager:Register(HomeService)
    self.Context.Manager:Register(InventoryService)
    self.Context.Manager:Register(PersistenceService)
    self.Context.Manager:Register(EconomyService)
    self.Context.Manager:Register(PlayerSpeedService)
    self.Context.Manager:Register(TreadmillService)
    self.Context.Manager:Register(PurchaseService)
    self.Context.Manager:Register(RebirthService)
    self.Context.Manager:Register(MultiplierPurchaseService)
    self.Context.Manager:Register(CoinPurchaseService)
    self.Context.Manager:Register(GiftPackService)
    self.Context.Manager:Register(SignInService)
    self.Context.Manager:Register(TrackShopService)
    self.Context.Manager:Register(HomeUpgradeService)
    self.Context.Manager:Register(SellShopService)
    self.Context.Manager:Register(HotbarService)
    self.Context.Manager:Register(PlacementService)
    self.Context.Manager:Register(EggProductionService)
    self.Context.Manager:Register(EggCollectionService)
    self.Context.Manager:Register(GuardianService)
    self.Context.Manager:Register(TheftService)
    self.Context.Manager:Register(TutorialService)
    if GameConfig.Refresh.Enabled then self.Context.Manager:Register(TheftRefreshService) end

    local initialized = self.Context.Manager:Init(self.Context)
    if not initialized then
        Log:PrintError("[GameServer:Init] 服务端基础配置校验失败")
    end
    return initialized
end


function GameServer:OnStart()
    StartupDiagnostic("enter", { contextPresent = function() return self.Context ~= nil end })
    Log:PrintServerLog("[GameServer:OnStart]")
    if not self.Context then
        StartupDiagnostic("context_missing")
        return false
    end
    local started = self.Context.Manager:Start()
    StartupDiagnostic("manager_return", { started = function() return started end })
    pcall(function()
        for _, name in ipairs(self.Context.Manager._registrationOrder) do
            pcall(function()
                StartupDiagnostic("module_result", {
                    name = function() return name end,
                    status = function() return self.Context.Manager._records[name].Status end,
                })
            end)
        end
    end)
    if not started then return false end
    StartupDiagnostic("production_gate", { enabled = function() return GameConfig.Persistence.ProductionEnabled end })
    if GameConfig.Persistence.ProductionEnabled then
        local persistence = self.Context.Services.PersistenceService
        StartupDiagnostic("seal_before", { persistencePresent = function() return persistence ~= nil end })
        local ok, reason
        if persistence then ok, reason = persistence:SealAdapters() end
        StartupDiagnostic("seal_after", { ok = function() return ok end, reason = function() return reason end })
        if not ok then
            Log:PrintError("[Persistence] adapter seal failed; assets remain locked", tostring(reason))
            return false
        end
    end
    return true
end


function GameServer:OnUpdate(deltaTime)
    if self.Context then
        self.Context.Manager:Update(deltaTime)
    end
end


function GameServer:NeedsUpdate()
    return self.Context and self.Context.Manager:HasActiveUpdates() or false
end


function GameServer:OnEnd()
    Log:PrintServerLog("[GameServer:OnEnd]")
    if not self.Context then
        return
    end

    local persistence = self.Context.Services.PersistenceService
    if GameConfig.Persistence.ProductionEnabled and persistence then
        for _, id in ipairs(Character:GetAllPlayerIds() or {}) do persistence:PrepareLeave(id) end
    end
    -- Stop随后取消计时器；此处不表示跨帧云写入已完成。
    self.Context.Manager:Stop()
    self.Context.Timers:Clear()
    self.Context.Events:Clear()
end

return GameServer
