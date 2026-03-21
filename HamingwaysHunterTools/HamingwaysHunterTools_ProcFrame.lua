-- HamingwaysHunterTools_ProcFrame.lua
-- Proc Frame Module
-- Displays active hunter procs relevant to rotation (Turtle WoW 1.18.1+)
-- Tracks: Lock and Load, Experimental Ammunition variants
-- Requires: SuperWoW (for GetPlayerBuffTimeLeft accurate timer)

print("[HHT] Loading ProcFrame.lua")

-- Module frame
local ProcModule = CreateFrame("Frame", "HamingwaysHunterToolsProcModule")

-- ============ ALL State in ONE table to avoid upvalue limit ============
local ProcState = {
    -- Frame references
    procFrame = nil,

    -- Lock and Load icon elements
    lnlBg       = nil,
    lnlIcon     = nil,
    lnlGlow     = nil,
    lnlTimer    = nil,

    -- Experimental Ammo icon elements
    ammoBg      = nil,
    ammoIcon    = nil,
    ammoGlow    = nil,
    ammoTimer   = nil,
    ammoLabel   = nil,  -- spell name hint shown to the right of the icon

    -- Lock and Load detection state
    lnlActive    = false,
    lnlSlot      = 0,    -- 0-based GetPlayerBuff index (same index for GetPlayerBuffTimeLeft)
    lnlBuffId    = 0,    -- buffId from GetPlayerBuff (for GetPlayerBuffTexture)
    lnlExpireTime = 0,   -- GetTime() value when LnL expires (refreshed every scan to handle slot-drift)

    -- Experimental Ammo detection state
    ammoActive    = false,
    ammoSlot      = 0,
    ammoIsDebuff  = true,   -- Experimental Ammo appears as player debuff, not buff
    ammoType      = nil,    -- "explosive" | "poisonous" | "enchanted"
    ammoExpireTime = 0,     -- GetTime() value when ammo expires (set at detection)

    -- Pulse animation
    pulsePhase  = 0,

    -- Throttling
    lastUpdate  = 0,
    lastScan    = 0,
    UPDATE_INTERVAL = 0.05,
    SCAN_THROTTLE   = 0.1,
    pendingRescan   = false,  -- force scan on next frame after UNIT_BUFF
}

-- ============ Buff Detection Constants ============
-- Spell IDs (primary detection via GetPlayerBuffID - fastest and most reliable)
-- Verified in-game via /hht proc scan:
local LNL_SPELL_ID          = 52921  -- Lock and Load (verified 2026-03-20 via /hht proc scan: B6 ID:52921)
local AMMO_ID_EXPLOSIVE     = nil    -- TODO: scan in-game with Explosive Ammo active
local AMMO_ID_POISONOUS     = nil    -- TODO: scan in-game with Poisonous Ammo active
local AMMO_ID_ENCHANTED     = nil    -- TODO: scan in-game with Enchanted Ammo active

-- Texture path fragments (fallback when spell ID not yet known)
local LNL_TEXTURE_PATTERN   = "lockandload"
local AMMO_TEX_EXPLOSIVE    = "SearingArrow"     -- verified 2026-03-20 via /hht proc scan
local AMMO_TEX_POISONOUS    = "PoisonArrow"      -- verified 2026-03-20 via /hht proc scan
local AMMO_TEX_ENCHANTED    = "TheBlackArrow"    -- verified 2026-03-20 via /hht proc scan

-- Buff names (last-resort fallback via tooltip)
local LNL_BUFF_NAME         = "Lock and Load"
local AMMO_BUFF_EXPLOSIVE   = "Explosive Ammunition"
local AMMO_BUFF_POISONOUS   = "Poisonous Ammunition"
local AMMO_BUFF_ENCHANTED   = "Enchanted Ammunition"

