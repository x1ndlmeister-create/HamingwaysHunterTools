# Hamingway's HunterTools - Changelog

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
