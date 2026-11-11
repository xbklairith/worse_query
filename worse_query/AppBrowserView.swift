import SwiftUI
import ZIPFoundation

struct AppBrowserView: View {
    @Binding var containers: [AppContainer]
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var dumping = false
    @State private var zipping = false
    @State private var zippingBundleId: String?

    var selectedCount: Int {
        containers.flatMap { $0.files }.filter { $0.selected }.count
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach($containers) { $app in
                    Section {
                        ForEach($app.files) { $file in
                            HStack {
                                Image(systemName: file.selected ? "checkmark.square.fill" : "square")
                                    .foregroundColor(file.selected ? .blue : .secondary)
                                    .onTapGesture { file.selected.toggle() }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.relativePath)
                                        .font(.system(.caption2, design: .monospaced))
                                        .lineLimit(2)
                                    Text(formatSize(file.size))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(app.bundleId)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            // Zip whole container
                            let isZipping = zipping && zippingBundleId == app.bundleId
                            Button(isZipping ? "Zipping…" : "Zip") {
                                zipContainer(app)
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .disabled(zipping)
                            // Select / deselect all files
                            let allSelected = app.files.allSatisfy { $0.selected }
                            Button(allSelected ? "Deselect All" : "Dump All") {
                                let idx = containers.firstIndex(where: { $0.id == app.id })!
                                let newVal = !allSelected
                                for j in containers[idx].files.indices {
                                    containers[idx].files[j].selected = newVal
                                }
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .tint(allSelected ? .red : .green)
                        }
                    }
                }
            }
            .navigationTitle("File Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    if selectedCount > 0 {
                        Button(dumping ? "Dumping…" : "Dump \(selectedCount) file(s)") {
                            dumpSelected()
                        }
                        .disabled(dumping)
                        .buttonStyle(.borderedProminent)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Select All") {
                        for i in containers.indices {
                            for j in containers[i].files.indices {
                                containers[i].files[j].selected = true
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = shareURL { ShareSheet(url: url) }
            }
        }
    }

    private func dumpSelected() {
        dumping = true
        DispatchQueue.global(qos: .userInitiated).async {
            var entries: [DumpEntry] = []
            // group selected files by container
            for app in containers {
                let selected = app.files.filter { $0.selected }
                guard !selected.isEmpty else { continue }
                // re-escape sandbox for this container
                let isAppGroup = app.containerPath.contains("/Shared/AppGroup")
                let needsWorkaround = isAppGroup && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
                let handle = worse_query(app.containerPath, "group.com.xb.wqtest", needsWorkaround, false)
                guard handle > 0 else { continue }

                for file in selected {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: file.absolutePath)) {
                        entries.append(DumpEntry(
                            bundleId: app.bundleId,
                            file: file.relativePath,
                            sizeBytes: file.size,
                            content: data.base64EncodedString()
                        ))
                    }
                }
                worse_query_release(handle)
            }

            // write JSON
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(entries) else {
                DispatchQueue.main.async { dumping = false }
                return
            }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = docs.appendingPathComponent("dump-\(formatter.string(from: Date())).json")
            try? data.write(to: url)

            DispatchQueue.main.async {
                dumping = false
                shareURL = url
                showShare = true
            }
        }
    }

    private func zipContainer(_ app: AppContainer) {
        zipping = true
        zippingBundleId = app.bundleId
        DispatchQueue.global(qos: .userInitiated).async {
            let isAppGroup = app.containerPath.contains("/Shared/AppGroup")
            let needsWorkaround = isAppGroup && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
            let handle = worse_query(app.containerPath, "group.com.xb.wqtest", needsWorkaround, false)
            guard handle > 0 else {
                DispatchQueue.main.async { zipping = false; zippingBundleId = nil }
                return
            }

            let fm = FileManager.default
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "\(app.bundleId)-\(formatter.string(from: Date())).zip"
            let zipURL = fm.temporaryDirectory.appendingPathComponent(name)
            try? fm.removeItem(at: zipURL)

            let sourceURL = URL(fileURLWithPath: app.containerPath)
            do {
                try fm.zipItem(at: sourceURL, to: zipURL, shouldKeepParent: false)
            } catch {
                DispatchQueue.main.async { zipping = false; zippingBundleId = nil }
                worse_query_release(handle)
                return
            }
            worse_query_release(handle)

            DispatchQueue.main.async {
                zipping = false
                zippingBundleId = nil
                shareURL = zipURL
                showShare = true
            }
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
