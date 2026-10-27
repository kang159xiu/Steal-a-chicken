local GameConfig = require "Common.Config.GameConfig"
local PromptController = { Name = "PromptController", FeatureFlag = "Prompt", Dependencies = {} }
local function Integer(n) return type(n) == "number" and n > 0 and n < math.huge and n == math.floor(n) end
function PromptController:ValidateConfig()
    local c = GameConfig.Prompt
    if not c or not Integer(c.TemplateId) or not Integer(c.TextId) or c.TemplateId == c.TextId
        or c.X ~= -180 or c.Y ~= -430 or c.VisibleSeconds ~= 3 or c.HideSeconds ~= 1 or c.AnimationIndex ~= 1 then
        return false, { "统一提示UI配置无效" }
    end
    return true
end
function PromptController:Start(context)
    if context.Side ~= "Client" then return end
    local c = GameConfig.Prompt
    local rt = { Active = true, Ready = false, Copies = {} }
    context.Services.PromptController = rt
    local function Active() return rt.Active and context.Services.PromptController == rt end
    local function Call(stage, callback)
        local ok, value = pcall(callback)
        if not ok then Log:PrintError("[PromptController] 提示UI失败，不重试", stage, tostring(value)) end
        return ok, value
    end
    local function Current(copy) return Active() and rt.Copies[copy.uid] == copy end
    local function RemoveTimer(copy, field)
        if copy[field] then context.Timers:Remove(copy[field]); copy[field] = nil end
    end
    local function Destroy(copy)
        if rt.Copies[copy.uid] ~= copy then return end
        rt.Copies[copy.uid] = nil; copy.phase = "destroyed"; copy.epoch = copy.epoch + 1
        if rt.Current == copy then rt.Current = nil end
        for _, field in ipairs({ "landing", "display", "hide" }) do RemoveTimer(copy, field) end
        Call("hide:" .. copy.uid, function() UI:SetVisibility({ copy.uid }, false) end)
        Call("destroy:" .. copy.uid, function() UI:OnShow({ copy.uid }, false) end)
    end
    local function Hide(copy)
        if not Current(copy) or copy.phase == "hiding" then return end
        if copy.phase ~= "shown" then Destroy(copy); return end
        copy.phase = "hiding"; copy.epoch = copy.epoch + 1
        if rt.Current == copy then rt.Current = nil end
        RemoveTimer(copy, "display")
        local epoch = copy.epoch
        Call("animation:" .. copy.uid, function() UI:PlayUIAnimation(copy.uid, c.AnimationIndex, 0) end)
        copy.hide = context.Timers:AddTimer(self.Name, c.HideSeconds, function()
            if Current(copy) and copy.epoch == epoch and copy.phase == "hiding" then copy.hide = nil; Destroy(copy) end
        end)
    end
    -- 按源文字到组模板的实际名称路径映射；不假定子级顺序或模板ID等于副本UID。
    local function UniqueChild(parent, name)
        local found
        local children = UI:GetAllChildren(parent)
        if type(children) ~= "table" then error("提示子控件列表无效") end
        for _, child in ipairs(children) do
            if UI:GetUIName(child) == name then
                if found then error("提示文字路径存在同名子控件: " .. name) end
                found = child
            end
        end
        local child = UI:FindChildWithName(parent, name)
        if not Integer(child) or child ~= found then error("提示文字路径不可用: " .. name) end
        return child
    end
    local function ReadPath()
        local path, child, seen = {}, c.TextId, {}
        while child ~= c.TemplateId do
            if seen[child] or #path >= 4 then error("提示文字不在模板四层组内") end
            seen[child] = true
            local name, parent = UI:GetUIName(child), UI:GetParent(child)
            if type(name) ~= "string" or name == "" or not Integer(parent) or UniqueChild(parent, name) ~= child then
                error("提示源文字层级无效")
            end
            table.insert(path, 1, name); child = parent
        end
        return path
    end
    function rt:Show(text)
        if not Active() or type(text) ~= "string" or text == "" then return false end
        if not self.Ready then self.QueuedText = text; return false end
        local previous = self.Current
        if previous and previous.text == text then return false end
        if previous then Hide(previous) end
        local ok, uid = Call("duplicate", function()
            local value = UI:DuplicateWidget(c.TemplateId, c.X, c.Y)
            if not Integer(value) or value == c.TemplateId or self.Copies[value] then error("提示复制未返回独立UID") end
            return value
        end)
        if not ok then return false end
        local copy = { uid = uid, text = text, phase = "pending", epoch = 1 }
        self.Copies[uid], self.Current = copy, copy
        local epoch = copy.epoch
        copy.landing = context.Timers:AddFrame(PromptController.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Current(copy) or copy.epoch ~= epoch or self.Current ~= copy then return end
            copy.landing = nil
            local landed = Call("show:" .. uid, function()
                local textUid = uid
                for _, name in ipairs(self.TextPath) do textUid = UniqueChild(textUid, name) end
                if textUid == c.TextId then error("提示副本文字返回源控件") end
                UI:SetText({ textUid }, text, false)
                UI:SetTransparency({ uid }, 1)
                UI:SetVisibility({ uid }, true)
            end)
            if not landed then Destroy(copy); return end
            copy.phase = "shown"
            copy.display = context.Timers:AddTimer(PromptController.Name, c.VisibleSeconds, function()
                if Current(copy) and copy.epoch == epoch and copy.phase == "shown" then copy.display = nil; Hide(copy) end
            end)
        end)
        return true
    end
    context.Timers:AddTimer(self.Name, GameConfig.Runtime.ClientSnapshotRequestDelaySeconds, function()
        if not Active() then return end
        local ok = Call("source", function()
            UI:SetTransparency({ c.TemplateId }, 0)
            UI:SetVisibility({ c.TemplateId }, true)
        end)
        if not ok then return end
        context.Timers:AddFrame(self.Name, GameConfig.Runtime.EngineOperationDelayFrames, function()
            if not Active() then return end
            local found, path = Call("source_text_path", ReadPath)
            if not found then return end
            rt.TextPath, rt.Ready = path, true
            local queued = rt.QueuedText; rt.QueuedText = nil
            if queued then rt:Show(queued) end
        end)
    end)
    rt.Cleanup = function()
        rt.Active = false; rt.QueuedText = nil
        context.Timers:RemoveOwner(self.Name)
        local copies = {}; for _, copy in pairs(rt.Copies) do copies[#copies + 1] = copy end
        for _, copy in ipairs(copies) do Destroy(copy) end
    end
end
function PromptController:Stop(context)
    local rt = context.Services.PromptController
    if not rt then return end
    rt.Cleanup(); context.Services.PromptController = nil
end
return PromptController
