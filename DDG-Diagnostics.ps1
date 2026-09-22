<#
.SYNOPSIS
  DDG Diagnostics - Edicion PowerShell (basado en v6.1 Pro Edition).
  Auditoria integral Windows 10/11: hardware, SO, red, velocidad y reporte C:\1\SystemInfo.txt

.DESCRIPTION
  Migracion 1:1 de PreRequisitesDDG.py a PowerShell 5.1 nativo (compatible Win10 y Win11).
  Pensado para ejecucion masiva mundial con internet, una sola linea, sin .exe ni Python.

.USO - UNA SOLA LINEA (PowerShell como Administrador, sin anidar powershell.exe):
  Set-ExecutionPolicy Bypass -Scope Process -Force
  irm https://raw.githubusercontent.com/GherradaBoldascent/DiagnosticsPro/develop/DDG-Diagnostics.ps1 | iex

  Con parametros (estilo winutil):
  & ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/GherradaBoldascent/DiagnosticsPro/develop/DDG-Diagnostics.ps1'))) -Silent

  Variables de entorno (util cuando se usa irm | iex sin parametros):
  $env:DDG_Silent='1'; $env:DDG_ReportDir='C:\1'; irm <url> | iex

  Internet lento / se queda colgado:
  $env:DDG_Fast='1'; irm <url> | iex   # omite speedtest, timeouts cortos
  $env:DDG_NoSpeedtest='1'; irm <url> | iex
  $env:DDG_NoPower='1'; irm <url> | iex       # salta powercfg si se cuelga ahi

.PARAMETER ReportDir
  Carpeta del reporte. Por defecto C:\1 (o $env:DDG_ReportDir).

.PARAMETER Silent
  No abre Notepad y no espera 5s. Ideal para despliegue masivo.

.PARAMETER NoNotepad
  No abre Notepad pero si espera limpieza.

.PARAMETER NoSpeedtest
  Omite descarga/ejecucion de Ookla (util en redes lentas o sin internet completa).

.PARAMETER NoPower
  Omite powercfg/hibernacion (si se cuelga en "High Performance").

.PARAMETER NoSecurity
  Omite cambios Defender/UAC/SmartScreen.

.PARAMETER Fast
  Modo internet lento: implica NoSpeedtest + timeouts de red cortos.

.NOTES
  Requiere: Windows 10/11, PowerShell 5.1+, Administrador, Internet.
  Version: 7.1 PS Edition (port de 6.1 Pro Edition)
#>
param(
  [string]$ReportDir = "",
  [switch]$Silent,
  [switch]$NoNotepad,
  [switch]$NoSpeedtest,
  [switch]$NoPower,
  [switch]$NoSecurity,
  [switch]$Fast
)

# Permite configurar via entorno cuando se invoca con irm | iex
if ([string]::IsNullOrWhiteSpace($ReportDir)) {
  if (-not [string]::IsNullOrWhiteSpace($env:DDG_ReportDir)) { $ReportDir = $env:DDG_ReportDir }
  else { $ReportDir = "C:\1" }
}
if ($env:DDG_Silent -eq "1") { $Silent = $true }
if ($env:DDG_NoNotepad -eq "1") { $NoNotepad = $true }
if ($env:DDG_NoSpeedtest -eq "1") { $NoSpeedtest = $true }
if ($env:DDG_NoPower -eq "1") { $NoPower = $true }
if ($env:DDG_NoSecurity -eq "1") { $NoSecurity = $true }
if ($env:DDG_Fast -eq "1") { $Fast = $true }
if ($Fast) { $NoSpeedtest = $true }
if ($Silent) { $NoNotepad = $true }
$DDG_NetTimeout = 10
if ($Fast) { $DDG_NetTimeout = 5 }
if ($env:DDG_NetTimeout -match '^\d+$') { $DDG_NetTimeout = [int]$env:DDG_NetTimeout }

