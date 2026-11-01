# PSWinKit

[English](README.md) | **Русский**

**PSWinKit** — развивающийся набор независимых утилит для Windows PowerShell. Каждая утилита запускается без обязательных параметров и использует общую библиотеку для локализации, повышения прав через UAC, начала и завершения работы.

## Утилиты

| Утилита | Назначение | Состояние |
| --- | --- | --- |
| [Remove-Paths](Remove-Paths/README.ru.md) | Интерактивное безвозвратное удаление выбранных файлов и каталогов, в том числе защищённых | **Готова** |
| [Repair-Windows](Repair-Windows/README.ru.md) | Восстановление Windows через CHKDSK, DISM и SFC | **Готова** |
| WinRE-Manager | Управление и восстановление среды Windows RE | Планируется перенос |

Теперь в PSWinKit есть **Remove-Paths** и **Repair-Windows**. Перенос **WinRE-Manager** запланирован.

## Требования и запуск

Windows 10+, Windows Server 2016+, Windows PowerShell 5.1; x86/x64, где применимо. Некоторым утилитам нужны права администратора. Для общей библиотеки не требуется PowerShell 7 или сторонние модули.

Из PowerShell в корне репозитория:

```powershell
.\Remove-Paths\Remove-Paths.ps1
.\Repair-Windows\Repair-Windows.ps1
```

Описание возможностей, предупреждения и ограничения приведены в README каждой утилиты. Структуру каталогов необходимо сохранять: утилиты подключают `Common/Common.ps1` по относительному пути.

## Документация

- [`Common/README.ru.md`](Common/README.ru.md) — **полное описание общего интерфейса и обязательный контракт разработки**.
- [`Remove-Paths/README.ru.md`](Remove-Paths/README.ru.md) — запуск, поведение и ограничения Remove-Paths.
- [`Repair-Windows/README.ru.md`](Repair-Windows/README.ru.md) — запуск и ограничения Repair-Windows.
- [`README.md`](README.md) — обзор на английском языке.

Лицензия проекта — [MIT](LICENSE).
