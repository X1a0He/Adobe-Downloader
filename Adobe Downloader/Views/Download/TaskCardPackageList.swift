import SwiftUI

struct TaskCardPackageList: View {
    let task: NewDownloadTask
    @State private var expandedProducts: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if DEBUG
            HStack(spacing: 8) {
                debugPersistenceButton
                if case .completed = task.status, task.productId != "APRO" {
                    commandLineInstallButton
                }
                Spacer()
                copyAllButton
            }
            #else
            HStack {
                Spacer()
                copyAllButton
            }
            #endif

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(task.dependenciesToDownload, id: \.sapCode) { product in
                        PackageProductRow(
                            product: product,
                            isExpanded: expandedProducts.contains(product.sapCode),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if expandedProducts.contains(product.sapCode) {
                                        expandedProducts.remove(product.sapCode)
                                    } else {
                                        expandedProducts.insert(product.sapCode)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
        }
    }

    @State private var showCopyAllAlert = false

    private var copyAllButton: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(generateAllProductsInfo(), forType: .string)
            showCopyAllAlert = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCopyAllAlert = false }
        }) {
            Label(String(localized: "复制所有信息"), systemImage: "doc.on.clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .buttonStyle(GlassButtonStyle(tint: .green))
        .popover(isPresented: $showCopyAllAlert, arrowEdge: .leading) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("已复制所有信息").font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    #if DEBUG
    private var debugPersistenceButton: some View {
        Button(action: {
            let containerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let tasksDirectory = containerURL.appendingPathComponent("Adobe Downloader/tasks", isDirectory: true)
            let fileName = "\(task.productId == "APRO" ? "Adobe Downloader \(task.productId)_\(task.productVersion)_\(task.platform)" : "Adobe Downloader \(task.productId)_\(task.productVersion)-\(task.language)-\(task.platform)")-task.json"
            let fileURL = tasksDirectory.appendingPathComponent(fileName)
            NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: tasksDirectory.path)
        }) {
            Label(String(localized: "持久化文件"), systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .buttonStyle(GlassButtonStyle(tint: .blue))
    }

    @State private var showCommandLineInstall = false
    @State private var showCommandCopied = false

    private var commandLineInstallButton: some View {
        Button(action: { showCommandLineInstall.toggle() }) {
            Label(String(localized: "命令行安装"), systemImage: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
        .buttonStyle(GlassButtonStyle(tint: .purple))
        .popover(isPresented: $showCommandLineInstall, arrowEdge: .bottom) {
            let setupPath = "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup"
            let driverPath = "\(task.directory.path)/driver.xml"
            let command = "sudo \"\(setupPath)\" --install=1 --driverXML=\"\(driverPath)\""
            VStack(alignment: .leading, spacing: 8) {
                Button(String(localized: "复制命令")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    showCommandCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showCommandCopied = false }
                }
                .buttonStyle(GlassButtonStyle(tint: .purple))
                .foregroundColor(.white)

                if showCommandCopied {
                    Text("已复制").font(.caption).foregroundColor(.green)
                }

                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            }
            .padding()
            .frame(width: 400)
        }
    }
    #endif

    private func generateAllProductsInfo() -> String {
        var result = ""
        for (index, product) in task.dependenciesToDownload.enumerated() {
            if product.sapCode == "APRO" {
                result += "\(product.sapCode) \(product.version)\n"
            } else {
                result += "\(product.sapCode) \(product.version) - (\(product.buildGuid))\n"
            }
            for (pkgIndex, package) in product.packages.enumerated() {
                let prefix = pkgIndex == product.packages.count - 1 ? "    └── " : "    ├── "
                result += "\(prefix)\(package.fullPackageName) (\(package.packageVersion)) - \(package.type)\n"
            }
            if !product.selectedReason.isEmpty {
                result += "    依赖详情:\n"
                result += "    - targetReason: \(product.selectedReason.isEmpty ? "(无)" : product.selectedReason)\n"
            }
            if index < task.dependenciesToDownload.count - 1 { result += "\n" }
        }
        return result
    }
}

private struct PackageProductRow: View {
    @ObservedObject var product: DependenciesToDownload
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var showCopiedAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "cube.box.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.blue.opacity(0.8))

                    Text("\(product.sapCode) \(product.version)\(product.sapCode != "APRO" ? " - (\(product.buildGuid))" : "")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.8))

                    if product.sapCode != "APRO" {
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(product.buildGuid, forType: .string)
                            showCopiedAlert = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedAlert = false }
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(GlassButtonStyle(tint: .blue))
                        .help(String(localized: "复制 buildGuid"))
                        .popover(isPresented: $showCopiedAlert, arrowEdge: .trailing) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text("已复制").font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                    }

                    Spacer()

                    Text("\(product.completedPackages)/\(product.totalPackages)")
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(4)
                        .foregroundColor(.primary.opacity(0.7))

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(product.packages) { package in
                        PackageItemRow(package: package)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}

private struct PackageItemRow: View {
    @ObservedObject var package: Package

    private var clampedProgress: Double {
        min(max(package.progress, 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(package.fullPackageName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(1)

                Text(package.type)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue.opacity(0.8))
                    .cornerRadius(3)

                Text(package.formattedSize)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))

                Spacer()

                packageStatusView
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)

            if package.status == .downloading {
                VStack(spacing: 4) {
                    ProgressView(value: clampedProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue.opacity(0.8))

                    HStack {
                        Text("\(package.formattedDownloadedSize) / \(package.formattedSize)")
                            .font(.system(size: 10))
                            .foregroundColor(.primary.opacity(0.7))
                        Spacer()
                        if package.speed > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down").font(.system(size: 8))
                                Text(DownloadFormatters.speed(package.speed)).font(.system(size: 10))
                            }
                            .foregroundColor(.blue.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var packageStatusView: some View {
        switch package.status {
        case .waiting:
            HStack(spacing: 3) {
                Image(systemName: "hourglass.circle.fill").font(.system(size: 9))
                Text(package.status.description).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.secondary.opacity(0.8))
        case .downloading:
            Text("\(Int(clampedProgress * 100))%")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.blue.opacity(0.9))
        case .completed:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                Text(package.status.description).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.green.opacity(0.9))
        default:
            Text(package.status.description)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.8))
        }
    }
}
