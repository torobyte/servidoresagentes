# Torobyte Monitor Cloud - Windows agent
# Compatible: Windows 7 / Server 2008 R2 y superiores (PowerShell 5.0+)
#
# Instalación (PowerShell como Administrador):
#   $env:AGENT_TOKEN='xxx'; $env:INGEST_URL='https://<host>/api/public/ingest/metrics';
#   iex ((iwr 'https://<host>/api/public/agents/windows.ps1' -UseBasicParsing).Content)
#
# El script se autoinstala como Tarea Programada (TorobyteAgent) ejecutándose
# como SYSTEM al inicio, y vuelve a ejecutarse cada INTERVAL segundos.

$p=0;'Ssl3','Tls','Tls11','Tls12','Tls13'|%{try{$p=$p-bor[Net.SecurityProtocolType]::$_}catch{}};[Net.ServicePointManager]::SecurityProtocol=$p
# Aceptar cadena de certificados aunque el root CA del store esté desactualizado
# (típico en Windows Server 2012/2016 sin Windows Updates recientes).
try { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } } catch {}
$ErrorActionPreference = 'Continue'

$AgentVersion = '1.7.4-windows'
$Token        = if ($env:AGENT_TOKEN) { $env:AGENT_TOKEN } else { $env:TOKEN }
$Url          = if ($env:INGEST_URL)  { $env:INGEST_URL }  else { $env:URL }
$Interval     = if ($env:INTERVAL)    { [int]$env:INTERVAL } else { 5 }
if ($Interval -lt 5) { $Interval = 5 }
$Mode         = if ($env:MODE) { $env:MODE } else { 'install' }

$InstallDir   = Join-Path $env:ProgramData 'TorobyteAgent'
$ScriptPath   = Join-Path $InstallDir 'torobyte-agent.ps1'
$LogPath      = Join-Path $InstallDir 'agent.log'
$TaskName     = 'TorobyteAgent'

function W-Log($msg) {
  $line = "[$((Get-Date).ToString('o'))] $msg"
  Write-Host $line
  try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}
function W-Step($n, $total, $msg) { Write-Host ("[{0}/{1}] {2}" -f $n,$total,$msg) -ForegroundColor Cyan }
function W-Ok($msg)   { Write-Host ("      OK   {0}" -f $msg) -ForegroundColor Green }
function W-Fail($msg) { Write-Host ("      FAIL {0}" -f $msg) -ForegroundColor Red; exit 1 }

function Enable-ModernTls {
  try {
    $p = 0
    'Tls12','Tls11','Tls' | ForEach-Object {
      try { $p = $p -bor [Net.SecurityProtocolType]::$_ } catch {}
    }
    if ($p -ne 0) { [Net.ServicePointManager]::SecurityProtocol = $p }
    [Net.ServicePointManager]::Expect100Continue = $false
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
  } catch {}
}

Enable-ModernTls

function Test-AgentScriptFile($path) {
  try {
    return (Test-Path $path) -and ((Get-Item $path).Length -gt 1000) -and ((Get-Content $path -TotalCount 1) -match '^# Torobyte')
  } catch { return $false }
}

function Download-AgentScript($destination) {
  $primary = $Url -replace '/api/public/ingest/metrics.*$', '/api/public/agents/windows.ps1'
  $fallback = 'https://project--de5cadf8-756e-4d2f-8f8b-6ca62009361b-dev.lovable.app/api/public/agents/windows.ps1'
  $supabase = 'https://giwbmxwlklctlcuyaxzy.functions.supabase.co/windows-agent'
  $rawGithub = 'https://raw.githubusercontent.com/torobyte/servidoresagentes/main/agents/windows.ps1'
  $urls = @($fallback, $primary, $supabase)
  if ($rawGithub -and $rawGithub -notmatch '__RAW_GITHUB') { $urls += $rawGithub }
  $errs = @()

  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]'Tls12,Tls11,Tls'
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
  } catch {}
  foreach ($scriptUrl in $urls) {
    Remove-Item $destination -Force -ErrorAction SilentlyContinue
    try {
      if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -k -L -fsSLo $destination $scriptUrl 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-AgentScriptFile $destination)) { return $true }
        $errs += "curl exit=$LASTEXITCODE"
      }
    } catch { $errs += "curl:$($_.Exception.Message)" }
    Remove-Item $destination -Force -ErrorAction SilentlyContinue
    try {
      & certutil.exe -urlcache -split -f $scriptUrl $destination | Out-Null
      if (Test-AgentScriptFile $destination) { return $true }
      $errs += "certutil contenido invalido"
    } catch { $errs += "certutil:$($_.Exception.Message)" }
    Remove-Item $destination -Force -ErrorAction SilentlyContinue
    try {
      $job = "toro_" + [guid]::NewGuid().ToString('N')
      & bitsadmin.exe /transfer $job /priority foreground $scriptUrl $destination | Out-Null
      if (Test-AgentScriptFile $destination) { return $true }
      $errs += "bits contenido invalido"
    } catch { $errs += "bits:$($_.Exception.Message)" }
    Remove-Item $destination -Force -ErrorAction SilentlyContinue
    try {
      Import-Module BitsTransfer -ErrorAction Stop
      Start-BitsTransfer -Source $scriptUrl -Destination $destination -ErrorAction Stop
      if (Test-AgentScriptFile $destination) { return $true }
      $errs += "bitsps contenido invalido"
    } catch { $errs += "bitsps:$($_.Exception.Message)" }
    Remove-Item $destination -Force -ErrorAction SilentlyContinue
    try {
      Invoke-WebRequest -Uri $scriptUrl -OutFile $destination -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
      if (Test-AgentScriptFile $destination) { return $true }
      $errs += "iwr contenido invalido"
    } catch { $errs += "iwr:$($_.Exception.Message)" }
  }
  W-Log ("download failed: {0}" -f ($errs -join ' | '))
  return $false
}

