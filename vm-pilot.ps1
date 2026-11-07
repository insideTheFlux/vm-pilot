<#
.SYNOPSIS
  See and drive a Hyper-V guest from the Windows host: screenshot, mouse, keyboard.

.DESCRIPTION
  vm-pilot talks to Hyper-V's own WMI interface (root\virtualization\v2). Nothing is installed in the
  guest and nothing is sent to the host's keyboard or mouse: the input reaches the guest as virtual
  hardware, so it works in Wayland sessions, login screens and installers, where tools such as
  xdotool cannot.

  Run it from an elevated PowerShell (or as a member of the "Hyper-V Administrators" group).

.EXAMPLE
  .\vm-pilot.ps1 list
  .\vm-pilot.ps1 info  -VM Ubuntu
  .\vm-pilot.ps1 shot  -VM Ubuntu -Out screen.png
  .\vm-pilot.ps1 click 300 200 -VM Ubuntu
  .\vm-pilot.ps1 drag 220 250 620 480 -VM Ubuntu
  .\vm-pilot.ps1 type "hello" -VM Ubuntu
  .\vm-pilot.ps1 key Ctrl+Alt+T -VM Ubuntu
  .\vm-pilot.ps1 scroll -3 -VM Ubuntu

.NOTES
  Exit codes: 0 done, 1 bad arguments, 2 VM not found or not running, 3 Hyper-V refused or failed.
  Licence: MIT. Not affiliated with Microsoft.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string]$Command = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]]$Rest = @(),
  [Alias('VM')] [string]$VmName = '',
  [string]$Out = '',
  [ValidateSet('left', 'right', 'middle')] [string]$Button = 'left',
  [switch]$Double,
  [int]$HoverMs = 450
)

$ErrorActionPreference = 'Stop'
$ns = 'root\virtualization\v2'

function Fail([string]$message, [int]$code) {
  [Console]::Error.WriteLine("vm-pilot: $message")
  exit $code
}

function Usage {
@'
vm-pilot <command> [arguments] [-VM name] [options]

  list                          the VMs on this host and their state
  info                          screen size and state of the VM
  shot [-Out file.png]          save the guest's screen as a PNG (default: vm-pilot-shot.png)
  move X Y                      put the pointer at pixel X,Y of the guest screen
  click X Y [-Button left|right|middle] [-Double]
  drag X1 Y1 X2 Y2             press at X1,Y1, move, release at X2,Y2
  scroll N                      wheel notches (positive up, negative down; at most 100)
  type "text"                   type ASCII text
  key Name[+Name...]            press a key or a combination, e.g. Enter, Esc, Super, Ctrl+Alt+T, Ctrl+Shift+2

Options: -VM name (optional when exactly one VM is running), -Out file, -HoverMs 450 (pause before a click).
Keys: letters, digits, F1-F12, Enter, Esc, Tab, Space, Backspace, Delete, Home, End, PageUp, PageDown,
      Up, Down, Left, Right, Ctrl, Shift, Alt, Super (Win).
Exit codes: 0 done, 1 bad arguments, 2 VM not found or not running, 3 Hyper-V refused or failed.
'@
}

function Get-Vms {
  Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "Caption='Virtual Machine'"
}

function Resolve-Vm([string]$name) {
  $all = @(Get-Vms)
  if ($name) {
    $hit = @($all | Where-Object { $_.ElementName -eq $name })
    if ($hit.Count -eq 0) { Fail "no VM named '$name' (try: vm-pilot list)" 2 }
    $vm = $hit[0]
  } else {
    $running = @($all | Where-Object { $_.EnabledState -eq 2 })
    if ($running.Count -ne 1) { Fail "say which VM with -VM (running VMs: $($running.Count); try: vm-pilot list)" 2 }
    $vm = $running[0]
  }
  if ($vm.EnabledState -ne 2) { Fail "VM '$($vm.ElementName)' is not running" 2 }
  return $vm
}

function Get-ScreenSize($vm) {
  $vh = Get-CimInstance -Namespace $ns -ClassName Msvm_VideoHead -Filter "SystemName='$($vm.Name)'" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($vh -and $vh.CurrentHorizontalResolution -gt 0 -and $vh.CurrentVerticalResolution -gt 0) {
    return @([int]$vh.CurrentHorizontalResolution, [int]$vh.CurrentVerticalResolution)
  }
  return @(1024, 768)
}

