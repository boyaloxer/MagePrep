# MagePrep

A **mage arena prep helper** for WoW TBC Anniversary (2.5.x).

Forked from [LockPrep](https://github.com/boyaloxer/LockPrep) — same architecture
(state-aware next-step button + bracket checklist + options UI). The warlock
domain has been remapped to mage prep: Arcane Intellect, armor, Amplify/Dampen
Magic, Mana Emerald, conjured food/water (trade or Ritual of Refreshment table),
drink-to-full, Ice Barrier, and the gate mount.

## Quick start

1. Enable **MagePrep** at the character select addon list (`/reload` if needed).
2. `/mp bind SHIFT-E` (or set keys in options via the minimap icon).
3. Left-click the minimap icon for options. Right-click to toggle the checklist.

## Commands

| Command | Description |
| --- | --- |
| `/mageprep` / `/mp` / `/mprep` | Help / status |
| `/mp bind <KEY>` | Bind the next-step button |
| `/mp armor ice\|molten\|mage` | Pick which armor the armor step casts |
| `/mp preset 2s\|3s5s\|bg\|custom` | Apply a preset |
| `/mp test` | Toggle checklist |
| `/mp options` | Open options |

## Status

- **v0.2.0** — mage prep routine live: Arcane Intellect, armor (Ice/Molten/Mage), Amplify/Dampen Magic, Mana Emerald, Conjure Food/Water (trade) or Ritual of Refreshment, drink-to-full, Ice Barrier, mount. Presets retuned (2s / 3s5s / BGs). LockPrep safety engine kept; warlock-only systems (pets/sac/spellstone) removed.
- **v0.1.2** — options background swapped to `blizzmage` (mage art).
- **v0.1.1** — mage-blue theme + Mage Armor minimap icon (distinct from LockPrep).
- **v0.1.0** — rebranded LockPrep scaffold (UI, presets shell, minimap, options art).

## Art credit

Options backdrop illustration by **Wayne Reynolds** (Blizzard / *World of Warcraft*).
Temporary shared asset from LockPrep; may change for MagePrep later.

## License

GPL-2.0. See [LICENSE](LICENSE). Copyright (C) 2026 boyaloxer.
(Artwork is not covered by this license — see Art credit above.)
