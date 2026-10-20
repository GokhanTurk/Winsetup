# Winsetup — Windows 11 tek tıkla kurulum
# Kullanım:
#   irm gokhanturk.com/win | iex
#   & ([scriptblock]::Create((irm gokhanturk.com/win))) -Profile Gaming -Yes
#   & ([scriptblock]::Create((irm gokhanturk.com/win))) -Profile Debloat -Level Full -Yes

# Tüm script ayrı bir kapsamda çalışır: irm | iex ile çalışınca param bloğu kullanıcının oturumunda
# çalışır ve -Profile otomatik $PROFILE değişkeniyle çakışır; ayrıca fonksiyonlar oturuma sızmaz.
& {

param(
    [ValidateSet('Gaming', 'Work', 'VM', 'Standard', 'Debloat', 'Neovim', 'Terminal', 'RSAT')]
    [string]$Profile,
    [ValidateSet('Standard', 'Full')]
    [string]$Level,
    [switch]$Yes,
    # -Yes ile terminal arka planına BJK logosu konmaz
    [switch]$NoLogo,
    [switch]$DryRun,
    # Yerel klondan çalışırken config/asset dosyaları buradan kopyalanır (otomatik verilir)
    [string]$LocalRepo
)

if (-not $LocalRepo -and $PSScriptRoot) { $LocalRepo = $PSScriptRoot }

# Windows PowerShell 5.1 BOM'suz dosyayı ANSI okur (Türkçe karakterler bozulur); diskten çalıştırılınca
# metin UTF-8 olarak yeniden okunup çalıştırılır. irm ile gelen ve yönetici penceresindeki kopya etkilenmez.
if ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSCommandPath) {
    $forward = @{} + $PSBoundParameters
    $forward.LocalRepo = $LocalRepo
    $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($PSCommandPath, [Text.Encoding]::UTF8), [ref]$null, [ref]$null)
    # Dosyadaki & { param(...) ... } bloğu
    $body = $ast.Find({ $args[0] -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $false).ScriptBlock.GetScriptBlock()
    & $body @forward
    return
}
# Yönetici penceresi script'i tekrar indirmez, bu metni diskten okur (bkz. Start-Elevated)
$SelfSource = "& {$($MyInvocation.MyCommand.ScriptBlock)} @args"

$RepoRaw = 'https://raw.githubusercontent.com/GokhanTurk/Winsetup/main'
$DotfilesRaw = 'https://raw.githubusercontent.com/GokhanTurk/dotfiles/main'
$LogPath = Join-Path $env:TEMP 'Winsetup.log'
$DataDir = Join-Path $env:LOCALAPPDATA 'Winsetup'
$MachineDataDir = Join-Path $env:ProgramData 'Winsetup'
$State = @{ Warnings = 0 }

#region Yardımcılar

function Write-Info([string]$Message) { Write-Host "  $Message" -ForegroundColor Gray }
function Write-Ok([string]$Message) { Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) {
    $State.Warnings++
    Write-Host "  UYARI: $Message" -ForegroundColor Yellow
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Warn "Kayıt defteri yazılamadı: $Path\$Name"
    }
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Save-File([string]$Url, [string]$Destination) {
    $dir = Split-Path $Destination -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path $Destination) -and -not (Test-Path "$Destination.winsetup.bak")) {
        Copy-Item $Destination "$Destination.winsetup.bak" -Force
    }
    if ($LocalRepo -and $Url.StartsWith("$RepoRaw/")) {
        $local = Join-Path $LocalRepo ($Url.Substring($RepoRaw.Length + 1) -replace '/', '\')
        Copy-Item -LiteralPath $local -Destination $Destination -Force
        Write-Info "Kopyalandı: $Destination"
        return
    }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
        Write-Info "İndirildi: $Destination"
    } catch {
        Write-Warn "İndirilemedi: $Url"
    }
}

# Default kullanıcı hive'ı: yeni açılacak hesaplar buradan kopyalanır.
function Invoke-DefaultUserHive([scriptblock]$Action) {
    $mount = 'HKU\WinsetupDefault'
    reg.exe load $mount "$env:SystemDrive\Users\Default\NTUSER.DAT" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Default kullanıcı hive''ı yüklenemedi'
        return
    }
    try {
        & $Action 'Registry::HKEY_USERS\WinsetupDefault'
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 1
        reg.exe unload $mount 2>&1 | Out-Null
    }
}

function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

#endregion

#region winget

function Initialize-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Write-Info 'winget bulunamadı, kaydediliyor...'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    } catch { }
    $env:Path += ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }

    Write-Info 'winget onarılıyor (Microsoft.WinGet.Client)...'
    try {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        Install-Module Microsoft.WinGet.Client -Force -Scope CurrentUser -Repository PSGallery -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -Latest -ErrorAction Stop
    } catch { }
    [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# winget'in sessiz kurulum parametrelerine eklenecek kurucu parametreleri.
# Git: /COMPONENTS varsayılan listeden sağ tık menüsü (ext, ext\shellhere, ext\guihere) çıkarılmış hali;
# kurucu seçimi hatırlar, güncellemelerde menü geri gelmez.
$WingetCustom = @{ 'Git.Git' = '/COMPONENTS=gitlfs,assoc,assoc_sh,scalar' }

function Install-WingetPackage([string]$Id) {
    Write-Info "Kuruluyor: $Id"
    $extra = if ($WingetCustom.ContainsKey($Id)) { @('--custom', $WingetCustom[$Id]) } else { @() }
    winget install --id $Id --exact --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity @extra | Out-Null
    # 0x8A15002B: güncelleme yok, 0x8A150061: zaten kurulu
    if ($LASTEXITCODE -in 0, -1978335189, -1978335135) {
        Write-Ok "Tamam: $Id"
    } else {
        Write-Warn "$Id kurulamadı (winget kodu $LASTEXITCODE)"
    }
}

function Install-Apps([string[]]$Ids) {
    if (-not (Initialize-Winget)) {
        Write-Warn 'winget kullanılamıyor, uygulamalar atlandı'
        return
    }
    foreach ($id in $Ids) { Install-WingetPackage $id }
    Update-SessionPath
}

#endregion

#region Debloat

# Standart profilde bile kaldırılan, kimsenin özlemeyeceği uygulamalar.
$JunkApps = @(
    'Microsoft.BingNews', 'Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.BingSearch',
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.WindowsFeedbackHub', 'Microsoft.MixedReality.Portal', 'Microsoft.3DBuilder',
    'Microsoft.Microsoft3DViewer', 'Microsoft.Print3D', 'Clipchamp.Clipchamp',
    'Microsoft.PowerAutomateDesktop', 'Microsoft.Windows.DevHome', '7EE7776C.LinkedInforWindows',
    'Microsoft.SkypeApp', 'Microsoft.People', 'Microsoft.Wallet', 'Microsoft.Messaging',
    'Microsoft.Office.Sway', 'Microsoft.OneConnect', 'Microsoft.MicrosoftOfficeHub',
    'Microsoft.549981C3F5F10', 'Microsoft.WindowsMaps', 'Microsoft.Todos', 'Microsoft.Office.OneNote',
    'Microsoft.Copilot', 'MicrosoftCorporationII.MicrosoftFamily',
    'SpotifyAB.SpotifyMusic', 'Disney.37853FC22B2CE', 'king.com.*'
)

# Full seviyede Microsoft'un tüm uygulamaları kaldırılır, bunlar hariç.
# Donanım üreticisi uygulamaları (NVIDIA, Intel, Realtek, HP...) Microsoft yayıncılı olmadığı için zaten dokunulmaz.
$FullKeepApps = @(
    'Microsoft.WindowsCalculator', 'Microsoft.WindowsNotepad', 'Microsoft.WindowsTerminal',
    'Microsoft.ScreenSketch', 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp',
    'Microsoft.DesktopAppInstaller', 'Microsoft.Winget.Source', 'Microsoft.Windows.Photos',
    'Microsoft.Paint', 'Microsoft.PowerShell', 'Microsoft.SecHealthUI',
    '*VideoExtension*', '*ImageExtension*', 'Microsoft.WebMediaExtensions',
    'Microsoft.LanguageExperiencePack*', 'Microsoft.ApplicationCompatibilityEnhancements',
    'Microsoft.StartExperiencesApp', 'Microsoft.MicrosoftEdge*', 'Microsoft.WindowsAppRuntime*',
    'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.*', 'Microsoft.Services.Store.Engagement',
    '*CBS*'
)

function Test-NameLike([string]$Name, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    $false
}

function Test-ShouldRemove([string]$Name, [string]$FamilyOrFullName, [string]$DebloatLevel, [string[]]$Extra) {
    if (Test-NameLike $Name ($JunkApps + $Extra)) { return $true }
    if ($DebloatLevel -ne 'Full') { return $false }
    $isMicrosoft = $FamilyOrFullName -like '*_8wekyb3d8bbwe' -or $FamilyOrFullName -like '*_cw5n1h2txyewy'
    $isMicrosoft -and -not (Test-NameLike $Name $FullKeepApps)
}

$CopilotKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Copilot'
$EdgeKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'

$AppLabels = @{
    'Microsoft.BingNews' = 'Bing Haberler'; 'Microsoft.BingFinance' = 'Bing Finans'; 'Microsoft.BingSports' = 'Bing Spor'
    'Microsoft.BingSearch' = 'Bing Arama'; 'Microsoft.BingWeather' = 'Hava Durumu'; 'Microsoft.GetHelp' = 'Yardım Alın'
    'Microsoft.Getstarted' = 'İpuçları'; 'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire'
    'Microsoft.WindowsFeedbackHub' = 'Geri Bildirim Merkezi'; 'Microsoft.MixedReality.Portal' = 'Mixed Reality'
    'Microsoft.3DBuilder' = '3D Builder'; 'Microsoft.Microsoft3DViewer' = '3D Görüntüleyici'; 'Microsoft.Print3D' = 'Print 3D'
    'Clipchamp.Clipchamp' = 'Clipchamp'; 'Microsoft.PowerAutomateDesktop' = 'Power Automate'; 'Microsoft.Windows.DevHome' = 'Dev Home'
    '7EE7776C.LinkedInforWindows' = 'LinkedIn'; 'Microsoft.SkypeApp' = 'Skype'; 'Microsoft.People' = 'Kişiler'
    'Microsoft.Wallet' = 'Wallet'; 'Microsoft.Messaging' = 'Mesajlaşma'; 'Microsoft.Office.Sway' = 'Sway'
    'Microsoft.OneConnect' = 'Mobil Planlar'; 'Microsoft.MicrosoftOfficeHub' = 'Microsoft 365 (Office)'
    'Microsoft.549981C3F5F10' = 'Cortana'; 'Microsoft.WindowsMaps' = 'Haritalar'; 'Microsoft.Todos' = 'To Do'
    'Microsoft.Office.OneNote' = 'OneNote'; 'Microsoft.Copilot' = 'Copilot'; 'MicrosoftCorporationII.MicrosoftFamily' = 'Aile Güvenliği'
    'SpotifyAB.SpotifyMusic' = 'Spotify'; 'Disney.37853FC22B2CE' = 'Disney+'
    'Microsoft.GamingApp' = 'Xbox'; 'Microsoft.XboxGamingOverlay' = 'Xbox Game Bar'; 'Microsoft.XboxGameOverlay' = 'Xbox Game Overlay'
    'Microsoft.XboxIdentityProvider' = 'Xbox Kimlik Sağlayıcı'; 'Microsoft.XboxSpeechToTextOverlay' = 'Xbox Konuşmayı Metne Dönüştürme'
    'Microsoft.Xbox.TCUI' = 'Xbox TCUI'; 'Microsoft.YourPhone' = 'Telefon Bağlantısı'; 'MicrosoftWindows.CrossDevice' = 'Cihazlar Arası Deneyim'
    'Microsoft.ZuneMusic' = 'Media Player'; 'Microsoft.ZuneVideo' = 'Filmler ve TV'; 'Microsoft.WindowsAlarms' = 'Saat'
    'Microsoft.WindowsCamera' = 'Kamera'; 'Microsoft.WindowsSoundRecorder' = 'Ses Kaydedici'; 'Microsoft.MicrosoftStickyNotes' = 'Yapışkan Notlar'
    'Microsoft.OutlookForWindows' = 'Outlook'; 'MSTeams' = 'Teams'; 'MicrosoftCorporationII.QuickAssist' = 'Hızlı Yardım'
    'MicrosoftWindows.Client.WebExperience' = 'Widgets'; 'Microsoft.WidgetsPlatformRuntime' = 'Widgets Platformu'
    'Microsoft.OneDriveSync' = 'OneDrive'; 'Microsoft.WindowsCalculator' = 'Hesap Makinesi'; 'Microsoft.WindowsNotepad' = 'Not Defteri'
    'Microsoft.Paint' = 'Paint'; 'Microsoft.ScreenSketch' = 'Ekran Alıntısı Aracı'; 'Microsoft.Windows.Photos' = 'Fotoğraflar'
}

function Get-ShortAppName([string]$Name) {
    if ($AppLabels.ContainsKey($Name)) { return $AppLabels[$Name] }
    if ($Name -like 'king.com.*') { return 'Candy Crush' }
    $Name -replace '^(MicrosoftWindows|MicrosoftCorporationII|Microsoft)\.', ''
}

# Kaldırılacakları önceden hesaplar: plan bu listeyi onaydan önce gösterir, adım tam olarak bunu kaldırır.
function Get-BloatTargets([string]$DebloatLevel, [string[]]$Extra = @()) {
    $provisioned = @()
    try {
        $provisioned = @(foreach ($pkg in Get-AppxProvisionedPackage -Online -ErrorAction Stop) {
            $parts = $pkg.PackageName -split '_'
            $family = "$($parts[0])_$($parts[-1])"
            if (Test-ShouldRemove $pkg.DisplayName $family $DebloatLevel $Extra) {
                [pscustomobject]@{ Name = $pkg.DisplayName; Family = $family; PackageName = $pkg.PackageName }
            }
        })
    } catch { }
    $all = try { Get-AppxPackage -AllUsers -ErrorAction Stop } catch { Get-AppxPackage }
    $installed = @($all | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -ne 'System' } |
        Sort-Object PackageFullName -Unique |
        Where-Object { Test-ShouldRemove $_.Name $_.PackageFamilyName $DebloatLevel $Extra })

    $names = @(@($installed | ForEach-Object Name) + @($provisioned | ForEach-Object Name) |
        ForEach-Object { Get-ShortAppName $_ } | Sort-Object -Unique)
    if (Test-Path -LiteralPath $CopilotKey) { $names += 'Copilot (Win32)' }
    [pscustomobject]@{ Provisioned = $provisioned; Installed = $installed; Names = $names }
}