function Get-Device($vm, [string]$class) {
  $d = Get-CimInstance -Namespace $ns -ClassName $class -Filter "SystemName='$($vm.Name)'" | Select-Object -First 1
  if (-not $d) { Fail "the VM has no $class device (is it fully started?)" 3 }
  return $d
}

function Invoke-Wmi($instance, [string]$method, [hashtable]$arguments) {
  $r = Invoke-CimMethod -InputObject $instance -MethodName $method -Arguments $arguments
  if ($null -ne $r.ReturnValue -and $r.ReturnValue -ne 0) { Fail "Hyper-V returned $($r.ReturnValue) for $method" 3 }
  return $r
}

function ToInt([string]$text, [string]$what) {
  $n = 0
  if (-not [int]::TryParse($text, [ref]$n)) { Fail "$what must be a whole number, got '$text'" 1 }
  return $n
}

function Check-Point($vm, [int]$x, [int]$y) {
  $size = Get-ScreenSize $vm
  if ($x -lt 0 -or $y -lt 0 -or $x -ge $size[0] -or $y -ge $size[1]) {
    Fail "point $x,$y is outside the $($size[0])x$($size[1]) screen" 1
  }
}

# ---- screen ----
function Save-Shot($vm, [string]$path) {
  $size = Get-ScreenSize $vm
  $w = $size[0]; $h = $size[1]
  $mgmt = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
  $r = Invoke-CimMethod -InputObject $mgmt -MethodName GetVirtualSystemThumbnailImage -Arguments @{ TargetSystem = $vm; WidthPixels = [uint16]$w; HeightPixels = [uint16]$h }
  if ($r.ReturnValue -ne 0 -or -not $r.ImageData) { Fail "Hyper-V gave no picture (return value $($r.ReturnValue))" 3 }
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
  try {
    $bd = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $w, $h), [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
    $count = [Math]::Min($r.ImageData.Length, $bd.Stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy([byte[]]$r.ImageData, 0, $bd.Scan0, $count)
    $bmp.UnlockBits($bd)
    $full = [System.IO.Path]::GetFullPath($path)
    $bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $bmp.Dispose() }
  return $full
}

# ---- mouse (the synthetic mouse takes the guest's own pixel coordinates; ButtonIndex 1 = left) ----
function Move-Pointer($vm, [int]$x, [int]$y) {
  Check-Point $vm $x $y
  $null = Invoke-Wmi (Get-Device $vm 'Msvm_SyntheticMouse') 'SetAbsolutePosition' @{ HorizontalPosition = [int32]$x; VerticalPosition = [int32]$y }
}
function Button-Index([string]$name) {
  switch ($name) { 'left' { 1 } 'right' { 2 } 'middle' { 3 } default { 1 } }
}
function Set-Button($vm, [int]$index, [bool]$down) {
  $null = Invoke-Wmi (Get-Device $vm 'Msvm_SyntheticMouse') 'SetButtonState' @{ ButtonIndex = [uint32]$index; IsDown = $down }
}
function Hover-To($vm, [int]$x, [int]$y) {
  # Toolkits such as egui and GTK want to see the pointer arrive before a press lands on a widget.
  $size = Get-ScreenSize $vm
  $near = [Math]::Min($x + 6, $size[0] - 1)
  Move-Pointer $vm $near $y
  Start-Sleep -Milliseconds ([Math]::Max(100, $HoverMs / 2))
  Move-Pointer $vm $x $y
  Start-Sleep -Milliseconds $HoverMs
}
function Click-At($vm, [int]$x, [int]$y, [string]$which, [bool]$twice) {
  Hover-To $vm $x $y
  $i = Button-Index $which
  $times = 1; if ($twice) { $times = 2 }
  for ($k = 0; $k -lt $times; $k++) {
    Set-Button $vm $i $true
    Start-Sleep -Milliseconds 150
    Set-Button $vm $i $false
    Start-Sleep -Milliseconds 120
  }
}
function Drag-From($vm, [int]$x1, [int]$y1, [int]$x2, [int]$y2) {
  Hover-To $vm $x1 $y1
  Set-Button $vm 1 $true
  Start-Sleep -Milliseconds 250
  for ($s = 1; $s -le 4; $s++) {
    Move-Pointer $vm ([int]($x1 + ($x2 - $x1) * $s / 4)) ([int]($y1 + ($y2 - $y1) * $s / 4))
    Start-Sleep -Milliseconds 150
  }
  Start-Sleep -Milliseconds 250
  Set-Button $vm 1 $false
}

# ---- keyboard (Windows virtual-key codes) ----
$VK = @{
  'ENTER' = 0x0D; 'RETURN' = 0x0D; 'ESC' = 0x1B; 'ESCAPE' = 0x1B; 'TAB' = 0x09; 'SPACE' = 0x20; 'BACKSPACE' = 0x08
  'DELETE' = 0x2E; 'DEL' = 0x2E; 'HOME' = 0x24; 'END' = 0x23; 'PAGEUP' = 0x21; 'PAGEDOWN' = 0x22
  'UP' = 0x26; 'DOWN' = 0x28; 'LEFT' = 0x25; 'RIGHT' = 0x27
  'CTRL' = 0x11; 'CONTROL' = 0x11; 'SHIFT' = 0x10; 'ALT' = 0x12; 'SUPER' = 0x5B; 'WIN' = 0x5B
}
for ($n = 1; $n -le 12; $n++) { $VK["F$n"] = 0x6F + $n }
$Modifiers = @('CTRL', 'CONTROL', 'SHIFT', 'ALT', 'SUPER', 'WIN')

function Key-Code([string]$name) {
  $u = $name.Trim().ToUpperInvariant()
  if ($VK.ContainsKey($u)) { return [int]$VK[$u] }
  if ($u.Length -eq 1 -and $u -match '[A-Z0-9]') { return [int][char]$u }
  Fail "unknown key '$name'" 1
}
function Press-Combo($vm, [string]$combo) {
  $parts = @($combo.Split('+') | Where-Object { $_.Trim() -ne '' })
  if ($parts.Count -eq 0) { Fail 'key needs a key name' 1 }
  $codes = @($parts | ForEach-Object { Key-Code $_ })   # check every name before pressing anything
  $kb = Get-Device $vm 'Msvm_Keyboard'
  $mods = @(); $main = $null
  for ($i = 0; $i -lt $parts.Count; $i++) {
    if ($Modifiers -contains $parts[$i].Trim().ToUpperInvariant() -and $i -lt $parts.Count - 1) { $mods += $codes[$i] } else { $main = $codes[$i] }
  }
  foreach ($c in $mods) { $null = Invoke-Wmi $kb 'PressKey' @{ KeyCode = [uint32]$c }; Start-Sleep -Milliseconds 40 }
  $null = Invoke-Wmi $kb 'PressKey' @{ KeyCode = [uint32]$main }
  Start-Sleep -Milliseconds 80
  $null = Invoke-Wmi $kb 'ReleaseKey' @{ KeyCode = [uint32]$main }
  [array]::Reverse($mods)
  foreach ($c in $mods) { Start-Sleep -Milliseconds 40; $null = Invoke-Wmi $kb 'ReleaseKey' @{ KeyCode = [uint32]$c } }
}

# Typing goes through single key presses (US layout): Hyper-V's own TypeText method garbled text in our tests.
$Shifted = @{
  ')' = '0'; '!' = '1'; '@' = '2'; '#' = '3'; '$' = '4'; '%' = '5'; '^' = '6'; '&' = '7'; '*' = '8'; '(' = '9'
  ':' = ';'; '+' = '='; '<' = ','; '_' = '-'; '>' = '.'; '?' = '/'; '~' = '`'; '{' = '['; '|' = '\'; '}' = ']'; '"' = "'"
}
$Oem = @{ ';' = 0xBA; '=' = 0xBB; ',' = 0xBC; '-' = 0xBD; '.' = 0xBE; '/' = 0xBF; '`' = 0xC0; '[' = 0xDB; '\' = 0xDC; ']' = 0xDD; "'" = 0xDE }

