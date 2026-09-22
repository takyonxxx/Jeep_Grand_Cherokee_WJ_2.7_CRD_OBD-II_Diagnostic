import Foundation

// MARK: - Smoke Test (black smoke on sudden throttle) recording session
//
// Records a focused, high-rate snapshot of the EDC15C values that decide
// whether combustion goes rich during a throttle transient:
//   fuel per stroke (0x28 / 0x32), air per stroke = MAF (0x36), boost actual
//   vs setpoint (0x22 / 0x36), rail pressure (0x12), pedal (0x36), the seven
//   fuel-quantity limiter words of block 0x21, EGR / wastegate raw words of
//   0x37 and the raw MAF / boost detail words of 0x20 / 0x23.
// The session renders itself as a WhatsApp-ready text report (summary +
// CSV) so the log can be shared straight from the car.

struct SmokeSample {
    let t: Double            // seconds since session start
    let src: UInt8           // block that produced this snapshot
    let rpm: Double
    let pedal: Double        // %
    let iq: Double           // mg/str  (0x28)
    let fuelAct: Double      // mg/str  (0x32)
    let maf: Double          // mg/str  (0x36)
    let boostAct: Double     // bar abs (0x22 MAP/1000)
    let boostSet: Double     // bar abs (0x36[8-9]/1000)
    let map: Double          // mbar raw (0x12[16-17])
    let rail: Double         // bar (0x12)
    let coolant: Double      // C
    let iat: Double          // C
    let fq: [Double]         // 0x21[0-13] /100 (7 fuel qty words)
    let egr: Double          // 0x37[0-1] raw
    let wg: Double           // 0x37[2-3] raw
    let b36c: Double         // 0x36[10-11] raw
    let b20a: Double         // 0x20[0-1] raw
    let b20b: Double         // 0x20[2-3] raw
    let b23a: Double         // 0x23[0-1] raw
    let b23g: Double         // 0x23[6-7] raw
    let corr: [Double]       // 0x28 injection corrections mg/str
    var mark: String

    /// Fuel per stroke, always from 0x28 (read every cycle). 0x32 "actual"
    /// is a slow block: falling back to it when 0x28 reads 0 (overrun cut)
    /// would resurrect a stale pre-lift-off value, so it is never used here
    /// and only kept as a CSV column.
    var fuelUsed: Double { iq }
    /// Air / fuel mass ratio per stroke. Diesel smoke becomes visible
    /// roughly below 17:1 and heavy below 15:1. Below 5 mg/str (overrun
    /// fuel cut; idle is ~9) the ratio is meaningless, so it is reported as 0.
    var af: Double { fuelUsed >= 5.0 ? maf / fuelUsed : 0 }
}

struct SmokeTestSession {
    /// Blocks that must each have been read once before rows are stored, so
    /// the first rows are not padded with zeros: pedal/MAF (0x36), rpm/fuel
    /// (0x28) and MAP/rail/IAT (0x12, interleaved every other cycle).
    static let fastBlocks: Set<UInt8> = [0x36, 0x28, 0x12]

    var isRecording = false
    var startDate: Date?          // START pressed
    var dataStart: Date?          // first complete cycle (t = 0 in the CSV)
    var endDate: Date?
    var initSeconds: Double = 0   // ECU init + first cycle time
    var samples: [SmokeSample] = []
    var marks: [Double] = []
    var pendingMark = false
    var error: String?
    private var seen: Set<UInt8> = []

    var duration: Double { samples.last?.t ?? 0 }
    var hasData: Bool { !samples.isEmpty }
    /// Recording but no sample yet: ECU init or first cycle in progress.
    var isInitializing: Bool { isRecording && samples.isEmpty }

    mutating func reset() {
        isRecording = false
        startDate = nil; dataStart = nil; endDate = nil
        initSeconds = 0
        samples.removeAll(); marks.removeAll(); seen.removeAll()
        pendingMark = false; error = nil
    }

    mutating func begin() {
        reset()
        startDate = Date()
        isRecording = true
    }

    mutating func finish() {
        isRecording = false
        endDate = Date()
    }

    /// Driver or passenger saw smoke: tag the next sample.
    mutating func mark() {
        guard isRecording else { return }
        let ref = dataStart ?? startDate ?? Date()
        marks.append(Date().timeIntervalSince(ref))
        pendingMark = true
    }

