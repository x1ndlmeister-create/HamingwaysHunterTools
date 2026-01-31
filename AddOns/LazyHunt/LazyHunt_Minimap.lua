-- LazyHunt Minimap Button and Options
-- Separated for better organization

local minimapButton = nil
local optionsFrame = nil
local burstToggleButton = nil
local multiShotToggleButton = nil

-- Create burst toggle button
local function CreateBurstToggleButton()
    if burstToggleButton then return end
    
    burstToggleButton = CreateFrame("Button", "LazyHuntBurstToggle", UIParent)
    burstToggleButton:SetWidth(80)
    burstToggleButton:SetHeight(30)
    burstToggleButton:SetPoint("CENTER", UIParent, "CENTER", LazyHuntDB.burstButtonX or 0, LazyHuntDB.burstButtonY or 200)
    
    burstToggleButton:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    
    local text = burstToggleButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", 0, 0)
    burstToggleButton.text = text
    
    -- Update button appearance
    local function UpdateButtonAppearance()
        if LazyHuntDB.burstEnabled then
            burstToggleButton.text:SetText("Burst: ON")
            burstToggleButton.text:SetTextColor(0, 1, 0)
        else
            burstToggleButton.text:SetText("Burst: OFF")
            burstToggleButton.text:SetTextColor(1, 0, 0)
        end
    end
    
    burstToggleButton:SetScript("OnClick", function()
        LazyHuntDB.burstEnabled = not LazyHuntDB.burstEnabled
        UpdateButtonAppearance()
        -- Update checkbox in options if open
        if LazyHuntBurstCheckbox then
            LazyHuntBurstCheckbox:SetChecked(LazyHuntDB.burstEnabled)
        end
    end)
    
    burstToggleButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(burstToggleButton, "ANCHOR_TOP")
        GameTooltip:SetText("Burst Mode", 1, 1, 1)
        GameTooltip:AddLine("Linksklick: Ein/Aus", 0, 1, 0)
        GameTooltip:AddLine("Rechtsklick + Ziehen: Verschieben", 0, 1, 0)
        GameTooltip:Show()
    end)
    
    burstToggleButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    burstToggleButton:SetMovable(true)
    burstToggleButton:RegisterForDrag("RightButton")
    burstToggleButton:SetScript("OnDragStart", function()
        burstToggleButton:StartMoving()
    end)
    
    burstToggleButton:SetScript("OnDragStop", function()
        burstToggleButton:StopMovingOrSizing()
        local x, y = burstToggleButton:GetCenter()
        local screenW, screenH = GetScreenWidth(), GetScreenHeight()
        LazyHuntDB.burstButtonX = x - (screenW / 2)
        LazyHuntDB.burstButtonY = y - (screenH / 2)
    end)
    
    UpdateButtonAppearance()
    burstToggleButton:Show()
end

