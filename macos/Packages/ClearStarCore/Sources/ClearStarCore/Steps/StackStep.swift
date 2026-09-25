import Foundation

/// Step 2: stacking the light frames, following the logic of Siril's OSC preprocessing script:
/// calibration → per-frame plane gradient removal (seqsubsky 1) → star alignment (shift + rotation +
/// scale) → background level normalisation (norm=add) → full field of view (framing=max) → sigma-clipped
/// mean. Frames are loaded one at a time, so memory does not grow with their number (hence three
/// passes: alignment, sums, clipping).
public final class StackStep: WorkflowStep {
    public static let calibrateKey = "calibrate", alignKey = "align", rejectKey = "reject", clipKey = "clip"
    public static let gradientKey = "gradient", framingKey = "framing"
    private static let minMatches = 8
    private static let s = "stack"

    public let definition = StepDefinition.fromLanguage(.stack, .preparation, s, [
        StepKit.toggle(s, alignKey, true),
        StepKit.toggle(s, rejectKey, true),
        StepKit.toggle(s, calibrateKey, true),
        StepKit.toggle(s, gradientKey, true, advanced: true),
        StepKit.toggle(s, framingKey, true, advanced: true),
        StepKit.toggle(s, clipKey, true, advanced: true),
    ])

    public init() {}

    private struct FramePlan: Sendable { let frame: FrameInfo; let toReference: SimilarityTransform; let matches: Int; let rms: Float }
    private struct FrameQuality { let stars: Int; let starSize: Float; let background: Float }

    public func run(_ context: WorkflowContext) async throws -> StepResult {
        try await Task.detached(priority: .userInitiated) { try Self.run(context) }.value
    }

    /// Frames processed at the same time (this also bounds the memory: ~100 MB per frame).
    private static var concurrency: Int { (ProcessInfo.processInfo.activeProcessorCount / 2).clamped(2, 8) }

