-- HamingwaysHunterTools_AutoShotTimer.lua
-- Auto Shot Timer Module
-- Handles auto-shot detection, bar updates, and timer display

print("[HHT] Loading AutoShotTimer.lua")

-- Module frame
local AutoShotModule = CreateFrame("Frame", "HamingwaysHunterToolsAutoShotModule")

print("[HHT] AutoShotModule frame created")

-- ============ Module Variables (Global for main addon access) ============
HHT_AutoShot_Frame = nil  -- Main timer frame

-- ============ ALL State in ONE table to avoid upvalue limit ============
local AutoShotState = {
    -- Frame references
    frame = nil,
    barFrame = nil,
    barText = nil,
    barTextTotal = nil,
    barTextRange = nil,
    maxBarWidth = 0,
    
    -- Timer state
    isReloading = false,
    isShooting = false,
    lastAutoFired = 0,
    weaponSpeed = 2.0,
    baseWeaponSpeed = 2.0,
    hasteMultiplier = 1.0,
    
    -- Melee timer state
    lastMeleeSwingTime = 0,
    meleeSwingSpeed = 2.0,
    isMeleeSwinging = false,
    useMeleeTimer = false,
    
    -- Other state
    lastAutoShotTime = 0,
    autoShotBetweenCasts = false,
    
    -- Timing state
    lastTimerModeCheck = 0,
    lastRangeCheck = 0,
    
    -- Range cache
    cachedRangeText = nil,
    cachedIsDeadZone = false,
    
    -- Text cache
    textCache = {
        barText = nil,
        barTextTotal = nil,
        barTextRange = nil,
        lastUpdate = 0,
        interval = 0.1,
        lastBlink = false,
    },
    
    -- Events
    registeredEvents = {},
    
    -- Position tracking
    lastPlayerX = 0,
    lastPlayerY = 0,
    
    -- Timer state (no closures)
    timeReloadStart = 0,
    timeShootStart = 0,
    
    -- OnUpdate
    isMainOnUpdateActive = false,
}

-- Constants
local AIMING_TIME = 0.5
local BAR_ALPHA = 0.8
local TIMER_MODE_INTERVAL = 0.5
local RANGE_CHECK_INTERVAL = 0.3

-- ============ Helper Functions ============
local function GetDB()
    return HamingwaysHunterToolsDB or {}
end

local function ScanBaseWeaponSpeed()
    if not HHT_AutoShot_ScanTooltip then
        HHT_AutoShot_ScanTooltip = CreateFrame("GameTooltip", "HHT_AutoShot_WeaponSpeedScan", nil, "GameTooltipTemplate")
        HHT_AutoShot_ScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end
    
    HHT_AutoShot_ScanTooltip:ClearLines()
    HHT_AutoShot_ScanTooltip:SetInventoryItem("player", 18)
    
    for i = 1, HHT_AutoShot_ScanTooltip:NumLines() do
        local rightText = getglobal("HHT_AutoShot_WeaponSpeedScanTextRight" .. i)
        if rightText then
            local text = rightText:GetText()
            if text then
                local _, _, speed = string.find(text, "(%d+%.%d+)")
                if speed then
                    AutoShotState.baseWeaponSpeed = tonumber(speed)
                    return
                end
            end
        end
    end
    
    local currentSpeed = UnitRangedDamage("player")
    if currentSpeed and currentSpeed > 0 then
        AutoShotState.baseWeaponSpeed = currentSpeed
    end
end

local function UpdateWeaponSpeed()
    local speed = UnitRangedDamage("player")
    if speed and speed > 0 then
        AutoShotState.weaponSpeed = speed
        if AutoShotState.baseWeaponSpeed and AutoShotState.baseWeaponSpeed > 0 then
            AutoShotState.hasteMultiplier = AutoShotState.weaponSpeed / AutoShotState.baseWeaponSpeed
        end
    end
end

local function UpdateMeleeSpeed()
    local speed, offhandSpeed = UnitAttackSpeed("player")
    if speed and speed > 0 then
        AutoShotState.meleeSwingSpeed = speed
    end
end

local function IsTargetInMeleeRange()
    if not UnitExists("target") or UnitIsDead("target") then
        return false
    end
    return CheckInteractDistance("target", 3)
end

-- ============ Range Detection ============
local function CheckSpellInRange(spellName)
    -- Will be provided by main addon
    if HHT_Core and HHT_Core.CheckSpellInRange then
        return HHT_Core.CheckSpellInRange(spellName)
    end
    return false
end

local function GetTargetRange()
    if not UnitExists("target") or UnitIsDead("target") or not UnitCanAttack("player", "target") then
        return nil
    end
    
    local isMelee = CheckInteractDistance("target", 3)
    local isFollow = CheckInteractDistance("target", 4)
    local isRanged = CheckSpellInRange("Auto Shot")
    local isScatter = CheckSpellInRange("Scatter Shot")
    local isScare = CheckSpellInRange("Scare Beast")
    
    if isMelee then
        return "Melee Range", false
    elseif isRanged then
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
        return "Dead Zone", true
    else
        return "Out of Range", false
    end
