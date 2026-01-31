-- HamingwaysHunterTools - Vanilla 1.12
-- Autoshot timer matching Quiver's design: red reload, yellow windup

-- Version: x.y.z (x=release 0-9, y=feature 0-999, z=build 0-9999)
local VERSION = "0.3.0"

local AH = CreateFrame("Frame", "HamingwaysHunterToolsCore")

-- SavedVariables (per character): HamingwaysHunterToolsDB
-- Structure: { x, y, point, minimapPos, locked, frameWidth, frameHeight, borderSize, castbarSpacing }
local loadedMessageShown = false
local frame = nil
local barFrame = nil  -- Frame-based bar (like Quiver), not StatusBar
local barText = nil
local barTextTotal = nil
local minimapButton = nil
local configFrame = nil
local ammoFrame = nil
local ammoMenuFrame = nil
local statsFrame = nil

-- Reaction time tracking (delay between auto-shot and cast start)
local reactionTimes = {}
local lastAutoShotTime = 0
local MAX_REACTION_SAMPLES = 20  -- Keep last 20 reactions

-- Skipped auto-shots tracking
local lastCastTime = 0
local autoShotBetweenCasts = false
local skippedAutoShots = 0
local totalCastSequences = 0

-- Delayed auto-shots tracking (yellow bar reset by cast)
local delayedAutoShotTimes = {}
local MAX_DELAYED_SAMPLES = 20
local statsNeedReset = false  -- Flag to reset stats on next combat start

-- Castbar elements
local castFrame = nil
local castBarFrame = nil
local castBarText = nil
local castBarTextTime = nil
local isCasting = false
local castStartTime = 0
local castEndTime = 0
local castSpellName = ""
local lastCastEndTime = 0  -- Track when cast ended to prevent shot detection
local previewMode = false  -- For config UI preview

-- Haste buff tracker elements
local hasteFrame = nil
local hasteIcons = {}
local MAX_HASTE_ICONS = 8
local buffTimestamps = {}  -- Track when buffs were applied
local lastBuffRemaining = {}  -- Track last remaining time to detect refreshes
local maxBuffDurations = {}  -- Track maximum duration seen for each buff (by texture)

-- ============ Timer State (like Quiver) ============
local isReloading = false
local isShooting = false
local lastShotTime = 0
local weaponSpeed = 2.0
local AIMING_TIME = 0.5  -- 0.5s like Quiver (not 0.65)

-- Default config values
local DEFAULT_FRAME_WIDTH = 240
local DEFAULT_FRAME_HEIGHT = 14
local DEFAULT_BORDER_SIZE = 10
local DEFAULT_CASTBAR_SPACING = 2
local DEFAULT_ICON_SIZE = 24
local DEFAULT_AMMO_ICON_SIZE = 32
local DEFAULT_STATS_FONT_SIZE = 12
local DEFAULT_SHOW_ONLY_IN_COMBAT = false
local DEFAULT_RELOAD_COLOR = {r=1, g=0, b=0}
local DEFAULT_AIMING_COLOR = {r=1, g=1, b=0}
local DEFAULT_CAST_COLOR = {r=0.5, g=0.5, b=1}
local DEFAULT_BG_COLOR = {r=0, g=0, b=0}
local DEFAULT_BG_OPACITY = 0.8
local PLAYER_BUFF_START_ID = 0  -- Vanilla 1.12 player buff offset

-- Spell cast database for Castbar (like Quiver)
-- Time in ms, Offset in ms, Haste="range" means affected by ranged haste
local castSpells = {
    ["Aimed Shot"] = { Time=3000, Offset=500, Haste="range" },
    ["Gezielter Schuss"] = { Time=3000, Offset=500, Haste="range" },
    ["Multi-Shot"] = { Time=0, Offset=500, Haste="range" },
    ["Mehrfachschuss"] = { Time=0, Offset=500, Haste="range" },
    ["Steady Shot"] = { Time=1000, Offset=500, Haste="range" },
    ["Stetiger Schuss"] = { Time=1000, Offset=500, Haste="range" },
    ["Trueshot"] = { Time=1000, Offset=0, Haste="none" },
}

-- Known haste buffs (English and German names)
local hasteBuffs = {
    ["Rapid Fire"] = true,
    ["Schnelles Feuer"] = true,
    ["Quick Shots"] = true,
    ["Schnelle Schüsse"] = true,
    ["Berserking"] = true,
    ["Berserker"] = true,
    ["Essence of the Red"] = true,
    ["Essenz des Roten"] = true,
    ["Kiss of the Spider"] = true,
    ["Kuss der Spinne"] = true,
    ["Potion of Quickness"] = true,  -- Turtle WoW custom
    ["Swiftness"] = true,
    ["Schnelligkeit"] = true,
    ["Juju Flurry"] = true,  -- Vanilla consumable
    ["Juju der Eile"] = true,
}

-- Buff durations in seconds (for remaining time calculation)
local buffDurations = {
    ["Rapid Fire"] = 15,
    ["Schnelles Feuer"] = 15,
    ["Quick Shots"] = 12,
    ["Schnelle Schüsse"] = 12,
    ["Berserking"] = 10,
    ["Berserker"] = 10,
    ["Essence of the Red"] = 20,
    ["Essenz des Roten"] = 20,
    ["Kiss of the Spider"] = 15,
    ["Kuss der Spinne"] = 15,
    ["Potion of Quickness"] = 30,  -- Turtle WoW custom
    ["Swiftness"] = 15,
    ["Schnelligkeit"] = 15,
    ["Juju Flurry"] = 20,  -- Vanilla consumable
    ["Juju der Eile"] = 20,
}

-- Get base ranged weapon speed from tooltip
local function GetBaseWeaponSpeed()
    local scanTip = CreateFrame("GameTooltip", "HamingwaysHunterToolsWeaponScan", nil, "GameTooltipTemplate")
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    scanTip:SetInventoryItem("player", 18) -- Ranged slot
    
    for i = 1, scanTip:NumLines() do
        local text = getglobal("HamingwaysHunterToolsWeaponScanTextRight" .. i)
        if text then
            local textStr = text:GetText()
            if textStr then
                local _, _, speed = string.find(textStr, "(%d+%.%d+)")
                if speed then
                    return tonumber(speed)
                end
            end
        end
    end
    
    -- Fallback to current speed
    local currentSpeed = UnitRangedDamage("player")
    return currentSpeed or 2.0
end

-- Calculate cast time with haste (like Quiver)
local function CalcCastTime(spellName)
    local meta = castSpells[spellName]
    if not meta then return nil end
    
    if meta.Haste == "range" then
        local speedCurrent = UnitRangedDamage("player") or 2.0
        local speedWeapon = GetBaseWeaponSpeed()
        local speedMultiplier = speedCurrent / speedWeapon
        local casttime = (meta.Offset + meta.Time * speedMultiplier) / 1000
        return casttime
    else
        -- No haste
        return (meta.Offset + meta.Time) / 1000
    end
end

-- ============ Castbar Functions ============
local function UpdateCastbar()
    if not isCasting or not castFrame or not castBarFrame or not castBarText or not castBarTextTime then return end
    
    local now = GetTime()
    local elapsed = now - castStartTime
    local duration = castEndTime - castStartTime
    
    if elapsed >= duration then
        isCasting = false
        lastCastEndTime = GetTime()  -- Mark when cast ended
        castFrame:Hide()
        -- Hide main frame if needed when casting ends
        if frame then
            local showOnlyInCombat = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showOnlyInCombat
            local inCombat = UnitAffectingCombat("player")
            if showOnlyInCombat and not inCombat and not isShooting and not previewMode then
                frame:Hide()
            end
        end
        return
    end
    
    local percent = elapsed / duration
    local maxWidth = castFrame:GetWidth() - 4
    local width = math.max(1, maxWidth * percent)
    castBarFrame:SetWidth(width)
    castBarText:SetText(castSpellName)
    if HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showTimerText then
        castBarTextTime:SetText(string.format("%.2fs/%.2fs", elapsed, duration))
    else
        castBarTextTime:SetText("")
    end
end

local function StartCast(spellName, castTime)
    if not isCasting then
        isCasting = true
        castSpellName = spellName
        castStartTime = GetTime()
        castEndTime = castStartTime + castTime
        
        -- Only track statistics if stats frame is enabled
        local trackStats = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showStats
        
        -- Track reaction time if auto-shot was fired recently
        if trackStats and lastAutoShotTime > 0 then
            local reactionTime = castStartTime - lastAutoShotTime
            -- Only track if cast started within 3 seconds of auto-shot
            if reactionTime > 0 and reactionTime < 3.0 then
                table.insert(reactionTimes, reactionTime)
                -- Keep only last MAX_REACTION_SAMPLES
                if table.getn(reactionTimes) > MAX_REACTION_SAMPLES then
                    table.remove(reactionTimes, 1)
                end
                -- Reset to prevent counting multiple casts after one auto-shot
                lastAutoShotTime = 0
            end
        end
        
        -- Track skipped auto-shots (only between Steady Shots)
        if trackStats and (spellName == "Steady Shot" or spellName == "Stetiger Schuss") then
            if lastCastTime > 0 and (castStartTime - lastCastTime) < 10 then
                totalCastSequences = totalCastSequences + 1
                if not autoShotBetweenCasts then
                    skippedAutoShots = skippedAutoShots + 1
                end
            end
            lastCastTime = castStartTime
            autoShotBetweenCasts = false  -- Reset for next sequence
        end
        
        -- Track delayed auto-shots (yellow bar reset by cast, not movement)
        if trackStats and lastShotTime > 0 then
            local reloadDuration = weaponSpeed - AIMING_TIME
            local castEndTime = castStartTime + castTime
            
            -- Yellow phase: from (lastShotTime + reloadDuration) to (lastShotTime + weaponSpeed)
            local yellowPhaseStart = lastShotTime + reloadDuration
            local yellowPhaseEnd = lastShotTime + weaponSpeed
            
            -- Check if cast overlaps with yellow phase
            -- Cast overlaps if: cast starts before yellow ends AND cast ends after yellow starts
            local castOverlapsYellow = (castStartTime < yellowPhaseEnd) and (castEndTime >= yellowPhaseStart)
            
            if castOverlapsYellow then
                -- Calculate the delay: how much longer until next auto-shot compared to normal
                -- Normal: yellow phase would end at (lastShotTime + weaponSpeed)
                -- With cast: yellow phase ends at (castEndTime + AIMING_TIME)
                local normalYellowEnd = yellowPhaseEnd
                local actualYellowEnd = castEndTime + AIMING_TIME
                local delayTime = actualYellowEnd - normalYellowEnd
                
                if delayTime > 0 then
                    table.insert(delayedAutoShotTimes, delayTime)
                    if table.getn(delayedAutoShotTimes) > MAX_DELAYED_SAMPLES then
                        table.remove(delayedAutoShotTimes, 1)
                    end
                end
            end
        end
        
        if castFrame and HamingwaysHunterToolsDB.showCastbar then
            castFrame:Show()
        end
        -- Also show main frame when casting starts
        if frame and HamingwaysHunterToolsDB.showAutoShotTimer then
            local showOnlyInCombat = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showOnlyInCombat
            local inCombat = UnitAffectingCombat("player")
            if not showOnlyInCombat or inCombat or previewMode or isShooting or isCasting then
                frame:Show()
            end
        end
    end
end

-- Find spell by name (scans spellbook)
local function FindSpellByName(spellName)
    local i = 1
    while true do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then return nil end
        if name == spellName then return i end
        i = i + 1
    end
end

-- Find action bar slot by spell name (for IsCurrentAction check)
local function FindActionSlotBySpellName(spellName)
    local spellIndex = FindSpellByName(spellName)
    if not spellIndex then return nil end
    
    local texture = GetSpellTexture(spellIndex, BOOKTYPE_SPELL)
    if not texture then return nil end
    
    for slot = 1, 120 do
        if HasAction(slot) then
            local actionTexture = GetActionTexture(slot)
            if actionTexture == texture then
                return slot
            end
        end
    end
    return nil
end

