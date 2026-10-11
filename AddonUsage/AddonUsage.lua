local au = AddonUsage -- created in AddonUsage.xml

BINDING_HEADER_ADDONUSAGE = "Addon Usage"
BINDING_NAME_ADDONUSAGE_TOGGLE = "Toggle Addon Usage"
tinsert(UISpecialFrames, "AddonUsage") -- close with ESC

local ROW_HEIGHT = 16 -- must match the value in AddonUsage.xml OnVerticalScroll
local UPDATE_FREQUENCY = 1 -- seconds between realtime updates
local NAME_MIN_WIDTH = 120 -- narrowest the addon name column may get when resizing
local MIN_WIDTH, MIN_HEIGHT = 340, 220 -- smallest window; MIN_WIDTH grows if the columns need it
local MAX_WIDTH, MAX_HEIGHT = 900, 900

local settings -- AddonUsageSettings savedvar, set in PLAYER_LOGIN
local profiling = GetCVar("scriptProfile") == "1"
local needScan = true -- true when addons may have loaded since the last scan
local addonInfo = {} -- [addonIndex] = {name=folder, title=display name, memory=KB, cpu=ms/s}
local displayedList = {} -- addon indexes in display order
local totals = {memory = 0, cpu = 0, start = 0} -- start is GetTime() of the last reset
local sortOrder = 2 -- 1=name, 2=memory, 3=cpu; negative for reverse
local rows = {} -- list rows, created on demand as the window grows
local numRows = 0 -- rows that fit in the scrollframe
local totalsRow -- row below the list with the totals
local widthMem, widthCPU, widthPct -- widths of the number cells, measured at login
local updateTimer = 0

