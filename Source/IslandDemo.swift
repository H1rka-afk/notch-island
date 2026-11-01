import AppKit
import SwiftUI

// 3.15.0 — the island acting out its features, for the settings stage and
// the onboarding tour. Purely a picture: nothing here touches the real
// island. Where real data exists (the song, the cover, the battery,
// AirPods) it is used; otherwise a neat sample.
enum IslandDemo: String, CaseIterable, Equatable {
    case music, charging, airpods, focus, timer, airdrop, lock, meeting, volume, profile, eyes

    static let cycle: [IslandDemo] = [.music, .charging, .airpods, .airdrop, .eyes, .timer, .focus]

    var caption: String {
        switch self {
        case .music: return "Сейчас играет — обложка, волна и кнопки прямо в чёлке"
        case .charging: return "Зарядка — молния и процент прямо в островке"
        case .airpods: return "AirPods — заряд наушников и кейса при подключении"
        case .focus: return "Фокусирование — баннер при включении режима"
        case .timer: return "Таймер «Часов» — обратный отсчёт рядом с чёлкой"
        case .airdrop: return "AirDrop — процент приёма и файл на полке"
        case .lock: return "Экран блокировки — замочек, плеер и виджеты"
        case .meeting: return "Встреча через 10 минут — нажми, чтобы подключиться"
        case .volume: return "Громкость, вывод звука и другие системные баннеры"
        case .profile: return "Профиль включает нужный набор функций одним нажатием"
        case .eyes: return "Правило 20-20-20 — каждые 20 минут 20 секунд смотри вдаль"
        }
    }

    var expanded: Bool { self == .music || self == .airpods }

    var size: CGSize {
        switch self {
        case .music: return CGSize(width: 380, height: 116)
        case .airpods: return CGSize(width: 340, height: 104)
        default: return CGSize(width: 320, height: 38)
        }
    }
}

struct IslandDemoView: View {
    @ObservedObject var island: IslandState
    let demo: IslandDemo
    var scale: CGFloat = 1

    var body: some View {
        let size = demo.size
        let radius: CGFloat = demo.expanded ? 30 : 14
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                                   bottomTrailingRadius: radius, topTrailingRadius: 0, style: .continuous)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            content
                .id(demo)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(scale, anchor: .top)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: demo)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch demo {
        case .music: musicCard
        case .airpods: airPodsCard
        case .charging:
            compact(left: Image(systemName: "bolt.fill"), leftColor: .green,
                    right: Text("\(island.power?.percentage ?? 87)%"), rightColor: .green)
        case .focus:
            compact(left: Image(systemName: "moon.fill"), leftColor: Color(red: 0.49, green: 0.48, blue: 1),
                    right: Text("Вкл"), rightColor: Color(red: 0.49, green: 0.48, blue: 1))
        case .timer:
            compact(left: Image(systemName: "timer"), leftColor: .orange, right: Text("4:59"), rightColor: .orange)
        case .airdrop:
            compact(left: Image(systemName: "antenna.radiowaves.left.and.right"), leftColor: Color(red: 0.04, green: 0.52, blue: 1),
                    right: Text("45%"), rightColor: Color(red: 0.4, green: 0.7, blue: 1))
        case .lock:
            compact(left: Image(systemName: "lock.fill"), leftColor: .white, right: Text(""), rightColor: .white)
        case .meeting:
            compact(left: Image(systemName: "video.fill"), leftColor: Color(red: 1, green: 0.27, blue: 0.23),
                    right: Text("10 мин"), rightColor: .white)
        case .volume:
            compact(left: Image(systemName: "speaker.wave.2.fill"), leftColor: .white, right: Text("60%"), rightColor: .white)
        case .profile:
            compact(left: Image(systemName: "square.stack.3d.up.fill"), leftColor: Color(red: 0.49, green: 0.48, blue: 1),
                    right: Text("Профиль"), rightColor: .white)
        case .eyes:
            compact(left: Image(systemName: "eye.fill"), leftColor: Color(red: 0.25, green: 0.8, blue: 0.85),
                    right: Text("20 с"), rightColor: Color(red: 0.25, green: 0.8, blue: 0.85))
        }
    }

    private func compact(left: Image, leftColor: Color, right: Text, rightColor: Color) -> some View {
        HStack {
            left.font(.system(size: 15, weight: .bold)).foregroundStyle(leftColor)
                .padding(.leading, 18)
            Spacer()
            right.font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(rightColor)
                .padding(.trailing, 18)
        }
    }

    private var musicCard: some View {
        let track = island.track
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let art = island.musicArtwork {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.5), Color(red: 0.45, green: 0.3, blue: 1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "music.note").font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Любимая песня").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    Text(track?.artist ?? "Исполнитель").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                DemoWave(tint: island.track == nil ? Color(red: 1, green: 0.45, blue: 0.6) : island.musicArtworkTint)
            }
            HStack(spacing: 18) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.white).frame(width: 110, height: 4) }
                Image(systemName: "backward.fill")
                Image(systemName: track?.isPlaying == false ? "play.fill" : "pause.fill").font(.system(size: 16, weight: .bold))
                Image(systemName: "forward.fill")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    private var airPodsCard: some View {
        let pods = island.airPods
        let values: [(String, Int)] = [("Л", pods?.left ?? 82), ("П", pods?.right ?? 79), ("Кейс", pods?.caseBattery ?? 95)]
        return HStack(spacing: 16) {
            Image(systemName: "airpodspro").font(.system(size: 30, weight: .regular)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(pods?.name.isEmpty == false ? pods!.name : "AirPods Pro").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Text("Подключены").font(.system(size: 11)).foregroundStyle(.green)
            }
            Spacer(minLength: 0)
            ForEach(0..<values.count, id: \.self) { i in
                let label = values[i].0, value = values[i].1
                VStack(spacing: 3) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 3.5)
                        Circle().trim(from: 0, to: CGFloat(value) / 100)
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(value)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                    Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }
}

// Six bars moving like music (a picture, no audio is read).
struct DemoWave: View {
    let tint: Color
    @Environment(\.controlActiveState) private var activeState
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                paused: activeState == .inactive || EnergySaver.isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<6, id: \.self) { i in
                    let h = 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 0.7) + Double(i)))
                    Capsule().fill(tint).frame(width: 3, height: 4 + 18 * h)
                }
            }
            .frame(height: 24)
        }
    }
}

// The settings stage: a screen edge with the island; it plays the hovered
// tile's feature, or cycles through the favourites.
struct IslandStage: View {
    @ObservedObject var island: IslandState
    let demo: IslandDemo?
    let accent: Color?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3.2)) { context in
            let index = Int(context.date.timeIntervalSinceReferenceDate / 3.2) % IslandDemo.cycle.count
            stage(demo ?? IslandDemo.cycle[index])
        }
    }

    private func stage(_ current: IslandDemo) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let a = accent ?? Color(red: 0.36, green: 0.35, blue: 0.9)
        return ZStack(alignment: .top) {
            shape.fill(LinearGradient(colors: [a.opacity(0.85), Color(red: 0.12, green: 0.08, blue: 0.25)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [island.musicArtworkTint.opacity(0.6), .clear],
                                      center: .bottomTrailing, startRadius: 4, endRadius: 360))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
            IslandDemoView(island: island, demo: current)
            Text(current.caption)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 14)
                .id(current.caption)
                .transition(.opacity)
        }
        .frame(height: 176)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
        .shadow(color: a.opacity(0.35), radius: 14, y: 6)
        .animation(.easeInOut(duration: 0.35), value: current)
        .animation(.easeInOut(duration: 0.5), value: accent)
    }
}