-- Find spell by texture (for UseAction)
local function FindSpellByTexture(texture)
    local i = 1
    while true do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then return nil end
        local spellTexture = GetSpellTexture(i, BOOKTYPE_SPELL)
        if spellTexture == texture and castSpells[name] then
            return name
        end
        i = i + 1
    end
end

-- Handle cast attempt (validates cast is actually happening)
local function HandleCastAttempt(spellName, isCurrentAction)
    if not spellName or not castSpells[spellName] then return end
    
    local castTime = CalcCastTime(spellName)
    if not castTime or castTime <= 0 then return end
    
    -- For castable shots: verify cast is actually happening
    if isCurrentAction then
        -- Cast confirmed via IsCurrentAction
        StartCast(spellName, castTime)
    else
        -- Cast from spellbook/macro: check if spell is on action bars
        local slot = FindActionSlotBySpellName(spellName)
        if not slot then
            -- Spell not on action bars, can't verify cast - skip it
            return
        end
        -- Check if this action is now active (casting)
        if IsCurrentAction(slot) then
            StartCast(spellName, castTime)
        end
    end
end

-- Hook UseAction to detect casts from action bars
local OriginalUseAction = UseAction
UseAction = function(slot, checkCursor, onSelf)
    OriginalUseAction(slot, checkCursor, onSelf)
    
    local texture = GetActionTexture(slot)
    if texture then
        local spellName = FindSpellByTexture(texture)
        local isCurrentAction = IsCurrentAction(slot)
        HandleCastAttempt(spellName, isCurrentAction)
    end
end

-- Hook CastSpell to detect casts from spellbook
local OriginalCastSpell = CastSpell
CastSpell = function(spellId, bookType)
    OriginalCastSpell(spellId, bookType)
    
    local spellName = GetSpellName(spellId, bookType)
    HandleCastAttempt(spellName, false)
end

-- Hook CastSpellByName to detect casts from macros
local OriginalCastSpellByName = CastSpellByName
CastSpellByName = function(spellName, onSelf)
    OriginalCastSpellByName(spellName, onSelf)
    
    HandleCastAttempt(spellName, false)
end

local position = (function()
	local x, y = 0, 0
	local updateXY = function() x, y = GetPlayerMapPosition("player") end
	return {
		UpdateXY = updateXY,
		CheckStandingStill = function()
			local lastX, lastY = x, y
			updateXY()
			return x == lastX and y == lastY
		end,
	}
end)()

-- ============ Colors (dynamic from config) ============

local function UpdateWeaponSpeed()
    local speed = UnitRangedDamage("player")
    if speed and speed > 0 then
        weaponSpeed = speed
    end
end

-- ============ Config Functions ============
local function GetConfig()
    HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
    HamingwaysHunterToolsDB.minimapPos = HamingwaysHunterToolsDB.minimapPos or 225
    HamingwaysHunterToolsDB.locked = HamingwaysHunterToolsDB.locked or false
    HamingwaysHunterToolsDB.frameWidth = HamingwaysHunterToolsDB.frameWidth or DEFAULT_FRAME_WIDTH
    HamingwaysHunterToolsDB.frameHeight = HamingwaysHunterToolsDB.frameHeight or DEFAULT_FRAME_HEIGHT
    HamingwaysHunterToolsDB.borderSize = HamingwaysHunterToolsDB.borderSize or DEFAULT_BORDER_SIZE
    HamingwaysHunterToolsDB.castbarSpacing = HamingwaysHunterToolsDB.castbarSpacing or DEFAULT_CASTBAR_SPACING
    HamingwaysHunterToolsDB.iconSize = HamingwaysHunterToolsDB.iconSize or DEFAULT_ICON_SIZE
    HamingwaysHunterToolsDB.ammoIconSize = HamingwaysHunterToolsDB.ammoIconSize or DEFAULT_AMMO_ICON_SIZE
    HamingwaysHunterToolsDB.statsFontSize = HamingwaysHunterToolsDB.statsFontSize or DEFAULT_STATS_FONT_SIZE
    HamingwaysHunterToolsDB.showStats = HamingwaysHunterToolsDB.showStats ~= nil and HamingwaysHunterToolsDB.showStats or true
    HamingwaysHunterToolsDB.showAmmo = HamingwaysHunterToolsDB.showAmmo ~= nil and HamingwaysHunterToolsDB.showAmmo or true
    if HamingwaysHunterToolsDB.showAutoShotTimer == nil then
        HamingwaysHunterToolsDB.showAutoShotTimer = true
    end
    if HamingwaysHunterToolsDB.showCastbar == nil then
        HamingwaysHunterToolsDB.showCastbar = true
    end
    if HamingwaysHunterToolsDB.showBuffBar == nil then
        HamingwaysHunterToolsDB.showBuffBar = true
    end
    HamingwaysHunterToolsDB.showOnlyInCombat = HamingwaysHunterToolsDB.showOnlyInCombat ~= nil and HamingwaysHunterToolsDB.showOnlyInCombat or DEFAULT_SHOW_ONLY_IN_COMBAT
    if HamingwaysHunterToolsDB.showTimerText == nil then
        HamingwaysHunterToolsDB.showTimerText = true
    end
    HamingwaysHunterToolsDB.reloadColor = HamingwaysHunterToolsDB.reloadColor or {r=DEFAULT_RELOAD_COLOR.r, g=DEFAULT_RELOAD_COLOR.g, b=DEFAULT_RELOAD_COLOR.b}
    HamingwaysHunterToolsDB.aimingColor = HamingwaysHunterToolsDB.aimingColor or {r=DEFAULT_AIMING_COLOR.r, g=DEFAULT_AIMING_COLOR.g, b=DEFAULT_AIMING_COLOR.b}
    HamingwaysHunterToolsDB.castColor = HamingwaysHunterToolsDB.castColor or {r=DEFAULT_CAST_COLOR.r, g=DEFAULT_CAST_COLOR.g, b=DEFAULT_CAST_COLOR.b}
    HamingwaysHunterToolsDB.bgColor = HamingwaysHunterToolsDB.bgColor or {r=DEFAULT_BG_COLOR.r, g=DEFAULT_BG_COLOR.g, b=DEFAULT_BG_COLOR.b}
    HamingwaysHunterToolsDB.bgOpacity = HamingwaysHunterToolsDB.bgOpacity or DEFAULT_BG_OPACITY
    return {
        minimapPos = HamingwaysHunterToolsDB.minimapPos,
        locked = HamingwaysHunterToolsDB.locked,
        frameWidth = HamingwaysHunterToolsDB.frameWidth,
        frameHeight = HamingwaysHunterToolsDB.frameHeight,
        borderSize = HamingwaysHunterToolsDB.borderSize,
        castbarSpacing = HamingwaysHunterToolsDB.castbarSpacing,
        iconSize = HamingwaysHunterToolsDB.iconSize,
        ammoIconSize = HamingwaysHunterToolsDB.ammoIconSize,
        statsFontSize = HamingwaysHunterToolsDB.statsFontSize,
        showStats = HamingwaysHunterToolsDB.showStats,
        showAmmo = HamingwaysHunterToolsDB.showAmmo,
        showAutoShotTimer = HamingwaysHunterToolsDB.showAutoShotTimer,
        showCastbar = HamingwaysHunterToolsDB.showCastbar,
        showBuffBar = HamingwaysHunterToolsDB.showBuffBar,
        showOnlyInCombat = HamingwaysHunterToolsDB.showOnlyInCombat,
        showTimerText = HamingwaysHunterToolsDB.showTimerText,
        reloadColor = HamingwaysHunterToolsDB.reloadColor,
        aimingColor = HamingwaysHunterToolsDB.aimingColor,
        castColor = HamingwaysHunterToolsDB.castColor,
        bgColor = HamingwaysHunterToolsDB.bgColor,
        bgOpacity = HamingwaysHunterToolsDB.bgOpacity
    }
end

-- ============ Frame Update functions (defined before CreateUI) ============
local maxBarWidth = 0

local function UpdateBarShoot()
    if not barFrame or not barText or not barTextTotal then return end
    local cfg = GetConfig()
    
    -- Yellow bar: anchor LEFT, shrink left to right (inverted fill)
    barFrame:ClearAllPoints()
    barFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    
    local elapsed = lastShotTime == 0 and 0 or (GetTime() - lastShotTime)
    local reloadDuration = weaponSpeed - AIMING_TIME
    
    -- Update total time display
    if cfg.showTimerText then
        barTextTotal:SetText(string.format("%.2fs/%.2fs", elapsed, weaponSpeed))
    else
        barTextTotal:SetText("")
    end
    
    -- Only show yellow bar after reload is done
    if elapsed >= reloadDuration and elapsed < weaponSpeed then
        local windElapsed = elapsed - reloadDuration
        local windRemaining = AIMING_TIME - windElapsed
        -- Width shrinks: inverted (show empty space growing left to right)
        local percentElapsed = (windElapsed / AIMING_TIME)
        local width = math.max(1, maxBarWidth * percentElapsed)
        barFrame:SetWidth(width)
        barFrame:SetBackdropColor(cfg.aimingColor.r, cfg.aimingColor.g, cfg.aimingColor.b, 0.8)
        if cfg.showTimerText then
            barText:SetText(string.format("%.2fs", windRemaining))
        else
            barText:SetText("")
        end
    elseif elapsed >= weaponSpeed then
        -- Ready: show full yellow bar
        barFrame:SetWidth(maxBarWidth)
        barFrame:SetBackdropColor(cfg.aimingColor.r, cfg.aimingColor.g, cfg.aimingColor.b, 0.8)
        barText:SetText("")
    end
end

local function UpdateBarReload()
    if not barFrame or not barText or not barTextTotal then return end
    local cfg = GetConfig()
    
    -- Red bar: anchor LEFT, grow left to right (inverted fill)
    barFrame:ClearAllPoints()
    barFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    
    local elapsed = GetTime() - lastShotTime
    local reloadDuration = weaponSpeed - AIMING_TIME
    local remainingReload = reloadDuration - elapsed
    
    -- Update total time display
    if cfg.showTimerText then
        barTextTotal:SetText(string.format("%.2fs/%.2fs", elapsed, weaponSpeed))
    else
        barTextTotal:SetText("")
    end
    
    if remainingReload > 0 then
        -- Inverted: show empty space growing
        local percentRemaining = (remainingReload / reloadDuration)
        local width = math.max(1, maxBarWidth * percentRemaining)
        barFrame:SetWidth(width)
        barFrame:SetBackdropColor(cfg.reloadColor.r, cfg.reloadColor.g, cfg.reloadColor.b, 0.8)
        if cfg.showTimerText then
            barText:SetText(string.format("%.2fs", remainingReload))
        else
            barText:SetText("")
        end
    else
        isReloading = false
    end
end

local function UpdateAmmoDragState()
    if ammoFrame then
        local cfg = GetConfig()
        if cfg.locked then
            ammoFrame:RegisterForDrag()  -- Disable dragging
        else
            ammoFrame:RegisterForDrag("LeftButton")  -- Enable dragging
        end
    end
end

local function UpdateStatsDragState()
    if statsFrame then
        local cfg = GetConfig()
        if cfg.locked then
            statsFrame:RegisterForDrag()  -- Disable dragging
        else
            statsFrame:RegisterForDrag("LeftButton")  -- Enable dragging
        end
    end
end

