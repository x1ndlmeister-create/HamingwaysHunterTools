-- HamingwaysHunterTools_Castbar.lua
-- Castbar Module
-- Handles cast detection, bar display, and statistics tracking

-- Module frame
local CastbarModule = CreateFrame("Frame", "HamingwaysHunterToolsCastbarModule")

-- ============ ALL State in ONE table to avoid upvalue limit ============
local CastbarState = {
    -- Frame references
    castFrame = nil,
    castBarFrame = nil,
    castBarText = nil,
    castBarTextTime = nil,
    
    -- Cast state
    castStartTime = 0,
    castEndTime = 0,
    castDuration = 0,
    castSpellName = "",
    castSpellID = 0,
}

-- Constants
local BAR_ALPHA = 0.8
local AIMING_TIME = 0.5

-- ============ Helper Functions ============
local function GetDB()
    return HamingwaysHunterToolsDB or {}
end

local function GetCore()
    return HHT_Core
end

local function GetBaseWeaponSpeed()
    if HHT_Core and HHT_Core.GetBaseWeaponSpeed then
        return HHT_Core.GetBaseWeaponSpeed()
    end
    -- Fallback
    local currentSpeed = UnitRangedDamage("player")
    return currentSpeed or 2.0
end

-- Forward declarations
local UpdateCastbar
local StartCast
local HandleCastAttempt

-- ============ Cast Time Calculation ============
local function CalcCastTime(spellName)
    local meta = HHT_castSpells[spellName]
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

-- ============ Castbar Update ============
UpdateCastbar = function()
    -- PERFORMANCE: Early exit if castbar is disabled
    if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showCastbar then return end
    if not HHT_Core.isCasting then return end
    if not CastbarState.castFrame or not CastbarState.castBarFrame or not CastbarState.castBarText or not CastbarState.castBarTextTime then
        return
    end
    
    local now = GetTime()
    local elapsed = now - CastbarState.castStartTime
    local duration = CastbarState.castEndTime - CastbarState.castStartTime
    
    if elapsed >= duration then
        HHT_Core.isCasting = false
        HHT_Core.lastCastEndTime = GetTime()  -- Mark when cast ended
        CastbarState.castFrame:Hide()
        -- Hide main frame if needed when casting ends
        local frame = HHT_AutoShot_GetFrame()
        if frame then
            local showOnlyInCombat = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showOnlyInCombat
            local inCombat = UnitAffectingCombat("player")
            local state = HHT_AutoShot_GetState()
            if showOnlyInCombat and not inCombat and not (state and state.isShooting) and not HHT_Core.previewMode then
                frame:Hide()
            end
        end
        -- PERFORMANCE: Check if OnUpdate should be disabled
        HHT_AutoShot_CheckOnUpdateState()
        return
    end
    
    local percent = elapsed / duration
    local maxWidth = CastbarState.castFrame:GetWidth() - 4
    local width = math.max(1, maxWidth * percent)
    
    CastbarState.castBarFrame:SetWidth(width)
    CastbarState.castBarText:SetText(CastbarState.castSpellName)
    if HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showTimerText then
        CastbarState.castBarTextTime:SetText(string.format("%.2fs/%.2fs", elapsed, duration))
    else
        CastbarState.castBarTextTime:SetText("")
    end
end

