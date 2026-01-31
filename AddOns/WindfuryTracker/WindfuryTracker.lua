-- Totem Tracker for Vanilla 1.12
-- Tracks which party members have Totem buffs

local TT = {}
TT.frame = CreateFrame("Frame", "TotemTrackerFrame", UIParent)
TT.totemButtons = {}
TT.scanTooltip = CreateFrame("GameTooltip", "TTScanTooltip", nil, "GameTooltipTemplate")
TT.scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
TT.enabled = false

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

-- Totem Definitionen
local TOTEMS = {
    {name = "Windfury", texture = "Interface\\Icons\\Spell_Nature_Windfury", searchText = "Windfury"},
    {name = "Strength of Earth", texture = "Interface\\Icons\\Spell_Nature_EarthBindTotem", searchText = "Strength of Earth"},
    {name = "Grace of Air", texture = "Interface\\Icons\\Spell_Nature_InvisibilityTotem", searchText = "Grace of Air"},
    {name = "Stoneskin", texture = "Interface\\Icons\\Spell_Nature_StoneSkinTotem", searchText = "Stoneskin"},
    {name = "Tremor", texture = "Interface\\Icons\\Spell_Nature_TremorTotem", searchText = "Tremor"},
    {name = "Poison Cleansing", texture = "Interface\\Icons\\Spell_Nature_PoisonCleansingTotem", searchText = "Poison Cleansing"},
    {name = "Disease Cleansing", texture = "Interface\\Icons\\Spell_Nature_DiseaseCleansingTotem", searchText = "Disease Cleansing"},
    {name = "Mana Spring", texture = "Interface\\Icons\\Spell_Nature_ManaRegenTotem", searchText = "Mana Spring"},
}

-- Hauptfenster erstellen
local mainFrame = CreateFrame("Frame", "TTMainFrame", UIParent)
mainFrame:SetWidth(400)
mainFrame:SetHeight(70)
mainFrame:SetPoint("TOP", 0, -100)
mainFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
mainFrame:SetBackdropColor(0, 0, 0, 0.9)
mainFrame:EnableMouse(true)
mainFrame:SetMovable(true)
mainFrame:RegisterForDrag("LeftButton")
mainFrame:SetScript("OnDragStart", function() this:StartMoving() end)
mainFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
mainFrame:Hide()

-- Totem Icons erstellen
for i, totem in ipairs(TOTEMS) do
    local btn = CreateFrame("Button", "TTTotemBtn"..i, mainFrame)
    btn:SetWidth(40)
    btn:SetHeight(40)
    btn:SetPoint("LEFT", 10 + ((i-1) * 45), 0)
    
    -- Icon
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(40)
    icon:SetHeight(40)
    icon:SetPoint("CENTER")
    icon:SetTexture(totem.texture)
    btn.icon = icon
    
    -- Counter Text
    local counter = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    counter:SetPoint("BOTTOMRIGHT", 2, 2)
    counter:SetText("0")
    counter:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    btn.counter = counter
    
    -- Border für Highlight
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetWidth(44)
    border:SetHeight(44)
    border:SetPoint("CENTER")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:Hide()
    btn.border = border
    
    btn.totemData = totem
    btn.playersWithBuff = {}
    
    -- Tooltip on hover
    btn:SetScript("OnEnter", function()
        TT:ShowTotemTooltip(this)
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    TT.totemButtons[i] = btn
end

-- Funktion zum Scannen von Buffs mit Tooltip
function TT:HasTotemBuff(unit, searchText)
    if not UnitExists(unit) then
        return false
    end
    
    local buffIndex = 1
    while UnitBuff(unit, buffIndex) do
        TT.scanTooltip:ClearLines()
        TT.scanTooltip:SetUnitBuff(unit, buffIndex)
        
        local tooltipText = TTScanTooltipTextLeft1:GetText()
        if tooltipText and string.find(tooltipText, searchText) then
            return true
        end
        
        buffIndex = buffIndex + 1
    end
    
    return false
end

-- Tooltip für Totem anzeigen
function TT:ShowTotemTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(button.totemData.name.." Totem", 1, 1, 1)
    GameTooltip:AddLine(" ")
    
    local inRange = {}
    local outRange = {}
    
    for i = 1, 5 do
        local unit = (i == 1) and "player" or "party"..(i-1)
        if UnitExists(unit) then
            local name = UnitName(unit)
            local class = UnitClass(unit)
            local hasBuff = TT:HasTotemBuff(unit, button.totemData.searchText)
            
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
function TT:UpdateDisplay()
    if not TT.enabled then
        return
    end
    
    local totalPlayers = 0
    for i = 1, 5 do
        local unit = (i == 1) and "player" or "party"..(i-1)
        if UnitExists(unit) then
            totalPlayers = totalPlayers + 1
        end
    end
    
    local visibleButtons = {}
    
    for _, btn in ipairs(TT.totemButtons) do
        local count = 0
        
        for i = 1, 5 do
            local unit = (i == 1) and "player" or "party"..(i-1)
            if UnitExists(unit) then
                if TT:HasTotemBuff(unit, btn.totemData.searchText) then
                    count = count + 1
                end
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
    
    -- Sichtbare Buttons neu positionieren
    for i, btn in ipairs(visibleButtons) do
        btn:ClearAllPoints()
        btn:SetPoint("LEFT", 10 + ((i-1) * 45), 0)
    end
    
    -- Frame-Breite dynamisch anpassen
    local numVisible = table.getn(visibleButtons)
    if numVisible > 0 then
        mainFrame:SetWidth(20 + (numVisible * 45))
        mainFrame:Show()
    else
        -- Wenn keine Totems aktiv, Frame ausblenden
        mainFrame:Hide()
    end
end

-- Event Handler
TT.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
TT.frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
TT.frame:RegisterEvent("PLAYER_AURAS_CHANGED")
TT.frame:RegisterEvent("UNIT_AURA")

TT.frame:SetScript("OnEvent", function()
    TT:UpdateDisplay()
end)

-- Update Timer
local updateTimer = 0
TT.frame:SetScript("OnUpdate", function()
    updateTimer = updateTimer + arg1
    if updateTimer >= 0.5 then
        TT:UpdateDisplay()
        updateTimer = 0
    end
end)

-- Slash Commands
SLASH_TOTEMTRACKER1 = "/tt"
SLASH_TOTEMTRACKER2 = "/totem"
SlashCmdList["TOTEMTRACKER"] = function(msg)
    if TT.enabled then
        TT.enabled = false
        mainFrame:Hide()
        DEFAULT_CHAT_FRAME:AddMessage("Totem Tracker disabled")
    else
        TT.enabled = true
        TT:UpdateDisplay()
        DEFAULT_CHAT_FRAME:AddMessage("Totem Tracker enabled")
    end
end

-- Startup Message
DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00Totem Tracker loaded! Use /tt or /totem to toggle.|r")