    mutating func append(from ecu: ECUStatus, src: UInt8) {
        guard isRecording, let s = startDate else { return }
        seen.insert(src)
        guard Self.fastBlocks.isSubset(of: seen) else { return }
        let now = Date()
        if dataStart == nil {
            dataStart = now
            initSeconds = now.timeIntervalSince(s)
        }
        var sample = SmokeSample(
            t: now.timeIntervalSince(dataStart ?? now), src: src,
            rpm: ecu.rpm, pedal: ecu.pedalPos,
            iq: ecu.injectionQty, fuelAct: ecu.fuelQuantity, maf: ecu.mafFlow,
            boostAct: ecu.boostPressure, boostSet: ecu.boostSetpoint, map: ecu.mapActual,
            rail: ecu.railPressure, coolant: ecu.coolantTemp, iat: ecu.iat,
            fq: ecu.fuelQty21, egr: ecu.egrMafSetpoint, wg: ecu.wastegateRaw,
            b36c: ecu.blk36c, b20a: ecu.blk20a, b20b: ecu.blk20b,
            b23a: ecu.blk23a, b23g: ecu.blk23g,
            corr: ecu.injCorrections, mark: "")
        if pendingMark { sample.mark = "SMOKE"; pendingMark = false }
        samples.append(sample)
    }

    // MARK: - Analysis

    struct Summary {
        var lines: [String] = []
        var flags: [String] = []
    }

    /// One full-throttle event: pedal rises through 60% and stays above it.
    struct Pull {
        let start: Int      // index of first sample with pedal >= 60
        let end: Int        // index of last sample with pedal >= 60 (inclusive)
        var tStart: Double
        var tEnd: Double
    }

    /// Split the recording into pulls so lag / deficit / rail are judged
    /// per event and only while the pedal is actually down.
    func pulls() -> [Pull] {
        var out: [Pull] = []
        var start: Int? = nil
        for (i, s) in samples.enumerated() {
            if s.pedal >= 60 {
                if start == nil { start = i }
            } else if let st = start {
                out.append(Pull(start: st, end: i - 1, tStart: samples[st].t, tEnd: samples[i - 1].t))
                start = nil
            }
        }
        if let st = start {
            out.append(Pull(start: st, end: samples.count - 1, tStart: samples[st].t, tEnd: samples[samples.count - 1].t))
        }
        // ignore blips shorter than 0.3 s
        return out.filter { $0.tEnd - $0.tStart >= 0.3 }
    }

