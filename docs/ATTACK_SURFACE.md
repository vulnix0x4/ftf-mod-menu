# Attack Surface Map — Flee the Facility

**Place:** `893973440` · **Game:** `372226183` · **Creator:** A.W. Apps
**Client:** Disposable test account (Potassium)
**Captured:** 2026-10-29, live server (5 players at capture)
**Method:** client-side, passive only. No remote was invoked and no state was written.

> Differs from `REPORT.md`, which covers Place `14289388505`. This is a different
> experience (verified with `MarketplaceService:GetProductInfo(game.PlaceId)`).
>
> Working log and current corrections: `LEARNINGS.md`.

---

## 1. Executor constraints (why this is passive)

| Capability | Result |
|---|---|
| `hookmetamethod`, `getrawmetatable`, `getgc`, `getreg`, `getrenv`, `getloadedmodules`, `getscriptclosure`, `identifyexecutor`, `request` | **not present** |
| `Script.Source` / `LocalScript.Source` for game scripts | **empty (0 bytes)** |
| `debug.info`, `debug.getupvalues`, `debug.getconstants`, `debug.getprotos` | **available** |
| `require()` on client ModuleScripts | **works** |

Consequence at capture time: `FireServer` / `InvokeServer` calls could not be intercepted.
Only server→client traffic and static instance structure were visible; string literals
could be recovered only from functions reachable through `require()`d modules.

> **Corrected later (see `LEARNINGS.md` §1 and §4).** `getrawmetatable`, `hookfunction`,
> `getscriptclosure`, `getconnections` and `getnamecallmethod` *are* present. Client→server
> `FireServer` traffic was captured, and the `Input` opcode vocabulary was mapped. Hooking
> `FireServer` is still not recommended - it breaks the computer skillcheck.

---

## 2. Remote inventory

### 2.1 Static remotes (11)

All are direct children of `ReplicatedStorage` unless noted. None carry attributes
or children.

| # | Remote | Class | Observed S→C payloads | Inferred purpose |
|---|---|---|---|---|
| 1 | `RemoteEvent` | RemoteEvent | `"AddIconGui"` + `BillboardGui`; `"RemoveIconGui"` + `BillboardGui`; `"PlayerListRemoved"` + `name`; `"ResetPlayerStatusBar"` + `{}` | Generic action bus (string opcode + payload). Confirmed server→client; **may be bidirectional** |
| 2 | `StatusEvent` | RemoteEvent | `{ Content = {...}, Type = "Edit" }` | Per-player status bar / UI state edits |
| 3 | `AnnouncementEvent` | RemoteEvent | `"<name> was captured"` + `Color3` | Broadcast announcements |
| 4 | `WarningEvent` | RemoteEvent | — (silent this session) | Warning / anti-cheat notice UI |
| 5 | `DetectedEvent` | RemoteEvent | — (silent) | Detection / telemetry channel — treat as monitored |
| 6 | `AnalyticsRemoteEvent` | RemoteEvent | — (silent) | Analytics; do not fuzz |
| 7 | `GameSoundEvent` | RemoteEvent | — (silent) | Sound playback broadcast |
| 8 | `SystemMessageEvent` | RemoteEvent | — (silent) | System chat / message box |
| 9 | `ChatRemoteEvent` | RemoteEvent | — (silent) | Chat ingress (likely client→server) |
| 10 | `CandyCurrencyEvent` | RemoteEvent | — (silent) | Halloween candy currency sync / claim |
| 11 | `Halloween2026ClientAssets.Halloween2026Event` | RemoteEvent | — (silent) | Halloween event actions / quests |

### 2.2 Dynamic remotes (2) — per-beast, per-round

| Remote | Path | Lifetime |
|---|---|---|
| `HammerEvent` | `Workspace.<BeastPlayer>.Hammer.HammerEvent` | Exists only while that player is the beast; destroyed on death/round end |
| `PowersEvent` | `Workspace.<BeastPlayer>.BeastPowers.PowersEvent` | Same |

