import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// The settings window is a normal, activatable macOS window. It never becomes
// part of the borderless notch surface or the protected SkyLight lock overlay.
final class NotchSettingsSnapshot: ObservableObject {
    @Published var hoverHapticsEnabled = true
    @Published var audioCaptureEnabled = false
    @Published var spectrumTuning = SpectrumTuning.load()
    @Published var lockIslandEnabled = true
    @Published var launchAtLoginEnabled = false
    @Published var launchAtLoginNeedsApproval = false
    @Published var batterySummary = "Ожидание данных об аккумуляторе…"
    @Published var batteryExplanation = "Проверка состояния предупреждений…"
    @Published var clockStatus = "Часы: проверка подключения…"
    @Published var focusIslandEnabled = true
    @Published var focusStatus = "Проверка состояния фокусирования…"
    @Published var focusNeedsAccess = false
    // Sidebar selection. Kept here (not @State) for standalone swiftc builds.
    @Published var selectedSection = "island"
    // 3.14.0: the tile dashboard is the home screen; a tile opens its section.
    @Published var onHome = true
    // 3.5.1: settings search.
    @Published var searchQuery = ""
    @Published var searchHighlight: String?
    var highlightToken = UUID()
    @Published var updateStatus = "Проверка папки «Загрузки»…"
    @Published var updateAvailableVersion: String?
    @Published var updateInstalling = false
    // 3.20.0: what is new in the waiting version; the tour inside Settings.
    @Published var updateNotes: [String] = []
    @Published var onboardingVisible = false
    // 4.2.0: «own theme» editor.
    @Published var themeEditorOpen = false
    @Published var themeDraftName = ""
    @Published var themeDraftDark = true
    @Published var themeDraftColors: [Color] = [Color(red: 0.95, green: 0.35, blue: 0.45), Color(red: 0.45, green: 0.4, blue: 1.0),
                                                Color(red: 1.0, green: 0.7, blue: 0.25), Color(red: 0.2, green: 0.75, blue: 0.85)]
    @Published var themeDraftCount = 3
    @Published var customThemesVersion = 0
    @Published var mediaGesturesEnabled = true
    // 3.2.0 permissions overview.
    @Published var permAccessibility = false
    @Published var permFullDisk = false
    @Published var permDownloads = false
    @Published var signingPersistent = false
    @Published var signingDescription = "Проверка подписи…"
    @Published var diagnosticsMessage = ""
    // 3.3.0 laboratory
    @Published var labToggles: [String: Bool] = [:]
    @Published var clipboardHistory: [String] = []
    @Published var ejectableVolumes: [String] = []
    @Published var batteryTimeText = "Оценка недоступна"
    @Published var sleepTimerStatus = "Выключен"
    @Published var cleanupMessage = ""

    // Keep theme-animation state in the existing, long-lived settings model.
    // This avoids @State/SwiftUIMacros in standalone swiftc builds and keeps
    // the crossfade alive when SwiftUI rebuilds the value-type settings view.
    @Published var displayedTheme = NotchSettingsSnapshot.initialTheme()
    // 3.11.0: the user's own profiles and the «new profile» form.
    @Published var userProfiles = UserProfileStore.load()
    @Published var profileMessage = ""
    @Published var newProfileOpen = false
    @Published var newProfileName = ""
    @Published var newProfileSummary = ""
    // 3.10.0: hover in the glass sidebar (no @State in swiftc builds).
    @Published var hoveredSection: String?

    // 3.10.0: the new look follows the macOS theme by default. Switched once
    // to «Системная»; a later choice in «Оформление» is kept as before.
    static func initialTheme() -> String {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "settingsAppearanceSystemV3100") {
            defaults.set(true, forKey: "settingsAppearanceSystemV3100")
            defaults.set("system", forKey: "settingsAppearanceV323")
        }
        return defaults.string(forKey: "settingsAppearanceV323") ?? "system"
    }
    @Published var outgoingTheme: String?
    @Published var themeBlend = 1.0
    private var themeChangeToken = UUID()

    func transitionToTheme(_ theme: String) {
        guard theme != displayedTheme else { return }
        let token = UUID()
        themeChangeToken = token
        outgoingTheme = displayedTheme
        displayedTheme = theme
        themeBlend = 0.0

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.themeChangeToken == token else { return }
            withAnimation(.easeInOut(duration: 0.46)) {
                self.themeBlend = 1.0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { [weak self] in
            guard let self = self, self.themeChangeToken == token else { return }
            self.outgoingTheme = nil
        }
    }
}

struct NotchSettingsActions {
    let setHaptics: (Bool) -> Void
    let setAudioCapture: (Bool) -> Void
    let setSpectrumTuning: (SpectrumTuning) -> Void
    let setLockIsland: (Bool) -> Void
    let setLaunchAtLogin: (Bool) -> Void
    let useAutomaticWidth: () -> Void
    let setManualWidth: (CGFloat) -> Void
    let previewLowBattery: (Int) -> Void
    let previewCharging: () -> Void
    let previewAirPods: () -> Void
    let setFocusIsland: (Bool) -> Void
    let previewFocus: () -> Void
    let openFullDiskAccess: () -> Void
    let installUpdate: () -> Void
    let setMediaGestures: (Bool) -> Void
    let fixAccessibility: () -> Void
    let fixFullDisk: () -> Void
    let fixDownloads: () -> Void
    let recheckPermissions: () -> Void
    let relaunchApp: () -> Void
    let copyDiagnostics: () -> Void
    let setLab: (String, Bool) -> Void
    let setSleepTimer: (Int) -> Void
    let copyClipboardItem: (String) -> Void
    let clearClipboardHistory: () -> Void
    let ejectVolume: (String) -> Void
    let runCleanup: () -> Void
    let openDiagnostics: () -> Void
    let checkForUpdates: () -> Void
    let openUpdateLog: () -> Void
    let previewLock: () -> Void
    let previewTimer: () -> Void
    let retryAudio: () -> Void
    let reloadArtwork: () -> Void
    let openArtworkLog: () -> Void
    let requestYandexArtworkAccess: () -> Void
    let openLockLog: () -> Void
    let openLoginItems: () -> Void
    let connectSpotify: () -> Void
    let setupYandexFavorites: () -> Void
    let openClock: () -> Void
    let openAccessibility: () -> Void
    let refreshClock: () -> Void
    let forceQuit: () -> Void
    let openClockLog: () -> Void
    let previewLockWidgets: () -> Void
    let resetLockWidgetsPosition: () -> Void
    let previewLockMedia: () -> Void
    let applyUserProfile: (String) -> Void
    let currentProfileValues: () -> [String: Bool]
    let applyProfile: (String) -> Void
    let showOnboarding: () -> Void
    let previewEyeBreak: () -> Void
    let previewStandBy: () -> Void
}

struct NotchSettingsWindowView: View {
    @ObservedObject var island: IslandState
    @ObservedObject var snapshot: NotchSettingsSnapshot
    @ObservedObject private var displayOptions = SystemDisplayOptions.shared
    @ObservedObject private var lockWidgets = LockWidgetsModel.shared
    @ObservedObject private var weather = WeatherService.shared

    private var glassSubtitle: String {
        if displayOptions.reduceTransparency { return "Не действует: включено «Уменьшить прозрачность»" }
        guard displayOptions.glassMode == "system" else { return "Своя прозрачность — ползунок ниже" }
        guard let tint = displayOptions.systemGlassTint else { return "Как в Оформлении macOS" }
        let percent = Int((tint * 100).rounded())
        return tint < 0.05 ? "Как в macOS: прозрачное стекло"
            : (tint > 0.95 ? "Как в macOS: тонированное стекло" : "Как в macOS: тонировка \(percent)%")
    }
    let actions: NotchSettingsActions
    @AppStorage("settingsAppearanceV323") private var settingsAppearance = "system"
    @Namespace private var sidebarSelection
    @AppStorage("lockScreenMediaV360") private var lockScreenMedia = true
    @AppStorage("lockCoverClockV372") private var lockCoverClock = true
    @AppStorage("lockCoverScaleV384") private var lockCoverScale = 0.55
    @AppStorage("lockCoverAnimatedV395") private var lockCoverAnimated = true
    // 3.13.0: flowing colours behind the settings window.
    @AppStorage("settingsAnimatedBackgroundV3130") private var settingsAnimatedBackground = true
    @AppStorage("energySaverModeV3164") private var energySaverMode = "battery"
    @AppStorage("waveArtworkV3180") private var waveArtwork = true
    @AppStorage("githubUpdatesV400") private var githubUpdates = true
    // 4.0.0
    @AppStorage(ExpandedPlayerStyle.key) private var playerStyle = "new"
    @AppStorage(IdleWings.enabledKey) private var wingsEnabled = true
    @AppStorage(IdleWings.leftKey) private var wingsLeft = "weather"
    @AppStorage(IdleWings.rightKey) private var wingsRight = "battery"
    @AppStorage(CinemaMode.key) private var cinemaEnabled = true
    @AppStorage(StandBySettings.enabledKey) private var standbyEnabled = true
    @AppStorage(StandBySettings.keepAwakeKey) private var standbyKeepAwake = true
    @AppStorage(StandBySettings.nightKey) private var standbyNight = true
    // 3.19.0: redraw when the cover's colours change («Обложка» theme).
    @ObservedObject private var coverPalette = CoverPalette.shared
    @AppStorage("lockCoverLayerV387") private var lockCoverLayer = 400
    @Environment(\.colorScheme) private var systemColorScheme

    private func colorScheme(for theme: String) -> ColorScheme {
        guard let dark = SettingsTheme.find(theme).dark else { return systemColorScheme }
        return dark ? .dark : .light
    }

    private var theme: SettingsTheme { SettingsTheme.find(snapshot.displayedTheme) }

    // 3.16.0: in a colour theme the tiles, banner and switches take the
    // theme's palette (each section its own shade); otherwise their own colour.
    private func accent(_ section: Section) -> Color {
        guard !theme.palette.isEmpty, let index = Section.allCases.firstIndex(of: section) else { return section.accent }
        return theme.palette[index % theme.palette.count]
    }

    private func selectTheme(_ value: String) {
        snapshot.transitionToTheme(value)
        settingsAppearance = value
    }
    private var fullscreenBinding: Binding<Bool> {
        Binding(get: { island.hideMediaDuringFullscreen },
                set: { island.setHideMediaDuringFullscreen($0) })
    }