# Copilot artık Store uygulamasının yanında Edge gibi ayrı bir Win32 program olarak da geliyor.
function Remove-CopilotApp {
    $uninstall = (Get-ItemProperty -LiteralPath $CopilotKey -ErrorAction SilentlyContinue).UninstallString
    if ($uninstall -match '^"([^"]+)"\s*(.*)$') {
        Get-Process -Name '*copilot*' -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Process -FilePath $Matches[1] -ArgumentList "$($Matches[2]) --force-uninstall" -Wait -WindowStyle Hidden
        if (Test-Path -LiteralPath $CopilotKey) { Write-Warn 'Copilot (Win32) kaldırılamadı' } else { Write-Ok 'Kaldırıldı: Copilot (Win32)' }
    }
    # EdgeUpdate Copilot'u tekrar kurmasın
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{C50565E9-CCCF-44B4-BA15-5AC5C6569197}' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
}

function Remove-Bloatware($Targets) {
    if ($Targets.Names.Count -eq 0) { Write-Info 'Kaldırılacak uygulama yok, sistem zaten temiz' }
    $deprovisioned = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'

    # Yeni açılacak hesaplar için (provisioned)
    foreach ($pkg in $Targets.Provisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -AllUsers -ErrorAction Stop | Out-Null
            # Windows özellik güncellemesinden sonra geri yüklenmesin
            if (-not (Test-Path "$deprovisioned\$($pkg.Family)")) { New-Item -Path "$deprovisioned\$($pkg.Family)" -Force | Out-Null }
            Write-Ok "Kaldırıldı (yeni hesaplar): $(Get-ShortAppName $pkg.Name)"
        } catch {
            Write-Warn "Kaldırılamadı (yeni hesaplar): $(Get-ShortAppName $pkg.Name)"
        }
    }

    # Mevcut tüm kullanıcılar için
    foreach ($pkg in $Targets.Installed) {
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Write-Ok "Kaldırıldı: $(Get-ShortAppName $pkg.Name)"
        } catch {
            Write-Warn "Kaldırılamadı: $(Get-ShortAppName $pkg.Name)"
        }
    }

    Remove-CopilotApp
}

function Set-ContentDeliveryOff([string]$Root) {
    $cdm = "$Root\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    $names = @(
        'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
        'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled',
        'SoftLandingEnabled', 'SubscribedContentEnabled', 'SystemPaneSuggestionsEnabled',
        'RotatingLockScreenOverlayEnabled', 'SubscribedContent-310093Enabled',
        'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
        'SubscribedContent-338389Enabled', 'SubscribedContent-338393Enabled',
        'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled'
    )
    foreach ($n in $names) { Set-Reg $cdm $n 0 }
}

# Kaldırılan uygulamaların geri gelmesini engeller.
function Protect-Debloat([string]$DebloatLevel) {
    $cloud = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
    Set-Reg $cloud 'DisableWindowsConsumerFeatures' 1
    Set-Reg $cloud 'DisableConsumerAccountStateContent' 1
    Set-Reg $cloud 'DisableCloudOptimizedContent' 1

    Set-ContentDeliveryOff 'HKCU:'
    Invoke-DefaultUserHive { param($root) Set-ContentDeliveryOff $root }

    # Dev Home ve (Full'de) Outlook'u Windows Update tekrar kurmasın
    $updates = @('DevHomeUpdate')
    if ($DebloatLevel -eq 'Full') { $updates += 'OutlookUpdate' }
    foreach ($u in $updates) {
        foreach ($base in 'UScheduler_Oobe', 'UScheduler') {
            Remove-Item "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\$base\$u" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($DebloatLevel -eq 'Full') {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 3
    }
    Write-Ok 'Kaldırılanların geri gelmesi engellendi (Windows güncellemeleri, yeni hesaplar, önerilen uygulama kurulumları)'
}

function Test-OneDriveInstalled {
    $keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe'
    [bool]($keys | Where-Object { Test-Path -LiteralPath $_ })
}

function Remove-OneDrive {
    if (Test-OneDriveInstalled) {
        Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget uninstall --id Microsoft.OneDrive --exact --silent --accept-source-agreements --disable-interactivity | Out-Null
        }
        foreach ($setup in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
            if (Test-Path $setup) { Start-Process $setup -ArgumentList '/uninstall' -Wait -WindowStyle Hidden }
        }
        if (Test-OneDriveInstalled) { Write-Warn 'OneDrive kaldırılamadı' } else { Write-Ok 'Kaldırıldı: OneDrive' }
    } else {
        Write-Info 'OneDrive zaten kurulu değil'
    }
    # Yeni kullanıcılarda ilk girişte kurulmasın
    Invoke-DefaultUserHive {
        param($root)
        Remove-ItemProperty "$root\Software\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDriveSetup' -ErrorAction SilentlyContinue
    }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Write-Ok 'OneDrive''ın yeni hesaplarda kurulması engellendi'
}

$CapabilityPatterns = @(
    'App.StepsRecorder*', 'MathRecognizer*', 'Microsoft.Windows.WordPad*', 'Browser.InternetExplorer*',
    'Hello.Face*', 'Microsoft.Windows.PowerShell.ISE*', 'Media.WindowsMediaPlayer*', 'XPS.Viewer*',
    'Microsoft.Wallpapers.Extended*', 'App.Support.QuickAssist*'
)
$OptionalFeatureNames = @('Recall', 'WorkFolders-Client', 'Printing-XPSServices-Features',
    'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2')

function Remove-OptionalComponents {
    $done = 0
    Write-Info 'Yüklü bileşenler taranıyor...'
    foreach ($cap in Get-WindowsCapability -Online | Where-Object { $_.State -eq 'Installed' }) {
        if (-not (Test-NameLike $cap.Name $CapabilityPatterns)) { continue }
        $name = $cap.Name -replace '~.*$', ''
        Write-Info "Kaldırılıyor: $name"
        try {
            Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            Write-Ok "Kaldırıldı: $name"
            $done++
        } catch {
            Write-Warn "Kaldırılamadı: $name"
        }
    }

    foreach ($f in $OptionalFeatureNames) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if (-not $feature -or $feature.State -ne 'Enabled') { continue }
        try {
            Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
            Write-Ok "Kapatıldı (özellik): $f"
            $done++
        } catch {
            Write-Warn "Kapatılamadı (özellik): $f"
        }
    }
    if ($done -eq 0) { Write-Info 'Kaldırılacak bileşen yok, hepsi zaten kaldırılmış' }
}

# Edge kaldırılır, WebView2 kalır (launcher'lar ve Discord ona ihtiyaç duyar).
function Remove-Edge {
    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
    $uninstall = (Get-ItemProperty -LiteralPath $EdgeKey -ErrorAction SilentlyContinue).UninstallString
    $wasInstalled = [bool]$uninstall

    if ($uninstall -match '^"([^"]+)"\s*(.*)$') {
        $setupExe = $Matches[1]
        $setupArgs = $Matches[2]
        # setup.exe sadece "eski Edge" varken kaldırmaya izin veriyor; geçici sahte dosya ile ikna ediyoruz.
        $stubDir = "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
        $stubExe = "$stubDir\MicrosoftEdge.exe"
        $created = @()
        try {
            if (-not (Test-Path $stubDir)) { New-Item -ItemType Directory -Path $stubDir -ErrorAction Stop | Out-Null; $created += $stubDir }
            if (-not (Test-Path $stubExe)) { New-Item -ItemType File -Path $stubExe -ErrorAction Stop | Out-Null; $created = @($stubExe) + $created }
        } catch { }
        Start-Process -FilePath $setupExe -ArgumentList "$setupArgs --force-uninstall" -Wait -WindowStyle Hidden
        foreach ($p in $created) { Remove-Item $p -Force -Recurse -ErrorAction SilentlyContinue }
    }

    Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue |
        Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

    # EdgeUpdate WebView2'yi güncellemeye devam eder ama Edge'i tekrar kurmaz
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 0

    $shortcuts = @(
        "$env:PUBLIC\Desktop\Microsoft Edge.lnk",
        "$env:USERPROFILE\Desktop\Microsoft Edge.lnk",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
        "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk"
    )
    Remove-Item $shortcuts -Force -ErrorAction SilentlyContinue

    if (-not $wasInstalled) {
        Write-Info 'Edge zaten kurulu değil'
    } elseif (Test-Path -LiteralPath $EdgeKey) {
        Write-Warn 'Edge kaldırılamadı (Microsoft yöntemi değiştirmiş olabilir)'
    } else {
        Write-Ok 'Kaldırıldı: Microsoft Edge (WebView2 duruyor)'
    }
    Write-Ok 'Edge''in tekrar kurulması engellendi'
}

#endregion

#region Windows ayarları

