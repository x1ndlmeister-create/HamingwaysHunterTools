# Hamingway's HunterTools (Vanilla 1.12)

## Version 0.8.1

### Changes in v0.8.1
✅ Hunter Class Check (Addon nur für Jäger)
✅ Freundliche Nachricht für Nicht-Jäger

### Changes in v0.8.0
✅ Range Detection System (Quiver-Style)
✅ Dead Zone Warning mit Blink-Effekt
✅ Melee Timer mit Parry/Dodge/Block Erkennung
✅ Zentrierte Range-Anzeige (immer sichtbar)
✅ Optimiertes Melee Display (cleaner Format)

### Changes in v0.7.0
✅ GCD-basiertes Instant Shot Detection
✅ Gelber Balken Reset bei Instant Shots
✅ Revive Pet Icon & Castbar
✅ Mount-Detection für Turtle WoW
✅ Auto-Feed blockiert wenn mounted

## Installation
- Copy `AddOns/HamingwaysHunterTools` into your `Interface/AddOns` folder for WoW Vanilla 1.12.

## Features
- **Auto Shot Timer**: Visual bar showing ranged weapon cooldown with precise timing
- **Melee Swing Timer**: Shows melee attack cooldown (recognizes hits, crits, misses, parries, dodges, blocks)
- **Range Detection**: Displays target distance category (Melee Range, Short Range, Long Range, Dead Zone with blink warning, Out of Range)
- **Reaction Stats**: Track and display combat statistics
- **Ammo Tracking**: Monitor ammunition count
- **Pet Feeder**: Automatic pet feeding system

## Usage
- Drag the bar to move it; position is saved per character
- **Timer Display**: 
  - Ranged: Shows "0.50s/2.80s" (remaining/total)
  - Melee: Shows "0.71s" (remaining time only)
- **Range Display**: Always visible in center of bar
  - Text-only indicators (no exact yards - Vanilla limitation)
  - Dead Zone blinks as warning
- Commands: `/HamingwaysHunterTools reset` — reset settings

## Technical Notes
- Saved variables: `SavedVariablesPerCharacter: HamingwaysHunterToolsDB`
- Range detection uses `CheckInteractDistance()` and `IsActionInRange()` (boolean approximation only)
- Melee timer detects all swing outcomes: hits, crits, misses, parries, dodges, blocks, evades
- Filters out offhand swings (dual-wield aware)
- Requires Auto Shot on action bar (can be hidden) for ranged detection
- Optional: Scatter Shot and Scare Beast on action bars for enhanced range categories

## License
- No license specified — treat as example code for the community
