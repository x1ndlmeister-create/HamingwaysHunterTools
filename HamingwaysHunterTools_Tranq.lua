-- ========================================================================
-- Hamingway's Hunter Tools - Tranq Shot Announcer
-- ========================================================================
-- Cross-compatible with Quiver addon (dual-channel messaging)
-- Tracks hunter Tranq Shot cooldowns in raid/party
-- Does NOT auto-detect Boss Frenzy (use BigWigs/DBM/manual watch)
-- ========================================================================

-- Tranq Shot spell ID (5,000 spell ID in WoW 1.12)
local TRANQ_SHOT_SPELL_ID = 19801
local TRANQ_COOLDOWN = 20  -- 20 seconds
local TRANQ_SPELL_NAME = "Tranquilizing Shot"

-- Hunter cooldown tracker
local hunterCooldowns = {}  -- [playerName] = { endTime = time, startTime = time, missed = bool }

-- UI Frame
local tranqFrame = nil
local progressBars = {}  -- Array of progress bar frames

-- Object pool for progress bars (memory efficiency)
local progressBarPool = {}

-- Event frame
local eventFrame = CreateFrame("Frame")
local isEnabled = false
local previewMode = false  -- Flag for preview mode

-- ========================================================================
-- Helper Functions
-- ========================================================================

-- Initialize defaults ONCE (called only at addon load)
-- Note: Main GetConfig() handles initialization, this is just a safety check
local function InitializeDefaults()
    if not HamingwaysHunterToolsDB then
        HamingwaysHunterToolsDB = {}
    end
    -- Defaults are set by GetConfig() in main addon file
end

-- Simple getter (never modifies DB)
local function GetConfig()
    return HamingwaysHunterToolsDB or {}
end

-- Format message with %t (target) and %p (player) placeholders
local function FormatMessage(msg)
    local target = UnitName("target") or "Unknown"
    local player = UnitName("player") or "Unknown"
    
    msg = string.gsub(msg, "%%t", target)
    msg = string.gsub(msg, "%%p", player)
    
    return msg
end

-- Send chat message based on channel setting
local function SendChatMessage_Safe(msg)
    local cfg = GetConfig()
    local channel = cfg.tranqChannel
    
    if channel == "Raid" and GetNumRaidMembers() > 0 then
        SendChatMessage(msg, "RAID")
    elseif channel == "Party" and GetNumPartyMembers() > 0 then
        SendChatMessage(msg, "PARTY")
    elseif channel == "Say" then
        SendChatMessage(msg, "SAY")
    elseif channel == "Yell" then
        SendChatMessage(msg, "YELL")
    end
    -- "None (addon-only)" = no chat message
end

-- ========================================================================
-- Progress Bar Object Pool
-- ========================================================================

local function CreateProgressBar()
    local bar = CreateFrame("Frame", nil, tranqFrame)
    bar:SetWidth(280)
    bar:SetHeight(20)
    local cfg = GetConfig()
    local borderSize = cfg.borderSize or 12
    
    -- Use same backdrop style as AutoShot/Castbar
    local borderStyle = cfg.borderStyle or "Interface\\Tooltips\\UI-Tooltip-Border"
    local insetSize = 2
    if borderStyle == "Interface\\BUTTONS\\WHITE8X8" then
        insetSize = 1
    end
    -- IMPORTANT: If borderSize is 0, insets must also be 0 and edgeFile must be nil!
    if borderSize and borderSize <= 0 then
        insetSize = 0
        borderStyle = nil  -- No edge when border size is 0
    end
    
    bar:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = borderStyle,
        tile = false,
        edgeSize = borderSize,
        insets = { left = insetSize, right = insetSize, top = insetSize, bottom = insetSize }
    })
    bar:SetBackdropColor(0, 0, 0, 0.8)
    
    -- Set border colors based on style (matching CreateBackdrop logic)
    if borderStyle == "Interface\\BUTTONS\\WHITE8X8" then
        bar:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.8)  -- Dark for Simple style
    elseif borderSize and borderSize > 0 then
        bar:SetBackdropBorderColor(0.6, 0.7, 0.7, 1.0)  -- Light cyan for Tooltip/Dialog
    else
        bar:SetBackdropBorderColor(1, 1, 1, 1)
    end
    
    -- Progress fill - Use TEXTURE in BORDER layer (between background and text OVERLAY)
    bar.fill = bar:CreateTexture(nil, "BORDER")
    bar.fill:SetTexture(cfg.barStyle or "Interface\\TargetingFrame\\UI-StatusBar")
    bar.fill:SetPoint("TOPLEFT", bar, "TOPLEFT", insetSize, -insetSize)
    bar.fill:SetPoint("BOTTOM", bar, "BOTTOM", 0, insetSize)
    bar.fill:SetWidth(1)
    bar.fill:SetVertexColor(1, 0, 0, 1)  -- Red when full CD
    
    -- Store insetSize for width calculations
    bar.insetSize = insetSize
    
    -- Player name text - OVERLAY layer is above BORDER texture
    bar.nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.nameText:SetPoint("LEFT", bar, "LEFT", 5, 0)
    bar.nameText:SetJustifyH("LEFT")
    bar.nameText:SetTextColor(1, 1, 1, 1)
    
    -- Timer text - OVERLAY layer is above BORDER texture
    bar.timerText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.timerText:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
    bar.timerText:SetJustifyH("RIGHT")
    bar.timerText:SetTextColor(1, 1, 1, 1)
    
    -- Blink timer for missed shots
    bar.blinkTimer = 0
    bar.blinkState = false
    
    bar:Hide()
    return bar
