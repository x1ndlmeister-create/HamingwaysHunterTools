# Hamingway's HunterTools v1.0.5 - Release Notes

**Release Date:** February 4, 2026  
**Type:** Bugfix Release

---

## 🔧 Bug Fixes

### Critical API Fix
- **Fixed NotifyCastAuto API Error** - Resolved "attempt to index global 'castSpells' (a nil value)" error that occurred when macros called the API during addon initialization
  - Changed internal `castSpells` table from local to global scope (`HHT_castSpells`)
  - Ensures the spell database is always accessible when API functions are called

### Instant Cast Support
- **Fixed Multi-Shot & Instant Casts** - The NotifyCastAuto API now correctly handles instant casts (castTime = 0)
  - Changed validation from `castTime > 0` to `castTime >= 0`
  - Multi-Shot, instant Aimed Shot procs, and other instant casts now work properly

---

## 📝 Usage Example

Your macros should now work without errors:

```
/cast Multi-Shot
/script HamingwaysHunterTools_API.NotifyCastAuto("Multi-Shot")
```

```
/cast Aimed Shot
/script HamingwaysHunterTools_API.NotifyCastAuto("Aimed Shot")
```

```
/cast Steady Shot
/script HamingwaysHunterTools_API.NotifyCastAuto("Steady Shot")
```

---

## 📦 Installation

1. Extract `HamingwaysHunterTools_v1.0.5.zip` to your `World of Warcraft\Interface\AddOns\` folder
2. The folder structure should be: `AddOns\HamingwaysHunterTools\`
3. Restart WoW or use `/reload`

---

## 🔗 Included Files

- `HamingwaysHunterTools.lua` - Main addon logic
- `HamingwaysHunterTools.toc` - TOC file
- `HamingwaysHunterTools_PetFeeder.lua` - Pet feeding module
- `HamingwaysHunterTools_Tranq.lua` - Tranquilizing Shot announcer
- `HamingwaysHunterTools_Warnings.lua` - Aspect & buff warnings
- `README.md` - Documentation

---

## 🐛 Known Issues

None currently reported.

---

## 💬 Feedback

If you encounter any issues, please report them with:
- Your exact macro text
- When the error occurs (login, combat, etc.)
- Full error message from the game

---

**Previous Version:** [v1.0.4](CHANGELOG.md) - Added NotifyCastAuto and SmartPetAction APIs