-- Create Multi-Shot toggle button
local function CreateMultiShotToggleButton()
    if multiShotToggleButton then return end
    
    multiShotToggleButton = CreateFrame("Button", "LazyHuntMultiToggle", UIParent)
    multiShotToggleButton:SetWidth(80)
    multiShotToggleButton:SetHeight(30)
    multiShotToggleButton:SetPoint("CENTER", UIParent, "CENTER", LazyHuntDB.multiButtonX or 0, LazyHuntDB.multiButtonY or 160)
    
    multiShotToggleButton:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    
    local text = multiShotToggleButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("CENTER", 0, 0)
    multiShotToggleButton.text = text
    
    -- Update button appearance
    local function UpdateButtonAppearance()
        if LazyHuntDB.multiShotEnabled then
            multiShotToggleButton.text:SetText("Multi: ON")
            multiShotToggleButton.text:SetTextColor(0, 1, 0)
        else
            multiShotToggleButton.text:SetText("Multi: OFF")
            multiShotToggleButton.text:SetTextColor(1, 0, 0)
        end
    end
    
    multiShotToggleButton:SetScript("OnClick", function()
        LazyHuntDB.multiShotEnabled = not LazyHuntDB.multiShotEnabled
        UpdateButtonAppearance()
    end)
    
    multiShotToggleButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(multiShotToggleButton, "ANCHOR_TOP")
        GameTooltip:SetText("Multi-Shot Rotation", 1, 1, 1)
        GameTooltip:AddLine("ON: Steady + Multi-Shot", 0, 1, 0)
        GameTooltip:AddLine("OFF: Nur Steady Shot", 1, 0, 0)
        GameTooltip:AddLine("Rechtsklick + Ziehen: Verschieben", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    
    multiShotToggleButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    multiShotToggleButton:SetMovable(true)
    multiShotToggleButton:RegisterForDrag("RightButton")
    multiShotToggleButton:SetScript("OnDragStart", function()
        multiShotToggleButton:StartMoving()
    end)
    
    multiShotToggleButton:SetScript("OnDragStop", function()
        multiShotToggleButton:StopMovingOrSizing()
        local x, y = multiShotToggleButton:GetCenter()
        local screenW, screenH = GetScreenWidth(), GetScreenHeight()
        LazyHuntDB.multiButtonX = x - (screenW / 2)
        LazyHuntDB.multiButtonY = y - (screenH / 2)
    end)
    
    UpdateButtonAppearance()
    multiShotToggleButton:Show()
end

-- Create minimap button
local function CreateMinimapButton()
    if minimapButton then return end
    
    minimapButton = CreateFrame("Button", "LazyHuntMinimapButton", Minimap)
    minimapButton:SetWidth(32)
    minimapButton:SetHeight(32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    
    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\Ability_Hunter_RunningShot")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("CENTER", 0, 1)
    minimapButton.icon = icon
    
    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetWidth(52)
    overlay:SetHeight(52)
    overlay:SetPoint("TOPLEFT", 0, 0)
    
    minimapButton:SetScript("OnClick", function()
        if optionsFrame and optionsFrame:IsShown() then
            optionsFrame:Hide()
        else
            if not optionsFrame then
                CreateOptionsFrame()
            end
            optionsFrame:Show()
        end
    end)
    
    minimapButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(minimapButton, "ANCHOR_LEFT")
        GameTooltip:SetText("LazyHunt", 1, 1, 1)
        GameTooltip:AddLine("Linksklick: Optionen", 0, 1, 0)
        GameTooltip:Show()
    end)
    
    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    minimapButton:SetScript("OnDragStart", function()
        minimapButton.isMoving = true
    end)
    
    minimapButton:SetScript("OnDragStop", function()
        minimapButton.isMoving = false
        local xpos, ypos = minimapButton:GetCenter()
        local xmin, ymin = Minimap:GetCenter()
        local angle = math.deg(math.atan2(ypos - ymin, xpos - xmin))
        LazyHuntDB.minimapPos = angle
        UpdateMinimapButtonPosition()
    end)
    
    minimapButton:SetScript("OnUpdate", function()
        -- Throttle to 20 FPS while dragging
        if (this.tick or 0) > GetTime() then return else this.tick = GetTime() + 0.05 end
        
        if minimapButton.isMoving then
            UpdateMinimapButtonPosition()
        end
    end)
    
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:RegisterForClicks("LeftButtonUp")
    
    UpdateMinimapButtonPosition()
end

function UpdateMinimapButtonPosition()
    if not minimapButton then return end
    
    local angle = math.rad(LazyHuntDB.minimapPos or 225)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Create options frame
function CreateOptionsFrame()
    if optionsFrame then return end
    
    optionsFrame = CreateFrame("Frame", "LazyHuntOptionsFrame", UIParent)
    optionsFrame:SetWidth(420)
    optionsFrame:SetHeight(520)
    optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    optionsFrame:SetFrameStrata("DIALOG")  -- Show above other frames
    optionsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", function() optionsFrame:StartMoving() end)
    optionsFrame:SetScript("OnDragStop", function() optionsFrame:StopMovingOrSizing() end)
    optionsFrame:Hide()
    
    -- Title
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("LazyHunt Optionen")
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    
    -- Burst Mode Checkbox
    local burstCheckbox = CreateFrame("CheckButton", "LazyHuntBurstCheckbox", optionsFrame, "UICheckButtonTemplate")
    burstCheckbox:SetPoint("TOPLEFT", 30, -70)
    burstCheckbox:SetWidth(24)
    burstCheckbox:SetHeight(24)
    burstCheckbox:SetChecked(LazyHuntDB.burstEnabled)
    
    local burstLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    burstLabel:SetPoint("LEFT", burstCheckbox, "RIGHT", 5, 0)
    burstLabel:SetText("Burst Mode aktivieren")
    
    burstCheckbox:SetScript("OnClick", function()
        LazyHuntDB.burstEnabled = burstCheckbox:GetChecked()
    end)
    
    -- Sunder Armor Stacks Label
    local sunderLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sunderLabel:SetPoint("TOPLEFT", 30, -110)
    sunderLabel:SetText("Burst nach X Sunder Armor Stacks (0 = ignore):")
    
    -- Sunder Armor Stacks Slider
    local sunderSlider = CreateFrame("Slider", "LazyHuntSunderSlider", optionsFrame)
    sunderSlider:SetPoint("TOPLEFT", 30, -135)
    sunderSlider:SetWidth(360)
    sunderSlider:SetHeight(20)
    sunderSlider:SetOrientation("HORIZONTAL")
    sunderSlider:SetMinMaxValues(0, 5)
    sunderSlider:SetValueStep(1)
    sunderSlider:SetValue(LazyHuntDB.burstSunderStacks or 0)
    
    sunderSlider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 }
    })
    
    local sunderThumb = sunderSlider:CreateTexture(nil, "OVERLAY")
    sunderThumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    sunderThumb:SetWidth(32)
    sunderThumb:SetHeight(32)
    sunderSlider:SetThumbTexture(sunderThumb)
    
    local sunderValue = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sunderValue:SetPoint("TOP", sunderSlider, "BOTTOM", 0, -5)
    sunderValue:SetText(string.format("%d Stacks", LazyHuntDB.burstSunderStacks or 0))
    
    sunderSlider:SetScript("OnValueChanged", function()
        local val = sunderSlider:GetValue()
        LazyHuntDB.burstSunderStacks = val
        sunderValue:SetText(string.format("%d Stacks", val))
    end)
    
    -- Wait for Burst CD Checkbox
    local waitCDCheckbox = CreateFrame("CheckButton", "LazyHuntWaitCDCheckbox", optionsFrame, "UICheckButtonTemplate")
    waitCDCheckbox:SetPoint("TOPLEFT", 30, -180)
    waitCDCheckbox:SetWidth(24)
    waitCDCheckbox:SetHeight(24)
    waitCDCheckbox:SetChecked(LazyHuntDB.waitForBurstCD or false)
    
    local waitCDLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    waitCDLabel:SetPoint("LEFT", waitCDCheckbox, "RIGHT", 5, 0)
    waitCDLabel:SetText("Warten wenn CDs nicht zusammen ready")
    
    waitCDCheckbox:SetScript("OnClick", function()
        LazyHuntDB.waitForBurstCD = waitCDCheckbox:GetChecked()
    end)
    
    -- CD Threshold Label
    local cdThresholdLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cdThresholdLabel:SetPoint("TOPLEFT", 30, -220)
    cdThresholdLabel:SetText("Max Wartezeit wenn CD fast bereit (0-30 Sek):")
    
    -- CD Threshold Slider
    local cdThresholdSlider = CreateFrame("Slider", "LazyHuntCDThresholdSlider", optionsFrame)
    cdThresholdSlider:SetPoint("TOPLEFT", 30, -245)
    cdThresholdSlider:SetWidth(360)
    cdThresholdSlider:SetHeight(20)
    cdThresholdSlider:SetOrientation("HORIZONTAL")
    cdThresholdSlider:SetMinMaxValues(0, 30)
    cdThresholdSlider:SetValueStep(1)
    cdThresholdSlider:SetValue(LazyHuntDB.burstCDThreshold or 5)
    
    cdThresholdSlider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 }
    })
    
    local cdThresholdThumb = cdThresholdSlider:CreateTexture(nil, "OVERLAY")
    cdThresholdThumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    cdThresholdThumb:SetWidth(32)
    cdThresholdThumb:SetHeight(32)
    cdThresholdSlider:SetThumbTexture(cdThresholdThumb)
    
    local cdThresholdValue = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cdThresholdValue:SetPoint("TOP", cdThresholdSlider, "BOTTOM", 0, -5)
    cdThresholdValue:SetText(string.format("%d Sekunden", LazyHuntDB.burstCDThreshold or 5))
    
    cdThresholdSlider:SetScript("OnValueChanged", function()
        local val = cdThresholdSlider:GetValue()
        LazyHuntDB.burstCDThreshold = val
        cdThresholdValue:SetText(string.format("%d Sekunden", val))
    end)
    
    -- AS Delay Label
    local delayLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    delayLabel:SetPoint("TOPLEFT", 30, -300)
    delayLabel:SetText("Max erlaubte Auto Shot Verzoegerung:")
    
    -- AS Delay Slider
    local delaySlider = CreateFrame("Slider", "LazyHuntDelaySlider", optionsFrame)
    delaySlider:SetPoint("TOPLEFT", 30, -330)
    delaySlider:SetWidth(360)
    delaySlider:SetHeight(20)
    delaySlider:SetOrientation("HORIZONTAL")
    delaySlider:SetMinMaxValues(0, 0.5)
    delaySlider:SetValueStep(0.05)
    delaySlider:SetValue(LazyHuntDB.allowedASDelay)
    
    delaySlider:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 }
    })
    
    local thumb = delaySlider:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    thumb:SetWidth(32)
    thumb:SetHeight(32)
    delaySlider:SetThumbTexture(thumb)
    
    local delayValue = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    delayValue:SetPoint("TOP", delaySlider, "BOTTOM", 0, -5)
    delayValue:SetText(string.format("%.2f Sekunden", LazyHuntDB.allowedASDelay))
    
    delaySlider:SetScript("OnValueChanged", function()
        local val = delaySlider:GetValue()
        LazyHuntDB.allowedASDelay = val
        delayValue:SetText(string.format("%.2f Sekunden", val))
    end)
    
    -- Log display (smaller font)
    local logLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    logLabel:SetPoint("TOPLEFT", 30, -380)
    logLabel:SetText("Debug-Log:")
    logLabel:SetTextColor(1, 1, 1)
    
    local logDisplay = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    logDisplay:SetPoint("TOPLEFT", 30, -400)
    logDisplay:SetWidth(360)
    logDisplay:SetHeight(90)
    logDisplay:SetJustifyH("LEFT")
    logDisplay:SetJustifyV("TOP")
    logDisplay:SetTextColor(1, 0.8, 0)
    logDisplay:SetText("Warte auf Rotation-Events...")
    
    -- Store reference globally so LazyHunt.lua can update it
    optionsFrame.logDisplay = logDisplay
end

-- Initialize on addon loaded
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "LazyHunt" then
        -- Initialize saved variables
        LazyHuntDB = LazyHuntDB or {
            minimapPos = 225,
            allowedASDelay = 0.0,
            burstEnabled = false,
            burstSunderStacks = 0,
            waitForBurstCD = false,
            burstCDThreshold = 5,
            burstButtonX = 0,
            burstButtonY = 200,
            multiShotEnabled = true,
            multiButtonX = 0,
            multiButtonY = 160,
        }
        
        -- Create minimap button
        CreateMinimapButton()
        
        -- Create burst toggle button
        CreateBurstToggleButton()
        
        -- Create Multi-Shot toggle button
        CreateMultiShotToggleButton()
        
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00LazyHunt geladen! Minimap-Icon zum Konfigurieren anklicken.|r")
    end
end)
