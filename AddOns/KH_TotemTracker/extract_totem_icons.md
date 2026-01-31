# Totem Icons Liste

Um runde TGA-Dateien für alle Totems zu erstellen, benötigst du die folgenden Icons:

## Air Totems (Luft)
1. **Windfury** - `Spell_Nature_Windfury.tga`
2. **Grace of Air** - `Spell_Nature_InvisibilityTotem.tga`
3. **Grounding** - `Spell_Nature_GroundingTotem.tga`
4. **Nature Resistance** - `Spell_Nature_NatureResistanceTotem.tga`
5. **Windwall** - `Spell_Nature_EarthBind.tga`
6. **Tranquil Air** - `Spell_Nature_Brilliance.tga`

## Fire Totems (Feuer)
7. **Flametongue** - `Spell_Fire_FlameTounge.tga`
8. **Searing** - `Spell_Fire_SearingTotem.tga`
9. **Fire Nova** - `Spell_Fire_SealOfFire.tga`
10. **Magma** - `Spell_Fire_SelfDestruct.tga`
11. **Frost Resistance** - `Spell_FrostResistanceTotem_01.tga`

## Earth Totems (Erde)
12. **Strength of Earth** - `Spell_Nature_EarthBindTotem.tga`
13. **Stoneskin** - `Spell_Nature_StoneSkinTotem.tga`
14. **Tremor** - `Spell_Nature_TremorTotem.tga`
15. **Stoneclaw** - `Spell_Nature_StoneClawTotem.tga`
16. **Earthbind** - `Spell_Nature_StrengthOfEarthTotem02.tga`

## Water Totems (Wasser)
17. **Mana Spring** - `Spell_Nature_ManaRegenTotem.tga`
18. **Healing Stream** - `INV_Spear_04.tga`
19. **Mana Tide** - `Spell_Frost_SummonWaterElemental.tga`
20. **Poison Cleansing** - `Spell_Nature_PoisonCleansingTotem.tga`
21. **Disease Cleansing** - `Spell_Nature_DiseaseCleansingTotem.tga`
22. **Fire Resistance** - `Spell_FireResistanceTotem_01.tga`

---

## Wie du die Icons extrahieren kannst:

### Option 1: WoW Icon Extractor Tools
- **WoW.tools** (https://wow.tools) - Online BLP to PNG converter
- **BLPConverter** - Konvertiert BLP (WoW Format) zu TGA/PNG
- **WoW Model Viewer** - Kann Icons exportieren

### Option 2: Manual von WoW extrahieren
1. Navigiere zu deinem WoW-Installationsverzeichnis
2. Icons befinden sich in: `Interface\Icons\` (als BLP-Dateien)
3. Verwende einen BLP-Konverter, um sie zu TGA zu konvertieren
4. Bearbeite mit GIMP/Photoshop:
   - Mache quadratisch
   - Füge Alpha-Kanal hinzu (für Transparenz)
   - Schneide rund zu
   - Exportiere als **TGA, unkomprimiert, 32-bit mit Alpha**

### Option 3: KI-generiert (wie dein Shaman Logo)
Lasse dir runde, stilisierte Versionen der Totem-Icons erstellen

---

## Ordnerstruktur nach Erstellung:
```
AddOns/KH_TotemTracker/
  images/
    shaman_logo_alpha.tga
    Spell_Nature_Windfury.tga
    Spell_Nature_InvisibilityTotem.tga
    ... (alle anderen)
```

## Anpassung im Code
Sobald du die TGA-Dateien hast, können wir den Code anpassen, um statt der WoW-Standard-Icons deine custom TGAs zu verwenden.
