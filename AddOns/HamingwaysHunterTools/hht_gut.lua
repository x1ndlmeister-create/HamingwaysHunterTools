
-- HamingwaysHunterTools - Vanilla 1.12
-- Autoshot timer matching Quiver's design: red reload, yellow windup

-- Version: x.y.z (x=release 0-9, y=feature 0-999, z=build 0-9999)
local VERSION = "0.9.0"  -- Major performance overhaul

local AH = CreateFrame("Frame", "HamingwaysHunterToolsCore")

-- SavedVariables (per character): HamingwaysHunterToolsDB
-- Structure: { x, y, point, minimapPos, locked, frameWidth, frameHeight, borderSize, castbarSpacing }
local frame = nil
local barFrame = nil  -- Frame-based bar (like Quiver), not StatusBar
local barText = nil
local barTextTotal = nil
local barTextRange = nil  -- Center text for range display
local minimapButton = nil
local configFrame = nil
local ammoFrame = nil
local ammoMenuFrame = nil
local statsFrame = nil

-- Pet Feeder elements
local petFeedFrame = nil
local petIconButton = nil
local foodIconButton = nil
local foodMenuFrame = nil
local selectedFood = nil  -- Stores selected food item {bag, slot, name, texture, itemID}
local lastAttemptedFood = nil  -- Tracks last food attempt for error handling

-- Reaction time tracking (delay between auto-shot and cast start)
local reactionTimes = {}
local MAX_REACTION_SAMPLES = 20  -- Keep last 20 reactions
local lastAutoShotTime = 0  -- Track when auto-shot hit for reaction time stats

-- Skipped auto-shots tracking
local lastCastTime = 0
local autoShotBetweenCasts = false
local skippedAutoShots = 0
local totalCastSequences = 0

-- Delayed auto-shots tracking (yellow bar reset by cast)
local delayedAutoShotTimes = {}
local MAX_DELAYED_SAMPLES = 20
local statsNeedReset = false  -- Flag to reset stats on next combat start

-- Performance: Throttle expensive operations
local lastRangeCheck = 0
local cachedRangeText = nil
local cachedIsDeadZone = false
local lastTimerModeCheck = 0
local RANGE_CHECK_INTERVAL = 0.2  -- Check range every 0.2s (5x/sec - smooth enough)
local TIMER_MODE_INTERVAL = 0.5   -- Check timer mode every 0.5s

-- Castbar elements
local castFrame = nil
local castBarFrame = nil
local castBarText = nil
local castBarTextTime = nil
local isCasting = false
local castStartTime = 0
local castEndTime = 0
local castDuration = 0  -- Add this if missing
local castSpellName = ""
local lastCastEndTime = 0  -- Track when cast ended to prevent shot detection
local previewMode = false  -- For config UI preview

-- Haste buff tracker elements
local hasteFrame = nil
local hasteIcons = {}
local MAX_HASTE_ICONS = 8
local buffTimestamps = {}  -- Track when buffs were applied
local maxBuffDurations = {}  -- Track maximum duration seen for each buff (by texture)
local activeBuffs = {}  -- Cached active buffs with remaining time
local activeBuffCount = 0

-- ============ Timer State (Closure pattern for performance) ============
local isReloading = false
local isShooting = false
local lastAutoFired = 0
local weaponSpeed = 2.0
local AIMING_TIME = 0.5  -- 0.5s like Quiver (not 0.65)

-- Closure pattern for efficient time tracking (eliminates repeated calculations)
local timeReload = (function()
    local startTime = 0
    return {
        Start = function()
            startTime = GetTime()
        end,
        GetPercent = function()
            if startTime == 0 then return 0 end
            local elapsed = GetTime() - startTime
            local duration = weaponSpeed - AIMING_TIME
            return elapsed <= duration and (elapsed / duration) or 1.0
        end,
        GetElapsed = function()
            if startTime == 0 then return 0 end
            return GetTime() - startTime
        end,
        IsComplete = function()
            if startTime == 0 then return false end
            local duration = weaponSpeed - AIMING_TIME
            return GetTime() - startTime >= duration
        end,
        IsStarted = function() return startTime > 0 end,
        Reset = function() startTime = 0 end
    }
end)()

local timeShoot = (function()
    local startTime = 0
    return {
        Start = function() startTime = GetTime() end,
        StartReady = function() startTime = GetTime() - AIMING_TIME end,  -- Start in "ready" state
        GetElapsed = function()
            if startTime == 0 then return 0 end
            return GetTime() - startTime
        end,
        GetRemaining = function()
            if startTime == 0 then return AIMING_TIME end
            return AIMING_TIME - (GetTime() - startTime)
        end,
        IsStarted = function() return startTime > 0 end,
        Reset = function() startTime = 0 end
    }
end)()

-- Global API for other addons (like LazyHunt) to access timer state
HamingwaysHunterTools_API = {}

-- Initialize API functions (needs to be after local variables are defined)
local function InitAPI()
    HamingwaysHunterTools_API.IsReloading = function() return isReloading end
    HamingwaysHunterTools_API.IsShooting = function() return isShooting end
    HamingwaysHunterTools_API.IsCasting = function() return isCasting end
    HamingwaysHunterTools_API.GetLastShotTime = function() return lastAutoFired end  -- Return timestamp, not elapsed
    HamingwaysHunterTools_API.GetWeaponSpeed = function() return weaponSpeed end
    HamingwaysHunterTools_API.GetAimingTime = function() return AIMING_TIME end
    HamingwaysHunterTools_API.IsInRedPhase = function()
        -- Red phase = Same logic as red bar display
        return isShooting and isReloading
    end
    HamingwaysHunterTools_API.IsInYellowPhase = function()
        -- Yellow phase = Same logic as yellow bar display
        return isShooting and not isReloading
    end
    -- Notify about external casts (from LazyHunt) - used for instant casts like Multi-Shot
    HamingwaysHunterTools_API.NotifyCast = function(spellName, castTime)
        castSpellName = spellName
        isCasting = true
        castStartTime = GetTime()
        castDuration = castTime
        castEndTime = castStartTime + castTime
        lastCastEndTime = castEndTime
        
        -- Show castbar if it exists and is enabled
        if castFrame and HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showCastbar then
            castFrame:Show()
        end
        if frame and HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showAutoShotTimer then
            local showOnlyInCombat = HamingwaysHunterToolsDB.showOnlyInCombat
            local inCombat = UnitAffectingCombat("player")
            if not showOnlyInCombat or inCombat or isShooting then
                frame:Show()
            end
        end
    end
end

-- Init API immediately (closure will access variables at runtime)
InitAPI()

-- Melee Swing Timer State
local lastMeleeSwingTime = 0
local meleeSwingSpeed = 2.0
local isMeleeSwinging = false
local useMeleeTimer = false  -- Current active timer mode
local registeredEvents = {}  -- Track which events are registered (for performance)

-- Default config values
local DEFAULT_FRAME_WIDTH = 240
local DEFAULT_FRAME_HEIGHT = 14
local DEFAULT_BORDER_SIZE = 10
local DEFAULT_CASTBAR_SPACING = 2
local DEFAULT_ICON_SIZE = 24
local DEFAULT_AMMO_ICON_SIZE = 32
local DEFAULT_PET_FEEDER_ICON_SIZE = 32
local DEFAULT_STATS_FONT_SIZE = 12
local DEFAULT_SHOW_ONLY_IN_COMBAT = false
local DEFAULT_RELOAD_COLOR = {r=1, g=0, b=0}
local DEFAULT_AIMING_COLOR = {r=1, g=1, b=0}
local DEFAULT_CAST_COLOR = {r=0.5, g=0.5, b=1}
local DEFAULT_BG_COLOR = {r=0, g=0, b=0}
local DEFAULT_BG_OPACITY = 0.8
local DEFAULT_MELEE_COLOR = {r=1, g=0.5, b=0}  -- Orange for melee swings

-- Melee Timer Defaults
local DEFAULT_SHOW_MELEE_TIMER = false
local DEFAULT_MELEE_ONLY_IN_COMBAT = true
local DEFAULT_MELEE_INSTEAD_OF_AUTOSHOT = false
local DEFAULT_AUTO_SWITCH_MELEE_RANGED = true
local PLAYER_BUFF_START_ID = 0  -- Vanilla 1.12 player buff offset

-- Visual constants
local BAR_ALPHA = 0.8  -- Opacity for bar elements
local MAX_BUFF_SLOTS = 31  -- Vanilla 1.12 max buff slots (0-31)
local INACTIVE_COLOR_GRAY = 0.3  -- Gray color for inactive/unknown states
local CONTENT_COLOR_ORANGE = 0.6  -- Orange component for "content" happiness
local UNHAPPY_COLOR_RED = 0.8  -- Red for unhappy pet
local HAPPY_COLOR_GREEN = 0.6  -- Green for happy pet
local WARNING_COLOR = {r=1, g=0.5, b=0}  -- Orange for warnings/errors

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
    ["Dismiss Pet"] = { Time=5000, Offset=0, Haste="none" },
    ["Begleiter entlassen"] = { Time=5000, Offset=0, Haste="none" },
    ["Revive Pet"] = { Time=10000, Offset=0, Haste="none" },
    ["Tier wiederbeleben"] = { Time=10000, Offset=0, Haste="none" },
}

-- Pet Food Database (Item IDs by diet type)
local PET_FOODS = {
    fungus = {4607,8948,4604,4608,4605,3448,4606},
    fish = {13889,19996,13933,13888,13935,13546,6290,4593,5503,16971,2682,13927,2675,13930,5476,4655,6038,13928,13929,13893,4592,8364,13932,5095,6291,6308,13754,6317,6289,8365,6361,13758,6362,6303,8959,4603,13756,13760,4594,787,5468,15924,12216,8957,6887,5504,12206,13755,7974},
    meat = {21235,19995,4457,3173,2888,3730,3726,3220,2677,3404,12213,2679,769,2673,2684,1081,12224,5479,2924,3662,4599,17119,5478,5051,12217,2687,9681,2287,12204,3727,13851,12212,5472,5467,5480,1015,12209,3731,12223,3770,12037,4739,12184,13759,12203,12210,2681,5474,8952,1017,5465,6890,3712,3729,2680,17222,5471,5469,5477,2672,2685,3728,3667,12208,18045,5470,12202,117,12205,3771},
    bread = {1113,5349,1487,1114,8075,8076,22895,19696,21254,2683,4541,17197,3666,8950,4542,4544,4601,4540,16169},
    cheese = {8932,414,2070,422,3927,1707},
    fruit = {19994,8953,4539,16168,4602,4536,4538,4537,11950},
}

-- Ammo database (Item IDs) - 10000x faster than tooltip scanning!
local AMMO_IDS = {
    -- Arrows
    2512, -- Rough Arrow
    2515, -- Sharp Arrow
    3030, -- Razor Arrow
    3031, -- Wicked Arrow (Horde)
    11285, -- Jagged Arrow
    28053, -- Wicked Arrow (TBC/Turtle)
    18042, -- Thorium Headed Arrow
    12654, -- Doomshot
    19316, -- Ice Threaded Arrow
    
    -- Bullets
    2516, -- Light Shot
    2519, -- Heavy Shot
    3033, -- Solid Shot
    11284, -- Accurate Slugs
    28060, -- Impact Shot (TBC/Turtle)
    5568, -- Smooth Pebble (Sling)
    13377, -- Miniature Cannon Balls
    
    -- Special (Turtle WoW / Custom)
    19317, -- Silithid Barb
    23773, -- Fel Iron Shells (TBC)
    23772, -- Fel Iron Arrow (TBC)
}

-- Quick lookup table for ammo (faster than iterating array)
local AMMO_LOOKUP = {}
for _, itemID in ipairs(AMMO_IDS) do
    AMMO_LOOKUP[itemID] = true
end

-- Known haste buffs (TEXTURE-BASED for 10000x faster detection - no tooltip scans!)
-- Using texture paths as keys allows instant comparison without tooltip parsing
-- Note: GetPlayerBuffTexture() returns path WITH "Interface\\Icons\\" prefix in Vanilla
local hasteBuffsByTexture = {
    ["Interface\\Icons\\Ability_Hunter_RunningShot"] = {name="Rapid Fire", duration=15, texture="Interface\\Icons\\Ability_Hunter_RunningShot"},
    ["Interface\\Icons\\Ability_Warrior_InnerRage"] = {name="Quick Shots", duration=12, texture="Interface\\Icons\\Ability_Warrior_InnerRage"},
    ["Interface\\Icons\\Racial_Troll_Berserk"] = {name="Berserking", duration=10, texture="Interface\\Icons\\Racial_Troll_Berserk"},
    ["Interface\\Icons\\INV_Misc_Head_Dragon_Red"] = {name="Essence of the Red", duration=20, texture="Interface\\Icons\\INV_Misc_Head_Dragon_Red"},
    ["Interface\\Icons\\INV_Misc_MonsterSpiderCarapace_01"] = {name="Kiss of the Spider", duration=15, texture="Interface\\Icons\\INV_Misc_MonsterSpiderCarapace_01"},
    ["Interface\\Icons\\Spell_Nature_Invisibilty"] = {name="Potion of Quickness", duration=30, texture="Interface\\Icons\\Spell_Nature_Invisibilty"},  -- Turtle WoW
    ["Interface\\Icons\\Spell_Nature_EarthBind"] = {name="Swiftness", duration=15, texture="Interface\\Icons\\Spell_Nature_EarthBind"},
    -- Note: Juju Flurry removed - shares texture with Juju Might (AP buff). Need tooltip scan or different detection method.
}

-- Reverse lookup for tooltip display (when we need the name)
local hasteBuffNames = {}
for texture, data in pairs(hasteBuffsByTexture) do
    hasteBuffNames[data.name] = true
end

-- buffDurations removed - duration is now stored in hasteBuffsByTexture table

-- Hunter Instant Shots (should NOT reset auto shot timer)
-- Based on Quiver addon: https://github.com/SabineWren/Quiver
local instantShots = {
    ["Arcane Shot"] = true,
    ["Arkaner Schuss"] = true,  -- German
    ["Serpent Sting"] = true,
    ["Schlangenbiss"] = true,  -- German  
    ["Viper Sting"] = true,
    ["Vipernbiss"] = true,  -- German
    ["Scorpid Sting"] = true,
    ["Skorpidstich"] = true,  -- German
    ["Concussive Shot"] = true,
    ["Erschütternder Schuss"] = true,  -- German
    ["Scatter Shot"] = true,
    ["Streuschuss"] = true,  -- German
    ["Wyvern Sting"] = true,
    ["Wyvernstich"] = true,  -- German
    ["Baited Shot"] = true,  -- Turtle WoW
    ["Köder-Schuss"] = true,  -- German
}