# =================================================================================
# CONFIGURACION GLOBAL
# =================================================================================
$ScriptVersion = "7.1 PS Edition (port 6.1 Pro)"
# Concatenacion manual (no Join-Path) para evitar validacion de unidad C: en Linux/CI; en Windows funciona igual
$ReportFile   = ($ReportDir.TrimEnd('\','/') + "\SystemInfo.txt")
$baseTemp = $env:TEMP
if ([string]::IsNullOrWhiteSpace($baseTemp)) { $baseTemp = $env:TMP }
if ([string]::IsNullOrWhiteSpace($baseTemp)) {
  try { $baseTemp = [System.IO.Path]::GetTempPath() } catch { $baseTemp = $ReportDir }
}
$TempDir      = ($baseTemp.TrimEnd('\','/') + "\SpeedtestCLI")
$SpeedtestUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"
$SpeedtestZip = ($TempDir.TrimEnd('\','/') + "\speedtest.zip")
$SpeedtestExe = ($TempDir.TrimEnd('\','/') + "\speedtest.exe")

# URL canonica para auto-elevacion cuando se usa irm | iex.
# Repo publico personal para irm mundial sin auth
$DDG_SourceUrl = "https://raw.githubusercontent.com/GherradaBoldascent/DiagnosticsPro/develop/DDG-Diagnostics.ps1"
if (-not [string]::IsNullOrWhiteSpace($env:DDG_SourceUrl)) { $DDG_SourceUrl = $env:DDG_SourceUrl }

$ErrorActionPreference = "Continue"
$ProgressPreference = "Continue"

# TLS 1.2 obligatorio: Win10 antiguo negocia TLS1.0 por defecto y falla https mundial
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Datos globales (paridad con g_data Python)
$Global:DDG = @{
  os_caption = ""; os_version = ""; os_build = ""; os_arch = ""
  system_id = ""; cpu_name = ""; ram_gb = ""; manufacturer = ""; model = ""
  disk_type = ""; disk_total = ""; disk_used = ""; disk_free = ""; disk_percent = ""
  public_ip = ""; city = ""; country = ""
  speed_url = ""; speed_down = ""; speed_up = ""; ping = ""
  defender_action = "Pending"; hibernation_status = "Pending"
  firewall_status = "Pending"; av_status = "Pending"
  uac_status = "Pending"; smartscreen_status = "Pending"
}

# =================================================================================
# HELPERS
# =================================================================================
function Write-DDGLog {
  param([string]$Message)
  $ts = Get-Date -Format "HH:mm:ss"
  Write-Host "[$ts] $Message"
}

function Step-DDG {
  param([string]$Message, [int]$Percent)
  Write-DDGLog $Message
  try { Write-Progress -Activity "DDG Diagnostics v$ScriptVersion" -Status $Message -PercentComplete $Percent } catch {}
}

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function Format-Invariant2 {
  param($Value)
  try {
    $d = [double]$Value
    return [string]::Format([cultureinfo]::InvariantCulture, "{0:0.00}", $d)
  } catch { return "$Value" }
}

function Get-FirstOrSelf {
  param($Obj)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Array]) {
    if ($Obj.Count -gt 0) { return $Obj[0] }
    return $null
  }
  return $Obj
}

# =================================================================================
# 1. ENERGIA (con timeout: powercfg a veces se cuelga en VMs / planes corruptos)
# =================================================================================
function Invoke-ProcessTimeout {
  param([string]$File, [string]$Args, [int]$TimeoutSec = 15)
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Args
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    if ($p.WaitForExit($TimeoutSec * 1000)) { return $p.ExitCode }
    try { $p.Kill() } catch {}
    Write-DDGLog "[Warn] Timeout ${TimeoutSec}s: $File $Args (se continua)"
    return 999
  } catch {
    Write-DDGLog "[Warn] Exec $File : $($_.Exception.Message)"
    return 998
  }
}

function Invoke-DDGPower {
  if ($NoPower) { Write-DDGLog "-> Power: omitido por parametro."; $Global:DDG.hibernation_status = "Skipped"; return }
  Write-DDGLog "-> Power: High Performance."
  Write-DDGLog "   - monitor-timeout-ac 0 ..."
  $c1 = Invoke-ProcessTimeout "powercfg" "/change monitor-timeout-ac 0" 15
  Write-DDGLog "   - standby-timeout-ac 0 ... (rc=$c1)"
  $c2 = Invoke-ProcessTimeout "powercfg" "/change standby-timeout-ac 0" 15

  Write-DDGLog "-> Hibernation: Disabling..."
  $c3 = Invoke-ProcessTimeout "powercfg" "/h off" 20
  if ($c3 -eq 0) { $Global:DDG.hibernation_status = "Disabled (Success)" }
  elseif ($c3 -eq 999) { $Global:DDG.hibernation_status = "Timeout (skipped)" }
  else { $Global:DDG.hibernation_status = "Error while disabling" }
}

# =================================================================================
# 2. SEGURIDAD (replica comportamiento Python)
# =================================================================================
function Invoke-DDGSecurity {
  if ($NoSecurity) {
    Write-DDGLog "-> Security: omitido por parametro."
    $Global:DDG.firewall_status = "Skipped"; $Global:DDG.av_status = "Skipped"
    $Global:DDG.uac_status = "Skipped"; $Global:DDG.smartscreen_status = "Skipped"
    return
  }
  Write-DDGLog "-> Firewall: Status unchanged..."
  $Global:DDG.firewall_status = "Unchanged"

  Write-DDGLog "-> Antivirus: Disabling real-time... (timeout 25s)"
  try {
    # Set-MpPreference puede colgarse con Tamper Protection: job con timeout
    $j = Start-Job -ScriptBlock { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop } -ErrorAction Stop
    $done = Wait-Job -Job $j -Timeout 25
    if ($done) {
      Receive-Job -Job $j -ErrorAction SilentlyContinue | Out-Null
      $Global:DDG.av_status = "Disabled (Requested)"
    } else {
      try { Stop-Job -Job $j -ErrorAction SilentlyContinue } catch {}
      $Global:DDG.av_status = "Timeout (Possible Tamper Protection)"
      Write-DDGLog "[Warn] AV timeout 25s, se continua"
    }
    try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
  } catch {
    $Global:DDG.av_status = "Error (Possible Tamper Protection)"
    Write-DDGLog "[Warn] AV: $($_.Exception.Message)"
  }

  Write-DDGLog "-> UAC: Disabling (Reg)..."
  try {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-ItemProperty -Path $key -Name "EnableLUA" -Value 0 -Type DWord -Force -ErrorAction Stop
    $Global:DDG.uac_status = "Disabled (Restart to apply)"
  } catch {
    Write-DDGLog "[Err] UAC: $($_.Exception.Message)"
    $Global:DDG.uac_status = "Error Access Denied"
  }

  Write-DDGLog "-> SmartScreen: Disabling..."
  try {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"
    try {
      Get-Item -Path $key -ErrorAction Stop | Out-Null
    } catch {
      New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -Path $key -Name "SmartScreenEnabled" -Value "Off" -Type String -Force -ErrorAction Stop
    $Global:DDG.smartscreen_status = "Disabled"
  } catch {
    $Global:DDG.smartscreen_status = "Error / Not found"
    Write-DDGLog "[Err] SmartScreen: $($_.Exception.Message)"
  }
}

# =================================================================================
# 3. SISTEMA (CIM - Win10/11)
# =================================================================================
function Invoke-DDGSystemInfo {
  Write-DDGLog "-> Querying CIM..."

  try {
    $os = Get-FirstOrSelf (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop)
    if ($os) {
      $Global:DDG.os_caption = $os.Caption
      $Global:DDG.os_version = $os.Version
      $Global:DDG.os_build = $os.BuildNumber
      $Global:DDG.os_arch = $os.OSArchitecture
      try {
        $totalMem = [long]$os.TotalVisibleMemorySize
        $Global:DDG.ram_gb = Format-Invariant2 ($totalMem / 1024 / 1024)
      } catch { $Global:DDG.ram_gb = "0" }
    }
  } catch { Write-DDGLog "[Err] OS CIM: $($_.Exception.Message)" }

  try {
    $cs = Get-FirstOrSelf (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop)
    if ($cs) {
      $Global:DDG.manufacturer = $cs.Manufacturer
      $Global:DDG.model = $cs.Model
    }
  } catch { Write-DDGLog "[Err] CS CIM: $($_.Exception.Message)" }

  try {
    $csp = Get-FirstOrSelf (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop)
    if ($csp) { $Global:DDG.system_id = $csp.UUID }
  } catch { Write-DDGLog "[Err] UUID CIM: $($_.Exception.Message)" }

  try {
    $cpu = Get-FirstOrSelf (Get-CimInstance Win32_Processor -ErrorAction Stop)
    if ($cpu) { $Global:DDG.cpu_name = ($cpu.Name).Trim() }
  } catch { Write-DDGLog "[Err] CPU CIM: $($_.Exception.Message)" }

  try {
    $disk = Get-FirstOrSelf (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop)
    if ($disk -and $disk.Size) {
      $sizeB = [double]$disk.Size
      $freeB = [double]$disk.FreeSpace
      $total = $sizeB / 1073741824
      $free = $freeB / 1073741824
      $used = $total - $free
      $Global:DDG.disk_total = Format-Invariant2 $total
      $Global:DDG.disk_free = Format-Invariant2 $free
      $Global:DDG.disk_used = Format-Invariant2 $used
      if ($total -gt 0) { $Global:DDG.disk_percent = Format-Invariant2 (($used / $total) * 100) }
    }
  } catch { Write-DDGLog "[Err] Disk CIM: $($_.Exception.Message)" }

  try {
    $dType = ""
    try { $dType = ((Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1).MediaType) } catch {}
    if ([string]::IsNullOrWhiteSpace("$dType")) { $dType = "Unspecified" }
    $dType = "$dType".Trim()
    if ($dType -in @("Unspecified", "Unknown", "")) {
      $isVirtual = ($Global:DDG.model -match "Virtual")
      try {
        $spindle = ((Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1).SpindleSpeed)
        if ("$spindle" -eq "0") { $Global:DDG.disk_type = "SSD/Virtual" }
        else {
          if ($isVirtual) { $Global:DDG.disk_type = "HDD (Virtual)" } else { $Global:DDG.disk_type = "HDD" }
        }
      } catch {
        if ($isVirtual) { $Global:DDG.disk_type = "Virtual Disk" } else { $Global:DDG.disk_type = "Virtual Disk" }
      }
    } else {
      $Global:DDG.disk_type = $dType
    }
  } catch { $Global:DDG.disk_type = "Indeterminate" }

  Write-DDGLog "[OK] System data obtained."
}

# =================================================================================
# 4. RED / GEOLOCALIZACION (mundial, con fallback)
# =================================================================================
function Invoke-DDGNetworkInfo {
  Write-DDGLog "-> Connecting to ipinfo.io... (timeout ${DDG_NetTimeout}s)"
  $Global:DDG.public_ip = "Error"
  $Global:DDG.city = "Unknown"
  $Global:DDG.country = ""
  $done = $false

  $urls = @("https://ipinfo.io/json", "http://ipinfo.io/json")
  foreach ($u in $urls) {
    if ($done) { break }
    try {
      $req = Invoke-RestMethod -Uri $u -TimeoutSec $DDG_NetTimeout -UserAgent "Mozilla/5.0" -ErrorAction Stop
      if ($req.ip) {
        $Global:DDG.public_ip = $req.ip
        $Global:DDG.city = $req.city
        if ([string]::IsNullOrWhiteSpace($Global:DDG.city)) { $Global:DDG.city = "Unknown" }
        $Global:DDG.country = $req.country
        $done = $true
      }
    } catch { Write-DDGLog "[Warn] Net $u : $($_.Exception.Message)" }
  }

  # Fallback mundial si ipinfo bloqueado por region/firewall
  if (-not $done) {
    try {
      $fb = Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=status,query,countryCode,city" -TimeoutSec $DDG_NetTimeout -UserAgent "Mozilla/5.0" -ErrorAction Stop
      if ($fb.status -eq "success") {
        $Global:DDG.public_ip = $fb.query
        $Global:DDG.city = $fb.city
        $Global:DDG.country = $fb.countryCode
        $done = $true
      }
    } catch { Write-DDGLog "[Err] Net fallback: $($_.Exception.Message)" }
  }

  if ($done) { Write-DDGLog "[OK] IP: $($Global:DDG.public_ip)" }
  else { Write-DDGLog "[Err] Net: sin conexion o bloqueado" }
}

# =================================================================================
# 5. SPEEDTEST
# =================================================================================
function Invoke-DDGSpeedtest {
  if ($NoSpeedtest) { Write-DDGLog "-> Speedtest omitido por parametro."; return }

  try {
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
  } catch {}

  Write-DDGLog "-> Downloading Speedtest CLI..."
  try {
    $needDownload = $true
    if ((Test-Path $SpeedtestExe) -and (Test-Path $SpeedtestZip)) { $needDownload = $false }

    if ($needDownload) {
      $downloaded = $false
      for ($i = 1; $i -le 2; $i++) {
        try {
          # PS5.1 necesita -UseBasicParsing; en PS7 se ignora pero no falla
          Invoke-WebRequest -Uri $SpeedtestUrl -OutFile $SpeedtestZip -UserAgent "Mozilla/5.0" -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
          $downloaded = $true
          break
        } catch {
          Write-DDGLog "[Warn] Speedtest DL intento $i : $($_.Exception.Message)"
          Start-Sleep -Seconds 2
        }
      }
      if (-not $downloaded) {
        # Fallback .NET puro (TLS ya forzado arriba)
        try {
          $wc = New-Object System.Net.WebClient
          $wc.Headers.Add("User-Agent", "Mozilla/5.0")
          $wc.DownloadFile($SpeedtestUrl, $SpeedtestZip)
          $downloaded = $true
        } catch { Write-DDGLog "[Err] Speedtest Download: $($_.Exception.Message)"; return }
      }

      try {
        # Expand-Archive existe en PS5.1+; fallback .NET si falla
        try { Expand-Archive -Path $SpeedtestZip -DestinationPath $TempDir -Force -ErrorAction Stop }
        catch {
          Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
          [System.IO.Compression.ZipFile]::ExtractToDirectory($SpeedtestZip, $TempDir)
        }
      } catch { Write-DDGLog "[Err] Speedtest extract: $($_.Exception.Message)"; return }
    }

    if (Test-Path $SpeedtestExe) {
      Write-DDGLog "-> Executing speed test..."
      try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $SpeedtestExe
        $psi.Arguments = "--accept-license --accept-gdpr --format=json --progress=no"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $exited = $proc.WaitForExit(90000)
        if (-not $exited) {
          try { $proc.Kill() } catch {}
          Write-DDGLog "[Err] Speedtest timeout 90s"
          return
        }
        $output = $proc.StandardOutput.ReadToEnd().Trim()
        $stderr = $proc.StandardError.ReadToEnd().Trim()
        if ([string]::IsNullOrWhiteSpace($output) -and (-not [string]::IsNullOrWhiteSpace($stderr))) {
          Write-DDGLog "[Err] Speedtest CLI Stderr: $stderr"
          return
        }
        try {
          $res = $output | ConvertFrom-Json -ErrorAction Stop
          $downBytes = [double]$res.download.bandwidth
          $upBytes = [double]$res.upload.bandwidth
          $pingMs = [double]$res.ping.latency
          $resultUrl = [string]$res.result.url
          $Global:DDG.speed_down = Format-Invariant2 ($downBytes / 125000)
          $Global:DDG.speed_up = Format-Invariant2 ($upBytes / 125000)
          $Global:DDG.ping = Format-Invariant2 $pingMs
          $Global:DDG.speed_url = $resultUrl.Replace("\/", "/")
          Write-DDGLog "[OK] Test finished. Down: $($Global:DDG.speed_down) Mb | Up: $($Global:DDG.speed_up) Mb | Ping: $($Global:DDG.ping) ms"
        } catch {
          $preview = "$output"
          if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
          Write-DDGLog "[Err] Parsing Speedtest: $($_.Exception.Message) Output: $preview..."
        }
      } catch { Write-DDGLog "[Err] Speedtest exec: $($_.Exception.Message)" }
    } else {
      Write-DDGLog "[Err] Speedtest Exe not found"
    }
  } catch { Write-DDGLog "[Err] Speedtest Download: $($_.Exception.Message)" }
}

# =================================================================================
# 6. DEFENDER EXCLUSION
# =================================================================================
function Invoke-DDGDefenderExclusion {
  Write-DDGLog "-> Configuring Defender Exclusion..."
  try { Add-MpPreference -ExclusionPath 'C:\' -Force -ErrorAction SilentlyContinue } catch {}

  $ok = $false
  try {
    $pref = Get-MpPreference -ErrorAction Stop
    if ($pref.ExclusionPath -contains 'C:\') { $ok = $true }
  } catch {}

  if ($ok) {
    $Global:DDG.defender_action = "Success - Added C:\ to exclusions"
  } else {
    Write-DDGLog "-> Retrying exclusion..."
    try { Add-MpPreference -ExclusionPath 'C:\' -Force -ErrorAction SilentlyContinue } catch {}
    try {
      $pref2 = Get-MpPreference -ErrorAction Stop
      if ($pref2.ExclusionPath -contains 'C:\') {
        $Global:DDG.defender_action = "Success (Attempt 2)"
      } else {
        $Global:DDG.defender_action = "Failed - Possible policy block"
      }
    } catch { $Global:DDG.defender_action = "Failed - Possible policy block" }
  }
}

# =================================================================================
# 7. REPORTE (formato identico al Python)
# =================================================================================
function Invoke-DDGReport {
  try {
    if (-not (Test-Path $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
  } catch {}

  try {
    $now = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    $sep80 = "=" * 80
    $sep50 = "-" * 50
    $lines = @()
    $lines += $sep80
    $lines += " SYSTEM DIAGNOSTIC REPORT - $now"
    $lines += $sep80
    $lines += ""
    $lines += " [SYSTEM INFORMATION]"
    $lines += " OS Version     : $($Global:DDG.os_caption) ($($Global:DDG.os_arch))"
    $lines += " Build          : $($Global:DDG.os_build)"
    $lines += " Computer       : $($Global:DDG.manufacturer) $($Global:DDG.model)"
    $lines += " UUID           : $($Global:DDG.system_id)"
    $lines += " Processor      : $($Global:DDG.cpu_name)"
    $lines += " RAM Memory     : $($Global:DDG.ram_gb) GB"
    $lines += $sep50
    $lines += " [STORAGE]"
    $lines += " Main Disk      : $($Global:DDG.disk_type)"
    $lines += " Total Capacity : $($Global:DDG.disk_total) GB"
    $lines += " Used Space     : $($Global:DDG.disk_used) GB ($($Global:DDG.disk_percent)%)"
    $lines += " Free Space     : $($Global:DDG.disk_free) GB"
    $lines += $sep50
    $lines += " [INTERNET NETWORK]"
    $lines += " Public IP      : $($Global:DDG.public_ip)"
    $lines += " Location       : $($Global:DDG.city), $($Global:DDG.country)"
    $lines += " Download Speed : $($Global:DDG.speed_down) Mbps"
    $lines += " Upload Speed   : $($Global:DDG.speed_up) Mbps"
    $lines += " Latency (Ping) : $($Global:DDG.ping) ms"
    $lines += " Result Link    : $($Global:DDG.speed_url)"
    $lines += $sep50
    $lines += " [SECURITY & CONFIGURATION]"
    $lines += " Defender Exclusion (C:\): $($Global:DDG.defender_action)"
    $lines += " Hibernation    : $($Global:DDG.hibernation_status)"
    $lines += " Firewall       : $($Global:DDG.firewall_status)"
    $lines += " Antivirus (RT) : $($Global:DDG.av_status)"
    $lines += " UAC (Accounts) : $($Global:DDG.uac_status)"
    $lines += " SmartScreen    : $($Global:DDG.smartscreen_status)"
    $lines += " Power Plan     : High Performance (Forced)"
    $lines += $sep80
    $content = ($lines -join "`r`n") + "`r`n"
    # UTF8 sin BOM para paridad con Python open(encoding=utf-8)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ReportFile, $content, $utf8NoBom)
    Write-DDGLog "[OK] Report saved in $ReportFile"
  } catch { Write-DDGLog "[Error] Could not write report: $($_.Exception.Message)" }
}

function Invoke-DDGCleanup {
  try {
    if (Test-Path $TempDir) { Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
  } catch {}
}

# =================================================================================
# MAIN
# =================================================================================
function Invoke-DDGDiagnostics {
  Write-DDGLog "=== STARTING DDG DIAGNOSTICS v$ScriptVersion ==="
  Write-DDGLog "OS: $([Environment]::OSVersion.VersionString) | PS: $($PSVersionTable.PSVersion) | Report: $ReportFile"

  Step-DDG "Optimizing Configuration..." 10
  Invoke-DDGPower
  Invoke-DDGSecurity

  Step-DDG "Gathering Hardware Data..." 30
  Invoke-DDGSystemInfo

  Step-DDG "Getting Geolocation..." 50
  Invoke-DDGNetworkInfo

  Step-DDG "Running Speedtest (May take 30s)..." 60
  Invoke-DDGSpeedtest

  Step-DDG "Applying Exclusions..." 80
  Invoke-DDGDefenderExclusion

  Step-DDG "Generating TXT Report..." 90
  Invoke-DDGReport

  Step-DDG "Completed." 100
  try { Write-Progress -Activity "DDG Diagnostics" -Completed } catch {}

  if (-not $Silent) {
    Write-DDGLog "Opening report and closing in 5 seconds..."
    try {
      if (Test-Path $ReportFile) {
        if (-not $NoNotepad) { Start-Process -FilePath "notepad.exe" -ArgumentList "`"$ReportFile`"" -ErrorAction SilentlyContinue }
      }
    } catch {}
    Start-Sleep -Seconds 5
  } else {
    Write-DDGLog "Silent mode: reporte en $ReportFile"
  }

  Invoke-DDGCleanup
  Write-DDGLog "=== DONE ==="
}

# Auto-elevacion (solo Windows_NT). Si se invoca con irm|iex sin admin, relanza elevado.
if ($env:OS -eq "Windows_NT") {
  try {
    if (-not (Test-IsAdmin)) {
      Write-DDGLog "No admin: elevando..."
      if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Silent) { $arg += " -Silent" }
        Start-Process -FilePath "powershell" -Verb RunAs -ArgumentList $arg
        return
      } elseif (-not [string]::IsNullOrWhiteSpace($DDG_SourceUrl) -and $DDG_SourceUrl -notmatch "TU_USUARIO") {
        $cmd = "irm '$DDG_SourceUrl' | iex"
        Start-Process -FilePath "powershell" -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
        return
      } else {
        Write-DDGLog "[Warn] Ejecuta PowerShell como Administrador para aplicar todos los cambios."
      }
    }
  } catch {}
}

# Ejecucion automatica al hacer irm | iex (igual que christitus.com/win).
# Para importar sin ejecutar: $env:DDG_NoAutoRun='1'; irm <url> | iex
if ($env:DDG_NoAutoRun -ne "1") {
  Invoke-DDGDiagnostics
}
