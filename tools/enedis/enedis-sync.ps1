# Synchronise la consommation Enedis (via MyElectricalData) vers un appareil
# virtuel SmartThings « Linky (Enedis) ».
#
# Configuration : %APPDATA%\linky-enedis\config.json (jamais dans le depot) :
#   { "prm": "<point de livraison>", "token": "<cle MyElectricalData>",
#     "deviceId": "<id de l'appareil virtuel>",
#     "cli": "<chemin de smartthings.exe>" }
#
# Donnees Enedis disponibles a J-1 : lancer une fois par jour, le matin.
# Utilise 2 appels MyElectricalData par execution (quota : 50 par jour).

$ErrorActionPreference = "Stop"
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$dir = Join-Path $env:APPDATA "linky-enedis"
$cfg = Get-Content (Join-Path $dir "config.json") -Raw | ConvertFrom-Json
$log = Join-Path $dir "sync.log"
function Log($msg) { $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "  " + $msg; Add-Content -Path $log -Value $line -Encoding utf8; Write-Output $line }

$cli = if ($cfg.cli) { $cfg.cli } else { "C:\Users\Luis\Downloads\smartthings-windows-x64\smartthings.exe" }
$headers = @{ Authorization = $cfg.token }
$base = "https://www.myelectricaldata.fr"

$today = (Get-Date).Date
$monthStart = Get-Date -Year $today.Year -Month $today.Month -Day 1
$start = @($monthStart, $today.AddDays(-8)) | Sort-Object | Select-Object -First 1
$s = $start.ToString("yyyy-MM-dd"); $e = $today.ToString("yyyy-MM-dd")

try {
  $daily = Invoke-RestMethod -Uri "$base/daily_consumption/$($cfg.prm)/start/$s/end/$e" -Headers $headers -TimeoutSec 60
} catch { Log "ERREUR consommation quotidienne : $($_.Exception.Message)"; exit 1 }

$days = @($daily.meter_reading.interval_reading | ForEach-Object {
  [pscustomobject]@{ date = [datetime]::ParseExact($_.date.Substring(0, 10), "yyyy-MM-dd", $inv); wh = [double]$_.value }
} | Sort-Object date)
if ($days.Count -eq 0) { Log "Aucune donnee renvoyee par Enedis pour $s -> $e"; exit 1 }

$last = $days[-1]
$hier = $last.wh / 1000
$sept = ($days | Where-Object { $_.date -gt $last.date.AddDays(-7) } | Measure-Object wh -Sum).Sum / 1000
$mois = ($days | Where-Object { $_.date.Year -eq $last.date.Year -and $_.date.Month -eq $last.date.Month } | Measure-Object wh -Sum).Sum / 1000

$maxVa = $null
try {
  $ld = $last.date.ToString("yyyy-MM-dd"); $ln = $last.date.AddDays(1).ToString("yyyy-MM-dd")
  $mp = Invoke-RestMethod -Uri "$base/daily_consumption_max_power/$($cfg.prm)/start/$ld/end/$ln" -Headers $headers -TimeoutSec 60
  $maxVa = [double]($mp.meter_reading.interval_reading | Select-Object -Last 1).value
} catch { Log "Puissance max indisponible : $($_.Exception.Message)" }

function Fmt($v) { [math]::Round($v, 2).ToString($inv) }
function Push($attr, $value, $unit) {
  $cliArgs = @("virtualdevices:events", $cfg.deviceId, $attr, $value)
  if ($unit) { $cliArgs += $unit }
  & $cli @cliArgs *> $null
  if ($LASTEXITCODE -ne 0) { Log "ERREUR envoi $attr = $value" }
}

$cap = "main:smoothcommon59531.enedisConso"
Push "${cap}:hier" (Fmt $hier) "kWh"
Push "${cap}:septJours" (Fmt $sept) "kWh"
Push "${cap}:moisEnCours" (Fmt $mois) "kWh"
Push "${cap}:dateDonnees" ($last.date.ToString("dd/MM/yyyy")) $null
Push "main:energyMeter:energy" (Fmt $hier) "kWh"
if ($maxVa -ne $null) { Push "${cap}:puissanceMaxHier" ($maxVa.ToString($inv)) "VA" }

Log ("OK : {0} = {1} kWh, 7 jours = {2} kWh, mois = {3} kWh, puissance max = {4} VA" -f $last.date.ToString("dd/MM"), (Fmt $hier), (Fmt $sept), (Fmt $mois), $maxVa)
