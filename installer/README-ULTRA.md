# JARVIS NEXUS ULTRA — безопасная сборка Setup.exe

Используйте только файлы с суффиксом ULTRA. Они не зависят от старых черновых
скриптов и собирают локальную ULTRA-версию с единственным entrypoint:
ultra-server.mjs на http://127.0.0.1:3791.

В дистрибутив попадают только:

- ULTRA-сервер, public-ultra, assets, windows-control и windows-theme;
- локальный node.exe версии 20+;
- лаунчер ULTRA и неоновый WPF-инсталлятор.

Никогда не попадают .env, data, server.mjs, OMEGA, node_modules и .git.
Поэтому память, история и пользовательский ключ остаются в
%LOCALAPPDATA%\JARVIS NEXUS ULTRA\app после обновлений и перезагрузки ПК.

## Проверить, ничего не создавая

~~~powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Test-Installer-ULTRA.ps1
~~~

## Собрать EXE

~~~powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer-ULTRA.ps1
~~~

Для заранее подготовленного локального Node runtime:

~~~powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer-ULTRA.ps1 -NodeRuntime C:\portable-node\node.exe
~~~

EXE и SHA-256 появятся в installer\dist-ultra. Сборщик никогда не
перезаписывает готовый EXE, checksum или staging-каталог.

## IExpress: как не получить Command syntax is incorrect

Скрипт создаёт SED в ASCII-каталоге без пробелов и запускает IExpress именно с
параметрами /N /Q и обязательным именем SED:

~~~powershell
Push-Location C:\...\JNU-ULTRA-<id>
& "$env:WINDIR\System32\iexpress.exe" /N /Q JARVIS-NEXUS-ULTRA.sed
Pop-Location
~~~

Не запускайте IExpress без последнего аргумента. Если путь проекта содержит
пробелы, передайте отдельный staging-каталог без пробелов:

~~~powershell
.\installer\Build-Installer-ULTRA.ps1 -IExpressWorkRoot C:\JNU-build
~~~

IExpress не делает цифровую подпись. Перед передачей другу отправьте EXE
вместе с одноимённым .sha256.txt. Для широкого распространения нужен
подлинный сертификат подписи кода; не просите получателей обходить SmartScreen.