function To-Scalar($value, $fallback = 0) {
  if ($null -eq $value) { return $fallback }
  if ($value -is [System.Array]) {
    foreach ($item in $value) {
      if ($null -ne $item -and "$item" -ne '') { return $item }
    }
    return $fallback
  }
  return $value
}

function To-Double($value, [double]$fallback = 0) {
  try {
    $v = To-Scalar $value $fallback
    if ($null -eq $v -or "$v" -eq '') { return $fallback }
    return [double]$v
  } catch { return $fallback }
}

function To-Int($value, [int]$fallback = 0) {
  try { return [int][math]::Round((To-Double $value $fallback), 0) } catch { return $fallback }
}

# ----------------------------- Collectors -----------------------------
function Get-PrivIp {
  try {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -in 'Dhcp','Manual' } |
           Select-Object -First 1).IPAddress
    if ($ip) { return $ip }
  } catch {}
  try {
    return (Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
            Select-Object -ExpandProperty IPAddress -First 1 | Where-Object { $_ -match '^\d' } | Select-Object -First 1)
  } catch { return '' }
}

$Script:_pubIp     = ''
$Script:_pubIpAt   = $null
function Get-PubIp {
  # Cache 10 minutos para no consultar en cada ciclo
  if ($Script:_pubIp -and $Script:_pubIpAt -and ((Get-Date) - $Script:_pubIpAt).TotalMinutes -lt 10) {
    return $Script:_pubIp
  }
  $endpoints = @(
    'https://api.ipify.org?format=text',
    'https://ifconfig.me/ip',
    'https://icanhazip.com',
    'https://ipv4.icanhazip.com',
    'https://checkip.amazonaws.com'
  )
  foreach ($e in $endpoints) {
    try {
      if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $ip = (& curl.exe -k -L -fsS --max-time 8 $e 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
          $Script:_pubIp = $ip; $Script:_pubIpAt = Get-Date
          return $ip
        }
      }
    } catch {}
    try {
      Enable-ModernTls
      $r = Invoke-WebRequest -Uri $e -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
      $ip = ($r.Content | Out-String).Trim()
      if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $Script:_pubIp = $ip; $Script:_pubIpAt = Get-Date
        return $ip
      }
    } catch { W-Log ("pubip {0} fallo: {1}" -f $e, $_.Exception.Message) }
  }
  return $Script:_pubIp  # devolver ultimo conocido (o '')
}

# Sample CPU twice to get a real delta (LoadPercentage may return 0)
$Script:_lastCpuSample = $null
function Get-CpuPercent {
  try {
    $c = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
    if ($c -ne $null -and $c -gt 0) { return [math]::Round((To-Double $c 0), 1) }
  } catch {}
  try {
    $s = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
    return [math]::Round((To-Double $s.CounterSamples[0].CookedValue 0), 1)
  } catch { return 0 }
}