end

-- ============ Timer Mode Management ============
-- Timer helper functions
local function timeReloadGetElapsed()
    if AutoShotState.timeReloadStart == 0 then return 0 end
    return GetTime() - AutoShotState.timeReloadStart
end

local function timeReloadGetPercent()
    if AutoShotState.timeReloadStart == 0 then return 0 end
    local elapsed = GetTime() - AutoShotState.timeReloadStart
    local duration = AutoShotState.weaponSpeed - AIMING_TIME
    return elapsed <= duration and (elapsed / duration) or 1.0
end

local function timeReloadIsComplete()
    if AutoShotState.timeReloadStart == 0 then return false end
    local duration = AutoShotState.weaponSpeed - AIMING_TIME
    return GetTime() - AutoShotState.timeReloadStart >= duration
end

local function timeShootGetElapsed()
    if AutoShotState.timeShootStart == 0 then return 0 end
    return GetTime() - AutoShotState.timeShootStart
end

local function timeShootIsStarted()
    return AutoShotState.timeShootStart > 0
end

local function UpdateCombatEventRegistration()
    local db = GetDB()
    if not db then return end
    
    -- SuperWoW: Always use UNIT_CASTEVENT for melee (MAINHAND events)
    local needUnitCastEvent = (db.showMeleeTimer or db.autoSwitchMeleeRanged) and AutoShotState.useMeleeTimer
    if needUnitCastEvent then
        if PLAYER_GUID and not AutoShotState.registeredEvents["UNIT_CASTEVENT"] then
            if AH then
                AH:RegisterEvent("UNIT_CASTEVENT")
                AutoShotState.registeredEvents["UNIT_CASTEVENT"] = true
            end
        end
    else
        if AutoShotState.registeredEvents["UNIT_CASTEVENT"] and not AutoShotState.isShooting then
            if AH then
                AH:UnregisterEvent("UNIT_CASTEVENT")
                AutoShotState.registeredEvents["UNIT_CASTEVENT"] = nil
            end
        end
    end
end

local function UpdateTimerMode()
    local db = GetDB()
    if not db then return end
    local oldMode = AutoShotState.useMeleeTimer
    
    -- ORIGINAL LOGIC from original_before_extraction.lua
    -- Melee timer is bound to AutoShot visibility
    if not db.showAutoShotTimer then
        AutoShotState.useMeleeTimer = false
    elseif not db.showMeleeTimer and not db.autoSwitchMeleeRanged then
        AutoShotState.useMeleeTimer = false
    elseif db.meleeTimerInsteadOfAutoShot then
        AutoShotState.useMeleeTimer = true
    elseif db.autoSwitchMeleeRanged then
        AutoShotState.useMeleeTimer = IsTargetInMeleeRange()
    else
        -- Default: use ranged (not melee)
        AutoShotState.useMeleeTimer = false
    end
    
    if HHT_DEBUG and oldMode ~= AutoShotState.useMeleeTimer then
        print("[MeleeTimer] Mode changed: " .. tostring(AutoShotState.useMeleeTimer) .. " (showMeleeTimer=" .. tostring(db.showMeleeTimer) .. ", instead=" .. tostring(db.meleeTimerInsteadOfAutoShot) .. ", autoSwitch=" .. tostring(db.autoSwitchMeleeRanged) .. ")")
    end
    
    if oldMode ~= AutoShotState.useMeleeTimer then
        UpdateCombatEventRegistration()
    end
end

-- Forward declaration for MainFrameOnUpdate (needed by EnableMainOnUpdate)
local MainFrameOnUpdate

