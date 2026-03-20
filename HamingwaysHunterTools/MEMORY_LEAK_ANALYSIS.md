# Memory Leak Analysis - HamingwaysHunterTools

## 🔴 KRITISCHE FUNDE

### Problem #1: String.format() in OnUpdate-Schleife ⭐⭐⭐⭐⭐
**Datei**: HamingwaysHunterTools.lua  
**Zeilen**: ~1150, ~1180, ~1230, ~1268, ~1309  
**Häufigkeit**: 10-20x pro Sekunde (bereits gedrosselt von 60x/sec!)  
**Impact**: SEHR HOCH - Hauptverdächtiger

```lua
-- AKTUELL (SCHLECHT):
local newText = string.format("%.2fs/%.2fs", totalElapsed, weaponSpeed)
barTextTotal:SetText(newText)  -- Neuer String bei JEDEM Update!
```

**Problem**:
- `string.format()` erstellt bei jedem Call einen neuen String
- Strings sind immutable in Lua → alte Strings bleiben im Memory
- Garbage Collector kann mit 600+ Strings/Minute nicht mithalten
- Nach 30 Minuten AFK = 18.000+ String-Objekte im Memory!

**Lösung**:
```lua
-- PRE-CACHE String-Buffer mit fester Precision:
local timerStringCache = {}
local function FormatTimer(seconds, maxSeconds)
    -- Runde auf 0.01s Präzision (2 Dezimalen)
    local key = math.floor(seconds * 100) .. "_" .. math.floor((maxSeconds or 0) * 100)
    if not timerStringCache[key] then
        if maxSeconds then
            timerStringCache[key] = string.format("%.2fs/%.2fs", seconds, maxSeconds)
        else
            timerStringCache[key] = string.format("%.2fs", seconds)
        end
    end
    return timerStringCache[key]
end

-- Dann verwenden:
local newText = FormatTimer(totalElapsed, weaponSpeed)
```

**Noch besser: Nur bei Änderung updaten:**
```lua
-- String nur setzen wenn sich Wert geändert hat:
local newText = FormatTimer(totalElapsed, weaponSpeed)
if newText ~= textCache.barTextTotal then
    barTextTotal:SetText(newText)
    textCache.barTextTotal = newText
end
```

---

### Problem #2: Anonyme OnUpdate-Closure ⭐⭐⭐⭐
**Datei**: HamingwaysHunterTools.lua  
**Zeile**: ~3703  
**Impact**: HOCH

```lua
-- AKTUELL (SCHLECHT):
frame:SetScript("OnUpdate", function()
    -- 800+ Zeilen Code hier
    -- Alle lokalen Funktionsaufrufe erstellen Closures!
end)
```

**Problem**:
- Die anonyme Funktion wird 60x/Sekunde aufgerufen
- Jeder Aufruf kann neue Closure-Referenzen erstellen
- Lokale Variablen bleiben im Memory gefangen (Upvalues)

**Lösung**:
```lua
-- Named function AUSSERHALB definieren:
local function MainFrameOnUpdate()
    local now = GetTime()
    local db = HamingwaysHunterToolsDB
    if not db then return end
    -- ... rest der Logik
end

-- Dann zuweisen:
frame:SetScript("OnUpdate", MainFrameOnUpdate)
```

---

### Problem #3: GetTime() Overhead ⭐⭐⭐
**Häufigkeit**: 60x/Sekunde in mehreren OnUpdate-Funktionen  
**Impact**: MITTEL

**Lösung**:
```lua
-- Global cached time (einmal pro Frame-Batch):
local cachedTime = 0
local cachedTimeFrame = 0

local function GetCachedTime()
    local currentFrame = GetFrameID() or 0  -- Falls verfügbar
    if currentFrame ~= cachedTimeFrame then
        cachedTime = GetTime()
        cachedTimeFrame = currentFrame
    end
    return cachedTime
end
```

---

### Problem #4: Table-Erstellung ohne Recycling ⭐⭐⭐
**Verdächtige Stellen**:
- `FindAmmoInBags()` - erstellt neue Tables bei jedem Scan
- `reactionTimes = {}` - Array wächst unbegrenzt?
- Config-Tables in GetConfig()

**Lösung**:
```lua
-- Table Recycling:
local recycledTables = {}
local function GetRecycledTable()
    if table.getn(recycledTables) > 0 then
        return table.remove(recycledTables)
    end
    return {}
end

local function RecycleTable(t)
    -- Clear table
    for k in pairs(t) do t[k] = nil end
    table.insert(recycledTables, t)
end

-- Verwenden:
local ammoList = GetRecycledTable()
-- ... work with table ...
RecycleTable(ammoList)
```

---

### Problem #5: UnitName() String Leaks ⭐⭐
**Verdächtige Stellen**:
- `UnitName("pet")` - gibt String zurück
- `UnitName("target")` - in Range-Checks
- Texture paths von `UnitBuff()`

**Problem**:
- WoW API gibt interned strings zurück
- Bei häufigen Calls können diese sich aufstauen