-- Fallback display icons (shown when proc is inactive / not yet found)
local LNL_FALLBACK_ICON       = "Interface\\Icons\\ability_hunter_lockandload"  -- verified via /hht proc scan
local AMMO_FALLBACK_EXPLOSIVE = "Interface\\Icons\\Ability_SearingArrow"          -- verified 2026-03-20 via /hht proc scan
local AMMO_FALLBACK_POISONOUS = "Interface\\Icons\\Ability_PoisonArrow"         -- verified 2026-03-20 via /hht proc scan
local AMMO_FALLBACK_ENCHANTED = "Interface\\Icons\\Ability_TheBlackArrow"         -- verified 2026-03-20 via /hht proc scan

-- Known proc durations for self-timing (GetPlayerDebuffTimeLeft unavailable)
-- GetPlayerBuffTimeLeft is unreliable for repeated calls (wrong aura index),
-- so we capture it ONCE at detection and count down via GetTime().
local AMMO_DURATION = 60  -- seconds; verify from in-game tooltip if wrong

-- ============ Helper Functions ============
local function GetDB()
    return HamingwaysHunterToolsDB or {}
end

-- Case-insensitive substring match against texture path
local function MatchTexture(texture, pattern)
    if not texture or not pattern or pattern == "" then return false end
    return string.find(string.lower(texture), string.lower(pattern), 1, true) ~= nil
end

-- Tooltip-based buff name read (slower, used for fallback and /scan command)
local function ReadBuffNameFromTooltip(unit, index, isDebuff)
    if not HamingwaysHunterToolsTooltip then return nil end
    HamingwaysHunterToolsTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    if isDebuff then
        HamingwaysHunterToolsTooltip:SetUnitDebuff(unit, index)
    else
        HamingwaysHunterToolsTooltip:SetUnitBuff(unit, index)
    end
    local name = HamingwaysHunterToolsTooltipTextLeft1 and HamingwaysHunterToolsTooltipTextLeft1:GetText()
    HamingwaysHunterToolsTooltip:Hide()
    return name
end

-- Time remaining until expireTime (returns 0 when expired or unknown)
local function GetTimeLeft(expireTime)
    if not expireTime or expireTime <= 0 then return 0 end
    local t = expireTime - GetTime()
    return t > 0 and t or 0
end

-- Maximum buff slots to scan (fixed range to handle nil gaps in the buff list)
local MAX_BUFF_SLOTS = 40

