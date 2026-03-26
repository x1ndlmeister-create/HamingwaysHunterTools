-- HamingwaysHunterTools_ProcFrame.lua
-- Proc Frame Module
-- Displays active hunter procs relevant to rotation (Turtle WoW 1.18.1+)
-- Tracks: Lock and Load, Experimental Ammunition variants
-- Requires: Nampower (for BUFF_ADDED_SELF/BUFF_REMOVED_SELF/AURA_CAST_ON_SELF events)

print("[HHT] Loading ProcFrame.lua")

-- Module frame
local ProcModule = CreateFrame("Frame", "HamingwaysHunterToolsProcModule")

-- ============ Kill Command spell name (locale-aware) ============
-- Read once at load time; works for all client locales.
local KC_SPELL_NAME = GetSpellInfo and GetSpellInfo(34026) or "Kill Command"
if not KC_SPELL_NAME or KC_SPELL_NAME == "" then
    KC_SPELL_NAME = "Kill Command"  -- English fallback
end

-- Keybind helper: returns the first binding key for a spell name, or nil
-- Uses GetBindingKey which may not exist in all WoW builds; guarded accordingly.
local function GetSpellKeybind(spellName)
    if not spellName or spellName == "" then return nil end
    if not GetBindingKey then return nil end
    local ok, key = pcall(GetBindingKey, "SPELL " .. spellName)
    return ok and key or nil
end

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
    -- Cached spell icon textures (filled from spellbook at init)
    ammoSpellIconExplosive = nil,
    ammoSpellIconPoisonous = nil,
    ammoSpellIconEnchanted = nil,

    -- Lock and Load detection state
    lnlActive    = false,
    lnlSlot      = 0,    -- 0-based GetPlayerBuff index (same index for GetPlayerBuffTimeLeft)
    lnlBuffId    = 0,    -- buffId from GetPlayerBuff (for GetPlayerBuffTexture)
    lnlExpireTime = 0,   -- GetTime() value when LnL expires (set by BUFF_ADDED_SELF via AURA_CAST_ON_SELF cache)

    -- Experimental Ammo detection state
    ammoActive    = false,
    ammoSlot      = 0,
    ammoIsDebuff  = true,   -- Experimental Ammo appears as player debuff, not buff
    ammoType      = nil,    -- "explosive" | "poisonous" | "enchanted"
    ammoSpellId   = nil,    -- spellId from DEBUFF_ADDED_SELF (for matching DEBUFF_REMOVED_SELF)
    ammoExpireTime = 0,     -- GetTime() value when ammo expires (set at detection)

    -- Kill Command state
    kcBg          = nil,
    kcIcon        = nil,
    kcGlow        = nil,
    kcTimer       = nil,
    kcReady       = false,  -- true when KC is off cooldown
    kcCooldownEnd = 0,      -- GetTime() when CD expires
    kcSpellSlot   = nil,    -- spell book slot index for KC (cached at init for GetSpellCooldown)
    kcActionSlot  = nil,    -- action bar slot# for KC (for IsUsableAction - mirrors what action bar shows)

    -- Ammo spell CD overlay
    ammoSpellCdTimer        = nil,  -- FontString for spell cooldown text on spell icon
    ammoSpellSlotExplosive  = nil,  -- spellbook slot# for Multi-Shot
    ammoSpellSlotPoisonous  = nil,  -- spellbook slot# for Serpent Sting
    ammoSpellSlotEnchanted  = nil,  -- spellbook slot# for Arcane Shot

    -- Preview mode (config open)
    previewMode   = false,

    -- Pulse animation
    pulsePhase  = 0,

    -- Throttling
    lastUpdate  = 0,
    lastScan    = 0,
    UPDATE_INTERVAL = 0.05,
    SCAN_THROTTLE   = 0.1,
    pendingDurationMs = {},   -- AURA_CAST_ON_SELF cache: [spellId] = durationMs
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

