# LazyHunt

Ein WoW Vanilla 1.12 Addon für Jäger, das eine automatische Rotation von Steady Shot → Multi-Shot ermöglicht.

## Features

- Automatisches Casten von **Steady Shot** 
- Anschließendes Casten von **Multi-Shot** (wenn nicht auf Cooldown)
- Funktioniert über ein Macro, das zyklisch aufgerufen wird

## Installation

1. Entpacke den `LazyHunt` Ordner in deinen `World of Warcraft\Interface\AddOns\` Ordner
2. Starte WoW neu oder lade die Addons neu (`/reload`)

## Benutzung

### Schritt 1: Macro erstellen

Erstelle ein neues Macro mit folgendem Inhalt:

```
/script LazyHunt_DoRotation()
```

### Schritt 2: Macro benutzen

1. Aktiviere deinen **Auto Shot** auf ein Ziel
2. Drücke das Macro zyklisch (z.B. spamme die Taste)
3. Das Addon wird automatisch:
   - Steady Shot casten
   - Warten bis Steady Shot fertig ist
   - Multi-Shot casten (falls verfügbar)

## Befehle

- `/lazyhunt` oder `/lh` - Zeigt die Hilfe
- `/lazyhunt status` - Zeigt den aktuellen Status
- `/lazyhunt reset` - Setzt den internen Status zurück

## Wichtige Hinweise

- **Auto Shot muss aktiv sein**, damit die Rotation funktioniert
- Das Macro muss **zyklisch/wiederholt** aufgerufen werden (Taste gedrückt halten oder mehrfach drücken)
- Multi-Shot wird nur gecastet, wenn er nicht auf Cooldown ist
- Bei Unterbrechungen (Stuns, Silence, etc.) wird die Rotation automatisch zurückgesetzt

## Technische Details

Da WoW's API das Casten von Spells aus Events heraus als "protected" markiert, nutzt dieses Addon eine Funktion (`LazyHunt_DoRotation()`), die du manuell über ein Macro aufrufst. Dadurch umgehen wir die Einschränkungen und können die Rotation steuern.

## Version

**1.0.0** - Initiales Release

## Autor

Hamingway