function Char-Keys([char]$c) {
  # returns @(virtual-key code, needs shift)
  $s = [string]$c
  if ($c -ge 'a' -and $c -le 'z') { return @([int][char]$s.ToUpperInvariant(), $false) }
  if ($c -ge 'A' -and $c -le 'Z') { return @([int]$c, $true) }
  if ($c -ge '0' -and $c -le '9') { return @([int]$c, $false) }
  if ($c -eq ' ') { return @(0x20, $false) }
  if ($Oem.ContainsKey($s)) { return @([int]$Oem[$s], $false) }
  if ($Shifted.ContainsKey($s)) {
    $base = $Shifted[$s]
    if ($base -match '^[0-9]$') { return @([int][char]$base, $true) }
    return @([int]$Oem[$base], $true)
  }
  Fail "cannot type the character '$s'" 1
}
function Type-Text($vm, [string]$text) {
  $plan = @($text.ToCharArray() | ForEach-Object { , (Char-Keys $_) })   # check every character before sending any
  $kb = Get-Device $vm 'Msvm_Keyboard'
  foreach ($k in $plan) {
    if ($k[1]) { $null = Invoke-Wmi $kb 'PressKey' @{ KeyCode = [uint32]0x10 } }
    $null = Invoke-Wmi $kb 'PressKey' @{ KeyCode = [uint32]$k[0] }
    Start-Sleep -Milliseconds 15
    $null = Invoke-Wmi $kb 'ReleaseKey' @{ KeyCode = [uint32]$k[0] }
    if ($k[1]) { $null = Invoke-Wmi $kb 'ReleaseKey' @{ KeyCode = [uint32]0x10 } }
    Start-Sleep -Milliseconds 20
  }
}

