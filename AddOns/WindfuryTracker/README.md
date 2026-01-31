# Windfury Tracker

Ein Addon für WoW Vanilla 1.12, das für Schamanen trackt, welche Gruppenmitglieder den Windfury Totem Buff haben.

## Features

- **Echtzeit-Tracking**: Zeigt sofort an, wer den Windfury Totem Buff hat
- **Visuelle Indikatoren**: 
  - ✅ Grünes Windfury-Icon = Spieler hat den Buff
  - ❌ Rotes Icon = Spieler hat keinen Buff
- **Kompakte Anzeige**: Zeigt alle Party-Mitglieder mit Namen und Klasse
- **Bewegbar**: Fenster kann frei positioniert werden (einfach ziehen)

## Verwendung

### Commands
- `/wft` - Zeigt/versteckt das Tracker-Fenster
- `/windfury` - Alternative zum obigen Command

### Installation
1. Entpacke den Ordner `WindfuryTracker` in deinen WoW `Interface/AddOns/` Ordner
2. Starte WoW neu oder reloade die UI (`/reload`)
3. Das Addon wird automatisch geladen

### Im Spiel
- Das Addon trackt automatisch alle Party-Mitglieder
- Nutze `/wft` um das Fenster ein-/auszublenden
- Ziehe das Fenster an die gewünschte Position

## Technische Details

- **Vanilla 1.12 kompatibel**
- Nutzt Tooltip-Scanning um Buffs zu identifizieren
- Update-Intervall: 1 Sekunde + Event-basiert
- Reagiert auf UNIT_AURA und PLAYER_AURAS_CHANGED Events

## Verwendungszweck

Ideal für:
- Raid-Schamanen um sicherzustellen, dass Melee-DPS den Buff haben
- Group-Koordination (wer ist out of range?)
- Totem-Platzierung optimieren

## Hinweise

- Windfury Totem hat eine Range von ca. 20 yards
- Der Buff wird nur angezeigt, wenn die Spieler in Range sind
- Funktioniert nur in Gruppen/Raids