-- Duration is captured from AURA_CAST_ON_SELF (arg8=durationMs) before BUFF/DEBUFF_ADDED_SELF fires.
-- This matches the DoiteAuras approach and requires no hardcoded fallback durations.

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
    if ProcState.previewMode then return end
    local now = GetTime()
    if not force and (now - ProcState.lastScan < ProcState.SCAN_THROTTLE) then return end
    ProcState.lastScan = now

    local db = GetDB()
    local lnlEnabled  = db.procFrameLnlEnabled
    local ammoEnabled = db.procFrameAmmoEnabled
    if lnlEnabled  == nil then lnlEnabled  = true end
    if ammoEnabled == nil then ammoEnabled = true end

    -- ---- Scan BUFFS: Lock and Load (bootstrap only) ----
    -- Primary tracking: AURA_CAST_ON_SELF + BUFF_ADDED/REMOVED_SELF events (DoiteAuras pattern).
    -- This scan runs only as fallback for /reload or missed events, never to refresh expireTime.
    if lnlEnabled and not ProcState.lnlActive then
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
                end
                if hit then
                    ProcState.lnlActive = true
                    ProcState.lnlSlot   = i
                    -- expireTime unknown at bootstrap (no event durationMs available)
                    -- show "!" until next proc/refresh provides authoritative duration
                    ProcState.lnlExpireTime = 0
                    break
                end
            end
        end
    end

end

-- ============ Icon Slot Update Helper ============
-- Updates one icon slot: bg, icon texture, glow, timer text.
-- isActive:    bool - is this proc currently up?
-- expireTime:  GetTime() when proc expires (0 = unknown/no timer)
-- liveTexture: texture retrieved from UnitBuff (may be nil)
-- fallback:    icon path when liveTexture is nil
-- pulseAlpha:  current sine value 0..1 for glow
-- showDimmed:  when true and inactive, show slot with dimmed icon instead of hiding
local function UpdateIconSlot(bg, icon, glow, timer, isActive, expireTime, liveTexture, fallback, pulseAlpha, showDimmed)
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
        bg:Show()
    elseif showDimmed then
        -- Show always mode: show slot with dimmed icon so the frame is visible
        icon:SetTexture(fallback)
        icon:SetAlpha(0.15)
        if glow then glow:SetAlpha(0) end
        timer:SetText("")
        bg:Show()
    else
        -- Inactive and not show-always: hide slot entirely
        bg:Hide()
    end
end

-- ============ Display Update ============
-- Neupositioniert alle sichtbaren Slots lückenlos von links nach rechts
local function RepositionVisibleSlots()
    if not ProcState.procFrame then return end
    local db = GetDB()
    local iconSize = db.procFrameIconSize or 40
    local padding  = 6
    local dragPad  = 8
    local slotW    = iconSize + 4

    local visibleSlots = {}
    local n = 0
    if ProcState.lnlBg  and ProcState.lnlBg:IsShown()  then n = n + 1; visibleSlots[n] = ProcState.lnlBg  end
    if ProcState.ammoBg and ProcState.ammoBg:IsShown() then n = n + 1; visibleSlots[n] = ProcState.ammoBg end
    if ProcState.kcBg   and ProcState.kcBg:IsShown()   then n = n + 1; visibleSlots[n] = ProcState.kcBg   end

    local frameW = math.max(1, n) * slotW + math.max(0, n - 1) * padding + dragPad * 2
    ProcState.procFrame:SetWidth(frameW)

    local i
    for i = 1, n do
        local xOff = (i - 1) * (slotW + padding)
        visibleSlots[i]:ClearAllPoints()
        visibleSlots[i]:SetPoint("LEFT", ProcState.procFrame, "LEFT", dragPad + xOff, 0)
    end

    -- ammoSpellIconBg folgt ihrem Ammo-Slot automatisch (BOTTOM anchor auf ammoBg)