end

local function GetProgressBar()
    if table.getn(progressBarPool) > 0 then
        return table.remove(progressBarPool)
    end
    return CreateProgressBar()
end

local function ReturnProgressBar(bar)
    bar:Hide()
    bar.playerName = nil
    bar.missed = false
    bar.blinkState = false
    bar:SetAlpha(1.0)
    table.insert(progressBarPool, bar)
end

-- ========================================================================
-- Color Gradient (Red -> Green, perceptually uniform)
-- ========================================================================

-- Quiver-style 17-stop gradient (red at 0%, green at 100%)
local colorStops = {
    {0.00, {1.00, 0.00, 0.00}},
    {0.06, {1.00, 0.25, 0.00}},
    {0.12, {1.00, 0.40, 0.00}},
    {0.19, {1.00, 0.55, 0.00}},
    {0.25, {1.00, 0.65, 0.00}},
    {0.31, {1.00, 0.75, 0.00}},
    {0.38, {1.00, 0.85, 0.00}},
    {0.44, {1.00, 0.95, 0.00}},
    {0.50, {1.00, 1.00, 0.00}},
    {0.56, {0.85, 1.00, 0.00}},
    {0.62, {0.70, 1.00, 0.00}},
    {0.69, {0.55, 1.00, 0.00}},
    {0.75, {0.40, 1.00, 0.00}},
    {0.81, {0.25, 1.00, 0.00}},
    {0.88, {0.10, 1.00, 0.00}},
    {0.94, {0.00, 1.00, 0.15}},
    {1.00, {0.00, 1.00, 0.00}}
}

local function GetProgressColor(percent)
    for i = 1, table.getn(colorStops) - 1 do
        local current = colorStops[i]
        local next = colorStops[i + 1]
        
        if percent >= current[1] and percent <= next[1] then
            local range = next[1] - current[1]
            local t = (percent - current[1]) / range
            
            local r = current[2][1] + (next[2][1] - current[2][1]) * t
            local g = current[2][2] + (next[2][2] - current[2][2]) * t
            local b = current[2][3] + (next[2][3] - current[2][3]) * t
            
            return r, g, b
        end
    end
    
    -- Fallback
    return 0, 1, 0
end

-- ========================================================================
-- UI Update
-- ========================================================================

