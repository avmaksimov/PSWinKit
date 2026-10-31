# Shared messages for Windows PowerShell 5.1 utilities.
# UTF-8 with BOM. Positional placeholders: {0}, {1}, ...
# Each utility owns its own section; Common and Host are shared.
@{
    Common = @{
        YesNo        = '(Y/N)'
        SummaryTitle = '--- Итог ---'
        InvalidYesNo = 'Нужно ввести Y или N. Выбора по умолчанию нет.'
        Completed    = 'Выполнено'
    }

    Host = @{
        RequestElevation = 'Запрашиваю права администратора...'
        ElevationFailed  = 'Не удалось получить права администратора после перезапуска.'
        StartFailed      = 'Ошибка запуска: {0}'
        PressAnyKey      = 'Нажмите любую клавишу для закрытия окна...'
        PressEnter       = 'Нажмите Enter'
    }

    RemovePaths = @{
        Title               = 'Удаление файлов и каталогов'
        PhaseStart          = 'Начало работы'
        PhaseEntry          = 'Ввод путей'
        PhaseValidation     = 'Проверка списка'
        PhaseConfirmation   = 'Ожидание подтверждения'
        PhaseDeletion       = 'Удаление'
        PhaseDone           = 'Готово'
        StatusInterrupted   = 'Прервано до завершения (возможно Ctrl+C)'
        StatusEmpty         = 'Список пуст, ничего не удалено'
        StatusNoValid       = 'Нет допустимых путей, ничего не удалено'
        StatusCancelled     = 'Отменено пользователем (N), ничего не удалено'
        StatusPartial       = 'Выполнено с ошибками'
        StatusError         = 'Ошибка выполнения'
        Intro               = 'Введите пути для удаления — по одному в строке.'
        Instructions        = 'Пустой Enter завершает ввод. До подтверждения ничего не удаляется.'
        Protection          = 'C:\Users и другие системные каталоги диска C защищены.'
        PathPrompt          = 'Путь'
        AbsolutePath        = 'Требуется абсолютный путь на локальном диске, например D:\Windows.'
        SubstBlocked        = 'Пути через SUBST-диски не поддерживаются.'
        ProtectedPath       = 'Защищённый системный путь.'
        UnsupportedName     = 'Короткие имена (8.3) и завершающие точки/пробелы не поддерживаются.'
        AncestorLink        = 'Промежуточный компонент является NTFS-ссылкой: {0}'
        PreviewTitle        = '--- Сводка перед удалением ---'
        PreviewDelete       = 'УДАЛИТЬ'
        PreviewLink         = 'ССЫЛКА'
        PreviewSkip         = 'ПРОПУЩЕНО'
        PreviewCounts       = 'В очереди: {0}; пропущено: {1}'
        Confirm             = 'Удалить перечисленное без корзины?'
        Removing            = 'Удаление: {0}'
        Deleted             = 'Удалено.'
        PartialWarning      = 'Часть объектов осталась. См. итоговую сводку.'
        FailedWarning       = 'Не удалось удалить: {0}'
        CantReadDirectory   = 'Невозможно прочитать каталог: {0}'
        LinkNotDeleted      = 'Ссылка не удалена; права её цели не изменялись.'
        AccessBlocked       = 'Изменение прав запрещено: {0}'
        TakeOwnershipFailed = 'Не удалось сменить владельца: {0}'
        InheritanceFailed   = 'Не удалось включить наследование: {0}'
        GrantFailed         = 'Не удалось назначить полный доступ: {0}'
        SummaryResult       = 'Результат: {0}'
        SummaryPhase        = 'Этап: {0}'
        SummaryInput        = 'Введено путей: {0}'
        SummaryTargets      = 'Целей в списке: {0}; пропущено при проверке: {1}'
        SummaryStarted      = 'Начато: {0}; удалено полностью: {1}; не удалено полностью: {2}'
        SummaryUnstarted    = 'Не начато: {0}'
        SummaryCurrent      = 'Прервано на объекте: {0}'
        SummaryObjects      = 'Объектов удалено: {0} (из них ссылок: {1})'
        SummaryPermissions  = 'Объектов с исправленными правами: {0}'
        SummaryErrors       = 'Зафиксировано ошибок: {0}'
        SummaryTruncated    = 'Показаны только первые 15 ошибок.'
    }

}
