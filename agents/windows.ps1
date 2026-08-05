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

$AgentVersion = '2.3.2-windows-safe'
$Token        = if ($env:AGENT_TOKEN) { $env:AGENT_TOKEN } else { $env:TOKEN }
$Url          = if ($env:INGEST_URL)  { $env:INGEST_URL }  else { $env:URL }
$Interval     = if ($env:INTERVAL)    { [int]$env:INTERVAL } else { 5 }
if ($Interval -lt 5) { $Interval = 5 }
$Mode         = if ($env:MODE) { $env:MODE } else { 'install' }

$InstallDir   = Join-Path $env:ProgramData 'TorobyteAgent'
$ScriptPath   = Join-Path $InstallDir 'torobyte-agent.ps1'
$LogPath      = Join-Path $InstallDir 'agent.log'
$TaskName     = 'TorobyteAgent'
$SessionsTaskName = 'TorobyteAgentSessions'
$ShutdownTaskName = 'TorobyteAgentShutdown'
$SessionsVbsPath  = Join-Path $InstallDir 'torobyte-sessions.vbs'
$ShutdownPsPath   = Join-Path $InstallDir 'torobyte-shutdown.ps1'
$ShutdownVbsPath  = Join-Path $InstallDir 'torobyte-shutdown.vbs'
# Rutas de flags de ubicacion eliminadas


function W-Log($msg) {
  $line = "[$((Get-Date).ToString('o'))] $msg"
  Write-Host $line
  try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
}
function W-Step($n, $total, $msg) { Write-Host ("[{0}/{1}] {2}" -f $n,$total,$msg) -ForegroundColor Cyan }
function W-Ok($msg)   { Write-Host ("      OK   {0}" -f $msg) -ForegroundColor Green }
function W-Fail($msg) { Write-Host ("      FAIL {0}" -f $msg) -ForegroundColor Red; exit 1 }

function Start-HiddenPowerShell($path) {
  $quotedPath = '"' + $path + '"'
  $command = "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedPath"
  try {
    $startup = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
    $startup.ShowWindow = 0
    $result = ([wmiclass]'Win32_Process').Create($command, $null, $startup)
    if ($result.ReturnValue -eq 0) { return $true }
  } catch {}
  try {
    Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$path) -WindowStyle Hidden | Out-Null
    return $true
  } catch { return $false }
}

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
    
    # Se omitió certutil.exe por ser frecuentemente detectado como comportamiento de malware (Living off the Land)
    
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
function Get-WifiAps {
  # Redes Wi-Fi cercanas (BSSID + señal) eliminadas por privacidad y solicitud del usuario.
  return ,@()
}

# Funciones de geolocalizacion y consentimiento eliminadas por solicitud del usuario.
function Enable-LocationService { return }
function Get-UserGeoFix { return $null }
function Get-UserConsentPath { return $null }
function Set-GpsConsent { return }
function Get-GpsConsent { return $null }
function Grant-LocationCapability { return }

function Show-LocationConsentDialog {
  # Eliminado por solicitud del usuario: no se solicita ubicacion.
  return 'denied'
}

function Request-UserLocationConsent {
  # Eliminado por solicitud del usuario: no se solicita ubicacion.
  return
}


function Get-NativeGeo {
  return $null
}



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

  $manufacturer = ''
  $hwModel = ''
  try {
    if ($cs) {
      if ($cs.Manufacturer) { $manufacturer = ($cs.Manufacturer -replace '\s+', ' ').Trim() }
      if ($cs.Model)        { $hwModel      = ($cs.Model        -replace '\s+', ' ').Trim() }
    }
  } catch {}
  $serialNumber = ''
  try {
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bios -and $bios.SerialNumber) { $serialNumber = ($bios.SerialNumber -replace '\s+', ' ').Trim() }
  } catch {}

  
  # Geolocalizacion desactivada por el usuario.
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
    wifi_aps      = @()
    # latitude / longitude / gps_consent removidos




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
    manufacturer  = $manufacturer
    hw_model      = $hwModel
    serial_number = $serialNumber
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