-- ============ Start Cast ============
StartCast = function(spellName, castTime)
    -- SuperWoW: Skip old cast detection - we use UNIT_CASTEVENT instead
    if HAS_SUPERWOW and PLAYER_GUID then
        return
    end
    
    if not HHT_Core.isCasting then
        HHT_Core.isCasting = true
        CastbarState.castSpellName = spellName
        CastbarState.castStartTime = GetTime()
        CastbarState.castEndTime = CastbarState.castStartTime + castTime
        
        -- Only track statistics if stats frame is enabled
        local trackStats = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showStats
        
        -- Get AutoShot state for stats tracking
        local asState = HHT_AutoShot_GetState()
        
        -- Track reaction time if auto-shot was fired recently
        if trackStats and asState and asState.lastAutoShotTime and asState.lastAutoShotTime > 0 then
            local reactionTime = CastbarState.castStartTime - asState.lastAutoShotTime
            -- Only track if cast started within 3 seconds of auto-shot
            if reactionTime > 0 and reactionTime < 3.0 then
                table.insert(reactionTimes, reactionTime)
                -- Keep only last MAX_REACTION_SAMPLES
                if table.getn(reactionTimes) > MAX_REACTION_SAMPLES then
                    table.remove(reactionTimes, 1)
                end
                -- Reset to prevent counting multiple casts after one auto-shot
                HHT_AutoShot_ResetReactionTracking()
            end
        end
        
        -- Track skipped auto-shots (only between Steady Shots)
        local isSteadyShot = spellName and (string.find(spellName, "Steady Shot") or string.find(spellName, "Stetiger Schuss"))
        if trackStats and isSteadyShot then
            if lastCastTime > 0 and (CastbarState.castStartTime - lastCastTime) < 10 then
                totalCastSequences = totalCastSequences + 1
                if asState and not asState.autoShotBetweenCasts then
                    skippedAutoShots = skippedAutoShots + 1
                end
            end
            lastCastTime = CastbarState.castStartTime
            -- Reset for next sequence
            HHT_AutoShot_ResetAutoShotBetweenCasts()
        end
        
        -- Track delayed auto-shots (yellow bar reset by cast, not movement)
        local state = HHT_AutoShot_GetState()
        if trackStats and state and state.timeReloadStart and state.timeReloadStart > 0 then
            local reloadDuration = state.weaponSpeed - AIMING_TIME
            local castEndTime = CastbarState.castStartTime + castTime
            local elapsed = GetTime() - state.timeReloadStart
            
            -- Yellow phase: from reload complete to shoot complete
            local yellowPhaseStart = reloadDuration
            local yellowPhaseEnd = state.weaponSpeed
            
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
        
        if CastbarState.castFrame and HamingwaysHunterToolsDB.showCastbar then
            CastbarState.castFrame:Show()
        end
        -- PERFORMANCE: Enable main OnUpdate for frame visibility updates during cast
        HHT_AutoShot_EnableOnUpdate()
        -- Also show main frame when casting starts
        local frame = HHT_AutoShot_GetFrame()
        if frame and HamingwaysHunterToolsDB.showAutoShotTimer then
            local showOnlyInCombat = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showOnlyInCombat
            local inCombat = UnitAffectingCombat("player")
            local state = HHT_AutoShot_GetState()
            if not showOnlyInCombat or inCombat or HHT_Core.previewMode or (state and state.isShooting) or HHT_Core.isCasting then
                frame:Show()
            end
        end
    end
end

-- ============ Spell Finding Functions ============
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
        if spellTexture == texture and HHT_castSpells[name] then
            return name
        end
        i = i + 1
    end
end

-- ============ Cast Detection ============
-- Handle cast attempt (validates cast is actually happening)
HandleCastAttempt = function(spellName, isCurrentAction)
    if not spellName or not HHT_castSpells[spellName] then return end
    
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

-- ============ Frame Creation ============
function HHT_Castbar_CreateFrame(castFrame)
    CastbarState.castFrame = castFrame
    
    local cfg = GetDB()
    CastbarState.castBarFrame = castFrame:CreateTexture(nil, "BORDER")
    CastbarState.castBarFrame:SetPoint("TOPLEFT", castFrame, "TOPLEFT", 2, -2)
    CastbarState.castBarFrame:SetHeight(castFrame:GetHeight() -4)
    CastbarState.castBarFrame:SetWidth(1)
    CastbarState.castBarFrame:SetTexture(cfg.barStyle or "Interface\\TargetingFrame\\UI-StatusBar")
    -- Use castColor from settings (or fallback to blue)
    local castColor = cfg.castColor or {r=0.5, g=0.5, b=1}
    CastbarState.castBarFrame:SetVertexColor(castColor.r, castColor.g, castColor.b, BAR_ALPHA)
    
    CastbarState.castBarText = castFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    CastbarState.castBarText:SetPoint("CENTER", castFrame, "CENTER", 0, 0)
    CastbarState.castBarText:SetTextColor(1, 1, 1, 1)
    CastbarState.castBarText:SetText("")
    
    CastbarState.castBarTextTime = castFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    CastbarState.castBarTextTime:SetPoint("LEFT", castFrame, "RIGHT", 5, 0)
    CastbarState.castBarTextTime:SetTextColor(1, 1, 1, 1)
    CastbarState.castBarTextTime:SetText("")
