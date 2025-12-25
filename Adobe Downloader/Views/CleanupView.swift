//
//  CleanupView.swift
//  Adobe Downloader
//
//  Created by X1a0He on 3/28/25.
//
import SwiftUI

final class CleanupViewModel: ObservableObject {
    @Published var showConfirmation = false
    @Published var showAlert = false
    @Published var alertMessage = ""

    @Published var selectedOptions = Set<CleanupOption>()
    @Published var isProcessing = false
    @Published var cleanupLogs: [CleanupLog] = []
    @Published var currentCommandIndex = 0
    @Published var totalCommands = 0
    @Published var expandedOptions = Set<CleanupOption>()
    @Published var isCancelled = false
    @Published var isLogExpanded = false

    private var commands: [String] = []

    func startCleanup() {
        isProcessing = true
        cleanupLogs.removeAll()
        currentCommandIndex = 0
        isCancelled = false

        let userHome = NSHomeDirectory()

        var collected: [String] = []
        for option in selectedOptions {
            let userCommands = option.commands.map { command in
                command.replacingOccurrences(of: "~/", with: "\(userHome)/")
            }
            collected.append(contentsOf: userCommands)
        }

        commands = collected
        totalCommands = commands.count

        executeNextCommand()
    }

    func cancelCleanup() {
        isCancelled = true
    }

    private func finishCleanup(message: String) {
        isProcessing = false
        alertMessage = message
        showAlert = true
        selectedOptions.removeAll()
    }

    private func executeNextCommand() {
        guard currentCommandIndex < commands.count else {
            DispatchQueue.main.async {
                self.finishCleanup(message: self.isCancelled ? String(localized: "清理已取消") : String(localized: "清理完成"))
            }
            return
        }

        if isCancelled {
            DispatchQueue.main.async {
                self.finishCleanup(message: String(localized: "清理已取消"))
            }
            return
        }

        let command = commands[currentCommandIndex]
        cleanupLogs.append(
            CleanupLog(
                timestamp: Date(),
                command: command,
                status: .running,
                message: String(localized: "正在执行...")
            )
        )

        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global())
        timeoutTimer.schedule(deadline: .now() + 30)
        timeoutTimer.setEventHandler { [weak self] in
            guard let self else { return }
            if let index = self.cleanupLogs.lastIndex(where: { $0.command == command }) {
                DispatchQueue.main.async {
                    self.cleanupLogs[index] = CleanupLog(
                        timestamp: Date(),
                        command: command,
                        status: .error,
                        message: String(localized: "执行结果：执行超时\n执行命令：\(command)")
                    )
                    self.currentCommandIndex += 1
                    self.executeNextCommand()
                }
            }
        }
        timeoutTimer.resume()

        PrivilegedHelperAdapter.shared.executeCommand(command) { [weak self] (output: String) in
            timeoutTimer.cancel()
            guard let self else { return }
            DispatchQueue.main.async {
                if let index = self.cleanupLogs.lastIndex(where: { $0.command == command }) {
                    if self.isCancelled {
                        self.cleanupLogs[index] = CleanupLog(
                            timestamp: Date(),
                            command: command,
                            status: .cancelled,
                            message: String(localized: "已取消")
                        )
                    } else {
                        let isSuccess = output.isEmpty || output.lowercased() == "success"
                        let message = if isSuccess {
                            String(localized: "执行成功")
                        } else {
                            String(localized: "执行结果：\(output)\n执行命令：\(command)")
                        }
                        self.cleanupLogs[index] = CleanupLog(
                            timestamp: Date(),
                            command: command,
                            status: isSuccess ? .success : .error,
                            message: message
                        )
                    }
                }
                self.currentCommandIndex += 1
                self.executeNextCommand()
            }
        }
    }
}

struct CleanupView: View {
    @ObservedObject var viewModel: CleanupViewModel

    init(viewModel: CleanupViewModel = CleanupViewModel()) {
        self.viewModel = viewModel
    }
    
    private var percentage: Int {
        viewModel.totalCommands > 0
            ? Int((Double(viewModel.currentCommandIndex) / Double(viewModel.totalCommands)) * 100)
            : 0
    }
    