local function ApplyFrameSettings()
    local cfg = GetConfig()
    
    if frame then
        frame:SetWidth(cfg.frameWidth)
        frame:SetHeight(cfg.frameHeight)
        if cfg.borderSize > 0 then
            frame:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = cfg.borderSize,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
        else
            frame:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = nil,
                edgeSize = 0,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
        end
        frame:SetBackdropColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b, cfg.bgOpacity)
        frame:EnableMouse(not cfg.locked)
        if barFrame then
            barFrame:SetHeight(cfg.frameHeight - 4)
        end
    end
    
    UpdateAmmoDragState()
    UpdateStatsDragState()
    
    if castFrame then
        castFrame:SetWidth(cfg.frameWidth)
        castFrame:SetHeight(cfg.frameHeight)
        castFrame:EnableMouse(not cfg.locked)
        if cfg.borderSize > 0 then
            castFrame:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = cfg.borderSize,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
        else
            castFrame:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = nil,
                edgeSize = 0,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
        end
        castFrame:SetBackdropColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b, cfg.bgOpacity)
        castFrame:ClearAllPoints()
        -- Position castbar relative to autoshot timer if it's shown, otherwise to screen center
        if cfg.showAutoShotTimer and frame:IsShown() then
            castFrame:SetPoint("BOTTOM", frame, "TOP", 0, cfg.castbarSpacing)
        else
            -- Position independently when autoshot timer is hidden
            if not castFrame.independentPosition then
                castFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
                castFrame.independentPosition = true
            end
        end
        if castBarFrame then
            castBarFrame:SetHeight(cfg.frameHeight - 4)
            castBarFrame:SetBackdropColor(cfg.castColor.r, cfg.castColor.g, cfg.castColor.b, 0.8)
        end
    end
    
    if hasteFrame then
        hasteFrame:SetWidth(cfg.frameWidth)
        hasteFrame:SetHeight(cfg.iconSize + 4)
    end
    
    if ammoMenuFrame then
        if cfg.borderSize > 0 then
            ammoMenuFrame:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false,
                edgeSize = cfg.borderSize,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
        else
            ammoMenuFrame:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = nil,
                tile = false,
                edgeSize = 0,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
        end
        ammoMenuFrame:SetBackdropColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b, cfg.bgOpacity)
    end
    
    maxBarWidth = cfg.frameWidth - 4
end

local function ApplyIconSize(iconSize)
    if hasteFrame then
        hasteFrame:SetHeight(iconSize + 4)
        for i = 1, MAX_HASTE_ICONS do
            if hasteIcons[i] then
                hasteIcons[i]:SetWidth(iconSize)
                hasteIcons[i]:SetHeight(iconSize)
            end
        end
    end
end

local function ApplyAmmoIconSize(iconSize)
    if ammoFrame then
        local frameSize = iconSize + 16  -- Icon + padding
        ammoFrame:SetWidth(frameSize)
        ammoFrame:SetHeight(frameSize)
        if ammoFrame.icon then
            ammoFrame.icon:SetWidth(iconSize)
            ammoFrame.icon:SetHeight(iconSize)
        end
    end
end

local function UpdateFrameVisibility()
    local showOnlyInCombat = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showOnlyInCombat
    local inCombat = UnitAffectingCombat("player")
    local shouldShow = not showOnlyInCombat or inCombat or previewMode or isCasting or isShooting
    
    -- AutoShot Timer Frame
    if frame and HamingwaysHunterToolsDB.showAutoShotTimer then
        if shouldShow then
            frame:Show()
        else
            frame:Hide()
        end
    elseif frame then
        frame:Hide()
    end
    
    -- Castbar - only hide if toggle is off OR if combat-only mode requires it
    if castFrame then
        if not HamingwaysHunterToolsDB.showCastbar then
            castFrame:Hide()
        elseif showOnlyInCombat and not inCombat and not isCasting and not previewMode then
            castFrame:Hide()
        end
    end
    
    -- BuffBar - respect both toggle and combat setting
    if hasteFrame then
        if not HamingwaysHunterToolsDB.showBuffBar then
            hasteFrame:Hide()
        elseif not shouldShow then
            hasteFrame:Hide()
        end
    end
end

-- ============ Haste Buff Tracker Functions ============
local function UpdateHasteBuffs()
    if not hasteFrame then return end
    if previewMode then return end  -- Don't update buffs in preview mode
    
    local activeBuffs = {}
    local currentTime = GetTime()
    local foundBuffs = {}
    
    -- Store last scan time for refresh detection
    if not hasteFrame.lastScanTime then
        hasteFrame.lastScanTime = currentTime
    end
    local timeSinceLastScan = currentTime - hasteFrame.lastScanTime
    hasteFrame.lastScanTime = currentTime
    
    -- Scan all buff slots (Vanilla 1.12 API)
    for i = 0, 31 do
        -- Get buff directly via GetPlayerBuff
        local buffId = GetPlayerBuff(PLAYER_BUFF_START_ID + i, "HELPFUL")
        if buffId >= 0 then
            local buffTexture = GetPlayerBuffTexture(buffId)
            local buffCount = GetPlayerBuffApplications(buffId)
            local actualRemaining = GetPlayerBuffTimeLeft(buffId)
            
            if buffTexture then
                -- Get buff name by scanning tooltip
                local tooltip = getglobal("HamingwaysHunterToolsBuffTooltip") or CreateFrame("GameTooltip", "HamingwaysHunterToolsBuffTooltip", nil, "GameTooltipTemplate")
                tooltip:SetOwner(UIParent, "ANCHOR_NONE")
                tooltip:ClearLines()
                tooltip:SetPlayerBuff(buffId)
                
                local buffName = getglobal("HamingwaysHunterToolsBuffTooltipTextLeft1"):GetText()
                
                if buffName and hasteBuffs[buffName] then
                    local duration = buffDurations[buffName] or 15
                    
                    -- Track buff if new
                    if not buffTimestamps[buffName] then
                        buffTimestamps[buffName] = currentTime
                        maxBuffDurations[buffTexture] = actualRemaining > 0 and actualRemaining or duration
                        lastBuffRemaining[buffName] = actualRemaining
                    end
                    
                    -- Detect buff refresh: if actual remaining > stored max, buff was refreshed
                    if actualRemaining > 0 then
                        if not maxBuffDurations[buffTexture] then
                            maxBuffDurations[buffTexture] = actualRemaining
                        elseif maxBuffDurations[buffTexture] < actualRemaining then
                            -- Actual time is higher than max seen, buff was refreshed
                            maxBuffDurations[buffTexture] = actualRemaining
                            buffTimestamps[buffName] = currentTime
                        end
                    end
                    
                    local remaining = actualRemaining > 0 and actualRemaining or 0
                    lastBuffRemaining[buffName] = remaining
                    foundBuffs[buffName] = true
                    
                    table.insert(activeBuffs, {
                        name = buffName,
                        texture = buffTexture,
                        count = buffCount or 0,
                        remaining = remaining
                    })
                end
            end
        end
    end
    
    -- Clean up timestamps for buffs that are no longer active
    for buffName, _ in pairs(buffTimestamps) do
        if not foundBuffs[buffName] then
            buffTimestamps[buffName] = nil
            lastBuffRemaining[buffName] = nil
        end
    end
    
    -- Update icons
    local cfg = GetConfig()
    local iconSize = cfg.iconSize or DEFAULT_ICON_SIZE
    
    for i = 1, MAX_HASTE_ICONS do
        if not hasteIcons[i] then
            hasteIcons[i] = CreateFrame("Frame", nil, hasteFrame)
            hasteIcons[i]:SetWidth(iconSize)
            hasteIcons[i]:SetHeight(iconSize)
            
            hasteIcons[i].icon = hasteIcons[i]:CreateTexture(nil, "BACKGROUND")
            hasteIcons[i].icon:SetAllPoints()
            hasteIcons[i].icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            
            hasteIcons[i].cooldown = hasteIcons[i]:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            hasteIcons[i].cooldown:SetPoint("BOTTOM", 0, 2)
            hasteIcons[i].cooldown:SetTextColor(1, 1, 1, 1)
            
            if i == 1 then
                hasteIcons[i]:SetPoint("TOPLEFT", hasteFrame, "TOPLEFT", 2, -2)
            else
                hasteIcons[i]:SetPoint("LEFT", hasteIcons[i-1], "RIGHT", 2, 0)
            end
        else
            -- Update size for existing icons
            hasteIcons[i]:SetWidth(iconSize)
            hasteIcons[i]:SetHeight(iconSize)
        end
        
        if activeBuffs[i] then
            hasteIcons[i].icon:SetTexture(activeBuffs[i].texture)
            -- Show remaining time in seconds (no decimals, no unit)
            local seconds = math.floor(activeBuffs[i].remaining)
            hasteIcons[i].cooldown:SetText(tostring(seconds))
            hasteIcons[i]:Show()
        else
            hasteIcons[i]:Hide()
        end
    end
    
    -- Show/hide frame based on active buffs and combat setting
    if table.getn(activeBuffs) > 0 and HamingwaysHunterToolsDB.showBuffBar then
        local showOnlyInCombat = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showOnlyInCombat
        local inCombat = UnitAffectingCombat("player")
        if not showOnlyInCombat or inCombat or previewMode or isCasting or isShooting then
            hasteFrame:Show()
        end
    else
        hasteFrame:Hide()
    end
end

-- ============ Ammo Frame Functions ============
local function FindAmmoInBags()
    local ammoList = {}
    local scanTip = getglobal("HamingwaysHunterToolsAmmoScanTooltip") or CreateFrame("GameTooltip", "HamingwaysHunterToolsAmmoScanTooltip", nil, "GameTooltipTemplate")
    
    -- Scan all bags (0-4)
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local texture, count = GetContainerItemInfo(bag, slot)
                if texture and count then
                    -- Use tooltip to check item
                    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
                    scanTip:ClearLines()
                    scanTip:SetBagItem(bag, slot)
                    
                    -- Get item name from first line
                    local nameText = getglobal("HamingwaysHunterToolsAmmoScanTooltipTextLeft1")
                    local itemName = nameText and nameText:GetText()
                    
                    if itemName then
                        -- Check all tooltip lines for ammo indicators
                        local isAmmo = false
                        for i = 1, scanTip:NumLines() do
                            local lineText = getglobal("HamingwaysHunterToolsAmmoScanTooltipTextLeft" .. i)
                            if lineText then
                                local text = lineText:GetText()
                                if text then
                                    -- Look for projectile indicators
                                    local lowerText = string.lower(text)
                                    if string.find(lowerText, "arrow") or 
                                       string.find(lowerText, "bullet") or 
                                       string.find(lowerText, "pfeil") or 
                                       string.find(lowerText, "kugel") or
                                       string.find(lowerText, "projectile") or
                                       string.find(lowerText, "projektil") or
                                       string.find(lowerText, "ammo") or
                                       string.find(lowerText, "munition") then
                                        isAmmo = true
                                        break
                                    end
                                end
                            end
                        end
                        
                        if isAmmo then
                            -- Check if this ammo is not already in list
                            local exists = false
                            for j, ammo in ipairs(ammoList) do
                                if ammo and ammo.name == itemName then
                                    ammo.count = ammo.count + count
                                    exists = true
                                    break
                                end
                            end
                            
                            if not exists then
                                table.insert(ammoList, {
                                    name = itemName,
                                    texture = texture,
                                    count = count,
                                    bag = bag,
                                    slot = slot
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    
    scanTip:Hide()
    return ammoList
end

local function UpdateAmmoDisplay()
    if not ammoFrame then return end
    if not HamingwaysHunterToolsDB.showAmmo then
        ammoFrame:Hide()
        return
    end
    
    local ammoSlot = 0  -- Ammo slot in Vanilla
    local ammoTexture = GetInventoryItemTexture("player", ammoSlot)
    local ammoCount = GetInventoryItemCount("player", ammoSlot)
    
    if ammoTexture and ammoCount and ammoCount > 0 then
        ammoFrame.icon:SetTexture(ammoTexture)
        ammoFrame.text:SetText(tostring(ammoCount))
        
        -- Color based on count: green > 300, yellow <= 300 and > 100, red <= 100
        if ammoCount > 300 then
            ammoFrame.text:SetTextColor(0, 1, 0, 1)  -- Green
            -- Stop blinking and reset icon color
            if ammoFrame.blinkTimer then
                ammoFrame.blinkTimer = nil
                ammoFrame.icon:SetVertexColor(1, 1, 1, 1)  -- Normal white
            end
        elseif ammoCount > 100 then
            ammoFrame.text:SetTextColor(1, 1, 0, 1)  -- Yellow
            -- Stop blinking and reset icon color
            if ammoFrame.blinkTimer then
                ammoFrame.blinkTimer = nil
                ammoFrame.icon:SetVertexColor(1, 1, 1, 1)  -- Normal white
            end
        else
            ammoFrame.text:SetTextColor(1, 0, 0, 1)  -- Red
            -- Start blinking red icon
            if not ammoFrame.blinkTimer then
                ammoFrame.blinkTimer = 0
            end
        end
        
        ammoFrame:Show()
    else
        -- No ammo: show warning icon and blink
        ammoFrame.icon:SetTexture("Interface\\Icons\\Inv_Misc_QuestionMark")
        ammoFrame.text:SetText("0")
        ammoFrame.text:SetTextColor(1, 0, 0, 1)  -- Red
        -- Start blinking
        if not ammoFrame.blinkTimer then
            ammoFrame.blinkTimer = 0
        end
        ammoFrame:Show()
    end
end

local function EquipAmmo(bag, slot)
    -- Pick up ammo from bag
    PickupContainerItem(bag, slot)
    -- Equip it to ammo slot (slot 0)
    PickupInventoryItem(0)
end

local function ShowAmmoMenu()
    if not ammoMenuFrame then
        -- Create menu frame
        local cfg = GetConfig()
        ammoMenuFrame = CreateFrame("Frame", "HamingwaysHunterToolsAmmoMenu", UIParent)
        ammoMenuFrame:SetFrameStrata("DIALOG")
        if cfg.borderSize > 0 then
            ammoMenuFrame:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false,
                edgeSize = cfg.borderSize,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
        else
            ammoMenuFrame:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = nil,
                tile = false,
                edgeSize = 0,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
        end
        ammoMenuFrame:SetBackdropColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b, cfg.bgOpacity)
        ammoMenuFrame:EnableMouse(true)
        ammoMenuFrame.buttons = {}
    end
    
    -- Hide old buttons
    for _, btn in ipairs(ammoMenuFrame.buttons) do
        btn:Hide()
    end
    
    local ammoList = FindAmmoInBags()
    
    if table.getn(ammoList) == 0 then
        ammoMenuFrame:Hide()
        return
    end
    
    -- Calculate frame size
    local buttonHeight = 32
    local padding = 8
    local frameHeight = table.getn(ammoList) * (buttonHeight + 2) + padding * 2
    local frameWidth = 200
    
    ammoMenuFrame:SetWidth(frameWidth)
    ammoMenuFrame:SetHeight(frameHeight)
    ammoMenuFrame:ClearAllPoints()
    ammoMenuFrame:SetPoint("BOTTOM", ammoFrame, "TOP", 0, 5)
    
    -- Create/update buttons
    for i, ammo in ipairs(ammoList) do
        local btn = ammoMenuFrame.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, ammoMenuFrame)
            btn:SetWidth(frameWidth - padding * 2)
            btn:SetHeight(buttonHeight)
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            
            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetWidth(buttonHeight - 4)
            btn.icon:SetHeight(buttonHeight - 4)
            btn.icon:SetPoint("LEFT", 4, 0)
            btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            
            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            btn.text:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)
            btn.text:SetJustifyH("LEFT")
            
            btn.count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            btn.count:SetPoint("RIGHT", -4, 0)
            btn.count:SetJustifyH("RIGHT")
            
            ammoMenuFrame.buttons[i] = btn
        end
        
        btn.icon:SetTexture(ammo.texture)
        btn.text:SetText(ammo.name)
        btn.count:SetText(tostring(ammo.count))
        btn.ammoBag = ammo.bag
        btn.ammoSlot = ammo.slot
        
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", padding, -(padding + (i - 1) * (buttonHeight + 2)))
        
        btn:SetScript("OnClick", function()
            EquipAmmo(this.ammoBag, this.ammoSlot)
            ammoMenuFrame:Hide()
            UpdateAmmoDisplay()
        end)
        
        btn:SetScript("OnEnter", function()
            if this.ammoBag and this.ammoSlot then
                GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
                GameTooltip:SetBagItem(this.ammoBag, this.ammoSlot)
                GameTooltip:Show()
            end
        end)
        
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        
        btn:Show()
    end
    
    ammoMenuFrame:Show()