local lastInstantShotTime = 0

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
    -- PERFORMANCE: Early exit if castbar is disabled
    if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showCastbar then return end
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
        if trackStats and timeReload.IsStarted() then
            local reloadDuration = weaponSpeed - AIMING_TIME
            local castEndTime = castStartTime + castTime
            local elapsed = timeReload.GetElapsed()
            
            -- Yellow phase: from reload complete to shoot complete
            local yellowPhaseStart = reloadDuration
            local yellowPhaseEnd = weaponSpeed
            
            -- Check if cast overlaps with yellow phase
            -- Cast overlaps if: cast starts before yellow ends AND cast ends after yellow starts
            local castStartsAt = elapsed
            local castEndsAt = elapsed + castTime
            local castOverlapsYellow = (castStartsAt < yellowPhaseEnd) and (castEndsAt >= yellowPhaseStart)
            
            if castOverlapsYellow then
                -- Calculate the delay: how much longer until next auto-shot compared to normal
                -- Normal: yellow phase would end at weaponSpeed elapsed time
                -- With cast: yellow phase ends at (castEndTime + AIMING_TIME)
                local normalYellowEnd = yellowPhaseEnd
                local actualYellowEnd = castEndsAt + AIMING_TIME
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
    if HamingwaysHunterToolsDB.showStats == nil then
        HamingwaysHunterToolsDB.showStats = true
    end
    if HamingwaysHunterToolsDB.showAmmo == nil then
        HamingwaysHunterToolsDB.showAmmo = true
    end
    if HamingwaysHunterToolsDB.showAutoShotTimer == nil then
        HamingwaysHunterToolsDB.showAutoShotTimer = true
    end
    if HamingwaysHunterToolsDB.showCastbar == nil then
        HamingwaysHunterToolsDB.showCastbar = true
    end
    if HamingwaysHunterToolsDB.showBuffBar == nil then
        HamingwaysHunterToolsDB.showBuffBar = true
    end
    if HamingwaysHunterToolsDB.showPetFeeder == nil then
        HamingwaysHunterToolsDB.showPetFeeder = true
    end
    if HamingwaysHunterToolsDB.autoFeedPet == nil then
        HamingwaysHunterToolsDB.autoFeedPet = true
    end
    if HamingwaysHunterToolsDB.feedOnClick == nil then
        HamingwaysHunterToolsDB.feedOnClick = true
    end
    if HamingwaysHunterToolsDB.autoResetStats == nil then
        HamingwaysHunterToolsDB.autoResetStats = true
    end
    HamingwaysHunterToolsDB.petFeederIconSize = HamingwaysHunterToolsDB.petFeederIconSize or DEFAULT_PET_FEEDER_ICON_SIZE
    HamingwaysHunterToolsDB.selectedFood = HamingwaysHunterToolsDB.selectedFood or {}
    HamingwaysHunterToolsDB.petFoodBlacklist = HamingwaysHunterToolsDB.petFoodBlacklist or {}
    HamingwaysHunterToolsDB.showOnlyInCombat = HamingwaysHunterToolsDB.showOnlyInCombat ~= nil and HamingwaysHunterToolsDB.showOnlyInCombat or DEFAULT_SHOW_ONLY_IN_COMBAT
    if HamingwaysHunterToolsDB.showTimerText == nil then
        HamingwaysHunterToolsDB.showTimerText = true
    end
    HamingwaysHunterToolsDB.reloadColor = HamingwaysHunterToolsDB.reloadColor or {r=DEFAULT_RELOAD_COLOR.r, g=DEFAULT_RELOAD_COLOR.g, b=DEFAULT_RELOAD_COLOR.b}
    HamingwaysHunterToolsDB.aimingColor = HamingwaysHunterToolsDB.aimingColor or {r=DEFAULT_AIMING_COLOR.r, g=DEFAULT_AIMING_COLOR.g, b=DEFAULT_AIMING_COLOR.b}
    HamingwaysHunterToolsDB.castColor = HamingwaysHunterToolsDB.castColor or {r=DEFAULT_CAST_COLOR.r, g=DEFAULT_CAST_COLOR.g, b=DEFAULT_CAST_COLOR.b}
    HamingwaysHunterToolsDB.bgColor = HamingwaysHunterToolsDB.bgColor or {r=DEFAULT_BG_COLOR.r, g=DEFAULT_BG_COLOR.g, b=DEFAULT_BG_COLOR.b}
    HamingwaysHunterToolsDB.bgOpacity = HamingwaysHunterToolsDB.bgOpacity or DEFAULT_BG_OPACITY
    
    -- Melee Timer Defaults
    HamingwaysHunterToolsDB.meleeColor = HamingwaysHunterToolsDB.meleeColor or {r=DEFAULT_MELEE_COLOR.r, g=DEFAULT_MELEE_COLOR.g, b=DEFAULT_MELEE_COLOR.b}
    if HamingwaysHunterToolsDB.showMeleeTimer == nil then
        HamingwaysHunterToolsDB.showMeleeTimer = DEFAULT_SHOW_MELEE_TIMER
    end
    if HamingwaysHunterToolsDB.meleeTimerOnlyInCombat == nil then
        HamingwaysHunterToolsDB.meleeTimerOnlyInCombat = DEFAULT_MELEE_ONLY_IN_COMBAT
    end
    if HamingwaysHunterToolsDB.meleeTimerInsteadOfAutoShot == nil then
        HamingwaysHunterToolsDB.meleeTimerInsteadOfAutoShot = DEFAULT_MELEE_INSTEAD_OF_AUTOSHOT
    end
    if HamingwaysHunterToolsDB.autoSwitchMeleeRanged == nil then
        HamingwaysHunterToolsDB.autoSwitchMeleeRanged = DEFAULT_AUTO_SWITCH_MELEE_RANGED
    end
    
    return {
        minimapPos = HamingwaysHunterToolsDB.minimapPos,
        locked = HamingwaysHunterToolsDB.locked,
        frameWidth = HamingwaysHunterToolsDB.frameWidth,
        frameHeight = HamingwaysHunterToolsDB.frameHeight,
        borderSize = HamingwaysHunterToolsDB.borderSize,
        castbarSpacing = HamingwaysHunterToolsDB.castbarSpacing,
        iconSize = HamingwaysHunterToolsDB.iconSize,
        ammoIconSize = HamingwaysHunterToolsDB.ammoIconSize,
        petFeederIconSize = HamingwaysHunterToolsDB.petFeederIconSize,
        statsFontSize = HamingwaysHunterToolsDB.statsFontSize,
        showStats = HamingwaysHunterToolsDB.showStats,
        showAmmo = HamingwaysHunterToolsDB.showAmmo,
        showAutoShotTimer = HamingwaysHunterToolsDB.showAutoShotTimer,
        showCastbar = HamingwaysHunterToolsDB.showCastbar,
        showBuffBar = HamingwaysHunterToolsDB.showBuffBar,
        showPetFeeder = HamingwaysHunterToolsDB.showPetFeeder,
        autoFeedPet = HamingwaysHunterToolsDB.autoFeedPet,
        feedOnClick = HamingwaysHunterToolsDB.feedOnClick,
        autoResetStats = HamingwaysHunterToolsDB.autoResetStats,
        selectedFood = HamingwaysHunterToolsDB.selectedFood,
        petFoodBlacklist = HamingwaysHunterToolsDB.petFoodBlacklist,
        showOnlyInCombat = HamingwaysHunterToolsDB.showOnlyInCombat,
        showTimerText = HamingwaysHunterToolsDB.showTimerText,
        reloadColor = HamingwaysHunterToolsDB.reloadColor,
        aimingColor = HamingwaysHunterToolsDB.aimingColor,
        castColor = HamingwaysHunterToolsDB.castColor,
        bgColor = HamingwaysHunterToolsDB.bgColor,
        bgOpacity = HamingwaysHunterToolsDB.bgOpacity,
        meleeColor = HamingwaysHunterToolsDB.meleeColor,
        showMeleeTimer = HamingwaysHunterToolsDB.showMeleeTimer,
        meleeTimerOnlyInCombat = HamingwaysHunterToolsDB.meleeTimerOnlyInCombat,
        meleeTimerInsteadOfAutoShot = HamingwaysHunterToolsDB.meleeTimerInsteadOfAutoShot,
        autoSwitchMeleeRanged = HamingwaysHunterToolsDB.autoSwitchMeleeRanged
    }
end

-- ============ Helper Functions ============
-- Config cache for performance
local configCache = nil

local function InvalidateConfigCache()
    configCache = nil
end

local function GetCachedConfig()
    if not configCache then
        configCache = GetConfig()
    end
    return configCache
end

-- Create backdrop configuration (used by multiple frames)
local function CreateBackdrop(borderSize)
    if borderSize and borderSize > 0 then
        return {
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false,
            edgeSize = borderSize,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        }
    else
        return {
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = nil,
            tile = false,
            edgeSize = 0,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        }
    end
end

-- Make frame draggable with position saving
local function MakeDraggable(frame, dbKeyPrefix)
    frame:SetScript("OnDragStart", function()
        local cfg = GetCachedConfig()
        if not cfg.locked then
            this:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local point, _, _, xOfs, yOfs = this:GetPoint()
        HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
        HamingwaysHunterToolsDB[dbKeyPrefix .. "Point"] = point
        HamingwaysHunterToolsDB[dbKeyPrefix .. "X"] = xOfs
        HamingwaysHunterToolsDB[dbKeyPrefix .. "Y"] = yOfs
    end)
end

-- Show tooltip with title and optional lines
local function ShowTooltip(frame, title, lines, anchor)
    GameTooltip:SetOwner(frame, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    if lines then
        for i = 1, table.getn(lines) do
            local line = lines[i]
            if type(line) == "string" then
                GameTooltip:AddLine(line, 0.8, 0.8, 0.8)
            elseif type(line) == "table" then
                GameTooltip:AddLine(line.text, line.r or 0.8, line.g or 0.8, line.b or 0.8)
            end
        end
    end
    GameTooltip:Show()
end

-- Create a checkbox control with label
local function CreateCheckbox(name, parent, label, yOffset)
    local checkbox = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    checkbox:SetPoint("TOPLEFT", 10, yOffset)
    getglobal(checkbox:GetName().."Text"):SetText(label)
    return checkbox
end

-- Create a slider control
local function CreateSlider(name, parent, text, yOffset, minVal, maxVal, step, onValueChanged)
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 10, yOffset)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetWidth(250)
    getglobal(slider:GetName().."Low"):SetText(tostring(minVal))
    getglobal(slider:GetName().."High"):SetText(tostring(maxVal))
    getglobal(slider:GetName().."Text"):SetText(text)
    if onValueChanged then
        slider:SetScript("OnValueChanged", onValueChanged)
    end
    return slider
end

-- ============ Colors (dynamic from config) ============

local function UpdateWeaponSpeed()
    local speed = UnitRangedDamage("player")
    if speed and speed > 0 then
        weaponSpeed = speed
    end
end

local function UpdateMeleeSpeed()
    local speed, offhandSpeed = UnitAttackSpeed("player")
    if speed and speed > 0 then
        meleeSwingSpeed = speed
    end
end

-- Check if target is in melee range
local function IsTargetInMeleeRange()
    if not UnitExists("target") or UnitIsDead("target") then
        return false
    end
    -- CheckInteractDistance 3 = Duel distance (~10 yards, melee range)
    return CheckInteractDistance("target", 3)
end

-- PERFORMANCE: Register/unregister combat events only when timer mode changes
-- MUST be defined BEFORE UpdateTimerMode (which calls it)
local function UpdateCombatEventRegistration()
    -- PERFORMANCE: Direct DB access instead of GetCachedConfig()
    if not HamingwaysHunterToolsDB then return end
    local shouldRegister = (HamingwaysHunterToolsDB.showMeleeTimer or HamingwaysHunterToolsDB.autoSwitchMeleeRanged) and useMeleeTimer
    
    if shouldRegister then
        -- Register combat events if not already registered
        if not registeredEvents["CHAT_MSG_COMBAT_SELF_HITS"] then
            AH:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
            AH:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
            registeredEvents["CHAT_MSG_COMBAT_SELF_HITS"] = true
            registeredEvents["CHAT_MSG_COMBAT_SELF_MISSES"] = true
        end
    else
        -- Unregister combat events when melee timer disabled
        if registeredEvents["CHAT_MSG_COMBAT_SELF_HITS"] then
            AH:UnregisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
            AH:UnregisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
            registeredEvents["CHAT_MSG_COMBAT_SELF_HITS"] = nil
            registeredEvents["CHAT_MSG_COMBAT_SELF_MISSES"] = nil
            isMeleeSwinging = false
        end
    end
end

-- Determine which timer mode to use
local function UpdateTimerMode()
    -- PERFORMANCE: Direct DB access instead of GetCachedConfig()
    if not HamingwaysHunterToolsDB then return end
    local oldMode = useMeleeTimer
    
    -- Melee timer is bound to AutoShot visibility
    if not HamingwaysHunterToolsDB.showAutoShotTimer then
        -- AutoShot timer disabled, always use ranged (hidden anyway)
        useMeleeTimer = false
    -- Enable melee timer if either showMeleeTimer is true OR autoSwitch is enabled
    elseif not HamingwaysHunterToolsDB.showMeleeTimer and not HamingwaysHunterToolsDB.autoSwitchMeleeRanged then
        useMeleeTimer = false
    elseif HamingwaysHunterToolsDB.meleeTimerInsteadOfAutoShot then
        -- Always use melee timer
        useMeleeTimer = true
    elseif HamingwaysHunterToolsDB.autoSwitchMeleeRanged then
        -- Auto-switch based on range
        useMeleeTimer = IsTargetInMeleeRange()
    else
        -- Default: use ranged
        useMeleeTimer = false
    end
    
    -- Only update event registration if mode actually changed
    if oldMode ~= useMeleeTimer then
        UpdateCombatEventRegistration()
    end
end

-- ============ Range Detection (Quiver-style) ============
local function CheckSpellInRange(spellName)
    local spellIndex = FindSpellByName(spellName)
    if not spellIndex then return false end
    
    local slot = FindActionSlotBySpellName(spellName)
    if not slot then return false end
    
    return IsActionInRange(slot) == 1
end

local function GetTargetRange()
    if not UnitExists("target") or UnitIsDead("target") or not UnitCanAttack("player", "target") then
        return nil
    end
    
    -- CheckInteractDistance: 3 = ~10 yards (inspect), 4 = 28 yards (follow)
    local isMelee = CheckInteractDistance("target", 3)
    local isFollow = CheckInteractDistance("target", 4)
    
    -- Check spell ranges (requires spells on action bars)
    local isRanged = CheckSpellInRange("Auto Shot")
    local isScatter = CheckSpellInRange("Scatter Shot")
    local isScare = CheckSpellInRange("Scare Beast")
    
    if isMelee then
        return "Melee Range", false
    elseif isRanged then
        -- In ranged attack range
        if UnitCreatureType("target") == "Beast" and isScare then
            return "Scare Beast", false
        elseif isScatter then
            return "Scatter Shot", false
        elseif isFollow then
            return "Short Range", false
        else
            return "Long Range", false
        end
    elseif isFollow then
        return "Dead Zone", true  -- BLINK!
    else
        return "Out of Range", false
    end