    private func calculateProgressWidth(_ width: CGFloat) -> CGFloat {
        if viewModel.totalCommands <= 0 {
            return 0
        }
        let progress = Double(viewModel.currentCommandIndex) / Double(viewModel.totalCommands)
        let clampedProgress = min(1.0, max(0.0, progress))
        return width * CGFloat(clampedProgress)
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("选择要清理的内容")
                .font(.headline)
                .padding(.bottom, 4)

            Text("注意：清理过程不会影响 Adobe Downloader 的文件和下载数据")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading) {
                    ForEach(CleanupOption.allCases) { option in
                        CleanupOptionView(
                            option: option,
                            isProcessing: viewModel.isProcessing,
                            selectedOptions: $viewModel.selectedOptions,
                            expandedOptions: $viewModel.expandedOptions
                        )
                        .id(option.id)
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isProcessing {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("清理进度：\(viewModel.currentCommandIndex)/\(viewModel.totalCommands)")
                                .font(.system(size: 12, weight: .medium))

                            Spacer()

                            Text("\(percentage)%")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 2)

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 12)

                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue]),
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: calculateProgressWidth(geometry.size.width), height: 12)
                            }
                        }
                        .frame(height: 12)
                        .animation(.linear(duration: 0.3), value: viewModel.currentCommandIndex)

                        Button(action: {
                            viewModel.cancelCleanup()
                        }) {
                            Text("取消清理")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(BeautifulButtonStyle(baseColor: Color.red.opacity(0.8)))
                        .disabled(viewModel.isCancelled)
                        .opacity(viewModel.isCancelled ? 0.5 : 1)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )

                    if let lastLog = viewModel.cleanupLogs.last {
                        CurrentLogView(lastLog: lastLog)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    Button(action: {
                        withAnimation {
                            viewModel.isLogExpanded.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.blue.opacity(0.8))

                            Text("最近日志：")
                                .font(.system(size: 12, weight: .medium))

                            if viewModel.isProcessing {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)

                                    Text("正在执行...")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                            }

                            Spacer()

                            Text(viewModel.isLogExpanded ? "收起" : "展开")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                                .padding(.trailing, 4)

                            Image(systemName: viewModel.isLogExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ScrollView {
                        if viewModel.cleanupLogs.isEmpty {
                            EmptyLogView()
                        } else {
                            LogContentView(
                                logs: viewModel.cleanupLogs,
                                isExpanded: viewModel.isLogExpanded
                            )
                        }
                    }
                    .frame(height: viewModel.cleanupLogs.isEmpty ? 80 : (viewModel.isLogExpanded ? 220 : 54))
                    .animation(.easeInOut(duration: 0.3), value: viewModel.isLogExpanded)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                    .cornerRadius(6)
                    .padding(.bottom, 1)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }

            HStack(spacing: 10) {
                Group {
                    Button(action: {
                        viewModel.selectedOptions = Set(CleanupOption.allCases)
                    }) {
                        Text("全选")
                            .frame(minWidth: 50)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.blue.opacity(0.7)))
                    .foregroundColor(.white)

                    Button(action: {
                        viewModel.selectedOptions.removeAll()
                    }) {
                        Text("取消全选")
                            .frame(minWidth: 65)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.gray.opacity(0.7)))
                    .foregroundColor(.white)

                    #if DEBUG
                    Button(action: {
                        if viewModel.expandedOptions.count == CleanupOption.allCases.count {
                            viewModel.expandedOptions.removeAll()
                        } else {
                            viewModel.expandedOptions = Set(CleanupOption.allCases)
                        }
                    }) {
                        Text(viewModel.expandedOptions.count == CleanupOption.allCases.count ? "折叠全部" : "展开全部")
                            .frame(minWidth: 65)
                    }
                    .buttonStyle(BeautifulButtonStyle(baseColor: Color.purple.opacity(0.7)))
                    .foregroundColor(.white)
                    #endif
                }
                .disabled(viewModel.isProcessing)

                Spacer()

                Button(action: {
                    if !viewModel.selectedOptions.isEmpty {
                        viewModel.showConfirmation = true
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("开始清理")
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(BeautifulButtonStyle(baseColor: Color.red.opacity(0.8)))
                .foregroundColor(.white)
                .opacity(viewModel.selectedOptions.isEmpty || viewModel.isProcessing ? 0.5 : 1)
                .saturation(viewModel.selectedOptions.isEmpty || viewModel.isProcessing ? 0.3 : 1)
                .disabled(viewModel.selectedOptions.isEmpty || viewModel.isProcessing)
            }
            .padding(.top, 6)
        }
        .padding()
        .alert("确认清理", isPresented: $viewModel.showConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确定", role: .destructive) {
                viewModel.startCleanup()
            }
        } message: {
            Text("这将删除所选的 Adobe 相关文件，该操作不可撤销。清理过程不会影响 Adobe Downloader 的文件和下载数据。是否继续？")
        }
        .alert(isPresented: $viewModel.showAlert) {
            Alert(
                title: Text("清理结果"),
                message: Text(viewModel.alertMessage),
                dismissButton: .default(Text("确定"))
            )
        }
    }

    private func statusIcon(for status: CleanupLog.LogStatus) -> String {
        switch status {
        case .running:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        }
    }

    private func statusColor(for status: CleanupLog.LogStatus) -> Color {
        switch status {
        case .running:
            return .blue
        case .success:
            return .green
        case .error:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct CleanupOptionView: View {
    let option: CleanupOption
    let isProcessing: Bool
    @Binding var selectedOptions: Set<CleanupOption>
    @Binding var expandedOptions: Set<CleanupOption>
    
    private var isExpanded: Bool {
        expandedOptions.contains(option)
    }
    
    private var isSelected: Bool {
        selectedOptions.contains(option)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            #if DEBUG
            Button(action: {
                let animation = Animation.easeInOut(duration: 0.2)
                withAnimation(animation) {
                    if expandedOptions.contains(option) {
                        expandedOptions.remove(option)
                    } else {
                        expandedOptions.insert(option)
                    }
                }
            }) {
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { isSelected },
                        set: { isSelected in
                            if isSelected {
                                selectedOptions.insert(option)
                            } else {
                                selectedOptions.remove(option)
                            }
                        }
                    )) {
                        EmptyView()
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                    .disabled(isProcessing)
                    .labelsHidden()
                    .scaleEffect(0.85)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.localizedName)
                            .font(.system(size: 15, weight: .semibold))
                        Text(option.description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)

            if isExpanded {
                CommandListView(option: option)
            }
            #else
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { selectedOptions.contains(option) },
                    set: { isSelected in
                        if isSelected {
                            selectedOptions.insert(option)
                        } else {
                            selectedOptions.remove(option)
                        }
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(SwitchToggleStyle(tint: .green))
                .disabled(isProcessing)
                .labelsHidden()
                .scaleEffect(0.85)

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.localizedName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(option.description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            #endif
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

struct CommandListView: View {
    let option: CleanupOption
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("将执行的命令：")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.top, 2)
                .padding(.horizontal, 12)

            LazyVStack(spacing: 6) {
                ForEach(option.commands, id: \.self) { command in
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(.white))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(6)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

struct CurrentLogView: View {
    let lastLog: CleanupLog
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .foregroundColor(.blue.opacity(0.8))
                    .font(.system(size: 14))

                Text("当前执行：")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            #if DEBUG
            Text(lastLog.command)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            #else
            Text(CleanupLog.getCleanupDescription(for: lastLog.command))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
        .frame(height: 70)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct EmptyLogView: View {
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary.opacity(0.6))

                Text("暂无清理记录")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }
}

struct LogContentView: View {
    let logs: [CleanupLog]
    let isExpanded: Bool
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(alignment: .leading, spacing: 8) {
                if isExpanded {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(logs.reversed()) { log in
                            LogEntryView(log: log)
                                .id(log.id)
                        }
                    }
                } else if let lastLog = logs.last {
                    LogEntryView(log: lastLog)
                        .id(lastLog.id)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .onChange(of: logs.count) { newCount in
                if let lastLog = logs.last {
                    withAnimation {
                        scrollProxy.scrollTo(lastLog.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