function Get-CpuCores {
  # Devuelve un arreglo con el % de uso por CPU lógica.
  # Se prueban múltiples fuentes porque los nombres de contadores están
  # localizados (ej. español) y algunos sistemas los devuelven como
  # "socket,core" (0,0 / 0,1 / 0,_Total).
  $arr = New-Object System.Collections.ArrayList

  # 1) Win32_PerfFormattedData_Counters_ProcessorInformation (Win7+)
  #    Nombres típicos: "0,0", "0,1", ..., "0,_Total", "_Total"
  try {
    $rows = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop |
            Where-Object { $_.Name -and $_.Name -notmatch '_Total\s*$' } |
            Sort-Object { $_.Name }
    foreach ($r in $rows) {
      [void]$arr.Add([math]::Round((To-Double $r.PercentProcessorTime 0), 1))
    }
    if ($arr.Count -gt 0) { return ,$arr.ToArray() }
  } catch {}

  # 2) Win32_PerfFormattedData_PerfOS_Processor (nombres numéricos "0","1",...)
  try {
    $rows = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop |
            Where-Object { $_.Name -and $_.Name -ne '_Total' } |
            Sort-Object { try { [int]$_.Name } catch { $_.Name } }
    foreach ($r in $rows) {
      [void]$arr.Add([math]::Round((To-Double $r.PercentProcessorTime 0), 1))
    }
    if ($arr.Count -gt 0) { return ,$arr.ToArray() }
  } catch {}

  # 3) Get-Counter con wildcard (locale-sensible, último recurso)
  try {
    $samples = Get-Counter '\Processor(*)\% Processor Time' -ErrorAction Stop
    foreach ($s in $samples.CounterSamples) {
      $name = "$($s.InstanceName)"
      if ($name -match '_total') { continue }
      [void]$arr.Add([math]::Round((To-Double $s.CookedValue 0), 1))
    }
    if ($arr.Count -gt 0) { return ,$arr.ToArray() }
  } catch {}

  return ,@()
}

$Script:_lastNet = $null
function Get-NetRates {
  # Returns @{ inMB = x; outMB = y } in MB/s
  # 1) Preferir Win32_PerfFormattedData (ya viene en bytes/seg, sin estado)
  try {
    $perf = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
            Where-Object { $_.Name -notmatch 'Loopback|isatap|Pseudo|Teredo' }
    $rxRate = To-Double (($perf | Measure-Object -Property BytesReceivedPersec -Sum).Sum) 0
    $txRate = To-Double (($perf | Measure-Object -Property BytesSentPersec     -Sum).Sum) 0
    if ($rxRate -gt 0 -or $txRate -gt 0) {
      return @{ inMB = [math]::Round($rxRate / 1MB, 3); outMB = [math]::Round($txRate / 1MB, 3) }
    }
  } catch {}
  # 2) Fallback: delta via Get-NetAdapterStatistics
  try {
    $stats = Get-NetAdapterStatistics -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Loopback|isatap' }
    $rx = To-Double (($stats | Measure-Object -Property ReceivedBytes -Sum).Sum) 0
    $tx = To-Double (($stats | Measure-Object -Property SentBytes     -Sum).Sum) 0
  } catch { return @{ inMB = 0.0; outMB = 0.0 } }
  $now = Get-Date
  if ($Script:_lastNet) {
    $dt = ($now - $Script:_lastNet.t).TotalSeconds
    if ($dt -lt 1) { $dt = 1 }
    $din = [math]::Max(0, $rx - $Script:_lastNet.rx) / $dt / 1MB
    $dout= [math]::Max(0, $tx - $Script:_lastNet.tx) / $dt / 1MB
  } else { $din = 0; $dout = 0 }
  $Script:_lastNet = @{ t = $now; rx = $rx; tx = $tx }
  return @{ inMB = [math]::Round($din, 3); outMB = [math]::Round($dout, 3) }
}



