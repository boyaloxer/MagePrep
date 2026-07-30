# MagePrep

A **mage arena prep helper** for WoW TBC Anniversary (2.5.x).

Forked from [LockPrep](https://github.com/boyaloxer/LockPrep) — same architecture
(state-aware next-step button + bracket checklist + options UI). The current
build still contains the LockPrep warlock step list as a starting point; mage
prep steps, mounts, and food/water/water-elemental flow will replace that as we
go.

## Quick start

1. Enable **MagePrep** at the character select addon list (`/reload` if needed).
2. `/mp bind SHIFT-E` (or set keys in options via the minimap icon).
3. Left-click the minimap icon for options. Right-click to toggle the checklist.

## Commands

| Command | Description |
| --- | --- |
| `/mageprep` / `/mp` / `/mprep` | Help / status |
| `/mp bind <KEY>` | Bind the next-step button |
| `/mp test` | Toggle checklist |
| `/mp options` | Open options |

## Status

- **v0.1.0** — rebranded LockPrep scaffold (UI, presets shell, minimap, options art).
- Mage-specific prep routine: **WIP**.

## Art credit

Options backdrop illustration by **Wayne Reynolds** (Blizzard / *World of Warcraft*).
Temporary shared asset from LockPrep; may change for MagePrep later.

## License

GPL-2.0. See [LICENSE](LICENSE). Copyright (C) 2026 boyaloxer.
(Artwork is not covered by this license — see Art credit above.)
