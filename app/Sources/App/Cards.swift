import SwiftUI
import HarborKit
import SwiftStreamingMarkdown

struct ChatItemView: View {
    let item: ChatItem
    let chat: ChatState

    var body: some View {
        switch item.kind {
        case .user(let text, let images): UserBubble(text: text, imageCount: images)
        case .assistant(let text): AssistantText(text: text, streaming: item.isStreaming)
        case .thinking(let text): ThinkingRow(text: text, streaming: item.isStreaming)
        case .tool(let t): ToolCard(tool: t, chat: chat)
        case .footer(let f): FooterRow(footer: f)
        case .notice(let text, let isError): NoticeRow(text: text, isError: isError)
        }
    }
}

struct UserBubble: View {
    let text: String
    let imageCount: Int
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                if imageCount > 0 {
                    Label("\(imageCount) image\(imageCount == 1 ? "" : "s")", systemImage: "photo")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                if !text.isEmpty {
                    Text(text).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }
}

struct AssistantText: View {
    let text: String
    let streaming: Bool
    var body: some View {
        MarkdownView(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityLabel(text)
    }
}

struct ThinkingRow: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                Text(streaming ? "Thinking…" : "Thought")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}

struct NoticeRow: View {
    let text: String
    let isError: Bool
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.footnote)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((isError ? Color.red : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct FooterRow: View {
    let footer: TurnFooter
    var body: some View {
        HStack(spacing: 10) {
            if footer.isError { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
            Text(Duration.milliseconds(footer.durationMS).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
            if let c = footer.costUSD { Text(String(format: "$%.4f", c)) }
            if let t = footer.outputTokens { Text("\(t) tokens out") }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

// MARK: tools

struct ToolCard: View {
    let tool: ToolCall
    let chat: ChatState
    var body: some View {
        switch tool.kind {
        case .bash: CommandCard(tool: tool)
        case .edit, .write, .multiEdit: DiffCard(tool: tool)
        case .todo: CompactToolRow(tool: tool, icon: "checklist", title: "Updated the plan")
        case .task: TaskCard(tool: tool, children: chat.children(of: tool.id), chat: chat)
        case .read: CompactToolRow(tool: tool, icon: "doc.text", title: "Read " + shortPath(tool.filePath))
        case .grep: CompactToolRow(tool: tool, icon: "magnifyingglass", title: "Searched for " + (tool.input["pattern"]?.string ?? ""))
        case .glob: CompactToolRow(tool: tool, icon: "folder", title: "Listed " + (tool.input["pattern"]?.string ?? ""))
        case .webFetch: CompactToolRow(tool: tool, icon: "globe", title: "Fetched " + (tool.input["url"]?.string ?? ""))
        case .webSearch: CompactToolRow(tool: tool, icon: "magnifyingglass.circle", title: "Searched the web for " + (tool.input["query"]?.string ?? ""))
        case .other(let name): GenericToolCard(tool: tool, name: name)
        }
    }
}

func shortPath(_ p: String?) -> String {
    guard let p, !p.isEmpty else { return "file" }
    let parts = p.split(whereSeparator: { $0 == "\\" || $0 == "/" })
    return parts.suffix(2).joined(separator: "/")
}

struct StatusIcon: View {
    let status: ToolCall.Status
    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .interrupted: Image(systemName: "stop.circle").foregroundStyle(.orange)
        }
    }
}

struct CardChrome<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator).opacity(0.4)))
    }
}

/// Bash: command, spinner, live output, exit code; collapsible.
struct CommandCard: View {
    let tool: ToolCall
    @State private var expanded: Bool? = nil

    private var isExpanded: Bool { expanded ?? (tool.status == .running) }
    private var output: String {
        let o = tool.result.isEmpty ? tool.liveOutput : tool.result
        return o.trimmingCharacters(in: .newlines)
    }
    private var exitCode: String? {
        guard tool.status == .error else { return nil }
        if let r = tool.result.range(of: #"[Ee]xit code (\d+)"#, options: .regularExpression) {
            return String(tool.result[r])
        }
        return "failed"
    }

