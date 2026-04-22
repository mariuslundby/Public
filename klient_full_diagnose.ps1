# ============================================================================
# KLIENT-DIAGNOSE FOR SILENT DATA LOSS (SMB/DFS/Excel)
# Kjør som admin på berørt brukers PC
# Gjør ingen permanente endringer - kun lesing
# ============================================================================

$ErrorActionPreference = "SilentlyContinue"
$computer = $env:COMPUTERNAME
$user = $env:USERNAME
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

# Admin-sjekk
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  KLIENT-DIAGNOSE: SILENT DATA LOSS                            ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "Maskin:    $computer" 
Write-Host "Bruker:    $user"
Write-Host "Tidspunkt: $(Get-Date)"
Write-Host "Admin:     $isAdmin $(if (-not $isAdmin) {'⚠️  Noen sjekker hoppes over'})" -ForegroundColor $(if ($isAdmin) {'Green'} else {'Yellow'})

# Funn-samler
$findings = [System.Collections.ArrayList]@()
function Add-Finding {
    param($severity, $area, $detail)
    $null = $findings.Add([PSCustomObject]@{
        Severity = $severity
        Area = $area
        Detail = $detail
    })
}

# ============================================================================
# 1. POWER / DVALE-INNSTILLINGER
# ============================================================================
Write-Host "`n─── [1] POWER / DVALE ─────────────────────────────────────────" -ForegroundColor Yellow

$powerSchemes = powercfg /list
$activeScheme = (powercfg /getactivescheme) -replace '.*GUID: ([a-f0-9-]+).*', '$1' -replace '.*:\s*',''
Write-Host "  Aktiv power plan: $((powercfg /getactivescheme) -replace '.*:\s*','')"

# Les sleep timeout korrekt
$query = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
$currentAC = ($query | Select-String 'Current AC Power Setting Index:\s+0x([0-9a-f]+)').Matches.Groups[1].Value
$currentDC = ($query | Select-String 'Current DC Power Setting Index:\s+0x([0-9a-f]+)').Matches.Groups[1].Value

if ($currentAC) {
    $sleepACmin = [Convert]::ToInt32($currentAC, 16) / 60
    Write-Host "  Sleep (strøm):      $sleepACmin min $(if ($sleepACmin -eq 0) {'(aldri) ✓'} elseif ($sleepACmin -lt 30) {'⚠️  LAVT'} else {'✓'})"
    if ($sleepACmin -gt 0 -and $sleepACmin -lt 30) {
        Add-Finding 'MEDIUM' 'Power' "Dvale på strøm etter $sleepACmin min (anbefalt: aldri eller >30)"
    }
}

if ($currentDC) {
    $sleepDCmin = [Convert]::ToInt32($currentDC, 16) / 60
    Write-Host "  Sleep (batteri):    $sleepDCmin min $(if ($sleepDCmin -eq 0) {'(aldri) ✓'} elseif ($sleepDCmin -lt 30) {'⚠️  LAVT'} else {'✓'})"
    if ($sleepDCmin -gt 0 -and $sleepDCmin -lt 15) {
        Add-Finding 'MEDIUM' 'Power' "Dvale på batteri etter $sleepDCmin min"
    }
}

# Hibernate
$hibQuery = powercfg /query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE
$hibAC = ($hibQuery | Select-String 'Current AC Power Setting Index:\s+0x([0-9a-f]+)').Matches.Groups[1].Value
if ($hibAC) {
    $hibACmin = [Convert]::ToInt32($hibAC, 16) / 60
    Write-Host "  Hibernate (strøm):  $hibACmin min $(if ($hibACmin -eq 0) {'(aldri)'} else {''})"
}

# ============================================================================
# 2. NIC POWER MANAGEMENT
# ============================================================================
Write-Host "`n─── [2] NIC POWER MANAGEMENT ──────────────────────────────────" -ForegroundColor Yellow

