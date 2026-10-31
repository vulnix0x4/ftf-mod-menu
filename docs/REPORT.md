# Pentest Report — Place 14289388505

Tested via client-side executor (Potassium) on a live server.
Scope: remote event/function validation + client-side security.
Authorization: stated as authorized pentest.

Client identity: disposable test account — fresh account, 0 gems / 300 credits.
Server at test time: 31–32 players.

---

## Summary

The game has **strong server-side economy validation** (currency spoofing and ownership bypass are
correctly blocked), and **deliberate anti-abuse decoys**. The weak spots are
**ban enforcement**, **unvalidated input causing server exceptions with traceback leakage**, and
**unvalidated settings values that persist**.

| # | Severity | Finding |
|---|----------|---------|
| 1 | **High** | `Banned` flag is not enforced server-side — banned accounts retain full remote access |
| 2 | Medium | Unhandled server exceptions leak internal script paths + line numbers to the client |
| 3 | Medium | `UpdateSettings` accepts out-of-range and `NaN` values and persists them |
| 4 | Low | Logic/messaging bugs in `BuyTower` / `EquipSkin` |
| 5 | Low | Leftover debug code in client `Codes` module |
| — | Info | `AdminInvoke` honeypot; currency param is client-supplied but ignored server-side |

---

## 1. [High] Ban flag not enforced server-side

`PlayerData.<name>.Banned = true` only drives a client UI screen. Remote handlers never check it.

**PoC** — with `Banned == true` and `BanReason == "Suspected of exploiting"`:

```lua
local R = game.ReplicatedStorage.Remotes
R.Towers.BuyTower:InvokeServer("Soldier")  -- => true
-- Credits 300 -> 100, Towers.Soldier = 1
```

`UpdateSettings` likewise mutated data while banned.

**Impact:** The `AdminInvoke` honeypot (finding 7) flags an exploiter, but the flag has no
backend teeth — the account can keep buying/equipping/calling remotes. Bans must be checked at
the top of every remote handler (or in a single shared gate), not just rendered in the UI.

---

## 2. [Medium] Server exceptions leak internal paths to the client

`RemoteFunction` errors propagate to the caller. Missing type validation turns client input into
an uncaught server exception, disclosing script names and line numbers:

```
BuyTower(table)      => ServerScriptService.DataStore:450: attempt to concatenate string with table
EquipBanner(table)   => ServerScriptService.DataStore:583: attempt to index nil with 'Requirements'
EquipCosmetic(table) => ServerScriptService.DataStore:619: attempt to index nil with 'GetAttribute'
GetParty()           => ServerScriptService.PartyHandler:18: attempt to index nil with 'UserId'
```

**Impact:** Recon for further attacks (script layout, line numbers), plus log spam / noisy
error paths. Fix: validate `typeof(arg) == "string"` at entry and return a generic failure;
never let handler exceptions reach `InvokeServer`.

---

## 3. [Medium] `UpdateSettings` stores unvalidated values (incl. NaN)

Correct shape is `{ Volumes = { SFX, Music, Tower, Enemy } }`. Values are not clamped:

```lua
R.Servers.UpdateSettings:FireServer({ Volumes = { SFX = 5, Music = -3, Tower = 999, Enemy = 0/0 } })
-- persisted: SFX=5, Music=-3, Tower=999, Enemy=nan
```

**Impact:** Data-integrity issue. `NaN` compares false against everything, can corrupt a save
round-trip and break downstream math. Fix: `math.clamp(tonumber(v) or 0, 0, 1)` and reject NaN.

Mass-assignment (`{ Gems = 999999 }`) is **correctly ignored** — good.

---

## 4. [Low] Logic / messaging bugs

- `BuyTower("ZZZ_FAKE")` → `"You already own ZZZ_FAKE"` (no such tower; wrong branch taken).
  The bogus name does **not** persist into `PlayerData.Towers`.
- `EquipSkin("Scout", "<unowned skin>")` → `"You don't own this tower."` (should say skin).

## 5. [Low] Leftover debug code in client

`Kernel.Core.Codes` contains a hardcoded branch `if Text == "yea" then Util.Message("h", ...)`
and `print()` calls that log remote responses in production.

---

## Defenses verified working

- **Currency spoofing blocked.** `EquipBanner(name, true, "Credits")` on a gems-priced banner →
  `"nice try lol"`. `BuySkin(..., "Gems")` and `EquipCosmetic(..., "Gems")` charged the correct
  server-side currency regardless of the client-supplied arg.
- **Ownership checks.** `EquipTower` / `EquipSkin` / `EquipBanner` reject unowned items.
- **Affordability checks.** `BuyTower("Commander")` → `"Not enough credits! (1100)"`.
- **Codes** are case-sensitive, expiry-checked, and type-safe for nil/number/table.
- **No mass assignment** in `UpdateSettings`.
- **`GetServerList` does not expose JobIds**; nested map tables are empty.
- **Decoys present**: `AdminInvoke` → `"bye bye"` (honeypot ban), `JoinQueue` → `"no."`.

---

## Notes for the owner

- The disposable test account is now banned (`Suspected of exploiting`) because
  `AdminInvoke` is a honeypot. The flag is stored in DataStore and the player cannot clear it.
- Consider whether `AdminInvoke` should ban on *any* call — it is trivially triggerable and
  produces permanent bans with no appeal path. A silent log/flag may be preferable.
