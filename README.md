# FTF // Mod Menu

Client-side research and QoL tooling for **Flee the Facility** (Roblox place
`893973440`). Built for an authorized client-side pentest and for private use on
servers you control or have permission to test.

> **Scope:** this is a client-side toolkit. It never executes server code and does not
> hook `FireServer` (that breaks the hack skillcheck — see `docs/LEARNINGS.md` §7.2).
> Findings and the server-hardening notes live in `docs/`.

---

## Features

| Tab | Feature | Key |
|---|---|---|
| **PLAYER** | Player/beast/computer ESP overlay | — |
| | Computer markers toggle + hide-solved | — |
| | Beast alert banner (distance, direction, power %) | — |
| | Beast remote payload logger | — |
| **MOVE** | Speed boost, 1.5–5.0× slider | `Q` |
| | Noclip (collision bypass, restores on off) | `V` |
| | Teleport to nearest unsolved computer | `H` |
| **RESCUE** | Auto break-free + break-free now | `T` |
| | Auto doors (game's own `Input/Trigger`) | — |
| | Auto rescue nearby / camp guard (cross-map) | — |
| | Teleport to a frozen teammate / free nearest | `Y` |
| **SYSTEM** | Auto skillcheck (`TimingCircle` angle hit) | — |
| | Skillcheck GUI dump | — |
| | Reload modules / unload tools | — |

Menu: `RightShift` · drag the title bar · `_` minimise · `x` close.

- Toggle state resyncs from the module APIs ~10 Hz, so keybinds and menu never disagree.
- If a module is missing, its row loads it on first click from the local server.
- Every module owns an instance ID and tears itself down when replaced — hot reload is safe.

---

## Quick start

Requirements: Windows, Node.js, and a Roblox executor with `HttpGet` + `loadstring`
(the project is developed against **Potassium**).

```bash
# from the repo root
node serve.js
```

Serve output:

```
serving <repo>
inject: loadstring(game:HttpGet("http://127.0.0.1:8765/lua/loaders/ftf_loader.lua"))()
```

Paste that line into the executor and execute. `RightShift` opens the menu.

### Auto-load on attach (Potassium)

Create/edit:

```
%LOCALAPPDATA%\Potassium\autoexec\ftf.luau
```

```lua
pcall(function()
    local src = game:HttpGet("http://127.0.0.1:8765/lua/loaders/ftf_loader.lua")
    loadstring(src, "=ftf_loader.lua")()
end)
```

---

## Repository layout

```
lua/
  menu.lua                 tabbed CoreGui menu (loaded last)
  loaders/
    ftf_loader.lua         full suite: every module + menu
    ftf_suite.lua          legacy stable set: esp/speed/antifreeze/hud
  modules/
    esp.lua                player / beast / computer ESP
    speed.lua              Q speed boost from NormalWalkSpeed
    noclip.lua             V client-side collision bypass
    antifreeze.lua         T pod escape + self-rescue trigger
    unfreeze.lua           12 s aggressive emergency unfreeze
    rescue.lua             frozen-teammate list, TP, auto-free, camp guard
    doors.lua              auto-open via the game's Input/Trigger
    objectives.lua         H teleport to nearest unsolved computer
    beast_recon.lua        passive HammerEvent / PowersEvent logger
    beastwatch.lua         beast distance / direction / power banner
    skillcheck.lua         auto skillcheck (TimingCircle angle crossing)
    skillcheck_probe.lua   passive hack/minigame state logger
    hud.lua                legacy keybind HUD
  unload/                  per-module teardown scripts
  tools/
    menu_reset.lua         reset menu GUI + saved position
    reset_all.lua          stop every module and sweep GUIs
  probes/
    doors_probe.lua        door structure dump
    rescue_probe.lua       pod/CapturedTorso structure dump
    skillcheck_debug.lua   45–90 s timing-widget property logger
docs/
  LEARNINGS.md             working knowledge base + live measurements
  ATTACK_SURFACE.md        formal remote/attack-surface writeup
  REPORT.md                earlier report for a different place
serve.js                   zero-dependency local static server (port 8765)
```

---

## Module APIs

All module state is published on `_G` so the menu and your own scripts can drive it.

| Module | Handle | Teardown |
|---|---|---|
| ESP | `_G.__ftfESP` | `__ftfESPStop()` |
| Speed | `_G.__ftfSpeed` | `__ftfSpeedStop()` |
| Antifreeze | `_G.__ftfAntiFreeze` | `__ftfAntiFreezeStop()` |
| Unfreeze | `_G.__ftfUnfreeze` | `__ftfUnfreezeStop()` |
| Rescue | `_G.__ftfRescue` | `__ftfRescueStop()` |
| Doors | `_G.__ftfDoors` | `__ftfDoorsStop()` |
| Noclip | `_G.__ftfNoclip` | `__ftfNoclipStop()` |
| Objectives | `_G.__ftfObjectives` | `__ftfObjectivesStop()` |
| Beast recon | `_G.__ftfBeastRecon` | `__ftfBeastReconStop()` |
| Beast watch | `_G.__ftfBeastwatch` | `__ftfBeastwatchStop()` |
| Skillcheck | `_G.__ftfAutoSkill` | `__ftfAutoSkillStop()` |
| Probe | `_G.__ftfSkillProbe` | `__ftfSkillProbeStop()` |
| Menu | `_G.__ftfMenu` | `__ftfMenuStop()` |

Useful snippets:

```lua
_G.__ftfAutoSkill.Config.HitDelayTicks = 2      -- tune skillcheck timing
_G.__ftfRescue.Config.CampRadius = 24
_G.__ftfObjectives.TeleportNearest()
_G.__ftfMenu.Tab("rescue")
```

---

## Notes & caveats

- **Teleports** are client `CFrame` writes; if the live server adds position validation
  they will snap back.
- **Auto skillcheck** targets `PlayerGui.ScreenGui.TimingCircle`: success angle is
  `TimingBase.Rotation`, the pin sweeps through it, and the press is delayed
  `HitDelayTicks` frames (default 2).
- **Pod rescue is not range-checked** by the server (live finding, 2026-10-30), which is
  what makes camp guard and cross-map `Y` work. See `docs/LEARNINGS.md` §5.11.
- **Do not hook `FireServer`** while playing: it starves the hack skillcheck
  (`docs/LEARNINGS.md` §7.2).
- Test accounts only; respect the game's rules and the consent of other players.

---

## Research docs

- [`docs/LEARNINGS.md`](docs/LEARNINGS.md) — mechanics, protocol, measurements, traps
- [`docs/ATTACK_SURFACE.md`](docs/ATTACK_SURFACE.md) — remote inventory + test plan
- [`docs/REPORT.md`](docs/REPORT.md) — separate engagement report (place `14289388505`)

## License

This project is licensed under the [MIT License](LICENSE).