end

-- ============ Statistics Frame Functions ============
local function ReportStats(channel)
    local avgReaction = 0
    local minReaction = 9999
    local maxReaction = 0
    local count = table.getn(reactionTimes)
    
    if count > 0 then
        local sum = 0
        for i, time in ipairs(reactionTimes) do
            sum = sum + time
            if time < minReaction then minReaction = time end
            if time > maxReaction then maxReaction = time end
        end
        avgReaction = sum / count
    else
        minReaction = 0
    end
    
    local skippedPercent = 0
    if totalCastSequences > 0 then
        skippedPercent = (skippedAutoShots / totalCastSequences) * 100
    end
    
    local delayedCount = table.getn(delayedAutoShotTimes)
    local totalDelayed = 0
    if delayedCount > 0 then
        for i, time in ipairs(delayedAutoShotTimes) do
            totalDelayed = totalDelayed + time
        end
    end
    
    -- Format report message (escape pipe characters for chat)
    local msg1 = string.format("[HHT] Avg: %.3fs - Min: %.3fs - Max: %.3fs - Samples: %d", avgReaction, minReaction, maxReaction, count)
    local msg2 = string.format("[HHT] Skipped AS: %d (%.1f%%) - AS delays: %d (%.3fs total)", skippedAutoShots, skippedPercent, delayedCount, totalDelayed)
    
    -- Send to channel
    if channel == "WHISPER" then
        local targetName = UnitName("target")
        if targetName then
            SendChatMessage(msg1, "WHISPER", nil, targetName)
            SendChatMessage(msg2, "WHISPER", nil, targetName)
        else
            print("HHT: No target selected for whisper")
        end
    else
        SendChatMessage(msg1, channel)
        SendChatMessage(msg2, channel)
    end
end

local function ResetStats()
    reactionTimes = {}
    lastAutoShotTime = 0
    lastCastTime = 0
    autoShotBetweenCasts = false
    skippedAutoShots = 0
    totalCastSequences = 0
    delayedAutoShotTimes = {}
    print("HHT: Reaction time statistics reset")
end

local statsContextMenu = nil

local function ShowStatsContextMenu()
    if statsContextMenu and statsContextMenu:IsShown() then
        statsContextMenu:Hide()
        return
    end
    
    if not statsContextMenu then
        statsContextMenu = CreateFrame("Frame", "HamingwaysHunterToolsStatsContextMenu", UIParent)
        statsContextMenu:SetFrameStrata("TOOLTIP")
        statsContextMenu:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        local cfg = GetConfig()
        statsContextMenu:SetBackdropColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b, cfg.bgOpacity)
        statsContextMenu:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
        statsContextMenu:EnableMouse(true)
        statsContextMenu:SetWidth(120)
        statsContextMenu:SetHeight(117)
        statsContextMenu:SetPoint("CENTER", UIParent, "CENTER")
        statsContextMenu.buttons = {}
        
        -- Reset button
        local resetBtn = CreateFrame("Button", nil, statsContextMenu)
        resetBtn:SetWidth(110)
        resetBtn:SetHeight(20)
        resetBtn:SetPoint("TOP", statsContextMenu, "TOP", 0, -5)
        resetBtn:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        resetBtn:SetBackdropColor(0.2, 0.2, 0.2, 1)
        resetBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        local resetText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        resetText:SetPoint("CENTER", resetBtn, "CENTER")
        resetText:SetText("Reset")
        resetBtn:SetScript("OnClick", function()
            ResetStats()
            statsContextMenu:Hide()
        end)
        resetBtn:SetScript("OnEnter", function()
            this:SetBackdropColor(0.3, 0.3, 0.3, 1)
        end)
        resetBtn:SetScript("OnLeave", function()
            this:SetBackdropColor(0.2, 0.2, 0.2, 1)
        end)
        
        -- Report buttons
        local channels = {
            {name = "Say", channel = "SAY"},
            {name = "Party", channel = "PARTY"},
            {name = "Guild", channel = "GUILD"},
            {name = "Raid", channel = "RAID"},
            {name = "Whisper", channel = "WHISPER"}
        }
        
        for i, ch in ipairs(channels) do
            local btn = CreateFrame("Button", nil, statsContextMenu)
            btn:SetWidth(110)
            btn:SetHeight(16)
            btn:SetPoint("TOP", statsContextMenu, "TOP", 0, -30 - (i-1)*17)
            btn:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false, edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
            btn:SetBackdropColor(0.2, 0.2, 0.2, 1)
            btn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
            local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            btnText:SetPoint("CENTER", btn, "CENTER")
            btnText:SetText("Report > " .. ch.name)
            btn.channel = ch.channel
            btn:SetScript("OnClick", function()
                ReportStats(this.channel)
                statsContextMenu:Hide()
            end)
            btn:SetScript("OnEnter", function()
                this:SetBackdropColor(0.3, 0.3, 0.3, 1)
            end)
            btn:SetScript("OnLeave", function()
                this:SetBackdropColor(0.2, 0.2, 0.2, 1)
            end)
        end
    end
    
    -- Position menu next to stats frame
    statsContextMenu:ClearAllPoints()
    statsContextMenu:SetPoint("LEFT", statsFrame, "RIGHT", 5, 0)
    statsContextMenu:Show()
end

local function UpdateStatsDisplay()
    if not statsFrame or not HamingwaysHunterToolsDB.showStats then 
        if statsFrame then statsFrame:Hide() end
        return 
    end
    
    local avgReaction = 0
    local minReaction = 9999
    local maxReaction = 0
    local lastReaction = 0
    local count = table.getn(reactionTimes)
    
    if count > 0 then
        local sum = 0
        for i, time in ipairs(reactionTimes) do
            sum = sum + time
            if time < minReaction then minReaction = time end
            if time > maxReaction then maxReaction = time end
        end
        avgReaction = sum / count
        lastReaction = reactionTimes[count]
    else
        minReaction = 0
    end
    
    -- Color coding function: green <= 0.2, yellow <= 0.35, red > 0.35
    local function GetColorForTime(time)
        if time <= 0.2 then
            return 0, 1, 0  -- Green
        elseif time <= 0.35 then
            return 1, 1, 0  -- Yellow
        else
            return 1, 0, 0  -- Red
        end
    end
    
    if statsFrame.avgText then
        statsFrame.avgText:SetText(string.format("Avg Reaction: %.3fs", avgReaction))
        local r, g, b = GetColorForTime(avgReaction)
        statsFrame.avgText:SetTextColor(r, g, b, 1)
    end
    if statsFrame.minText then
        statsFrame.minText:SetText(string.format("Min: %.3fs", minReaction))
        local r, g, b = GetColorForTime(minReaction)
        statsFrame.minText:SetTextColor(r, g, b, 1)
    end
    if statsFrame.maxText then
        statsFrame.maxText:SetText(string.format("Max: %.3fs", maxReaction))
        local r, g, b = GetColorForTime(maxReaction)
        statsFrame.maxText:SetTextColor(r, g, b, 1)
    end
    if statsFrame.lastText then
        statsFrame.lastText:SetText(string.format("Last: %.3fs", lastReaction))
        local r, g, b = GetColorForTime(lastReaction)
        statsFrame.lastText:SetTextColor(r, g, b, 1)
    end
    if statsFrame.countText then
        statsFrame.countText:SetText(string.format("Samples: %d", count))
        statsFrame.countText:SetTextColor(1, 1, 1, 1)  -- White
    end
    
    -- Calculate skipped auto-shots percentage
    local skippedPercent = 0
    if totalCastSequences > 0 then
        skippedPercent = (skippedAutoShots / totalCastSequences) * 100
    end
    
    -- Calculate delayed auto-shot statistics
    local lastDelayed = 0
    local totalDelayed = 0
    local delayedCount = table.getn(delayedAutoShotTimes)
    if delayedCount > 0 then
        for i, time in ipairs(delayedAutoShotTimes) do
            totalDelayed = totalDelayed + time
        end
        lastDelayed = delayedAutoShotTimes[delayedCount]
    end
    
    if statsFrame.skippedText then
        statsFrame.skippedText:SetText(string.format("Skipped AS: %d (%.1f%%)", skippedAutoShots, skippedPercent))
        -- Color: green if 0%, yellow if <20%, red if >=20%
        if skippedPercent == 0 then
            statsFrame.skippedText:SetTextColor(0, 1, 0, 1)
        elseif skippedPercent < 20 then
            statsFrame.skippedText:SetTextColor(1, 1, 0, 1)
        else
            statsFrame.skippedText:SetTextColor(1, 0, 0, 1)
        end
    end
    if statsFrame.lastDelayedText then
        statsFrame.lastDelayedText:SetText(string.format("Last AS delay: %.3fs", lastDelayed))
        local r, g, b = GetColorForTime(lastDelayed)
        statsFrame.lastDelayedText:SetTextColor(r, g, b, 1)
    end
    if statsFrame.totalDelayedText then
        statsFrame.totalDelayedText:SetText(string.format("AS delay total: %.3fs", totalDelayed))
        local r, g, b = GetColorForTime(totalDelayed)
        statsFrame.totalDelayedText:SetTextColor(r, g, b, 1)
    end
    if statsFrame.delayedCountText then
        statsFrame.delayedCountText:SetText(string.format("Nr AS delays: %d", delayedCount))
        statsFrame.delayedCountText:SetTextColor(1, 1, 1, 1)  -- White
    end
    
    statsFrame:Show()
