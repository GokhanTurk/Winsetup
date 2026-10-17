# Winsetup — Windows 11 tek tıkla kurulum
# Kullanım:
#   irm gokhanturk.com/win | iex
#   & ([scriptblock]::Create((irm gokhanturk.com/win))) -Profile Gaming -Yes
#   & ([scriptblock]::Create((irm gokhanturk.com/win))) -Profile Debloat -Level Full -Yes

param(
    [ValidateSet('Gaming', 'Work', 'VM', 'Standard', 'Debloat')]
    [string]$Profile,
    [ValidateSet('Standard', 'Full')]
    [string]$Level,
    [switch]$Yes,
    [switch]$DryRun,
    # Yerel klondan çalışırken config/asset dosyaları buradan kopyalanır (otomatik verilir)
    [string]$LocalRepo
)

if (-not $LocalRepo -and $PSScriptRoot) { $LocalRepo = $PSScriptRoot }

$RepoRaw = 'https://raw.githubusercontent.com/GokhanTurk/Winsetup/main'
$DotfilesRaw = 'https://raw.githubusercontent.com/GokhanTurk/dotfiles/main'
$ScriptUrl = "$RepoRaw/winsetup.ps1"
$LogPath = Join-Path $env:TEMP 'Winsetup.log'
$DataDir = Join-Path $env:LOCALAPPDATA 'Winsetup'
$MachineDataDir = Join-Path $env:ProgramData 'Winsetup'
$script:Warnings = 0

#region Yardımcılar

function Write-Info([string]$Message) { Write-Host "  $Message" -ForegroundColor Gray }
function Write-Ok([string]$Message) { Write-Host "  $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) {
    $script:Warnings++
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

function Install-WingetPackage([string]$Id) {
    Write-Info "Kuruluyor: $Id"
    winget install --id $Id --exact --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
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

# Copilot artık Store uygulamasının yanında Edge gibi ayrı bir Win32 program olarak da geliyor.
function Remove-CopilotApp {
    $key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Copilot'
    $uninstall = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).UninstallString
    if ($uninstall -match '^"([^"]+)"\s*(.*)$') {
        Get-Process -Name '*copilot*' -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Process -FilePath $Matches[1] -ArgumentList "$($Matches[2]) --force-uninstall" -Wait -WindowStyle Hidden
        if (Test-Path -LiteralPath $key) { Write-Warn 'Copilot (Win32) kaldırılamadı' } else { Write-Ok 'Kaldırıldı: Copilot (Win32)' }
    }
    # EdgeUpdate Copilot'u tekrar kurmasın
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{C50565E9-CCCF-44B4-BA15-5AC5C6569197}' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
}

# Extra: bu profilde ayrıca kaldırılacak paketler
function Remove-Bloatware([string]$DebloatLevel, [string[]]$Extra = @()) {
    $deprovisioned = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'

    # Yeni kullanıcılar için (provisioned)
    foreach ($pkg in Get-AppxProvisionedPackage -Online) {
        $parts = $pkg.PackageName -split '_'
        $family = "$($parts[0])_$($parts[-1])"
        if (-not (Test-ShouldRemove $pkg.DisplayName $family $DebloatLevel $Extra)) { continue }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -AllUsers -ErrorAction Stop | Out-Null
            # Windows özellik güncellemesinden sonra geri yüklenmesin
            if (-not (Test-Path "$deprovisioned\$family")) { New-Item -Path "$deprovisioned\$family" -Force | Out-Null }
            Write-Ok "Kaldırıldı (provisioned): $($pkg.DisplayName)"
        } catch {
            Write-Warn "Kaldırılamadı (provisioned): $($pkg.DisplayName)"
        }
    }

    # Mevcut tüm kullanıcılar için
    $installed = Get-AppxPackage -AllUsers | Where-Object {
        -not $_.IsFramework -and -not $_.NonRemovable -and $_.SignatureKind -ne 'System'
    } | Sort-Object PackageFullName -Unique
    foreach ($pkg in $installed) {
        if (-not (Test-ShouldRemove $pkg.Name $pkg.PackageFamilyName $DebloatLevel $Extra)) { continue }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Write-Ok "Kaldırıldı: $($pkg.Name)"
        } catch {
            Write-Warn "Kaldırılamadı: $($pkg.Name)"
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
    Write-Ok 'Geri yükleme koruması uygulandı'
}

function Remove-OneDrive {
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget uninstall --id Microsoft.OneDrive --exact --silent --accept-source-agreements --disable-interactivity | Out-Null
    }
    foreach ($setup in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
        if (Test-Path $setup) { Start-Process $setup -ArgumentList '/uninstall' -Wait -WindowStyle Hidden }
    }
    # Yeni kullanıcılarda ilk girişte kurulmasın
    Invoke-DefaultUserHive {
        param($root)
        Remove-ItemProperty "$root\Software\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDriveSetup' -ErrorAction SilentlyContinue
    }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Write-Ok 'OneDrive kaldırıldı'
}

