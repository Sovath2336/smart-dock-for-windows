<div align="center">

# 🧊 Smart Dock for Windows

### Your taskbar's open windows, folded into one tiny floating grid.

**Pure PowerShell · Zero installs · One file · ~300 lines**

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![Status](https://img.shields.io/badge/status-hacky%20%26%20happy-orange)

</div>

---

## ✨ What is it?

The Windows taskbar is a wide strip that is always there, always growing, and always asking for attention.
**Smart Dock** takes every open window and tucks it into a compact, draggable, square grid that floats in the corner of your screen, and **removes those windows' buttons from the taskbar** so the clutter actually goes away.

```
 ┌──────────────────────────────┐
 │ 6 windows            [ HIDE ]│   ← drag me · right-click me · collapse me
 ├──────────────────────────────┤
 │  ✂️      🌐      ▮_      🌐   │
 │ GridSnip  Repo…  Terminal  Docs│
 │                              │
 │  📈      ▮_                  │
 │ ASYCUDA  Build…              │
 │                              │
 └──────────────────────────────┘
        collapsed:  [ 6 windows  [ SHOW ] ]
```

## 🚀 Features

| | |
|---|---|
| 🧱 **Square icon grid** | A tidy 4 × 4 grid of live window icons with short titles. Scroll with the mouse wheel when you have more. |
| 🫥 **Truly removes taskbar buttons** | Windows in the dock are hidden from the taskbar via the shell's `ITaskbarList` API. They are not just duplicated. |
| 🔄 **Send it back any time** | Right-click a tile → **Show in taskbar**. The window moves out of the dock and back to the taskbar. |
| 📥 **Return everything** | Right-click the top strip → **Return N taskbar window(s) to dock**. |
| 🪗 **Collapsible** | One big **HIDE / SHOW** button shrinks the dock to a slim pill. It stays anchored to its bottom-left corner. |
| 🖱️ **Draggable** | Grab the top strip and put it anywhere. |
| ⚡ **Live** | Opens, closes, renames and new windows are picked up automatically (every ~0.7 s). The active window is outlined in blue. |
| 🛟 **Safe exit** | Closing the dock restores every taskbar button it hid. A `-Restore` switch is there if the dock ever crashes. |
| 🪶 **No install** | One `.ps1` file. No Python, no .NET SDK, no admin rights. |

## 🏁 Quick start

```powershell
git clone https://github.com/Sovath2336/smart-dock-for-windows.git
cd smart-dock-for-windows

powershell -STA -ExecutionPolicy Bypass -File .\SmartDock.ps1
```

Want it silent, with no console window hanging around?

```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','.\SmartDock.ps1'
```

> The `-STA` flag matters. WinForms and the taskbar COM interface both need a single-threaded apartment.

## 🔁 Start at logon

Press `Win + R`, run `shell:startup`, and drop in a shortcut with:

- **Target:** `powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path	o\SmartDock.ps1"`
- **Run:** Minimized

Launching it twice is safe: a second instance exits immediately. To stop autostart, delete the shortcut. To stop the running dock, right-click its top strip → **Exit dock**.

## 🎮 Controls

| Action | What happens |
|---|---|
| **Left-click a tile** | Brings the window to the front. Restores it if it is minimized. |
| **Right-click a tile** | `Close window` · `Minimize` · `Show in taskbar` |
| **Drag the top strip** | Moves the dock. |
| **HIDE / SHOW button** | Collapses or expands the dock. |
| **Right-click the top strip** | `Collapse / Expand` · `Return … to dock` · `Auto-hide taskbar` · `Exit dock` |
| **Mouse wheel** | Scrolls the grid by one row. |

## 🛠️ How it works

1. **Find windows.** `EnumWindows` collects top-level windows, then filters them the way the taskbar does: visible, no owner, not a tool window (unless flagged `WS_EX_APPWINDOW`), non-empty title, and not DWM-cloaked. The cloaked check drops the ghost UWP frames.
2. **Get icons.** `WM_GETICON` (big, then small), then the window class icon, then the icon from the owning executable.
3. **Hide from the taskbar.** `ITaskbarList::DeleteTab` is called for every window in the dock, re-applied each tick because Explorer likes to re-add buttons. `AddTab` puts them back.
4. **Draw.** The dock is a borderless, top-most, non-activating tool window painted with plain GDI+. It never steals focus and never shows up in the taskbar or Alt-Tab itself.

## 🧯 Recovery

If the dock was killed hard (task manager, power loss, crash) and some windows are still missing from the taskbar:

```powershell
powershell -STA -ExecutionPolicy Bypass -File .\SmartDock.ps1 -Restore
```

This puts back the taskbar button of every eligible window and exits. Windows are never altered. Only the taskbar button is toggled.

## ⚠️ Honest limitations

- **Pinned apps keep their pinned icon.** Windows has no API to remove a pinned launcher. Only the *running-window* buttons are removed.
- **It does not remember anything between runs.** Position and collapsed state reset on restart. The dock always starts at the bottom-left.
- **Autostart is manual.** See [Start at logon](#-start-at-logon) below.
- **Primary monitor only** for the initial placement.
- **Not a shell replacement.** Windows can still re-add a button for a moment (for example when a window changes state). The dock removes it again on the next tick.

## 🗺️ Ideas / roadmap

- [ ] Remember position and collapsed state
- [ ] Optional start-at-logon switch
- [ ] Per-app pinning and ordering
- [ ] Multi-monitor and edge snapping
- [ ] Light / dark / accent themes
- [ ] Hotkey to toggle the dock

PRs and ideas are welcome.

## 📄 License

Choose a license for the repo (MIT is a common pick for scripts like this) and add a `LICENSE` file.

---

<div align="center">
<sub>Built with PowerShell, a little COM, and a strong dislike of cluttered taskbars.</sub>
</div>