-- ============ Buff Scanner ============
-- Uses fixed slot range instead of while-loop to handle Vanilla gaps
-- (UnitBuff can return nil mid-list when a buff was removed, breaking while-loops)
-- force=true bypasses the poll throttle (used by events for instant response)
local function ScanProcs(force)
    local now = GetTime()
    if not force and (now - ProcState.lastScan < ProcState.SCAN_THROTTLE) then return end
    ProcState.lastScan = now

    local db = GetDB()
    local lnlEnabled  = db.procFrameLnlEnabled
    local ammoEnabled = db.procFrameAmmoEnabled
    if lnlEnabled  == nil then lnlEnabled  = true end
    if ammoEnabled == nil then ammoEnabled = true end

    -- Remember previous state to detect activation transitions
    local prevLnlActive  = ProcState.lnlActive
    local prevAmmoActive = ProcState.ammoActive

    -- Reset before scan
    ProcState.lnlActive  = false
    ProcState.lnlSlot    = 0
    ProcState.lnlBuffId  = 0
    ProcState.ammoActive = false
    ProcState.ammoSlot   = 0
    ProcState.ammoType   = nil

    -- ---- Scan BUFFS: Lock and Load ----
    -- Use GetPlayerBuff/GetPlayerBuffTexture (0-based) so GetPlayerBuffTimeLeft(i) uses
    -- the exact same index - consistent with how the haste bar works.
    if lnlEnabled then
        for i = 0, MAX_BUFF_SLOTS do
            local buffId = GetPlayerBuff(i, "HELPFUL")
            if buffId >= 0 then
                local texture = GetPlayerBuffTexture(buffId)
                local spellID = GetPlayerBuffID and GetPlayerBuffID(i) or nil
                local hit = false
                if spellID and spellID == LNL_SPELL_ID then
                    hit = true
                elseif texture and MatchTexture(texture, LNL_TEXTURE_PATTERN) then
                    hit = true
                else
                    local name = ReadBuffNameFromTooltip("player", i + 1)  -- tooltip uses 1-based
                    if name and string.find(name, LNL_BUFF_NAME, 1, true) then
                        hit = true
                    end
                end
                if hit then
                    ProcState.lnlActive = true
                    ProcState.lnlSlot   = i       -- 0-based, for GetPlayerBuffTimeLeft(i)
                    ProcState.lnlBuffId = buffId  -- for GetPlayerBuffTexture(buffId)
                    break
                end
            end
        end
    end

    -- ---- Scan DEBUFFS: Experimental Ammo ----
    -- These appear as player debuffs (self-applied procs), not buffs
    -- NOTE: same 1-based/0-based split as buffs: UnitDebuff is 1-based, GetPlayerDebuffID is 0-based.
    if ammoEnabled then
        for i = 1, MAX_BUFF_SLOTS do
            local texture = UnitDebuff("player", i)
            if texture then
                local spellID = GetPlayerDebuffID and GetPlayerDebuffID(i - 1) or nil
                local amType = nil
                -- Primary: spell ID
                if spellID then
                    if AMMO_ID_EXPLOSIVE and spellID == AMMO_ID_EXPLOSIVE then
                        amType = "explosive"
                    elseif AMMO_ID_POISONOUS and spellID == AMMO_ID_POISONOUS then
                        amType = "poisonous"
                    elseif AMMO_ID_ENCHANTED and spellID == AMMO_ID_ENCHANTED then
                        amType = "enchanted"
                    end
                end
                -- Fallback: texture
                if not amType then
                    if MatchTexture(texture, AMMO_TEX_EXPLOSIVE) then
                        amType = "explosive"
                    elseif MatchTexture(texture, AMMO_TEX_POISONOUS) then
                        amType = "poisonous"
                    elseif MatchTexture(texture, AMMO_TEX_ENCHANTED) then
                        amType = "enchanted"
                    end
                end
                -- Last resort: tooltip name
                if not amType then
                    local name = ReadBuffNameFromTooltip("player", i, true)  -- isDebuff=true
                    if name then
                        if string.find(name, AMMO_BUFF_EXPLOSIVE, 1, true) then
                            amType = "explosive"
                        elseif string.find(name, AMMO_BUFF_POISONOUS, 1, true) then
                            amType = "poisonous"
                        elseif string.find(name, AMMO_BUFF_ENCHANTED, 1, true) then
                            amType = "enchanted"
                        end
                    end
                end
                if amType then
                    ProcState.ammoActive   = true
                    ProcState.ammoSlot     = i
                    ProcState.ammoIsDebuff = true
                    ProcState.ammoType     = amType
                    break
                end
            end
        end
    end

    -- ---- Set expire times ----
    -- LnL: timer is read FRESH every display tick in HHT_UpdateProcDisplay (not cached here).
    -- Caching caused a 1-in-10 wrong-value bug: when LnL and Ammo proc together, GetPlayerBuffTimeLeft
    -- could return the previous buff's stale time (~60s) on the first scan and lock it in.
    if not ProcState.lnlActive then
        ProcState.lnlExpireTime = 0  -- reset on deactivation
    end

    -- Ammo: use fixed known duration (GetPlayerDebuffTimeLeft unavailable)
    if ProcState.ammoActive and not prevAmmoActive then
        ProcState.ammoExpireTime = GetTime() + AMMO_DURATION
    elseif not ProcState.ammoActive then
        ProcState.ammoExpireTime = 0
    end
end

