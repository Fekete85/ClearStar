import Foundation

/// Runs the user's own StarNet2 command-line program (starnetastro.com) as an external process – like
/// Siril does on the Mac. StarNet2 is not part of ClearStar and is not redistributed: it is found on
/// the machine (ClearStar settings, Siril's configuration, the Applications folders, PATH) or chosen by
/// the user. Images travel as 32-bit FITS through a temporary folder.
public enum StarNet {
    public static let exeSettingKey = "starnet.exe"
    public static let downloadUrl = "https://www.starnetastro.com/download"
    public static let exeName = "starnet2"

    /// The executable's full path, or nil when StarNet2 cannot be found.
    public static func locate() -> String? {
        candidates().first { isExecutable($0) }
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Siril's configuration files on the Mac (newest first).
    static func sirilConfigFiles() -> [URL] {
        let base = AppPaths.home.appendingPathComponent("Library/Application Support/org.siril.Siril", isDirectory: true)
        var result: [URL] = []
        for dir in [base.appendingPathComponent("siril"), base] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for f in files.sorted(by: >) where f.hasPrefix("config") && f.hasSuffix(".ini") { result.append(dir.appendingPathComponent(f)) }
        }
        return result
    }

    /// Value of a `key=` line in Siril's configuration files (the first non-empty one).
    static func sirilSetting(_ key: String) -> [String] {
        var values: [String] = []
        for ini in sirilConfigFiles() {
            guard let text = try? String(contentsOf: ini, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix(key.lowercased() + "=") {
                let v = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { values.append(v) }
                break
            }
        }
        return values
    }

    static func candidates() -> [String] {
        var list: [String] = []
        if let own = UserSettings.get(exeSettingKey), !own.isEmpty { list.append(own) }
        // Siril stores the path the user configured: starnet_exe=/Applications/StarNet2/starnet2
        list.append(contentsOf: sirilSetting("starnet_exe"))
        let home = AppPaths.home.path
        for root in ["/Applications", home + "/Applications", home + "/StarNet2", home] {
            for sub in ["StarNet2", "StarNet", "starnet2", "StarNet2-mac-arm64", ""] {
                list.append(((root as NSString).appendingPathComponent(sub) as NSString).appendingPathComponent(exeName))
            }
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            list.append((String(dir) as NSString).appendingPathComponent(exeName))
        }
        list.append(contentsOf: ["/opt/homebrew/bin/starnet2", "/usr/local/bin/starnet2"])
        return list
    }

    /// Remembers a user-chosen executable (nil clears it).
    public static func setExecutable(_ path: String?) { UserSettings.set(exeSettingKey, path) }

    /// Removes the stars from an already stretched image. Returns the starless image; throws with
    /// StarNet2's own message when the program fails.
    public static func removeStars(_ stretched: AstroImage, exe: String, progress: (@Sendable (Double) -> Void)? = nil,
                                   _ ct: CancellationToken = .none) throws -> AstroImage {
        let fm = FileManager.default
        let dir = AppPaths.temporary.appendingPathComponent("starnet/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.fit").path, output = dir.appendingPathComponent("starless.fit").path
        try ImageFiles.save(input, stretched, .fits)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.currentDirectoryURL = URL(fileURLWithPath: exe).deletingLastPathComponent()
        process.arguments = ["--input", input, "--output", output, "--machine-progress", "--quiet"]
        let errPipe = Pipe(), outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe
        let lastError = Locked<String?>(nil)
        let pending = Locked("")
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            let lines: [String] = pending.withLock { buf in
                buf += chunk
                var parts = buf.components(separatedBy: "\n")
                buf = parts.removeLast()
                return parts
            }
            for line in lines { handleLine(line, progress, lastError) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        try process.run()
        while process.isRunning {
            if ct.isCancelled { process.terminate() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        handleLine(pending.current + String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), progress, lastError)
        try ct.check()
        if process.terminationStatus != 0 || !fm.fileExists(atPath: output) {
            throw ClearStarError(lastError.current ?? "StarNet2 exit code \(process.terminationStatus)")
        }
        let result = try ImageFiles.load(output, debayer: false)
        // Some StarNet2 builds (OpenCV inside) write the colour planes of a FITS cube in BGR order,
        // others in RGB: swap red and blue back only when the swapped planes match the input better.
        if result.channels == 3 && stretched.channels == 3 && isRedBlueSwapped(stretched, result) {
            let red = result.channelArray(0)
            result.setChannel(0, result.channelArray(2))
            result.setChannel(2, red)
        }
        return result
    }

    /// True when the starless image's red and blue planes fit the input's blue and red planes
    /// better than in their own order. Stars aside, StarNet2 leaves background and nebula
    /// untouched, so the right order has the smaller difference. Sampled for speed.
    public static func isRedBlueSwapped(_ input: AstroImage, _ starless: AstroImage) -> Bool {
        let n = input.pixelsPerChannel
        guard n == starless.pixelsPerChannel else { return false }
        let a = input.data, s = starless.data
        let step = max(1, n / 1_000_000)
        var same = 0.0, swapped = 0.0
        for i in stride(from: 0, to: n, by: step) {
            let r = a[i], b = a[2 * n + i], sr = s[i], sb = s[2 * n + i]
            same += Double(abs(sr - r) + abs(sb - b))
            swapped += Double(abs(sr - b) + abs(sb - r))
        }
        return swapped < same
    }

    private static func handleLine(_ text: String, _ progress: (@Sendable (Double) -> Void)?, _ lastError: Locked<String?>) {
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if let r = line.range(of: #""percent"\s*:\s*([0-9.]+)"#, options: .regularExpression) {
                let num = line[r].split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if let pct = Double(num) { progress?(pct / 100) }
            }
            if line.contains("\"event\":\"error\"") {
                if let r = line.range(of: #""message"\s*:\s*"([^"]*)""#, options: .regularExpression) {
                    let m = String(line[r])
                    let msg = m.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? m
                    lastError.current = msg
                } else {
                    lastError.current = line
                }
            }
        }
    }

    /// Star removal on a linear image: a linked MTF auto-stretch first, StarNet2 on the stretched image,
    /// then the exact inverse stretch brings the starless result back to linear. Returns (starless,
    /// stars) with stars = original − starless.
    public static func removeStarsLinear(_ linear: AstroImage, exe: String, progress: (@Sendable (Double) -> Void)? = nil,
                                         _ ct: CancellationToken = .none) throws -> (starless: AstroImage, stars: AstroImage) {
        let prms = DisplayStretch.computeAll(linear, preset: DisplayStretch.Preset("starnet", 0.25, 2.8), linked: true)
        let stretched = try StepKit.mapPixels(linear, ct) { v, c in prms[c].apply(v) }
        let starlessStretched = try removeStars(stretched, exe: exe, progress: progress, ct)
        if starlessStretched.width != linear.width || starlessStretched.height != linear.height || starlessStretched.channels != linear.channels {
            throw ClearStarError("StarNet2 returned an image of a different size.")
        }
        let starless = linear.createEmptyLike(), stars = linear.createEmptyLike()
        let n = linear.pixelsPerChannel
        for c in 0 ..< linear.channels {
            let p = prms[c]
            for i in c * n ..< (c + 1) * n {
                let v = p.invert(starlessStretched.data[i].clamped(0, 1)).clamped(0, 1)
                starless.data[i] = v
                stars.data[i] = max(linear.data[i] - v, 0)
            }
        }
        return (starless, stars)
    }
}
