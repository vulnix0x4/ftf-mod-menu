# Flee the Facility — Session Knowledge Base

Everything learned across this engagement, consolidated into one file.

| Field | Value |
|---|---|
| Place | `893973440` |
| Game / Universe | `372226183` |
| Experience | **Flee the Facility** by A.W. Apps |
| Test client | Disposable test account via Potassium |
| Dates | 2026-10-29 |
| Scope | Authorised client-side pentest + QoL/cheat tooling |
| Side documents | `ATTACK_SURFACE.md` (formal writeup §1–§11), `REPORT.md` (different place: `14289388505`) |

> This file is the working log: mechanics, the remote protocol, what the tools do, what was
> disproved, and every trap hit along the way. `ATTACK_SURFACE.md` remains the formal
> findings document; where the two overlap, this file is more current.

---

## Contents

1. [Executor environment](#1-executor-environment)
2. [Game internals](#2-game-internals)
3. [Capture / freeze mechanics](#3-capture--freeze-mechanics)
4. [Remote protocol](#4-remote-protocol)
5. [Shipped features](#5-shipped-features)
6. [Dead ends / negative results](#6-dead-ends--negative-results)
7. [Debugging traps](#7-debugging-traps)
8. [Operational notes](#8-operational-notes)
9. [File inventory](#9-file-inventory)
10. [Open questions](#10-open-questions)
11. [Verification snippets](#11-verification-snippets)

---

## 1. Executor environment

Potassium on a live Roblox client. Capability surface, confirmed by probing:

| Capability | Result |
|---|---|
| `Drawing` library | **absent** — GUIs must be `Frame` + `UIStroke` |
| `getgenv()` / `gethui()` | **absent** |
| `_G` | present, and **persists between separate script executions** — the cross-run channel |
| `game:GetService("CoreGui")` | reachable with no elevation; **directly writable** |
| `PlayerGui` | writable, but the game may clear it; prefer `CoreGui` |
| `hookmetamethod` | absent |
| `getrawmetatable` / `setreadonly` | present |
| `hookfunction` | present — **but see §7.2, do not hook `FireServer`** |
| `getnamecallmethod` | present |
| `getconnections` | present |
| `getscriptclosure` / `getscriptbytecode` | present |
| `firetouchinterest` | present |
| `debug.info` / `debug.getupvalues` / `debug.getconstants` / `debug.getprotos` | present |
| `require()` on client ModuleScripts | works |
| `Script.Source` / `LocalScript.Source` for game scripts | **empty (0 bytes)** |
| `Drawing`, `getgc`, `getreg`, `getrenv`, `getloadedmodules` | absent |

Behavioural note: the client **fully pauses when the Roblox window is unfocused** —
0 `Heartbeat` frames measured over 2 s. Anything that yields (`task.wait`,
`RenderStepped:Wait()`) stalls until focus returns. Only synchronous code runs.
(Earlier in the session a `RenderStepped` loop appeared to run unfocused; the later,
directly measured result is the one to trust.)

Consequence for tooling: no yields inside keypress handlers, no `task.wait`-based
"keep alive" logic, and teardown must be possible from a single synchronous call.
`_G` is the only durable state across script runs.

---

## 2. Game internals

### 2.1 Beast identification is free

Survivors carry only the cosmetic `PackedHammer` (an `Accessory`). The beast's character
is the **only** character with:

| Child | Class | Notes |
|---|---|---|
| `Hammer` | `Model` | `HammerEvent`, `LocalClubScript`, `ClubScript`, swing animations, `SelfDestroy` |
| `BeastPowers` | `Model` | `PowersEvent`, `PowerProgressPercent` |

So `character:FindFirstChild("BeastPowers")` (or `"Hammer"`) is an exact, zero-cost beast
oracle — no remotes, no state reads. Both disappear at round end, which doubles as a free
"round over" signal.

### 2.2 Round state (server-replicated, readable)

`ReplicatedStorage` ValueBase instances:

| Value | Type | Sample |
|---|---|---|
| `GameTimer` | IntValue | `793` |
| `IsGameActive` | BoolValue | `true` / `false` |
| `ComputersLeft` | IntValue | `3` |
| `PowerActive` | BoolValue | `true` |
| `CurrentPower` | StringValue | `"Seer"` |
| `CurrentMap` | ObjectValue | `Airport` |
| `GameStatus` | StringValue | `COMPUTERS LEFT : 3` |

Clients can write these locally (cosmetic only). Read them before/after an action to see
what the **server** accepted.

### 2.3 `TempPlayerStatsModule`

A **client-side** ModuleScript parented to `Player` (not `ReplicatedStorage`), holding
`ValueBase` children. Reads are useful; **writes are local-only and have no server effect**.

| Child | Type | Notes |
|---|---|---|
| `NormalWalkSpeed` | NumberValue | The game's intended speed: **16 survivor, 17 beast** |
| `Captured` | BoolValue | freeze state |
| `Ragdoll` | BoolValue | ragdoll state |
| `IsBeast` | BoolValue | role |
| `ActionProgress` | NumberValue | local mirror of computer-hack progress |
| `ActionInput` | BoolValue | hack input state |
| `MinigameResult` | BoolValue | skillcheck result |
| `OnTrigger` | BoolValue | trigger occupancy |
| `IsCrawling`, `DisableCrawl`, `DisableInteraction` | BoolValue | movement/interaction gates |

Key correction: do **not** read `Humanoid.WalkSpeed` as "normal speed". The game drops it
to 8 while frozen, so doubling it only gets back to normal. Always use
`NormalWalkSpeed`.

### 2.4 Map objects

- `CurrentMap.Value` is the map `Model` (e.g. `Airport`).
- `ComputerTable` models, each with one or more `ComputerTriggerN` parts.
  Each trigger has an `Event` `BindableEvent` child (also used by doors as
  `DoorTrigger.Event`).
- Each `ComputerTable` has a `Screen` part. **Solved state = `Screen.Color`.** Only
  colour changes; nothing else on the model flips.
  - solved: `287f47` (green-dominant)
  - unsolved: `0d69ac` (blue)
- `FreezePod` models live directly under the map folder (7 on Airport). See §3.

---

## 3. Capture / freeze mechanics

Capture is enforced **entirely on the client**:

1. The server teleports the character into a sealed `FreezePod` model.
2. It sets `TempPlayerStatsModule.Captured` and `.Ragdoll`.
3. The `Ragdoller` LocalScript responds by setting `Humanoid.PlatformStand = true`.

### 3.1 Pod anatomy

| Part / child | Class | Role |
|---|---|---|
| `PodTrigger` | BasePart | detection volume |
| `PodScript` | Script | pod logic |
| `CapturedTorso` | ObjectValue | **points at the captured character's torso** — the authoritative "this pod is mine" signal |
| `PodRoof` | BasePart | lid |
| `Event` | BindableEvent | per-pod trigger event |
| `PodBarriers` (folder, map-level) | parts | lid/barrier parts |

There are **no external welds**. `HumanoidRootPart.Anchored = false`. The only things
holding a captured player are the ragdoll flag and the pod's own collision.

### 3.2 What T actually has to undo

| Mechanism | Where | Client can undo |
|---|---|---|
| ragdoll (`PlatformStand = true`) | client Humanoid | yes — one property write |
| sealed box (floor + walls + roof) | pod `CanCollide` parts | yes — locally only |
| weld to the pod | **none** | n/a |

`CanCollide = false` on the client only changes the local physics world. It does not
replicate, so other players and the server never see it — useful, and invisible.

### 3.3 Detection order used by `antifreeze.lua`

1. **`CapturedTorso`** — check each *cached* pod's `CapturedTorso.Value`; if it is a
   descendant of your character, that is your pod. Also checks direct `workspace`
   children named `FreezePod` (lobby/prefab pods).
2. **Bounds** — transform your position into pod space and test against the bbox with a
   generous margin (**±1.5 X/Z, ±2.0 Y**). The original tight box missed players who were
   visibly inside.
3. **Nearest pod within 15 studs** — only when `Captured` is true or
   `PlatformStand` is set.

Never scan all of `workspace` from this path (see §7.1).

---

## 4. Remote protocol

This was the biggest discovery, and it changes the earlier "remotes cannot be observed"
conclusion in `ATTACK_SURFACE.md` §1.

`ReplicatedStorage.RemoteEvent` is the **client→server multiplexed gateway**. Opcode shape:

```
RemoteEvent:FireServer(<string family>, <string action>, ...)
```

### 4.1 Observed calls

Computers (hacking):

```lua
RemoteEvent:FireServer("Input", "Trigger", true,  ComputerTrigger3.Event)
RemoteEvent:FireServer("Input", "Trigger", false, ComputerTrigger3.Event)
RemoteEvent:FireServer("Input", "Action",  true)
RemoteEvent:FireServer("Input", "Action",  false)
```

Doors:

```lua
RemoteEvent:FireServer("Input", "Trigger", <bool>, DoorTrigger.Event)
```

Crawling:

```lua
RemoteEvent:FireServer("Input", "Crawl", <bool>)
```

Captured raw lines from the client (timestamps are client uptime):

```
[NC 698.82] FireServer(ReplicatedStorage.RemoteEvent | str:Input | str:Trigger | boolean:false | Inst:Workspace.Airport.ComputerTable.ComputerTrigger3.Event)
[NC 698.97] FireServer(ReplicatedStorage.RemoteEvent | str:Input | str:Action | boolean:false)
[TOUCH 699.00] ComputerTrigger3
```

The client **separately pulses** `Input/Action` from the `Trigger` press, and the action
lifetime is mirrored into `TempPlayerStatsModule.ActionProgress`.

### 4.2 Hacking duration is server-enforced

Measured progress rates on live hacks: roughly **0.02–0.08 per second**, i.e. **12–55 s**
per computer depending on the round. The `ActionProgress` value on the client is a mirror;
writing it does nothing server-side (a write persists locally, the computer never completes).

### 4.3 Speed-up attempts — all negative

Four automated A/B hacks comparing a normal baseline window against a window with
`Input/Action` pulses fired every frame:

| Hack | Baseline (per frame) | With `Action` pulses | Ratio |
|---|---|---|---|
| 1 | 0.00028 | 0.00030 | **1.06x** |
| 2 | 0.00030 | 0.00028 | **0.94x** |
| 3 | 0.00030 | 0.00028 | **0.94x** |
| 4 | 0.00030 | 0.00030 | **1.00x** |

No effect. And spamming `Input/Trigger true` is actively **worse**: each press restarts
the action, dropping the rate from ~0.08/s to ~0.018/s.

Firing across multiple triggers does not help — it is one action per trigger. There is no
RemoteFunction and no completion message to abuse.

**Conclusion: instant / faster hacking is not achievable client-side.** The client only
says start/stop; the duration is computed on the server.

---

## 5. Shipped features

All four systems are independent scripts with their own `_G` handle and teardown.
Live state at last check: ESP on, speed on (base 16, boost off), anti-freeze on
(7 pods), HUD on with two rows.

### 5.1 ESP — `esp.lua`

| Element | Colour | Rule |
|---|---|---|
| Beast | red `255,45,45` | character has `BeastPowers` or `Hammer` |
| Survivor | green `60,255,110` | everyone else |
| Computer | blue `70,150,255` | `ComputerTable` with an unsolved `Screen` |

- Solved computers are **hidden** (`HideSolved`, screen green-dominant).
- No `Drawing` in this executor: boxes are `Frame` + `UIStroke` inside a `ScreenGui`
  parented to `CoreGui`.
- Player boxes are built in `HumanoidRootPart` space so they hug the body instead of
  widening when a player turns. Computer boxes use a **cached world-space AABB** — those
  never move.
- Name + distance tags, dead players hidden, self excluded.
- Kill switch: newest run claims `_G.__ftfESPInstance`; older runs disconnect themselves.
- Caveat: some maps have more `ComputerTable` models than `ComputersLeft` implies, so an
  extra unsolved blue marker can appear.
- API: `_G.__ftfESP` (config table), `_G.__ftfESPStop()`.

### 5.2 Speed — `speed.lua`

- `Q` toggles 2x. `Mode = "toggle"` (or `"hold"`).
- Base comes from `NormalWalkSpeed`: **16 → 32**, beast **17 → 34**.
- Re-applied every frame if the game resets `WalkSpeed`, so it survives respawns and
  freezes.
- Badge indicator (`FTF_Speed`) in `CoreGui`, visible only while boosted.
- Measured: normal 14.8 studs/s (peak 16), boosted 31.8 studs/s (peak 32); no
  server-side reset, no rubber-banding.
- API: `_G.__ftfSpeed.IsBoosted()`, `.Base()`, `.Set(bool)`, `.Toggle()`, `.Stop()`,
  plus `_G.__ftfSpeedStop()`.

### 5.3 Break free — `antifreeze.lua`

Press `T` (manual; `AutoRelease = false`).

Three stages:

1. **Find the pod** — `CapturedTorso` → bounds (±1.5 X/Z, ±2.0 Y) → nearest within 15.
2. **Open it** — every `BasePart` with `Position.Y > floorY + 0.3` gets
   `CanCollide = false` (walls + roof + lid), floor kept so you do not fall through.
   Typically **9 of 10 parts**. Saved originals are restored once you are clear.
3. **Teleport out** — if still inside after 15 ticks (~0.25 s), raycast the four
   horizontal directions for the most open one, ignore your character and the pod, and
   move **7 studs** that way (facing out). Retries up to **8 times**
   (`TeleportRetries`), 24 ticks apart, in case the server snaps you back. A fresh
   `Captured` rising edge re-arms the window and resets the teleport budget
   (`RearmOnRecapture`), so a failed escape that gets re-podded does not sit at 0 ticks.

Also on every press:

- clears `Captured`, `Ragdoll`, `IsCrawling`, `DisableCrawl`, `DisableInteraction`
- `PlatformStand = false`, `ChangeState(GettingUp)` when in
  PlatformStanding / Physics / FallingDown
- restores `WalkSpeed` to `NormalWalkSpeed`
- keeps the pod open for up to 180 ticks (~3 s) while you walk out, then restores it

Keybind: capture screens can deliver the keypress as `gameProcessed`, so the bind ignores
that flag and only blocks when a `TextBox` actually has focus
(`UserInputService:GetFocusedTextBox()`).

API: `_G.__ftfAntiFreeze.Config`, `.Pods()`, `.Released()`, `.Release()`, `.Step()`,
`.Stop()`, plus `_G.__ftfAntiFreezeStop()`.

Verified in simulation (placed inside a pod, then released):

```
[FTF-ANTIFREEZE] break free (1) pod=FreezePod
[FTF-ANTIFREEZE] moved out of the pod (try 1)
freed: offset x=-7.0 z=0.0 ws=16 ps=false
Release 0.1 ms, pod noncollide 2 -> 11
```

### 5.4 HUD — `hud.lua`

- Small panel, bottom-right (`AnchorPoint 1,1`, 12 px inset), width 176 px.
- Rows: `Q  2x speed  ON/off`, `T  break free  ready`.
- ~10 Hz status refresh (`UpdateFrames = 6`).
- Extensible:

```lua
_G.__ftfHud.Register(id, key, label, statusFn)   -- statusFn returns (text, isActive)
```

- Rebuild clears rows **by name and by reference**, which fixed duplicate rows stacking
  on top of each other after a rebuild.
- API: `_G.__ftfHud.Register`, `.Refresh`, `.Rows`, `.Stop`, plus `_G.__ftfHudStop()`.
- Unload: `hud_unload.lua` (shipped) or `_G.__ftfHudStop()`.

### 5.5 Mod menu — `menu.lua`

A real panel instead of keybind-only status. Draggable by the title bar, built from
`Frame`/`TextButton`/`UIStroke` (no `Drawing`), parented to `CoreGui`, `DisplayOrder 200`.

| Tab | Controls | Drives |
|---|---|---|
| PLAYER | ESP overlay, computer markers, hide solved, beast alert, beast log | `__ftfESP`, `__ftfBeastwatch`, `__ftfBeastRecon` |
| MOVE | speed `[Q]`, multiplier slider, noclip `[V]`, TP to computer `[H]` | `__ftfSpeed`, `__ftfNoclip`, `__ftfObjectives` |
| RESCUE | auto break-free, break now `[T]`, auto doors, auto rescue, camp guard, TP to frozen, free nearest `[Y]` | `__ftfAntiFreeze`, `__ftfDoors`, `__ftfRescue` |
| SYSTEM | auto skillcheck, skillcheck snapshot, reload modules, unload tools | `__ftfAutoSkill`, `__ftfSkillProbe`, loader |

- 302 px tabbed panel: title bar (status dot, version, minimise `_`, close `x`), tab strip with
  an accent underline, page body, status footer with keybind hints.
- If a module is not loaded, the row fetches it from `127.0.0.1:8765` on first click.
- Toggle states resync from the live APIs ~10 Hz, so keybinds (`Q`/`V`/`T`/`Y`/`H`) and the
  menu never disagree.
- Multiplier changes apply live while boosted (the speed loop re-writes `WalkSpeed`).
- Footer shows `esp / spd / af` plus `+/-` tags for doors/rescue/auto-skillcheck; the title
  dot turns green when the three core modules are loaded.
- `RightShift` toggles visibility; `x` hides; `_` minimises to the title bar. Position
  persists across reloads in `_G.__ftfMenuPos`.
- API: `_G.__ftfMenu.Show/Toggle/Tab/Load/Stop`, plus `menu_unload.lua`.
  `Tab("player"|"move"|"rescue"|"system")` switches pages.

### 5.6 Beast recon — `beast_recon.lua`

Passive capture of the two per-round ability remotes, which live in the beast's
character (`Hammer.HammerEvent`, `BeastPowers.PowersEvent`).

- Polls the player list every 20 Heartbeat frames (no workspace walks) and attaches
  `OnClientEvent` listeners the moment a beast character appears; re-arms every round.
- Logs argument count and types to the console (`[FTF-BEAST] ... <- 2 args | ...`) and
  optionally to a bottom-left panel (`ShowPanel` / `.Show(true)`).
- Ring buffer of 60 entries; `Log()` returns them, `Remotes()` returns the hooked set.
- **No `FireServer` hook** — per §7.2 that breaks the hack skillcheck. Read-only.
- API: `_G.__ftfBeastRecon.Beast/Log/Remotes/Show/Stop`, plus `_G.__ftfBeastReconStop()`.

### 5.7 Loaders

| File | Loads | Use |
|---|---|---|
| `lua/loaders/ftf_suite.lua` | esp, speed, antifreeze, hud | legacy stable in-game set |
| `lua/loaders/ftf_loader.lua` | esp, speed, antifreeze, rescue, doors, noclip, objectives, beast_recon, beastwatch, skillcheck_probe, skillcheck, menu | full set incl. menu |

Both live under `lua/loaders/`; modules are under `lua/modules/`, teardown scripts under
`lua/unload/`, one-shot tools under `lua/tools/`, diagnostics under `lua/probes/`.
Both fetch from the local static server (`serve.js` in the repo root, port 8765) and
`loadstring` each module. `%LOCALAPPDATA%\Potassium\autoexec\ftf.luau` points at
`lua/loaders/ftf_loader.lua`, so the full set loads on attach.

### 5.8 Auto doors — `doors.lua`

Doors use the same `Input/Trigger` opcode as everything else, with the door's trigger
`Event` as the fourth argument:

```lua
RemoteEvent:FireServer("Input", "Trigger", true,  DoorTrigger.Event)   -- open
RemoteEvent:FireServer("Input", "Trigger", false, DoorTrigger.Event)   -- release
```

- Discovers door triggers from `CurrentMap` only: a `BasePart` with an `Event`
  `BindableEvent` child whose own name or parent name contains `door`
  (`ComputerTrigger*` excluded). Cached, rebuilt on map change / every 4 s.
- On **entering** `Radius` (10 studs) with the camera roughly facing the door, fires the
  press instantly, then the matching `false` six frames later. That is the game's own open
  path fired early, so the door is already swinging when you arrive.
- `FireOnce = true` by default: a door is never re-toggled after it has been opened, so
  walking past cannot close it again. `ReopenAfter > 0` opts into re-firing closed doors
  after N seconds if live doors turn out to auto-close.
- No teleporting, no door-part edits, no hooks, no workspace scan in the frame path.
- Config: `Enabled`, `Radius`, `FacingDot`, `FireOnce`, `ReopenAfter`, `ReleaseTicks`.
- API: `_G.__ftfDoors.Config/.Doors()/.Fired()/.Set()/.Toggle()/.Test()/.Dump()/.Stop()`.
- `Test()` fires the nearest trigger immediately, bypassing radius/facing/FireOnce — use it
  to prove the protocol works before blaming the auto path. `Dump()` lists every trigger,
  its `kind` (`named` or `event`), distance and fired state.
- If no trigger name contains `door`, discovery falls back to every non-computer `Event`
  part under the map (the only other things speaking `Input/Trigger`) and logs that it did.
- `doors_probe.lua` dumps the live door structure: map children, Event-bearing parts by
  name/parent, 15 nearest with distances, Workspace door models, remote presence, and what
  `doors.lua` currently sees. Copies the report to the clipboard when supported.
- **Live semantics still unconfirmed:** whether FTF doors open on press and stay open, or
  toggle on every press. The mock verifies the payload and edge logic; one real door will
  settle the config.

### 5.9 Noclip — `noclip.lua`

- `V` toggles; while on, every `BasePart` descendant of your character gets
  `CanCollide = false`, original values saved and restored on toggle-off / respawn /
  unload.
- Client-local only (same physics-visibility argument as §3.2): the server and other
  players still see normal movement; it just stops the local solver from pushing you out
  of geometry.
- Reapplies every frame while on, so respawns and newly added parts are caught.
- API: `_G.__ftfNoclip.Config/.IsOn()/.Set()/.Toggle()/.Stop()`.

### 5.10 Skillcheck probe — `skillcheck_probe.lua`

Passive recon for the hack timing minigame, because auto-hitting it needs the real widget
structure first.

- Logs every transition of `MinigameResult`, `ActionProgress`, `ActionInput`,
  `OnTrigger`, `Captured`.
- While progress is moving (or `ActionInput` is true), snapshots newly appearing
  `GuiObject`s with class, name, absolute size/position, rotation and a short parent path;
  widgets matching `skill/minigame/timing/zone/target/marker/needle/hit/bar/action/progress`
  are always recorded.
- `Snapshot()` dumps current stats + visible candidates on demand (menu button).
- `Tree()` dumps every `GuiObject` under `PlayerGui` **regardless of visibility** (the
  timing widget usually exists all round and is only hidden), with class, name,
  visibility, size, position, rotation and parent path. It also runs automatically when
  `ActionInput` rises, which is the closest signal we have to "the circle just appeared".
- `Copy()` puts the recent log **and the last tree dump** on the clipboard, for pasting
  into chat.
- `Force()` is a deliberate experiment: sets `MinigameResult = true` once, to test whether
  the client's result value is trusted by the server. It fires no remote.
- No hooks, no `FireServer` interception (§7.2 rule respected).
- API: `_G.__ftfSkillProbe.Config/.Log()/.Snapshot()/.Copy()/.Force()/.Stop()`.
- **Next step:** run one hack with the probe loaded, read the `[FTF-SKILL]` lines, then the
  auto-hit can lock onto the actual marker/zone widgets instead of guessing.

**Live GUI discovery (2026-10-30):** the minigame is
`PlayerGui.ScreenGui.TimingCircle` with children `TimingBase`, `TimingPin`,
`ActionKeyIcon`. Also confirmed: `ActionBox.ActionKeyIcon`, `ProgressBox.ProgressFill`,
`StatusBars` (per-survivor health bars), `SpectatorFrame`, `BeastPowerBar`, and the
end-of-round `GameResultsFrame` / `PersonalResultsFrame`. `Tree()` now defaults to this
gameplay subset instead of dumping every shop `ImageLabel`; `Tree(reason, true)` is the
full dump.

### 5.14 Auto skillcheck — `skillcheck.lua`

Built against the confirmed `TimingCircle` widget.

- **Timing model (live capture 2026-10-30):** `TimingBase.Rotation` is the success
  angle (sample: 135°); `TimingPin.Rotation` sweeps through it at roughly 4–8°/frame
  and does **multiple revolutions** before the circle hides. Pressing after
  `TimingCircle.Visible` goes false is always late.
- `TimingHit = true` (default): every frame the circle is visible, reads both rotations
  and fires on the exact crossing (delta sign change, wrap jumps over 90° are ignored)
  or inside `HitTolerance` (2°). `HitOffset` (0) shifts the target if the arc is not at
  `TimingBase.Rotation`. Max one press per 0.12 s.
- `HitDelayTicks = 2` (default): waits this many frames after the crossing before pressing.
  Two frames is ≈8° at the observed pin speed; raise/lower to taste, 0 = zero delay.
  The hit log prints the actual angle at press time.
- **Input is local, not just the remote:** during the circle the client's `ActionInput`
  stays false if only `Input/Action` is fired, and the player's manual press sets it true
  after the circle closes. On a hit the module now tries `keypress` / `VirtualInputManager`
  key event / `mouse1click` / a VIM click at the circle centre, in addition to the remote.
  The `input=` field in the hit log says whether any local method was available.
- `SetResult = true`: writes `MinigameResult = true` only on the timing hit; constant
  forcing was removed because it did not move the hack.
- `ActionPulse` / `AutoPress` remain as fallbacks (`Input/Action` on the rising edge or
  every `PressEvery` frames).
- Visibility is checked through the whole ancestor chain (`ScreenGui.Enabled`,
  `TimingCircle.Visible`, parent frames), not just the circle's own flag.
- Logs `TimingPin` rotation and absolute position while visible, plus `TimingBase`
  rotation, so a real timing hit can be derived if the result flag isn't trusted:
  `[FTF-AUTOSKILL] pin rot=... pos=...,... baseRot=...`.
- Menu toggle: **SYSTEM → Auto skillcheck (TimingCircle)**. The old "Force skill result"
  button was removed; `_G.__ftfSkillProbe.Force()` still exists for manual tests.
- Config: `Enabled`, `SetResult`, `ActionPulse`, `PulseTicks`, `LogPin`.
- API: `_G.__ftfAutoSkill.Config/.Checks()/.Forced()/.Status()/.Stop()`.
- `skillcheck_debug.lua` is the ground-truth logger: 45 s of `ScreenGui.Enabled`,
  circle/base/pin visibility, pin `Rotation`/`AbsolutePosition`/`ImageRectOffset`, stats
  values, and progress resets. Run it while hacking when the auto module appears to do
  nothing.

### 5.11 Frozen teammate rescue — `rescue.lua`

Occupied pods identify their occupant directly, so no guessing is needed:

| Signal | Meaning |
|---|---|
| `FreezePod.CapturedTorso.Value` | torso of the captured character |
| `player.Character` + `IsDescendantOf` | which player that torso belongs to |
| `FreezePod.Event` | the pod's own rescue trigger (same `Input/Trigger` protocol) |

- `Targets()` lists every occupied pod with player, pod, position and distance.
- Discovery is deliberately loose: pods are taken from `CurrentMap` direct children,
  any `ObjectValue` named `CapturedTorso` anywhere under the map, and Workspace direct
  children named `FreezePod*`. `CapturedTorso` and `Event` are looked up recursively, and
  a player-name ancestry fallback covers captured ragdolls that are no longer
  `Player.Character`.
- `TeleportNearest()` / `TeleportTo(name)` place you ~4 studs outside the pod, on the side
  you are approaching from, with a raycast clearance check; falls back to the approach
  direction if raycasting is unavailable.
- `FreeNearest()` / `Free(target)` fire `Input/Trigger true` with `pod.Event`, release six
  frames later, and (with `UseActionHold = true`) pulse `Input/Action` for ~0.75 s in case
  the rescue is a hold interaction. Cooldown 2.5 s per pod, preserved across rescans via an
  `attempts[pod]` table.
- `AutoRescue` frees any occupied pod within `Radius` (14 studs) whenever you are not
  captured yourself. Teleporting is a separate button, not automatic.
- `CampGuard` counters beast camping: it watches the beast's replicated position and, if
  it stays within `CampRadius` (20 studs) of an occupied pod for `CampDelay` (3 s), frees
  that teammate automatically — from anywhere on the map, because rescue is not
  range-checked. Timer resets when the beast leaves the pod.
- `Y` frees the nearest occupied pod from wherever you are, using the cached pod list
  (the handler never scans the map), with a 0.5 s key cooldown. `CONFIG.FreeKey` /
  `CONFIG.KeyCooldown` change that.
- No hooks, no pod edits. Teleporting is a normal client `HumanoidRootPart.CFrame` write —
  if the live server ever position-validates, the character will snap back; none observed
  so far.
- **Live finding (2026-10-30): the rescue trigger is accepted from any distance.** Firing
  `Input/Trigger` with an occupied pod's `Event` freed the teammate while the player was
  nowhere near the pod. The server does not range-check pod rescue against the caller —
  worth reporting to the owner alongside the capture/freeze findings in §11.
- Config: `AutoRescue`, `Radius`, `Cooldown`, `HoldTicks`, `UseActionHold`,
  `TeleportDistance`, `RescanSeconds`.
- API: `_G.__ftfRescue.Config/.Targets()/.Nearest()/.TeleportNearest()/.TeleportTo()/
  .FreeNearest()/.Free()/.Rescues()/.Debug()/.Stop()`.
- `Debug()` prints each pod's full path/children, its `CapturedTorso` value, every
  `Event`, all players' current `Character` paths, and the mapped targets.
  `rescue_probe.lua` does the same and copies the report to the clipboard — use it when
  the menu reports "no frozen teammate" while a pod is visibly occupied.
- **Live semantics unconfirmed:** whether one trigger press frees a teammate or the game
  needs a sustained hold/other input. Log line `[FTF-RESCUE] freeing <name> via <pod>`
  confirms the attempt; if the teammate stays frozen, flip `UseActionHold` and/or raise
  `HoldTicks` first.

### 5.12 Beast watch — `beastwatch.lua`

Top-centre HUD banner for countering the beast, especially camping:

```
BEAST  24m  ↗
POWER  68
```

- Finds the beast the same way ESP does (`BeastPowers` / `Hammer` marker on a character),
  reads `HumanoidRootPart.Position`, updates every 6 frames.
- Visible only inside `AlertRadius` (60 studs), hidden entirely when you are the beast.
- Direction arrow is camera-relative (8-way), and the border/text turn brighter red at
  ≤15 studs.
- `POWER` reads `BeastPowers.PowerProgressPercent` when present (normalised to 0–100 if
  the value is 0–1).
- Config: `Enabled`, `AlertRadius`, `ShowPower`, `UpdateFrames`.
- API: `_G.__ftfBeastwatch.Config/.Beast()/.Distance()/.Stop()`.
- Together with the rescue camp guard this closes the camping loop: banner tells you the
  beast is near, camp guard frees the teammate it is sitting on, `Y` frees the nearest
  pod from anywhere.

### 5.13 Objectives — `objectives.lua`

Nearest unsolved computer teleport.

- Computer tables are `CurrentMap` models named `ComputerTable`; solved state is the same
  `Screen.Color` check ESP uses (green-dominant = solved). Only unsolved tables are
  candidates.
- The list is cached and rebuilt every 3 s on RenderStepped — never inside the key/click
  handler (LEARNINGS §7.1).
- `TeleportNearest()` picks the nearest unsolved table's `ComputerTrigger*` part, raycasts
  four directions for the most open side, and drops you 1.5–4 studs out at trigger height.
- **Live bug fixed (2026-10-30):** a prefab trigger parked ~259,000 studs from the real map
  was selected, teleporting into the void. Targets are now rejected when the trigger is
  more than 50 studs outside its own model's bounding box, and anything beyond
  `MaxDistance` (2000 studs) is ignored.
- `H` teleports; menu **SYSTEM → Teleport to computer [H]** does the same. 0.5 s cooldown.
- Config: `Key`, `Cooldown`, `RescanSeconds`, `TeleportDistance`.
- API: `_G.__ftfObjectives.Config/.Computers()/.Nearest()/.TeleportNearest()/.Teleports()/
  .Stop()`.
- Same caveat as rescue teleport: it is a client `CFrame` write; if the server ever
  position-validates, expect a snap-back.

---

## 6. Dead ends / negative results

Recorded so they are not retried.

| Attempt | Result |
|---|---|
| Speed up computer hacking via `Input/Trigger` replay | **Slower** — each press restarts the action (0.08/s → 0.018/s) |
| Speed up hacking via `Input/Action` pulse | **No effect** — 1.06x / 0.94x / 0.94x / 1.00x |
| Write `TempPlayerStatsModule.ActionProgress` | Local only; computer never completes |
| Hook `RemoteEvent.FireServer` to inspect traffic | **Broke the hack skillcheck** (timing circle vanished after a split second). Removed; do not reinstall |
| Hide the beast by removing model names | Not possible client-side; `Hammer`/`BeastPowers` are replicated |
| `CoreGui`/`PlayerGui` injection detection | None — `DetectedEvent` / `WarningEvent` never fired, no `DetectedFrame` / `WarningFrame` |
| Server-side speed validation | None observed — no reset, no snap-back |
| Ban/settings/exception findings from `REPORT.md` | That is Place `14289388505`, **not** this game — do not conflate |

---

## 7. Debugging traps

### 7.1 A workspace-wide scan in a keypress path kills the script

`freeze` detection briefly used `workspace:GetDescendants()` (13,368 instances). Cost
measured ~0.9 ms for the walk and ~1.8 ms for the name filter, i.e. ~2.7 ms — yet the
executing thread died at exactly that point, after the humanoid calls had already run:

```
A1
A2
A3 ChangeState ok
A4 got 13368
        <- thread dead, A5 never printed
```

Mitigation: resolve pods from the **cached** pod list plus direct `workspace` children
only. `Release()` then took **0.1 ms** and the thread survived. Do not walk all of
`workspace` from `InputBegan`, `RenderStepped`, or anything else that must stay alive.

### 7.2 Hooking `FireServer` breaks the hack minigame

`hookfunction` on `RemoteEvent.FireServer` (and the noisy `__namecall` hook) starved the
server round-trip the timing skillcheck depends on. Symptom: the skillcheck appears, then
disappears before it can be hit. All hooks were torn down and verified gone
(`__ahStop`, `__ncRestore`, `__fsProbeRestore`, `__clRestore` all `nil`).

Rule: instrumentation on remote dispatch is off-limits while the user is playing.

### 7.3 `gameProcessed` eats keys during a capture

The pod/capture UI can mark `T` as game-processed, so `if gameProcessed then return end`
silently dropped it. Fix: only refuse the key when `GetFocusedTextBox()` is non-nil.

### 7.4 Wrong speed baseline while frozen

Reading `Humanoid.WalkSpeed` gave 8 inside a pod, so "2x" produced 16 — normal speed.
`NormalWalkSpeed` is the correct baseline.

### 7.5 Stale scripts tearing down newer ones

Every script instance generates `INSTANCE_ID = os.clock() .. ":" .. random` and publishes
it to `_G.__ftf<Name>Instance`. Each render loop checks that it still owns the slot and,
if not, disconnects **only itself**. Teardown is a per-instance local `unload` closure,
never a shared `_G` function. This prevents an old copy from destroying a newer GUI or
killing a newer loop.

### 7.6 HUD duplicate rows

A rebuild that only cleared by reference left orphaned `row_*` frames. Clearing by name
as well as reference fixed it. Verified: 1 panel, exactly 2 rows.

### 7.7 Console output arrives late

`read_console` frequently returns nothing on the first read after `execute_script`.
Pattern that works: read with the returned cursor, then read again with the new
`latest_cursor` and a short `wait_ms`. Do not conclude a script failed from one empty read.

### 7.8 The client pauses when unfocused

Anything that yields stalls. Test harnesses that used `task.wait` looked "hung" simply
because the Roblox window was not focused. Prefer synchronous loops over yields for
verification.

---

## 8. Operational notes

### Deployment pattern

A small Node static server serves this folder at `http://127.0.0.1:8765`, so long scripts
are fetched rather than pasted:

```lua
local src = game:HttpGet("http://127.0.0.1:8765/lua/modules/antifreeze.lua")  -- executor-dependent
                                                -- or fetch + execute via the harness
```

Practical flow used here:

1. `fetch('http://127.0.0.1:8765/<file>.lua')`
2. `execute_script({ source, pid = "<pid>" })`
3. `read_console({ after_cursor = <returned cursor>, wait_ms = ..., limit = ... })`
4. read once more, because output lags.

### Reload order

Stop the old instance first, then load the new file, otherwise the instance-ID guard makes
the new run disconnect itself:

```lua
if _G.__ftfAntiFreezeStop then _G.__ftfAntiFreezeStop() end
-- then run the file
```

### Testing without being captured

Place the character at a pod centre and release:

```lua
local api = _G.__ftfAntiFreeze
local pod = api.Pods()[1]
local ch  = game.Players.LocalPlayer.Character
local hum = ch:FindFirstChildOfClass("Humanoid")
local root = ch:FindFirstChild("HumanoidRootPart")

local saved = root.CFrame
root.CFrame = CFrame.new(pod.cf.Position + Vector3.new(0, 1.5, 0))
hum.PlatformStand = false
api.Release()
for i = 1, 45 do api.Step() end

local rel = pod.cf:PointToObjectSpace(root.Position)
print(string.format("offset x=%.1f z=%.1f ws=%.0f", rel.X, rel.Z, hum.WalkSpeed))

root.CFrame = saved
for i = 1, 5 do api.Step() end
```

### Safety observations

- No `DetectedEvent` / `WarningEvent` ever fired, and no `DetectedFrame` / `WarningFrame`
  appeared, across ESP, speed, and capture-bypass testing.
- Everything is client-local except the normal `Input` remote calls the game itself
  makes. Pod collision changes never replicate.

---

## 9. File inventory

All scripts live under `lua/` in the repo: modules in `lua/modules/`, loaders in
`lua/loaders/`, teardown in `lua/unload/`, one-shot tools in `lua/tools/`, diagnostics in
`lua/probes/`. The table lists basenames; see `README.md` for full paths.

| File | Purpose |
|---|---|
| `esp.lua` | Player ESP (beast red / survivor green) + computer ESP (blue, solved hidden) |
| `esp_unload.lua` | Removes `FTF_ESP`, stops the instance |
| `speed.lua` | `Q` 2x speed, base from `NormalWalkSpeed` |
| `speed_unload.lua` | Removes boost + badge, restores speed |
| `antifreeze.lua` | `T` break-free: pod detection, local open, teleport escape, re-arm |
| `antifreeze_unload.lua` | Stops rescue loop, restores every opened pod |
| `hud.lua` | Bottom-right keybind panel with extensible rows |
| `hud_unload.lua` | HUD teardown + orphan GUI sweep |
| `menu.lua` | Draggable mod menu (`RightShift`) driving all modules |
| `menu_unload.lua` | Menu teardown + orphan GUI sweep |
| `doors.lua` | Auto-open doors via the game's own `Input/Trigger` path |
| `doors_probe.lua` | Door structure dump + clipboard report for fixing discovery |
| `rescue.lua` | Frozen-teammate list, teleport to pod, auto-free nearby |
| `rescue_probe.lua` | Pod/CapturedTorso structure dump + clipboard report |
| `beastwatch.lua` | Beast distance/direction/power HUD banner |
| `objectives.lua` | `H` teleport to nearest unsolved computer |
| `skillcheck.lua` | `TimingCircle` auto-result / action pulse |
| `skillcheck_debug.lua` | 45 s timing-widget property logger |
| `noclip.lua` | `V` client-side collision bypass with restore |
| `skillcheck_probe.lua` | Passive hack/skillcheck widget recorder + `Force()` test |
| `beast_recon.lua` | Passive `HammerEvent` / `PowersEvent` payload logger |
| `ftf_suite.lua` | Fetches + runs esp/speed/antifreeze/hud |
| `ftf_loader.lua` | Fetches + runs esp/speed/antifreeze/doors/noclip/beast_recon/skillcheck_probe/menu |
| `ATTACK_SURFACE.md` | Formal pentest writeup, §1–§11 |
| `REPORT.md` | Earlier report for a **different** place (`14289388505`) |
| `LEARNINGS.md` | This file |

### `_G` handles

| Handle | Meaning |
|---|---|
| `__ftfESP`, `__ftfESPStop`, `__ftfESPInstance` | ESP config / teardown / owner token |
| `__ftfSpeed`, `__ftfSpeedStop`, `__ftfSpeedInstance` | speed API / teardown / owner token |
| `__ftfAntiFreeze`, `__ftfAntiFreezeStop`, `__ftfAntiFreezeInstance` | freeze API / teardown / owner token |
| `__ftfHud`, `__ftfHudStop`, `__ftfHudInstance` | HUD API / teardown / owner token |
| `__ftfMenu`, `__ftfMenuStop`, `__ftfMenuInstance` | menu API / teardown / owner token |
| `__ftfDoors`, `__ftfDoorsStop`, `__ftfDoorsInstance` | auto-doors API / teardown / owner token |
| `__ftfRescue`, `__ftfRescueStop`, `__ftfRescueInstance` | rescue API / teardown / owner token |
| `__ftfBeastwatch`, `__ftfBeastwatchStop`, `__ftfBeastwatchInstance` | beast alert API / teardown / owner token |
| `__ftfObjectives`, `__ftfObjectivesStop`, `__ftfObjectivesInstance` | objective TP API / teardown / owner token |
| `__ftfAutoSkill`, `__ftfAutoSkillStop`, `__ftfAutoSkillInstance` | auto skillcheck API / teardown / owner token |
| `__ftfNoclip`, `__ftfNoclipStop`, `__ftfNoclipInstance` | noclip API / teardown / owner token |
| `__ftfSkillProbe`, `__ftfSkillProbeStop`, `__ftfSkillProbeInstance` | skillcheck probe API / teardown / owner token |
| `__ftfBeastRecon`, `__ftfBeastReconStop`, `__ftfBeastReconInstance` | recon API / teardown / owner token |
| `__ftfMenuPos` | saved panel position (Vector2, survives reloads) |

`_G` persists across executions but is lost when the client process ends (rejoin), so a
rejoin requires re-dispatching every script.

---

## 10. Open questions

- [ ] **Real capture test.** `T` is verified only in simulation. Still unconfirmed inside
      a live pod. Diagnostics to look for:
      - `[FTF-ANTIFREEZE] break free (N) pod=FreezePod` → key fired, pod found
      - `[FTF-ANTIFREEZE] moved out of the pod (try N)` → hard escape used
      - **nothing at all** → keypress never reached the script; next step is a raw input
        path that bypasses `InputBegan` / `gameProcessed` entirely
      - line appears but you end up back in the pod → raise the teleport retry budget
        (currently 5) and `ReleaseTicks` (currently 180)
- [ ] Whether the hack skillcheck is fully normal again after the hook teardown.
- [ ] **Beast round capture.** `beast_recon.lua` is ready and passive; it needs a live
      beast round to record `HammerEvent` / `PowersEvent` payload schemas.
- [ ] **Menu live test.** `menu.lua` compiles and mirrors the proven APIs, but has not
      been loaded in-client yet: check drag, toggle resync after `Q`/`T`, slider live
      apply while boosted, and that the `x` chip still wins the click over the drag bar.
- [ ] **Auto doors live semantics.** `doors.lua` is mock-verified; confirm on one real
      door whether a press opens-and-stays or toggles. If it toggles/auto-closes, set
      `ReopenAfter` and test `FireOnce = false`.
- [ ] **Rescue live semantics.** `rescue.lua` is mock-verified; confirm whether
      `Input/Trigger` on `FreezePod.Event` frees a teammate in one press or needs the
      `Input/Action` hold. Tune `UseActionHold` / `HoldTicks` from that result.
- [x] **Rescue has no range check** (live, 2026-10-30): the pod trigger works cross-map.
      See §5.11 — report to the owner with the §11 freeze findings.
- [ ] **Camp guard / beast watch live pass.** Both are mock-verified. Confirm the banner
      distance/arrow matches the beast's real position and that camp guard frees after
      `CampDelay` while the beast sits on a pod.
- [ ] **Teleport acceptance.** Confirm the server keeps a pod-side `CFrame` teleport
      (no snap-back) before relying on it in a chase.
- [ ] **Auto skillcheck.** Waiting on one `skillcheck_probe.lua` run: which widgets appear,
      whether `Force()` (`MinigameResult = true`) is accepted, and where the success zone
      lives. Then the auto-hit can be written against real instance names.
- [ ] `CandyCurrencyEvent` / `Halloween2026Event` replay and claim tests.
- [ ] Shop / inventory opcodes on `RemoteEvent` (direction now known: client→server).
- [ ] Whether `DetectedEvent` reacts to invalid remote traffic (throwaway account,
      private server).
- [x] `RemoteEvent` client→server direction and `Input` opcode vocabulary — see §4.
- [x] Beast identification, HSV/colour computer state — see §2.
- [x] Computer hack acceleration — **not possible**, see §4.3.
- [x] Capture bypass mechanics — see §3, §5.3.
- [x] `hud_unload.lua` — shipped, plus orphan-GUI sweep.
- [x] ESP master switch (`CONFIG.Enabled`) and recon/menu/full loader — see §5.5–§5.7.

---

## 11. Verification snippets

### Health check

```lua
local lp = game.Players.LocalPlayer
local ok, core = pcall(function() return game:GetService("CoreGui") end)

print("esp="   .. tostring(ok and core:FindFirstChild("FTF_ESP") ~= nil))
print("hud="   .. tostring(ok and core:FindFirstChild("FTF_HUD") ~= nil))
print("speed=" .. tostring(_G.__ftfSpeed ~= nil) ..
      " boosted=" .. tostring(_G.__ftfSpeed and _G.__ftfSpeed.IsBoosted()) ..
      " base=" .. tostring(_G.__ftfSpeed and _G.__ftfSpeed.Base()))
print("af="    .. tostring(_G.__ftfAntiFreeze ~= nil) ..
      " pods=" .. tostring(_G.__ftfAntiFreeze and #_G.__ftfAntiFreeze.Pods()))

local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
print("ws=" .. tostring(hum and hum.WalkSpeed))

local s = lp:FindFirstChild("TempPlayerStatsModule")
print("captured=" .. tostring(s and s.Captured and s.Captured.Value) ..
      " ragdoll="  .. tostring(s and s.Ragdoll and s.Ragdoll.Value) ..
      " progress=" .. tostring(s and s.ActionProgress and s.ActionProgress.Value))
print("hooks: ah=" .. tostring(_G.__ahStop) ..
      " nc=" .. tostring(_G.__ncRestore) ..
      " fs=" .. tostring(_G.__fsProbeRestore))
```

All hook handles should print `nil`. If any is non-nil, run the cleanup:

```lua
if _G.__ahStop then _G.__ahStop() end
if _G.__ncRestore then _G.__ncRestore() end
if _G.__fsProbeRestore then _G.__fsProbeRestore() end
if _G.__clRestore then _G.__clRestore() end
```

### Computer state probe

```lua
local RS = game.ReplicatedStorage
local map = RS.CurrentMap.Value
local root = game.Players.LocalPlayer.Character.HumanoidRootPart

local best, dist, trig
for _, c in ipairs(map:GetChildren()) do
  if c.Name == "ComputerTable" then
    for _, d in ipairs(c:GetChildren()) do
      if d.Name:sub(1, 15) == "ComputerTrigger" then
        local dd = (d.Position - root.Position).Magnitude
        if dd < (dist or math.huge) then dist, best, trig = dd, c, d end
      end
    end
  end
end

print(string.format("nearest=%.1f screen=%s event=%s",
  dist,
  best and best.Screen.Color:ToHex(),
  tostring(trig and trig:FindFirstChild("Event") ~= nil)))
```

`287f47`-family = solved; `0d69ac` = unsolved.

---

*End of knowledge base.*
