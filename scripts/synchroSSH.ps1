<#
.SYNOPSIS
  Synchronise (sans suppression) un dossier Windows <-> un dossier Linux via SSH.
  Compare et affiche les differences, puis propose sync dans un sens, l'autre, ou fichier par fichier.

.EXAMPLE
  .\sync-ssh.ps1 -Remote "user@linux.example.com" -RemoteDir "/home/user/data" -LocalDir "C:\Data"
#>

param(
  [Parameter(Mandatory=$true)] [string]$Remote,        # ex: user@host
  [Parameter(Mandatory=$true)] [string]$RemoteDir,     # ex: /home/user/data
  [Parameter(Mandatory=$true)] [string]$LocalDir,      # ex: C:\Data
  [string]$SshKeyPath = "",                            # optionnel: C:\Users\me\.ssh\id_ed25519
  [switch]$UseHash                                   # optionnel (lent): compare aussi SHA256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-LocalPath([string]$p) {
  return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\')
}

function Escape-RemoteSingleQuotes([string]$s) {
  # pour mettre dans des quotes simples cote shell: ' -> '\'' (pattern standard)
  return $s -replace "'", "'\''"
}

function Invoke-Ssh([string]$command) {
  $args = @()
  if ($SshKeyPath -and (Test-Path -LiteralPath $SshKeyPath)) {
    $args += "-i"; $args += $SshKeyPath
  }
  $args += $Remote
  $args += $command
  & ssh @args
}

function Invoke-ScpUpload([string]$localFile, [string]$remoteFile) {
  $args = @()
  if ($SshKeyPath -and (Test-Path -LiteralPath $SshKeyPath)) {
    $args += "-i"; $args += $SshKeyPath
  }
  # -p conserve dates si possible
  $args += "-p"
  $args += $localFile
  $args += "${Remote}:${remoteFile}"
  & scp @args | Out-Null
}

function Invoke-ScpDownload([string]$remoteFile, [string]$localFile) {
  $args = @()
  if ($SshKeyPath -and (Test-Path -LiteralPath $SshKeyPath)) {
    $args += "-i"; $args += $SshKeyPath
  }
  $args += "-p"
  $args += "${Remote}:${remoteFile}"
  $args += $localFile
  & scp @args | Out-Null
}

function Ensure-RemoteDir([string]$remotePath) {
  # remotePath est un chemin complet de fichier, on cree le dossier parent
  $dir = [System.IO.Path]::GetDirectoryName($remotePath) -replace '\\','/'
  $dirEsc = Escape-RemoteSingleQuotes $dir
  Invoke-Ssh "bash -lc 'mkdir -p -- ''$dirEsc''' " | Out-Null
}