# Kullanıcıya ait gizlilik ayarları; mevcut kullanıcıya ve Default hive üzerinden yeni hesaplara uygulanır.
function Set-UserPrivacy([string]$Root) {
    Set-ContentDeliveryOff $Root
    $cv = "$Root\Software\Microsoft\Windows\CurrentVersion"
    $adv = "$cv\Explorer\Advanced"

    # Gizlilik > Öneriler ve teklifler
    Set-Reg "$cv\AdvertisingInfo" 'Enabled' 0
    Set-Reg "$cv\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg "$Root\Software\Policies\Microsoft\Windows\CloudContent" 'DisableTailoredExperiencesWithDiagnosticData' 1
    Set-Reg "$Root\Control Panel\International\User Profile" 'HttpAcceptLanguageOptOut' 1
    # "Improve Start and search results": açılan uygulamaların takibi
    Set-Reg $adv 'Start_TrackProgs' 0

    # Gizlilik > Mürekkep ve yazma kişiselleştirme, konuşma, geri bildirim
    Set-Reg "$Root\Software\Microsoft\InputPersonalization" 'RestrictImplicitInkCollection' 1
    Set-Reg "$Root\Software\Microsoft\InputPersonalization" 'RestrictImplicitTextCollection' 1
    Set-Reg "$Root\Software\Microsoft\InputPersonalization\TrainedDataStore" 'HarvestContacts' 0
    Set-Reg "$Root\Software\Microsoft\Personalization\Settings" 'AcceptedPrivacyPolicy' 0
    Set-Reg "$Root\Software\Microsoft\Input\TIPC" 'Enabled' 0
    Set-Reg "$Root\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" 'HasAccepted' 0
    Set-Reg "$Root\Software\Microsoft\Siuf\Rules" 'NumberOfSIUFInPeriod' 0

    # Arama: Bing, bulut içerik araması, arama geçmişi, arama vurguları
    Set-Reg "$cv\Search" 'BingSearchEnabled' 0
    Set-Reg "$cv\Search" 'CortanaConsent' 0
    Set-Reg "$Root\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1
    Set-Reg "$cv\SearchSettings" 'IsMSACloudSearchEnabled' 0
    Set-Reg "$cv\SearchSettings" 'IsAADCloudSearchEnabled' 0
    Set-Reg "$cv\SearchSettings" 'IsDeviceSearchHistoryEnabled' 0
    Set-Reg "$cv\SearchSettings" 'IsDynamicSearchBoxEnabled' 0

    # Başlat önerileri, hesap bildirimleri, "cihazı kurmayı bitir" ekranı, Gezgin'deki OneDrive/M365 tanıtımları
    Set-Reg $adv 'Start_IrisRecommendations' 0
    Set-Reg $adv 'Start_AccountNotifications' 0
    Set-Reg $adv 'ShowSyncProviderNotifications' 0
    Set-Reg "$cv\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0
}

$TelemetryTasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
    '\Microsoft\Windows\Feedback\Siuf\DmClient'
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
)

function Set-PrivacyTweaks {
    Set-UserPrivacy 'HKCU:'
    Invoke-DefaultUserHive { param($root) Set-UserPrivacy $root }

    # Tanılama verisi, geri bildirim, reklam kimliği, etkinlik geçmişi
    $policies = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
    Set-Reg "$policies\DataCollection" 'AllowTelemetry' 0
    Set-Reg "$policies\DataCollection" 'DoNotShowFeedbackNotifications' 1
    Set-Reg "$policies\AdvertisingInfo" 'DisabledByGroupPolicy' 1
    Set-Reg "$policies\System" 'EnableActivityFeed' 0
    Set-Reg "$policies\System" 'PublishUserActivities' 0
    Set-Reg "$policies\System" 'UploadUserActivities' 0
    Set-Reg "$policies\Windows Search" 'AllowCloudSearch' 0
    # Uygulama uyumluluk telemetrisi, müşteri deneyimi programı, hata raporlama
    Set-Reg "$policies\AppCompat" 'AITEnable' 0
    Set-Reg "$policies\AppCompat" 'DisableUAR' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    # Recall ekran görüntüleri
    Set-Reg "$policies\WindowsAI" 'DisableAIDataAnalysis' 1
    # Güncellemeler internetteki başka bilgisayarlara yüklenmez (sadece HTTP)
    Set-Reg "$policies\DeliveryOptimization" 'DODownloadMode' 0

    # Telemetri servisi (Connected User Experiences and Telemetry) ve zamanlanmış görevler
    Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue
    Set-Service DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue
    foreach ($task in $TelemetryTasks) {
        $name = Split-Path $task -Leaf
        Disable-ScheduledTask -TaskPath ((Split-Path $task -Parent) + '\') -TaskName $name -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Ok 'Reklam, öneri, ipucu ve telemetri kapatıldı (mevcut ve yeni hesaplar)'
}

# Ayarlar > Bildirimler ana anahtarı; kullanıcı istediğinde tekrar açabilir.
function Disable-Notifications {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
    Write-Ok 'Tüm bildirimler kapatıldı'
}

# SearchMode: 0 = gizli, 1 = sadece simge
function Set-TaskbarTweaks([int]$SearchMode) {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' $SearchMode
    Set-Reg $adv 'ShowTaskViewButton' 0
    Set-Reg $adv 'TaskbarMn' 0
    Set-Reg $adv 'ShowCopilotButton' 0
    # Widgets ayarları (Dsh, Windows Feeds, TaskbarDa) Windows tarafından kilitli (UCPD);
    # Widgets'ı kapatmak için Oyun/VM/İş profilleri uygulamanın kendisini kaldırır.
    Write-Ok 'Görev çubuğu sadeleştirildi'
}

# Arayüz dili ve klavye değişmez; tarih/saat/sayı biçimleri, konum ve saat dilimi Türkiye olur.
function Set-TurkishRegion {
    try {
        Set-Culture tr-TR -ErrorAction Stop
        Set-WinHomeLocation -GeoId 235 -ErrorAction Stop
        Set-TimeZone -Id 'Turkey Standard Time' -ErrorAction Stop
        # Karşılama ekranı ve yeni kullanıcılar da aynı biçimleri alsın
        Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction SilentlyContinue
        Write-Ok 'Bölge biçimleri Türkiye (tr-TR) olarak ayarlandı'
    } catch {
        Write-Warn "Bölge ayarları uygulanamadı: $($_.Exception.Message)"
    }
}

# Dil listesindeki her dilin klavyesi sadece Türkçe Q olur (arayüz dili değişmez).
function Set-TurkishKeyboard {
    try {
        $list = Get-WinUserLanguageList
        foreach ($lang in $list) {
            $prefix = @($lang.InputMethodTips)[0] -replace ':.*$', ''
            if (-not $prefix) { continue }
            $lang.InputMethodTips.Clear()
            $lang.InputMethodTips.Add("${prefix}:0000041F")
        }
        Set-WinUserLanguageList $list -Force -WarningAction SilentlyContinue

        # Görev çubuğunda kalan hayalet "ENG US": US düzenini ekleyip kaldırmak yüklü düzenleri sıfırlar
        $us = (@($list[0].InputMethodTips)[0] -replace ':.*$', '') + ':00000409'
        $list[0].InputMethodTips.Add($us)
        Set-WinUserLanguageList $list -Force -WarningAction SilentlyContinue
        [void]$list[0].InputMethodTips.Remove($us)
        Set-WinUserLanguageList $list -Force -WarningAction SilentlyContinue
        Write-Ok 'Klavye sadece Türkçe Q'
    } catch {
        Write-Warn "Klavye ayarlanamadı: $($_.Exception.Message)"
    }
}

function Set-FileExtensionsVisible {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
    Write-Ok 'Dosya uzantıları görünür'
}

# Num Lock açılışta açık: giriş ekranı, mevcut kullanıcı ve yeni hesaplar.
# Giriş ekranında 2 yerine 2147483650 (0x80000002) kullanılır; Windows 11 2'yi güncellemelerle sıfırlayabiliyor.
function Enable-NumLock {
    Set-Reg 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2147483650' 'String'
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
    Invoke-DefaultUserHive { param($root) Set-Reg "$root\Control Panel\Keyboard" 'InitialKeyboardIndicators' '2' 'String' }
}

# Eski OneClickToReady'den gelen kişisel ayarlar
function Set-PersonalTweaks {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
    Set-Reg $adv 'HideFileExt' 0
    Set-Reg $adv 'LaunchTo' 1
    Enable-NumLock
    # Yapışkan / Geçiş / Filtre tuşları kısayolları kapalı
    Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'
    Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
    # Prizdeyken uyku kapalı; ekran zaman aşımına dokunulmaz
    powercfg.exe /change standby-timeout-ac 0
    Set-PrivacyTweaks
    Set-TaskbarTweaks 0
    Write-Ok 'Kişisel Windows ayarları uygulandı'
}

function Disable-BackgroundApps {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Write-Ok 'Arka plan uygulamaları kapatıldı'
}

function Set-InterfaceCleanup {
    # Windows 10 tarzı klasik sağ tık menüsü
    Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String'
    # Gereksiz sağ tık girdileri: "Erişim ver", "Kitaplığa ekle", "Uyumluluk sorunlarını gider", "Sık kullanılanlara ekle"
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}' '' 'String'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' '{3dad6c5d-2167-4cae-9914-f99e41c12cfa}' '' 'String'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' '{1d27f844-3a1f-4410-85ac-14651078412d}' '' 'String'
    reg.exe delete 'HKCR\*\shell\pintohomefile' /f 2>&1 | Out-Null
    # Görev çubuğu sabitlemeleri temizlenir
    Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\*" -Force -ErrorAction SilentlyContinue
    Write-Ok 'Arayüz temizlendi (klasik sağ tık, Widgets/Copilot kapalı, taskbar boş)'
}

# desktop.ini'deki [LocalizedFileNames] haritası: "dfrgui.lnk" -> "Defragment and Optimize Drives"
function Get-LocalizedShortcutNames([string]$Dir) {
    $map = @{}
    $ini = Join-Path $Dir 'desktop.ini'
    if (-not (Test-Path -LiteralPath $ini)) { return $map }
    if (-not ('Winsetup.IndirectString' -as [type])) {
        Add-Type -Namespace Winsetup -Name IndirectString -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf, int cchOutBuf, IntPtr ppvReserved);
'@
    }
    $inSection = $false
    foreach ($line in Get-Content -LiteralPath $ini -Force -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*\[(.+)\]') { $inSection = $Matches[1] -eq 'LocalizedFileNames'; continue }
        if (-not $inSection -or $line -notmatch '^(.+?)=(.+)$') { continue }
        $file = $Matches[1].Trim()
        $source = [Environment]::ExpandEnvironmentVariables($Matches[2].Trim())
        $name = $source
        if ($source.StartsWith('@')) {
            $sb = New-Object System.Text.StringBuilder 1024
            if ([Winsetup.IndirectString]::SHLoadIndirectString($source, $sb, $sb.Capacity, [IntPtr]::Zero) -ne 0) { continue }
            $name = $sb.ToString()
        }
        $map[$file] = $name
    }
    $map
}

# Program klasörleri (Git, Steam...) düzleştirilir, kısayollar en üst düzeye taşınır; görünüm liste olur.
function Set-FlatStartMenu {
    $junk = '(?i)^uninstall|release notes|\bfaq|support center|readme|web ?site|documentation|license'
    # Windows'un kendi klasörleri (Windows Tools, Erişilebilirlik...) yerinde kalır; Startup ise açılışta çalışanların klasörü
    $windowsFolders = 'Startup', 'Administrative Tools', 'System Tools', 'Accessibility', 'Accessories', 'Maintenance', 'Windows PowerShell'
    $roots = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    foreach ($root in $roots) {
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $windowsFolders -notcontains $_.Name }) {
            # -Include, 5.1'de -LiteralPath ile çalışmıyor; uzantıyla süzülür
            $shortcuts = Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force | Where-Object { $_.Extension -in '.lnk', '.url' }
            foreach ($file in $shortcuts) {
                if ($file.BaseName -match $junk) { continue }
                $names = Get-LocalizedShortcutNames $file.DirectoryName
                $display = if ($names.ContainsKey($file.Name)) { $names[$file.Name] } else { $file.BaseName }
                $display = $display -replace '[\\/:*?"<>|]', ''
                $target = Join-Path $root ($display + $file.Extension)
                if (-not (Test-Path -LiteralPath $target)) {
                    Move-Item -LiteralPath $file.FullName -Destination $target -ErrorAction SilentlyContinue
                }
            }
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' 'AllAppsViewMode' 2
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    Write-Ok 'Başlat menüsü klasörsüz ve liste görünümünde'
}