--[[ Local shims for newer APIs that 3.3.5a lacks (after ClassicAPI's C_Timer and WidgetAPI) ]]

-- C_Timer.After
local function After(delay, func)
    local elapsed = 0
    local timer = CreateFrame("Frame")
    timer:SetScript("OnUpdate", function(self, e)
        elapsed = elapsed + e
        if elapsed >= delay then
            self:SetScript("OnUpdate", nil)
            func()
        end
    end)
end

-- Region:SetShown
local function SetShown(region, show)
    if show then
        region:Show()
    else
        region:Hide()
    end
end

-- inserts thousands separators: 1234567.8 -> "1,234,567.8"
local function formatNumber(number, pattern)
    local text = format(pattern, number)
    if number >= 1000 then
        local count
        repeat
            text, count = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        until count == 0
    end
    return text
end

au:SetScript("OnEvent", function(self, event, ...)
    if self[event] then
        self[event](self, ...)
    end
end)

au:RegisterEvent("PLAYER_LOGIN")

function au:PLAYER_LOGIN()
    if type(AddonUsageSettings) ~= "table" then
        AddonUsageSettings = {}
    end
    settings = AddonUsageSettings
    if settings.live == nil then
        settings.live = true -- realtime updates on by default
    end
    if type(settings.sortOrder) ~= "number" then
        settings.sortOrder = profiling and 3 or 2
    end
    self:InitializeFrame()
    self:RegisterEvent("ADDON_LOADED")
    totals.start = GetTime()
    After(0.25, au.ResetUsage)
end

function au:ADDON_LOADED()
    needScan = true -- a load-on-demand addon was loaded
end

local function CreateCells(row)
    local function cell(justify)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH(justify)
        return fs
    end
    local anchor, gap = row, 0
    if profiling then
        row.cpuPct = cell("RIGHT")
        row.cpuPct:SetWidth(widthPct)
        row.cpuPct:SetPoint("RIGHT", row, "RIGHT", -3, 0)
        row.cpu = cell("RIGHT")
        row.cpu:SetWidth(widthCPU)
        row.cpu:SetPoint("RIGHT", row.cpuPct, "LEFT", -4, 0)
        anchor, gap = row.cpu, -8
    end
    row.memPct = cell("RIGHT")
    row.memPct:SetWidth(widthPct)
    if anchor == row then
        row.memPct:SetPoint("RIGHT", row, "RIGHT", -3, 0)
    else
        row.memPct:SetPoint("RIGHT", anchor, "LEFT", gap, 0)
    end
    row.mem = cell("RIGHT")
    row.mem:SetWidth(widthMem)
    row.mem:SetPoint("RIGHT", row.memPct, "LEFT", -4, 0)
    row.name = cell("LEFT")
    row.name:SetPoint("LEFT", row, "LEFT", 3, 0)
    row.name:SetPoint("RIGHT", row.mem, "LEFT", -8, 0)
end

local function CreateRow(i)
    local row = CreateFrame("Button", nil, au.scrollFrame)
    row:SetHeight(ROW_HEIGHT)
    if i == 1 then
        row:SetPoint("TOPLEFT", au.scrollFrame, "TOPLEFT", 0, 0)
        row:SetPoint("TOPRIGHT", au.scrollFrame, "TOPRIGHT", 0, 0)
    else
        row:SetPoint("TOPLEFT", rows[i-1], "BOTTOMLEFT", 0, 0)
        row:SetPoint("TOPRIGHT", rows[i-1], "BOTTOMRIGHT", 0, 0)
    end
    if i % 2 == 0 then
        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints(true)
        stripe:SetTexture(1, 1, 1, 0.06)
    end
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(true)
    highlight:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    highlight:SetBlendMode("ADD")
    highlight:SetVertexColor(0.2, 0.5, 1, 0.25)
    CreateCells(row)
    return row
end

local function SetTooltip(widget, text)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(text, nil, nil, nil, nil, 1)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", GameTooltip_Hide)
end

-- Creates the parts of the UI that depend on profiling and measured text widths
function au:InitializeFrame()
    -- measure number cells by their widest expected text, digits replaced by 0 for an even width
    local measure = self:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
    local function textWidth(text)
        measure:SetText(text)
        return ceil(measure:GetStringWidth())
    end
    widthPct = textWidth("100%")
    -- a column is its number cell, the percent cell and 12px padding; it must also fit its header
    widthMem = max(textWidth("000,000.0"), textWidth(self.sortMemory:GetText()) + 14 - widthPct - 12)
    widthCPU = max(textWidth("0,000.00"), textWidth(self.sortCPU:GetText()) + 14 - widthPct - 12)
    measure:Hide()

    local memColumn = widthMem + widthPct + 12
    local cpuColumn = profiling and widthCPU + widthPct + 12 or 0
    self.sortMemory:SetWidth(memColumn)
    self.sortCPU:SetWidth(cpuColumn)
    local nameText = self.sortAddon:GetFontString()
    nameText:ClearAllPoints()
    nameText:SetPoint("LEFT", 7, 0)
    if not profiling then
        self.sortCPU:Hide()
        self.sortMemory:ClearAllPoints()
        self.sortMemory:SetPoint("TOPRIGHT", self, "TOPRIGHT", -30, -30)
    end

    totalsRow = CreateFrame("Frame", nil, self)
    totalsRow:SetHeight(ROW_HEIGHT)
    totalsRow:SetPoint("TOPLEFT", self.scrollFrame, "BOTTOMLEFT", 0, -4)
    totalsRow:SetPoint("TOPRIGHT", self.scrollFrame, "BOTTOMRIGHT", 0, -4)
    local bg = totalsRow:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetTexture(1, 1, 1, 0.1)
    CreateCells(totalsRow)
    totalsRow.name:SetText("Total")

    -- thin lines between the columns, from below the headers to the bottom of the totals
    local dividers = CreateFrame("Frame", nil, self)
    dividers:SetPoint("TOPLEFT", self.sortMemory, "BOTTOMLEFT", 0, -1)
    dividers:SetPoint("BOTTOMRIGHT", totalsRow, "BOTTOMRIGHT", 0, 0)
    dividers:SetFrameLevel(self:GetFrameLevel() + 5)
    local memLine = dividers:CreateTexture(nil, "OVERLAY")
    memLine:SetTexture(0.3, 0.3, 0.3)
    memLine:SetWidth(1)
    memLine:SetPoint("TOPLEFT")
    memLine:SetPoint("BOTTOMLEFT")
    if profiling then
        local cpuLine = dividers:CreateTexture(nil, "OVERLAY")
        cpuLine:SetTexture(0.3, 0.3, 0.3)
        cpuLine:SetWidth(1)
        cpuLine:SetPoint("TOPRIGHT", -cpuColumn, 0)
        cpuLine:SetPoint("BOTTOMRIGHT", -cpuColumn, 0)
    end

    _G[self.profilingCheckButton:GetName().."Text"]:SetText("CPU Usage")
    _G[self.autoCheckButton:GetName().."Text"]:SetText("Live")
    self.profilingCheckButton:SetChecked(profiling)
    self.autoCheckButton:SetChecked(settings.live)
    SetTooltip(self.profilingCheckButton, "Monitor CPU usage (reloads the UI).\nCauses overhead, turn it off when done testing.")
    SetTooltip(self.autoCheckButton, "Update every second while the window is open.")
    SetTooltip(self.resetButton, "Collect garbage and reset CPU usage.")

    -- 38 is the space left and right of the columns
    local minWidth = max(MIN_WIDTH, 38 + NAME_MIN_WIDTH + memColumn + cpuColumn)
    self:SetMinResize(minWidth, MIN_HEIGHT)
    self:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    if settings.width and settings.height then
        -- the saved size may predate the cpu column being turned on
        self:SetWidth(max(settings.width, minWidth))
        self:SetHeight(max(settings.height, MIN_HEIGHT))
    end

    self:SetScript("OnShow", self.OnShow)
    self:SetScript("OnSizeChanged", self.OnSizeChanged)
end

function au:OnShow()
    au:UpdateLive()
    au:Update()
end

function au:OnSizeChanged()
    if au:IsVisible() then
        au:UpdateRowCount()
    end
end

function au:StopResizing()
    au:StopMovingOrSizing()
    settings.width, settings.height = au:GetWidth(), au:GetHeight()
end

-- Creates rows until they fill the scrollframe (only valid while the window is shown)
function au:UpdateRowCount()
    numRows = max(1, floor(au.scrollFrame:GetHeight() / ROW_HEIGHT))
    for i = #rows + 1, numRows do
        rows[i] = CreateRow(i)
    end
    -- the window grew past the end of the list: scroll back so no empty rows show
    local maxOffset = max(0, #displayedList - numRows)
    if FauxScrollFrame_GetOffset(au.scrollFrame) > maxOffset then
        FauxScrollFrame_SetOffset(au.scrollFrame, maxOffset)
        _G[au.scrollFrame:GetName().."ScrollBar"]:SetValue(maxOffset * ROW_HEIGHT)
    end
    au:UpdateList()
end

function au:ResetUsage()
    totals.start = GetTime()
    if profiling then
        ResetCPUUsage()
    end
    collectgarbage("collect")
    au:Update()
end

-- Refreshes addonInfo and totals. Tables are reused so realtime updates don't create garbage.
function au:GatherUsage()
    if needScan then
        for i = 1, GetNumAddOns() do
            -- IsAddOnLoaded alone: an addon unchecked without /reload is still loaded and using memory
            if not addonInfo[i] and IsAddOnLoaded(i) then
                local name, title = GetAddOnInfo(i)
                title = (title or name):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") -- strip color codes
                addonInfo[i] = {name = name, title = title}
            end
        end
        needScan = false
    end
    UpdateAddOnMemoryUsage()
    if profiling then
        UpdateAddOnCPUUsage()
    end
    -- CPU is shown in ms per second since the last reset, so different time spans compare
    local elapsed = max(GetTime() - totals.start, 0.01)
    totals.memory, totals.cpu = 0, 0
    for _, info in pairs(addonInfo) do
        info.memory = GetAddOnMemoryUsage(info.name)
        totals.memory = totals.memory + info.memory
        if profiling then
            info.cpu = GetAddOnCPUUsage(info.name) / elapsed
            totals.cpu = totals.cpu + info.cpu
        end
    end
end

-- Sorts by the chosen column, then by title and folder name so equal values keep their order
local function sortList(e1, e2)
    local info1, info2 = addonInfo[e1], addonInfo[e2]
    local key = abs(sortOrder)
    if key == 2 and info1.memory ~= info2.memory then
        if sortOrder > 0 then
            return info1.memory > info2.memory
        end
        return info1.memory < info2.memory
    elseif key == 3 and info1.cpu ~= info2.cpu then
        if sortOrder > 0 then
            return info1.cpu > info2.cpu
        end
        return info1.cpu < info2.cpu
    end
    if info1.title ~= info2.title then
        if sortOrder > 0 then
            return info1.title < info2.title
        end
        return info1.title > info2.title
    end
    if sortOrder > 0 then
        return info1.name < info2.name
    end
    return info1.name > info2.name
end

function au:Update()
    if not au:IsVisible() then
        return
    end
    au:GatherUsage()
    wipe(displayedList)
    for index in pairs(addonInfo) do
        tinsert(displayedList, index)
    end
    sortOrder = settings.sortOrder
    if abs(sortOrder) == 3 and not profiling then
        sortOrder = 2
    end
    table.sort(displayedList, sortList)
    au.sortAddon:SetText(format("Addons (%d)", #displayedList))
    totalsRow.mem:SetText(formatNumber(totals.memory, "%.1f"))
    if profiling then
        totalsRow.cpu:SetText(formatNumber(totals.cpu, "%.2f"))
    end
    au:UpdateRowCount()
end

function au:UpdateList()
    local offset = FauxScrollFrame_GetOffset(au.scrollFrame)
    for i = 1, #rows do
        local row = rows[i]
        local info = addonInfo[displayedList[i + offset]]
        if i <= numRows and info then
            row.name:SetText(info.title)
            row.mem:SetText(formatNumber(info.memory, "%.1f"))
            row.memPct:SetText(format("%d%%", totals.memory > 0 and info.memory * 100 / totals.memory or 0))
            if profiling then
                row.cpu:SetText(formatNumber(info.cpu, "%.2f"))
                row.cpuPct:SetText(format("%d%%", totals.cpu > 0 and info.cpu * 100 / totals.cpu or 0))
            end
            row:Show()
        else
            row:Hide()
        end
    end
    FauxScrollFrame_Update(au.scrollFrame, #displayedList, numRows, ROW_HEIGHT)
end

function AddonUsageScrollFrame_Update()
    au:UpdateList()
end

-- Clicking the active column reverses the order
function au.HeaderOnClick(self)
    local id = self:GetID()
    if id == abs(sortOrder) then
        settings.sortOrder = -sortOrder
    else
        settings.sortOrder = id
    end
    au:Update()
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
            hideOnEscape = 1,
            showAlert = enable,
            OnAccept = function()
                SetCVar("scriptProfile", enable and "1" or "0")
                ReloadUI()
            end,
            -- OnHide instead of OnCancel: also fires when another popup displaces this one
            OnHide = function()
                au.profilingCheckButton:Enable()
                au.profilingCheckButton:SetChecked(profiling)
            end
        }
        au.profilingCheckButton:Disable()
        StaticPopup_Show("ADDONUSAGEPROFILE")
    elseif self == au.autoCheckButton then
        settings.live = self:GetChecked() and true or false
        au:UpdateLive()
        au:Update()
    end
end

-- Realtime updates; OnUpdate only runs while the window is shown
local function OnUpdate(self, elapsed)
    updateTimer = updateTimer + elapsed
    if updateTimer > UPDATE_FREQUENCY then
        updateTimer = 0
        au:Update()
    end
end

function au:UpdateLive()
    updateTimer = 0
    au:SetScript("OnUpdate", settings.live and OnUpdate or nil)
end

function au.Toggle()
    SetShown(au, not au:IsVisible())
end

SLASH_ADDONUSAGE1 = "/addonusage"
SLASH_ADDONUSAGE2 = "/usage"
SlashCmdList["ADDONUSAGE"] = au.Toggle