local function UpdateProgressBars()
    if not tranqFrame then return end
    
    local now = GetTime()
    
    -- Clear old bars
    for i = 1, table.getn(progressBars) do
        ReturnProgressBar(progressBars[i])
    end
    progressBars = {}
    
    -- Collect active cooldowns
    local activeCooldowns = {}
    for playerName, data in pairs(hunterCooldowns) do
        local remaining = data.endTime - now
        
        -- In preview mode: loop cooldowns when they expire
        if previewMode and remaining <= 0 then
            data.startTime = now
            data.endTime = now + TRANQ_COOLDOWN
            remaining = TRANQ_COOLDOWN
        end
        
        if remaining > 0 then
            table.insert(activeCooldowns, {
                name = playerName,
                endTime = data.endTime,
                startTime = data.startTime,
                remaining = remaining,
                missed = data.missed or false
            })
        else
            -- Expired, remove (only in non-preview mode)
            if not previewMode then
                hunterCooldowns[playerName] = nil
            end
        end
    end
    
    -- Sort by remaining time (ascending)
    table.sort(activeCooldowns, function(a, b)
        return a.remaining < b.remaining
    end)
    
    -- Create bars
    for i, cd in ipairs(activeCooldowns) do
        local bar = GetProgressBar()
        bar.playerName = cd.name
        bar.missed = cd.missed
        
        local elapsed = now - cd.startTime
        local percentElapsed = math.min(elapsed / TRANQ_COOLDOWN, 1.0)
        local percentRemaining = 1.0 - percentElapsed
        
        -- Update fill width (shows remaining time, full at start)
        -- Use bar.insetSize for accurate width calculation (2 insets on each side)
        local maxWidth = 280 - (bar.insetSize * 2)
        bar.fill:SetWidth(maxWidth * percentRemaining)
        -- Update color (red at start, green at end) - Use SetVertexColor for Texture
        local r, g, b = GetProgressColor(percentElapsed)
        bar.fill:SetVertexColor(r, g, b, 1)
        
        -- Update texts
        if cd.missed then
            bar.nameText:SetText(cd.name .. " |cFFFF0000MISSED|r")
        else
            bar.nameText:SetText(cd.name)
        end
        bar.timerText:SetText(string.format("%.1fs", cd.remaining))
        
        -- Position (20px bar height + 1px spacing)
        bar:SetPoint("TOPLEFT", 0, -(i - 1) * 21)
        bar:Show()
        
        table.insert(progressBars, bar)
    end
    
    -- Resize frame height
    local numBars = table.getn(activeCooldowns)
    if numBars > 0 then
        tranqFrame:SetHeight(numBars * 21 - 1)  -- 21px per bar, minus 1px for last bar (no spacing after)
        tranqFrame:Show()
    else
        tranqFrame:Hide()
    end
end

-- ========================================================================
-- Event Handlers
-- ========================================================================

local function OnSpellUpdateCooldown()
    -- Detect Tranq Shot cast via cooldown start
    local start, duration = GetSpellCooldown(TRANQ_SHOT_SPELL_ID, BOOKTYPE_SPELL)
    
    if start and start > 0 and duration and duration >= TRANQ_COOLDOWN then
        -- Tranq Shot cast detected!
        local playerName = UnitName("player")
        local now = GetTime()
        
        hunterCooldowns[playerName] = {
            startTime = now,
            endTime = now + TRANQ_COOLDOWN
        }
        
        -- Send addon message
        local cfg = GetConfig()
        local latency = 0
        local _, _, lag = GetNetStats()
        if lag then latency = lag end
        
        -- Quiver compatibility
        if cfg.quiverCompat then
            local msg = "Quiver_Tranq_Shot:" .. playerName .. ":" .. latency
            SendAddonMessage("Quiver", msg, "RAID")
        end
        
        -- HHT format
        local msg = "HHT_Tranq:" .. playerName .. ":" .. latency
        SendAddonMessage("HamingwaysHunterTools", msg, "RAID")
        
        -- Chat message
        local castMsg = FormatMessage(cfg.tranqCastMsg)
        SendChatMessage_Safe(castMsg)
        
        UpdateProgressBars()
    end
end

local function OnChatMsgAddon()
    -- Receive other hunters' Tranq casts
    local prefix = arg1
    local message = arg2
    local channel = arg3
    local sender = arg4
    
    if channel ~= "RAID" and channel ~= "PARTY" then return end
    
    local playerName, latency
    
    -- Quiver format
    if prefix == "Quiver" and string.find(message, "Quiver_Tranq_Shot:") then
        local _, _, name, lat = string.find(message, "Quiver_Tranq_Shot:([^:]+):(%d+)")
        if name then
            playerName = name
            latency = tonumber(lat) or 0
        end
    end
    
    -- HHT format
    if prefix == "HamingwaysHunterTools" and string.find(message, "HHT_Tranq:") then
        local _, _, name, lat = string.find(message, "HHT_Tranq:([^:]+):(%d+)")
        if name then
            playerName = name
            latency = tonumber(lat) or 0
        end
    end
    
    if playerName and playerName ~= UnitName("player") then
        local now = GetTime()
        hunterCooldowns[playerName] = {
            startTime = now,
            endTime = now + TRANQ_COOLDOWN
        }
        UpdateProgressBars()
    end
