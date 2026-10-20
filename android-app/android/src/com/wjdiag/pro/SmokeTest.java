package com.wjdiag.pro;

import com.wjdiag.pro.Models.EcuStatus;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;

/**
 * Black-smoke transient test session: high-rate snapshot of fuel / air / boost /
 * rail while the pedal is floored, with the analysis and the WhatsApp-ready
 * report (summary + CSV). Port of the iOS SmokeTestSession.
 */
public final class SmokeTest {

    public static final class Sample {
        double t; int src; double rpm, pedal; int gear; double b36s, speed, iq, fuelAct, maf, boostAct, boostSet, map, rail, coolant, iat;
        double[] fq; double egr, wg, b36c, b20a, b20b, b23a, b23g; double[] corr; String mark = "";
        double fuelUsed() { return iq; }
        double af() { return fuelUsed() >= 5.0 ? maf / fuelUsed() : 0; }
    }

    public static final class Pull { int start, end; double tStart, tEnd; }

    public static final class Summary {
        public final List<String> lines = new ArrayList<>();
        public final List<String> flags = new ArrayList<>();
    }

    private static final Set<Integer> FAST_BLOCKS = new HashSet<>();
    static { FAST_BLOCKS.add(0x36); FAST_BLOCKS.add(0x28); FAST_BLOCKS.add(0x12); }

    public boolean isRecording;
    public Date startDate, dataStart, endDate;
    public double initSeconds;
    public final List<Sample> samples = new ArrayList<>();
    public final List<Double> marks = new ArrayList<>();
    public boolean pendingMark;
    public String error;
    private final Set<Integer> seen = new HashSet<>();

    public double duration() { return samples.isEmpty() ? 0 : samples.get(samples.size() - 1).t; }
    public boolean hasData() { return !samples.isEmpty(); }
    public boolean isInitializing() { return isRecording && samples.isEmpty(); }

    public void reset() {
        isRecording = false; startDate = null; dataStart = null; endDate = null; initSeconds = 0;
        samples.clear(); marks.clear(); seen.clear(); pendingMark = false; error = null;
    }
    public void begin() { reset(); startDate = new Date(); isRecording = true; }
    public void finish() { isRecording = false; endDate = new Date(); }

    public void mark() {
        if (!isRecording) return;
        Date ref = dataStart != null ? dataStart : (startDate != null ? startDate : new Date());
        marks.add((new Date().getTime() - ref.getTime()) / 1000.0);
        pendingMark = true;
    }

    public void append(EcuStatus e, int src) {
        if (!isRecording || startDate == null) return;
        seen.add(src);
        if (!seen.containsAll(FAST_BLOCKS)) return;
        Date now = new Date();
        if (dataStart == null) { dataStart = now; initSeconds = (now.getTime() - startDate.getTime()) / 1000.0; }
        Sample s = new Sample();
        s.t = (now.getTime() - dataStart.getTime()) / 1000.0; s.src = src;
        s.rpm = e.rpm; s.pedal = e.pedalPos; s.gear = e.gear; s.b36s = e.blk36signed; s.speed = e.vehicleSpeed;
        s.iq = e.injectionQty; s.fuelAct = e.fuelQuantity; s.maf = e.mafFlow; s.boostAct = e.boostPressure;
        s.boostSet = e.boostSetpoint; s.map = e.mapActual; s.rail = e.railPressure; s.coolant = e.coolantTemp; s.iat = e.iat;
        s.fq = e.fuelQty21.clone(); s.egr = e.egrMafSetpoint; s.wg = e.wastegateRaw; s.b36c = e.blk36c;
        s.b20a = e.blk20a; s.b20b = e.blk20b; s.b23a = e.blk23a; s.b23g = e.blk23g; s.corr = e.injCorrections.clone();
        if (pendingMark) { s.mark = "SMOKE"; pendingMark = false; }
        samples.add(s);
    }

    // ------------------------------------------------------------------ analysis