-- ============ Icon Slot Update Helper ============
-- Updates one icon slot: bg, icon texture, glow, timer text.
-- isActive:    bool - is this proc currently up?
-- slot:        buff slot index (for time remaining)
-- liveTexture: texture retieved from UnitBuff (may be nil)
-- fallback:    icon path when liveTexture is nil
-- pulseAlpha:  current sine value 0..1 for glow
local function UpdateIconSlot(bg, icon, glow, timer, isActive, expireTime, liveTexture, fallback, pulseAlpha)
    if not bg then return end

    if isActive then
        -- Apply real buff texture (or fallback if not discovered yet)
        if liveTexture then
            icon:SetTexture(liveTexture)
        else
            icon:SetTexture(fallback)
        end
        icon:SetAlpha(1.0)

        -- Glow shimmer
        if glow then
            glow:SetAlpha(pulseAlpha * 0.45)
        end

        -- Timer text with color coding
        local timeLeft = GetTimeLeft(expireTime)
        if timeLeft > 0 then
            timer:SetText(string.format("%.1f", timeLeft))
            if timeLeft < 2 then
                timer:SetTextColor(1, 0.2, 0.2, 1)  -- red: danger
            elseif timeLeft < 5 then
                timer:SetTextColor(1, 0.9, 0, 1)     -- yellow: hurry
            else
                timer:SetTextColor(1, 1, 1, 1)        -- white: fine
            end
        else
            -- SuperWoW not returning time, or buff has no timer (consumed procs)
            timer:SetText("!")
            timer:SetTextColor(1, 1, 0, 1)
        end
    else
        -- Inactive: show dimmed fallback icon
        icon:SetTexture(fallback)
        icon:SetAlpha(0.15)
        if glow then glow:SetAlpha(0) end
        timer:SetText("")
    end
end