end

local function OnChatMsgSpellSelfDamage()
    -- Detect Tranq Shot miss
    local msg = arg1
    
    if msg and (
        string.find(msg, TRANQ_SPELL_NAME) and (
            string.find(msg, "miss") or 
            string.find(msg, "resist") or 
            string.find(msg, "dodge") or
            string.find(msg, "parry")
        )
    ) then
        -- Tranq missed! Mark cooldown as missed
        local playerName = UnitName("player")
        if hunterCooldowns[playerName] then
            hunterCooldowns[playerName].missed = true
            UpdateProgressBars()
        end
        
        local cfg = GetConfig()
        local missMsg = FormatMessage(cfg.tranqMissMsg)
        SendChatMessage_Safe(missMsg)
    end
end

-- ========================================================================
-- OnUpdate (for progress bar refresh)
-- ========================================================================

local updateInterval = 0.1
local timeSinceLastUpdate = 0
local fadeTimer = 0  -- Continuous timer for smooth fade in/out

local function OnUpdate()
    local elapsed = arg1 or 0
    timeSinceLastUpdate = timeSinceLastUpdate + elapsed
    fadeTimer = fadeTimer + elapsed
    
    -- PERFORMANCE: Early exit if no bars to update
    if table.getn(progressBars) == 0 then return end
    
    -- Update progress bars
    if timeSinceLastUpdate >= updateInterval then
        UpdateProgressBars()
        timeSinceLastUpdate = 0
    end
    
    -- Smooth fade effect for missed bars (1 sec out, 1 sec in = 2 sec cycle)
    local fadeCycle = 2.0  -- Total cycle duration
    local t = math.mod(fadeTimer, fadeCycle) / fadeCycle  -- 0 to 1 (Lua 5.0: use math.mod)
    
    -- Sine wave for smooth fade: goes from 1.0 -> 0.15 -> 1.0
    local pi = 3.14159265359
    local alpha = 0.575 + 0.425 * math.cos(t * 2 * pi)
    
    -- PERFORMANCE: Apply fade only to bars that need it
    for i = 1, table.getn(progressBars) do
        local bar = progressBars[i]
        if bar.missed and bar.fill then
            bar.fill:SetAlpha(alpha)
        elseif bar.fill and bar.fill:GetAlpha() ~= 1.0 then
            bar.fill:SetAlpha(1.0)
        end
    end
end

-- ========================================================================
-- Enable/Disable Functions
-- ========================================================================

function HHT_Tranq_Enable()
    if isEnabled then return end
    isEnabled = true
    
    -- Register events
    eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    eventFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
    
    eventFrame:SetScript("OnEvent", function()
        if event == "SPELL_UPDATE_COOLDOWN" then
            OnSpellUpdateCooldown()
        elseif event == "CHAT_MSG_ADDON" then
            OnChatMsgAddon()
        elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
            OnChatMsgSpellSelfDamage()
        end
    end)
    
    -- OnUpdate always runs for blink effect (even in preview mode)
    if not eventFrame:GetScript("OnUpdate") then
        eventFrame:SetScript("OnUpdate", OnUpdate)
    end
    
    -- Show window if cooldowns exist
    UpdateProgressBars()
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Tranq Shot Announcer|r |cFF00FF00enabled|r")
end

function HHT_Tranq_Disable()
    if not isEnabled then return end
    isEnabled = false
    
    eventFrame:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
    eventFrame:UnregisterEvent("CHAT_MSG_ADDON")
    eventFrame:UnregisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
    
    eventFrame:SetScript("OnEvent", nil)
    eventFrame:SetScript("OnUpdate", nil)
    
    if tranqFrame then
        tranqFrame:Hide()
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Tranq Shot Announcer|r |cFFFF0000disabled|r")
end

-- ========================================================================
-- UI Window Creation
-- ========================================================================

local function CreateTranqWindow()
    if tranqFrame then return end
    
    tranqFrame = CreateFrame("Frame", "HHT_TranqFrame", UIParent)
    tranqFrame:SetWidth(300)
    tranqFrame:SetHeight(100)
    tranqFrame:SetPoint("CENTER", 0, 200)
    tranqFrame:SetMovable(true)
    tranqFrame:EnableMouse(true)
    tranqFrame:RegisterForDrag("LeftButton")
    tranqFrame:SetScript("OnDragStart", function() 
        if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.locked then
            this:StartMoving() 
        end
    end)
    tranqFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    tranqFrame:SetFrameStrata("MEDIUM")
    tranqFrame:Hide()
