# Gökhan'ın PowerShell 7 profili — Winsetup tarafından kurulur.
# dotfiles/fish/config.fish'in Windows karşılığı.

# zoxide ve starship init çıktıları statik; her açılışta üretmek yerine
# cache'le, sadece binary güncellenince yenile.
$cacheDir = Join-Path $env:LOCALAPPDATA 'pwsh-cache'
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }

function Import-CachedInit([string]$Name, [scriptblock]$Generate, [string[]]$DependsOn) {
    $exe = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { return }
    $file = Join-Path $cacheDir "$Name.ps1"
    $stale = -not (Test-Path $file)
    if (-not $stale) {
        $cached = (Get-Item $file).LastWriteTime
        foreach ($dep in @($exe.Source) + $DependsOn) {
            if ($dep -and (Test-Path $dep) -and (Get-Item $dep).LastWriteTime -gt $cached) { $stale = $true; break }
        }
    }
    if ($stale) {
        $enc = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        try { & $Generate | Out-String | Set-Content -Path $file -Encoding utf8 }
        finally { [Console]::OutputEncoding = $enc }
    }
    . $file
}

# starship init her açılışta continuation prompt için starship.exe çalıştırıyor;
# çıktısını cache'e göm. starship.toml değişince cache yenilenir.
$starshipConfig = if ($env:STARSHIP_CONFIG) { $env:STARSHIP_CONFIG } else { "$HOME\.config\starship.toml" }
Import-CachedInit starship {
    $cont = (starship prompt --continuation) -join '' -replace "'", "''"
    (starship init powershell --print-full-init | Out-String) -replace `
        '(?s)Set-PSReadLineOption -ContinuationPrompt \(\s*Invoke-Native.*?"--continuation"\s*\)\s*\)',
        "Set-PSReadLineOption -ContinuationPrompt '$cont'"
} -DependsOn $starshipConfig
Import-CachedInit zoxide { zoxide init powershell }

# fzf: Ctrl+T dosya, Ctrl+R geçmiş. PSFzf yüklemesi ~150 ms sürüyor; tuşa ilk
# basışta yüklenir, Set-PsFzfOption tuşları PSFzf'in kendi handler'larına bağlar.
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    function Initialize-PsFzf {
        Import-Module PSFzf -Global -ErrorAction SilentlyContinue
        if (-not (Get-Module PSFzf)) { return $false }
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
        $true
    }
    Set-PSReadLineKeyHandler -Chord Ctrl+t -ScriptBlock {
        if (Initialize-PsFzf) { Invoke-FzfPsReadlineHandlerProvider }
    }
    Set-PSReadLineKeyHandler -Chord Ctrl+r -ScriptBlock {
        if (Initialize-PsFzf) { Invoke-FzfPsReadlineHandlerHistory }
        else { [Microsoft.PowerShell.PSConsoleReadLine]::ReverseSearchHistory() }
    }
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