end

local function CreateStatsFrame()
    local cfg = GetConfig()
    local fontSize = cfg.statsFontSize or DEFAULT_STATS_FONT_SIZE
    
    statsFrame = CreateFrame("Frame", "HamingwaysHunterToolsStatsFrame", UIParent)
    statsFrame:SetWidth(180)
    statsFrame:SetHeight(182)  -- Increased height for new fields
    statsFrame:SetFrameStrata("HIGH")
    statsFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    statsFrame:SetBackdropColor(0, 0, 0, 0.8)
    statsFrame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    statsFrame:SetPoint("CENTER", UIParent, "CENTER", 250, 150)
    
    -- Title
    statsFrame.title = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.title:SetPoint("TOP", 0, -6)
    statsFrame.title:SetText("Reaction Time")
    statsFrame.title:SetTextColor(1, 0.82, 0, 1)
    
    -- Average Reaction
    statsFrame.avgText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.avgText:SetPoint("TOPLEFT", 8, -22)
    statsFrame.avgText:SetText("Avg Reaction: 0.000s")
    statsFrame.avgText:SetJustifyH("LEFT")
    
    -- Min Reaction
    statsFrame.minText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.minText:SetPoint("TOPLEFT", 8, -38)
    statsFrame.minText:SetText("Min: 0.000s")
    statsFrame.minText:SetJustifyH("LEFT")
    
    -- Max Reaction
    statsFrame.maxText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.maxText:SetPoint("TOPLEFT", 8, -54)
    statsFrame.maxText:SetText("Max: 0.000s")
    statsFrame.maxText:SetJustifyH("LEFT")
    
    -- Last Reaction
    statsFrame.lastText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.lastText:SetPoint("TOPLEFT", 8, -70)
    statsFrame.lastText:SetText("Last: 0.000s")
    statsFrame.lastText:SetJustifyH("LEFT")
    
    -- Sample Count
    statsFrame.countText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.countText:SetPoint("TOPLEFT", 8, -86)
    statsFrame.countText:SetText("Samples: 0")
    statsFrame.countText:SetJustifyH("LEFT")
    
    -- Separator
    statsFrame.separator = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.separator:SetPoint("TOPLEFT", 8, -102)
    statsFrame.separator:SetText("--- Details ---")
    statsFrame.separator:SetTextColor(0.5, 0.5, 0.5, 1)
    statsFrame.separator:SetJustifyH("LEFT")
    
    -- Skipped Auto-Shots
    statsFrame.skippedText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.skippedText:SetPoint("TOPLEFT", 8, -118)
    statsFrame.skippedText:SetText("Skipped AS: 0 (0.0%)")
    statsFrame.skippedText:SetJustifyH("LEFT")
    
    -- Last AS delay
    statsFrame.lastDelayedText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.lastDelayedText:SetPoint("TOPLEFT", 8, -134)
    statsFrame.lastDelayedText:SetText("Last AS delay: 0.000s")
    statsFrame.lastDelayedText:SetJustifyH("LEFT")
    
    -- Total AS delay
    statsFrame.totalDelayedText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.totalDelayedText:SetPoint("TOPLEFT", 8, -150)
    statsFrame.totalDelayedText:SetText("AS delay total: 0.000s")
    statsFrame.totalDelayedText:SetJustifyH("LEFT")
    
    -- Nr AS delays
    statsFrame.delayedCountText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.delayedCountText:SetPoint("TOPLEFT", 8, -166)
    statsFrame.delayedCountText:SetText("Nr AS delays: 0")
    statsFrame.delayedCountText:SetJustifyH("LEFT")
    
    -- Dragging (only when unlocked)
    statsFrame:EnableMouse(true)
    statsFrame:SetMovable(true)
    
    statsFrame:SetScript("OnDragStart", function()
        local cfg = GetConfig()
        if not cfg.locked then
            this:StartMoving()
        end
    end)
    statsFrame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local point, _, _, xOfs, yOfs = this:GetPoint()
        HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
        HamingwaysHunterToolsDB.statsPoint = point
        HamingwaysHunterToolsDB.statsX = xOfs
        HamingwaysHunterToolsDB.statsY = yOfs
    end)
    
    -- Right-click context menu
    statsFrame:SetScript("OnMouseDown", function()
        if arg1 == "RightButton" then
            ShowStatsContextMenu()
        end
    end)
    
    -- Tooltip
    statsFrame:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reaction Time", 1, 1, 1)
        GameTooltip:AddLine("Shows the delay between", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Auto-Shot and Cast-Start", 0.8, 0.8, 0.8)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Right-click for options", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    statsFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Update throttle
    statsFrame:SetScript("OnUpdate", function()
        if not this.statsThrottle then this.statsThrottle = 0 end
        if not this.lastUpdate then this.lastUpdate = GetTime() end
        local now = GetTime()
        local elapsed = now - this.lastUpdate
        this.lastUpdate = now
        this.statsThrottle = this.statsThrottle + elapsed
        if this.statsThrottle >= 0.2 then  -- Update every 0.2s
            UpdateStatsDisplay()
            this.statsThrottle = 0
        end
    end)
    
    return statsFrame
end

local function CreateAmmoFrame()
    local cfg = GetConfig()
    local iconSize = cfg.ammoIconSize or DEFAULT_AMMO_ICON_SIZE
    
    ammoFrame = CreateFrame("Button", "HamingwaysHunterToolsAmmoFrame", UIParent)
    ammoFrame:SetWidth(iconSize)
    ammoFrame:SetHeight(iconSize + 20)  -- Extra height for text
    ammoFrame:SetFrameStrata("HIGH")
    ammoFrame:SetPoint("CENTER", UIParent, "CENTER", 200, -202)
    
    -- Icon (no border)
    ammoFrame.icon = ammoFrame:CreateTexture(nil, "ARTWORK")
    ammoFrame.icon:SetPoint("TOP", 0, 0)
    ammoFrame.icon:SetWidth(iconSize)
    ammoFrame.icon:SetHeight(iconSize)
    ammoFrame.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    
    -- Count text
    ammoFrame.text = ammoFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ammoFrame.text:SetPoint("TOP", ammoFrame.icon, "BOTTOM", 0, -2)
    ammoFrame.text:SetTextColor(1, 1, 1, 1)
    ammoFrame.text:SetText("")
    
    -- Dragging (only when unlocked) and clicking (always enabled)
    ammoFrame:EnableMouse(true)
    ammoFrame:SetMovable(true)
    
    ammoFrame:SetScript("OnClick", function()
        if ammoMenuFrame and ammoMenuFrame:IsShown() then
            ammoMenuFrame:Hide()
        else
            ShowAmmoMenu()
        end
    end)
    
    ammoFrame:SetScript("OnDragStart", function()
        local cfg = GetConfig()
        if not cfg.locked then
            this:StartMoving()
        end
    end)
    ammoFrame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local point, _, _, xOfs, yOfs = this:GetPoint()
        HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
        HamingwaysHunterToolsDB.ammoPoint = point
        HamingwaysHunterToolsDB.ammoX = xOfs
        HamingwaysHunterToolsDB.ammoY = yOfs
    end)
    
    -- Tooltip
    ammoFrame:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetInventoryItem("player", 0)
        GameTooltip:Show()
    end)
    ammoFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Update throttle
    ammoFrame:SetScript("OnUpdate", function()
        if not this.ammoThrottle then this.ammoThrottle = 0 end
        if not this.lastUpdate then this.lastUpdate = GetTime() end
        local now = GetTime()
        local elapsed = now - this.lastUpdate
        this.lastUpdate = now
        this.ammoThrottle = this.ammoThrottle + elapsed
        if this.ammoThrottle >= 0.5 then  -- Update every 0.5s
            UpdateAmmoDisplay()
            this.ammoThrottle = 0
        end
        
        -- Handle blinking when ammo is low (red) - blink the icon
        if this.blinkTimer then
            this.blinkTimer = this.blinkTimer + elapsed
            -- Blink every 0.5 seconds (on for 0.25s, off for 0.25s)
            local blinkCycle = math.mod(this.blinkTimer, 0.5)
            if blinkCycle < 0.25 then
                this.icon:SetVertexColor(1, 0, 0, 1)  -- Red icon
            else
                this.icon:SetVertexColor(1, 1, 1, 1)  -- Normal icon
            end
        end
    end)
    
    return ammoFrame
end

-- ============ Config Preview Functions ============
-- ============ Config Preview Functions ============
local function ShowConfigPreview()
    previewMode = true
    local cfg = GetConfig()
    local iconSize = cfg.iconSize or DEFAULT_ICON_SIZE
    
    -- Show AutoShot frame in preview (only if enabled)
    if frame and cfg.showAutoShotTimer then
        frame:Show()
    end
    
    -- Show castbar with preview (only if enabled)
    if castFrame and castBarFrame and castBarText and castBarTextTime and cfg.showCastbar then
        castFrame:Show()
        castBarFrame:SetWidth((cfg.frameWidth - 4) * 0.6)
        castBarText:SetText("Aimed Shot")
        if cfg.showTimerText then
            castBarTextTime:SetText("1.80s/3.00s")
        else
            castBarTextTime:SetText("")
        end
    end
    
    -- Show all haste buffs in preview (only if enabled)
    if hasteFrame and cfg.showBuffBar then
        hasteFrame:Show()  -- Ensure frame is visible
        
        local previewBuffs = {
            {name = "Rapid Fire", texture = "Interface\\Icons\\Ability_Hunter_RunningShot", remaining = 15},
            {name = "Quick Shots", texture = "Interface\\Icons\\Ability_Warrior_InnerRage", remaining = 12},
            {name = "Berserking", texture = "Interface\\Icons\\Racial_Troll_Berserking", remaining = 10},
            {name = "Essence of the Red", texture = "Interface\\Icons\\INV_Potion_26", remaining = 20},
            {name = "Kiss of the Spider", texture = "Interface\\Icons\\INV_Misc_MonsterSpiderCarapace_01", remaining = 15},
            {name = "Potion of Quickness", texture = "Interface\\Icons\\INV_Potion_03", remaining = 30},
            {name = "Juju Flurry", texture = "Interface\\Icons\\INV_Misc_MonsterClaw_04", remaining = 20},
        }
        
        for i = 1, MAX_HASTE_ICONS do
            if not hasteIcons[i] then
                hasteIcons[i] = CreateFrame("Frame", nil, hasteFrame)
                hasteIcons[i]:SetWidth(iconSize)
                hasteIcons[i]:SetHeight(iconSize)
                
                hasteIcons[i].icon = hasteIcons[i]:CreateTexture(nil, "BACKGROUND")
                hasteIcons[i].icon:SetAllPoints()
                hasteIcons[i].icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                
                hasteIcons[i].cooldown = hasteIcons[i]:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                hasteIcons[i].cooldown:SetPoint("BOTTOM", 0, 2)
                hasteIcons[i].cooldown:SetTextColor(1, 1, 1, 1)
                
                if i == 1 then
                    hasteIcons[i]:SetPoint("TOPLEFT", hasteFrame, "TOPLEFT", 2, -2)
                else
                    hasteIcons[i]:SetPoint("LEFT", hasteIcons[i-1], "RIGHT", 2, 0)
                end
            else
                hasteIcons[i]:SetWidth(iconSize)
                hasteIcons[i]:SetHeight(iconSize)
            end
            
            if previewBuffs[i] then
                hasteIcons[i].icon:SetTexture(previewBuffs[i].texture)
                hasteIcons[i].cooldown:SetText(tostring(previewBuffs[i].remaining))
                hasteIcons[i]:Show()
            else
                hasteIcons[i]:Hide()
            end
        end
        
        hasteFrame:Show()
    end