    private var sourceInFrontBinding: Binding<Bool> {
        Binding(get: { island.hideMediaWhenSourceInFront },
                set: { island.setHideMediaWhenSourceInFront($0) })
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { Double(island.notchWidth) },
                set: { actions.setManualWidth(CGFloat($0)) })
    }
    private var autoWidthBinding: Binding<Bool> {
        Binding(get: { island.autoNotchSize }, set: { automatic in
            if automatic { actions.useAutomaticWidth() }
            else { actions.setManualWidth(island.notchWidth) }
        })
    }
    private var hapticsBinding: Binding<Bool> {
        Binding(get: { snapshot.hoverHapticsEnabled }, set: { actions.setHaptics($0) })
    }
    private var audioBinding: Binding<Bool> {
        Binding(get: { snapshot.audioCaptureEnabled }, set: { actions.setAudioCapture($0) })
    }
    private func spectrumBinding(_ key: WritableKeyPath<SpectrumTuning, Double>) -> Binding<Double> {
        Binding(get: { snapshot.spectrumTuning[keyPath: key] }, set: { newValue in
            var updated = snapshot.spectrumTuning
            updated[keyPath: key] = newValue
            actions.setSpectrumTuning(updated)
        })
    }

    private func spectrumSlider(_ title: String, description: String,
                                key: WritableKeyPath<SpectrumTuning, Double>,
                                range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.2f×", snapshot.spectrumTuning[keyPath: key]))
                    .monospacedDigit()
                    .font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: spectrumBinding(key), in: range)
                .disabled(!snapshot.audioCaptureEnabled)
            hint(description)
        }
    }

    private var lockBinding: Binding<Bool> {
        Binding(get: { snapshot.lockIslandEnabled }, set: { actions.setLockIsland($0) })
    }
    private var focusBinding: Binding<Bool> {
        Binding(get: { snapshot.focusIslandEnabled }, set: { actions.setFocusIsland($0) })
    }
    private var coverGlowBinding: Binding<Bool> {
        Binding(get: { island.coverGlowEnabled }, set: { island.setCoverGlowEnabled($0) })
    }
    private var gesturesBinding: Binding<Bool> {
        Binding(get: { snapshot.mediaGesturesEnabled }, set: { actions.setMediaGestures($0) })
    }
    private var loginBinding: Binding<Bool> {
        Binding(get: { snapshot.launchAtLoginEnabled }, set: { actions.setLaunchAtLogin($0) })
    }

    var body: some View {
        ZStack {
            if let outgoingTheme = snapshot.outgoingTheme {
                settingsLayout(themeID: outgoingTheme)
                    .environment(\.colorScheme, colorScheme(for: outgoingTheme))
                    .opacity(1 - snapshot.themeBlend)
                    .allowsHitTesting(false)
            }
            settingsLayout(themeID: snapshot.displayedTheme)
                .environment(\.colorScheme, colorScheme(for: snapshot.displayedTheme))
                .opacity(snapshot.themeBlend)
            // 3.20.0: the tour, right here on first opening (no extra window).
            if snapshot.onboardingVisible {
                OnboardingView(island: island, snapshot: snapshot, actions: actions, embedded: true,
                               onFinish: { _ in
                                   UserDefaults.standard.set(true, forKey: OnboardingView.doneKey)
                                   withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                                       snapshot.onboardingVisible = false
                                       snapshot.onHome = true
                                   }
                               })
                    .environment(\.colorScheme, colorScheme(for: snapshot.displayedTheme))
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: snapshot.onboardingVisible)
        // 3.16.0: the theme also sets the WINDOW's appearance. Before, only
        // SwiftUI's colour scheme changed: switches, sliders, text fields and
        // the glass stayed in the system theme («Тёмная»/«Светлая» looked broken).
        .background(WindowAppearanceSetter(dark: SettingsTheme.find(snapshot.displayedTheme).dark))
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // 3.13.0: switches, sliders and buttons take the colour of the section.
        .tint(accent(currentSection))
        .animation(.easeInOut(duration: 0.35), value: currentSection)
        .ignoresSafeArea()
    }

    static let windowSize = CGSize(width: 940, height: 680)

    // MARK: - Layout (3.10.0): Liquid Glass — the desktop shows through the
    // window, a floating glass sidebar, a hero header with a live island
    // preview, and glass cards for the groups.

    private enum Section: String, CaseIterable {
        case general, profiles, permissions, island, media, spectrum, lock, notifications, shelf, battery, focus, timer, calendar, airpods

        var title: String {
            switch self {
            case .general: return "Основные"
            case .profiles: return "Профили"
            case .permissions: return "Разрешения"
            case .island: return "Островок"
            case .media: return "Медиаплеер"
            case .spectrum: return "Спектрограмма"
            case .lock: return "Экран блокировки"
            case .battery: return "Батарея"
            case .focus: return "Фокусирование"
            case .timer: return "Таймер «Часов»"
            case .airpods: return "AirPods"
            case .notifications: return "Уведомления"
            case .shelf: return "Полка"
            case .calendar: return "Календарь"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .profiles: return "square.stack.3d.up.fill"
            case .permissions: return "checkmark.shield.fill"
            case .island: return "macbook"
            case .media: return "play.fill"
            case .spectrum: return "waveform"
            case .lock: return "lock.fill"
            case .battery: return "battery.75percent"
            case .focus: return "moon.fill"
            case .timer: return "timer"
            case .airpods: return "airpodspro"
            case .notifications: return "bell.badge.fill"
            case .shelf: return "tray.full.fill"
            case .calendar: return "calendar"
            }
        }
        var color: Color {
            switch self {
            case .general: return Color(red: 0.55, green: 0.56, blue: 0.60)
            case .permissions: return Color(red: 0.18, green: 0.66, blue: 0.42)
            case .profiles: return Color(red: 0.36, green: 0.35, blue: 0.90)
            case .island: return Color(red: 0.20, green: 0.48, blue: 1.0)
            case .media: return Color(red: 1.0, green: 0.27, blue: 0.40)
            case .spectrum: return Color(red: 0.66, green: 0.36, blue: 0.95)
            case .lock: return Color(red: 0.36, green: 0.38, blue: 0.45)
            case .battery: return Color(red: 0.20, green: 0.75, blue: 0.35)
            case .focus: return Color(red: 0.36, green: 0.35, blue: 0.90)
            case .timer: return Color(red: 1.0, green: 0.58, blue: 0.0)
            case .airpods: return Color(red: 0.20, green: 0.68, blue: 0.85)
            case .notifications: return Color(red: 1.0, green: 0.27, blue: 0.23)
            case .shelf: return Color(red: 0.04, green: 0.52, blue: 1.0)
            case .calendar: return Color(red: 1.0, green: 0.42, blue: 0.20)
            }
        }
        // One line under the big title.
        var subtitle: String {
            switch self {
            case .general: return "Оформление, обновления и запуск"
            case .profiles: return "Готовые наборы функций одним нажатием"
            case .permissions: return "Что Notch Island может делать в macOS"
            case .island: return "Размер, отклик и поведение островка"
            case .media: return "Сейчас играет, обложки и жесты"
            case .spectrum: return "Как музыка оживляет волну"
            case .lock: return "Плеер, обложка и виджеты на экране блокировки"
            case .battery: return "Зарядка и предупреждения о заряде"
            case .focus: return "Баннер при смене режима"
            case .timer: return "Таймер из приложения «Часы»"
            case .airpods: return "Заряд наушников и кейса"
            case .notifications: return "Системные баннеры в островке"
            case .shelf: return "Файлы, AirDrop и снимки экрана"
            case .calendar: return "Встречи и напоминания"
            }
        }
        // Bright colour for switches and the selection; grey sections get blue.
        var accent: Color {
            switch self {
            case .general, .lock: return Color(red: 0.24, green: 0.52, blue: 1.0)
            default: return color
            }
        }
        var group: Int {
            switch self {
            case .general, .profiles, .permissions: return 0
            case .island, .media, .spectrum, .lock: return 1
            case .notifications, .shelf: return 1
            case .battery, .focus, .timer, .calendar, .airpods: return 2
            }
        }
    }

    private var currentSection: Section {
        Section(rawValue: snapshot.selectedSection) ?? .island
    }

    // 3.14.0: tile dashboard. A top bar (title or «back», search, the live
    // island), then either the home grid of bright tiles or one section.
    private func settingsLayout(themeID: String) -> some View {
        let look = SettingsTheme.find(themeID)
        let scheme = colorScheme(for: themeID)
        return ZStack {
            SettingsGlassBackground(dark: scheme == .dark)
            // 3.16.0: a colour theme paints its own gradient over the glass.
            if !look.background.isEmpty {
                LinearGradient(colors: look.background, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.92)
                    .allowsHitTesting(false)
            }
            SettingsAuroraBackground(primary: look.palette.first.map { snapshot.onHome ? $0 : accent(currentSection) }
                                        ?? (snapshot.onHome ? Color(red: 0.36, green: 0.35, blue: 0.90) : accent(currentSection)),
                                     secondary: look.palette.count > 1 ? look.palette[1] : island.musicArtworkTint,
                                     artwork: look.background.isEmpty ? island.musicArtwork : nil,
                                     animated: settingsAnimatedBackground,
                                     dark: scheme == .dark)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                ZStack {
                    if snapshot.onHome {
                        homeView
                            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)),
                                                    removal: .opacity.combined(with: .scale(scale: 1.03))))
                    } else {
                        detail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func goHome() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            snapshot.onHome = true
            snapshot.searchHighlight = nil
        }
    }

    private func open(_ section: Section) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            snapshot.selectedSection = section.rawValue
            snapshot.onHome = false
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            // Room for the traffic-light buttons of the transparent title bar.
            Spacer().frame(width: 64)
            if snapshot.onHome {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Notch Island").font(.system(size: 15, weight: .heavy, design: .rounded))
                    Text("Версия \(Self.appVersion)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                Button { goHome() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Все настройки").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(accent(currentSection).gradient))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.8))
                    .shadow(color: accent(currentSection).opacity(0.4), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(snapshot.newProfileOpen ? nil : KeyboardShortcut(.escape, modifiers: []))
                .help("Назад ко всем настройкам (Esc)")
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer(minLength: 12)
            searchField
                .frame(width: 230)
                .onChange(of: snapshot.searchQuery) { _, query in
                    // Results are shown on the home screen.
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty && !snapshot.onHome { goHome() }
                }
            SettingsIslandPreview(island: island)
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .frame(height: 58)
    }

    // MARK: Home — the tiles

    // 3.15.0: a stage with the island on top — it acts out what the tile
    // under the pointer does — and a bento grid of tilting tiles below.
    private var homeView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if !snapshot.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        tileHeader("Найдено")
                        searchResults
                            .padding(8)
                            .settingsCard(cornerRadius: 18)
                    }
                } else {
                    if snapshot.updateAvailableVersion != nil || snapshot.updateInstalling {
                        updateBanner
                            .transition(.move(edge: .top).combined(with: .opacity))
                        if !snapshot.updateNotes.isEmpty && !snapshot.updateInstalling {
                            updateNotesCard
                                .transition(.opacity)
                        }
                    }
                    IslandStage(island: island,
                                demo: Section(rawValue: snapshot.hoveredSection ?? "").map(Self.demo(for:)),
                                accent: Section(rawValue: snapshot.hoveredSection ?? "").map { accent($0) } ?? theme.palette.first)
                    Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                        GridRow {
                            nowPlayingTile.gridCellColumns(2)
                            sectionTile(.profiles)
                            sectionTile(.general)
                        }
                        GridRow {
                            sectionTile(.island); sectionTile(.media); sectionTile(.spectrum); sectionTile(.lock)
                        }
                        GridRow {
                            sectionTile(.notifications); sectionTile(.shelf); sectionTile(.calendar); sectionTile(.permissions)
                        }
                        GridRow {
                            sectionTile(.battery); sectionTile(.airpods); sectionTile(.focus); sectionTile(.timer)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 26)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: snapshot.updateAvailableVersion)
            .animation(.easeInOut(duration: 0.3), value: snapshot.updateNotes)
        }
    }

    // 3.20.0: what the waiting version brings, right under its banner.
    private var updateNotesCard: some View {
        let colors = theme.palette.count >= 2 ? (theme.palette[0], theme.palette[1]) : SettingsTheme.updateColors
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(LinearGradient(colors: [colors.0, colors.1], startPoint: .leading, endPoint: .trailing))
                Text("Что нового в \(snapshot.updateAvailableVersion ?? "новой версии")")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
            }
            ForEach(Array(snapshot.updateNotes.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
                        .frame(width: 6, height: 6)
                        .offset(y: -1)
                    Text(item)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard(cornerRadius: 20, tint: colors.0)
    }

    // 3.16.1: a new version waiting in Downloads — right on the home screen.
    private var updateBanner: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        // 3.18.2: the theme's colours, as the banner in the island.
        let colors = theme.palette.count >= 2 ? (theme.palette[0], theme.palette[1]) : SettingsTheme.updateColors
        let green = colors.0
        let teal = colors.1
        let version = snapshot.updateAvailableVersion ?? ""
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.white.opacity(0.22))
                if snapshot.updateInstalling {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating)
                }
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.updateInstalling ? "Устанавливаю обновление…" : "Доступна версия \(version)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                Text(snapshot.updateInstalling
                     ? "Около минуты. Notch Island закроется и откроется сам."
                     : "Архив уже в «Загрузках». Установка около минуты, приложение откроется само; настройки и разрешения сохранятся.")
                    .font(.system(size: 11.5, weight: .medium))
                    .opacity(0.88)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if !snapshot.updateInstalling {
                Button { open(.general) } label: { Text("Подробнее") }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.85)
                Button { actions.installUpdate() } label: {
                    Text("Обновить")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(green)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule(style: .continuous).fill(Color.white))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help("Установить версию \(version)")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            ZStack {
                shape.fill(LinearGradient(colors: [green, teal], startPoint: .leading, endPoint: .trailing))
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        .shadow(color: green.opacity(0.4), radius: 12, y: 5)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: snapshot.updateInstalling)
    }

    private static func demo(for section: Section) -> IslandDemo {
        switch section {
        case .media, .spectrum: return .music
        case .battery: return .charging
        case .airpods: return .airpods
        case .focus: return .focus
        case .timer: return .timer
        case .shelf: return .airdrop
        case .lock: return .lock
        case .calendar: return .meeting
        case .notifications: return .eyes
        case .profiles: return .profile
        case .general, .island, .permissions: return .music
        }
    }

    private func tileHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func tileGroup(_ title: String, _ sections: [Section]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            tileHeader(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 186), spacing: 14)], spacing: 14) {
                ForEach(sections, id: \.self) { sectionTile($0) }
            }
        }
    }

    // A quick switch on the tile itself, for sections that have one.
    private func tileSwitch(_ section: Section) -> Binding<Bool>? {
        switch section {
        case .lock: return lockBinding
        case .focus: return focusBinding
        case .shelf: return labBinding("shelf")
        case .spectrum: return audioBinding
        case .calendar: return labBinding("calendar")
        default: return nil
        }
    }

    private func tileStatus(_ section: Section) -> String {
        switch section {
        case .general: return "Тема, обновления, запуск"
        case .profiles:
            if let id = UserProfileStore.match(profileValues, in: snapshot.userProfiles),
               let name = snapshot.userProfiles.first(where: { $0.id == id })?.name { return "Сейчас: \(name)" }
            switch IslandProfiles.match(profileValues) {
            case .iphone: return "Сейчас: Как на iPhone"
            case .extended: return "Сейчас: Максимум"
            case .custom: return "Сейчас: Свой"
            }
        case .permissions:
            let missing = [snapshot.permAccessibility, snapshot.permFullDisk, snapshot.permDownloads].filter { !$0 }.count
            return missing == 0 ? "Всё разрешено" : "Не хватает: \(missing)"
        case .island: return island.autoNotchSize ? "Размер по чёлке" : "Ширина \(Int(island.notchWidth)) pt"
        case .media: return island.track.map { "♫ \($0.title)" } ?? "Сейчас ничего не играет"
        case .spectrum: return snapshot.audioCaptureEnabled ? "Живой звук" : "Плавная волна без захвата"
        case .lock: return lockWidgets.enabled ? "Плеер, обложка, виджеты: \(lockWidgets.selected.count)" : "Плеер и обложка"
        case .battery: return snapshot.batterySummary
        case .focus: return snapshot.focusStatus
        case .timer: return "Из приложения «Часы»"
        case .calendar: return "Встречи и напоминания"
        case .airpods: return "Заряд наушников и кейса"
        case .notifications: return "Системные баннеры"
        case .shelf: return "Файлы, AirDrop, снимки"
        }
    }

    private func sectionTile(_ section: Section) -> some View {
        DashboardTile(title: section.title, icon: section.icon, status: tileStatus(section),
                      color: accent(section), toggle: tileSwitch(section),
                      onTap: { open(section) },
                      onHover: { inside in
                          if inside { snapshot.hoveredSection = section.rawValue }
                          else if snapshot.hoveredSection == section.rawValue { snapshot.hoveredSection = nil }
                      })
    }

    // Wide tile: what plays right now, on its own blurred cover.
    private var nowPlayingTile: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let tint = island.musicArtworkTint
        return HStack(spacing: 14) {
            Group {
                if let artwork = island.musicArtwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.18))
                        Image(systemName: "music.note").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(island.track == nil ? "ТИШИНА" : (island.track?.isPlaying == true ? "СЕЙЧАС ИГРАЕТ" : "НА ПАУЗЕ"))
                    .font(.system(size: 10, weight: .heavy)).kerning(0.8)
                    .foregroundStyle(.white.opacity(0.7))
                Text(island.track?.title ?? "Островок ждёт музыку")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(island.track?.artist ?? "Включи что-нибудь — плеер появится в чёлке")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124)
        .background {
            ZStack {
                shape.fill(LinearGradient(colors: [tint.opacity(0.95), Color.black.opacity(0.75)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                if let artwork = island.musicArtwork {
                    // 3.15.1: sized to the tile — a free-sized blurred cover
                    // spread far outside it (the grey sheet over the stage).
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                        .blur(radius: 30)
                        .opacity(0.55)
                }
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
        .shadow(color: tint.opacity(0.4), radius: 12, y: 5)
        .contentShape(shape)
        .onTapGesture { open(.media) }
        .onHover { inside in
            if inside { snapshot.hoveredSection = Section.media.rawValue }
            else if snapshot.hoveredSection == Section.media.rawValue { snapshot.hoveredSection = nil }
        }
        .help("Открыть «Медиаплеер»")
    }

    // The active profile, one click to change it.
    private var profileTile: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let color = accent(.profiles)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 16, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).opacity(0.7)
            }
            Spacer(minLength: 0)
            Text("ПРОФИЛЬ").font(.system(size: 10, weight: .heavy)).kerning(0.8).opacity(0.7)
            Text(tileStatus(.profiles).replacingOccurrences(of: "Сейчас: ", with: ""))
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 210, height: 116)
        .background {
            ZStack {
                shape.fill(LinearGradient(colors: [color, Color(red: 0.66, green: 0.36, blue: 0.95)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
        .shadow(color: color.opacity(0.4), radius: 12, y: 5)
        .contentShape(shape)
        .onTapGesture { open(.profiles) }
        .help("Открыть «Профили»")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic-light buttons of the transparent title bar.
            Spacer().frame(height: 30)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notch Island").font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Версия \(Self.appVersion)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                if snapshot.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Section.allCases, id: \.self) { section in
                            if section != Section.allCases.first && section.group != previousGroup(of: section) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                    .frame(height: 1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                            }
                            sidebarItem(section)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                } else {
                    searchResults
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .settingsGlass(cornerRadius: 22, prominent: true)
    }

    private func previousGroup(of section: Section) -> Int {
        let all = Section.allCases
        guard let index = all.firstIndex(of: section), index > 0 else { return section.group }
        return all[index - 1].group
    }

    private func sidebarItem(_ section: Section) -> some View {
        let selected = section == currentSection
        let hovered = snapshot.hoveredSection == section.rawValue
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                snapshot.selectedSection = section.rawValue
            }
        } label: {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: section.icon, color: section.color, size: 24)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    // 3.13.0: a bright glossy pill in the section's colour.
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [accent(section).opacity(0.95), accent(section).opacity(0.72)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                                 startPoint: .top, endPoint: .center)))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8))
                        .shadow(color: accent(section).opacity(0.45), radius: 8, y: 3)
                        .matchedGeometryEffect(id: "selection", in: sidebarSelection)
                } else if hovered {
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { snapshot.hoveredSection = section.rawValue }
            else if snapshot.hoveredSection == section.rawValue { snapshot.hoveredSection = nil }
        }
    }

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    sectionContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 4)
                .padding(.bottom, 30)
            }
            .onAppear { scrollToHighlight(proxy) }
            .onChange(of: snapshot.searchHighlight) { _, _ in scrollToHighlight(proxy) }
        }
        .id(currentSection.rawValue)
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94)),
                                removal: .opacity.combined(with: .scale(scale: 0.94))))
    }

    // Big icon, title and one line — and the island itself, live, on the right.
    // 3.13.0: a bright banner in the section's colour — glossy top, a
    // glowing icon, the title, and the live island on the right.
    private var hero: some View {
        let color = accent(currentSection)
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return HStack(alignment: .center, spacing: 18) {
            SettingsIconTile(symbol: currentSection.icon, color: theme.palette.isEmpty ? currentSection.color : color, size: 60)
                .shadow(color: color.opacity(0.6), radius: 16, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(currentSection.title)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(currentSection.subtitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background {
            ZStack {
                shape.fill(LinearGradient(colors: [color.opacity(0.92), color.opacity(0.55)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                // A second colour from the cover, for depth.
                shape.fill(RadialGradient(colors: [island.musicArtworkTint.opacity(0.55), .clear],
                                          center: .bottomTrailing, startRadius: 4, endRadius: 320))
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.30), .clear],
                                          startPoint: .top, endPoint: .center))
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        .shadow(color: color.opacity(0.35), radius: 18, y: 8)
        .padding(.bottom, 4)
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy) {
        guard let title = snapshot.searchHighlight else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("search:" + title, anchor: .center)
            }
        }
    }

    // MARK: Search (3.5.1)

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Поиск", text: $snapshot.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit {
                    if let first = SettingsSearch.search(snapshot.searchQuery).first { openSearchResult(first) }
                }
            if !snapshot.searchQuery.isEmpty {
                Button {
                    snapshot.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Очистить поиск")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsSearch.search(snapshot.searchQuery)
        if results.isEmpty {
            Text("Ничего не найдено")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 18)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, entry in
                    searchResultItem(entry)
                }
            }
        }
    }

    private func searchResultItem(_ entry: SettingsSearchEntry) -> some View {
        let section = Section(rawValue: entry.section) ?? .general
        let selected = snapshot.searchHighlight == entry.title && currentSection == section
        return Button {
            openSearchResult(entry)
        } label: {
            HStack(spacing: 9) {
                SettingsIconTile(symbol: section.icon, color: section.color, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(entry.sectionTitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? section.color.opacity(0.22) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSearchResult(_ entry: SettingsSearchEntry) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            snapshot.selectedSection = entry.section
            snapshot.onHome = false
        }
        snapshot.searchHighlight = entry.title
        let token = UUID()
        snapshot.highlightToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard snapshot.highlightToken == token else { return }
            withAnimation(.easeOut(duration: 0.5)) { snapshot.searchHighlight = nil }
        }
    }

    // Soft accent behind the row/group the search pointed to.
    private func searchMark(_ title: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(snapshot.searchHighlight == title ? 0.22 : 0))
            .animation(.easeOut(duration: 0.3), value: snapshot.searchHighlight)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch currentSection {
        case .general: generalSection
        case .profiles: profilesSection
        case .permissions: permissionsSection
        case .island: islandSection
        case .media: mediaSection
        case .spectrum: spectrumSection
        case .lock: lockSection
        case .battery: batterySection
        case .focus: focusSection
        case .timer: timerSection
        case .airpods: airPodsSection
        case .notifications: notificationsSection
        case .shelf: shelfSection
        case .calendar: calendarSection
        }
    }

    // MARK: - Sections

    // MARK: Profiles (3.5.0)

    private var profileValues: [String: Bool] {
        var values = snapshot.labToggles
        values["lockIsland"] = snapshot.lockIslandEnabled
        values["focus"] = snapshot.focusIslandEnabled
        values["gestures"] = snapshot.mediaGesturesEnabled
        values["coverGlow"] = island.coverGlowEnabled
        values["hideFullscreen"] = island.hideMediaDuringFullscreen
        values["hideSource"] = island.hideMediaWhenSourceInFront
        values["lockMedia"] = lockScreenMedia
        values["lockWidgets"] = lockWidgets.enabled
        values["coverAnimated"] = lockCoverAnimated
        return values
    }

    private var profilesSection: some View {
        let current = profileValues
        let userActive = UserProfileStore.match(current, in: snapshot.userProfiles)
        let matched = IslandProfiles.match(current)
        // A user profile that matches wins over «Свой».
        let active: IslandProfile? = (userActive != nil && matched == .custom) ? nil : matched
        return VStack(alignment: .leading, spacing: 20) {
            hint("Профиль сразу включает нужный набор функций. Ширина, спектрограмма, тема и разрешения не меняются. Если потом переключить что-то вручную, профиль станет «Свой» — он запоминается и возвращается одним нажатием.")
                .padding(.horizontal, 4)
            VStack(spacing: 12) {
                profileCard(.iphone, active: active,
                            title: "Как на iPhone", icon: "iphone.gen3",
                            color: Color(red: 0.20, green: 0.48, blue: 1.0),
                            summary: "Только то, что умеет Dynamic Island и экран блокировки iPhone. Плеер прячется, когда открыто приложение с музыкой.",
                            features: ["Сейчас играет", "Зарядка", "AirPods", "Фокусирование",
                                       "Таймер", "Замочек", "Камера и микрофон", "AirDrop",
                                       "Плеер на экране блокировки", "Виджеты под часами", "Живой фон обложки"])
                profileCard(.extended, active: active,
                            title: "Максимум", icon: "sparkles",
                            color: Color(red: 0.66, green: 0.36, blue: 0.95),
                            summary: "Всё, что умеет Notch Island: полка, снимки и записи экрана, буфер обмена, системные баннеры, жесты и свечение.",
                            features: ["Всё из iPhone", "Полка", "AirDrop с полки", "Снимки экрана", "«Скопировано»",
                                       "Громкость", "Устройство вывода", "VPN и интернет", "Диски",
                                       "Нагрев", "Жесты", "Свечение", "⌃⌥N", "Календарь*"])
                profileCard(.custom, active: active,
                            title: "Свой", icon: "slider.horizontal.3",
                            color: Color(red: 1.0, green: 0.58, blue: 0.0),
                            summary: IslandProfiles.loadCustom() == nil && active != .custom
                                ? "Твой собственный набор. Появится, когда изменишь переключатели в разделах."
                                : "Твой собственный набор переключателей — запомнен при выборе другого профиля.",
                            features: [])
            }
            hint("* Встречи и напоминания включаются, только если macOS уже дала доступ к Календарю и Напоминаниям (раздел «Календарь»).")
                .padding(.horizontal, 4)
            userProfilesBlock(active: userActive)
        }
    }

    // MARK: 3.11.0 «Мои профили»

    private func userProfilesBlock(active: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("МОИ ПРОФИЛИ")
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .id("search:Мои профили")
                Spacer()
                Button { importProfiles() } label: { Label("Открыть файл…", systemImage: "square.and.arrow.down.on.square") }
                    .help("Добавить профиль из файла .notchprofile")
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        snapshot.newProfileName = ""
                        snapshot.newProfileSummary = ""
                        snapshot.newProfileOpen = true
                    }
                } label: { Label("Новый профиль", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(snapshot.newProfileOpen)
            }
            .controlSize(.small)

            if snapshot.newProfileOpen {
                newProfileForm
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if snapshot.userProfiles.isEmpty && !snapshot.newProfileOpen {
                VStack(spacing: 6) {
                    Image(systemName: "person.crop.rectangle.stack")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Своих профилей пока нет")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Настрой переключатели в разделах как нравится, затем нажми «Новый профиль» — он запомнит их под твоим названием. Профиль можно отправить другу по AirDrop или файлом.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(18)
                .settingsCard(cornerRadius: 18)
            }

            ForEach(snapshot.userProfiles) { profile in
                userProfileCard(profile, selected: profile.id == active)
            }

            if !snapshot.profileMessage.isEmpty {
                hint(snapshot.profileMessage).padding(.horizontal, 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: snapshot.userProfiles)
    }

    private var newProfileForm: some View {
        let count = actions.currentProfileValues().values.filter { $0 }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: "person.crop.square.fill", color: Color(red: 0.18, green: 0.66, blue: 0.62), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Новый профиль").font(.system(size: 13.5, weight: .semibold))
                    Text("Сохранит текущие переключатели — сейчас включено \(count)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            TextField("Название, например «Работа»", text: $snapshot.newProfileName)
                .textFieldStyle(.roundedBorder)
            TextField("Описание (необязательно): что он включает и когда нужен", text: $snapshot.newProfileSummary, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            HStack {
                Spacer()
                Button("Отмена") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { snapshot.newProfileOpen = false }
                }
                .keyboardShortcut(.cancelAction)
                Button("Создать") { createProfile() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .padding(16)
        .settingsCard(cornerRadius: 18, tint: Color(red: 0.18, green: 0.66, blue: 0.62))
    }

    private func userProfileCard(_ profile: UserIslandProfile, selected: Bool) -> some View {
        let color = Color(red: 0.18, green: 0.66, blue: 0.62)
        return HStack(alignment: .top, spacing: 14) {
            SettingsIconTile(symbol: "person.crop.square.fill", color: color, size: 42)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    Spacer(minLength: 4)
                    Button { airDropProfile(profile) } label: { Image(systemName: "paperplane") }
                        .help("Отправить по AirDrop")
                    Button { exportProfile(profile) } label: { Image(systemName: "square.and.arrow.up") }
                        .help("Сохранить в файл, чтобы передать")
                    Button { deleteProfile(profile) } label: { Image(systemName: "trash") }
                        .help("Удалить профиль")
                }
                .buttonStyle(.borderless)
                if !profile.summary.isEmpty {
                    Text(profile.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ProfileChips(items: profileChipTitles(profile))
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard(cornerRadius: 18, tint: selected ? color : nil)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(selected ? color.opacity(0.9) : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                actions.applyUserProfile(profile.id)
            }
            snapshot.profileMessage = "Включён профиль «\(profile.name)»"
        }
        .help("Нажми, чтобы включить этот профиль")
    }

    // Short names of what the profile switches on.
    private func profileChipTitles(_ profile: UserIslandProfile) -> [String] {
        let names: [String: String] = [
            "volume": "Громкость", "output": "Вывод звука", "privacy": "Камера и микрофон", "vpn": "VPN",
            "network": "Интернет", "thermal": "Нагрев", "disks": "Диски", "clipboard": "«Скопировано»",
            "screenshots": "Снимки экрана", "shelf": "Полка", "calendar": "Встречи", "reminders": "Напоминания",
            "hotkey": "⌃⌥N", "airdrop": "AirDrop", "lockIsland": "Замочек", "focus": "Фокусирование",
            "gestures": "Жесты", "coverGlow": "Свечение", "hideFullscreen": "Прятать в полноэкранном",
            "hideSource": "Прятать при открытом плеере", "lockMedia": "Плеер на экране блокировки",
            "lockWidgets": "Виджеты под часами", "coverAnimated": "Живой фон обложки"
        ]
        let on = IslandProfiles.allKeys.filter { profile.values[$0] == true }.compactMap { names[$0] }
        return on.isEmpty ? ["Всё выключено"] : on
    }

    private func createProfile() {
        var list = snapshot.userProfiles
        var profile = UserProfileStore.make(name: snapshot.newProfileName, summary: snapshot.newProfileSummary,
                                            values: actions.currentProfileValues())
        profile.name = UserProfileStore.uniqueName(profile.name, among: list)
        list.append(profile)
        UserProfileStore.save(list)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            snapshot.userProfiles = list
            snapshot.newProfileOpen = false
        }
        snapshot.profileMessage = "Профиль «\(profile.name)» создан"
    }

    private func deleteProfile(_ profile: UserIslandProfile) {
        let alert = NSAlert()
        alert.messageText = "Удалить профиль «\(profile.name)»?"
        alert.informativeText = "Настройки не изменятся — удалится только сам профиль."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let list = snapshot.userProfiles.filter { $0.id != profile.id }
        UserProfileStore.save(list)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { snapshot.userProfiles = list }
        snapshot.profileMessage = "Профиль «\(profile.name)» удалён"
    }

    private static var profileType: UTType {
        UTType(filenameExtension: UserProfileStore.fileExtension) ?? .json
    }

    private func exportProfile(_ profile: UserIslandProfile) {
        guard let data = UserProfileStore.exportData(profile) else { return }
        let panel = NSSavePanel()
        panel.title = "Сохранить профиль"
        panel.nameFieldStringValue = UserProfileStore.fileName(for: profile)
        panel.allowedContentTypes = [Self.profileType]
        panel.canCreateDirectories = true
        let snapshot = self.snapshot
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                snapshot.profileMessage = "Сохранено: \(url.lastPathComponent). Открой этот файл на другом Mac — профиль добавится сам."
            } catch {
                snapshot.profileMessage = "Не удалось сохранить: \(error.localizedDescription)"
            }
        }
    }

    private func airDropProfile(_ profile: UserIslandProfile) {
        guard let data = UserProfileStore.exportData(profile) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchIslandProfiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UserProfileStore.fileName(for: profile))
        guard (try? data.write(to: url)) != nil else { return }
        if !AirDropSender.shared.send([url]) {
            snapshot.profileMessage = "AirDrop недоступен — сохрани профиль в файл и передай его как удобно."
        }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.title = "Открыть профиль"
        panel.allowedContentTypes = [Self.profileType, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let snapshot = self.snapshot
        panel.begin { response in
            guard response == .OK else { return }
            var list = UserProfileStore.load()
            var added: [String] = []
            var failed = 0
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url),
                      var profile = UserProfileStore.importProfile(from: data) else { failed += 1; continue }
                profile.name = UserProfileStore.uniqueName(profile.name, among: list)
                list.append(profile)
                added.append(profile.name)
            }
            UserProfileStore.save(list)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { snapshot.userProfiles = list }
            var message = added.isEmpty ? "" : (added.count == 1 ? "Добавлен профиль «\(added[0])»" : "Добавлено профилей: \(added.count)")
            if failed > 0 { message += (message.isEmpty ? "" : ". ") + "Не профиль Notch Island: \(failed)" }
            snapshot.profileMessage = message
        }
    }

    private func profileCard(_ profile: IslandProfile, active: IslandProfile?, title: String,
                             icon: String, color: Color, summary: String, features: [String]) -> some View {
        let selected = profile == active
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                actions.applyProfile(profile.rawValue)
            }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                SettingsIconTile(symbol: icon, color: color, size: 42)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !features.isEmpty {
                        ProfileChips(items: features)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard(cornerRadius: 18, tint: selected ? color : nil)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? color.opacity(0.9) : Color.clear, lineWidth: 1.5))
            .overlay(searchMark(title))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id("search:" + title)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Оформление", footer: "Тема меняет только это окно (и значок приложения: светлый или тёмный). Цветные темы перекрашивают фон, плитки, баннер и переключатели. «Обложка» берёт цвета из обложки играющей песни и плавно меняет их вместе с треком. Островки всегда чёрные, как на iPhone.") {
                // 3.16.0: three plain themes and colour themes.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(SettingsTheme.all) { item in themeSwatch(item) }
                    if !snapshot.themeEditorOpen { newThemeButton }
                }
                .padding(12)
                .id(snapshot.customThemesVersion)
                if snapshot.themeEditorOpen {
                    rowDivider
                    themeEditor
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                rowDivider
                toggleRow("Живой фон настроек",
                          subtitle: "Цвета раздела и обложки медленно переливаются за стеклом окна",
                          isOn: $settingsAnimatedBackground)
                rowDivider
                row("Энергосбережение", subtitle: "Волна плавная, но реже (15 кадров/с), живые фоны стоят. Меньше нагрузки и нагрева") {
                    Picker("", selection: $energySaverMode) {
                        Text("Выкл").tag("off")
                        Text("От батареи").tag("battery")
                        Text("Всегда").tag("always")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                rowDivider
                row("Знакомство с Notch Island", subtitle: "Короткий тур: что умеет островок, разрешения, профиль") {
                    Button("Показать") { actions.showOnboarding() }
                }
            }
            group("Обновление",
                  footer: "Новые версии Notch Island сам находит на GitHub (H1rka-afk/notch-island), скачивает готовую сборку в фоне и показывает «Обновить». Установка — несколько секунд, разрешения сохраняются. Архив, положенный в «Загрузки», тоже подхватывается, как раньше.") {
                toggleRow("Обновления с GitHub", subtitle: "Проверять раз в 3 часа и скачивать новую версию заранее", isOn: $githubUpdates)
                rowDivider
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: snapshot.updateAvailableVersion == nil
                          ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(snapshot.updateAvailableVersion == nil ? Color.green : Color.accentColor)
                    Text(snapshot.updateStatus)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if snapshot.updateInstalling {
                        ProgressView().controlSize(.small)
                    } else if let version = snapshot.updateAvailableVersion {
                        Button("Обновить до \(version)") { actions.installUpdate() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Проверить") { actions.checkForUpdates() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                rowDivider
                row("Журнал обновления") {
                    Button("Открыть") { actions.openUpdateLog() }
                }
            }
            group("Запуск") {
                toggleRow("Открывать при входе в macOS", isOn: loginBinding)
                if snapshot.launchAtLoginNeedsApproval {
                    rowDivider
                    row("macOS ждёт разрешения на автозапуск") {
                        Button("Открыть…") { actions.openLoginItems() }
                    }
                }
                rowDivider
                toggleRow("Тактильный отклик при наведении",
                          subtitle: "Лёгкий щелчок трекпада при открытии островка",
                          isOn: hapticsBinding)
            }
            group("Диагностика",
                  footer: snapshot.diagnosticsMessage.isEmpty
                    ? "Один файл с версией, подписью, разрешениями и последними записями всех журналов. Названия треков в него не попадают."
                    : snapshot.diagnosticsMessage) {
                row("Отчёт для разработчика") {
                    HStack(spacing: 6) {
                        Button("Скопировать") { actions.copyDiagnostics() }
                        Button("Открыть") { actions.openDiagnostics() }
                    }
                }
            }
            group("Управление") {
                toggleRow("Горячая клавиша ⌃⌥N", subtitle: "Открывает и закрывает островок", isOn: labBinding("hotkey"))
            }
            group("Уборка", footer: snapshot.cleanupMessage.isEmpty
                  ? "Старые архивы и папки Notch Island из «Загрузок» и тестовые файлы из ~/Library/Logs переносятся в Корзину."
                  : snapshot.cleanupMessage) {
                row("Старые версии и тестовые файлы") {
                    Button("Убрать в Корзину") { actions.runCleanup() }
                }
            }
            group("Приложение") {
                row("Завершить работу Notch Island", subtitle: "Сразу, без ожидания анимаций") {
                    Button("Выйти") { actions.forceQuit() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil, footer: "После включения разрешения нажми «Перезапустить» — некоторые разрешения macOS применяет только к заново открытому приложению.") {
                permissionRow("Универсальный доступ",
                              subtitle: "Таймер «Часов» и избранное Яндекс Музыки",
                              granted: snapshot.permAccessibility) { actions.fixAccessibility() }
                rowDivider
                permissionRow("Полный доступ к диску",
                              subtitle: "Режим фокусирования",
                              granted: snapshot.permFullDisk) { actions.fixFullDisk() }
                rowDivider
                permissionRow("Папка «Загрузки»",
                              subtitle: "Обновление в один клик",
                              granted: snapshot.permDownloads) { actions.fixDownloads() }
            }
            group("Подпись приложения") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: snapshot.signingPersistent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(snapshot.signingPersistent ? Color.green : Color.orange)
                        .font(.system(size: 15))
                    Text(snapshot.signingDescription)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            HStack {
                Button("Проверить снова") { actions.recheckPermissions() }
                Spacer()
                Button("Перезапустить Notch Island") { actions.relaunchApp() }
            }
        }
    }

    private func permissionRow(_ title: String, subtitle: String, granted: Bool,
                               fix: @escaping () -> Void) -> some View {
        row(title, subtitle: subtitle) {
            if granted {
                Label("Есть", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.green)
            } else {
                HStack(spacing: 8) {
                    Label("Нет", systemImage: "xmark.octagon.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.orange)
                    Button("Исправить…", action: fix)
                }
            }
        }
    }

    private var islandSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Крылья", footer: "Когда в островке ничего не происходит, по бокам от чёлки тихо видна мелочь на выбор. Как только появляется музыка, баннер или таймер, крылья прячутся. На мышь не реагируют.") {
                toggleRow("Крылья в покое", subtitle: "Погода, заряд, время или дата рядом с чёлкой", isOn: $wingsEnabled)
                rowDivider
                row("Слева") {
                    Picker("", selection: $wingsLeft) {
                        ForEach(IdleWings.choices, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .disabled(!wingsEnabled)
                }
                rowDivider
                row("Справа") {
                    Picker("", selection: $wingsRight) {
                        ForEach(IdleWings.choices, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .disabled(!wingsEnabled)
                }
            }
            group("Режим кинотеатра", footer: "Видеоплеер, браузер или приложение с музыкой открыто на весь экран — островок полностью гаснет: ни плеера, ни баннеров, ни полки. Когда выходишь из полноэкранного режима, всё возвращается.") {
                toggleRow("Режим кинотеатра", subtitle: "Ничего не отвлекает во время фильма", isOn: $cinemaEnabled)
            }
            group("Физическая чёлка",
                  footer: island.autoNotchSize
                    ? "Ширина берётся из геометрии дисплея."
                    : "Меняй ширину, только если края островка не совпадают с чёлкой.") {
                toggleRow("Определять ширину автоматически", isOn: autoWidthBinding)
                rowDivider
                sliderRow("Ширина", value: "\(Int(island.notchWidth.rounded())) pt",
                          binding: widthBinding, range: 160...280, step: 1,
                          disabled: island.autoNotchSize)
            }
            group("Размеры", footer: "Только для справки: крылья, скругления и анимации не настраиваются.") {
                HStack(spacing: 0) {
                    metric("Медиа", String(format: "%.1f pt", Double(island.mediaCompactHeight)))
                    metric("Зарядка", String(format: "%.1f pt", Double(island.notchHeight + island.chargingBridgeDepth)))
                    metric("Чёлка", String(format: "%.0f pt", Double(island.notchHeight)))
                }
                .padding(14)
            }
        }
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Развёрнутый плеер", footer: "Новый: крупная обложка, её цвета светятся за кнопками, название приложения, выбор устройства вывода (AirPods, динамики…) и ползунок громкости. Классический — как раньше, компактнее.") {
                Picker("", selection: $playerStyle) {
                    Text("Новый").tag("new")
                    Text("Классический").tag("classic")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(14)
                .id("search:Развёрнутый плеер")
            }
            group("Медиаплеер") {
                toggleRow("Скрывать в полноэкранном режиме",
                          subtitle: "Когда браузер, видеоплеер или приложение с музыкой открыто на весь экран",
                          isOn: fullscreenBinding)
                toggleRow("Скрывать, когда открыт источник музыки",
                          subtitle: "Приложение, где играет музыка, или вкладка браузера с ней",
                          isOn: sourceInFrontBinding)
            }
            group("Свечение", footer: "При смене трека контур островка на пару секунд подсвечивается цветом новой обложки.") {
                toggleRow("Свечение в цвет обложки", isOn: coverGlowBinding)
            }
            group("Таймер сна", footer: snapshot.sleepTimerStatus) {
                row("Поставить музыку на паузу через") {
                    HStack(spacing: 6) {
                        ForEach([15, 30, 60], id: \.self) { minutes in
                            Button("\(minutes) мин") { actions.setSleepTimer(minutes) }
                        }
                        Button("Выкл") { actions.setSleepTimer(0) }
                    }
                }
            }
            group("Жесты", footer: "Наведи курсор на островок с музыкой. Свайп двумя пальцами влево — следующий трек, вправо — предыдущий. Прокрутка вверх и вниз (или колесо мыши) меняет громкость.") {
                toggleRow("Жесты на медиаплеере", isOn: gesturesBinding)
            }
            group("Обложки",
                  footer: "Сначала у самого плеера, затем в каталогах Яндекс Музыки, Apple Music и Deezer. В журнал названия треков не записываются.") {
                row("Текущий трек") {
                    Button("Обновить обложку") { actions.reloadArtwork() }
                        .disabled(island.track == nil)
                }
                rowDivider
                row("Журнал поиска обложек") {
                    Button("Открыть") { actions.openArtworkLog() }
                }
            }
            group("Избранное") {
                row("Spotify") {
                    Button("Подключить…") { actions.connectSpotify() }
                }
                rowDivider
                row("Яндекс Музыка") {
                    Button("Настроить…") { actions.setupYandexFavorites() }
                }
            }
        }
    }

    private var spectrumSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil, footer: "Шесть полос реагируют на системный звук. Звук не записывается и не сохраняется.") {
                toggleRow("Живая спектрограмма", isOn: audioBinding)
                rowDivider
                toggleRow("Обложка в полосах", subtitle: "Полосы окрашены размытой обложкой песни, как на iPhone. Выключено — один цвет из обложки", isOn: $waveArtwork)
                rowDivider
                row("Состояние") {
                    Text(island.audioStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            group("Реакция на звук") {
                spectrumRow("Чувствительность", key: \.sensitivity, range: 0.5...2.0)
                rowDivider
                spectrumRow("Скорость реакции", key: \.attack, range: 0.5...2.0)
                rowDivider
                spectrumRow("Плавность затухания", key: \.release, range: 0.5...2.5)
                rowDivider
                spectrumRow("Акцент баса", key: \.bassBoost, range: 0.5...1.8)
                rowDivider
                spectrumRow("Порог тишины", key: \.noiseGate, range: 0.25...3.0)
            }
            HStack {
                Button("Сбросить настройки") { actions.setSpectrumTuning(.defaults) }
                Spacer()
                Button("Переподключить аудио") { actions.retryAudio() }
                    .disabled(!snapshot.audioCaptureEnabled)
            }
        }
    }

    private var lockSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil, footer: "Экспериментальное отображение поверх экрана блокировки.") {
                toggleRow("Замочек на экране блокировки", isOn: lockBinding)
            }
            group("Медиаплеер", footer: "Как на экране блокировки iPhone: обложка, название, прогресс и кнопки внизу по центру, над полем пароля. Появляется, только когда играет или стоит на паузе музыка. Кнопки управляют музыкой без разблокировки; если macOS не пропустит нажатия, карточка останется для просмотра.") {
                toggleRow("Медиаплеер на экране блокировки", isOn: $lockScreenMedia)
                rowDivider
                row("Прозрачность",
                    subtitle: displayOptions.reduceTransparency
                        ? "Непрозрачная — в macOS включено «Уменьшить прозрачность»"
                        : "Размытые обои — как в macOS") {
                    Button("Настройки macOS…") {
                        if let url = URL(string: SystemDisplayOptions.accessibilityDisplayPane) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                // Shown only on macOS 27+, where Appearance has the same control.
                if displayOptions.systemHasGlassControl {
                    rowDivider
                    row("Прозрачность стекла", subtitle: glassSubtitle) {
                        Picker("", selection: Binding(get: { displayOptions.glassMode },
                                                      set: {
                                                          displayOptions.setGlassMode($0)
                                                          // Show the card right away to see the change.
                                                          actions.previewLockMedia()
                                                      })) {
                            Text("Как в macOS").tag("system")
                            Text("Своя").tag("custom")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(displayOptions.reduceTransparency)
                    }
                    if displayOptions.glassMode == "custom" {
                        rowDivider
                        sliderRow("Прозрачность карточки",
                                  value: "\(Int(((1 - displayOptions.customGlassTint) * 100).rounded()))%",
                                  binding: Binding(get: { 1 - displayOptions.customGlassTint },
                                                   set: {
                                                       displayOptions.setCustomGlassTint(1 - $0)
                                                       actions.previewLockMedia()
                                                   }),
                                  range: 0...1,
                                  disabled: displayOptions.reduceTransparency)
                        hint("100% — полностью прозрачное стекло: видны только преломление и блики по краю. 0% — тёмное тонированное.")
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                }
                rowDivider
                sliderRow("Размер карточки",
                          value: "\(Int((displayOptions.cardScale * 100).rounded()))%",
                          binding: Binding(get: { displayOptions.cardScale },
                                           set: {
                                               displayOptions.setCardScale($0)
                                               actions.previewLockMedia()
                                           }),
                          range: 0.6...1, step: 0.05)
                rowDivider
                toggleRow("Часы на обложке",
                          subtitle: "Нажатие на обложку в карточке ставит её вместо обоев (снова — вернуть обои). Если часы видны дважды, выключи",
                          isOn: $lockCoverClock)
                rowDivider
                toggleRow("Живой фон обложки",
                          subtitle: "Цвета обложки медленно переливаются за ней, как на iPhone. На паузе — медленнее",
                          isOn: $lockCoverAnimated)
                rowDivider
                sliderRow("Размер обложки на обоях",
                          value: "\(Int((lockCoverScale * 100).rounded()))%",
                          binding: $lockCoverScale,
                          range: 0.3...1, step: 0.05)
                rowDivider
                row("Как выглядит") {
                    Button("Показать") { actions.previewLockMedia() }
                }
            }
            group("StandBy", footer: "Как iPhone на зарядке: Mac заблокирован, подключён к питанию и его не трогают 20 секунд — весь экран становится большими часами с зарядом и музыкой или погодой. Нажатие в любом месте (кроме раскрытого островка с музыкой) или любая клавиша возвращают обычный экран входа — пароль никогда не вводится вслепую.") {
                toggleRow("StandBy на зарядке", isOn: $standbyEnabled)
                rowDivider
                toggleRow("Не гасить экран", subtitle: "Пока StandBy на экране, дисплей не засыпает", isOn: $standbyKeepAwake)
                    .disabled(!standbyEnabled)
                rowDivider
                toggleRow("Ночной режим", subtitle: "С 22:00 до 7:00 — тусклый красный, как на iPhone", isOn: $standbyNight)
                    .disabled(!standbyEnabled)
                rowDivider
                row("Как выглядит", subtitle: "Покажет StandBy на 8 секунд, нажатие — закрыть") {
                    Button("Показать") { actions.previewStandBy() }
                }
            }
            group("Виджеты под часами",
                  footer: "Как на iPhone: до \(LockWidgetsModel.maxCount) виджетов под часами экрана блокировки — без фона, только значок и надписи. Виджет без данных (AirPods не подключены, таймер не запущен, фокус выключен) не показывается. Погода — сервис Open-Meteo: ему передаётся только название города.") {
                toggleRow("Показывать виджеты", isOn: Binding(get: { lockWidgets.enabled },
                                                            set: { lockWidgets.setEnabled($0) }))
                rowDivider
                sliderRow("Размер виджетов",
                          value: "\(Int((lockWidgets.scale * 100).rounded()))%",
                          binding: Binding(get: { lockWidgets.scale },
                                           set: {
                                               lockWidgets.setScale($0)
                                               actions.previewLockWidgets()
                                           }),
                          range: 0.6...1, step: 0.05,
                          disabled: !lockWidgets.enabled)
                ForEach(LockWidgetKind.allCases) { kind in
                    rowDivider
                    widgetRow(kind)
                    if kind == .weather && lockWidgets.isSelected(.weather) {
                        toggleRow("Определять город автоматически",
                                  subtitle: weather.status,
                                  isOn: Binding(get: { weather.autoLocate }, set: {
                                      weather.setAutoLocate($0)
                                      weather.refreshIfNeeded(force: true) {}
                                  }))
                        if weather.autoLocate && weather.locationDenied {
                            row("Геопозиция выключена для Notch Island",
                                subtitle: "Разреши в Конфиденциальности или впиши город ниже") {
                                Button("Открыть…") {
                                    if let url = URL(string: WeatherService.locationPane) { NSWorkspace.shared.open(url) }
                                }
                            }
                        }
                        if !weather.autoLocate || weather.locationDenied {
                            row("Город", subtitle: weather.autoLocate ? "Используется, если место не определено" : nil) {
                                TextField("Например, Москва",
                                          text: Binding(get: { weather.city }, set: { weather.setCity($0) }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 180)
                                    .onSubmit { weather.refreshIfNeeded(force: true) {} }
                            }
                        }
                    }
                }
                rowDivider
                row("Положение", subtitle: "«Настроить» открывает экран блокировки поверх рабочего стола: перетаскивай виджеты по одному, «Готово» — сохранить") {
                    HStack(spacing: 8) {
                        Button("Сбросить") { actions.resetLockWidgetsPosition() }
                            .disabled(!lockWidgets.hasCustomPlaces)
                        Button("Настроить") { actions.previewLockWidgets() }
                            .disabled(!lockWidgets.enabled || lockWidgets.selected.isEmpty)
                    }
                }
            }
            group("Проверка") {
                row("Анимация замка") {
                    Button("Показать") { actions.previewLock() }
                }
                rowDivider
                row("Журнал замочка") {
                    Button("Открыть") { actions.openLockLog() }
                }
            }
        }
    }

    private func widgetRow(_ kind: LockWidgetKind) -> some View {
        let selected = lockWidgets.isSelected(kind)
        let index = lockWidgets.selected.firstIndex(of: kind)
        let full = lockWidgets.selected.count >= LockWidgetsModel.maxCount
        return HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(selected && index != nil ? "\(index! + 1). \(kind.title)" : kind.title)
                    .font(.system(size: 13))
                Text(kind.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selected, let index {
                Button { lockWidgets.move(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("Левее")
                Button { lockWidgets.move(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == lockWidgets.selected.count - 1)
                    .help("Правее")
            }
            Toggle("", isOn: Binding(get: { selected }, set: { lockWidgets.toggle(kind, on: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!lockWidgets.enabled || (!selected && full))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("Состояние") {
                HStack(spacing: 12) {
                    Image(systemName: island.power?.onACPower == true ? "bolt.fill" : "battery.25percent")
                        .font(.system(size: 20))
                        .foregroundStyle(island.power?.onACPower == true ? Color.green : Color.orange)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.batterySummary).font(.system(size: 13, weight: .semibold))
                        Text(snapshot.batteryExplanation)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
            group("Время работы") {
                row("Осталось от батареи") {
                    Text(snapshot.batteryTimeText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            group("Проверка", footer: "Демонстрация на 7 секунд, реальный заряд не меняется. Если островок занят, тест встанет в очередь.") {
                row("Низкий заряд") {
                    HStack(spacing: 6) {
                        ForEach([20, 10, 5, 1], id: \.self) { threshold in
                            Button("\(threshold)%") { actions.previewLowBattery(threshold) }
                        }
                    }
                }
                rowDivider
                row("Подключение зарядки") {
                    Button("Показать") { actions.previewCharging() }
                }
            }
        }
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil) {
                toggleRow("Показывать включение и выключение", isOn: focusBinding)
                rowDivider
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: snapshot.focusNeedsAccess ? "exclamationmark.triangle.fill" : "moon.fill")
                        .foregroundStyle(snapshot.focusNeedsAccess ? Color.orange : Color.indigo)
                    Text(snapshot.focusStatus)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            group("Доступ", footer: "macOS хранит состояние фокусирования в защищённой папке. Включи Notch Island в «Полном доступе к диску» и перезапусти приложение. Файлы только читаются.") {
                row("Полный доступ к диску") {
                    Button("Открыть…") { actions.openFullDiskAccess() }
                }
                rowDivider
                row("Анимация фокусирования") {
                    Button("Показать") { actions.previewFocus() }
                }
            }
        }
    }

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil, footer: "Таймер берётся из запущенных «Часов». Нужен «Универсальный доступ» для текущей версии приложения: после обновления выключи и снова включи его.") {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "timer").foregroundStyle(Color.orange)
                    Text(snapshot.clockStatus)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            group("Управление") {
                row("Приложение «Часы»") {
                    Button("Открыть") { actions.openClock() }
                }
                rowDivider
                row("Универсальный доступ") {
                    Button("Проверить…") { actions.openAccessibility() }
                }
            }
            group("Проверка") {
                row("Анимация таймера") {
                    Button("Показать") { actions.previewTimer() }
                }
                rowDivider
                row("Таймер «Часов»") {
                    Button("Проверить") { actions.refreshClock() }
                }
                rowDivider
                row("Журнал проверки") {
                    Button("Открыть") { actions.openClockLog() }
                }
            }
        }
    }

    private func labBinding(_ feature: String) -> Binding<Bool> {
        Binding(get: { snapshot.labToggles[feature] ?? false },
                set: { actions.setLab(feature, $0) })
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil, footer: "Баннеры появляются тем же островком, что и зарядка. Нажатие на баннер открывает связанное приложение, настройки или файл.") {
                toggleRow("Громкость", subtitle: "Уровень при изменении громкости клавишами", isOn: labBinding("volume"))
                rowDivider
                toggleRow("Устройство вывода", subtitle: "AirPods, наушники, динамики; нажатие — настройки звука", isOn: labBinding("output"))
            }
            group("Исправление раскладки", footer: "Набрал «ghbdtn» вместо «привет»? Нажми ⌃⌥L — выделенный текст (или, если ничего не выделено, слово перед курсором) переведётся на другую раскладку, а клавиатура переключится на нужный язык. Буфер обмена потом возвращается как был. Работает там, где работают ⌘C и ⌘V; нужен «Универсальный доступ».") {
                toggleRow("Исправлять раскладку по ⌃⌥L", subtitle: "Как Punto Switcher: «ghbdtn» → «привет», «руддщ» → «hello»", isOn: labBinding("layout"))
            }
            group("Забота о глазах", footer: "Каждые 20 минут работы за Mac островок на 20 секунд просит посмотреть на что-нибудь вдалеке (метрах в шести) — так глаза меньше устают. Если ты отошёл от Mac на 5 минут, отсчёт начинается заново. Во время созвона (включены камера или микрофон) и на экране блокировки напоминания нет. Нажатие на баннер — пропустить.") {
                toggleRow("Правило 20-20-20", subtitle: "Напоминание отдохнуть глазам", isOn: labBinding("eyes"))
                rowDivider
                row("Как выглядит", subtitle: "Покажет напоминание в островке прямо сейчас — все 20 секунд") {
                    Button("Показать") { actions.previewEyeBreak() }
                }
            }
            group("Приватность и сеть") {
                toggleRow("Камера и микрофон", subtitle: "Когда их начинает или перестаёт использовать приложение", isOn: labBinding("privacy"))
                rowDivider
                toggleRow("VPN", subtitle: "Подключение и отключение VPN", isOn: labBinding("vpn"))
                rowDivider
                toggleRow("Интернет", subtitle: "Потеря и восстановление связи", isOn: labBinding("network"))
            }
            group("Система") {
                toggleRow("Нагрев и нагрузка", subtitle: "Сильный нагрев или процессор выше 85% дольше 30 секунд", isOn: labBinding("thermal"))
                rowDivider
                toggleRow("Внешние диски", subtitle: "Подключение и извлечение флешек и дисков", isOn: labBinding("disks"))
                ForEach(snapshot.ejectableVolumes, id: \.self) { path in
                    rowDivider
                    row((path as NSString).lastPathComponent) {
                        Button("Извлечь") { actions.ejectVolume(path) }
                    }
                }
            }
            group("Копирование", footer: "Пароли из менеджеров паролей не показываются и не запоминаются. История — только в памяти, последние 10 текстов.") {
                toggleRow("«Скопировано»", subtitle: "Короткий баннер при копировании текста, фото или файла", isOn: labBinding("clipboard"))
                ForEach(Array(snapshot.clipboardHistory.enumerated()), id: \.offset) { _, text in
                    rowDivider
                    row(text.replacingOccurrences(of: "\n", with: " ").prefix(60).description) {
                        Button("Копировать") { actions.copyClipboardItem(text) }
                    }
                }
                if !snapshot.clipboardHistory.isEmpty {
                    rowDivider
                    row("Очистить историю") {
                        Button("Очистить") { actions.clearClipboardHistory() }
                    }
                }
            }
        }
    }

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil, footer: "Перетащи файлы на чёлку или на островок — они подождут на полке слева. Наведи курсор, чтобы увидеть файлы: их можно перетащить куда угодно, отправить через AirDrop или убрать. Двойное нажатие — показать в Finder. Хранятся только ссылки, сами файлы не копируются и не перемещаются.") {
                toggleRow("Файловая полка", isOn: labBinding("shelf"))
            }
            group("AirDrop", footer: "Когда тебе присылают файлы по AirDrop, островок показывает процент приёма, потом «Получено» — нажатие покажет файл в Finder, а сам файл появится на полке. Чтобы отправить: перетащи файлы на полку и отпусти на правой половине «AirDrop».") {
                toggleRow("AirDrop в островке", subtitle: "Приём с прогрессом и отправка с полки", isOn: labBinding("airdrop"))
            }
            group("Снимки экрана") {
                toggleRow("Новые снимки экрана", subtitle: "⇧⌘3, ⇧⌘4, ⇧⌘5: баннер с миниатюрой, снимок попадает на полку", isOn: labBinding("screenshots"))
            }
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil, footer: "При включении macOS спросит доступ к Календарю или Напоминаниям. События только читаются.") {
                toggleRow("Встречи", subtitle: "За 10 минут; нажатие — ссылка на звонок или Календарь", isOn: labBinding("calendar"))
                rowDivider
                toggleRow("Напоминания", subtitle: "Когда подошёл срок", isOn: labBinding("reminders"))
            }
        }
    }

    private var airPodsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(nil, footer: "Островок появляется при подключении AirPods. Заряд кейса виден, только если macOS его сообщает.") {
                row("Подключённые AirPods") {
                    Button("Показать") { actions.previewAirPods() }
                }
            }
        }
    }

    // MARK: - Building blocks

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func group<Content: View>(_ title: String?, footer: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .padding(.vertical, 2)
                    .background(searchMark(title).padding(.horizontal, -2))
                    .id("search:" + title)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .settingsCard(cornerRadius: 18)
            if let footer {
                hint(footer).padding(.horizontal, 6)
            }
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.leading, 16).padding(.trailing, 12)
    }

    private func row<Trailing: View>(_ title: String, subtitle: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .background(searchMark(title).padding(3))
        .id("search:" + title)
    }

    private func toggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        row(title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func sliderRow(_ title: String, value: String, binding: Binding<Double>,
                           range: ClosedRange<Double>, step: Double? = nil,
                           disabled: Bool = false) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 13))
                .frame(width: 150, alignment: .leading)
            Group {
                if let step {
                    Slider(value: binding, in: range, step: step)
                } else {
                    Slider(value: binding, in: range)
                }
            }
            .controlSize(.small)
            .disabled(disabled)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .opacity(disabled ? 0.55 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .background(searchMark(title).padding(3))
        .id("search:" + title)
    }

    private func spectrumRow(_ title: String, key: WritableKeyPath<SpectrumTuning, Double>,
                             range: ClosedRange<Double>) -> some View {
        sliderRow(title, value: String(format: "%.2f×", snapshot.spectrumTuning[keyPath: key]),
                  binding: spectrumBinding(key), range: range,
                  disabled: !snapshot.audioCaptureEnabled)
    }

    // MARK: 4.2.0 Own themes

    private var newThemeButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                snapshot.themeDraftName = ""
                snapshot.themeEditorOpen = true
            }
        } label: {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(height: 52)
                    .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary))
                Text("Своя тема").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Создать тему из своих цветов")
    }

    private var themeEditor: some View {
        let colors = Array(snapshot.themeDraftColors.prefix(snapshot.themeDraftCount))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Live preview: background, two tiles, a switch.
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: snapshot.themeDraftDark
                                             ? [PaletteRGB(colors[0]).scaled(0.3).color, Color(white: 0.06)]
                                             : [PaletteRGB(colors[0]).mixedWithWhite(0.82).color, .white],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    HStack(spacing: 6) {
                        ForEach(0..<colors.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LinearGradient(colors: [colors[i], colors[i].opacity(0.7)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 26, height: 34)
                        }
                    }
                }
                .frame(width: 150, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Название, например «Ночной город»", text: $snapshot.themeDraftName)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $snapshot.themeDraftDark) {
                        Text("Тёмная").tag(true)
                        Text("Светлая").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            HStack(spacing: 14) {
                ForEach(0..<snapshot.themeDraftCount, id: \.self) { i in
                    ColorPicker("", selection: Binding(get: { snapshot.themeDraftColors[i] },
                                                       set: { snapshot.themeDraftColors[i] = $0 }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
                Stepper("Цветов: \(snapshot.themeDraftCount)", value: $snapshot.themeDraftCount, in: 2...4)
                    .font(.system(size: 12))
                Spacer()
            }
            HStack {
                Text("Первые два цвета — главные: из них фон и баннеры.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { snapshot.themeEditorOpen = false }
                }
                .keyboardShortcut(.cancelAction)
                Button("Сохранить") { saveDraftTheme() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    private func saveDraftTheme() {
        let colors = snapshot.themeDraftColors.prefix(snapshot.themeDraftCount).map { PaletteRGB($0) }
        let theme = CustomThemeStore.add(name: snapshot.themeDraftName, dark: snapshot.themeDraftDark, colors: Array(colors))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            snapshot.themeEditorOpen = false
            snapshot.customThemesVersion += 1
        }
        selectTheme(theme.id)
    }

    private func deleteCustomTheme(_ item: SettingsTheme) {
        let alert = NSAlert()
        alert.messageText = "Удалить тему «\(item.name)»?"
        alert.informativeText = "Готовые темы не удаляются — только свои."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if settingsAppearance == item.id { selectTheme("system") }
        CustomThemeStore.delete(item.id)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { snapshot.customThemesVersion += 1 }
    }

    private func themeSwatch(_ item: SettingsTheme) -> some View {
        let selected = settingsAppearance == item.id
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            selectTheme(item.id)
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    shape.fill(LinearGradient(colors: item.preview, startPoint: .topLeading, endPoint: .bottomTrailing))
                    if !item.palette.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(0..<min(4, item.palette.count), id: \.self) { i in
                                Circle().fill(item.palette[i]).frame(width: 11, height: 11)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 7)
                    } else {
                        Image(systemName: item.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(item.dark == false ? Color.black.opacity(0.75) : Color.white)
                    }
                }
                .frame(height: 52)
                .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                            lineWidth: selected ? 2.5 : 1))
                .shadow(color: (item.palette.first ?? .black).opacity(selected ? 0.45 : 0.15), radius: selected ? 8 : 3, y: 2)
                Text(item.name)
                    .font(.system(size: 11, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.dark == nil ? "\(item.name): светлая или тёмная вслед за macOS" : item.name)
        // 4.2.0: only the user's own themes have a delete button.
        .overlay(alignment: .topTrailing) {
            if CustomThemeStore.isCustom(item.id) {
                Button { deleteCustomTheme(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Удалить тему «\(item.name)»")
            }
        }
    }

    private func themeChoice(_ title: String, icon: String, value: String) -> some View {
        let selected = settingsAppearance == value
        return Button {
            selectTheme(value)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Wrapping row of small capsules for the profile cards.
private struct ProfileChips: View {
    let items: [String]

    var body: some View {
        ChipFlow(spacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }
}

private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}


// MARK: - 3.10.0 Liquid Glass pieces

// The window background: the desktop, blurred, shows through.
struct SettingsGlassBackground: NSViewRepresentable {
    let dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

extension View {
    // Floating glass panel (the sidebar). Real Liquid Glass on macOS 26+,
    // a material with a lit edge before that.
    @ViewBuilder
    func settingsGlass(cornerRadius: CGFloat, prominent: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(prominent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: shape)
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }

    // A group card: a light translucent layer with a lit top edge. 3.10.1:
    // no own blur and no shadow — the window already blurs the desktop, and
    // a blur + shadow per card made scrolling and redraws heavy.
    func settingsCard(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    shape.fill(Color.primary.opacity(0.055))
                    if let tint { shape.fill(tint.opacity(0.12)) }
                }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.06),
                                                                Color.white.opacity(0.10)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

// Rounded colour tile with a glossy top — the section icons.
struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        shape
            .fill(color.gradient)
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                               startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .shadow(color: color.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

// The island in miniature, as it is right now: the song that plays (cover,
// title, waveform in the cover's colour) or the quiet notch.
struct SettingsIslandPreview: View {
    @ObservedObject var island: IslandState
    private static let bars: [CGFloat] = [8, 13, 10, 6]

    var body: some View {
        HStack(spacing: 8) {
            if let track = island.track {
                Group {
                    if let artwork = island.musicArtwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(island.musicArtworkTint.opacity(0.6))
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
                    Text(track.artist).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        Capsule().fill(island.musicArtworkTint)
                            .frame(width: 2.5, height: track.isPlaying ? Self.bars[i] : 3)
                    }
                }
                .frame(height: 14)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Островок ждёт")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Capsule(style: .continuous).fill(Color.black))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: island.track?.title)
        .accessibilityLabel(island.track.map { "Сейчас играет: \($0.title)" } ?? "Островок")
    }
}


// 3.13.0 — «aurora»: soft blobs in the section's colour and the cover's
// colour drift behind the glass; with music, the cover itself glows through.
// Drawn at 1/6 size and scaled up (blurred anyway), 24 frames a second, only
// while the settings window is open; still with «Reduce motion».
struct SettingsAuroraBackground: View {
    let primary: Color
    let secondary: Color
    let artwork: NSImage?
    let animated: Bool
    let dark: Bool
    @StateObject private var phase = LivingPhase()
    // 3.16.3: stands still while the window is in the background.
    @Environment(\.controlActiveState) private var activeState

    private static let downscale: CGFloat = 6
    private var moving: Bool {
        animated && activeState != .inactive && !EnergySaver.isActive
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !moving)) { context in
                let t = moving ? phase.advance(to: context.date, speed: 1) : phase.value
                canvas(size: size, t: t)
            }
        }
        .opacity(dark ? 0.62 : 0.42)
        .animation(.easeInOut(duration: 0.6), value: primary)
    }

    private func canvas(size: CGSize, t: Double) -> some View {
        let small = CGSize(width: size.width / Self.downscale, height: size.height / Self.downscale)
        let d = max(small.width, small.height)
        return ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.low)
                    .scaledToFill()
                    .frame(width: d * 1.2, height: d * 1.2)
                    .rotationEffect(.degrees(t * 4))
                    .opacity(0.55)
            }
            blob(primary, d: d * 0.85, x: 0.78 + 0.16 * sin(t * 0.21), y: 0.18 + 0.14 * cos(t * 0.17), small: small)
            blob(secondary, d: d * 0.75, x: 0.22 + 0.18 * cos(t * 0.19 + 1.2), y: 0.82 + 0.12 * sin(t * 0.23), small: small)
            blob(primary.opacity(0.8), d: d * 0.55, x: 0.30 + 0.20 * sin(t * 0.15 + 2.0), y: 0.30 + 0.18 * cos(t * 0.27 + 0.5), small: small)
            blob(secondary.opacity(0.85), d: d * 0.5, x: 0.85 + 0.12 * cos(t * 0.25 + 2.6), y: 0.78 + 0.15 * sin(t * 0.19 + 1.1), small: small)
        }
        .frame(width: small.width, height: small.height)
        .clipped()
        .blur(radius: 14)
        .saturation(1.3)
        .drawingGroup()
        .scaleEffect(Self.downscale)
        .frame(width: size.width, height: size.height)
    }

    private func blob(_ color: Color, d: CGFloat, x: Double, y: Double, small: CGSize) -> some View {
        Circle()
            .fill(color)
            .frame(width: d, height: d)
            .position(x: small.width * x, y: small.height * y)
    }
}


// 3.14.0 — the small on/off pill on a tile: white when on, glass when off.
struct TilePill: View {
    @Binding var isOn: Bool
    let color: Color

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isOn.toggle() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn ? color : Color.white.opacity(0.7))
                    .frame(width: 7, height: 7)
                Text(isOn ? "Вкл" : "Выкл")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundStyle(isOn ? color : Color.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(isOn ? Color.white : Color.white.opacity(0.2)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Выключить" : "Включить")
    }
}


// MARK: - 3.15.0 Dashboard pieces

// Keeps the pointer position of ONE tile, so only that tile redraws while
// the mouse moves over it (the whole window did before).
final class TileTilt: ObservableObject {
    @Published var point: CGPoint?      // 0…1 inside the tile, nil = not hovered
    var size = CGSize(width: 200, height: 124)
}

// A bright tile that tilts towards the pointer in 3D, with a light that
// follows it; an optional Вкл/Выкл pill.
struct DashboardTile: View {
    let title: String
    let icon: String
    let status: String
    let color: Color
    let toggle: Binding<Bool>?
    let onTap: () -> Void
    let onHover: (Bool) -> Void
    @StateObject private var tilt = TileTilt()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let p = tilt.point
        let hovered = p != nil
        let dx = Double((p?.x ?? 0.5) - 0.5), dy = Double((p?.y ?? 0.5) - 0.5)
        return VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Circle().fill(Color.white.opacity(0.22))
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .offset(x: dx * 4, y: dy * 4)
            Spacer(minLength: 6)
            Text(title)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124, alignment: .topLeading)
        .background {
            GeometryReader { geometry in
                ZStack {
                    shape.fill(LinearGradient(colors: [color.opacity(0.98), color.opacity(0.66)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.18), .clear],
                                              startPoint: .top, endPoint: .center))
                    // The light under the pointer.
                    shape.fill(RadialGradient(colors: [Color.white.opacity(hovered ? 0.38 : 0.2), .clear],
                                              center: UnitPoint(x: p?.x ?? 0.15, y: p?.y ?? 0.1),
                                              startRadius: 2, endRadius: geometry.size.width * 0.8))
                }
            }
        }
        .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(hovered ? 0.7 : 0.35), Color.white.opacity(0.1)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .overlay(alignment: .topTrailing) {
            if let toggle {
                TilePill(isOn: toggle, color: color).padding(12)
            }
        }
        .rotation3DEffect(.degrees(-dy * 10), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(dx * 12), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .scaleEffect(hovered ? 1.035 : 1)
        .shadow(color: color.opacity(hovered ? 0.55 : 0.28), radius: hovered ? 16 : 8,
                x: -dx * 10, y: hovered ? 9 - dy * 6 : 4)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: tilt.point)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { tilt.size = geometry.size }
                .onChange(of: geometry.size) { _, size in tilt.size = size }
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let w = max(1, tilt.size.width), h = max(1, tilt.size.height)
                tilt.point = CGPoint(x: min(1, max(0, location.x / w)), y: min(1, max(0, location.y / h)))
            case .ended:
                tilt.point = nil
            }
        }
        .onChange(of: tilt.point == nil) { _, ended in onHover(!ended) }
        .help("Открыть «\(title)»")
    }
}


