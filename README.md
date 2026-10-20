<div align="center">

<img src="assets/banner.svg" alt="GÖKHAN WinSetup" width="720">

<br>

![Windows 11](https://img.shields.io/badge/Windows_11-1e1e2e?style=for-the-badge&logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0iIzg5YjRmYSIgZD0iTTIgMmg5LjV2OS41SDJ6TTEyLjUgMkgyMnY5LjVoLTkuNXpNMiAxMi41aDkuNVYyMkgyek0xMi41IDEyLjVIMjJWMjJoLTkuNXoiLz48L3N2Zz4=) ![PowerShell](https://img.shields.io/badge/PowerShell_5.1_/_7-1e1e2e?style=for-the-badge&logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0ibm9uZSIgc3Ryb2tlPSIjY2JhNmY3IiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIgZD0iTTQgNmw3IDYtNyA2TTEzIDE4aDciLz48L3N2Zz4=)


Windows 11 için tek komutla kurulum ve sadeleştirme

</div>

## Kurulum

```powershell
irm gokhanturk.com/win | iex
```

Etkileşimsiz:

```powershell
& ([scriptblock]::Create((irm gokhanturk.com/win))) -Profile Gaming -Yes
```

Yalnızca debloat:

```powershell
irm gokhanturk.com/uninstall | iex
```

## Profiller

| Profil | İçerik |
| --- | --- |
| `Gaming` | Full debloat, Edge ve OneDrive kaldırma, oyun optimizasyonları, Steam, Firefox, mpv, geliştirici ortamı |
| `Work` | Standart debloat, OneDrive kaldırma, 7-Zip, Firefox, geliştirici ortamı |
| `VM` | Full debloat, OneDrive kaldırma, geliştirici ortamı |
| `Standard` | Standart debloat, reklam ve telemetri kapatma, 7-Zip |
| `Debloat` | Yalnızca uygulama kaldırma |
| `Neovim` | Neovim ve yapılandırması |
| `Terminal` | Yalnızca geliştirici ortamı |
| `RSAT` | AD Users and Computers, AD Sites and Services, DNS, DHCP |

**Geliştirici ortamı:** PowerShell 7, Windows Terminal, FiraCode Nerd Font, git, gh, neovim, starship, zoxide, fzf, eza, bat, ripgrep, fd, fastfetch ve [dotfiles](https://github.com/GokhanTurk/dotfiles) yapılandırmaları.

## Parametreler

| Parametre | Açıklama |
| --- | --- |
| `-Profile` | Profil adı |
| `-Level` | `Standard` veya `Full` (yalnızca `Debloat` profili) |
| `-Yes` | Onay istemeden çalışır |
| `-DryRun` | Değişiklik yapmadan planı listeler |
| `-NoLogo` | Terminal arka plan logosunu eklemez |

## Debloat seviyeleri

- **Standard:** Bing uygulamaları, Copilot, Clipchamp, LinkedIn, oyunlar gibi gereksiz uygulamalar
- **Full:** Temel araçlar (Hesap Makinesi, Not Defteri, Terminal, Store, Fotoğraflar, Paint, codec'ler) dışındaki tüm Microsoft uygulamaları

Değişiklikler mevcut ve yeni kullanıcı hesaplarına uygulanır. Kayıt dosyası: `%TEMP%\Winsetup.log`

---

<p align="center"><a href="https://gokhanturk.com"><img src="https://gokhanturk.com/favicon.svg" width="16" height="16" align="absmiddle"> gokhanturk.com</a></p>
