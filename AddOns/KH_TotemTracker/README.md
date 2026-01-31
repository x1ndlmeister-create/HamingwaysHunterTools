# KH Totem Tracker

Ein Addon für WoW Vanilla 1.12, das für Schamanen trackt, welche Gruppenmitglieder Totem-Buffs haben.

## Features

- **Echtzeit-Tracking**: Zeigt sofort an, wer Totem-Buffs hat
- **8 Wichtige Totems**: Windfury, Strength of Earth, Grace of Air, Stoneskin, Tremor, Poison Cleansing, Disease Cleansing, Mana Spring
- **Dynamische Anzeige**: 
  - Nur aktive Totems werden angezeigt
  - Counter zeigt Anzahl der Spieler in Range
  - Rot = nicht alle in Range, Grün = alle haben den Buff
- **Hover-Tooltip**: 
  - Zeigt wer in Range ist (grün, Klassenfarbe)
  - Zeigt wer out of range ist (rot)
- **Bewegbar**: Fenster kann frei positioniert werden (einfach ziehen)

## Verwendung

### Commands
- `/tt` - Schaltet das Addon an/aus
- `/totem` - Alternative zum obigen Command

### Installation
1. Entpacke den Ordner `KH_TotemTracker` in deinen WoW `Interface/AddOns/` Ordner
2. Starte WoW neu oder reloade die UI (`/reload`)
3. Das Addon wird automatisch geladen

### Im Spiel
- Nutze `/tt` um das Addon zu aktivieren
- Das Fenster erscheint automatisch wenn Totems aktiv sind
- Ziehe das Fenster an die gewünschte Position
- Hover über Icons für Details zu In-Range/Out-of-Range Spielern

## Technische Details

- **Vanilla 1.12 kompatibel**
- Nutzt Tooltip-Scanning um Buffs zu identifizieren
- Update-Intervall: 0.5 Sekunden + Event-basiert
- Reagiert auf UNIT_AURA und PLAYER_AURAS_CHANGED Events
- Icons werden ausgeblendet wenn niemand den Buff hat

## Verwendungszweck

Ideal für:
- Raid-Schamanen um sicherzustellen, dass wichtige Buffs aktiv sind
- Group-Koordination (wer ist out of range?)
- Totem-Platzierung optimieren
- Schneller Überblick über alle aktiven Totem-Buffs

## Hinweise

- Totems haben eine begrenzte Range (ca. 20-30 yards je nach Totem)
- Der Buff wird nur angezeigt, wenn die Spieler in Range sind
- Funktioniert nur in Gruppen/Raids
