// Photos library indexer + text search prototype.
// Build:  swiftc -O image_search.swift -o image_search
// Run:    ./image_search index [--limit N]
//         ./image_search search "your text query"
//         ./image_search show <localIdentifier>     # open in Photos.app
//
// First run prompts macOS for Photos library access.

import Foundation
import Vision
import Photos
import AppKit
import CoreImage

// ----- paths -----------------------------------------------------------

let here = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().path
let indexPath = "\(here)/index.json"

// ----- model -----------------------------------------------------------

struct Entry: Codable {
    var id: String                   // PHAsset.localIdentifier
    var creationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var labels: [LabelHit]           // [(label, confidence)]
    var ocr: String
    var featurePrint: [Float]        // 768-d
}

struct LabelHit: Codable {
    var name: String
    var confidence: Float
}

// ----- Photos auth -----------------------------------------------------

func requestAuth() async -> PHAuthorizationStatus {
    await withCheckedContinuation { cont in
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            cont.resume(returning: status)
        }
    }
}

// ----- fetch assets ----------------------------------------------------

func fetchAssets(limit: Int) -> [PHAsset] {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    opts.fetchLimit = limit
    let result = PHAsset.fetchAssets(with: .image, options: opts)
    var arr: [PHAsset] = []
    result.enumerateObjects { asset, _, _ in arr.append(asset) }
    return arr
}

// ----- load CGImage from asset -----------------------------------------

func loadCGImage(for asset: PHAsset) async -> CGImage? {
    // Use requestImageDataAndOrientation — more reliable than requestImage on macOS.
    // The callback fires exactly once with the original data (or nil if iCloud-only
    // and download fails). 10-second timeout guards against silent hangs.
    let didResume = NSLock()
    var resumed = false

    return await withCheckedContinuation { cont in
        let opts = PHImageRequestOptions()
        opts.isSynchronous = false
        opts.deliveryMode = .fastFormat                // accept any resolution
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false            // skip iCloud-only photos
        opts.isSynchronous = false

        let resumeOnce: (CGImage?) -> Void = { img in
            didResume.lock()
            defer { didResume.unlock() }
            if !resumed { resumed = true; cont.resume(returning: img) }
        }

        // 10-second hard timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            resumeOnce(nil)
        }

        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) {
            data, _, _, info in
            guard let data,
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                resumeOnce(nil)
                return
            }
            resumeOnce(cg)
        }
    }
}

// ----- vision requests -------------------------------------------------

