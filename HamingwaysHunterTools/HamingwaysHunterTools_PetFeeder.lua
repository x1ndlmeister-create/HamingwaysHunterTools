-- HamingwaysHunterTools_PetFeeder.lua
-- Pet Feeder Module
-- Handles pet feeding, happiness display, and food selection

-- Module frame
local PetFeederModule = CreateFrame("Frame", "HamingwaysHunterToolsPetFeederModule")

-- Module variables (global for main addon access)
HHT_PetFeedFrame = nil
HHT_PetIconButton = nil
HHT_FoodIconButton = nil
local foodMenuFrame = nil
local selectedFood = nil
local lastAttemptedFood = {}  -- Persistent table for reuse
local HHT_PetFeedBgFrame = nil  -- Background frame that shows the color

-- Constants
local DEFAULT_PET_FEEDER_ICON_SIZE = 32
local INACTIVE_COLOR_GRAY = 0.3
local CONTENT_COLOR_ORANGE = 0.6
local UNHAPPY_COLOR_RED = 0.8
local HAPPY_COLOR_GREEN = 0.6
local WARNING_COLOR = {r=1, g=0.5, b=0}

-- Pet Food Database (Item IDs by diet type)
local PET_FOODS = {
    fungus = {4607,8948,4604,4608,4605,3448,4606},
    fish = {13889,19996,13933,13888,13935,13546,6290,4593,5503,16971,2682,13927,2675,13930,5476,4655,6038,13928,13929,13893,4592,8364,13932,5095,6291,6308,13754,6317,6289,8365,6361,13758,6362,6303,8959,4603,13756,13760,4594,787,5468,15924,12216,8957,6887,5504,12206,13755,7974},
    meat = {21235,19995,4457,3173,2888,3730,3726,3220,2677,3404,12213,2679,769,2673,2684,1081,12224,5479,2924,3662,4599,17119,5478,5051,12217,2687,9681,2287,12204,3727,13851,12212,5472,5467,5480,1015,12209,3731,12223,3770,12037,4739,12184,13759,12203,12210,2681,5474,8952,1017,5465,6890,3712,3729,2680,17222,5471,5469,5477,2672,2685,3728,3667,12208,18045,5470,12202,117,12205,3771},
    bread = {1113,5349,1487,1114,8075,8076,22895,19696,21254,2683,4541,17197,3666,8950,4542,4544,4601,4540,16169},
    cheese = {8932,414,2070,422,3927,1707},
    fruit = {19994,8953,4539,16168,4602,4536,4538,4537,11950},
}

