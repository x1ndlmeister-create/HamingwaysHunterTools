-- KH Totem Tracker for Vanilla 1.12
-- Tracks which party members have Totem buffs

local KH_TT = {}
KH_TT.frame = CreateFrame("Frame", "KHTotemTrackerFrame", UIParent)
KH_TT.totemButtons = {}
-- scanTooltip removed - using texture comparison now (100x faster!)
KH_TT.enabled = false
KH_TT.testMode = false

local configFrame = nil
local minimapButton = nil
local centerSizeSlider = nil
local outerSizeSlider = nil
local radiusSlider = nil
local showTrackerCheckbox = nil
local lockFrameCheckbox = nil

-- Totem Definitionen (MUSS vor GetConfig() stehen!)
local TOTEMS = {
    -- Air Totems
    {name = "Windfury", texture = "Interface\\Icons\\Spell_Nature_Windfury", searchText = "Windfury"},
    {name = "Grace of Air", texture = "Interface\\Icons\\Spell_Nature_InvisibilityTotem", searchText = "Grace of Air"},
    {name = "Grounding", texture = "Interface\\Icons\\Spell_Nature_GroundingTotem", searchText = "Grounding"},
    {name = "Nature Resistance", texture = "Interface\\Icons\\Spell_Nature_NatureResistanceTotem", searchText = "Nature Resistance"},
    {name = "Windwall", texture = "Interface\\Icons\\Spell_Nature_EarthBind", searchText = "Windwall"},
    {name = "Tranquil Air", texture = "Interface\\Icons\\Spell_Nature_Brilliance", searchText = "Tranquil Air"},
    
    -- Fire Totems
    {name = "Flametongue", texture = "Interface\\Icons\\Spell_Fire_FlameTounge", searchText = "Flametongue"},
    {name = "Searing", texture = "Interface\\Icons\\Spell_Fire_SearingTotem", searchText = "Searing"},
    {name = "Fire Nova", texture = "Interface\\Icons\\Spell_Fire_SealOfFire", searchText = "Fire Nova"},
    {name = "Magma", texture = "Interface\\Icons\\Spell_Fire_SelfDestruct", searchText = "Magma"},
    {name = "Frost Resistance", texture = "Interface\\Icons\\Spell_FrostResistanceTotem_01", searchText = "Frost Resistance"},
    
    -- Earth Totems
    {name = "Strength of Earth", texture = "Interface\\Icons\\Spell_Nature_EarthBindTotem", searchText = "Strength of Earth"},
    {name = "Stoneskin", texture = "Interface\\Icons\\Spell_Nature_StoneSkinTotem", searchText = "Stoneskin"},
    {name = "Tremor", texture = "Interface\\Icons\\Spell_Nature_TremorTotem", searchText = "Tremor"},
    {name = "Stoneclaw", texture = "Interface\\Icons\\Spell_Nature_StoneClawTotem", searchText = "Stoneclaw"},
    {name = "Earthbind", texture = "Interface\\Icons\\Spell_Nature_StrengthOfEarthTotem02", searchText = "Earthbind"},
    
    -- Water Totems
    {name = "Mana Spring", texture = "Interface\\Icons\\Spell_Nature_ManaRegenTotem", searchText = "Mana Spring"},
    {name = "Healing Stream", texture = "Interface\\Icons\\INV_Spear_04", searchText = "Healing Stream"},
    {name = "Mana Tide", texture = "Interface\\Icons\\Spell_Frost_SummonWaterElemental", searchText = "Mana Tide"},
    {name = "Poison Cleansing", texture = "Interface\\Icons\\Spell_Nature_PoisonCleansingTotem", searchText = "Poison Cleansing"},
    {name = "Disease Cleansing", texture = "Interface\\Icons\\Spell_Nature_DiseaseCleansingTotem", searchText = "Disease Cleansing"},
    {name = "Fire Resistance", texture = "Interface\\Icons\\Spell_FireResistanceTotem_01", searchText = "Fire Resistance"},
}

-- Default Config
local function GetConfig()
    if not KHTotemTrackerDB then
        KHTotemTrackerDB = {}
    end
    
    -- Setze nur defaults wenn Wert noch nicht existiert
    KHTotemTrackerDB.minimapPos = KHTotemTrackerDB.minimapPos or 225
    KHTotemTrackerDB.centerIconSize = KHTotemTrackerDB.centerIconSize or 60
    KHTotemTrackerDB.outerIconSize = KHTotemTrackerDB.outerIconSize or 36
    KHTotemTrackerDB.circleRadius = KHTotemTrackerDB.circleRadius or 100
    
    -- Tracked Totems (default: alle aktiviert)
    if not KHTotemTrackerDB.trackedTotems then
        KHTotemTrackerDB.trackedTotems = {}
        for i, totem in ipairs(TOTEMS) do
            KHTotemTrackerDB.trackedTotems[totem.name] = true
        end
    end
    
    -- Boolean braucht spezielle Behandlung (nil check)
    if KHTotemTrackerDB.showTracker == nil then
        KHTotemTrackerDB.showTracker = true
    end
    if KHTotemTrackerDB.locked == nil then
        KHTotemTrackerDB.locked = false
    end
    
    return KHTotemTrackerDB
