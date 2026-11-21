import SwiftUI
import PhotosUI
import HarborKit

/// The conversation: a scrolling list of messages and cards, a pinned todo
/// checklist, and the input bar.
struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ClaudeEngine
    @State private var draft = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachments: [ClaudeProtocol.ImageAttachment] = []
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !engine.chat.todos.isEmpty {
                TodoPanel(todos: engine.chat.todos)
            }
            messages
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .background(Color(.systemGroupedBackground))
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if engine.chat.items.isEmpty { EmptyChatHint(phase: engine.phase) }
                    ForEach(engine.chat.items) { item in
                        ChatItemView(item: item, chat: engine.chat)
                            .id(item.id)
                    }
                    if engine.chat.isTurnRunning, !(engine.chat.items.last?.isStreaming ?? false) {
                        WorkingIndicator().id("working")
                    }
                    if case .failed(let message) = engine.phase {
                        NoticeRow(text: message, isError: true).id("failure")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: engine.chat.items.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: lastItemLength) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Changes while the last message streams, so the list follows it.
    private var lastItemLength: Int {
        guard let last = engine.chat.items.last else { return 0 }
        switch last.kind {
        case .assistant(let t), .thinking(let t): return t.count
        case .tool(let t): return t.liveOutput.count + t.result.count
        default: return 0
        }
    }

    private var canSend: Bool {
        engine.phase == .ready && !engine.chat.isTurnRunning &&
            (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { i, a in
                            AttachmentChip(attachment: a) { attachments.remove(at: i) }
                        }
                    }.padding(.horizontal)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Attach images")
                .onChange(of: photoItems) { _, items in Task { await loadPhotos(items) } }

                TextField("Message Claude", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("composer")

                if engine.chat.isTurnRunning {
                    Button { engine.interrupt() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                    .tint(.red)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("send")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.send(text: text, images: attachments)
        draft = ""
        attachments = []
        photoItems = []
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var out: [ClaudeProtocol.ImageAttachment] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            // Keep requests small: longest side 1568 px (the API's own limit), JPEG.
            let scaled = image.scaledDown(maxSide: 1568)
            if let jpeg = scaled.jpegData(compressionQuality: 0.85) {
                out.append(.init(mediaType: "image/jpeg", base64: jpeg.base64EncodedString()))
            }
        }
        attachments = out
    }
}

extension UIImage {
    func scaledDown(maxSide: CGFloat) -> UIImage {
        let s = max(size.width, size.height)
        guard s > maxSide else { return self }
        let scale = maxSide / s
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

struct AttachmentChip: View {
    let attachment: ClaudeProtocol.ImageAttachment
    let remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let d = Data(base64Encoded: attachment.base64), let img = UIImage(data: d) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove image")
        }
    }
}

struct EmptyChatHint: View {
    let phase: ClaudeEngine.Phase
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(phase == .starting ? "Starting Claude Code…" : "Ask Claude to build, fix or explain something.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Workspace: C:\\workspace")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