func runVision(on image: CGImage) -> (labels: [LabelHit], ocr: String, fp: [Float]) {
    let classify = VNClassifyImageRequest()
    let textReq = VNRecognizeTextRequest()
    textReq.recognitionLevel = .accurate
    textReq.usesLanguageCorrection = true
    let fpReq = VNGenerateImageFeaturePrintRequest()

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try? handler.perform([classify, textReq, fpReq])

    let labelHits: [LabelHit] = (classify.results ?? [])
        .filter { $0.confidence >= 0.25 }
        .prefix(15)
        .map { LabelHit(name: $0.identifier, confidence: $0.confidence) }

    let ocrText = (textReq.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")

    var fpVec: [Float] = []
    if let obs = fpReq.results?.first as? VNFeaturePrintObservation {
        let n = obs.elementCount
        fpVec = [Float](repeating: 0, count: n)
        obs.data.withUnsafeBytes { buf in
            let f = buf.bindMemory(to: Float.self)
            for i in 0..<n { fpVec[i] = f[i] }
        }
    }
    return (labelHits, ocrText, fpVec)
}

// ----- index folder command (walks a directory of image files) --------

func cmdIndexFolder(path: String) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let fm = FileManager.default
    guard let enumr = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else {
        FileHandle.standardError.write(Data("Cannot enumerate \(url.path)\n".utf8))
        exit(2)
    }
    let imageExts: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","bmp","webp","gif"]
    var files: [URL] = []
    for case let f as URL in enumr {
        if imageExts.contains(f.pathExtension.lowercased()) {
            files.append(f)
        }
    }
    print("Found \(files.count) image files in \(url.path). Indexing…")

    var entries: [Entry] = []
    entries.reserveCapacity(files.count)
    let t0 = Date()
    for (i, file) in files.enumerated() {
        let tStart = Date()
        print("  [\(i+1)/\(files.count)] \(file.lastPathComponent)", terminator: " ")
        fflush(stdout)
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("skip: cannot decode")
            continue
        }
        let v = runVision(on: cg)
        let entry = Entry(
            id: file.path,
            creationDate: (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date,
            pixelWidth: cg.width,
            pixelHeight: cg.height,
            labels: v.labels,
            ocr: v.ocr,
            featurePrint: v.fp
        )
        entries.append(entry)
        let labelStr = v.labels.prefix(3).map { "\($0.name):\(String(format:"%.2f", $0.confidence))" }.joined(separator: ", ")
        let ocrSnippet = String(v.ocr.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        let totalMs = Int(Date().timeIntervalSince(tStart) * 1000)
        print("\(totalMs)ms  labels=[\(labelStr)]  ocr=\"\(ocrSnippet)\"")
    }
    let json = try! JSONEncoder().encode(entries)
    try? json.write(to: URL(fileURLWithPath: indexPath))
    print("\nIndexed \(entries.count)/\(files.count) files (\(json.count / 1024) KB) in \(Int(Date().timeIntervalSince(t0)))s")
    print("Index: \(indexPath)")
}

// ----- index command ---------------------------------------------------

func cmdIndex(limit: Int) async {
    let status = await requestAuth()
    guard status == .authorized || status == .limited else {
        FileHandle.standardError.write(Data("Photos access denied. Status=\(status.rawValue)\n".utf8))
        exit(2)
    }

    let assets = fetchAssets(limit: limit)
    print("Found \(assets.count) image assets. Indexing…")

    var entries: [Entry] = []
    entries.reserveCapacity(assets.count)

    let t0 = Date()
    for (i, asset) in assets.enumerated() {
        let tStart = Date()
        print("  [\(i+1)/\(assets.count)] loading…", terminator: " ")
        fflush(stdout)
        guard let cg = await loadCGImage(for: asset) else {
            print("skip: load failed/iCloud-only")
            continue
        }
        let loadMs = Int(Date().timeIntervalSince(tStart) * 1000)
        print("loaded(\(cg.width)x\(cg.height) in \(loadMs)ms), processing…", terminator: " ")
        fflush(stdout)
        let v = runVision(on: cg)
        let entry = Entry(
            id: asset.localIdentifier,
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            labels: v.labels,
            ocr: v.ocr,
            featurePrint: v.fp
        )
        entries.append(entry)

        let labelStr = v.labels.prefix(3).map { "\($0.name):\(String(format:"%.2f", $0.confidence))" }.joined(separator: ", ")
        let ocrSnippet = String(v.ocr.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        let totalMs = Int(Date().timeIntervalSince(tStart) * 1000)
        print("\(totalMs)ms  labels=[\(labelStr)]  ocr=\"\(ocrSnippet)\"")
    }

    let json = try! JSONEncoder().encode(entries)
    try? json.write(to: URL(fileURLWithPath: indexPath))
    print("\nWrote \(entries.count) entries (\(json.count / 1024) KB) in \(Int(Date().timeIntervalSince(t0)))s")
    print("Index: \(indexPath)")
}

// ----- search command --------------------------------------------------

func loadIndex() -> [Entry] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
          let arr = try? JSONDecoder().decode([Entry].self, from: data) else {
        FileHandle.standardError.write(Data("No index at \(indexPath). Run `index` first.\n".utf8))
        exit(3)
    }
    return arr
}

func scoreEntry(_ e: Entry, queryTokens: [String], queryRaw: String) -> Double {
    var score: Double = 0
    let ocrLower = e.ocr.lowercased()

    for token in queryTokens {
        // Label matches (weight 2x, scaled by confidence)
        for label in e.labels {
            let labelLower = label.name.lowercased()
            if labelLower == token {
                score += 4.0 * Double(label.confidence)
            } else if labelLower.contains(token) || token.contains(labelLower) {
                score += 2.0 * Double(label.confidence)
            }
        }
        // OCR word/substring match
        if ocrLower.contains(token) { score += 1.0 }
    }

    // Bonus: full query phrase in OCR
    if !queryRaw.isEmpty && ocrLower.contains(queryRaw.lowercased()) {
        score += 2.0
    }
    return score
}

func cmdSearch(query: String) {
    let entries = loadIndex()
    let tokens = query.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }

    let scored = entries.map { ($0, scoreEntry($0, queryTokens: tokens, queryRaw: query)) }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }

    print("Query: \"\(query)\"  tokens=\(tokens)")
    print("Matches: \(scored.count) (showing top 10)\n")

    if scored.isEmpty {
        print("No matches.")
        return
    }
    for (i, (e, score)) in scored.prefix(10).enumerated() {
        let date = e.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        let labelStr = e.labels.prefix(5).map { "\($0.name):\(String(format:"%.2f", $0.confidence))" }.joined(separator: ", ")
        let ocrSnippet = String(e.ocr.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        print("[\(i+1)] score=\(String(format:"%.2f", score))  \(date)  id=\(e.id.prefix(36))")
        print("     size=\(e.pixelWidth)x\(e.pixelHeight)  labels=[\(labelStr)]")
        if !ocrSnippet.isEmpty {
            print("     ocr=\"\(ocrSnippet)\"")
        }
        print("")
    }
}

// ----- show command (open in Photos.app via x-callback) ----------------

func cmdShow(localId: String) {
    // Photos.app accepts a special URL for assets; fallback to printing path
    print("PHAsset localIdentifier: \(localId)")
    print("(To open in Photos.app: use PHPhotoLibrary.shared() in an app; CLI can't open directly.)")
}

// ----- entry -----------------------------------------------------------

let argv = CommandLine.arguments
let usage = """
Usage:
  image_search index [--limit N]         Index first N photos from Photos.app (default 50)
  image_search index-folder <path>       Index all images in a folder (recursive)
  image_search search <query>            Search for text in labels + OCR
  image_search show <localId>            Print info about a PHAsset id
"""

guard argv.count >= 2 else { print(usage); exit(1) }

switch argv[1] {
case "index-folder":
    guard argv.count >= 3 else { print(usage); exit(1) }
    cmdIndexFolder(path: argv[2])

case "index":
    var limit = 50
    if let i = argv.firstIndex(of: "--limit"), i + 1 < argv.count, let v = Int(argv[i+1]) {
        limit = v
    }
    let sem = DispatchSemaphore(value: 0)
    Task {
        await cmdIndex(limit: limit)
        sem.signal()
    }
    sem.wait()

case "search":
    guard argv.count >= 3 else { print(usage); exit(1) }
    let q = argv.dropFirst(2).joined(separator: " ")
    cmdSearch(query: q)

case "show":
    guard argv.count >= 3 else { print(usage); exit(1) }
    cmdShow(localId: argv[2])

default:
    print(usage); exit(1)
}