end

-- Klassenfarben (RGB)
local CLASS_COLORS = {
    ["Warrior"] = {r=0.78, g=0.61, b=0.43},
    ["Paladin"] = {r=0.96, g=0.55, b=0.73},
    ["Hunter"] = {r=0.67, g=0.83, b=0.45},
    ["Rogue"] = {r=1.00, g=0.96, b=0.41},
    ["Priest"] = {r=1.00, g=1.00, b=1.00},
    ["Shaman"] = {r=0.00, g=0.44, b=0.87},
    ["Mage"] = {r=0.41, g=0.80, b=0.94},
    ["Warlock"] = {r=0.58, g=0.51, b=0.79},
    ["Druid"] = {r=1.00, g=0.49, b=0.04}
}

-- Get own party members (only same subgroup in raids - totem buffs are NOT raid-wide!)
local function GetOwnPartyMembers()
    local members = {}
    local numRaidMembers = GetNumRaidMembers()
    
    if numRaidMembers > 0 then
        -- In raid: Find own subgroup
        local playerSubgroup = nil
        for i = 1, numRaidMembers do
            local name, rank, subgroup = GetRaidRosterInfo(i)
            if name == UnitName("player") then
                playerSubgroup = subgroup
                break
            end
        end
        
        -- Get all members of own subgroup
        if playerSubgroup then
            for i = 1, numRaidMembers do
                local name, rank, subgroup = GetRaidRosterInfo(i)
                if subgroup == playerSubgroup then
                    table.insert(members, "raid"..i)
                end
            end
        end
    else
        -- In party: Get all party members
        table.insert(members, "player")
        for i = 1, 4 do
            if UnitExists("party"..i) then
                table.insert(members, "party"..i)
            end
        end
    end
    
    return members
end

-- Hauptfenster erstellen
local mainFrame = CreateFrame("Frame", "KHTTMainFrame", UIParent)
mainFrame:SetWidth(300)
mainFrame:SetHeight(300)
mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
mainFrame:SetFrameStrata("MEDIUM")  -- Don't overlap other addons
mainFrame:EnableMouse(true)
mainFrame:SetMovable(true)
mainFrame:RegisterForDrag("LeftButton")
mainFrame:SetScript("OnDragStart", function() this:StartMoving() end)
mainFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
mainFrame:Hide()

-- Zentrales Shamanen-Icon
local centerIcon = mainFrame:CreateTexture(nil, "ARTWORK")
local cfg = GetConfig()
centerIcon:SetWidth(cfg.centerIconSize)
centerIcon:SetHeight(cfg.centerIconSize)
centerIcon:SetPoint("CENTER", mainFrame, "CENTER", 0, -8)  -- 8 Pixel nach unten verschoben
-- Versuche Custom-Texture zu laden
if centerIcon:SetTexture("Interface\\AddOns\\KH_TotemTracker\\images\\shaman_logo_alpha") then
    centerIcon:SetTexCoord(0, 1, 0, 1)  -- Zeige das ganze Bild
    centerIcon:SetBlendMode("BLEND")
else
    -- Fallback
    centerIcon:SetTexture("Interface\\Icons\\Spell_Nature_BloodLust")
    centerIcon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
end
mainFrame.centerIcon = centerIcon

-- Kreis-Parameter
local CENTER_X = 150
local CENTER_Y = 150

-- Totem Icons erstellen
local numTotems = table.getn(TOTEMS)
for i, totem in ipairs(TOTEMS) do
    local btn = CreateFrame("Button", "KHTTTotemBtn"..i, mainFrame)
    local cfg = GetConfig()
    btn:SetWidth(cfg.outerIconSize)
    btn:SetHeight(cfg.outerIconSize)
    
    -- Position im Kreis berechnen
    local angle = (360 / numTotems) * (i - 1)
    local angleRad = math.rad(angle - 90) -- -90 um oben zu starten
    local x = cfg.circleRadius * math.cos(angleRad)
    local y = cfg.circleRadius * math.sin(angleRad)
    
    btn:SetPoint("CENTER", mainFrame, "CENTER", x, y)
    
    -- Icon
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(cfg.outerIconSize)
    icon:SetHeight(cfg.outerIconSize)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    
    -- Versuche custom TGA zu laden, sonst Standard-Icon
    local fileName = string.gsub(totem.name, " ", "_")  -- Ersetze Leerzeichen mit Underscore
    local customTexPath = "Interface\\AddOns\\KH_TotemTracker\\images\\"..fileName
    local loaded = icon:SetTexture(customTexPath)
    
    if loaded then
        -- Custom TGA gefunden - verwende es ohne Crop (ist bereits rund)
        icon:SetTexCoord(0, 1, 0, 1)
        icon:SetBlendMode("BLEND")
    else
        -- Fallback auf Standard WoW-Icon
        icon:SetTexture(totem.texture)
        icon:SetTexCoord(0, 1, 0, 1)
    end
    btn.icon = icon
    
    -- Counter Text
    local counter = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    counter:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, 2)
    counter:SetText("0")
    counter:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    btn.counter = counter
    
    btn.totemData = totem
    -- playersWithBuff removed - was never used (memory leak prevention)
    
    -- Tooltip scripts
    btn:SetScript("OnEnter", function()
        KH_TT:ShowTotemTooltip(this)
    end)
    
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    btn:Hide()
    table.insert(KH_TT.totemButtons, btn)