Get-NetAdapter -Physical | Where-Object Status -eq "Up" | ForEach-Object {
    $adapter = $_
    $pm = Get-NetAdapterPowerManagement -Name $adapter.Name
    $flag = if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') {'⚠️  JA'} else {'Nei ✓'}
    Write-Host "  $($adapter.Name) ($($adapter.MediaType)): 'Allow turn off' = $flag"
    Write-Host "    Speed: $($adapter.LinkSpeed), MAC: $($adapter.MacAddress)"
    
    if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
        Add-Finding 'HIGH' 'NIC' "$($adapter.Name): 'Allow computer to turn off this device' er aktivert"
    }
}

# ============================================================================
# 3. WIFI-DETALJER
# ============================================================================
Write-Host "`n─── [3] WIFI / ROAMING ────────────────────────────────────────" -ForegroundColor Yellow

$wifi = netsh wlan show interfaces 2>$null
if ($wifi -match 'State\s+:\s+connected') {
    $ssid = ($wifi | Select-String "^\s+SSID\s+:" | Select-Object -First 1).Line -replace '.*:\s*',''
    $bssid = ($wifi | Select-String "^\s+BSSID\s+:").Line -replace '.*:\s*',''
    $signal = ($wifi | Select-String "Signal").Line -replace '.*:\s*',''
    $band = ($wifi | Select-String "Band").Line -replace '.*:\s*',''
    $channel = ($wifi | Select-String "Channel").Line -replace '.*:\s*',''
    $auth = ($wifi | Select-String "Authentication").Line -replace '.*:\s*',''
    
    Write-Host "  SSID:            $ssid"
    Write-Host "  BSSID (AP):      $bssid"
    Write-Host "  Band:            $band   Channel: $channel"
    Write-Host "  Signal:          $signal"
    Write-Host "  Autentisering:   $auth"
    
    if ($signal -match '(\d+)%' -and [int]$matches[1] -lt 60) {
        Add-Finding 'MEDIUM' 'WiFi' "Signalstyrke kun $signal"
    }
    if ($auth -match '802\.1X|Enterprise') {
        Add-Finding 'INFO' 'WiFi' "802.1x Enterprise - reconnect tar lenger tid"
    }
} else {
    Write-Host "  WiFi ikke tilkoblet - maskinen er på kabel"
}

# ============================================================================
# 4. SMB KLIENT-KONFIGURASJON
# ============================================================================
Write-Host "`n─── [4] SMB KLIENT-KONFIGURASJON ──────────────────────────────" -ForegroundColor Yellow

$smb = Get-SmbClientConfiguration
Write-Host "  SessionTimeout:         $($smb.SessionTimeout) sek $(if ($smb.SessionTimeout -le 60) {'⚠️  KORT'} else {'✓'})"
Write-Host "  ConnectionTimeoutInMs:  $($smb.ConnectionTimeoutInMs) ms"
Write-Host "  EnableMultiChannel:     $($smb.EnableMultiChannel)"
Write-Host "  EnableLargeMtu:         $($smb.EnableLargeMtu)"

if ($smb.SessionTimeout -le 60) {
    Add-Finding 'MEDIUM' 'SMB' "SessionTimeout er $($smb.SessionTimeout) sek (anbefalt: 120+)"
}

# ============================================================================
# 5. OFFLINE FILES / CSC - uten takeown
# ============================================================================
Write-Host "`n─── [5] OFFLINE FILES / CSC ───────────────────────────────────" -ForegroundColor Yellow

$cscService = Get-Service -Name "CscService" -ErrorAction SilentlyContinue
Write-Host "  CscService:      $($cscService.Status) / StartType: $($cscService.StartType)"