end

-- Update lock state
function HHT_Tranq_UpdateLock()
    if tranqFrame then
        local cfg = GetConfig()
        tranqFrame:SetMovable(not cfg.locked)
    end
end

function HHT_Tranq_ShowWindow()
    if not tranqFrame then
        CreateTranqWindow()
    end
    
    UpdateProgressBars()
    
    if table.getn(progressBars) > 0 then
        tranqFrame:Show()
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Tranq Shot Announcer:|r No active cooldowns")
    end
end

-- ========================================================================
-- Slash Command (for testing)
-- ========================================================================

function HHT_Tranq_SimulateCast()
    if not isEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Tranq Shot Announcer:|r |cFFFF0000Not enabled!|r Use /hht and enable it in Tab 9")
        return
    end
    
    -- Make sure window exists
    if not tranqFrame then
        CreateTranqWindow()
    end
    
    local playerName = UnitName("player")
    local now = GetTime()
    
    -- Add cooldown
    hunterCooldowns[playerName] = {
        startTime = now,
        endTime = now + TRANQ_COOLDOWN
    }
    
    -- Send addon message
    local cfg = GetConfig()
    local latency = 0
    local _, _, lag = GetNetStats()
    if lag then latency = lag end
    
    -- Quiver compatibility
    if cfg.quiverCompat then
        local msg = "Quiver_Tranq_Shot:" .. playerName .. ":" .. latency
        SendAddonMessage("Quiver", msg, "RAID")
    end
    
    -- HHT format
    local msg = "HHT_Tranq:" .. playerName .. ":" .. latency
    SendAddonMessage("HamingwaysHunterTools", msg, "RAID")
    
    -- Chat message
    local castMsg = FormatMessage(cfg.tranqCastMsg)
    SendChatMessage_Safe(castMsg)
    
    -- Force show window and update
    tranqFrame:Show()
    UpdateProgressBars()
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Tranq Shot Announcer:|r |cFF00FF00Simulated cast|r (20s cooldown started)")
end

SLASH_HHTTRANQ1 = "/hhttranq"
SlashCmdList["HHTTRANQ"] = function(msg)
    HHT_Tranq_SimulateCast()
end

-- ========================================================================
-- Preview Functions (for Config UI)
-- ========================================================================

function HHT_Tranq_ShowPreview()
    if not tranqFrame then
        CreateTranqWindow()
    end
    
    -- Ensure OnUpdate is running
    if not eventFrame:GetScript("OnUpdate") then
        eventFrame:SetScript("OnUpdate", OnUpdate)
    end
    
    -- Enable preview mode (allows looping cooldowns)
    previewMode = true
    
    -- Clear real cooldowns
    hunterCooldowns = {}
    
    -- Add preview hunters with cooldowns at different stages
    local now = GetTime()
    local previewHunters = {
        {name = "Hamingway the Hambringer", remaining = 3.5, missed = false},
        {name = "Nataja the Eggcollector", remaining = 7.2, missed = false},
        {name = "Sheriis", remaining = 12.8, missed = false},
        {name = "Shinya", remaining = 16.1, missed = true},  -- MISSED!
        {name = "Bagstreet", remaining = 19.3, missed = false}
    }
    
    for _, hunter in ipairs(previewHunters) do
        hunterCooldowns[hunter.name] = {
            startTime = now - (TRANQ_COOLDOWN - hunter.remaining),
            endTime = now + hunter.remaining,
            missed = hunter.missed
        }
    end
    
    tranqFrame:Show()
    tranqFrame:SetAlpha(1.0)  -- Always visible in preview
    UpdateProgressBars()  -- Initial display
end

function HHT_Tranq_HidePreview()
    -- Disable preview mode
    previewMode = false
    
    -- Clear preview data
    hunterCooldowns = {}
    
    if tranqFrame then
        tranqFrame:Hide()
    end
    
    -- Clear progress bars
    for i = 1, table.getn(progressBars) do
        ReturnProgressBar(progressBars[i])
    end
    progressBars = {}
end