end

-- Optimierte Funktion zum Scannen der Buffs (Texture-Vergleich - KEINE Tooltip-Scans!)
function KH_TT:HasTotemBuff(unit, totemTexture)
    if not UnitExists(unit) then
        return false
    end
    
    -- Direkte Texture-Vergleich - 100x schneller als Tooltip-Scan!
    for i = 1, 32 do
        local buffTexture = UnitBuff(unit, i)
        if not buffTexture then
            break  -- Keine weiteren Buffs
        end
        if buffTexture == totemTexture then
            return true
        end
    end
    
    return false
end

-- Tooltip für Totem anzeigen
function KH_TT:ShowTotemTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(button.totemData.name.." Totem", 1, 1, 1)
    GameTooltip:AddLine(" ")
    
    -- Local tables are GC'd automatically after function - no memory leak
    local inRange = {}
    local outRange = {}
    
    -- Get only own party members (totem buffs are NOT raid-wide!)
    local partyMembers = GetOwnPartyMembers()
    
    for _, unit in ipairs(partyMembers) do
        if UnitExists(unit) then
            local name = UnitName(unit)
            local class = UnitClass(unit)
            local hasBuff = KH_TT:HasTotemBuff(unit, button.totemData.texture)
            
            local classColor = CLASS_COLORS[class] or {r=1, g=1, b=1}
            
            if hasBuff then
                table.insert(inRange, {name=name, class=class, color=classColor})
            else
                table.insert(outRange, {name=name, class=class, color=classColor})
            end
        end
    end
    
    -- In Range (grün)
    if table.getn(inRange) > 0 then
        GameTooltip:AddLine("In Range:", 0, 1, 0)
        for _, player in ipairs(inRange) do
            GameTooltip:AddLine(player.name, player.color.r, player.color.g, player.color.b)
        end
    end
    
    -- Out of Range (rot)
    if table.getn(outRange) > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Out of Range:", 1, 0, 0)
        for _, player in ipairs(outRange) do
            GameTooltip:AddLine(player.name, 1, 0, 0)
        end
    end
    
    GameTooltip:Show()
end

-- Funktion zum Update der Anzeige
function KH_TT:UpdateDisplay()
    if not KH_TT.enabled or KH_TT.testMode then
        return
    end
    
    -- Get only own party members (totem buffs are NOT raid-wide!)
    local partyMembers = GetOwnPartyMembers()
    local totalPlayers = table.getn(partyMembers)
    
    if totalPlayers == 0 then
        mainFrame:Hide()
        return
    end
    
    -- Local tables are GC'd automatically after function - no memory leak
    local visibleButtons = {}
    local activeTotems = {}  -- Track which totems are actually active
    local cfg = GetConfig()
    
    -- OPTIMIZATION: First pass - find which totems are active (quick scan)
    for _, btn in ipairs(KH_TT.totemButtons) do
        -- Skip if this totem is disabled in config
        if not cfg.trackedTotems[btn.totemData.name] then
            btn:Hide()
        else
            -- Quick check: Does ANY player in our party have this buff?
            local foundAny = false
        for _, unit in ipairs(partyMembers) do
            if UnitExists(unit) and KH_TT:HasTotemBuff(unit, btn.totemData.texture) then
                foundAny = true
                break
            end
        end
        
            if foundAny then
                table.insert(activeTotems, btn)
            else
                btn:Hide()  -- Hide immediately if not active
            end
        end
    end
    
    -- OPTIMIZATION: Second pass - only scan players for ACTIVE totems
    for _, btn in ipairs(activeTotems) do
        local count = 0
        
        for _, unit in ipairs(partyMembers) do
            if UnitExists(unit) and KH_TT:HasTotemBuff(unit, btn.totemData.texture) then
                count = count + 1
            end
        end
        
        btn.counter:SetText(count)
        
        -- Icon ausblenden wenn count == 0
        if count == 0 then
            btn:Hide()
        else
            btn:Show()
            table.insert(visibleButtons, btn)
            
            -- Farbe basierend auf Count
            if count < totalPlayers then
                btn.counter:SetTextColor(1, 0, 0) -- Rot
                btn.icon:SetVertexColor(1, 1, 1)
            else
                btn.counter:SetTextColor(0, 1, 0) -- Grün
                btn.icon:SetVertexColor(1, 1, 1)
            end
        end
    end
    
    -- Positionen neu berechnen für sichtbare Buttons
    local numVisible = table.getn(visibleButtons)
    if numVisible > 0 then
        local cfg = GetConfig()
        for i, btn in ipairs(visibleButtons) do
            local angle = (360 / numVisible) * (i - 1)
            local angleRad = math.rad(angle - 90)
            local x = cfg.circleRadius * math.cos(angleRad)
            local y = cfg.circleRadius * math.sin(angleRad)
            
            btn:ClearAllPoints()
            btn:SetPoint("CENTER", mainFrame, "CENTER", x, y)
        end
    end
    
    -- Frame immer anzeigen wenn enabled
    mainFrame:Show()