end

-- ============ SuperWoW UNIT_CASTEVENT Handler ============
function HHT_Castbar_HandleUnitCastEvent()
    -- UNIT_CASTEVENT args: casterGUID, targetGUID, eventType, spellID, castDuration
    local casterGUID = arg1
    local targetGUID = arg2
    local eventType = arg3
    local spellID = arg4
    local castDurationMS = arg5  -- Cast duration in milliseconds (if available)
    
    -- Filter: Only react to player events
    if not PLAYER_GUID or casterGUID ~= PLAYER_GUID then
        return
    end
    
    -- DEBUG: Show player events
    if HHT_DEBUG then
        DEFAULT_CHAT_FRAME:AddMessage("[PLAYER Event] type=" .. tostring(eventType) .. " | spellID=" .. tostring(spellID), 0, 1, 1)
    end
    
    -- Auto-learn spell names (always, not just in debug mode)
    local spellName = KNOWN_SPELL_NAMES[spellID]
    if not spellName and SpellInfo then
        -- SuperWoW: SpellInfo(spellid) returns: name, rank, texture, minrange, maxrange
        local name, rank = SpellInfo(spellID)
        if name and type(name) == "string" and name ~= "" then
            spellName = name
            if rank and rank ~= "" then
                spellName = name .. " (" .. rank .. ")"
            end
            -- Cache the spell name for next time (performance!)
            KNOWN_SPELL_NAMES[spellID] = spellName
        end
    end
    
    -- SuperWoW: Check for Auto Shot (ID 75) - maximum efficiency!
    if spellID == 75 and eventType == "CAST" then
        HHT_AutoShot_OnShotFired()
        return
    end
    
    -- SuperWoW: Check for MAINHAND melee swing
    if eventType == "MAINHAND" then
        if HHT_DEBUG then
            DEFAULT_CHAT_FRAME:AddMessage("  -> MAINHAND swing detected!", 1, 0.7, 0.2)
        end
        HHT_AutoShot_OnMeleeSwing()
        return
    end
    
    -- SuperWoW: Track cast spells dynamically (Aimed Shot, Multi-Shot, Steady Shot, etc.)
    if eventType == "START" and castDurationMS and castDurationMS > 0 then
        -- Cast started - NOTE: castDurationMS is BASE duration WITHOUT haste!
        -- The actual cast will finish earlier with haste buffs
        HHT_Core.isCasting = true
        CastbarState.castSpellID = spellID  -- Track which spell we're casting
        CastbarState.castStartTime = GetTime()
        CastbarState.castDuration = castDurationMS / 1000  -- Convert ms to seconds (base duration)
        CastbarState.castEndTime = CastbarState.castStartTime + CastbarState.castDuration
        local spellName = KNOWN_SPELL_NAMES[spellID] or ("Spell " .. spellID)
        CastbarState.castSpellName = spellName
        
        -- Only track statistics if stats frame is enabled
        local trackStats = HamingwaysHunterToolsDB and HamingwaysHunterToolsDB.showStats
        
        -- Get AutoShot state for stats tracking
        local asState = HHT_AutoShot_GetState()
        
        -- Track reaction time if auto-shot was fired recently
        if trackStats and asState and asState.lastAutoShotTime and asState.lastAutoShotTime > 0 then
            local reactionTime = CastbarState.castStartTime - asState.lastAutoShotTime
            -- Only track if cast started within 3 seconds of auto-shot
            if reactionTime > 0 and reactionTime < 3.0 then
                table.insert(reactionTimes, reactionTime)
                -- Keep only last MAX_REACTION_SAMPLES
                if table.getn(reactionTimes) > MAX_REACTION_SAMPLES then
                    table.remove(reactionTimes, 1)
                end
                -- Reset to prevent counting multiple casts after one auto-shot
                HHT_AutoShot_ResetReactionTracking()
            end
        end
        
        -- Track skipped auto-shots (only between Steady Shots)
        local isSteadyShot = spellName and (string.find(spellName, "Steady Shot") or string.find(spellName, "Stetiger Schuss"))
        if trackStats and isSteadyShot then
            if lastCastTime > 0 and (CastbarState.castStartTime - lastCastTime) < 10 then
                totalCastSequences = totalCastSequences + 1
                if asState and not asState.autoShotBetweenCasts then
                    skippedAutoShots = skippedAutoShots + 1
                end
            end
            lastCastTime = CastbarState.castStartTime
            -- Reset for next sequence
            HHT_AutoShot_ResetAutoShotBetweenCasts()
        end
        
        -- Track delayed auto-shots (yellow bar reset by cast, not movement)
        if trackStats and asState and asState.timeReloadStart and asState.timeReloadStart > 0 then
            local reloadDuration = asState.weaponSpeed - AIMING_TIME
            local castEndTime = CastbarState.castStartTime + CastbarState.castDuration
            local elapsed = GetTime() - asState.timeReloadStart
            
            -- Yellow phase: from reload complete to shoot complete
            local yellowPhaseStart = reloadDuration
            local yellowPhaseEnd = asState.weaponSpeed
            
            -- Check if cast overlaps with yellow phase
            local castStartsAt = elapsed
            local castEndsAt = elapsed + CastbarState.castDuration
            local castOverlapsYellow = (castStartsAt < yellowPhaseEnd) and (castEndsAt >= yellowPhaseStart)
            
            if castOverlapsYellow then
                -- Calculate the delay
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
        
        -- Show cast frame and cast bar
        if CastbarState.castFrame then
            CastbarState.castFrame:Show()
            if HHT_DEBUG then
                DEFAULT_CHAT_FRAME:AddMessage("    [DEBUG] castFrame:Show() called", 0.5, 0.5, 0.5)
            end
        else
            if HHT_DEBUG then
                DEFAULT_CHAT_FRAME:AddMessage("    [ERROR] castFrame is nil!", 1, 0, 0)
            end
        end
        if CastbarState.castBarFrame then
            CastbarState.castBarFrame:Show()
        end
        -- PERFORMANCE: Enable main OnUpdate for frame visibility updates during cast
        HHT_AutoShot_EnableOnUpdate()
        if HHT_DEBUG then
            DEFAULT_CHAT_FRAME:AddMessage("  -> Cast started: " .. CastbarState.castSpellName .. " (ID " .. spellID .. ", base: " .. string.format("%.2f", CastbarState.castDuration) .. "s)", 1, 0.8, 0)
        end
    elseif eventType == "CAST" then
        -- Cast finished - but ONLY if it's the same spell we're casting!
        -- (Quick Shots buff proc also sends CAST event - ignore it!)
        if HHT_Core.isCasting and spellID == CastbarState.castSpellID then
            local actualDuration = GetTime() - CastbarState.castStartTime
            HHT_Core.isCasting = false
            CastbarState.castSpellID = 0
            HHT_Core.lastCastEndTime = GetTime()
            if CastbarState.castFrame then
                CastbarState.castFrame:Hide()
            end
            if CastbarState.castBarFrame then
                CastbarState.castBarFrame:Hide()
            end
            -- PERFORMANCE: Check if OnUpdate should be disabled
            HHT_AutoShot_CheckOnUpdateState()
            if HHT_DEBUG then
                DEFAULT_CHAT_FRAME:AddMessage("  -> Cast finished: " .. CastbarState.castSpellName .. " (ID " .. spellID .. ", actual: " .. string.format("%.3f", actualDuration) .. "s)", 0, 1, 0.5)
            end
        elseif HHT_DEBUG and not BUFF_PROC_SPELLS[spellID] then
            -- Ignore buff procs, but show other mismatches
            DEFAULT_CHAT_FRAME:AddMessage("  -> Ignoring CAST event for ID " .. spellID .. " (currently casting: " .. (CastbarState.castSpellID or "none") .. ")", 0.7, 0.7, 0.7)
        end
    elseif eventType == "FAIL" then
        -- Cast interrupted - abort ANY active cast (movement/damage may send different spellID)
        if HHT_Core.isCasting then
            local interruptedAt = GetTime() - CastbarState.castStartTime
            local interruptedSpellName = CastbarState.castSpellName
            HHT_Core.isCasting = false
            CastbarState.castSpellID = 0
            HHT_Core.lastCastEndTime = GetTime()
            if CastbarState.castFrame then
                CastbarState.castFrame:Hide()
            end
            if CastbarState.castBarFrame then
                CastbarState.castBarFrame:Hide()
            end
            -- PERFORMANCE: Check if OnUpdate should be disabled
            HHT_AutoShot_CheckOnUpdateState()
            if HHT_DEBUG then
                DEFAULT_CHAT_FRAME:AddMessage("  -> Cast FAILED: " .. interruptedSpellName .. " (FAIL ID " .. spellID .. ", interrupted at " .. string.format("%.3f", interruptedAt) .. "s)", 1, 0, 0)
            end
        end
    end
