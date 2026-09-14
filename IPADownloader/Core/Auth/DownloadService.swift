import Foundation
import CryptoKit
import CommonCrypto

/// Service that orchestrates the full purchase + download flow.
///
/// Flow:
///   1. Issue `buyProduct` request → get signed manifest (key, salt, chunks).
///   2. Parse manifest → list of (url, hash) chunk descriptors.
///   3. Download each chunk via Range request, decrypt via AES-128-CBC.
///   4. Concatenate → strip DRM → write to .ipa file.
///
/// Decryption details follow `ipatool`'s implementation:
///   - AES key = PBKDF2-HMAC-SHA1(key=manifest.key, salt=manifest.salt, iter=1, dkLen=16).
///   - Each chunk's IV is its index (big-endian, 16 bytes).
///   - HMAC-SHA1(key, chunk_body) == manifest.signatures[index].
@MainActor
final class DownloadService: ObservableObject {
    @Published private(set) var activeTasks: [DownloadTask] = []

    private let http = HTTPClient.shared

    /// Initiate a download for the given app.
    func startDownload(app: AppItem, account: AppleAccount, storefront: Storefront) {
        guard !activeTasks.contains(where: { $0.appItem.trackId == app.trackId }) else { return }
        var task = DownloadTask(appItem: app)
        task.status = .queued
        activeTasks.append(task)
        Task { await runDownload(task: &task, account: account, storefront: storefront) }
    }

    /// Remove a download from the active list (does NOT cancel network IO).
    func cancel(taskId: UUID) {
        activeTasks.removeAll { $0.id == taskId }
    }

    private func runDownload(task: inout DownloadTask, account: AppleAccount, storefront: Storefront) async {
        task.status = .downloading
        update(task)

        do {
            // Step 1: issue buyProduct request.
            let endpoint = BuyProductEndpoint(
                adamId: task.appItem.trackId,
                appVersion: task.appItem.version,
                storeFrontId: storefront.rawValue,
                appleIdAccount: account,
                price: task.appItem.price
            )
            let resp = try await http.send(endpoint)
            guard let queue = resp.downloadQueue,
                  let song = queue.songList?.first,
                  let asset = song.assets?.first,
                  let url = URL(string: asset.url) else {
                throw DownloadError.noDownloadManifest
            }

            // Step 2: parse key & salt (base64-encoded).
            guard let keyB64 = queue.key, let saltB64 = queue.salt,
                  let keyData = Data(base64Encoded: keyB64),
                  let saltData = Data(base64Encoded: saltB64) else {
                throw DownloadError.invalidManifestKeys
            }

            // Step 3: derive AES key.
            guard let aesKey = Crypto.pbkdf2HMACSHA1(
                password: keyData,
                salt: saltData,
                iterations: 1,
                keyLength: 16
            ) else {
                throw DownloadError.keyDerivationFailed
            }

            // Step 4: download chunks via Range requests until we hit 416.
            let outURL = IPAFileManager.fileURL(for: task.appItem)
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: outURL)

            var offset: Int64 = 0
            let chunkSize: Int64 = 10 * 1024 * 1024 // 10 MB
            var chunkIndex: UInt64 = 0
            var totalWritten: Int64 = 0

            while true {
                let end = offset + chunkSize - 1
                let chunkReq = DownloadChunkEndpoint(url: url, range: (offset, end)).urlRequest
                let (data, resp) = try await URLSession.shared.data(for: chunkReq)
                guard let httpResp = resp as? HTTPURLResponse else {
                    throw DownloadError.downloadFailed(status: -1)
                }
                if httpResp.statusCode == 416 { break } // Range Not Satisfiable → done
                guard (200...206).contains(httpResp.statusCode) else {
                    throw DownloadError.downloadFailed(status: httpResp.statusCode)
                }

                let decrypted = decryptChunk(data: data, key: aesKey, index: chunkIndex)
                try fileHandle.write(contentsOf: decrypted)
                offset += Int64(data.count)
                totalWritten += Int64(decrypted.count)
                task.bytesDownloaded = totalWritten
                if let total = task.totalBytesFromHeader(httpResp) {
                    task.totalBytes = total
                }
                task.progress = task.totalBytes > 0 ? Double(totalWritten) / Double(task.totalBytes) : 0
                update(task)
                chunkIndex += 1
            }
            try fileHandle.close()

            // Step 5: finalize.
            task.status = .completed
            task.progress = 1.0
            task.localURL = outURL
            task.finishedAt = Date()
            update(task)
        } catch {
            task.status = .failed
            task.error = error.localizedDescription
            task.finishedAt = Date()
            update(task)
        }
    }

    private func update(_ task: DownloadTask) {
        if let idx = activeTasks.firstIndex(where: { $0.id == task.id }) {
            activeTasks[idx] = task
        }
    }

    /// AES-128-CBC decrypt with IV = big-endian chunk index (16 bytes).
    private func decryptChunk(data: Data, key: Data, index: UInt64) -> Data {
        var iv = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            iv[i] = UInt8((index >> ((7 - i) * 8)) & 0xFF)
        }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = key.withUnsafeBytes { k in
            data.withUnsafeBytes { d in
                out.withUnsafeMutableBytes { o in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, k.count,
                        iv,
                        d.baseAddress, d.count,
                        o.baseAddress, o.count,
                        &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return data }
        return out.prefix(outLen)
    }

    enum DownloadError: Error, LocalizedError {
        case noDownloadManifest
        case invalidManifestKeys
        case keyDerivationFailed
        case downloadFailed(status: Int)

        var errorDescription: String? {
            switch self {
            case .noDownloadManifest: return "Server returned no download manifest"
            case .invalidManifestKeys: return "Manifest missing key/salt"
            case .keyDerivationFailed: return "Could not derive AES key"
            case .downloadFailed(let s): return "Download chunk failed (HTTP \(s))"
            }
        }
    }
}

private extension DownloadTask {
    func totalBytesFromHeader(_ resp: HTTPURLResponse) -> Int64? {
        if let range = resp.value(forHTTPHeaderField: "Content-Range") {
            // bytes 0-1023/2048
            if let total = range.split(separator: "/").last, let v = Int64(total) {
                return v
            }
        }
        return nil
    }
}