end

-- Event Handler
KH_TT.frame:RegisterEvent("ADDON_LOADED")
KH_TT.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
KH_TT.frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
KH_TT.frame:RegisterEvent("RAID_ROSTER_UPDATE")  -- Support 40-man raids
-- Note: PLAYER_AURAS_CHANGED and UNIT_AURA removed - too spammy in raids
-- Updates now happen on roster changes only (much more efficient)

KH_TT.frame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "KH_TotemTracker" then
        -- Lade gespeicherte Einstellungen
        local cfg = GetConfig()
        
        -- Update Slider-Werte in der UI
        if centerSizeSlider then
            centerSizeSlider:SetValue(cfg.centerIconSize)
            getglobal(centerSizeSlider:GetName().."Text"):SetText("Center Icon Size: "..cfg.centerIconSize)
        end
        if outerSizeSlider then
            outerSizeSlider:SetValue(cfg.outerIconSize)
            getglobal(outerSizeSlider:GetName().."Text"):SetText("Outer Icon Size: "..cfg.outerIconSize)
        end
        if radiusSlider then
            radiusSlider:SetValue(cfg.circleRadius)
            getglobal(radiusSlider:GetName().."Text"):SetText("Circle Radius: "..cfg.circleRadius)
        end
        if showTrackerCheckbox then
            showTrackerCheckbox:SetChecked(cfg.showTracker and 1 or 0)
        end
        
        -- Wende Lock-Status an
        if cfg.locked then
            mainFrame:SetMovable(false)
            mainFrame:RegisterForDrag()
            if lockFrameCheckbox then
                lockFrameCheckbox:SetChecked(1)
            end
        else
            mainFrame:SetMovable(true)
            mainFrame:RegisterForDrag("LeftButton")
            if lockFrameCheckbox then
                lockFrameCheckbox:SetChecked(0)
            end
        end
        
        -- Wende gespeicherte Größen an
        centerIcon:SetWidth(cfg.centerIconSize)
        centerIcon:SetHeight(cfg.centerIconSize)
        
        for _, btn in ipairs(KH_TT.totemButtons) do
            btn:SetWidth(cfg.outerIconSize)
            btn:SetHeight(cfg.outerIconSize)
            btn.icon:SetWidth(cfg.outerIconSize)
            btn.icon:SetHeight(cfg.outerIconSize)
        end
        
        -- Setze enabled Status aus Config
        KH_TT.enabled = cfg.showTracker
        
        -- Zeige oder verstecke Frame basierend auf gespeicherter Einstellung
        if cfg.showTracker then
            KH_TT:UpdateDisplay()
        else
            mainFrame:Hide()
        end
        
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00KH Totem Tracker loaded! Use /tt or /totem to toggle.|r")
    else
        -- Andere Events: Update Display
        KH_TT:UpdateDisplay()
    end
end)

-- Update on smart throttle (1s interval) - scans only active totems
local updateTimer = 0
KH_TT.frame:SetScript("OnUpdate", function()
    if not KH_TT.enabled or KH_TT.testMode then return end
    
    updateTimer = updateTimer + arg1
    if updateTimer >= 1.0 then  -- 1 second (was 0.5s, but smarter now)
        KH_TT:UpdateDisplay()
        updateTimer = 0
    end
end)