end

-- ============ Public API Functions ============
function HHT_Castbar_UpdateCastbar()
    UpdateCastbar()
end

function HHT_Castbar_AbortCast()
    if HHT_Core.isCasting then
        -- CRITICAL: Actually stop the cast on the server, not just hide the bar!
        SpellStopCasting()
        
        HHT_Core.isCasting = false
        CastbarState.castSpellID = 0
        HHT_Core.lastCastEndTime = GetTime()
        if CastbarState.castFrame then
            CastbarState.castFrame:Hide()
        end
        if CastbarState.castBarFrame then
            CastbarState.castBarFrame:Hide()
        end
        if HHT_DEBUG then
            DEFAULT_CHAT_FRAME:AddMessage("[Castbar] Cast aborted with SpellStopCasting()", 1, 0.5, 0)
        end
    end
end

function HHT_Castbar_InitNotifyCastAutoAPI()
    HamingwaysHunterTools_API.NotifyCastAuto = function(spellName)
        if not spellName or not HHT_castSpells[spellName] then 
            return false 
        end
        local castTime = CalcCastTime(spellName)
        if castTime and castTime >= 0 then  -- Changed: Allow instant casts (castTime = 0)
            StartCast(spellName, castTime)
            return true
        end
        return false
    end
end

function HHT_Castbar_GetFrame()
    return CastbarState.castFrame