# Başlat menüsündeki Önerilenler bölümü gizlenir; sabitlenmiş öğelere dokunulmaz.
# İlke Pro sürümde yalnızca eğitim ortamı işaretiyle uygulanıyor.
function Disable-StartRecommended {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'HideRecommendedSection' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education' 'IsEducationEnvironment' 1
    # En çok kullanılan uygulamalar listesi
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' 'ShowFrequentList' 0
    Write-Ok 'Başlat menüsünde Önerilenler bölümü kapatıldı'
}

function Disable-FastBoot {
    powercfg.exe /hibernate off
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    Write-Ok 'Hızlı başlatma ve hazırda bekletme kapatıldı'
}

function Set-Wallpaper {
    $dest = Join-Path $DataDir 'duvarkagidi.png'
    Save-File "$RepoRaw/assets/duvarkagidi.png" $dest
    if (-not (Test-Path $dest)) { return }
    if (-not ('Winsetup.Wallpaper' -as [type])) {
        Add-Type -Namespace Winsetup -Name Wallpaper -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
    }
    Set-Reg 'HKCU:\Control Panel\Desktop' 'WallpaperStyle' '10' 'String'
    # SPI_SETDESKWALLPAPER, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    [Winsetup.Wallpaper]::SystemParametersInfo(20, 0, $dest, 3) | Out-Null
    Write-Ok 'Duvar kağıdı ayarlandı'
}

#endregion

#region Oyun ayarları

function Disable-DevicePowerSaving {
    foreach ($bus in 'ACPI', 'HID', 'PCI', 'USB') {
        $keys = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\$bus" -Recurse -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $path = $key.PSPath
            if ($key.PSChildName -eq 'Device Parameters') {
                Set-ItemProperty $path 'EnhancedPowerManagementEnabled' 0 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty $path 'SelectiveSuspendEnabled' ([byte[]](0)) -Type Binary -ErrorAction SilentlyContinue
                Set-ItemProperty $path 'SelectiveSuspendOn' 0 -Type DWord -ErrorAction SilentlyContinue
                Set-ItemProperty $path 'WaitWakeEnabled' 0 -Type DWord -ErrorAction SilentlyContinue
            } elseif ($key.PSChildName -eq 'WDF') {
                Set-ItemProperty $path 'IdleInWorkingState' 0 -Type DWord -ErrorAction SilentlyContinue
            }
        }
    }

    # Ağ adaptörleri: güç tasarrufu ve uyandırma kapalı; sadece sürücünün desteklediği ayarlar değiştirilir
    $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $adapterOff = @('*EEE', 'AdvancedEEE', 'EEELinkAdvertisement', 'SipsEnabled', 'ULPMode', 'GigaLite',
        'EnableGreenEthernet', 'PowerSavingMode', 'S5WakeOnLan', '*WakeOnMagicPacket',
        '*ModernStandbyWoLMagicPacket', '*WakeOnPattern', 'WakeOnLink')
    foreach ($key in Get-ChildItem $class -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }) {
        $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        if (-not $props.NetCfgInstanceId) { continue }
        Set-ItemProperty $key.PSPath 'PnPCapabilities' 24 -Type DWord -ErrorAction SilentlyContinue
        foreach ($name in $adapterOff) {
            if ($null -ne $props.$name) { Set-ItemProperty $key.PSPath $name '0' -ErrorAction SilentlyContinue }
        }
    }
    Write-Ok 'Cihaz ve ağ adaptörü güç tasarrufu kapatıldı'
}

function Install-TimerResolution {
    $exe = "$env:SystemRoot\WinsetupTimerResolution.exe"
    $cs = "$env:TEMP\WinsetupTimerResolution.cs"
    Set-Content -Path $cs -Encoding ASCII -Value @'
using System;
using System.Runtime.InteropServices;
using System.ServiceProcess;

public class WinsetupTimerResolution : ServiceBase
{
    [DllImport("ntdll.dll")] static extern int NtQueryTimerResolution(out uint min, out uint max, out uint current);
    [DllImport("ntdll.dll")] static extern int NtSetTimerResolution(uint desired, bool set, out uint current);

    uint requested;

    public WinsetupTimerResolution() { ServiceName = "WinsetupTimerResolution"; CanStop = true; }

    protected override void OnStart(string[] args)
    {
        uint min, max, current;
        NtQueryTimerResolution(out min, out max, out current);
        requested = max;
        NtSetTimerResolution(requested, true, out current);
    }

    protected override void OnStop()
    {
        uint current;
        NtSetTimerResolution(requested, false, out current);
    }

    public static void Main() { ServiceBase.Run(new WinsetupTimerResolution()); }
}
'@
    $csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $svc = Get-Service WinsetupTimerResolution -ErrorAction SilentlyContinue
    if ($svc) { Stop-Service WinsetupTimerResolution -Force -ErrorAction SilentlyContinue }
    & $csc -nologo -out:$exe -r:System.ServiceProcess.dll $cs | Out-Null
    Remove-Item $cs -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $exe)) {
        Write-Warn 'Timer resolution servisi derlenemedi'
        return
    }
    if (-not $svc) {
        New-Service -Name WinsetupTimerResolution -BinaryPathName $exe -DisplayName 'Winsetup Timer Resolution' -StartupType Automatic | Out-Null
    }
    Start-Service WinsetupTimerResolution -ErrorAction SilentlyContinue
    # Windows 11'de bir sürecin isteği tüm sisteme uygulansın
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
    Write-Ok 'Timer resolution servisi kuruldu (0.5 ms)'
}

function Disable-GameBar {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'GamepadNexusChordEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    # Game Bar kaldırılınca oyunlarda çıkan "ms-gamingoverlay için uygulama bulun" penceresini engelle
    foreach ($protocol in 'ms-gamebar', 'ms-gamebarservices', 'ms-gamingoverlay') {
        $root = "HKCU:\Software\Classes\$protocol"
        Set-Reg $root '(default)' "URL:$protocol" 'String'
        Set-Reg $root 'URL Protocol' '' 'String'
        Set-Reg $root 'NoOpenWith' '' 'String'
        Set-Reg "$root\shell\open\command" '(default)' "$env:SystemRoot\System32\systray.exe" 'String'
    }
    Write-Ok 'Game Bar ve oyun kaydı kapatıldı'
}

function Optimize-Defender {
    try {
        # Örnek gönderme kapalı, tarama CPU kullanımı düşük
        Set-MpPreference -SubmitSamplesConsent 2 -ScanAvgCPULoadFactor 25 -ErrorAction Stop
    } catch {
        Write-Warn 'Defender tercihleri değiştirilemedi (Tamper Protection engellemiş olabilir)'
    }
    Add-MpPreference -ExclusionPath "${env:ProgramFiles(x86)}\Steam\steamapps" -ErrorAction SilentlyContinue
    # Kritik olmayan bildirimleri gizle
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' 'DisableEnhancedNotifications' 1
    Write-Ok 'Defender hafif optimize edildi (korumalar açık)'
}

function Set-BlackLockScreen {
    if (-not (Test-Path $MachineDataDir)) { New-Item -ItemType Directory -Path $MachineDataDir | Out-Null }
    Add-Type -AssemblyName System.Drawing
    $black = Join-Path $MachineDataDir 'black.jpg'
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Black)
    $g.Dispose()
    $bmp.Save($black, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()

    $csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    Set-Reg $csp 'LockScreenImagePath' $black 'String'
    Set-Reg $csp 'LockScreenImageUrl' $black 'String'
    Set-Reg $csp 'LockScreenImageStatus' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'DisableAcrylicBackgroundOnLogon' 1

    # Varsayılan hesap resimleri siyah (orijinaller yedeklenir)
    $pictures = "$env:ProgramData\Microsoft\User Account Pictures"
    $backup = Join-Path $MachineDataDir 'User Account Pictures'
    if (-not (Test-Path $backup)) { Copy-Item $pictures $backup -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($img in Get-ChildItem $pictures -Include *.png, *.bmp -Recurse -ErrorAction SilentlyContinue) {
        try {
            $src = [System.Drawing.Image]::FromFile($img.FullName)
            $w = $src.Width; $h = $src.Height
            $src.Dispose()
            $out = New-Object System.Drawing.Bitmap $w, $h
            $g = [System.Drawing.Graphics]::FromImage($out)
            $g.Clear([System.Drawing.Color]::Black)
            $g.Dispose()
            $out.Save($img.FullName)
            $out.Dispose()
        } catch { }
    }
    Write-Ok 'Kilit ekranı ve hesap resimleri siyah'
}

#endregion

#region Kişisel ortam

function Install-NerdFont {
    $zip = Join-Path $env:TEMP 'FiraCode.zip'
    $extract = Join-Path $env:TEMP 'FiraCodeNerd'
    try {
        Invoke-WebRequest 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraCode.zip' -OutFile $zip -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Warn 'FiraCode Nerd Font indirilemedi'
        return
    }
    Expand-Archive $zip -DestinationPath $extract -Force
    $fontsDir = "$env:SystemRoot\Fonts"
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    foreach ($font in Get-ChildItem $extract -Filter *.ttf) {
        Copy-Item $font.FullName (Join-Path $fontsDir $font.Name) -Force -ErrorAction SilentlyContinue
        Set-Reg $regPath "$($font.BaseName) (TrueType)" $font.Name 'String'
    }
    Remove-Item $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'FiraCode Nerd Font kuruldu'
}

function Test-NerdFontInstalled {
    (Test-Path "$env:SystemRoot\Fonts\FiraCodeNerdFontMono-Regular.ttf") -or
        (Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\FiraCodeNerdFontMono-Regular.ttf")
}

# winget "zaten kurulu" demek için bile paket başına birkaç saniye harcıyor;
# komutu PATH'te bulunan araç için winget hiç çağrılmaz.
$NeovimTools = [ordered]@{ 'Neovim.Neovim' = 'nvim'; 'Git.Git' = 'git'; 'BurntSushi.ripgrep.MSVC' = 'rg' }
$TerminalTools = [ordered]@{
    'Microsoft.PowerShell' = 'pwsh'; 'Microsoft.WindowsTerminal' = 'wt'; 'Git.Git' = 'git'; 'GitHub.cli' = 'gh'
    'Neovim.Neovim' = 'nvim'; 'ajeetdsouza.zoxide' = 'zoxide'; 'Starship.Starship' = 'starship'; 'junegunn.fzf' = 'fzf'
    'eza-community.eza' = 'eza'; 'sharkdp.bat' = 'bat'; 'BurntSushi.ripgrep.MSVC' = 'rg'; 'sharkdp.fd' = 'fd'
    'Fastfetch-cli.Fastfetch' = 'fastfetch'
}

function Get-MissingTools($Tools) {
    @($Tools.Keys | Where-Object { -not (Get-Command $Tools[$_] -CommandType Application -ErrorAction SilentlyContinue) })
}

function Get-ToolStepDetails($Tools) {
    $missing = Get-MissingTools $Tools
    $installed = @($Tools.Keys | Where-Object { $_ -notin $missing } | ForEach-Object { $Tools[$_] })
    if ($missing.Count) { "Kurulacak: " + (($missing | ForEach-Object { $Tools[$_] }) -join ', ') }
    if ($installed.Count) { "Zaten kurulu, sadece config: " + ($installed -join ', ') }
    if (-not (Test-NerdFontInstalled)) { 'Kurulacak: FiraCode Nerd Font' }
    if ('Git.Git' -in $missing) { 'Git sağ tık menüsü (Open Git Bash/GUI here) olmadan kurulur' }
}

function Install-Tools($Tools) {
    $missing = Get-MissingTools $Tools
    if ($missing.Count) { Install-Apps $missing } else { Write-Info 'Araçların hepsi zaten kurulu' }
    if (Test-NerdFontInstalled) { Write-Info 'FiraCode Nerd Font zaten kurulu' } else { Install-NerdFont }
}

function Get-NeovimVersion {
    $nvim = Get-Command nvim -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nvim) { return $null }
    if ((& $nvim.Source --version | Select-Object -First 1) -match 'v(\d+\.\d+\.\d+)') { [version]$Matches[1] }
}

# Config vim.pack kullanıyor, Neovim 0.12+ ister.
function Install-NeovimConfig {
    $version = Get-NeovimVersion
    if ($version -and $version -lt [version]'0.12.0') {
        Write-Info "Neovim $version eski, güncelleniyor..."
        if (Initialize-Winget) { Install-WingetPackage 'Neovim.Neovim'; Update-SessionPath }
        $version = Get-NeovimVersion
        if ($version -lt [version]'0.12.0') { Write-Warn "Neovim hâlâ $version (0.12+ gerekli), plugin'ler çalışmayabilir" }
    }
    Save-File "$DotfilesRaw/nvim/.config/nvim/init.lua" "$env:LOCALAPPDATA\nvim\init.lua"
    Save-File "$DotfilesRaw/nvim/.config/nvim/nvim-pack-lock.json" "$env:LOCALAPPDATA\nvim\nvim-pack-lock.json"
    Install-NeovimPlugins
}

# Config plugin'leri ilk açılışta indiriyor; burada headless açıp önceden indiriyoruz.
function Install-NeovimPlugins {
    $nvim = Get-Command nvim -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nvim -or -not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warn 'nvim veya git bulunamadı, plugin''ler ilk açılışta inecek'
        return
    }
    # Önceki başarısız denemenin bıraktığı işaret varsa config plugin kurmayı denemez
    Remove-Item "$env:LOCALAPPDATA\nvim-data\nopack" -Force -ErrorAction SilentlyContinue
    Write-Info 'Neovim plugin''leri indiriliyor...'
    $proc = Start-Process $nvim.Source -ArgumentList '--headless', '+qa' -NoNewWindow -PassThru
    $done = $proc.WaitForExit(180000)
    Write-Host '' # vim.pack ilerleme satırı satır sonu olmadan biter
    if (-not $done) {
        $proc.Kill()
        Write-Warn 'Plugin indirme zaman aşımına uğradı, ilk açılışta tekrar denenecek'
    } elseif (Test-Path "$env:LOCALAPPDATA\nvim-data\nopack") {
        Remove-Item "$env:LOCALAPPDATA\nvim-data\nopack" -Force -ErrorAction SilentlyContinue
        Write-Warn 'Plugin''ler indirilemedi, ilk açılışta tekrar denenecek'
    } else {
        Write-Ok 'Neovim plugin''leri indirildi'
    }
}