-- Update bar style for all existing bars (called from config UI)
function HHT_Tranq_UpdateBarStyle()
    local cfg = GetConfig()
    local barStyle = cfg.barStyle or "Interface\\TargetingFrame\\UI-StatusBar"
    
    -- Update all active progress bars - fill is now a Texture again
    for i = 1, table.getn(progressBars) do
        if progressBars[i] and progressBars[i].fill then
            progressBars[i].fill:SetTexture(barStyle)
        end
    end
    
    -- Update all pooled bars
    for i = 1, table.getn(progressBarPool) do
        if progressBarPool[i] and progressBarPool[i].fill then
            progressBarPool[i].fill:SetTexture(barStyle)
        end
    end
end

-- Update border size and style for all existing bars (called from config UI)
function HHT_Tranq_UpdateBorder()
    local cfg = GetConfig()
    local borderSize = cfg.borderSize or 12
    local borderStyle = cfg.borderStyle or "Interface\\Tooltips\\UI-Tooltip-Border"
    
    -- Use same inset logic as CreateProgressBar
    local insetSize = 2
    if borderStyle == "Interface\\BUTTONS\\WHITE8X8" then
        insetSize = 1
    end
    -- IMPORTANT: If borderSize is 0, insets must also be 0 and edgeFile must be nil!
    if borderSize and borderSize <= 0 then
        insetSize = 0
        borderStyle = nil  -- No edge when border size is 0
    end
    
    -- Calculate border colors based on style
    local br, bg, bb, ba
    if borderStyle == "Interface\\BUTTONS\\WHITE8X8" then
        br, bg, bb, ba = 0.2, 0.2, 0.2, 0.8  -- Dark for Simple
    elseif borderSize and borderSize > 0 then
        br, bg, bb, ba = 0.6, 0.7, 0.7, 1.0  -- Light cyan for Tooltip/Dialog
    else
        br, bg, bb, ba = 1, 1, 1, 1
    end
    
    -- Update all active progress bars
    for i = 1, table.getn(progressBars) do
        if progressBars[i] then
            progressBars[i]:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = borderStyle,
                tile = false,
                edgeSize = borderSize,
                insets = { left = insetSize, right = insetSize, top = insetSize, bottom = insetSize }
            })
            progressBars[i]:SetBackdropColor(0, 0, 0, 0.8)
            progressBars[i]:SetBackdropBorderColor(br, bg, bb, ba)
            -- Update stored insetSize for width calculations
            progressBars[i].insetSize = insetSize
        end
    end
    
    -- Update all pooled bars
    for i = 1, table.getn(progressBarPool) do
        if progressBarPool[i] then
            progressBarPool[i]:SetBackdrop({
                bgFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = borderStyle,
                tile = false,
                edgeSize = borderSize,
                insets = { left = insetSize, right = insetSize, top = insetSize, bottom = insetSize }
            })
            progressBarPool[i]:SetBackdropColor(0, 0, 0, 0.8)
            progressBarPool[i]:SetBackdropBorderColor(br, bg, bb, ba)
            -- Update stored insetSize for width calculations
            progressBarPool[i].insetSize = insetSize
        end
    end
end

-- ========================================================================
-- Initialization
-- ========================================================================

local function Initialize()
    -- Wait for main addon to initialize DB
    if not HamingwaysHunterToolsDB then
        local initFrame = CreateFrame("Frame")
        initFrame:RegisterEvent("VARIABLES_LOADED")
        initFrame:SetScript("OnEvent", function()
            if arg1 == "VARIABLES_LOADED" and HamingwaysHunterToolsDB then
                this:UnregisterEvent("VARIABLES_LOADED")
                Initialize()
            end
        end)
        return
    end
    
    -- Initialize defaults ONCE at addon load
    InitializeDefaults()
    
    CreateTranqWindow()
    
    -- Start OnUpdate for blink effect (always, even when disabled)
    eventFrame:SetScript("OnUpdate", OnUpdate)
    
    -- Auto-enable if setting is true
    local cfg = GetConfig()
    if cfg.enableTranq then
        HHT_Tranq_Enable()
    end
end

-- Initialize on PLAYER_ENTERING_WORLD
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function()
    if arg1 == "PLAYER_ENTERING_WORLD" then
        this:UnregisterEvent("PLAYER_ENTERING_WORLD")
        Initialize()
    end
end)