    var body: some View {
        CardChrome {
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded = !isExpanded } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        Text(tool.command ?? tool.description ?? "Command")
                            .font(.callout.monospaced())
                            .lineLimit(isExpanded ? 6 : 1)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let e = exitCode { Text(e).font(.caption2.monospaced()).foregroundStyle(.red) }
                        StatusIcon(status: tool.status)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Command \(tool.command ?? ""), \(statusText)")
                if isExpanded, !output.isEmpty {
                    ScrollView(.vertical) {
                        Text(String(output.suffix(20_000)))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    .padding(8)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var statusText: String {
        switch tool.status {
        case .running: return "running"
        case .success: return "finished"
        case .error: return "failed"
        case .interrupted: return "stopped"
        }
    }
}

/// Edit / Write / MultiEdit as a unified line diff.
struct DiffCard: View {
    let tool: ToolCall
    @State private var expanded = true

    private var hunks: [(old: String, new: String)] {
        switch tool.kind {
        case .write: return [("", tool.input["content"]?.string ?? "")]
        case .multiEdit:
            return tool.input["edits"]?.array?.map { (old: $0["old_string"]?.string ?? "", new: $0["new_string"]?.string ?? "") } ?? []
        default:
            return [(tool.input["old_string"]?.string ?? "", tool.input["new_string"]?.string ?? "")]
        }
    }

    var body: some View {
        let lines = hunks.flatMap { LineDiff.diff($0.old, $0.new) + [.separator] }.dropLast()
        let added = lines.filter { if case .added = $0 { return true }; return false }.count
        let removed = lines.filter { if case .removed = $0 { return true }; return false }.count
        CardChrome {
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tool.kind == .write ? "doc.badge.plus" : "pencil").foregroundStyle(.secondary)
                        Text(shortPath(tool.filePath)).font(.callout.monospaced()).lineLimit(1)
                        Spacer()
                        Text("+\(added)").foregroundStyle(.green).font(.caption.monospaced())
                        Text("−\(removed)").foregroundStyle(.red).font(.caption.monospaced())
                        StatusIcon(status: tool.status)
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    ScrollView([.vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.prefix(400).enumerated()), id: \.offset) { _, line in
                                DiffLineView(line: line)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if tool.status == .error {
                    Text(tool.result).font(.caption).foregroundStyle(.red).lineLimit(4)
                }
            }
        }
    }
}

struct DiffLineView: View {
    let line: LineDiff.Line
    var body: some View {
        switch line {
        case .same(let s): row(" ", s, nil)
        case .added(let s): row("+", s, .green)
        case .removed(let s): row("−", s, .red)
        case .separator: Divider().padding(.vertical, 4)
        }
    }
    private func row(_ mark: String, _ text: String, _ color: Color?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(mark).foregroundStyle(color ?? .secondary)
            Text(text.isEmpty ? " " : text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background((color ?? .clear).opacity(0.12))
    }
}

/// Read / Grep / Glob / web: one line, expandable to the result.
struct CompactToolRow: View {
    let tool: ToolCall
    let icon: String
    let title: String
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 18)
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    StatusIcon(status: tool.status)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded, !tool.result.isEmpty {
                Text(String(tool.result.prefix(8000)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Task (sub-agent): its own nested list of messages and tools.
struct TaskCard: View {
    let tool: ToolCall
    let children: [ChatItem]
    let chat: ChatState
    @State private var expanded = false
    var body: some View {
        CardChrome {
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.wave.2").foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.description ?? "Sub-agent").font(.callout.weight(.medium))
                            Text("\(children.count) step\(children.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusIcon(status: tool.status)
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(children) { ChatItemView(item: $0, chat: chat) }
                        if !tool.result.isEmpty {
                            Divider()
                            MarkdownView(text: tool.result)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(.purple.opacity(0.3)).frame(width: 2) }
                }
            }
        }
    }
}

struct GenericToolCard: View {
    let tool: ToolCall
    let name: String
    @State private var expanded = false
    var body: some View {
        CardChrome {
            VStack(alignment: .leading, spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
                        Text(name).font(.callout.monospaced())
                        Spacer()
                        StatusIcon(status: tool.status)
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    Text(tool.input.serialized(pretty: true)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    if !tool.result.isEmpty {
                        Text(String(tool.result.prefix(8000))).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

struct TodoPanel: View {
    let todos: [TodoItem]
    @State private var expanded = true
    var body: some View {
        let done = todos.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack {
                    Image(systemName: "checklist")
                    Text("Plan").font(.subheadline.weight(.semibold))
                    Text("\(done)/\(todos.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(todos) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: t.status == .completed ? "checkmark.circle.fill" :
                                t.status == .inProgress ? "circle.dotted.circle" : "circle")
                            .foregroundStyle(t.status == .completed ? .green : t.status == .inProgress ? .blue : .secondary)
                        Text(t.status == .inProgress ? t.activeForm : t.content)
                            .font(.footnote)
                            .strikethrough(t.status == .completed)
                            .foregroundStyle(t.status == .completed ? .secondary : .primary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