**Lösung**:
```lua
-- Cache Unit-Namen:
local cachedPetName = nil
local lastPetCheck = 0

local function GetCachedPetName()
    local now = GetTime()
    if now - lastPetCheck > 1 then  -- Nur 1x/Sekunde prüfen
        cachedPetName = UnitExists("pet") and UnitName("pet") or nil
        lastPetCheck = now
    end
    return cachedPetName
end
```

---

## 📊 Prioritäten-Liste

### 1. **SOFORT FIX** (Quick Win, hoher Impact):
- ✅ String.format() caching in UpdateBarShoot/UpdateBarReload
- ✅ Nur String setzen wenn Text sich ändert (bereits teilweise implementiert)

### 2. **PHASE 2** (Strukturelles Refactoring):
- ⬜ OnUpdate-Handler zu named functions konvertieren
- ⬜ Table Recycling für FindAmmoInBags()
- ⬜ GetTime() global cachen pro Frame

### 3. **PHASE 3** (Optimierungen):
- ⬜ UnitName() caching
- ⬜ Config-Table caching verbessern
- ⬜ String-Concatenation in Chat-Messages pre-builden

---

## 🧪 Test-Strategie

### Test #1: Minimaler OnUpdate
```lua
-- Teste ob OnUpdate selbst leaked:
frame:SetScript("OnUpdate", function()
    -- NUR logging, keine Logik
    if math.random() < 0.001 then  -- 0.1% der Zeit
        DEFAULT_CHAT_FRAME:AddMessage("Update: " .. gcinfo() .. " kB")
    end
end)
```

### Test #2: String.format() isoliert
```lua
-- Teste nur string.format ohne Rest:
local counter = 0
frame:SetScript("OnUpdate", function()
    counter = counter + 1
    local str = string.format("%.2fs/%.2fs", counter * 0.1, 3.5)
    -- str wird nicht verwendet = Leak?
end)
```

### Test #3: Mit Caching
```lua
-- Mit String-Cache:
local cache = {}
local function CachedFormat(a, b)
    local key = a .. "_" .. b
    if not cache[key] then
        cache[key] = string.format("%.2fs/%.2fs", a, b)
    end
    return cache[key]
end

frame:SetScript("OnUpdate", function()
    local str = CachedFormat(GetTime(), 3.5)
end)
```

---

## 🎯 Erwartete Ergebnisse

**VOR dem Fix**:
- Memory: 4915 kB (OnEvent-Handler)
- Growth: +36 kB pro Event-Call
- Nach 30min AFK: ~1.2 MB leak

**NACH String.format() Fix**:
- Memory: ~500-800 kB (erwartetes Normal-Level)
- Growth: <5 kB pro Event-Call
- Nach 30min AFK: <100 kB leak (akzeptabel)

**Wenn kein Unterschied**:
→ Leak ist im OnEvent-Handler selbst (Closure-Problem)
→ Dann Phase 2 nötig (named functions)

---

## 🔧 Quick-Fix Implementation (10 Minuten)

### Datei: HamingwaysHunterTools.lua

**Schritt 1**: String-Cache-System hinzufügen (nach Zeile ~1100):
```lua
-- String caching system for performance (reduce GC pressure)
local timerFormatCache = {}
local function FormatTimerCached(elapsed, total)
    -- Round to 0.01s precision to limit cache size
    local key = math.floor(elapsed * 100)
    if total then
        key = key .. "_" .. math.floor(total * 100)
    end
    
    if not timerFormatCache[key] then
        if total then
            timerFormatCache[key] = string.format("%.2fs/%.2fs", elapsed, total)
        else
            timerFormatCache[key] = string.format("%.2fs", elapsed)
        end
        
        -- Limit cache size (prevent unbounded growth)
        local count = 0
        for _ in pairs(timerFormatCache) do count = count + 1 end
        if count > 500 then
            timerFormatCache = {}  -- Clear cache if too large
        end
    end
    
    return timerFormatCache[key]
end
```

**Schritt 2**: Replace alle string.format() Calls:
- Zeile ~1150: `string.format("%.2fs/%.2fs", ...)` → `FormatTimerCached(...)`
- Zeile ~1180: `string.format("%.2fs", ...)` → `FormatTimerCached(...)`
- Zeile ~1230: `string.format("%.2fs/%.2fs", ...)` → `FormatTimerCached(...)`
- Zeile ~1268: `string.format("%.2fs", ...)` → `FormatTimerCached(...)`
- Zeile ~1309: `string.format("%.2fs", ...)` → `FormatTimerCached(...)`

**Schritt 3**: Teste mit pfDebug nach 5-10 Minuten AFK

---

## 📝 Weitere Verdächtige (später untersuchen)

1. **Tooltip-Scans**: Falls noch irgendwo vorhanden
2. **Combat-Log-Parsing**: `string.find()` in CHAT_MSG_COMBAT_*
3. **Config-Table-Copies**: `GetConfig()` gibt neue Table zurück?
4. **Event-Registration**: Werden Events mehrfach registriert?
5. **Buff-Scanning**: `UnitBuff()` Loop könnte Strings leaken

---

**Status**: Ready for implementation  
**Estimated Fix Time**: 10-15 Minuten für Quick-Fix  
**Expected Impact**: 80-90% Leak-Reduktion
