-- HamingwaysHunterTools_Warnings.lua
-- Trueshot Aura and Aspect Tracker module
-- Uses shared HamingwaysHunterToolsDB

-- Module frame
local WarningsModule = CreateFrame("Frame", "HamingwaysHunterToolsWarningsModule")

-- Module variables (global for config access)
HHT_WarningFrame = nil
HHT_TrueshotIcon = nil
HHT_AspectIcon = nil
local availableAspects = {}
local DEFAULT_WARNING_ICON_SIZE = 40

-- Get correct texture path for each aspect
local function GetAspectTexture(aspectName)
    if not aspectName then return "Interface/Icons/Ability_Hunter_AspectOfTheHawk" end
    
    if string.find(aspectName, "Hawk") then
        return "Interface/Icons/Spell_Nature_RavenForm"
    elseif string.find(aspectName, "Monkey") then
        return "Interface/Icons/Ability_Hunter_AspectOfTheMonkey"
    elseif string.find(aspectName, "Cheetah") then
        return "Interface/Icons/Ability_Mount_JungleTiger"
    elseif string.find(aspectName, "Pack") then
        return "Interface/Icons/Ability_Mount_WhiteTiger"
    elseif string.find(aspectName, "Wild") then
        return "Interface/Icons/Spell_Nature_ProtectionformNature"
    elseif string.find(aspectName, "Beast") then
        return "Interface/Icons/Ability_Mount_Pinktiger"
    end
    
    return "Interface/Icons/Ability_Hunter_AspectOfTheHawk"  -- fallback
end

-- ============ Helper Functions ============
local function ScanAvailableAspects()
    availableAspects = {}
    local i = 1
    while true do
        local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        if spellName == "Aspect of the Hawk" or spellName == "Aspect of the Monkey" or 
           spellName == "Aspect of the Cheetah" or spellName == "Aspect of the Pack" or 
           spellName == "Aspect of the Wild" or spellName == "Aspect of the Beast" then
            table.insert(availableAspects, spellName)
        end
        i = i + 1
    end
end

local function HasTrueshotAura()
    local i = 1
    while UnitBuff("player", i) do
        local buffTexture = UnitBuff("player", i)
        if buffTexture and string.find(buffTexture, "Ability_TrueShot") then
            return true
        end
        i = i + 1
    end
    return false
end

local function GetCurrentAspect()
    local i = 1
    while UnitBuff("player", i) do
        local buffTexture = UnitBuff("player", i)
        if buffTexture then
            local lowerTexture = string.lower(buffTexture)
            -- Check for various aspect texture patterns
            if string.find(lowerTexture, "ravenform") or string.find(lowerTexture, "hawk") then 
                return "Aspect of the Hawk"
            elseif string.find(lowerTexture, "monkey") then 
                return "Aspect of the Monkey"
            elseif string.find(lowerTexture, "cheetah") then 
                return "Aspect of the Cheetah"
            elseif string.find(lowerTexture, "pack") then 
                return "Aspect of the Pack"
            elseif string.find(lowerTexture, "wild") then 
                return "Aspect of the Wild"
            elseif string.find(lowerTexture, "beast") then 
                return "Aspect of the Beast"
            end
        end
        i = i + 1
    end
    return nil
end

-- Global blink handler (runs on WarningsModule frame)
local blinkingIcons = {}
local blinkUpdateActive = false

local function StartBlinking(icon)
    if not icon then return end
    blinkingIcons[icon] = true
    
    -- Enable OnUpdate only when needed
    if not blinkUpdateActive then
        blinkUpdateActive = true
        WarningsModule:SetScript("OnUpdate", function()
            local time = GetTime()
            local alpha = (math.sin(time * 3) + 1) / 2
            local hasBlinking = false
            for blinkIcon, _ in pairs(blinkingIcons) do
                if blinkIcon then
                    blinkIcon:SetAlpha(0.3 + alpha * 0.7)
                    hasBlinking = true
                end
            end
            -- Disable OnUpdate if no icons are blinking
            if not hasBlinking then
                WarningsModule:SetScript("OnUpdate", nil)
                blinkUpdateActive = false
            end
        end)
    end
end