function Collect-Programs {
  $list = @()
  $paths = @(
    @{ p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             a = 'x64' },
    @{ p = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; a = 'x86' },
    @{ p = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             a = 'user' }
  )
  $seen = @{}
  foreach ($entry in $paths) {
    try {
      $items = Get-ItemProperty -Path $entry.p -ErrorAction SilentlyContinue
      foreach ($it in $items) {
        try {
          $name = $it.DisplayName
          if (-not $name) { continue }
          if ($it.SystemComponent -eq 1) { continue }
          if ($it.ReleaseType -and ($it.ReleaseType -match 'Update|Hotfix|Security Update')) { continue }
          if ($it.ParentKeyName) { continue }
          $ver = "$($it.DisplayVersion)"
          $key = "$name|$ver"
          if ($seen.ContainsKey($key)) { continue }
          $seen[$key] = $true
          $sizeMb = $null
          try { if ($it.EstimatedSize) { $sizeMb = [Math]::Round(([double]$it.EstimatedSize) / 1024, 1) } } catch {}
          $instDate = $null
          try { if ($it.InstallDate -match '^\d{8}$') { $instDate = "$($it.InstallDate)" } } catch {}
          $list += [pscustomobject]@{
            name             = "$name"
            version          = $ver
            publisher        = "$($it.Publisher)"
            install_date     = $instDate
            install_location = "$($it.InstallLocation)"
            size_mb          = $sizeMb
            arch             = $entry.a
            source           = 'registry'
          }
        } catch {}
      }
    } catch {}
  }
  # Aplicaciones de la Microsoft Store (AppX)
  try {
    $appx = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable }
    foreach ($a in $appx) {
      $name = "$($a.Name)"
      if (-not $name) { continue }
      $ver = "$($a.Version)"
      $key = "$name|$ver"
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      $list += [pscustomobject]@{
        name             = $name
        version          = $ver
        publisher        = "$($a.Publisher)"
        install_date     = $null
        install_location = "$($a.InstallLocation)"
        size_mb          = $null
        arch             = "$($a.Architecture)"
        source           = 'store'
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

# ---------------------- Sesiones de foreground (v2.0.0) --------------------
$Script:_curSession   = $null   # sesion foreground en curso
$Script:_sessionQueue = New-Object System.Collections.ArrayList
$Script:_curIdle      = $null
$Script:_idleQueue    = New-Object System.Collections.ArrayList
$Script:_idleThresholdSec = if ($env:IDLE_THRESHOLD_SECONDS) { [int]$env:IDLE_THRESHOLD_SECONDS } else { 180 }
$Script:_sessionSampleSec = if ($env:SESSION_SAMPLE_SECONDS) { [int]$env:SESSION_SAMPLE_SECONDS } else { 2 }
if ($Script:_sessionSampleSec -lt 1) { $Script:_sessionSampleSec = 1 }

try {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class ToroForegroundWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  [DllImport("kernel32.dll")] public static extern uint GetTickCount();
}
"@ -ErrorAction SilentlyContinue
} catch {}

$Script:_uiAutomationReady = $false
try {
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
  $Script:_uiAutomationReady = $true
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
    $procId = 0
    [void][ToroForegroundWin]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    if ($procId -le 0) { return $null }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
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

# ---------------------- Sitios web visitados (dominio de la pestana activa) --------------
$Script:_webActive = @{}
$Script:_webBrowser = @{}
$Script:_webFirst = @{}
$Script:_webLast = @{}
$Script:_browserProcNames = @('chrome','msedge','firefox','brave','opera','vivaldi','iexplore','arc','waterfox','librewolf','msedgewebview2','operagx','tor','torbrowser','yandex','browser','palemoon','floorp','thorium','ucbrowser','maxthon','slimjet','centbrowser','epicprivacybrowser','duckduckgo','samsung','safari','chromium','ungoogled-chromium','iron','srware')

# ---------------- Persistencia local de contadores (anti-perdida) --------
$Script:_stateFile = Join-Path $InstallDir 'agent-state.json'

function ConvertTo-Hash($psobj) {
  $h = @{}
  if ($null -eq $psobj) { return $h }
  if ($psobj -is [hashtable]) { return $psobj }
  try { foreach ($p in $psobj.PSObject.Properties) { $h[$p.Name] = $p.Value } } catch {}
  return $h
}

function Save-AgentState {
  try {
    $obj = @{
      web = @{
        active  = $Script:_webActive
        browser = $Script:_webBrowser
        first   = $Script:_webFirst
        last    = $Script:_webLast
      }
      apps = @{
        active = $Script:_appActive
        open   = $Script:_appOpen
        first  = $Script:_appFirst
        last   = $Script:_appLast
        labels = $Script:_appLabels
      }
      sessions = @{
        queue   = @($Script:_sessionQueue)
        idle    = @($Script:_idleQueue)
        current = $Script:_curSession
        curIdle = $Script:_curIdle
      }
      saved_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $json = $obj | ConvertTo-Json -Depth 10 -Compress
    $tmp  = $Script:_stateFile + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
    Move-Item -Force -Path $tmp -Destination $Script:_stateFile -ErrorAction SilentlyContinue
  } catch {}
}

function Load-AgentState {
  try {
    if (-not (Test-Path $Script:_stateFile)) { return }
    $raw = Get-Content -Raw -Path $Script:_stateFile -ErrorAction Stop
    if (-not $raw) { return }
    $obj = $raw | ConvertFrom-Json
    if ($obj.web) {
      $Script:_webActive  = ConvertTo-Hash $obj.web.active
      $Script:_webBrowser = ConvertTo-Hash $obj.web.browser
      $Script:_webFirst   = ConvertTo-Hash $obj.web.first
      $Script:_webLast    = ConvertTo-Hash $obj.web.last
    }
    if ($obj.apps) {
      $Script:_appActive = ConvertTo-Hash $obj.apps.active
      $Script:_appOpen   = ConvertTo-Hash $obj.apps.open
      $Script:_appFirst  = ConvertTo-Hash $obj.apps.first
      $Script:_appLast   = ConvertTo-Hash $obj.apps.last
      $Script:_appLabels = ConvertTo-Hash $obj.apps.labels
    }
    if ($obj.sessions) {
      if ($obj.sessions.queue) { foreach ($it in @($obj.sessions.queue)) { [void]$Script:_sessionQueue.Add((ConvertTo-Hash $it)) } }
      if ($obj.sessions.idle)  { foreach ($it in @($obj.sessions.idle))  { [void]$Script:_idleQueue.Add((ConvertTo-Hash $it)) } }
      if ($obj.sessions.current) { $Script:_curSession = ConvertTo-Hash $obj.sessions.current }
      if ($obj.sessions.curIdle) { $Script:_curIdle    = ConvertTo-Hash $obj.sessions.curIdle }
    }
    W-Log ("estado local restaurado (web={0} apps={1} sess={2} idle={3})" -f $Script:_webActive.Count, $Script:_appActive.Count, $Script:_sessionQueue.Count, $Script:_idleQueue.Count)
  } catch { W-Log "load-state error: $($_.Exception.Message)" }
}

function Test-BrowserProc([string]$name) {
  if (-not $name) { return $false }
  $lower = $name.ToLowerInvariant()
  foreach ($b in $Script:_browserProcNames) { if ($lower -eq $b) { return $true } }
  return $false
}

function Normalize-WebDomain([string]$raw) {
  if (-not $raw) { return $null }
  $s = ($raw.Trim() -replace '^view-source:', '')
  if (-not $s) { return $null }
  try {
    if ($s -match '^[a-z][a-z0-9+.-]*://') {
      $u = [Uri]$s
      if ($u.Host) {
        $host = $u.Host.ToLowerInvariant()
        if ($host.StartsWith('www.')) { $host = $host.Substring(4) }
        if ($host -match '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { return $host }
      }
    }
  } catch {}
  $m = [regex]::Match($s, '(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:[a-z]{2,24}))\b')
  if ($m.Success) {
    $d = $m.Value.ToLowerInvariant()
    if ($d.StartsWith('www.')) { $d = $d.Substring(4) }
    if ($d -match '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { return $d }
  }
  return $null
}

function Get-BrowserDomainFromWindow([IntPtr]$hwnd) {
  if (-not $Script:_uiAutomationReady) { return $null }
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if (-not $root) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit
    )
    $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    for ($i = 0; $i -lt $edits.Count; $i++) {
      $el = $edits.Item($i)
      $candidates = @()
      try {
        $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp -and $vp.Current.Value) { $candidates += $vp.Current.Value }
      } catch {}
      try { if ($el.Current.Name) { $candidates += $el.Current.Name } } catch {}
      foreach ($candidate in $candidates) {
        $domain = Normalize-WebDomain $candidate
        if ($domain) { return $domain }
      }
    }
  } catch {}
  return $null
}

function Extract-DomainFromTitle([string]$title) {
  if (-not $title) { return $null }
  # Quitar sufijos tipicos " - Google Chrome" / " — Mozilla Firefox" / " - Microsoft Edge" etc.
  $clean = $title -replace '\s+[\-\u2014\u2013\u2015\|]\s+(Google Chrome|Chromium|Mozilla Firefox|Microsoft.? Edge|Brave|Vivaldi|Opera( GX)?|Arc|Waterfox|LibreWolf|Internet Explorer)(\s+\(.*\))?$', ''
  # Buscar patron de dominio dentro del titulo
  $m = [regex]::Match($clean, '(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:[a-z]{2,24}))\b')
  if ($m.Success) {
    $d = $m.Value.ToLowerInvariant()
    if ($d.StartsWith('www.')) { $d = $d.Substring(4) }
    return $d
  }
  return $null
}

function Get-ForegroundDomain {
  try {
    $hwnd = [ToroForegroundWin]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $procId = 0
    [void][ToroForegroundWin]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    if ($procId -le 0) { return $null }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    if (-not (Test-BrowserProc $p.ProcessName)) { return $null }
    $domain = Get-BrowserDomainFromWindow $hwnd
    if ($domain) { return @{ domain = $domain; browser = $p.ProcessName.ToLowerInvariant() } }
    $sb = New-Object System.Text.StringBuilder 512
    [void][ToroForegroundWin]::GetWindowText($hwnd, $sb, 512)
    $title = $sb.ToString()
    $domain = Extract-DomainFromTitle $title
    if (-not $domain) { return $null }
    return @{ domain = $domain; browser = $p.ProcessName.ToLowerInvariant() }
  } catch {}
  return $null
}

function Add-WebSeconds([string]$domain, [string]$browser, [int]$seconds) {
  if (-not $domain -or $seconds -le 0) { return }
  if (-not $Script:_webActive.ContainsKey($domain)) { $Script:_webActive[$domain] = 0 }
  $Script:_webActive[$domain] = [int]$Script:_webActive[$domain] + $seconds
  if ($browser -and -not $Script:_webBrowser.ContainsKey($domain)) { $Script:_webBrowser[$domain] = $browser }
  $nowIso = (Get-Date).ToUniversalTime().ToString('o')
  if (-not $Script:_webFirst.ContainsKey($domain)) { $Script:_webFirst[$domain] = $nowIso }
  $Script:_webLast[$domain] = $nowIso
}

function Sample-Websites([int]$seconds) {
  $info = Get-ForegroundDomain
  if ($info) { Add-WebSeconds $info.domain $info.browser $seconds }
}

function Build-WebsitesPayload {
  $sites = @()
  foreach ($k in @($Script:_webActive.Keys)) {
    $sites += [pscustomobject]@{
      domain = $k
      browser = if ($Script:_webBrowser.ContainsKey($k)) { $Script:_webBrowser[$k] } else { $null }
      seconds_active = [int]$Script:_webActive[$k]
      first_seen = if ($Script:_webFirst.ContainsKey($k)) { $Script:_webFirst[$k] } else { $null }
      last_seen  = if ($Script:_webLast.ContainsKey($k)) { $Script:_webLast[$k] } else { $null }
    }
  }
  return @{ date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'); mode = 'delta'; websites = $sites }
}

function Reset-WebCounters {
  $Script:_webActive = @{}
  $Script:_webBrowser = @{}
  $Script:_webFirst = @{}
  $Script:_webLast = @{}
}

# ------------- Foreground sessions v2 (idempotentes por UUID) --------------
function New-SessionUuid { return [guid]::NewGuid().ToString().ToLowerInvariant() }
function Iso-Now { return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }

function Get-IdleSeconds {
  try {
    $l = New-Object ToroForegroundWin+LASTINPUTINFO
    $l.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($l)
    if ([ToroForegroundWin]::GetLastInputInfo([ref]$l)) {
      $tick = [ToroForegroundWin]::GetTickCount()
      $diff = $tick - $l.dwTime
      return [int]([Math]::Max(0, [double]$diff / 1000.0))
    }
  } catch {}
  return 0
}

function Get-ForegroundSessionInfo {
  try {
    $hwnd = [ToroForegroundWin]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $procId = 0
    [void][ToroForegroundWin]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    if ($procId -le 0) { return $null }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not (Test-UserFacingProcess $p)) { return $null }
    $sb = New-Object System.Text.StringBuilder 512
    [void][ToroForegroundWin]::GetWindowText($hwnd, $sb, 512)
    $procName = $null
    try { $procName = $p.ProcessName } catch {}
    $osUser = $null
    try { $osUser = [Environment]::UserName } catch {}
    return @{
      app_name = (Get-AppDisplayName $p)
      process_name = $procName
      pid = $procId
      window_title = $sb.ToString()
      os_user = $osUser
    }
  } catch {}
  return $null
}

function Close-Session($sIn, [string]$endIso, [bool]$idleInterrupt=$false) {
  if (-not $sIn) { return }
  $s = ConvertTo-Hash $sIn
  if (-not $s.started_at) { return }
  $startMs = ([datetime]::Parse($s.started_at)).ToUniversalTime().Ticks
  $endMs   = ([datetime]::Parse($endIso)).ToUniversalTime().Ticks
  $durSec  = [int](($endMs - $startMs) / 10000000)
  if ($durSec -le 0) { return }
  [void]$Script:_sessionQueue.Add(@{
    session_uuid = $s.session_uuid
    application_name = $s.application_name
    process_name = $s.process_name
    bundle_id = $null
    window_title = $s.window_title
    started_at = $s.started_at
    ended_at = $endIso
    duration_seconds = $durSec
    foreground = $true
    window_visible = $true
    idle_interrupted = $idleInterrupt
    os_user = $s.os_user
  })
}

function Sample-Session {
  $nowIso = Iso-Now
  $idle = Get-IdleSeconds
  $sendTitle = $env:TRACK_WINDOW_TITLE -eq '1'

  if ($idle -ge $Script:_idleThresholdSec) {
    if ($Script:_curSession) { Close-Session $Script:_curSession $nowIso $true; $Script:_curSession = $null }
    if (-not $Script:_curIdle) {
      $Script:_curIdle = @{ session_uuid = (New-SessionUuid); started_at = $nowIso; reason = 'idle'; os_user = try { [Environment]::UserName } catch { $null } }
    }
    return
  }

  if ($Script:_curIdle) {
    $startMs = ([datetime]::Parse($Script:_curIdle.started_at)).ToUniversalTime().Ticks
    $endMs   = ([datetime]::Parse($nowIso)).ToUniversalTime().Ticks
    $dur = [int](($endMs - $startMs) / 10000000)
    [void]$Script:_idleQueue.Add(@{
      session_uuid = $Script:_curIdle.session_uuid
      started_at = $Script:_curIdle.started_at
      ended_at = $nowIso
      duration_seconds = [Math]::Max(0, $dur)
      reason = $Script:_curIdle.reason
      os_user = $Script:_curIdle.os_user
    })
    $Script:_curIdle = $null
  }

  $fg = Get-ForegroundSessionInfo
  if (-not $fg -or -not $fg.app_name) { return }

  if ($Script:_curSession -and
      $Script:_curSession.application_name -eq $fg.app_name -and
      $Script:_curSession.process_name -eq $fg.process_name) {
    $Script:_curSession.last_seen = $nowIso
    if ($sendTitle) { $Script:_curSession.window_title = $fg.window_title }
    return
  }
  if ($Script:_curSession) {
    Close-Session $Script:_curSession $nowIso $false
  }
  $Script:_curSession = @{
    session_uuid = (New-SessionUuid)
    application_name = $fg.app_name
    process_name = $fg.process_name
    window_title = if ($sendTitle) { $fg.window_title } else { $null }
    started_at = $nowIso
    last_seen = $nowIso
    os_user = $fg.os_user
  }
}

function Build-SessionsPayload {
  $sessions = @()
  foreach ($s in $Script:_sessionQueue) { $sessions += $s }
  # snapshot de la sesión en curso (upsert por UUID)
  if ($Script:_curSession) {
    $s = $Script:_curSession
    $startMs = ([datetime]::Parse($s.started_at)).ToUniversalTime().Ticks
    $endMs   = ([datetime]::Parse($s.last_seen)).ToUniversalTime().Ticks
    $dur = [int](($endMs - $startMs) / 10000000)
    if ($dur -gt 0) {
      $sessions += @{
        session_uuid = $s.session_uuid
        application_name = $s.application_name
        process_name = $s.process_name
        bundle_id = $null
        window_title = $s.window_title
        started_at = $s.started_at
        ended_at = $s.last_seen
        duration_seconds = $dur
        foreground = $true
        window_visible = $true
        idle_interrupted = $false
        os_user = $s.os_user
      }
    }
  }
  $idles = @()
  foreach ($i in $Script:_idleQueue) { $idles += $i }
  if ($Script:_curIdle) {
    $idles += @{
      session_uuid = $Script:_curIdle.session_uuid
      started_at = $Script:_curIdle.started_at
      ended_at = $null
      duration_seconds = $null
      reason = $Script:_curIdle.reason
      os_user = $Script:_curIdle.os_user
    }
  }
  return @{ agent_version = $AgentVersion; sessions = $sessions; idle_sessions = $idles }
}

function Reset-SessionQueues {
  $Script:_sessionQueue = New-Object System.Collections.ArrayList
  $Script:_idleQueue = New-Object System.Collections.ArrayList
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

$script:SecErrors = @()

# Los colectores escriben explícitamente en $script:*; así cada bloque puede
# aislar sus variables temporales sin perder los resultados de la auditoría.
function Try-Get($block, $label) {
  try { & $block }
  catch {
    if ($label) { $script:SecErrors += $label; W-Log "collect[$label]: $($_.Exception.Message)" }
    $null
  }
}

function Collect-Security {
  $script:SecErrors = @()
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  # -1 = desconocido. Nunca se reporta 0 si no se pudo consultar.
  $script:pending = -1; $script:critical = -1; $script:lastUpd = $null; $script:updSource = $null
  Try-Get {
    $Session = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
    $Searcher = $Session.CreateUpdateSearcher()
    $Searcher.Online = $true
    $r = $Searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    $script:pending = [int]$r.Updates.Count
    $script:critical = @($r.Updates | Where-Object { $_.MsrcSeverity -eq "Critical" -or $_.MsrcSeverity -eq "Important" }).Count
    $script:updSource = "com-online"
  } $null | Out-Null
  if ($pending -lt 0) {
    Try-Get {
      $Session = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
      $Searcher = $Session.CreateUpdateSearcher()
      $Searcher.Online = $false
      $r = $Searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
      $script:pending = [int]$r.Updates.Count
      $script:critical = @($r.Updates | Where-Object { $_.MsrcSeverity -eq "Critical" -or $_.MsrcSeverity -eq "Important" }).Count
      $script:updSource = "com-cache"
    } $null | Out-Null
  }
  if ($pending -lt 0) {
    Try-Get {
      $mod = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue
      if ($mod) {
        Import-Module PSWindowsUpdate -ErrorAction Stop
        $list = @(Get-WindowsUpdate -ErrorAction Stop)
        $script:pending = $list.Count
        $script:critical = @($list | Where-Object { "$($_.Title)" -match 'Security|Seguridad' }).Count
        $script:updSource = "pswindowsupdate"
      }
    } 'updates-psmodule' | Out-Null
  }
  # Fecha del último parche instalado (varias fuentes)
  Try-Get {
    $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hf) { $script:lastUpd = $hf.InstalledOn.ToUniversalTime().ToString("o") }
  } 'last-hotfix' | Out-Null
  if (-not $lastUpd) {
    Try-Get {
      $au = New-Object -ComObject Microsoft.Update.AutoUpdate
      $d = $au.Results.LastInstallationSuccessDate
      if ($d) { $script:lastUpd = ([datetime]$d).ToUniversalTime().ToString("o") }
    } 'last-autoupdate' | Out-Null
  }
  # Antigüedad del parcheo: si hace más de 60 días, se marca como pendiente
  # aunque el buscador no devuelva nada (evita falsos "Al día").
  $script:patchAgeDays = $null
  if ($lastUpd) {
    Try-Get { $script:patchAgeDays = [int]((Get-Date).ToUniversalTime() - ([datetime]$script:lastUpd).ToUniversalTime()).TotalDays } 'patch-age' | Out-Null
  }
  if ($pending -le 0 -and $patchAgeDays -ne $null -and $patchAgeDays -gt 60) {
    if ($pending -lt 0) { $pending = 1 } else { $pending = [Math]::Max(1, $pending) }
    if ($critical -lt 0) { $critical = 0 }
    $updSource = "$updSource+stale-patch"
  }

  # Antivirus: se prioriza el estado real de Defender (Get-MpComputerStatus) y
  # se agregan todos los productos de SecurityCenter2 (basta uno activo).
  $script:avName = $null; $script:avEnabled = $null; $script:avUpToDate = $null; $script:defScan = $null
  Try-Get {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp) {
      $script:avName = "Microsoft Defender"
      $rtp = $false
      try { $rtp = [bool]$mp.RealTimeProtectionEnabled } catch { $rtp = $false }
      $script:avEnabled = ([bool]$mp.AntivirusEnabled -or $rtp)
      if ($mp.AntivirusSignatureAge -ne $null) { $script:avUpToDate = ([int]$mp.AntivirusSignatureAge -le 7) }
      $script:defScan = $mp.QuickScanEndTime
    }
  } $null | Out-Null
  Try-Get {
    $prods = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop)
    if ($prods.Count -gt 0) {
      $anyOn = $false; $anyUpToDate = $false; $names = @()
      foreach ($av in $prods) {
        $names += "$($av.displayName)"
        $state = 0
        try { $state = [int]$av.productState } catch { $state = 0 }
        # Byte de estado del producto: 0x10 o 0x11 => protección activa.
        $svc = ($state -shr 8) -band 0xFF
        if ($svc -eq 0x10 -or $svc -eq 0x11 -or (($state -band 0x1000) -eq 0x1000)) { $anyOn = $true }
        if ((($state -band 0x10) -eq 0)) { $anyUpToDate = $true }
      }
      if (-not $script:avName -or $script:avEnabled -ne $true) {
        if ($anyOn -or -not $script:avName) { $script:avName = ($names -join ", ") }
      }
      if ($script:avEnabled -ne $true) { $script:avEnabled = $anyOn }
      if ($script:avUpToDate -eq $null) { $script:avUpToDate = $anyUpToDate }
    }
  } $null | Out-Null
  # Fallback: servicio de Defender en ejecución (Server Core sin SecurityCenter2)
  if ($script:avEnabled -eq $null) {
    Try-Get {
      $svc = Get-Service -Name WinDefend -ErrorAction Stop
      $script:avName = if ($script:avName) { $script:avName } else { "Microsoft Defender" }
      $script:avEnabled = ($svc.Status -eq 'Running')
    } 'antivirus-service' | Out-Null
  }

  # Firewall: Get-NetFirewallProfile y, si no está disponible, netsh.
  $script:fwEnabled = $null; $script:fwProfiles = @()
  Try-Get {
    foreach ($p in (Get-NetFirewallProfile -ErrorAction Stop)) {
      $script:fwProfiles += @{ name = $p.Name; enabled = [bool]$p.Enabled }
      if ($script:fwEnabled -eq $null) { $script:fwEnabled = $false }
      if ($p.Enabled) { $script:fwEnabled = $true }
    }
  } 'firewall-netsecurity' | Out-Null
  if ($script:fwEnabled -eq $null) {
    Try-Get {
      $out = & netsh advfirewall show allprofiles state 2>$null
      if ($out) {
        $states = @($out | Select-String -Pattern 'ON|OFF|ACTIVADO|DESACTIVADO')
        if ($states.Count -gt 0) {
          $script:fwEnabled = ($states | Where-Object { "$_" -match '(?i)\b(ON|ACTIVADO)\b' }).Count -gt 0
        }
      }
    } 'firewall-netsh' | Out-Null
  }
  if ($script:fwEnabled -eq $null) {
    Try-Get {
      $on = $false
      foreach ($prof in @('DomainProfile','StandardProfile','PublicProfile')) {
        $v = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\$prof" -Name EnableFirewall -ErrorAction SilentlyContinue).EnableFirewall
        if ($v -eq 1) { $on = $true }
        if ($v -ne $null -and $script:fwEnabled -eq $null) { $script:fwEnabled = $false }
      }
      if ($on) { $script:fwEnabled = $true }
    } 'firewall-registry' | Out-Null
  }

  # Cifrado de disco: BitLocker cmdlet y fallback a manage-bde.
  $script:diskEnc = $null; $script:diskEncMethod = "BitLocker"
  Try-Get {
    $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
    $script:diskEnc = ($vol.ProtectionStatus -eq "On" -or [int]$vol.ProtectionStatus -eq 1)
    if ($script:diskEnc) { $script:diskEncMethod = "BitLocker $($vol.EncryptionMethod)" }
  } $null | Out-Null
  if ($script:diskEnc -eq $null) {
    Try-Get {
      $out = & manage-bde -status C: 2>$null
      if ($out) {
        $txt = ($out -join [Environment]::NewLine)
        if ($txt -match '(?i)Protection\s+On|Protecci.n\s+activada') { $script:diskEnc = $true }
        elseif ($txt -match '(?i)Protection\s+Off|Protecci.n\s+desactivada') { $script:diskEnc = $false }
      }
    } $null | Out-Null
  }

  $script:uac = $null
  Try-Get { $script:uac = ((Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name EnableLUA -ErrorAction Stop).EnableLUA -eq 1) } 'uac' | Out-Null

  # Bloqueo de pantalla: política de máquina (InactivityTimeoutSecs) y, si no
  # existe, preferencias de los usuarios cargados en HKEY_USERS. Sin evidencia
  # se deja como desconocido para no marcar un falso "desactivado".
  $script:screenLock = $null; $script:screenLockTimeout = $null
  Try-Get {
    $pol = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name InactivityTimeoutSecs -ErrorAction SilentlyContinue).InactivityTimeoutSecs
    if ($pol -ne $null -and [int]$pol -gt 0) {
      $script:screenLock = $true
      $script:screenLockTimeout = [int]$pol
    }
  } 'screen-lock-policy' | Out-Null
  if ($script:screenLock -ne $true) {
    Try-Get {
      $hives = @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction Stop | Where-Object { $_.Name -match 'S-1-5-21-' -and $_.Name -notmatch '_Classes$' })
      foreach ($h in $hives) {
        $reg = Get-ItemProperty -Path "Registry::$($h.Name)\Control Panel\Desktop" -ErrorAction SilentlyContinue
        if ($reg -eq $null) { continue }
        $active = ("$($reg.ScreenSaveActive)" -eq "1")
        $secure = $false
        if ($reg.ScreenSaverIsSecure -ne $null) { $secure = ("$($reg.ScreenSaverIsSecure)" -eq "1") }
        if ($script:screenLock -eq $null) { $script:screenLock = $false }
        if ($active -and $secure) {
          $script:screenLock = $true
          if ($reg.ScreenSaveTimeOut) { $script:screenLockTimeout = [int]$reg.ScreenSaveTimeOut }
        } elseif ($reg.ScreenSaveTimeOut -and -not $script:screenLockTimeout) {
          $script:screenLockTimeout = [int]$reg.ScreenSaveTimeOut
        }
      }
    } 'screen-lock-users' | Out-Null
  }

  $script:adminCount = $null; $script:localUsers = $null
  Try-Get {
    $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    $script:adminCount = $members.Count
    $script:localUsers = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled }).Count
  } 'local-users' | Out-Null
  if ($script:adminCount -eq $null) {
    Try-Get {
      $g = [ADSI]"WinNT://./Administrators,group"
      $script:adminCount = @($g.psbase.Invoke("Members")).Count
    } 'local-users-adsi' | Out-Null
  }
  $script:openPortsCount = -1; $script:risky = @(); $script:portDetails = @()
  Try-Get {
    $conns = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    $ports = @($conns.LocalPort | Sort-Object -Unique)
    $script:openPortsCount = $ports.Count
    $riskyList = @(21,23,135,139,445,1433,3306,3389,5432,5900,5985,5986,6379,11211,27017)
    foreach ($c in $conns) {
      $pname = $null
      try { $pname = (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch { $pname = $null }
      $script:portDetails += @{ port = [int]$c.LocalPort; address = "$($c.LocalAddress)"; pid = [int]$c.OwningProcess; process = $pname; protocol = "tcp" }
    }
    foreach ($p in $ports) {
      if ($riskyList -contains [int]$p) {
        $d = $script:portDetails | Where-Object { $_.port -eq [int]$p } | Select-Object -First 1
        $script:risky += @{ port = [int]$p; address = $(if ($d) { $d.address } else { $null }); process = $(if ($d) { $d.process } else { $null }); protocol = "tcp" }
      }
    }
  } 'ports' | Out-Null
  if ($openPortsCount -lt 0) {
    Try-Get {
      $out = & netstat -ano -p TCP 2>$null
      if ($out) {
        $lines = @($out | Select-String 'LISTENING')
        $ports = @()
        foreach ($l in $lines) {
          $parts = ("$l" -split '\s+') | Where-Object { $_ }
          $local = $parts[1]
          if ($local -match ':(\d+)$') {
            $pt = [int]$Matches[1]
            $addr = $local -replace ':\d+$',''
            if ($ports -notcontains $pt) {
              $ports += $pt
              $script:portDetails += @{ port = $pt; address = $addr; protocol = "tcp" }
            }
          }
        }
        if ($ports.Count -gt 0) {
          $script:openPortsCount = $ports.Count
          $riskyList = @(21,23,135,139,445,1433,3306,3389,5432,5900,5985,5986,6379,11211,27017)
          foreach ($p in $ports) {
            if ($riskyList -contains $p) {
              $d = $script:portDetails | Where-Object { $_.port -eq $p } | Select-Object -First 1
              $script:risky += @{ port = $p; address = $(if ($d) { $d.address } else { $null }); protocol = "tcp" }
            }
          }
        }
      }
    } 'ports-netstat' | Out-Null
  }
  if ($openPortsCount -lt 0) { $openPortsCount = -1 }
  $script:rdpEnabled = $null
  Try-Get { $script:rdpEnabled = ((Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -ErrorAction Stop).fDenyTSConnections -eq 0) } 'rdp' | Out-Null
  # SSH (OpenSSH Server) — antes se enviaba siempre false.
  $script:sshEnabled = $null
  Try-Get {
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc) { $script:sshEnabled = ($svc.Status -eq 'Running') }
    elseif ($script:portDetails.Count -gt 0) { $script:sshEnabled = (@($script:portDetails | Where-Object { $_.port -eq 22 }).Count -gt 0) }
  } 'ssh' | Out-Null
  # Auditoría: independiente del idioma del sistema. Se considera activa si
  # alguna subcategoría tiene auditoría distinta de "sin auditoría".
  $script:auditEnabled = $null
  Try-Get {
    $out = & auditpol /get /category:* /r 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) {
      $rows = @($out | Select-Object -Skip 1 | Where-Object { "$_".Trim() })
      $noAudit = 0; $withAudit = 0
      foreach ($r in $rows) {
        $cols = "$r" -split ','
        if ($cols.Count -lt 5) { continue }
        $setting = "$($cols[4])".Trim()
        if (-not $setting) { continue }
        if ($setting -match '(?i)^(No Auditing|Sin auditor|Ninguno|None)') { $noAudit++ } else { $withAudit++ }
      }
      if (($withAudit + $noAudit) -gt 0) { $script:auditEnabled = ($withAudit -gt 0) }
    }
  } 'audit' | Out-Null
  if ($script:auditEnabled -eq $null) {
    Try-Get {
      $log = Get-WinEvent -ListLog Security -ErrorAction Stop
      if ($log) { $script:auditEnabled = ($log.RecordCount -gt 0) }
    } 'audit-eventlog' | Out-Null
  }
  return @{
    agent_version           = $AgentVersion
    os_name                 = $os.Caption
    os_version              = $os.Version
    os_build                = $os.BuildNumber
    os_last_update_at       = $lastUpd
    os_pending_updates      = [int]$pending
    os_critical_updates     = [int]$critical
    os_patch_age_days       = $patchAgeDays
    updates_source          = $updSource
    antivirus_name          = $avName
    antivirus_enabled       = $script:avEnabled
    antivirus_up_to_date    = $script:avUpToDate
    antivirus_last_scan_at  = $(if ($defScan) { $defScan.ToString("o") } else { $null })
    firewall_enabled        = $script:fwEnabled
    firewall_profiles       = $script:fwProfiles
    disk_encryption_enabled = $script:diskEnc
    disk_encryption_method  = $diskEncMethod
    uac_enabled             = $script:uac
    screen_lock_enabled     = $script:screenLock
    screen_lock_timeout_seconds = $script:screenLockTimeout
    admin_accounts_count    = $script:adminCount
    local_users_count       = $script:localUsers
    open_ports_count        = [int]$openPortsCount
    risky_open_ports        = $script:risky
    open_ports_detail       = $script:portDetails
    rdp_enabled             = $script:rdpEnabled
    ssh_enabled             = $script:sshEnabled
    audit_logging_enabled   = $script:auditEnabled
    collection_errors       = @($script:SecErrors)
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
    if (-not (Start-HiddenPowerShell $newScript)) { throw 'no se pudo iniciar update oculto' }
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
  $websUrl = Get-IngestEndpoint 'websites'
  $sessionsUrl = Get-IngestEndpoint 'sessions'
  $securityUrl = Get-IngestEndpoint 'security'
  $programsUrl = Get-IngestEndpoint 'programs'
  $Script:_progLastAt = [DateTime]::MinValue
  $Script:_secLastAt = [DateTime]::MinValue
  $Script:_secLastFingerprint = ""
  $secIntervalSec = 3600

  W-Log "torobyte-agent $AgentVersion started interval=$Interval endpoint=$Url"
  Load-AgentState
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
        try {
          $newSec = [int]$resp.security_interval
          if ($newSec -ge 15 -and $newSec -le 604800) { $secIntervalSec = $newSec }
        } catch {}
        try {
          if ($resp.security_now -eq $true) {
            W-Log 'auditoria de seguridad solicitada manualmente'
            $Script:_secLastAt = [DateTime]::MinValue
          }
        } catch {}
        # Solicitudes de GPS desactivadas por el usuario.

      } else {
        W-Log 'metrics failed'
      }
      Post-Json $procUrl @{ processes = (Collect-Processes) } | Out-Null
      Post-Json $portUrl @{ ports     = (Collect-Ports) }     | Out-Null
      Post-Json $diskUrl @{ disks     = (Collect-Disks) }     | Out-Null
      Post-Json $svcUrl  @{ services  = (Collect-Services) }  | Out-Null
      # Inventario de programas instalados (cada 6 horas)
      if (((Get-Date) - $Script:_progLastAt).TotalSeconds -ge 21600) {
        try {
          $progs = Collect-Programs
          if ($progs -and $progs.Count -gt 0) {
            if (Post-Json $programsUrl @{ programs = $progs }) { $Script:_progLastAt = Get-Date }
          }
        } catch { W-Log "programs error: $($_.Exception.Message)" }
      }
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
      Sample-Websites $sampleDelta
      Save-AgentState
      $appsResp = Post-Json $appsUrl (Build-AppsPayload)
      if ($appsResp) { Reset-AppCounters; Save-AgentState } else { W-Log "apps post pendiente (buffer local)" }
      try {
        $wPayload = Build-WebsitesPayload
        if ($wPayload.websites.Count -gt 0) {
          $wResp = Post-Json $websUrl $wPayload
          if ($wResp) { Reset-WebCounters; Save-AgentState } else { W-Log "web post pendiente (buffer local)" }
        }
      } catch { W-Log "web post error: $($_.Exception.Message)" }

      # Sesiones foreground v2: muestreo fino durante el sleep
      $slept = 0
      $step = $Script:_sessionSampleSec
      while ($slept -lt $script:Interval) {
        try { Sample-Session } catch { W-Log "session sample error: $($_.Exception.Message)" }
        if ($env:ONCE -eq '1') { break }
        Start-Sleep -Seconds $step
        $slept += $step
      }
      Save-AgentState
      try {
        $sPayload = Build-SessionsPayload
        if ($sPayload.sessions.Count -gt 0 -or $sPayload.idle_sessions.Count -gt 0) {
          $sResp = Post-Json $sessionsUrl $sPayload
          if ($sResp) { Reset-SessionQueues; Save-AgentState } else { W-Log "sessions post pendiente (buffer local)" }
        }
      } catch { W-Log "sessions post error: $($_.Exception.Message)" }
    } catch {
      W-Log "loop error: $($_.Exception.Message)"
    }
    try {
      $now = Get-Date
      $secDue = ($now - $Script:_secLastAt).TotalSeconds -ge $secIntervalSec
      if ($secDue -or ($env:ONCE -eq '1')) {
        $secPayload = Collect-Security
        $fp = ""
        try {
          # Fingerprint ignoring transient details like dates or counts to detect real changes
          $fpObj = @{
            av = $secPayload.antivirus_enabled; avUp = $secPayload.antivirus_up_to_date;
            fw = $secPayload.firewall_enabled; disk = $secPayload.disk_encryption;
            uac = $secPayload.uac_enabled; lock = $secPayload.screen_lock;
            pending = $secPayload.pending_updates; crit = $secPayload.critical_updates;
            ports = $secPayload.open_ports_count
          }
          $fp = $fpObj | ConvertTo-Json -Compress
        } catch {}

        if ($secDue -or ($fp -ne $Script:_secLastFingerprint) -or ($env:ONCE -eq '1')) {
          $secResp = Post-Json $securityUrl $secPayload
          if ($secResp) { 
            $Script:_secLastAt = $now
            $Script:_secLastFingerprint = $fp
          }
        }
      }
    } catch { W-Log "security post error: $($_.Exception.Message)" }
    if ($env:ONCE -eq '1') { return $cycleOk }
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

  W-Step 6 $total 'Registrando tareas programadas (TorobyteAgent + Sessions)...'
  & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
  & schtasks.exe /Delete /TN $SessionsTaskName /F 2>$null | Out-Null
  # Persistir variables a nivel de maquina para que la tarea las herede
  [Environment]::SetEnvironmentVariable('AGENT_TOKEN', $Token,    'Machine')
  [Environment]::SetEnvironmentVariable('INGEST_URL',  $Url,      'Machine')
  [Environment]::SetEnvironmentVariable('INTERVAL',    "$Interval",'Machine')
  [Environment]::SetEnvironmentVariable('MODE',        'run',     'Machine')
  # ONSTART task (SYSTEM) - se registra con XML para eliminar el limite por defecto
  # de 72h (ExecutionTimeLimit=PT0S) y activar reintentos automaticos si falla.
  $agentXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$ScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
  $agentXmlPath = Join-Path $InstallDir 'agent-task.xml'
  Set-Content -Encoding Unicode -Path $agentXmlPath -Value $agentXml
  & schtasks.exe /Create /TN $TaskName /XML $agentXmlPath /F | Out-Null
  if ($LASTEXITCODE -ne 0) { W-Fail 'no se pudo crear la tarea programada del sistema' }

  # Tarea por-usuario (ONLOGON) para capturar la aplicacion en primer plano.
  # SYSTEM esta en Session 0 y no puede ver el escritorio interactivo, por eso
  # se requiere una tarea separada que corra como el usuario que inicia sesion.
  # Tambien se crea con XML para eliminar el limite de 72h.
  # Invoca PowerShell directamente sin pasar por cmd.exe.
  $vbsLines = @(
    'Option Explicit',
    'Dim sh, env',
    'Set sh = CreateObject("WScript.Shell")',
    'Set env = sh.Environment("PROCESS")',
    'env("MODE") = "run-sessions"',
    ('sh.Run "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""' + $ScriptPath + '""", 0, False')
  )
  Set-Content -Encoding ASCII -Path $SessionsVbsPath -Value $vbsLines
  W-Ok 'tareas creadas'
  $sessionsXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <GroupId>S-1-5-32-545</GroupId>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>//B //Nologo "$SessionsVbsPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
  $sessionsXmlPath = Join-Path $InstallDir 'sessions-task.xml'
  Set-Content -Encoding Unicode -Path $sessionsXmlPath -Value $sessionsXml
  & schtasks.exe /Create /TN $SessionsTaskName /XML $sessionsXmlPath /F | Out-Null
  if ($LASTEXITCODE -ne 0) { W-Log 'aviso: no se pudo crear la tarea de sesiones por-usuario (metricas de apps deshabilitadas)' }

  # Tarea de apagado: notifica offline al instante cuando el equipo se apaga o reinicia.
  # Trigger = Event ID 1074 (User32) que Windows escribe apenas se inicia el shutdown.
  & schtasks.exe /Delete /TN $ShutdownTaskName /F 2>$null | Out-Null
  $shutdownUrl = $Url -replace '/api/public/ingest/metrics.*$', '/api/public/ingest/shutdown'
  $shutdownScript = @(
    '$ErrorActionPreference = ''SilentlyContinue''',
    'try {',
    ('  Invoke-WebRequest -UseBasicParsing -Method Post -TimeoutSec 5 -Uri ''' + $shutdownUrl + ''' -Headers @{ Authorization = (''Bearer '' + $env:AGENT_TOKEN) } | Out-Null'),
    '} catch {}'
  )
  Set-Content -Encoding UTF8 -Path $ShutdownPsPath -Value $shutdownScript
  $shutdownVbs = @(
    'Option Explicit',
    'Dim sh',
    'Set sh = CreateObject("WScript.Shell")',
    ('sh.Run "powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""' + $ShutdownPsPath + '""", 0, True')
  )
  Set-Content -Encoding ASCII -Path $ShutdownVbsPath -Value $shutdownVbs
  $shutdownXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='USER32'] and (EventID=1074)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>true</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>//B //Nologo "$ShutdownVbsPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
  $shutdownXmlPath = Join-Path $InstallDir 'shutdown-task.xml'
  Set-Content -Encoding Unicode -Path $shutdownXmlPath -Value $shutdownXml
  & schtasks.exe /Create /TN $ShutdownTaskName /XML $shutdownXmlPath /F | Out-Null
  if ($LASTEXITCODE -ne 0) { W-Log 'aviso: no se pudo crear la tarea de apagado (offline instantaneo deshabilitado)' }


  W-Step 7 $total 'Iniciando agente en background...'
  & schtasks.exe /Run /TN $TaskName | Out-Null
  & schtasks.exe /Run /TN $SessionsTaskName 2>$null | Out-Null
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
  & schtasks.exe /End /TN $SessionsTaskName 2>$null | Out-Null
  & schtasks.exe /Delete /TN $SessionsTaskName /F 2>$null | Out-Null
  & schtasks.exe /End /TN $ShutdownTaskName 2>$null | Out-Null
  & schtasks.exe /Delete /TN $ShutdownTaskName /F 2>$null | Out-Null
  W-Ok 'tareas programadas eliminadas'
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

function Run-SessionsLoop {
  if (-not $Token -or -not $Url) { W-Log 'sessions loop: token/url faltantes'; exit 1 }
  $appsUrl = Get-IngestEndpoint 'apps'
  $websUrl = Get-IngestEndpoint 'websites'
  $sessionsUrl = Get-IngestEndpoint 'sessions'
  # Estado local por usuario en una carpeta escribible. La tarea corre con
  # LeastPrivilege, por lo que ProgramData puede ser solo lectura para usuarios.
  try {
    $userStateRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'TorobyteAgent' } else { Join-Path $env:TEMP 'TorobyteAgent' }
    New-Item -ItemType Directory -Force -Path $userStateRoot | Out-Null
    $Script:_stateFile = Join-Path $userStateRoot ("agent-state-{0}.json" -f ([Environment]::UserName).ToLowerInvariant())
  } catch {}
  W-Log "torobyte-agent sessions loop $AgentVersion interval=$Interval user=$([Environment]::UserName)"
  # Request-UserLocationConsent (Removido)
  Load-AgentState
  while ($true) {
    # Request-UserLocationConsent (Removido)
    try {
      $slept = 0
      $step = $Script:_sessionSampleSec
      while ($slept -lt $script:Interval) {
        try { Sample-Apps $step } catch { W-Log "apps sample error: $($_.Exception.Message)" }
        try { Sample-Websites $step } catch { W-Log "web sample error: $($_.Exception.Message)" }
        try { Sample-Session } catch { W-Log "session sample error: $($_.Exception.Message)" }
        Save-AgentState
        Start-Sleep -Seconds $step
        $slept += $step
      }
      Save-AgentState
      try {
        $aPayload = Build-AppsPayload
        if ($aPayload.apps.Count -gt 0) {
          $aResp = Post-Json $appsUrl $aPayload
          if ($aResp) { Reset-AppCounters; Save-AgentState } else { W-Log "apps post pendiente (buffer local)" }
        }
      } catch { W-Log "apps post error: $($_.Exception.Message)" }
      try {
        $wPayload = Build-WebsitesPayload
        if ($wPayload.websites.Count -gt 0) {
          $wResp = Post-Json $websUrl $wPayload
          if ($wResp) { Reset-WebCounters; Save-AgentState } else { W-Log "web post pendiente (buffer local)" }
        }
      } catch { W-Log "web post error: $($_.Exception.Message)" }
      try {
        $sPayload = Build-SessionsPayload
        if ($sPayload.sessions.Count -gt 0 -or $sPayload.idle_sessions.Count -gt 0) {
          $sResp = Post-Json $sessionsUrl $sPayload
          if ($sResp) { Reset-SessionQueues; Save-AgentState } else { W-Log "sessions post pendiente (buffer local)" }
        }
      } catch { W-Log "sessions post error: $($_.Exception.Message)" }
    } catch { W-Log "sessions loop error: $($_.Exception.Message)" }
  }
}

# Modo de ejecucion
if ($Mode -eq 'run') {
  Run-AgentLoop
} elseif ($Mode -eq 'run-sessions') {
  Run-SessionsLoop
} elseif ($Mode -eq 'uninstall' -or $Mode -eq 'remove') {
  Uninstall-Agent
} else {
  Install-Agent
}