-- ============ Bar Update Functions (EXACT COPY from original) ============
local function UpdateBarShoot(now)
    if not AutoShotState.barFrame or not AutoShotState.barText or not AutoShotState.barTextTotal then return end
    -- PERFORMANCE: Direct DB access - this runs 60 times per second!
    local db = HamingwaysHunterToolsDB
    if not db then return end
    
    -- Yellow bar: anchor LEFT, grow left to right during aiming window
    AutoShotState.barFrame:ClearAllPoints()
    AutoShotState.barFrame:SetPoint("TOPLEFT", AutoShotState.frame, "TOPLEFT", 2, -2)
    AutoShotState.barFrame:Show()
    
    -- Calculate elapsed time from shoot start
    local shootElapsed = timeShootGetElapsed()
    local remainingShoot = AIMING_TIME - shootElapsed
    
    -- Update timer display (show shoot elapsed / weapon speed) - no throttle for precision
    if db.showTimerText then
        -- Calculate total elapsed: reload duration + shoot elapsed
        local reloadDuration = AutoShotState.weaponSpeed - AIMING_TIME
        local totalElapsed = reloadDuration + shootElapsed
        local newText = string.format("%.2fs/%.2fs", totalElapsed, AutoShotState.weaponSpeed)
        if newText ~= AutoShotState.textCache.barTextTotal then
            AutoShotState.barTextTotal:SetText(newText)
            AutoShotState.textCache.barTextTotal = newText
        end
    else
        if AutoShotState.textCache.barTextTotal ~= "" then
            AutoShotState.barTextTotal:SetText("")
            AutoShotState.textCache.barTextTotal = ""
        end
    end
    
    -- Update range display (center of bar) - use cached value
    if AutoShotState.barTextRange then
        if AutoShotState.cachedRangeText ~= AutoShotState.textCache.barTextRange then
            AutoShotState.barTextRange:SetText(AutoShotState.cachedRangeText or "")
            AutoShotState.textCache.barTextRange = AutoShotState.cachedRangeText
        end
        -- Blink in Dead Zone
        if AutoShotState.cachedIsDeadZone then
            local blink = math.mod(math.floor(now * 3), 2) == 0
            if blink ~= AutoShotState.textCache.lastBlink then
                AutoShotState.barTextRange:SetAlpha(blink and 1 or 0.3)
                AutoShotState.textCache.lastBlink = blink
            end
        else
            AutoShotState.barTextRange:SetAlpha(1)
            AutoShotState.textCache.lastBlink = false
        end
    end
    
    -- Show yellow bar during aiming window
    if remainingShoot > 0 then
        -- Width grows left to right (elapsed time)
        local percentElapsed = shootElapsed / AIMING_TIME
        local width = math.max(1, AutoShotState.maxBarWidth * percentElapsed)
        AutoShotState.barFrame:SetWidth(width)
        AutoShotState.barFrame:SetVertexColor(db.aimingColor.r, db.aimingColor.g, db.aimingColor.b, BAR_ALPHA)
        if db.showTimerText then
            local newText = string.format("%.2fs", remainingShoot)
            if newText ~= AutoShotState.textCache.barText then
                AutoShotState.barText:SetText(newText)
                AutoShotState.textCache.barText = newText
            end
        elseif AutoShotState.textCache.barText ~= "" then
            AutoShotState.barText:SetText("")
            AutoShotState.textCache.barText = ""
        end
    else
        -- Ready to shoot: show full yellow bar
        AutoShotState.barFrame:SetWidth(AutoShotState.maxBarWidth)
        AutoShotState.barFrame:SetVertexColor(db.aimingColor.r, db.aimingColor.g, db.aimingColor.b, BAR_ALPHA)
        if AutoShotState.textCache.barText ~= "" then
            AutoShotState.barText:SetText("")
            AutoShotState.textCache.barText = ""
        end
    end
end

local function UpdateBarReload(now)
    if not AutoShotState.barFrame or not AutoShotState.barText or not AutoShotState.barTextTotal then return end
    -- PERFORMANCE: Direct DB access - this runs 60 times per second!
    local db = HamingwaysHunterToolsDB
    if not db then return end
    
    -- Check if reload is complete and transition to shoot phase
    if timeReloadIsComplete() then
        AutoShotState.isReloading = false
        UpdateWeaponSpeed()  -- Update speed before shoot phase
        AutoShotState.timeShootStart = GetTime()  -- Start shoot timer when reload completes
        return
    end
    
    -- Red bar: anchor LEFT, grow left to right (inverted fill)
    AutoShotState.barFrame:ClearAllPoints()
    AutoShotState.barFrame:SetPoint("TOPLEFT", AutoShotState.frame, "TOPLEFT", 2, -2)
    
    -- Use closure pattern for efficient calculation
    local percent = timeReloadGetPercent()
    local elapsed = timeReloadGetElapsed()
    local reloadDuration = AutoShotState.weaponSpeed - AIMING_TIME
    local remainingReload = reloadDuration - elapsed
    
    -- Update timer display (no throttle for precision)
    if db.showTimerText then
        local newText = string.format("%.2fs/%.2fs", elapsed, AutoShotState.weaponSpeed)
        if newText ~= AutoShotState.textCache.barTextTotal then
            AutoShotState.barTextTotal:SetText(newText)
            AutoShotState.textCache.barTextTotal = newText
        end
    else
        if AutoShotState.textCache.barTextTotal ~= "" then
            AutoShotState.barTextTotal:SetText("")
            AutoShotState.textCache.barTextTotal = ""
        end
    end
    
    -- Update range display (center of bar) - use cached value
    if AutoShotState.barTextRange then
        if AutoShotState.cachedRangeText ~= AutoShotState.textCache.barTextRange then
            AutoShotState.barTextRange:SetText(AutoShotState.cachedRangeText or "")
            AutoShotState.textCache.barTextRange = AutoShotState.cachedRangeText
        end
        -- Blink in Dead Zone
        if AutoShotState.cachedIsDeadZone then
            local blink = math.mod(math.floor(now * 3), 2) == 0
            if blink ~= AutoShotState.textCache.lastBlink then
                AutoShotState.barTextRange:SetAlpha(blink and 1 or 0.3)
                AutoShotState.textCache.lastBlink = blink
            end
        else
            AutoShotState.barTextRange:SetAlpha(1)
            AutoShotState.textCache.lastBlink = false
        end
    end
    
    if remainingReload > 0 then
        -- Inverted: show empty space growing
        local width = math.max(1, AutoShotState.maxBarWidth * (1 - percent))
        AutoShotState.barFrame:SetWidth(width)
        AutoShotState.barFrame:SetVertexColor(db.reloadColor.r, db.reloadColor.g, db.reloadColor.b, BAR_ALPHA)
        if db.showTimerText then
            local newText = string.format("%.2fs", remainingReload)
            if newText ~= AutoShotState.textCache.barText then
                AutoShotState.barText:SetText(newText)
                AutoShotState.textCache.barText = newText
            end
        elseif AutoShotState.textCache.barText ~= "" then
            AutoShotState.barText:SetText("")
            AutoShotState.textCache.barText = ""
        end
    else
        AutoShotState.isReloading = false
    end
