# irm gokhanturk.com/uninstall | iex
# Winsetup'ı "Sadece debloat" profiliyle açar (seviye ve onay sorulur).
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/GokhanTurk/Winsetup/main/winsetup.ps1'))) -Profile Debloat