-- ============ Display Update ============
function HHT_UpdateProcDisplay()
    if not ProcState.procFrame then return end

    local db = GetDB()
    if not db.procFrameEnabled then
        ProcState.procFrame:Hide()
        return
    end

    local lnlEnabled  = db.procFrameLnlEnabled
    local ammoEnabled = db.procFrameAmmoEnabled
    if lnlEnabled  == nil then lnlEnabled  = true end
    if ammoEnabled == nil then ammoEnabled = true end

    local anyActive = ProcState.lnlActive or ProcState.ammoActive

    -- Hide frame when no procs active and showAlways is off
    local showAlways = db.procFrameShowAlways
    if showAlways == nil then showAlways = false end

    if not anyActive and not showAlways then
        ProcState.procFrame:Hide()
        return
    end
    ProcState.procFrame:Show()

    -- Pulse animation: smooth ramp 0..1
    ProcState.pulsePhase = ProcState.pulsePhase + ProcState.UPDATE_INTERVAL * 3.5
    local pulseAlpha = (math.sin(ProcState.pulsePhase) + 1) * 0.5  -- 0.0 .. 1.0

    -- Visibility of each slot background
    if ProcState.lnlBg then
        if lnlEnabled then
            ProcState.lnlBg:Show()
        else
            ProcState.lnlBg:Hide()
        end
    end
    if ProcState.ammoBg then
        if ammoEnabled then
            ProcState.ammoBg:Show()
        else
            ProcState.ammoBg:Hide()
        end
    end

    -- Lock and Load slot
    if lnlEnabled then
        local liveTex = nil
        if ProcState.lnlActive and ProcState.lnlBuffId > 0 then
            liveTex = GetPlayerBuffTexture(ProcState.lnlBuffId)
            if liveTex and MatchTexture(liveTex, LNL_TEXTURE_PATTERN) then
                -- Read timer FRESH every display tick (0.05s) - never use a cached value.
                -- If one read is stale (e.g. returns prev buff's time), the next frame corrects it.
                local tl = GetPlayerBuffTimeLeft and GetPlayerBuffTimeLeft(ProcState.lnlSlot) or 0
                if tl > 0 then
                    ProcState.lnlExpireTime = GetTime() + tl
                end
                -- tl == 0: no timer data or permanent buff - keep previous expireTime as-is
            else
                -- Slot no longer holds LnL (expired between scans)
                ProcState.lnlActive     = false
                ProcState.lnlSlot       = 0
                ProcState.lnlBuffId     = 0
                ProcState.lnlExpireTime = 0
                liveTex = nil
            end
        end
        UpdateIconSlot(
            ProcState.lnlBg, ProcState.lnlIcon, ProcState.lnlGlow, ProcState.lnlTimer,
            ProcState.lnlActive, ProcState.lnlExpireTime,
            liveTex, LNL_FALLBACK_ICON,
            pulseAlpha
        )
    end

    -- Experimental Ammo slot
    if ammoEnabled then
        local liveTex = nil
        if ProcState.ammoActive and ProcState.ammoSlot > 0 then
            -- Ammo is a player debuff, not a buff
            liveTex = UnitDebuff("player", ProcState.ammoSlot)
            -- Validate slot still has an aura (debuffs don't shift like buffs, but be safe)
            if not liveTex then
                ProcState.ammoActive    = false
                ProcState.ammoSlot      = 0
                ProcState.ammoExpireTime = 0
            end
        end
        local fallback = AMMO_FALLBACK_EXPLOSIVE
        if ProcState.ammoType == "poisonous" then
            fallback = AMMO_FALLBACK_POISONOUS
        elseif ProcState.ammoType == "enchanted" then
            fallback = AMMO_FALLBACK_ENCHANTED
        end
        UpdateIconSlot(
            ProcState.ammoBg, ProcState.ammoIcon, ProcState.ammoGlow, ProcState.ammoTimer,
            ProcState.ammoActive, ProcState.ammoExpireTime,
            liveTex, fallback,
            pulseAlpha
        )

        -- Spell hint label
        if ProcState.ammoLabel then
            if ProcState.ammoActive then
                local hint = ""
                if ProcState.ammoType == "explosive" then
                    hint = "Multi-Shot"
                elseif ProcState.ammoType == "poisonous" then
                    hint = "Serpent Sting"
                elseif ProcState.ammoType == "enchanted" then
                    hint = "Arcane Shot"
                end
                ProcState.ammoLabel:SetText(hint)
                ProcState.ammoLabel:Show()
            else
                ProcState.ammoLabel:SetText("")
                ProcState.ammoLabel:Hide()
            end
        end
    end
end

-- ============ Create Proc Frame ============
local function CreateProcFrame()
    local db = GetDB()
    local iconSize    = db.procFrameIconSize or 40
    local padding     = 6   -- between slots
    local dragPad     = 8   -- extra area for easier dragging
    local timerH      = 16  -- height reserved for timer text below icon

    -- Each icon slot: (iconSize + 4) wide × (iconSize + 4 + timerH) tall
    local slotW = iconSize + 4
    local slotH = iconSize + 4 + timerH

    local frameW = 2 * slotW + padding + dragPad * 2
    local frameH = slotH + dragPad * 2

    local f = CreateFrame("Frame", "HamingwaysHunterToolsProcFrameMain", UIParent)
    ProcState.procFrame = f
    -- expose as global so main HHT.lua can reference it
    HHT_ProcFrame = f

    f:SetWidth(frameW)
    f:SetHeight(frameH)
    f:SetFrameStrata("MEDIUM")

    -- Load saved position
    local point = db.procFramePoint or "CENTER"
    local posX  = db.procFrameX    or 0
    local posY  = db.procFrameY    or -250
    f:SetPoint(point, UIParent, point, posX, posY)

    -- Drag support
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if not HamingwaysHunterToolsDB.locked then
            this:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local p, _, _, x, y = this:GetPoint()
        HamingwaysHunterToolsDB.procFramePoint = p
        HamingwaysHunterToolsDB.procFrameX     = x
        HamingwaysHunterToolsDB.procFrameY     = y
    end)

    -- Start hidden; UpdateProcDisplay controls visibility
    f:Hide()

    -- ---- Helper: create one icon slot ----
    local function MakeIconSlot(xOff)
        -- Background
        local bg = CreateFrame("Frame", nil, f)
        bg:SetWidth(slotW)
        bg:SetHeight(slotH)
        bg:SetPoint("LEFT", f, "LEFT", dragPad + xOff, 0)
        bg:SetBackdrop({
            bgFile   = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets   = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        bg:SetBackdropColor(0, 0, 0, 0.82)
        bg:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.9)

        -- Icon texture
        local icon = bg:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(iconSize)
        icon:SetHeight(iconSize)
        icon:SetPoint("TOP", bg, "TOP", 0, -2)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)  -- trim default border
        icon:SetAlpha(0.15)

        -- Glow overlay: yellow-white shimmer when proc is active
        local glow = bg:CreateTexture(nil, "OVERLAY")
        glow:SetWidth(iconSize)
        glow:SetHeight(iconSize)
        glow:SetPoint("TOP", bg, "TOP", 0, -2)
        glow:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        glow:SetVertexColor(1, 0.85, 0.1, 1)
        glow:SetAlpha(0)

        -- Timer text (centered below icon)
        local timer = bg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        timer:SetPoint("BOTTOM", bg, "BOTTOM", 0, 3)
        timer:SetJustifyH("CENTER")
        timer:SetText("")
        timer:SetTextColor(1, 1, 1, 1)

        return bg, icon, glow, timer
    end

    -- Slot 1: Lock and Load (left)
    ProcState.lnlBg,  ProcState.lnlIcon,  ProcState.lnlGlow,  ProcState.lnlTimer  = MakeIconSlot(0)
    -- Slot 2: Experimental Ammo (right)
    ProcState.ammoBg, ProcState.ammoIcon, ProcState.ammoGlow, ProcState.ammoTimer = MakeIconSlot(slotW + padding)

    -- Spell hint label: shown to the right of the ammo slot
    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", ProcState.ammoBg, "RIGHT", 4, 0)
    label:SetJustifyH("LEFT")
    label:SetText("")
    label:SetTextColor(1, 0.9, 0.5, 1)  -- warm yellow
    ProcState.ammoLabel = label
end

-- ============ OnUpdate (throttled) ============
ProcModule:SetScript("OnUpdate", function()
    if not ProcState.procFrame then return end

    local db = GetDB()
    if not db.procFrameEnabled then
        if ProcState.procFrame:IsShown() then ProcState.procFrame:Hide() end
        return
    end

    local now = GetTime()
    if now - ProcState.lastUpdate < ProcState.UPDATE_INTERVAL then return end
    ProcState.lastUpdate = now

    -- Deferred rescan: UNIT_BUFF fires before buff list updates in 1.12,
    -- so we scan again on the next frame to catch procs missed by the event scan
    if ProcState.pendingRescan then
        ProcState.pendingRescan = false
        ScanProcs(true)
        HHT_UpdateProcDisplay()
        return
    end

    ScanProcs()  -- throttled internally; keeps state current without relying on events
    HHT_UpdateProcDisplay()
end)

-- ============ Event Handler ============
ProcModule:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        ProcModule:UnregisterEvent("VARIABLES_LOADED")
        HHT_ProcFrame_Initialize()

    elseif event == "UNIT_BUFF" or event == "UNIT_DEBUFF" then
        -- arg1 == "player" means player's auras changed; scan immediately (no throttle)
        -- UNIT_BUFF fires before buff list updates in 1.12, so also set pendingRescan
        -- to catch procs on the very next frame
        if arg1 == "player" then
            ScanProcs(true)
            HHT_UpdateProcDisplay()
            ProcState.pendingRescan = true
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- DetectSuperWoW() in the main file runs on this same event.
        -- If initialization was skipped earlier (DB not ready), retry now.
        if not ProcState.procFrame then
            HHT_ProcFrame_Initialize()
        end
        ScanProcs()
    end
end)

