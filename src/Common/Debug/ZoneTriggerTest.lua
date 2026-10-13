-- 临时回归模块：确认家园区/偷取区触发盒的进入离开事件参数和查询 API。
local ZoneTriggerTest = {
    Name = "ZoneTriggerTest",
    FeatureFlag = "ZoneTriggerTest",
    Dependencies = {},
}

local HOME_TRIGGER_BOX_ID = 232
local STOLEN_TRIGGER_BOX_ID = 233

local function Traceback(errorMessage)
    if debug and debug.traceback then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

local function FormatIds(ids)
    local values = {}
    for _, id in ipairs(ids or {}) do
        values[#values + 1] = tostring(id)
    end
    return "[" .. table.concat(values, ",") .. "]"
end

local function LogArguments(eventName, ...)
    local arguments = { n = select("#", ...), ... }
    Log:PrintServerLog("[ZoneTriggerTest] 收到区域触发事件",
        "event:", eventName,
        "argumentCount:", arguments.n)
    for index = 1, arguments.n do
        local value = arguments[index]
        Log:PrintServerLog("[ZoneTriggerTest] 事件参数",
            "event:", eventName,
            "index:", index,
            "type:", type(value),
            "value:", tostring(value))
    end
end

local function LogQuerySnapshot(eventName)
    local playerIds = Character:GetAllPlayerIds() or {}
    local homePlayers = Character:GetCharactersInBoxTrigger(HOME_TRIGGER_BOX_ID) or {}
    local stolenPlayers = Character:GetCharactersInBoxTrigger(STOLEN_TRIGGER_BOX_ID) or {}

    Log:PrintServerLog("[ZoneTriggerTest] 触发盒查询快照",
        "event:", eventName,
        "homeTriggerBoxId:", HOME_TRIGGER_BOX_ID,
        "homePlayers:", FormatIds(homePlayers),
        "stolenTriggerBoxId:", STOLEN_TRIGGER_BOX_ID,
        "stolenPlayers:", FormatIds(stolenPlayers))

    for _, playerId in ipairs(playerIds) do
        Log:PrintServerLog("[ZoneTriggerTest] 玩家区域查询",
            "event:", eventName,
            "playerId:", playerId,
            "isInHome:", tostring(TriggerBox:IsCharacterInTriggerBox(
                playerId,
                HOME_TRIGGER_BOX_ID
            )),
            "isInStolen:", tostring(TriggerBox:IsCharacterInTriggerBox(
                playerId,
                STOLEN_TRIGGER_BOX_ID
            )))
    end
end

local function HandleEvent(context, eventName, ...)
    local arguments = { n = select("#", ...), ... }
    local unpackArguments = table.unpack or unpack
    local ok, errorMessage = xpcall(function()
        LogArguments(eventName, unpackArguments(arguments, 1, arguments.n))
        LogQuerySnapshot(eventName)
        context.Timers:AddFrame(ZoneTriggerTest.Name, 1, function()
            LogQuerySnapshot(eventName .. "_after_1_frame")
        end)
    end, Traceback)
    if not ok then
        context.Manager:FailModule(ZoneTriggerTest.Name,
            eventName .. " 回调失败: " .. tostring(errorMessage))
    end
end

function ZoneTriggerTest:Start(context)
    if context.Side ~= "Server" then
        return
    end

    local runtime = {
        EnterCallback = nil,
        LeaveCallback = nil,
    }
    context.Services.ZoneTriggerTest = runtime

    runtime.EnterCallback = function(...)
        HandleEvent(context, Events.ON_CHARACTER_ENTER_SIGNAL_BOX, ...)
    end
    runtime.LeaveCallback = function(...)
        HandleEvent(context, Events.ON_CHARACTER_LEAVE_SIGNAL_BOX, ...)
    end

    System:RegisterEvent(
        Events.ON_CHARACTER_ENTER_SIGNAL_BOX,
        runtime.EnterCallback
    )
    System:RegisterEvent(
        Events.ON_CHARACTER_LEAVE_SIGNAL_BOX,
        runtime.LeaveCallback
    )

    Log:PrintServerLog("[ZoneTriggerTest] 已启用",
        "homeTriggerBoxId:", HOME_TRIGGER_BOX_ID,
        "stolenTriggerBoxId:", STOLEN_TRIGGER_BOX_ID)
    LogQuerySnapshot("test_started")
end

function ZoneTriggerTest:Stop(context)
    if context.Side ~= "Server" then
        return
    end

    local runtime = context.Services.ZoneTriggerTest
    if not runtime then
        return
    end
    if runtime.EnterCallback then
        System:UnregisterEvent(
            Events.ON_CHARACTER_ENTER_SIGNAL_BOX,
            runtime.EnterCallback
        )
        runtime.EnterCallback = nil
    end
    if runtime.LeaveCallback then
        System:UnregisterEvent(
            Events.ON_CHARACTER_LEAVE_SIGNAL_BOX,
            runtime.LeaveCallback
        )
        runtime.LeaveCallback = nil
    end
end

return ZoneTriggerTest