function Collect-Metrics {
  $os    = Get-CimInstance Win32_OperatingSystem
  $cs    = Get-CimInstance Win32_ComputerSystem
  $cpuInfo = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
  $cpuModel = if ($cpuInfo) { ($cpuInfo.Name -replace '\s+', ' ').Trim() } else { 'CPU desconocida' }
  $cpuPct= Get-CpuPercent
  $cpuCores = @(Get-CpuCores)
  $totMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
  $freMB = [math]::Round($os.FreePhysicalMemory   / 1024, 0)
  $ramPct= if ($totMB -gt 0) { [math]::Round((($totMB - $freMB) / $totMB) * 100, 1) } else { 0 }
  $totGB = [math]::Round($totMB / 1024, 1)

  # Aggregate fixed disks
  $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
  $tot   = ($disks | Measure-Object -Property Size      -Sum).Sum
  $fre   = ($disks | Measure-Object -Property FreeSpace -Sum).Sum
  $diskPct = if ($tot -gt 0) { [math]::Round((($tot - $fre) / $tot) * 100, 1) } else { 0 }
  $totalDiskGB = if ($tot -gt 0) { [math]::Round($tot / 1GB, 1) } else { 0 }
  $totalDiskStr = if ($totalDiskGB -ge 1024) { "{0:N2} TB" -f ($totalDiskGB/1024) } else { "$totalDiskGB GB" }

  $net = Get-NetRates
  $up  = (Get-Date) - $os.LastBootUpTime
  $uptime = "{0}d {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes

  $gpuStr = ''
  try {
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -and $_.Name -notmatch 'Basic Display|Remote' } |
            Select-Object -ExpandProperty Name
    if ($gpus) { $gpuStr = ($gpus -join ', ') }
  } catch {}
  if (-not $gpuStr) { $gpuStr = 'GPU desconocida' }

  $mbStr = ''
  try {
    $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bb) { $mbStr = (("{0} {1}" -f $bb.Manufacturer, $bb.Product) -replace '\s+', ' ').Trim() }
  } catch {}
  if (-not $mbStr) { $mbStr = 'Desconocida' }

  $macStr = ''
  try {
    $adapters = Get-NetAdapter -ErrorAction Stop |
                Where-Object { $_.Status -eq 'Up' -and $_.MacAddress -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|Bluetooth|VPN' }
    $parts = @()
    foreach ($a in $adapters) { $parts += ("{0}={1}" -f $a.Name, $a.MacAddress) }
    $macStr = ($parts -join ',')
  } catch {
    try {
      $nics = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue
      $parts = @()
      foreach ($n in $nics) { if ($n.MACAddress) { $parts += ("{0}={1}" -f $n.Description, $n.MACAddress) } }
      $macStr = ($parts -join ',')
    } catch {}
  }

  $latencyMs = 0
  try {
    $ping = @(Test-Connection -ComputerName '1.1.1.1' -Count 1 -ErrorAction SilentlyContinue)
    if ($ping -and $ping.Count -gt 0) {
      $rt = $ping[0].ResponseTime
      if ($rt -is [array]) { $rt = $rt[0] }
      if ($rt -ne $null) { $latencyMs = To-Int $rt 0 }
    }
  } catch { $latencyMs = 0 }

  [pscustomobject]@{
    hostname      = $env:COMPUTERNAME
    os            = $os.Caption
    kernel        = $os.Version
    arch          = $env:PROCESSOR_ARCHITECTURE
    cores         = [int]$cs.NumberOfLogicalProcessors
    cpu_model     = $cpuModel
    total_ram     = "$totGB GB"
    total_disk    = $totalDiskStr
    public_ip     = (Get-PubIp)
    private_ip    = (Get-PrivIp)
    uptime        = $uptime
    cpu           = To-Double $cpuPct 0
    cpu_cores     = @($cpuCores | ForEach-Object { To-Double $_ 0 })
    ram           = To-Double $ramPct 0
    disk          = To-Double $diskPct 0
    network_in    = To-Double $net.inMB 0
    network_out   = To-Double $net.outMB 0
    load_avg      = @{ '1' = To-Double $cpuPct 0; '5' = To-Double $cpuPct 0; '15' = To-Double $cpuPct 0 }
    gpu           = $gpuStr
    motherboard   = $mbStr
    mac_address   = $macStr
    latency_ms    = [int]$latencyMs
    agent_version = $AgentVersion
  }
}

function Collect-Processes {
  try {
    $procs = Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.Id -gt 0 } |
             Sort-Object -Property CPU -Descending |
             Select-Object -First 200
    $list = @()
    foreach ($p in $procs) {
      $list += [pscustomobject]@{
        pid     = [int]$p.Id
        user    = ''
        name    = $p.ProcessName
        cpu     = [math]::Round((To-Double $p.CPU 0), 1)
        mem     = 0
        mem_mb  = [math]::Round($p.WorkingSet64 / 1MB, 1)
        command = ($p.Path | ForEach-Object { if ($_) { $_ } else { $p.ProcessName } })
      }
    }
    return ,$list
  } catch { return ,@() }
}

