-- Force a Lua error for testing
print("ErrorTest: Loading...")

-- This will cause an error after 2 seconds
local testFrame = CreateFrame("Frame")
testFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
testFrame:SetScript("OnEvent", function()
    print("ErrorTest: Triggering test error in 2 seconds...")
    this:UnregisterAllEvents()
    
    -- Schedule an error
    local errorTimer = CreateFrame("Frame")
    errorTimer.elapsed = 0
    errorTimer:SetScript("OnUpdate", function()
        this.elapsed = this.elapsed + arg1
        if this.elapsed >= 2 then
            print("ErrorTest: Now causing intentional error...")
            -- Call undefined function to trigger error
            ThisFunctionDoesNotExist()
        end
    end)
end)

print("ErrorTest: Loaded. Error will trigger 2s after entering world.")
