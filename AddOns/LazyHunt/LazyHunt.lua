-- LazyHunt - Hunter Rotation Addon for WoW Vanilla 1.12 (Turtle WoW)
-- Version: 4.0.0 - Frame-based architecture (uses HHT timing engine)
-- Author: Copilot

local VERSION = "4.0.0"

-- Global flag to indicate addon is fully loaded and ready
LazyHunt_IsLoaded = false

-- Global action variable (set by frame, executed by macro)
LazyHunt_NextAction = "NONE"  -- "NONE", "STEADY", "MULTI"

-- Saved Variables
LazyHuntDB = LazyHuntDB or {
    minimapPos = 225,
    burstEnabled = false,
    burstSunderStacks = 0,
    waitForBurstCD = false,
    burstCDThreshold = 5,
    burstButtonX = 0,
    burstButtonY = 200,
    multiShotEnabled = true,
    multiButtonX = 0,
    multiButtonY = 160,
    allowedASDelay = 0.0,
}

-- State Machine
local STEP_INIT = "INIT"
local STEP_WORK = "WORK"
local currentStep = STEP_INIT

local ROTA_DO_NOTHING = "DO_NOTHING"
local ROTA_DO_MULTI = "DO_MULTI"
local ROTA_DO_STEADY = "DO_STEADY"
local ROTA_WAITING_FOR_STEADY = "WAITING_FOR_STEADY"  -- After Steady cast, check if Multi fits next
local currentRotaStep = ROTA_DO_NOTHING

-- Rotation state
local debugMode = false
local shouldCastMultiInsteadOfSteady = false  -- Flag: Cast Multi instead of Steady this cycle
local decisionMadeInYellow = false  -- Flag: Decision already made in Yellow Phase (reset in Red Phase)
local doBurst = false
local stopCast = false

-- Cached spell IDs
local cachedSteadyID, cachedSteadyName = nil, nil
local cachedMultiID, cachedMultiName = nil, nil
local cachedRapidFireID = nil
local isShooting_old = false

-- Cache spell lookups
local function CacheSpellIDs()
    local i = 1
    while true do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        
        if (name == "Steady Shot" or name == "Stetiger Schuss") and not cachedSteadyID then
            cachedSteadyID = i
            cachedSteadyName = name
        elseif (name == "Multi-Shot" or name == "Mehrfachschuss") and not cachedMultiID then
            cachedMultiID = i
            cachedMultiName = name
        elseif name == "Rapid Fire" and not cachedRapidFireID then
            cachedRapidFireID = i
        end
        
        if cachedSteadyID and cachedMultiID and cachedRapidFireID then
            break
        end
        
        i = i + 1
    end
end

-- Options log display
local function ShowNotification(message)
    if LazyHuntOptionsFrame and LazyHuntOptionsFrame.logDisplay then
        LazyHuntOptionsFrame.logDisplay:SetText(message)
    end
end

-- ============================================================================
-- BURST MODE
-- ============================================================================
local function GetSunderArmorStacks()
    local i = 1
    while UnitDebuff("target", i) do
        local texture = UnitDebuff("target", i)
        if texture and string.find(texture, "Ability_Warrior_Sunder") then
            return i
        end
        i = i + 1
    end
    return 0
end

