local GameConfig = require "Common.Config.GameConfig"
local Decimal = require "Common.DecimalInteger"
local EggModelText = require "Common.EggModelText"
local ChickenValueController = { Name = "ChickenValueController" }
local function EggConfig(eggTypeId)
    for _, chicken in pairs(GameConfig.ChickenTypes) do
        if chicken.Egg and chicken.Egg.EggTypeId == eggTypeId then return chicken.Egg end
    end
end

function ChickenValueController:Start(context)
    if context.Side ~= "Client" then return end
    local config = GameConfig.ChickenDisplay
    local rt = { Ready = false, Active = true, Sources = {}, Roots = {}, TransferredRoots = {} }
    context.Services.ChickenValueController = rt
    local function Active() return rt.Active and context.Services.ChickenValueController == rt end
    local function Current(record)
        return Active() and rt.Roots[record.rootId] == record
            and record.owner.models[record.rootId] == record
    end
    local function RenderCountdown(record, elementId)
        if not Current(record) then return end
        local ok, reason = pcall(function()
            local visible = record.countdownEndMs ~= nil
            if visible then
                local seconds = math.max(0, math.ceil((record.countdownEndMs - MiscService:GetServerTimestamp()) / 1000))
                FuncElement:SetTextBoardText(elementId, tostring(seconds) .. "s")
            end
            if Current(record) then Element:SetVisibility(elementId, visible) end
        end)
        if not ok then
            Log:PrintError("[ChickenValue] 倒计时文字失败，仅跳过本元件", "rootId:", record.rootId,
                "elementId:", elementId, tostring(reason))
            record.countdownElements[elementId] = nil
        end
    end
    local function Queue(record)
        if not rt.Ready then return end
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Current(record) then return end
            local visited = {}
            local function Visit(elementId)
                if not Current(record) or visited[elementId] then return end
                visited[elementId] = true
                local readOk, purpose = pcall(function()
                    return CustomProperty:GetCustomProperty(elementId, config.PurposeProperty, CustomProperty.PROPERTY_TYPE.String)
                end)
                if readOk then pcall(function()
                    if not Current(record) then return end
                    local chicken = GameConfig.ChickenTypes[record.chickenType]
                    if record.kind == "Egg" then
                        local egg = EggConfig(record.eggTypeId)
                        if purpose == GameConfig.EggGrowth.ValuePurpose then
                            FuncElement:SetTextBoardText(elementId, EggModelText.FormatPrice(record.finalSellPrice))
                            if Current(record) then Element:SetVisibility(elementId, true) end
                        elseif purpose == GameConfig.EggGrowth.MultiplierPurpose then
                            FuncElement:SetTextBoardText(elementId, egg.DisplayName)
                            if Current(record) then Element:SetVisibility(elementId, true) end
                        end
                    elseif purpose == config.EggValuePurpose then
                        local text = Decimal.Format(Decimal.FromSafeInteger(chicken.Egg.SellPrice))
                        text = text:gsub("(%.[0-9]-)0+([^0-9]*)$", "%1%2"):gsub("%.([^0-9]*)$", "%1")
                        FuncElement:SetTextBoardText(elementId, "~" .. text .. "$")
                        if Current(record) then Element:SetVisibility(elementId, true) end
                    elseif purpose == config.NamePurpose then
                        FuncElement:SetTextBoardText(elementId, chicken.DisplayName)
                        if Current(record) then Element:SetVisibility(elementId, true) end
                    elseif purpose == config.CountdownPurpose then
                        record.countdownElements[elementId] = true
                        RenderCountdown(record, elementId)
                    end
                end) end
                if not Current(record) then return end
                local childOk, children = pcall(function() return Element:GetChildElementsFromElement(elementId) end)
                if childOk then for _, childId in ipairs(children or {}) do Visit(childId) end
                end
            end
            Visit(record.rootId)
        end)
    end
    rt.Callback = function(_, message)
        if not Active() or type(message) ~= "table" or (message.source ~= "placement"
            and message.source ~= "hotbar" and message.source ~= "world")
            or type(message.playerId) ~= "number" or type(message.version) ~= "number" or type(message.models) ~= "table" then return end
        local key = message.source .. ":" .. string.format("%.0f", message.playerId)
        local source = rt.Sources[key]
        if source and message.version <= source.version then return end
        local nextModels = {}
        for _, model in ipairs(message.models) do
            if type(model) ~= "table" or type(model.rootId) ~= "number" or model.rootId <= 0 or model.rootId ~= math.floor(model.rootId)
                or not Decimal.FromSafeInteger(model.finalSellPrice) or nextModels[model.rootId] then return end
            if model.kind == "Egg" then
                if message.source ~= "hotbar" or type(model.eggTypeId) ~= "string" or not EggConfig(model.eggTypeId) then return end
            elseif type(model.chickenType) ~= "string" or not GameConfig.ChickenTypes[model.chickenType] then return end
            if message.source == "world" and (type(model.operation) ~= "number" or model.operation < 0
                or model.operation ~= math.floor(model.operation) or type(model.generation) ~= "number"
                or (model.countdownEndMs ~= nil and (type(model.countdownEndMs) ~= "number"
                    or model.countdownEndMs ~= model.countdownEndMs or model.countdownEndMs == math.huge))) then return end
            nextModels[model.rootId] = model
        end
        source = source or { models = {} }
        rt.Sources[key], source.version = source, message.version
        for rootId, record in pairs(source.models) do
            if not nextModels[rootId] and rt.Roots[rootId] == record then rt.Roots[rootId] = nil end
        end
        for rootId, model in pairs(nextModels) do
            local prior = source.models[rootId]
            if message.source == "world" and rt.TransferredRoots[rootId] then
                nextModels[rootId] = nil
            elseif prior and prior.finalSellPrice == model.finalSellPrice and prior.chickenType == model.chickenType
                and prior.kind == model.kind and prior.eggTypeId == model.eggTypeId
                and prior.countdownEndMs == model.countdownEndMs and prior.operation == model.operation
                and prior.generation == model.generation and rt.Roots[rootId] == prior then
                nextModels[rootId] = prior
            else
                if message.source ~= "world" then rt.TransferredRoots[rootId] = true end
                local record = { rootId = rootId, finalSellPrice = model.finalSellPrice, chickenType = model.chickenType,
                    kind = model.kind, eggTypeId = model.eggTypeId, owner = source,
                    countdownEndMs = model.countdownEndMs, operation = model.operation,
                    generation = model.generation, countdownElements = {} }
                nextModels[rootId], rt.Roots[rootId] = record, record
                Queue(record)
            end
        end
        source.models = nextModels
    end
    System:BindNotify(context.NetMsg.Messages.ChickenModelState, rt.Callback)
    context.Timers:AddLoopTimer(self.Name, 1, function()
        if not Active() or not rt.Ready then return end
        for _, record in pairs(rt.Roots) do
            if record.countdownEndMs and Current(record) then
                for elementId in pairs(record.countdownElements) do RenderCountdown(record, elementId) end
            end
        end
    end)
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        rt.Ready = true
        for _, source in pairs(rt.Sources) do for _, record in pairs(source.models) do Queue(record) end end
        System:SendToServer(context.NetMsg.Messages.ChickenModelSnapshotRequest, {})
    end)
end

function ChickenValueController:Stop(context)
    local rt = context.Services.ChickenValueController
    if not rt then return end
    rt.Active = false
    rt.Roots, rt.Sources, rt.TransferredRoots = {}, {}, {}
    System:UnbindNotify(context.NetMsg.Messages.ChickenModelState, rt.Callback)
    context.Timers:RemoveOwner(self.Name)
    context.Services.ChickenValueController = nil
end
return ChickenValueController
