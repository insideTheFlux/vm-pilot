# vm-pilot

See and drive a Hyper-V guest from the Windows host: take a screenshot, move and click the mouse, type, press
keys. One PowerShell script, nothing to install in the guest.

It talks to Hyper-V's own WMI interface (`root\virtualization\v2`). The mouse and keyboard events reach the
guest as virtual hardware, so they work where in-guest tools do not:

- **Wayland** sessions (GNOME blocks `xdotool`-style input and screenshots from other apps),
- login screens, lock screens, installers and recovery shells,
- a guest with no network, no SSH and no guest additions.

Nothing is sent to the host's own keyboard or mouse, so it never lands in whatever window you have open.

## Requirements

- Windows with Hyper-V, PowerShell 5.1 or newer.
- An **elevated** PowerShell, or an account in the "Hyper-V Administrators" group.
- A running VM (any generation, any guest OS).

## Use

```powershell
.\vm-pilot.ps1 list                          # the VMs and their state
.\vm-pilot.ps1 info  -VM Ubuntu              # screen size
.\vm-pilot.ps1 shot  -VM Ubuntu -Out s.png   # the guest's screen as a PNG
.\vm-pilot.ps1 click 300 200 -VM Ubuntu      # left click at pixel 300,200 (-Button right, -Double)
.\vm-pilot.ps1 drag 220 250 620 480 -VM Ubuntu
.\vm-pilot.ps1 scroll -3 -VM Ubuntu          # wheel notches, positive = up, negative = down
.\vm-pilot.ps1 type "hello" -VM Ubuntu       # printable ASCII
.\vm-pilot.ps1 key Ctrl+Alt+T -VM Ubuntu     # a key or a combination
```

`-VM` can be left out when exactly one VM is running. Coordinates are pixels of the guest's screen, origin top
left; the script reads the size from Hyper-V and refuses points outside it.

Keys: letters, digits, `F1`-`F12`, `Enter`, `Esc`, `Tab`, `Space`, `Backspace`, `Delete`, `Home`, `End`,
`PageUp`, `PageDown`, `Up`, `Down`, `Left`, `Right`, and the modifiers `Ctrl`, `Shift`, `Alt`, `Super` (Win).
A combination presses the modifiers, taps the last key, then releases in reverse order.

Exit codes: `0` done, `1` bad arguments (nothing was sent), `2` VM not found or not running, `3` Hyper-V
refused or failed.

The pause before a click (`-HoverMs`, default 450 ms) matters: toolkits such as GTK and egui want to see the
pointer arrive before a press lands on a widget, and an instant move-and-click is often ignored.

## How it works, and what we found out the hard way

| Job | WMI class and method |
|---|---|
| Screenshot | `Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage` returns raw **RGB565** bytes, saved here as a 16bpp bitmap and then as PNG. The pointer is drawn in it. |
| Screen size | `Msvm_VideoHead.CurrentHorizontalResolution` / `CurrentVerticalResolution` |
| Mouse | `Msvm_SyntheticMouse`: `SetAbsolutePosition`, `SetButtonState`, `SetScrollPosition` |
| Keyboard | `Msvm_Keyboard`: `PressKey`, `ReleaseKey` (Windows virtual-key codes) |

- The synthetic mouse takes the guest's **own pixel coordinates**, not a 0 to 32767 scale. Feeding it 0-32767
  values just clamps the pointer to the bottom-right corner.
- The **left button is `ButtonIndex` 1**. `ClickButton` alone did nothing in our tests; an explicit press, a
  150 ms pause and a release works.
- The wheel counts in units of **120 per notch**, like a real mouse (a delta of 8 does nothing visible).
  `scroll N` multiplies for you.
- Hyper-V's `Msvm_Keyboard.TypeText` **garbles text** (our `echo hello` arrived as `d`). `type` therefore
  presses one key at a time, with Shift for capitals and symbols (US layout).
- WMI parameter names are not what you would guess (`ButtonIndex`, `HorizontalPosition`, `AsciiText`,
  `KeyCode`). Read them with `(Get-CimClass -Namespace root\virtualization\v2 -ClassName Msvm_SyntheticMouse).CimClassMethods['SetButtonState'].Parameters`.
- PowerShell variable names are case-insensitive: a script-level `$vm = ...` silently overwrites a typed
  `$VM` parameter. The parameter here is `$VmName` with `-VM` as an alias.

## Limits

- Tested on a Windows 11 Pro host with a Generation 2 Ubuntu 24.04 guest at 1024x768, under GNOME on both X11
  and Wayland. Other guests and resolutions should work but are not tested.
- The screenshot is a snapshot of the guest's display at its current resolution: no video, and small text can
  be hard to read.
- `type` sends printable ASCII as key presses for a **US keyboard layout**; other layouts in the guest are
  untested. Newlines and tabs are not typed: use `key Enter` and `key Tab`. There is no clipboard transfer.
- It acts on whatever has focus in the guest. A locked screen receives your keystrokes like anything else:
  take a screenshot before you type.
- Not affiliated with or endorsed by Microsoft. "Hyper-V" is their trademark.

## Licence

MIT. See `LICENSE`.
