-- 脚本加载入口。单机模式下服务端与客户端都会启动，但两端各自持有独立运行上下文。
_GAME = {}

_GAME.GameServer = require "Server.GameServer"
_GAME.GameClient = require "Client.GameClient"

local serverInitialized = false
local clientInitialized = false
local serverUpdateTimerId = nil
local clientUpdateTimerId = nil
local serverPreviousTime = 0
local clientPreviousTime = 0

if System:IsServer() then
    serverInitialized = _GAME.GameServer:Init() == true
end
if System:IsClient() then
    clientInitialized = _GAME.GameClient:Init() == true
end

local function UpdateServer()
    local currentTime = TimerManager:GetTimeSeconds()
    _GAME.GameServer:OnUpdate(currentTime - serverPreviousTime)
    serverPreviousTime = currentTime
end

local function UpdateClient()
    local currentTime = TimerManager:GetTimeSeconds()
    _GAME.GameClient:OnUpdate(currentTime - clientPreviousTime)
    clientPreviousTime = currentTime
end

local function OnBeginPlay()
    if System:IsServer() and serverInitialized and not serverUpdateTimerId then
        serverPreviousTime = TimerManager:GetTimeSeconds()
        if _GAME.GameServer:OnStart() and _GAME.GameServer:NeedsUpdate() then
            serverUpdateTimerId = TimerManager:AddLoopFrame(1, UpdateServer)
        end
    end

    if System:IsClient() and clientInitialized and not clientUpdateTimerId then
        clientPreviousTime = TimerManager:GetTimeSeconds()
        if _GAME.GameClient:OnStart() and _GAME.GameClient:NeedsUpdate() then
            clientUpdateTimerId = TimerManager:AddLoopFrame(1, UpdateClient)
        end
    end
end

local function OnEndPlay()
    if serverUpdateTimerId then
        TimerManager:RemoveTimer(serverUpdateTimerId)
        serverUpdateTimerId = nil
    end
    if clientUpdateTimerId then
        TimerManager:RemoveTimer(clientUpdateTimerId)
        clientUpdateTimerId = nil
    end

    if System:IsServer() and serverInitialized then
        _GAME.GameServer:OnEnd()
    end
    if System:IsClient() and clientInitialized then
        _GAME.GameClient:OnEnd()
    end
end

System:RegisterEvent(Events.ON_BEGIN_PLAY, OnBeginPlay)
System:RegisterEvent(Events.ON_END_PLAY, OnEndPlay)