local function TryBurst()
    if not LazyHuntDB.burstEnabled then return false end
    if not UnitAffectingCombat("player") then return false end
    if not UnitExists("target") or UnitIsDead("target") then return false end
    
    local requiredStacks = LazyHuntDB.burstSunderStacks or 0
    if requiredStacks > 0 and GetSunderArmorStacks() < requiredStacks then
        return false
    end
    
    -- Use cached Rapid Fire ID (no spell book iteration)
    local rapidFireReady = false
    local rapidFireCD = 999
    if cachedRapidFireID then
        local rapidFireStart, rapidFireDuration = GetSpellCooldown(cachedRapidFireID, BOOKTYPE_SPELL)
        rapidFireCD = (rapidFireStart > 0 and (rapidFireStart + rapidFireDuration - GetTime()) > 1.5) and (rapidFireStart + rapidFireDuration - GetTime()) or 0
        rapidFireReady = rapidFireCD == 0
    end
    
    -- Check trinket slot 13
    local trinket13Ready = false
    local trinket13CD = 999
    local start13, duration13 = GetInventoryItemCooldown("player", 13)
    if start13 then
        trinket13CD = (start13 > 0 and (start13 + duration13 - GetTime()) > 1.5) and (start13 + duration13 - GetTime()) or 0
        trinket13Ready = trinket13CD == 0
    end
    
    -- Check trinket slot 14
    local trinket14Ready = false
    local trinket14CD = 999
    local start14, duration14 = GetInventoryItemCooldown("player", 14)
    if start14 then
        trinket14CD = (start14 > 0 and (start14 + duration14 - GetTime()) > 1.5) and (start14 + duration14 - GetTime()) or 0
        trinket14Ready = trinket14CD == 0
    end
    
    -- At least one ability must be ready
    if not rapidFireReady and not trinket13Ready and not trinket14Ready then
        return false
    end
    
    -- If "Wait for burst CD" is enabled, check if we should wait
    if LazyHuntDB.waitForBurstCD then
        local threshold = LazyHuntDB.burstCDThreshold or 5
        
        -- Check if any ability is ready but others are close to ready
        if rapidFireReady or trinket13Ready or trinket14Ready then
            -- Find the highest CD among abilities that are not ready
            local maxCD = 0
            if not rapidFireReady and rapidFireCD < 999 then
                maxCD = math.max(maxCD, rapidFireCD)
            end
            if not trinket13Ready and trinket13CD < 999 then
                maxCD = math.max(maxCD, trinket13CD)
            end
            if not trinket14Ready and trinket14CD < 999 then
                maxCD = math.max(maxCD, trinket14CD)
            end
            
            -- If any ability is within threshold, wait for it
            if maxCD > 0 and maxCD <= threshold then
                return false
            end
        end
    end
    
    -- All conditions met - activate burst!
    if rapidFireReady then
        doBurst = true
    end
    
    if trinket13Ready then
        doBurst = true
    end
    
    if trinket14Ready then
        doBurst = true
    end
 
    return true

end

-- ============================================================================
-- FRAME-BASED ROTATION ENGINE (uses HHT timing)
-- ============================================================================
local rotationFrame = CreateFrame("Frame")

