local GuardianDiagnosticController = require "Client.Controllers.GuardianDiagnosticController"
local GameConfig = require "Common.Config.GameConfig"
local ChickenValueController = require "Client.Controllers.ChickenValueController"
local PersistenceController = require "Client.Controllers.PersistenceController"
local PromptController = require "Client.Controllers.PromptController"
local RefreshController = require "Client.Controllers.RefreshController"
local FeatureFlags = require "Common.Config.FeatureFlags"
local NetMsg = require "Common.NetMsg"
local ElementCopy = require "Common.ElementCopy"
local EventBus = require "Common.Core.EventBus"
local TimerRegistry = require "Common.Core.TimerRegistry"
local ModuleManager = require "Common.Core.ModuleManager"
local ElementCopyTest = require "Common.Debug.ElementCopyTest"
local GuideLineTest = require "Client.Debug.GuideLineTest"
local GuardianTrackTest = require "Common.Debug.GuardianTrackTest"
local CharacterBindingTest = require "Common.Debug.CharacterBindingTest"
local GuardianCarryIntegrationTest = require "Common.Debug.GuardianCarryIntegrationTest"
local ZoneTriggerTest = require "Common.Debug.ZoneTriggerTest"
local PickupInteractionTest = require "Common.Debug.PickupInteractionTest"
local HomeAssignmentTest = require "Common.Debug.HomeAssignmentTest"
local AvatarPictureBoardTest = require "Common.Debug.AvatarPictureBoardTest"
local AvatarReadTest = require "Common.Debug.AvatarReadTest"
local PickupController = require "Client.Controllers.PickupController"
local HotbarController = require "Client.Controllers.HotbarController"
local SellShopController = require "Client.Controllers.SellShopController"
local PlacementController = require "Client.Controllers.PlacementController"
local HomeNameController = require "Client.Controllers.HomeNameController"
local HomeCountController = require "Client.Controllers.HomeCountController"
local HomeUpgradeController = require "Client.Controllers.HomeUpgradeController"
local TreadmillController = require "Client.Controllers.TreadmillController"
local RebirthController = require "Client.Controllers.RebirthController"
local MultiplierPurchaseController = require "Client.Controllers.MultiplierPurchaseController"
local TrackShopController = require "Client.Controllers.TrackShopController"
local EggGrowthController = require "Client.Controllers.EggGrowthController"
local EggCollectionController = require "Client.Controllers.EggCollectionController"
local EggCollectionListController = require "Client.Controllers.EggCollectionListController"
local HotbarClickTest = require "Common.Debug.HotbarClickTest"

local GameClient = {
    Context = nil,
}

local function CreateClientContext()
    local manager = ModuleManager.New("Client", FeatureFlags, NetMsg)
    local events = EventBus.New(function(owner, errorMessage)
        manager:FailModule(owner, errorMessage)
    end)
    local timers = TimerRegistry.New(function(owner, errorMessage)
        manager:FailModule(owner, errorMessage)
    end)

    return {
        Side = "Client",
        Manager = manager,
        Events = events,
        Timers = timers,
        ElementCopy = ElementCopy.New("Client", timers),
        NetMsg = NetMsg,
        Services = {},
    }
end


function GameClient:Init()
    Log:PrintLog("[GameClient:Init]")
    self.Context = CreateClientContext()

    self.Context.Manager:Register(ElementCopyTest)
    self.Context.Manager:Register(GuideLineTest)
    self.Context.Manager:Register(GuardianTrackTest)
    self.Context.Manager:Register(CharacterBindingTest)
    self.Context.Manager:Register(GuardianCarryIntegrationTest)
    self.Context.Manager:Register(ZoneTriggerTest)
    self.Context.Manager:Register(PickupInteractionTest)
    self.Context.Manager:Register(HomeAssignmentTest)
    self.Context.Manager:Register(AvatarPictureBoardTest)
    self.Context.Manager:Register(AvatarReadTest)
    if FeatureFlags.Values.Guardian then self.Context.Manager:Register(GuardianDiagnosticController) end
    self.Context.Manager:Register(PromptController)
    self.Context.Manager:Register(PersistenceController)
    self.Context.Manager:Register(PickupController)
    self.Context.Manager:Register(HotbarController)
    self.Context.Manager:Register(ChickenValueController)
    self.Context.Manager:Register(SellShopController)
    self.Context.Manager:Register(PlacementController)
    self.Context.Manager:Register(HomeNameController)
    self.Context.Manager:Register(HomeCountController)
    self.Context.Manager:Register(HomeUpgradeController)
    self.Context.Manager:Register(TreadmillController)
    self.Context.Manager:Register(RebirthController)
    self.Context.Manager:Register(MultiplierPurchaseController)
    self.Context.Manager:Register(TrackShopController)
    self.Context.Manager:Register(EggGrowthController)
    self.Context.Manager:Register(EggCollectionController)
    self.Context.Manager:Register(EggCollectionListController)
    if GameConfig.Refresh.Enabled then self.Context.Manager:Register(RefreshController) end
    self.Context.Manager:Register(HotbarClickTest)

    local initialized = self.Context.Manager:Init(self.Context)
    if not initialized then
        Log:PrintError("[GameClient:Init] 客户端基础配置校验失败")
    end
    return initialized
end


function GameClient:OnStart()
    Log:PrintLog("[GameClient:OnStart]")
    return self.Context and self.Context.Manager:Start() or false
end


function GameClient:OnUpdate(deltaTime)
    if self.Context then
        self.Context.Manager:Update(deltaTime)
    end
end


function GameClient:NeedsUpdate()
    return self.Context and self.Context.Manager:HasActiveUpdates() or false
end


function GameClient:OnEnd()
    Log:PrintLog("[GameClient:OnEnd]")
    if not self.Context then
        return
    end

    self.Context.Manager:Stop()
    self.Context.Timers:Clear()
    self.Context.Events:Clear()
end

return GameClient