    public List<Pull> pulls() {
        List<Pull> out = new ArrayList<>();
        int start = -1;
        for (int i = 0; i < samples.size(); i++) {
            Sample s = samples.get(i);
            if (s.pedal >= 60) { if (start < 0) start = i; }
            else if (start >= 0) { out.add(mk(start, i - 1)); start = -1; }
        }
        if (start >= 0) out.add(mk(start, samples.size() - 1));
        List<Pull> f = new ArrayList<>();
        for (Pull p : out) if (p.tEnd - p.tStart >= 0.3) f.add(p);
        return f;
    }
    private Pull mk(int s, int e) { Pull p = new Pull(); p.start = s; p.end = e; p.tStart = samples.get(s).t; p.tEnd = samples.get(e).t; return p; }

    private static String f1(double v) { return String.format(Locale.US, "%.1f", v); }
    private static String f2(double v) { return String.format(Locale.US, "%.2f", v); }

    private static double interp(List<double[]> reads, double t) {
        if (reads.isEmpty()) return 0;
        if (t <= reads.get(0)[0]) return reads.get(0)[1];
        for (int i = 1; i < reads.size(); i++) {
            if (reads.get(i)[0] >= t) {
                double t0 = reads.get(i - 1)[0], m0 = reads.get(i - 1)[1], t1 = reads.get(i)[0], m1 = reads.get(i)[1];
                return t1 > t0 ? m0 + (m1 - m0) * (t - t0) / (t1 - t0) : m1;
            }
        }
        return reads.get(reads.size() - 1)[1];
    }