# ---- main ----
try {
  $cmd = $Command.ToLowerInvariant()
  switch ($cmd) {
    { $_ -in 'help', '-h', '--help', '/?' } { Usage; exit 0 }
    'list' {
      Get-Vms | Sort-Object ElementName | ForEach-Object {
        $state = switch ($_.EnabledState) { 2 { 'running' } 3 { 'off' } 32768 { 'paused' } 32769 { 'saved' } default { "state $($_.EnabledState)" } }
        '{0,-30} {1}' -f $_.ElementName, $state
      }
      exit 0
    }
    'info' {
      $vm = Resolve-Vm $VmName; $s = Get-ScreenSize $vm
      "VM:     $($vm.ElementName)"; "State:  running"; "Screen: $($s[0]) x $($s[1])"; exit 0
    }
    'shot' {
      $vm = Resolve-Vm $VmName
      $path = $Out; if (-not $path) { $path = 'vm-pilot-shot.png' }
      Save-Shot $vm $path; exit 0
    }
    'move' {
      if ($Rest.Count -ne 2) { Fail 'move needs X Y' 1 }
      $vm = Resolve-Vm $VmName; Move-Pointer $vm (ToInt $Rest[0] 'X') (ToInt $Rest[1] 'Y'); exit 0
    }
    'click' {
      if ($Rest.Count -ne 2) { Fail 'click needs X Y' 1 }
      $vm = Resolve-Vm $VmName; Click-At $vm (ToInt $Rest[0] 'X') (ToInt $Rest[1] 'Y') $Button ([bool]$Double); exit 0
    }
    'drag' {
      if ($Rest.Count -ne 4) { Fail 'drag needs X1 Y1 X2 Y2' 1 }
      $vm = Resolve-Vm $VmName
      $a = @($Rest | ForEach-Object { ToInt $_ 'coordinate' })
      Check-Point $vm $a[0] $a[1]; Check-Point $vm $a[2] $a[3]
      Drag-From $vm $a[0] $a[1] $a[2] $a[3]; exit 0
    }
    'scroll' {
      if ($Rest.Count -ne 1) { Fail 'scroll needs a number of steps' 1 }
      $vm = Resolve-Vm $VmName
      $notches = ToInt $Rest[0] 'steps'
      if ([Math]::Abs($notches) -gt 100) { Fail 'scroll takes at most 100 notches at a time' 1 }
      # the synthetic wheel counts in units of 120 per notch, like a real mouse
      $null = Invoke-Wmi (Get-Device $vm 'Msvm_SyntheticMouse') 'SetScrollPosition' @{ ScrollPositionDelta = [int32]($notches * 120) }; exit 0
    }
    'type' {
      if ($Rest.Count -lt 1) { Fail 'type needs the text' 1 }
      $text = $Rest -join ' '
      if ($text -notmatch '^[\x20-\x7E]*$') { Fail 'type sends printable ASCII only' 1 }
      $vm = Resolve-Vm $VmName
      Type-Text $vm $text; exit 0
    }
    'key' {
      if ($Rest.Count -ne 1) { Fail 'key needs one key or combination, e.g. Ctrl+Alt+T' 1 }
      $vm = Resolve-Vm $VmName; Press-Combo $vm $Rest[0]; exit 0
    }
    default { Fail "unknown command '$Command' (try: vm-pilot help)" 1 }
  }
} catch {
  Fail $_.Exception.Message 3
}