end

local function UpdateBarMelee(now)
    if not AutoShotState.barFrame or not AutoShotState.barTextTotal then return end
    -- PERFORMANCE: Direct DB access - this runs 60 times per second!
    local db = HamingwaysHunterToolsDB
    if not db then return end
    
    -- Orange bar for melee swings
    AutoShotState.barFrame:ClearAllPoints()
    AutoShotState.barFrame:SetPoint("TOPLEFT", AutoShotState.frame, "TOPLEFT", 2, -2)
    
    local elapsed = AutoShotState.isMeleeSwinging and (now - AutoShotState.lastMeleeSwingTime) or 0
    local remainingSwing = math.max(0, AutoShotState.meleeSwingSpeed - elapsed)
    
    -- Auto-stop tracking after 3 seconds of no swings
    if AutoShotState.isMeleeSwinging and elapsed > (AutoShotState.meleeSwingSpeed + 3.0) then
        AutoShotState.isMeleeSwinging = false
        remainingSwing = AutoShotState.meleeSwingSpeed
    end
    
    -- Hide left timer text in melee mode
    if AutoShotState.barText and AutoShotState.textCache.barText ~= "" then
        AutoShotState.barText:SetText("")
        AutoShotState.textCache.barText = ""
    end
    
    -- Update timer display - only seconds, no "Melee" prefix
    if db.showTimerText and now - AutoShotState.textCache.lastUpdate >= AutoShotState.textCache.interval then
        local newText = string.format("%.2fs", remainingSwing)
        if newText ~= AutoShotState.textCache.barTextTotal then
            AutoShotState.barTextTotal:SetText(newText)
            AutoShotState.textCache.barTextTotal = newText
        end
    elseif AutoShotState.textCache.barTextTotal ~= "" then
        AutoShotState.barTextTotal:SetText("")
        AutoShotState.textCache.barTextTotal = ""
    end
    
    -- Update range display (center of bar) - use cached value
    if AutoShotState.barTextRange then
        if AutoShotState.cachedRangeText ~= AutoShotState.textCache.barTextRange then
            AutoShotState.barTextRange:SetText(AutoShotState.cachedRangeText or "")
            AutoShotState.textCache.barTextRange = AutoShotState.cachedRangeText
        end
        -- Blink in Dead Zone
        if AutoShotState.cachedIsDeadZone then
            local blink = math.mod(math.floor(now * 3), 2) == 0
            if blink ~= AutoShotState.textCache.lastBlink then
                AutoShotState.barTextRange:SetAlpha(blink and 1 or 0.3)
                AutoShotState.textCache.lastBlink = blink
            end
        else
            AutoShotState.barTextRange:SetAlpha(1)
            AutoShotState.textCache.lastBlink = false
        end
    end
    
    if remainingSwing > 0 then
        -- Show progress bar (growing from left to right as swing progresses)
        local percentElapsed = elapsed / AutoShotState.meleeSwingSpeed
        local width = math.max(1, AutoShotState.maxBarWidth * percentElapsed)
        AutoShotState.barFrame:SetWidth(width)
        AutoShotState.barFrame:SetVertexColor(db.meleeColor.r, db.meleeColor.g, db.meleeColor.b, BAR_ALPHA)
    else
        -- Ready for next swing (100% full, change color to indicate ready)
        AutoShotState.barFrame:SetWidth(AutoShotState.maxBarWidth)
        AutoShotState.barFrame:SetVertexColor(1.0, 0.8, 0.8, BAR_ALPHA)  -- Lighter color when ready
    end
end