function Collect-Ports {
  $list = @()
  try {
    $conns = Get-NetTCPConnection -State Listen -ErrorAction Stop
    foreach ($c in $conns) {
      $pname = ''
      try { $pname = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch {}
      $list += [pscustomobject]@{
        protocol = 'tcp'
        port     = [int]$c.LocalPort
        address  = "$($c.LocalAddress)"
        process  = $pname
        pid      = [int]$c.OwningProcess
      }
    }
    $udps = Get-NetUDPEndpoint -ErrorAction SilentlyContinue
    foreach ($u in $udps) {
      $pname = ''
      try { $pname = (Get-Process -Id $u.OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch {}
      $list += [pscustomobject]@{
        protocol = 'udp'
        port     = [int]$u.LocalPort
        address  = "$($u.LocalAddress)"
        process  = $pname
        pid      = [int]$u.OwningProcess
      }
    }
  } catch {
    # Fallback netstat (Windows 7 / 2008 R2)
    try {
      $lines = netstat -ano | Select-String -Pattern '^\s+(TCP|UDP)\s'
      foreach ($l in $lines) {
        $parts = ($l.ToString().Trim() -split '\s+')
        if ($parts.Length -lt 4) { continue }
        $proto = $parts[0].ToLower()
        $local = $parts[1]
        $state = if ($proto -eq 'tcp') { $parts[3] } else { '' }
        if ($proto -eq 'tcp' -and $state -ne 'LISTENING') { continue }
        $procId = $parts[$parts.Length - 1]
        $i = $local.LastIndexOf(':')
        if ($i -lt 0) { continue }
        $addr = $local.Substring(0, $i)
        $port = [int]$local.Substring($i + 1)
        $pname = ''
        try { $pname = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName } catch {}
        $list += [pscustomobject]@{ protocol=$proto; port=$port; address=$addr; process=$pname; pid=[int]$procId }
      }
    } catch {}
  }
  return ,$list
}

function Collect-Disks {
  $list = @()
  try {
    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop
    foreach ($d in $disks) {
      $total = [int64]$d.Size
      if ($total -le 0) { continue }
      $free  = [int64]$d.FreeSpace
      $used  = $total - $free
      $pct   = [math]::Round(($used / $total) * 100, 1)
      $list += [pscustomobject]@{
        device       = $d.DeviceID
        mountpoint   = $d.DeviceID
        fstype       = ($d.FileSystem | ForEach-Object { if ($_) { $_ } else { 'unknown' } })
        total_bytes  = $total
        used_bytes   = $used
        free_bytes   = $free
        use_percent  = $pct
      }
    }
  } catch {}
  return ,$list
}

function Collect-Services {
  $list = @()
  try {
    $svcs = Get-Service -ErrorAction Stop
    foreach ($s in $svcs) {
      $status = switch ($s.Status.ToString()) {
        'Running' { 'running' }
        'Stopped' { 'stopped' }
        'Paused'  { 'stopped' }
        default   { $s.Status.ToString().ToLower() }
      }
      $list += [pscustomobject]@{
        name         = $s.Name
        display_name = $s.DisplayName
        status       = $status
        type         = 'windows-service'
      }
    }
  } catch {}
  return ,$list
}

$Script:_appActive = @{}
$Script:_appOpen = @{}
$Script:_appFirst = @{}
$Script:_appLast = @{}
$Script:_appLabels = @{}
$Script:_appLastSampleAt = $null

try {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ToroForegroundWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
}
"@ -ErrorAction SilentlyContinue
} catch {}

function Normalize-AppKey($name) {
  $s = ("$name").ToLowerInvariant() -replace '[^a-z0-9._-]', '_'
  if ($s.Length -gt 60) { $s = $s.Substring(0, 60) }
  return $s
}

function Get-AppDisplayName($p) {
  if (-not $p) { return $null }
  try {
    $desc = $p.MainModule.FileVersionInfo.FileDescription
    if ($desc -and $desc.Trim().Length -gt 1) { return $desc.Trim() }
  } catch {}
  try {
    if ($p.ProcessName) { return $p.ProcessName }
  } catch {}
  return $null
}

function Test-UserFacingProcess($p) {
  if (-not $p) { return $false }
  try { if ($p.MainWindowHandle -eq 0 -or -not $p.MainWindowTitle) { return $false } } catch { return $false }
  $n = ("$($p.ProcessName)").ToLowerInvariant()
  if ($n -match '^(system|idle|registry|memory compression|dwm|explorer|taskhostw|sihost|runtimebroker|searchhost|startmenuexperiencehost|applicationframehost|textinputhost|securityhealthsystray)$') { return $false }
  if ($n -match '(helper|crashpad|updater|update|service|broker)$') { return $false }
  return $true
}

function Get-ForegroundAppName {
  try {
    $hwnd = [ToroForegroundWin]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $pid = 0
    [void][ToroForegroundWin]::GetWindowThreadProcessId($hwnd, [ref]$pid)
    if ($pid -le 0) { return $null }
    $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
    if (Test-UserFacingProcess $p) { return (Get-AppDisplayName $p) }
  } catch {}
  return $null
}

function Get-OpenAppNames {
  try {
    $names = New-Object System.Collections.ArrayList
    Get-Process -ErrorAction SilentlyContinue |
      Where-Object { Test-UserFacingProcess $_ } |
      ForEach-Object {
        $name = Get-AppDisplayName $_
        if ($name -and -not $names.Contains($name)) { [void]$names.Add($name) }
      }
    return ,$names.ToArray()
  } catch { return @() }
}

function Add-AppSeconds($bucket, $name, [int]$seconds) {
  if (-not $name) { return }
  $key = Normalize-AppKey $name
  if (-not $key) { return }
  if (-not $bucket.ContainsKey($key)) { $bucket[$key] = 0 }
  $bucket[$key] = [int]$bucket[$key] + $seconds
  if (-not $Script:_appLabels.ContainsKey($key)) { $Script:_appLabels[$key] = "$name" }
  $nowIso = (Get-Date).ToUniversalTime().ToString('o')
  if (-not $Script:_appFirst.ContainsKey($key)) { $Script:_appFirst[$key] = $nowIso }
  $Script:_appLast[$key] = $nowIso
}

function Sample-Apps([int]$seconds) {
  Add-AppSeconds $Script:_appActive (Get-ForegroundAppName) $seconds
  foreach ($name in (Get-OpenAppNames)) { Add-AppSeconds $Script:_appOpen $name $seconds }
}

function Build-AppsPayload {
  $keys = @(@($Script:_appActive.Keys) + @($Script:_appOpen.Keys) | Sort-Object -Unique)
  $apps = @()
  foreach ($k in $keys) {
    $apps += [pscustomobject]@{
      key = $k
      label = if ($Script:_appLabels.ContainsKey($k)) { $Script:_appLabels[$k] } else { $k }
      source = 'gui'
      seconds_active = if ($Script:_appActive.ContainsKey($k)) { [int]$Script:_appActive[$k] } else { 0 }
      seconds_open = if ($Script:_appOpen.ContainsKey($k)) { [int]$Script:_appOpen[$k] } else { 0 }
      first_seen = if ($Script:_appFirst.ContainsKey($k)) { $Script:_appFirst[$k] } else { $null }
      last_seen = if ($Script:_appLast.ContainsKey($k)) { $Script:_appLast[$k] } else { $null }
    }
  }
  return @{ date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'); mode = 'delta'; apps = $apps }
}

function Reset-AppCounters {
  $Script:_appActive = @{}
  $Script:_appOpen = @{}
}

function Encrypt-Payload($json, $pass) {
  # AES-256-CBC + PBKDF2 (SHA-256, 10000 iters), formato OpenSSL "Salted__" base64.
  # Compatible con: openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -pass pass:$pass
  try {
    $salt = New-Object byte[] 8
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $kdf  = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pass, $salt, 10000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $key  = $kdf.GetBytes(32)
    $iv   = $kdf.GetBytes(16)
    $aes  = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key; $aes.IV = $iv; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ct    = $aes.CreateEncryptor().TransformFinalBlock($bytes, 0, $bytes.Length)
    $magic = [System.Text.Encoding]::ASCII.GetBytes('Salted__')
    $out   = New-Object byte[] ($magic.Length + $salt.Length + $ct.Length)
    [Array]::Copy($magic, 0, $out, 0, 8)
    [Array]::Copy($salt,  0, $out, 8, 8)
    [Array]::Copy($ct,    0, $out, 16, $ct.Length)
    return [Convert]::ToBase64String($out)
  } catch {
    return $null
  }
}

function Invoke-PostWithCurl($endpoint, $bodyPath, $contentType, [bool]$encrypted) {
  try {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return $null }
    $out = Join-Path $env:TEMP ("toro-resp-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    $args = @(
      '-k','-L','-sS','--max-time','30',
      '-X','POST', $endpoint,
      '-H', ("Authorization: Bearer {0}" -f $Token),
      '-H', ("Content-Type: {0}" -f $contentType)
    )
    if ($encrypted) { $args += @('-H', 'X-Encrypted: aes-256-cbc-pbkdf2') }
    $args += @('--data-binary', ("@{0}" -f $bodyPath), '-o', $out, '-w', '%{http_code}')

    $rawCode = (& curl.exe @args 2>&1 | Out-String).Trim()
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
      W-Log ("curl POST {0} failed exit={1}: {2}" -f $endpoint, $exit, $rawCode)
      Remove-Item $out -Force -ErrorAction SilentlyContinue
      return $null
    }

    $statusText = ($rawCode -replace '[^0-9]', '')
    if ($statusText.Length -gt 3) { $statusText = $statusText.Substring($statusText.Length - 3) }
    $status = 0
    try { $status = [int]$statusText } catch {}
    $text = ''
    try { if (Test-Path $out) { $text = Get-Content $out -Raw -ErrorAction SilentlyContinue } } catch {}
    Remove-Item $out -Force -ErrorAction SilentlyContinue

    if ($status -lt 200 -or $status -ge 300) {
      W-Log ("curl POST {0} http={1}: {2}" -f $endpoint, $status, $text)
      return $null
    }
    if (-not $text -or $text.Trim().Length -eq 0) { return [pscustomobject]@{ ok = $true } }
    try { return ($text | ConvertFrom-Json) } catch { return [pscustomobject]@{ ok = $true; raw = $text } }
  } catch {
    W-Log ("curl POST {0} error: {1}" -f $endpoint, $_.Exception.Message)
    return $null
  }
}

function Post-Json($endpoint, $payload) {
  $bodyFile = Join-Path $env:TEMP ("toro-body-{0}.txt" -f ([guid]::NewGuid().ToString('N')))
  try {
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $enc  = Encrypt-Payload $json $Token
    if ($enc) {
      $headers = @{ Authorization = "Bearer $Token"; 'X-Encrypted' = 'aes-256-cbc-pbkdf2' }
      [System.IO.File]::WriteAllText($bodyFile, $enc, [System.Text.Encoding]::ASCII)
      $curlResp = Invoke-PostWithCurl $endpoint $bodyFile 'text/plain' $true
      if ($curlResp) { return $curlResp }
      Enable-ModernTls
      $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Body $enc -ContentType 'text/plain' -Headers $headers -TimeoutSec 30
    } else {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
      $headers = @{ Authorization = "Bearer $Token" }
      [System.IO.File]::WriteAllBytes($bodyFile, $bytes)
      $curlResp = Invoke-PostWithCurl $endpoint $bodyFile 'application/json; charset=utf-8' $false
      if ($curlResp) { return $curlResp }
      Enable-ModernTls
      $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Body $bytes -ContentType 'application/json; charset=utf-8' -Headers $headers -TimeoutSec 30
    }
    return $resp
  } catch {
    W-Log "POST $endpoint failed: $($_.Exception.Message)"
    return $null
  } finally {
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-IngestEndpoint($suffix) {
  $publicBase = if ($env:PUBLIC_INGEST_BASE) { $env:PUBLIC_INGEST_BASE } else { 'https://project--de5cadf8-756e-4d2f-8f8b-6ca62009361b-dev.lovable.app/api/public/ingest' }
  if ($Url -match 'functions\.supabase\.co/ingest-metrics') { return "$publicBase/$suffix" }
  if ($Url -match '/metrics$') { return ($Url -replace '/metrics$', "/$suffix") }
  return "$publicBase/$suffix"
}

function Check-SelfUpdate($resp) {
  if (-not $resp) { return }
  $updateTo = $null
  try { $updateTo = $resp.update_to } catch {}
  if (-not $updateTo) { return }
  $base = ($AgentVersion -split '-')[0]
  if ($updateTo -eq $base) { return }
  W-Log "update_to=$updateTo solicitada - reinstalando agente"
  try {
    $newScript = Join-Path $env:TEMP ("torobyte-agent.new.{0}.ps1" -f $PID)
    if (-not (Download-AgentScript $newScript)) { throw 'no se pudo descargar update' }
    $env:AGENT_TOKEN = $Token; $env:INGEST_URL = $Url; $env:INTERVAL = "$script:Interval"; $env:MODE = 'install'
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$newScript) -WindowStyle Hidden
    Start-Sleep -Seconds 2
    exit 0
  } catch {
    W-Log "self-update failed: $($_.Exception.Message)"
  }
}

function Run-AgentLoop {
  if (-not $Token -or -not $Url) { W-Log 'AGENT_TOKEN/INGEST_URL faltantes - saliendo'; exit 1 }
  $procUrl = Get-IngestEndpoint 'processes'
  $portUrl = Get-IngestEndpoint 'ports'
  $diskUrl = Get-IngestEndpoint 'disks'
  $svcUrl  = Get-IngestEndpoint 'services'
  $appsUrl = Get-IngestEndpoint 'apps'

  W-Log "torobyte-agent $AgentVersion started interval=$Interval endpoint=$Url"
  [void](Get-NetRates)

  while ($true) {
    $cycleOk = $false
    try {
      $m = Collect-Metrics
      $resp = Post-Json $Url $m
      if ($resp) {
        $cycleOk = $true
        W-Log 'metrics ok'
        Check-SelfUpdate $resp
        $newInt = $null
        try { $newInt = [int]$resp.interval } catch {}
        if ($newInt -and $newInt -ge 5 -and $newInt -le 86400 -and $newInt -ne $script:Interval) {
          W-Log ("interval cambiado {0}s -> {1}s" -f $script:Interval, $newInt)
          $script:Interval = $newInt
        }
      } else {
        W-Log 'metrics failed'
      }
      Post-Json $procUrl @{ processes = (Collect-Processes) } | Out-Null
      Post-Json $portUrl @{ ports     = (Collect-Ports) }     | Out-Null
      Post-Json $diskUrl @{ disks     = (Collect-Disks) }     | Out-Null
      Post-Json $svcUrl  @{ services  = (Collect-Services) }  | Out-Null
      $sampleNow = Get-Date
      if ($null -eq $Script:_appLastSampleAt) {
        $sampleDelta = [Math]::Max(5, [int]$script:Interval)
      } else {
        $sampleDelta = [int][Math]::Round(($sampleNow - $Script:_appLastSampleAt).TotalSeconds)
        if ($sampleDelta -lt 1) { $sampleDelta = 1 }
        if ($sampleDelta -gt 300) { $sampleDelta = 300 }
      }
      $Script:_appLastSampleAt = $sampleNow
      Sample-Apps $sampleDelta
      Post-Json $appsUrl (Build-AppsPayload) | Out-Null
      Reset-AppCounters
    } catch {
      W-Log "loop error: $($_.Exception.Message)"
    }
    if ($env:ONCE -eq '1') { return $cycleOk }
    Start-Sleep -Seconds $script:Interval
  }
}

function Install-Agent {
  Write-Host ""
  Write-Host ("Torobyte Monitor Agent - Instalacion {0}" -f $AgentVersion) -ForegroundColor White
  Write-Host ""

  $total = 7
  W-Step 1 $total 'Validando parametros...'
  if (-not $Token) { W-Fail 'AGENT_TOKEN requerido' }
  if (-not $Url)   { W-Fail 'INGEST_URL requerido' }
  W-Ok ("token={0}...  url={1}" -f $Token.Substring(0,[Math]::Min(8,$Token.Length)), $Url)

  W-Step 2 $total 'Verificando privilegios de Administrador...'
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { W-Fail 'Ejecuta PowerShell como Administrador' }
  W-Ok 'OK'

  W-Step 3 $total ("Creando carpeta de instalacion: {0}" -f $InstallDir)
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  W-Ok 'OK'

  W-Step 4 $total 'Descargando agente...'
  if (-not (Download-AgentScript $ScriptPath)) { W-Fail 'no se pudo descargar el script del agente. Revisa C:\ProgramData\TorobyteAgent\agent.log' }
  W-Ok ("{0} bytes" -f (Get-Item $ScriptPath).Length)

  W-Step 5 $total 'Enviando primera metrica de prueba...'
  $env:ONCE = '1'; $env:MODE = 'run'
  try {
    $firstMetricOk = Run-AgentLoop
    if (-not $firstMetricOk) { W-Fail 'primera metrica fallo: no se pudo conectar con la plataforma. Revisa el log mostrado arriba.' }
  } catch { W-Fail ("primera metrica fallo: {0}" -f $_.Exception.Message) }
  $env:ONCE = ''
  W-Ok 'OK - el servidor pasara a "en linea"'

  W-Step 6 $total 'Registrando tarea programada (TorobyteAgent)...'
  & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
  # Persistir variables a nivel de maquina para que la tarea las herede
  [Environment]::SetEnvironmentVariable('AGENT_TOKEN', $Token,    'Machine')
  [Environment]::SetEnvironmentVariable('INGEST_URL',  $Url,      'Machine')
  [Environment]::SetEnvironmentVariable('INTERVAL',    "$Interval",'Machine')
  [Environment]::SetEnvironmentVariable('MODE',        'run',     'Machine')
  $action = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
  & schtasks.exe /Create /TN $TaskName /SC ONSTART /RL HIGHEST /RU SYSTEM /F /TR $action | Out-Null
  if ($LASTEXITCODE -ne 0) { W-Fail 'no se pudo crear la tarea programada' }
  W-Ok 'tarea creada'

  W-Step 7 $total 'Iniciando agente en background...'
  & schtasks.exe /Run /TN $TaskName | Out-Null
  Start-Sleep -Seconds 2
  $proc = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and $_.CommandLine -match 'torobyte-agent.ps1' } catch { $false }
  }
  W-Ok 'agente en ejecucion'

  Write-Host ""
  Write-Host "Instalacion completada" -ForegroundColor Green
  Write-Host ("  script: {0}" -f $ScriptPath)
  Write-Host ("  log:    {0}" -f $LogPath)
  Write-Host ("  tarea:  {0}" -f $TaskName)
  Write-Host ""
}

