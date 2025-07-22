AddonUsage = AddonUsage or CreateFrame("Frame", "AddonUsage", UIParent)
local au = AddonUsage

BINDING_HEADER_ADDONUSAGE = "AddonUsage"
au.profiling = GetCVar("scriptProfile") == "1" 
au.list = {} 
au.listCache = {} 

local sortKey = 2 -- 1=name, 2=memory, 4=cpu
local sortDir = 1 -- 0=ascending order, 1=descending order
local MAX_ADDONS_DISPLAY = 15 -- Maximum number of addons to display at once

local function sortList(e1, e2)
    if sortDir == 1 then
        if e1[sortKey] and e2[sortKey] and e1[sortKey] > e2[sortKey] then
            return true
        end
    else
        if e1[sortKey] and e2[sortKey] and e1[sortKey] < e2[sortKey] then
            return true
        end
    end
end

au:SetScript("OnEvent", function(self, event, ...)
    if self[event] then
        self[event](self, ...)
    end
end)

au:RegisterEvent("PLAYER_LOGIN")

function au:PLAYER_LOGIN()
    self:InitializeFrame()
    self:BuildList()
end

function au:BuildList()
    local list = au.list
    local cache = au.listCache
    wipe(list)
    wipe(cache)
    for i = 1, GetNumAddOns() do
        local name, _, _, enabled = GetAddOnInfo(i)
        if enabled and IsAddOnLoaded(i) then 
            tinsert(list, {name})
            cache[name] = 1
        end
    end
    UpdateAddOnMemoryUsage()
    local total = 0
    for i = 1, #list do
        local mem = GetAddOnMemoryUsage(list[i][1])
        list[i][2] = mem
        total = total + mem
    end
    for i = 1, #list do
        if total > 0 then
            list[i][3] = list[i][2] * 100 / total
        else
            list[i][3] = 0
        end
    end
    if au.profiling then -- Repeat above for CPU if profiling enabled
        UpdateAddOnCPUUsage()
        total = 0
        for i = 1, #list do
            local cpu = GetAddOnCPUUsage(list[i][1])
            list[i][4] = cpu
            total = total + cpu
        end
        for i = 1, #list do
            if total > 0 then
                list[i][5] = list[i][4] * 100 / total
            else
                list[i][5] = 0
            end
        end
    end
    table.sort(list, sortList) 
    au:UpdateList() 
end

-- Creates the UI for the addon
function au:InitializeFrame()
    SetPortraitToTexture(self.portrait, "Interface\\Icons\\INV_Gizmo_02")
    _G[self.profilingCheckButton:GetName().."Text"]:SetText("Monitor CPU usage")
    _G[self.autoCheckButton:GetName().."Text"]:SetText("Realtime updates")
    -- Set initial checkbox state
    self.profilingCheckButton:SetChecked(self.profiling)
    -- Hide CPU column if profiling is not enabled
    if not self.profiling then
        self.sortCPU:Hide()
    else
        self.sortCPU:Show()
    end
    local buttons = {}
    for i = 1, MAX_ADDONS_DISPLAY do
        local button = CreateFrame("Button", "AddonUsageButton"..i, self.scrollFrame)
        button:SetHeight(16)
        button:SetWidth(self.scrollFrame:GetWidth() - 16)      
        if i == 1 then
            button:SetPoint("TOPLEFT", self.scrollFrame, "TOPLEFT", 0, 0)
        else
            button:SetPoint("TOPLEFT", buttons[i-1], "BOTTOMLEFT", 0, -2)
        end
        button.name = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.name:SetPoint("LEFT", 2, 0)
        button.name:SetJustifyH("LEFT")
        button.name:SetWidth(130) -- Increased addon name width
        button.mem = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.mem:SetPoint("LEFT", button.name, "RIGHT", 0, 0)
        button.mem:SetJustifyH("RIGHT")
        button.mem:SetWidth(60) -- Increased to match memory column button width
        button.memPercent = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.memPercent:SetPoint("LEFT", button.mem, "RIGHT", 5, 0)
        button.memPercent:SetJustifyH("LEFT")
        button.memPercent:SetWidth(65) -- Adjusted for new layout
        button.cpu = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.cpu:SetPoint("LEFT", button.memPercent, "RIGHT", 0, 0)
        button.cpu:SetJustifyH("RIGHT")
        button.cpu:SetWidth(108) -- Reduced by ~10% from 120
        local highlight = button:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints(true)
        highlight:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
        highlight:SetBlendMode("ADD")
        highlight:SetVertexColor(0.2, 0.5, 1, 0.25)
        buttons[i] = button
    end
    self.buttons = buttons
    sortKey = self.profiling and 4 or 2
