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
        "stopped.failure": "Lidwing перестал защищать этот Mac. Откройте его, чтобы посмотреть детали."
    ]
}