end

-- Scan Mounts tab in spellbook (Turtle WoW specific)
local function ScanMountSpells()
    mountSpells = {}  -- Reset table
    local numTabs = GetNumSpellTabs()
    
    for tabIndex = 1, numTabs do
        local tabName, tabTexture, tabOffset, numEntries = GetSpellTabInfo(tabIndex)
        
        -- Check if this is the Mounts tab (ZMounts in Turtle WoW)
        if tabName == "ZMounts" or tabName == "Mounts" then
            -- Scan all spells in this tab
            for i = 1, numEntries do
                local spellIndex = tabOffset + i
                local spellName, spellRank = GetSpellName(spellIndex, BOOKTYPE_SPELL)
                
                if spellName then
                    mountSpells[spellName] = true
                end
            end
            break  -- Found the tab, no need to continue
        end
    end
end

-- Check if player is currently mounted (Turtle WoW)
local function IsPlayerMounted()
    -- Scan player buffs
    local i = 1
    while UnitBuff("player", i) do
        local buffTexture = UnitBuff("player", i)
        
        -- Get buff name by scanning tooltip
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:SetUnitBuff("player", i)
        local buffName = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        GameTooltip:Hide()
        
        if buffName and mountSpells[buffName] then
            return true
        end
        
        i = i + 1
    end
    
    return false
end

-- ============ Frame Update functions (defined before CreateUI) ============
local maxBarWidth = 0

-- PERFORMANCE: Text caching to avoid unnecessary SetText() calls (LUA 5.0: use table to avoid upvalue limit)
local textCache = {
    barText = nil,
    barTextTotal = nil,
    barTextRange = nil,
    lastUpdate = 0,
    interval = 0.1,  -- Update text max 10x/second (smooth enough, 50% less overhead)
    lastBlink = false
}

local function UpdateBarShoot(now)
    if not barFrame or not barText or not barTextTotal then return end
    -- PERFORMANCE: Direct DB access - this runs 60 times per second!
    local db = HamingwaysHunterToolsDB
    if not db then return end
    
    -- Yellow bar: anchor LEFT, grow left to right during aiming window
    barFrame:ClearAllPoints()
    barFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    barFrame:Show()
    
    -- Calculate elapsed time from shoot start
    local shootElapsed = timeShoot.GetElapsed()
    local remainingShoot = AIMING_TIME - shootElapsed
    
    -- PERFORMANCE: Throttle text updates to 20x/second
    if now - textCache.lastUpdate >= textCache.interval then
        textCache.lastUpdate = now
        
        -- Update timer display (show shoot elapsed / weapon speed)
        if db.showTimerText then
            local totalElapsed = timeReload.GetElapsed() + shootElapsed
            local newText = string.format("%.2fs/%.2fs", totalElapsed, weaponSpeed)
            if newText ~= textCache.barTextTotal then
                barTextTotal:SetText(newText)
                textCache.barTextTotal = newText
            end
        else
            if textCache.barTextTotal ~= "" then
                barTextTotal:SetText("")
                textCache.barTextTotal = ""
            end
        end
    end
    
    -- Update range display (center of bar) - use cached value
    if barTextRange then
        if cachedRangeText ~= textCache.barTextRange then
            barTextRange:SetText(cachedRangeText or "")
            textCache.barTextRange = cachedRangeText
        end
        -- Blink in Dead Zone
        if cachedIsDeadZone then
            local blink = math.mod(math.floor(now * 3), 2) == 0
            if blink ~= textCache.lastBlink then
                barTextRange:SetAlpha(blink and 1 or 0.3)
                textCache.lastBlink = blink
            end
        else
            barTextRange:SetAlpha(1)
            textCache.lastBlink = false
        end
    end
    
    -- Show yellow bar during aiming window
    if remainingShoot > 0 then
        -- Width grows left to right (elapsed time)
        local percentElapsed = shootElapsed / AIMING_TIME
        local width = math.max(1, maxBarWidth * percentElapsed)
        barFrame:SetWidth(width)
        barFrame:SetBackdropColor(db.aimingColor.r, db.aimingColor.g, db.aimingColor.b, BAR_ALPHA)
        if db.showTimerText and now - textCache.lastUpdate < textCache.interval then
            local newText = string.format("%.2fs", remainingShoot)
            if newText ~= textCache.barText then
                barText:SetText(newText)
                textCache.barText = newText
            end
        elseif textCache.barText ~= "" then
            barText:SetText("")
            textCache.barText = ""
        end
    else
        -- Ready to shoot: show full yellow bar
        barFrame:SetWidth(maxBarWidth)
        barFrame:SetBackdropColor(db.aimingColor.r, db.aimingColor.g, db.aimingColor.b, BAR_ALPHA)
        if textCache.barText ~= "" then
            barText:SetText("")
            textCache.barText = ""
        end
    end
end

local function UpdateBarReload(now)
    if not barFrame or not barText or not barTextTotal then return end
    -- PERFORMANCE: Direct DB access - this runs 60 times per second!
    local db = HamingwaysHunterToolsDB
    if not db then return end
    
    -- Check if reload is complete and transition to shoot phase
    if timeReload.IsComplete() then
        isReloading = false
        UpdateWeaponSpeed()  -- Update speed before shoot phase
        timeShoot.Start()  -- Start shoot timer when reload completes
        return
    end
    
    -- Red bar: anchor LEFT, grow left to right (inverted fill)
    barFrame:ClearAllPoints()
    barFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    
    -- Use closure pattern for efficient calculation
    local percent = timeReload.GetPercent()
    local elapsed = timeReload.GetElapsed()
    local reloadDuration = weaponSpeed - AIMING_TIME
    local remainingReload = reloadDuration - elapsed
    
    -- PERFORMANCE: Throttle text updates
    if now - textCache.lastUpdate >= textCache.interval then
        textCache.lastUpdate = now
        
        -- Update timer display (no range in timer text)
        if db.showTimerText then
            local newText = string.format("%.2fs/%.2fs", elapsed, weaponSpeed)
            if newText ~= textCache.barTextTotal then
                barTextTotal:SetText(newText)
                textCache.barTextTotal = newText
            end
        else
            if textCache.barTextTotal ~= "" then
                barTextTotal:SetText("")
                textCache.barTextTotal = ""
            end
        end
    end
    
    -- Update range display (center of bar) - use cached value
    if barTextRange then
        if cachedRangeText ~= textCache.barTextRange then
            barTextRange:SetText(cachedRangeText or "")
            textCache.barTextRange = cachedRangeText
        end
        -- Blink in Dead Zone
        if cachedIsDeadZone then
            local blink = math.mod(math.floor(now * 3), 2) == 0
            if blink ~= textCache.lastBlink then
                barTextRange:SetAlpha(blink and 1 or 0.3)
                textCache.lastBlink = blink
            end
        else
            barTextRange:SetAlpha(1)
            textCache.lastBlink = false
        end
    end
    
    if remainingReload > 0 then
        -- Inverted: show empty space growing
        local width = math.max(1, maxBarWidth * (1 - percent))
        barFrame:SetWidth(width)
        barFrame:SetBackdropColor(db.reloadColor.r, db.reloadColor.g, db.reloadColor.b, BAR_ALPHA)
        if db.showTimerText and now - textCache.lastUpdate < textCache.interval then
            local newText = string.format("%.2fs", remainingReload)
            if newText ~= textCache.barText then
                barText:SetText(newText)
                textCache.barText = newText
            end
        elseif textCache.barText ~= "" then
            barText:SetText("")
            textCache.barText = ""
        end
    else
        isReloading = false
    end
end

local function UpdateBarMelee(now)
    if not barFrame or not barTextTotal then return end
    -- PERFORMANCE: Direct DB access - this runs 60 times per second!
    local db = HamingwaysHunterToolsDB
    if not db then return end
    
    -- Orange bar for melee swings
    barFrame:ClearAllPoints()
    barFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    
    local elapsed = isMeleeSwinging and (now - lastMeleeSwingTime) or 0
    local remainingSwing = math.max(0, meleeSwingSpeed - elapsed)
    
    -- Auto-stop tracking after 3 seconds of no swings
    if isMeleeSwinging and elapsed > (meleeSwingSpeed + 3.0) then
        isMeleeSwinging = false
        remainingSwing = meleeSwingSpeed
    end
    
    -- Hide left timer text in melee mode
    if barText and textCache.barText ~= "" then
        barText:SetText("")
        textCache.barText = ""
    end
    
    -- Update timer display - only seconds, no "Melee" prefix
    if db.showTimerText and now - textCache.lastUpdate >= textCache.interval then
        local newText = string.format("%.2fs", remainingSwing)
        if newText ~= textCache.barTextTotal then
            barTextTotal:SetText(newText)
            textCache.barTextTotal = newText
        end
    elseif textCache.barTextTotal ~= "" then
        barTextTotal:SetText("")
        textCache.barTextTotal = ""
    end
    
    -- Update range display (center of bar) - use cached value
    if barTextRange then
        if cachedRangeText ~= textCache.barTextRange then
            barTextRange:SetText(cachedRangeText or "")
            textCache.barTextRange = cachedRangeText
        end
        -- Blink in Dead Zone
        if cachedIsDeadZone then
            local blink = math.mod(math.floor(now * 3), 2) == 0
            if blink ~= textCache.lastBlink then
                barTextRange:SetAlpha(blink and 1 or 0.3)
                textCache.lastBlink = blink
            end
        else
            barTextRange:SetAlpha(1)
            textCache.lastBlink = false
        end
    end
    
    if remainingSwing > 0 then
        -- Show progress bar (growing from left to right as swing progresses)
        local percentElapsed = elapsed / meleeSwingSpeed
        local width = math.max(1, maxBarWidth * percentElapsed)
        barFrame:SetWidth(width)
        barFrame:SetBackdropColor(db.meleeColor.r, db.meleeColor.g, db.meleeColor.b, BAR_ALPHA)
    else
        -- Ready for next swing (100% full, change color to indicate ready)
        barFrame:SetWidth(maxBarWidth)
        barFrame:SetBackdropColor(1.0, 0.8, 0.8, BAR_ALPHA)  -- Lighter color when ready
    end
end

local function UpdateAmmoDragState()
    if ammoFrame then
        local cfg = GetCachedConfig()
        if cfg.locked then
            ammoFrame:RegisterForDrag()  -- Disable dragging
        else
            ammoFrame:RegisterForDrag("LeftButton")  -- Enable dragging
        end
    end
end

local function UpdateStatsDragState()
    if statsFrame then
        local cfg = GetCachedConfig()
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
        frame:SetBackdrop(CreateBackdrop(cfg.borderSize))
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
        castFrame:SetBackdrop(CreateBackdrop(cfg.borderSize))
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
            castBarFrame:SetBackdropColor(cfg.castColor.r, cfg.castColor.g, cfg.castColor.b, BAR_ALPHA)
        end
    end
    
    if hasteFrame then
        hasteFrame:SetWidth(cfg.frameWidth)
        hasteFrame:SetHeight(cfg.iconSize + 4)
    end
    
    if ammoMenuFrame then
        ammoMenuFrame:SetBackdrop(CreateBackdrop(cfg.borderSize))
        ammoMenuFrame:SetBackdropColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b, cfg.bgOpacity)
    end
    
    -- Apply settings to Pet Feeder Frame
    if petFeedFrame then
        local iconSize = cfg.petFeederIconSize or DEFAULT_PET_FEEDER_ICON_SIZE
        local frameWidth = iconSize * 2 + 9
        local frameHeight = iconSize + 4
        
        petFeedFrame:SetWidth(frameWidth)
        petFeedFrame:SetHeight(frameHeight)
        
        petFeedFrame:SetBackdrop(CreateBackdrop(cfg.borderSize))
        
        -- Keep green color but apply config opacity and border opacity
        petFeedFrame:SetBackdropColor(0, 0.6, 0, cfg.bgOpacity)
        petFeedFrame:SetBackdropBorderColor(0.67, 0.83, 0.45, cfg.borderOpacity or 1)
        
        -- Update icon sizes and positions
        if petIconButton then
            petIconButton:SetWidth(iconSize)
            petIconButton:SetHeight(iconSize)
            petIconButton:ClearAllPoints()
            petIconButton:SetPoint("LEFT", petFeedFrame, "LEFT", 2, 0)
        end
        if foodIconButton then
            foodIconButton:SetWidth(iconSize)
            foodIconButton:SetHeight(iconSize)
            foodIconButton:ClearAllPoints()
            foodIconButton:SetPoint("LEFT", petIconButton, "RIGHT", 5, 0)
        end
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
    
    -- PERFORMANCE: Use SetAlpha instead of Show/Hide (Quiver-style)
    -- AutoShot Timer Frame
    if frame and HamingwaysHunterToolsDB.showAutoShotTimer then
        if shouldShow then
            frame:SetAlpha(1)
            frame:Show()
        else
            frame:SetAlpha(0)
            if not previewMode then frame:Hide() end
        end
    elseif frame then
        frame:SetAlpha(0)
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
    
    -- Pet Feeder - respect show toggle
    if petFeedFrame then
        if not HamingwaysHunterToolsDB.showPetFeeder then
            petFeedFrame:Hide()
        else
            -- Show immediately (UpdatePetFeederDisplay will be called by event handlers)
            petFeedFrame:Show()
        end
    end
end

-- ============ Haste Buff Tracker Functions ============
-- PERFORMANCE: Reusable tables to avoid GC pressure (Quiver object pooling pattern)
local activeBuffs = {}
local foundBuffs = {}
local activeBuffCount = 0