    func summary() -> Summary {
        var s = Summary()
        guard !samples.isEmpty else { s.lines.append("No samples"); return s }
        let f1 = { (v: Double) in String(format: "%.1f", v) }
        let f2 = { (v: Double) in String(format: "%.2f", v) }

        let rpmMax = samples.map { $0.rpm }.max() ?? 0
        let pedalMax = samples.map { $0.pedal }.max() ?? 0
        s.lines.append("RPM max \(Int(rpmMax)) | Pedal max \(Int(pedalMax))%")

        // A/F is judged on 0x28 rows (fresh fuel) with the MAF interpolated in
        // time between the surrounding 0x36 reads. Fuel and MAF are read
        // ~0.25 s apart; during turbo spool MAF climbs ~25 %/s, so dividing
        // fresh fuel by the previous MAF read biases A/F low by ~10 %.
        // Linear interpolation of a 0x36 quantity (MAF, boost setpoint) at time t.
        func interp(_ reads: [(Double, Double)], _ t: Double) -> Double {
            guard let first = reads.first else { return 0 }
            if t <= first.0 { return first.1 }
            for i in 1..<reads.count where reads[i].0 >= t {
                let (t0, m0) = reads[i - 1], (t1, m1) = reads[i]
                return t1 > t0 ? m0 + (m1 - m0) * (t - t0) / (t1 - t0) : m1
            }
            return reads[reads.count - 1].1
        }
        let reads36 = samples.filter { $0.src == 0x36 }
        let mafReads = reads36.map { ($0.t, $0.maf) }
        let setReads = reads36.map { ($0.t, $0.boostSet) }
        func mafAt(_ t: Double) -> Double { interp(mafReads, t) }
        func setAt(_ t: Double) -> Double { interp(setReads, t) }

        // Pulls are needed both for A/F (flag only inside pulls >= 1.5 s: a
        // 0.6 s stab has its MAF peak between two 0x36 reads, so its A/F is
        // not resolvable at ~0.8 s sampling) and for the boost analysis.
        let events = pulls()
        let longPulls = events.filter { $0.tEnd - $0.tStart >= 1.5 }
        func inLongPull(_ t: Double) -> Bool { longPulls.contains { t >= $0.tStart && t <= $0.tEnd } }

        struct AFRow { let s: SmokeSample; let maf: Double; let af: Double }
        let afRows: [AFRow] = samples.filter { $0.src == 0x28 && $0.fuelUsed >= 5.0 }.map {
            let m = mafAt($0.t); return AFRow(s: $0, maf: m, af: m / $0.fuelUsed)
        }
        if let pk = afRows.max(by: { $0.s.fuelUsed < $1.s.fuelUsed }) {
            s.lines.append("Fuel peak \(f1(pk.s.fuelUsed)) mg/str @\(Int(pk.s.rpm))rpm t=\(f1(pk.s.t))s | MAF \(f1(pk.maf)) -> A/F \(f1(pk.af))")
        }
        let inPull = afRows.filter { inLongPull($0.s.t) }
        if let lo = inPull.min(by: { $0.af < $1.af }) {
            s.lines.append("A/F min (pulls >= 1.5 s) \(f1(lo.af)) @\(Int(lo.s.rpm))rpm t=\(f1(lo.s.t))s (fuel \(f1(lo.s.fuelUsed)) / air \(f1(lo.maf)) interp)")
            if lo.af < 15 { s.flags.append("A/F < 15: cok zengin karisim, kara duman kacinilmaz (hava az veya yakit fazla)") }
            else if lo.af < 17 { s.flags.append("A/F < 17: zengin karisim, duman sinirinda") }
        }
        let other = afRows.filter { !inLongPull($0.s.t) && ($0.s.pedal > 30 || $0.s.fuelUsed > 15) }
        if let lo = other.min(by: { $0.af < $1.af }) {
            s.lines.append("A/F min (short stabs / part throttle, not flagged) \(f1(lo.af)) @\(Int(lo.s.rpm))rpm t=\(f1(lo.s.t))s")
        }

        // Boost
        let positive = samples.filter { $0.boostAct > 0 }
        let ambient = positive.map { $0.boostAct }.min() ?? 0
        let actMax = positive.map { $0.boostAct }.max() ?? 0
        let setMax = samples.map { $0.boostSet }.max() ?? 0
        s.lines.append("Boost act max \(f2(actMax)) bar abs | set max \(f2(setMax)) | ambient ~\(f2(ambient))")

        // Per-pull analysis: lag and deficit are only meaningful while the
        // pedal is still down (a falling setpoint at lift-off must not count
        // as "target reached").
        if events.isEmpty {
            s.lines.append("Pedal never held >= 60% - no full throttle transient captured")
        }
        var worstDeficit = 0.0
        var worstLag = 0.0
        var neverReached = false
        var railLoad: [Double] = []
        for (n, p) in events.enumerated() {
            var line = "Pull \(n + 1) t=\(f1(p.tStart))-\(f1(p.tEnd))s rpm \(Int(samples[p.start].rpm))->\(Int(samples[p.end].rpm))"
            if p.tEnd - p.tStart < 2.0 {
                // Stationary blips / short stabs: the turbo cannot spool in
                // under 2 s even on a healthy engine, so boost is not judged.
                line += " | short pull, boost/rail not evaluated"
                s.lines.append(line)
                continue
            }
            // Boost actual is fresh only on 0x12 rows. Rows after the last
            // 0x36 read that still showed pedal >= 60 are ambiguous (the pedal
            // may already be up, boost collapsing), so they are excluded.
            var evalEnd = p.start
            for i in stride(from: p.end, through: p.start, by: -1) where samples[i].src == 0x36 {
                evalEnd = i; break
            }
            let rows12 = samples[p.start...evalEnd].filter { $0.src == 0x12 && $0.boostAct > 0 && $0.boostSet > 0 }
            // Setpoint on a 0x12 row is up to 0.5 s stale (it comes from 0x36),
            // so it is interpolated to the 0x12 read time.
            // settle: ignore the first 0.7 s after the pedal step for deficit and rail
            let settled = rows12.filter { $0.t >= p.tStart + 0.7 }
            if let d = settled.max(by: { (setAt($0.t) - $0.boostAct) < (setAt($1.t) - $1.boostAct) }) {
                let deficit = setAt(d.t) - d.boostAct
                worstDeficit = max(worstDeficit, deficit)
                line += " | deficit max \(f2(deficit)) bar @\(Int(d.rpm))rpm"
            }
            // Spool time: pedal step until actual boost reaches +0.5 bar gauge.
            // A fixed threshold is used because the setpoint itself climbs with
            // rpm during the pull, so "within x of target" is ill-defined even
            // on a healthy engine (tracking error ~0.2 bar). Boost is read
            // every other cycle (~1.6 s), so the crossing time is interpolated
            // between the last read below and the first read at/above threshold.
            let spoolThr = ambient + 0.5
            if let hitIdx = rows12.firstIndex(where: { $0.boostAct >= spoolThr }) {
                let hit = rows12[hitIdx]
                var before: SmokeSample? = hitIdx > 0 ? rows12[hitIdx - 1] : nil
                if before == nil, p.start > 0 {
                    before = samples[0..<p.start].last(where: { $0.src == 0x12 && $0.boostAct > 0 })
                }
                var tCross = hit.t
                if let b = before, b.boostAct < spoolThr, hit.boostAct > b.boostAct {
                    tCross = b.t + (hit.t - b.t) * (spoolThr - b.boostAct) / (hit.boostAct - b.boostAct)
                }
                let lag = max(0, tCross - p.tStart)
                worstLag = max(worstLag, lag)
                line += " | spool to +0.5 bar \(f1(lag))s"
            } else if (rows12.map { setAt($0.t) }.max() ?? 0) > ambient + 0.5 {
                neverReached = true
                line += " | +0.5 bar NOT reached"
            } else if rows12.isEmpty {
                line += " | no boost reads"
            } else {
                line += " | no boost demand"
            }
            railLoad += settled.filter { $0.rail > 0 }.map { $0.rail }
            s.lines.append(line)
        }
        if worstDeficit > 0.4 { s.flags.append("Boost hedefin 0.4 bar+ altinda kaliyor: VNT kanatcik / hortum kacagi / N75 kontrol") }
        if worstLag > 2.5 { s.flags.append("Turbo +0.5 bar'a 2.5 s'den gec ulasiyor: turbo lag donemi uzun, duman bu pencerede olusur") }
        if neverReached { s.flags.append("Turbo pedal basiliyken +0.5 bar'a hic ulasamadi: VNT sikismasi / kacak / MAP sensor") }

        // MAF plausibility vs theoretical air per stroke at measured boost/IAT.
        // OM612: 2685 cc / 5 cyl = 537 cc per cylinder. m = P*V/(R*T), VE ~0.85.
        if let pk = positive.max(by: { $0.boostAct < $1.boostAct }), pk.maf > 0 {
            let pPa = pk.boostAct * 100_000.0
            let tK = (pk.iat > -40 ? pk.iat : 25) + 273.15
            let theo = pPa * 0.000537 / (287.0 * tK) * 1_000_000.0 * 0.85 // mg/str
            let ratio = pk.maf / theo
            s.lines.append("MAF at boost peak \(f1(pk.maf)) mg/str vs theoretical \(f1(theo)) (ratio \(f2(ratio)))")
            if ratio < 0.7 { s.flags.append("MAF teorik havanin %70 altinda: MAF sensor dusuk okuyor veya MAF sonrasi kacak") }
            if ratio > 1.2 { s.flags.append("MAF teorik havanin %120 ustunde: MAF yuksek okuyor -> ECU fazla yakit verir -> duman") }
        }

        // Rail pressure: collected above from fresh 0x12 rows of pulls >= 2 s,
        // after the pump has had 0.7 s to respond to the pedal step.
        let railMax = samples.map { $0.rail }.max() ?? 0
        if let rmin = railLoad.min() {
            s.lines.append("Rail under load (settled) min \(Int(rmin)) bar | max \(Int(railMax)) bar")
            if rmin < 600 { s.flags.append("Yuk altinda rail < 600 bar: yakit basinci cokuyor (CP1 pompa / regulator / filtre)") }
        } else {
            s.lines.append("Rail max \(Int(railMax)) bar")
        }

        // Temperatures & corrections
        let cool = samples.last?.coolant ?? 0
        let iatMax = samples.map { $0.iat }.max() ?? 0
        s.lines.append("Coolant \(Int(cool))C | IAT max \(Int(iatMax))C")
        if cool < 70 { s.flags.append("Motor soguk (<70C): test sicak motorla tekrarlanmali") }
        if iatMax > 60 { s.flags.append("Emme havasi > 60C: intercooler verimi dusuk / EGR gazi giriyor olabilir") }
        var maxCorr = 0.0
        for smp in samples { for c in smp.corr { maxCorr = max(maxCorr, abs(c)) } }
        s.lines.append("Injection correction max |\(f2(maxCorr))| mg/str")
        if maxCorr > 3 { s.flags.append("Silindir duzeltmesi > 3 mg: enjektor / kompresyon dengesizligi") }

        // 0x21 limiter words: slow block, so take the 0x21 read closest in
        // time to the fuel peak rather than the (possibly stale) copy on the
        // peak row itself.
        if let pk = samples.max(by: { $0.fuelUsed < $1.fuelUsed }) {
            // Prefer a 0x21 read taken while the pedal was still down; the
            // block is read only every ~5 cycles so the nearest read overall
            // may already be from the lift-off / idle phase.
            let reads21 = samples.filter { $0.src == 0x21 }
            let underPedal = reads21.filter { $0.pedal >= 60 }
            let pool21 = underPedal.isEmpty ? reads21 : underPedal
            if let w = pool21.min(by: { abs($0.t - pk.t) < abs($1.t - pk.t) }), w.fq.count >= 7 {
                s.lines.append("0x21 words @t=\(f1(w.t))s pedal \(Int(w.pedal))%: " + w.fq.map { f1($0) }.joined(separator: " / "))
            }
        }

        if !marks.isEmpty {
            s.lines.append("Smoke marks: " + marks.map { f1($0) + "s" }.joined(separator: ", "))
        }
        return s
    }

