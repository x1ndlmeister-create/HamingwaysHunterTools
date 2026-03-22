# Hamingway's HunterTools - Changelog

## Version 1.1.4 (Mar 22, 2026)

### ✨ New Features
- **Kill Command Tracking** - New optional proc frame slot for Kill Command. Shows GO (full alpha + glow pulse) when the spell is usable after your pet attacks, grey + cooldown timer when on cooldown, and very dim when unavailable. Uses `IsUsableAction` to mirror the action bar exactly.
- **Spell Cooldown on Ammo Icons** - The spell icon overlay above the ammo proc slot now turns grey and shows the remaining cooldown when the corresponding spell (Multi-Shot / Serpent Sting / Arcane Shot) is on cooldown.
- **Aspect of the Viper & Wolf** - Added Viper and Wolf to the main aspect dropdown and warning system.
- **Auto Aspect Icon** - Aspect icons in the warning frame are now loaded directly from your spellbook via `GetSpellTexture`, so the correct icon is always shown for every aspect including custom/modded ones.
- **Generic Aspect Scanning** - `ScanAvailableAspects` now finds all `"Aspect of"` spells automatically — no hardcoded list needed. New aspects on Turtle WoW are discovered without any code changes.

### 🔧 Bug Fixes
- **Kill Command "GO" false positive** - Fixed KC showing GO when the action bar showed it as greyed out. Root cause: `IsUsableSpell` does not reflect the KC proc condition correctly in WoW 1.12; switched to `IsUsableAction` on the cached action bar slot.
- **KC Spell Slot not cached** - `CacheSpellBookInfo` was not caching the Kill Command spellbook slot index, causing all `GetSpellCooldown` calls for KC to silently fail.
- **GCD false cooldown** - KC no longer flashes grey during the global cooldown (durations ≤1.5s are ignored).
- **Wolf aspect icon broken** - Removed hardcoded icon path for Wolf; texture is now read from spellbook.

### 📝 Technical Details
- `ProcState.kcActionSlot` — action bar slot found by texture match at init, used for `IsUsableAction`
- `ProcState.kcSpellSlot` — spellbook slot cached by `CacheSpellBookInfo`, used for `GetSpellCooldown`
- `aspectTextureCache` — table populated from spellbook at init, maps aspect name → texture path
- KC proc frame slot is **disabled by default** (`procFrameKcEnabled = false`)

---

## Version 1.0.7 (Feb 4, 2026)

### ✨ New Features
- **SuperWoW Support** - Full support for Balake's SuperWoW (github.com/balakethelock/SuperWoW)
- **UNIT_CASTEVENT Integration** - Perfect Auto-Shot detection via UNIT_CASTEVENT (no more ITEM_LOCK_CHANGED filtering!)
- **GetPlayerBuffID Support** - Enhanced Haste Buff tracking via Buff IDs
- **Dual-Mode Operation** - Seamless fallback to Vanilla 1.12 APIs when SuperWoW not available
- **Zero Overhead** - No performance impact on Vanilla clients

### 📝 Technical Details
- SuperWoW's UNIT_CASTEVENT provides perfect Auto-Shot timing (no false positives from instant shots)
- GetPlayerBuffID allows precise Haste Buff identification
- Automatic detection at addon load (one-time check, zero runtime overhead)

---

## Version 1.0.6 (Feb 4, 2026)

### 🔧 Bug Fixes
- **Fixed Stats Frame Crash** - Prevented game crash when dragging statistics window multiple times by adding safety checks and preventing duplicate event handler registrations
- **Enhanced Drag Safety** - Added frame visibility checks and GetPoint() validation in MakeDraggable function

---

## Version 1.0.5 (Feb 4, 2026)

### 🔧 Bug Fixes
- **Fixed NotifyCastAuto API Error** - Changed `castSpells` from local to global table (`HHT_castSpells`) to prevent "attempt to index global 'castSpells' (a nil value)" error when API is called from macros
- **Instant Cast Support** - Fixed Multi-Shot and other instant casts not working with `NotifyCastAuto` API (changed condition from `castTime > 0` to `castTime >= 0`)

### 📝 Technical Details
The issue occurred when macros called the API before addon initialization completed. Making the spell database globally accessible ensures it's always available when needed.

---

## Version 1.0.4 (Feb 2, 2026)

### ✨ New Features
- **NotifyCastAuto API** - Simplified API for user macros that auto-calculates cast times from spell database
- **Smart Pet Action API** - One-click pet management: Feed/Dismiss/Call/Revive based on pet state

---

## Version 1.0.3 (Feb 1, 2026)

### 🔧 Bug Fixes
- **PetFeeder Memory Leak** - Fixed memory leak in PetFeeder module through table reuse patterns
- **Real-time Count Updates** - Food count now updates instantly when consuming items
- **Happiness Display** - Fixed color not updating correctly with pet happiness changes

---

## Version 0.8.4 - Performance Hotfix (Jan 28, 2026)

### 🔧 Critical Fixes
- **Fixed API Load Order** - Restored proper initialization sequence for LazyHunt integration
- **Removed Aggressive Throttling** - Eliminated artificial 0.2-0.5s delays causing input lag
- **Removed Continuous OnUpdate Loop** - Haste buff timers now update event-driven (only when buffs change) instead of every 0.2s
- **Simplified Buff Tracking** - Reverted to faster, lighter-weight buff duration calculation method
- **Fixed LazyHunt Integration** - Shot timing and rotation now works correctly again

### 📊 Performance Impact
- Reduced CPU usage during combat by ~40%
- Eliminated frame drops from continuous GetPlayerBuffTimeLeft() calls
- Restored responsive feel - no more delayed reactions
- LazyHunt rotation now precise and lag-free

**NOTE**: The "optimization" in 0.8.3 accidentally made things worse. This version rolls back the problematic changes while keeping the good stuff (texture-based buff detection, table reuse).

---

## Version 0.8.3 - Previous Release (DEPRECATED - Performance Issues)

### ✅ New Features
- **Melee Swing Timer** - Combat log based melee swing detection with visual countdown, perfectly synced with your white damage hits
- **Enhanced Buff Bar** - Now with pfUI-inspired buff refresh detection - timers accurately reset when buffs are reapplied

### ✅ Performance Optimizations
- **40-Man Raid Ready** - Aggressive throttling and caching ensures smooth performance even in large raid environments
- **Smart Event Handling** - Immediate buff detection on aura changes, throttled updates for visual display (5 FPS)
- **Efficient Resource Usage** - Disabled features consume zero CPU cycles with early-exit guards
- **Optimized Pet Feeder** - Reduced tooltip scanning overhead with intelligent update intervals

### ✅ Technical Improvements  
- **Lua 5.0 Compatibility** - Fixed "too many upvalues" errors by extracting event handlers into separate functions
- **Direct API Queries** - Each buff icon queries `GetPlayerBuffTimeLeft()` directly for accurate real-time tracking
- **Robust Refresh Detection** - Buffs now properly refresh their timers when reapplied, using proven pfUI methodology

### ✅ Bug Fixes
- Fixed buff bar disappearing after optimization pass (variable naming conflict)
- Fixed buff timers freezing at zero when buffs were refreshed
- Fixed pet feeder incorrectly graying out valid food items
- Fixed manual event registration for vanilla client compatibility

---
*Tested on Turtle WoW (Vanilla 1.12.1) - Performance validated in 40-man raids*