end

function au.SortOnClick(self)
    local id = self:GetID()
    if id == sortKey then
        sortDir = 1 - sortDir
    else
        sortKey = id
        sortDir = id == 1 and 0 or 1
    end
    au:BuildList()
end

function au.ButtonOnClick(self)
    if self == au.closeButton then
        au:Hide()
    elseif self == au.updateButton then
        au:BuildList()
    elseif self == au.resetButton then
        collectgarbage()
        if au.profiling then
            ResetCPUUsage()
        end
        au:BuildList()
    end
end

function au.CheckOnClick(self)
    if self == au.profilingCheckButton then
        local enable = self:GetChecked()
        StaticPopupDialogs["ADDONUSAGEPROFILE"] = {
            text = enable and "CPU monitoring causes overhead that will affect performance while it is enabled.\n\nRemember to turn it off when done testing.\n\nDo you want to turn CPU monitoring on and reload the UI?" or "Turn off CPU monitoring and reload the UI?",
            button1 = "Yes", 
            button2 = "No", 
            timeout = 30, 
            whileDead = 1, 
            showAlert = enable,
            OnAccept = function() 
                SetCVar("scriptProfile", enable and "1" or "0")
                ReloadUI()
            end,
            OnCancel = function() 
                au.profilingCheckButton:Enable() 
                au.profilingCheckButton:SetChecked(not enable)
            end
        }
        au.profilingCheckButton:Disable()
        StaticPopup_Show("ADDONUSAGEPROFILE")
    elseif self == au.autoCheckButton then
        au.timer = 0
        if self:GetChecked() then
            au:SetScript("OnUpdate", au.OnUpdate)
        else
            au:SetScript("OnUpdate", nil)
        end
    end
end

function au.Toggle()
    if au:IsVisible() then
        au:Hide()
    else
        au:Show()
        au:BuildList()
    end
end


function au:UpdateList()
    local offset = FauxScrollFrame_GetOffset(self.scrollFrame)
    for i = 1, MAX_ADDONS_DISPLAY do
        local index = i + offset
        local button = self.buttons[i]
        if index <= #self.list then
            local addon = self.list[index]
            button.name:SetText(addon[1])
            -- Convert KB to MB by dividing by 1024
            button.mem:SetText(format("%.2fMB", addon[2] / 1024))
            button.memPercent:SetText(format("(%d%%)", addon[3]))
            if self.profiling then
                -- Display both CPU time in milliseconds and percentage
                button.cpu:SetText(format("%.1fms (%d%%)", addon[4] or 0, addon[5] or 0))
                button.cpu:Show()
            else
                button.cpu:Hide()
            end
            button:Show()
        else
            button:Hide()
        end
    end
    FauxScrollFrame_Update(self.scrollFrame, #self.list, MAX_ADDONS_DISPLAY, 16)
end

function AddonUsageScrollFrame_Update()
    AddonUsage:UpdateList()
end

-- Realtime updates
function au:OnUpdate(elapsed)
    au.timer = (au.timer or 0) + elapsed
    if au.timer > 1 then
        au.timer = 0
        au:BuildList()
    end
end

SLASH_ADDONUSAGE1 = "/addonusage"
SLASH_ADDONUSAGE2 = "/usage"
SlashCmdList["ADDONUSAGE"] = function() au.Toggle() end