function Remove-OptionalComponents {
    $capabilities = @(
        'App.StepsRecorder*', 'MathRecognizer*', 'Microsoft.Windows.WordPad*', 'Browser.InternetExplorer*',
        'Hello.Face*', 'Microsoft.Windows.PowerShell.ISE*', 'Media.WindowsMediaPlayer*', 'XPS.Viewer*',
        'Microsoft.Wallpapers.Extended*', 'App.Support.QuickAssist*'
    )
    foreach ($cap in Get-WindowsCapability -Online | Where-Object { $_.State -eq 'Installed' }) {
        if (-not (Test-NameLike $cap.Name $capabilities)) { continue }
        try {
            Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            Write-Ok "Kaldırıldı (capability): $($cap.Name)"
        } catch {
            Write-Warn "Kaldırılamadı (capability): $($cap.Name)"
        }
    }

    $features = @('Recall', 'WorkFolders-Client', 'Printing-XPSServices-Features',
        'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2')
    foreach ($f in $features) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if (-not $feature -or $feature.State -ne 'Enabled') { continue }
        try {
            Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
            Write-Ok "Kapatıldı (özellik): $f"
        } catch {
            Write-Warn "Kapatılamadı (özellik): $f"
        }
    }
}

# Edge kaldırılır, WebView2 kalır (launcher'lar ve Discord ona ihtiyaç duyar).
function Remove-Edge {
    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
    $key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
    $uninstall = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).UninstallString

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

    if (Test-Path -LiteralPath $key) {
        Write-Warn 'Edge kaldırılamadı (Microsoft yöntemi değiştirmiş olabilir)'
    } else {
        Write-Ok 'Edge kaldırıldı, WebView2 duruyor'
    }
}

#endregion

#region Windows ayarları