Observed once on a beast player during an active round. They are **inside the
character model**, not in `ReplicatedStorage`, so a naive `ReplicatedStorage` scan
misses both of the main gameplay-ability endpoints.

### 2.3 Not found

No remotes exist in `ReplicatedFirst`, `PlayerGui`, `StarterGui`, `Lighting`,
`SoundService`, `Teams`, or `Players.LocalPlayer` (Backpack/PlayerScripts).
`Workspace` contained only the two beast remotes above.

---

## 3. Protocol observations

- `RemoteEvent` is the only multiplexed channel. Payloads are `(string action, value)`
  where `value` is a `BillboardGui`, a player name, or an empty table. Because a
  `RemoteEvent` is bidirectional, the **same instance may be the client→server gateway**
  for shop/inventory/UI actions — unconfirmed (no hooking available).
- `StatusEvent` sends a structured table (`Content`, `Type`) rather than a primitive,
  so the server expects a table-shaped response contract.
- `AnnouncementEvent` is broadcast to all clients with a color argument.
- `ChatRemoteEvent` is the only plausible chat ingress; `SystemMessageEvent` is its
  server-side counterpart.
- `DetectedEvent` / `WarningEvent` never fired during normal play. `StarterGui` ships
  `DetectedFrame` and `WarningFrame`, so invalid remote traffic may be surfaced (or
  silently flagged). Assume monitored.

---

## 4. Server-replicated state (useful as test oracles)

`ReplicatedStorage` exposes authoritative round state as `ValueBase` instances:

| Value | Type | Sample |
|---|---|---|
| `GameTimer` | IntValue | `793` |
| `IsGameActive` | BoolValue | `true` / `false` |
| `ComputersLeft` | IntValue | `3` |
| `PowerActive` | BoolValue | `true` |
| `CurrentPower` | StringValue | `"Seer"` |
| `CurrentMap` | ObjectValue | `Homestead` |
| `GameStatus` | StringValue | `COMPUTERS LEFT : 3` |

Clients can write these locally (cosmetic only), but reading them before/after a
probe is a cheap way to detect whether the **server** accepted an action.

---

## 5. Data exposed to the client

| Module | Shape |
|---|---|
| `ItemDatabaseTable` | 1,059 entries (`G0001`…), each a `Model` with icon/asset children |
| `ShopCrates` | 4 crates: `Series 1G`, `Series 1H`, `Series 2G`, `Series 2H` |
| `GamePassIds` | `VIP` |
| `ShopBundles` | empty at capture |
| `LevelingXpCurve`, `StatusBarModule`, `TimerModule`, `EventIconModule`, `DebounceModule`, `GameImages`, `SeasonalEventDatesModule` | data/helper modules |
| `Halloween2026ClientAssets.HalloweenClientModule` | constants `ActionText`, `CandyBucket`, `SetCandy`, `StoredCandy`, `UnstoredCandy` |

Full item catalogue + crate contents being client-side means item IDs are enumerable;
it does **not** imply the server trusts them (see prior report: server-side price and
ownership checks were correct on the other game — must be re-verified here).

### Feature surface (from `StarterGui`)

Menus: Main, Shop, Inventory, Crates, Buy Credits, Donation, Trade Post, Pro Servers,
VC Servers, Merch, Bundles.
In-game: ActionBox, ProgressBox, StatusBars, AnnouncementBox, Spectator, BeastPowerBar,
BeastPowerMenu, GameResults, Candy menu, Quest window.

---

## 6. Prioritised test plan

Ordered by expected impact / cost. Each item lists preconditions and the oracle to
watch. **One probe at a time**, and stop if `DetectedFrame`/`WarningFrame` appears.