function Ensure-LocalDir([string]$localPath) {
  $dir = Split-Path -Parent -LiteralPath $localPath
  if (!(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

# --- Preparation chemins
$LocalDir = Normalize-LocalPath $LocalDir

# --- Liste locale
Write-Host "Lecture liste locale: $LocalDir"
$localFiles = Get-ChildItem -LiteralPath $LocalDir -Recurse -File
$localMap = @{}  # relPath -> object { Full, Size, MtimeEpoch, Hash? }

foreach ($f in $localFiles) {
  $rel = $f.FullName.Substring($LocalDir.Length).TrimStart('\') -replace '\\','/'
  $mtimeEpoch = [int][double]([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeSeconds()
  $obj = [pscustomobject]@{
    Rel  = $rel
    Full = $f.FullName
    Size = [int64]$f.Length
    Mtime = $mtimeEpoch
    Hash = $null
  }
  $localMap[$rel] = $obj
}

if ($UseHash) {
  Write-Host "Calcul des hash locaux (SHA256) (peut être long)..."
  foreach ($k in $localMap.Keys) {
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $localMap[$k].Full).Hash.ToLowerInvariant()
    $localMap[$k].Hash = $h
  }
}

# --- Liste distante via SSH (TSV: rel \t size \t mtime \t [hash])
Write-Host "Lecture liste distante: ${Remote}:${RemoteDir}"
$rdEsc = Escape-RemoteSingleQuotes $RemoteDir

if ($UseHash) {
  $remoteCmd = @'
bash -lc '
set -euo pipefail
cd -- '"$rdEsc"'
# print: rel<TAB>size<TAB>mtime<TAB>sha256
find . -type f -print0 |
  while IFS= read -r -d "" f; do
    rel="\${f#./}"
    size=\$(stat -c %s -- "\$f")
    mt=\$(stat -c %Y -- "\$f")
    hs=\$(sha256sum -- "\$f" | awk "{print \\\$1}")
    printf "%s\t%s\t%s\t%s\n" "\$rel" "\$size" "\$mt" "\$hs"
  done
'
'@
} else {
  $remoteCmd = @'
bash -lc '
set -euo pipefail
cd -- '"$rdEsc"'
# print: rel<TAB>size<TAB>mtime
find . -type f -print0 |
  while IFS= read -r -d "" f; do
    rel="\${f#./}"2
    size=\$(stat -c %s -- "\$f")
    mt=\$(stat -c %Y -- "\$f")
    printf "%s\t%s\t%s\n" "\$rel" "\$size" "\$mt"
  done
'
'@
}

$remoteOutput = Invoke-Ssh $remoteCmd
$remoteMap = @{}  # relPath -> object { Rel, Size, MtimeEpoch, Hash? }

foreach ($line in ($remoteOutput -split "`n")) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $parts = $line -split "`t"
  if ($parts.Count -lt 3) { continue }
  $rel = $parts[0]
  $obj = [pscustomobject]@{
    Rel = $rel
    Size = [int64]$parts[1]
    Mtime = [int64]$parts[2]
    Hash = $null
  }
  if ($UseHash -and $parts.Count -ge 4) { $obj.Hash = $parts[3].ToLowerInvariant() }
  $remoteMap[$rel] = $obj
}

# --- Comparaison
$onlyLocal = New-Object System.Collections.Generic.List[object]
$onlyRemote = New-Object System.Collections.Generic.List[object]
$diffBoth = New-Object System.Collections.Generic.List[object]

# fichiers presents local
foreach ($rel in $localMap.Keys) {
  if (-not $remoteMap.ContainsKey($rel)) {
    $onlyLocal.Add($localMap[$rel])
  } else {
    $l = $localMap[$rel]
    $r = $remoteMap[$rel]
    $different = $false

    if ($UseHash) {
      if ($l.Hash -ne $r.Hash) { $different = $true }
    } else {
      # rapide: taille + mtime
      if ($l.Size -ne $r.Size -or $l.Mtime -ne $r.Mtime) { $different = $true }
    }

    if ($different) {
      $diffBoth.Add([pscustomobject]@{
        Rel = $rel
        LocalSize = $l.Size
        LocalMtime = $l.Mtime
        RemoteSize = $r.Size
        RemoteMtime = $r.Mtime
      })
    }
  }
}

# fichiers presents remote seulement
foreach ($rel in $remoteMap.Keys) {
  if (-not $localMap.ContainsKey($rel)) {
    $onlyRemote.Add($remoteMap[$rel])
  }
}

# --- Affichage resume
Write-Host ""
Write-Host "=== DIFFERENCES ===" -ForegroundColor Cyan
Write-Host ("Ajouts cote Windows (a uploader): {0}" -f $onlyLocal.Count)
Write-Host ("Ajouts cote Linux   (a telecharger): {0}" -f $onlyRemote.Count)
Write-Host ("Modifies des deux cotes (diff): {0}" -f $diffBoth.Count)

if ($onlyLocal.Count -gt 0) {
  Write-Host "`n--- Ajouts Windows -> Linux ---" -ForegroundColor Yellow
  $onlyLocal | Select-Object -First 30 | ForEach-Object { Write-Host $_.Rel }
  if ($onlyLocal.Count -gt 30) { Write-Host "… (+$($onlyLocal.Count-30))" }
}

if ($onlyRemote.Count -gt 0) {
  Write-Host "`n--- Ajouts Linux -> Windows ---" -ForegroundColor Yellow
  $onlyRemote | Select-Object -First 30 | ForEach-Object { Write-Host $_.Rel }
  if ($onlyRemote.Count -gt 30) { Write-Host "… (+$($onlyRemote.Count-30))" }
}

if ($diffBoth.Count -gt 0) {
  Write-Host "`n--- Modifies (local vs distant) ---" -ForegroundColor Yellow
  $diffBoth | Select-Object -First 30 | ForEach-Object {
    Write-Host ("{0}  (L:{1}/{2}  R:{3}/{4})" -f $_.Rel, $_.LocalSize, $_.LocalMtime, $_.RemoteSize, $_.RemoteMtime)
  }
  if ($diffBoth.Count -gt 30) { Write-Host "… (+$($diffBoth.Count-30))" }
}

# --- Choix utilisateur
Write-Host ""
Write-Host "Que veux-tu faire ?" -ForegroundColor Cyan
Write-Host "  [1] Tout copier Windows -> Linux (upload des ajouts + remplace les modifies cote Linux)"
Write-Host "  [2] Tout copier Linux -> Windows (download des ajouts + remplace les modifies cote Windows)"
Write-Host "  [3] Fichier par fichier (pour les ajouts + modifies)"
Write-Host "  [0] Quitter"
$choice = Read-Host "Choix"

function RemoteFileFullPath([string]$rel) {
  # construit un chemin POSIX complet
  $p = ($RemoteDir.TrimEnd('/') + '/' + $rel) -replace '//','/'
  return $p
}

function Upload-One([string]$rel) {
  $localFull = $localMap[$rel].Full
  $remoteFull = RemoteFileFullPath $rel
  Ensure-RemoteDir $remoteFull
  $remoteEsc = Escape-RemoteSingleQuotes $remoteFull
  # scp attend remote:path, path peut être quote via shell distant => on met des quotes simples
  Invoke-ScpUpload $localFull ("'" + $remoteEsc + "'")
}

function Download-One([string]$rel) {
  $remoteFull = RemoteFileFullPath $rel
  $localFull = Join-Path $LocalDir ($rel -replace '/','\')
  Ensure-LocalDir $localFull
  $remoteEsc = Escape-RemoteSingleQuotes $remoteFull
  Invoke-ScpDownload ("'" + $remoteEsc + "'") $localFull
}

function All-Upload() {
  Write-Host "`n=== UPLOAD Windows -> Linux ===" -ForegroundColor Cyan
  foreach ($o in $onlyLocal) {
    Write-Host "UPLOAD + $($o.Rel)"
    Upload-One $o.Rel
  }
  foreach ($d in $diffBoth) {
    Write-Host "UPLOAD * $($d.Rel)"
    Upload-One $d.Rel
  }
  Write-Host "Termine."
}

function All-Download() {
  Write-Host "`n=== DOWNLOAD Linux -> Windows ===" -ForegroundColor Cyan
  foreach ($o in $onlyRemote) {
    Write-Host "DOWNLOAD + $($o.Rel)"
    Download-One $o.Rel
  }
  foreach ($d in $diffBoth) {
    Write-Host "DOWNLOAD * $($d.Rel)"
    Download-One $d.Rel
  }
  Write-Host "Termine."
}

function Interactive() {
  Write-Host "`n=== MODE INTERACTIF ===" -ForegroundColor Cyan
  $items = @()

  foreach ($o in $onlyLocal) {
    $items += [pscustomobject]@{ Rel=$o.Rel; Type="Ajout local"; Default="L" }
  }
  foreach ($o in $onlyRemote) {
    $items += [pscustomobject]@{ Rel=$o.Rel; Type="Ajout remote"; Default="R" }
  }
  foreach ($d in $diffBoth) {
    $items += [pscustomobject]@{ Rel=$d.Rel; Type="Modifie"; Default="?" }
  }

  foreach ($it in $items) {
    Write-Host ""
    Write-Host ("{0} :: {1}" -f $it.Type, $it.Rel) -ForegroundColor Yellow
    Write-Host "  [L] Copier Windows -> Linux"
    Write-Host "  [R] Copier Linux -> Windows"
    Write-Host "  [S] Skip"
    $c = Read-Host ("Choix (defaut: {0})" -f $it.Default)

    if ([string]::IsNullOrWhiteSpace($c)) { $c = $it.Default }
    $c = $c.ToUpperInvariant()

    switch ($c) {
      "L" { Write-Host "=> UPLOAD $($it.Rel)"; Upload-One $it.Rel }
      "R" { Write-Host "=> DOWNLOAD $($it.Rel)"; Download-One $it.Rel }
      default { Write-Host "=> SKIP $($it.Rel)" }
    }
  }
  Write-Host "Termine."
}

switch ($choice) {
  "1" { All-Upload }
  "2" { All-Download }
  "3" { Interactive }
  default { Write-Host "Quit." }
}