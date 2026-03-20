# HHT Debug Commands

## Show Lua Errors (even with DragonflightUI)

In-Game Chat commands:

```
/run UIErrorsFrame:Show()
/run UIErrorsFrame:AddMessage("Test Error", 1, 0, 0, 1, 5)
/script DEFAULT_CHAT_FRAME:AddMessage("Script Errors aktiviert")
```

## Force Error Display

```
/script ScriptErrors_Message = function(msg, frame, stack) DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000ERROR:|r " .. msg, 1, 0, 0); end
```

## Check if HHT is loaded

```
/script if HamingwaysHunterToolsDB then print("HHT: LOADED") else print("HHT: NOT LOADED") end
```

## Show HHT Frame Status

```
/script if HamingwaysHunterToolsCore then print("HHT Frame exists") else print("HHT Frame missing") end
```

## Manual Addon Load Test

```
/reload
```

## Alternative: Create BugSack-like error catcher

```
/script _ERRORS = {}; _OLDERROR = geterrorhandler(); seterrorhandler(function(msg) table.insert(_ERRORS, msg); DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000ERROR:|r " .. msg, 1, 0, 0); _OLDERROR(msg); end)
```

## Show collected errors

```
/script for i,v in ipairs(_ERRORS or {}) do DEFAULT_CHAT_FRAME:AddMessage(i..": "..v, 1, 0.5, 0); end
```

---

## FIXED ISSUE:

**math.mod()** wurde zu **mod()** geändert (Lua 5.0 Kompatibilität)
- WoW Vanilla nutzt Lua 5.0
- `math.mod()` existiert erst ab Lua 5.1
- In Lua 5.0 heißt es nur `mod()` als globale Funktion

Das Addon sollte jetzt laden!