end

function HHT_Castbar_GetBarFrame()
    return CastbarState.castBarFrame
end

function HHT_Castbar_ShowPreview(frameWidth, showTimerText)
    if not CastbarState.castFrame or not CastbarState.castBarFrame or not CastbarState.castBarText or not CastbarState.castBarTextTime then return end
    
    CastbarState.castFrame:Show()
    CastbarState.castBarFrame:SetWidth((frameWidth - 4) * 0.6)
    CastbarState.castBarText:SetText("Aimed Shot")
    if showTimerText then
        CastbarState.castBarTextTime:SetText("1.80s/3.00s")
    else
        CastbarState.castBarTextTime:SetText("")
    end
end

function HHT_Castbar_HideBarText()
    if CastbarState.castBarText and CastbarState.castBarTextTime then
        CastbarState.castBarText:SetText("")
        CastbarState.castBarTextTime:SetText("")
    end
end

function HHT_Castbar_ApplySettings()
    local db = GetDB()
    if not db or not CastbarState.castBarFrame then return end
    
    -- Update bar texture and color
    CastbarState.castBarFrame:SetTexture(db.barStyle or "Interface\\TargetingFrame\\UI-StatusBar")
    -- Use castColor from settings (or fallback to blue)
    local castColor = db.castColor or {r=0.5, g=0.5, b=1}
    CastbarState.castBarFrame:SetVertexColor(castColor.r, castColor.g, castColor.b, BAR_ALPHA)
    
    -- Update bar height if frame size changed
    if CastbarState.castFrame then
        CastbarState.castBarFrame:SetHeight(CastbarState.castFrame:GetHeight() - 4)
    end
end

function HHT_Castbar_StartCast(spellName, castTime)
    StartCast(spellName, castTime)
end

-- ============ Module Initialization ============
CastbarModule:SetScript("OnEvent", function()
    -- Module loaded
end)

CastbarModule:RegisterEvent("PLAYER_LOGIN")