local function UpdateHasteBuffs()
    if not hasteFrame then return end
    if previewMode then return end  -- Don't update buffs in preview mode
    
    -- PERFORMANCE: Direct DB access instead of GetCachedConfig() - called from event handler
    if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showBuffBar then
        hasteFrame:Hide()
        return
    end
    
    -- PERFORMANCE: Reuse tables instead of creating new ones (pfUI pattern)
    for k in pairs(foundBuffs) do foundBuffs[k] = nil end
    
    -- Store old count to clear unused slots
    local oldBuffCount = activeBuffCount
    activeBuffCount = 0
    local currentTime = GetTime()
    
    -- Scan all buff slots (Vanilla 1.12 API)
    for i = 0, MAX_BUFF_SLOTS do
        -- Get buff directly via GetPlayerBuff
        local buffId = GetPlayerBuff(PLAYER_BUFF_START_ID + i, "HELPFUL")
        if buffId >= 0 then
            local buffTexture = GetPlayerBuffTexture(buffId)
            local buffCount = GetPlayerBuffApplications(buffId)
            local buffIndex = PLAYER_BUFF_START_ID + i  -- Store INDEX for GetPlayerBuffTimeLeft
            local actualRemaining = GetPlayerBuffTimeLeft(buffIndex)
            
            -- TEXTURE-BASED DETECTION - 10000x faster than tooltip scan!
            if buffTexture and hasteBuffsByTexture[buffTexture] then
                local buffData = hasteBuffsByTexture[buffTexture]
                local buffName = buffData.name
                
                -- Skip if we already found this buff (prevent duplicates)
                -- Also skip if buff has expired (remaining time <= 0)
                if not foundBuffs[buffName] and actualRemaining and actualRemaining > 0 then
                    foundBuffs[buffName] = true
                    
                    -- PERFORMANCE: Reuse existing table entry instead of creating new one (Quiver pattern)
                    activeBuffCount = activeBuffCount + 1
                    if not activeBuffs[activeBuffCount] then
                        activeBuffs[activeBuffCount] = {}
                    end
                    local buff = activeBuffs[activeBuffCount]
                    buff.name = buffName
                    buff.texture = buffTexture
                    buff.buffIndex = buffIndex  -- Store INDEX for GetPlayerBuffTimeLeft
                    buff.count = buffCount or 0
                end
            end
        end
    end
    
    -- Clear unused buff slots (prevent showing old buffs)
    for i = activeBuffCount + 1, oldBuffCount do
        if activeBuffs[i] then
            activeBuffs[i].buffIndex = nil
            activeBuffs[i].name = nil
            activeBuffs[i].texture = nil
        end
    end
    
    -- Update icons
    local iconSize = HamingwaysHunterToolsDB.iconSize or DEFAULT_ICON_SIZE
    
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
        
        if activeBuffs[i] and activeBuffs[i].buffIndex then
            -- Query API once and cache the value
            local remaining = GetPlayerBuffTimeLeft(activeBuffs[i].buffIndex)
            activeBuffs[i].cachedRemaining = remaining  -- Cache for UpdateBuffCountdowns
            
            -- Only show icon if buff still has time remaining
            if remaining and remaining > 0 then
                hasteIcons[i].icon:SetTexture(activeBuffs[i].texture)
                local seconds = math.floor(remaining)
                hasteIcons[i].cooldown:SetText(tostring(seconds))
                hasteIcons[i]:Show()
            else
                -- Buff expired, hide icon
                hasteIcons[i]:Hide()
            end
        else
            hasteIcons[i]:Hide()
        end
    end
    
    -- Show/hide frame based on active buffs and combat setting
    if activeBuffCount > 0 and HamingwaysHunterToolsDB.showBuffBar then
        local showOnlyInCombat = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showOnlyInCombat
        local inCombat = UnitAffectingCombat("player")
        if not showOnlyInCombat or inCombat or previewMode or isCasting or isShooting then
            hasteFrame:Show()
        end
    else
        hasteFrame:Hide()
    end
end

-- Efficient OnUpdate for buff countdown (separate from UpdateHasteBuffs)
local function UpdateBuffCountdowns()
    -- CRITICAL: Early exit if no active buffs (most common case out of combat)
    if activeBuffCount == 0 then return end
    if not hasteFrame or not hasteFrame:IsShown() then return end
    
    for i = 1, activeBuffCount do
        if activeBuffs[i] and activeBuffs[i].buffIndex and hasteIcons[i] and hasteIcons[i]:IsShown() then
            -- Query API for current remaining time (needed for countdown)
            local remaining = GetPlayerBuffTimeLeft(activeBuffs[i].buffIndex)
            
            if remaining > 0 then
                local seconds = math.floor(remaining)
                hasteIcons[i].cooldown:SetText(tostring(seconds))
            else
                hasteIcons[i].cooldown:SetText("0")
            end
        end
    end
end

-- ============ Pet Feeder Functions ============
local function HasPet()
    if not UnitExists("pet") then return false end
    local petName = UnitName("pet")
    if petName == "Unknown Entity" or petName == "Unknown" or petName == UNKNOWNOBJECT then
        return false
    end
    return true
end

local function HasFeedEffect()
    -- Check for "Feed Pet Effect" buff by scanning tooltip text
    -- Note: GetPlayerBuffTexture() only works for player buffs, not pet buffs in Vanilla
    -- Since this is called infrequently (~1x/minute) and pets have few buffs (5-10 max),
    -- the tooltip scan performance impact is negligible (~2ms)
    local i = 1
    while UnitBuff("pet", i) do
        if HamingwaysHunterToolsTooltip then
            HamingwaysHunterToolsTooltip:SetOwner(UIParent, "ANCHOR_NONE")
            HamingwaysHunterToolsTooltip:SetUnitBuff("pet", i)
            local buffName = HamingwaysHunterToolsTooltipTextLeft1:GetText()
            HamingwaysHunterToolsTooltip:Hide()
            
            -- Check for exact buff name (localized)
            if buffName and (
               string.find(buffName, "Feed Pet Effect") or  -- English
               string.find(buffName, "Haustier.*Effect") or  -- German (Haustier füttern Effect)
               string.find(buffName, "Effet.*familier")      -- French
            ) then
                return true
            end
        end
        i = i + 1
    end
    return false
end

local function IsPetFoodByID(itemID)
    if not itemID then return false end
    if not UnitExists("pet") then return false end
    
    local foodTypes = {GetPetFoodTypes()}
    if not foodTypes or table.getn(foodTypes) == 0 then return false end
    
    for _, foodType in ipairs(foodTypes) do
        local diet = string.lower(foodType)
        if PET_FOODS[diet] then
            for _, foodID in ipairs(PET_FOODS[diet]) do
                if foodID == itemID then
                    return true
                end
            end
        end
    end
    
    return false
end

local function FindPetFoodInBags()
    if not HasPet() then return {} end
    
    local foodList = {}
    local foodCounts = {}
    local petName = UnitName("pet")
    local cfg = GetConfig()
    local blacklist = cfg.petFoodBlacklist[petName] or {}
    
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local texture, count = GetContainerItemInfo(bag, slot)
                if texture and count then
                    local itemLink = GetContainerItemLink(bag, slot)
                    if itemLink then
                        local _, _, itemID = string.find(itemLink, "item:(%d+)")
                        itemID = tonumber(itemID)
                        
                        -- Check if item is blacklisted for this pet
                        local isBlacklisted = false
                        if itemID and blacklist then
                            for i = 1, table.getn(blacklist) do
                                if blacklist[i] == itemID then
                                    isBlacklisted = true
                                    break
                                end
                            end
                        end
                        
                        if itemID and IsPetFoodByID(itemID) and not isBlacklisted then
                            local itemName = GetItemInfo(itemID)
                            if itemName then
                                if foodCounts[itemName] then
                                    foodCounts[itemName].count = foodCounts[itemName].count + count
                                else
                                    foodCounts[itemName] = {
                                        bag = bag,
                                        slot = slot,
                                        name = itemName,
                                        texture = texture,
                                        count = count,
                                        itemID = itemID
                                    }
                                    table.insert(foodList, foodCounts[itemName])
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    return foodList
end

local function FeedPet(silent)
    if not HasPet() then
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r No pet active", WARNING_COLOR.r, WARNING_COLOR.g, WARNING_COLOR.b)
        end
        return false
    end
    
    if UnitHealth("pet") <= 0 then
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r Pet is dead", WARNING_COLOR.r, WARNING_COLOR.g, WARNING_COLOR.b)
        end
        return false
    end
    
    -- Don't feed while casting
    if isCasting then
        return false  -- Silent check for casting
    end
    
    if HasFeedEffect() then
        return false  -- Already feeding
    end
    
    -- Check if we recently fed (within last 15 seconds) - prevents double feeding while buff applies
    if petFeedFrame and petFeedFrame.lastSuccessfulFeed then
        local timeSinceLastFeed = GetTime() - petFeedFrame.lastSuccessfulFeed
        if timeSinceLastFeed < 15 then
            return false
        end
    end
    
    local foodToFeed = nil
    local petName = UnitName("pet")
    
    -- Load pet-specific selected food
    if petName and HamingwaysHunterToolsDB.selectedFood and HamingwaysHunterToolsDB.selectedFood[petName] then
        selectedFood = HamingwaysHunterToolsDB.selectedFood[petName]
    end
    
    -- Use selected food if available
    if selectedFood then
        local texture, count = GetContainerItemInfo(selectedFood.bag, selectedFood.slot)
        if texture and count then
            foodToFeed = selectedFood
        else
            selectedFood = nil  -- Clear invalid selection
            if HamingwaysHunterToolsDB.selectedFood then
                HamingwaysHunterToolsDB.selectedFood[petName] = nil
            end
        end
    end
    
    -- Find any pet food if no selection
    if not foodToFeed then
        local foodList = FindPetFoodInBags()
        if table.getn(foodList) > 0 then
            foodToFeed = foodList[1]  -- Use first available food
            selectedFood = foodToFeed  -- Remember for next time
            HamingwaysHunterToolsDB.selectedFood = HamingwaysHunterToolsDB.selectedFood or {}
            HamingwaysHunterToolsDB.selectedFood[petName] = foodToFeed
        end
    end
    
    if foodToFeed then
        -- Store the food we're about to attempt to feed (for error tracking)
        lastAttemptedFood = {
            itemID = foodToFeed.itemID,
            name = foodToFeed.name,
            petName = petName
        }
        
        PickupContainerItem(foodToFeed.bag, foodToFeed.slot)
        local hasCursor = CursorHasItem()
        
        if hasCursor then
            -- Suppress error sounds in silent mode (auto-feed)
            local oldUIErrorsFrameShow = nil
            if silent and UIErrorsFrame then
                oldUIErrorsFrameShow = UIErrorsFrame.Show
                UIErrorsFrame.Show = function() end
            end
            
            DropItemOnUnit("pet")
            
            -- Restore error frame
            if silent and UIErrorsFrame and oldUIErrorsFrameShow then
                UIErrorsFrame.Show = oldUIErrorsFrameShow
            end
            
            -- Check if drop was successful (cursor should be empty now)
            if CursorHasItem() then
                -- Drop failed, put item back (protected function restriction)
                PickupContainerItem(foodToFeed.bag, foodToFeed.slot)
                -- Don't spam chat in silent mode (auto-feed will retry on next target change)
                return false
            end
            if not silent then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r Feeding " .. petName .. " with " .. foodToFeed.name, 0.67, 0.83, 0.45)
            end
            -- Mark time of successful feed to prevent double-feeding
            if petFeedFrame then
                petFeedFrame.lastSuccessfulFeed = GetTime()
            end
            -- Update display will happen via events
            return true
        end
    else
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r No suitable pet food found", WARNING_COLOR.r, WARNING_COLOR.g, WARNING_COLOR.b)
        end
    end
    
    return false
end

