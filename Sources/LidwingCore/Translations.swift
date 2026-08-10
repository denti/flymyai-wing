import Foundation

/// Translations, as data in the portable module rather than as `.lproj` resources.
///
/// The conventional place for these is a localised resource bundle. That is not used here for
/// one specific reason: this product assembles its own `.app` with `lipo` and `cp`, and a
/// SwiftPM resource bundle would have to be copied by a step in `build.sh` that nobody would
/// notice was missing. Translations that silently vanish from a shipped build are worse than
/// translations that do not exist, because the English fallback looks deliberate.
///
/// As data they are unit-tested on Linux, they cannot be dropped by the packaging step, and a
/// missing key is a compile-time-visible gap rather than a blank menu row.
public enum Translations {

    /// Language code to key-value map. Region variants fall back to the base language.
    public static let catalogues: [String: [String: String]] = [
        "ru": russian
    ]

    /// Picks the best catalogue for a list of preferred languages, or nil for English.
    ///
    /// Matches on the base language, so `ru-RU`, `ru_RU` and `ru` all find the Russian one.
    public static func catalogue(for preferredLanguages: [String]) -> [String: String]? {
        for language in preferredLanguages {
            let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
                .map(String.init) ?? language
            if let found = catalogues[base.lowercased()] { return found }
        }
        return nil
    }

    /// A localiser suitable for `Strings.localiser`.
    public static func localiser(for preferredLanguages: [String])
        -> (String, String) -> String {
        guard let catalogue = catalogue(for: preferredLanguages) else {
            return { _, fallback in fallback }
        }
        return { key, fallback in catalogue[key] ?? fallback }
    }

    // MARK: ru
    //
    // Written to be read aloud by a person who is not a power-management enthusiast. The
    // safety sentences keep their plainness: "выключится" rather than anything softer, because
    // the user needs to know the Mac will go to sleep and the run will stop.