-- Helper to get config (uses main addon's DB)
local function GetConfig()
    return HamingwaysHunterToolsDB or {}
end

-- Cache for FindPetFoodInBags to prevent memory leak
local cachedFoodList = nil
local lastFoodScanTime = 0
local FOOD_SCAN_THROTTLE = 2  -- Responsive but prevents spam

-- Cache for UnitName("pet") to reduce string allocations  
local cachedPetName = nil
local lastPetNameCheck = 0
local PET_NAME_CACHE_DURATION = 1  -- seconds

-- Cache for HasFeedEffect to reduce tooltip scans
local cachedHasFeedEffect = false
local lastFeedEffectCheck = 0
local FEED_EFFECT_CACHE_DURATION = 1  -- seconds

-- Cache for UpdateDisplay to throttle UI updates and prevent string allocations
local lastDisplayUpdate = 0
local DISPLAY_UPDATE_THROTTLE = 0.2  -- seconds (5 FPS update rate)
local lastDisplayedCount = nil
local lastDisplayedFood = nil
local lastDisplayedHappiness = nil

-- Separate cache for selected food count (updated when FindPetFoodInBags is called)
local cachedSelectedFoodCount = 0
local cachedSelectedFoodItemID = nil

-- Persistent table pool for reuse (prevents memory allocations)
local persistentFoodList = {}
local persistentFoodCounts = {}

-- ============ Helper Functions ============
-- Global cache wrapper for UnitName("pet")
local function GetCachedPetName()
    local currentTime = GetTime()
    if currentTime - lastPetNameCheck < PET_NAME_CACHE_DURATION and cachedPetName then
        return cachedPetName
    end
    
    lastPetNameCheck = currentTime
    cachedPetName = UnitName("pet")
    return cachedPetName
end

local function HasPet()
    if not UnitExists("pet") then return false end
    local petName = GetCachedPetName()
    if petName == "Unknown Entity" or petName == "Unknown" or petName == UNKNOWNOBJECT then
        return false
    end
    return true
end

-- Global function to check if pet has feed buff (with caching to prevent excessive tooltip scans)
function HHT_PetFeeder_HasFeedEffect()
    local currentTime = GetTime()
    if currentTime - lastFeedEffectCheck < FEED_EFFECT_CACHE_DURATION then
        return cachedHasFeedEffect
    end
    
    lastFeedEffectCheck = currentTime
    local i = 1
    while UnitBuff("pet", i) do
        if HamingwaysHunterToolsTooltip then
            HamingwaysHunterToolsTooltip:SetOwner(UIParent, "ANCHOR_NONE")
            HamingwaysHunterToolsTooltip:SetUnitBuff("pet", i)
            local buffName = HamingwaysHunterToolsTooltipTextLeft1:GetText()
            HamingwaysHunterToolsTooltip:Hide()
            
            if buffName and (
               string.find(buffName, "Feed Pet Effect") or
               string.find(buffName, "Haustier.*Effect") or
               string.find(buffName, "Effet.*familier")
            ) then
                cachedHasFeedEffect = true
                return true
            end
        end
        i = i + 1
    end
    cachedHasFeedEffect = false
    return false
end

-- Local alias for internal use
local HasFeedEffect = HHT_PetFeeder_HasFeedEffect

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
    if not HasPet() then 
        if not cachedFoodList or table.getn(cachedFoodList) > 0 then
            cachedFoodList = {}
        end
        return cachedFoodList
    end
    
    -- Cache food list to prevent creating tables/strings
    -- Use longer cache during AFK (player position unchanged)
    local now = GetTime()
    if cachedFoodList and (now - lastFoodScanTime) < FOOD_SCAN_THROTTLE then
        return cachedFoodList
    end
    
    lastFoodScanTime = now
    
    -- Reuse existing tables instead of creating new ones
    local foodList = persistentFoodList
    local foodCounts = persistentFoodCounts
    
    -- Clear tables for reuse - properly clear array portion
    local n = table.getn(foodList)
    for i = 1, n do
        foodList[i] = nil
    end
    for k in pairs(foodCounts) do 
        foodCounts[k] = nil 
    end
    
    local foodIndex = 0  -- Manual counter for array insertion
    
    local petName = GetCachedPetName()
    local cfg = GetConfig()
    local blacklist = cfg.petFoodBlacklist and cfg.petFoodBlacklist[petName] or {}
    
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
                                    -- Reuse existing table, just update values
                                    local foodEntry = foodCounts[itemName]
                                    foodEntry.count = foodEntry.count + count
                                    foodEntry.bag = bag
                                    foodEntry.slot = slot
                                else
                                    -- Create new entry only if doesn't exist
                                    local foodEntry = {
                                        bag = bag,
                                        slot = slot,
                                        name = itemName,
                                        texture = texture,
                                        count = count,
                                        itemID = itemID
                                    }
                                    foodCounts[itemName] = foodEntry
                                    foodIndex = foodIndex + 1
                                    foodList[foodIndex] = foodEntry
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Cache the result
    cachedFoodList = foodList
    
    -- Also update cached count for selected food to avoid repeated calls in UpdateDisplay
    if selectedFood and selectedFood.itemID then
        cachedSelectedFoodItemID = selectedFood.itemID
        cachedSelectedFoodCount = 0
        for i = 1, table.getn(foodList) do
            if foodList[i] and foodList[i].itemID == selectedFood.itemID then
                cachedSelectedFoodCount = foodList[i].count
                break
            end
        end
    end
    
    return foodList
end

-- Global function for feeding pet (called from main addon)
function HHT_PetFeeder_FeedPet(silent)
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
    
    if HasFeedEffect() then
        return false
    end
    
    if HHT_PetFeedFrame and HHT_PetFeedFrame.lastSuccessfulFeed then
        local timeSinceLastFeed = GetTime() - HHT_PetFeedFrame.lastSuccessfulFeed
        if timeSinceLastFeed < 15 then
            return false
        end
    end
    
    local foodToFeed = nil
    local petName = GetCachedPetName()
    
    if petName and HamingwaysHunterToolsDB.selectedFood and HamingwaysHunterToolsDB.selectedFood[petName] then
        selectedFood = HamingwaysHunterToolsDB.selectedFood[petName]
    end
    
    if selectedFood then
        local texture, count = GetContainerItemInfo(selectedFood.bag, selectedFood.slot)
        if texture and count then
            foodToFeed = selectedFood
        else
            selectedFood = nil
            if HamingwaysHunterToolsDB.selectedFood then
                HamingwaysHunterToolsDB.selectedFood[petName] = nil
            end
        end
    end
    
    if not foodToFeed then
        local foodList = FindPetFoodInBags()
        if table.getn(foodList) > 0 and foodList[1] then
            foodToFeed = foodList[1]
            -- Create a copy to avoid reference issues
            selectedFood = {
                bag = foodToFeed.bag,
                slot = foodToFeed.slot,
                name = foodToFeed.name,
                texture = foodToFeed.texture,
                count = foodToFeed.count,
                itemID = foodToFeed.itemID
            }
            HamingwaysHunterToolsDB.selectedFood = HamingwaysHunterToolsDB.selectedFood or {}
            HamingwaysHunterToolsDB.selectedFood[petName] = selectedFood
        end
    end
    
    if not foodToFeed then
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r No pet food found", WARNING_COLOR.r, WARNING_COLOR.g, WARNING_COLOR.b)
        end
        return false
    end
    
    -- Reuse lastAttemptedFood table instead of creating new one
    lastAttemptedFood.bag = foodToFeed.bag
    lastAttemptedFood.slot = foodToFeed.slot
    lastAttemptedFood.name = foodToFeed.name
    lastAttemptedFood.texture = foodToFeed.texture
    lastAttemptedFood.itemID = foodToFeed.itemID
    lastAttemptedFood.petName = petName
    
    CastSpellByName("Feed Pet")
    PickupContainerItem(foodToFeed.bag, foodToFeed.slot)
    
    if CursorHasItem() then
        DropItemOnUnit("pet")
        if HHT_PetFeedFrame then
            HHT_PetFeedFrame.lastSuccessfulFeed = GetTime()
        end
        -- Invalidate caches so count/effect updates immediately
        cachedFoodList = nil
        cachedSelectedFoodItemID = nil
        cachedSelectedFoodCount = 0
        lastFeedEffectCheck = 0  -- Force feed effect check on next call
        lastDisplayedCount = nil  -- Force count text update
        lastDisplayUpdate = 0  -- Force display update
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r Fed " .. (foodToFeed.name or "pet"), 0.67, 0.83, 0.45)
        end
        return true
    end
    
    return false
end

-- Global function to update display (called from main addon)
function HHT_PetFeeder_UpdateDisplay(forceUpdate)
    if not HHT_PetFeedFrame then return end
    
    -- Throttle updates to reduce memory allocations (unless forced)
    local currentTime = GetTime()
    if not forceUpdate and (currentTime - lastDisplayUpdate) < DISPLAY_UPDATE_THROTTLE then
        return
    end
    
    -- Only update throttle timer for non-forced updates
    if not forceUpdate then
        lastDisplayUpdate = currentTime
    end
    
    if not HamingwaysHunterToolsDB or not HamingwaysHunterToolsDB.showPetFeeder then
        HHT_PetFeedFrame:Hide()
        return
    end
    
    if UnitExists("pet") and UnitIsDead("pet") then
        if HHT_PetIconButton and HHT_PetIconButton.icon then
            HHT_PetIconButton.icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastSoothe")
        end
        if HHT_PetFeedBgFrame then
            HHT_PetFeedBgFrame:SetBackdropColor(UNHAPPY_COLOR_RED, 0, 0, HamingwaysHunterToolsDB.bgOpacity)
        end
        HHT_PetFeedFrame:Show()
        return
    end
    
    if not HasPet() then
        if HHT_PetIconButton and HHT_PetIconButton.icon then
            HHT_PetIconButton.icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastCall")
        end
        if HHT_PetFeedBgFrame then
            HHT_PetFeedBgFrame:SetBackdropColor(INACTIVE_COLOR_GRAY, INACTIVE_COLOR_GRAY, INACTIVE_COLOR_GRAY, HamingwaysHunterToolsDB.bgOpacity)
        end
        -- Reset cached happiness so color updates correctly when pet is called again
        lastDisplayedHappiness = nil
        HHT_PetFeedFrame:Show()
        return
    end
    
    if HHT_PetIconButton and HHT_PetIconButton.icon then
        SetPortraitTexture(HHT_PetIconButton.icon, "pet")
    end
    
    local happiness = GetPetHappiness()
    
    -- Update color when forced OR when happiness changes
    local shouldUpdateColor = forceUpdate or (happiness and happiness ~= lastDisplayedHappiness)
    
    if happiness and HHT_PetFeedBgFrame and shouldUpdateColor then
        lastDisplayedHappiness = happiness
        if happiness == 1 then
            HHT_PetFeedBgFrame:SetBackdropColor(UNHAPPY_COLOR_RED, 0, 0, HamingwaysHunterToolsDB.bgOpacity)
        elseif happiness == 2 then
            HHT_PetFeedBgFrame:SetBackdropColor(UNHAPPY_COLOR_RED, CONTENT_COLOR_ORANGE, 0, HamingwaysHunterToolsDB.bgOpacity)
        elseif happiness == 3 then
            HHT_PetFeedBgFrame:SetBackdropColor(0, HAPPY_COLOR_GREEN, 0, HamingwaysHunterToolsDB.bgOpacity)
        else
            HHT_PetFeedBgFrame:SetBackdropColor(INACTIVE_COLOR_GRAY, INACTIVE_COLOR_GRAY, INACTIVE_COLOR_GRAY, HamingwaysHunterToolsDB.bgOpacity)
        end
    end
    
    -- Use cached pet name
    local petName = GetCachedPetName()
    
    if petName and HamingwaysHunterToolsDB.selectedFood and HamingwaysHunterToolsDB.selectedFood[petName] then
        selectedFood = HamingwaysHunterToolsDB.selectedFood[petName]
    end
    
    if selectedFood then
        -- Check current count directly from bag (fast, no table allocations)
        local currentCount = 0
        local texture, count = GetContainerItemInfo(selectedFood.bag, selectedFood.slot)
        if texture and count then
            currentCount = count
        else
            -- Item moved or consumed - scan bags to find it
            local foodList = FindPetFoodInBags()
            for i = 1, table.getn(foodList) do
                if foodList[i] and foodList[i].itemID == selectedFood.itemID then
                    currentCount = foodList[i].count
                    -- Update selectedFood with new bag/slot
                    selectedFood.bag = foodList[i].bag
                    selectedFood.slot = foodList[i].slot
                    break
                end
            end
        end
        
        if HHT_FoodIconButton and HHT_FoodIconButton.icon then
            -- Only update texture if food changed
            if lastDisplayedFood ~= selectedFood.itemID then
                lastDisplayedFood = selectedFood.itemID
                HHT_FoodIconButton.icon:SetTexture(selectedFood.texture)
            end
            
            if HasFeedEffect() then
                HHT_FoodIconButton.icon:SetVertexColor(0.4, 0.4, 0.4)
            else
                HHT_FoodIconButton.icon:SetVertexColor(1, 1, 1)
            end
            
            -- Only update count text when it changes (prevents tostring allocations)
            if HHT_FoodIconButton.countText and currentCount ~= lastDisplayedCount then
                lastDisplayedCount = currentCount
                HHT_FoodIconButton.countText:SetText(currentCount > 1 and tostring(currentCount) or "")
            end
        end
    else
        if HHT_FoodIconButton and HHT_FoodIconButton.icon then
            -- Reset displayed food so texture updates when food is selected again
            if lastDisplayedFood ~= nil then
                lastDisplayedFood = nil
                HHT_FoodIconButton.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                HHT_FoodIconButton.icon:SetVertexColor(1, 1, 1)
            end
            if HHT_FoodIconButton.countText then
                HHT_FoodIconButton.countText:SetText("")
            end
        end
    end
    
    HHT_PetFeedFrame:Show()
end

-- Show food selection menu
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
    
    if foodMenuFrame.buttons then
        for _, btn in ipairs(foodMenuFrame.buttons) do
            btn:Hide()
        end
    end
    
    -- Hide existing buttons and reset list
    if not foodMenuFrame.buttons then
        foodMenuFrame.buttons = {}
    end
    for i = 1, table.getn(foodMenuFrame.buttons) do
        if foodMenuFrame.buttons[i] then
            foodMenuFrame.buttons[i]:Hide()
        end
    end
    
    foodMenuFrame:ClearAllPoints()
    if HHT_FoodIconButton then
        foodMenuFrame:SetPoint("LEFT", HHT_FoodIconButton, "RIGHT", 5, 0)
    else
        foodMenuFrame:SetPoint("CENTER", UIParent, "CENTER")
    end
    
    local yOffset = -5
    for i, food in ipairs(foodList) do
        -- Reuse existing button or create new one
        local btn = foodMenuFrame.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, foodMenuFrame)
            btn:SetWidth(150)
            btn:SetHeight(24)
            
            btn.icon = btn:CreateTexture(nil, "BACKGROUND")
            btn.icon:SetWidth(20)
            btn.icon:SetHeight(20)
            btn.icon:SetPoint("LEFT", 2, 0)
            
            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            btn.text:SetPoint("LEFT", 26, 0)
            
            foodMenuFrame.buttons[i] = btn
        end
        
        -- Update button data
        btn:SetPoint("TOPLEFT", 5, yOffset)
        btn:Show()
        btn.icon:SetTexture(food.texture)
        btn.text:SetText(food.name .. " (" .. food.count .. ")")
        btn.text:SetTextColor(1, 1, 1)
        
        -- Store food data on button for click handler
        btn.foodData = {
            bag = food.bag,
            slot = food.slot,
            name = food.name,
            texture = food.texture,
            count = food.count,
            itemID = food.itemID
        }
        
        btn:RegisterForClicks("LeftButtonUp")
        btn:SetScript("OnClick", function()
            -- Use food data stored on button
            selectedFood = {
                bag = this.foodData.bag,
                slot = this.foodData.slot,
                name = this.foodData.name,
                texture = this.foodData.texture,
                count = this.foodData.count,
                itemID = this.foodData.itemID
            }
            local petName = GetCachedPetName()
            HamingwaysHunterToolsDB.selectedFood = HamingwaysHunterToolsDB.selectedFood or {}
            HamingwaysHunterToolsDB.selectedFood[petName] = selectedFood
            -- Clear lastAttemptedFood to prevent false blacklisting
            lastAttemptedFood.itemID = nil
            lastAttemptedFood.petName = nil
            -- Reset display cache to force immediate update
            lastDisplayedFood = nil
            lastDisplayedCount = nil
            cachedSelectedFoodItemID = nil
            HHT_PetFeeder_UpdateDisplay(true)  -- Force update for user action
            foodMenuFrame:Hide()
        end)
        
        btn:SetScript("OnEnter", function()
            this.text:SetTextColor(1, 1, 0)
        end)
        
        btn:SetScript("OnLeave", function()
            this.text:SetTextColor(1, 1, 1)
        end)
        
        yOffset = yOffset - 24
    end
    
    local menuHeight = table.getn(foodList) * 24 + 10
    foodMenuFrame:SetHeight(menuHeight)
    foodMenuFrame:Show()