    // MARK: - Text output

    static let csvHeader = "t,src,rpm,ped,iq,fuel,maf,af,bAct,bSet,map,rail,cool,iat,fq0,fq1,fq2,fq3,fq4,fq5,fq6,egr,wg,b36c,b20a,b20b,b23a,b23g,c1,c2,c3,mark"

    func csvText() -> String {
        var out = Self.csvHeader + "\n"
        for s in samples {
            var cols: [String] = [
                String(format: "%.2f", s.t),
                String(format: "%02X", Int(s.src)),
                String(Int(s.rpm)),
                String(Int(s.pedal)),
                String(format: "%.1f", s.iq),
                String(format: "%.1f", s.fuelAct),
                String(format: "%.1f", s.maf),
                String(format: "%.1f", s.af),
                String(format: "%.3f", s.boostAct),
                String(format: "%.3f", s.boostSet),
                String(Int(s.map)),
                String(Int(s.rail)),
                String(Int(s.coolant)),
                String(Int(s.iat)),
            ]
            cols += s.fq.map { String(format: "%.1f", $0) }
            cols += [String(Int(s.egr)), String(Int(s.wg)), String(Int(s.b36c)),
                     String(Int(s.b20a)), String(Int(s.b20b)),
                     String(Int(s.b23a)), String(Int(s.b23g))]
            cols += s.corr.map { String(format: "%.2f", $0) }
            cols.append(s.mark)
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    func reportText() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let when = startDate.map { df.string(from: $0) } ?? "-"
        var out = "JeepWJDiag SMOKE TEST \(when)\n"
        let rate = duration > 0 ? Double(samples.count) / duration : 0
        let fuelReads = samples.filter { $0.src == 0x28 }.count
        let fuelRate = duration > 0 ? Double(fuelReads) / duration : 0
        out += "Duration \(String(format: "%.1f", duration))s, \(samples.count) samples (\(String(format: "%.1f", rate))/s, fuel+pedal \(String(format: "%.1f", fuelRate))/s), \(marks.count) marks, ECU init \(String(format: "%.1f", initSeconds))s\n"
        if let e = error { out += "ERROR: \(e)\n" }
        let sum = summary()
        out += "-- SUMMARY --\n" + sum.lines.joined(separator: "\n") + "\n"
        out += "-- FLAGS --\n" + (sum.flags.isEmpty ? "none" : sum.flags.map { "! " + $0 }.joined(separator: "\n")) + "\n"
        out += "-- CSV (mg/str, bar abs, C) --\n" + csvText()
        return out
    }

    func fileName() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmm"
        return "SmokeTest_\(df.string(from: startDate ?? Date())).txt"
    }
}