-- Slash Commands
SLASH_KHTOTEMTRACKER1 = "/tt"
SLASH_KHTOTEMTRACKER2 = "/totem"
SlashCmdList["KHTOTEMTRACKER"] = function(msg)
    if msg == "reset" then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        KH_TT.enabled = true
        KH_TT:UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("KH Totem Tracker position reset and enabled")
    elseif msg == "debug" then
        DEFAULT_CHAT_FRAME:AddMessage("=== KH Totem Tracker Debug ===")
        DEFAULT_CHAT_FRAME:AddMessage("Saved DB values:")
        if KHTotemTrackerDB then
            DEFAULT_CHAT_FRAME:AddMessage("  centerIconSize: "..tostring(KHTotemTrackerDB.centerIconSize))
            DEFAULT_CHAT_FRAME:AddMessage("  outerIconSize: "..tostring(KHTotemTrackerDB.outerIconSize))
            DEFAULT_CHAT_FRAME:AddMessage("  circleRadius: "..tostring(KHTotemTrackerDB.circleRadius))
            DEFAULT_CHAT_FRAME:AddMessage("  showTracker: "..tostring(KHTotemTrackerDB.showTracker))
        else
            DEFAULT_CHAT_FRAME:AddMessage("  KHTotemTrackerDB is nil!")
        end
        local cfg = GetConfig()
        DEFAULT_CHAT_FRAME:AddMessage("After GetConfig():")
        DEFAULT_CHAT_FRAME:AddMessage("  centerIconSize: "..cfg.centerIconSize)
        DEFAULT_CHAT_FRAME:AddMessage("  outerIconSize: "..cfg.outerIconSize)
        DEFAULT_CHAT_FRAME:AddMessage("  circleRadius: "..cfg.circleRadius)
        DEFAULT_CHAT_FRAME:AddMessage("Enabled: "..tostring(KH_TT.enabled)..", TestMode: "..tostring(KH_TT.testMode))
        
        -- Zeige Positionen der sichtbaren Icons
        DEFAULT_CHAT_FRAME:AddMessage("Visible icon positions:")
        for i, btn in ipairs(KH_TT.totemButtons) do
            if btn:IsShown() then
                local point, relativeTo, relativePoint, xOfs, yOfs = btn:GetPoint()
                local distance = math.sqrt(xOfs*xOfs + yOfs*yOfs)
                DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s: x=%.1f, y=%.1f, dist=%.1f", btn.totemData.name, xOfs, yOfs, distance))
            end
        end
    elseif msg == "circle" then
        -- Zeige perfekten Testkreis mit 8 Icons gleicher Distanz
        mainFrame:Show()
        local cfg = GetConfig()
        for i = 1, 8 do
            if KH_TT.totemButtons[i] then
                local angle = (360 / 8) * (i - 1)
                local angleRad = math.rad(angle - 90)
                local x = cfg.circleRadius * math.cos(angleRad)
                local y = cfg.circleRadius * math.sin(angleRad)
                
                KH_TT.totemButtons[i]:Show()
                KH_TT.totemButtons[i]:ClearAllPoints()
                KH_TT.totemButtons[i]:SetPoint("CENTER", mainFrame, "CENTER", x, y)
                KH_TT.totemButtons[i].counter:SetText(i)
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("Showing perfect circle with 8 icons")
    elseif msg == "test" then
        -- Test-Modus: Zeige WF (4 Spieler) + 3 weitere Totems
        KH_TT.testMode = true
        mainFrame:Show()
        
        -- Windfury (erstes Totem) auf 4 setzen
        KH_TT.totemButtons[1]:Show()
        KH_TT.totemButtons[1].counter:SetText("4")
        KH_TT.totemButtons[1].counter:SetTextColor(0, 1, 0)
        
        -- Grace of Air (zweites Totem) auf 3 setzen
        KH_TT.totemButtons[2]:Show()
        KH_TT.totemButtons[2].counter:SetText("3")
        KH_TT.totemButtons[2].counter:SetTextColor(1, 0, 0)
        
        -- Grounding (drittes Totem) auf 2 setzen
        KH_TT.totemButtons[3]:Show()
        KH_TT.totemButtons[3].counter:SetText("2")
        KH_TT.totemButtons[3].counter:SetTextColor(1, 0, 0)
        
        -- Strength of Earth auf 5 setzen
        KH_TT.totemButtons[12]:Show()
        KH_TT.totemButtons[12].counter:SetText("5")
        KH_TT.totemButtons[12].counter:SetTextColor(0, 1, 0)
        
        -- Restliche Buttons ausblenden
        for i, btn in ipairs(KH_TT.totemButtons) do
            if i ~= 1 and i ~= 2 and i ~= 3 and i ~= 12 then
                btn:Hide()
            end
        end
        
        -- Positionen neu berechnen für die 4 sichtbaren Buttons
        local visibleButtons = {KH_TT.totemButtons[1], KH_TT.totemButtons[2], KH_TT.totemButtons[3], KH_TT.totemButtons[12]}
        local cfg = GetConfig()
        for i, btn in ipairs(visibleButtons) do
            local angle = (360 / 4) * (i - 1)
            local angleRad = math.rad(angle - 90)
            local x = cfg.circleRadius * math.cos(angleRad)
            local y = cfg.circleRadius * math.sin(angleRad)
            
            btn:ClearAllPoints()
            btn:SetPoint("CENTER", mainFrame, "CENTER", x, y)
        end
        
        DEFAULT_CHAT_FRAME:AddMessage("KH Totem Tracker test mode activated")
    elseif KH_TT.enabled then
        KH_TT.enabled = false
        KH_TT.testMode = false
        mainFrame:Hide()
        DEFAULT_CHAT_FRAME:AddMessage("KH Totem Tracker disabled")
    else
        KH_TT.enabled = true
        KH_TT.testMode = false
        KH_TT:UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("KH Totem Tracker enabled")
    end
