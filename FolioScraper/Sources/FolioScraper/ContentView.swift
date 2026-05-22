import SwiftUI
import UniformTypeIdentifiers

private let totalWindowWidth: CGFloat = 980
private let totalWindowHeight: CGFloat = 620
private let mainColumnWidth: CGFloat = 652
private let sidebarWidth: CGFloat = 327

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var draggedQueuedJob: QueuedJob?

    var body: some View {
        HStack(spacing: 0) {
            mainPanel
                .frame(width: mainColumnWidth, height: totalWindowHeight)

            Divider()

            sidebar
                .frame(width: sidebarWidth, height: totalWindowHeight)
        }
        .frame(width: totalWindowWidth, height: totalWindowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FolioArchiver")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 26)

            Text("Queue artist and designer portfolio URLs and save large images into Desktop folders.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            HStack(spacing: 10) {
                Circle()
                    .fill(viewModel.statusColor)
                    .frame(width: 14, height: 14)

                Text("Status: \(viewModel.statusText)")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
            }
            .padding(.top, 20)

            Text("Add portfolio URL")
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 26)

            Text("Each click adds a site to the queue. Jobs run one after another.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 12) {
                TextField("https://example.com", text: $viewModel.inputURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))

                Button("Add to queue") {
                    viewModel.enqueueCurrentInput()
                }
                .buttonStyle(.borderedProminent)

                Button("Stop") {
                    viewModel.stopScraping()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isRunning)
            }
            .padding(.top, 18)

            Text("Options")
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 28)

            HStack(spacing: 12) {
                Text("Maximum images per site")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Picker("", selection: $viewModel.selectedMaxImages) {
                    ForEach(viewModel.maxImageOptions, id: \.self) { option in
                        Text("\(option)").tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 90)
            }
            .padding(.top, 12)

            Toggle("Save details", isOn: $viewModel.saveDetails)
                .font(.system(size: 13))
                .toggleStyle(.checkbox)
                .padding(.top, 12)

            Toggle("Download small images", isOn: $viewModel.downloadSmallImages)
                .font(.system(size: 13))
                .toggleStyle(.checkbox)
                .padding(.top, 10)

            Toggle("Check for duplicates", isOn: $viewModel.checkForDuplicates)
                .font(.system(size: 13))
                .toggleStyle(.checkbox)
                .padding(.top, 10)

            Toggle("Organise images by source page", isOn: $viewModel.organizeImagesBySourcePage)
                .font(.system(size: 13))
                .toggleStyle(.checkbox)
                .padding(.top, 10)

            Text("The `folioscraper` terminal command is installed automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 14)

            HStack(spacing: 8) {
                StatusPill(title: "Saved", value: viewModel.savedCount, style: .success)
                StatusPill(title: "Failed", value: viewModel.failedCount, style: .failure)
                StatusPill(title: "Found", value: viewModel.foundCount, style: .neutral)
            }
            .padding(.top, 24)

            if viewModel.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 18)
            }

            Spacer()
        }
        .padding(.horizontal, 30)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Queue")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 26)

            Text(viewModel.queueSummary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            ScrollView {
                QueueListView(
                    currentJob: viewModel.currentJob,
                    queuedJobs: viewModel.queuedJobs,
                    draggedQueuedJob: $draggedQueuedJob,
                    removeQueuedJob: { id in
                        viewModel.removeQueuedJob(id: id)
                    },
                    moveQueuedJob: { draggedID, targetID in
                        viewModel.moveQueuedJob(id: draggedID, before: targetID)
                    }
                )
            }
            .frame(height: 205)
            .padding(.top, 12)

            Text("Log console")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 24)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.logEntries.suffix(12).reversed().enumerated()), id: \.offset) { _, entry in
                        SidebarRow(title: nil, message: entry, monospaced: true)
                    }
                }
            }
            .frame(height: 262)
            .padding(.top, 12)

            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

private struct QueueListView: View {
    let currentJob: QueuedJob?
    let queuedJobs: [QueuedJob]
    @Binding var draggedQueuedJob: QueuedJob?
    let removeQueuedJob: (UUID) -> Void
    let moveQueuedJob: (UUID, UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let currentJob {
                QueueRow(message: currentJob.displayText)
            }

            ForEach(queuedJobs) { job in
                QueuePendingRow(
                    job: job,
                    draggedQueuedJob: $draggedQueuedJob,
                    removeQueuedJob: removeQueuedJob,
                    moveQueuedJob: moveQueuedJob
                )
            }
        }
    }
}

private struct QueuePendingRow: View {
    let job: QueuedJob
    @Binding var draggedQueuedJob: QueuedJob?
    let removeQueuedJob: (UUID) -> Void
    let moveQueuedJob: (UUID, UUID) -> Void

    var body: some View {
        QueueRow(
            message: job.displayText,
            messageColor: Color(nsColor: .secondaryLabelColor),
            onDelete: {
                removeQueuedJob(job.id)
            }
        )
        .onDrag {
            draggedQueuedJob = job
            return NSItemProvider(object: job.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: QueueDropDelegate(
                targetJob: job,
                draggedQueuedJob: $draggedQueuedJob,
                moveAction: moveQueuedJob
            )
        )
    }
}

private struct StatusPill: View {
    enum Style {
        case neutral
        case success
        case failure

        var textColor: Color {
            switch self {
            case .neutral:
                Color(nsColor: .secondaryLabelColor)
            case .success:
                Color(nsColor: .systemGreen)
            case .failure:
                Color(nsColor: .systemRed)
            }
        }

        var backgroundColor: Color {
            switch self {
            case .neutral:
                Color(nsColor: .secondaryLabelColor).opacity(0.12)
            case .success:
                Color(nsColor: .systemGreen).opacity(0.14)
            case .failure:
                Color(nsColor: .systemRed).opacity(0.14)
            }
        }
    }

    let title: String
    let value: Int
    let style: Style

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(style.textColor)
                .lineLimit(1)

            Text("\(value)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(style.textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule(style: .continuous)
                .fill(style.backgroundColor)
        )
        .fixedSize()
    }
}

private struct SidebarRow: View {
    let title: String?
    let message: String
    let monospaced: Bool
    var messageColor: Color = Color(nsColor: .labelColor).opacity(0.9)

    var bodyViewFont: Font {
        monospaced ? .system(size: 12.5, weight: .regular, design: .monospaced) : .system(size: 13)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if !message.isEmpty {
                Text(message)
                    .font(bodyViewFont)
                    .foregroundStyle(messageColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct QueueRow: View {
    let message: String
    var messageColor: Color = Color(nsColor: .labelColor).opacity(0.9)
    var onDelete: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(messageColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct QueueDropDelegate: DropDelegate {
    let targetJob: QueuedJob
    @Binding var draggedQueuedJob: QueuedJob?
    let moveAction: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedQueuedJob, draggedQueuedJob.id != targetJob.id else { return }
        moveAction(draggedQueuedJob.id, targetJob.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedQueuedJob = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}