end

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

    local showAlways = db.procFrameShowAlways
    if showAlways == nil then showAlways = true end
    -- showAlways=true  → inaktive Slots gedimmt anzeigen
    -- showAlways=false → inaktive Slots komplett ausblenden + Slots nach links schieben
    local showDimmed = showAlways

    -- Outer frame immer sichtbar wenn enabled
    ProcState.procFrame:Show()

    -- Pulse animation
    ProcState.pulsePhase = ProcState.pulsePhase + ProcState.UPDATE_INTERVAL * 3.5
    local pulseAlpha = (math.sin(ProcState.pulsePhase) + 1) * 0.5

    -- Lock and Load slot
    if lnlEnabled then
        if ProcState.lnlActive then
            -- Safety net: if expireTime elapsed and event was missed, clear state
            if ProcState.lnlExpireTime > 0 and GetTime() > ProcState.lnlExpireTime then
                ProcState.lnlActive     = false
                ProcState.lnlSlot       = 0
                ProcState.lnlBuffId     = 0
                ProcState.lnlExpireTime = 0
            end
        end
        -- liveTex is always nil: GetPlayerBuffTexture(buffId) requires the buffId from
        -- GetPlayerBuff(), not the aura slot from arg6. Passing the wrong value returns
        -- a random other buff's icon. LNL_FALLBACK_ICON is always correct here.
        UpdateIconSlot(
            ProcState.lnlBg, ProcState.lnlIcon, ProcState.lnlGlow, ProcState.lnlTimer,
            ProcState.lnlActive, ProcState.lnlExpireTime,
            nil, LNL_FALLBACK_ICON,
            pulseAlpha, showDimmed
        )
    elseif ProcState.lnlBg then
        ProcState.lnlBg:Hide()
    end

    -- Experimental Ammo slot
    if ammoEnabled then
        -- liveTex is always nil: ammo is a debuff tracked via DEBUFF_ADDED/REMOVED_SELF events.
        -- UnitDebuff() uses a 1-based index, but ammoSlot holds the raw Nampower aura slot
        -- (0-based, 32-47), so we cannot use it to validate via UnitDebuff. The event handlers
        -- are authoritative; we do not re-validate here.
        local liveTex = nil
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
            pulseAlpha, showDimmed
        )

        -- Spell icon overlay above ammo slot (only when active)
        if ProcState.ammoActive then
            local spellIcon, bindKey
            if ProcState.ammoType == "explosive" then
                spellIcon = ProcState.ammoSpellIconExplosive
                bindKey   = GetSpellKeybind("Multi-Shot")
            elseif ProcState.ammoType == "poisonous" then
                spellIcon = ProcState.ammoSpellIconPoisonous
                bindKey   = GetSpellKeybind("Serpent Sting")
            elseif ProcState.ammoType == "enchanted" then
                spellIcon = ProcState.ammoSpellIconEnchanted
                bindKey   = GetSpellKeybind("Arcane Shot")
            end

            if ProcState.ammoSpellIcon and spellIcon then
                ProcState.ammoSpellIcon:SetTexture(spellIcon)

                -- Check if spell is on cooldown
                local spellCdSlot = nil
                if ProcState.ammoType == "explosive" then
                    spellCdSlot = ProcState.ammoSpellSlotExplosive
                elseif ProcState.ammoType == "poisonous" then
                    spellCdSlot = ProcState.ammoSpellSlotPoisonous
                elseif ProcState.ammoType == "enchanted" then
                    spellCdSlot = ProcState.ammoSpellSlotEnchanted
                end
                local spellOnCd = false
                local spellCdRemaining = 0
                if spellCdSlot then
                    local cdOk, cdStart, cdDur = pcall(GetSpellCooldown, spellCdSlot, BOOKTYPE_SPELL)
                    if cdOk and cdStart and cdDur and cdDur > 0 then
                        spellCdRemaining = (cdStart + cdDur) - GetTime()
                        if spellCdRemaining < 0 then spellCdRemaining = 0 end
                        if spellCdRemaining > 0 then spellOnCd = true end
                    end
                end

                if spellOnCd then
                    ProcState.ammoSpellIcon:SetAlpha(0.25)
                    if ProcState.ammoSpellCdTimer then
                        local cdText
                        if spellCdRemaining >= 10 then
                            cdText = tostring(math.floor(spellCdRemaining))
                        else
                            cdText = string.format("%.1f", spellCdRemaining)
                        end
                        ProcState.ammoSpellCdTimer:SetText(cdText)
                    end
                else
                    ProcState.ammoSpellIcon:SetAlpha(1.0)
                    if ProcState.ammoSpellCdTimer then
                        ProcState.ammoSpellCdTimer:SetText("")
                    end
                end

                if ProcState.ammoKeybindText then
                    ProcState.ammoKeybindText:SetText(bindKey and ("[" .. bindKey .. "]") or "")
                end
                ProcState.ammoSpellIconBg:Show()
            elseif ProcState.ammoSpellIconBg then
                ProcState.ammoSpellIconBg:Hide()
            end
        else
            if ProcState.ammoSpellIconBg then
                ProcState.ammoSpellIconBg:Hide()
            end
        end
    elseif ProcState.ammoBg then
        ProcState.ammoBg:Hide()
        if ProcState.ammoSpellIconBg then ProcState.ammoSpellIconBg:Hide() end
    end

    -- Kill Command slot
    -- KC is only usable after the pet damages an enemy (IsUsableSpell checks this condition).
    -- States: usable (GO + glow) | on cooldown (grey + timer) | not usable (very dim, no text)
    local kcEnabled = db.procFrameKcEnabled
    if kcEnabled == nil then kcEnabled = false end
    if kcEnabled and ProcState.kcBg then
        ProcState.kcBg:Show()
        ProcState.kcIcon:SetTexture("Interface\\Icons\\Ability_Hunter_KillCommand")

        -- Check cooldown
        local cdRemaining = 0
        local isOnCooldown = false
        if not ProcState.previewMode and ProcState.kcSpellSlot then
            local cdOk, cdStart, cdDur = pcall(GetSpellCooldown, ProcState.kcSpellSlot, BOOKTYPE_SPELL)
            if cdOk and cdStart and cdDur and cdDur > 1.5 then
                -- Ignore GCD-only cooldowns (<=1.5s) - those aren't real KC cooldowns
                cdRemaining = (cdStart + cdDur) - GetTime()
                if cdRemaining < 0 then cdRemaining = 0 end
                isOnCooldown = cdRemaining > 0
            end
        end

        -- Check if KC is usable right now (pet attacked recently).
        -- IsUsableAction mirrors exactly what the action bar displays.
        local kcUsable = false
        if not ProcState.previewMode then
            if ProcState.kcActionSlot then
                local ok, usable = pcall(IsUsableAction, ProcState.kcActionSlot)
                kcUsable = ok and usable or false
            elseif ProcState.kcSpellSlot then
                -- Fallback when KC not on action bar
                local ok, usable = pcall(IsUsableSpell, ProcState.kcSpellSlot, BOOKTYPE_SPELL)
                kcUsable = ok and usable or false
            end
        end

        if isOnCooldown then
            -- On cooldown: grey icon + remaining time
            ProcState.kcIcon:SetAlpha(0.25)
            if ProcState.kcGlow then ProcState.kcGlow:SetAlpha(0) end
            local cdText
            if cdRemaining >= 10 then
                cdText = tostring(math.floor(cdRemaining))
            else
                cdText = string.format("%.1f", cdRemaining)
            end
            ProcState.kcTimer:SetText(cdText)
            ProcState.kcTimer:SetTextColor(0.7, 0.7, 0.7, 1)
        elseif kcUsable then
            -- Usable and off cooldown: full alpha + glow pulse + GO
            ProcState.kcIcon:SetAlpha(1.0)
            if ProcState.kcGlow then ProcState.kcGlow:SetAlpha(pulseAlpha * 0.55) end
            ProcState.kcTimer:SetText("GO")
            ProcState.kcTimer:SetTextColor(0.2, 1, 0.2, 1)
        else
            -- Not usable (pet hasn't attacked / no pet): very dim, no text
            ProcState.kcIcon:SetAlpha(0.12)
            if ProcState.kcGlow then ProcState.kcGlow:SetAlpha(0) end
            ProcState.kcTimer:SetText("")
        end
    elseif ProcState.kcBg then
        ProcState.kcBg:Hide()
    end

    -- Slots neu positionieren (lückenlos wenn showAlways=false)
    if not showDimmed then
        RepositionVisibleSlots()
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
    f:SetClampedToScreen(true)

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
        bg:Hide()  -- start hidden; HHT_UpdateProcDisplay controls Show/Hide

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
    -- Slot 2: Experimental Ammo
    ProcState.ammoBg, ProcState.ammoIcon, ProcState.ammoGlow, ProcState.ammoTimer = MakeIconSlot(slotW + padding)
    -- Slot 3: Kill Command
    ProcState.kcBg,   ProcState.kcIcon,   ProcState.kcGlow,   ProcState.kcTimer   = MakeIconSlot(2 * (slotW + padding))

    -- Spell icon overlay above ammo slot (full icon size, shows which spell to press)
    local ammoSpellIconBg = CreateFrame("Frame", nil, f)
    ammoSpellIconBg:SetWidth(slotW)
    ammoSpellIconBg:SetHeight(iconSize + 4)
    ammoSpellIconBg:SetPoint("BOTTOM", ProcState.ammoBg, "TOP", 0, 2)
    ammoSpellIconBg:SetBackdrop({
        bgFile   = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    ammoSpellIconBg:SetBackdropColor(0, 0, 0, 0.82)
    ammoSpellIconBg:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.9)
    ammoSpellIconBg:Hide()
    ProcState.ammoSpellIconBg = ammoSpellIconBg

    local ammoSpellIcon = ammoSpellIconBg:CreateTexture(nil, "ARTWORK")
    ammoSpellIcon:SetWidth(iconSize)
    ammoSpellIcon:SetHeight(iconSize)
    ammoSpellIcon:SetPoint("CENTER", ammoSpellIconBg, "CENTER", 0, 0)
    ammoSpellIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    ProcState.ammoSpellIcon = ammoSpellIcon

    -- Keybind text overlaid at bottom of the spell icon
    local ammoKeybindText = ammoSpellIconBg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ammoKeybindText:SetPoint("BOTTOM", ammoSpellIconBg, "BOTTOM", 0, 2)
    ammoKeybindText:SetTextColor(1, 1, 0, 1)
    ammoKeybindText:SetText("")
    ProcState.ammoKeybindText = ammoKeybindText

    -- Cooldown timer overlaid in center of the spell icon (shown when spell is on CD)
    local ammoSpellCdTimer = ammoSpellIconBg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ammoSpellCdTimer:SetPoint("CENTER", ammoSpellIconBg, "CENTER", 0, 0)
    ammoSpellCdTimer:SetTextColor(1, 0.9, 0.1, 1)
    ammoSpellCdTimer:SetText("")
    ProcState.ammoSpellCdTimer = ammoSpellCdTimer

    -- 3 slots
    f:SetWidth(3 * slotW + 2 * padding + dragPad * 2)
end

-- ============ OnUpdate (throttled) ============
ProcModule:SetScript("OnUpdate", function()
    if not ProcState.procFrame then return end

    local db = GetDB()
    if db.procFrameEnabled == false then
        if ProcState.procFrame:IsShown() then ProcState.procFrame:Hide() end
        return
    end

    local now = GetTime()
    if now - ProcState.lastUpdate < ProcState.UPDATE_INTERVAL then return end
    ProcState.lastUpdate = now

    -- Wrap in pcall so a single runtime error doesn't permanently break the display loop
    local ok, err = pcall(function()
        ScanProcs()
        HHT_UpdateProcDisplay()
    end)
    if not ok and err then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF4444HHT ProcFrame OnUpdate error:|r " .. tostring(err), 1, 0.3, 0.3)
    end
end)

-- ============ Event Handler ============
ProcModule:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        ProcModule:UnregisterEvent("VARIABLES_LOADED")
        HHT_ProcFrame_Initialize()

    elseif event == "AURA_CAST_ON_SELF" then
        -- Nampower: fires BEFORE BUFF_ADDED_SELF. arg1=spellId, arg8=durationMs
        -- DoiteAuras Refresh-Fix: if LnL already active → re-proc → update expireTime NOW.
        -- This is the authoritative refresh mechanism. No slot scanning needed.
        local spellId    = tonumber(arg1) or 0
        local durationMs = tonumber(arg8) or 0
        if spellId == LNL_SPELL_ID and durationMs > 0 then
            if ProcState.lnlActive then
                -- Re-proc while active: refresh timer immediately from server duration
                ProcState.lnlExpireTime = GetTime() + durationMs / 1000
                HHT_UpdateProcDisplay()
            end
            -- Cache for BUFF_ADDED_SELF (first proc)
            ProcState.pendingDurationMs[spellId] = durationMs
        elseif spellId > 0 and durationMs > 0 then
            -- Other spells (ammo etc.)
            ProcState.pendingDurationMs[spellId] = durationMs
        end

    elseif event == "BUFF_ADDED_SELF" then
        -- Nampower: fires after AURA_CAST_ON_SELF. arg3=spellId, arg6=auraSlot (0-based)
        local spellId  = tonumber(arg3) or 0
        local auraSlot = tonumber(arg6) or 0
        if spellId == LNL_SPELL_ID then
            local cached = ProcState.pendingDurationMs[LNL_SPELL_ID]
            ProcState.pendingDurationMs[LNL_SPELL_ID] = nil
            local durationMs = cached
            if not durationMs or durationMs <= 0 then
                local ok, _, rem = pcall(GetPlayerAuraDuration, auraSlot)
                if ok and rem and rem > 0 then durationMs = rem end
            end
            ProcState.lnlActive     = true
            ProcState.lnlSlot       = auraSlot
            ProcState.lnlExpireTime = (durationMs and durationMs > 0) and (GetTime() + durationMs / 1000) or 0
            HHT_UpdateProcDisplay()
        end

    elseif event == "BUFF_REMOVED_SELF" then
        -- Nampower: arg3=spellId, arg7=state (1=fully removed, 2=refresh/re-applied)
        -- state=2 means buff was refreshed; AURA_CAST_ON_SELF already updated expireTime.
        local spellId = tonumber(arg3) or 0
        local state   = tonumber(arg7) or 1
        if state == 2 then return end
        if spellId == LNL_SPELL_ID then
            ProcState.lnlActive     = false
            ProcState.lnlSlot       = 0
            ProcState.lnlExpireTime = 0
            HHT_UpdateProcDisplay()
        end

    elseif event == "DEBUFF_ADDED_SELF" then
        -- Nampower: fires instantly when a player debuff is added.
        -- arg3=spellId, arg6=auraSlot (0-based, 32-47 for debuffs), arg7=state (0=added, 2=stacks changed)
        local spellId  = tonumber(arg3) or 0
        local auraSlot = tonumber(arg6) or 0
        if spellId <= 0 then return end
        -- Identify ammo type via spell name (locale-independent)
        local ok, name = pcall(GetSpellNameAndRankForId, spellId)
        local amType = nil
        if ok and name and name ~= "" then
            if string.find(name, AMMO_BUFF_EXPLOSIVE, 1, true) then
                amType = "explosive"
            elseif string.find(name, AMMO_BUFF_POISONOUS, 1, true) then
                amType = "poisonous"
            elseif string.find(name, AMMO_BUFF_ENCHANTED, 1, true) then
                amType = "enchanted"
            end
        end
        if amType then
            -- GetPlayerAuraDuration returns (spellId, remainingMs, expiryTimestamp)
            local cached = ProcState.pendingDurationMs[spellId]
            local durationMs = cached
            if not durationMs or durationMs <= 0 then
                local ok, _, remainingMs = pcall(GetPlayerAuraDuration, auraSlot)
                if ok and remainingMs and remainingMs > 0 then durationMs = remainingMs end
            end
            ProcState.pendingDurationMs[spellId] = nil
            ProcState.ammoActive     = true
            ProcState.ammoSlot       = auraSlot
            ProcState.ammoIsDebuff   = true
            ProcState.ammoType       = amType
            ProcState.ammoSpellId    = spellId
            ProcState.ammoExpireTime = (durationMs and durationMs > 0) and (GetTime() + durationMs / 1000) or 0
            HHT_UpdateProcDisplay()
        end

    elseif event == "DEBUFF_REMOVED_SELF" then
        -- Nampower: fires when a player debuff is fully removed.
        -- arg3=spellId, arg7=state (1=fully removed, 2=stack decrease)
        local spellId = tonumber(arg3) or 0
        local state   = tonumber(arg7) or 1
        if state == 2 then return end
        if ProcState.ammoActive and ProcState.ammoSpellId == spellId then
            ProcState.ammoActive     = false
            ProcState.ammoSlot       = 0
            ProcState.ammoType       = nil
            ProcState.ammoSpellId    = nil
            ProcState.ammoExpireTime = 0
            HHT_UpdateProcDisplay()
        end

    elseif event == "UNIT_BUFF" then
        -- Table stable: re-read duration to catch re-proc (the ONLY fix needed here).
        if arg1 == "player" and ProcState.lnlActive then
            local ok, _, rem = pcall(GetPlayerAuraDuration, ProcState.lnlSlot)
            if ok and rem and rem > 0 then
                ProcState.lnlExpireTime = GetTime() + rem / 1000
                HHT_UpdateProcDisplay()
            end
        end

    elseif event == "PLAYER_AURAS_CHANGED" then
        -- bootstrap fallback only
        ScanProcs()

    elseif event == "PLAYER_ENTERING_WORLD" then
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

-- Reposition all enabled slots left-to-right (called after enable/disable or icon size change)
function HHT_ProcFrame_RebuildLayout()
    if not ProcState.procFrame then return end
    local db = GetDB()
    local iconSize = db.procFrameIconSize or 40
    local padding  = 6
    local dragPad  = 8
    local slotW    = iconSize + 4

    local lnlEnabled  = (db.procFrameLnlEnabled  ~= false)
    local ammoEnabled = (db.procFrameAmmoEnabled ~= false)
    local kcEnabled   = (db.procFrameKcEnabled   ~= false)

    -- Build ordered list of enabled slot backgrounds
    local slots = {}
    local numSlots = 0
    if lnlEnabled  and ProcState.lnlBg  then numSlots = numSlots + 1; slots[numSlots] = ProcState.lnlBg  end
    if ammoEnabled and ProcState.ammoBg then numSlots = numSlots + 1; slots[numSlots] = ProcState.ammoBg end
    if kcEnabled   and ProcState.kcBg   then numSlots = numSlots + 1; slots[numSlots] = ProcState.kcBg   end

    local numEnabled = math.max(1, numSlots)
    local frameW = numEnabled * slotW + math.max(0, numEnabled - 1) * padding + dragPad * 2
    ProcState.procFrame:SetWidth(frameW)

    for i, bg in ipairs(slots) do
        local xOff = (i - 1) * (slotW + padding)
        bg:ClearAllPoints()
        bg:SetPoint("LEFT", ProcState.procFrame, "LEFT", dragPad + xOff, 0)
    end
end

-- Called from config tab when settings change
function HHT_ProcFrame_UpdateSettings()
    if not ProcState.procFrame then return end
    HHT_ProcFrame_RebuildLayout()
    ScanProcs()
    HHT_UpdateProcDisplay()
end

-- Show preview with dummy data (called from ShowConfigPreview in main addon)
function HHT_ProcFrame_ShowPreview()
    if not ProcState.procFrame then return end

    local db = GetDB()
    if not db.procFrameEnabled then return end

    ProcState.previewMode = true

    local lnlEnabled  = (db.procFrameLnlEnabled  ~= false)
    local ammoEnabled = (db.procFrameAmmoEnabled ~= false)
    local kcEnabled   = (db.procFrameKcEnabled   ~= false)

    -- LnL slot preview
    if lnlEnabled and ProcState.lnlBg then
        ProcState.lnlActive = true
        if ProcState.lnlIcon  then ProcState.lnlIcon:SetTexture("Interface\\Icons\\ability_hunter_lockandload"); ProcState.lnlIcon:SetAlpha(1.0) end
        if ProcState.lnlTimer then ProcState.lnlTimer:SetText("8.0"); ProcState.lnlTimer:SetTextColor(1, 1, 1, 1) end
        if ProcState.lnlGlow  then ProcState.lnlGlow:SetAlpha(0.35) end
        ProcState.lnlBg:Show()
    end

    -- Ammo slot preview
    if ammoEnabled and ProcState.ammoBg then
        ProcState.ammoActive = true
        ProcState.ammoType   = "explosive"
        if ProcState.ammoIcon  then ProcState.ammoIcon:SetTexture("Interface\\Icons\\Spell_Fire_SelfDestruct"); ProcState.ammoIcon:SetAlpha(1.0) end
        if ProcState.ammoTimer then ProcState.ammoTimer:SetText("!"); ProcState.ammoTimer:SetTextColor(1, 1, 0, 1) end
        if ProcState.ammoGlow  then ProcState.ammoGlow:SetAlpha(0.35) end
        ProcState.ammoBg:Show()
        -- Spell icon overlay
        if ProcState.ammoSpellIconBg then ProcState.ammoSpellIconBg:Show() end
        if ProcState.ammoSpellIcon and ProcState.ammoSpellIconExplosive then
            ProcState.ammoSpellIcon:SetTexture(ProcState.ammoSpellIconExplosive)
            ProcState.ammoSpellIcon:SetAlpha(1.0)
        end
        if ProcState.ammoKeybindText then
            local key = GetSpellKeybind("Multi-Shot")
            ProcState.ammoKeybindText:SetText(key and ("[" .. key .. "]") or "")
        end
    end

    -- Kill Command slot preview
    if kcEnabled and ProcState.kcBg then
        ProcState.kcReady       = true
        ProcState.kcCooldownEnd = 0
        if ProcState.kcIcon  then ProcState.kcIcon:SetTexture("Interface\\Icons\\Ability_Hunter_KillCommand"); ProcState.kcIcon:SetAlpha(1.0) end
        if ProcState.kcTimer then ProcState.kcTimer:SetText("GO"); ProcState.kcTimer:SetTextColor(0.2, 1, 0.2, 1) end
        if ProcState.kcGlow  then ProcState.kcGlow:SetAlpha(0.35) end
        ProcState.kcBg:Show()
    end

    ProcState.procFrame:Show()
end

-- Hide preview / restore normal state (called from HideConfigPreview in main addon)
function HHT_ProcFrame_HidePreview()
    if not ProcState.procFrame then return end
    -- Disable preview mode first so ScanProcs runs again
    ProcState.previewMode   = false
    -- Reset dummy state
    ProcState.lnlActive     = false
    ProcState.lnlSlot       = 0
    ProcState.ammoActive    = false
    ProcState.ammoSlot      = 0
    ProcState.ammoType      = nil
    ProcState.kcReady       = false
    ProcState.kcCooldownEnd = 0
    ScanProcs(true)
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
    ResizeSlot(ProcState.kcBg,   ProcState.kcIcon,   ProcState.kcGlow)

    -- Resize ammo spell icon overlay (same size as main icon)
    if ProcState.ammoSpellIconBg then
        ProcState.ammoSpellIconBg:SetWidth(slotW)
        ProcState.ammoSpellIconBg:SetHeight(newSize + 4)
    end
    if ProcState.ammoSpellIcon then
        ProcState.ammoSpellIcon:SetWidth(newSize)
        ProcState.ammoSpellIcon:SetHeight(newSize)
    end

    -- Reposition slots based on which are enabled
    HHT_ProcFrame_RebuildLayout()
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

-- ============ LnL status command (/hht lnl) ============
function HHT_LnlStatus()
    local now = GetTime()
    local left = ProcState.lnlExpireTime > 0 and (ProcState.lnlExpireTime - now) or 0
    DEFAULT_CHAT_FRAME:AddMessage(
        string.format("|cFFABD473HHT LnL:|r active=%s slot=%s timeLeft=%.1f",
            tostring(ProcState.lnlActive),
            tostring(ProcState.lnlSlot),
            left),
        0.67, 0.83, 0.45)
end

-- ============ Initialize ============
local function CacheSpellBookInfo()
    local ammoToFind = {
        ["Multi-Shot"]    = "ammoSpellIconExplosive",
        ["Serpent Sting"] = "ammoSpellIconPoisonous",
        ["Arcane Shot"]   = "ammoSpellIconEnchanted",
    }
    local ammoSlotMap = {
        ["Multi-Shot"]    = "ammoSpellSlotExplosive",
        ["Serpent Sting"] = "ammoSpellSlotPoisonous",
        ["Arcane Shot"]   = "ammoSpellSlotEnchanted",
    }
    local ammoRemaining = 3
    for i = 1, 300 do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        -- Cache Kill Command spell slot
        if name == KC_SPELL_NAME and not ProcState.kcSpellSlot then
            ProcState.kcSpellSlot = i
        end
        -- Cache ammo spell icons + slot numbers
        local key = ammoToFind[name]
        if key and not ProcState[key] then
            ProcState[key] = GetSpellTexture(i, BOOKTYPE_SPELL)
            ProcState[ammoSlotMap[name]] = i  -- cache slot# for GetSpellCooldown
            ammoRemaining = ammoRemaining - 1
        end
        -- Stop early when everything found
        if ammoRemaining <= 0 and ProcState.kcSpellSlot then break end
    end

    -- Find KC on the action bar by matching its icon texture.
    -- IsUsableAction(slot) is what the action bar itself uses - correctly reflects proc state.
    if ProcState.kcSpellSlot then
        local kcTex = GetSpellTexture(ProcState.kcSpellSlot, BOOKTYPE_SPELL)
        if kcTex then
            kcTex = string.lower(kcTex)
            local i
            for i = 1, 120 do
                if HasAction(i) then
                    local aTex = GetActionTexture(i)
                    if aTex and string.lower(aTex) == kcTex then
                        ProcState.kcActionSlot = i
                        break
                    end
                end
            end
        end
    end
end

function HHT_ProcFrame_Initialize()
    -- Wait until DB is loaded by the WoW client
    if not HamingwaysHunterToolsDB then
        ProcModule:RegisterEvent("VARIABLES_LOADED")
        return
    end

    -- Don't double-create if already initialized
    if ProcState.procFrame then return end

    -- Create the frame
    local ok, err = pcall(CreateProcFrame)
    if not ok then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF4444HHT ProcFrame FEHLER:|r " .. tostring(err), 1, 0.2, 0.2)
        return
    end

    -- Cache spell icons + KC slot from spellbook (non-fatal if unavailable)
    pcall(CacheSpellBookInfo)

    -- Register events
    ProcModule:RegisterEvent("PLAYER_AURAS_CHANGED")  -- standard vanilla: fires on any aura change, stable next frame
    ProcModule:RegisterEvent("UNIT_BUFF")              -- Nampower polyfill, belt+suspenders
    ProcModule:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- Nampower: event-driven LnL/Ammo tracking
    ProcModule:RegisterEvent("AURA_CAST_ON_SELF")
    ProcModule:RegisterEvent("BUFF_ADDED_SELF")
    ProcModule:RegisterEvent("BUFF_REMOVED_SELF")
    ProcModule:RegisterEvent("DEBUFF_ADDED_SELF")
    ProcModule:RegisterEvent("DEBUFF_REMOVED_SELF")

    -- Nampower availability check (hard dependency for accurate proc timers)
    if not GetPlayerBuffTimeLeft then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cFFFF4444HHT:|r Nampower nicht gefunden! Proc Frame benötigt Nampower für korrekte Timer.",
            1, 0.3, 0.3)
    end

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cFFABD473HHT:|r Proc Frame loaded. Use |cFFFFFF00/hht proc scan|r to discover buff textures.",
        0.67, 0.83, 0.45)
end

-- Kick off initialization (will wait for VARIABLES_LOADED if DB not ready yet)
HHT_ProcFrame_Initialize()
