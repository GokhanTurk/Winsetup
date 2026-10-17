# Gökhan'ın PowerShell 7 profili — Winsetup tarafından kurulur.
# dotfiles/fish/config.fish'in Windows karşılığı.

# zoxide ve starship init çıktıları statik; her açılışta üretmek yerine
# cache'le, sadece binary güncellenince yenile.
$cacheDir = Join-Path $env:LOCALAPPDATA 'pwsh-cache'
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }

function Import-CachedInit([string]$Name, [scriptblock]$Generate) {
    $exe = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { return }
    $file = Join-Path $cacheDir "$Name.ps1"
    if (-not (Test-Path $file) -or (Get-Item $exe.Source).LastWriteTime -gt (Get-Item $file).LastWriteTime) {
        & $Generate | Out-String | Set-Content -Path $file -Encoding utf8
    }
    . $file
}

Import-CachedInit starship { starship init powershell --print-full-init }
Import-CachedInit zoxide { zoxide init powershell }

# fzf: Ctrl+T dosya, Ctrl+R geçmiş
if ((Get-Command fzf -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable PSFzf)) {
    Import-Module PSFzf
    Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
}

if (Get-Command nvim -ErrorAction SilentlyContinue) {
    $env:EDITOR = 'nvim'
    $env:VISUAL = 'nvim'
    Set-Alias v nvim
}

if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
    Set-Alias ff fastfetch
}

if (Get-Command eza -ErrorAction SilentlyContinue) {
    Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
    function ls { eza @args }
    function ll { eza -l @args }
}

if (Get-Command bat -ErrorAction SilentlyContinue) {
    Remove-Item Alias:cat -Force -ErrorAction SilentlyContinue
    function cat { bat @args }
}

function myip {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '169.254.*' }
    foreach ($ip in $ips) {
        $adapter = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adapter -or $adapter.Status -ne 'Up' -or $adapter.Virtual) { continue }
        $label = if ($adapter.PhysicalMediaType -match '802\.11|Wireless') { 'Wifi' } else { 'Ethernet' }
        "${label}: $($ip.IPAddress)"
    }
}

# fish_greeting karşılığı
if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
    fastfetch
}