# WMI-baserte oppslag (trenger ikke CSC file-read)
if ($isAdmin) {
    try {
        $cscWmi = Get-WmiObject -Class Win32_OfflineFilesCache -ErrorAction Stop
        Write-Host "  CSC Active:      $($cscWmi.Active)"
        Write-Host "  CSC Enabled:     $($cscWmi.Enabled)"
        Write-Host "  CSC Location:    $($cscWmi.Location)"
    } catch {
        Write-Host "  CSC WMI:         ikke tilgjengelig"
    }
    
    # Finn filer som er markert som "dirty" (skrevet lokalt, ikke syncet)
    try {
        $items = Get-WmiObject -Class Win32_OfflineFilesItem -ErrorAction Stop
        $pinned = $items | Where-Object { $_.Pinned -eq $true }
        $dirty  = $items | Where-Object { $_.DirtyInCache -eq $true }
        
        Write-Host "  Pinned filer:    $($pinned.Count) (aktivt offline-merket)"
        Write-Host "  Dirty filer:     $($dirty.Count) (lokale endringer ikke syncet)"
        
        if ($dirty.Count -gt 0) {
            Write-Host "`n  🎯 FILER MED USYNKRONISERTE ENDRINGER:" -ForegroundColor Red
            $dirty | Select-Object -First 20 ItemName, ItemPath |
                Format-Table -AutoSize | Out-String | Write-Host
            Add-Finding 'CRITICAL' 'CSC' "$($dirty.Count) filer har usynkroniserte endringer - potensielt tapt arbeid"
        }
        if ($pinned.Count -gt 0) {
            Write-Host "  Eksempel på pinned:"
            $pinned | Select-Object -First 5 ItemName, ItemPath |
                Format-Table -AutoSize | Out-String | Write-Host
        }
    } catch {
        Write-Host "  CSC items via WMI: ikke tilgjengelig"
    }
} else {
    Write-Host "  ⚠️ Trenger admin for CSC-detaljer"
}

# Sync Center konflikter
$conflictsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\NetCache\Conflicts"
if (Test-Path $conflictsKey) {
    $conflicts = Get-ChildItem $conflictsKey -Recurse -ErrorAction SilentlyContinue
    if ($conflicts.Count -gt 0) {
        Write-Host "`n  🎯 SYNC CENTER KONFLIKTER FUNNET: $($conflicts.Count)" -ForegroundColor Red
        Add-Finding 'HIGH' 'CSC' "$($conflicts.Count) Sync Center konflikter"
    } else {
        Write-Host "  Sync Center konflikter: 0"
    }
}

# ============================================================================
# 6. EXCEL / OFFICE - AUTORECOVERY OG SAVE A COPY-SPOR
# ============================================================================
Write-Host "`n─── [6] EXCEL / OFFICE: TAPTE ARBEID-SPOR ──────────────────" -ForegroundColor Yellow

# Excel autorecovery
$unsavedPath = "$env:LOCALAPPDATA\Microsoft\Office\UnsavedFiles"
if (Test-Path $unsavedPath) {
    $unsaved = Get-ChildItem $unsavedPath -File -ErrorAction SilentlyContinue
    Write-Host "  UnsavedFiles:       $($unsaved.Count) filer"
    if ($unsaved.Count -gt 0) {
        $unsaved | Select-Object -First 10 | ForEach-Object {
            Write-Host "    $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  $($_.Name) ($([math]::Round($_.Length/1KB,0)) KB)"
        }
        Add-Finding 'HIGH' 'Excel' "$($unsaved.Count) filer i UnsavedFiles - aldri ferdig lagret"
    }
}

# Excel autorecovery location
$excelAutorecoverPath = "$env:APPDATA\Microsoft\Excel"
if (Test-Path $excelAutorecoverPath) {
    $asdFiles = Get-ChildItem $excelAutorecoverPath -Recurse -Filter "*.asd" -ErrorAction SilentlyContinue
    $xarFiles = Get-ChildItem $excelAutorecoverPath -Recurse -Filter "*.xar" -ErrorAction SilentlyContinue
    Write-Host "  Excel AutoRecovery: $($asdFiles.Count) .asd filer, $($xarFiles.Count) .xar filer"
    if ($asdFiles.Count -gt 0) {
        $asdFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
            Write-Host "    $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  $($_.Name)"
        }
    }
}

# Word autorecovery
$wordAutorecoverPath = "$env:APPDATA\Microsoft\Word"
if (Test-Path $wordAutorecoverPath) {
    $asdFilesWord = Get-ChildItem $wordAutorecoverPath -Recurse -Filter "*.asd" -ErrorAction SilentlyContinue
    Write-Host "  Word AutoRecovery:  $($asdFilesWord.Count) .asd filer"
}

# Se etter "Save a copy" / "(1)" / " - Kopi" filer på typiske plasseringer
Write-Host "`n  Søker etter 'Save a copy'-filer:"
$copyFiles = @()
$searchPaths = @(
    [Environment]::GetFolderPath("Desktop"),
    [Environment]::GetFolderPath("MyDocuments"),
    "$env:USERPROFILE\Downloads"
)