local function StopBlinking(icon)
    if not icon then return end
    blinkingIcons[icon] = nil
    -- Don't set alpha here - let UpdateWarningDisplay control visibility
    
    -- Check if we can disable OnUpdate
    local hasBlinking = false
    for _, _ in pairs(blinkingIcons) do
        hasBlinking = true
        break
    end
    if not hasBlinking and blinkUpdateActive then
        WarningsModule:SetScript("OnUpdate", nil)
        blinkUpdateActive = false
    end
end

-- ============ Update Display ============
function HHT_UpdateWarningDisplay()
    if not HHT_WarningFrame or not HamingwaysHunterToolsDB then return end
    
    local db = HamingwaysHunterToolsDB
    local showTrueshot = db.showTrueshotWarning
    local showAspect = db.showAspectWarning
    
    local anyIconVisible = false
    
    -- Trueshot Icon - only show when feature enabled AND missing
    if HHT_TrueshotIcon then
        if showTrueshot then
            local hasTrueshot = HasTrueshotAura()
            if not hasTrueshot then
                -- Show: Set texture and blink
                HHT_TrueshotIcon:SetTexture("Interface/Icons/Ability_TrueShot")
                HHT_TrueshotIcon:SetAlpha(1.0)
                StartBlinking(HHT_TrueshotIcon)
                anyIconVisible = true
            else
                -- Hide: Clear texture
                HHT_TrueshotIcon:SetTexture("")
                HHT_TrueshotIcon:SetAlpha(0)
                StopBlinking(HHT_TrueshotIcon)
            end
        else
            -- Feature disabled - clear texture
            HHT_TrueshotIcon:SetTexture("")
            HHT_TrueshotIcon:SetAlpha(0)
            StopBlinking(HHT_TrueshotIcon)
        end
    end
    
    -- Aspect Icon - only show when feature enabled AND (wrong or missing)
    if HHT_AspectIcon then
        if showAspect then
            local currentAspect = GetCurrentAspect()
            local mainAspect = db.mainAspect or "Aspect of the Hawk"
            local isWrong = (currentAspect ~= mainAspect)
            
            if isWrong then
                -- Show: Set texture and blink
                local aspectTexture = GetAspectTexture(mainAspect)
                HHT_AspectIcon:SetTexture(aspectTexture)
                HHT_AspectIcon:SetAlpha(1.0)
                StartBlinking(HHT_AspectIcon)
                anyIconVisible = true
            else
                -- Hide: Clear texture
                HHT_AspectIcon:SetTexture("")
                HHT_AspectIcon:SetAlpha(0)
                StopBlinking(HHT_AspectIcon)
            end
        else
            -- Feature disabled - clear texture
            HHT_AspectIcon:SetTexture("")
            HHT_AspectIcon:SetAlpha(0)
            StopBlinking(HHT_AspectIcon)
        end
    end
    
    -- Show frame only if at least one warning is active
    if anyIconVisible then
        HHT_WarningFrame:Show()
    else
        HHT_WarningFrame:Hide()
    end
end

-- ============ Event Handler ============
local function HandleWarningEvents()
    if not HamingwaysHunterToolsDB then return end
    
    local db = HamingwaysHunterToolsDB
    
    -- Auto-cast Trueshot if missing (self-buff, no target needed)
    if db.autoTrueshotAura then
        if not HasTrueshotAura() then
            CastSpellByName("Trueshot Aura")
        end
    end
    
    HHT_UpdateWarningDisplay()
end