function Set-PrivacyTweaks {
    Set-ContentDeliveryOff 'HKCU:'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_AccountNotifications' 0
    Write-Ok 'Reklam, öneri ve telemetri kapatıldı'
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

function Set-FileExtensionsVisible {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
    Write-Ok 'Dosya uzantıları görünür'
}

# Eski OneClickToReady'den gelen kişisel ayarlar
function Set-PersonalTweaks {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
    Set-Reg $adv 'HideFileExt' 0
    Set-Reg $adv 'LaunchTo' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0
    # Num Lock açılışta açık (giriş ekranı + kullanıcı)
    Set-Reg 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
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

function Install-PersonalEnvironment {
    Install-Apps @(
        'Microsoft.PowerShell', 'Microsoft.WindowsTerminal', 'Git.Git', 'GitHub.cli', 'Neovim.Neovim',
        'ajeetdsouza.zoxide', 'Starship.Starship', 'junegunn.fzf', 'eza-community.eza', 'sharkdp.bat',
        'BurntSushi.ripgrep.MSVC', 'sharkdp.fd', 'Fastfetch-cli.Fastfetch'
    )
    Install-NerdFont

    # Windows Terminal
    $wt = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    Save-File "$RepoRaw/config/WindowsTerminal/settings.json" $wt
    Save-File "$RepoRaw/assets/BJK(Terminal).png" (Join-Path $DataDir 'BJK(Terminal).png')

    # PowerShell 7 profili
    $docs = [Environment]::GetFolderPath('MyDocuments')
    Save-File "$RepoRaw/config/PowerShell/profile.ps1" "$docs\PowerShell\Microsoft.PowerShell_profile.ps1"
    # Store sürümü WindowsApps'te, winget/MSI sürümü Program Files'ta olur
    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $pwsh -and (Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe")) { $pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    if ($pwsh) {
        & $pwsh -NoProfile -Command 'Install-Module PSFzf -Scope CurrentUser -Force -Repository PSGallery' 2>&1 | Out-Null
    } else {
        Write-Warn 'PowerShell 7 bulunamadı, PSFzf kurulamadı'
    }

    # dotfiles reposundan ortak configler
    Save-File "$DotfilesRaw/starship/.config/starship.toml" "$env:USERPROFILE\.config\starship.toml"
    Save-File "$DotfilesRaw/fastfetch/.config/fastfetch/config.jsonc" "$env:USERPROFILE\.config\fastfetch\config.jsonc"
    Save-File "$DotfilesRaw/bat/.config/bat/config" "$env:APPDATA\bat\config"
    Save-File "$DotfilesRaw/nvim/.config/nvim/init.lua" "$env:LOCALAPPDATA\nvim\init.lua"
    Save-File "$DotfilesRaw/nvim/.config/nvim/nvim-pack-lock.json" "$env:LOCALAPPDATA\nvim\nvim-pack-lock.json"
    Write-Ok 'Kişisel terminal ortamı kuruldu'
}

#endregion

#region Profiller

function New-Step([string]$Name, [scriptblock]$Action) {
    [pscustomobject]@{ Name = $Name; Action = $Action }
}

function Get-Plan([string]$Selected, [string]$DebloatLevel) {
    switch ($Selected) {
        'Gaming' {
            New-Step 'Debloat (Full): hesap makinesi, notepad, terminal, ekran alıntısı, Store, fotoğraflar, paint ve codec''ler hariç her şey' { Remove-Bloatware 'Full'; Protect-Debloat 'Full' }
            New-Step 'Edge kaldır (WebView2 kalır)' { Remove-Edge }
            New-Step 'OneDrive kaldır' { Remove-OneDrive }
            New-Step 'Kişisel ayarlar (koyu tema, uzantılar, Bu Bilgisayar, Num Lock, yapışkan tuşlar, telemetri, prizde uyku kapalı)' { Set-PersonalTweaks }
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
            New-Step 'Kişisel terminal ortamı (PS7, Terminal, FiraCode, zoxide, starship, fzf, eza, bat, rg, fd, fastfetch, git, gh, nvim, dotfiles)' { Install-PersonalEnvironment }
            New-Step 'Gereksiz Windows bileşenleri (WordPad, IE, Steps Recorder, Recall, PowerShell 2.0...) — uzun sürebilir' { Remove-OptionalComponents }
        }
        'Work' {
            New-Step 'Debloat (Standart + Widgets): Edge, Teams, Outlook, Uzak Masaüstü, Hızlı Yardım kalır' { Remove-Bloatware 'Standard' @('MicrosoftWindows.Client.WebExperience'); Protect-Debloat 'Standard' }
            New-Step 'Kişisel ayarlar (koyu tema, uzantılar, Bu Bilgisayar, Num Lock, yapışkan tuşlar, telemetri, prizde uyku kapalı)' { Set-PersonalTweaks }
            New-Step 'Bölge biçimleri Türkiye' { Set-TurkishRegion }
            New-Step 'Arayüz temizliği (klasik sağ tık, Widgets/Copilot kapalı, taskbar boş)' { Set-InterfaceCleanup }
            New-Step 'Hızlı başlatma / hazırda bekletme kapalı' { Disable-FastBoot }
            New-Step 'Uygulamalar: 7-Zip, Firefox' { Install-Apps @('7zip.7zip', 'Mozilla.Firefox') }
            New-Step 'Duvar kağıdı' { Set-Wallpaper }
            New-Step 'Kişisel terminal ortamı (PS7, Terminal, FiraCode, zoxide, starship, fzf, eza, bat, rg, fd, fastfetch, git, gh, nvim, dotfiles)' { Install-PersonalEnvironment }
        }
        'VM' {
            New-Step 'Debloat (Full): Edge dahil kalanlar korunur' { Remove-Bloatware 'Full'; Protect-Debloat 'Full' }
            New-Step 'OneDrive kaldır' { Remove-OneDrive }
            New-Step 'Kişisel ayarlar (koyu tema, uzantılar, Bu Bilgisayar, Num Lock, yapışkan tuşlar, telemetri, prizde uyku kapalı)' { Set-PersonalTweaks }
            New-Step 'Bölge biçimleri Türkiye' { Set-TurkishRegion }
            New-Step 'Arka plan uygulamaları kapalı' { Disable-BackgroundApps }
            New-Step 'Arayüz temizliği (klasik sağ tık, Widgets/Copilot kapalı, taskbar boş)' { Set-InterfaceCleanup }
            New-Step 'Duvar kağıdı' { Set-Wallpaper }
            New-Step 'Kişisel terminal ortamı (PS7, Terminal, FiraCode, zoxide, starship, fzf, eza, bat, rg, fd, fastfetch, git, gh, nvim, dotfiles)' { Install-PersonalEnvironment }
            New-Step 'Gereksiz Windows bileşenleri (WordPad, IE, Steps Recorder, Recall, PowerShell 2.0...) — uzun sürebilir' { Remove-OptionalComponents }
        }
        'Standard' {
            New-Step 'Debloat (Standart): sadece çöp uygulamalar, Xbox/Edge/Store ve günlük uygulamalar kalır' { Remove-Bloatware 'Standard'; Protect-Debloat 'Standard' }
            New-Step 'Reklam, öneri ve telemetri kapalı' { Set-PrivacyTweaks }
            New-Step 'Bölge biçimleri Türkiye' { Set-TurkishRegion }
            New-Step 'Görev çubuğu sadeleştirme (arama simge olarak kalır)' { Set-TaskbarTweaks 1 }
            New-Step 'Dosya uzantılarını göster' { Set-FileExtensionsVisible }
            New-Step 'Uygulama: 7-Zip' { Install-Apps @('7zip.7zip') }
        }
        'Debloat' {
            if ($DebloatLevel -eq 'Full') {
                New-Step 'Debloat (Full): hesap makinesi, notepad, terminal, ekran alıntısı, Store, Edge, fotoğraflar, paint ve codec''ler hariç her şey' { Remove-Bloatware 'Full'; Protect-Debloat 'Full' }
                New-Step 'OneDrive kaldır' { Remove-OneDrive }
                New-Step 'Gereksiz Windows bileşenleri (WordPad, IE, Steps Recorder, Recall, PowerShell 2.0...) — uzun sürebilir' { Remove-OptionalComponents }
            } else {
                New-Step 'Debloat (Standart): sadece çöp uygulamalar, tüm kullanıcılardan ve yeni kullanıcılardan' { Remove-Bloatware 'Standard'; Protect-Debloat 'Standard' }
            }
        }
    }
}

$ProfileNames = [ordered]@{
    Gaming   = 'Oyun'
    Work     = 'İş'
    VM       = 'Sanal makine'
    Standard = 'Standart (genel kullanıcı)'
    Debloat  = 'Sadece debloat'
}

function Read-ProfileChoice {
    Write-Host ''
    Write-Host '  Winsetup — profil seç' -ForegroundColor Cyan
    Write-Host '  1) Oyun         Full debloat + Edge kaldır + oyun ayarları + Steam + kişisel ortam'
    Write-Host '  2) İş           Standart debloat (Edge/Teams/Outlook kalır) + kişisel ortam'
    Write-Host '  3) Sanal makine Full debloat + kişisel ortam (Steam/oyun ayarı yok)'
    Write-Host '  4) Standart     Genel kullanıcı: sadece çöpler, reklamlar ve telemetri'
    Write-Host '  5) Debloat      Sadece uygulama kaldırma'
    Write-Host '  0) Çıkış'
    while ($true) {
        switch (Read-Host '  Seçim') {
            '1' { return 'Gaming' }
            '2' { return 'Work' }
            '3' { return 'VM' }
            '4' { return 'Standard' }
            '5' { return 'Debloat' }
            '0' { return $null }
        }
    }
}

function Read-LevelChoice {
    Write-Host ''
    Write-Host '  1) Standart  Sadece çöp uygulamalar (genel kullanıcı için güvenli)'
    Write-Host '  2) Full      Microsoft uygulamalarının neredeyse hepsi (VM / minimal kurulum)'
    while ($true) {
        switch (Read-Host '  Seviye') {
            '1' { return 'Standard' }
            '2' { return 'Full' }
        }
    }
}

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
    }

    $plan = @(Get-Plan $selected $debloatLevel)
    Write-Host ''
    Write-Host "  Profil: $($ProfileNames[$selected])" -ForegroundColor Cyan
    Write-Host '  Yapılacaklar:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $plan.Count; $i++) { Write-Host ("  {0,2}. {1}" -f ($i + 1), $plan[$i].Name) }
    Write-Host ''
    if ($DryRun) { return }

    $createRestorePoint = $false
    if ($interactive) {
        if (-not (Read-YesNo 'Devam edilsin mi?')) { return }
        $createRestorePoint = Read-YesNo 'Önce geri yükleme noktası oluşturulsun mu?'
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
                & $plan[$i].Action
            } catch {
                Write-Warn "Adım hata verdi: $($_.Exception.Message)"
            }
        }
        Restart-Explorer
    } finally {
        Stop-Transcript | Out-Null
    }

    Write-Host ''
    if ($script:Warnings -gt 0) {
        Write-Host "  Bitti, $($script:Warnings) uyarı var. Ayrıntılar: $LogPath" -ForegroundColor Yellow
    } else {
        Write-Host "  Bitti. Log: $LogPath" -ForegroundColor Green
    }
    if ($interactive) {
        if (Read-YesNo 'Değişikliklerin tamamı için yeniden başlatılsın mı?') { Restart-Computer -Force }
    }
}

