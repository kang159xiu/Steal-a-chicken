local GameConfig = require "Common.Config.GameConfig"
local Diagnostic = require "Common.Debug.GuardianDiagnostic"
local Controller = { Name = "GuardianDiagnosticController", Dependencies = {} }
function Controller:Start(context)
    if context.Side ~= "Client" then return end
    local runtime = { Regions = {} }
    context.Services[self.Name] = runtime
    runtime.Callback = function(_, message)
        Diagnostic.Safe(function()
            if context.Services[self.Name] ~= runtime or type(message) ~= "table"
                or type(message.regionId) ~= "number" or type(message.sequence) ~= "number"
                or type(message.generation) ~= "number" or type(message.revision) ~= "number" then return end
            local old = runtime.Regions[message.regionId]
            if old and message.revision <= old.revision then return end
            local same = old and old.sequence == message.sequence and old.generation == message.generation
            local token = same and old.token or {}
            if message.phase == "invalidated" or message.phase == "returned" then token = {} end
            runtime.Regions[message.regionId] = { revision = message.revision, sequence = message.sequence,
                generation = message.generation, token = token }
            if message.phase == "invalidated" then return end
            local sample = {}
            for key, value in pairs(message) do sample[key] = value end
            sample.receivedTime = Diagnostic.Time()
            context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
                Diagnostic.Safe(function()
                    local current = runtime.Regions[sample.regionId]
                    if context.Services[self.Name] ~= runtime or not current or current.token ~= token then return end
                    Diagnostic.Sample("Client", sample)
                end)
            end)
        end)
    end
    Diagnostic.Safe(function() System:BindNotify(context.NetMsg.Messages.GuardianDiagnosticSample, runtime.Callback) end)
end
function Controller:Stop(context)
    if context.Side ~= "Client" then return end
    local runtime = context.Services[self.Name]
    if not runtime then return end
    context.Services[self.Name] = nil
    Diagnostic.Safe(function() System:UnbindNotify(context.NetMsg.Messages.GuardianDiagnosticSample, runtime.Callback) end)
    Diagnostic.Safe(function() context.Timers:RemoveOwner(self.Name) end)
end
return Controller