| Pri | Target | Precondition | Probe | Oracle |
|---|---|---|---|---|
| **P1** | `HammerEvent` | You are the beast | Hit at max/over range; re-fire during swing; re-fire after cooldown expiry vs before | Survivor health, round state, `GameTimer` |
| **P1** | `PowersEvent` | You are the beast, `PowerActive = true` | Fire with each `CurrentPower`; fire with an invalid/foreign power id; double-fire | `PowerActive`, cooldown UI, whether the effect applies |
| **P2** | `RemoteEvent` | Any | Confirm direction: trigger a shop/inventory action and watch for echo; if it accepts `FireServer`, send a **single unknown opcode** and watch `Detected`/`Warning` | `WarningEvent`, `DetectedEvent`, DataStore/save state |
| **P2** | `CandyCurrencyEvent` + `Halloween2026Event` | Candy event active | Claim once, then replay the same payload; negative/zero/huge amounts; stored vs unstored mismatch | Candy counter, quest progress |
| **P3** | `ChatRemoteEvent` | Private server | Very long string, rich-text tags, newline/CR, rate burst | How it renders to other clients |
| **P3** | Shop path | Private server, low-value item | Buy with wrong currency arg, unowned item, negative price, item id not in catalogue | Credits/gems, inventory |
| **P4** | `AnalyticsRemoteEvent`, `DetectedEvent` | — | **Do not fuzz.** Observe only | — |
| **P4** | `WarningEvent`, `SystemMessageEvent` | — | Observe only; they are the response channels | — |

### Notes on each

