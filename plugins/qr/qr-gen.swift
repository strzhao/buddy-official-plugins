// qr-gen.swift — 二维码生成器（command mode 插件可执行文件）
//
// 数据流：读 stdin JSON {query, sessionId, cwd} → CIFilter.qrCodeGenerator →
//         CIContext.createCGImage 放大到 ≥480px → NSBitmapImageRep PNG → 写 $BUDDY_OUTPUT_IMAGE
//
// 契约（state.md ## 契约规约）：
//   - query.count >= 1；空 → exit 1 + stderr（不写 BUDDY_OUTPUT_IMAGE）
//   - PNG 边长 >= 480 px（CoreImage 默认 module ~23px 需放大保证扫码）
//   - 输出路径读环境变量 BUDDY_OUTPUT_IMAGE（框架注入 /tmp/buddy-plugin-<uuid>.png）
//   - 超二维码容量 → 升级纠错级仍失败则非零 exit（不写截断的码）

import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 1. 读 stdin JSON

struct PluginInput: Decodable {
    let query: String
    let sessionId: String?
    let cwd: String?
}

let stdin = FileHandle.standardInput
let inputData = stdin.readDataToEndOfFile()

let input: PluginInput
do {
    input = try JSONDecoder().decode(PluginInput.self, from: inputData)
} catch {
    FileHandle.standardError.write(Data("qr-gen: 无法解析 stdin JSON: \(error)\n".utf8))
    exit(1)
}

let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)

// query 校验：空 → exit 1（契约边界：query="" → exit 1，不写 BUDDY_OUTPUT_IMAGE）
guard !query.isEmpty else {
    FileHandle.standardError.write(Data("qr-gen: 查询为空，无法生成二维码\n".utf8))
    exit(1)
}

let queryData = Data(query.utf8)

// MARK: - 2. CoreImage 生成 QR（纠错级 M，超容量时降级到 H 重试）

func generateQR(message: Data, correctionLevel: String) -> CIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = message
    filter.correctionLevel = correctionLevel
    return filter.outputImage
}

// 先 M（中等纠错，容量大），失败（超容量返回 nil）降级到 H（高纠错，容量小但能容更多数据冗余）
let qrImage = generateQR(message: queryData, correctionLevel: "M")
    ?? generateQR(message: queryData, correctionLevel: "H")

guard let outputImage = qrImage else {
    // 超 H 级容量仍失败 → 非零 exit（不写截断的码，场景5.P1）
    FileHandle.standardError.write(Data("qr-gen: 输入超过二维码容量（纠错级 H 仍失败）\n".utf8))
    exit(2)
}

// MARK: - 3. 放大到 ≥480px

let originalSize = outputImage.extent.width
let scale = max(1.0, 480.0 / originalSize)
let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

let context = CIContext()
guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
    FileHandle.standardError.write(Data("qr-gen: createCGImage 失败\n".utf8))
    exit(3)
}

// MARK: - 4. PNG 编码

let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("qr-gen: PNG 编码失败\n".utf8))
    exit(4)
}

// MARK: - 5. 写 BUDDY_OUTPUT_IMAGE（框架注入的路径）

let outputPath = ProcessInfo.processInfo.environment["BUDDY_OUTPUT_IMAGE"]
guard let path = outputPath, !path.isEmpty else {
    FileHandle.standardError.write(Data("qr-gen: 环境变量 BUDDY_OUTPUT_IMAGE 未设置\n".utf8))
    exit(5)
}

do {
    try pngData.write(to: URL(fileURLWithPath: path))
} catch {
    FileHandle.standardError.write(Data("qr-gen: 写 \(path) 失败: \(error)\n".utf8))
    exit(6)
}

// stdout 保持空（图片走 BUDDY_OUTPUT_IMAGE，不污染文本通道）
exit(0)