# Yönetici değilsek ya da PowerShell 7'deysek (Appx modülü 5.1 ister) Windows PowerShell'de yönetici olarak yeniden başlat.
if (-not $DryRun -and (-not (Test-Admin) -or $PSVersionTable.PSEdition -ne 'Desktop')) {
    $forward = @()
    if ($Profile) { $forward += "-Profile $Profile" }
    if ($Level) { $forward += "-Level $Level" }
    if ($Yes) { $forward += '-Yes' }
    if ($LocalRepo) { $forward += "-LocalRepo '$LocalRepo'" }
    $forward = $forward -join ' '
    # Dosya BOM'suz UTF-8 (BOM irm | iex'i bozar); 5.1 -File ile ANSI okuyacağı için UTF-8 olarak okutuyoruz.
    $source = if ($PSCommandPath) { "[IO.File]::ReadAllText('$PSCommandPath', [Text.Encoding]::UTF8)" } else { "(irm '$ScriptUrl')" }
    $launch = "-NoProfile -ExecutionPolicy Bypass -Command `"& ([scriptblock]::Create($source)) $forward`""
    if (-not $Yes) { $launch = "-NoExit $launch" }
    Write-Host '  Yönetici olarak Windows PowerShell''de yeniden başlatılıyor...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList $launch
} else {
    Invoke-Winsetup
}