-- ============ Create Warning Frame ============
local function CreateWarningFrame()
    local db = HamingwaysHunterToolsDB
    local iconSize = db.warningIconSize or DEFAULT_WARNING_ICON_SIZE
    local frameWidth = iconSize * 2 + 14
    local frameHeight = iconSize + 8
    
    HHT_WarningFrame = CreateFrame("Frame", "HamingwaysHunterToolsWarningFrame", UIParent)
    HHT_WarningFrame:SetWidth(frameWidth)
    HHT_WarningFrame:SetHeight(frameHeight)
    HHT_WarningFrame:SetFrameStrata("MEDIUM")
    
    -- Load saved position
    local savedPoint = db.warningPoint or "CENTER"
    local posX = db.warningX or 0
    local posY = db.warningY or -150
    HHT_WarningFrame:SetPoint(savedPoint, UIParent, savedPoint, posX, posY)
    
    -- No backdrop - only icons visible
    HHT_WarningFrame:SetBackdrop(nil)
    HHT_WarningFrame:EnableMouse(true)
    HHT_WarningFrame:SetMovable(true)
    HHT_WarningFrame:RegisterForDrag("LeftButton")
    HHT_WarningFrame:SetScript("OnDragStart", function()
        -- Only allow dragging when frames are unlocked
        if not HamingwaysHunterToolsDB.locked then
            this:StartMoving()
        end
    end)
    HHT_WarningFrame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local point, _, _, xOfs, yOfs = this:GetPoint()
        HamingwaysHunterToolsDB.warningPoint = point
        HamingwaysHunterToolsDB.warningX = xOfs
        HamingwaysHunterToolsDB.warningY = yOfs
    end)
    -- Don't hide initially - let UpdateWarningDisplay handle it
    
    -- Trueshot Icon (direct texture)
    HHT_TrueshotIcon = HHT_WarningFrame:CreateTexture(nil, "ARTWORK")
    HHT_TrueshotIcon:SetWidth(iconSize)
    HHT_TrueshotIcon:SetHeight(iconSize)
    HHT_TrueshotIcon:SetPoint("LEFT", HHT_WarningFrame, "LEFT", 4, 0)
    HHT_TrueshotIcon:SetTexture("Interface/Icons/Ability_TrueShot")
    HHT_TrueshotIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    HHT_TrueshotIcon:SetAlpha(0)  -- Start hidden, UpdateWarningDisplay will show if needed
    
    -- Create tooltip frame for trueshot
    local trueshotTooltip = CreateFrame("Button", nil, HHT_WarningFrame)
    trueshotTooltip:SetWidth(iconSize)
    trueshotTooltip:SetHeight(iconSize)
    trueshotTooltip:SetPoint("LEFT", HHT_WarningFrame, "LEFT", 4, 0)
    trueshotTooltip:EnableMouse(true)
    trueshotTooltip:RegisterForClicks("LeftButtonUp")
    
    trueshotTooltip:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Trueshot Aura", 1, 1, 1)
        if HasTrueshotAura() then
            GameTooltip:AddLine("Active", 0, 1, 0)
        else
            GameTooltip:AddLine("Missing!", 1, 0, 0)
        end
        GameTooltip:AddLine("Click to cast", 0.5, 0.5, 1)
        GameTooltip:Show()
    end)
    trueshotTooltip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    trueshotTooltip:SetScript("OnClick", function()
        if arg1 == "LeftButton" then
            CastSpellByName("Trueshot Aura")
        end
    end)
    
    -- Aspect Icon (direct texture)
    HHT_AspectIcon = HHT_WarningFrame:CreateTexture(nil, "ARTWORK")
    HHT_AspectIcon:SetWidth(iconSize)
    HHT_AspectIcon:SetHeight(iconSize)
    HHT_AspectIcon:SetPoint("LEFT", HHT_WarningFrame, "LEFT", iconSize + 10, 0)
    
    -- Set texture based on main aspect
    local aspectTexture = GetAspectTexture(db.mainAspect)
    HHT_AspectIcon:SetTexture(aspectTexture)
    HHT_AspectIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    HHT_AspectIcon:SetAlpha(0)  -- Start hidden, UpdateWarningDisplay will show if needed
    
    -- Create tooltip frame for aspect
    local aspectTooltip = CreateFrame("Button", nil, HHT_WarningFrame)
    aspectTooltip:SetWidth(iconSize)
    aspectTooltip:SetHeight(iconSize)
    aspectTooltip:SetPoint("LEFT", HHT_WarningFrame, "LEFT", iconSize + 10, 0)
    aspectTooltip:EnableMouse(true)
    aspectTooltip:RegisterForClicks("LeftButtonUp")
    
    aspectTooltip:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        local db = HamingwaysHunterToolsDB
        local mainAspect = db.mainAspect or "Aspect of the Hawk"
        GameTooltip:SetText("Aspect Tracker", 1, 1, 1)
        GameTooltip:AddLine("Expected: " .. mainAspect, 0.8, 0.8, 0.8)
        local current = GetCurrentAspect()
        if current then
            if current == mainAspect then
                GameTooltip:AddLine("Current: " .. current, 0, 1, 0)
            else
                GameTooltip:AddLine("Current: " .. current, 1, 0, 0)
            end
        else
            GameTooltip:AddLine("No aspect active!", 1, 0, 0)
        end
        GameTooltip:AddLine("Click to cast", 0.5, 0.5, 1)
        GameTooltip:Show()
    end)
    aspectTooltip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    aspectTooltip:SetScript("OnClick", function()
        if arg1 == "LeftButton" then
            local db = HamingwaysHunterToolsDB
            local mainAspect = db.mainAspect or "Aspect of the Hawk"
            CastSpellByName(mainAspect)
        end
    end)
