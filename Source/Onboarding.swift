import AppKit
import SwiftUI

// 3.15.0 — «Знакомство»: five short screens on first launch (and from
// Settings → Основные). What the island does, the permissions and why, a
// profile to start with, and a few tips. Nothing is switched on silently:
// permissions open System Settings only on a button press.
final class OnboardingModel: ObservableObject {
    @Published var page = 0
    @Published var forward = true
    @Published var chosenProfile: String?
}

struct OnboardingView: View {
    static let doneKey = "onboardingDoneV3150"
    static let windowSize = CGSize(width: 760, height: 540)
    static let pageCount = 5

    @ObservedObject var island: IslandState
    @ObservedObject var snapshot: NotchSettingsSnapshot
    let actions: NotchSettingsActions
    // 3.20.0: shown inside the settings window, filling it.
    var embedded = false
    let onFinish: (_ openSettings: Bool) -> Void
    @StateObject private var model = OnboardingModel()
    @Environment(\.colorScheme) private var scheme

    private let colors: [Color] = [
        Color(red: 0.36, green: 0.35, blue: 0.90),
        Color(red: 1.0, green: 0.27, blue: 0.40),
        Color(red: 0.18, green: 0.66, blue: 0.42),
        Color(red: 0.66, green: 0.36, blue: 0.95),
        Color(red: 1.0, green: 0.58, blue: 0.0)
    ]
    private var color: Color { colors[min(model.page, colors.count - 1)] }