    static let russian: [String: String] = [
        // Tooltips. Verb first and no ending period, like the English ones: they say what will
        // happen if you click, not what is already true.
        "tip.off": "Включите, чтобы Mac не засыпал с закрытой крышкой",
        "tip.on": "Не даёт этому Mac уснуть с закрытой крышкой",
        "tip.agent": "Не даёт этому Mac уснуть - работает %1$@",
        "tip.degraded": "Не даёт этому Mac уснуть - нажмите, есть предупреждение",
        "tip.nolid": "Крышку можно закрывать свободно - у этого Mac её нет",
        "tip.repair": "Нажмите, чтобы снять то, что не даёт Mac уснуть",
        "tip.failed": "Нажмите за подробностями - защиты сейчас нет",
        "tip.foreign": "Другое приложение уже не даёт этому Mac уснуть",
        "tip.arming": "Проверяем, что настройка крышки сработала",
        "tip.disarming": "Возвращаем обычный сон",
        "tip.slept": "Нажмите за подробностями - Mac уснул во время защиты",

        "notify.osRechecked.title": "macOS обновилась, Lidwing по-прежнему работает",
        "notify.osRechecked.body": "Только что проверено на %1$@, а не предположено.",

        "settings.sound.play": "Проиграть звук закрытия крышки",
        "settings.sound.play.detail": "Проиграет сейчас, даже если звук выше выключен.",
        "settings.sound.missing": "На этом Mac нет звуков, которые использует Lidwing (%1$@). "
            + "Подтверждения при закрытии крышки не будет слышно.",

        "uninstall.step.login": "Убрать запуск при входе.",
        "settings.startup": "Запуск",
        "settings.login": "Запускать Lidwing при входе",
        "settings.login.detail": "Lidwing будет запускаться вместе с Mac. "
            + "И всё равно ничего не делает, пока вы его не включите.",
        "login.unavailable": "Для запуска при входе нужна macOS 13 или новее.",
        "login.approval": "Ждём вашего подтверждения в «Системных настройках», "
            + "в разделе «Основные \u{25B8} Объекты входа».",
        "login.notFound": "macOS потеряла эту запись. Включите ещё раз, чтобы починить.",
        "login.failed": "macOS не дала это изменить: %1$@",

        "hardware.untested": "Lidwing не проверяли на этом Mac. "
            + "Он сам скажет, если не сможет сделать свою работу.",
        "hardware.partial": "Коротко проверено на таком Mac, но не на полном прогоне.",

        "menu.toggle": "Не спать с закрытой крышкой",
        "menu.off": "Выключено - Mac засыпает как обычно",
        "menu.awake": "Не спит - можно закрывать крышку",
        "menu.awake.agent": "Не спит - работает %1$@",
        "menu.hot": "Не спит - Mac сильно греется",
        "menu.hot.detail": "Если станет горячее, Lidwing выключится.",
        "menu.battery": "Не спит - батарея %1$lld%%",
        "menu.battery.detail": "Lidwing выключится на %1$lld%%.",
        "menu.arming": "Проверяю, что получилось\u{2026}",
        "menu.arming.detail": "Lidwing не скажет «включено», пока Mac не подтвердит.",
        "menu.disarming": "Возвращаю настройку сна\u{2026}",
        "menu.failed": "Mac уснул в %1$@, несмотря на защиту",
        "menu.slept": "Mac уснул в %1$@",
        "menu.slept.detail": "Защита снова включена. Подробности в диагностике.",
        "menu.failed.noTime": "Lidwing не смог защитить этот Mac",
        "menu.failed.detail": "Откройте диагностику. Защита не работает.",
        "menu.foreign": "Другое приложение не даёт этому Mac уснуть",
        "menu.foreign.detail": "%1$@ (pid %2$lld) - Lidwing не вмешивается.",
        "menu.nolid": "У этого Mac нет крышки",
        "menu.nolid.detail": "Здесь нечему мешать: сна по закрытию крышки не бывает.",
        "menu.repair": "Что-то не даёт этому Mac уснуть",
        "menu.repair.detail": "Возможно, это осталось от Lidwing. Нажмите «Исправить».",
        "menu.repair.action": "Исправить сейчас\u{2026}",
        "menu.sleepNow": "Уснуть сейчас",
        "menu.diagnostics": "Скопировать диагностику",
        "menu.settings": "Настройки\u{2026}",
        "menu.uninstall": "Удалить Lidwing\u{2026}",
        "menu.about": "О программе Lidwing",
        "menu.quit": "Завершить Lidwing",
        "menu.agentWaiting": "%1$@ ждёт вас",

        "detail.left": "осталось %1$@",
        "detail.battery": "батарея %1$lld%%",
        "detail.pluggedIn": "от сети",
        "detail.onBattery": "от батареи",

        "refuse.noLid": "У этого Mac нет крышки, поэтому мешать нечему.",
        "refuse.unsupported": "В этой версии macOS сон работает иначе. Нужно обновить Lidwing.",
        "refuse.batteryLow": "Батарея уже на пределе, который вы задали. "
            + "Подключите питание и попробуйте снова.",
        "refuse.tooHot": "Сейчас Mac слишком горячий. Дайте ему остыть и попробуйте снова.",
        "refuse.foreign": "Этот Mac уже держит не дающим уснуть другое приложение: "
            + "%1$@ (pid %2$lld).",
        "refuse.externalDisplay": "macOS уже делает это сама, пока подключён внешний монитор "
            + "и питание.",
        "refuse.watchdog": "Lidwing не смог запустить сторожевой процесс, поэтому не будет "
            + "мешать Mac засыпать.",
        "refuse.notInApplications": "Сначала перенесите Lidwing в папку «Программы».",

        "notify.firstArm.title": "Lidwing работает",
        "notify.firstArm.body": "Ищите крыло в строке меню. Крышку можно закрывать.",
        "notify.stopped.title": "Lidwing выключился",
        "notify.armFailed.title": "Lidwing не смог удержать Mac от сна",
        "notify.armFailed.body": "Mac всё равно уснёт при закрытии крышки. "
            + "Откройте Lidwing, чтобы посмотреть детали.",
        "notify.releaseFailed.title": "Lidwing не смог вернуть настройку сна",
        "notify.releaseFailed.body": "Откройте Lidwing и нажмите «Исправить», "
            + "либо перезагрузите Mac.",
        "notify.slept.title": "Mac уснул, несмотря на защиту",
        "notify.slept.body": "Lidwing включился снова. Точное время - в диагностике.",
        "notify.recovered.title": "Lidwing неожиданно завершился",
        "notify.recovered.body": "Сон по закрытию крышки восстановлен.",
        "notify.bag.title": "Не убирайте Mac в сумку, пока Lidwing включён",
        "notify.bag.body": "С закрытой крышкой и без притока воздуха он может сильно нагреться.",
        "notify.groundTruthLost.title": "Lidwing больше не защищает этот Mac",
        "notify.groundTruthLost.body": "Настройку сна изменило что-то ещё. "
            + "Откройте Lidwing, чтобы посмотреть детали.",
        "notify.hot.title": "Mac сильно греется",
        "notify.hot.body": "Если станет горячее, Lidwing выключится сам.",
        "notify.lowBattery.title": "Батарея на исходе",
        "notify.lowBattery.body": "Скоро Lidwing выключится и даст Mac уснуть как обычно.",

        "stopped.batteryFloor": "Остановлено на пороге батареи. Mac засыпает как обычно.",
        "stopped.thermal": "Mac слишком нагрелся. Lidwing выключился, чтобы дать ему остыть.",
        "stopped.timer": "Время вышло. Lidwing выключился.",
        "stopped.agentExited": "Агент закончил работу. Lidwing выключился.",
        "stopped.watchdogLost": "Lidwing потерял сторожевой процесс и выключился.",
        "stopped.unsupportedState": "Lidwing выключился: состояние Mac изменилось.",
        "stopped.failure": "Lidwing перестал защищать этот Mac. "
            + "Откройте его, чтобы посмотреть детали.",

        "agent.generic": "Ваш агент",
        "agent.waiting.body": "Ему нужен ответ, чтобы продолжить.",

        "settings.title": "Настройки Lidwing",
        "settings.when": "Когда не давать Mac уснуть",
        "settings.mode.manual": "Вручную",
        "settings.mode.auto": "Автоматически",
        "settings.mode.detail": "В автоматическом режиме Lidwing включается сам, пока работает "
            + "claude, codex или cursor-agent, и выключается через несколько минут после того, "
            + "как последний из них завершится.",
        "settings.limits": "Выключится сам",
        "settings.floor": "Выключиться, когда батарея дойдёт до",
        "settings.floor.detail": "Mac уснёт, а не разрядится в ноль.",
        "settings.duration": "Выключиться через",
        "settings.duration.detail": "Lidwing выключится сам через это время, даже если вы забудете.",
        "settings.duration.hours": "%1$lld ч",
        "settings.floor.custom": "%1$lld%% (своё значение)",
        "settings.duration.custom": "%1$lld ч (своё значение)",
        "settings.duration.none": "Без ограничения",
        "settings.thermal": "Выключиться, если Mac перегреется",
        "settings.thermal.detail": "Закрытая крышка мешает продуву. "
            + "Lidwing выключится до перегрева.",
        "settings.sound": "Звук",
        "settings.sound.lidClose": "Звук при закрытии крышки",
        "settings.sound.detail": "С закрытой крышкой экрана не видно, поэтому Lidwing "
            + "говорит об этом вслух.",
        "settings.agents": "Кодинг-агенты",
        "settings.agents.detail": "Lidwing может подать звук, когда агент ждёт вашего ответа - "
            + "чтобы вы услышали это с закрытой крышкой. Перед записью он покажет каждую строку.",
        "settings.agents.found": "%1$@ - найден в ~/%2$@",
        "settings.agents.missing": "%1$@ - не установлен",
        "settings.agents.show": "Показать, что будет записано\u{2026}",
        "settings.agents.remove": "Убрать",
        "settings.bagWarning": "\u{26A0}\u{FE0E} Не убирайте Mac в сумку, пока Lidwing включён.",
        "settings.noLimit.title": "Работать без ограничения по времени?",
        "settings.noLimit.body": "Ограничения по батарее и температуре останутся, так что "
            + "Lidwing всё равно выключится до разряда и до перегрева. Но он не выключится "
            + "просто потому, что прошло время, а забытый Lidwing - это как раз тот случай, "
            + "когда ноутбук нагревается в сумке.",
        "settings.noLimit.confirm": "Убрать ограничение",

        "button.ok": "ОК",
        "button.cancel": "Отмена",

        "uninstall.confirm.title": "Удалить Lidwing с этого Mac?",
        "uninstall.confirm.action": "Удалить Lidwing",
        "uninstall.willDo": "Lidwing сделает следующее:",
        "uninstall.willDelete": "Файлы, которые он удалит:",
        "uninstall.noSettings": "Системные настройки он не трогает: Lidwing ничего в них "
            + "и не писал.",
        "uninstall.checkWith": "Проверить после удаления можно так:",
        "uninstall.step.disarm": "Вернуть сон по закрытию крышки и убедиться, что он вернулся.",
        "uninstall.step.integrations": "Убрать свои записи из конфигов кодинг-агентов.",
        "uninstall.step.restore": "Вернуть в точности то, что он заменил.",
        "uninstall.step.watchdog": "Остановить и удалить фоновый процесс.",
        "uninstall.step.files": "Удалить свои файлы.",
        "uninstall.step.verify": "Проверить, что от Lidwing ничего не осталось.",
        "uninstall.step.reveal": "Показать Lidwing в Finder, чтобы вы перетащили его в Корзину.",
        "uninstall.done.title": "Lidwing удалён",
        "uninstall.done.body": "Перетащите Lidwing в Корзину, чтобы закончить.",
        "uninstall.failed.title": "Lidwing удалён не полностью",
        "uninstall.failed.body": "Если Mac по-прежнему не засыпает при закрытии крышки, "
            + "перезагрузите его: Lidwing не пишет ничего, что переживает перезагрузку.",

        "integration.absent.title": "%1$@ здесь не установлен",
        "integration.absent.body": "Lidwing искал ~/%1$@ и не нашёл. Он никогда не создаёт "
            + "файл настроек для инструмента, которого у вас нет.",
        "integration.unreadable.title": "Lidwing не станет менять настройки %1$@",
        "integration.unreadable.body": "Не удалось прочитать ~/%1$@ достаточно уверенно, чтобы "
            + "изменить только свою строку, поэтому он не изменил ничего.",
        "integration.already.title": "Уже настроено",
        "integration.already.body": "%1$@ уже запускает уведомитель Lidwing. Делать нечего.",
        "integration.offer.title": "Добавить Lidwing в %1$@?",
        "integration.offer.body": "Lidwing изменит ровно эти строки в ~/%1$@ и оставит рядом "
            + "копию файла с датой.",
        "integration.offer.chaining": "%1$@ уже что-то здесь запускает. Lidwing вызовет это "
            + "следом, а не заменит собой, так что оно продолжит работать:",
        "integration.offer.confirm": "Записать эти строки",
        "integration.done.title": "Готово",
        "integration.done.body": "%1$@ сообщит Lidwing, когда вы понадобитесь, а Lidwing подаст "
            + "звук, чтобы вы услышали это с закрытой крышкой.",
        "integration.writeFailed.title": "Lidwing не смог записать файл",
        "integration.removed.title": "Убрано",
        "integration.removed.body": "Записи Lidwing больше нет в ~/%1$@. Всё остальное в файле "
            + "осталось ровно как было.",
        "integration.nothing.title": "Убирать нечего",
        "integration.nothing.body": "Lidwing ничего не писал в ~/%1$@.",

        "dialog.didNotTurnOn.title": "Lidwing не включился",
        "dialog.repair.title": "Этот Mac настроен не засыпать при закрытии крышки",
        "dialog.repair.body": "Lidwing не выставлял это в текущем сеансе, поэтому ничего не "
            + "меняет без вашего согласия. Обычно так остаётся после прошлого запуска.",
        "dialog.repair.body2": "«Исправить» вернёт настройку к той, что macOS ставит по умолчанию.",
        "dialog.repair.confirm": "Исправить",
        "dialog.repair.decline": "Не трогать",
        "dialog.alreadyRunning.title": "Lidwing уже работает",
        "dialog.alreadyRunning.body": "Ищите крыло в строке меню."
    ]
}