rotationFrame:SetScript("OnUpdate", function()
    -- Init check
    if currentStep == STEP_INIT then
        if not LazyHunt_IsLoaded then return end
        if not HamingwaysHunterTools_API then return end
        if not cachedSteadyID or not cachedMultiID then
            CacheSpellIDs()
            return
        end
        
        -- We can jump to Work after Init
        currentStep = STEP_WORK

        return
    end
    
    -- Work: Main rotation logic
    if currentStep == STEP_WORK then
	
        -- ====================================================================
        -- WORK: Main rotation logic
        -- ====================================================================
        
        -- Get basic state
		local isInYellowPhase = HamingwaysHunterTools_API.IsInYellowPhase()
        local isInRedPhase = HamingwaysHunterTools_API.IsInRedPhase()
        local isShooting = HamingwaysHunterTools_API.IsShooting() or isInYellowPhase or isInRedPhase
		
		
		--if isShooting ~= isShooting_old then
		--	DEFAULT_CHAT_FRAME:AddMessage("" .. tostring(isShooting))
		--	DEFAULT_CHAT_FRAME:AddMessage("red" .. tostring(isInRedPhase))
		--	DEFAULT_CHAT_FRAME:AddMessage("yellow" .. tostring(isInYellowPhase))
		--	isShooting_old = isShooting
		--end
        
        -- If not shooting or no target, cancel all casts and reset rotation
        if not isShooting or not UnitExists("target") or UnitIsDead("target") then
				LazyHunt_NextAction = "NONE"
				decisionMadeInYellow = false
                --if isShooting_old then stopCast = true end
                currentRotaStep = ROTA_DO_NOTHING
                shouldCastMultiInsteadOfSteady = false
                -- DebugRotaStepChange(currentRotaStep)  -- DISABLED
				
            return
        end
        --isShooting_old = isShooting
		
		--DEFAULT_CHAT_FRAME:AddMessage("" .. tostring(isInYellowPhase))
		
		local now = GetTime()
        
        --local isInYellowPhase = HamingwaysHunterTools_API.IsInYellowPhase()
        --local isInRedPhase = HamingwaysHunterTools_API.IsInRedPhase()
        
        -- ================================================================
        -- YELLOW PHASE: Decision logic
        -- ================================================================
        if isInYellowPhase then
		
			--DEFAULT_CHAT_FRAME:AddMessage("  yellow ")
		
			-- CRITICAL: If decision already made, do nothing (prevent re-triggering)
            if decisionMadeInYellow then 
				return 
			end
            
            -- If we have a rotation step and are still casting, wait for cast to finish
            if currentRotaStep ~= ROTA_DO_NOTHING and HamingwaysHunterTools_API.IsCasting() then
                return  -- Still casting, wait
            end
            
            -- Clean up old step if present (cast has finished or never started)
            if currentRotaStep ~= ROTA_DO_NOTHING then
                currentRotaStep = ROTA_DO_NOTHING
                -- DebugRotaStepChange(currentRotaStep)  -- DISABLED
            end
            
            -- Decide what to cast (only if DO_NOTHING and decision not yet made)
            if currentRotaStep == ROTA_DO_NOTHING and not decisionMadeInYellow then

                if not HamingwaysHunterTools_API.IsCasting() then
                    -- Try burst before making decision
                    TryBurst()
                    
					-- if we should do multi instead of steady and multi is enabled
                    if shouldCastMultiInsteadOfSteady and LazyHuntDB.multiShotEnabled then
                        currentRotaStep = ROTA_DO_MULTI
                        DEFAULT_CHAT_FRAME:AddMessage("  yedo multi " .. tostring(LazyHuntDB.multiShotEnabled))
						shouldCastMultiInsteadOfSteady = false
					-- do steady
                    else
                        currentRotaStep = ROTA_DO_STEADY
                        DEFAULT_CHAT_FRAME:AddMessage("  yedo steady " .. tostring(LazyHuntDB.steadyShotEnabled))
                    end
                    -- DebugRotaStepChange(currentRotaStep)  -- DISABLED
                    
                    -- Mark decision as made
                    decisionMadeInYellow = true
					LazyHunt_NextAction = "NONE"
                end
            end
            return
        end
        
        -- ================================================================
        -- RED PHASE: Execution logic
        -- ================================================================
        if isInRedPhase then
		
			-- Reset decision flag (allow new decision in next Yellow Phase)
            decisionMadeInYellow = false
            
            -- Check if auto shot still active
            local currentAutoShotTime = HamingwaysHunterTools_API.GetLastShotTime()
           
            -- ============================================================
            -- DO NOTHING
            -- ============================================================
            if currentRotaStep == ROTA_DO_NOTHING then
                -- Do nothing, wait for yellow phase decision
                return
            
			-- ============================================================
            -- DO MULTI
            -- ============================================================			
            elseif currentRotaStep == ROTA_DO_MULTI then

				-- Check CanMultiFit()
				local elapsed = now - currentAutoShotTime
				-- Use Base Speed for red phase (not affected by haste)
				local redPhaseEnd = HamingwaysHunterTools_API.GetBaseWeaponSpeed() - HamingwaysHunterTools_API.GetAimingTime()
				local timeLeftInRed = redPhaseEnd - elapsed
				
				local start, duration = GetSpellCooldown(cachedMultiID, BOOKTYPE_SPELL)
				local multiCD = 0
				if start and start > 0 then
					multiCD = duration - (now - start)
					if multiCD < 0 then multiCD = 0 end
				end
				
				local multiTotalTime = 1.5 + multiCD
				
				if multiTotalTime < timeLeftInRed then
					-- Cast Multi
					-- Tell Macro what to cast
					LazyHunt_NextAction = "MULTI"
					-- Finished
					currentRotaStep = ROTA_DO_NOTHING
				else
					-- Tell Macro what to cast
					LazyHunt_NextAction = "STEADY"
					-- next Step
					currentRotaStep = ROTA_DO_STEADY
				end
                
                -- DebugRotaStepChange(currentRotaStep)  -- DISABLED
                return
            
			-- ============================================================
            -- DO STEADY
            -- ============================================================
            elseif currentRotaStep == ROTA_DO_STEADY then
			
                -- Cast Steady Shot once (will queue if GCD active)
                -- Tell Macro what to cast
				LazyHunt_NextAction = "STEADY"
                
                -- Verify cast started before transitioning
                if HamingwaysHunterTools_API.IsCasting() then
					-- next step
					if LazyHuntDB.multiShotEnabled then
						currentRotaStep = ROTA_DO_MULTIAFTERSTEADY
					else
						currentRotaStep = ROTA_DO_NOTHING
					end
					
                    -- DebugRotaStepChange(currentRotaStep)  -- DISABLED
                end
                return
            
			-- ============================================================
            -- DO MULTI AFTER STEADY
            -- ============================================================
            elseif currentRotaStep == ROTA_DO_MULTIAFTERSTEADY then
                -- First: Check if Steady is still casting
                if HamingwaysHunterTools_API.IsCasting() then
					return
				end
                
                -- Check if Multi-Shot is ready (CD check first, before any calculations)             
                local start, duration = GetSpellCooldown(cachedMultiID, BOOKTYPE_SPELL)
                local isMultiReady = (not start or start == 0 or duration <= 1.5)
                
                if not isMultiReady then
                    -- Multi not ready, go back to DO_NOTHING
                    currentRotaStep = ROTA_DO_NOTHING
                    -- DebugRotaStepChange(currentRotaStep)  -- DISABLED
                    return
                end
                
                -- Multi is ready, now do fit calculations
				                
                -- Check if we can cast Multi after Steady
                local elapsed = now - currentAutoShotTime
                -- Use Base Speed for red phase (not affected by haste)
                local redPhaseEnd = HamingwaysHunterTools_API.GetBaseWeaponSpeed() - HamingwaysHunterTools_API.GetAimingTime()
                local timeLeftInRed = redPhaseEnd - elapsed
                
                local multiGCD = 1.5
                local yellowPhase = HamingwaysHunterTools_API.GetAimingTime()
                -- Steady Shot cast time adjusted by haste multiplier
                local steadyBaseCast = 1.0 * (HamingwaysHunterTools_API.GetBaseWeaponSpeed() / 2.0)
                local steadyCastDuration = steadyBaseCast * HamingwaysHunterTools_API.GetHasteMultiplier()
                
                -- Calculate GCD remaining after auto shot fires
                local gcdRemainingAfterAutoShot = multiGCD - (timeLeftInRed + yellowPhase)
                if gcdRemainingAfterAutoShot < 0 then gcdRemainingAfterAutoShot = 0 end
                
                -- Check: Can Steady finish in next red phase?
                
                if ((gcdRemainingAfterAutoShot + steadyCastDuration) < (redPhaseEnd + LazyHuntDB.allowedASDelay)) then
                    -- Steady fits next cycle, so reset flag and cast Multi now
                    shouldCastMultiInsteadOfSteady = false
                    currentRotaStep = ROTA_DO_NOTHING
                    -- DebugRotaStepChange(currentRotaStep)  -- DISABLED
                    -- Tell Macro what to cast
					LazyHunt_NextAction = "MULTI"
                else
                    -- Steady won't fit next cycle - set flag for next yellow decision
                    shouldCastMultiInsteadOfSteady = true
                    currentRotaStep = ROTA_DO_NOTHING
                    -- DebugRotaStepChange(currentRotaStep)  -- DISABLED
                end
                
                return
            end
        end
    end
end)