local function UpdatePetFeederDisplay()
    -- Early exit: Frame doesn't exist
    if not petFeedFrame then return end
    
    -- PERFORMANCE: Direct DB access instead of GetCachedConfig() - called from event handler
    if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showPetFeeder then
        petFeedFrame:Hide()
        return
    end
    
    -- Early exit: Frame not visible (don't waste CPU on hidden UI)
    if not petFeedFrame:IsVisible() then return end
    
    if UnitExists("pet") and UnitIsDead("pet") then
        -- Pet is dead: Show Revive Pet icon
        if petIconButton and petIconButton.icon then
            petIconButton.icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastSoothe")
        end
        -- Red background when pet is dead
        if petFeedFrame then
            petFeedFrame:SetBackdropColor(UNHAPPY_COLOR_RED, 0, 0, HamingwaysHunterToolsDB.bgOpacity)
        end
        petFeedFrame:Show()
        return
    end
    
    if not HasPet() then
        -- No pet: Show default icon
        if petIconButton and petIconButton.icon then
            petIconButton.icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastCall")
        end
        -- Gray background when no pet
        if petFeedFrame then
            petFeedFrame:SetBackdropColor(INACTIVE_COLOR_GRAY, INACTIVE_COLOR_GRAY, INACTIVE_COLOR_GRAY, HamingwaysHunterToolsDB.bgOpacity)
        end
        petFeedFrame:Show()
        return
    end
    
    -- Pet exists: Show actual pet icon from unit frame
    if petIconButton and petIconButton.icon then
        SetPortraitTexture(petIconButton.icon, "pet")
    end
    
    -- Update frame background based on happiness
    local happiness = GetPetHappiness()
    if happiness and petFeedFrame then
        if happiness == 1 then
            -- Unhappy (red)
            petFeedFrame:SetBackdropColor(UNHAPPY_COLOR_RED, 0, 0, HamingwaysHunterToolsDB.bgOpacity)
        elseif happiness == 2 then
            -- Content (yellow/orange)
            petFeedFrame:SetBackdropColor(UNHAPPY_COLOR_RED, CONTENT_COLOR_ORANGE, 0, HamingwaysHunterToolsDB.bgOpacity)
        elseif happiness == 3 then
            -- Happy (green)
            petFeedFrame:SetBackdropColor(0, HAPPY_COLOR_GREEN, 0, HamingwaysHunterToolsDB.bgOpacity)
        else
            -- Unknown (gray)
            petFeedFrame:SetBackdropColor(INACTIVE_COLOR_GRAY, INACTIVE_COLOR_GRAY, INACTIVE_COLOR_GRAY, HamingwaysHunterToolsDB.bgOpacity)
        end
    end
    
    -- Load pet-specific food selection
    local petName = UnitName("pet")
    if petName and HamingwaysHunterToolsDB.selectedFood and HamingwaysHunterToolsDB.selectedFood[petName] then
        selectedFood = HamingwaysHunterToolsDB.selectedFood[petName]
    end
    
    -- Update food icon
    if selectedFood then
        -- Get current count from bags
        local currentCount = 0
        local foodList = FindPetFoodInBags()
        for i = 1, table.getn(foodList) do
            if foodList[i].itemID == selectedFood.itemID then
                currentCount = foodList[i].count
                break
            end
        end
        
        if foodIconButton and foodIconButton.icon then
            foodIconButton.icon:SetTexture(selectedFood.texture)
            -- Gray out food icon when pet has feed effect
            if HasFeedEffect() then
                foodIconButton.icon:SetVertexColor(0.4, 0.4, 0.4)
            else
                foodIconButton.icon:SetVertexColor(1, 1, 1)
            end
            if foodIconButton.countText then
                foodIconButton.countText:SetText(currentCount > 1 and tostring(currentCount) or "")
            end
        end
    else
        if foodIconButton and foodIconButton.icon then
            foodIconButton.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            if foodIconButton.countText then
                foodIconButton.countText:SetText("")
            end
        end
    end
    
    petFeedFrame:Show()
end

local function ShowFoodMenu()
    if not foodMenuFrame then return end
    if not HasPet() then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r No pet active", 1, 0.5, 0)
        return
    end
    
    local foodList = FindPetFoodInBags()
    if table.getn(foodList) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r No pet food found in bags", 1, 0.5, 0)
        return
    end
    
    -- Clear existing buttons
    if foodMenuFrame.buttons then
        for _, btn in ipairs(foodMenuFrame.buttons) do
            btn:Hide()
        end
    end
    foodMenuFrame.buttons = {}
    
    -- Position menu next to food icon
    foodMenuFrame:ClearAllPoints()
    if foodIconButton then
        foodMenuFrame:SetPoint("LEFT", foodIconButton, "RIGHT", 5, 0)
    else
        foodMenuFrame:SetPoint("CENTER", UIParent, "CENTER")
    end
    
    local yOffset = -5
    for i, food in ipairs(foodList) do
        local btn = CreateFrame("Button", nil, foodMenuFrame)
        btn:SetWidth(150)
        btn:SetHeight(24)
        btn:SetPoint("TOPLEFT", 5, yOffset)
        
        btn.icon = btn:CreateTexture(nil, "BACKGROUND")
        btn.icon:SetWidth(20)
        btn.icon:SetHeight(20)
        btn.icon:SetTexture(food.texture)
        btn.icon:SetPoint("LEFT", 2, 0)
        
        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.text:SetPoint("LEFT", 26, 0)
        btn.text:SetText(food.name .. " (" .. food.count .. ")")
        btn.text:SetTextColor(1, 1, 1)
        
        -- Store food reference on button to avoid closure issues
        btn.foodData = food
        btn:SetScript("OnClick", function()
            if HasPet() then
                local petName = UnitName("pet")
                local foodData = {
                    bag = this.foodData.bag,
                    slot = this.foodData.slot,
                    name = this.foodData.name,
                    texture = this.foodData.texture,
                    count = this.foodData.count,
                    itemID = this.foodData.itemID
                }
                selectedFood = foodData
                HamingwaysHunterToolsDB.selectedFood = HamingwaysHunterToolsDB.selectedFood or {}
                HamingwaysHunterToolsDB.selectedFood[petName] = foodData
                UpdatePetFeederDisplay()
                foodMenuFrame:Hide()
            end
        end)
        
        btn:SetScript("OnEnter", function()
            btn.text:SetTextColor(1, 1, 0)
        end)
        
        btn:SetScript("OnLeave", function()
            btn.text:SetTextColor(1, 1, 1)
        end)
        
        table.insert(foodMenuFrame.buttons, btn)
        yOffset = yOffset - 24
    end
    
    -- Set frame height dynamically based on number of items
    local menuHeight = table.getn(foodList) * 24 + 10
    foodMenuFrame:SetHeight(menuHeight)
    foodMenuFrame:Show()
end

-- ============ Ammo Frame Functions ============
local function FindAmmoInBags()
    local ammoList = {}
    local ammoCounts = {}  -- Track unique ammo types
    
    -- Scan all bags (0-4) - ItemID-based, NO tooltip scans!
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local texture, count = GetContainerItemInfo(bag, slot)
                if texture and count then
                    -- Get ItemID directly - no tooltip needed!
                    local itemLink = GetContainerItemLink(bag, slot)
                    if itemLink then
                        local _, _, itemID = string.find(itemLink, "item:(%d+)")
                        itemID = tonumber(itemID)
                        
                        -- Check if this is ammo (instant lookup!)
                        if itemID and AMMO_LOOKUP[itemID] then
                            local itemName = GetItemInfo(itemID)
                            
                            if itemName then
                                -- Check if this ammo already counted
                                if ammoCounts[itemName] then
                                    ammoCounts[itemName].count = ammoCounts[itemName].count + count
                                else
                                    ammoCounts[itemName] = {
                                        bag = bag,
                                        slot = slot,
                                        name = itemName,
                                        texture = texture,
                                        count = count,
                                        itemID = itemID
                                    }
                                    table.insert(ammoList, ammoCounts[itemName])
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
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
        ammoMenuFrame:SetBackdrop(CreateBackdrop(cfg.borderSize))
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
    statsFrame:SetFrameStrata("MEDIUM")
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
    MakeDraggable(statsFrame, "stats")
    
    -- Right-click context menu
    statsFrame:SetScript("OnMouseDown", function()
        if arg1 == "RightButton" then
            ShowStatsContextMenu()
        end
    end)
    
    -- Tooltip
    statsFrame:SetScript("OnEnter", function()
        ShowTooltip(this, "Reaction Time", {
            {text = "Shows the delay between", r = 0.8, g = 0.8, b = 0.8},
            {text = "Auto-Shot and Cast-Start", r = 0.8, g = 0.8, b = 0.8},
            " ",
            {text = "Right-click for options", r = 0.6, g = 0.6, b = 0.6}
        }, "ANCHOR_RIGHT")
    end)
    statsFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Update throttle (pfUI-style)
    statsFrame:SetScript("OnUpdate", function()
        -- PERFORMANCE: Early exit if frame hidden or feature disabled
        if not this:IsShown() or not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showStats then
            return
        end
        
        -- pfUI pattern: more efficient throttling
        if (this.tick or 1) > GetTime() then return else this.tick = GetTime() + 0.2 end
        UpdateStatsDisplay()
    end)
    
    return statsFrame
end

local function CreateAmmoFrame()
    local cfg = GetConfig()
    local iconSize = cfg.ammoIconSize or DEFAULT_AMMO_ICON_SIZE
    
    ammoFrame = CreateFrame("Button", "HamingwaysHunterToolsAmmoFrame", UIParent)
    ammoFrame:SetWidth(iconSize)
    ammoFrame:SetHeight(iconSize + 20)  -- Extra height for text
    ammoFrame:SetFrameStrata("MEDIUM")
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
    
    MakeDraggable(ammoFrame, "ammo")
    
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
        -- PERFORMANCE: Early exit if frame hidden or feature disabled
        if not this:IsShown() or not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showAmmo then
            return
        end
        
        -- pfUI pattern: more efficient throttling
        if (this.tick or 1) > GetTime() then return else this.tick = GetTime() + 0.5 end
        UpdateAmmoDisplay()
        
        -- Handle blinking when ammo is low (red) - blink the icon
        if this.blinkTimer then
            local elapsed = arg1 or 0
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
    configFrame:SetHeight(650)
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
    
    -- Create tabs (split into 2 rows)
    local tabNames = {"AutoShot", "Castbar", "Buffs", "Munition", "Statistik", "Pet Feeder", "Melee"}
    local tabWidthRow1 = (320 - 32) / 4  -- First 4 tabs
    local tabWidthRow2 = (320 - 32) / 3  -- Last 3 tabs
    
    for i, name in ipairs(tabNames) do
        local tabIndex = i  -- Create local copy for closure
        local tab = CreateFrame("Button", nil, configFrame)
        
        -- Position tabs in 2 rows inside frame, below title
        if i <= 4 then
            -- First row (tabs 1-4)
            tab:SetWidth(tabWidthRow1)
            tab:SetHeight(24)
            tab:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 16 + (i - 1) * tabWidthRow1, -40)
        else
            -- Second row (tabs 5-7)
            tab:SetWidth(tabWidthRow2)
            tab:SetHeight(24)
            tab:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 16 + (i - 5) * tabWidthRow2, -64)
        end
        
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
        
        tab:Hide()  -- Hide initially
        tabs[i] = tab
        
        -- Create content frame for this tab
        local content = CreateFrame("Frame", nil, configFrame)
        content:SetPoint("TOPLEFT", 16, -95)  -- Below title (15) + 2 rows of tabs (24*2) + spacing (8)
        content:SetWidth(288)
        content:SetHeight(500)
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
    
    -- AutoShot Timer Title
    local autoShotTitle = tab1:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    autoShotTitle:SetPoint("TOP", 0, -10)
    autoShotTitle:SetText("AutoShot Timer Settings")
    
    -- Show AutoShot Timer Checkbox (first option)
    local showAutoShotCheck = CreateCheckbox("HamingwaysHunterToolsShowAutoShotCheck", tab1, "Show AutoShot Timer", -40)
    showAutoShotCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showAutoShotTimer = this:GetChecked() and true or false
        UpdateFrameVisibility()
    end)
    
    -- Lock Checkbox
    local lockCheck = CreateCheckbox("HamingwaysHunterToolsLockCheck", tab1, "Lock frames", -70)
    lockCheck:SetScript("OnClick", function()
        local locked = this:GetChecked() and true or false
        HamingwaysHunterToolsDB.locked = locked
        InvalidateConfigCache()
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
    local combatCheck = CreateCheckbox("HamingwaysHunterToolsCombatCheck", tab1, "Show only in combat", -100)
    combatCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showOnlyInCombat = this:GetChecked() and true or false
        UpdateFrameVisibility()
    end)
    
    -- Show Timer Text Checkbox
    local timerCheck = CreateCheckbox("HamingwaysHunterToolsTimerCheck", tab1, "Show timer text", -130)
    timerCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showTimerText = this:GetChecked() and true or false
        -- Immediately update preview if config is open
        if previewMode then
            HideConfigPreview()
            ShowConfigPreview()
        end
    end)
    
    -- Frame Width Slider
    local widthSlider = CreateSlider("HamingwaysHunterToolsWidthSlider", tab1, "Width", -175, 100, 400, 10, function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.frameWidth = val
        getglobal(this:GetName().."Text"):SetText("Width: "..val)
        ApplyFrameSettings()
    end)
    
    -- Frame Height Slider
    local heightSlider = CreateSlider("HamingwaysHunterToolsHeightSlider", tab1, "Höhe", -220, 10, 40, 2, function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.frameHeight = val
        getglobal(this:GetName().."Text"):SetText("Height: "..val)
        ApplyFrameSettings()
    end)
    
    -- Border Size Slider
    local borderSlider = CreateSlider("HamingwaysHunterToolsBorderSlider", tab1, "Border", -265, 0, 20, 2, function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.borderSize = val
        getglobal(this:GetName().."Text"):SetText("Border: "..val)
        ApplyFrameSettings()
    end)
    
    -- Color buttons for Tab 1
    local reloadColorBtn = CreateColorButton("HamingwaysHunterToolsReloadColor", "Reload:", -310, "reloadColor", tab1)
    local aimingColorBtn = CreateColorButton("HamingwaysHunterToolsAimingColor", "Aiming:", -340, "aimingColor", tab1)
    local bgColorBtn1 = CreateColorButton("HamingwaysHunterToolsBgColor1", "Hintergrund:", -370, "bgColor", tab1)
    
    -- Background Opacity for Tab 1
    local opacitySlider = CreateSlider("HamingwaysHunterToolsOpacitySlider", tab1, "BG Opacity", -415, 0, 1, 0.1, function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.bgOpacity = val
        getglobal(this:GetName().."Text"):SetText(string.format("BG Opacity: %.1f", val))
        ApplyFrameSettings()
    end)
    
    -- Auto-Switch Melee/Ranged based on range
    local autoSwitchMeleeCheck = CreateCheckbox("HamingwaysHunterToolsAutoSwitchCheck", tab1, "Auto-switch to Melee Timer at melee range", -460)
    autoSwitchMeleeCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.autoSwitchMeleeRanged = this:GetChecked() and true or false
        InvalidateConfigCache()
    end)
    
    -- Tab 2: Castbar settings
    local tab2 = tabContents[2]
    
    -- Castbar Title
    local castbarTitle = tab2:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    castbarTitle:SetPoint("TOP", 0, -10)
    castbarTitle:SetText("Castbar Settings")
    
    -- Show Castbar Checkbox
    local showCastbarCheck = CreateCheckbox("HamingwaysHunterToolsShowCastbarCheck", tab2, "Show Castbar", -40)
    showCastbarCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showCastbar = this:GetChecked() and true or false
        if not HamingwaysHunterToolsDB.showCastbar and castFrame then
            castFrame:Hide()
        end
    end)
    
    -- Castbar Spacing Slider
    local spacingSlider = CreateFrame("Slider", "HamingwaysHunterToolsSpacingSlider", tab2, "OptionsSliderTemplate")
    spacingSlider:SetPoint("TOPLEFT", 10, -85)
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
    
    local castColorBtn = CreateColorButton("HamingwaysHunterToolsCastColor", "Cast Farbe:", -135, "castColor", tab2)
    
    -- Tab 3: Buff bar settings
    local tab3 = tabContents[3]
    
    -- Buffs Title
    local buffsTitle = tab3:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    buffsTitle:SetPoint("TOP", 0, -10)
    buffsTitle:SetText("Buff Bar Settings")
    
    -- Show BuffBar Checkbox
    local showBuffBarCheck = CreateCheckbox("HamingwaysHunterToolsShowBuffBarCheck", tab3, "Show BuffBar", -40)
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
    iconSizeSlider:SetPoint("TOPLEFT", 10, -85)
    iconSizeSlider:SetMinMaxValues(16, 48)
    iconSizeSlider:SetValueStep(2)
    iconSizeSlider:SetWidth(250)
    getglobal(iconSizeSlider:GetName().."Low"):SetText("16")
    getglobal(iconSizeSlider:GetName().."High"):SetText("48")
    getglobal(iconSizeSlider:GetName().."Text"):SetText("Icon Size")
    iconSizeSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.iconSize = val
        getglobal(this:GetName().."Text"):SetText("Icon Size: "..val)
        ApplyIconSize(val)
    end)
    
    -- Tab 4: Ammunition settings
    local tab4 = tabContents[4]
    
    -- Munition Title
    local munitionTitle = tab4:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    munitionTitle:SetPoint("TOP", 0, -10)
    munitionTitle:SetText("Ammunition Settings")
    
    -- Show Ammo Checkbox
    local showAmmoCheck = CreateCheckbox("HamingwaysHunterToolsShowAmmoCheck", tab4, "Show ammunition", -40)
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
    ammoIconSizeSlider:SetPoint("TOPLEFT", 10, -85)
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
    
    -- Statistics Title
    local statisticsTitle = tab5:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    statisticsTitle:SetPoint("TOP", 0, -10)
    statisticsTitle:SetText("Statistics Settings")
    
    -- Show Stats Checkbox
    local showStatsCheck = CreateCheckbox("HamingwaysHunterToolsShowStatsCheck", tab5, "Show statistics", -40)
    showStatsCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showStats = this:GetChecked() and true or false
        UpdateStatsDisplay()
    end)
    
    -- Auto Reset Stats Checkbox
    local autoResetStatsCheck = CreateCheckbox("HamingwaysHunterToolsAutoResetStatsCheck", tab5, "Auto reset stats", -70)
    autoResetStatsCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.autoResetStats = this:GetChecked() and true or false
    end)
    
    -- Stats Font Size Slider
    local statsFontSlider = CreateFrame("Slider", "HamingwaysHunterToolsStatsFontSlider", tab5, "OptionsSliderTemplate")
    statsFontSlider:SetPoint("TOPLEFT", 10, -115)
    statsFontSlider:SetMinMaxValues(8, 16)
    statsFontSlider:SetValueStep(1)
    statsFontSlider:SetWidth(250)
    getglobal(statsFontSlider:GetName().."Low"):SetText("8")
    getglobal(statsFontSlider:GetName().."High"):SetText("16")
    getglobal(statsFontSlider:GetName().."Text"):SetText("Font Size")
    statsFontSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.statsFontSize = val
        getglobal(this:GetName().."Text"):SetText("Font Size: "..val)
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
    resetStatsBtn:SetPoint("TOPLEFT", 20, -240)
    resetStatsBtn:SetText("Reset Stats")
    resetStatsBtn:SetScript("OnClick", function()
        ResetStats()
    end)
    
    -- Info text
    local statsInfo = tab5:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsInfo:SetPoint("TOPLEFT", 10, -170)
    statsInfo:SetWidth(270)
    statsInfo:SetJustifyH("LEFT")
    statsInfo:SetText("Measures the reaction time between Auto-Shot and Cast-Start (Aimed Shot, Multi-Shot, etc.). Right-click to reset.")
    statsInfo:SetTextColor(1, 0.82, 0, 1)
    
    -- ========== Tab 6: Pet Feeder ==========
    local tab6 = tabContents[6]
    
    -- Pet Feeder Title
    local petFeederTitle = tab6:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    petFeederTitle:SetPoint("TOP", 0, -10)
    petFeederTitle:SetText("Pet Feeder Settings")
    
    -- Show Pet Feeder
    local showPetFeederCheck = CreateCheckbox("HamingwaysHunterToolsShowPetFeederCheck", tab6, "Show Pet Feeder", -40)
    showPetFeederCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.showPetFeeder = this:GetChecked() and true or false
        UpdateFrameVisibility()
        if HamingwaysHunterToolsDB.showPetFeeder then
            UpdatePetFeederDisplay()
        end
    end)
    
    -- Auto Feed Pet
    local autoFeedCheck = CreateCheckbox("HamingwaysHunterToolsAutoFeedCheck", tab6, "Auto feed pet when unhappy", -70)
    autoFeedCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.autoFeedPet = this:GetChecked() and true or false
    end)
    
    -- Feed on Click
    local feedOnClickCheck = CreateCheckbox("HamingwaysHunterToolsFeedOnClickCheck", tab6, "Feed on left-click food icon", -100)
    feedOnClickCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.feedOnClick = this:GetChecked() and true or false
    end)
    
    -- Pet Feeder Icon Size Slider
    local petFeederIconSlider = CreateFrame("Slider", "HamingwaysHunterToolsPetFeederIconSlider", tab6, "OptionsSliderTemplate")
    petFeederIconSlider:SetPoint("TOPLEFT", 10, -145)
    petFeederIconSlider:SetMinMaxValues(24, 64)
    petFeederIconSlider:SetValueStep(2)
    petFeederIconSlider:SetWidth(250)
    getglobal(petFeederIconSlider:GetName().."Low"):SetText("24")
    getglobal(petFeederIconSlider:GetName().."High"):SetText("64")
    getglobal(petFeederIconSlider:GetName().."Text"):SetText("Icon Size")
    petFeederIconSlider:SetScript("OnValueChanged", function()
        local val = this:GetValue()
        HamingwaysHunterToolsDB.petFeederIconSize = val
        getglobal(this:GetName().."Text"):SetText("Icon Size: "..val)
        ApplyFrameSettings()
    end)
    
    -- Info Text
    local petFeederInfo = tab6:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    petFeederInfo:SetPoint("TOPLEFT", 20, -200)
    petFeederInfo:SetWidth(270)
    petFeederInfo:SetJustifyH("LEFT")
    petFeederInfo:SetText("The Pet Feeder shows your pet portrait and selected food. Background color indicates pet happiness:\n\n|cff00ff00Green|r = Happy\n|cffffff00Yellow|r = Content\n|cffff0000Red|r = Unhappy\n\nLeft-click food icon to feed, right-click to select food. Food your pet rejects is automatically blacklisted.")
    
    -- Reset Blacklist Button
    local resetBlacklistBtn = CreateFrame("Button", nil, tab6, "UIPanelButtonTemplate")
    resetBlacklistBtn:SetWidth(200)
    resetBlacklistBtn:SetHeight(24)
    resetBlacklistBtn:SetPoint("TOPLEFT", 20, -340)
    resetBlacklistBtn:SetText("Reset Blacklisted Food")
    resetBlacklistBtn:SetScript("OnClick", function()
        if HasPet() then
            local petName = UnitName("pet")
            if HamingwaysHunterToolsDB.petFoodBlacklist and HamingwaysHunterToolsDB.petFoodBlacklist[petName] then
                HamingwaysHunterToolsDB.petFoodBlacklist[petName] = {}
                DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r Blacklist cleared for " .. petName, 0.67, 0.83, 0.45)
                UpdatePetFeederDisplay()
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r No blacklisted food for " .. petName, 1, 1, 0)
            end
        end
    end)
    
    -- Store button reference for visibility updates
    tab6.resetBlacklistBtn = resetBlacklistBtn
    
    -- ========== Tab 7: Melee Timer ==========
    local tab7 = tabContents[7]
    
    -- Melee Timer Title
    local meleeTitle = tab7:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    meleeTitle:SetPoint("TOP", 0, -10)
    meleeTitle:SetText("Melee Swing Timer")
    
    -- Use Instead of AutoShot
    local meleeInsteadCheck = CreateCheckbox("HamingwaysHunterToolsMeleeInsteadCheck", tab7, "Use instead of AutoShot timer", -40)
    meleeInsteadCheck:SetScript("OnClick", function()
        HamingwaysHunterToolsDB.meleeTimerInsteadOfAutoShot = this:GetChecked() and true or false
        InvalidateConfigCache()
    end)
    
    -- Melee Bar Color
    local meleeColorBtn = CreateColorButton("HamingwaysHunterToolsMeleeColor", "Melee Farbe:", -80, "meleeColor", tab7)
    
    -- Info Text
    local meleeInfo = tab7:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    meleeInfo:SetPoint("TOPLEFT", 20, -125)
    meleeInfo:SetWidth(270)
    meleeInfo:SetJustifyH("LEFT")
    meleeInfo:SetText("The Melee Swing Timer tracks your melee attacks (detected via combat log).\n\n|cffFFFFFFOptions:|r\n\n|cff00ff00Instead of AutoShot|r - Always shows melee, never ranged\n\n|cff00ff00Auto-switch|r - (Tab 1) Switches between melee/ranged based on target distance\n\n|cffFFFF00Note:|r Melee timer visibility and combat behavior are bound to AutoShot Timer settings. Works best with consistent melee attacks.")
    
    -- Close Button
    local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    closeBtn:SetWidth(80)
    closeBtn:SetHeight(22)
    closeBtn:SetPoint("BOTTOM", 0, 15)
    closeBtn:SetText("Close")
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
    configFrame.autoResetStatsCheck = autoResetStatsCheck
    configFrame.opacitySlider = opacitySlider
    configFrame.reloadColorBtn = reloadColorBtn
    configFrame.aimingColorBtn = aimingColorBtn
    configFrame.castColorBtn = castColorBtn
    configFrame.bgColorBtn = bgColorBtn1
    configFrame.showPetFeederCheck = showPetFeederCheck
    configFrame.autoFeedCheck = autoFeedCheck
    configFrame.feedOnClickCheck = feedOnClickCheck
    configFrame.petFeederIconSlider = petFeederIconSlider
    configFrame.autoSwitchMeleeCheck = autoSwitchMeleeCheck
    configFrame.meleeInsteadCheck = meleeInsteadCheck
    configFrame.meleeColorBtn = meleeColorBtn
    
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
        this.autoResetStatsCheck:SetChecked(cfg.autoResetStats)
        this.showAmmoCheck:SetChecked(cfg.showAmmo)
        this.opacitySlider:SetValue(cfg.bgOpacity)
        this.reloadColorBtn.colorSwatch:SetVertexColor(cfg.reloadColor.r, cfg.reloadColor.g, cfg.reloadColor.b)
        this.aimingColorBtn.colorSwatch:SetVertexColor(cfg.aimingColor.r, cfg.aimingColor.g, cfg.aimingColor.b)
        this.castColorBtn.colorSwatch:SetVertexColor(cfg.castColor.r, cfg.castColor.g, cfg.castColor.b)
        this.bgColorBtn.colorSwatch:SetVertexColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b)
        this.showPetFeederCheck:SetChecked(cfg.showPetFeeder)
        this.autoFeedCheck:SetChecked(cfg.autoFeedPet)
        this.feedOnClickCheck:SetChecked(cfg.feedOnClick)
        this.petFeederIconSlider:SetValue(cfg.petFeederIconSize or DEFAULT_PET_FEEDER_ICON_SIZE)
        this.autoSwitchMeleeCheck:SetChecked(cfg.autoSwitchMeleeRanged)
        this.meleeInsteadCheck:SetChecked(cfg.meleeTimerInsteadOfAutoShot)
        this.meleeColorBtn.colorSwatch:SetVertexColor(cfg.meleeColor.r, cfg.meleeColor.g, cfg.meleeColor.b)
        for i, tab in ipairs(tabs) do
            tab:Show()
        end
        
        -- Update reset blacklist button visibility
        if tabContents[6] and tabContents[6].resetBlacklistBtn then
            if HasPet() then
                tabContents[6].resetBlacklistBtn:Show()
            else
                tabContents[6].resetBlacklistBtn:Hide()
            end
        end
        
        ShowConfigPreview()
    end)
    
    configFrame:SetScript("OnHide", function()
        for i, tab in ipairs(tabs) do
            tab:Hide()
        end
        HideConfigPreview()
        InvalidateConfigCache()  -- Invalidate cache when config UI closes
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

local function CreateMinimapButton()
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
end

local function SetupMainFrameUpdate(frame)
    frame:SetScript("OnUpdate", function()
        -- PERFORMANCE: Single GetTime() call per frame (cached)
        local now = GetTime()
        
        -- PERFORMANCE: Cache DB reference once per frame
        local db = HamingwaysHunterToolsDB
        if not db then return end
        
        -- CRITICAL EARLY EXIT: Both timers completely disabled
        if not db.showAutoShotTimer and not (db.showMeleeTimer and useMeleeTimer) then
            if frame:GetAlpha() > 0 then frame:SetAlpha(0) end
            return
        end
        
        -- EARLY EXIT: Not shooting/reloading/casting and frames are locked
        if not isShooting and not isReloading and not isCasting then
            local showOnlyInCombat = db.showOnlyInCombat
            local inCombat = UnitAffectingCombat("player")
            if showOnlyInCombat and not inCombat and not previewMode then
                if frame:GetAlpha() > 0 then frame:SetAlpha(0) end
                return
            end
        end
        
        -- PERFORMANCE: Update castbar if needed (early exit if disabled)
        if isCasting and not previewMode then
            if db.showCastbar then
                UpdateCastbar()
            end
        end
        
        -- PERFORMANCE: Throttled operations (only run when needed)
        if now - lastTimerModeCheck >= TIMER_MODE_INTERVAL then
            lastTimerModeCheck = now
            UpdateTimerMode()
        end
        
        -- Cache range check (expensive operation)
        local isAutoShotEnabled = (not db.showOnlyInCombat or UnitAffectingCombat("player") or isShooting or isCasting or previewMode)
        if isAutoShotEnabled and now - lastRangeCheck >= RANGE_CHECK_INTERVAL then
            lastRangeCheck = now
            cachedRangeText, cachedIsDeadZone = GetTargetRange()
        end
        
        -- Melee Timer Mode (bound to AutoShot visibility and combat settings)
        if db.showAutoShotTimer and useMeleeTimer then
            if db.showOnlyInCombat and not UnitAffectingCombat("player") then
                -- Hide in non-combat (bound to AutoShot combat setting)
                if barFrame then
                    barFrame:SetWidth(1)
                    barFrame:SetBackdropColor(0.3, 0.3, 0.3, 0.5)
                    barTextTotal:SetText("")
                    if frame then frame:SetAlpha(0) end  -- Quiver-style: Alpha instead of Hide
                end
            elseif not isMeleeSwinging then
                -- Not swinging - show idle state
                if barFrame and barTextTotal and barTextRange then
                    barFrame:SetWidth(1)
                    barFrame:SetBackdropColor(0.3, 0.3, 0.3, 0.5)
                    -- Hide left text
                    if barText then
                        barText:SetText("")
                    end
                    -- Show only seconds on right
                    if db.showTimerText and now - textCache.lastUpdate >= textCache.interval then
                        local newText = string.format("%.2fs", meleeSwingSpeed)
                        if newText ~= textCache.barTextTotal then
                            barTextTotal:SetText(newText)
                            textCache.barTextTotal = newText
                        end
                    elseif textCache.barTextTotal ~= "" then
                        barTextTotal:SetText("")
                        textCache.barTextTotal = ""
                    end
                    -- Update range display (center) - use cached value
                    if barTextRange then
                        if cachedRangeText ~= textCache.barTextRange then
                            barTextRange:SetText(cachedRangeText or "")
                            textCache.barTextRange = cachedRangeText
                        end
                        -- Blink in Dead Zone
                        if cachedIsDeadZone then
                            local blink = math.mod(math.floor(now * 3), 2) == 0
                            if blink ~= textCache.lastBlink then
                                barTextRange:SetAlpha(blink and 1 or 0.3)
                                textCache.lastBlink = blink
                            end
                        else
                            barTextRange:SetAlpha(1)
                            textCache.lastBlink = false
                        end
                    end
                end
            else
                if frame then frame:SetAlpha(1) end  -- Ensure visible
                UpdateBarMelee(now)
            end
        -- Ranged Timer Mode
        elseif not isShooting then
            if barFrame and barTextTotal then
                barFrame:SetWidth(1)
                barFrame:SetBackdropColor(0.3, 0.3, 0.3, 0.5)
                -- PERFORMANCE: Throttle text updates
                if now - textCache.lastUpdate >= textCache.interval then
                    textCache.lastUpdate = now
                    if db.showTimerText then
                        local newText = string.format("%.2fs", weaponSpeed)
                        if newText ~= textCache.barTextTotal then
                            barTextTotal:SetText(newText)
                            textCache.barTextTotal = newText
                        end
                    else
                        if textCache.barTextTotal ~= "" then
                            barTextTotal:SetText("")
                            textCache.barTextTotal = ""
                        end
                    end
                end
                -- Update range display (center) - use cached value
                if barTextRange then
                    if cachedRangeText ~= textCache.barTextRange then
                        barTextRange:SetText(cachedRangeText or "")
                        textCache.barTextRange = cachedRangeText
                    end
                    -- Blink in Dead Zone
                    if cachedIsDeadZone then
                        local blink = math.mod(math.floor(now * 3), 2) == 0
                        if blink ~= textCache.lastBlink then
                            barTextRange:SetAlpha(blink and 1 or 0.3)
                            textCache.lastBlink = blink
                        end
                    else
                        barTextRange:SetAlpha(1)
                        textCache.lastBlink = false
                    end
                end
            end
        elseif isReloading then
            if frame then frame:SetAlpha(1) end
            UpdateBarReload(now)
        else
            -- Shoot phase (yellow bar) - isShooting=true but isReloading=false
            if frame then frame:SetAlpha(1) end
            -- Yellow bar (aiming): reset on movement OR during cast
            if not position.CheckStandingStill() or isCasting then
                timeShoot.Start()  -- Reset yellow bar to 0%
            end
            UpdateBarShoot(now)
        end
    end)
end

local function CreateCastbarFrame()
    castFrame = CreateFrame("Frame", "HamingwaysHunterToolsCastFrame", UIParent)
    castFrame:SetWidth(240)
    castFrame:SetHeight(14)
    castFrame:SetFrameStrata("MEDIUM")
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
    castBarFrame:SetBackdropColor(0.5, 0.5, 1, BAR_ALPHA)
    
    castBarText = castFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    castBarText:SetPoint("CENTER", castFrame, "CENTER", 0, 0)
    castBarText:SetTextColor(1, 1, 1, 1)
    castBarText:SetText("")
    
    castBarTextTime = castFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    castBarTextTime:SetPoint("LEFT", castFrame, "RIGHT", 5, 0)
    castBarTextTime:SetTextColor(1, 1, 1, 1)
    castBarTextTime:SetText("")
end

local function CreateHasteFrame(mainFrame)
    hasteFrame = CreateFrame("Frame", "HamingwaysHunterToolsHasteFrame", UIParent)
    hasteFrame:SetWidth(240)
    hasteFrame:SetHeight(28)
    hasteFrame:SetFrameStrata("MEDIUM")
    hasteFrame:SetPoint("TOP", mainFrame, "BOTTOM", 0, -2)
    hasteFrame:Hide()
    
    -- PERFORMANCE: Throttled OnUpdate (0.5s) instead of PLAYER_AURAS_CHANGED event (raid optimized)
    -- PLAYER_AURAS_CHANGED fires 15-30x/sec (every buff tick) - replaced with 2x/sec polling
    hasteFrame:SetScript("OnUpdate", function()
        if (this.tick or 0) > GetTime() then return else this.tick = GetTime() + 0.5 end
        
        -- Only update buffs if bar is enabled
        if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showBuffBar then return end
        if not UnitAffectingCombat("player") and not isShooting then return end
        
        UpdateHasteBuffs()
        UpdateBuffCountdowns()
    end)
end

local function CreatePetFeederFrame()
    local cfg = GetConfig()
    local iconSize = cfg.petFeederIconSize or DEFAULT_PET_FEEDER_ICON_SIZE
    local frameWidth = iconSize * 2 + 9
    local frameHeight = iconSize + 4
    
    petFeedFrame = CreateFrame("Frame", "HamingwaysHunterToolsPetFeederFrame", UIParent)
    petFeedFrame:SetWidth(frameWidth)
    petFeedFrame:SetHeight(frameHeight)
    petFeedFrame:SetFrameStrata("MEDIUM")
    petFeedFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    
    -- Use config settings for backdrop
    if cfg.borderSize > 0 then
        petFeedFrame:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, 
            edgeSize = cfg.borderSize,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
    else
        petFeedFrame:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = nil,
            tile = false,
            edgeSize = 0,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
    end
    
    petFeedFrame:SetBackdropColor(0, 0.6, 0, cfg.bgOpacity)
    petFeedFrame:SetBackdropBorderColor(0.67, 0.83, 0.45, cfg.borderOpacity or 1)
    petFeedFrame:EnableMouse(true)
    petFeedFrame:SetMovable(true)
    petFeedFrame:RegisterForDrag("LeftButton")
    
    -- Pet Icon Button
    petIconButton = CreateFrame("Button", nil, petFeedFrame)
    petIconButton:SetWidth(iconSize)
    petIconButton:SetHeight(iconSize)
    petIconButton:SetPoint("LEFT", petFeedFrame, "LEFT", 2, 0)
    
    petIconButton.icon = petIconButton:CreateTexture(nil, "BACKGROUND")
    petIconButton.icon:SetAllPoints()
    petIconButton.icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastCall")
    petIconButton.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    
    petIconButton:RegisterForClicks("LeftButtonUp")
    
    petIconButton:SetScript("OnClick", function()
        if arg1 ~= "LeftButton" then return end
        
        if UnitExists("pet") and UnitIsDead("pet") then
            -- Pet is dead, revive it
            CastSpellByName("Revive Pet")
        elseif HasPet() then
            -- Pet is active, dismiss it
            CastSpellByName("Dismiss Pet")
        else
            -- No pet active, call pet
            CastSpellByName("Call Pet")
        end
        -- Delay update to allow pet summon to complete
        if not this.updateTimer then
            this.updateTimer = 0
        end
        this.updateTimer = 0.5
        this:SetScript("OnUpdate", function()
            if this.updateTimer and this.updateTimer > 0 then
                this.updateTimer = this.updateTimer - arg1
                if this.updateTimer <= 0 then
                    UpdatePetFeederDisplay()
                    this:SetScript("OnUpdate", nil)
                    this.updateTimer = nil
                end
            end
        end)
    end)
    
    petIconButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if UnitExists("pet") and UnitIsDead("pet") then
            GameTooltip:SetText("Revive Pet", 1, 0.2, 0.2)
            GameTooltip:AddLine("Click to revive your pet", 0.8, 0.8, 0.8)
        elseif HasPet() then
            GameTooltip:SetUnit("pet")
            GameTooltip:AddLine(" ", 1, 1, 1)
            GameTooltip:AddLine("Left click: Dismiss pet", 0.8, 0.8, 0.8)
        else
            GameTooltip:SetText("Call Pet", 1, 1, 1)
            GameTooltip:AddLine("Click to call your pet", 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)
    
    petIconButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Food Icon Button
    foodIconButton = CreateFrame("Button", nil, petFeedFrame)
    foodIconButton:SetWidth(iconSize)
    foodIconButton:SetHeight(iconSize)
    foodIconButton:SetPoint("LEFT", petIconButton, "RIGHT", 5, 0)
    
    foodIconButton.icon = foodIconButton:CreateTexture(nil, "BACKGROUND")
    foodIconButton.icon:SetAllPoints()
    foodIconButton.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    foodIconButton.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    
    foodIconButton.countText = foodIconButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    foodIconButton.countText:SetPoint("BOTTOMRIGHT", -2, 2)
    foodIconButton.countText:SetTextColor(1, 1, 1, 1)
    
    foodIconButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    foodIconButton:SetScript("OnClick", function()
        local cfg = GetConfig()
        if arg1 == "LeftButton" then
            if cfg.feedOnClick then
                -- Left click: Feed pet with selected food (if enabled)
                FeedPet()
            end
        elseif arg1 == "RightButton" then
            -- Right click: Show food menu
            ShowFoodMenu()
        end
    end)
    
    foodIconButton:SetScript("OnEnter", function()
        local cfg = GetCachedConfig()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Pet Food", 1, 1, 1)
        if cfg.feedOnClick then
            GameTooltip:AddLine("Left click: Feed pet", 0.8, 0.8, 0.8)
        end
        GameTooltip:AddLine("Right click: Select food", 0.8, 0.8, 0.8)
        if selectedFood then
            GameTooltip:AddLine(" ", 1, 1, 1)
            GameTooltip:AddLine("Current: " .. selectedFood.name, 0.67, 0.83, 0.45)
        end
        GameTooltip:Show()
    end)
    
    foodIconButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Track last auto-feed attempt time (to prevent spam)
    petFeedFrame.lastAutoFeedAttempt = 0
    
    -- Food Menu Frame
    foodMenuFrame = CreateFrame("Frame", "HamingwaysHunterToolsPetFoodMenu", UIParent)
    foodMenuFrame:SetFrameStrata("DIALOG")
    
    foodMenuFrame:SetBackdrop(CreateBackdrop(cfg.borderSize))
    
    foodMenuFrame:SetBackdropColor(cfg.bgColor.r, cfg.bgColor.g, cfg.bgColor.b, cfg.bgOpacity)
    foodMenuFrame:SetBackdropBorderColor(1, 1, 1, cfg.borderOpacity or 1)
    foodMenuFrame:EnableMouse(true)
    foodMenuFrame:SetWidth(160)
    foodMenuFrame:SetHeight(100)
    foodMenuFrame:Hide()
    
    -- Dragging for Pet Feeder Frame
    MakeDraggable(petFeedFrame, "petFeed")
end

local function CreateMainFrame()
    frame = CreateFrame("Frame", "HamingwaysHunterToolsFrame", UIParent)
    frame:SetWidth(240)
    frame:SetHeight(14)
    frame:SetFrameStrata("MEDIUM")
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
    
    barTextRange = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    barTextRange:SetPoint("CENTER", frame, "CENTER", 0, 0)
    barTextRange:SetTextColor(1, 1, 1, 1)
    barTextRange:SetText("")
    
    barTextRange = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    barTextRange:SetPoint("CENTER", frame, "CENTER", 0, 0)
    barTextRange:SetTextColor(1, 1, 1, 1)
    barTextRange:SetText("")
    
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetMovable(true)
    
    MakeDraggable(frame, "")
    
    SetupMainFrameUpdate(frame)
    maxBarWidth = frame:GetWidth() - 4
    
    return frame
end

local function CreateUI()
    -- Create main AutoShot timer frame
    local mainFrame = CreateMainFrame()
    
    -- Create Minimap Button
    CreateMinimapButton()
    
    -- Create Config Frame
    CreateConfigFrame()
    
    -- Create Castbar
    CreateCastbarFrame()
    
    -- Create Ammo Frame
    CreateAmmoFrame()
    UpdateAmmoDragState()  -- Initialize drag state
    
    -- Create Stats Frame
    CreateStatsFrame()
    UpdateStatsDragState()  -- Initialize drag state
    
    -- Create Pet Feeder Frame
    CreatePetFeederFrame()
    
    -- Create Haste Buff Tracker
    CreateHasteFrame(mainFrame)
    
    return mainFrame
end


-- ============ Shot Detection (Quiver-style) ============
local function OnShotFired()
    -- Ignore if currently casting (Aimed Shot, Multi-Shot, etc.)
    if isCasting then return end
    
    -- Ignore shot detection for 0.3s after cast ends to prevent false red bar
    if GetTime() - lastCastEndTime < 0.3 then return end
    
    -- Track auto-shot time for reaction time statistics
    lastAutoShotTime = GetTime()
    lastAutoFired = lastAutoShotTime
    
    -- Update weapon speed first (in case haste changed)
    UpdateWeaponSpeed()
    
    -- Start reload phase only (shoot phase starts when reload completes)
    timeReload.Start()
    timeShoot.Reset()  -- Reset shoot timer, will start after reload
    
    isReloading = true
    if not isShooting then
        isShooting = true
    end
    
    -- Track that auto-shot occurred between casts (for skipped shot tracking)
    autoShotBetweenCasts = true
end

-- GCD-based instant shot detection (Quiver approach)
local lastGCDStart = 0

local function GetSpellIndexByName(spellName)
    local i = 1
    while true do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then
            break
        end
        if name == spellName then
            return i
        end
        i = i + 1
    end
    return nil
end

local function CheckNewGCD()
    -- Use Serpent Sting as GCD indicator (1.5 sec cooldown)
    local spellIndex = GetSpellIndexByName("Serpent Sting") or GetSpellIndexByName("Schlangenbiss")
    if spellIndex then
        local start, duration = GetSpellCooldown(spellIndex, BOOKTYPE_SPELL)
        -- GCD is ~1.5 seconds, check if new GCD started
        if duration > 0 and duration < 2 and start ~= lastGCDStart then
            lastGCDStart = start
            return true
        end
    end
    return false
end

local function IsInstantShotSpell(spellName)
    return spellName and instantShots[spellName]
end

-- Hook CastSpellByName to detect instant shots via GCD
local originalCastSpellByName = CastSpellByName
CastSpellByName = function(spellName, onSelf)
    originalCastSpellByName(spellName, onSelf)
    -- Only mark as instant shot if GCD was triggered
    if IsInstantShotSpell(spellName) and CheckNewGCD() then
        lastInstantShotTime = GetTime()
        -- Reset yellow bar (like Quiver: instant shots reset auto shot timer)
        if isShooting and timeReload.IsComplete() then
            -- Restart shoot phase from beginning (reset to start of yellow window)
            timeShoot.Start()
            isReloading = false
        end
    end
end

-- Hook UseAction to detect instant shots via GCD
local originalUseAction = UseAction
UseAction = function(slot, checkCursor, onSelf)
    originalUseAction(slot, checkCursor, onSelf)
    -- GCD check will tell us if an instant shot was actually cast
    if CheckNewGCD() then
        lastInstantShotTime = GetTime()
        -- Reset yellow bar (like Quiver: instant shots reset auto shot timer)
        if isShooting and timeReload.IsComplete() then
            -- Restart shoot phase from beginning (reset to start of yellow window)
            timeShoot.Start()
            isReloading = false
        end
    end
end

-- Register only essential events permanently (performance optimized)
AH:RegisterEvent("START_AUTOREPEAT_SPELL")
AH:RegisterEvent("STOP_AUTOREPEAT_SPELL")
AH:RegisterEvent("PLAYER_ENTERING_WORLD")
AH:RegisterEvent("PLAYER_REGEN_ENABLED")
AH:RegisterEvent("PLAYER_REGEN_DISABLED")
AH:RegisterEvent("ADDON_LOADED")
AH:RegisterEvent("PLAYER_LOGOUT")
-- PERFORMANCE: These events registered dynamically only when needed:
-- PLAYER_AURAS_CHANGED: Only during combat/shooting
-- ITEM_LOCK_CHANGED, UNIT_INVENTORY_CHANGED: Only during shooting
-- UI_ERROR_MESSAGE, CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS: Only when buff bar enabled
-- UNIT_HAPPINESS, UNIT_PET, PET_BAR_UPDATE, PLAYER_TARGET_CHANGED: Only when pet feeder enabled
-- Melee timer uses combat state polling (no combat log events needed - raid optimized)

-- ============ Event Handler Functions (split to reduce upvalues) ============
local function HandleAddonLoaded()
    -- Check if player is a Hunter - do this BEFORE anything else
    -- Note: UnitClass might not be ready yet, so we check silently here and show message later
    local _, playerClass = UnitClass("player")
    if playerClass and playerClass ~= "HUNTER" then
        isHunter = false
        -- Don't show message yet - will be shown at PLAYER_ENTERING_WORLD
        return
    end
    isHunter = true
    
    HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
    
    if frame == nil then
        frame = CreateUI()
    end
    local cfg = GetCachedConfig()
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
    if petFeedFrame and HamingwaysHunterToolsDB.petFeedX and HamingwaysHunterToolsDB.petFeedY and HamingwaysHunterToolsDB.petFeedPoint then
        petFeedFrame:ClearAllPoints()
        petFeedFrame:SetPoint(HamingwaysHunterToolsDB.petFeedPoint, UIParent, HamingwaysHunterToolsDB.petFeedPoint, HamingwaysHunterToolsDB.petFeedX, HamingwaysHunterToolsDB.petFeedY)
    end
    ApplyFrameSettings()
    print("HHT: loaded (Quiver-style timer, use /HamingwaysHunterTools test)")
    frame:Show()
    UpdateWeaponSpeed()
    UpdateFrameVisibility()
    if statsFrame then UpdateStatsDisplay() end
    if petFeedFrame then UpdatePetFeederDisplay() end
end

local function HandlePlayerEnteringWorld()
    UpdateWeaponSpeed()
    UpdateAmmoDisplay()
    
    -- Register feature-specific events based on config (performance optimization)
    local cfg = GetCachedConfig()
    if cfg.showBuffBar then
        AH:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")
    end
    if cfg.showPetFeeder and HasPet() then
        AH:RegisterEvent("UI_ERROR_MESSAGE")
        AH:RegisterEvent("UNIT_HAPPINESS")
        AH:RegisterEvent("UNIT_PET")
        AH:RegisterEvent("PET_BAR_UPDATE")
        AH:RegisterEvent("PLAYER_TARGET_CHANGED")
    end
    
    if not loadedMessageShown then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's |r|cFFFFFF00HunterTools |r(" .. VERSION .. ") loaded")
        loadedMessageShown = true
    end
end

local function HandleInventoryChanged()
    UpdateWeaponSpeed()
    UpdateAmmoDisplay()
end

local function HandleAurasChanged()
    if not isShooting then
        UpdateWeaponSpeed()
    end
    
    -- PERFORMANCE: Haste buff updates moved to hasteFrame OnUpdate (0.5s throttle)
    -- No longer called from PLAYER_AURAS_CHANGED event (15-30x/sec → 2x/sec)
    
    -- Update pet feeder when buffs change (keep event-driven for pet happiness)
    if HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showPetFeeder and petFeedFrame and HasPet() then
        UpdatePetFeederDisplay()
    end
end

local function HandleCombatStart()
    if statsNeedReset then
        ResetStats()
        statsNeedReset = false
    end
    -- Register PLAYER_AURAS_CHANGED for haste buff tracking during combat
    AH:RegisterEvent("PLAYER_AURAS_CHANGED")
    UpdateFrameVisibility()
end

local function HandleCombatEnd()
    -- PERFORMANCE: Direct DB access instead of GetCachedConfig()
    if HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.autoResetStats and (table.getn(reactionTimes) > 0 or skippedAutoShots > 0 or table.getn(delayedAutoShotTimes) > 0) then
        statsNeedReset = true
    end
    -- Unregister PLAYER_AURAS_CHANGED if not shooting (performance optimization)
    if not isShooting then
        AH:UnregisterEvent("PLAYER_AURAS_CHANGED")
    end
    UpdateFrameVisibility()
end

local function HandleAutoShotStart()
    isShooting = true
    -- Register performance-critical events only while shooting
    AH:RegisterEvent("PLAYER_AURAS_CHANGED")
    AH:RegisterEvent("ITEM_LOCK_CHANGED")
    AH:RegisterEvent("UNIT_INVENTORY_CHANGED")
    position.UpdateXY()
    UpdateFrameVisibility()
    -- Start shoot timer at fight start (bar will grow from 0)
    if not timeShoot.IsStarted() then
        UpdateWeaponSpeed()
        timeShoot.Start()  -- Start shoot timer from 0
    end
end

local function HandleAutoShotStop()
    isShooting = false
    isReloading = false
    -- Reset closures
    timeReload.Reset()
    timeShoot.Reset()
    -- Unregister performance-critical events when not shooting
    if not UnitAffectingCombat("player") then
        AH:UnregisterEvent("PLAYER_AURAS_CHANGED")
    end
    AH:UnregisterEvent("ITEM_LOCK_CHANGED")
    AH:UnregisterEvent("UNIT_INVENTORY_CHANGED")
    UpdateFrameVisibility()
end

local function HandleLogout()
    HamingwaysHunterToolsDB = HamingwaysHunterToolsDB or {}
    local point, _, _, xOfs, yOfs = frame:GetPoint()
    HamingwaysHunterToolsDB.point = point
    HamingwaysHunterToolsDB.x = xOfs
    HamingwaysHunterToolsDB.y = yOfs
end

local function HandleUIError(errMsg)
    if errMsg and type(errMsg) == "string" and HasPet() then
        -- Check for various pet food rejection messages
        local isFoodRejected = string.find(errMsg, "refuse") or 
                              string.find(errMsg, "doesn't like") or 
                              string.find(errMsg, "does not like") or
                              string.find(errMsg, "will not eat") or
                              string.find(errMsg, "won't eat") or
                              string.find(errMsg, "not high enough") or
                              string.find(errMsg, "too low") or
                              string.find(errMsg, "can't use that") or
                              string.find(errMsg, "cannot use that") or
                              string.find(errMsg, "fail to perform Feed Pet")
        
        if isFoodRejected and lastAttemptedFood and lastAttemptedFood.itemID then
            local petName = UnitName("pet")
            
            -- Verify this error is for the same pet we tried to feed
            if lastAttemptedFood.petName == petName then
                HamingwaysHunterToolsDB.petFoodBlacklist = HamingwaysHunterToolsDB.petFoodBlacklist or {}
                HamingwaysHunterToolsDB.petFoodBlacklist[petName] = HamingwaysHunterToolsDB.petFoodBlacklist[petName] or {}
                
                local alreadyBlacklisted = false
                for i = 1, table.getn(HamingwaysHunterToolsDB.petFoodBlacklist[petName]) do
                    if HamingwaysHunterToolsDB.petFoodBlacklist[petName][i] == lastAttemptedFood.itemID then
                        alreadyBlacklisted = true
                        break
                    end
                end
                
                if not alreadyBlacklisted then
                    table.insert(HamingwaysHunterToolsDB.petFoodBlacklist[petName], lastAttemptedFood.itemID)
                    DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r " .. (lastAttemptedFood.name or "Food") .. " blacklisted for " .. petName .. " (" .. errMsg .. ")", 1, 0.5, 0)
                    
                    -- Clear selected food if it was blacklisted
                    if selectedFood and selectedFood.itemID == lastAttemptedFood.itemID then
                        selectedFood = nil
                        if HamingwaysHunterToolsDB.selectedFood then
                            HamingwaysHunterToolsDB.selectedFood[petName] = nil
                        end
                    end
                    
                    UpdatePetFeederDisplay()
                end
                
                -- Clear the last attempted food after processing
                lastAttemptedFood = nil
            end
        end
    end
    
    if isCasting then
        isCasting = false
        if castFrame then castFrame:Hide() end
    end
end

local function HandleBuffGained(message)
    if message then
        -- Use hasteBuffNames (reverse lookup) instead of hasteBuffs
        for buffName, _ in pairs(hasteBuffNames) do
            if string.find(message, buffName, 1, true) then
                buffTimestamps[buffName] = GetTime()
                break
            end
        end
    end
end

local function HandleItemLockChanged()
    -- Check if this is from an instant shot (which should NOT reset the timer)
    local currentTime = GetTime()
    if currentTime - lastInstantShotTime < 0.5 then
        -- This ITEM_LOCK_CHANGED is from an instant shot, ignore it
        return
    end
    -- This is a real auto shot
    if isShooting then OnShotFired() end
end

local function HandlePetEvents()
    -- PERFORMANCE: Direct DB access, no config table creation
    if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showPetFeeder then
        return
    end
    
    if petFeedFrame and HasPet() then
        UpdatePetFeederDisplay()
    end
end

local function HandlePlayerTargetChanged()
    if not petFeedFrame then return end
    
    -- PERFORMANCE: Direct DB access instead of GetCachedConfig()
    if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.autoFeedPet then
        return
    end
    
    -- WORKAROUND: WoW 1.10+ requires DropItemOnUnit() to be called from a player-initiated event
    -- This is the same approach used by PetFeeder addon (see PetFeederFrame.lua line 629)
    -- Block auto-feed when player is mounted (Turtle WoW)
    if HasPet() and selectedFood and not IsPlayerMounted() then
        local happiness = GetPetHappiness()
        local hasFeedEffect = HasFeedEffect()
        -- Only attempt feed if pet needs it and we haven't tried recently (prevent spam)
        local currentTime = GetTime()
        if (happiness == 1 or happiness == 2) and not hasFeedEffect then
            if currentTime - petFeedFrame.lastAutoFeedAttempt >= 2 then  -- 2 second cooldown
                petFeedFrame.lastAutoFeedAttempt = currentTime
                FeedPet(true)  -- silent mode (no error messages)
            end
        end
    end
end

local function HandleCombatLog(message)
    -- PERFORMANCE: Direct DB access instead of GetCachedConfig()
    if not useMeleeTimer then
        return  -- Early exit if melee timer disabled
    end
    
    -- AttackBar logic: Use string.find (Lua 5.0 compatible)
    -- Check if it's a spell first: "Your <spell> hits/crits/misses"
    local a, b, spell = string.find(message, "Your (.+) hits")
    if not spell then a, b, spell = string.find(message, "Your (.+) crits") end
    if not spell then a, b, spell = string.find(message, "Your (.+) is") end
    if not spell then a, b, spell = string.find(message, "Your (.+) misses") end
    
    -- If it's a spell, it's not a melee auto-attack
    if spell then
        return
    end
    
    -- It's a melee auto-attack (no spell name found)
    -- Like AttackBar: distinguish mainhand from offhand
    local mainSpeed, offSpeed = UnitAttackSpeed("player")
    
    if not offSpeed then
        -- No offhand = all hits are mainhand
        lastMeleeSwingTime = GetTime()
        isMeleeSwinging = true
        UpdateMeleeSpeed()
    else
        -- Has offhand: use timing comparison (AttackBar method)
        local currentTime = GetTime()
        local timeSinceLastSwing = currentTime - lastMeleeSwingTime
        
        -- Mainhand if: first swing OR time matches mainhand speed better than 50%
        if timeSinceLastSwing == 0 or timeSinceLastSwing > (mainSpeed * 0.5) then
            lastMeleeSwingTime = currentTime
            isMeleeSwinging = true
            UpdateMeleeSpeed()
        end
        -- else: ignore offhand swing
    end
end

AH:SetScript("OnEvent", function()
    -- PERFORMANCE TEST: Minimal handler to isolate memory leak
    -- Skip all processing except essential events
    
    if event == "ADDON_LOADED" and arg1 == "HamingwaysHunterTools" then
        HandleAddonLoaded()
        return
    end
    
    if event == "PLAYER_ENTERING_WORLD" then
        if isHunter == false then
            DEFAULT_CHAT_FRAME:AddMessage("Hamingway whispers: Aye, I've seen proper hunters, and ye, friend... ye ain't one o' 'em.", 1.0, 0.5, 1.0)
            AH:UnregisterAllEvents()
            return
        end
        ScanMountSpells()
    end
    
    if isHunter == false then
        return
    end
    
    if frame == nil then
        frame = CreateUI()
    end
    
    -- MINIMAL EVENT HANDLING - only essential events
    if event == "PLAYER_ENTERING_WORLD" then
        HandlePlayerEnteringWorld()
    elseif event == "START_AUTOREPEAT_SPELL" then
        HandleAutoShotStart()
    elseif event == "STOP_AUTOREPEAT_SPELL" then
        HandleAutoShotStop()
    elseif event == "PLAYER_LOGOUT" then
        HandleLogout()
    -- PLAYER_AURAS_CHANGED: Kept for weapon speed + pet happiness (haste buffs via OnUpdate)
    elseif event == "PLAYER_AURAS_CHANGED" then
        HandleAurasChanged()
    -- TEST 2: Re-enable UNIT_INVENTORY_CHANGED (OK ✅)
    elseif event == "UNIT_INVENTORY_CHANGED" and arg1 == "player" then
        HandleInventoryChanged()
    -- TEST 3: Re-enable ITEM_LOCK_CHANGED (OK ✅)
    elseif event == "ITEM_LOCK_CHANGED" then
        HandleItemLockChanged()
    -- TEST 4: Re-enable Combat Events (OK ✅)
    elseif event == "PLAYER_REGEN_DISABLED" then
        HandleCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
        HandleCombatEnd()
    -- TEST 5: Re-enable UI and Target Events (OK ✅)
    elseif event == "UI_ERROR_MESSAGE" then
        HandleUIError(arg1)
    elseif event == "PLAYER_TARGET_CHANGED" then
        HandlePlayerTargetChanged()
    -- TEST 6: Re-enable Pet Events (with fix for GetCachedConfig leak)
    elseif event == "UNIT_PET" and arg1 == "player" then
        HandlePetEvents()
    elseif event == "UNIT_HAPPINESS" and arg1 == "pet" then
        HandlePetEvents()
    -- Melee swing tracking (AttackBar style: both hits and misses)
    elseif event == "CHAT_MSG_COMBAT_SELF_HITS" or event == "CHAT_MSG_COMBAT_SELF_MISSES" then
        HandleCombatLog(arg1)
    end
    
    -- All other events still disabled
end)


-- ============ Slash Commands ============
SLASH_HamingwaysHunterTools1 = "/HamingwaysHunterTools"
SlashCmdList["HamingwaysHunterTools"] = function(msgArg)
    local msgLower = string.lower(msgArg or "")
    if msgLower == "reset" then
        timeReload.Reset()
        timeShoot.Reset()
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
        local elapsed = timeReload.GetElapsed()
        if elapsed > 0 then
            local reloadDuration = weaponSpeed - AIMING_TIME
            print("Time since last shot: " .. string.format("%.3f", elapsed) .. " reload=" .. string.format("%.3f", reloadDuration) .. " total=" .. string.format("%.3f", weaponSpeed))
        end
        -- Event tracking debug
        if HHT_EventCount then
            print("Event counts:")
            for eventName, count in pairs(HHT_EventCount) do
                print("  " .. eventName .. ": " .. count)
            end
            HHT_EventCount = {}  -- Reset
        end
    elseif msgLower == "stats" or msgLower == "resetstats" then
        ResetStats()
    else
        print("HHT: /HamingwaysHunterTools reset | lock | unlock | config | test | debug | stats")
    end
end