end

-- Handle blacklist errors (called from main addon via global function)
function HHT_PetFeeder_HandleFoodError(errorMsg)
    if not errorMsg or type(errorMsg) ~= "string" then return end
    if not HasPet() then return end
    
    local isFoodRejected = string.find(errorMsg, "refuse") or 
                          string.find(errorMsg, "doesn't like") or 
                          string.find(errorMsg, "does not like") or 
                          string.find(errorMsg, "will not eat") or 
                          string.find(errorMsg, "won't eat") or 
                          string.find(errorMsg, "not high enough") or 
                          string.find(errorMsg, "too low") or 
                          string.find(errorMsg, "can't use that") or 
                          string.find(errorMsg, "cannot use that") or 
                          string.find(errorMsg, "fail to perform Feed Pet")
    
    if isFoodRejected and lastAttemptedFood and lastAttemptedFood.itemID then
        local petName = GetCachedPetName()
        
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
                DEFAULT_CHAT_FRAME:AddMessage("|cFFABD473Hamingway's HunterTools:|r " .. (lastAttemptedFood.name or "Food") .. " blacklisted for " .. petName .. " (" .. errorMsg .. ")", 1, 0.5, 0)
                
                if selectedFood and selectedFood.itemID == lastAttemptedFood.itemID then
                    selectedFood = nil
                    if HamingwaysHunterToolsDB.selectedFood then
                        HamingwaysHunterToolsDB.selectedFood[petName] = nil
                    end
                end
                
                HHT_PetFeeder_UpdateDisplay(true)  -- Force update after blacklist
            end
            
            -- Clear lastAttemptedFood for reuse
            lastAttemptedFood.itemID = nil
            lastAttemptedFood.petName = nil
        end
    end
