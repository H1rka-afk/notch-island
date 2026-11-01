import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 3.3.0 (experimental): file shelf.
// Drag files onto the notch or the island → they wait on a small shelf to
// the LEFT of the notch (mirror of the timer satellite). Hover it to see the
// files, drag them out anywhere, send them by AirDrop or clear the shelf.
// Only references are kept: the files themselves are never moved or copied.
final class ShelfModel: ObservableObject {
    @Published private(set) var items: [URL] = []
    @Published var dropTargeted = false {
        didSet { if dropTargeted && !oldValue { watchDragEnd() } }
    }
    private var dragWatch: Timer?
    // 3.9.4: the pointer is over the «AirDrop» half while dragging.
    @Published var airDropHover = false
    var airDropEnabled: Bool { LabFeature.airdrop.isOn }
    @Published private(set) var expanded = false
    // 3.4.0: the shelf appears like the timer "drop" — it grows out of the
    // island side with a soft spring and shrinks back into it.
    @Published private(set) var presented = false
    private var presenceToken = UUID()

    func present() {
        presenceToken = UUID()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.68)) { presented = true }
    }

    func dismiss(completion: @escaping () -> Void) {
        let token = UUID()
        presenceToken = token
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { [weak self] in
            guard let self, self.presenceToken == token else { return }
            completion()
        }
    }
    private var hoverExit: DispatchWorkItem?
    private let key = "lab.shelf.items.v330"

    let compactSize: CGFloat = 34
    let expandedSize = CGSize(width: 268, height: 182)

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isVisible: Bool { !items.isEmpty || dropTargeted }

    // 3.3.1: AppKit/SwiftUI do not always report the end of a drag that was
    // dropped elsewhere, which left the shelf stuck in "Отпусти, чтобы
    // положить". When no mouse button is pressed any more, the drag is over.
    private func watchDragEnd() {
        dragWatch?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSEvent.pressedMouseButtons == 0 {
                timer.invalidate()
                self.dragWatch = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                    self.dropTargeted = false
                    self.airDropHover = false
                    self.collapse()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }
    var showsExpanded: Bool { expanded || dropTargeted }

    func add(_ urls: [URL]) {
        var changed = false
        let key: (URL) -> String = { $0.standardizedFileURL.path.precomposedStringWithCanonicalMapping }
        for url in urls where url.isFileURL && !items.contains(where: { key($0) == key(url) }) {
            items.insert(url, at: 0)
            changed = true
        }
        if items.count > 30 { items.removeLast(items.count - 30) }
        if changed { save() }
    }

    // 3.4.2: a capture moved from the preview folder to its final place.
    func replace(_ old: URL, with new: URL) {
        let key: (URL) -> String = { $0.standardizedFileURL.path.precomposedStringWithCanonicalMapping }
        guard let index = items.firstIndex(where: { key($0) == key(old) }) else { return }
        if items.contains(where: { key($0) == key(new) }) { items.remove(at: index) }
        else { items[index] = new }
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
        if items.isEmpty { collapse() }
    }

    func clear() {
        items.removeAll()
        save()
        collapse()
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }

    func hoverChanged(_ over: Bool) {
        hoverExit?.cancel()
        if over {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { expanded = true }
        } else {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            hoverExit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    func collapse() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { expanded = false }
    }

    func airDropAll() {
        guard !items.isEmpty else { return }
        AirDropSender.shared.send(items)
    }

    // 3.9.4: files dropped on the «AirDrop» half go straight to the AirDrop
    // picker; they are not put on the shelf.
    func acceptForAirDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.collapse()
            AirDropSender.shared.send(urls)
        }
        return true
    }

    // Loads dropped file URLs from SwiftUI/AppKit item providers.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self?.add([url]) }
            }
        }
        return true
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: ShelfModel
    let roof: CGFloat

    private var size: CGSize {
        shelf.showsExpanded ? shelf.expandedSize : CGSize(width: shelf.compactSize, height: shelf.compactSize)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            UnevenRoundedRectangle(topLeadingRadius: 0,
                                   bottomLeadingRadius: shelf.showsExpanded ? 16 : 9,
                                   bottomTrailingRadius: shelf.showsExpanded ? 16 : 9,
                                   topTrailingRadius: 0, style: .continuous)
                .fill(Color.black)
                .frame(width: size.width, height: size.height + roof)
                .overlay(alignment: .top) {
                    if shelf.dropTargeted {
                        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 16,
                                               bottomTrailingRadius: 16, topTrailingRadius: 0,
                                               style: .continuous)
                            .strokeBorder(Color(red: 0.04, green: 0.52, blue: 1.0), lineWidth: 1.5)
                            .padding(.top, roof)
                    }
                }

            Group {
                if shelf.showsExpanded {
                    expandedContent
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
                } else {
                    compactContent
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity)
                }
            }
            .padding(.top, roof)
        }
        .frame(width: size.width, height: size.height + roof, alignment: .topTrailing)
        .contentShape(Rectangle())
        .onHover { shelf.hoverChanged($0) }
        .onDrop(of: [UTType.fileURL], delegate: ShelfDropDelegate(shelf: shelf))
        .scaleEffect(shelf.presented ? 1 : 0.35, anchor: .topTrailing)
        .offset(x: shelf.presented ? 0 : 16)
        .opacity(shelf.presented ? 1 : 0)
        .blur(radius: shelf.presented ? 0 : 3)
        .frame(width: shelf.expandedSize.width, height: shelf.expandedSize.height + roof, alignment: .topTrailing)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: shelf.showsExpanded)
    }

    private var compactContent: some View {
        ZStack {
            Image(systemName: shelf.items.isEmpty ? "tray" : "tray.full.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            if !shelf.items.isEmpty {
                Text("\(shelf.items.count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Color.white))
                    .offset(x: 9, y: -8)
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tray.full.fill").foregroundStyle(.white.opacity(0.85))
                Text(shelf.dropTargeted
                     ? (shelf.airDropEnabled ? (shelf.airDropHover ? "Отправить через AirDrop" : "Положить на полку")
                                             : "Отпусти, чтобы положить")
                     : "Полка")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if !shelf.items.isEmpty && !shelf.dropTargeted {
                    Button { shelf.airDropAll() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Отправить всё через AirDrop")
                    Button { shelf.clear() } label: { Image(systemName: "trash") }
                        .help("Очистить полку")
                }
            }
            .foregroundStyle(.white.opacity(0.85))
            .buttonStyle(.plain)

            if shelf.dropTargeted && shelf.airDropEnabled {
                HStack(spacing: 8) {
                    dropZone(symbol: "tray.and.arrow.down.fill", title: "На полку",
                             active: !shelf.airDropHover, tint: .white)
                    dropZone(symbol: "antenna.radiowaves.left.and.right", title: "AirDrop",
                             active: shelf.airDropHover, tint: Color(red: 0.04, green: 0.52, blue: 1.0))
                }
                .frame(maxHeight: .infinity)
                .animation(.easeOut(duration: 0.15), value: shelf.airDropHover)
            } else if shelf.items.isEmpty {
                Spacer(minLength: 0)
                Text("Перетащи файлы сюда или на чёлку")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(shelf.items, id: \.self) { url in
                            ShelfRow(url: url, remove: { shelf.remove(url) })
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func dropZone(symbol: String, title: String, active: Bool, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(active ? tint : .white.opacity(0.45))
                .scaleEffect(active ? 1.08 : 1)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 0.95 : 0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(active ? tint.opacity(0.18) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(active ? tint.opacity(0.8) : Color.white.opacity(0.12),
                          style: StrokeStyle(lineWidth: 1.2, dash: active ? [] : [4, 3])))
    }
}

// 3.9.4: the drop decides by the pointer — left half: shelf, right half:
// AirDrop (only when «AirDrop» is on and the shelf is open).
struct ShelfDropDelegate: DropDelegate {
    let shelf: ShelfModel

    private func wantsAirDrop(_ info: DropInfo) -> Bool {
        guard shelf.airDropEnabled, shelf.showsExpanded else { return false }
        return info.location.x > shelf.expandedSize.width / 2
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.fileURL]) }

    func dropEntered(info: DropInfo) {
        shelf.dropTargeted = true
        shelf.airDropHover = wantsAirDrop(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let over = wantsAirDrop(info)
        if over != shelf.airDropHover { shelf.airDropHover = over }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        shelf.dropTargeted = false
        shelf.airDropHover = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let toAirDrop = wantsAirDrop(info)
        let providers = info.itemProviders(for: [UTType.fileURL])
        shelf.airDropHover = false
        shelf.dropTargeted = false
        return toAirDrop ? shelf.acceptForAirDrop(providers) : shelf.accept(providers)
    }
}

private struct ShelfRow: View {
    let url: URL
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
            Text(url.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        // The original file itself, not a temporary copy (3.3.1).
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help("Перетащи файл куда нужно. Двойное нажатие — показать в Finder")
    }
}

// Hit-testing limited to the visible shelf, anchored to the top-RIGHT.
final class ShelfHostingView: NSHostingView<ShelfView> {
    var visibleSize: (() -> CGSize)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let size = visibleSize?() ?? bounds.size
        let hit = CGRect(x: bounds.width - size.width, y: bounds.height - size.height,
                         width: size.width, height: size.height)
        guard hit.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

// Invisible drop target exactly over the physical camera notch, so files can
// be shelved even when no island is shown. Black on the black notch housing.
final class NotchDropView: NSView {
    weak var shelf: ShelfModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    // Only real files: dragged text, links or images from web pages are ignored.
    private func carriesFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard carriesFiles(sender) else { return [] }
        shelf?.dropTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Leave the shelf open briefly so the drop can also land on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.shelf?.dropTargeted = false
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        shelf?.add(urls)
        shelf?.dropTargeted = false
        return !urls.isEmpty
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        shelf?.dropTargeted = false
    }
}
