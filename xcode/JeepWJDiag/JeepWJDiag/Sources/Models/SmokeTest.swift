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

        // Peak fuel and A/F at that moment
        if let pk = samples.max(by: { $0.fuelUsed < $1.fuelUsed }) {
            s.lines.append("Fuel peak \(f1(pk.fuelUsed)) mg/str @\(Int(pk.rpm))rpm t=\(f1(pk.t))s | MAF \(f1(pk.maf)) -> A/F \(f1(pk.af))")
        }
        // Minimum A/F under load
        let loaded = samples.filter { $0.pedal > 30 || $0.fuelUsed > 15 }
        let pool = loaded.isEmpty ? samples : loaded
        if let lo = pool.filter({ $0.af > 0 }).min(by: { $0.af < $1.af }) {
            s.lines.append("A/F min \(f1(lo.af)) @\(Int(lo.rpm))rpm t=\(f1(lo.t))s (fuel \(f1(lo.fuelUsed)) / air \(f1(lo.maf)))")
            if lo.af < 15 { s.flags.append("A/F < 15: cok zengin karisim, kara duman kacinilmaz (hava az veya yakit fazla)") }
            else if lo.af < 17 { s.flags.append("A/F < 17: zengin karisim, duman sinirinda") }
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
        let events = pulls()
        if events.isEmpty {
            s.lines.append("Pedal never held >= 60% - no full throttle transient captured")
        }
        var worstDeficit = 0.0
        var worstLag = 0.0
        var neverReached = false
        for (n, p) in events.enumerated() {
            let window = samples[p.start...p.end]
            // settle: ignore the first 0.7 s after the pedal step for deficit
            let settled = window.filter { $0.t >= p.tStart + 0.7 && $0.boostSet > 0 && $0.boostAct > 0 }
            var line = "Pull \(n + 1) t=\(f1(p.tStart))-\(f1(p.tEnd))s rpm \(Int(samples[p.start].rpm))->\(Int(samples[p.end].rpm))"
            if let d = settled.max(by: { ($0.boostSet - $0.boostAct) < ($1.boostSet - $1.boostAct) }) {
                let deficit = d.boostSet - d.boostAct
                worstDeficit = max(worstDeficit, deficit)
                line += " | deficit max \(f2(deficit)) bar @\(Int(d.rpm))rpm"
            }
            if let hit = window.first(where: { $0.boostSet > ambient + 0.3 && $0.boostAct >= $0.boostSet - 0.15 }) {
                let lag = hit.t - p.tStart
                worstLag = max(worstLag, lag)
                line += " | lag \(f1(lag))s"
            } else if (window.map { $0.boostSet }.max() ?? 0) > ambient + 0.3 {
                neverReached = true
                line += " | target NOT reached"
            } else {
                line += " | no boost demand"
            }
            s.lines.append(line)
        }
        if worstDeficit > 0.4 { s.flags.append("Boost hedefin 0.4 bar+ altinda kaliyor: VNT kanatcik / hortum kacagi / N75 kontrol") }
        if worstLag > 1.5 { s.flags.append("Turbo yanit gecikmesi > 1.5 s: turbo lag donemi uzun, duman bu pencerede olusur") }
        if neverReached { s.flags.append("Turbo hedef basinca pedal basiliyken hic ulasamadi: VNT sikismasi / kacak / MAP sensor") }

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

        // Rail pressure: 0x12 is a slow block, so only rows where 0x12 was
        // actually read carry a fresh value (other rows repeat the previous
        // read). Judged only after the pump has had 0.7 s to respond to the
        // pedal step, otherwise the pre-step value is a false dip.
        var railLoad: [Double] = []
        for p in events {
            railLoad += samples[p.start...p.end]
                .filter { $0.src == 0x12 && $0.t >= p.tStart + 0.7 && $0.rail > 0 }
                .map { $0.rail }
        }
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
        if let pk = samples.max(by: { $0.fuelUsed < $1.fuelUsed }),
           let w = samples.filter({ $0.src == 0x21 }).min(by: { abs($0.t - pk.t) < abs($1.t - pk.t) }),
           w.fq.count >= 7 {
            s.lines.append("0x21 words near fuel peak (t=\(f1(w.t))s): " + w.fq.map { f1($0) }.joined(separator: " / "))
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