end

-- Create Pet Feeder Frame (called from main addon)
function HHT_PetFeeder_Initialize(MakeDraggableFn, CreateBackdropFn)
    local cfg = GetConfig()
    local iconSize = cfg.petFeederIconSize or DEFAULT_PET_FEEDER_ICON_SIZE
    local dragPadding = 8
    local contentWidth = iconSize * 2 + 9
    local contentHeight = iconSize + 4
    local frameWidth = contentWidth + (dragPadding * 2)
    local frameHeight = contentHeight + (dragPadding * 2)
    
    HHT_PetFeedFrame = CreateFrame("Frame", "HamingwaysHunterToolsPetFeederFrame", UIParent)
    HHT_PetFeedFrame:SetWidth(frameWidth)
    HHT_PetFeedFrame:SetHeight(frameHeight)
    HHT_PetFeedFrame:SetFrameStrata("MEDIUM")
    HHT_PetFeedFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    HHT_PetFeedFrame:SetAlpha(0)
    HHT_PetFeedFrame:EnableMouse(true)
    HHT_PetFeedFrame:SetMovable(true)
    HHT_PetFeedFrame:RegisterForDrag("LeftButton")
    
    local bgFrame = CreateFrame("Frame", nil, HHT_PetFeedFrame)
    HHT_PetFeedBgFrame = bgFrame  -- Store globally for color updates
    bgFrame:SetWidth(contentWidth)
    bgFrame:SetHeight(contentHeight)
    bgFrame:SetPoint("CENTER", HHT_PetFeedFrame, "CENTER", 0, 0)
    bgFrame:SetFrameLevel(HHT_PetFeedFrame:GetFrameLevel())
    
    if cfg.borderSize and cfg.borderSize > 0 then
        bgFrame:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, 
            edgeSize = cfg.borderSize,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
    else
        bgFrame:SetBackdrop({
            bgFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = nil,
            tile = false,
            edgeSize = 0,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
    end
    
    bgFrame:SetBackdropColor(0, 0.6, 0, cfg.bgOpacity or 0.8)
    bgFrame:SetBackdropBorderColor(0.67, 0.83, 0.45, cfg.borderOpacity or 1)
    
    HHT_PetIconButton = CreateFrame("Button", nil, HHT_PetFeedFrame)
    HHT_PetIconButton:SetWidth(iconSize)
    HHT_PetIconButton:SetHeight(iconSize)
    HHT_PetIconButton:SetPoint("LEFT", HHT_PetFeedFrame, "LEFT", 2 + dragPadding, 0)
    
    HHT_PetIconButton.icon = HHT_PetIconButton:CreateTexture(nil, "BACKGROUND")
    HHT_PetIconButton.icon:SetAllPoints()
    HHT_PetIconButton.icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastCall")
    HHT_PetIconButton.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    
    HHT_PetIconButton:RegisterForClicks("LeftButtonUp")
    
    HHT_PetIconButton:SetScript("OnClick", function()
        if arg1 ~= "LeftButton" then return end
        
        if UnitExists("pet") and UnitIsDead("pet") then
            CastSpellByName("Revive Pet")
        elseif HasPet() then
            CastSpellByName("Dismiss Pet")
        else
            CastSpellByName("Call Pet")
        end
        
        if not this.updateTimer then
            this.updateTimer = 0
        end
        this.updateTimer = 0.5
        this:SetScript("OnUpdate", function()
            if this.updateTimer and this.updateTimer > 0 then
                this.updateTimer = this.updateTimer - arg1
                if this.updateTimer <= 0 then
                    HHT_PetFeeder_UpdateDisplay()
                    this:SetScript("OnUpdate", nil)
                    this.updateTimer = nil
                end
            end
        end)
    end)
    
    HHT_PetIconButton:SetScript("OnEnter", function()
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
    
    HHT_PetIconButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    HHT_FoodIconButton = CreateFrame("Button", nil, HHT_PetFeedFrame)
    HHT_FoodIconButton:SetWidth(iconSize)
    HHT_FoodIconButton:SetHeight(iconSize)
    HHT_FoodIconButton:SetPoint("LEFT", HHT_PetIconButton, "RIGHT", 5, 0)
    
    HHT_FoodIconButton.icon = HHT_FoodIconButton:CreateTexture(nil, "BACKGROUND")
    HHT_FoodIconButton.icon:SetAllPoints()
    HHT_FoodIconButton.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    HHT_FoodIconButton.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    
    HHT_FoodIconButton.countText = HHT_FoodIconButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    HHT_FoodIconButton.countText:SetPoint("BOTTOMRIGHT", -2, 2)
    HHT_FoodIconButton.countText:SetTextColor(1, 1, 1, 1)
    
    HHT_FoodIconButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    HHT_FoodIconButton:SetScript("OnClick", function()
        local cfg = GetConfig()
        if arg1 == "LeftButton" then
            if cfg.feedOnClick then
                HHT_PetFeeder_FeedPet()
            end
        elseif arg1 == "RightButton" then
            ShowFoodMenu()
        end
    end)
    
    HHT_FoodIconButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Pet Food", 1, 1, 1)
        local cfg = GetConfig()
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
    
    HHT_FoodIconButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    HHT_PetFeedFrame.lastAutoFeedAttempt = 0
    
    foodMenuFrame = CreateFrame("Frame", "HamingwaysHunterToolsPetFoodMenu", UIParent)
    foodMenuFrame:SetFrameStrata("DIALOG")
    
    local backdrop = CreateBackdropFn and CreateBackdropFn(cfg.borderSize) or {
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = cfg.borderSize or 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    }
    
    foodMenuFrame:SetBackdrop(backdrop)
    foodMenuFrame:SetBackdropColor(cfg.bgColor and cfg.bgColor.r or 0, cfg.bgColor and cfg.bgColor.g or 0, cfg.bgColor and cfg.bgColor.b or 0, cfg.bgOpacity or 0.8)
    foodMenuFrame:SetBackdropBorderColor(1, 1, 1, cfg.borderOpacity or 1)
    foodMenuFrame:EnableMouse(true)
    foodMenuFrame:SetWidth(160)
    foodMenuFrame:SetHeight(100)
    foodMenuFrame:Hide()
    
    -- OnUpdate timer to check happiness color (1x per second)
    HHT_PetFeedFrame.happinessCheckTimer = 0
    HHT_PetFeedFrame:SetScript("OnUpdate", function()
        this.happinessCheckTimer = this.happinessCheckTimer + arg1
        if this.happinessCheckTimer >= 1 then
            this.happinessCheckTimer = 0
            if HasPet() then
                local happiness = GetPetHappiness()
                if happiness and happiness ~= lastDisplayedHappiness then
                    HHT_PetFeeder_UpdateDisplay(true)
                end
            end
        end
    end)
    
    if MakeDraggableFn then
        MakeDraggableFn(HHT_PetFeedFrame, "petFeed")
    end
end