- **P1 is the highest-value area**: gameplay remotes inside the character model are
  commonly under-validated (server trusts the tool's local cooldown or hit result).
  Check: server re-computes range/damage, ignores client-supplied hit targets, and
  enforces its own cooldown (not the client's).
- **P2**: if `RemoteEvent` is a single string-dispatch gateway, it is the whole
  economy's front door. Map the opcode vocabulary first (e.g. by triggering one
  purchase in a private server and diffing), then test one opcode's validation.
- **P3 candy**: `StoredCandy` vs `UnstoredCandy` in the client module suggests a
  two-phase claim. Replay/double-claim is the classic bug.
- **P4**: `DetectedEvent` appearing in `StarterGui` alongside `DetectedFrame` means
  the client is expected to *report* something to the server. That is a plausible
  honeypot/heuristic channel — treat any invalid-remote test as observable.

---

## 7. Generic server-side hardening (for the owner)

1. Single dispatch gate for `RemoteEvent`: per-opcode schema, type/enum checks,
   `math.clamp`, reject `NaN`, rate limit per player, reject unknown opcodes.
2. Never trust client-supplied price, currency, item id, power id, cooldown, or hit
   target. Re-derive from `PlayerData` and round state.
3. Ability remotes: verify the caller's character actually owns the tool, is the
   current beast, the round is active, and the power is the active `CurrentPower`.
4. Keep `DetectedEvent` as a silent log rather than an instant ban; false positives
   from lag/duplicate events are likely.
5. Do not return exception text to the client (see `REPORT.md` finding 2 — same
   failure mode is worth re-testing here).

---

## 8. Open questions / next capture

- [x] `RemoteEvent` direction: confirmed bidirectional. Client→server uses
      `("Input", "Trigger"|"Action"|"Crawl", ...)` - see `LEARNINGS.md` §4.
- [ ] `HammerEvent` / `PowersEvent` payloads — need a beast round with the listener active.
- [ ] Opcode vocabulary for `RemoteEvent` (shop/inventory/trade) — needs hooks or a
      controlled purchase-to-echo diff.
- [ ] Whether the Halloween event grants candy server-side only.
- [ ] Whether invalid remote calls raise `DetectedEvent` (test on a throwaway account,
      ideally in a private server).
- [x] Beast identity is client-discoverable (see §9).
- [x] `CoreGui` / `PlayerGui` writable, injected GUIs undetected (see §9).

---

## 9. Client-side visibility test — player ESP (2026-10-29, live)

**Severity: Info / Low.** Nothing here is a server bug: Roblox replicates every
character's position to every client, so a position ESP is inherent to the platform.
The notable part is that the **beast is identifiable from a static model marker** and
that **injected GUI is not detected**.

### 9.1 Beast identification is free

Every survivor's character carries only the cosmetic `PackedHammer` accessory
(`Accessory`). The beast's character is the **only** one carrying:

| Child | Class | Contents |
|---|---|---|
| `Hammer` | `Model` | `HammerEvent`, `LocalClubScript`, `ClubScript`, swing animations, `SelfDestroy` |
| `BeastPowers` | `Model` | `PowersEvent`, `PowerProgressPercent` |

So `character:FindFirstChild("BeastPowers")` (or `"Hammer"`) is an exact, zero-cost
beast oracle — no remotes, no state reads. It is destroyed on round end, which also
gives a free "round over" signal. This is the same model that §2.2 lists as holding the
P1 ability remotes.

### 9.2 GUI injection is not detected

`CoreGui` is directly writable by the executor (no `gethui` needed) and `PlayerGui` is
too. A `ScreenGui` with per-player projected boxes ran continuously for several minutes
of live play; **`DetectedEvent` and `WarningEvent` never fired**, and no
`DetectedFrame` / `WarningFrame` appeared. The game also never scans for foreign
`ScreenGui` children — an injected GUI in `CoreGui` is completely invisible to game code.

`PlayerGui` children were not cleared during the session either, but `CoreGui` is the
safer parent since the game cannot touch it.

### 9.3 Executor notes (corrections to §1)

- `getgenv()` is **absent**; `_G` works and **persists between separate script
  executions**, so `_G` is the cross-run channel.
- `task.wait`, `task.spawn`, and `RunService.RenderStepped:Wait()` all work normally.
  Render is **not** throttled while the window is merely unfocused — a `RenderStepped` loop
  sustained 60 fps. However, a **minimised or fully occluded** client can stall
  completely - 0 `Heartbeat` frames in 2 s of wall clock was measured, and any
  script that yields at that point never resumes. Do not use yields to detect
  liveness.
- `CoreGui` is reachable via `game:GetService("CoreGui")` with no elevation.
- Still no `Drawing` library, no `hookmetamethod` / `getgc` / `getreg` — the §1
  constraints otherwise hold.

### 9.4 Impact and what to fix

An ESP gives the beast exact survivor positions (and survivors exact beast positions),
plus name/distance, which removes the game's core uncertainty. It is client-side and
therefore unpreventable in absolute terms, but the **detection** surface is empty:

1. Nothing distinguishes the beast except a replicated model; if hiding the beast is
   intended to matter, consider not naming the marker `BeastPowers` / `Hammer` and
   putting `PowersEvent` under a neutral, per-round name.
2. No server-side telemetry on suspicious client behaviour. If `DetectedEvent` exists
   as a reporting channel (§2.1, §6-P4), nothing currently feeds it for GUI injection —
   this is expected, but it means the only anti-ESP lever is behavioural server-side
   (e.g. aim/angle heuristics), not client-side scanning.

Reproduction: `esp.lua` + `esp_unload.lua` in this folder.

## 10. Client-side `WalkSpeed` - 2x movement speed (2026-10-29, live)

**Severity: Low-Medium.** `Humanoid.WalkSpeed` on your own character is effectively
client-authoritative: the owning client writes it, the change replicates, and the server
accepts the resulting movement. No server-side validation was observed.

### 10.1 Measured

| Condition | `WalkSpeed` | Average speed | Peak |
|---|---|---|---|
| Normal | 16 | 14.8 studs/s | 16.0 |
| Boosted | 32 | 31.8 studs/s | 32.0 |

The boost was measured over 1 s of sustained movement. A 2 s idle watch on
`GetPropertyChangedSignal("WalkSpeed")` saw **no server-side reset**, and 1 s of boosted
movement produced **no rubber-banding or position correction**, so the server is not
clamping or snapping the character back.

### 10.2 No detection

`DetectedEvent` / `WarningEvent` never fired during the boosted run, no `DetectedFrame` /
`WarningFrame` appeared, and nothing re-set `WalkSpeed` to the game's value. As with §9,
the client is trusted for its own movement and nothing on the server double-checks it.

Everything the game needs to catch this is available server-side - `Humanoid.WalkSpeed`,
distance travelled per interval, and the humanoid's `MoveDirection` - but none of it is
currently used.

### 10.3 Impact and what to fix

The beast is the character for whom speed matters most: 2x closes any chase the survivors
can otherwise win, and combined with §9's position ESP it removes both halves of the
game's core asymmetry (knowing where people are, and being able to outrun them).

1. Validate displacement server-side against a sane per-round maximum rather than trusting
   `WalkSpeed`. Sample `HumanoidRootPart.Position` on a fixed interval and flag sustained
   overspeed - this catches writes to `WalkSpeed`, `AssemblyLinearVelocity`, and teleports
   with the same check.
2. Feed it into the existing reporting channel (A 2.1, A 6-P4) instead of silently ignoring
   it.
3. Do not hard-code `16` as the expected speed for both roles - the beast legitimately
   differs, so the check must follow whatever the round assigned.

Reproduction: `speed.lua` + `speed_unload.lua` in this folder.

## 11. Client-side capture bypass - anti-freeze (2026-10-29, live)

**Severity: Medium.** Being captured is enforced entirely on the client: the server
teleports you into a `FreezePod` model and sets `TempPlayerStatsModule.Captured` /
`.Ragdoll`, and the `Ragdoller` LocalScript responds by setting
`Humanoid.PlatformStand = true`. Nothing else holds you in place.

### 11.1 The freeze has only two teeth

| Mechanism | Where it lives | Client can undo |
|---|---|---|
| ragdoll (`PlatformStand = true`) | client Humanoid | yes, one property write |
| sealed box (floor + walls + roof + `PodRoof`) | pod `CanCollide` parts | yes, locally |
| weld to the pod | **none** - `HumanoidRootPart.Anchored = false`, no external `JointInstance` | n/a |

That second row is the important one: `Plate1.CanCollide = false` on the client only
changes the local physics world. The server's parts are untouched, so this is invisible
to every other player - there is no replication of the change back to the server.

### 11.2 Verified

Issuing `PlatformStand = false` + `ChangeState(GettingUp)` and clearing
`Captured` / `Ragdoll` / `IsCrawling` / `DisableCrawl` / `DisableInteraction` releases the
character immediately. Opening the pod locally turns off collision on 9 of its 10 parts
(everything above the floor), leaving the floor so you do not fall through the map; the
whole pod is restored the moment you step clear of it. Full round trip tested live.

`TempPlayerStatsModule.NormalWalkSpeed` also exposes the game's intended speed for the
current role (16 survivor, 17 beast), which is the honest number any speed check must
compare against.

### 11.3 Impact and what to fix

Capture is the survivors' main loss condition, so being able to walk out of a pod
neutralises the beast's objective. The anti-freeze also clears `DisableInteraction`, so
objective prompts are usable while supposedly captured.

1. Make capture server-authoritative. The client must not be the only thing enforcing it:
   on capture, have the **server** anchor or weld the character into the pod and keep a
   server-side `Captured` flag.
2. While `Captured` is true server-side, reject character movement: clamp or snap
   `HumanoidRootPart` back to the pod if it leaves a small radius. This catches un-ragdoll,
   noclip, and teleport variants with the same check.
3. Do not gate objective interaction on a client-set flag such as `DisableInteraction` -
   validate on the server.

Reproduction: `antifreeze.lua` + `antifreeze_unload.lua` in this folder.