-- ============ OnUpdate Management ============
local function ShouldMainOnUpdateRun()
    local db = GetDB()
    -- OnUpdate must always run if showAutoShotTimer OR showMeleeTimer OR autoSwitchMeleeRanged is enabled
    -- This allows UpdateTimerMode() to run regularly and detect range changes for auto-switching
    return db and (db.showAutoShotTimer or db.showMeleeTimer or db.autoSwitchMeleeRanged)
end

local function EnableMainOnUpdate()
    if not AutoShotState.isMainOnUpdateActive and AutoShotState.frame then
        AutoShotState.frame:SetScript("OnUpdate", MainFrameOnUpdate)
        AutoShotState.isMainOnUpdateActive = true
    end
end

local function DisableMainOnUpdate()
    if AutoShotState.isMainOnUpdateActive and AutoShotState.frame then
        -- Reset bar to idle state before disabling OnUpdate
        if AutoShotState.barFrame and AutoShotState.barTextTotal then
            AutoShotState.barFrame:SetWidth(1)
            AutoShotState.barFrame:SetVertexColor(0.3, 0.3, 0.3, 0.5)
            if AutoShotState.barText then AutoShotState.barText:SetText("") end
            AutoShotState.barTextTotal:SetText("")
            if AutoShotState.barTextRange then AutoShotState.barTextRange:SetText("") end
        end
        
        -- Reset text cache so texts can be updated again when OnUpdate resumes
        AutoShotState.textCache.barText = nil
        AutoShotState.textCache.barTextTotal = nil
        AutoShotState.textCache.barTextRange = nil
        AutoShotState.textCache.lastUpdate = 0
        
        AutoShotState.frame:SetScript("OnUpdate", nil)
        AutoShotState.isMainOnUpdateActive = false
    end
end

local function CheckMainOnUpdateState()
    if ShouldMainOnUpdateRun() then
        EnableMainOnUpdate()
    else
        DisableMainOnUpdate()
    end
end

-- ============ Shot Detection ============
-- Timer inline functions (no closures = no upvalues)
local function UpdatePlayerPosition()
    AutoShotState.lastPlayerX, AutoShotState.lastPlayerY = GetPlayerMapPosition("player")
end

local function CheckStandingStill()
    local x, y = GetPlayerMapPosition("player")
    local standing = (x == AutoShotState.lastPlayerX and y == AutoShotState.lastPlayerY)
    AutoShotState.lastPlayerX, AutoShotState.lastPlayerY = x, y
    return standing
end