-- ============================================================================
-- MACRO EXECUTOR FUNCTION (called from macro)
-- ============================================================================
function LazyHunt_ExecuteAction()

	-- we should do nothing
	if LazyHunt_NextAction == "NONE" then
        -- stop current cast if needed
        --if stopCast then
        --    SpellStopCasting()
        --   stopCast = false
        --end
		-- nothing to do :)
		return
		
	elseif doBurst then
    
        if cachedRapidFireID then
			CastSpell(cachedRapidFireID, BOOKTYPE_SPELL)
		end 
        UseInventoryItem(13)
        UseInventoryItem(14)
    
		doBurst = false
		
	-- we should do steady
    elseif LazyHunt_NextAction == "STEADY" then
        CastSpellByName(cachedSteadyName)
		-- spam until game is casting
		--if HamingwaysHunterTools_API.IsCasting() then
			-- job finished
			LazyHunt_NextAction = "NONE" 
		--end

	-- we should do multi
    elseif LazyHunt_NextAction == "MULTI" then
        HamingwaysHunterTools_API.NotifyCast(cachedMultiName, 0.5)
        CastSpellByName(cachedMultiName)
        -- spam until game is casting
		--if HamingwaysHunterTools_API.IsCasting() then
			-- job finished
			LazyHunt_NextAction = "NONE" 
		--end
    end

end

-- Keep old function for compatibility
LazyHunt_DoRotation = LazyHunt_ExecuteAction