    var body: some View {
        ZStack {
            SettingsGlassBackground(dark: scheme == .dark)
            SettingsAuroraBackground(primary: color, secondary: island.musicArtworkTint,
                                     artwork: nil, animated: true, dark: scheme == .dark)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if model.page < Self.pageCount - 1 {
                        Button("Пропустить") { onFinish(false) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 28)
                .padding(.horizontal, 20)
                .padding(.top, embedded ? 16 : 10)

                ZStack {
                    page(model.page)
                        .id(model.page)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: model.forward ? 40 : -40)),
                            removal: .opacity.combined(with: .offset(x: model.forward ? -40 : 40))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)

                bottomBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)
            }
        }
        .frame(width: embedded ? nil : Self.windowSize.width, height: embedded ? nil : Self.windowSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(color)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.4), value: model.page)
    }

    private func go(_ delta: Int) {
        let next = min(Self.pageCount - 1, max(0, model.page + delta))
        guard next != model.page else { return }
        model.forward = delta > 0
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { model.page = next }
    }

    private var bottomBar: some View {
        HStack {
            Button { go(-1) } label: { Text("Назад").frame(minWidth: 70) }
                .controlSize(.large)
                .opacity(model.page == 0 ? 0 : 1)
                .disabled(model.page == 0)
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<Self.pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == model.page ? color : Color.primary.opacity(0.2))
                        .frame(width: i == model.page ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.page)
            Spacer()
            if model.page < Self.pageCount - 1 {
                Button { go(1) } label: { Text(model.page == 0 ? "Начнём" : "Далее").frame(minWidth: 90) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { onFinish(false) } label: { Text("Готово").frame(minWidth: 90) }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        switch index {
        case 0: welcome
        case 1: features
        case 2: permissions
        case 3: profiles
        default: tips
        }
    }

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 26) {
            IslandStage(island: island, demo: nil, accent: color)
                .frame(width: 560)
            title("Привет! Это Notch Island",
                  "Чёлка MacBook превращается в живой островок, как Dynamic Island на iPhone: музыка, зарядка, AirPods, файлы и экран блокировки.")
        }
    }

    private var features: some View {
        VStack(spacing: 22) {
            title("Что умеет островок", "Всё появляется само, когда нужно, и прячется, когда нет.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                feature("play.fill", "Музыка", "Обложка, волна, кнопки; жесты по островку", Color(red: 1, green: 0.27, blue: 0.4))
                feature("bolt.fill", "Зарядка и AirPods", "Процент зарядки, заряд наушников и кейса", Color(red: 0.2, green: 0.75, blue: 0.35))
                feature("tray.full.fill", "Полка и AirDrop", "Перетащи файлы на чёлку — они подождут", Color(red: 0.04, green: 0.52, blue: 1))
                feature("lock.fill", "Экран блокировки", "Плеер, обложка вместо обоев, виджеты", Color(red: 0.36, green: 0.38, blue: 0.6))
                feature("timer", "Таймер и встречи", "Отсчёт «Часов», созвоны за 10 минут", Color(red: 1, green: 0.58, blue: 0))
                feature("square.stack.3d.up.fill", "Профили", "Набор функций одним нажатием", Color(red: 0.36, green: 0.35, blue: 0.9))
            }
        }
    }

    private func feature(_ icon: String, _ name: String, _ text: String, _ tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.22)))
            Spacer(minLength: 0)
            Text(name).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(shape.fill(LinearGradient(colors: [tint, tint.opacity(0.68)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        .shadow(color: tint.opacity(0.35), radius: 10, y: 4)
    }

    private var permissions: some View {
        VStack(spacing: 22) {
            title("Разрешения", "Notch Island работает только на этом Mac и ничего никуда не отправляет. Разрешения нужны, чтобы видеть то, что показывает островок.")
            VStack(spacing: 0) {
                permission("hand.raised.fill", "Универсальный доступ",
                           "Таймер «Часов», жесты, обложки Яндекс Музыки", snapshot.permAccessibility) { actions.fixAccessibility() }
                Divider().padding(.leading, 58)
                permission("externaldrive.fill", "Полный доступ к диску",
                           "Фокусирование и снимки экрана", snapshot.permFullDisk) { actions.fixFullDisk() }
                Divider().padding(.leading, 58)
                permission("arrow.down.circle.fill", "Папка «Загрузки»",
                           "Обновления одним нажатием и AirDrop", snapshot.permDownloads) { actions.fixDownloads() }
            }
            .padding(.vertical, 4)
            .settingsCard(cornerRadius: 20)
            Button("Проверить снова") { actions.recheckPermissions() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private func permission(_ icon: String, _ name: String, _ why: String, _ granted: Bool,
                            fix: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            SettingsIconTile(symbol: icon, color: granted ? Color(red: 0.2, green: 0.75, blue: 0.35) : color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13.5, weight: .semibold))
                Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Готово", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Button("Разрешить", action: fix).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: granted)
    }

    private var profiles: some View {
        VStack(spacing: 22) {
            title("С чего начать?", "Профиль включает готовый набор функций. Его всегда можно поменять в настройках или создать свой.")
            HStack(spacing: 14) {
                profileChoice("iphone", "Как на iPhone", "iphone.gen3",
                              "Только то, что умеет Dynamic Island: музыка, зарядка, AirPods, Фокусирование, экран блокировки.",
                              Color(red: 0.2, green: 0.48, blue: 1))
                profileChoice("extended", "Максимум", "sparkles",
                              "Всё сразу: полка, AirDrop, снимки экрана, системные баннеры, жесты, свечение и виджеты.",
                              Color(red: 0.66, green: 0.36, blue: 0.95))
            }
            Text(model.chosenProfile == nil ? "Можно пропустить — останутся текущие настройки." : "Готово, профиль включён.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func profileChoice(_ raw: String, _ name: String, _ icon: String, _ text: String, _ tint: Color) -> some View {
        let chosen = model.chosenProfile == raw
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.system(size: 22, weight: .bold))
                Spacer()
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.system(size: 20))
            }
            Text(name).font(.system(size: 20, weight: .heavy, design: .rounded))
            Text(text).font(.system(size: 12, weight: .medium)).opacity(0.88)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(shape.fill(LinearGradient(colors: [tint, tint.opacity(0.65)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
        .overlay(shape.strokeBorder(Color.white.opacity(chosen ? 0.95 : 0.3), lineWidth: chosen ? 2.5 : 1))
        .shadow(color: tint.opacity(chosen ? 0.6 : 0.3), radius: chosen ? 18 : 10, y: 5)
        .scaleEffect(chosen ? 1.02 : 1)
        .contentShape(shape)
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { model.chosenProfile = raw }
            actions.applyProfile(raw)
        }
    }

    private var tips: some View {
        VStack(spacing: 22) {
            title("Пара секретов", "И всё — островок уже работает.")
            VStack(alignment: .leading, spacing: 14) {
                tip("cursorarrow.motionlines", "Наведи курсор на чёлку — плеер раскроется. Смахни по нему — следующий трек.")
                tip("doc.on.doc.fill", "Перетащи файлы на чёлку — они лягут на полку. Отпусти справа — уйдут по AirDrop.")
                tip("keyboard", "⌃⌥N — открыть или закрыть плеер с клавиатуры.")
                tip("photo.fill", "На экране блокировки нажми на обложку в карточке — она станет обоями.")
                tip("square.grid.2x2.fill", "В настройках наведи на плитку — островок сверху покажет, что она делает.")
            }
            .padding(20)
            .settingsCard(cornerRadius: 20)
            Button(embedded ? "Перейти к настройкам" : "Открыть настройки") { onFinish(true) }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
