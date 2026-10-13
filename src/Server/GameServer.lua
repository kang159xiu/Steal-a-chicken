local GameConfig = require "Common.Config.GameConfig"
local TheftRefreshService = require "Server.Services.TheftRefreshService"
local FeatureFlags = require "Common.Config.FeatureFlags"
local NetMsg = require "Common.NetMsg"
local ElementCopy = require "Common.ElementCopy"
local EventBus = require "Common.Core.EventBus"
local TimerRegistry = require "Common.Core.TimerRegistry"
local ModuleManager = require "Common.Core.ModuleManager"
local ElementCopyTest = require "Common.Debug.ElementCopyTest"
local GuardianTrackTest = require "Common.Debug.GuardianTrackTest"
local CharacterBindingTest = require "Common.Debug.CharacterBindingTest"
local GuardianCarryIntegrationTest = require "Common.Debug.GuardianCarryIntegrationTest"
local ZoneTriggerTest = require "Common.Debug.ZoneTriggerTest"
local PickupInteractionTest = require "Common.Debug.PickupInteractionTest"
local HomeAssignmentTest = require "Common.Debug.HomeAssignmentTest"
local AvatarPictureBoardTest = require "Common.Debug.AvatarPictureBoardTest"
local AvatarReadTest = require "Common.Debug.AvatarReadTest"
local ZoneService = require "Server.Services.ZoneService"
local HomeService = require "Server.Services.HomeService"
local InventoryService = require "Server.Services.InventoryService"
local HotbarService = require "Server.Services.HotbarService"
local GuardianService = require "Server.Services.GuardianService"
local TheftService = require "Server.Services.TheftService"

local GameServer = {
    Context = nil,
}

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

    self.Context.Manager:Register(ElementCopyTest)
    self.Context.Manager:Register(GuardianTrackTest)
    self.Context.Manager:Register(CharacterBindingTest)
    self.Context.Manager:Register(GuardianCarryIntegrationTest)
    self.Context.Manager:Register(ZoneTriggerTest)
    self.Context.Manager:Register(PickupInteractionTest)
    self.Context.Manager:Register(HomeAssignmentTest)
    self.Context.Manager:Register(AvatarPictureBoardTest)
    self.Context.Manager:Register(AvatarReadTest)
    self.Context.Manager:Register(ZoneService)
    self.Context.Manager:Register(HomeService)
    self.Context.Manager:Register(InventoryService)
    self.Context.Manager:Register(HotbarService)
    self.Context.Manager:Register(GuardianService)
    self.Context.Manager:Register(TheftService)
    if GameConfig.Refresh.Enabled then self.Context.Manager:Register(TheftRefreshService) end

    local initialized = self.Context.Manager:Init(self.Context)
    if not initialized then
        Log:PrintError("[GameServer:Init] 服务端基础配置校验失败")
    end
    return initialized
end


function GameServer:OnStart()
    Log:PrintServerLog("[GameServer:OnStart]")
    return self.Context and self.Context.Manager:Start() or false
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

    self.Context.Manager:Stop()
    self.Context.Timers:Clear()
    self.Context.Events:Clear()
end

return GameServer