end

-- ============ Config UI ============
local function CreateConfigUI()
    configFrame = CreateFrame("Frame", "KHTTConfigFrame", UIParent)
    configFrame:SetWidth(400)
    configFrame:SetHeight(500)
    configFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    configFrame:EnableMouse(true)
    configFrame:SetMovable(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    configFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    configFrame:Hide()
    
    -- Title
    local title = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", configFrame, "TOP", 0, -20)
    title:SetText("|cFF0070DDKH Totem Tracker Settings|r")
    
    -- Close Button
    local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -5, -5)
    
    -- Tab System
    local tabs = {}
    local tabContents = {}
    local activeTab = 1
    
    local function ShowTab(tabIndex)
        for i, content in ipairs(tabContents) do
            if i == tabIndex then
                content:Show()
            else
                content:Hide()
            end
        end
        for i, tab in ipairs(tabs) do
            if i == tabIndex then
                tab:SetBackdropColor(0.3, 0.3, 0.3, 1)
            else
                tab:SetBackdropColor(0.1, 0.1, 0.1, 1)
            end
        end
        activeTab = tabIndex
    end
    
    -- Create Tabs
    local tabNames = {"General", "Totems", "Statistics"}
    local tabWidth = (400 - 40) / 3
    
    for i, name in ipairs(tabNames) do
        local tabIndex = i
        local tab = CreateFrame("Button", nil, configFrame)
        tab:SetWidth(tabWidth)
        tab:SetHeight(24)
        tab:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 20 + (i - 1) * tabWidth, -50)
        tab:SetFrameStrata("DIALOG")
        tab:SetFrameLevel(configFrame:GetFrameLevel() + 2)
        tab:EnableMouse(true)
        tab:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        tab:SetBackdropColor(0.1, 0.1, 0.1, 1)
        tab:SetBackdropBorderColor(1, 1, 1, 1)
        
        local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("CENTER", 0, 0)
        text:SetText(name)
        
        tab:SetScript("OnClick", function()
            ShowTab(tabIndex)
        end)
        
        tab:SetScript("OnEnter", function()
            this:SetBackdropBorderColor(1, 1, 0, 1)
        end)
        
        tab:SetScript("OnLeave", function()
            this:SetBackdropBorderColor(1, 1, 1, 1)
        end)
        
        table.insert(tabs, tab)
    end
    
    -- Tab 1: General Settings
    local tab1 = CreateFrame("Frame", nil, configFrame)
    tab1:SetAllPoints(configFrame)
    tab1:Hide()
    table.insert(tabContents, tab1)
    
    local yOffset = -100
    
    -- Show Tracker Checkbox
    showTrackerCheckbox = CreateFrame("CheckButton", "KHTTShowTrackerCheckbox", tab1, "UICheckButtonTemplate")
    showTrackerCheckbox:SetPoint("TOPLEFT", tab1, "TOPLEFT", 30, yOffset)
    showTrackerCheckbox:SetWidth(24)
    showTrackerCheckbox:SetHeight(24)
    showTrackerCheckbox:SetChecked(1)  -- Default
    
    local showTrackerLabel = tab1:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showTrackerLabel:SetPoint("LEFT", showTrackerCheckbox, "RIGHT", 5, 0)
    showTrackerLabel:SetText("Show Totem Tracker")
    
    showTrackerCheckbox:SetScript("OnClick", function()
        local checked = this:GetChecked() == 1
        KHTotemTrackerDB.showTracker = checked
        if checked then
            KH_TT.enabled = true
            KH_TT:UpdateDisplay()
        else
            KH_TT.enabled = false
            mainFrame:Hide()
        end
    end)
    
    yOffset = yOffset - 40
    
    -- Lock Frame Checkbox
    local lockFrameCheckbox = CreateFrame("CheckButton", "KHTTLockFrameCheckbox", tab1, "UICheckButtonTemplate")
    lockFrameCheckbox:SetPoint("TOPLEFT", tab1, "TOPLEFT", 30, yOffset)
    lockFrameCheckbox:SetWidth(24)
    lockFrameCheckbox:SetHeight(24)
    lockFrameCheckbox:SetChecked(0)  -- Default
    
    local lockFrameLabel = tab1:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lockFrameLabel:SetPoint("LEFT", lockFrameCheckbox, "RIGHT", 5, 0)
    lockFrameLabel:SetText("Lock Frame")
    
    lockFrameCheckbox:SetScript("OnClick", function()
        local checked = this:GetChecked() == 1
        KHTotemTrackerDB.locked = checked
        if checked then
            mainFrame:SetMovable(false)
            mainFrame:RegisterForDrag()
        else
            mainFrame:SetMovable(true)
            mainFrame:RegisterForDrag("LeftButton")
        end
    end)
    
    yOffset = yOffset - 50
    
    -- Center Icon Size Slider
    centerSizeSlider = CreateFrame("Slider", "KHTTCenterSizeSlider", tab1, "OptionsSliderTemplate")
    centerSizeSlider:SetPoint("TOPLEFT", tab1, "TOPLEFT", 30, yOffset)
    centerSizeSlider:SetWidth(320)
    centerSizeSlider:SetMinMaxValues(30, 250)
    centerSizeSlider:SetValueStep(5)
    centerSizeSlider:SetValue(60)  -- Default
    getglobal(centerSizeSlider:GetName().."Low"):SetText("30")
    getglobal(centerSizeSlider:GetName().."High"):SetText("250")
    getglobal(centerSizeSlider:GetName().."Text"):SetText("Center Icon Size: 60")
    
    centerSizeSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        getglobal(this:GetName().."Text"):SetText("Center Icon Size: "..val)
        KHTotemTrackerDB.centerIconSize = val
        centerIcon:SetWidth(val)
        centerIcon:SetHeight(val)
    end)
    
    yOffset = yOffset - 60
    
    -- Outer Icon Size Slider
    outerSizeSlider = CreateFrame("Slider", "KHTTOuterSizeSlider", tab1, "OptionsSliderTemplate")
    outerSizeSlider:SetPoint("TOPLEFT", tab1, "TOPLEFT", 30, yOffset)
    outerSizeSlider:SetWidth(320)
    outerSizeSlider:SetMinMaxValues(20, 60)
    outerSizeSlider:SetValueStep(2)
    outerSizeSlider:SetValue(36)  -- Default
    getglobal(outerSizeSlider:GetName().."Low"):SetText("20")
    getglobal(outerSizeSlider:GetName().."High"):SetText("60")
    getglobal(outerSizeSlider:GetName().."Text"):SetText("Outer Icon Size: 36")
    
    outerSizeSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        getglobal(this:GetName().."Text"):SetText("Outer Icon Size: "..val)
        KHTotemTrackerDB.outerIconSize = val
        for _, btn in ipairs(KH_TT.totemButtons) do
            btn:SetWidth(val)
            btn:SetHeight(val)
            btn.icon:SetWidth(val)
            btn.icon:SetHeight(val)
        end
    end)
    
    yOffset = yOffset - 60
    
    -- Circle Radius Slider
    radiusSlider = CreateFrame("Slider", "KHTTRadiusSlider", tab1, "OptionsSliderTemplate")
    radiusSlider:SetPoint("TOPLEFT", tab1, "TOPLEFT", 30, yOffset)
    radiusSlider:SetWidth(320)
    radiusSlider:SetMinMaxValues(60, 200)
    radiusSlider:SetValueStep(5)
    radiusSlider:SetValue(100)  -- Default
    getglobal(radiusSlider:GetName().."Low"):SetText("60")
    getglobal(radiusSlider:GetName().."High"):SetText("200")
    getglobal(radiusSlider:GetName().."Text"):SetText("Circle Radius: 100")
    
    radiusSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        getglobal(this:GetName().."Text"):SetText("Circle Radius: "..val)
        KHTotemTrackerDB.circleRadius = val
        
        -- Aktualisiere Positionen aller sichtbaren Buttons
        local visibleButtons = {}
        for _, btn in ipairs(KH_TT.totemButtons) do
            if btn:IsShown() then
                table.insert(visibleButtons, btn)
            end
        end
        
        local numVisible = table.getn(visibleButtons)
        if numVisible > 0 then
            for i, btn in ipairs(visibleButtons) do
                local angle = (360 / numVisible) * (i - 1)
                local angleRad = math.rad(angle - 90)
                local x = val * math.cos(angleRad)
                local y = val * math.sin(angleRad)
                
                btn:ClearAllPoints()
                btn:SetPoint("CENTER", mainFrame, "CENTER", x, y)
            end
        end
    end)
    
    -- Tab 2: Totems Selection
    local tab2 = CreateFrame("Frame", nil, configFrame)
    tab2:SetAllPoints(configFrame)
    tab2:Hide()
    table.insert(tabContents, tab2)
    
    -- ScrollFrame for totems
    local totemScrollFrame = CreateFrame("ScrollFrame", "KHTTTotemScrollFrame", tab2, "UIPanelScrollFrameTemplate")
    totemScrollFrame:SetPoint("TOPLEFT", tab2, "TOPLEFT", 20, -80)
    totemScrollFrame:SetPoint("BOTTOMRIGHT", tab2, "BOTTOMRIGHT", -40, 60)  -- 60 Pixel Abstand für Buttons
    
    local totemScrollChild = CreateFrame("Frame", nil, totemScrollFrame)
    totemScrollChild:SetWidth(totemScrollFrame:GetWidth())
    totemScrollChild:SetHeight(800)  -- Genug Platz für alle Totems
    totemScrollFrame:SetScrollChild(totemScrollChild)
    
    -- Totem Checkboxen erstellen
    local totemYOffset = -10
    local totemCheckboxes = {}
    
    local cfg = GetConfig()
    for i, totem in ipairs(TOTEMS) do
        local checkbox = CreateFrame("CheckButton", "KHTTTotem"..i.."Checkbox", totemScrollChild, "UICheckButtonTemplate")
        checkbox:SetPoint("TOPLEFT", totemScrollChild, "TOPLEFT", 10, totemYOffset)
        checkbox:SetWidth(24)
        checkbox:SetHeight(24)
        checkbox:SetChecked(cfg.trackedTotems[totem.name] and 1 or 0)
        
        -- Icon neben Checkbox
        local icon = checkbox:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(24)
        icon:SetHeight(24)
        icon:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
        icon:SetTexture(totem.texture)
        icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
        
        local label = totemScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        label:SetText(totem.name .. " Totem")
        
        checkbox.totemName = totem.name
        checkbox:SetScript("OnClick", function()
            local checked = this:GetChecked() == 1
            KHTotemTrackerDB.trackedTotems[this.totemName] = checked
            -- Sofort Display updaten
            if KH_TT.enabled then
                KH_TT:UpdateDisplay()
            end
        end)
        
        table.insert(totemCheckboxes, checkbox)
        totemYOffset = totemYOffset - 35
    end
    
    -- Select All / Deselect All Buttons
    local selectAllBtn = CreateFrame("Button", nil, tab2, "UIPanelButtonTemplate")
    selectAllBtn:SetWidth(100)
    selectAllBtn:SetHeight(24)
    selectAllBtn:SetPoint("BOTTOMLEFT", tab2, "BOTTOMLEFT", 25, 25)
    selectAllBtn:SetText("Select All")
    selectAllBtn:SetScript("OnClick", function()
        for _, checkbox in ipairs(totemCheckboxes) do
            checkbox:SetChecked(1)
            KHTotemTrackerDB.trackedTotems[checkbox.totemName] = true
        end
        if KH_TT.enabled then
            KH_TT:UpdateDisplay()
        end
    end)
    
    local deselectAllBtn = CreateFrame("Button", nil, tab2, "UIPanelButtonTemplate")
    deselectAllBtn:SetWidth(100)
    deselectAllBtn:SetHeight(24)
    deselectAllBtn:SetPoint("LEFT", selectAllBtn, "RIGHT", 10, 0)
    deselectAllBtn:SetText("Deselect All")
    deselectAllBtn:SetScript("OnClick", function()
        for _, checkbox in ipairs(totemCheckboxes) do
            checkbox:SetChecked(0)
            KHTotemTrackerDB.trackedTotems[checkbox.totemName] = false
        end
        if KH_TT.enabled then
            KH_TT:UpdateDisplay()
        end
    end)
    
    -- Tab 3: Statistics (empty for now)
    local tab3 = CreateFrame("Frame", nil, configFrame)
    tab3:SetAllPoints(configFrame)
    tab3:Hide()
    table.insert(tabContents, tab3)
    
    local statsText = tab3:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statsText:SetPoint("CENTER", tab3, "CENTER", 0, 0)
    statsText:SetText("Statistics coming soon...")
    
    -- Show first tab by default
    ShowTab(1)