end

local function HideConfigPreview()
    previewMode = false
    
    -- Hide castbar
    if castFrame then
        castFrame:Hide()
    end
    
    -- Hide buff icons
    if hasteFrame then
        hasteFrame:Hide()
    end
end

-- ============ Config Frame Creation ============
local function CreateConfigFrame()
    -- Create Config Frame
    configFrame = CreateFrame("Frame", "HamingwaysHunterToolsConfigFrame", UIParent)
    configFrame:SetWidth(320)
    configFrame:SetHeight(550)
    configFrame:SetPoint("CENTER", UIParent, "CENTER")
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
    
    -- Color Picker Function (defined before tabs)
    local function CreateColorButton(name, label, yPos, colorKey, parent)
        local btn = CreateFrame("Button", name, parent or configFrame)
        btn:SetWidth(100)
        btn:SetHeight(20)
        btn:SetPoint("TOPLEFT", 20, yPos)
        
        local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btnText:SetPoint("LEFT", btn, "LEFT", 0, 0)
        btnText:SetText(label)
        
        local colorSwatch = btn:CreateTexture(nil, "OVERLAY")
        colorSwatch:SetWidth(16)
        colorSwatch:SetHeight(16)
        colorSwatch:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
        colorSwatch:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        
        btn.colorSwatch = colorSwatch
        btn.colorKey = colorKey
        
        btn:SetScript("OnClick", function()
            local cfg = GetConfig()
            local color = cfg[colorKey]
            ColorPickerFrame.func = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                cfg[colorKey].r = r
                cfg[colorKey].g = g
                cfg[colorKey].b = b
                colorSwatch:SetVertexColor(r, g, b)
                ApplyFrameSettings()
            end
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.previousValues = {color.r, color.g, color.b}
            ColorPickerFrame:SetColorRGB(color.r, color.g, color.b)
            ColorPickerFrame:Show()
        end)
        
        return btn
    end
    
    -- Tab system
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
    
    -- Create tabs
    local tabNames = {"AutoShot", "Castbar", "Buffs", "Munition", "Statistik"}
    local tabWidth = (320 - 32) / 5
    
    for i, name in ipairs(tabNames) do
        local tabIndex = i  -- Create local copy for closure
        local tab = CreateFrame("Button", nil, UIParent)
        tab:SetWidth(tabWidth)
        tab:SetHeight(24)
        tab:SetPoint("BOTTOMLEFT", configFrame, "TOPLEFT", 16 + (i - 1) * tabWidth, -57)
        tab:SetFrameStrata("FULLSCREEN_DIALOG")
        tab:SetFrameLevel(999)
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
        
        tab:Hide()  -- Hide initially
        tabs[i] = tab
        
        -- Create content frame for this tab
        local content = CreateFrame("Frame", nil, configFrame)
        content:SetPoint("TOPLEFT", 16, -80)
        content:SetWidth(288)
        content:SetHeight(386)
        content:SetFrameLevel(configFrame:GetFrameLevel() + 1)
        content:EnableMouse(false)
        content:Hide()
        tabContents[i] = content
    end
    
    -- Tab 1: AutoShot Timer settings
    local tab1 = tabContents[1]
    
    -- Title
    local title = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText("|cFFABD473Hamingway's |r|cFFFFFF00HunterTools|r")
    
    -- Show AutoShot Timer Checkbox (first option)
    local showAutoShotCheck = CreateFrame("CheckButton", "HamingwaysHunterToolsShowAutoShotCheck", tab1, "UICheckButtonTemplate")
    showAutoShotCheck:SetPoint("TOPLEFT", 10, -5)
    getglobal(showAutoShotCheck:GetName().."Text"):SetText("Show AutoShot Timer")
    showAutoShotCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showAutoShotTimer = this:GetChecked() and true or false
        UpdateFrameVisibility()
    end)
    
    -- Lock Checkbox
    local lockCheck = CreateFrame("CheckButton", "HamingwaysHunterToolsLockCheck", tab1, "UICheckButtonTemplate")
    lockCheck:SetPoint("TOPLEFT", 10, -35)
    getglobal(lockCheck:GetName().."Text"):SetText("Lock frames")
    lockCheck:SetScript("OnClick", function()
        local locked = this:GetChecked() and true or false
        HamingwaysHunterToolsDB.locked = locked
        local mainFrame = getglobal("HamingwaysHunterToolsFrame")
        if mainFrame then
            mainFrame:EnableMouse(not locked)
        end
        local ammo = getglobal("HamingwaysHunterToolsAmmoFrame")
        if ammo then
            ammo:EnableMouse(not locked)
        end
        local stats = getglobal("HamingwaysHunterToolsStatsFrame")
        if stats then
            stats:EnableMouse(not locked)
        end
    end)
    
    -- Show Only In Combat Checkbox
    local combatCheck = CreateFrame("CheckButton", "HamingwaysHunterToolsCombatCheck", tab1, "UICheckButtonTemplate")
    combatCheck:SetPoint("TOPLEFT", 10, -65)
    getglobal(combatCheck:GetName().."Text"):SetText("Show only in combat")
    combatCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showOnlyInCombat = this:GetChecked() and true or false
        UpdateFrameVisibility()
    end)
    
    -- Show Timer Text Checkbox
    local timerCheck = CreateFrame("CheckButton", "HamingwaysHunterToolsTimerCheck", tab1, "UICheckButtonTemplate")
    timerCheck:SetPoint("TOPLEFT", 10, -95)
    getglobal(timerCheck:GetName().."Text"):SetText("Show timer text")
    timerCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showTimerText = this:GetChecked() and true or false
        -- Immediately update preview if config is open
        if previewMode then
            HideConfigPreview()
            ShowConfigPreview()
        end
    end)
    
    -- Frame Width Slider
    local widthSlider = CreateFrame("Slider", "HamingwaysHunterToolsWidthSlider", tab1, "OptionsSliderTemplate")
    widthSlider:SetPoint("TOPLEFT", 10, -135)
    widthSlider:SetMinMaxValues(100, 400)
    widthSlider:SetValueStep(10)
    widthSlider:SetWidth(250)
    getglobal(widthSlider:GetName().."Low"):SetText("100")
    getglobal(widthSlider:GetName().."High"):SetText("400")
    getglobal(widthSlider:GetName().."Text"):SetText("Width")
    widthSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.frameWidth = val
        getglobal(this:GetName().."Text"):SetText("Width: "..val)
        ApplyFrameSettings()
    end)
    
    -- Frame Height Slider
    local heightSlider = CreateFrame("Slider", "HamingwaysHunterToolsHeightSlider", tab1, "OptionsSliderTemplate")
    heightSlider:SetPoint("TOPLEFT", 10, -180)
    heightSlider:SetMinMaxValues(10, 40)
    heightSlider:SetValueStep(2)
    heightSlider:SetWidth(250)
    getglobal(heightSlider:GetName().."Low"):SetText("10")
    getglobal(heightSlider:GetName().."High"):SetText("40")
    getglobal(heightSlider:GetName().."Text"):SetText("Höhe")
    heightSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.frameHeight = val
        getglobal(this:GetName().."Text"):SetText("Höhe: "..val)
        ApplyFrameSettings()
    end)
    
    -- Border Size Slider
    local borderSlider = CreateFrame("Slider", "HamingwaysHunterToolsBorderSlider", tab1, "OptionsSliderTemplate")
    borderSlider:SetPoint("TOPLEFT", 10, -225)
    borderSlider:SetMinMaxValues(0, 20)
    borderSlider:SetValueStep(2)
    borderSlider:SetWidth(250)
    getglobal(borderSlider:GetName().."Low"):SetText("0")
    getglobal(borderSlider:GetName().."High"):SetText("20")
    getglobal(borderSlider:GetName().."Text"):SetText("Border")
    borderSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.borderSize = val
        getglobal(this:GetName().."Text"):SetText("Border: "..val)
        ApplyFrameSettings()
    end)
    
    -- Color buttons for Tab 1
    local reloadColorBtn = CreateColorButton("HamingwaysHunterToolsReloadColor", "Reload:", -270, "reloadColor", tab1)
    local aimingColorBtn = CreateColorButton("HamingwaysHunterToolsAimingColor", "Aiming:", -300, "aimingColor", tab1)
    local bgColorBtn1 = CreateColorButton("HamingwaysHunterToolsBgColor1", "Hintergrund:", -330, "bgColor", tab1)
    
    -- Background Opacity for Tab 1
    local opacitySlider = CreateFrame("Slider", "HamingwaysHunterToolsOpacitySlider", tab1, "OptionsSliderTemplate")
    opacitySlider:SetPoint("TOPLEFT", 10, -375)
    opacitySlider:SetMinMaxValues(0, 1)
    opacitySlider:SetValueStep(0.1)
    opacitySlider:SetWidth(250)
    getglobal(opacitySlider:GetName().."Low"):SetText("0")
    getglobal(opacitySlider:GetName().."High"):SetText("1")
    getglobal(opacitySlider:GetName().."Text"):SetText("BG Opacity")
    opacitySlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.bgOpacity = val
        getglobal(this:GetName().."Text"):SetText(string.format("BG Opacity: %.1f", val))
        ApplyFrameSettings()
    end)
    
    -- Tab 2: Castbar settings
    local tab2 = tabContents[2]
    
    -- Show Castbar Checkbox
    local showCastbarCheck = CreateFrame("CheckButton", "HamingwaysHunterToolsShowCastbarCheck", tab2, "UICheckButtonTemplate")
    showCastbarCheck:SetPoint("TOPLEFT", 10, -5)
    getglobal(showCastbarCheck:GetName().."Text"):SetText("Show Castbar")
    showCastbarCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showCastbar = this:GetChecked() and true or false
        if not HamingwaysHunterToolsDB.showCastbar and castFrame then
            castFrame:Hide()
        end
    end)
    
    -- Castbar Spacing Slider
    local spacingSlider = CreateFrame("Slider", "HamingwaysHunterToolsSpacingSlider", tab2, "OptionsSliderTemplate")
    spacingSlider:SetPoint("TOPLEFT", 10, -40)
    spacingSlider:SetMinMaxValues(0, 20)
    spacingSlider:SetValueStep(1)
    spacingSlider:SetWidth(250)
    getglobal(spacingSlider:GetName().."Low"):SetText("0")
    getglobal(spacingSlider:GetName().."High"):SetText("20")
    getglobal(spacingSlider:GetName().."Text"):SetText("Castbar Spacing")
    spacingSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.castbarSpacing = val
        getglobal(this:GetName().."Text"):SetText("Castbar Spacing: "..val)
        ApplyFrameSettings()
    end)
    
    local castColorBtn = CreateColorButton("HamingwaysHunterToolsCastColor", "Cast Farbe:", -90, "castColor", tab2)
    
    -- Tab 3: Buff bar settings
    local tab3 = tabContents[3]
    
    -- Show BuffBar Checkbox
    local showBuffBarCheck = CreateFrame("CheckButton", "HamingwaysHunterToolsShowBuffBarCheck", tab3, "UICheckButtonTemplate")
    showBuffBarCheck:SetPoint("TOPLEFT", 10, -5)
    getglobal(showBuffBarCheck:GetName().."Text"):SetText("Show BuffBar")
    showBuffBarCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showBuffBar = this:GetChecked() and true or false
        if not HamingwaysHunterToolsDB.showBuffBar and hasteFrame then
            hasteFrame:Hide()
        else
            UpdateHasteBuffs()
        end
    end)
    
    -- Icon Size Slider
    local iconSizeSlider = CreateFrame("Slider", "HamingwaysHunterToolsIconSizeSlider", tab3, "OptionsSliderTemplate")
    iconSizeSlider:SetPoint("TOPLEFT", 10, -40)
    iconSizeSlider:SetMinMaxValues(16, 48)
    iconSizeSlider:SetValueStep(2)
    iconSizeSlider:SetWidth(250)
    getglobal(iconSizeSlider:GetName().."Low"):SetText("16")
    getglobal(iconSizeSlider:GetName().."High"):SetText("48")
    getglobal(iconSizeSlider:GetName().."Text"):SetText("Icon Größe")
    iconSizeSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.iconSize = val
        getglobal(this:GetName().."Text"):SetText("Icon Größe: "..val)
        ApplyIconSize(val)
    end)
    
    -- Tab 4: Ammunition settings
    local tab4 = tabContents[4]
    
    -- Show Ammo Checkbox
    local showAmmoCheck = CreateFrame("CheckButton", "HamingwaysHunterToolsShowAmmoCheck", tab4, "UICheckButtonTemplate")
    showAmmoCheck:SetPoint("TOPLEFT", 10, -5)
    getglobal(showAmmoCheck:GetName().."Text"):SetText("Show ammunition")
    showAmmoCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showAmmo = this:GetChecked() and true or false
        if ammoFrame then
            if HamingwaysHunterToolsDB.showAmmo then
                UpdateAmmoDisplay()
            else
                ammoFrame:Hide()
            end
        end
    end)
    
    -- Ammo Icon Size Slider
    local ammoIconSizeSlider = CreateFrame("Slider", "HamingwaysHunterToolsAmmoIconSizeSlider", tab4, "OptionsSliderTemplate")
    ammoIconSizeSlider:SetPoint("TOPLEFT", 10, -40)
    ammoIconSizeSlider:SetMinMaxValues(16, 64)
    ammoIconSizeSlider:SetValueStep(2)
    ammoIconSizeSlider:SetWidth(250)
    getglobal(ammoIconSizeSlider:GetName().."Low"):SetText("16")
    getglobal(ammoIconSizeSlider:GetName().."High"):SetText("64")
    getglobal(ammoIconSizeSlider:GetName().."Text"):SetText("Ammo Icon Size")
    ammoIconSizeSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.ammoIconSize = val
        getglobal(this:GetName().."Text"):SetText("Ammo Icon Size: "..val)
        ApplyAmmoIconSize(val)
    end)
    
    -- Tab 5: Statistics settings
    local tab5 = tabContents[5]
    
    -- Show Stats Checkbox
    local showStatsCheck = CreateFrame("CheckButton", "HamingwaysHunterToolsShowStatsCheck", tab5, "UICheckButtonTemplate")
    showStatsCheck:SetPoint("TOPLEFT", 10, -5)
    getglobal(showStatsCheck:GetName().."Text"):SetText("Show statistics")
    showStatsCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showStats = this:GetChecked() and true or false
        UpdateStatsDisplay()
    end)
    
    -- Stats Font Size Slider
    local statsFontSlider = CreateFrame("Slider", "HamingwaysHunterToolsStatsFontSlider", tab5, "OptionsSliderTemplate")
    statsFontSlider:SetPoint("TOPLEFT", 10, -40)
    statsFontSlider:SetMinMaxValues(8, 16)
    statsFontSlider:SetValueStep(1)
    statsFontSlider:SetWidth(250)
    getglobal(statsFontSlider:GetName().."Low"):SetText("8")
    getglobal(statsFontSlider:GetName().."High"):SetText("16")
    getglobal(statsFontSlider:GetName().."Text"):SetText("Schriftgröße")
    statsFontSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.statsFontSize = val
        getglobal(this:GetName().."Text"):SetText("Schriftgröße: "..val)
        if statsFrame then
            local fontName = "GameFontNormalSmall"
            if val >= 14 then fontName = "GameFontNormal" end
            if statsFrame.avgText then statsFrame.avgText:SetFontObject(fontName) end
            if statsFrame.minText then statsFrame.minText:SetFontObject(fontName) end
            if statsFrame.maxText then statsFrame.maxText:SetFontObject(fontName) end
            if statsFrame.lastText then statsFrame.lastText:SetFontObject(fontName) end
            if statsFrame.countText then statsFrame.countText:SetFontObject(fontName) end
            if statsFrame.skippedText then statsFrame.skippedText:SetFontObject(fontName) end
            if statsFrame.delayedText then statsFrame.delayedText:SetFontObject(fontName) end
        end
    end)
    
    -- Reset Stats Button
    local resetStatsBtn = CreateFrame("Button", nil, tab5, "UIPanelButtonTemplate")
    resetStatsBtn:SetWidth(120)
    resetStatsBtn:SetHeight(22)
    resetStatsBtn:SetPoint("TOPLEFT", 10, -95)
    resetStatsBtn:SetText("Stats zurücksetzen")
    resetStatsBtn:SetScript("OnClick", function()
        ResetStats()
    end)
    
    -- Info text
    local statsInfo = tab5:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsInfo:SetPoint("TOPLEFT", 10, -130)
    statsInfo:SetWidth(270)
    statsInfo:SetJustifyH("LEFT")
    statsInfo:SetText("Measures the reaction time between Auto-Shot and Cast-Start (Aimed Shot, Multi-Shot, etc.). Right-click to reset.")
    statsInfo:SetTextColor(0.7, 0.7, 0.7, 1)
    
    -- Close Button
    local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    closeBtn:SetWidth(80)
    closeBtn:SetHeight(22)
    closeBtn:SetPoint("BOTTOM", 0, 15)
    closeBtn:SetText("Schließen")
    closeBtn:SetScript("OnClick", function()
        configFrame:Hide()
    end)
    
    -- Version text (bottom left, visible in all tabs)
    local versionText = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    versionText:SetPoint("BOTTOMLEFT", 15, 15)
    versionText:SetText("v" .. VERSION)
    versionText:SetTextColor(0.5, 0.5, 0.5, 1)
    
    -- Store references for OnShow handler
    configFrame.showAutoShotCheck = showAutoShotCheck
    configFrame.showCastbarCheck = showCastbarCheck
    configFrame.showBuffBarCheck = showBuffBarCheck
    configFrame.lockCheck = lockCheck
    configFrame.combatCheck = combatCheck
    configFrame.timerCheck = timerCheck
    configFrame.widthSlider = widthSlider
    configFrame.heightSlider = heightSlider
    configFrame.borderSlider = borderSlider
    configFrame.spacingSlider = spacingSlider
    configFrame.iconSizeSlider = iconSizeSlider
    configFrame.showAmmoCheck = showAmmoCheck
    configFrame.ammoIconSizeSlider = ammoIconSizeSlider
    configFrame.statsFontSlider = statsFontSlider
    configFrame.showStatsCheck = showStatsCheck
    configFrame.opacitySlider = opacitySlider
    configFrame.reloadColorBtn = reloadColorBtn
    configFrame.aimingColorBtn = aimingColorBtn
    configFrame.castColorBtn = castColorBtn
    configFrame.bgColorBtn = bgColorBtn1
    
    -- Show first tab by default
    ShowTab(1)
    
    -- Update config UI when shown
    configFrame:SetScript("OnShow", function()
        local cfg = GetConfig()
        this.showAutoShotCheck:SetChecked(cfg.showAutoShotTimer)
        this.showCastbarCheck:SetChecked(cfg.showCastbar)
        this.showBuffBarCheck:SetChecked(cfg.showBuffBar)
        this.lockCheck:SetChecked(cfg.locked)
        this.combatCheck:SetChecked(cfg.showOnlyInCombat)
        this.timerCheck:SetChecked(cfg.showTimerText)
        this.widthSlider:SetValue(cfg.frameWidth)
        this.heightSlider:SetValue(cfg.frameHeight)
        this.borderSlider:SetValue(cfg.borderSize)
        this.spacingSlider:SetValue(cfg.castbarSpacing)
        this.iconSizeSlider:SetValue(cfg.iconSize)
        this.ammoIconSizeSlider:SetValue(cfg.ammoIconSize)
        this.statsFontSlider:SetValue(cfg.statsFontSize)
        this.showStatsCheck:SetChecked(cfg.showStats)
        this.showAmmoCheck:SetChecked(cfg.showAmmo)
        this.opacitySlider:SetValue(cfg.bgOpacity)
        this.reloadColorBtn.colorSwatch:SetVertexColor(cfg.reloadColor.r, cfg.reloadColor.g, cfg.reloadColor.b)
        this.aimingColorBtn.colorSwatch:SetVertexColor(cfg.aimingColor.r, cfg.aimingColor.g, cfg.aimingColor.b)
        this.castColorBtn.colorSwatch:SetVertexColor(cfg.castColor.r, cfg.castColor.g, cfg.castColor.b)
        this.bgColorBtn.colorSwatch:SetVertexColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b)
        for i, tab in ipairs(tabs) do
            tab:Show()
        end
        ShowConfigPreview()
    end)
    
    configFrame:SetScript("OnHide", function()
        for i, tab in ipairs(tabs) do
            tab:Hide()
        end
        HideConfigPreview()
    end)
    
    return configFrame