    public Summary summary() {
        Summary s = new Summary();
        if (samples.isEmpty()) { s.lines.add("Örnek yok"); return s; }
        double rpmMax = 0, pedalMax = 0;
        TreeSet<Integer> gears = new TreeSet<>();
        for (Sample x : samples) { rpmMax = Math.max(rpmMax, x.rpm); pedalMax = Math.max(pedalMax, x.pedal); if (x.gear > 0) gears.add(x.gear); }
        StringBuilder g = new StringBuilder();
        for (int v : gears) { if (g.length() > 0) g.append(','); g.append(v); }
        s.lines.add("RPM max " + (int) rpmMax + " | Pedal max " + (int) pedalMax + "%" + (gears.isEmpty() ? "" : " | vites " + g));
        if (pedalMax > 100 || pedalMax < 0) s.flags.add("Pedal decode hatasi (" + (int) pedalMax + "%): 0x36/0x12 offset yanlis, pull analizi gecersiz");

        List<Double> gaps = new ArrayList<>();
        for (int i = 1; i < samples.size(); i++) { double dt = samples.get(i).t - samples.get(i - 1).t; if (dt > 1.0) gaps.add(dt); }
        if (!gaps.isEmpty()) {
            double mx = 0; for (double d : gaps) mx = Math.max(mx, d);
            s.lines.add("Ornekleme boslugu > 1 s: " + gaps.size() + " (max " + f1(mx) + " s) - adaptor takildi, veri eksik");
        }

        // standing start
        List<Sample> speedRows = new ArrayList<>();
        for (Sample x : samples) if (x.src == 0x26) speedRows.add(x);
        if (speedRows.size() >= 3) {
            int li = -1;
            for (int i = 0; i < speedRows.size(); i++) {
                Sample r = speedRows.get(i);
                if (r.speed >= 3) continue;
                for (Sample x : samples) if (x.t > r.t && x.t < r.t + 3 && x.pedal >= 60) { li = i; break; }
                if (li >= 0) break;
            }
            if (li >= 0) {
                double t0 = speedRows.get(li).t;
                for (Sample x : samples) if (x.t >= speedRows.get(li).t && x.pedal >= 60) { t0 = x.t; break; }
                double vmax = 0; for (int j = li; j < speedRows.size(); j++) vmax = Math.max(vmax, speedRows.get(j).speed);
                StringBuilder line = new StringBuilder("Kalkis t=" + f1(t0) + "s (duruyor, pedal >= 60%) | v max " + (int) vmax + " km/h");
                for (double v : new double[]{60, 80, 100}) {
                    Double tt = null;
                    for (int j = li + 1; j < speedRows.size(); j++) {
                        if (speedRows.get(j).speed >= v) {
                            Sample a = speedRows.get(j - 1), b = speedRows.get(j);
                            tt = b.speed > a.speed ? a.t + (b.t - a.t) * (v - a.speed) / (b.speed - a.speed) - t0 : b.t - t0;
                            break;
                        }
                    }
                    if (tt != null) line.append(" | 0-").append((int) v).append(" ").append(f1(tt)).append(" s");
                }
                if (vmax < 100) line.append(" | 100 km/h'ye ulasilmadi");
                s.lines.add(line.toString());
            } else {
                double mn = 99; for (Sample r : speedRows) mn = Math.min(mn, r.speed);
                if (mn >= 3) s.lines.add("Bu kayitta duran kalkis yok (min hiz " + (int) mn + " km/h) - 0-100 olculemez");
            }
        } else s.lines.add("Hiz kaydedilmedi (blok 0x26 yok) - 0-100 olculemez");

        List<double[]> mafReads = new ArrayList<>(), setReads = new ArrayList<>();
        for (Sample x : samples) if (x.src == 0x36) { mafReads.add(new double[]{x.t, x.maf}); setReads.add(new double[]{x.t, x.boostSet}); }

        List<Pull> events = pulls();
        List<Pull> longPulls = new ArrayList<>();
        for (Pull p : events) if (p.tEnd - p.tStart >= 1.5) longPulls.add(p);

        // A/F rows (0x28 rows with fresh fuel, MAF interpolated)
        class AF { Sample s; double maf, af; }
        List<AF> afRows = new ArrayList<>();
        for (Sample x : samples) if (x.src == 0x28 && x.fuelUsed() >= 5.0) { AF a = new AF(); a.s = x; a.maf = interp(mafReads, x.t); a.af = a.maf / x.fuelUsed(); afRows.add(a); }
        AF pk = null; for (AF a : afRows) if (pk == null || a.s.fuelUsed() > pk.s.fuelUsed()) pk = a;
        if (pk != null) s.lines.add("Yakit tepe " + f1(pk.s.fuelUsed()) + " mg/str @" + (int) pk.s.rpm + "rpm t=" + f1(pk.s.t) + "s | MAF " + f1(pk.maf) + " -> A/F " + f1(pk.af));
        AF tipLo = null, pullLo = null, otherLo = null;
        for (AF a : afRows) {
            double t = a.s.t;
            boolean inLong = false, tip = false;
            for (Pull p : longPulls) { if (t >= p.tStart && t <= p.tEnd) inLong = true; if (t >= p.tStart && t < p.tStart + 0.5) tip = true; }
            if (tip) { if (tipLo == null || a.af < tipLo.af) tipLo = a; }
            else if (inLong) { if (pullLo == null || a.af < pullLo.af) pullLo = a; }
            else if (a.s.pedal > 30 || a.s.fuelUsed() > 15) { if (otherLo == null || a.af < otherLo.af) otherLo = a; }
        }
        if (tipLo != null) s.lines.add("A/F tip-in (ilk 0.5 s, MAF gecikir, bayrak yok) " + f1(tipLo.af) + " @" + (int) tipLo.s.rpm + "rpm t=" + f1(tipLo.s.t) + "s");
        if (pullLo != null) {
            s.lines.add("A/F min (>= 1.5 s pull, tip-in sonrasi) " + f1(pullLo.af) + " @" + (int) pullLo.s.rpm + "rpm t=" + f1(pullLo.s.t) + "s (yakit " + f1(pullLo.s.fuelUsed()) + " / hava " + f1(pullLo.maf) + ")");
            if (pullLo.af < 15) s.flags.add("A/F < 15: cok zengin karisim, kara duman kacinilmaz (hava az veya yakit fazla)");
            else if (pullLo.af < 17) s.flags.add("A/F < 17: zengin karisim, duman sinirinda");
        }
        if (otherLo != null) s.lines.add("A/F min (kisa darbe / kismi gaz, bayrak yok) " + f1(otherLo.af) + " @" + (int) otherLo.s.rpm + "rpm t=" + f1(otherLo.s.t) + "s");

        // boost
        double ambient = Double.MAX_VALUE, actMax = 0, setMax = 0;
        Sample peakBoost = null;
        for (Sample x : samples) {
            if (x.boostAct > 0) { ambient = Math.min(ambient, x.boostAct); actMax = Math.max(actMax, x.boostAct); if (peakBoost == null || x.boostAct > peakBoost.boostAct) peakBoost = x; }
            setMax = Math.max(setMax, x.boostSet);
        }
        if (ambient == Double.MAX_VALUE) ambient = 0;
        s.lines.add("Boost act max " + f2(actMax) + " bar abs | set max " + f2(setMax) + " | ortam ~" + f2(ambient));
        if (events.isEmpty()) s.lines.add("Pedal hic >= 60% tutulmadi - tam gaz gecisi yakalanmadi");

        double worstDeficit = 0, worstLag = 0; boolean neverReached = false;
        List<Double> railLoad = new ArrayList<>();
        int n = 0;
        for (Pull p : events) {
            n++;
            StringBuilder line = new StringBuilder("Pull " + n + " t=" + f1(p.tStart) + "-" + f1(p.tEnd) + "s rpm " + (int) samples.get(p.start).rpm + "->" + (int) samples.get(p.end).rpm);
            if (p.tEnd - p.tStart < 2.0) { line.append(" | kisa pull, boost/rail degerlendirilmedi"); s.lines.add(line.toString()); continue; }
            int evalEnd = p.start;
            for (int i = p.end; i >= p.start; i--) if (samples.get(i).src == 0x36 || samples.get(i).src == 0x12) { evalEnd = i; break; }
            List<Sample> rows12 = new ArrayList<>();
            for (int i = p.start; i <= evalEnd; i++) { Sample x = samples.get(i); if (x.src == 0x12 && x.boostAct > 0 && x.boostSet > 0) rows12.add(x); }
            List<Sample> settled = new ArrayList<>();
            for (Sample x : rows12) if (x.t >= p.tStart + 0.7) settled.add(x);
            Sample d = null; double dDef = -1e9;
            for (Sample x : settled) { double def = interp(setReads, x.t) - x.boostAct; if (def > dDef) { dDef = def; d = x; } }
            if (d != null) { worstDeficit = Math.max(worstDeficit, dDef); line.append(" | acik max ").append(f2(dDef)).append(" bar @").append((int) d.rpm).append("rpm"); }
            double spoolThr = ambient + 0.5;
            int hitIdx = -1;
            for (int i = 0; i < rows12.size(); i++) if (rows12.get(i).boostAct >= spoolThr) { hitIdx = i; break; }
            if (hitIdx >= 0) {
                Sample hit = rows12.get(hitIdx);
                Sample before = hitIdx > 0 ? rows12.get(hitIdx - 1) : null;
                if (before == null && p.start > 0) for (int i = p.start - 1; i >= 0; i--) { Sample x = samples.get(i); if (x.src == 0x12 && x.boostAct > 0) { before = x; break; } }
                double tCross = hit.t;
                if (before != null && before.boostAct < spoolThr && hit.boostAct > before.boostAct)
                    tCross = before.t + (hit.t - before.t) * (spoolThr - before.boostAct) / (hit.boostAct - before.boostAct);
                double lag = Math.max(0, tCross - p.tStart);
                worstLag = Math.max(worstLag, lag);
                line.append(" | +0.5 bar'a ").append(f1(lag)).append("s");
            } else {
                double mxSet = 0; for (Sample x : rows12) mxSet = Math.max(mxSet, interp(setReads, x.t));
                if (mxSet > ambient + 0.5) { neverReached = true; line.append(" | +0.5 bar'a ULASILMADI"); }
                else if (rows12.isEmpty()) line.append(" | boost okumasi yok");
                else line.append(" | boost talebi yok");
            }
            for (Sample x : settled) if (x.rail > 0 && x.iq >= 5.0) railLoad.add(x.rail);
            s.lines.add(line.toString());
        }
        if (worstDeficit > 0.4) s.flags.add("Boost hedefin 0.4 bar+ altinda kaliyor: VNT kanatcik / hortum kacagi / N75 kontrol");
        if (worstLag > 2.5) s.flags.add("Turbo +0.5 bar'a 2.5 s'den gec ulasiyor: turbo lag donemi uzun, duman bu pencerede olusur");
        if (neverReached) s.flags.add("Turbo pedal basiliyken +0.5 bar'a hic ulasamadi: VNT sikismasi / kacak / MAP sensor");

        if (peakBoost != null && peakBoost.maf > 0) {
            double pPa = peakBoost.boostAct * 100000.0;
            double tK = (peakBoost.iat > -40 ? peakBoost.iat : 25) + 273.15;
            double theo = pPa * 0.000537 / (287.0 * tK) * 1_000_000.0 * 0.85;
            double ratio = peakBoost.maf / theo;
            s.lines.add("Boost tepesinde MAF " + f1(peakBoost.maf) + " mg/str vs teorik " + f1(theo) + " (oran " + f2(ratio) + ")");
            if (ratio < 0.7) s.flags.add("MAF teorik havanin %70 altinda: MAF sensor dusuk okuyor veya MAF sonrasi kacak");
            if (ratio > 1.2) s.flags.add("MAF teorik havanin %120 ustunde: MAF yuksek okuyor -> ECU fazla yakit verir -> duman");
        }

        double railMax = 0; for (Sample x : samples) railMax = Math.max(railMax, x.rail);
        if (!railLoad.isEmpty()) {
            double rmin = Double.MAX_VALUE; for (double r : railLoad) rmin = Math.min(rmin, r);
            s.lines.add("Yuk altinda rail (oturmus) min " + (int) rmin + " bar | max " + (int) railMax + " bar");
            if (rmin < 600) s.flags.add("Yuk altinda rail < 600 bar: yakit basinci cokuyor (CP1 pompa / regulator / filtre)");
        } else s.lines.add("Rail max " + (int) railMax + " bar");

        double cool = samples.get(samples.size() - 1).coolant, iatMax = -999;
        for (Sample x : samples) iatMax = Math.max(iatMax, x.iat);
        s.lines.add("Sogutma " + (int) cool + "C | IAT max " + (int) iatMax + "C");
        if (cool < 70) s.flags.add("Motor soguk (<70C): test sicak motorla tekrarlanmali");
        if (iatMax > 60) s.flags.add("Emme havasi > 60C: intercooler verimi dusuk / EGR gazi giriyor olabilir");

        double maxCorr = 0; int idleRows = 0;
        for (Sample x : samples) if (x.rpm > 0 && x.rpm < 1000) { idleRows++; for (double c : x.corr) maxCorr = Math.max(maxCorr, Math.abs(c)); }
        if (idleRows > 0) {
            s.lines.add("Enjeksiyon duzeltme max |" + f2(maxCorr) + "| mg/str (rolanti satiri: " + idleRows + ")");
            if (maxCorr > 3) s.flags.add("Silindir duzeltmesi > 3 mg: enjektor / kompresyon dengesizligi");
        } else s.lines.add("Enjeksiyon duzeltmeleri: yok (ECU sadece rolantide verir)");

        Sample fpk = null; for (Sample x : samples) if (fpk == null || x.fuelUsed() > fpk.fuelUsed()) fpk = x;
        if (fpk != null) {
            List<Sample> reads21 = new ArrayList<>(), under = new ArrayList<>();
            for (Sample x : samples) if (x.src == 0x21) { reads21.add(x); if (x.pedal >= 60) under.add(x); }
            List<Sample> pool = under.isEmpty() ? reads21 : under;
            Sample w = null; for (Sample x : pool) if (w == null || Math.abs(x.t - fpk.t) < Math.abs(w.t - fpk.t)) w = x;
            if (w != null && w.fq.length >= 7) {
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < 7; i++) { if (i > 0) sb.append(" / "); sb.append(f1(w.fq[i])); }
                s.lines.add("0x21 kelimeleri @t=" + f1(w.t) + "s pedal " + (int) w.pedal + "%: " + sb);
            }
        }
        if (!marks.isEmpty()) {
            StringBuilder sb = new StringBuilder();
            for (double m : marks) { if (sb.length() > 0) sb.append(", "); sb.append(f1(m)).append('s'); }
            s.lines.add("Duman isaretleri: " + sb);
        }
        return s;
    }

    // ------------------------------------------------------------------ text

    public static final String CSV_HEADER = "t,src,rpm,ped,gear,b36s,kmh,iq,fuel,maf,af,bAct,bSet,map,rail,cool,iat,fq0,fq1,fq2,fq3,fq4,fq5,fq6,egr,wg,b36c,b20a,b20b,b23a,b23g,c1,c2,c3,c4,c5,mark";

    public String csvText() {
        StringBuilder o = new StringBuilder(CSV_HEADER).append('\n');
        for (Sample s : samples) {
            o.append(f2(s.t)).append(',').append(String.format("%02X", s.src)).append(',').append((int) s.rpm).append(',')
             .append((int) s.pedal).append(',').append(s.gear).append(',').append((int) s.b36s).append(',').append((int) s.speed).append(',')
             .append(f1(s.iq)).append(',').append(f1(s.fuelAct)).append(',').append(f1(s.maf)).append(',').append(f1(s.af())).append(',')
             .append(String.format(Locale.US, "%.3f", s.boostAct)).append(',').append(String.format(Locale.US, "%.3f", s.boostSet)).append(',')
             .append((int) s.map).append(',').append((int) s.rail).append(',').append((int) s.coolant).append(',').append((int) s.iat);
            for (double v : s.fq) o.append(',').append(f1(v));
            o.append(',').append((int) s.egr).append(',').append((int) s.wg).append(',').append((int) s.b36c).append(',').append((int) s.b20a)
             .append(',').append((int) s.b20b).append(',').append((int) s.b23a).append(',').append((int) s.b23g);
            for (double v : s.corr) o.append(',').append(f2(v));
            o.append(',').append(s.mark).append('\n');
        }
        return o.toString();
    }

    public String reportText() {
        SimpleDateFormat df = new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US);
        String when = startDate != null ? df.format(startDate) : "-";
        StringBuilder o = new StringBuilder("WJDiag SMOKE TEST " + when + "\n");
        double dur = duration();
        double rate = dur > 0 ? samples.size() / dur : 0;
        int fuelReads = 0; for (Sample s : samples) if (s.src == 0x28) fuelReads++;
        double fuelRate = dur > 0 ? fuelReads / dur : 0;
        o.append("Sure ").append(f1(dur)).append("s, ").append(samples.size()).append(" ornek (").append(f1(rate)).append("/s, yakit+pedal ")
         .append(f1(fuelRate)).append("/s), ").append(marks.size()).append(" isaret, ECU init ").append(f1(initSeconds)).append("s\n");
        if (error != null) o.append("ERROR: ").append(error).append('\n');
        Summary sum = summary();
        o.append("-- OZET --\n");
        for (String l : sum.lines) o.append(l).append('\n');
        o.append("-- BAYRAKLAR --\n");
        if (sum.flags.isEmpty()) o.append("yok\n"); else for (String f : sum.flags) o.append("! ").append(f).append('\n');
        o.append("-- CSV (mg/str, bar abs, C) --\n").append(csvText());
        return o.toString();
    }

    public String fileName() {
        SimpleDateFormat df = new SimpleDateFormat("yyyyMMdd_HHmm", Locale.US);
        return "SmokeTest_" + df.format(startDate != null ? startDate : new Date()) + ".txt";
    }
}