-- ============ Public API ============

-- LazyHunt interface:
--   HHT_ProcState_LnL()   → true if Lock and Load is active, false otherwise
--   HHT_ProcState_Ammo()  → 0 = not active
--                            1 = Explosive Ammunition (fire)
--                            2 = Enchanted Ammunition (arcane)
--                            3 = Poisonous Ammunition (poison)
function HHT_ProcState_LnL()
    return ProcState.lnlActive == true
end

function HHT_ProcState_Ammo()
    if not ProcState.ammoActive then return 0 end
    if ProcState.ammoType == "explosive" then return 1 end
    if ProcState.ammoType == "enchanted"  then return 2 end
    if ProcState.ammoType == "poisonous"  then return 3 end
    return 0
end

-- Called from main HHT.lua lock checkbox to keep lock behaviour consistent
function HHT_ProcFrame_SetMouseEnabled(enabled)
    if ProcState.procFrame then
        ProcState.procFrame:EnableMouse(enabled)
    end
end

-- Called from config tab when settings change
function HHT_ProcFrame_UpdateSettings()
    if not ProcState.procFrame then return end
    ScanProcs()
    HHT_UpdateProcDisplay()
end

-- Show preview with dummy data (called from ShowConfigPreview in main addon)
function HHT_ProcFrame_ShowPreview()
    if not ProcState.procFrame then return end

    local db = GetDB()
    if not db.procFrameEnabled then return end

    -- Force dummy active state so frame is visible regardless of real buffs
    ProcState.lnlActive  = true
    ProcState.lnlSlot    = 0  -- slot 0 → GetBuffTimeLeft returns 0 → shows "!" (no SuperWoW needed for preview)
    ProcState.ammoActive = true
    ProcState.ammoSlot   = 0
    ProcState.ammoType   = "explosive"

    -- Force icons to fallback textures for preview (slot 0 won't return real texture)
    if ProcState.lnlIcon then
        ProcState.lnlIcon:SetTexture("Interface\\Icons\\ability_hunter_lockandload")
        ProcState.lnlIcon:SetAlpha(1.0)
    end
    if ProcState.lnlTimer then
        ProcState.lnlTimer:SetText("8.0")
        ProcState.lnlTimer:SetTextColor(1, 1, 1, 1)
    end
    if ProcState.lnlGlow then ProcState.lnlGlow:SetAlpha(0.35) end

    if ProcState.ammoIcon then
        ProcState.ammoIcon:SetTexture("Interface\\Icons\\Spell_Fire_SelfDestruct")
        ProcState.ammoIcon:SetAlpha(1.0)
    end
    if ProcState.ammoTimer then
        ProcState.ammoTimer:SetText("!")
        ProcState.ammoTimer:SetTextColor(1, 1, 0, 1)
    end
    if ProcState.ammoGlow then ProcState.ammoGlow:SetAlpha(0.35) end

    if ProcState.lnlBg  then ProcState.lnlBg:Show()  end
    if ProcState.ammoBg then ProcState.ammoBg:Show() end
    ProcState.procFrame:Show()
end

-- Hide preview / restore normal state (called from HideConfigPreview in main addon)
function HHT_ProcFrame_HidePreview()
    if not ProcState.procFrame then return end
    -- Reset dummy state and re-scan real buffs
    ProcState.lnlActive  = false
    ProcState.lnlSlot    = 0
    ProcState.ammoActive = false
    ProcState.ammoSlot   = 0
    ProcState.ammoType   = nil
    ScanProcs()
    HHT_UpdateProcDisplay()
end

-- Resize icons (called from config icon size slider)
function HHT_ProcFrame_ApplyIconSize(newSize)
    if not ProcState.procFrame then return end

    local db = GetDB()
    local padding = 6
    local dragPad = 8
    local timerH  = 16
    local slotW   = newSize + 4
    local slotH   = newSize + 4 + timerH

    ProcState.procFrame:SetWidth(2 * slotW + padding + dragPad * 2)
    ProcState.procFrame:SetHeight(slotH + dragPad * 2)

    -- Resize each slot background and its children
    local function ResizeSlot(bg, icon, glow)
        if not bg then return end
        bg:SetWidth(slotW)
        bg:SetHeight(slotH)
        icon:SetWidth(newSize)
        icon:SetHeight(newSize)
        glow:SetWidth(newSize)
        glow:SetHeight(newSize)
    end

    ResizeSlot(ProcState.lnlBg,  ProcState.lnlIcon,  ProcState.lnlGlow)
    ResizeSlot(ProcState.ammoBg, ProcState.ammoIcon, ProcState.ammoGlow)

    -- Reposition ammo slot background
    if ProcState.ammoBg then
        ProcState.ammoBg:ClearAllPoints()
        ProcState.ammoBg:SetPoint("LEFT", ProcState.procFrame, "LEFT", dragPad + slotW + padding, 0)
    end
end

-- ============ /hht proc scan ============
-- Prints all current player buff data (slot, spell ID, name, texture)
-- Use this in-game to discover actual IDs/textures for the constant tables above.
function HHT_ProcFrame_Scan()
    -- ---- BUFFS ----
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cFFABD473HHT Proc Scan:|r Buffs (" .. MAX_BUFF_SLOTS .. " slots):", 0.67, 0.83, 0.45)
    local found = 0
    for i = 1, MAX_BUFF_SLOTS do
        local texture = UnitBuff("player", i)
        if texture then
            local spellID = GetPlayerBuffID and tostring(GetPlayerBuffID(i)) or "n/a"
            local name    = ReadBuffNameFromTooltip("player", i) or "?"
            DEFAULT_CHAT_FRAME:AddMessage(
                string.format("  [B%d] ID:%s  |cFFFFFFFF%s|r", i, spellID, name),
                0.8, 0.8, 0.8)
            DEFAULT_CHAT_FRAME:AddMessage(
                "      Tex: |cFF888888" .. tostring(texture) .. "|r",
                0.6, 0.6, 0.6)
            found = found + 1
        end
    end
    if found == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("  No buffs active on player.", 0.8, 0.8, 0.8)
    else
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  Buffs total: %d", found), 0.8, 0.8, 0.8)
    end

    -- ---- DEBUFFS ----
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cFFABD473HHT Proc Scan:|r Debuffs (" .. MAX_BUFF_SLOTS .. " slots):", 0.67, 0.83, 0.45)
    local dfound = 0
    for i = 1, MAX_BUFF_SLOTS do
        local texture = UnitDebuff("player", i)
        if texture then
            local spellID = GetPlayerDebuffID and tostring(GetPlayerDebuffID(i)) or "n/a"
            local name    = ReadBuffNameFromTooltip("player", i, true) or "?"
            DEFAULT_CHAT_FRAME:AddMessage(
                string.format("  [D%d] ID:%s  |cFFFFFFFF%s|r", i, spellID, name),
                0.8, 0.8, 0.8)
            DEFAULT_CHAT_FRAME:AddMessage(
                "      Tex: |cFF888888" .. tostring(texture) .. "|r",
                0.6, 0.6, 0.6)
            dfound = dfound + 1
        end
    end
    if dfound == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("  No debuffs active on player.", 0.8, 0.8, 0.8)
    else
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  Debuffs total: %d", dfound), 0.8, 0.8, 0.8)
    end

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cFFFFFF00Tip:|r Update AMMO_ID_* constants at top of ProcFrame.lua with the [D#] IDs above.",
        0.9, 0.9, 0.4)
end

-- ============ Initialize ============
function HHT_ProcFrame_Initialize()
    -- Wait until DB is loaded by the WoW client
    if not HamingwaysHunterToolsDB then
        ProcModule:RegisterEvent("VARIABLES_LOADED")
        return
    end

    -- Don't double-create if already initialized
    if ProcState.procFrame then return end

    -- SuperWoW is preferred for timers but not strictly required;
    -- GetBuffTimeLeft degrades gracefully to 0 when APIs are absent.
    -- (HAS_SUPERWOW may not be set yet at VARIABLES_LOADED — it is set
    --  during PLAYER_ENTERING_WORLD by DetectSuperWoW() in the main file.)

    -- Create the frame
    CreateProcFrame()

    -- Register events
    ProcModule:RegisterEvent("UNIT_BUFF")
    ProcModule:RegisterEvent("UNIT_DEBUFF")   -- Experimental Ammo appears as player debuff
    ProcModule:RegisterEvent("PLAYER_ENTERING_WORLD")

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cFFABD473HHT:|r Proc Frame loaded. " ..
        "Use |cFFFFFF00/hht proc scan|r to discover buff textures.",
        0.67, 0.83, 0.45)
end

-- Kick off initialization (will wait for VARIABLES_LOADED if DB not ready yet)
HHT_ProcFrame_Initialize()
