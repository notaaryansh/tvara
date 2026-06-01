// CLIP-based image search using Apple MobileCLIP-S2 (CoreML).
//
// Build:  swiftc -O clip_search.swift -o clip_search
// Run:    ./clip_search index <folder>           # encode images, save clip_index.json
//         ./clip_search search "query text"      # rank by cosine to query embedding
//
// Models expected at ./models/mobileclip_s2_{image,text}.mlmodelc
// Tokenizer:        ./clip_tokenize.py  (calls Python; uses transformers CLIPTokenizer)

import Foundation
import CoreML
import CoreImage
import AppKit
import Accelerate

let here = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().path
let modelsDir = "\(here)/models"
let indexFile = "\(here)/clip_index.json"
let tokenizerScript = "\(here)/clip_tokenize.py"
let imageInputSize = 256  // MobileCLIP-S2 takes 256x256 RGB

// ----- entry type --------------------------------------------------------

struct ClipEntry: Codable {
    var path: String
    var embedding: [Float]  // 512-d L2-normalised
}

// ----- model loading -----------------------------------------------------

func loadModel(at path: String) -> MLModel {
    let url = URL(fileURLWithPath: path)
    do {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all      // ANE + GPU + CPU as available
        return try MLModel(contentsOf: url, configuration: cfg)
    } catch {
        FileHandle.standardError.write(Data("Failed to load \(path): \(error)\n".utf8))
        exit(2)
    }
}

// ----- CGImage -> CVPixelBuffer (RGB, 256x256) ---------------------------

func makePixelBuffer(from cg: CGImage, w: Int, h: Int) -> CVPixelBuffer? {
    let attrs: NSDictionary = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     attrs as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buf),
        width: w, height: h,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                  | CGBitmapInfo.byteOrder32Little.rawValue
    )
    ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

// ----- image encoder -----------------------------------------------------

func encodeImage(_ cg: CGImage, model: MLModel) -> [Float]? {
    guard let pb = makePixelBuffer(from: cg, w: imageInputSize, h: imageInputSize) else {
        return nil
    }
    let input = try? MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(pixelBuffer: pb)
    ])
    guard let input,
          let result = try? model.prediction(from: input),
          let multi = result.featureValue(for: "final_emb_1")?.multiArrayValue else {
        return nil
    }
    return l2Normalize(extractFloats(multi))
}

// ----- text encoder ------------------------------------------------------

func encodeText(_ query: String, model: MLModel) -> [Float]? {
    guard let ids = tokenize(query) else { return nil }
    guard let arr = try? MLMultiArray(shape: [1, 77], dataType: .int32) else { return nil }
    for (i, id) in ids.enumerated() {
        arr[i] = NSNumber(value: id)
    }
    let input = try? MLDictionaryFeatureProvider(dictionary: [
        "text": MLFeatureValue(multiArray: arr)
    ])
    guard let input,
          let result = try? model.prediction(from: input),
          let multi = result.featureValue(for: "final_emb_1")?.multiArrayValue else {
        return nil
    }
    return l2Normalize(extractFloats(multi))
}

func tokenize(_ text: String) -> [Int32]? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["python3", tokenizerScript, text]
    let out = Pipe(); let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    do { try proc.run() } catch {
        FileHandle.standardError.write(Data("tokenize failed: \(error)\n".utf8))
        return nil
    }
    proc.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Int],
          arr.count == 77 else {
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        FileHandle.standardError.write(Data("tokenize bad output, stderr=\(stderr)\n".utf8))
        return nil
    }
    return arr.map { Int32($0) }
}

// ----- vector ops --------------------------------------------------------

func extractFloats(_ multi: MLMultiArray) -> [Float] {
    let n = multi.count
    var out = [Float](repeating: 0, count: n)
    let ptr = multi.dataPointer.bindMemory(to: Float.self, capacity: n)
    for i in 0..<n { out[i] = ptr[i] }
    return out
}

