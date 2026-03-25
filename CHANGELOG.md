# Changelog

All notable changes to sts2-cli are documented here.

---

## Mar 24, 2026

### Added
- **Compact card lists in all selection views** — card reward, card_select (remove/transform/etc.) now use the same compact grouped format as the `deck` command: one card per line, type-grouped with colored headers, names aligned, full description joined to one line, keywords inline, upgrade preview inline; card reward shows rarity label for Uncommon/Rare
- **Compact deck view** — `deck` command now shows one card per line grouped by type (Attack/Skill/Power/Status/Curse) with colored section headers; names column-aligned, full description on one line, keywords inline as `[消耗]`, upgrade preview inline as `升: 伤害 3→4 虚弱 1→2`; non-damage/block upgrade stats now labeled (虚弱, 易伤, 毒, etc.)
- **`q` as universal leave shortcut** — `q` now works as an alias for `leave` in all contexts that accept it (shop, event); during combat, `q` re-displays the combat state after viewing `help`/`deck`/`map`/etc.
- **Meta-commands during combat no longer auto-redisplay combat** — after `help`, `deck`, `map`, `potions`, or `relics`, a `(q: 返回战斗)` hint is shown; type `q` or `leave` to explicitly return to the combat view
- **`map` during path selection shows numbered choices** — typing `map` while choosing a path now shows the full map with the numbered path options below it, identical to the initial display
- **Exhaust pile now tracked in combat** — exhaust count shown in combat header when non-zero; each exhausted card listed by name; C# now exposes `pcs.ExhaustPile` with count and card list; end-of-turn exhaust events logged to stderr

### Fixed
- **Neutralize (中和) no longer exhausted after play** — a Harmony patch that fully replaced `Neutralize.OnPlay` was causing the card to end up in the exhaust pile instead of the discard pile after play; the patch was originally added to prevent a NullRef crash when `cardPlay.Target` is null; narrowed it to a null-guard only (returns `true` to let the original `OnPlay` run when target is present)
- **`play_full_run.py` no longer crashes if `.dotnet-arm64` path is missing** — dotnet binary discovery now tries multiple paths (same fallback logic as `play.py`)
- **Unresolved localization keys now display cleanly** — power/card names that fall back to raw loc keys (e.g. `MANGLE_POWER.title`) are now cleaned to title-case display names (e.g. `Mangle Power`)

---

## Mar 24, 2026

### Changed
- **Shop layout reordered** — all items now follow `name — price (SALE label if on sale) — description` order; card descriptions are collapsed to a single line

### Fixed
- **Event option card-name vars now resolve correctly** — e.g. SLIPPERY_BRIDGE "跨越" showed `0将从你的牌组中被移除` instead of the actual card name; fixed by reflecting on the event object to find `CardModel` fields/properties matching the DynamicVar name (covers `RandomCard` and similarly named vars in other events)
- **Rest site no longer crashes when all options are disabled** — e.g. full HP (HEAL disabled) with no upgradable cards (SMITH disabled) now automatically leaves the room instead of raising `KeyError`
- **Shop `c1`/`c2`... syntax now works** — entering `c1` to buy a card no longer crashes with `ValueError`; bare numbers (e.g. `1`) still accepted as before
- **Map path numbering now consistent** — `show_map()` and the selection handler both use the same column-sorted order, preventing a mismatch where index `1` could point to a different path than shown
- **Multi-card selection rejects duplicate indices** — entering `1,1` now shows an error instead of counting the same card twice toward the required selection count
- **Hand card descriptions now shown for multi-hit and other single-stat cards** — cards like 痛殴 (Pummel) that only have a `damage` stat but carry meaningful description text (e.g. "3 times") now show their first description line inline; previously only cards with extra stat keys or no stats at all would show descriptions

---

## Mar 24, 2026

### Added
- **Player powers/debuffs now shown in combat** — buffs (Strength, Dexterity, Artifact, etc.) appear in green, debuffs (Weak, Vulnerable, Frail, Poison, etc.) appear in red, separated by `|`; line is hidden when no powers are active
- **Enemy powers are now color-coded** — enemy debuffs (Vulnerable, Weak on an enemy) appear in green (good for player), enemy buffs (Strength, Ritual) appear in red (threat to player); previously everything was dim gray
- **Effective card damage/block** — card stats now show real-time effective values via the engine's `UpdateDynamicVarPreview` API (same system used by the actual game on hover); when effective differs from base, the effective value is highlighted and base shown in parentheses (e.g. `8伤(6)` with Strength +2)
- **Per-enemy Vulnerable annotation** — for targeted attack cards, if Vulnerable varies between enemies the increased damage per vulnerable enemy is shown in yellow (e.g. `8伤 (12→[1])`)

### Changed
- Power JSON now includes `"id"` field (e.g. `"WeakPower"`, `"StrengthPower"`) alongside the localized name, enabling language-independent buff/debuff classification
- Card JSON now includes `"preview_stats"` (effective values after modifiers) and `"per_enemy_damage"` (per-enemy damage when Vulnerable varies) fields

---

## Mar 23, 2026

### Added
- **Character & ascension positional args** — `play.py d 4` launches Defect at Ascension 4; character abbreviations `i/s/d/r/n` accepted (case-insensitive)
- **Colored map nodes** — Elite (magenta), Rest (green), Shop (yellow), Treasure/Ancient (orange), Event (blue); available paths are underlined
- **Boss name on map** — current act boss is shown above the map separator line
- **Shop descriptions** — cards, relics, and potions in the shop now show their description inline
- **Multi-card selection** — card select prompts show the required count range (e.g. `2-2`) and accept comma- or space-separated indices; invalid counts are rejected with a clear message
- **`map` command from any state** — typing `map` outside of `map_select` now derives reachable nodes from current position and renders the full map
- **zsh alias docs** — README now includes an optional `sts2` shortcut alias for macOS

### Changed
- **All interactive indices are now 1-based** — cards, enemies, potions, relics, bundles, rest options, event options, and map paths all start at `1` (previously `0`)
- **Updated help text and README** to reflect 1-based indices (`p1`, `c1`, `r1`, etc.)
- **`setup.sh` now enforces .NET 9+ and adapts to the installed version** — detects the SDK major version at startup, rejects versions below 9 with a clear error, and compiles the IL patcher against the detected framework (`net9.0`, `net10.0`, etc.); GodotStubs resolver path is now discovered dynamically instead of being hardcoded to `net9.0`
- **Event option vars** — card-type variable names (Attack, Skill, Power, etc.) are now resolved to their localized display string instead of a raw integer
- Refactored meta-command handling into a shared `_handle_meta()` helper

### Fixed
- Rest site **SMITH** now waits for the upgrade action to complete before transitioning to the map
- Rest site **HEAL** now waits for the heal action before forcing navigation to the map
- Potion use now correctly passes the engine's internal index regardless of display order

---

## Mar 22, 2026

### Added
- **Game logging and replay** — simulator writes structured logs for bug reproduction

### Fixed
- Self-targeting cards no longer fail when `target_index` is provided (BUG-022)
- Three additional simulator bugs resolved (BUG-005, BUG-007, BUG-013)
- Compact bridge mode added for AI agent use cases
- `GodotSharp` assembly resolution error in `setup.sh` IL patching step
- File lock error during `setup.sh` DLL patching on macOS

### Chore
- Added `.gitignore` entries for learning files, bug tracker, and temporary play scripts
- Random port selection in `sts2-cli-agent` skill to avoid conflicts