end

-- ============ Initialize ============
local function InitializeWarnings()
    -- Wait for main addon to initialize DB
    if not HamingwaysHunterToolsDB then
        WarningsModule:RegisterEvent("VARIABLES_LOADED")
        WarningsModule:SetScript("OnEvent", function()
            if event == "VARIABLES_LOADED" and HamingwaysHunterToolsDB then
                WarningsModule:UnregisterEvent("VARIABLES_LOADED")
                InitializeWarnings()
            end
        end)
        return
    end
    
    -- Set defaults if not present (only on first ever load)
    local db = HamingwaysHunterToolsDB
    if type(db.autoTrueshotAura) ~= "boolean" then db.autoTrueshotAura = false end
    if type(db.showTrueshotWarning) ~= "boolean" then db.showTrueshotWarning = true end
    if type(db.aspectTracking) ~= "boolean" then db.aspectTracking = true end
    if type(db.showAspectWarning) ~= "boolean" then db.showAspectWarning = true end
    if type(db.mainAspect) ~= "string" then db.mainAspect = "Aspect of the Hawk" end
    if type(db.warningIconSize) ~= "number" then db.warningIconSize = DEFAULT_WARNING_ICON_SIZE end
    
    -- Scan available aspects
    ScanAvailableAspects()
    
    -- Create UI
    CreateWarningFrame()
    
    -- Register events
    WarningsModule:RegisterEvent("PLAYER_TARGET_CHANGED")  -- Protected function context
    WarningsModule:RegisterEvent("SPELLS_CHANGED")
    
    WarningsModule:SetScript("OnEvent", function()
        if event == "PLAYER_TARGET_CHANGED" then
            -- ONLY place where we can cast (protected function context)
            if HamingwaysHunterToolsDB.autoTrueshotAura then
                if not HasTrueshotAura() then
                    CastSpellByName("Trueshot Aura")
                end
            end
            -- Update display on target change
            HHT_UpdateWarningDisplay()
        elseif event == "SPELLS_CHANGED" then
            ScanAvailableAspects()
        end
    end)
    
    -- PERFORMANCE: Aura updates handled by main addon's PLAYER_AURAS_CHANGED (shared, throttled)
    
    -- Initial update
    HHT_UpdateWarningDisplay()
end

-- Reset warning frame position
function HHT_ResetWarningPosition()
    if HHT_WarningFrame then
        HamingwaysHunterToolsDB.warningPoint = "CENTER"
        HamingwaysHunterToolsDB.warningX = 0
        HamingwaysHunterToolsDB.warningY = -150
        HHT_WarningFrame:ClearAllPoints()
        HHT_WarningFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
        DEFAULT_CHAT_FRAME:AddMessage("HHT Warning Frame position reset to center!")
    end
end

-- Slash command
SlashCmdList["HHTRESETWARNING"] = HHT_ResetWarningPosition
SLASH_HHTRESETWARNING1 = "/hhtresetwarning"

-- Start initialization when player enters world
WarningsModule:RegisterEvent("PLAYER_ENTERING_WORLD")
WarningsModule:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
        WarningsModule:UnregisterEvent("PLAYER_ENTERING_WORLD")
        InitializeWarnings()
    end
end)