    private static func run(_ context: WorkflowContext) throws -> StepResult {
        guard let frames = context.frames else { throw ClearStarError(L.t("msg.stack.loadFirst")) }
        let lights = frames.lights
        if lights.isEmpty { throw ClearStarError(L.t("msg.stack.noLights")) }
        let p = context.parameters
        let calibrate = p.getBool(calibrateKey, true), align = p.getBool(alignKey, true)
        let reject = p.getBool(rejectKey, true), clip = p.getBool(clipKey, true)
        let gradient = p.getBool(gradientKey, true), framingMax = p.getBool(framingKey, true)
        let ct = context.cancellation

        let (masterDark, masterFlat) = calibrate ? try buildMasters(frames, context) : (nil, nil)

        if lights.count == 1 {
            context.report(0.3, L.t("msg.stack.loading"))
            let single = try loadCalibrated(lights[0].path, masterDark, masterFlat)
            single.clamp01()
            return StepResult(image: single, summary: L.t("msg.stack.single"))
        }

        // Reference: the middle frame in time – the largest rotation from it is the smallest.
        let refIndex = lights.count / 2
        context.report(0.05, L.t("msg.stack.prepRef"))
        let reference = try prepare(lights[refIndex].path, masterDark, masterFlat, gradient, nil, ct)
        let fw = reference.width, fh = reference.height, ch = reference.channels
        let refMedians = ImageStats.computeAll(reference).map(\.median)
        var refTotal = 0
        var refStars: [Star] = []
        if align {
            (refStars, refTotal) = try StarDetector.detectCounting(reference, ct: ct)
            if refStars.count < minMatches { throw ClearStarError(L.f("msg.stack.fewStars", refStars.count, minMatches)) }
        }

        // Pass 1: alignment (frame → reference transforms), several frames at a time.
        let planSlots = Locked([FramePlan?](repeating: nil, count: lights.count))
        let skipSlots = Locked([String?](repeating: nil, count: lights.count))
        let qualitySlots = Locked([FrameQuality?](repeating: nil, count: lights.count))
        let done = Locked(0)
        let firstError = Locked<Error?>(nil)
        let gate = DispatchSemaphore(value: concurrency)
        let refStarsFinal = refStars, refTotalFinal = refTotal
        parallelFor(lights.count) { i in
            gate.wait()
            defer {
                gate.signal()
                let d = done.withLock { $0 += 1; return $0 }
                context.report(0.05 + 0.35 * Double(d) / Double(lights.count), L.f("msg.stack.aligning", d, lights.count))
            }
            if ct.isCancelled || firstError.current != nil { return }
            do {
                if i == refIndex {
                    planSlots.withLock { $0[i] = FramePlan(frame: lights[i], toReference: .identity, matches: refStarsFinal.count, rms: 0) }
                    let q = quality(reference, refStarsFinal, refTotalFinal)
                    qualitySlots.withLock { $0[i] = q }
                    return
                }
                if !align {
                    let info = FrameSet.inspect(lights[i].path)
                    if info.width != 0 && (info.width != fw || info.height != fh) {
                        skipSlots.withLock { $0[i] = lights[i].fileName + ": " + L.t("msg.stack.sizeMismatch") }
                        return
                    }
                    planSlots.withLock { $0[i] = FramePlan(frame: lights[i], toReference: .identity, matches: 0, rms: 0) }
                    return
                }
                let frame = try loadCalibrated(lights[i].path, masterDark, masterFlat)
                if frame.width != fw || frame.height != fh || frame.channels != ch {
                    skipSlots.withLock { $0[i] = lights[i].fileName + ": " + L.t("msg.stack.sizeMismatch") }
                    return
                }
                let (stars, total) = try StarDetector.detectCounting(frame, ct: ct)
                let q = quality(frame, stars, total)
                qualitySlots.withLock { $0[i] = q }
                guard let match = StarMatcher.match(refStarsFinal, stars, minMatches: minMatches) else {
                    if reject {
                        skipSlots.withLock { $0[i] = lights[i].fileName + ": " + L.f("msg.stack.alignFailed", stars.count) }
                    } else {
                        planSlots.withLock { $0[i] = FramePlan(frame: lights[i], toReference: .identity, matches: 0, rms: 0) }
                    }
                    return
                }
                planSlots.withLock { $0[i] = FramePlan(frame: lights[i], toReference: match.transform, matches: match.matchedStars, rms: match.rms) }
            } catch {
                firstError.withLock { if $0 == nil { $0 = error } }
            }
        }
        try ct.check()
        if let e = firstError.current { throw e }
        let planArray = planSlots.current, skipArray = skipSlots.current, qualityArray = qualitySlots.current
        let plans = planArray.compactMap { $0 }
        let skipped = skipArray.compactMap { $0 }
        let maxAngle = plans.map { abs($0.toReference.angleDegrees) }.max() ?? 0
        if plans.isEmpty { throw ClearStarError(L.f("msg.stack.noneUsable", skipped.prefix(3).joined(separator: "; "))) }

        // Canvas: the reference frame, or (full field) the bounding box of all rotated frames.
        var ox = 0, oy = 0, w = fw, h = fh
        if framingMax && align {
            var minX: Float = 0, minY: Float = 0, maxX = Float(fw - 1), maxY = Float(fh - 1)
            for plan in plans {
                for (cx, cy) in [(Float(0), Float(0)), (Float(fw - 1), 0), (0, Float(fh - 1)), (Float(fw - 1), Float(fh - 1))] {
                    let (x, y) = plan.toReference.apply(cx, cy)
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            ox = Int(minX.rounded(.down)); oy = Int(minY.rounded(.down))
            w = Int(maxX.rounded(.up)) - ox + 1; h = Int(maxY.rounded(.up)) - oy + 1
        }
        let n = w * h

        // Pass 2: frame → canvas resampling, sum + sum of squares + count.
        var sum = [Float](repeating: 0, count: ch * n)
        var sumSq = clip ? [Float](repeating: 0, count: ch * n) : []
        var count = [Float](repeating: 0, count: n)
        let refPath = lights[refIndex].path
        let prepareFrame: @Sendable (FramePlan) throws -> AstroImage = { plan in
            plan.frame.path == refPath ? reference : try prepare(plan.frame.path, masterDark, masterFlat, gradient, refMedians, ct)
        }

        try forEachPrefetched(plans, prepareFrame, ct) { i, frame in
            context.report(0.4 + 0.3 * Double(i) / Double(plans.count), L.f("msg.stack.stacking", i + 1, plans.count))
            try sum.withUnsafeMutableBufferPointer { s in
                try sumSq.withUnsafeMutableBufferPointer { sq in
                    try count.withUnsafeMutableBufferPointer { cnt in
                        try accumulate(frame, canvasToFrame(plans[i].toReference, ox, oy), w, h, ch, s, clip ? sq : nil, cnt, nil, nil, ct)
                    }
                }
            }
        }

        let result = AstroImage(width: w, height: h, channels: ch, header: reference.header)
        for c in 0 ..< ch {
            for i in 0 ..< n { result.data[c * n + i] = count[i] > 0 ? sum[c * n + i] / count[i] : 0 }
        }

        // Pass 3: sigma-clipped mean (only with enough frames for the scatter to mean something).
        let clipped = clip && plans.count >= 5
        if clipped {
            var sigma = [Float](repeating: 0, count: ch * n)
            for c in 0 ..< ch {
                for i in 0 ..< n {
                    let m = result.data[c * n + i]
                    let v = count[i] > 1 ? sumSq[c * n + i] / count[i] - m * m : 0
                    sigma[c * n + i] = sqrt(max(v, 0)) * 2.5 + 1e-4
                }
            }
            var clipSum = [Float](repeating: 0, count: ch * n)
            var clipCount = [Float](repeating: 0, count: ch * n)
            let mean = result.data
            try forEachPrefetched(plans, prepareFrame, ct) { i, frame in
                context.report(0.7 + 0.28 * Double(i) / Double(plans.count), L.f("msg.stack.clipping", i + 1, plans.count))
                try clipSum.withUnsafeMutableBufferPointer { s in
                    try clipCount.withUnsafeMutableBufferPointer { cnt in
                        try mean.withUnsafeBufferPointer { m in
                            try sigma.withUnsafeBufferPointer { sg in
                                try accumulate(frame, canvasToFrame(plans[i].toReference, ox, oy), w, h, ch, s, nil, cnt, m, sg, ct)
                            }
                        }
                    }
                }
            }
            for k in 0 ..< ch * n where clipCount[k] > 0 { result.data[k] = clipSum[k] / clipCount[k] }
        }

        result.clamp01()
        result.header["STACKCNT"] = String(plans.count)
        result.header.remove("BAYERPAT")

        var summary = L.f(align ? "msg.stack.summaryAligned" : "msg.stack.summaryAveraged", plans.count)
        if clipped { summary += L.t("msg.stack.clipped") }
        if gradient { summary += L.t("msg.stack.gradient") }
        if masterDark != nil || masterFlat != nil { summary += L.t("msg.stack.calibrated") }
        if align && maxAngle > 0.05 { summary += L.f("msg.stack.rotation", maxAngle) }
        if !skipped.isEmpty { summary += L.f("msg.stack.skipped", skipped.count) }
        var notes: [String: FrameNote] = [:]
        for i in 0 ..< lights.count {
            let q = qualityArray[i]
            if let plan = planArray[i] {
                let text = i == refIndex ? L.t("msg.stack.reference")
                    : plan.matches == 0 ? L.t("msg.stack.noAlign")
                    : L.f("msg.stack.aligned", plan.matches, plan.toReference.angleDegrees)
                notes[lights[i].path] = FrameNote(used: true, text: text, stars: q?.stars, starSize: q?.starSize, background: q?.background, angle: plan.toReference.angleDegrees)
            } else if let why = skipArray[i] {
                let reason = why.range(of: ": ").map { String(why[$0.upperBound...]) } ?? why
                notes[lights[i].path] = FrameNote(used: false, text: L.f("msg.stack.skippedNote", reason), stars: q?.stars, starSize: q?.starSize, background: q?.background)
            }
        }
        return StepResult(image: result, summary: summary, frameNotes: notes)
    }

    /// Consumes the items in order while the next ones are already being prepared in parallel, so
    /// loading/gradient (many threads) and summing (one thread) overlap.
    private static func forEachPrefetched<T: Sendable>(_ items: [T], _ prepare: @escaping @Sendable (T) throws -> AstroImage, _ ct: CancellationToken,
                                             _ consume: (Int, AstroImage) throws -> Void) throws {
        let ahead = min(concurrency, items.count)
        let slots = (0 ..< items.count).map { _ in Locked<Result<AstroImage, Error>?>(nil) }
        let ready = (0 ..< items.count).map { _ in DispatchSemaphore(value: 0) }
        let queue = DispatchQueue.global(qos: .userInitiated)
        func start(_ i: Int) {
            let item = items[i]
            queue.async {
                let r: Result<AstroImage, Error> = ct.isCancelled ? .failure(CancellationError()) : Result { try prepare(item) }
                slots[i].current = r
                ready[i].signal()
            }
        }
        var started = 0
        for i in 0 ..< ahead { start(i); started += 1 }
        var consumed = 0
        defer {
            // Prefetches still running reference our captures: let them finish before returning.
            for k in consumed ..< started { ready[k].wait() }
        }
        while consumed < items.count {
            let i = consumed
            ready[i].wait()
            consumed += 1
            let r = slots[i].current!
            slots[i].current = nil
            if started < items.count { start(started); started += 1 }
            let frame = try r.get()
            try ct.check()
            try consume(i, frame)
        }
    }

    /// Quality figures: star count, typical star size (sharpness), background level (green channel).
    private static func quality(_ frame: AstroImage, _ stars: [Star], _ totalFound: Int) -> FrameQuality {
        let size = stars.isEmpty ? 0 : ImageStats.median(stars.prefix(200).map(\.size))
        let bg = ImageStats.compute(frame.channels == 3 ? frame.channel(1) : frame.channel(0), maxSamples: 100_000).median
        return FrameQuality(stars: totalFound, starSize: size, background: bg)
    }

    /// Canvas (x, y) → frame coordinate: the canvas is shifted by (ox, oy) relative to the reference.
    private static func canvasToFrame(_ toReference: SimilarityTransform, _ ox: Int, _ oy: Int) -> SimilarityTransform {
        var inv = toReference.inverse()
        let a = inv.a, b = inv.b
        inv.tx = a * Float(ox) - b * Float(oy) + inv.tx
        inv.ty = b * Float(ox) + a * Float(oy) + inv.ty
        return inv
    }

    /// Load + calibration + (optionally) plane gradient removal + background level matched to the
    /// reference (additive normalisation, like Siril's -norm=add).
    private static func prepare(_ path: String, _ dark: AstroImage?, _ flat: AstroImage?, _ gradient: Bool, _ refMedians: [Float]?,
                                _ ct: CancellationToken) throws -> AstroImage {
        let img = try loadCalibrated(path, dark, flat)
        if gradient { _ = try BackgroundFit.flatten(img, img, degree: 1, tolerance: 1, columns: 24, ct) }
        if let refMedians, refMedians.count == img.channels {
            let stats = ImageStats.computeAll(img)
            let n = img.pixelsPerChannel
            for c in 0 ..< img.channels {
                let shift = refMedians[c] - stats[c].median
                if abs(shift) < 1e-6 { continue }
                img.data.withUnsafeMutableBufferPointer { d in for i in c * n ..< (c + 1) * n { d[i] += shift } }
            }
        }
        return img
    }

    /// Resamples the frame onto the canvas and adds it to the sums.
    private static func accumulate(_ frame: AstroImage, _ toFrame: SimilarityTransform, _ w: Int, _ h: Int, _ ch: Int,
                                   _ sum: UnsafeMutableBufferPointer<Float>, _ sumSq: UnsafeMutableBufferPointer<Float>?,
                                   _ count: UnsafeMutableBufferPointer<Float>, _ mean: UnsafeBufferPointer<Float>?,
                                   _ sigma: UnsafeBufferPointer<Float>?, _ ct: CancellationToken) throws {
        let n = w * h
        try ImageWarp.resample(frame, toFrame, w, h, ct) { y, width, row in
            let wOff = width * ch
            for x in 0 ..< width {
                if row[wOff + x] <= 0 { continue }
                let i = y * width + x
                if let mean, let sigma {
                    // Sigma clipping: a counter per channel (count has ch·n entries here).
                    for c in 0 ..< ch {
                        let v = row[c * width + x]
                        let k = c * n + i
                        if abs(v - mean[k]) <= sigma[k] { sum[k] += v; count[k] += 1 }
                    }
                } else {
                    count[i] += 1
                    for c in 0 ..< ch {
                        let v = row[c * width + x]
                        sum[c * n + i] += v
                        if let sumSq { sumSq[c * n + i] += v * v }
                    }
                }
            }
        }
    }

    private static func buildMasters(_ frames: FrameSet, _ context: WorkflowContext) throws -> (AstroImage?, AstroImage?) {
        var dark: AstroImage?, flat: AstroImage?
        let darks = frames.darks.map(\.path), flats = frames.flats.map(\.path)
        if !darks.isEmpty {
            context.report(0.02, L.t("msg.stack.masterDark"))
            dark = try plainAverage(darks, context.cancellation)
        }
        if !flats.isEmpty {
            context.report(0.06, L.t("msg.stack.masterFlat"))
            let f = try plainAverage(flats, context.cancellation)
            let n = f.pixelsPerChannel
            for c in 0 ..< f.channels {
                var m = 0.0
                for i in c * n ..< (c + 1) * n { m += Double(f.data[i]) }
                let mean = Float(max(m / Double(n), 1e-6))
                for i in c * n ..< (c + 1) * n { f.data[i] = max(f.data[i] / mean, 0.05) }
            }
            flat = f
        }
        return (dark, flat)
    }

    private static func plainAverage(_ paths: [String], _ ct: CancellationToken) throws -> AstroImage {
        var sum: AstroImage?
        var used = 0
        for path in paths {
            try ct.check()
            let img = try ImageFiles.load(path)
            if sum == nil { sum = img.createEmptyLike() }
            guard let s = sum, img.width == s.width, img.height == s.height, img.channels == s.channels else { continue }
            for i in 0 ..< s.data.count { s.data[i] += img.data[i] }
            used += 1
        }
        guard let s = sum, used > 0 else { throw ClearStarError(L.t("msg.stack.calibLoadFailed")) }
        let inv = 1 / Float(used)
        for i in 0 ..< s.data.count { s.data[i] *= inv }
        return s
    }

    private static func loadCalibrated(_ path: String, _ dark: AstroImage?, _ flat: AstroImage?) throws -> AstroImage {
        let img = try ImageFiles.load(path)
        let useDark = dark.map { sameShape($0, img) } ?? false
        let useFlat = flat.map { sameShape($0, img) } ?? false
        if !useDark && !useFlat { return img }
        let dk = dark?.data ?? [], fl = flat?.data ?? []
        let n = img.pixelsPerChannel, w = img.width
        img.data.withUnsafeMutableBufferPointer { d in
            dk.withUnsafeBufferPointer { dkp in
                fl.withUnsafeBufferPointer { flp in
                    parallelFor(img.height) { y in
                        for c in 0 ..< img.channels {
                            let start = c * n + y * w
                            for k in start ..< start + w {
                                var v = d[k]
                                if useDark { v -= dkp[k] }
                                if useFlat { v /= flp[k] }
                                d[k] = v
                            }
                        }
                    }
                }
            }
        }
        return img
    }

    private static func sameShape(_ a: AstroImage, _ b: AstroImage) -> Bool { a.width == b.width && a.height == b.height && a.channels == b.channels }
}