func l2Normalize(_ v: [Float]) -> [Float] {
    var sumSq: Float = 0
    vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
    let norm = sqrt(sumSq) + 1e-9
    var out = [Float](repeating: 0, count: v.count)
    var inv = 1.0 / norm
    vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
    return out
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    var r: Float = 0
    vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(a.count))
    return r
}

// ----- index command -----------------------------------------------------

func cmdIndex(folder: String) {
    let imgModel = loadModel(at: "\(modelsDir)/mobileclip_s2_image.mlmodelc")
    print("Loaded image encoder. Walking \(folder)…")

    let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
    let fm = FileManager.default
    guard let enumr = fm.enumerator(at: root,
                                    includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else {
        FileHandle.standardError.write(Data("cannot enumerate \(root.path)\n".utf8))
        exit(2)
    }
    let imageExts: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","bmp","webp","gif"]
    var files: [URL] = []
    for case let f as URL in enumr {
        if imageExts.contains(f.pathExtension.lowercased()) { files.append(f) }
    }
    print("Found \(files.count) images. Encoding…")

    var entries: [ClipEntry] = []
    entries.reserveCapacity(files.count)
    let t0 = Date()
    for (i, f) in files.enumerated() {
        let tStart = Date()
        print("  [\(i+1)/\(files.count)] \(f.lastPathComponent)", terminator: " ")
        fflush(stdout)
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("skip: cannot decode"); continue
        }
        guard let emb = encodeImage(cg, model: imgModel) else {
            print("skip: encode failed"); continue
        }
        entries.append(ClipEntry(path: f.path, embedding: emb))
        let ms = Int(Date().timeIntervalSince(tStart) * 1000)
        print("\(ms)ms  emb[0..3]=[\(emb[0]),\(emb[1]),\(emb[2])]")
    }
    let json = try! JSONEncoder().encode(entries)
    try? json.write(to: URL(fileURLWithPath: indexFile))
    print("\nIndexed \(entries.count) images (\(json.count / 1024) KB) in \(Int(Date().timeIntervalSince(t0)))s")
    print("Index: \(indexFile)")
}

// ----- search command ----------------------------------------------------

func cmdSearch(query: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexFile)),
          let entries = try? JSONDecoder().decode([ClipEntry].self, from: data) else {
        FileHandle.standardError.write(Data("no index at \(indexFile). Run `index` first.\n".utf8))
        exit(3)
    }
    let txtModel = loadModel(at: "\(modelsDir)/mobileclip_s2_text.mlmodelc")
    print("Loaded text encoder. Encoding query…")
    guard let qVec = encodeText(query, model: txtModel) else {
        FileHandle.standardError.write(Data("text encode failed\n".utf8))
        exit(4)
    }

    let scored = entries.map { ($0, dot(qVec, $0.embedding)) }
        .sorted { $0.1 > $1.1 }

    print("Query: \"\(query)\"")
    print("Indexed: \(entries.count) images. Top 10:\n")
    for (i, (e, s)) in scored.prefix(10).enumerated() {
        let name = (e.path as NSString).lastPathComponent
        print("[\(i+1)] cosine=\(String(format:"%.3f", s))  \(name)")
        print("     \(e.path)")
    }
}

// ----- entry -------------------------------------------------------------

let argv = CommandLine.arguments
let usage = """
Usage:
  clip_search index <folder>     Encode all images in folder, save clip_index.json
  clip_search search "query"     Rank images by cosine similarity to text query
"""
guard argv.count >= 2 else { print(usage); exit(1) }

switch argv[1] {
case "index":
    guard argv.count >= 3 else { print(usage); exit(1) }
    cmdIndex(folder: argv[2])
case "search":
    guard argv.count >= 3 else { print(usage); exit(1) }
    cmdSearch(query: argv.dropFirst(2).joined(separator: " "))
default:
    print(usage); exit(1)
}