-- ============================================================================
-- EVENT HANDLER
-- ============================================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "LazyHunt" then
        LazyHuntDB = LazyHuntDB or {}
        
        -- Apply defaults for missing values
        if LazyHuntDB.minimapPos == nil then LazyHuntDB.minimapPos = 225 end
        if LazyHuntDB.burstEnabled == nil then LazyHuntDB.burstEnabled = false end
        if LazyHuntDB.burstSunderStacks == nil then LazyHuntDB.burstSunderStacks = 0 end
        if LazyHuntDB.waitForBurstCD == nil then LazyHuntDB.waitForBurstCD = false end
        if LazyHuntDB.burstCDThreshold == nil then LazyHuntDB.burstCDThreshold = 5 end
        if LazyHuntDB.burstButtonX == nil then LazyHuntDB.burstButtonX = 0 end
        if LazyHuntDB.burstButtonY == nil then LazyHuntDB.burstButtonY = 200 end
        if LazyHuntDB.multiShotEnabled == nil then LazyHuntDB.multiShotEnabled = true end
        if LazyHuntDB.multiButtonX == nil then LazyHuntDB.multiButtonX = 0 end
        if LazyHuntDB.multiButtonY == nil then LazyHuntDB.multiButtonY = 160 end
        if LazyHuntDB.allowedASDelay == nil then LazyHuntDB.allowedASDelay = 0.0 end
        
        currentStep = STEP_INIT
        currentRotaStep = ROTA_DO_NOTHING
        decisionMadeInYellow = false
        shouldCastMultiNextCycle = false
        steadyWasCasted = false
        
        CacheSpellIDs()
        LazyHunt_IsLoaded = true
        
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00LazyHunt v" .. VERSION .. " loaded! (Frame-based)|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00Macro: /script LazyHunt_ExecuteAction()|r")
    end
end)

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================
local function SlashCommandHandler(msg)
    msg = string.lower(msg or "")
    
    if msg == "help" or msg == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00LazyHunt|r v" .. VERSION .. " (Frame-based)")
        DEFAULT_CHAT_FRAME:AddMessage("Makro: |cFFFFFF00/script LazyHunt_ExecuteAction()|r")
        DEFAULT_CHAT_FRAME:AddMessage("Befehle: /lh reset, /lh status, /lh debug")
    elseif msg == "debug" then
        debugActions = not debugActions
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00LazyHunt:|r Debug " .. (debugActions and "AN" or "AUS"))
    elseif msg == "reset" then
        currentStep = STEP_INIT
        currentRotaStep = ROTA_DO_NOTHING
        decisionMadeInYellow = false
        shouldCastMultiNextCycle = false
        steadyWasCasted = false
        LazyHunt_NextAction = "NONE"
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00LazyHunt:|r State reset")
    elseif msg == "status" then
        if HamingwaysHunterTools_API then
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00LazyHunt Status:|r")
            DEFAULT_CHAT_FRAME:AddMessage("  Shooting: " .. tostring(HamingwaysHunterTools_API.IsShooting()))
            DEFAULT_CHAT_FRAME:AddMessage("  Red Phase: " .. tostring(HamingwaysHunterTools_API.IsInRedPhase()))
            DEFAULT_CHAT_FRAME:AddMessage("  Yellow Phase: " .. tostring(HamingwaysHunterTools_API.IsInYellowPhase()))
            DEFAULT_CHAT_FRAME:AddMessage("  Next Action: " .. tostring(LazyHunt_NextAction))
            DEFAULT_CHAT_FRAME:AddMessage("  Base Weapon Speed: " .. string.format("%.2f", HamingwaysHunterTools_API.GetBaseWeaponSpeed()))
            DEFAULT_CHAT_FRAME:AddMessage("  Current Speed: " .. string.format("%.2f", HamingwaysHunterTools_API.GetWeaponSpeed()))
            DEFAULT_CHAT_FRAME:AddMessage("  Haste Multiplier: " .. string.format("%.3f", HamingwaysHunterTools_API.GetHasteMultiplier()))
			DEFAULT_CHAT_FRAME:AddMessage("  lastAutoShotTime: " .. string.format("%.2f", HamingwaysHunterTools_API.GetLastShotTime()))
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000LazyHunt: HHT not loaded!|r")
        end
    end
end

SLASH_LAZYHUNT1 = "/lazyhunt"
SLASH_LAZYHUNT2 = "/lh"
SlashCmdList["LAZYHUNT"] = SlashCommandHandler

DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00LazyHunt|r v" .. VERSION .. " ready. Type /lh help")
