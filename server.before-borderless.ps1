# Hanki (formerly Hanzi Farm) local server (Windows PowerShell 5.1+). The folder keeps its old name so autostart keeps working.
# Serves the app at http://localhost:8765/, saves progress to data\data.json,
# keeps daily backups in data\backups, and can add itself to Windows startup.

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
$backDir = Join-Path $dataDir 'backups'
$dataFile = Join-Path $dataDir 'data.json'
$port = 8765
$url  = "http://localhost:$port/"
$utf8 = New-Object System.Text.UTF8Encoding $false
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Shengdiao Lab.lnk'
$mediaDir = Join-Path $root 'media'

foreach ($d in @($dataDir, $backDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

# Edge first: it has Microsoft's natural voices (Xiaoxiao, Jenny...) that Chrome can't use. Chrome if Edge is missing.
function Find-Chrome {
  $paths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
  )
  foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return $p } }
  return $null
}

function Open-App {
  $browser = Find-Chrome
  # its own small browser profile, so the taskbar shows the Hanzi Farm logo without a profile picture on it
  $prof = Join-Path $env:LOCALAPPDATA 'HanziFarm\Browser'
  if ($browser -and $browser -like '*msedge.exe') { $prof = Join-Path $env:LOCALAPPDATA 'HanziFarm\Edge' }
  # a tall portrait window (816 x 1156, like a phone held upright), shrunk to fit the screen if needed
  $w = 816; $h = 1156; $pos = $null
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($wa.Height -gt 300 -and $h -gt $wa.Height - 8) { $h = $wa.Height - 8; $w = [int][Math]::Round($h * 816 / 1156) }
    $pos = "--window-position=$([int]($wa.Left + ($wa.Width - $w) / 2)),$([int]($wa.Top + 4))"
  } catch {}
  $argv = @("--app=$url", "--window-size=$w,$h", "--user-data-dir=`"$prof`"", "--no-first-run", "--no-default-browser-check", "--disable-features=msEdgeSidebarV2,msHubApps,msImplicitSignin")
  if ($pos) { $argv += $pos }
  if ($browser) { Start-Process $browser -ArgumentList $argv }
  else { Start-Process $url }
}

# Stop any older copy of this server so the newest version always takes the port.
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -like '*Shengdiao Lab*' -and $_.CommandLine -like '*server.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 700
} catch {}

# Phone access goes through Tailscale (an HTTPS address only your own devices can reach), which hands
# requests to this server from this computer but with its own host name. Taking every host name ("+")
# needs a one-time admin step, done by "Dung tren dien thoai.bat":
#   netsh http add urlacl url=http://+:8765/ sddl=D:(A;;GX;;;WD)
# Without it the server runs as before, on localhost only.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$port/")
try { $listener.Start() }
catch {
  try { $listener.Close() } catch {}
  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add($url)
  try { $listener.Start() }
  catch {
    # Already running (or port busy): just show the app.
    Open-App
    exit
  }
}

if ($args -notcontains '-quiet') { Open-App }

$static = @{
  '/'                  = @('hanzifarm.html', 'text/html; charset=utf-8', 'no-store', $false)
  '/index.html'        = @('hanzifarm.html', 'text/html; charset=utf-8', 'no-store', $false)
  '/hanzifarm.html'    = @('hanzifarm.html', 'text/html; charset=utf-8', 'no-store', $false)
  '/shengdiao-lab.html'= @('hanzifarm.html', 'text/html; charset=utf-8', 'no-store', $false)
  '/hsk.json'          = @('hsk.json', 'application/json; charset=utf-8', 'max-age=86400', $false)
  '/dict.json'         = @('dict.json.gz', 'application/json; charset=utf-8', 'max-age=604800', $true)
  '/endict.json'       = @('endict.json.gz', 'application/json; charset=utf-8', 'max-age=604800', $true)
  '/tatoeba.json'      = @('tatoeba.json.gz', 'application/json; charset=utf-8', 'max-age=604800', $true)
  '/anki-hsk46.json'   = @('anki-hsk46.json', 'application/json; charset=utf-8', 'no-store', $false)
  '/favicon.ico'       = @('hanzifarm-3.ico', 'image/x-icon', 'no-store', $false)
}

# big replies go out gzipped when the browser takes it (the page is ~4.7 MB, ~1.3 MB gzipped: matters on a phone)
$gzCache = @{}
function Gzip([byte[]]$bytes) {
  $ms = New-Object System.IO.MemoryStream
  $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
  $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
  return ,$ms.ToArray()
}
function Send($ctx, [int]$code, [string]$type, [byte[]]$bytes, [string]$cache = 'no-store', [bool]$gzip = $false, [string]$gzKey = '') {
  $res = $ctx.Response
  $res.StatusCode = $code
  $res.ContentType = $type
  $res.AddHeader('Cache-Control', $cache)
  if (-not $gzip -and $bytes.Length -gt 20000 -and ([string]$ctx.Request.Headers['Accept-Encoding']) -match 'gzip') {
    if ($gzKey) {
      if (-not $gzCache.ContainsKey($gzKey)) { $gzCache.Clear(); $gzCache[$gzKey] = (Gzip $bytes) }
      $bytes = $gzCache[$gzKey]
    } else { $bytes = Gzip $bytes }
    $gzip = $true
  }
  if ($gzip) { $res.AddHeader('Content-Encoding', 'gzip') }
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.Close()
}
function SendText($ctx, [int]$code, [string]$text, [string]$type = 'application/json; charset=utf-8') {
  Send $ctx $code $type ($utf8.GetBytes($text))
}

# a revision number for data.json (its last write time), so two devices can't overwrite each other's progress
function Get-Rev { if (Test-Path $dataFile) { return [string](Get-Item $dataFile).LastWriteTimeUtc.Ticks } else { return '0' } }
function Save-Data([string]$body) {
  # One backup per day, taken before the first save of the day.
  $today = (Get-Date).AddHours(-4).ToString('yyyy-MM-dd')
  $dayBackup = Join-Path $backDir "$today.json"
  if ((Test-Path $dataFile) -and -not (Test-Path $dayBackup)) {
    Copy-Item $dataFile $dayBackup
    Get-ChildItem $backDir -Filter '*.json' | Sort-Object Name -Descending | Select-Object -Skip 30 | Remove-Item -ErrorAction SilentlyContinue
  }
  $tmp = "$dataFile.tmp"
  [System.IO.File]::WriteAllText($tmp, $body, $utf8)
  [System.IO.File]::Copy($tmp, $dataFile, $true)
  [System.IO.File]::Delete($tmp)
}

# Sharp taskbar icon. The app runs in a Chrome window, and Chrome draws that window's taskbar icon from the
# page's tiny 16/32 px favicon, so it looks blurry. A small helper gives the window the real icon at the
# screen's size, and tags it (plus the shortcuts) as "Hanzi Farm" so a pinned shortcut and the window share one button.
$iconCs = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
public static class HFIcon {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr hi, string name, uint type, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore { void GetCount(out uint c); void GetAt(uint i, out PKEY k); void GetValue(ref PKEY k, out PV v); void SetValue(ref PKEY k, ref PV v); void Commit(); }
  [StructLayout(LayoutKind.Sequential, Pack = 4)] struct PKEY { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Explicit, Size = 24)] struct PV { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
  [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class CShellLink { }
  static readonly Guid AUM = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
  static Dictionary<uint, IntPtr[]> icons = new Dictionary<uint, IntPtr[]>();
  static IntPtr[] IconsFor(string ico, uint dpi) {
    IntPtr[] r;
    if (icons.TryGetValue(dpi, out r)) return r;
    int small = (int)Math.Round(16.0 * dpi / 96), big = (int)Math.Round(48.0 * dpi / 96);
    r = new IntPtr[] { LoadImage(IntPtr.Zero, ico, 1, small, small, 0x10), LoadImage(IntPtr.Zero, ico, 1, big, big, 0x10) };
    icons[dpi] = r; return r;
  }
  static void SetStr(IPropertyStore ps, uint pid, string v) {
    PKEY k = new PKEY(); k.fmtid = AUM; k.pid = pid;
    PV pv = new PV(); pv.vt = 31; pv.p = Marshal.StringToCoTaskMemUni(v);
    try { ps.SetValue(ref k, ref pv); } finally { Marshal.FreeCoTaskMem(pv.p); }
  }
  static void TagWindow(IntPtr h, string ico, string relaunch, string appId) {
    Guid iid = typeof(IPropertyStore).GUID; IPropertyStore ps;
    if (SHGetPropertyStoreForWindow(h, ref iid, out ps) != 0 || ps == null) return;
    try {
      SetStr(ps, 2, relaunch); SetStr(ps, 3, ico + ",0"); SetStr(ps, 4, "Hanki"); SetStr(ps, 5, appId);
    } finally { Marshal.ReleaseComObject(ps); }
  }
  // every Hanzi Farm window: real icon at the right size, and the Hanzi Farm identity
  public static int Apply(string title, string ico, string relaunch, string appId) {
    List<IntPtr> found = new List<IntPtr>();
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      StringBuilder t = new StringBuilder(64), c = new StringBuilder(64);
      GetClassName(h, c, 64);
      if (c.ToString() == "Chrome_WidgetWin_1") { GetWindowText(h, t, 64); if (t.ToString() == title) found.Add(h); }
      return true;
    }, IntPtr.Zero);
    int n = 0;
    foreach (IntPtr h in found) {
      uint dpi = 96; try { dpi = GetDpiForWindow(h); if (dpi == 0) dpi = 96; } catch { }
      IntPtr[] ic = IconsFor(ico, dpi);
      if (ic[1] == IntPtr.Zero) continue;
      if (SendMessage(h, 0x7F, (IntPtr)1, IntPtr.Zero) == ic[1]) continue;   // already ours
      try { TagWindow(h, ico, relaunch, appId); } catch { }
      SendMessage(h, 0x80, (IntPtr)0, ic[0]); SendMessage(h, 0x80, (IntPtr)1, ic[1]); n++;
    }
    return n;
  }
  // give a .lnk shortcut the same identity, so the pinned shortcut and the running window are one taskbar button
  public static void SetLinkAppId(string path, string appId) {
    object link = new CShellLink();
    try {
      IPersistFile pf = (IPersistFile)link; pf.Load(path, 2);
      IPropertyStore ps = (IPropertyStore)link;
      SetStr(ps, 5, appId); ps.Commit();
      pf.Save(path, true);
    } finally { Marshal.ReleaseComObject(link); }
  }
}
"@
$appId = 'HanziFarm.App'
$iconReady = $false
try { Add-Type -TypeDefinition $iconCs -ErrorAction Stop; $iconReady = $true } catch {}
function Set-LinkId([string]$path) { if ($iconReady -and (Test-Path $path)) { try { [HFIcon]::SetLinkAppId($path, $appId) } catch {} } }
function Start-IconKeeper {
  if (-not $iconReady) { return }
  try {
    $ico = Join-Path $root 'hanzifarm-3.ico'; if (-not (Test-Path $ico)) { return }
    $relaunch = '"' + (Join-Path $env:WINDIR 'System32\wscript.exe') + '" "' + (Join-Path $root 'launch.vbs') + '"'
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ param($ico, $rel, $id) while ($true) { try { [void][HFIcon]::Apply('Hanki', $ico, $rel, $id) } catch {}; Start-Sleep -Seconds 2 } }).AddArgument($ico).AddArgument($relaunch).AddArgument($appId)
    $script:iconKeeper = @($ps, $ps.BeginInvoke())
  } catch {}
}

# a "Hanzi Farm" shortcut on the Desktop with the app icon (pin it to the taskbar from there)
function Set-AppShortcut {
  try {
    $ico = Join-Path $root 'hanzifarm-3.ico'
    if (-not (Test-Path $ico)) { return }
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hanki.lnk'))
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $root 'launch.vbs') + '"'
    $lnk.WorkingDirectory = $root
    $lnk.IconLocation = "$ico,0"
    $lnk.Description = 'Hanki'
    $lnk.Save()
    Set-LinkId $lnk.FullName
    if (Test-Path $startupLink) { $st = $sh.CreateShortcut($startupLink); $st.IconLocation = "$ico,0"; $st.Save(); Set-LinkId $startupLink }
    # the same shortcut in the Start menu: Windows only shows notifications under an app name that has one there
    $sm = Join-Path ([Environment]::GetFolderPath('Programs')) 'Hanki.lnk'
    $sl = $sh.CreateShortcut($sm)
    $sl.TargetPath = $lnk.TargetPath; $sl.Arguments = $lnk.Arguments; $sl.WorkingDirectory = $root; $sl.IconLocation = "$ico,0"; $sl.Description = 'Hanki'
    $sl.Save(); Set-LinkId $sm
    # renamed from Hanzi Farm: drop the old-name shortcuts now that the new ones exist
    foreach ($old in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Hanzi Farm.lnk'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'Hanzi Farm.lnk'))) { if (Test-Path $old) { Remove-Item $old -ErrorAction SilentlyContinue } }
    if ($iconReady) { $script:toastId = $appId }
    # copies of the shortcut pinned to the taskbar or Start keep their own icon path: point them at the new icon too
    $changed = $false
    foreach ($dir in @((Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
      if (-not (Test-Path $dir)) { continue }
      Get-ChildItem -Path $dir -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
          $p = $sh.CreateShortcut($_.FullName)
          if ($p.Arguments -like '*launch.vbs*' -or $p.Arguments -like '*localhost:8765*' -or $_.BaseName -like 'Hanzi Farm*' -or $_.BaseName -like 'Hanki*') {
            if ($p.IconLocation -ne "$ico,0") { $p.IconLocation = "$ico,0"; $p.Save(); $changed = $true }
            Set-LinkId $_.FullName
          }
        } catch {}
      }
    }
    # Windows keeps old icons in a cache; ask it to refresh once whenever the icon is new
    $mark = Join-Path $dataDir 'icon-version.txt'
    $ver = (Get-Item $ico).Length.ToString() + '-' + (Get-Item $ico).LastWriteTimeUtc.Ticks
    if ($changed -or -not (Test-Path $mark) -or ((Get-Content $mark -Raw) -ne $ver)) {
      $ie = Join-Path $env:WINDIR 'System32\ie4uinit.exe'
      if (Test-Path $ie) { Start-Process $ie -ArgumentList '-show' -WindowStyle Hidden }
      [System.IO.File]::WriteAllText($mark, $ver)
    }
  } catch {}
}

# ---------- study reminders: a Windows notification at set times when cards are left for today ----------
# The page writes a small flat "remindHF" object into data.json on every save: today's count of cards left,
# an estimate for the next days, the reminder times (minutes after midnight) and the message texts
# (kept in the page so they can be Vietnamese or Chinese; this file stays plain ASCII).
$remindLib = @'
function Get-RemindInfo([string]$dataFile) {
  if (-not (Test-Path $dataFile)) { return $null }
  $m = [regex]::Match([System.IO.File]::ReadAllText($dataFile), '"remindHF":(\{[^{}]*\})')
  if (-not $m.Success) { return $null }
  $r = $m.Groups[1].Value | ConvertFrom-Json
  $today = (Get-Date).AddHours(-4).ToString('yyyy-MM-dd')
  $left = -1; $by = ''
  if ($r.day -eq $today) { $left = [int]$r.left; $by = [string]$r.by }
  elseif ($r.ahead) { foreach ($p in ([string]$r.ahead).Split(',')) { $kv = $p.Split(':'); if ($kv.Length -eq 2 -and $kv[0] -eq $today) { $left = [int]$kv[1] } } }
  return @{ r = $r; left = $left; by = $by }
}
function Show-Toast([string]$appId, [string]$url, [string]$title, [string]$body) {
  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
  $e = [System.Security.SecurityElement]
  $x = "<toast activationType='protocol' launch='" + $e::Escape($url) + "'><visual><binding template='ToastGeneric'><text>" + $e::Escape($title) + "</text><text>" + $e::Escape($body) + "</text></binding></visual></toast>"
  $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
  $doc.LoadXml($x)
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification $doc))
}
function Show-Remind($info, [string]$appId, [string]$url) {
  $r = $info.r
  if ($info.left -gt 0) { $t = ([string]$r.t1).Replace('%n', [string]$info.left); $b = if ($info.by) { ([string]$r.b1).Replace('%b', $info.by) } else { [string]$r.b2 } }
  elseif ($info.left -lt 0) { $t = [string]$r.t0; $b = [string]$r.b0 }
  else { $t = [string]$r.tt; $b = [string]$r.bt }
  Show-Toast $appId $url $t $b
}
'@
. ([scriptblock]::Create($remindLib))
$toastId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'   # PowerShell's own id until the Start menu shortcut exists
function Start-Reminders {
  try {
    $loop = @'
$fired = @{}
if (Test-Path $stateFile) { foreach ($l in [System.IO.File]::ReadAllLines($stateFile)) { $fired[$l] = 1 } }
while ($true) {
  try {
    $now = Get-Date; $today = $now.AddHours(-4).ToString('yyyy-MM-dd'); $mins = $now.Hour * 60 + $now.Minute
    if ($now.Hour -lt 4) { $mins += 1440 }   # the study day runs until 4 am
    $info = Get-RemindInfo $dataFile
    if ($info -and $info.r.on -ne 0) {
      foreach ($s in ([string]$info.r.at).Split(',')) {
        $slot = 0
        if (-not [int]::TryParse($s, [ref]$slot)) { continue }
        $key = "$today|$slot"
        if ($mins -ge $slot -and $mins -lt $slot + 60 -and -not $fired.ContainsKey($key)) {
          $fired[$key] = 1
          $keep = @($fired.Keys | Where-Object { $_ -ge ($now.AddDays(-3).ToString('yyyy-MM-dd')) })
          [System.IO.File]::WriteAllLines($stateFile, [string[]]$keep)
          # studying right now (saved in the last 3 minutes): no need to nag
          $busy = ((Get-Date) - (Get-Item $dataFile).LastWriteTime).TotalMinutes -lt 3
          if (-not $busy -and $info.left -ne 0) { Show-Remind $info $appId $url }
        }
      }
    }
  } catch {}
  Start-Sleep -Seconds 30
}
'@
    $ps = [powershell]::Create()
    [void]$ps.AddScript('param($dataFile, $stateFile, $appId, $url)' + "`n" + $remindLib + "`n" + $loop).AddArgument($dataFile).AddArgument((Join-Path $dataDir 'remind-state.txt')).AddArgument($toastId).AddArgument($url + '#today')
    $script:reminders = @($ps, $ps.BeginInvoke())
  } catch {}
}

function Set-Autostart([bool]$on) {
  if ($on) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($startupLink)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $root 'launch.vbs') + '"'
    $lnk.WorkingDirectory = $root
    $lnk.Description = 'Open Hanki when Windows starts'
    $ico = Join-Path $root 'hanzifarm-3.ico'; if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" }
    $lnk.Save()
    Set-LinkId $startupLink
  } elseif (Test-Path $startupLink) {
    Remove-Item $startupLink
  }
}

Set-AppShortcut
Start-IconKeeper
Start-Reminders

while ($listener.IsListening) {
  $ctx = $null
  try {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath
    $method = $ctx.Request.HttpMethod
    # only this computer (the browser here, or Tailscale relaying for your phone); never the rest of the network
    if (-not $ctx.Request.IsLocal) { SendText $ctx 403 '{"error":"local only"}'; continue }

    if ($static.ContainsKey($path) -and $method -eq 'GET') {
      $s = $static[$path]
      $file = Join-Path $root $s[0]
      if (Test-Path $file) {
        # the page itself: "no-cache" + ETag, so a phone re-checks it each time but only downloads it again when it changed
        $fi = Get-Item $file; $etag = '"' + $fi.LastWriteTimeUtc.Ticks + '-' + $fi.Length + '"'
        $cache = if ($s[2] -eq 'no-store') { 'no-cache' } else { $s[2] }
        if ($ctx.Request.Headers['If-None-Match'] -eq $etag) {
          $ctx.Response.StatusCode = 304; $ctx.Response.AddHeader('ETag', $etag); $ctx.Response.AddHeader('Cache-Control', $cache); $ctx.Response.Close()
        } else {
          $ctx.Response.AddHeader('ETag', $etag)
          Send $ctx 200 $s[1] ([System.IO.File]::ReadAllBytes($file)) $cache $s[3] ($s[0] + $etag)
        }
      }
      else { SendText $ctx 404 '{"error":"missing file"}' }
    }
    elseif ($path -eq '/api/data' -and $method -eq 'GET') {
      $ctx.Response.AddHeader('X-Rev', (Get-Rev))
      if (Test-Path $dataFile) { Send $ctx 200 'application/json; charset=utf-8' ([System.IO.File]::ReadAllBytes($dataFile)) }
      else { SendText $ctx 200 'null' }
    }
    elseif ($path -eq '/api/data' -and $method -eq 'POST') {
      $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, $utf8)
      $body = $reader.ReadToEnd(); $reader.Close()
      # the page says which revision it started from; if another device saved since, refuse (409) and let it reload
      $base = [string]$ctx.Request.Headers['X-Base-Rev']; if (-not $base) { $base = [string]$ctx.Request.QueryString['rev'] }
      if ($base -and $base -ne (Get-Rev)) { SendText $ctx 409 ('{"ok":false,"conflict":true,"rev":"' + (Get-Rev) + '"}') }
      elseif ($body.TrimStart().StartsWith('{')) { Save-Data $body; SendText $ctx 200 ('{"ok":true,"rev":"' + (Get-Rev) + '"}') }
      else { SendText $ctx 400 '{"ok":false,"error":"not json"}' }
    }
    elseif ($path -eq '/api/autostart' -and $method -eq 'GET') {
      $on = if (Test-Path $startupLink) { 'true' } else { 'false' }
      SendText $ctx 200 "{`"enabled`":$on}"
    }
    elseif ($path -eq '/api/autostart' -and $method -eq 'POST') {
      $want = $ctx.Request.QueryString['on'] -eq '1'
      Set-Autostart $want
      $on = if (Test-Path $startupLink) { 'true' } else { 'false' }
      SendText $ctx 200 "{`"enabled`":$on}"
    }
    elseif ($path.StartsWith('/fonts/') -and $method -eq 'GET') {
      $name = [System.Uri]::UnescapeDataString($path.Substring(7))
      $file = Join-Path (Join-Path $root 'fonts') $name
      if (($name -match '^[A-Za-z0-9_.\-]+\.(woff2|css)$') -and (Test-Path $file)) {
        $type = if ($name.EndsWith('.css')) { 'text/css; charset=utf-8' } else { 'font/woff2' }
        Send $ctx 200 $type ([System.IO.File]::ReadAllBytes($file)) 'max-age=31536000'
      } else { SendText $ctx 404 '{"error":"no font"}' }
    }
    elseif ($path.StartsWith('/media/') -and $method -eq 'GET') {
      $name = [System.Uri]::UnescapeDataString($path.Substring(7))
      $file = Join-Path $mediaDir $name
      if (($name -match '^[A-Za-z0-9_.\-]+\.(mp3|ogg|wav)$') -and (Test-Path $file)) { Send $ctx 200 'audio/mpeg' ([System.IO.File]::ReadAllBytes($file)) 'max-age=31536000' }
      else { SendText $ctx 404 '{"error":"no audio"}' }
    }
    elseif ($path -eq '/api/ai' -and $method -eq 'POST') {
      # relay for AI APIs that block browser calls (CORS); only https targets
      $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, $utf8)
      $raw = $reader.ReadToEnd(); $reader.Close()
      $req = $raw | ConvertFrom-Json
      if (-not ($req.url -match '^https://')) { SendText $ctx 400 '{"error":"bad url"}' }
      else {
        try {
          [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
          $wc = New-Object System.Net.WebClient; $wc.Encoding = $utf8
          $wc.Headers.Add('Content-Type', 'application/json'); $wc.Headers.Add('Authorization', 'Bearer ' + $req.key)
          $resp = $wc.UploadString([string]$req.url, 'POST', [string]$req.body)
          SendText $ctx 200 $resp
        } catch {
          $code = 502; $msg = $_.Exception.Message
          try { $r = $_.Exception.InnerException.Response; if ($r) { $code = [int]$r.StatusCode; $msg = (New-Object System.IO.StreamReader($r.GetResponseStream())).ReadToEnd() } } catch {}
          if (-not ($msg.TrimStart().StartsWith('{'))) { $msg = '{"error":"' + ($msg -replace '"', "'" -replace "[\r\n]", ' ') + '"}' }
          SendText $ctx $code $msg
        }
      }
    }
    elseif ($path -eq '/api/tts' -and $method -eq 'POST') {
      # Azure neural voices (Xiaoxiao, Jenny) for devices without Edge's natural voices, e.g. a phone.
      # Every clip is kept in media\tts, named by a hash of voice + speed + text, so each sentence is made once.
      $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, $utf8)
      $raw = $reader.ReadToEnd(); $reader.Close()
      $req = $raw | ConvertFrom-Json
      $text = [string]$req.text; $voice = [string]$req.voice; $rate = 0; [void][int]::TryParse([string]$req.rate, [ref]$rate)
      if (-not $text -or $text.Length -gt 500 -or $voice -notmatch '^[a-z]{2,3}-[A-Z]{2}-[A-Za-z]+Neural$' -or $rate -lt -50 -or $rate -gt 100) { SendText $ctx 400 '{"error":"bad request"}' }
      else {
        $ttsDir = Join-Path $mediaDir 'tts'
        if (-not (Test-Path $ttsDir)) { New-Item -ItemType Directory -Path $ttsDir | Out-Null }
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $hash = -join ($sha.ComputeHash($utf8.GetBytes("$voice|$rate|$text")) | ForEach-Object { $_.ToString('x2') })
        $clip = Join-Path $ttsDir "$hash.mp3"
        if (Test-Path $clip) {
          $ctx.Response.AddHeader('X-Cache', 'hit')
          Send $ctx 200 'audio/mpeg' ([System.IO.File]::ReadAllBytes($clip)) 'max-age=31536000'
        }
        elseif (-not $req.key -or ([string]$req.region) -notmatch '^[a-z0-9]+$') { SendText $ctx 400 '{"error":"no key"}' }
        else {
          try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $lang = $voice.Substring(0, $voice.LastIndexOf('-'))
            $pct = if ($rate -ge 0) { "+$rate%" } else { "$rate%" }
            $ssml = "<speak version='1.0' xml:lang='$lang'><voice name='$voice'><prosody rate='$pct'>" + [System.Security.SecurityElement]::Escape($text) + "</prosody></voice></speak>"
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('Ocp-Apim-Subscription-Key', [string]$req.key)
            $wc.Headers.Add('Content-Type', 'application/ssml+xml')
            $wc.Headers.Add('X-Microsoft-OutputFormat', 'audio-24khz-48kbitrate-mono-mp3')
            $wc.Headers.Add('User-Agent', 'HanziFarm')
            $bytes = $wc.UploadData("https://$($req.region).tts.speech.microsoft.com/cognitiveservices/v1", 'POST', $utf8.GetBytes($ssml))
            if ($bytes.Length -gt 0) { [System.IO.File]::WriteAllBytes($clip, $bytes) }
            $ctx.Response.AddHeader('X-Cache', 'miss')
            Send $ctx 200 'audio/mpeg' $bytes 'max-age=31536000'
          } catch {
            $code = 502; $msg = $_.Exception.Message
            try { $r = $_.Exception.InnerException.Response; if ($r) { $code = [int]$r.StatusCode; $msg = 'Azure ' + $code } } catch {}
            SendText $ctx $code ('{"error":"' + ($msg -replace '"', "'" -replace "[\r\n]", ' ') + '"}')
          }
        }
      }
    }
    elseif ($path -eq '/api/remind-test' -and $method -eq 'POST') {
      try {
        $info = Get-RemindInfo $dataFile
        if (-not $info) { SendText $ctx 400 '{"error":"no reminder data yet"}' }
        else { Show-Remind $info $toastId ($url + '#today'); SendText $ctx 200 ('{"ok":true,"left":' + $info.left + '}') }
      } catch { SendText $ctx 500 ('{"error":"' + ($_.Exception.Message -replace '"', "'" -replace "[\r\n]", ' ') + '"}') }
    }
    elseif ($path -eq '/api/ping') { SendText $ctx 200 '{"ok":true}' }
    elseif ($path -eq '/api/rev') { SendText $ctx 200 ('{"rev":"' + (Get-Rev) + '"}') }
    elseif ($path -eq '/api/quit' -and $method -eq 'POST') { SendText $ctx 200 '{"ok":true}'; $listener.Stop(); break }
    else { SendText $ctx 404 '{"error":"not found"}' }
  } catch {
    try { if ($ctx) { SendText $ctx 500 ('{"error":"' + ($_.Exception.Message -replace '"', "'") + '"}') } } catch {}
  }
}
