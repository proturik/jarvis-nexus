# JARVIS NEXUS ULTRA — офлайн-установщик

Эта папка собирает один переносимый Setup.exe только штатными средствами
Windows: PowerShell, Compress-Archive и IExpress. Никаких загрузок,
удалений файлов или записи в Program Files не требуется.

Установщик запускает собственное WPF-окно в стиле NEXUS: неоновое ядро,
анимированное свечение, прогресс, ярлык и отдельный выбор автозапуска.
Он устанавливается только для текущего пользователя, поэтому не просит UAC.

## Что защищено

- Сборка берёт локальный node.exe (сначала -NodeRuntime, затем
  runtime/node.exe, затем установленный Node 20+) и ничего не скачивает.
- В пакет никогда не попадают data/, .env, .git или node_modules/.
- При обновлении сохраняются
  %LOCALAPPDATA%\JARVIS NEXUS ULTRA\app\data и
  %LOCALAPPDATA%\JARVIS NEXUS ULTRA\app\.env.
- Перед распаковкой установщик сверяет SHA-256 локального payload.zip.
- Он не удаляет пользовательские файлы, старые данные или ярлыки. Сборочные
  артефакты тоже сохраняются для аудита.

Память JARVIS хранится рядом с установленным приложением, а не во временной
папке установщика: перезапуск Windows её не стирает.

## Проверка без сборки

Выполните из корня проекта:

~~~powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Test-InstallerPrerequisites.ps1
~~~

Команда только проверяет файлы приложения, синтаксис скриптов, Node и IExpress.
Она не создаёт EXE и ничего не меняет.

## Создание EXE

После успешной проверки:

~~~powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1
~~~

Результат будет в installer\dist\JARVIS-NEXUS-ULTRA-Setup-<version>.exe
вместе с файлом SHA-256. Сборщик откажется перезаписать существующий EXE,
контрольную сумму или каталог staging.

Для заранее подготовленного портативного рантайма:

~~~powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer.ps1 -NodeRuntime C:\portable-node\node.exe
~~~

## Важное про IExpress: корректный синтаксис

IExpress очень чувствителен к аргументу .sed: при пробелах в пути он может
показать Command syntax is incorrect или Error Opening ... SED.
Сборщик специально создаёт SED в ASCII-каталоге без пробелов, переходит в него
и вызывает IExpress с явным именем SED:

~~~powershell
Push-Location C:\...\JNU-<id>
& "$env:WINDIR\System32\iexpress.exe" /N /Q JARVIS-NEXUS-ULTRA.sed
Pop-Location
~~~

Не заменяйте последний аргумент на путь с пробелами и не запускайте
iexpress.exe без .sed. Если проект находится в пути с пробелами, укажите
отдельный staging-каталог без пробелов:

~~~powershell
.\installer\Build-Installer.ps1 -IExpressWorkRoot C:\JNU-build
~~~

Test-InstallerPrerequisites.ps1 заранее проверяет это условие.

## Как отправить другу

Передайте оба файла из installer\dist:

- JARVIS-NEXUS-ULTRA-Setup-<version>.exe;
- одноимённый .sha256.txt.

Получатель может сверить файл локально:

~~~powershell
Get-FileHash .\JARVIS-NEXUS-ULTRA-Setup-<version>.exe -Algorithm SHA256
~~~

IExpress не подписывает EXE сам. Для распространения вне круга знакомых нужен
настоящий сертификат подписи кода и проверка подписи; не советуйте людям
обходить SmartScreen или защиту Windows.

## Содержимое пакета

IExpress не сохраняет структуру каталогов в CAB. Поэтому он несёт только
плоский набор аудируемых файлов:

- Install-Jarvis.cmd и Install-Jarvis.ps1;
- installer-manifest.json;
- payload.sha256;
- payload.zip.

Внутри payload.zip лежат приложение, визуальные ресурсы, Windows-контроль,
Windows-тема, стартовый launcher и локальный Node runtime. Установщик
распаковывает их в %LOCALAPPDATA%\JARVIS NEXUS ULTRA, сохраняя пользовательские
данные отдельно.