local function OnShotFired()
    -- IMPORTANT: Always track that auto-shot fired between casts for stats
    AutoShotState.autoShotBetweenCasts = true
    
    -- Ignore if currently casting (don't update timer/phases)
    if HHT_Core and HHT_Core.isCasting then return end
    
    -- Ignore shot detection for 0.3s after cast ends
    if HHT_Core and (GetTime() - HHT_Core.lastCastEndTime) < 0.3 then return end
    
    AutoShotState.lastAutoShotTime = GetTime()
    AutoShotState.lastAutoFired = AutoShotState.lastAutoShotTime
    
    UpdateWeaponSpeed()
    
    AutoShotState.timeReloadStart = GetTime()
    AutoShotState.timeShootStart = 0
    
    AutoShotState.isReloading = true
    if not AutoShotState.isShooting then
        AutoShotState.isShooting = true
    end
    
    AutoShotState.autoShotBetweenCasts = true
    
    -- Notify stats module
    if HHT_Stats_OnAutoShot then
        HHT_Stats_OnAutoShot(AutoShotState.lastAutoShotTime)
    end
end

-- ============ Main AutoShotState.frame OnUpdate ============
MainFrameOnUpdate = function()
    local now = GetTime()
    local db = GetDB()
    if not db then return end
    
    -- CRITICAL EARLY EXIT: Both timers completely disabled
    -- Show bar if: showAutoShotTimer OR (useMeleeTimer AND (showMeleeTimer OR autoSwitchMeleeRanged))
    if not db.showAutoShotTimer and not (AutoShotState.useMeleeTimer and (db.showMeleeTimer or db.autoSwitchMeleeRanged)) then
        if AutoShotState.frame:GetAlpha() > 0 then AutoShotState.frame:SetAlpha(0) end
        return
    end
    
    -- PERFORMANCE: Cache UnitAffectingCombat once per frame (expensive API call)
    local inCombat = UnitAffectingCombat("player")
    
    -- EARLY EXIT: Not active and frames are locked (combat visibility check)
    if not AutoShotState.isShooting and not AutoShotState.isReloading and not (HHT_Core and HHT_Core.isCasting) and not AutoShotState.isMeleeSwinging then
        if db.showOnlyInCombat and not inCombat and not (HHT_Core and HHT_Core.previewMode) then
            if AutoShotState.frame:GetAlpha() > 0 then AutoShotState.frame:SetAlpha(0) end
            return
        end
    end
    
    -- PERFORMANCE: Throttled UpdateTimerMode (runs AFTER early exits)
    if now - AutoShotState.lastTimerModeCheck >= TIMER_MODE_INTERVAL then
        AutoShotState.lastTimerModeCheck = now
        UpdateTimerMode()
    end
    
    local isAutoShotEnabled = (not db.showOnlyInCombat or inCombat or AutoShotState.isShooting or (HHT_Core and HHT_Core.isCasting) or (HHT_Core and HHT_Core.previewMode))
    if isAutoShotEnabled and now - AutoShotState.lastRangeCheck >= RANGE_CHECK_INTERVAL then
        AutoShotState.lastRangeCheck = now
        AutoShotState.cachedRangeText, AutoShotState.cachedIsDeadZone = GetTargetRange()
    end
    
    -- Melee Timer Mode (from original v1.0.6)
    -- Show melee bar if ANY of these are true: showAutoShotTimer, showMeleeTimer, or autoSwitchMeleeRanged
    if AutoShotState.useMeleeTimer and (db.showAutoShotTimer or db.showMeleeTimer or db.autoSwitchMeleeRanged) then
        if db.showOnlyInCombat and not inCombat then
            -- Hide in non-combat (bound to AutoShot combat setting)
            if AutoShotState.barFrame then
                AutoShotState.barFrame:SetWidth(1)
                AutoShotState.barFrame:SetVertexColor(0.3, 0.3, 0.3, 0.5)
                AutoShotState.barTextTotal:SetText("")
                if AutoShotState.frame then AutoShotState.frame:SetAlpha(0) end
            end
        elseif not AutoShotState.isMeleeSwinging then
            -- Not swinging - show idle state
            if AutoShotState.barFrame and AutoShotState.barTextTotal and AutoShotState.barTextRange then
                AutoShotState.barFrame:SetWidth(1)
                AutoShotState.barFrame:SetVertexColor(0.3, 0.3, 0.3, 0.5)
                -- Hide left text
                if AutoShotState.barText then
                    AutoShotState.barText:SetText("")
                end
                -- Show only seconds on right
                if db.showTimerText and now - AutoShotState.textCache.lastUpdate >= AutoShotState.textCache.interval then
                    AutoShotState.textCache.lastUpdate = now
                    local newText = string.format("%.2fs", AutoShotState.meleeSwingSpeed)
                    if newText ~= AutoShotState.textCache.barTextTotal then
                        AutoShotState.barTextTotal:SetText(newText)
                        AutoShotState.textCache.barTextTotal = newText
                    end
                elseif not db.showTimerText and AutoShotState.textCache.barTextTotal ~= "" then
                    AutoShotState.barTextTotal:SetText("")
                    AutoShotState.textCache.barTextTotal = ""
                end
                -- Update range display (center) - use cached value
                if AutoShotState.barTextRange then
                    if AutoShotState.cachedRangeText ~= AutoShotState.textCache.barTextRange then
                        AutoShotState.barTextRange:SetText(AutoShotState.cachedRangeText or "")
                        AutoShotState.textCache.barTextRange = AutoShotState.cachedRangeText
                    end
                    -- Blink in Dead Zone
                    if AutoShotState.cachedIsDeadZone then
                        local blink = math.mod(math.floor(now * 3), 2) == 0
                        if blink ~= AutoShotState.textCache.lastBlink then
                            AutoShotState.barTextRange:SetAlpha(blink and 1 or 0.3)
                            AutoShotState.textCache.lastBlink = blink
                        end
                    else
                        AutoShotState.barTextRange:SetAlpha(1)
                        AutoShotState.textCache.lastBlink = false
                    end
                end
            end
        else
            -- Active melee swinging
            if AutoShotState.frame then AutoShotState.frame:SetAlpha(1) end
            UpdateBarMelee(now)
        end
    -- Ranged Timer Mode
    elseif not AutoShotState.isShooting then
        if AutoShotState.barFrame and AutoShotState.barTextTotal then
            AutoShotState.barFrame:SetWidth(1)
            AutoShotState.barFrame:SetVertexColor(0.3, 0.3, 0.3, 0.5)
            if now - AutoShotState.textCache.lastUpdate >= AutoShotState.textCache.interval then
                AutoShotState.textCache.lastUpdate = now
                if db.showTimerText then
                    local newText = string.format("%.2fs", AutoShotState.weaponSpeed)
                    if newText ~= AutoShotState.textCache.barTextTotal then
                        AutoShotState.barTextTotal:SetText(newText)
                        AutoShotState.textCache.barTextTotal = newText
                    end
                else
                    if AutoShotState.textCache.barTextTotal ~= "" then
                        AutoShotState.barTextTotal:SetText("")
                        AutoShotState.textCache.barTextTotal = ""
                    end
                end
            end
            if AutoShotState.barTextRange then
                if AutoShotState.cachedRangeText ~= AutoShotState.textCache.barTextRange then
                    AutoShotState.barTextRange:SetText(AutoShotState.cachedRangeText or "")
                    AutoShotState.textCache.barTextRange = AutoShotState.cachedRangeText
                end
                if AutoShotState.cachedIsDeadZone then
                    local blink = math.mod(math.floor(now * 3), 2) == 0
                    if blink ~= AutoShotState.textCache.lastBlink then
                        AutoShotState.barTextRange:SetAlpha(blink and 1 or 0.3)
                        AutoShotState.textCache.lastBlink = blink
                    end
                else
                    AutoShotState.barTextRange:SetAlpha(1)
                    AutoShotState.textCache.lastBlink = false
                end
            end
        end
    elseif AutoShotState.isReloading then
        if AutoShotState.frame then AutoShotState.frame:SetAlpha(1) end
        UpdateBarReload(now)
    else
        if AutoShotState.frame then AutoShotState.frame:SetAlpha(1) end
        if not CheckStandingStill() or (HHT_Core and HHT_Core.isCasting) then
            AutoShotState.timeShootStart = GetTime()
        end
        UpdateBarShoot(now)
    end
end

-- ============ Event Handlers ============
local function HandleCombatLog(message)
    if not AutoShotState.useMeleeTimer then
        return
    end
    
    if HHT_DEBUG then
        print("[MeleeTimer] Combat log: " .. tostring(message))
    end
    
    local a, b, spell = string.find(message, "Your (.+) hits")
    if not spell then a, b, spell = string.find(message, "Your (.+) crits") end
    if not spell then a, b, spell = string.find(message, "Your (.+) is") end
    if not spell then a, b, spell = string.find(message, "Your (.+) misses") end
    
    if spell then
        if HHT_DEBUG then
            print("[MeleeTimer] Ignored spell: " .. spell)
        end
        return
    end
    
    local mainSpeed, offSpeed = UnitAttackSpeed("player")
    
    if not offSpeed then
        AutoShotState.lastMeleeSwingTime = GetTime()
        AutoShotState.isMeleeSwinging = true
        UpdateMeleeSpeed()
        if HHT_DEBUG then
            print("[MeleeTimer] Melee swing detected! Speed: " .. string.format("%.2f", AutoShotState.meleeSwingSpeed))
        end
    else
        local currentTime = GetTime()
        local timeSinceLastSwing = currentTime - AutoShotState.lastMeleeSwingTime
        
        if timeSinceLastSwing == 0 or timeSinceLastSwing > (mainSpeed * 0.5) then
            AutoShotState.lastMeleeSwingTime = currentTime
            AutoShotState.isMeleeSwinging = true
            UpdateMeleeSpeed()
            if HHT_DEBUG then
                print("[MeleeTimer] Melee swing detected! Speed: " .. string.format("%.2f", AutoShotState.meleeSwingSpeed))
            end
        end
    end
end

-- ============ Global API Functions ============
function HHT_AutoShot_Initialize()
    print("[HHT] AutoShot_Initialize START")
    
    -- Scan base weapon speed
    ScanBaseWeaponSpeed()
    UpdateWeaponSpeed()
    UpdateMeleeSpeed()
    
    print("[HHT] AutoShot_Initialize: Weapon speeds updated")
    
    -- Setup event handler (nil - AutoShotModule events are handled by UNIT_CASTEVENT in main module)
    AutoShotModule:SetScript("OnEvent", function()
    end)
    
    print("[HHT] AutoShot_Initialize: Event handler set")
    
    -- Initialize timer mode and register events if needed
    UpdateTimerMode()
    print("[HHT] AutoShot_Initialize: Timer mode updated, useMeleeTimer=" .. tostring(AutoShotState.useMeleeTimer))
    
    UpdateCombatEventRegistration()
    print("[HHT] AutoShot_Initialize: Combat events registered, UNIT_CASTEVENT=" .. tostring(AutoShotState.registeredEvents["UNIT_CASTEVENT"] ~= nil))
    
    -- Always output status
    local db = GetDB()
    if db then
        print("[HHT] MeleeTimer: showMeleeTimer=" .. tostring(db.showMeleeTimer) .. ", meleeTimerInstead=" .. tostring(db.meleeTimerInsteadOfAutoShot) .. ", autoSwitch=" .. tostring(db.autoSwitchMeleeRanged))
    else
        print("[HHT] MeleeTimer: DB is nil!")
    end
    
    print("[HHT] AutoShot_Initialize DONE")
end

function HHT_AutoShot_CreateFrame(parentFrame)
    AutoShotState.frame = parentFrame
    
    -- Create bar
    AutoShotState.barFrame = AutoShotState.frame:CreateTexture(nil, "ARTWORK")
    AutoShotState.barFrame:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    AutoShotState.barFrame:SetHeight(parentFrame:GetHeight() - 4)
    AutoShotState.barFrame:SetPoint("TOPLEFT", AutoShotState.frame, "TOPLEFT", 2, -2)
    -- Initialize bar in idle state (thin gray line)
    AutoShotState.barFrame:SetWidth(1)
    AutoShotState.barFrame:SetVertexColor(0.3, 0.3, 0.3, 0.5)
    
    -- Create text elements
    AutoShotState.barText = AutoShotState.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    AutoShotState.barText:SetPoint("RIGHT", AutoShotState.frame, "LEFT", -5, 0)
    AutoShotState.barText:SetTextColor(1, 1, 1, 1)
    
    AutoShotState.barTextTotal = AutoShotState.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    AutoShotState.barTextTotal:SetPoint("LEFT", AutoShotState.frame, "RIGHT", 5, 0)
    AutoShotState.barTextTotal:SetTextColor(1, 1, 1, 1)
    
    AutoShotState.barTextRange = AutoShotState.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    AutoShotState.barTextRange:SetPoint("CENTER", AutoShotState.frame, "CENTER", 0, 0)
    AutoShotState.barTextRange:SetTextColor(1, 1, 1, 1)
    
    local db = GetDB()
    AutoShotState.maxBarWidth = (db.frameWidth or 240) - 4
end

function HHT_AutoShot_OnShotFired()
    OnShotFired()
end

function HHT_AutoShot_EnableOnUpdate()
    EnableMainOnUpdate()
end

function HHT_AutoShot_DisableOnUpdate()
    DisableMainOnUpdate()
end

function HHT_AutoShot_CheckOnUpdateState()
    CheckMainOnUpdateState()
end

function HHT_AutoShot_GetFrame()
    return AutoShotState.frame
end

function HHT_AutoShot_UpdateFrameSettings()
    local db = GetDB()
    if AutoShotState.frame and db then
        AutoShotState.maxBarWidth = (db.frameWidth or 240) - 4
    end
end

function HHT_AutoShot_HandleAutoShotStart()
    AutoShotState.isShooting = true
    UpdatePlayerPosition()
    if not timeShootIsStarted() then
        UpdateWeaponSpeed()
        AutoShotState.timeShootStart = GetTime()
    end
    EnableMainOnUpdate()
end

function HHT_AutoShot_HandleAutoShotStop()
    AutoShotState.isShooting = false
    AutoShotState.isReloading = false
    AutoShotState.timeReloadStart = 0
    AutoShotState.timeShootStart = 0
    
    -- Abort active cast when AutoShot is manually stopped (e.g., via ESC key)
    if HHT_Core and HHT_Core.isCasting then
        HHT_Castbar_AbortCast()
    end
    
    CheckMainOnUpdateState()
end

function HHT_AutoShot_Reset()
    AutoShotState.timeReloadStart = 0
    AutoShotState.timeShootStart = 0
    AutoShotState.isReloading = false
    UpdateWeaponSpeed()
end

function HHT_AutoShot_GetState()
    return {
        isShooting = AutoShotState.isShooting,
        isReloading = AutoShotState.isReloading,
        weaponSpeed = AutoShotState.weaponSpeed,
        baseWeaponSpeed = AutoShotState.baseWeaponSpeed,
        hasteMultiplier = AutoShotState.hasteMultiplier,
        meleeSwingSpeed = AutoShotState.meleeSwingSpeed,
        isMeleeSwinging = AutoShotState.isMeleeSwinging,
        useMeleeTimer = AutoShotState.useMeleeTimer,
        lastAutoShotTime = AutoShotState.lastAutoShotTime,
        lastAutoFired = AutoShotState.lastAutoFired,
        autoShotBetweenCasts = AutoShotState.autoShotBetweenCasts,
        lastMeleeSwingTime = AutoShotState.lastMeleeSwingTime,
        timeReloadStart = AutoShotState.timeReloadStart,
        timeShootStart = AutoShotState.timeShootStart,
    }
end

function HHT_AutoShot_OnMeleeSwing()
    -- Called from UNIT_CASTEVENT MAINHAND (doesn't work) or ready for future use
    AutoShotState.lastMeleeSwingTime = GetTime()
    AutoShotState.isMeleeSwinging = true
    UpdateMeleeSpeed()
end

function HHT_AutoShot_GetDebugInfo()
    return {
        shooting = AutoShotState.isShooting,
        reloading = AutoShotState.isReloading,
        weaponSpeed = AutoShotState.weaponSpeed,
        onUpdateActive = AutoShotState.isMainOnUpdateActive,
    }
end

function HHT_AutoShot_ResetReactionTracking()
    AutoShotState.lastAutoShotTime = 0
end

function HHT_AutoShot_ResetAutoShotBetweenCasts()
    AutoShotState.autoShotBetweenCasts = false
end