end

-- ============ Minimap Button ============
local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "KHTTMinimapButton", Minimap)
    minimapButton:SetWidth(31)
    minimapButton:SetHeight(31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(9)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    
    minimapButton.icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    minimapButton.icon:SetWidth(20)
    minimapButton.icon:SetHeight(20)
    minimapButton.icon:SetTexture("Interface\\Icons\\Spell_Nature_Windfury")
    minimapButton.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    minimapButton.icon:SetPoint("CENTER", 1, 1)
    
    minimapButton.overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    minimapButton.overlay:SetWidth(53)
    minimapButton.overlay:SetHeight(53)
    minimapButton.overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    minimapButton.overlay:SetPoint("TOPLEFT", 0, 0)
    
    minimapButton:SetScript("OnClick", function()
        if configFrame:IsShown() then
            configFrame:Hide()
        else
            configFrame:Show()
        end
    end)
    
    minimapButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("|cFF0070DDKH Totem Tracker|r")
        GameTooltip:AddLine("Click to open settings", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    
    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    local function UpdateMinimapButton()
        local cfg = GetConfig()
        local angle = math.rad(cfg.minimapPos or 225)
        local x = 80 * math.cos(angle)
        local y = 80 * math.sin(angle)
        minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end
    
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetScript("OnDragStart", function()
        this:LockHighlight()
        this:SetScript("OnUpdate", function()
            local mx, my = GetCursorPosition()
            local px, py = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            mx, my = mx / scale, my / scale
            local angle = math.deg(math.atan2(my - py, mx - px))
            KHTotemTrackerDB.minimapPos = angle
            UpdateMinimapButton()
        end)
    end)
    
    minimapButton:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
        this:UnlockHighlight()
    end)
    
    UpdateMinimapButton()
    minimapButton:Show()
end

-- Initialize on load
CreateConfigUI()
CreateMinimapButton()