function Install-Neovim {
    Install-Tools $NeovimTools
    Install-NeovimConfig
    Write-Ok 'Neovim hazır'
}

function Install-PersonalEnvironment {
    Install-Tools $TerminalTools

    # Windows Terminal
    $wt = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    Save-File "$RepoRaw/config/WindowsTerminal/settings.json" $wt
    if ($State.Logo) {
        Save-File "$RepoRaw/assets/BJK(Terminal).png" (Join-Path $DataDir 'BJK(Terminal).png')
    } elseif (Test-Path $wt) {
        $lines = [IO.File]::ReadAllLines($wt) | Where-Object { $_ -notmatch '"backgroundImage' }
        [IO.File]::WriteAllLines($wt, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
        Write-Info 'Terminal arka planı logosuz'
    }

    # PowerShell 7 profili
    $docs = [Environment]::GetFolderPath('MyDocuments')
    Save-File "$RepoRaw/config/PowerShell/profile.ps1" "$docs\PowerShell\Microsoft.PowerShell_profile.ps1"
    if (Test-Path "$docs\PowerShell\Modules\PSFzf") {
        Write-Info 'PSFzf zaten kurulu'
    } else {
        # Store sürümü WindowsApps'te, winget/MSI sürümü Program Files'ta olur
        $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
        if (-not $pwsh -and (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe")) { $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
        if ($pwsh) {
            & $pwsh -NoProfile -Command 'Install-Module PSFzf -Scope CurrentUser -Force -Repository PSGallery' 2>&1 | Out-Null
        } else {
            Write-Warn 'PowerShell 7 bulunamadı, PSFzf kurulamadı'
        }
    }

    # dotfiles reposundan ortak configler
    Save-File "$DotfilesRaw/starship/.config/starship.toml" "$env:USERPROFILE\.config\starship.toml"
    Save-File "$DotfilesRaw/fastfetch/.config/fastfetch/config.jsonc" "$env:USERPROFILE\.config\fastfetch\config.jsonc"
    Save-File "$DotfilesRaw/bat/.config/bat/config" "$env:APPDATA\bat\config"
    Install-NeovimConfig
    Write-Ok 'Kişisel terminal ortamı kuruldu'
}

#endregion

#region RSAT

# Active Directory paketi Users and Computers ve Sites and Services'i (ayrıca Domains and Trusts, ADSI Edit
# ve ActiveDirectory modülünü) içerir.
$RsatCapabilities = [ordered]@{
    'Rsat.ActiveDirectory.DS-LDS.Tools' = 'AD Users and Computers, AD Sites and Services'
    'Rsat.Dns.Tools'                    = 'DNS'
    'Rsat.DHCP.Tools'                   = 'DHCP'
}

function Get-RsatCapabilities {
    foreach ($name in $RsatCapabilities.Keys) {
        Get-WindowsCapability -Online -Name "$name~*" -ErrorAction Stop | Select-Object -First 1
    }
}

function Get-RsatLabel([string]$CapabilityName) { $RsatCapabilities[$CapabilityName -replace '~.*$', ''] }

function Get-RsatStepDetails {
    try {
        $caps = @(Get-RsatCapabilities)
    } catch {
        return 'Kurulum durumu kontrol edilemedi (yönetici gerekir)'
    }
    $missing = @($caps | Where-Object State -ne 'Installed' | ForEach-Object { Get-RsatLabel $_.Name })
    $installed = @($caps | Where-Object State -eq 'Installed' | ForEach-Object { Get-RsatLabel $_.Name })
    if ($missing.Count) { 'Kurulacak: ' + ($missing -join ', ') }
    if ($installed.Count) { 'Zaten kurulu: ' + ($installed -join ', ') }
    if (-not $caps.Count) { 'Bu Windows sürümünde RSAT yok (Pro/Enterprise/Education gerekir)' }
}

function Install-Rsat {
    $caps = @(Get-RsatCapabilities)
    if (-not $caps.Count) {
        Write-Warn 'Bu Windows sürümünde RSAT yok (Pro/Enterprise/Education gerekir)'
        return
    }
    $missing = @($caps | Where-Object State -ne 'Installed')
    if (-not $missing.Count) {
        Write-Info 'RSAT araçları zaten kurulu'
        return
    }

    foreach ($cap in $missing) {
        $label = Get-RsatLabel $cap.Name
        Write-Info "Kuruluyor: $label (birkaç dakika sürebilir)"
        try {
            Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            Write-Ok "Kuruldu: $label"
        } catch {
            Write-Warn "Kurulamadı: $label ($($_.Exception.Message))"
        }
    }
}

#endregion

#region Profiller

# Details onaydan önce adımın altında gösterilir; Data adımın Action'ına parametre olarak verilir.
function New-Step([string]$Name, [scriptblock]$Action, [string[]]$Details = @(), $Data = $null) {
    [pscustomobject]@{ Name = $Name; Action = $Action; Details = $Details; Data = $Data }
}

function New-DebloatStep([string]$Name, [string]$DebloatLevel, [string[]]$Extra = @()) {
    $targets = Get-BloatTargets $DebloatLevel $Extra
    $list = if ($targets.Names.Count) { "Kaldırılacak ($($targets.Names.Count)): " + ($targets.Names -join ', ') } else { 'Kaldırılacak uygulama yok, sistem zaten temiz' }
    New-Step $Name { param($step) Remove-Bloatware $step.Data.Targets; Protect-Debloat $step.Data.Level } @(
        $list, 'Ayrıca kaldırılanların Windows güncellemeleriyle ve yeni hesaplarda geri gelmesi engellenir'
    ) @{ Targets = $targets; Level = $DebloatLevel }
}

function Get-EdgeStepDetails {
    if (Test-Path -LiteralPath $EdgeKey) { 'Kaldırılacak: Microsoft Edge' } else { 'Edge zaten kurulu değil, sadece tekrar kurulması engellenir' }
}

function Get-OneDriveStepDetails {
    if (Test-OneDriveInstalled) { 'Kaldırılacak: OneDrive' } else { 'OneDrive zaten kurulu değil, sadece yeni hesaplarda kurulması engellenir' }
}

$OptionalComponentsDetails = 'Yüklüyse kaldırılır: Steps Recorder, Math Recognizer, WordPad, Internet Explorer modu, Hello yüz tanıma, PowerShell ISE, eski Media Player, XPS Viewer, ek duvar kağıtları, Recall, Work Folders, XPS yazdırma, PowerShell 2.0'

function Write-Wrapped([string]$Text, [string]$Indent = '        ') {
    $console = try { [Console]::WindowWidth } catch { 120 }
    $width = [Math]::Max(60, $console - $Indent.Length - 2)
    $line = ''
    foreach ($word in $Text -split ' ') {
        if ($line -and ($line.Length + $word.Length + 1) -gt $width) {
            Write-Host "$Indent$line" -ForegroundColor DarkGray
            $line = $word
        } else {
            $line = if ($line) { "$line $word" } else { $word }
        }
    }
    if ($line) { Write-Host "$Indent$line" -ForegroundColor DarkGray }
}

function Get-Plan([string]$Selected, [string]$DebloatLevel) {
    switch ($Selected) {
        'Gaming' {
            New-DebloatStep 'Debloat (Full): hesap makinesi, notepad, terminal, ekran alıntısı, Store, fotoğraflar, paint ve codec''ler hariç her şey' 'Full'
            New-Step 'Edge kaldır (WebView2 kalır)' { Remove-Edge } @(Get-EdgeStepDetails)
            New-Step 'OneDrive kaldır' { Remove-OneDrive } @(Get-OneDriveStepDetails)
            New-Step 'Kişisel ayarlar (koyu tema, uzantılar, Gezgin Bu Bilgisayar''da açılır, Num Lock, yapışkan tuşlar, telemetri ve ipuçları, prizde uyku kapalı)' { Set-PersonalTweaks }
            New-Step 'Tüm bildirimler kapalı' { Disable-Notifications }
            New-Step 'Klavye sadece Türkçe Q' { Set-TurkishKeyboard }
            New-Step 'Bölge biçimleri Türkiye' { Set-TurkishRegion }
            New-Step 'Arka plan uygulamaları kapalı' { Disable-BackgroundApps }
            New-Step 'Arayüz temizliği (klasik sağ tık, Widgets/Copilot kapalı, taskbar boş)' { Set-InterfaceCleanup }
            New-Step 'Hızlı başlatma / hazırda bekletme kapalı' { Disable-FastBoot }
            New-Step 'Cihaz ve ağ adaptörü güç tasarrufu kapalı' { Disable-DevicePowerSaving }
            New-Step 'Timer resolution servisi' { Install-TimerResolution }
            New-Step 'Game Bar kapalı' { Disable-GameBar }
            New-Step 'Uygulamalar: Steam, Firefox, mpv' { Install-Apps @('Valve.Steam', 'Mozilla.Firefox', 'shinchiro.mpv') }
            New-Step 'Defender hafif optimizasyon' { Optimize-Defender }
            New-Step 'Kilit ekranı ve hesap resimleri siyah' { Set-BlackLockScreen }
            New-Step 'Duvar kağıdı' { Set-Wallpaper }
            New-Step 'Kişisel terminal ortamı (PS7, Terminal, FiraCode, zoxide, starship, fzf, eza, bat, rg, fd, fastfetch, git, gh, nvim, dotfiles)' { Install-PersonalEnvironment } @(Get-ToolStepDetails $TerminalTools)
            New-Step 'Başlat menüsü: program klasörleri düzleştirilir (Windows klasörleri kalır), liste görünümü' { Set-FlatStartMenu }
            New-Step 'Başlat menüsü: Önerilenler bölümü kapalı (sabitlenenlere dokunulmaz)' { Disable-StartRecommended }
            New-Step 'Gereksiz Windows bileşenleri (WordPad, IE, Steps Recorder, Recall, PowerShell 2.0...) — uzun sürebilir' { Remove-OptionalComponents } @($OptionalComponentsDetails)
        }
        'Work' {
            New-DebloatStep 'Debloat (Standart + Widgets, Telefon Bağlantısı): Edge, Teams, Outlook, Uzak Masaüstü, Hızlı Yardım kalır' 'Standard' @('MicrosoftWindows.Client.WebExperience', 'Microsoft.YourPhone')
            New-Step 'OneDrive kaldır' { Remove-OneDrive } @(Get-OneDriveStepDetails)
            New-Step 'Kişisel ayarlar (koyu tema, uzantılar, Gezgin Bu Bilgisayar''da açılır, Num Lock, yapışkan tuşlar, telemetri ve ipuçları, prizde uyku kapalı)' { Set-PersonalTweaks }
            New-Step 'Tüm bildirimler kapalı' { Disable-Notifications }
            New-Step 'Klavye sadece Türkçe Q' { Set-TurkishKeyboard }
            New-Step 'Bölge biçimleri Türkiye' { Set-TurkishRegion }
            New-Step 'Arayüz temizliği (klasik sağ tık, Widgets/Copilot kapalı, taskbar boş)' { Set-InterfaceCleanup }
            New-Step 'Hızlı başlatma / hazırda bekletme kapalı' { Disable-FastBoot }
            New-Step 'Uygulamalar: 7-Zip, Firefox' { Install-Apps @('7zip.7zip', 'Mozilla.Firefox') }
            New-Step 'Duvar kağıdı' { Set-Wallpaper }
            New-Step 'Kişisel terminal ortamı (PS7, Terminal, FiraCode, zoxide, starship, fzf, eza, bat, rg, fd, fastfetch, git, gh, nvim, dotfiles)' { Install-PersonalEnvironment } @(Get-ToolStepDetails $TerminalTools)
            New-Step 'Başlat menüsü: program klasörleri düzleştirilir (Windows klasörleri kalır), liste görünümü' { Set-FlatStartMenu }
            New-Step 'Başlat menüsü: Önerilenler bölümü kapalı (sabitlenenlere dokunulmaz)' { Disable-StartRecommended }
        }
        'VM' {
            New-DebloatStep 'Debloat (Full): Edge dahil kalanlar korunur' 'Full'
            New-Step 'OneDrive kaldır' { Remove-OneDrive } @(Get-OneDriveStepDetails)
            New-Step 'Kişisel ayarlar (koyu tema, uzantılar, Gezgin Bu Bilgisayar''da açılır, Num Lock, yapışkan tuşlar, telemetri ve ipuçları, prizde uyku kapalı)' { Set-PersonalTweaks }
            New-Step 'Tüm bildirimler kapalı' { Disable-Notifications }
            New-Step 'Klavye sadece Türkçe Q' { Set-TurkishKeyboard }
            New-Step 'Bölge biçimleri Türkiye' { Set-TurkishRegion }
            New-Step 'Arka plan uygulamaları kapalı' { Disable-BackgroundApps }
            New-Step 'Arayüz temizliği (klasik sağ tık, Widgets/Copilot kapalı, taskbar boş)' { Set-InterfaceCleanup }
            New-Step 'Duvar kağıdı' { Set-Wallpaper }
            New-Step 'Kişisel terminal ortamı (PS7, Terminal, FiraCode, zoxide, starship, fzf, eza, bat, rg, fd, fastfetch, git, gh, nvim, dotfiles)' { Install-PersonalEnvironment } @(Get-ToolStepDetails $TerminalTools)
            New-Step 'Başlat menüsü: program klasörleri düzleştirilir (Windows klasörleri kalır), liste görünümü' { Set-FlatStartMenu }
            New-Step 'Başlat menüsü: Önerilenler bölümü kapalı (sabitlenenlere dokunulmaz)' { Disable-StartRecommended }
            New-Step 'Gereksiz Windows bileşenleri (WordPad, IE, Steps Recorder, Recall, PowerShell 2.0...) — uzun sürebilir' { Remove-OptionalComponents } @($OptionalComponentsDetails)
        }
        'Standard' {
            New-DebloatStep 'Debloat (Standart): sadece çöp uygulamalar, Xbox/Edge/Store ve günlük uygulamalar kalır' 'Standard'
            New-Step 'Reklam, öneri, ipucu ve telemetri kapalı' { Set-PrivacyTweaks }
            New-Step 'Bölge biçimleri Türkiye' { Set-TurkishRegion }
            New-Step 'Görev çubuğu sadeleştirme (arama simge olarak kalır)' { Set-TaskbarTweaks 1 }
            New-Step 'Dosya uzantılarını göster' { Set-FileExtensionsVisible }
            New-Step 'Uygulama: 7-Zip' { Install-Apps @('7zip.7zip') }
        }
        'Debloat' {
            if ($DebloatLevel -eq 'Full') {
                New-DebloatStep 'Debloat (Full): hesap makinesi, notepad, terminal, ekran alıntısı, Store, Edge, fotoğraflar, paint ve codec''ler hariç her şey' 'Full'
                New-Step 'OneDrive kaldır' { Remove-OneDrive } @(Get-OneDriveStepDetails)
                New-Step 'Gereksiz Windows bileşenleri (WordPad, IE, Steps Recorder, Recall, PowerShell 2.0...) — uzun sürebilir' { Remove-OptionalComponents } @($OptionalComponentsDetails)
            } else {
                New-DebloatStep 'Debloat (Standart): sadece çöp uygulamalar, tüm kullanıcılardan ve yeni kullanıcılardan' 'Standard'
            }
        }
        'Neovim' {
            New-Step 'Neovim (git, rg, FiraCode, dotfiles config; kurulu olanlar atlanır)' { Install-Neovim } @(Get-ToolStepDetails $NeovimTools)
        }
        'Terminal' {
            New-Step 'Kişisel terminal ortamı (PS7, Terminal, FiraCode, zoxide, starship, fzf, eza, bat, rg, fd, fastfetch, git, gh, nvim, dotfiles)' { Install-PersonalEnvironment } @(Get-ToolStepDetails $TerminalTools)
        }
        'RSAT' {
            New-Step 'RSAT: AD Users and Computers, AD Sites and Services, DNS, DHCP' { Install-Rsat } @(Get-RsatStepDetails)
        }
    }
}

# Bu profiller sistem ayarına dokunmaz: geri yükleme noktası ve Explorer yeniden başlatma gerekmez.
$LightProfiles = @('Neovim', 'Terminal', 'RSAT')
# Bunlar PowerShell 7'de çalışır; diğerleri Appx/DISM cmdlet'leri için Windows PowerShell 5.1 ister.
$Pwsh7Profiles = @('Neovim', 'Terminal')
$TerminalProfiles = @('Gaming', 'Work', 'VM', 'Terminal')

$ProfileNames = [ordered]@{
    Gaming   = 'Oyun'
    Work     = 'İş'
    VM       = 'Sanal makine'
    Standard = 'Standart (genel kullanıcı)'
    Debloat  = 'Sadece debloat'
    Neovim   = 'Neovim'
    Terminal = 'Terminal ortamı'
    RSAT     = 'RSAT yönetim araçları'
}

#endregion

#region Menü

# Note rengi: Warn = sistemi değiştirir, Ok = sisteme dokunmaz, Info = bilgi
function New-MenuItem([string]$Key, [string]$Hotkey, [string]$Label, [string]$Hint, [string[]]$Lines, [string]$Note = '', [string]$NoteKind = 'Info') {
    [pscustomobject]@{ Key = $Key; Hotkey = $Hotkey; Label = $Label; Hint = $Hint; Lines = $Lines; Note = $Note; NoteKind = $NoteKind }
}

$SystemNote = 'Sistem ayarlarını değiştirir · yeniden başlatma önerilir'
$LightNote = 'Sistem ayarlarına dokunmaz · kurulu araçlar atlanır'
$DevEnvironment = 'Geliştirici ortamı: PowerShell 7, Windows Terminal, CLI araçları ve dotfiles'

$ProfileMenu = @(
    New-MenuItem 'Gaming' '1' 'Oyun' 'Full debloat + Edge kaldır + oyun ayarları + Steam + kişisel ortam' @(
        'Full debloat: temel araçlar dışındaki Microsoft uygulamaları kaldırılır'
        'Edge ve OneDrive kaldırılır'
        'Oyun ayarları: timer resolution, cihaz güç tasarrufu ve Game Bar kapalı'
        'Steam, Firefox, mpv'
        $DevEnvironment
    ) $SystemNote 'Warn'
    New-MenuItem 'Work' '2' 'İş' 'Standart debloat (Edge/Teams/Outlook kalır) + OneDrive kaldır + kişisel ortam' @(
        'Standart debloat: Edge, Teams ve Outlook kalır'
        'OneDrive ve Telefon Bağlantısı kaldırılır'
        '7-Zip, Firefox'
        $DevEnvironment
    ) $SystemNote 'Warn'
    New-MenuItem 'VM' '3' 'Sanal makine' 'Full debloat + kişisel ortam (Steam/oyun ayarı yok)' @(
        'Full debloat: temel araçlar dışındaki Microsoft uygulamaları kaldırılır'
        'OneDrive ve gereksiz Windows bileşenleri kaldırılır'
        $DevEnvironment
    ) $SystemNote 'Warn'
    New-MenuItem 'Standard' '4' 'Standart' 'Genel kullanıcı: sadece çöpler, reklamlar ve telemetri' @(
        'Gereksiz uygulamalar kaldırılır; Xbox, Edge ve Store kalır'
        'Reklam, öneri ve telemetri kapatılır'
        '7-Zip'
    ) 'Genel kullanıcı için güvenli' 'Ok'
    New-MenuItem 'Debloat' '5' 'Debloat' 'Sadece uygulama kaldırma' @(
        'Yalnızca uygulama kaldırma'
        'Standart veya Full seviye sonraki adımda seçilir'
    ) 'Diğer ayarlara dokunmaz' 'Info'
    New-MenuItem 'Neovim' '6' 'Neovim' 'Neovim + config (kuruluysa sadece config)' @(
        'Neovim, git, ripgrep, FiraCode Nerd Font'
        'dotfiles yapılandırması, plugin''ler önceden indirilir'
    ) $LightNote 'Ok'
    New-MenuItem 'Terminal' '7' 'Terminal' 'Tüm terminal ve CLI ortamı + configler (kurulu olanlar atlanır)' @(
        'PowerShell 7, Windows Terminal, FiraCode Nerd Font'
        'git, gh, neovim, starship, zoxide, fzf, eza, bat, ripgrep, fd, fastfetch'
        'dotfiles yapılandırmaları'
    ) $LightNote 'Ok'
    New-MenuItem 'RSAT' '8' 'RSAT' 'AD Users and Computers, AD Sites and Services, DNS, DHCP' @(
        'Active Directory Users and Computers'
        'Active Directory Sites and Services'
        'DNS ve DHCP yönetim araçları'
    ) 'Windows Update''ten indirilir · birkaç dakika sürebilir' 'Info'
    New-MenuItem $null '0' 'Çıkış' '' @('Hiçbir değişiklik yapmadan çık')
)

$LevelMenu = @(
    New-MenuItem 'Standard' '1' 'Standart' 'Sadece çöp uygulamalar (genel kullanıcı için güvenli)' @(
        'Bing uygulamaları, Copilot, Clipchamp, LinkedIn, oyunlar gibi gereksiz uygulamalar'
        'Hesap makinesi, saat, kamera, fotoğraflar, Xbox, Edge ve Store kalır'
    ) 'Genel kullanıcı için güvenli' 'Ok'
    New-MenuItem 'Full' '2' 'Full' 'Microsoft uygulamalarının neredeyse hepsi (VM / minimal kurulum)' @(
        'Microsoft uygulamalarının neredeyse hepsi kaldırılır'
        'Hesap Makinesi, Not Defteri, Terminal, Ekran Alıntısı, Store, Fotoğraflar, Paint ve codec''ler kalır'
        'OneDrive ve gereksiz Windows bileşenleri de kaldırılır'
    ) 'VM ve minimal kurulumlar için' 'Warn'
    New-MenuItem $null '0' 'Çıkış' '' @('Hiçbir değişiklik yapmadan çık')
)

$Esc = [char]27

# Çizim karakterleri kod noktasından üretilir: Windows PowerShell 5.1 BOM'suz dosyayı ANSI okur ve
# bu karakterlerin UTF-8 baytları ANSI'de tırnak işaretine dönüşüp script'i ayrıştırılamaz yapar.
$Glyph = @{
    H = [char]0x2500; V = [char]0x2502; TL = [char]0x256D; TR = [char]0x256E; BL = [char]0x2570; BR = [char]0x256F
    Block = [char]0x2588; Pointer = [char]0x25B8; Bullet = [char]0x2022; Dot = [char]0x00B7
    Up = [char]0x2191; Down = [char]0x2193; Dash = [char]0x2014
}

function Get-Fg([int[]]$Rgb) { "$Esc[38;2;$($Rgb[0]);$($Rgb[1]);$($Rgb[2])m" }

# Catppuccin Mocha
$Ui = @{
    Text   = Get-Fg 205, 214, 244
    Sub    = Get-Fg 166, 173, 200
    Dim    = Get-Fg 108, 112, 134
    Border = Get-Fg 69, 71, 90
    Accent = Get-Fg 203, 166, 247
    Ok     = Get-Fg 166, 227, 161
    Warn   = Get-Fg 250, 179, 135
    Info   = Get-Fg 137, 220, 235
    SelBg  = "$Esc[48;2;49;50;68m"
    Bold   = "$Esc[1m"
    Reset  = "$Esc[0m"
}

# Banner'daki akan renk geçişi: mauve → blue → sky → pink, 96 adımlık döngü
$GradientSteps = 96
$Gradient = & {
    $stops = @(@(203, 166, 247), @(137, 180, 250), @(137, 220, 235), @(245, 194, 231))
    for ($i = 0; $i -lt $GradientSteps; $i++) {
        $p = $i / $GradientSteps * $stops.Count
        $a = $stops[[Math]::Floor($p)]; $b = $stops[([Math]::Floor($p) + 1) % $stops.Count]; $f = $p - [Math]::Floor($p)
        Get-Fg @(foreach ($k in 0..2) { [int]($a[$k] + ($b[$k] - $a[$k]) * $f) })
    }
}

# ANSI Shadow "GÖKHAN"; Ö'nün noktaları yerine >_ simgesi çizilir.
# Şablon: # = █, = = ═, | = ║, r = ╔, 7 = ╗, L = ╚, J = ╝
$BannerRows = & {
    $letters = @(
        @(' ######7 ', '##r====J ', '##|  ###7', '##|   ##|', 'L######rJ', ' L=====J '),
        @(' ######7 ', '##r===##7', '##|   ##|', '##|   ##|', 'L######rJ', ' L=====J '),
        @('##7  ##7', '##| ##rJ', '#####rJ ', '##r=##7 ', '##|  ##7', 'L=J  L=J'),
        @('##7  ##7', '##|  ##|', '#######|', '##r==##|', '##|  ##|', 'L=J  L=J'),
        @(' #####7 ', '##r==##7', '#######|', '##r==##|', '##|  ##|', 'L=J  L=J'),
        @('###7   ##7', '####7  ##|', '##r##7 ##|', '##|L##7##|', '##| L####|', 'L=J  L===J')
    )
    $map = @{ '#' = 0x2588; '=' = 0x2550; '|' = 0x2551; 'r' = 0x2554; '7' = 0x2557; 'L' = 0x255A; 'J' = 0x255D }
    foreach ($r in 0..5) {
        $row = -join ($letters | ForEach-Object { $_[$r] })
        -join ($row.ToCharArray() | ForEach-Object { if ($map.ContainsKey([string]$_)) { [char]$map[[string]$_] } else { $_ } })
    }
}
$BannerWidth = $BannerRows[0].Length
# Ö'nün üstündeki >_ simgesi, yarım bloklarla: T = ▀, B = ▄, # = █
$BannerIconColumn = 9
$BannerIconRows = foreach ($row in 'T#B', ' B#T', 'TT TTTT') {
    -join ($row.ToCharArray() | ForEach-Object { switch ($_) { 'T' { [char]0x2580 } 'B' { [char]0x2584 } '#' { [char]0x2588 } default { ' ' } } })
}
$BannerIconHeight = $BannerIconRows.Count

function Get-SystemSummary {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $name = "$($cv.ProductName)"
    # ProductName Windows 11'de de "Windows 10" der
    if ([int]$cv.CurrentBuildNumber -ge 22000) { $name = $name -replace 'Windows 10', 'Windows 11' }
    $os = (@($name, $cv.DisplayVersion) | Where-Object { $_ }) -join ' '
    "$os  ·  $env:USERNAME@$env:COMPUTERNAME"
}

function Split-Text([string]$Text, [int]$Width) {
    $line = ''
    foreach ($word in $Text -split ' ') {
        if ($line -and ($line.Length + $word.Length + 1) -gt $Width) { $line; $line = $word }
        else { $line = if ($line) { "$line $word" } else { $word } }
    }
    if ($line) { $line }
}

# Ayrıntı panelinin satırları: (renk, metin) çiftleri
function Get-DetailRows($Item, [int]$Width) {
    foreach ($text in $Item.Lines) {
        $first = $true
        foreach ($part in Split-Text $text ($Width - 2)) {
            $bullet = if ($first) { "$($Glyph.Bullet) " } else { '  ' }
            , @($Ui.Text, "$bullet$part")
            $first = $false
        }
    }
    if ($Item.Note) {
        , @($Ui.Text, '')
        foreach ($part in Split-Text $Item.Note $Width) { , @($Ui[$Item.NoteKind], $part) }
    }
}

# VT dizileri: Windows Terminal ve PowerShell 7'de zaten açık, 5.1 conhost'ta açılır
function Enable-VirtualTerminal {
    if ($env:WT_SESSION -or $PSVersionTable.PSVersion.Major -ge 7) { return $true }
    try {
        if (-not ('Winsetup.ConsoleMode' -as [type])) {
            Add-Type -Namespace Winsetup -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $handle = [Winsetup.ConsoleMode]::GetStdHandle(-11)
        [uint32]$mode = 0
        if (-not [Winsetup.ConsoleMode]::GetConsoleMode($handle, [ref]$mode)) { return $false }
        # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        [Winsetup.ConsoleMode]::SetConsoleMode($handle, $mode -bor 4)
    } catch {
        $false
    }
}

function Test-FancyConsole {
    try {
        $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and
            [Console]::WindowWidth -ge 60 -and (Enable-VirtualTerminal)
    } catch {
        $false
    }
}

function Get-MenuLayout($Items) {
    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight
    $leftW = 28
    $rightW = [Math]::Min(60, $w - $leftW - 6)
    if ($rightW -lt 34) { $rightW = 0 }
    $inner = $Items.Count
    if ($rightW) {
        foreach ($item in $Items) { $inner = [Math]::Max($inner, @(Get-DetailRows $item ($rightW - 4)).Count) }
    }
    $panelH = $inner + 2
    # simge + banner, boşluk, bilgi, boşluk, paneller, boşluk, kısayollar
    $bannerH = $BannerIconHeight + $BannerRows.Count
    $contentH = $bannerH + 1 + 1 + 1 + $panelH + 1 + 1
    if ($w -lt $BannerWidth + 4 -or $h -lt $contentH + 1) { return $null }
    $totalW = if ($rightW) { $leftW + 2 + $rightW } else { $leftW }
    $top = [Math]::Max(1, [int][Math]::Floor(($h - $contentH) / 2) + 1)
    $panelTop = $top + $bannerH + 3
    [pscustomobject]@{
        Width = $w; BannerTop = $top; BannerLeft = [int][Math]::Floor(($w - $BannerWidth) / 2) + 1
        InfoRow = $top + $bannerH + 1; PanelTop = $panelTop; PanelLeft = [int][Math]::Floor(($w - $totalW) / 2) + 1
        LeftW = $leftW; RightW = $rightW; Inner = $inner; FooterRow = $panelTop + $panelH + 1
    }
}

function Get-Centered([string]$Plain, [string]$Colored, [int]$Row, [int]$Width) {
    "$Esc[$Row;$([Math]::Max(1, [int][Math]::Floor(($Width - $Plain.Length) / 2) + 1))H$Colored"
}

# Başlıklı kutu üst kenarı: ╭─ Başlık ───╮
function Get-BoxTop([int]$X, [int]$Y, [int]$Width, [string]$Title, [string]$TitleColor) {
    $line = [string]$Glyph.H * ($Width - 5 - $Title.Length)
    "$Esc[$Y;$($X)H$($Ui.Border)$($Glyph.TL)$($Glyph.H) $($Ui.Bold)$TitleColor$Title$($Ui.Reset)$($Ui.Border) $line$($Glyph.TR)"
}

function Write-Banner($Layout, [double]$Phase, [int]$Reveal) {
    $sb = New-Object Text.StringBuilder
    $colors = for ($c = 0; $c -lt $BannerWidth; $c++) {
        $Gradient[(([int]($c * 1.4 - $Phase) % $GradientSteps) + $GradientSteps) % $GradientSteps]
    }
    for ($r = 0; $r -lt $BannerIconHeight; $r++) {
        $row = $BannerIconRows[$r]
        [void]$sb.Append("$Esc[$($Layout.BannerTop + $r);$($Layout.BannerLeft + $BannerIconColumn)H")
        for ($c = 0; $c -lt $row.Length; $c++) {
            $col = $BannerIconColumn + $c
            if ($row[$c] -eq ' ' -or $col -ge $Reveal) { [void]$sb.Append(' ') } else { [void]$sb.Append($colors[$col]).Append($row[$c]) }
        }
    }
    for ($r = 0; $r -lt $BannerRows.Count; $r++) {
        [void]$sb.Append("$Esc[$($Layout.BannerTop + $BannerIconHeight + $r);$($Layout.BannerLeft)H")
        $row = $BannerRows[$r]
        for ($c = 0; $c -lt $BannerWidth; $c++) {
            $ch = $row[$c]
            if ($c -ge $Reveal -or $ch -eq ' ') { [void]$sb.Append(' ') }
            elseif ($ch -eq [char]0x2588) { [void]$sb.Append($colors[$c]).Append($ch) }
            else { [void]$sb.Append($Ui.Border).Append($ch) }
        }
    }
    [void]$sb.Append($Ui.Reset)
    [Console]::Write($sb.ToString())
}

function Write-MenuBody($Layout, [string]$Title, $Items, [int]$Index, [string]$Info) {
    $sb = New-Object Text.StringBuilder
    $x = $Layout.PanelLeft; $y = $Layout.PanelTop; $w = $Layout.LeftW

    $sep = "  $($Glyph.Dot)  "
    [void]$sb.Append((Get-Centered "WinSetup$sep$Info" "$($Ui.Bold)$($Ui.Accent)WinSetup$($Ui.Reset)$($Ui.Dim)$sep$($Ui.Sub)$Info" $Layout.InfoRow $Layout.Width))

    $v = "$($Ui.Border)$($Glyph.V)"
    $h = [string]$Glyph.H

    # Sol panel: liste
    [void]$sb.Append((Get-BoxTop $x $y $w $Title $Ui.Accent))
    for ($i = 0; $i -lt $Layout.Inner; $i++) {
        [void]$sb.Append("$Esc[$($y + 1 + $i);$($x)H$v")
        if ($i -lt $Items.Count) {
            $item = $Items[$i]
            $text = " $($item.Hotkey)  $($item.Label)".PadRight($w - 4)
            if ($i -eq $Index) {
                [void]$sb.Append("$($Ui.SelBg)$($Ui.Accent) $($Glyph.Pointer)$($Ui.Bold)$($Ui.Text)$text$($Ui.Reset)")
            } elseif (-not $item.Key) {
                [void]$sb.Append("  $($Ui.Dim)$text")
            } else {
                [void]$sb.Append("  $($Ui.Sub)$text")
            }
        } else {
            [void]$sb.Append(' ' * ($w - 2))
        }
        [void]$sb.Append($v)
    }
    [void]$sb.Append("$Esc[$($y + 1 + $Layout.Inner);$($x)H$($Ui.Border)$($Glyph.BL)$($h * ($w - 2))$($Glyph.BR)")

    # Sağ panel: seçili öğenin ayrıntıları
    if ($Layout.RightW) {
        $rx = $x + $w + 2; $rw = $Layout.RightW
        $item = $Items[$Index]
        [void]$sb.Append((Get-BoxTop $rx $y $rw $item.Label $Ui.Text))
        $rows = @(Get-DetailRows $item ($rw - 4))
        for ($i = 0; $i -lt $Layout.Inner; $i++) {
            $color, $text = if ($i -lt $rows.Count) { $rows[$i] } else { $Ui.Text, '' }
            [void]$sb.Append("$Esc[$($y + 1 + $i);$($rx)H$v $color$($text.PadRight($rw - 4)) $v")
        }
        [void]$sb.Append("$Esc[$($y + 1 + $Layout.Inner);$($rx)H$($Ui.Border)$($Glyph.BL)$($h * ($rw - 2))$($Glyph.BR)")
    }

    $keys = @($Items | Where-Object Key | ForEach-Object Hotkey)
    $range = if ($keys.Count -gt 1) { "$($keys[0])-$($keys[-1])" } else { "$($keys[0])" }
    $hints = @(@("$($Glyph.Up)$($Glyph.Down)", 'gezin'), @('enter', 'seç'), @($range, 'kısayol'), @('esc', 'çık'))
    $plain = ($hints | ForEach-Object { "$($_[0]) $($_[1])" }) -join '   '
    $colored = ($hints | ForEach-Object { "$($Ui.Text)$($_[0])$($Ui.Dim) $($_[1])" }) -join '   '
    [void]$sb.Append((Get-Centered $plain $colored $Layout.FooterRow $Layout.Width))
    [void]$sb.Append($Ui.Reset)
    [Console]::Write($sb.ToString())
}

# Alternatif ekranda animasyonlu menü; seçilen öğenin Key'ini döner (çıkışta $null).
function Read-FancyMenu([string]$Title, $Items) {
    $index = 0
    $info = Get-SystemSummary
    $savedEncoding = [Console]::OutputEncoding
    $savedCtrlC = [Console]::TreatControlCAsInput
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    [Console]::TreatControlCAsInput = $true
    [Console]::Write("$Esc[?1049h$Esc[?25l$Esc[2J")
    try {
        $size = ''; $layout = $null; $dirty = $true
        $phase = 0.0; $reveal = 0
        while ($true) {
            $now = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
            if ($now -ne $size) {
                $size = $now
                $layout = Get-MenuLayout $Items
                [Console]::Write("$Esc[0m$Esc[2J")
                if (-not $layout) {
                    $msg = 'Pencere çok küçük, büyüt ya da esc ile çık'
                    [Console]::Write((Get-Centered $msg "$($Ui.Warn)$msg$($Ui.Reset)" ([int]([Console]::WindowHeight / 2)) ([Console]::WindowWidth)))
                }
                $dirty = $true
            }
            if ($layout) {
                if ($dirty) { Write-MenuBody $layout $Title $Items $index $info; $dirty = $false }
                Write-Banner $layout $phase $reveal
            }
            if ($reveal -le $BannerWidth) { $reveal += 3 }
            $phase = ($phase + 1.6) % $GradientSteps

            $deadline = [DateTime]::Now.AddMilliseconds(40)
            while (-not [Console]::KeyAvailable -and [DateTime]::Now -lt $deadline) { Start-Sleep -Milliseconds 10 }
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $char = [string]$key.KeyChar
                if ($key.Key -eq 'UpArrow' -or $char -eq 'k') { $index = ($index - 1 + $Items.Count) % $Items.Count; $dirty = $true }
                elseif ($key.Key -eq 'DownArrow' -or $key.Key -eq 'Tab' -or $char -eq 'j') { $index = ($index + 1) % $Items.Count; $dirty = $true }
                elseif ($key.Key -eq 'Home') { $index = 0; $dirty = $true }
                elseif ($key.Key -eq 'End') { $index = $Items.Count - 1; $dirty = $true }
                elseif ($key.Key -eq 'Enter') { return $Items[$index].Key }
                elseif ($key.Key -eq 'Escape' -or $char -eq 'q' -or [int]$key.KeyChar -eq 3) { return $null }
                else {
                    $hit = @($Items | Where-Object Hotkey -eq $char)
                    if ($hit.Count) { return $hit[0].Key }
                }
            }
        }
    } finally {
        [Console]::Write("$Esc[0m$Esc[?25h$Esc[?1049l")
        [Console]::TreatControlCAsInput = $savedCtrlC
        [Console]::OutputEncoding = $savedEncoding
    }
}

function Read-PlainMenu([string]$Title, $Items) {
    Write-Host ''
    Write-Host "  Winsetup $($Glyph.Dash) $Title" -ForegroundColor Cyan
    $pad = ($Items | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum + 1
    foreach ($item in $Items) { Write-Host ("  {0}) {1} {2}" -f $item.Hotkey, $item.Label.PadRight($pad), $item.Hint) }
    while ($true) {
        $answer = Read-Host '  Seçim'
        $hit = @($Items | Where-Object Hotkey -eq $answer)
        if ($hit.Count) { return $hit[0].Key }
    }
}

function Read-MenuChoice([string]$Title, $Items) {
    if ((Test-FancyConsole) -and (Get-MenuLayout $Items)) { Read-FancyMenu $Title $Items } else { Read-PlainMenu $Title $Items }
}

function Read-ProfileChoice { Read-MenuChoice 'Profil' $ProfileMenu }

function Read-LevelChoice { Read-MenuChoice 'Debloat seviyesi' $LevelMenu }

function Read-YesNo([string]$Question) {
    (Read-Host "  $Question (E/H)") -match '^(e|evet|y|yes)$'
}

function New-RestorePoint {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Windows varsayılan olarak 24 saatte bir nokta oluşturmaya izin verir
        $sr = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        Set-Reg $sr 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'Winsetup öncesi' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Remove-ItemProperty $sr -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
        Write-Ok 'Geri yükleme noktası oluşturuldu'
    } catch {
        Write-Warn 'Geri yükleme noktası oluşturulamadı'
    }
}

#endregion

function Invoke-Winsetup {
    $selected = $Profile
    $debloatLevel = $Level
    $interactive = -not $Yes

    if (-not $selected) {
        if (-not $interactive) {
            Write-Host '  -Yes ile birlikte -Profile da verilmeli.' -ForegroundColor Red
            return
        }
        $selected = Read-ProfileChoice
        if (-not $selected) { return }
    }
    if ($selected -eq 'Debloat' -and -not $debloatLevel) {
        $debloatLevel = if ($interactive) { Read-LevelChoice } else { 'Standard' }
        if (-not $debloatLevel) { return }
    }

    # Uygulama kaldıran profiller Windows PowerShell 5.1 ister: PS7'de Get-AppxProvisionedPackage
    # çalışmıyor, geri yükleme noktası cmdlet'leri yok. Neovim/Terminal her PowerShell'de çalışır.
    $needsDesktop = $selected -notin $Pwsh7Profiles
    if (-not $DryRun -and (-not (Test-Admin) -or ($needsDesktop -and $PSVersionTable.PSEdition -ne 'Desktop'))) {
        Start-Elevated $selected $debloatLevel $needsDesktop
        return
    }

    Write-Host ''
    Write-Info 'Sistem taranıyor...'
    $plan = @(Get-Plan $selected $debloatLevel)
    Write-Host ''
    Write-Host "  Profil: $($ProfileNames[$selected])" -ForegroundColor Cyan
    Write-Host '  Yapılacaklar:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $plan.Count; $i++) {
        Write-Host ("  {0,2}. {1}" -f ($i + 1), $plan[$i].Name)
        foreach ($d in $plan[$i].Details) { Write-Wrapped $d }
    }
    Write-Host ''
    if ($DryRun) { return }

    $light = $selected -in $LightProfiles
    $createRestorePoint = $false
    $State.Logo = -not $NoLogo
    if ($interactive) {
        if (-not (Read-YesNo 'Devam edilsin mi?')) { return }
        if ($selected -in $TerminalProfiles) { $State.Logo = Read-YesNo 'Terminal arka planına BJK logosu konsun mu?' }
        if (-not $light) { $createRestorePoint = Read-YesNo 'Önce geri yükleme noktası oluşturulsun mu?' }
    }

    Start-Transcript -Path $LogPath -Append | Out-Null
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
        if ($createRestorePoint) { New-RestorePoint }

        for ($i = 0; $i -lt $plan.Count; $i++) {
            Write-Host ''
            Write-Host ("[{0}/{1}] {2}" -f ($i + 1), $plan.Count, $plan[$i].Name) -ForegroundColor Cyan
            try {
                & $plan[$i].Action $plan[$i]
            } catch {
                Write-Warn "Adım hata verdi: $($_.Exception.Message)"
            }
        }
        if (-not $light) { Restart-Explorer }
    } finally {
        Stop-Transcript | Out-Null
    }

    Write-Host ''
    if ($State.Warnings -gt 0) {
        Write-Host "  Bitti, $($State.Warnings) uyarı var. Ayrıntılar: $LogPath" -ForegroundColor Yellow
    } else {
        Write-Host "  Bitti. Log: $LogPath" -ForegroundColor Green
    }
    if ($interactive -and -not $light) {
        if (Read-YesNo 'Değişikliklerin tamamı için yeniden başlatılsın mı?') { Restart-Computer -Force }
    }
}

# Seçilen profille yönetici penceresi açar. Script zaten indirilmiş olduğu için metni diske yazılır,
# yeni pencere onu okur: komut satırında URL/irm ve -ExecutionPolicy olmaz (Defender bu kalıbı
# Trojan:Win32/Commando.A!ml diye engelliyordu; execution policy -Command'ı zaten etkilemez).
function Start-Elevated([string]$Selected, [string]$DebloatLevel, [bool]$NeedsDesktop) {
    $dir = Join-Path $env:TEMP 'Winsetup'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $file = Join-Path $dir 'winsetup.ps1'
    [IO.File]::WriteAllText($file, $SelfSource, (New-Object Text.UTF8Encoding $false))

    $forward = @("-Profile $Selected")
    if ($DebloatLevel) { $forward += "-Level $DebloatLevel" }
    if ($Yes) { $forward += '-Yes' }
    if ($NoLogo) { $forward += '-NoLogo' }
    if ($LocalRepo) { $forward += "-LocalRepo '$LocalRepo'" }
    # 5.1 dosyaları ANSI okur, metin UTF-8 olarak okutulur
    $command = "& ([scriptblock]::Create([IO.File]::ReadAllText('$file', [Text.Encoding]::UTF8))) $($forward -join ' ')"

    $shell = 'powershell.exe'
    if (-not $NeedsDesktop) {
        $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pwsh) { $shell = $pwsh.Source }
    }
    $shellArgs = "-NoProfile -Command `"$command`""
    if (-not $Yes) { $shellArgs = "-NoExit $shellArgs" }

    $name = if ($shell -eq 'powershell.exe') { 'Windows PowerShell' } else { 'PowerShell 7' }
    Write-Host "  Yönetici olarak $name açılıyor..." -ForegroundColor Yellow
    try {
        if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
            Start-Process wt.exe -Verb RunAs -ArgumentList "new-tab --title Winsetup `"$shell`" $shellArgs" -ErrorAction Stop
        } else {
            Start-Process $shell -Verb RunAs -ArgumentList $shellArgs -ErrorAction Stop
        }
    } catch {
        Write-Host '  Yönetici izni verilmedi.' -ForegroundColor Red
    }
}

Invoke-Winsetup
} @args