function Uninstall-Agent {
  Write-Host ""
  Write-Host "Torobyte Monitor Agent - Desinstalacion" -ForegroundColor White
  Write-Host ""
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { W-Fail 'Ejecuta PowerShell como Administrador' }
  & schtasks.exe /End /TN $TaskName 2>$null | Out-Null
  & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
  W-Ok 'tarea programada eliminada'
  Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    try { $_.CommandLine -match 'torobyte-agent.ps1' } catch { $false }
  } | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {} }
  W-Ok 'procesos detenidos'
  [Environment]::SetEnvironmentVariable('AGENT_TOKEN', $null, 'Machine')
  [Environment]::SetEnvironmentVariable('INGEST_URL',  $null, 'Machine')
  [Environment]::SetEnvironmentVariable('INTERVAL',    $null, 'Machine')
  [Environment]::SetEnvironmentVariable('MODE',        $null, 'Machine')
  if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue }
  W-Ok 'archivos eliminados'
  Write-Host ""
  Write-Host "Agente desinstalado" -ForegroundColor Green
  Write-Host "  Recuerda eliminar el servidor desde la plataforma si ya no lo necesitas."
  Write-Host ""
}

# Modo de ejecucion
if ($Mode -eq 'run') {
  Run-AgentLoop
} elseif ($Mode -eq 'uninstall' -or $Mode -eq 'remove') {
  Uninstall-Agent
} else {
  Install-Agent
}