end

local function HideConfigPreview()
    previewMode = false
    
    -- Hide castbar if not currently casting
    if castFrame then
        if not isCasting then
            castFrame:Hide()
            -- Clear preview text
            if castBarText and castBarTextTime then
                castBarText:SetText("")
                castBarTextTime:SetText("")
            end
        end
    end
    
    -- Update buff icons to show only real buffs (not preview buffs)
    if hasteFrame then
        UpdateHasteBuffs()
    end
    
    -- Update frame visibility to respect combat settings
    UpdateFrameVisibility()
end

local function CreateUI()
    frame = CreateFrame("Frame", "HamingwaysHunterToolsFrame", UIParent)
    frame:SetWidth(240)
    frame:SetHeight(14)
    frame:SetFrameStrata("HIGH")
    frame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.8)
    frame:SetBackdropBorderColor(1, 1, 1, 0.8)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    
    barFrame = CreateFrame("Frame", nil, frame)
    barFrame:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    barFrame:SetHeight(frame:GetHeight() - 4)
    barFrame:SetWidth(1)
    barFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false,
    })
    
    barText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    barText:SetPoint("RIGHT", frame, "LEFT", -5, 0)
    barText:SetTextColor(1, 1, 1, 1)
    barText:SetText("")
    
    barTextTotal = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    barTextTotal:SetPoint("LEFT", frame, "RIGHT", 5, 0)
    barTextTotal:SetTextColor(1, 1, 1, 1)
    barTextTotal:SetText("--")
    
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetMovable(true)
    
    frame:SetScript("OnDragStart", function()
        this:StartMoving()
    end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local point, _, _, xOfs, yOfs = this:GetPoint()
        HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
        HamingwaysHunterToolsDB.point = point
        HamingwaysHunterToolsDB.x = xOfs
        HamingwaysHunterToolsDB.y = yOfs
    end)
    
    frame:SetScript("OnUpdate", function()
        -- Calculate elapsed time manually (Vanilla 1.12 doesn't pass elapsed to OnUpdate)
        if not this.lastUpdate then this.lastUpdate = GetTime() end
        local now = GetTime()
        local elapsed = now - this.lastUpdate
        this.lastUpdate = now
        
        -- Update castbar
        if isCasting and not previewMode then
            UpdateCastbar()
        end
        
        -- Update haste buffs (throttled to every 0.1s)
        if not this.hasteThrottle then this.hasteThrottle = 0 end
        this.hasteThrottle = this.hasteThrottle + elapsed
        if this.hasteThrottle >= 0.1 then
            if not previewMode then
                UpdateHasteBuffs()
            end
            this.hasteThrottle = 0
        end
        
        if not isShooting then
            -- Always update the bar when not shooting to show current weapon speed
            if barFrame and barText and barTextTotal then
                barFrame:SetWidth(1)
                barFrame:SetBackdropColor(0.3, 0.3, 0.3, 0.5)
                barText:SetText("")
                local cfg = GetConfig()
                barTextTotal:SetText(cfg.showTimerText and string.format("%.2fs", weaponSpeed) or "")
            end
        elseif isReloading then
            UpdateBarReload()
        else
            -- Yellow bar (aiming): reset on movement OR during cast
            if not position.CheckStandingStill() or isCasting then
                lastShotTime = GetTime() - (weaponSpeed - AIMING_TIME)
            end
            UpdateBarShoot()
        end
    end)
    
    maxBarWidth = frame:GetWidth() - 4
    
    -- Create Minimap Button
    minimapButton = CreateFrame("Button", "HamingwaysHunterToolsMinimapButton", Minimap)
    minimapButton:SetWidth(31)
    minimapButton:SetHeight(31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(9)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    
    minimapButton.icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    minimapButton.icon:SetWidth(20)
    minimapButton.icon:SetHeight(20)
    minimapButton.icon:SetTexture("Interface\\Icons\\ability_marksmanship")
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
        GameTooltip:SetText("|cFFABD473Hamingway's |r|cFFFFFF00HunterTools|r")
        GameTooltip:AddLine("Click to open settings", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    
    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Position minimap button
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
            HamingwaysHunterToolsDB.minimapPos = angle
            UpdateMinimapButton()
        end)
    end)
    
    minimapButton:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
        this:UnlockHighlight()
    end)
    
    UpdateMinimapButton()
    minimapButton:Show()
    
    -- Create Config Frame (moved to separate function to reduce upvalues)
    CreateConfigFrame()
    
    -- Create Castbar above AutoShot bar
    castFrame = CreateFrame("Frame", "HamingwaysHunterToolsCastFrame", UIParent)
    castFrame:SetWidth(240)
    castFrame:SetHeight(14)
    castFrame:SetFrameStrata("HIGH")
    castFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    castFrame:SetBackdropColor(0, 0, 0, 0.8)
    castFrame:SetBackdropBorderColor(1, 1, 1, 0.8)
    castFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    castFrame:Hide()
    
    castFrame:EnableMouse(true)
    castFrame:RegisterForDrag("LeftButton")
    castFrame:SetMovable(true)
    castFrame:SetScript("OnDragStart", function()
        if not HamingwaysHunterToolsDB.locked then
            this:StartMoving()
        end
    end)
    castFrame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        castFrame.independentPosition = true
    end)
    
    -- Add OnUpdate to castFrame for updating castbar when frame is hidden
    castFrame:SetScript("OnUpdate", function()
        if isCasting and not previewMode then
            UpdateCastbar()
        end
    end)
    
    castBarFrame = CreateFrame("Frame", nil, castFrame)
    castBarFrame:SetPoint("TOPLEFT", castFrame, "TOPLEFT", 2, -2)
    castBarFrame:SetHeight(castFrame:GetHeight() - 4)
    castBarFrame:SetWidth(1)
    castBarFrame:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false,
    })
    castBarFrame:SetBackdropColor(0.5, 0.5, 1, 0.8)
    
    castBarText = castFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    castBarText:SetPoint("CENTER", castFrame, "CENTER", 0, 0)
    castBarText:SetTextColor(1, 1, 1, 1)
    castBarText:SetText("")
    
    castBarTextTime = castFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    castBarTextTime:SetPoint("LEFT", castFrame, "RIGHT", 5, 0)
    castBarTextTime:SetTextColor(1, 1, 1, 1)
    castBarTextTime:SetText("")
    
    -- Create Ammo Frame
    CreateAmmoFrame()
    
    -- Create Stats Frame
    CreateStatsFrame()
    
    -- Create Haste Buff Tracker below Castbar (transparent, no border)
    hasteFrame = CreateFrame("Frame", "HamingwaysHunterToolsHasteFrame", UIParent)
    hasteFrame:SetWidth(240)
    hasteFrame:SetHeight(28)
    hasteFrame:SetFrameStrata("HIGH")
    hasteFrame:SetPoint("TOP", frame, "BOTTOM", 0, -2)
    hasteFrame:Hide()
    
    -- Update haste buffs continuously
    hasteFrame:SetScript("OnUpdate", function()
        if not this.updateThrottle then this.updateThrottle = 0 end
        if not this.lastUpdateTime then this.lastUpdateTime = GetTime() end
        local now = GetTime()
        local elapsed = now - this.lastUpdateTime
        this.lastUpdateTime = now
        this.updateThrottle = this.updateThrottle + elapsed
        if this.updateThrottle >= 0.1 then  -- Update every 0.1s
            UpdateHasteBuffs()
            this.updateThrottle = 0
        end
    end)
    
    return frame
