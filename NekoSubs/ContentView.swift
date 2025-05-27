//
//  ContentView.swift
//  NekoSubs
//
//  Created by 千葉牧人 on 2025/5/27.
//


import SwiftUI
import UniformTypeIdentifiers


struct VideoItem {
    var videoURL: URL
    var subtitleURL: URL?
}

struct FileDropView: View {
    @Binding var videoItems: [VideoItem]

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .frame(height: 100)
            .overlay(Text("拖曳影片檔案到這裡").foregroundColor(.gray))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   isVideoFile(url) {
                    DispatchQueue.main.async {
                        var newItem = VideoItem(videoURL: url)
                        newItem.subtitleURL = autoMatchSubtitle(for: url)
                        videoItems.append(newItem)
                    }
                }
            }
        }
        return true
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = ["mp4", "mkv", "avi", "mov", "flv", "webm"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    private func autoMatchSubtitle(for videoURL: URL) -> URL? {
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let folder = videoURL.deletingLastPathComponent()
        let fm = FileManager.default
        let possibleSubs = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(baseName) && ["srt", "ass"].contains($0.pathExtension.lowercased()) }
        return possibleSubs?.first
    }
}

struct ContentView: View {
    enum CompressionLevel: String, CaseIterable, Identifiable {
        case fast, medium, slow
        var id: String { self.rawValue }
    }
    @State private var videoItems: [VideoItem] = []
    @State private var outputDirectory: URL? = nil
    @State private var isMerging = false
    @State private var currentIndex = 0
    @State private var isCancelled = false
    @State private var showMergeCompleteAlert = false
    @State private var outputFormat = "mp4"
    @State private var currentMessage = ""
    @State private var currentProcess: Process? = nil
    @State private var compressionLevel: CompressionLevel = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("🎬 拖曳影片檔至下方區域")
                .font(.headline)

            FileDropView(videoItems: $videoItems)

            List {
                ForEach(videoItems.indices, id: \.self) { index in
                    HStack {
                        Text(videoItems[index].videoURL.lastPathComponent)
                            .lineLimit(1)
                        Spacer()
                        if let subtitle = videoItems[index].subtitleURL {
                            Text(subtitle.lastPathComponent)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("尚未選擇字幕")
                                .foregroundColor(.red)
                        }
                    }
                    .contextMenu {
                        Button("選擇字幕檔") {
                            selectSubtitle(for: index)
                        }
                        Button("移除此影片", role: .destructive) {
                            videoItems.remove(at: index)
                        }
                    }
                }
                .onDelete { indices in
                    videoItems.remove(atOffsets: indices)
                }
            }
            .frame(height: 200)

            HStack {
                Button("選擇輸出資料夾") {
                    selectOutputDirectory()
                }

                if let output = outputDirectory {
                    Text("輸出到：\(output.path)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Picker("輸出格式", selection: $outputFormat) {
                Text("MKV").tag("mkv")
                Text("MP4").tag("mp4")
            }
            .pickerStyle(SegmentedPickerStyle())

            Picker("壓縮選項", selection: $compressionLevel) {
                Text("速度模式")
                    .tag(CompressionLevel.fast)
                    .help("快速轉檔，檔案大，畫質最佳")
                Text("平衡模式")
                    .tag(CompressionLevel.medium)
                    .help("畫質與檔案大小之間的平衡（推薦）")
                Text("品質模式")
                    .tag(CompressionLevel.slow)
                    .help("壓縮率最高，檔案最小，但畫質會降低")
            }
            .pickerStyle(SegmentedPickerStyle())

            ProgressView(value: isMerging ? Double(currentIndex) / Double(videoItems.count) : 0)
                .padding(.vertical, 8)

            if !currentMessage.isEmpty {
                Text(currentMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("開始合併") {
                    startMerging()
                }
                .disabled(isMerging)

                Button("取消") {
                    isCancelled = true
                    currentProcess?.terminate()
                }
                .disabled(!isMerging)
            }
        }
        .padding()
        .alert("合併完成", isPresented: $showMergeCompleteAlert) {
            Button("確定", role: .cancel) {}
        }
    }

    private func selectSubtitle(for index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt")!,
            UTType(filenameExtension: "ass")!
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                videoItems[index].subtitleURL = url
            }
        }
    }

    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK {
                outputDirectory = panel.url
            }
        }
    }

    private func startMerging() {
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            print("⚠️ 找不到 ffmpeg 可執行檔")
            return
        }

        isMerging = true
        isCancelled = false
        currentIndex = 0

        DispatchQueue.global(qos: .userInitiated).async {
            for (i, item) in videoItems.enumerated() {
                if isCancelled {
                    break
                }

                DispatchQueue.main.async {
                    currentMessage = "正在處理 \(item.videoURL.lastPathComponent)"
                }

                let inputVideo = item.videoURL.path
                let outputFolder = outputDirectory ?? item.videoURL.deletingLastPathComponent()
                let outputFilename = item.videoURL.deletingPathExtension().lastPathComponent + "_merged.\(outputFormat)"
                let outputPath = outputFolder.appendingPathComponent(outputFilename).path

                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                currentProcess = process

                var args: [String] = ["-i", inputVideo]

                if let subtitleURL = item.subtitleURL {
                    args += [
                        "-vf", "subtitles='\(subtitleURL.path)':charenc=UTF-8"
                    ]
                }

                args += ["-c:a", "copy"]

                switch compressionLevel {
                case .fast:
                    args += ["-c:v", "libx264", "-crf", "18"]
                case .medium:
                    args += ["-c:v", "libx264", "-crf", "23"]
                case .slow:
                    args += ["-c:v", "libx264", "-crf", "28"]
                }

                args.append(outputPath)
                process.arguments = args

                do {
                    try process.run()
                    process.waitUntilExit()
                    DispatchQueue.main.async {
                        currentIndex = i + 1
                    }
                    print("✅ 完成：\(outputFilename)")
                } catch {
                    print("❌ 失敗：\(outputFilename) - \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                isMerging = false
                showMergeCompleteAlert = true
                currentMessage = ""
                currentProcess = nil
            }
        }
    }
}

#Preview {
    ContentView()
}