// MARK: - 3.16.0 Themes

struct SettingsTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let dark: Bool?            // nil — follow macOS
    let background: [Color]    // empty — the clear glass
    let palette: [Color]       // empty — every section keeps its own colour
    let preview: [Color]

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    // 3.19.0: the fixed themes plus «Обложка», built from the current cover.
    // 4.2.0: plus the user's own themes, at the end.
    static var all: [SettingsTheme] { fixed + [cover] + CustomThemeStore.themes.map(SettingsTheme.from) }
    static var builtInNames: [String] { fixed.map(\.name) + ["Обложка"] }

    static var cover: SettingsTheme {
        let p = CoverPalette.shared.colors
        let a = p.first ?? CoverPalette.fallback[0]
        let b = p.count > 1 ? p[1] : a
        return SettingsTheme(id: "cover", name: "Обложка", icon: "music.note", dark: true,
                             background: [a.scaled(0.32).color, b.scaled(0.22).color, Color(white: 0.05)],
                             palette: p.map(\.color),
                             preview: [a.color, b.scaled(0.45).color])
    }

    private static let fixed: [SettingsTheme] = [
        SettingsTheme(id: "system", name: "Системная", icon: "circle.lefthalf.filled", dark: nil,
                      background: [], palette: [], preview: [rgb(0.93, 0.93, 0.95), rgb(0.16, 0.16, 0.19)]),
        SettingsTheme(id: "light", name: "Светлая", icon: "sun.max.fill", dark: false,
                      background: [], palette: [], preview: [rgb(0.98, 0.98, 1.0), rgb(0.86, 0.88, 0.93)]),
        SettingsTheme(id: "dark", name: "Тёмная", icon: "moon.stars.fill", dark: true,
                      background: [], palette: [], preview: [rgb(0.22, 0.22, 0.26), rgb(0.06, 0.06, 0.08)]),
        SettingsTheme(id: "ocean", name: "Океан", icon: "water.waves", dark: true,
                      background: [rgb(0.02, 0.18, 0.36), rgb(0.0, 0.33, 0.45), rgb(0.02, 0.1, 0.22)],
                      palette: [rgb(0.0, 0.6, 0.95), rgb(0.0, 0.78, 0.78), rgb(0.25, 0.45, 1.0), rgb(0.1, 0.85, 0.65)],
                      preview: [rgb(0.0, 0.55, 0.9), rgb(0.0, 0.25, 0.45)]),
        SettingsTheme(id: "sunset", name: "Закат", icon: "sunset.fill", dark: true,
                      background: [rgb(0.42, 0.08, 0.32), rgb(0.62, 0.2, 0.18), rgb(0.2, 0.05, 0.25)],
                      palette: [rgb(1.0, 0.45, 0.25), rgb(1.0, 0.3, 0.5), rgb(1.0, 0.68, 0.2), rgb(0.85, 0.3, 0.75)],
                      preview: [rgb(1.0, 0.55, 0.25), rgb(0.75, 0.15, 0.45)]),
        SettingsTheme(id: "forest", name: "Лес", icon: "leaf.fill", dark: true,
                      background: [rgb(0.03, 0.22, 0.14), rgb(0.1, 0.3, 0.12), rgb(0.02, 0.12, 0.09)],
                      palette: [rgb(0.2, 0.78, 0.4), rgb(0.55, 0.82, 0.25), rgb(0.1, 0.65, 0.55), rgb(0.85, 0.75, 0.25)],
                      preview: [rgb(0.3, 0.8, 0.4), rgb(0.05, 0.3, 0.18)]),
        SettingsTheme(id: "lavender", name: "Лаванда", icon: "sparkles", dark: false,
                      background: [rgb(0.9, 0.86, 1.0), rgb(0.97, 0.85, 0.95), rgb(0.84, 0.88, 1.0)],
                      palette: [rgb(0.55, 0.4, 0.95), rgb(0.85, 0.4, 0.8), rgb(0.4, 0.5, 0.95), rgb(0.95, 0.5, 0.65)],
                      preview: [rgb(0.85, 0.78, 1.0), rgb(0.6, 0.45, 0.95)]),
        SettingsTheme(id: "neon", name: "Неон", icon: "bolt.fill", dark: true,
                      background: [rgb(0.05, 0.02, 0.12), rgb(0.12, 0.02, 0.2), rgb(0.02, 0.05, 0.12)],
                      palette: [rgb(1.0, 0.15, 0.75), rgb(0.1, 0.9, 1.0), rgb(0.65, 0.3, 1.0), rgb(0.2, 1.0, 0.55)],
                      preview: [rgb(1.0, 0.15, 0.75), rgb(0.1, 0.9, 1.0)]),
        SettingsTheme(id: "peach", name: "Персик", icon: "heart.fill", dark: false,
                      background: [rgb(1.0, 0.9, 0.82), rgb(1.0, 0.84, 0.86), rgb(1.0, 0.95, 0.85)],
                      palette: [rgb(1.0, 0.5, 0.4), rgb(1.0, 0.62, 0.3), rgb(0.95, 0.4, 0.55), rgb(0.9, 0.55, 0.2)],
                      preview: [rgb(1.0, 0.8, 0.65), rgb(1.0, 0.5, 0.45)]),
        // 3.16.2
        SettingsTheme(id: "aurora", name: "Аврора", icon: "sparkles", dark: true,
                      background: [rgb(0.02, 0.1, 0.16), rgb(0.04, 0.24, 0.22), rgb(0.12, 0.06, 0.24)],
                      palette: [rgb(0.15, 0.95, 0.6), rgb(0.3, 0.75, 1.0), rgb(0.65, 0.4, 1.0), rgb(0.1, 0.8, 0.8)],
                      preview: [rgb(0.15, 0.9, 0.6), rgb(0.5, 0.35, 0.95)]),
        SettingsTheme(id: "cherry", name: "Вишня", icon: "heart.fill", dark: true,
                      background: [rgb(0.25, 0.02, 0.08), rgb(0.4, 0.04, 0.12), rgb(0.12, 0.02, 0.06)],
                      palette: [rgb(1.0, 0.2, 0.35), rgb(0.95, 0.35, 0.55), rgb(1.0, 0.45, 0.3), rgb(0.85, 0.15, 0.5)],
                      preview: [rgb(1.0, 0.25, 0.4), rgb(0.35, 0.03, 0.1)]),
        SettingsTheme(id: "mint", name: "Мята", icon: "leaf.fill", dark: false,
                      background: [rgb(0.85, 0.98, 0.93), rgb(0.82, 0.95, 0.98), rgb(0.9, 0.99, 0.9)],
                      palette: [rgb(0.1, 0.72, 0.6), rgb(0.15, 0.6, 0.85), rgb(0.3, 0.75, 0.4), rgb(0.0, 0.65, 0.75)],
                      preview: [rgb(0.75, 0.97, 0.9), rgb(0.15, 0.7, 0.6)]),
        SettingsTheme(id: "sand", name: "Песок", icon: "sun.max.fill", dark: false,
                      background: [rgb(0.98, 0.94, 0.85), rgb(0.96, 0.9, 0.8), rgb(0.99, 0.96, 0.9)],
                      palette: [rgb(0.85, 0.6, 0.25), rgb(0.75, 0.45, 0.3), rgb(0.6, 0.55, 0.3), rgb(0.9, 0.5, 0.35)],
                      preview: [rgb(0.97, 0.9, 0.75), rgb(0.8, 0.55, 0.3)])
    ]

    static func find(_ id: String) -> SettingsTheme { all.first { $0.id == id } ?? all[0] }

    // 3.18.2: the two colours of «new version» banners (island and Settings).
    static var current: SettingsTheme {
        find(UserDefaults.standard.string(forKey: "settingsAppearanceV323") ?? "system")
    }
    static var updateColors: (Color, Color) {
        let palette = current.palette
        guard palette.count >= 2 else {
            return (Color(red: 0.2, green: 0.86, blue: 0.5), Color(red: 0.1, green: 0.7, blue: 0.95))
        }
        return (palette[0], palette[1])
    }

    static func == (a: SettingsTheme, b: SettingsTheme) -> Bool { a.id == b.id }
}

// Sets the hosting window's appearance (nil = follow macOS).
struct WindowAppearanceSetter: NSViewRepresentable {
    let dark: Bool?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let wanted: NSAppearance? = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.appearance?.name != wanted?.name { window.appearance = wanted }
        }
    }
}