foreach ($path in $searchPaths) {
    if (Test-Path $path) {
        $found = Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue -Include "*(1).xlsx","*(2).xlsx","*(1).xlsm","*(1).docx","*(2).docx","* - Kopi.xlsx","* - Kopi.docx","* - Copy.xlsx","* - Copy.docx" -File |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) }
        $copyFiles += $found
    }
}

if ($copyFiles.Count -gt 0) {
    Write-Host "`n  🎯 MULIGE 'SAVE A COPY'-FILER (siste 30 dager):" -ForegroundColor Red
    $copyFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 15 |
        Format-Table @{N='Endret';E={$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')}}, Name, @{N='Sti';E={$_.DirectoryName}} -AutoSize |
        Out-String | Write-Host
    Add-Finding 'HIGH' 'Excel' "$($copyFiles.Count) filer med '(1)'/' - Kopi'-suffix funnet - indikerer 'Save a copy'-valg"
} else {
    Write-Host "    Ingen funnet"
}

# Excel MRU - siste åpnede filer (hjelp for å se hva de har jobbet med)
Write-Host "`n  Excel MRU (siste åpnede filer):"
try {
    $mruPath = "HKCU:\Software\Microsoft\Office\*\Excel\User MRU\*\File MRU"
    $mruItems = @()
    Get-ItemProperty $mruPath -ErrorAction SilentlyContinue | ForEach-Object {
        $_.PSObject.Properties | Where-Object { $_.Name -match '^Item \d+' } | ForEach-Object {
            $mruItems += $_.Value
        }
    }
    $mruItems | Select-Object -First 10 | ForEach-Object {
        # Fjern metadata-prefix (ser ut som [F00000000][T...][O...])
        $path = $_ -replace '^\[.*?\]+\s*', ''
        Write-Host "    $path"
    }
} catch {
    Write-Host "    Kunne ikke lese MRU"
}

# ============================================================================
# 7. AKTIVE SMB-TILKOBLINGER
# ============================================================================
Write-Host "`n─── [7] AKTIVE SMB-TILKOBLINGER ───────────────────────────────" -ForegroundColor Yellow

$connections = Get-SmbConnection | Where-Object { $_.ServerName -notlike "*\IPC$" }
if ($connections) {
    $connections | Format-Table ServerName, ShareName, UserName, NumOpens, Dialect -AutoSize |
        Out-String | Write-Host
} else {
    Write-Host "  Ingen aktive SMB-tilkoblinger"
}

# Åpne filer nå
$openNow = Get-SmbOpenFile -ErrorAction SilentlyContinue
if ($openNow) {
    Write-Host "  Åpne filer nå: $($openNow.Count)"
    $openNow | Select-Object -First 5 | ForEach-Object {
        Write-Host "    $($_.Path)"
    }
}

# ============================================================================
# 8. SMB CLIENT-FEIL SISTE 7 DAGER
# ============================================================================
Write-Host "`n─── [8] SMB DISCONNECT-HISTORIKK ──────────────────────────────" -ForegroundColor Yellow

$smbErrors = Get-WinEvent -LogName "Microsoft-Windows-SMBClient/Connectivity" -MaxEvents 1000 -ErrorAction SilentlyContinue |
    Where-Object { $_.LevelDisplayName -in "Error","Warning" -and $_.TimeCreated -gt (Get-Date).AddDays(-7) }

Write-Host "  Totalt feil/warnings siste 7 dager: $($smbErrors.Count)"

if ($smbErrors.Count -gt 0) {
    Write-Host "`n  Per Event ID:"
    $smbErrors | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
        $desc = switch ($_.Name) {
            "30800" {"Session established (?!)"}
            "30803" {"Connection rejected"}
            "30804" {"Network disconnect"}
            "30805" {"Failed to establish connection"}
            "30807" {"Connection disconnect"}
            "30808" {"Connection re-established"}
            default {""}
        }
        Write-Host ("    {0,3} x  ID {1}  {2}" -f $_.Count, $_.Name, $desc)
    }
    
    Write-Host "`n  Per time på dagen (siste 7d):"
    $smbErrors | Group-Object { $_.TimeCreated.Hour } | Sort-Object { [int]$_.Name } | ForEach-Object {
        $bar = "█" * [math]::Min($_.Count, 40)
        Write-Host ("    {0,2}:00  {1,4}  {2}" -f $_.Name, $_.Count, $bar)
    }
    
    if ($smbErrors.Count -gt 30) {
        Add-Finding 'HIGH' 'SMB' "$($smbErrors.Count) SMB-disconnects siste 7 dager (>4/dag)"
    }
}

# ============================================================================
# 9. WIFI DISCONNECT-HISTORIKK (siste 48t)
# ============================================================================
Write-Host "`n─── [9] WIFI EVENTS SISTE 48 TIMER ────────────────────────────" -ForegroundColor Yellow

$wifiEvents = Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 500 -ErrorAction SilentlyContinue |
    Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-2) }

