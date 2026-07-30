local ADDON = ...

-- MagePrep - mage arena prep helper.
-- Copyright (C) 2026 boyaloxer
--
-- This program is free software; you can redistribute it and/or modify it under the terms of
-- the GNU General Public License as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version. This program is distributed WITHOUT
-- ANY WARRANTY; see the GNU General Public License for more details. You should have received a
-- copy of the license with this program (see the LICENSE file); if not, see
-- <https://www.gnu.org/licenses/>.

-- =====================================================================
-- MagePrep -- mage arena prep helper.
--
-- Two pieces working together:
--   1. A state-aware secure button (MagePrepButton). Bind one key to it;
--      each press does the FIRST setup step that isn't done yet, checking
--      your actual game state (bags, buffs, pet, weapon imbue). A failed
--      step just stays "not done", so the next press retries it -- no
--      castsequence desync.
--   2. A bracket-aware checklist overlay with a gate countdown display
--      (parsed from the "One minute / Thirty seconds / ..." messages). It
--      highlights the current step. Steps are gated by state and order only --
--      not the clock -- so nothing is blocked if the countdown mis-parses.
--
-- Everything castable is expressed as macro text so targeting (@player,
-- @party1, ...) and specific spell ranks are exact. Tweak CFG if any name
-- differs on your client/locale.
-- =====================================================================

local CFG = {
    -- macro text per action (edit names/ranks/locale here if needed)
    cast = {
        hsMajor      = "/cast Create Healthstone(Rank 5)",   -- 11730 -> Major Healthstone
        hsMaster     = "/cast Create Healthstone(Rank 6)",   -- 27230 -> Master Healthstone
        ritual       = "/cast Ritual of Souls",              -- 3s/5s: soulwell for the team
        spellstone      = "/cast Create Spellstone",          -- highest known = Master (Rank 4)
        equipSpellstone = "/equip Master Spellstone",         -- relic goes in the wand/ranged slot
        dispelSpellstone= "/use Master Spellstone",           -- IN-COMBAT: dispel all harmful magic (3 min CD)
        summonImp    = "/cast Summon Imp",
        summonVoid   = "/cast Summon Voidwalker",
        summonFel    = "/cast Summon Felhunter",
        felArmor     = "/cast Fel Armor",                    -- self-only armor buff
        fireShield   = "/cast [@%s] Fire Shield",            -- %s = unit
        unending     = "/cast [@%s] Unending Breath",
        detectInvis  = "/cast [@%s] Detect Invisibility",
        sacrifice    = "/cast Sacrifice",
        soulLink     = "/cast Soul Link",
        taintedBlood = "/cast Tainted Blood",
        shadowWard   = "/cast Shadow Ward",
        mount        = "/use Red Skeletal Warhorse",         -- ground mount for the gate sprint
    },

    -- item / buff / pet names used for state detection (enUS)
    item = { hsMajor = "Major Healthstone", hsMaster = "Master Healthstone", spellstone = "Master Spellstone" },
    buff = {
        felArmor = "Fel Armor",
        fireShield = "Fire Shield", unending = "Unending Breath", detectInvis = "Detect Invisibility",
        sacrifice = "Sacrifice", soulLink = "Soul Link", shadowWard = "Shadow Ward", taintedBlood = "Tainted Blood",
    },
}

-- =====================================================================
-- State helpers
-- =====================================================================
local function HasBuff(unit, name)
    if not UnitExists(unit) then return false end
    for i = 1, 40 do
        local n = UnitBuff(unit, i)
        if not n then return false end
        if n == name then return true end
    end
    return false
end

local PET_RANK = { Imp = 1, Voidwalker = 2, Felhunter = 3 }
local function PetFamily() return UnitExists("pet") and UnitCreatureFamily("pet") or nil end
local function PetRank() return PET_RANK[PetFamily() or ""] or 0 end
local function HasPet() return UnitExists("pet") end

local function Have(itemName) return (GetItemCount(itemName) or 0) > 0 end

-- Creation-delay guard (summons + healthstones only) ------------------
-- A summon/conjure can double-fire in two ways when you mash the key:
--   1. Spell-queue window: a spell with a cast time queues a SECOND identical
--      cast if you press again during its last ~0.4s. Nothing you check in
--      done() can undo an already-queued cast.
--   2. Spawn gap: for a beat AFTER the cast lands the pet isn't UnitExists yet
--      / the stone hasn't dropped into the bag yet, so done() reads false and
--      the next press recasts.
-- We close BOTH, scoped to just these steps:
--   * (1) while you're mid-cast on the step's own spell, Refresh blanks the
--         button so a mashed press can't queue a duplicate;
--   * (2) on cast SUCCESS we mark the step done until the real thing is
--         observed. Pets use a monotonic "highest rank summoned this match" so
--         summoning a higher pet (which dismisses the lower one) never re-opens
--         an earlier summon step. Healthstones use a per-tier pending flag that
--         clears the instant the stone lands; trade it away and the step
--         re-offers on its own (stone's gone, pending already cleared).
-- No timers involved: latches clear on the confirming event, not a stopwatch.
local CREATE_HS_NAME = GetSpellInfo(6201) or "Create Healthstone" -- shared by all HS ranks
local SUMMON_NAME = {
    [1] = GetSpellInfo(688) or "Summon Imp",
    [2] = GetSpellInfo(697) or "Summon Voidwalker",
    [3] = GetSpellInfo(691) or "Summon Felhunter",
}
local petSummonedMax = 0   -- highest pet rank summoned this match (monotonic)
local hsPending = {}       -- "hs_major"/"hs_master" -> true until the stone lands

-- A summon step is done if we've summoned that rank (or higher) THIS match
-- (petSummonedMax, monotonic, set on cast success) OR the live pet is EXACTLY
-- that rank. We deliberately use PetRank() == rank (not >=): a HIGHER-rank pet
-- carried in from before the match (e.g. zoning in with a Felhunter) must NOT
-- mark the lower Imp/Voidwalker summons done, or Fire Shield (needs Imp) and
-- Sacrifice (needs Voidwalker) get stranded. Summoning the Imp first replaces
-- the carried-in pet, so the chain self-corrects into normal order.
local function PetStepDone(rank) return petSummonedMax >= rank or PetRank() == rank end
local function HSStepDone(id, item) return Have(item) or hsPending[id] == true end

-- mount for the gate sprint (configurable so the addon is shareable)
local DEFAULT_MOUNT = "Red Skeletal Warhorse"
local OwnedMounts   -- forward decl; defined later (scans bags for mount items)
local function MountName()
    if MagePrepDB and MagePrepDB.mount then return MagePrepDB.mount end
    -- No explicit choice: auto-use the first ground mount found in the user's
    -- bags so the mount step works out of the box for anyone, not just the
    -- author. OwnedMounts() already filters out flying mounts (unusable in the
    -- arena). Falls back to a sensible name if the bag scan comes up empty.
    if OwnedMounts then
        local owned = OwnedMounts()
        if owned and owned[1] then return owned[1] end
    end
    return DEFAULT_MOUNT
end

-- Warlock class mounts are SPELLS you cast, not bag items you use, so they need
-- /cast instead of /use. Keyed by localized spell name.
local WARLOCK_MOUNT_IDS = { 5784, 23161 }   -- Summon Felsteed, Summon Dreadsteed
local WARLOCK_MOUNT_NAME = {
    [GetSpellInfo(5784) or "Summon Felsteed"]   = true,
    [GetSpellInfo(23161) or "Summon Dreadsteed"] = true,
}
-- The action line for the mount step: cast the warlock steed, or use an item mount.
local function MountMacro()
    local m = MountName()
    if WARLOCK_MOUNT_NAME[m] then return "/cast " .. m end
    return "/use " .. m
end

-- Whether we're in "ritual" mode: driven purely by the checkboxes (set via a
-- preset or by hand) - Ritual of Souls enabled and the manual pair disabled.
local function UseRitual()
    local d = MagePrepDB and MagePrepDB.disabled
    local ritualOn = not (d and d.ritual)
    local majorOn  = not (d and d.hsmajor)
    local masterOn = not (d and d.hsmaster)
    return ritualOn and not (majorOn or masterOn)
