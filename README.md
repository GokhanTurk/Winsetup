# Winsetup

Windows 11 tek tıkla kurulum: debloat, ayarlar, uygulamalar ve kişisel terminal ortamı.

## Kullanım

PowerShell'de (yönetici olması gerekmez, script kendini yönetici olarak yeniden başlatır):

```powershell
irm gokhanturk.com/win | iex
```

Menüden profil seçilir, yapılacaklar listelenir ve onay istenir. Geri yükleme noktası oluşturulup oluşturulmayacağı da sorulur.

Sessiz kurulum (soru sormaz, geri yükleme noktası oluşturmaz, yeniden başlatmaz):

```powershell
& ([scriptblock]::Create((irm gokhanturk.com/win))) -Profile Gaming -Yes
& ([scriptblock]::Create((irm gokhanturk.com/win))) -Profile Debloat -Level Full -Yes
```

Sadece debloat:

```powershell
irm gokhanturk.com/uninstall | iex
```

Yapılacakları görmek için `-DryRun` eklenebilir. Log: `%TEMP%\Winsetup.log`

## Profiller

| Profil | Ne yapar |
| --- | --- |
| `Gaming` | Full debloat, Edge kaldırılır (WebView2 kalır), OneDrive ve gereksiz Windows bileşenleri kaldırılır. Oyun ayarları: cihaz/ağ güç tasarrufu kapalı, timer resolution, Game Bar kapalı, Defender hafif optimize, siyah kilit ekranı. Steam, Firefox, mpv. Kişisel ortam. |
| `Work` | Standart debloat (Edge, Teams, Outlook, Uzak Masaüstü, Hızlı Yardım kalır). 7-Zip, Firefox. Kişisel ortam. |
| `VM` | Full debloat (Edge kalır), OneDrive ve gereksiz bileşenler kaldırılır. Kişisel ortam. |
| `Standard` | Genel kullanıcı: sadece çöp uygulamalar kaldırılır, reklam/öneri/telemetri kapatılır, görev çubuğu sadeleşir, dosya uzantıları görünür. 7-Zip. |
| `Debloat` | Sadece uygulama kaldırma. `-Level Standard` (varsayılan) veya `-Level Full`. |

**Kişisel ortam:** PowerShell 7, Windows Terminal ([ayarlar](config/WindowsTerminal/settings.json)), FiraCode Nerd Font, zoxide, starship, fzf + PSFzf, eza, bat, ripgrep, fd, fastfetch, git, gh, neovim, [PowerShell profili](config/PowerShell/profile.ps1). starship, bat, fastfetch ve nvim ayarları [dotfiles](https://github.com/GokhanTurk/dotfiles) reposundan çekilir. Koyu tema, dosya uzantıları, Bu Bilgisayar, Num Lock, yapışkan tuş kısayolları kapalı, prizde uyku kapalı, klasik sağ tık menüsü, duvar kağıdı.

### Debloat seviyeleri

- **Standard:** Bing Haberler/Finans/Spor/Arama, İpuçları, Yardım Alın, Solitaire, Geri Bildirim Merkezi, Mixed Reality, 3D uygulamaları, Clipchamp, Power Automate, Dev Home, LinkedIn, Skype, People, Wallet, Messaging, Sway, Microsoft 365 (Office Hub), Cortana, Haritalar, To Do, OneNote, Copilot, Aile Güvenliği, Spotify, Disney+, Candy Crush. Hesap makinesi, saat, kamera, fotoğraflar, Xbox, Edge, Store vb. kalır.
- **Full:** Microsoft'un tüm uygulamaları kaldırılır; hesap makinesi, Notepad, Terminal, Ekran Alıntısı, Store, winget, Fotoğraflar, Paint, medya codec'leri, Windows Güvenliği ve Edge kalır. Donanım üreticisi uygulamalarına (NVIDIA, Intel, Realtek, HP...) dokunulmaz.

Her iki seviyede de uygulamalar mevcut tüm kullanıcılardan ve yeni açılacak kullanıcılardan kaldırılır, Windows'un önerilen uygulamaları otomatik kurması kapatılır.

## Notlar

- Script Windows PowerShell 5.1'de çalışır (Appx modülü için); PowerShell 7'den çağrılırsa otomatik geçer.
- Kişisel ayarlar scripti çalıştıran (yönetici yetkisi veren) kullanıcıya uygulanır.
- Edge, Windows büyük sürüm güncellemelerinde geri gelebilir; script tekrar çalıştırılabilir.
- `archive/` kullanılmayan dosyaları tutar.