end


-- ============ Shot Detection (Quiver-style) ============
local function OnShotFired()
    -- Ignore if currently casting (Aimed Shot, Multi-Shot, etc.)
    if isCasting then return end
    
    -- Ignore shot detection for 0.3s after cast ends to prevent false red bar
    if GetTime() - lastCastEndTime < 0.3 then return end
    
    lastShotTime = GetTime()
    
    -- Only track statistics if stats frame is enabled
    if HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showStats then
        lastAutoShotTime = lastShotTime  -- Track for reaction time
        autoShotBetweenCasts = true  -- Mark that an auto-shot happened
    end
    
    isReloading = true
    UpdateWeaponSpeed()
    if not isShooting then
        isShooting = true
    end
end

-- Register events for shot detection
AH:RegisterEvent("ITEM_LOCK_CHANGED")
AH:RegisterEvent("START_AUTOREPEAT_SPELL")
AH:RegisterEvent("STOP_AUTOREPEAT_SPELL")
AH:RegisterEvent("UNIT_INVENTORY_CHANGED")
AH:RegisterEvent("PLAYER_ENTERING_WORLD")
AH:RegisterEvent("PLAYER_AURAS_CHANGED")
AH:RegisterEvent("PLAYER_REGEN_ENABLED")
AH:RegisterEvent("PLAYER_REGEN_DISABLED")
AH:RegisterEvent("ADDON_LOADED")
AH:RegisterEvent("PLAYER_LOGOUT")
AH:RegisterEvent("UI_ERROR_MESSAGE")
AH:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")  -- Detect when buffs are gained


AH:SetScript("OnEvent", function()
    local ev = event
    local a1 = arg1
    
    if ev == "ADDON_LOADED" and a1 == "HamingwaysHunterTools" then
        HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
        if frame == nil then
            frame = CreateUI()
        end
        local cfg = GetConfig()
        if cfg.x and cfg.y and cfg.point then
            frame:ClearAllPoints()
            frame:SetPoint(cfg.point, UIParent, cfg.point, cfg.x, cfg.y)
        end
        if ammoFrame and cfg.ammoX and cfg.ammoY and cfg.ammoPoint then
            ammoFrame:ClearAllPoints()
            ammoFrame:SetPoint(cfg.ammoPoint, UIParent, cfg.ammoPoint, cfg.ammoX, cfg.ammoY)
        end
        if statsFrame and cfg.statsX and cfg.statsY and cfg.statsPoint then
            statsFrame:ClearAllPoints()
            statsFrame:SetPoint(cfg.statsPoint, UIParent, cfg.statsPoint, cfg.statsX, cfg.statsY)
        end
        ApplyFrameSettings()
        print("HHT: loaded (Quiver-style timer, use /HamingwaysHunterTools test)")
        frame:Show()
        UpdateWeaponSpeed()
        UpdateFrameVisibility()
        -- Initialize stats display
        if statsFrame then
            UpdateStatsDisplay()
        end
        return
    end
    
    if frame == nil then
        frame = CreateUI()
    end
    
    if ev == "PLAYER_ENTERING_WORLD" then
        UpdateWeaponSpeed()
        UpdateAmmoDisplay()
        -- Print loaded message once
        if not loadedMessageShown then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's |r|cFFFFFF00HunterTools |r(" .. VERSION .. ") loaded")
            loadedMessageShown = true
        end
    elseif ev == "UNIT_INVENTORY_CHANGED" and a1 == "player" then
        UpdateWeaponSpeed()
        UpdateAmmoDisplay()
    elseif ev == "PLAYER_AURAS_CHANGED" then
        -- Only update on aura changes when not shooting (out of combat)
        if not isShooting then
            UpdateWeaponSpeed()
        end
    elseif ev == "PLAYER_REGEN_DISABLED" then
        -- Combat started
        if statsNeedReset then
            ResetStats()
            statsNeedReset = false
        end
        UpdateFrameVisibility()
    elseif ev == "PLAYER_REGEN_ENABLED" then
        -- Combat ended - set flag to reset stats on next combat
        if table.getn(reactionTimes) > 0 or skippedAutoShots > 0 or table.getn(delayedAutoShotTimes) > 0 then
            statsNeedReset = true
        end
        UpdateFrameVisibility()
    elseif ev == "START_AUTOREPEAT_SPELL" then
        isShooting = true
        position.UpdateXY()
        UpdateFrameVisibility()
        -- Initialize timer to start of yellow bar phase
        if lastShotTime == 0 then
            UpdateWeaponSpeed()
            lastShotTime = GetTime() - (weaponSpeed - AIMING_TIME)
        end
    elseif ev == "STOP_AUTOREPEAT_SPELL" then
        isShooting = false
        isReloading = false
        lastShotTime = 0
        UpdateFrameVisibility()
    elseif ev == "ITEM_LOCK_CHANGED" then
        if isShooting then
            OnShotFired()
        end
    elseif ev == "PLAYER_LOGOUT" then
        HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
        local point, _, _, xOfs, yOfs = frame:GetPoint()
        HamingwaysHunterToolsDB.point = point
        HamingwaysHunterToolsDB.x = xOfs
        HamingwaysHunterToolsDB.y = yOfs
    elseif ev == "UI_ERROR_MESSAGE" then
        -- Cancel castbar if spell failed
        if isCasting then
            isCasting = false
            if castFrame then castFrame:Hide() end
        end
    elseif ev == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" then
        -- Buff gained, reset timestamp for tracked haste buffs
        local message = arg1
        if message then
            -- Message format: "You gain <Buff Name>." or just contains buff name
            for buffName, _ in pairs(hasteBuffs) do
                -- Use pattern matching to find buff name anywhere in message
                if string.find(message, buffName, 1, true) then
                    -- Reset timestamp and remaining time to full duration
                    local duration = buffDurations[buffName] or 15
                    buffTimestamps[buffName] = GetTime()
                    lastBuffRemaining[buffName] = duration
                    break
                end
            end
        end
    end
end)


-- ============ Slash Commands ============
SLASH_HamingwaysHunterTools1 = "/HamingwaysHunterTools"
SlashCmdList["HamingwaysHunterTools"] = function(msgArg)
    local msgLower = string.lower(msgArg or "")
    if msgLower == "reset" then
        lastShotTime = 0
        isReloading = false
        UpdateWeaponSpeed()
        print("HHT: timer reset")
    elseif msgLower == "lock" then
        HamingwaysHunterToolsDB.locked = true
        if frame then frame:EnableMouse(false) end
        print("HHT: locked")
    elseif msgLower == "unlock" then
        HamingwaysHunterToolsDB.locked = false
        if frame then frame:EnableMouse(true) end
        print("HHT: unlocked (drag to move)")
    elseif msgLower == "config" then
        if configFrame then
            if configFrame:IsShown() then
                configFrame:Hide()
            else
                configFrame:Show()
            end
        end
    elseif msgLower == "test" then
        print("HHT: test shot")
        OnShotFired()
    elseif msgLower == "debug" then
        print("HamingwaysHunterTools Debug: shooting=" .. tostring(isShooting) .. " reload=" .. tostring(isReloading) .. " speed=" .. weaponSpeed)
        print("Reaction samples: " .. table.getn(reactionTimes) .. " last=" .. tostring(reactionTimes[table.getn(reactionTimes)] or 0))
        print("Delayed samples: " .. table.getn(delayedAutoShotTimes) .. " avg=" .. tostring(delayedAutoShotTimes[table.getn(delayedAutoShotTimes)] or 0))
        if lastShotTime > 0 then
            local elapsed = GetTime() - lastShotTime
            local reloadDuration = weaponSpeed - AIMING_TIME
            print("Time since last shot: " .. string.format("%.3f", elapsed) .. " reload=" .. string.format("%.3f", reloadDuration) .. " total=" .. string.format("%.3f", weaponSpeed))
        end
    elseif msgLower == "stats" or msgLower == "resetstats" then
        ResetStats()
    else
        print("HHT: /HamingwaysHunterTools reset | lock | unlock | config | test | debug | stats")
    end
end