end
local ritualDone = false  -- set when the Soulwell is actually created; reset each match
local ritualChannelStart = nil  -- GetTime() the current Ritual channel began
local debugOn = false     -- /mp debug: verbose ritual/cast tracing
-- Debug lines are ALSO appended to MagePrepDB.log so they persist to the
-- SavedVariables file on /reload (the in-game chat can't be copied). Capped so it
-- can't grow without bound.
local function DPrint(...)
    if not debugOn then return end
    local msg = table.concat({ tostringall(...) }, "  ")
    print("|cff66ccffLP|r " .. msg)
    MagePrepDB = MagePrepDB or {}
    local t = MagePrepDB.log or {}
    t[#t + 1] = date("%H:%M:%S") .. "  " .. msg
    if #t > 1000 then
        local trimmed = {}
        for i = #t - 600 + 1, #t do trimmed[#trimmed + 1] = t[i] end
        t = trimmed
    end
    MagePrepDB.log = t
end
local RITUAL_NAME = GetSpellInfo(29893) or "Ritual of Souls"  -- 29893 = Ritual of Souls

-- generic "am I casting/channeling this spell right now" (by localized name)
local function IsCasting(spellName)
    return (UnitCastingInfo("player") == spellName) or (UnitChannelInfo("player") == spellName)
end

-- countdown ------------------------------------------------------------
-- gateAt is the GetTime() at which the gates open. Sources, either works:
--   * the "one minute / thirty seconds / fifteen seconds" arena emotes - this
--     is the timer that actually fires on this client and drove the original
--     (working) countdown. Once set, TimeLeft() counts down on its own via
--     GetTime(), so a single message is enough.
--   * START_TIMER - the game's own begin timer; used when it fires, but on the
--     Anniversary client it doesn't reliably show up, so we don't depend on it.
-- Whichever sets gateAt first wins; later messages just refine it.
local gateAt
local function TimeLeft()
    if not gateAt then return nil end
    local t = gateAt - GetTime()
    return (t < 0) and 0 or t
end

-- Soft time-gate for the time-sensitive finish (Felhunter + sac + Soul Link +
-- Shadow Ward + Tainted Blood + mount). Holds them until <= EndPrepSecs() left
-- so mashing early doesn't blow the fresh-shield/short-duration stuff. Tunable
-- via the options slider, stored PER PRESET (2s / 3s5s / bg / custom each keep
-- their own value). Default 12; 0 disables the gate entirely. If no countdown
-- has been detected yet (gateAt nil) we allow it - never lock the user out over
-- a missing timer; order still applies via each step's own checks.
local END_PREP_DEFAULT = 12
local END_PREP_MIN, END_PREP_MAX = 0, 30
local function ClampEndPrep(v)
    if type(v) ~= "number" then return END_PREP_DEFAULT end
    if v < END_PREP_MIN then return END_PREP_MIN end
    if v > END_PREP_MAX then return END_PREP_MAX end
    return math.floor(v + 0.5)
end
local function CurrentPresetKey()
    local k = MagePrepDB and MagePrepDB.preset
    if k == "2s" or k == "3s5s" or k == "bg" or k == "custom" then return k end
    return "custom"
end
local function EndPrepSecs()
    local db = MagePrepDB
    if not db then return END_PREP_DEFAULT end
    local by = db.endPrepByPreset
    if type(by) == "table" then
        local v = by[CurrentPresetKey()]
        if type(v) == "number" then return ClampEndPrep(v) end
    end
    -- Migrate pre-0.15.10 global slider (same value was shared by every preset).
    if type(db.endPrepSecs) == "number" then return ClampEndPrep(db.endPrepSecs) end
    return END_PREP_DEFAULT
end
local function SetEndPrepSecs(v)
    MagePrepDB = MagePrepDB or {}
    MagePrepDB.endPrepByPreset = MagePrepDB.endPrepByPreset or {}
    MagePrepDB.endPrepByPreset[CurrentPresetKey()] = ClampEndPrep(v)
end
local function EndPrepReady()
    local secs = EndPrepSecs()
    if secs <= 0 then return true end   -- slider at 0 = no time gate
    local t = TimeLeft()
    if t == nil then return true end
    return t <= secs
end
local SyncEndPrepSlider  -- fwd: options slider follows the active preset
local function InArena()
    local _, itype = IsInInstance()
    return itype == "arena"
end

-- Any zone where the prep routine runs: arenas and battlegrounds (the BGs preset
-- relies on this so Ritual of Souls' SPELL_CREATE is detected and the per-match
-- state resets outside arenas too).
local function InPrepZone()
    local _, itype = IsInInstance()
    return itype == "arena" or itype == "pvp"
end

local function Partners()
    local out = {}
    local total = GetNumGroupMembers() or 0
    -- party1..partyN (teammates); works for 2s/3s/5s
    for i = 1, math.max(0, total - 1) do out[i] = "party" .. i end
    return out
end

local function IsWarlock(unit)
    -- class comes from the group roster, so it's known even out of range /
    -- before the partner has zoned in
    local _, class = UnitClass(unit)
    return class == "WARLOCK"
end

-- Partners who actually need a healthstone FROM US. Warlocks conjure their own
-- (and never accept a traded one), so pestering them with the trade window just
-- jams the series. This is trade-only: buffs and Ritual of Souls still cover
-- warlock partners like everyone else.
local function StonePartners()
    local out = {}
    for _, u in ipairs(Partners()) do
        if not IsWarlock(u) then out[#out + 1] = u end
    end
    return out
end

-- per-match healthstone trade tracking (declared early; used by the UI)
-- We track by GUID (unique, realm-proof) so cross-realm skirmish partners are
-- matched correctly; tradedNames stays for the traded-count display.
local tradedNames = {}
local tradedGUIDs = {}
local tradeGUID                    -- GUID of the unit in the current trade window
local iAccepted = false            -- is OUR side of the trade accepted? (from TRADE_ACCEPT_UPDATE)
local partnerAccepted = false      -- the OTHER side's accept flag (TRADE_ACCEPT_UPDATE arg2)
local tradeCommitStones = 0        -- healthstones in OUR side seen while BOTH sides were accepted
local function TradedCount()
    local n = 0
    for _ in pairs(tradedNames) do n = n + 1 end
    return n
end
local function HasTraded(unit)
    local g = UnitGUID(unit)
    if g and tradedGUIDs[g] then return true end
    local name = UnitName(unit)
    return name ~= nil and tradedNames[name] == true
end
-- total healthstones currently in bags (used to detect a completed trade)
local function HSCount()
    return (GetItemCount(CFG.item.hsMajor) or 0) + (GetItemCount(CFG.item.hsMaster) or 0)
end

-- =====================================================================
-- Step groups (each can be toggled off in the options panel)
-- =====================================================================
local GROUPS = {
    { key = "hsmajor",      label = "Major Healthstone (2s)" },
    { key = "hsmaster",     label = "Master Healthstone (2s)" },
    { key = "ritual",       label = "Ritual of Souls (3s/5s)" },
    { key = "spellstone",   label = "Master Spellstone" },
    { key = "imp",          label = "Summon Imp" },
    { key = "felarmor",     label = "Fel Armor" },
    { key = "fireshield",   label = "Fire Shield" },
    { key = "unending",     label = "Unending Breath" },
    { key = "detectinvis",  label = "Detect Invisibility" },
    { key = "voidwalker",   label = "Summon Voidwalker" },
    { key = "felhunter",    label = "Summon Felhunter" },
    { key = "sacrifice",    label = "Sacrifice" },
    { key = "soullink",     label = "Soul Link" },
    { key = "shadowward",   label = "Shadow Ward" },
    { key = "taintedblood", label = "Tainted Blood" },
    { key = "mount",        label = "Mount" },
}

local function Enabled(group)
    if not group then return true end
    return not (MagePrepDB and MagePrepDB.disabled and MagePrepDB.disabled[group])
end

-- =====================================================================
-- Step model
-- =====================================================================
local steps = {}

local function BuildSteps()
    wipe(steps)
    local allies = Partners()
    local function add(t)
        if t.group and not Enabled(t.group) then return end
        steps[#steps + 1] = t
    end

    -- Healthstones. Which of these show is driven by the checkboxes (via presets):
    --  * 2s preset:   Major + Master on, Ritual off  -> conjure your pair, trade them
    --  * 3s/5s + BGs: Ritual on, pair off            -> one soulwell, team grabs stones
    -- (2s loop: once you trade a stone away it goes back to "not done" and the
    -- button re-offers it, so you make -> trade -> make ...).
    add({ id = "hs_major", group = "hsmajor", label = "Major Healthstone", macro = CFG.cast.hsMajor,
          castName = CREATE_HS_NAME,
          done = function() return HSStepDone("hs_major", CFG.item.hsMajor) end })
    add({ id = "hs_master", group = "hsmaster", label = "Master Healthstone", macro = CFG.cast.hsMaster,
          castName = CREATE_HS_NAME,
          done = function() return HSStepDone("hs_master", CFG.item.hsMaster) end })
    -- Ritual is done ONLY when the Soulwell actually spawns (ritualDone, set from
    -- the SPELL_CREATE combat-log event). It deliberately does NOT count "you have
    -- a healthstone" as done -- a warlock almost always carries their own stone,
    -- which would make the ritual skip itself every time (it exists to drop a well
    -- for the TEAM, not to give you a stone).
    add({ id = "ritual", group = "ritual", label = "Ritual of Souls (soulwell for the team)", macro = CFG.cast.ritual,
          done = function() return ritualDone end })

    -- Spellstone: create it, then equip it in the wand/relic slot.
    -- (In TBC the spellstone is a wand-slot relic: passive +spell crit, plus an
    --  in-combat on-use that dispels all harmful magic. The dispel is a combat
    --  button, not a prep cast -- see /mp spellstone for a macro.)
    add({ id = "ss_make", group = "spellstone", label = "Create Master Spellstone", macro = CFG.cast.spellstone,
          done = function() return Have(CFG.item.spellstone) or IsEquippedItem(CFG.item.spellstone) end })
    add({ id = "ss_equip", group = "spellstone", label = "Equip Spellstone (wand slot)", macro = CFG.cast.equipSpellstone,
          done = function() return IsEquippedItem(CFG.item.spellstone) end,
          ready = function() return Have(CFG.item.spellstone) end })

    -- Imp (needed for Fire Shield)
    add({ id = "imp", group = "imp", label = "Summon Imp", macro = CFG.cast.summonImp,
          castName = SUMMON_NAME[1],
          done = function() return PetStepDone(1) end })

    -- Self buffs (Fel Armor first - it's your baseline armor buff)
    add({ id = "fa_self", group = "felarmor", label = "Fel Armor (you)", macro = CFG.cast.felArmor,
          done = function() return HasBuff("player", CFG.buff.felArmor) end })
    add({ id = "fs_self", group = "fireshield", label = "Fire Shield (you)", macro = CFG.cast.fireShield:format("player"),
          done = function() return HasBuff("player", CFG.buff.fireShield) end,
          ready = function() return PetFamily() == "Imp" end })
    add({ id = "ub_self", group = "unending", label = "Unending Breath (you)", macro = CFG.cast.unending:format("player"),
          done = function() return HasBuff("player", CFG.buff.unending) end })
    add({ id = "di_self", group = "detectinvis", label = "Detect Invisibility (you)", macro = CFG.cast.detectInvis:format("player"),
          done = function() return HasBuff("player", CFG.buff.detectInvis) end })

    -- Ally buffs (per partner, scales with 2s/3s/5s)
    for _, u in ipairs(allies) do
        add({ id = "fs_" .. u, group = "fireshield", label = "Fire Shield (" .. u .. ")", macro = CFG.cast.fireShield:format(u),
              done = function() return HasBuff(u, CFG.buff.fireShield) end,
              ready = function() return PetFamily() == "Imp" and UnitExists(u) end })
        add({ id = "ub_" .. u, group = "unending", label = "Unending Breath (" .. u .. ")", macro = CFG.cast.unending:format(u),
              done = function() return HasBuff(u, CFG.buff.unending) end,
              ready = function() return UnitExists(u) end })
        add({ id = "di_" .. u, group = "detectinvis", label = "Detect Invisibility (" .. u .. ")", macro = CFG.cast.detectInvis:format(u),
              done = function() return HasBuff(u, CFG.buff.detectInvis) end,
              ready = function() return UnitExists(u) end })
    end

    -- Voidwalker (for Sacrifice shield)
    add({ id = "vw", group = "voidwalker", label = "Summon Voidwalker", macro = CFG.cast.summonVoid,
          castName = SUMMON_NAME[2],
          done = function() return PetStepDone(2) end })

    -- Timed finish -----------------------------------------------------
    -- Felhunter + sac gate on STATE, not the clock: as soon as the voidwalker is
    -- out it's time to swap. Sac/Soul Link buffs persist, so no need to wait for
    -- the countdown. (If you trade your stones away, the healthstone step jumps
    -- back ahead of this in the order, so the button re-offers a stone first.)
    -- Ready once the voidwalker is out (arena sac flow); but if the voidwalker
    -- step is turned off (e.g. the BGs preset), go straight imp -> felhunter.
    -- We use petSummonedMax (not just the live PetRank) so the step stays ready
    -- through the no-pet gap: when you sacrifice the VW mid-summon the pet is
    -- gone for a beat, and a live-only check would drop Felhunter's readiness and
    -- skip ahead to Shadow Ward. Once you've had a VW this match, Felhunter is
    -- always reachable (and re-offered if the summon gets cut after the sac).
    -- No castName here: the Felhunter cast has its own handling in Refresh
    -- (felCastFrac) which offers the Voidwalker sac mid-cast.
    add({ id = "fh", group = "felhunter", label = "Summon Felhunter", macro = CFG.cast.summonFel,
          done = function() return PetStepDone(3) end,
          ready = function() return EndPrepReady()
                    and (PetRank() >= 2 or petSummonedMax >= 2 or not Enabled("voidwalker")) end })
    add({ id = "sac", group = "sacrifice", label = "Sacrifice VW (during Felhunter cast!)", macro = CFG.cast.sacrifice,
          done = function() return HasBuff("player", CFG.buff.sacrifice) or PetRank() >= 3 end,
          ready = function() return EndPrepReady() and PetFamily() == "Voidwalker" end })
    -- Ready check tolerates the felhunter spawn gap (petSummonedMax>=3): right
    -- after the summon lands the pet isn't UnitExists yet, and a live-only check
    -- would let Shadow Ward jump ahead of Soul Link. A press before the pet is
    -- up just no-ops (no demon = no GCD) and retries on the next mash.
    add({ id = "sl", group = "soullink", label = "Soul Link", macro = CFG.cast.soulLink,
          done = function() return HasBuff("player", CFG.buff.soulLink) end,
          ready = function() return EndPrepReady()
                    and (PetFamily() == "Felhunter" or petSummonedMax >= 3) end })
    -- These last steps are order-gated only (no countdown timing). The gate
    -- countdown on the Anniversary client is unreliable to parse, and mistiming
    -- these costs mana, so we just enforce order and let you press them when the
    -- gate is about to open -- same as the rest of the routine.
    add({ id = "sw", group = "shadowward", label = "Shadow Ward", macro = CFG.cast.shadowWard,
          done = function() return HasBuff("player", CFG.buff.shadowWard) end,
          ready = EndPrepReady })
    -- Tainted Blood MUST come before the mount: you can't use any ability
    -- (yours or the pet's) while mounted. Pet abilities don't share your GCD,
    -- so it's fine right alongside Shadow Ward.
    add({ id = "tb", group = "taintedblood", label = "Tainted Blood", macro = CFG.cast.taintedBlood,
          done = function() return HasBuff("pet", CFG.buff.taintedBlood) end,
          ready = function() return EndPrepReady()
                    and (PetFamily() == "Felhunter" or petSummonedMax >= 3) end })
    -- Mount is the very last thing (mounting locks out all abilities).
    add({ id = "mount", group = "mount", label = "Mount up (" .. MountName() .. ")", macro = MountMacro(),
          done = function() return IsMounted() end,
          ready = EndPrepReady })
end

local function FirstIncomplete()
    for _, s in ipairs(steps) do
        if not s.done() then
            if (not s.ready) or s.ready() then return s end
        end
    end
end

-- =====================================================================
-- Secure "next step" button
-- =====================================================================
-- Kept shown (tiny, transparent, mouse-off) -- hidden secure buttons can fail
-- to trigger from keybinds/click.
local button = CreateFrame("Button", "MagePrepButton", UIParent, "SecureActionButtonTemplate")
button:SetSize(1, 1)
button:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
button:SetAlpha(0)
button:EnableMouse(false)
button:RegisterForClicks("AnyDown") -- CLICK keybinds fire on key-down
button:SetAttribute("type", "macro")

-- Spellstone swap button. Smart toggle on one keybind:
--   * stone equipped  -> dispel (off-GCD) + swap wand in
--   * wand equipped   -> re-equip the stone (arms the 30s equip cooldown so the
--                        next press can dispel)
-- The stone is equipped during prep, so its equip CD is already gone by the
-- gates and the first press dispels immediately.
local ssButton = CreateFrame("Button", "MagePrepSpellstoneButton", UIParent, "SecureActionButtonTemplate")
ssButton:SetSize(1, 1)
ssButton:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
ssButton:SetAlpha(0)
ssButton:EnableMouse(false)
ssButton:RegisterForClicks("AnyDown") -- single fire so the toggle doesn't undo itself
ssButton:SetAttribute("type", "macro")

local function SpellstoneMacro()
    local wand = MagePrepDB and MagePrepDB.wand
    if wand and wand ~= "" then
        return "/use [noequipped:Wand] " .. CFG.item.spellstone ..
             "\n/equip [equipped:Wand] " .. CFG.item.spellstone ..
             "\n/equip [noequipped:Wand] " .. wand
    end
    -- no wand set yet: just dispel with the equipped stone
    return "/use " .. CFG.item.spellstone
end

local function UpdateSpellstoneButton()
    if InCombatLockdown() then return end
    ssButton:SetAttribute("macrotext", SpellstoneMacro())
end

local currentId
local function HaveAnyStone()
    return Have(CFG.item.hsMajor) or Have(CFG.item.hsMaster)
end

-- Felhunter-summon awareness: while you're casting Summon Felhunter we hand the
-- button the Voidwalker Sacrifice (the classic "sac during the felpup cast"),
-- and expose the cast progress so the checklist can show a % / "SAC NOW" cue.
local FEL_NAME = GetSpellInfo(691) or "Summon Felhunter"  -- 691 = Summon Felhunter
local felCastFrac = nil   -- 0..1 while summoning felhunter, else nil (read by UI)
local felAction = nil     -- action-line override while sac is offered
local function SacDone()
    return HasBuff("player", CFG.buff.sacrifice) or PetRank() >= 3
end
local function FelSummonProgress()
    local name, _, _, startMs, endMs = UnitCastingInfo("player")
    if not name or name ~= FEL_NAME then return nil end
    if not startMs or not endMs or endMs <= startMs then return 0 end
    local frac = (GetTime() * 1000 - startMs) / (endMs - startMs)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return frac
end

local function Refresh()
    if #steps == 0 then BuildSteps() end
    -- Drop a healthstone pending-latch the instant the real stone lands, so the
    -- 2s make -> trade -> make loop re-offers with no delay. (Pet ranks are
    -- monotonic for the match and reset on a new arena.)
    if hsPending.hs_major and Have(CFG.item.hsMajor) then hsPending.hs_major = nil end
    if hsPending.hs_master and Have(CFG.item.hsMaster) then hsPending.hs_master = nil end
    local step = FirstIncomplete()
    local macro = step and step.macro or ""
    felCastFrac = FelSummonProgress()
    felAction = nil
    if IsCasting(RITUAL_NAME) then
        -- Ritual of Souls in progress: cast nothing so a stray press can't
        -- interrupt the channel (teammates need the soulwell to finish).
        macro = ""
        currentId = "ritual"
    elseif felCastFrac then
        -- mid-felhunter-summon: offer the VW sac (if enabled, not yet done, and
        -- the voidwalker is still out), otherwise cast nothing so a stray press
        -- can't interrupt the summon.
        if Enabled("sacrifice") and not SacDone() and PetFamily() == "Voidwalker" then
            macro = CFG.cast.sacrifice
            currentId = "sac"
            felAction = "Sacrifice Voidwalker!"
        else
            macro = ""
            currentId = nil
        end
    elseif step and step.castName and IsCasting(step.castName) then
        -- Mid-cast on this step's OWN spell (summon / conjure): cast nothing so a
        -- mashed press can't queue a duplicate in the spell-queue window. Keep
        -- currentId pointed at the step so cast-SUCCESS latches the right tier.
        macro = ""
        currentId = step.id
    else
        currentId = step and step.id or nil
    end
    -- While a trade window is open and we still owe an accept, the button's only
    -- job is to accept (handled in PreClick), so blank the prep cast. But once
    -- WE'VE accepted (our stone is in, waiting on them), un-blank so you can keep
    -- prepping while they take their time -- casting doesn't cancel the trade, and
    -- if they never accept you're not jammed. (If they change the trade our accept
    -- resets, iAccepted flips false, and we blank again to re-accept.)
    if TradeFrame and TradeFrame:IsShown() and not iAccepted then
        macro = ""
    end
    if not InCombatLockdown() then
        button:SetAttribute("macrotext", macro)
    end
    if MagePrep_UpdateUI then MagePrep_UpdateUI() end
end

-- =====================================================================
-- UI: checklist overlay
-- =====================================================================
-- ---------------------------------------------------------------------
-- Skin helpers (shared by the overlay + options panel)
-- ---------------------------------------------------------------------
local MP_FONT = "Fonts\\FRIZQT__.TTF"
local WHITE8  = "Interface\\Buttons\\WHITE8X8"

local function MP_FS(parent, size, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(MP_FONT, size, flags or "")
    return fs
end

local function MP_Tex(parent, layer)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetTexture(WHITE8)
    return t
end

-- horizontal gradient that works on both the old (SetGradientAlpha) and the
-- new (SetGradient + CreateColor) texture APIs
local function MP_Grad(tex, r1, g1, b1, a1, r2, g2, b2, a2)
    if tex.SetGradient and CreateColor then
        tex:SetVertexColor(1, 1, 1, 1)
        tex:SetGradient("HORIZONTAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    elseif tex.SetGradientAlpha then
        tex:SetVertexColor(1, 1, 1, 1)
        tex:SetGradientAlpha("HORIZONTAL", r1, g1, b1, a1, r2, g2, b2, a2)
    else
        tex:SetVertexColor((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

-- flat dark panel, 1px border, hairline sheen under the top edge
local function MP_SkinPanel(f, br, bg, bb)
    f:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
    f:SetBackdropColor(0.035, 0.055, 0.095, 0.97)
    f:SetBackdropBorderColor(br, bg, bb, 1)
    local sheen = MP_Tex(f, "BORDER")
    sheen:SetPoint("TOPLEFT", 1, -1); sheen:SetPoint("TOPRIGHT", -1, -1)
    sheen:SetHeight(1)
    sheen:SetVertexColor(0.55, 0.75, 0.98, 0.10)
end

local function MP_Close(parent, onclick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 18)
    b:SetPoint("TOPRIGHT", -6, -6)
    local x = MP_FS(b, 13)
    x:SetPoint("CENTER", 0, 0); x:SetText("x"); x:SetTextColor(0.38, 0.48, 0.62)
    b:SetScript("OnEnter", function() x:SetTextColor(0.78, 0.88, 0.98) end)
    b:SetScript("OnLeave", function() x:SetTextColor(0.38, 0.48, 0.62) end)
    b:SetScript("OnClick", onclick)
    return b
end

-- adds a 30px header strip (mage-blue tint + divider) and returns it
local function MP_Header(f)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", 1, -1); bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(29)
    local bg = MP_Tex(bar); bg:SetAllPoints(); bg:SetVertexColor(0.28, 0.48, 0.78, 0.07)
    local div = MP_Tex(bar, "BORDER")
    div:SetPoint("BOTTOMLEFT"); div:SetPoint("BOTTOMRIGHT"); div:SetHeight(1)
    div:SetVertexColor(0.40, 0.52, 0.68, 0.18)
    return bar
end

local ui = CreateFrame("Frame", "MagePrepFrame", UIParent, "BackdropTemplate")
ui:SetSize(308, 120)
ui:SetPoint("CENTER", UIParent, "CENTER", 350, 0)
MP_SkinPanel(ui, 0.18, 0.32, 0.52)
ui:SetMovable(true)
ui:EnableMouse(true)
ui:RegisterForDrag("LeftButton")
ui:SetClampedToScreen(true)
ui:SetScript("OnDragStart", function(self) if not self.locked then self:StartMoving() end end)
ui:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, r, x, y = self:GetPoint()
    MagePrepDB = MagePrepDB or {}
    MagePrepDB.pos = { p, r, x, y }
end)
ui:Hide()

local headerBar = MP_Header(ui)
do
    local gem = MP_Tex(headerBar, "ARTWORK")
    gem:SetSize(7, 7); gem:SetPoint("LEFT", 12, 0)
    gem:SetVertexColor(0.32, 0.58, 0.95, 1)
    gem:SetRotation(math.pi / 4)
    local title = MP_FS(headerBar, 13)
    title:SetPoint("LEFT", 26, 0); title:SetText("MagePrep")
    title:SetTextColor(0.78, 0.88, 0.98)
    local hint = MP_FS(headerBar, 9)
    hint:SetPoint("LEFT", title, "RIGHT", 7, -1)
    hint:SetText("right-click: options")
    hint:SetTextColor(0.38, 0.50, 0.66)
end

-- Fade the checklist out (mounting / gates open). Hard-hide when done so it
-- stays gone for the rest of the match; ShowUI resets alpha for the next one.
local fadeOut = ui:CreateAnimationGroup()
do
    local a = fadeOut:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    a:SetDuration(0.45)
    a:SetSmoothing("OUT")
end
fadeOut:SetScript("OnFinished", function()
    ui.fading = false
    ui.userHidden = true
    ui.preview = false
    ui:Hide()
    ui:SetAlpha(1)
end)
local function FadeOutChecklist()
    if ui.fading or not ui:IsShown() then return end
    ui.fading = true
    fadeOut:Stop()
    ui:SetAlpha(1)
    fadeOut:Play()
end
local function DismissChecklist()
    if fadeOut:IsPlaying() then fadeOut:Stop() end
    ui.fading = false
    ui.userHidden = true
    ui.preview = false
    ui:SetAlpha(1)
    ui:Hide()
end

local closeBtn = MP_Close(ui, DismissChecklist)

-- countdown pill (top right)
local cdPill = CreateFrame("Frame", nil, headerBar, "BackdropTemplate")
cdPill:SetSize(42, 18)
cdPill:SetPoint("RIGHT", headerBar, "RIGHT", -26, 0)
cdPill:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
cdPill:SetBackdropColor(0, 0, 0, 0.35)
cdPill:SetBackdropBorderColor(0.28, 0.40, 0.55, 0.6)
local cdText = MP_FS(cdPill, 12)
cdText:SetPoint("CENTER", 0, 0)
cdPill:Hide()

-- "next press" block: label, key chip, big action line
local actionBlock = CreateFrame("Frame", nil, ui)
actionBlock:SetPoint("TOPLEFT", headerBar, "BOTTOMLEFT", 0, 0)
actionBlock:SetPoint("TOPRIGHT", headerBar, "BOTTOMRIGHT", 0, 0)
actionBlock:SetHeight(44)
do
    local bg = MP_Tex(actionBlock)
    bg:SetAllPoints()
    MP_Grad(bg, 0.32, 0.58, 0.95, 0.13, 0.32, 0.58, 0.95, 0.0)
    local div = MP_Tex(actionBlock, "BORDER")
    div:SetPoint("BOTTOMLEFT"); div:SetPoint("BOTTOMRIGHT"); div:SetHeight(1)
    div:SetVertexColor(0.40, 0.52, 0.68, 0.14)
    local lbl = MP_FS(actionBlock, 9)
    lbl:SetPoint("TOPLEFT", 12, -7)
    lbl:SetText("NEXT PRESS")
    lbl:SetTextColor(0.48, 0.60, 0.76)
end
local keyChip = CreateFrame("Frame", nil, actionBlock, "BackdropTemplate")
keyChip:SetSize(24, 16)
keyChip:SetPoint("TOPLEFT", 12, -20)
keyChip:SetBackdrop({ bgFile = WHITE8 })
keyChip:SetBackdropColor(0.66, 0.88, 0.42, 1)
local keyText = MP_FS(keyChip, 11)
keyText:SetPoint("CENTER", 0, 0)
keyText:SetTextColor(0.05, 0.04, 0.08)
local actionFS = MP_FS(actionBlock, 13)
actionFS:SetJustifyH("LEFT")
actionFS:SetWordWrap(true)

-- felhunter cast bar (only visible mid-summon)
local castBlock = CreateFrame("Frame", nil, ui)
castBlock:SetPoint("TOPLEFT", actionBlock, "BOTTOMLEFT", 12, -6)
castBlock:SetPoint("RIGHT", ui, "RIGHT", -12, 0)
castBlock:SetHeight(1)
do
    local nm = MP_FS(castBlock, 11)
    nm:SetPoint("TOPLEFT", 0, 0)
    nm:SetText("Summon Felhunter")
    nm:SetTextColor(0.78, 0.63, 0.35)
end
local castPct = MP_FS(castBlock, 11)
castPct:SetPoint("TOPRIGHT", 0, 0)
local castBar = CreateFrame("StatusBar", nil, castBlock, "BackdropTemplate")
castBar:SetPoint("BOTTOMLEFT", 0, 2); castBar:SetPoint("BOTTOMRIGHT", 0, 2)
castBar:SetHeight(7)
castBar:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
castBar:SetBackdropColor(0, 0, 0, 0.5)
castBar:SetBackdropBorderColor(0.28, 0.40, 0.55, 0.5)
castBar:SetStatusBarTexture(WHITE8)
castBar:SetMinMaxValues(0, 1)
castBlock:Hide()

-- healthstone trade progress ("Healthstones traded: 1/2")
local tradeFS = MP_FS(ui, 11)
tradeFS:SetPoint("TOPLEFT", castBlock, "BOTTOMLEFT", 0, -5)
tradeFS:SetPoint("RIGHT", ui, "RIGHT", -12, 0)
tradeFS:SetJustifyH("LEFT")
tradeFS:SetText("")

-- step rows: mark box + label + NOW/HELD tag, current row gets a mage-blue wash
local rows = {}
local function GetRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, ui)
    -- stack each row under the previous one's actual bottom, so a wrapped
    -- (two-line) label pushes everything below it down instead of overlapping
    if i == 1 then
        r:SetPoint("TOPLEFT", tradeFS, "BOTTOMLEFT", -4, -6)
    else
        r:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, -1)
    end
    r:SetPoint("RIGHT", ui, "RIGHT", -8, 0)
    r.bg = MP_Tex(r)
    r.bg:SetAllPoints()
    r.box = CreateFrame("Frame", nil, r, "BackdropTemplate")
    r.box:SetSize(13, 13)
    r.box:SetPoint("TOPLEFT", 5, -3)
    r.box:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
    r.mark = MP_FS(r.box, 9)
    r.mark:SetPoint("CENTER", 0.5, 0)
    r.tag = MP_FS(r, 8)
    r.tag:SetPoint("TOPRIGHT", -4, -6)
    r.label = MP_FS(r, 12)
    r.label:SetPoint("TOPLEFT", 26, -4)
    r.label:SetPoint("RIGHT", r, "RIGHT", -34, 0)
    r.label:SetJustifyH("LEFT")
    r.label:SetWordWrap(true)
    rows[i] = r
    return r
end

local function BoundKey()
    return GetBindingKey("CLICK MagePrepButton:LeftButton")
end

function MagePrep_UpdateUI()
    if not ui:IsShown() then return end
    -- countdown pill
    local t = TimeLeft()
    if t then
        cdText:SetText(string.format("0:%02d", math.floor(t + 0.5)))
        if t <= 5 then cdText:SetTextColor(1, 0.48, 0.42)
        else cdText:SetTextColor(0.94, 0.82, 0.38) end
        cdPill:SetWidth(math.max(38, cdText:GetStringWidth() + 14))
        cdPill:Show()
    else
        cdPill:Hide()
    end

    -- step rows
    local shown, curLabel, anyIncomplete = 0, nil, false
    local rowsH = 0
    for i, s in ipairs(steps) do
        local row = GetRow(i)
        local done = s.done()
        local ready = (not s.ready) or s.ready()
        if not done then anyIncomplete = true end
        if s.id == currentId then curLabel = s.label end
        row.label:SetText(s.label)
        row.tag:SetText("")
        if done then
            MP_Grad(row.bg, 0, 0, 0, 0, 0, 0, 0, 0)
            row.box:SetBackdropColor(0.18, 0.38, 0.18, 0.5)
            row.box:SetBackdropBorderColor(0.29, 0.48, 0.29, 1)
            row.mark:SetText("v"); row.mark:SetTextColor(0.48, 0.82, 0.48)
            row.label:SetTextColor(0.36, 0.46, 0.58)
        elseif s.id == currentId then
            MP_Grad(row.bg, 0.32, 0.58, 0.95, 0.22, 0.32, 0.58, 0.95, 0.02)
            row.box:SetBackdropColor(0.32, 0.58, 0.95, 0.35)
            row.box:SetBackdropBorderColor(0.32, 0.58, 0.95, 1)
            row.mark:SetText(">"); row.mark:SetTextColor(0.72, 0.86, 1.00)
            row.label:SetTextColor(0.92, 0.96, 1.00)
            row.tag:SetText("NOW"); row.tag:SetTextColor(0.55, 0.75, 0.98)
        elseif not ready then
            MP_Grad(row.bg, 0, 0, 0, 0, 0, 0, 0, 0)
            row.box:SetBackdropColor(0, 0, 0, 0.25)
            row.box:SetBackdropBorderColor(0.18, 0.28, 0.40, 1)
            row.mark:SetText("")
            row.label:SetTextColor(0.36, 0.46, 0.58)
            row.tag:SetText("HELD"); row.tag:SetTextColor(0.22, 0.32, 0.45)
        else
            MP_Grad(row.bg, 0, 0, 0, 0, 0, 0, 0, 0)
            row.box:SetBackdropColor(0, 0, 0, 0.3)
            row.box:SetBackdropBorderColor(0.22, 0.32, 0.45, 1)
            row.mark:SetText("")
            row.label:SetTextColor(0.62, 0.72, 0.86)
        end
        local h = math.max(19, (row.label:GetStringHeight() or 12) + 8)
        row:SetHeight(h)
        rowsH = rowsH + h + 1
        row:Show()
        shown = i
    end
    for i = shown + 1, #rows do rows[i]:Hide() end

    -- action line: tells a new user exactly what to do
    local key = BoundKey()
    actionFS:ClearAllPoints()
    if key then
        keyText:SetText(key)
        keyChip:SetWidth(math.max(20, keyText:GetStringWidth() + 10))
        keyChip:Show()
        actionFS:SetPoint("TOPLEFT", keyChip, "TOPRIGHT", 8, 0)
        actionFS:SetPoint("RIGHT", ui, "RIGHT", -10, 0)
    else
        keyChip:Hide()
        actionFS:SetPoint("TOPLEFT", actionBlock, "TOPLEFT", 12, -20)
        actionFS:SetPoint("RIGHT", ui, "RIGHT", -10, 0)
    end
    actionFS:SetTextColor(0.92, 0.96, 1.00)
    if not key then
        actionFS:SetText("|cffff6666No key bound|r - type |cffffffff/mp bind <KEY>|r")
    elseif felAction then
        actionFS:SetText("|cffff5555" .. felAction .. "|r")
    elseif curLabel then
        actionFS:SetText(curLabel)
    elseif anyIncomplete then
        local tl = TimeLeft()
        local gate = EndPrepSecs()
        if tl and gate > 0 and tl > gate then
            actionFS:SetText(string.format("|cffaaaaaaHolding the finish until %ds left (%ds)|r",
                gate, math.floor(tl + 0.5)))
        else
            actionFS:SetText("|cffaaaaaaWaiting for the countdown...|r")
        end
    else
        actionFS:SetText("|cff55ff55All set - good luck!|r")
    end

    -- Dismiss once prep is effectively over: as soon as you start mounting
    -- (cast or already mounted), or the gates have opened. Arena/BG only so
    -- /mp test outside a match isn't killed just because you're on a horse.
    if not ui.fading and InPrepZone() then
        local casting = UnitCastingInfo("player")
        local mounting = IsMounted() or (casting and casting == MountName())
        local gatesOpen = (TimeLeft() ~= nil and TimeLeft() <= 0)
        if mounting or gatesOpen then
            FadeOutChecklist()
        end
    end

    actionBlock:SetHeight(20 + math.max(16, actionFS:GetStringHeight() or 13) + 9)

    -- felhunter summon progress bar (fills orange, flips green at 90%)
    if felCastFrac then
        local pct = math.floor(felCastFrac * 100 + 0.5)
        castBar:SetValue(felCastFrac)
        if felCastFrac >= 0.90 then
            castBar:SetStatusBarColor(0.42, 0.82, 0.42)
            castPct:SetText(pct .. "%  SAC NOW")
            castPct:SetTextColor(1, 0.48, 0.42)
        else
            castBar:SetStatusBarColor(0.88, 0.63, 0.32)
            castPct:SetText(pct .. "%")
            castPct:SetTextColor(0.94, 0.82, 0.38)
        end
        castBlock:SetHeight(26)
        castBlock:Show()
    else
        castBlock:SetHeight(1)
        castBlock:Hide()
    end

    -- trade progress (2s only; in 3s/5s people grab from the soulwell)
    -- count only warlock-free partners - a warlock partner never needs a stone
    local partners = #StonePartners()
    if UseRitual() then
        tradeFS:SetText(ritualDone and "|cff55ff55Soulwell up - team grabs their own|r" or "")
    elseif partners > 0 then
        local n = TradedCount()
        local col = (n >= partners) and "|cff55ff55" or "|cff88ccff"
        tradeFS:SetText(col .. "Healthstones traded: " .. n .. "/" .. partners .. "|r")
    else
        tradeFS:SetText("")
    end

    -- size the window to the real (possibly wrapped) content height
    local h = 29 + actionBlock:GetHeight() + 6 + castBlock:GetHeight() + 5
        + (tradeFS:GetStringHeight() or 0) + 6 + rowsH + 8
    ui:SetHeight(h + 2)
end

-- =====================================================================
-- Show / hide
-- =====================================================================
local function ApplyPos()
    ui:ClearAllPoints()
    local p = MagePrepDB and MagePrepDB.pos
    if p then ui:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else ui:SetPoint("CENTER", UIParent, "CENTER", 350, 0) end
end

local function ShowUI()
    if fadeOut:IsPlaying() then fadeOut:Stop() end
    ui.fading = false
    ui:SetAlpha(1)
    BuildSteps(); ApplyPos(); Refresh(); ui:Show()
end
local function HideUI()
    if fadeOut:IsPlaying() then fadeOut:Stop() end
    ui.fading = false
    ui:SetAlpha(1)
    ui:Hide()
end

-- =====================================================================
-- Trade auto-fill: drop your healthstones into the trade window.
-- Filling the trade window is NOT a protected action (this is how
-- TradeDispenser etc. work), so it runs from the TRADE_SHOW event. You
-- still click Accept yourself (AcceptTrade needs a real click).
-- =====================================================================
local tradeArmed = false      -- one-shot arm, for testing outside an arena
local tradeHadStones = false  -- did we put stones in the current trade?
local tradePartner = nil      -- who we're trading with (captured at TRADE_SHOW)
local tradeStartHS = 0        -- healthstone count when the trade opened
-- (iAccepted is declared earlier, near the trade-tracking state, so Refresh can read it)
local tradeFilledAt = 0       -- when we auto-filled; wait a beat before accepting
local TRADE_SETTLE = 0.4      -- so the item-placement confirms land before we accept
-- (tradedNames / TradedCount / HSCount are declared earlier, near Partners())

-- container API works via C_Container (modern) or legacy globals
local C = _G.C_Container
local GetNumSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
local GetItemLink = (C and C.GetContainerItemLink) or GetContainerItemLink
local PickupItem  = (C and C.PickupContainerItem) or PickupContainerItem

local function AutoTradeOn()
    return not (MagePrepDB and MagePrepDB.autoTrade == false)
end

-- window is OFF by default now (toggle via the minimap icon). Opt in to have it
-- pop automatically when you zone into an arena.
local function AutoShowOn()
    return MagePrepDB and MagePrepDB.autoShow == true
end

local function FindBagItem(name)
    for bag = 0, 4 do
        local slots = GetNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetItemLink(bag, slot)
            if link and link:find(name, 1, true) then
                return bag, slot
            end
        end
    end
end

local function PlaceInTrade(name, tradeSlot)
    local bag, slot = FindBagItem(name)
    if not bag then return false end
    ClearCursor()
    PickupItem(bag, slot)
    ClickTradeButton(tradeSlot)
    ClearCursor()
    return true
end

local function FillTrade()
    tradeArmed = false
    local placed = 0
    if PlaceInTrade(CFG.item.hsMajor, 1) then placed = placed + 1 end
    if PlaceInTrade(CFG.item.hsMaster, 2) then placed = placed + 1 end
    tradeHadStones = placed > 0
    if placed > 0 then
        tradeFilledAt = GetTime()   -- let the placement confirms settle before we accept
        print("|cff66b3ffMagePrep|r: placed " .. placed .. " healthstone(s) - keep pressing your button to accept")
    else
        print("|cff66b3ffMagePrep|r: no healthstones in bags to trade (conjure a pair first)")
    end
end

-- How many of MY offered trade items are healthstones (so we only accept a
-- trade that actually has the stones in it).
local function StonesInTrade()
    local n = 0
    for i = 1, 7 do
        local link = GetTradePlayerItemLink and GetTradePlayerItemLink(i)
        if link and link:find("Healthstone", 1, true) then n = n + 1 end
    end
    return n
end

-- Is the person we're trading with actually one of our teammates? (Never
-- auto-accept a stranger's trade - only stones we placed or a teammate's gift.)
local function TradeFromTeammate()
    local g = UnitGUID("npc")
    if not g then return false end
    for _, u in ipairs(Partners()) do
        if UnitGUID(u) == g then return true end
    end
    return false
end

-- Has the other side actually put an item in yet? Stops us from accepting an
-- empty window the instant a teammate opens it (before they drop the food in).
local function TargetHasItems()
    for i = 1, 7 do
        if GetTradeTargetItemLink and GetTradeTargetItemLink(i) then return true end
    end
    return false
end

-- First partner (2s: party1) who still needs a stone. Skips anyone already
-- traded this match and anyone not currently present.
local function NextTradePartner()
    -- StonePartners() excludes warlocks (they make their own), so we never open
    -- a trade window with a partner who'll never accept it.
    for _, u in ipairs(StonePartners()) do
        if UnitExists(u) and not HasTraded(u) then
            return u, UnitName(u)
        end
    end
end

-- Fold trade handling into the SPAM key. PreClick runs on the same hardware
-- press (before the secure cast), so mashing your normal button:
--   * accepts an open stone-trade (AcceptTrade), and
--   * opens a trade with the next partner who needs a stone (InitiateTrade).
-- Both are legal from this hardware context; InitiateTrade(unit) does NOT change
-- your target, so you keep pressing through the rest of prep uninterrupted.
local lastInitiate = 0
local lastTradeClosed = 0        -- set on TRADE_CLOSED; blocks an instant empty re-open
local TRADE_REOPEN_CD = 1.5      -- > the 0.4s bag-drop confirm, with margin for bag lag
button:SetScript("PreClick", function()
    -- 1) a trade is already open -> accept it if our stones are in. AcceptTrade()
    -- TOGGLES, so calling it again while already accepted un-accepts you (green ->
    -- gray flicker). Only accept when our side isn't accepted yet; iAccepted is
    -- kept in sync from TRADE_ACCEPT_UPDATE. (The prep cast is blanked in Refresh
    -- while the window is up, so a mash here only accepts.)
    if TradeFrame and TradeFrame:IsShown() then
        -- Only accept when Blizzard's Accept button is actually enabled. If the
        -- other side adds/changes items (a mage handing back food/water), WoW
        -- un-accepts both sides and locks the button for a few seconds (anti-scam
        -- countdown); mashing AcceptTrade() through that is what caused the "-1" /
        -- stuck states. We just wait it out, then accept once when it clears.
        local acceptBtn = _G.TradeFrameTradeButton
        local canAccept = (not acceptBtn) or acceptBtn:IsEnabled()
        -- Accept when EITHER our stones are in (the give flow) OR a teammate has
        -- put something in for us (food/water back). Never a stranger, never an
        -- empty window.
        local shouldAccept = StonesInTrade() > 0
                             or (TradeFromTeammate() and TargetHasItems())
        if shouldAccept and not iAccepted and canAccept
           and (GetTime() - tradeFilledAt) > TRADE_SETTLE then
            iAccepted = true          -- optimistic; TRADE_ACCEPT_UPDATE corrects it
            AcceptTrade()
        end
        return
    end
    -- 2) 2s only: we hold a stone and a partner still needs one -> open the trade.
    -- The close cooldown covers the gap right after a trade completes: the stone
    -- has left the bags but HasTraded() isn't recorded until the bag-drop confirm
    -- lands (~0.4s later), so without it a mash would re-open an empty trade with
    -- the partner we just finished with.
    if AutoTradeOn() and InArena() and not UseRitual() and HaveAnyStone()
       and (GetTime() - lastInitiate) > 1.0
       and (GetTime() - lastTradeClosed) > TRADE_REOPEN_CD then
        local u = NextTradePartner()
        if u then
            lastInitiate = GetTime()
            InitiateTrade(u)
        end
    end
end)

-- Optional standalone accept key (same guard) for anyone who wants a dedicated bind.
local acceptBtn = CreateFrame("Button", "MagePrepAcceptButton", UIParent)
acceptBtn:RegisterForClicks("AnyDown")
acceptBtn:SetScript("OnClick", function()
    if not (TradeFrame and TradeFrame:IsShown()) then
        print("|cff66b3ffMagePrep|r: no trade window open")
        return
    end
    if StonesInTrade() > 0 then
        AcceptTrade()
    else
        print("|cff66b3ffMagePrep|r: no healthstone in the trade yet - not accepting")
    end
end)

-- =====================================================================
-- Options panel (checkboxes to include/exclude step groups)
-- =====================================================================
-- Presets: one click sets a whole configuration of checkboxes.
-- Major Healthstone + Master Spellstone are left OFF in every preset (personal
-- preference); tick them yourself if you use them.
local PRESETS = {
    ["2s"]   = { label = "2s",     disabled = { hsmajor = true, spellstone = true, ritual = true } },
    ["3s5s"] = { label = "3s / 5s", disabled = { hsmajor = true, hsmaster = true, spellstone = true } },
    ["bg"]   = { label = "BGs",    disabled = { hsmajor = true, hsmaster = true, spellstone = true, taintedblood = true, voidwalker = true, sacrifice = true, shadowward = true } },
    -- "custom" restores the user's last hand-tuned checkbox set (saved in
    -- MagePrepDB.customDisabled). Hand-editing any box also flips to this.
    ["custom"] = { label = "Custom", custom = true },
}
local PRESET_ORDER = { "2s", "3s5s", "bg", "custom" }

local groupChecks = {}   -- key -> check row, so presets can refresh their state
local allChecks = {}     -- every check row (refreshed on panel show)
local UpdatePresetSeg    -- fwd: highlights the active preset segment

local function RefreshGroupChecks()
    for _, row in pairs(groupChecks) do row:Refresh() end
end

-- Persist the current checkbox set as the Custom preset so switching away to
-- 2s/3s/BGs and back doesn't lose the user's hand-tuned config.
local function SnapshotCustom()
    MagePrepDB = MagePrepDB or {}
    local copy = {}
    for k, v in pairs(MagePrepDB.disabled or {}) do copy[k] = v end
    MagePrepDB.customDisabled = copy
end

local function ApplyPreset(key)
    local p = PRESETS[key]; if not p then return end
    MagePrepDB = MagePrepDB or {}
    local cur = MagePrepDB.preset
    -- Leaving Custom: remember its boxes before a named preset overwrites them.
    if (cur == "custom" or not cur) and not p.custom then
        SnapshotCustom()
    end
    if p.custom then
        -- Restore the remembered Custom configuration (if any).
        local saved = MagePrepDB.customDisabled
        if saved then
            local copy = {}
            for k, v in pairs(saved) do copy[k] = v end
            MagePrepDB.disabled = copy
        end
        -- else: first time on Custom with nothing saved -- leave boxes as-is
    else
        MagePrepDB.disabled = {}
        for grp, v in pairs(p.disabled) do MagePrepDB.disabled[grp] = v end
    end
    MagePrepDB.preset = key
    RefreshGroupChecks()
    if UpdatePresetSeg then UpdatePresetSeg() end
    if SyncEndPrepSlider then SyncEndPrepSlider() end
    BuildSteps(); Refresh()
end

local opt = CreateFrame("Frame", "MagePrepOptions", UIParent, "BackdropTemplate")
opt:SetSize(340, 400)   -- height is set after layout below
opt:SetPoint("CENTER")
MP_SkinPanel(opt, 0.22, 0.38, 0.62)
-- Solid black/blue fill (opaque) so UI behind the panel never bleeds through.
opt:SetBackdropColor(0.03, 0.05, 0.10, 1)
do
    -- Child frame ABOVE the backdrop fill, BELOW options controls.
    -- (Textures on the parent BACKGROUND layer sit under SetBackdrop and vanish
    -- once the fill is fully opaque.)
    local bg = CreateFrame("Frame", nil, opt)
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetFrameLevel(opt:GetFrameLevel())
    bg:EnableMouse(false)

    -- Art: Wayne Reynolds / Blizzard warlock illustration (Textures\wreynolds.tga).
    -- Cover-fit (no stretch): crop the source to the panel's aspect ratio.
    local art = bg:CreateTexture(nil, "ARTWORK", nil, 0)
    art:SetAllPoints(bg)
    art:SetTexture("Interface\\AddOns\\MagePrep\\Textures\\wreynolds")
    art:SetVertexColor(1, 1, 1, 0.50)

    -- Light blue tint over the art so controls stay readable.
    local wash = bg:CreateTexture(nil, "ARTWORK", nil, 1)
    wash:SetAllPoints(bg)
    wash:SetTexture(WHITE8)
    wash:SetVertexColor(0.05, 0.10, 0.20, 0.35)

    opt.bgLayer = bg
    opt.bgArt = art
    opt.bgWash = wash

    -- Source TGA is 512x1024. Bias crop slightly upward so the face stays in frame.
    local SRC_W, SRC_H = 512, 1024
    local function FitOptionsArt()
        local pw = opt:GetWidth() - 2
        local ph = opt:GetHeight() - 2
        if not pw or not ph or pw <= 0 or ph <= 0 then return end
        -- Keep the bg layer under header/controls.
        bg:SetFrameLevel(math.max(1, opt:GetFrameLevel()))
        local panelAspect = pw / ph
        local imgAspect = SRC_W / SRC_H
        local u0, u1, v0, v1
        if panelAspect > imgAspect then
            -- Panel wider than image: use full width, crop top/bottom.
            local visH = SRC_W / panelAspect
            local slack = (SRC_H - visH) / SRC_H
            -- Keep more of the top (face / pauldrons) than the feet.
            v0 = slack * 0.18
            v1 = v0 + (visH / SRC_H)
            if v1 > 1 then v1 = 1; v0 = 1 - (visH / SRC_H) end
            u0, u1 = 0, 1
        else
            -- Panel taller than image: use full height, crop sides.
            local visW = SRC_H * panelAspect
            local side = (1 - (visW / SRC_W)) * 0.5
            u0, u1 = side, 1 - side
            v0, v1 = 0, 1
        end
        art:SetTexCoord(u0, u1, v0, v1)
    end
    opt.FitOptionsArt = FitOptionsArt
end
opt:SetMovable(true); opt:EnableMouse(true); opt:RegisterForDrag("LeftButton")
opt:SetScript("OnDragStart", opt.StartMoving)
opt:SetScript("OnDragStop", opt.StopMovingOrSizing)
opt:SetFrameStrata("DIALOG")
opt:Hide()

do
    local bar = MP_Header(opt)
    local otitle = MP_FS(bar, 13)
    otitle:SetPoint("LEFT", 12, 0)
    otitle:SetText("MagePrep |cff6a8eb8- Options|r")
    otitle:SetTextColor(0.78, 0.88, 0.98)
end
MP_Close(opt, function() opt:Hide() end)

local oy = -40   -- running layout cursor from the panel top

local function SectionHeader(text)
    local fs = MP_FS(opt, 9)
    fs:SetPoint("TOPLEFT", 14, oy)
    fs:SetText(text)
    fs:SetTextColor(0.48, 0.60, 0.76)
    local div = MP_Tex(opt, "BORDER")
    div:SetPoint("TOPLEFT", 14, oy - 12)
    div:SetPoint("RIGHT", opt, "RIGHT", -14, 0)
    div:SetHeight(1)
    div:SetVertexColor(0.40, 0.52, 0.68, 0.14)
    oy = oy - 19
end

-- custom checkbox row: box + label + right-aligned note, hover wash
local function MakeCheck(label, note, get, set)
    local row = CreateFrame("Button", nil, opt)
    row:SetPoint("TOPLEFT", 12, oy)
    row:SetPoint("RIGHT", opt, "RIGHT", -12, 0)
    row:SetHeight(19)
    local hl = MP_Tex(row)
    hl:SetAllPoints(); hl:SetVertexColor(0.32, 0.58, 0.95, 0.08); hl:Hide()
    local box = CreateFrame("Frame", nil, row, "BackdropTemplate")
    box:SetSize(13, 13); box:SetPoint("LEFT", 3, 0)
    box:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
    local mark = MP_FS(box, 9)
    mark:SetPoint("CENTER", 0.5, 0); mark:SetText("v")
    local lbl = MP_FS(row, 12)
    lbl:SetPoint("LEFT", box, "RIGHT", 8, 0); lbl:SetText(label)
    if note and note ~= "" then
        local nfs = MP_FS(row, 10)
        nfs:SetPoint("RIGHT", -4, 0); nfs:SetText(note)
        nfs:SetTextColor(0.36, 0.46, 0.58)
    end
    function row:Refresh()
        if get() then
            box:SetBackdropColor(0.34, 0.60, 0.96, 1)
            box:SetBackdropBorderColor(0.45, 0.70, 0.98, 1)
            mark:SetTextColor(0.05, 0.04, 0.08); mark:Show()
            lbl:SetTextColor(0.88, 0.93, 1.00)
        else
            box:SetBackdropColor(0, 0, 0, 0.35)
            box:SetBackdropBorderColor(0.22, 0.32, 0.45, 1)
            mark:Hide()
            lbl:SetTextColor(0.42, 0.54, 0.68)
        end
    end
    row:SetScript("OnEnter", function() hl:Show() end)
    row:SetScript("OnLeave", function() hl:Hide() end)
    row:SetScript("OnClick", function() set(not get()); row:Refresh() end)
    row:Refresh()
    allChecks[#allChecks + 1] = row
    oy = oy - 20
    return row
end

-- preset segmented control
do
    local lbl = MP_FS(opt, 9)
    lbl:SetPoint("TOPLEFT", 14, oy)
    lbl:SetText("PRESET")
    lbl:SetTextColor(0.48, 0.60, 0.76)
end
oy = oy - 14
local segTrack = CreateFrame("Frame", nil, opt, "BackdropTemplate")
segTrack:SetPoint("TOPLEFT", 14, oy)
segTrack:SetPoint("RIGHT", opt, "RIGHT", -14, 0)
segTrack:SetHeight(22)
segTrack:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
segTrack:SetBackdropColor(0, 0, 0, 0.4)
segTrack:SetBackdropBorderColor(0.22, 0.32, 0.45, 1)
local segButtons = {}
for i, key in ipairs(PRESET_ORDER) do
    local b = CreateFrame("Button", nil, segTrack)
    b:SetSize(76, 18)
    b:SetPoint("LEFT", 2 + (i - 1) * 77, 0)
    b.bg = MP_Tex(b)
    b.bg:SetAllPoints(); b.bg:SetVertexColor(0.22, 0.45, 0.82, 1); b.bg:Hide()
    b.txt = MP_FS(b, 11)
    b.txt:SetPoint("CENTER", 0, 0); b.txt:SetText(PRESETS[key].label)
    b:SetScript("OnClick", function() ApplyPreset(key) end)
    b:SetScript("OnEnter", function()
        if ((MagePrepDB and MagePrepDB.preset) or "custom") ~= key then
            b.txt:SetTextColor(0.78, 0.88, 0.98)
        end
    end)
    b:SetScript("OnLeave", function() UpdatePresetSeg() end)
    segButtons[key] = b
end
UpdatePresetSeg = function()
    local cur = (MagePrepDB and MagePrepDB.preset) or "custom"
    for key, b in pairs(segButtons) do
        if key == cur then
            b.bg:Show(); b.txt:SetTextColor(0.92, 0.96, 1.00)
        else
            b.bg:Hide(); b.txt:SetTextColor(0.42, 0.54, 0.68)
        end
    end
end
oy = oy - 32

-- step-group checkboxes, grouped into sections (labels come from GROUPS; a
-- trailing "(...)" qualifier becomes the right-aligned note)
local GROUP_SECTIONS = {
    { title = "STONES", keys = { "hsmajor", "hsmaster", "ritual", "spellstone" } },
    { title = "BUFFS",  keys = { "imp", "felarmor", "fireshield", "unending", "detectinvis" } },
    { title = "FINISH", keys = { "voidwalker", "felhunter", "sacrifice", "soullink", "shadowward", "taintedblood", "mount" } },
}
local GROUP_LABEL, GROUP_NOTE = {}, {}
for _, g in ipairs(GROUPS) do
    local base, tag = g.label:match("^(.-)%s*%((.-)%)$")
    GROUP_LABEL[g.key] = base or g.label
    GROUP_NOTE[g.key] = tag
end
-- catch-all: any GROUPS key not in a section lands in FINISH so a new step
-- group can never silently lose its checkbox
do
    local placed = {}
    for _, sec in ipairs(GROUP_SECTIONS) do
        for _, k in ipairs(sec.keys) do placed[k] = true end
    end
    for _, g in ipairs(GROUPS) do
        if not placed[g.key] then
            table.insert(GROUP_SECTIONS[#GROUP_SECTIONS].keys, g.key)
        end
    end
end
for _, sec in ipairs(GROUP_SECTIONS) do
    SectionHeader(sec.title)
    for _, key in ipairs(sec.keys) do
        local k = key
        groupChecks[k] = MakeCheck(GROUP_LABEL[k] or k, GROUP_NOTE[k],
            function() return Enabled(k) end,
            function(v)
                MagePrepDB = MagePrepDB or {}
                MagePrepDB.disabled = MagePrepDB.disabled or {}
                MagePrepDB.disabled[k] = (not v) or nil
                -- Hand-edit flips to Custom; carry the unlock time you were using
                -- into Custom's per-preset slot so the slider doesn't jump.
                local secsNow = EndPrepSecs()
                MagePrepDB.preset = "custom"
                SetEndPrepSecs(secsNow)
                SnapshotCustom()              -- keep Custom's remembered set in sync
                UpdatePresetSeg()
                if SyncEndPrepSlider then SyncEndPrepSlider() end
                BuildSteps(); Refresh()
            end)
    end
    oy = oy - 8
end

-- extras
SectionHeader("EXTRAS")
MakeCheck("Auto-fill healthstones on trade", "arena",
    function() return AutoTradeOn() end,
    function(v)
        MagePrepDB = MagePrepDB or {}
        MagePrepDB.autoTrade = v and true or false
    end)
MakeCheck("Auto-show window in arena", nil,
    function() return AutoShowOn() end,
    function(v)
        MagePrepDB = MagePrepDB or {}
        MagePrepDB.autoShow = v and true or false
    end)
MakeCheck("Debug logging", "traces to chat",
    function() return debugOn end,
    function(v)
        debugOn = v and true or false
        MagePrepDB = MagePrepDB or {}
        MagePrepDB.debug = debugOn
        if debugOn then MagePrepDB.log = {} end   -- fresh capture each time it's turned on
        print("|cff66b3ffMagePrep|r: debug tracing |cffffffff" .. (debugOn and "ON" or "OFF") .. "|r"
              .. (debugOn and " - do the ritual test, then |cffffffff/reload|r to save the log to disk." or ""))
    end)
oy = oy - 10

-- Felhunter unlock slider: per-preset (each of 2s / 3s5s / BGs / Custom stores
-- its own value). Default 12s; 0 = no gate.
local function EndPrepSliderLabel(v)
    if v <= 0 then return "Felhunter unlock: anytime (no gate)" end
    return "Felhunter unlock: " .. v .. "s left on the countdown"
end
local epslider = CreateFrame("Slider", "MagePrepEndPrepSlider", opt, "OptionsSliderTemplate")
epslider:SetPoint("TOPLEFT", 20, oy - 16)
epslider:SetWidth(296)
epslider:SetMinMaxValues(END_PREP_MIN, END_PREP_MAX)
epslider:SetValueStep(1)
epslider:SetObeyStepOnDrag(true)
if _G["MagePrepEndPrepSliderLow"] then _G["MagePrepEndPrepSliderLow"]:SetText("0") end
if _G["MagePrepEndPrepSliderHigh"] then _G["MagePrepEndPrepSliderHigh"]:SetText("30") end
SyncEndPrepSlider = function()
    if not epslider then return end
    local v = EndPrepSecs()
    epslider.setting = true
    epslider:SetValue(v)
    epslider.setting = false
    if _G["MagePrepEndPrepSliderText"] then
        _G["MagePrepEndPrepSliderText"]:SetText(EndPrepSliderLabel(v))
    end
end
epslider:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value + 0.5)
    if _G["MagePrepEndPrepSliderText"] then
        _G["MagePrepEndPrepSliderText"]:SetText(EndPrepSliderLabel(value))
    end
    -- self.setting guards programmatic SetValue (preset switch / OnShow).
    if self.setting then return end
    SetEndPrepSecs(value)
    Refresh()
end)
epslider:SetScript("OnShow", function() SyncEndPrepSlider() end)
oy = oy - 60

-- mount selector: pick from your learned mounts (or /mp mount <name>)
do
    local lbl = MP_FS(opt, 9)
    lbl:SetPoint("TOPLEFT", 14, oy)
    lbl:SetText("GATE MOUNT")
    lbl:SetTextColor(0.48, 0.60, 0.76)
end
local mdd = CreateFrame("Frame", "MagePrepMountDropDown", opt, "UIDropDownMenuTemplate")
mdd:SetPoint("TOPLEFT", -2, oy - 12)
UIDropDownMenu_SetWidth(mdd, 280)

local function SetMount(name)
    MagePrepDB = MagePrepDB or {}
    -- store exactly what was picked; auto-detect only applies when nothing is
    -- saved (use /mp mount reset to clear back to auto)
    MagePrepDB.mount = name
    UIDropDownMenu_SetText(mdd, MountName())
    BuildSteps(); Refresh()
end

-- Flying mounts can't be summoned in the arena, and bag items don't flag ground
-- vs flying. But TBC's mount naming is consistent: every flying mount is a
-- gryphon, wind rider, nether drake, nether ray, hippogryph, flying machine, or
-- Ashes of Al'ar - and no ground mount uses any of those words. So we exclude on
-- keywords (this also covers the arena Nether Drakes a PvP player will own).
-- If someone really wants a flying mount here, /mp mount <name> still sets it.
local FLYING_MOUNT_KEYWORDS = {
    "gryphon", "wind rider", "nether drake", "netherwing",
    "nether ray", "hippogryph", "flying machine", "al'ar",
}
local function IsFlyingMountName(name)
    local lc = name:lower()
    for _, kw in ipairs(FLYING_MOUNT_KEYWORDS) do
        if lc:find(kw, 1, true) then return true end
    end
    return false
end

-- collect owned mounts. In TBC (2.5.x) mounts are ITEMS in your bags, not
-- entries in the WotLK+ companion journal, so scan the bags. We also fold in
-- any learned companions in case this ever runs on a later client.
-- Flying mounts are filtered out (see IsFlyingMountName) since they can't be
-- used in the arena.
OwnedMounts = function()
    local names, seen = {}, {}
    local function addName(nm)
        if nm and nm ~= "" and not seen[nm] and not IsFlyingMountName(nm) then
            seen[nm] = true; names[#names + 1] = nm
        end
    end
    -- learned mounts (usually empty in TBC)
    local n = (GetNumCompanions and GetNumCompanions("MOUNT")) or 0
    for i = 1, n do
        local _, cname = GetCompanionInfo("MOUNT", i)
        addName(cname)
    end
    -- mount items in bags (classID 15 = Miscellaneous, subclassID 5 = Mount)
    for bag = 0, 4 do
        local slots = (GetNumSlots and GetNumSlots(bag)) or 0
        for slot = 1, slots do
            local link = GetItemLink and GetItemLink(bag, slot)
            if link then
                local isMount = false
                if GetItemInfoInstant then
                    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(link)
                    isMount = (classID == 15 and subclassID == 5)
                end
                if not isMount then
                    local _, _, _, _, _, _, subclass = GetItemInfo(link)
                    isMount = (subclass == "Mount")
                end
                if isMount then
                    addName((GetItemInfo(link)) or link:match("%[(.-)%]"))
                end
            end
        end
    end
    -- warlock class mounts (spells, not bag items) if the player knows them
    for _, id in ipairs(WARLOCK_MOUNT_IDS) do
        if not IsSpellKnown or IsSpellKnown(id) then
            addName(GetSpellInfo(id))
        end
    end
    table.sort(names)
    return names
end

UIDropDownMenu_Initialize(mdd, function(self, level)
    local names = OwnedMounts()
    local current = MountName()   -- resolve once (may scan bags) instead of per entry
    for _, cname in ipairs(names) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = cname
        info.checked = (current == cname)
        info.func = function() SetMount(cname) end
        UIDropDownMenu_AddButton(info, level)
    end
    if #names == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "no mounts found - use /mp mount <name>"
        info.disabled = true; info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
    end
end)
mdd:SetScript("OnShow", function() UIDropDownMenu_SetText(mdd, MountName()) end)
oy = oy - 54

-- keybind: label, hint, then a listening button
do
    local lbl = MP_FS(opt, 9)
    lbl:SetPoint("TOPLEFT", 14, oy)
    lbl:SetText("KEYBIND")
    lbl:SetTextColor(0.48, 0.60, 0.76)
    local h = MP_FS(opt, 10)
    h:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    h:SetText("click the button, then press the key you want")
    h:SetTextColor(0.36, 0.46, 0.58)
end

local keyRows = {}

local IGNORE_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, UNKNOWN = true,
}
local function KeyChord(key)
    if not key or IGNORE_KEYS[key] then return nil end
    local m = ""
    if IsAltKeyDown()     then m = m .. "ALT-"   end
    if IsControlKeyDown() then m = m .. "CTRL-"  end
    if IsShiftKeyDown()   then m = m .. "SHIFT-" end
    return m .. key
end

local function RefreshKeyButtons()
    for _, row in ipairs(keyRows) do
        if not row.listening then
            local k = GetBindingKey(row.action)
            row.btn:SetText(k or "|cff888888Not bound|r")
        end
    end
end

local function StopListening(row)
    row.listening = false
    row.btn:EnableKeyboard(false)
    row.btn:EnableMouseWheel(false)
    row.btn:SetPropagateKeyboardInput(true)
    row.btn:SetButtonState("NORMAL")   -- release the stuck "pressed" look
    row.btn:UnlockHighlight()
    row.btn:SetScript("OnKeyDown", nil)
    row.btn:SetScript("OnMouseWheel", nil)
    row.btn:SetScript("OnMouseUp", nil)
    RefreshKeyButtons()
end

local function ApplyKey(row, keyStr)
    if not keyStr then return end
    local old1, old2 = GetBindingKey(row.action)   -- clear this action's old key(s)
    if old1 then SetBinding(old1) end
    if old2 then SetBinding(old2) end
    SetBindingClick(keyStr, row.button)
    SaveBindings(GetCurrentBindingSet())
    StopListening(row)
    print("|cff66b3ffMagePrep|r: bound |cffffffff" .. keyStr .. "|r to " .. row.label)
end

local function StartListening(row)
    for _, r in ipairs(keyRows) do
        if r ~= row and r.listening then StopListening(r) end
    end
    row.listening = true
    row.btn:SetText("|cffffff00Press a key...|r")
    row.btn:EnableKeyboard(true)
    row.btn:EnableMouseWheel(true)
    row.btn:SetScript("OnKeyDown", function(self, key)
        self:SetPropagateKeyboardInput(false)
        if key == "ESCAPE" then StopListening(row); return end
        local chord = KeyChord(key)
        if chord then ApplyKey(row, chord) end
    end)
    row.btn:SetScript("OnMouseWheel", function(_, delta)
        ApplyKey(row, (delta > 0) and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
    end)
    row.btn:SetScript("OnMouseUp", function(_, mbtn)
        if mbtn == "LeftButton" then return end   -- left starts listening
        local map = { RightButton = "BUTTON2", MiddleButton = "BUTTON3",
                      Button4 = "BUTTON4", Button5 = "BUTTON5" }
        local b = map[mbtn]
        if b then ApplyKey(row, KeyChord(b)) end
    end)
end

local function MakeKeyRow(labelText, buttonName, yoff)
    local btn = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate")
    btn:SetSize(200, 24)
    btn:SetPoint("TOPLEFT", 16, yoff)
    local nt = btn:GetNormalTexture()
    if nt then nt:SetVertexColor(0.40, 0.65, 0.95) end   -- mage-blue tint, keeps the button border/texture
    local row = {
        label  = labelText,
        button = buttonName,
        action = "CLICK " .. buttonName .. ":LeftButton",
        btn    = btn,
    }
    btn:SetScript("OnClick", function()
        if row.listening then StopListening(row) else StartListening(row) end
    end)
    keyRows[#keyRows + 1] = row
    return row
end

MakeKeyRow("the next-step button", "MagePrepButton", oy - 16)
oy = oy - 44

opt:SetHeight(-oy + 12)
if opt.FitOptionsArt then opt.FitOptionsArt() end
opt:HookScript("OnShow", function()
    if opt.FitOptionsArt then opt.FitOptionsArt() end
    RefreshKeyButtons()
    UpdatePresetSeg()
    for _, r in ipairs(allChecks) do r:Refresh() end
end)

local function ToggleOptions()
    if opt:IsShown() then opt:Hide() else opt:Show() end
end

-- right-click the checklist to open options
ui:SetScript("OnMouseUp", function(_, mb) if mb == "RightButton" then ToggleOptions() end end)

-- =====================================================================
-- Minimap button (LibDBIcon) - the round, bordered icon on the minimap
-- =====================================================================
local ToggleWindow  -- fwd (defined with the window show/hide flags below)
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
local ldbObj
if LDB then
    ldbObj = LDB:NewDataObject("MagePrep", {
        type = "launcher",
        text = "MagePrep",
        icon = "Interface\\Icons\\Spell_Holy_MagicalSentry", -- Mage Armor
        OnClick = function(_, mb)
            if mb == "RightButton" then
                ToggleWindow()
            else
                ToggleOptions()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("MagePrep")
            tt:AddLine("|cffffffffLeft-click|r  options / presets", 1, 1, 1)
            tt:AddLine("|cffffffffRight-click|r  toggle the checklist", 1, 1, 1)
        end,
    })
end

-- Right-click the icon (and /mp show|hide|test) toggles the checklist window;
-- respects the manual show/hide flags so it behaves the same as /mp show|hide.
ToggleWindow = function()
    if ui:IsShown() then
        ui.userHidden = true; ui.preview = false; HideUI()
    else
        ui.userHidden = false; ui.preview = true; ShowUI()
    end
end

-- =====================================================================
-- Events
-- =====================================================================
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("UNIT_PET")
ev:RegisterEvent("UNIT_AURA")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL")
ev:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE")
ev:RegisterEvent("START_TIMER")   -- reliable arena begin timer (Blizzard TimerTracker)
ev:RegisterEvent("TRADE_SHOW")
ev:RegisterEvent("TRADE_CLOSED")
ev:RegisterEvent("TRADE_ACCEPT_UPDATE")
-- Either side changing the trade contents un-accepts BOTH sides (and starts the
-- anti-scam accept lockout). WoW signals that via these item-change events, not
-- reliably via TRADE_ACCEPT_UPDATE, so we listen here to keep our accept mirror
-- honest -- otherwise iAccepted sticks true and PreClick refuses to re-accept.
ev:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
ev:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
-- Player-only cast start/stop so the button blanks the instant a summon/conjure
-- begins (kills the spell-queue duplicate) and re-offers if the cast is cut.
ev:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
-- Channels (Ritual of Souls) don't fire the *_START cast events, so register the
-- channel equivalents too. They fall through to the default Refresh() branch,
-- which blanks the button the instant the channel begins -- the same mid-cast
-- mash protection the timed casts already get.
ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
ev:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player")

-- Live updater: while Summon Felhunter is casting, refresh ~10x/sec so the
-- progress % and the swap-to-sacrifice button stay current, plus one final
-- refresh when the cast ends to return to the normal flow.
local felTicker = CreateFrame("Frame")
felTicker.t = 0
felTicker:SetScript("OnUpdate", function(self, dt)
    self.t = self.t + dt
    if self.t < 0.1 then return end
    self.t = 0
    local casting = FelSummonProgress() ~= nil
    if casting or self.was then
        self.was = casting
        Refresh()
    end
end)

local function OnCountdownMessage(msg)
    if not msg then return end
    msg = msg:lower()
    if msg:find("one minute") then gateAt = GetTime() + 60
    elseif msg:find("thirty second") then gateAt = GetTime() + 30
    elseif msg:find("fifteen second") then gateAt = GetTime() + 15
    elseif msg:find("has begun") or msg:find("gates are open") then gateAt = GetTime() end
end

-- Decide whether a just-ended Ritual of Souls channel actually created the Soulwell.
-- There's no combat-log event for the well and the channel ends early on success,
-- so we key off the spell's cooldown: a successful ritual triggers its real ~5min
-- cooldown; a cancel/interrupt does not. We only count a cooldown that STARTED
-- during this channel (start >= channelStart - 1s) so a leftover cooldown from an
-- earlier success can't mark a later cancel as done. GCD is excluded via dur > 10.
local function CheckRitualCompletion(channelStart)
    if ritualDone or not channelStart then return end
    local start, dur = GetSpellCooldown(29893)
    if start and start > 0 and dur and dur > 10 and start >= (channelStart - 1) then
        ritualDone = true
        DPrint("ritualDone <- cooldown", "cd=" .. tostring(start) .. "/" .. tostring(dur))
        Refresh()
    end
end

ev:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
    if event == "PLAYER_LOGIN" then
        MagePrepDB = MagePrepDB or {}
        debugOn = MagePrepDB.debug or false
        -- Re-resolve the spell names the mid-cast blanks/latches key on, now that
        -- the client's spell cache is warm. At file-load these can come back nil
        -- (cold cache) and fall back to English strings, which would silently break
        -- the guards on a non-enUS client. We only overwrite when a real name
        -- resolves, so this never nils anything and is a no-op where load-time
        -- values were already correct. BuildSteps re-runs per match, so step
        -- castNames pick these up before any arena.
        CREATE_HS_NAME = GetSpellInfo(6201)  or CREATE_HS_NAME
        SUMMON_NAME[1] = GetSpellInfo(688)   or SUMMON_NAME[1]
        SUMMON_NAME[2] = GetSpellInfo(697)   or SUMMON_NAME[2]
        SUMMON_NAME[3] = GetSpellInfo(691)   or SUMMON_NAME[3]
        RITUAL_NAME    = GetSpellInfo(29893) or RITUAL_NAME
        FEL_NAME       = GetSpellInfo(691)   or FEL_NAME
        if not MagePrepDB.disabled then
            MagePrepDB.disabled = { hsmajor = true, spellstone = true, ritual = true } -- 2s preset
            MagePrepDB.preset = "2s"
        end
        ApplyPos()
        ui.locked = MagePrepDB.locked or false
        UpdateSpellstoneButton()
        if DBIcon and ldbObj then
            MagePrepDB.minimap = MagePrepDB.minimap or {}
            if not DBIcon:IsRegistered("MagePrep") then
                DBIcon:Register("MagePrep", ldbObj, MagePrepDB.minimap)
            end
        end
        if not GetBindingKey("CLICK MagePrepButton:LeftButton") then
            print("|cff66b3ffMagePrep|r loaded. Quick start:")
            print("  1) Left-click the |cffffffffminimap icon|r for options/presets, then set your keys in the |cffffffffKeybinds|r section")
            print("     (or use |cffffffff/mp bind SHIFT-E|r for the next-step key)")
            print("  2) |cffffffff/mp wand <your wand name>|r for the spellstone dispel/swap")
            print("  3) Right-click the minimap icon (or |cffffffff/mp test|r) to peek at the checklist")
            print("  In the arena: just mash your bound key - it does each step in order.")
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if InPrepZone() then
            gateAt = nil
            wipe(tradedNames)     -- fresh trade tracking each match
            wipe(tradedGUIDs)
            tradeGUID = nil
            petSummonedMax = 0    -- fresh creation-delay latches each match
            wipe(hsPending)
            ritualDone = false
            ritualChannelStart = nil
            ui.fading = false
            BuildSteps()          -- fresh steps for this match
            if AutoShowOn() then
                ui.userHidden = false -- auto-show fresh each match
                ShowUI()
            else
                Refresh()         -- keep the button macro correct even if hidden
            end
        else
            if ui.preview then ShowUI() else HideUI() end
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_STOP" then
        if arg1 == "player" then
            local nm = arg3 and GetSpellInfo(arg3) or (UnitChannelInfo("player")) or "?"
            if event == "UNIT_SPELLCAST_CHANNEL_START" and nm == RITUAL_NAME then
                ritualChannelStart = GetTime()
                DPrint("RITUAL channel start")
            elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" and ritualChannelStart then
                -- Completion signal: Ritual of Souls has NO combat-log event for the
                -- Soulwell and the channel ends EARLY when teammates click (nominal
                -- 60s, real success ~6s), so neither a create event nor the channel
                -- duration works. What IS reliable: a successful ritual puts the spell
                -- on its real ~5min cooldown; a cancel/interrupt leaves no cooldown.
                -- So if Ritual is on a long cooldown that STARTED during this channel,
                -- the well spawned. (Confirmed via /mp debug: cd=.../300 on success.)
                CheckRitualCompletion(ritualChannelStart)
                -- Re-check shortly after in case the cooldown registers a beat late.
                local started = ritualChannelStart
                C_Timer.After(0.5, function() CheckRitualCompletion(started) end)
                ritualChannelStart = nil
            elseif debugOn and nm == RITUAL_NAME then
                DPrint(event, "spell=" .. tostring(nm), "ritualDone=" .. tostring(ritualDone))
            end
        end
        Refresh()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" and arg3 then
            local name = GetSpellInfo(arg3)
            if debugOn and (name == RITUAL_NAME or name == SUMMON_NAME[1] or name == SUMMON_NAME[2]
                or name == SUMMON_NAME[3] or name == CREATE_HS_NAME) then
                DPrint("SUCCEEDED", "spell=" .. tostring(name))
            end
            -- NOTE: Ritual of Souls is a CHANNEL, so SUCCEEDED fires when the
            -- channel *starts*, not when it finishes. Latching ritualDone here
            -- meant a cancelled/interrupted ritual still counted as complete.
            -- Completion is decided on CHANNEL_STOP via the spell's cooldown
            -- (CheckRitualCompletion), so we do nothing for the ritual here.
            if name == SUMMON_NAME[1] then
                if petSummonedMax < 1 then petSummonedMax = 1 end
                Refresh()
            elseif name == SUMMON_NAME[2] then
                if petSummonedMax < 2 then petSummonedMax = 2 end
                Refresh()
            elseif name == SUMMON_NAME[3] then
                if petSummonedMax < 3 then petSummonedMax = 3 end
                Refresh()
            elseif name == CREATE_HS_NAME then
                -- ranks share one name; latch whichever tier we're on right now
                if currentId == "hs_master" then hsPending.hs_master = true
                elseif currentId == "hs_major" then hsPending.hs_major = true end
                Refresh()
            end
        end
    elseif event == "START_TIMER" then
        -- arg1 = timerType, arg2 = seconds left. Extra source for the gate when it
        -- fires: type 1 is the arena begin timer on the Classic client (what
        -- DBM-PvP keys on); retail's Enum.StartTimerType.PvPBeginTimer is 0, so
        -- accept either. Type 2 is the /countdown pull timer - ignore it. On the
        -- Anniversary client this often doesn't fire, which is fine: the chat
        -- countdown carries the gate on its own.
        local pvpBegin = Enum and Enum.StartTimerType and Enum.StartTimerType.PvPBeginTimer
        if arg2 and (arg1 == 1 or (pvpBegin and arg1 == pvpBegin)) then
            gateAt = GetTime() + arg2
            Refresh()
        end
    elseif event == "CHAT_MSG_BG_SYSTEM_NEUTRAL" or event == "CHAT_MSG_RAID_BOSS_EMOTE" then
        OnCountdownMessage(arg1)
    elseif event == "TRADE_ACCEPT_UPDATE" then
        -- arg1 = our side accepted (0/1), arg2 = the partner's side. Keep iAccepted
        -- in sync so PreClick only calls AcceptTrade() once (a second call toggles
        -- it back off).
        iAccepted = (arg1 == 1)
        partnerAccepted = (arg2 == 1)
        -- When BOTH sides are green the trade is about to go through. Snapshot how
        -- many healthstones are in OUR side right now: if it's >0, this completion
        -- credits the partner regardless of bag-count timing (a conjure landing
        -- mid-trade or a bag-update lag can otherwise hide the count delta and make
        -- us re-trade someone who already got a stone).
        if iAccepted and partnerAccepted then
            local s = StonesInTrade()
            if s > tradeCommitStones then tradeCommitStones = s end
        end
        Refresh()   -- un-blank prep once accepted / re-blank if our accept reset
    elseif event == "TRADE_PLAYER_ITEM_CHANGED" or event == "TRADE_TARGET_ITEM_CHANGED" then
        -- Contents changed on either side -> WoW un-accepted both sides. Clear our
        -- mirror so PreClick will accept again once the anti-scam lockout clears,
        -- and drop the both-accepted stone snapshot so it re-captures at the real
        -- completion (a fresh accept is required now). Re-blank the prep cast via
        -- Refresh since we're back to "needs accept".
        iAccepted = false
        partnerAccepted = false
        tradeCommitStones = 0
        Refresh()
    elseif event == "TRADE_SHOW" then
        iAccepted = false
        partnerAccepted = false
        tradeCommitStones = 0
        tradeHadStones = false
        tradeStartHS = HSCount()
        tradeGUID = UnitGUID("npc")   -- the unit we're trading with (either direction)
        tradePartner = (TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText())
        if not tradePartner or tradePartner == "" then tradePartner = UnitName("npc") end
        if not tradePartner or tradePartner == "" then tradePartner = "partner" end
        -- Only auto-fill our stones if THIS partner still needs one. Otherwise a
        -- teammate re-opening a trade to hand US something (a mage giving food)
        -- would get another stone dumped in - and possibly accepted away.
        local giveStone = AutoTradeOn() and InArena() and not UseRitual()
                          and HaveAnyStone() and not HasTraded("npc")
        if tradeArmed or giveStone then FillTrade() end
        Refresh()                     -- blank the prep cast while the window is up
    elseif event == "TRADE_CLOSED" then
        lastTradeClosed = GetTime()   -- start the re-open cooldown (see PreClick)
        iAccepted = false
        partnerAccepted = false
        local partner, guid, before = tradePartner, tradeGUID, tradeStartHS
        local committed = tradeCommitStones   -- our stones in-window when both accepted
        tradeHadStones = false; tradePartner = nil; tradeGUID = nil; tradeCommitStones = 0
        Refresh()                     -- restore the prep cast now the window is gone
        -- Credit the partner with their stone. Store the GUID (realm-proof) plus a
        -- realm-stripped name so HasTraded()'s UnitName fallback can't miss on a
        -- cross-realm skirmish partner.
        local function record()
            if guid then tradedGUIDs[guid] = true end
            if partner then tradedNames[(partner:match("^[^-]+")) or partner] = true end
            Refresh()
        end
        if committed > 0 then
            -- Both sides accepted with our healthstone(s) in the window: it went
            -- through. Deterministic, immune to conjure timing / bag-update lag.
            record()
        else
            -- Fallback for clients that don't report the partner's accept flag:
            -- infer from our stones leaving the bags. Poll twice for bag lag.
            C_Timer.After(0.4, function() if HSCount() < before then record() end end)
            C_Timer.After(1.2, function() if HSCount() < before then record() end end)
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- roster affects partner buff steps; rebuild to keep them current
        BuildSteps()
        Refresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        UpdateSpellstoneButton()
        Refresh()
    else
        Refresh()
    end
end)

-- Throttled re-evaluation (handles the time-gated steps, which have no event to
-- fire when "12s left" arrives - they must be polled). This MUST live on an
-- always-running frame, NOT on `ui`: OnUpdate only fires while its frame is
-- shown, and the window is hidden during matches. Tying it to `ui` meant that
-- once the finish was gated the button's macro was blanked and never re-armed
-- when the clock crossed the gate, so the finish stayed locked all match.
local tickerFrame = CreateFrame("Frame")
local acc = 0
tickerFrame:SetScript("OnUpdate", function(self, elapsed)
    if not MagePrepDB then return end   -- wait for PLAYER_LOGIN / saved vars
    acc = acc + elapsed
    if acc < 0.2 then return end
    acc = 0
    Refresh()
end)

-- =====================================================================
-- Slash
-- =====================================================================
SLASH_MAGEPREP1 = "/mageprep"
SLASH_MAGEPREP2 = "/mp"
SLASH_MAGEPREP3 = "/mprep"
SlashCmdList["MAGEPREP"] = function(msg)
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lc = raw:lower()
    local cmd, arg = lc:match("^(%S*)%s*(.-)$")
    local _, rawArg = raw:match("^(%S*)%s*(.-)$") -- preserves case (item names)
    if cmd == "unlock" then
        ui.locked = false; ui.preview = true; ui.userHidden = false
        MagePrepDB = MagePrepDB or {}; MagePrepDB.locked = nil
        ShowUI()
        print("|cff66b3ffMagePrep|r: movable - drag it anywhere, then /mp lock when happy")
    elseif cmd == "lock" then
        ui.locked = true
        local p, _, r, x, y = ui:GetPoint()
        MagePrepDB = MagePrepDB or {}; MagePrepDB.pos = { p, r, x, y }; MagePrepDB.locked = true
        print("|cff66b3ffMagePrep|r: locked & position saved")
    elseif cmd == "test" or cmd == "toggle" or cmd == "show" or cmd == "hide" then
        local wantShow
        if cmd == "show" then wantShow = true
        elseif cmd == "hide" then wantShow = false
        else wantShow = not ui:IsShown() end
        if wantShow then
            if InArena() then ui.userHidden = false else ui.preview = true end
            ShowUI(); print("|cff66b3ffMagePrep|r: shown")
        else
            if InArena() then ui.userHidden = true else ui.preview = false end
            HideUI(); print("|cff66b3ffMagePrep|r: hidden (/mp show to bring back)")
        end
    elseif cmd == "status" then
        local key = GetBindingKey("CLICK MagePrepButton:LeftButton") or "|cffff6666none|r"
        local sskey = GetBindingKey("CLICK MagePrepSpellstoneButton:LeftButton") or "|cffff6666none|r"
        local ackey = GetBindingKey("CLICK MagePrepAcceptButton:LeftButton") or "|cffff6666none|r"
        print("|cff66b3ffMagePrep|r status:")
        print("  next-step key: |cffffffff" .. key .. "|r   spellstone key: |cffffffff" .. sskey .. "|r   accept key: |cffffffff" .. ackey .. "|r")
        print("  next-step macro: |cffffffff" .. (button:GetAttribute("macrotext") or "(empty)") .. "|r")
        print("  wand: |cffffffff" .. (MagePrepDB and MagePrepDB.wand or "(not set)") .. "|r  in arena: " .. tostring(InArena()))
        local sz = GetNumGroupMembers() or 0
        local preset = (MagePrepDB and MagePrepDB.preset and PRESETS[MagePrepDB.preset] and PRESETS[MagePrepDB.preset].label) or "Custom"
        print("  group size: |cffffffff" .. sz .. "|r  preset: |cffffffff" .. preset .. "|r  ->  stones: |cffffffff" .. (UseRitual() and "Ritual of Souls" or "conjure pair") .. "|r")
    elseif cmd == "debug" then
        if arg == "clear" then
            MagePrepDB = MagePrepDB or {}; MagePrepDB.log = {}
            print("|cff66b3ffMagePrep|r: debug log cleared")
            return
        end
        debugOn = not debugOn
        MagePrepDB = MagePrepDB or {}
        MagePrepDB.debug = debugOn
        if debugOn then MagePrepDB.log = {} end   -- fresh capture each time it's turned on
        print("|cff66b3ffMagePrep|r: debug tracing |cffffffff" .. (debugOn and "ON" or "OFF") .. "|r"
              .. (debugOn and " - cast Ritual of Souls, cancel it, then complete it, then |cffffffff/reload|r to save the log to disk." or ""))
    elseif cmd == "bind" and arg ~= "" then
        local key = arg:upper()
        SetBindingClick(key, "MagePrepButton")
        SaveBindings(GetCurrentBindingSet())
        print("|cff66b3ffMagePrep|r: bound |cffffffff" .. key .. "|r to the next-step button")
    elseif cmd == "bindss" and arg ~= "" then
        local key = arg:upper()
        SetBindingClick(key, "MagePrepSpellstoneButton")
        SaveBindings(GetCurrentBindingSet())
        print("|cff66b3ffMagePrep|r: bound |cffffffff" .. key .. "|r to the spellstone dispel/swap button")
    elseif cmd == "bindaccept" and arg ~= "" then
        local key = arg:upper()
        SetBindingClick(key, "MagePrepAcceptButton")
        SaveBindings(GetCurrentBindingSet())
        print("|cff66b3ffMagePrep|r: bound |cffffffff" .. key .. "|r to accept a trade (only when stones are in)")
    elseif cmd == "unbind" and arg ~= "" then
        SetBinding(arg:upper())
        SaveBindings(GetCurrentBindingSet())
        print("|cff66b3ffMagePrep|r: unbound |cffffffff" .. arg:upper() .. "|r")
    elseif cmd == "wand" then
        MagePrepDB = MagePrepDB or {}
        if rawArg == "" then
            MagePrepDB.wand = nil
            UpdateSpellstoneButton()
            print("|cff66b3ffMagePrep|r: wand cleared (spellstone button will just dispel, no swap)")
        else
            MagePrepDB.wand = rawArg
            UpdateSpellstoneButton()
            print("|cff66b3ffMagePrep|r: wand set to |cffffffff" .. rawArg .. "|r")
        end
    elseif cmd == "mount" then
        MagePrepDB = MagePrepDB or {}
        if rawArg == "" then
            MagePrepDB.mount = nil
            BuildSteps(); Refresh()
            print("|cff66b3ffMagePrep|r: gate mount reset to default (|cffffffff" .. DEFAULT_MOUNT .. "|r)")
        else
            MagePrepDB.mount = rawArg
            BuildSteps(); Refresh()
            print("|cff66b3ffMagePrep|r: gate mount set to |cffffffff" .. rawArg .. "|r")
        end
    elseif cmd == "preset" then
        local key
        if arg == "2s" then key = "2s"
        elseif arg == "3s" or arg == "5s" or arg == "3s5s" or arg == "3s/5s" then key = "3s5s"
        elseif arg == "bg" or arg == "bgs" then key = "bg"
        elseif arg == "custom" then key = "custom"
        else print("|cff66b3ffMagePrep|r: usage /mp preset 2s|3s5s|bg|custom"); return end
        ApplyPreset(key)
        print("|cff66b3ffMagePrep|r: preset = |cffffffff" .. PRESETS[key].label .. "|r")
    elseif cmd == "minimap" or cmd == "icon" then
        MagePrepDB = MagePrepDB or {}
        MagePrepDB.minimap = MagePrepDB.minimap or {}
        MagePrepDB.minimap.hide = not MagePrepDB.minimap.hide
        if DBIcon then
            if MagePrepDB.minimap.hide then DBIcon:Hide("MagePrep") else DBIcon:Show("MagePrep") end
        end
        print("|cff66b3ffMagePrep|r: minimap icon " .. (MagePrepDB.minimap.hide and "hidden" or "shown"))
    elseif cmd == "options" or cmd == "config" or cmd == "opt" then
        ToggleOptions()
    elseif cmd == "trade" then
        tradeArmed = true
        print("|cff66b3ffMagePrep|r: armed - open a trade now and your healthstones drop in (once)")
    elseif cmd == "spellstone" or cmd == "ss" then
        print("|cff66b3ffMagePrep|r spellstone dispel/swap:")
        print("  Prep equips the stone (30s equip CD burns off before the gates).")
        print("  Then bind the swap button: |cffffffff/mp bindss <KEY>|r (or macro |cffffffff/click MagePrepSpellstoneButton|r)")
        print("  Set your wand name first: |cffffffff/mp wand <exact wand name>|r")
        print("  Press = dispel all harmful magic (off-GCD) + swap to wand. Press again later to re-arm the stone.")
    else
        print("|cff66b3ffMagePrep|r commands:")
        print("  /mp show | hide | test  - show/hide the checklist (or right-click the minimap icon)")
        print("  /mp minimap  - show/hide the minimap icon")
        print("  /mp options  - choose which steps to include (or left-click the icon)")
        print("  /mp trade  - arm one trade to auto-fill your healthstones (auto in arena)")
        print("  /mp unlock | lock  - move / pin the window")
        print("  /mp bind <KEY>  - bind the next-step button (e.g. /mp bind 0)")
        print("  /mp bindss <KEY>  - bind the spellstone dispel/swap button")
        print("  /mp bindaccept <KEY>  - bind a key to accept a trade (when stones are in)")
        print("  /mp wand <name>  - set your wand's exact name (for the spellstone swap)")
        print("  /mp mount <name>  - set the mount used for the gate sprint (or pick it in /mp options)")
        print("  /mp preset 2s|3s5s|bg|custom  - apply a preset (custom keeps your boxes)")
        print("  /mp spellstone  - how the spellstone dispel/swap button works")
        print("  /mp status  - show your keybinds + what the next press will cast")
    end
end