if ($wifiEvents) {
    $disconnects = $wifiEvents | Where-Object Id -in 8003,11006,12013
    Write-Host "  Totalt WiFi-events: $($wifiEvents.Count)"
    Write-Host "  Av dem disconnects/feil: $($disconnects.Count)"
    
    if ($disconnects.Count -gt 10) {
        Add-Finding 'MEDIUM' 'WiFi' "$($disconnects.Count) WiFi-disconnects siste 48t"
    }
} else {
    Write-Host "  Ingen WiFi-events (kabel-tilkobling)"
}

# ============================================================================
# 10. BRUKERENS EGNE SPOR - MRU, RECENT, EXPLORER HISTORY
# ============================================================================
Write-Host "`n─── [10] BRUKERENS AKTIVITET-SPOR ─────────────────────────────" -ForegroundColor Yellow

# Recent Items
$recent = "$env:APPDATA\Microsoft\Windows\Recent"
if (Test-Path $recent) {
    $recentFiles = Get-ChildItem $recent -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) } |
        Sort-Object LastWriteTime -Descending
    Write-Host "  Recent Items siste 14d: $($recentFiles.Count)"
}

# Preview-pane status
$previewKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Modules\GlobalSettings\DetailsContainer"
$previewOn = Get-ItemProperty $previewKey -ErrorAction SilentlyContinue
if ($previewOn) {
    Write-Host "  Preview/Details pane: konfigurert"
    # 2 = vis, 1 = skjul (sjekk DetailsContainer-verdi hvis mulig)
}

# Explorer - vis skjulte filer og extensions
$advanced = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction SilentlyContinue
if ($advanced) {
    Write-Host "  Vis skjulte filer:  $(if ($advanced.Hidden -eq 1) {'Ja'} else {'Nei'})"
    Write-Host "  Vis extensions:     $(if ($advanced.HideFileExt -eq 0) {'Ja ✓'} else {'Nei ⚠️'})"
    if ($advanced.HideFileExt -eq 1) {
        Add-Finding 'INFO' 'Explorer' "Filendelser skjules - kan skjule (1).xlsx-filer fra brukeren"
    }
}

# ============================================================================
# OPPSUMMERING
# ============================================================================
Write-Host "`n`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  OPPSUMMERING                                                 ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($findings.Count -eq 0) {
    Write-Host "`n  Ingen tydelige funn på denne maskinen ✓" -ForegroundColor Green
} else {
    $bySeverity = $findings | Group-Object Severity
    
    foreach ($severity in @('CRITICAL','HIGH','MEDIUM','INFO')) {
        $group = $bySeverity | Where-Object Name -eq $severity
        if ($group) {
            $color = switch ($severity) {
                'CRITICAL' {'Red'}
                'HIGH'     {'Yellow'}
                'MEDIUM'   {'Cyan'}
                'INFO'     {'Gray'}
            }
            Write-Host "`n  $severity ($($group.Count)):" -ForegroundColor $color
            $group.Group | ForEach-Object {
                Write-Host "    [$($_.Area)] $($_.Detail)"
            }
        }
    }
}

Write-Host "`n  Lagre dette resultatet:"
Write-Host "    .\klient_full_diagnose.ps1 *> diagnose_${computer}_${timestamp}.txt" -ForegroundColor Gray
Write-Host ""
