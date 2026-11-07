# PSWinKit

[English](README.md) | **Русский**

**PSWinKit** — развивающийся набор независимых утилит для Windows PowerShell. Каждая утилита запускается без обязательных параметров и использует общую библиотеку для локализации, повышения прав через UAC, начала и завершения работы.

## Утилиты

| Утилита | Назначение |
| --- | --- |
| [Remove-Paths](Remove-Paths/README.ru.md) | Интерактивное безвозвратное удаление выбранных файлов и каталогов, в том числе защищённых |
| [Repair-Windows](Repair-Windows/README.ru.md) | Восстановление Windows через CHKDSK, DISM и SFC |
| [Repair-WinRE](Repair-WinRE/README.ru.md) | Восстановление WinRE и поддерживаемых схем Recovery на GPT/MBR |
| [Check-SystemPartitions](Check-SystemPartitions/README.ru.md) | Диагностика системных разделов, оптимизация C: и Recovery, проверка и удаление лишних разделов |

## Требования и запуск

Windows 10+, Windows Server 2016+, Windows PowerShell 5.1; x86/x64, где применимо. Некоторым утилитам нужны права администратора. Для общей библиотеки не требуется PowerShell 7 или сторонние модули.

Из PowerShell в корне репозитория:

```powershell
.\Remove-Paths\Remove-Paths.ps1
.\Repair-Windows\Repair-Windows.ps1
.\Repair-WinRE\Repair-WinRE.ps1
.\Check-SystemPartitions\Check-SystemPartitions.ps1
```

Описание возможностей, предупреждения и ограничения приведены в README каждой утилиты. Структуру каталогов необходимо сохранять: утилиты подключают `Common/Common.ps1` по относительному пути.

## Установка и обновление

### Первоначальная установка

Откройте Windows PowerShell 5.1 **в существующем каталоге**, куда хотите установить PSWinKit. Скачайте архив репозитория в `%TEMP%`, распакуйте в уникальный каталог и запустите `install.ps1`:

```powershell
$dir = Join-Path $env:TEMP ('PSWinKit-' + [guid]::NewGuid().ToString('N'))
$zip = "$dir.zip"

$url = 'https://github.com/avmaksimov/PSWinKit/archive/refs/heads/main.zip?cacheBust=' + [guid]::NewGuid().ToString('N')
Invoke-WebRequest -Uri $url `
    -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' } `
    -OutFile $zip -UseBasicParsing -ErrorAction Stop

Expand-Archive -LiteralPath $zip -DestinationPath $dir
& (Join-Path $dir 'PSWinKit-main\install.ps1')
```

Установщик берёт файлы и переводы из распакованного архива и устанавливает их **непосредственно в текущий рабочий каталог** (`Get-Location`), **не создавая вложенную папку `PSWinKit`**. Каталог `PSWinKit-main` существует только во временной папке распаковки ZIP. Для первоначальной установки `update.ps1` не используется. При первоначальной установке `install.ps1` самостоятельно получает SHA и дату последнего коммита ветки `main` через GitHub API и сохраняет их в `install-info`. Если API недоступен, сведения о версии остаются неизвестными.

### Последующие обновления

Из каталога уже установленного PSWinKit выполните:

```powershell
.\update.ps1
```

`update.ps1` сравнивает установленный SHA с последним коммитом ветки `main` на GitHub. Если коммит отличается или его SHA неизвестен, скачивает архив и запускает свежий `install.ps1`. При доступном GitHub API скачивается архив конкретного коммита и устанавливается его SHA и дата; если API недоступен, используется `main.zip` без подтверждённых метаданных версии. Установщик не требует повышения прав, если каталог назначения доступен для записи.

Перед подтверждением проверьте каталог назначения и общую сводку `INSTALL`, `REPLACE`, `UNCHANGED`, `REMOVE`. Установщик сохраняет посторонние файлы, исключает из обработки компоненты путей с точкой в начале (включая служебные файлы Git) и не копирует самого себя. Локальный `install.psd1` содержит список `installed-files` для удаления устаревших файлов и отдельную секцию `install-info` с полным SHA и датой коммита в UTC. Если GitHub API не смог подтвердить коммит, поля версии остаются пустыми; отсутствие секции `install-info` означает первую установку. При отсутствии или повреждении файла либо списка устаревшие файлы не удаляются. Содержимое сравнивается по SHA-256; все изменения, включая удаление, подтверждаются один раз. Резервные копии старых версий и автоматический откат не предусмотрены. Не редактируйте `install.psd1` вручную.

## Документация

- [`Common/README.ru.md`](Common/README.ru.md) — **полное описание общего интерфейса и обязательный контракт разработки**.
- [`Remove-Paths/README.ru.md`](Remove-Paths/README.ru.md) — запуск, поведение и ограничения Remove-Paths.
- [`Repair-Windows/README.ru.md`](Repair-Windows/README.ru.md) — запуск и ограничения Repair-Windows.
- [`Repair-WinRE/README.ru.md`](Repair-WinRE/README.ru.md) — восстановление WinRE, схемы Recovery и ограничения безопасности.
- [`Check-SystemPartitions/README.ru.md`](Check-SystemPartitions/README.ru.md) — диагностика системного диска и оптимизация разметки.
- [`README.md`](README.md) — обзор на английском языке.

Лицензия проекта — [MIT](LICENSE).

Дата коммита отображается по местному времени и региональным настройкам Windows. При совпадении SHA проверка файлов пропускается; для повторной установки вручную запустите свежий `install.ps1` из архива исходников.
