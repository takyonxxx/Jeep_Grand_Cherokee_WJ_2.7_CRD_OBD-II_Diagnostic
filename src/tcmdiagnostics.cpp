#include "tcmdiagnostics.h"
#include <QDebug>
#include <QTimer>

// ============================================================
// WJ 2.7 CRD Multi-Protocol Diagnostics
// APK verified: K-Line 0x15=Motor, 0x20=EPC | J1850 0x28=TCM
// ============================================================

WJDiagnostics::WJDiagnostics(ELM327Connection *elm, QObject *parent)
    : QObject(parent), m_elm(elm)
{
    m_kwp = new KWP2000Handler(elm, this);
    connect(m_kwp, &KWP2000Handler::logMessage,
            this, &WJDiagnostics::logMessage);
}

// --- Static Module Registry ---

QList<WJDiagnostics::ModuleInfo> WJDiagnostics::allModules()
{
    return {
        // K-Line modules (ISO 14230-4 KWP fast init)
        {Module::MotorECU, "Motor ECU (Bosch EDC15C2 OM612)", "Motor",
         BusType::KLine, "ATSH8115F1", "ATWM8115F13E", "ATSP5"},
        {Module::EPC, "CRD Cruise Control / EPC", "EPC",
         BusType::KLine, "ATSH8120F1", "ATWM8120F13E", "ATSP5"},
        // J1850 VPW modules (SAE J1850 VPW) - APK dogrulanmis
        {Module::TCM, "NAG1 722.6 Sanziman (EGS52)", "TCM",
         BusType::J1850, "ATSH242810", "", "ATSP2"},
        {Module::TransferCase, "NV247 Transfer Case (4WD)", "T-Case",
         BusType::J1850, "ATSH242A10", "", "ATSP2"},
        {Module::ABS, "ABS / ESP Frenleme", "ABS",
         BusType::J1850, "ATSH244011", "", "ATSP2"},
        {Module::Airbag, "Airbag (ORC)", "Airbag",
         BusType::J1850, "ATSH246011", "", "ATSP2"},
        {Module::SKIM, "SKIM Immobilizer", "SKIM",
         BusType::J1850, "ATSH246211", "", "ATSP2"},
        {Module::ATC, "Klima Kontrol (ATC)", "Klima",
         BusType::J1850, "ATSH246811", "", "ATSP2"},
        {Module::BCM, "Govde Kontrol (BCM)", "BCM",
         BusType::J1850, "ATSH248011", "", "ATSP2"},
        {Module::Compass, "Pusula / Mini-Trip", "Pusula",
         BusType::J1850, "ATSH248711", "", "ATSP2"},
        {Module::Cluster, "Gosterge Paneli", "Gosterge",
         BusType::J1850, "ATSH249011", "", "ATSP2"},
        {Module::Radio, "Radyo / Ses Sistemi", "Radyo",
         BusType::J1850, "ATSH249811", "", "ATSP2"},
        {Module::Overhead, "Tavan Konsolu", "Tavan",
         BusType::J1850, "ATSH24A011", "", "ATSP2"},
    };
}

WJDiagnostics::ModuleInfo WJDiagnostics::moduleInfo(Module mod)
{
    for (const auto &m : allModules())
        if (m.id == mod) return m;
    return allModules().first();
}

QString WJDiagnostics::moduleName(Module mod)
{
    return moduleInfo(mod).shortName;
}

// --- Protocol & Module Switching ---

void WJDiagnostics::switchToModule(Module mod, std::function<void(bool)> done)
{
    auto info = moduleInfo(mod);
    BusType newBus = info.bus;

    emit logMessage(QString("Modul: %1 [%2]")
        .arg(info.name, info.bus == BusType::KLine ? "K-Line" : "J1850"));

    auto setHeaders = [this, info, mod, done]() {
        m_elm->sendCommand(info.atshHeader, [this, info, mod, done](const QString&) {
            if (!info.atwmWakeup.isEmpty()) {
                m_elm->sendCommand(info.atwmWakeup, [this, info, mod, done](const QString&) {
                    m_activeModule = mod;
                    m_activeBus = info.bus;
                    emit logMessage(QString("Aktif: %1 | %2 | %3")
                        .arg(info.shortName, info.atshHeader, info.atwmWakeup));
                    if (done) done(true);
                });
            } else {
                m_activeModule = mod;
                m_activeBus = info.bus;
                emit logMessage(QString("Aktif: %1 | %2").arg(info.shortName, info.atshHeader));
                if (done) done(true);
            }
        });
    };

    if (newBus != m_activeBus) {
        QString proto = info.atspProtocol;
        emit logMessage(QString("Protokol: %1").arg(proto));
        m_elm->sendCommand(proto, [this, newBus, setHeaders](const QString&) {
            if (newBus == BusType::KLine) {
                m_elm->sendCommand("ATFI", [this, setHeaders](const QString &fi) {
                    if (fi.contains("?") || fi.contains("ERROR")) {
                        emit logMessage("ATFI basarisiz, ATSP3 fallback");
                        m_elm->sendCommand("ATSP3", [setHeaders](const QString&) {
                            setHeaders();
                        });
                    } else {
                        setHeaders();
                    }
                });
            } else {
                setHeaders();
            }
        });
    } else {
        setHeaders();
    }
}

// --- Session ---

void WJDiagnostics::startSession(Module mod, std::function<void(bool)> cb)
{
    switchToModule(mod, [this, mod, cb](bool ok) {
        if (!ok) { if (cb) cb(false); return; }
        if (moduleInfo(mod).bus == BusType::KLine) {
            m_kwp->startDiagnosticSession(KWP2000Handler::DefaultSession,
                [this, mod, cb](bool s) {
                    emit moduleReady(mod, s);
                    if (cb) cb(s);
                });
        } else {
            emit moduleReady(mod, true);
            if (cb) cb(true);
        }
    });
}

void WJDiagnostics::stopSession()
{
    if (m_activeBus == BusType::KLine)
        m_kwp->startDiagnosticSession(KWP2000Handler::DefaultSession, nullptr);
}

// --- DTC Read/Clear ---

void WJDiagnostics::readDTCs(Module mod, std::function<void(const QList<DTCEntry>&)> cb)
{
    switchToModule(mod, [this, mod, cb](bool ok) {
        if (!ok) { if (cb) cb({}); return; }

        if (moduleInfo(mod).bus == BusType::KLine) {
            m_kwp->readAllDTCs([this, mod, cb](const QList<KWP2000Handler::DTCInfo> &kwp) {
                QList<DTCEntry> r;
                for (const auto &d : kwp) {
                    DTCEntry e;
                    e.code = d.codeStr; e.status = d.status;
                    e.isActive = d.isActive; e.occurrences = d.occurrences;
                    e.description = dtcDescription(d.codeStr, mod);
                    e.source = mod;
                    r.append(e);
                }
                emit dtcListReady(mod, r);
                if (cb) cb(r);
            });
        } else {
            // J1850 VPW DTC read
            m_elm->sendCommand("1800FF00", [this, mod, cb](const QString &resp) {
                auto dtcs = decodeJ1850DTCs(resp, mod);
                emit dtcListReady(mod, dtcs);
                if (cb) cb(dtcs);
            });
        }
    });
}

void WJDiagnostics::clearDTCs(Module mod, std::function<void(bool)> cb)
{
    switchToModule(mod, [this, mod, cb](bool ok) {
        if (!ok) { if (cb) cb(false); return; }

        if (moduleInfo(mod).bus == BusType::KLine) {
            m_kwp->clearAllDTCs(cb);
        } else {
            m_elm->sendCommand("140000", [this, mod, cb](const QString &resp) {
                bool ok = !resp.contains("7F") && !resp.contains("ERROR");
                emit logMessage(QString("%1 DTC sil: %2")
                    .arg(moduleName(mod), ok ? "OK" : "FAIL"));
                if (cb) cb(ok);
            });
        }
    });
}

void WJDiagnostics::readModuleInfo(Module mod, std::function<void(const QMap<QString,QString>&)> cb)
{
    switchToModule(mod, [this, mod, cb](bool ok) {
        if (!ok) { if (cb) cb({}); return; }

        auto r = std::make_shared<QMap<QString,QString>>();
        auto info = moduleInfo(mod);
        (*r)["Module"] = info.name;
        (*r)["Bus"] = (info.bus == BusType::KLine) ? "K-Line" : "J1850 VPW";

        if (info.bus == BusType::KLine) {
            auto n = std::make_shared<int>(3);
            auto chk = [r, n, cb]() { if (--(*n) <= 0 && cb) cb(*r); };
            m_kwp->readECUIdentification(0x91, [r, chk](const QByteArray &d) {
                if (d.size() > 2) (*r)["ECU_ID"] = QString::fromLatin1(d.mid(2));
                chk();
            });
            m_kwp->readECUIdentification(0x90, [r, chk](const QByteArray &d) {
                if (d.size() > 2) (*r)["VIN"] = QString::fromLatin1(d.mid(2));
                chk();
            });
            m_kwp->readECUIdentification(0x86, [r, chk](const QByteArray &d) {
                if (d.size() > 2) (*r)["Variant"] = QString::fromLatin1(d.mid(2));
                chk();
            });
        } else {
            if (cb) cb(*r);
        }
    });
}

// --- ECU Live Data (K-Line 0x15) ---

void WJDiagnostics::readECULiveData(std::function<void(const ECUStatus&)> cb)
{
    auto ecu = std::make_shared<ECUStatus>();
    auto step = std::make_shared<int>(0);
    auto doNext = std::make_shared<std::function<void()>>();

    *doNext = [this, ecu, step, doNext, cb]() {
        uint8_t ids[] = {0x12, 0x28, 0x20, 0x22};
        if (*step >= 4) {
            m_lastECU = *ecu;
            emit ecuStatusUpdated(*ecu);
            if (cb) cb(*ecu);
            return;
        }
        m_kwp->readLocalData(ids[*step], [this, ecu, step, doNext](const QByteArray &data) {
            if (!data.isEmpty()) {
                uint8_t ids2[] = {0x12, 0x28, 0x20, 0x22};
                parseECUBlock(ids2[*step], data, *ecu);
            }
            (*step)++;
            QTimer::singleShot(30, *doNext);
        });
    };

    switchToModule(Module::MotorECU, [doNext](bool ok) {
        if (ok) (*doNext)();
    });
}

// --- TCM Live Data (J1850 VPW 0x28) ---

void WJDiagnostics::readTCMLiveData(std::function<void(const TCMStatus&)> cb)
{
    // J1850 VPW: ATSH242822 for ReadDataByPID
    // PIDs need real vehicle verification
    auto tcm = std::make_shared<TCMStatus>();

    switchToModule(Module::TCM, [this, tcm, cb](bool ok) {
        if (!ok) { if (cb) cb(*tcm); return; }
        // Switch to data-read header
        m_elm->sendCommand("ATSH242822", [this, tcm, cb](const QString&) {
            // Read basic PIDs sequentially
            auto step = std::make_shared<int>(0);
            auto doNext = std::make_shared<std::function<void()>>();

            // Chrysler J1850 PID pairs: cmd -> parse
            struct PIDRead { QString cmd; QString name; };
            auto pids = std::make_shared<QList<PIDRead>>(QList<PIDRead>{
                {"2201", "Actual Gear"},
                {"2202", "Selected Gear"},
                {"2210", "Turbine RPM"},
                {"2211", "Output RPM"},
                {"2214", "Trans Temp"},
                {"2220", "Vehicle Speed"},
            });

            *doNext = [this, tcm, step, doNext, pids, cb]() {
                if (*step >= pids->size()) {
                    m_lastTCM = *tcm;
                    emit tcmStatusUpdated(*tcm);
                    if (cb) cb(*tcm);
                    return;
                }
                auto &p = pids->at(*step);
                m_elm->sendCommand(p.cmd, [this, tcm, step, doNext, p](const QString &resp) {
                    QString c = resp; c.remove(' ').remove('\r').remove('\n');
                    if (!c.contains("NODATA") && !c.contains("7F") && c.size() >= 6) {
                        bool ok;
                        if (p.cmd == "2201") {
                            int v = c.mid(4,2).toInt(&ok,16); if(ok) tcm->actualGear = v;
                        } else if (p.cmd == "2202") {
                            int v = c.mid(4,2).toInt(&ok,16); if(ok) tcm->selectedGear = v;
                        } else if (p.cmd == "2210") {
                            int v = c.mid(4,4).toInt(&ok,16); if(ok) tcm->turbineRPM = v;
                        } else if (p.cmd == "2211") {
                            int v = c.mid(4,4).toInt(&ok,16); if(ok) tcm->outputRPM = v;
                        } else if (p.cmd == "2214") {
                            int v = c.mid(4,2).toInt(&ok,16); if(ok) tcm->transTemp = v - 40;
                        } else if (p.cmd == "2220") {
                            int v = c.mid(4,4).toInt(&ok,16); if(ok) tcm->vehicleSpeed = v;
                        }
                    }
                    (*step)++;
                    QTimer::singleShot(40, *doNext);
                });
            };
            (*doNext)();
        });
    });
}

// --- ABS Live Data (J1850 VPW 0x40) ---

void WJDiagnostics::readABSLiveData(std::function<void(const ABSStatus&)> cb)
{
    auto abs = std::make_shared<ABSStatus>();

    switchToModule(Module::ABS, [this, abs, cb](bool ok) {
        if (!ok) { if (cb) cb(*abs); return; }
        // Switch to data-read header for ABS
        m_elm->sendCommand("ATSH244022", [this, abs, cb](const QString&) {
            auto step = std::make_shared<int>(0);
            auto doNext = std::make_shared<std::function<void()>>();

            // APK live data params: LF/RF/LR/RR Wheel Speed, Vehicle Speed
            struct PIDRead { QString cmd; QString name; };
            auto pids = std::make_shared<QList<PIDRead>>(QList<PIDRead>{
                {"2201", "LF Wheel Speed"},
                {"2202", "RF Wheel Speed"},
                {"2203", "LR Wheel Speed"},
                {"2204", "RR Wheel Speed"},
                {"2210", "Vehicle Speed"},
            });

            *doNext = [this, abs, step, doNext, pids, cb]() {
                if (*step >= pids->size()) {
                    m_lastABS = *abs;
                    emit absStatusUpdated(*abs);
                    if (cb) cb(*abs);
                    return;
                }
                auto &p = pids->at(*step);
                m_elm->sendCommand(p.cmd, [this, abs, step, doNext, p](const QString &resp) {
                    QString c = resp; c.remove(' ').remove('\r').remove('\n');
                    if (!c.contains("NODATA") && !c.contains("7F") && c.size() >= 6) {
                        bool ok;
                        int v = c.mid(4, 4).toInt(&ok, 16);
                        if (!ok) v = c.mid(4, 2).toInt(&ok, 16);
                        if (ok) {
                            if (p.cmd == "2201") abs->wheelLF = v;
                            else if (p.cmd == "2202") abs->wheelRF = v;
                            else if (p.cmd == "2203") abs->wheelLR = v;
                            else if (p.cmd == "2204") abs->wheelRR = v;
                            else if (p.cmd == "2210") abs->vehicleSpeed = v;
                        }
                    }
                    (*step)++;
                    QTimer::singleShot(40, *doNext);
                });
            };
            (*doNext)();
        });
    });
}

// --- Raw Bus Dump ---

void WJDiagnostics::rawBusDump(Module mod, const QList<uint8_t> &ids,
                                 std::function<void(uint8_t, const QByteArray&)> perID,
                                 std::function<void()> done)
{
    auto idx = std::make_shared<int>(0);
    auto idList = std::make_shared<QList<uint8_t>>(ids);
    auto readNext = std::make_shared<std::function<void()>>();
    auto busType = moduleInfo(mod).bus;

    *readNext = [this, idx, idList, readNext, perID, done, busType]() {
        if (*idx >= idList->size()) { if (done) done(); return; }
        uint8_t lid = idList->at(*idx);

        if (busType == BusType::KLine) {
            m_kwp->readLocalData(lid, [idx, readNext, perID, lid](const QByteArray &data) {
                if (perID) perID(lid, data);
                (*idx)++;
                QTimer::singleShot(40, *readNext);
            });
        } else {
            QString cmd = QString("22%1").arg(lid, 2, 16, QChar('0'));
            m_elm->sendCommand(cmd, [idx, readNext, perID, lid](const QString &resp) {
                QByteArray data;
                QString c = resp; c.remove(' ').remove('\r').remove('\n');
                for (int i = 0; i + 1 < c.size(); i += 2) {
                    bool ok; uint8_t b = c.mid(i, 2).toUInt(&ok, 16);
                    if (ok) data.append(static_cast<char>(b));
                }
                if (perID) perID(lid, data);
                (*idx)++;
                QTimer::singleShot(40, *readNext);
            });
        }
    };

    switchToModule(mod, [readNext](bool ok) { if (ok) (*readNext)(); });
}

void WJDiagnostics::rawSendCommand(const QString &cmd, std::function<void(const QString&)> cb)
{
    m_elm->sendCommand(cmd, [cb](const QString &r) { if (cb) cb(r); });
}

// --- ECU Block Parser ---

void WJDiagnostics::parseECUBlock(uint8_t localID, const QByteArray &d, ECUStatus &ecu)
{
    int n = d.size();
    auto u8 = [&](int i) -> uint8_t { return (i < n) ? static_cast<uint8_t>(d[i]) : 0; };
    auto u16 = [&](int i) -> uint16_t { return (uint16_t(u8(i)) << 8) | u8(i+1); };
    auto s16 = [&](int i) -> int16_t { return static_cast<int16_t>(u16(i)); };

    switch (localID) {
    case 0x12:
        if (n >= 34) {
            ecu.coolantTemp = u16(2) / 10.0 - 273.1;
            ecu.iat = u16(4) / 10.0 - 273.1;
            ecu.mapActual = u16(18);
            ecu.aap = u16(30);
            ecu.tps = u16(16) / 19.53;
            emit logMessage(QString("ECU 2112: cool=%1 iat=%2 map=%3 tps=%4")
                .arg(ecu.coolantTemp,0,'f',1).arg(ecu.iat,0,'f',1)
                .arg(ecu.mapActual).arg(ecu.tps,0,'f',1));
        }
        break;
    case 0x20:
        if (n >= 18) {
            ecu.mafActual = u16(14);
            ecu.mafSpec = u16(16);
            emit logMessage(QString("ECU 2120: maf=%1/%2").arg(ecu.mafActual).arg(ecu.mafSpec));
        }
        break;
    case 0x22:
        if (n >= 34) {
            ecu.railSpec = u16(18) / 10.0;
            ecu.mapSpec = u16(16);
            emit logMessage(QString("ECU 2122: rail=%1bar mapSpec=%2")
                .arg(ecu.railSpec,0,'f',1).arg(ecu.mapSpec));
        }
        break;
    case 0x28:
        if (n >= 28) {
            ecu.rpm = u16(2);
            ecu.injectionQty = u16(4) / 100.0;
            for (int i = 0; i < 5; i++)
                ecu.injCorr[i] = s16(18 + i*2) / 100.0;
            emit logMessage(QString("ECU 2128: rpm=%1 iq=%2 inj=[%3,%4,%5,%6,%7]")
                .arg(ecu.rpm).arg(ecu.injectionQty,0,'f',1)
                .arg(ecu.injCorr[0],0,'f',2).arg(ecu.injCorr[1],0,'f',2)
                .arg(ecu.injCorr[2],0,'f',2).arg(ecu.injCorr[3],0,'f',2)
                .arg(ecu.injCorr[4],0,'f',2));
        }
        break;
    }
}

// --- J1850 DTC Decoder ---

QList<WJDiagnostics::DTCEntry> WJDiagnostics::decodeJ1850DTCs(const QString &resp, Module src)
{
    QList<DTCEntry> result;
    QString c = resp; c.remove(' ').remove('\r').remove('\n');
    if (c.contains("NODATA") || c.contains("ERROR") || c.size() < 6)
        return result;

    int start = 0;
    if (c.startsWith("58")) start = 4;

    for (int i = start; i + 3 < c.size(); i += 4) {
        bool ok;
        uint16_t raw = c.mid(i, 4).toUInt(&ok, 16);
        if (!ok || raw == 0) continue;

        DTCEntry e;
        char pfx;
        switch ((raw >> 14) & 3) {
        case 0: pfx='P'; break; case 1: pfx='C'; break;
        case 2: pfx='B'; break; default: pfx='U';
        }
        e.code = QString("%1%2").arg(pfx).arg(raw & 0x3FFF, 4, 16, QChar('0')).toUpper();
        e.description = dtcDescription(e.code, src);
        e.status = 0; e.isActive = true; e.occurrences = 1; e.source = src;
        result.append(e);
    }
    return result;
}

QList<WJDiagnostics::DTCEntry> WJDiagnostics::decodeKWPDTCs(const QByteArray &data, Module src)
{
    Q_UNUSED(data) Q_UNUSED(src) return {};
}

// --- DTC Descriptions (APK'dan) ---

QString WJDiagnostics::dtcDescription(const QString &code, Module src)
{
    static const QMap<QString, QString> ecuDtcs = {
        {"P0100","MAF Sensor Circuit"}, {"P0105","Barometric Pressure Sensor"},
        {"P0110","Air Intake Temp Sensor"}, {"P0115","Coolant Temp Sensor"},
        {"P0190","Fuel Rail Pressure Sensor"}, {"P0201","Cyl 1 Injector Circuit"},
        {"P0202","Cyl 2 Injector Circuit"}, {"P0203","Cyl 3 Injector Circuit"},
        {"P0204","Cyl 4 Injector Circuit"}, {"P0205","Cyl 5 Injector Circuit"},
        {"P0335","CKP Position Sensor"}, {"P0340","CMP Position Sensor"},
        {"P0380","Glow Plug Circuit"}, {"P0403","EGR Solenoid Circuit"},
        {"P0500","Vehicle Speed Sensor"}, {"P1130","Boost Pressure Sensor"},
        {"P2602","Fuel Pressure Solenoid"},
    };

    static const QMap<QString, QString> tcmDtcs = {
        {"P0700","Transmission Control System"}, {"P0705","Range Sensor Circuit"},
        {"P0710","Trans Fluid Temp Sensor"}, {"P0715","Input Speed Sensor"},
        {"P0720","Output Speed Sensor"}, {"P0730","Incorrect Gear Ratio"},
        {"P0731","Gear 1 Ratio Error"}, {"P0732","Gear 2 Ratio Error"},
        {"P0733","Gear 3 Ratio Error"}, {"P0734","Gear 4 Ratio Error"},
        {"P0735","Gear 5 Ratio Error"}, {"P0740","TCC Solenoid Circuit"},
        {"P0741","TCC Stuck On"}, {"P0748","Pressure Solenoid Electrical"},
        {"P0750","Shift Solenoid A"}, {"P0755","Shift Solenoid B"},
        {"P0760","Shift Solenoid C"}, {"P0765","Shift Solenoid D"},
        {"P0780","Shift Error"}, {"P0894","Transmission Slipping"},
    };

    // ABS DTCs (APK dogrulanmis - Chrysler C-codes + standard)
    static const QMap<QString, QString> absDtcs = {
        {"C0031","Left Front Sensor Circuit Failure"},
        {"C0032","Left Front Wheel Speed Signal Failure"},
        {"C0035","Right Front Sensor Circuit Failure"},
        {"C0036","Right Front Wheel Speed Signal Failure"},
        {"C0041","Left Rear Sensor Circuit Failure"},
        {"C0042","Left Rear Wheel Speed Signal Failure"},
        {"C0045","Right Rear Sensor Circuit Failure"},
        {"C0046","Right Rear Wheel Speed Signal Failure"},
        {"C0051","Valve Power Feed Failure"},
        {"C0060","Pump Motor Circuit Failure"},
        {"C0070","CAB Internal Failure"},
        {"C0080","ABS Lamp Circuit Short"},
        {"C0081","ABS Lamp Open"},
        {"C0085","Brake Lamp Circuit Short"},
        {"C0086","Brake Lamp Open"},
        {"C0110","Brake Fluid Level Switch"},
        {"C0111","G-Switch / Sensor Failure"},
        {"C1014","ABS Messages Not Received"},
        {"C1015","No BCM Park Brake Messages Received"},
    };

    // Airbag/ORC DTCs (APK dogrulanmis - B-codes)
    static const QMap<QString, QString> airbagDtcs = {
        {"B1000","Airbag Lamp Driver Failure"},
        {"B1001","Airbag Lamp Open"},
        {"B1010","Driver SQUIB 1 Circuit Open"},
        {"B1011","Driver SQUIB 1 Circuit Short"},
        {"B1012","Driver SQUIB 1 Short To Battery"},
        {"B1013","Driver SQUIB 1 Short To Ground"},
        {"B1014","Driver Squib 2 Circuit Open"},
        {"B1015","Driver SQUIB 2 Circuit Short"},
        {"B1016","Driver SQUIB 2 Short To Battery"},
        {"B1017","Driver SQUIB 2 Short To Ground"},
        {"B1020","Passenger SQUIB 1 Circuit Open"},
        {"B1021","Passenger SQUIB 1 Circuit Short"},
        {"B1022","Passenger SQUIB 1 Short To Battery"},
        {"B1023","Passenger SQUIB 1 Short To Ground"},
        {"B1024","Passenger SQUIB 2 Circuit Open"},
        {"B1025","Passenger SQUIB 2 Circuit Short"},
        {"B1026","Passenger SQUIB 2 Short To Battery"},
        {"B1027","Passenger SQUIB 2 Short To Ground"},
        {"B1030","Driver Curtain SQUIB Circuit Open"},
        {"B1031","Driver Curtain SQUIB Short To Battery"},
        {"B1032","Driver Curtain SQUIB Short To Ground"},
        {"B1033","Passenger Curtain SQUIB Circuit Open"},
        {"B1034","Passenger Curtain SQUIB Circuit Short"},
        {"B1035","Passenger Curtain SQUIB Short To Battery"},
        {"B1036","Passenger Curtain SQUIB Short To Ground"},
        {"B1040","Driver Side Impact Sensor Internal 1"},
        {"B1041","No Driver Side Impact Sensor Communication"},
        {"B1042","Passenger Side Impact Sensor Internal 1"},
        {"B1043","No Passenger Side Impact Sensor Communication"},
        {"B1050","Driver Seat Belt Switch Circiut Open"},
        {"B1051","Driver Seat Belt Switch Shorted To Battery"},
        {"B1052","Driver Seat Belt Switch Shorted To Ground"},
        {"B1053","Passenger Seat Belt Switch Circiut Open"},
        {"B1054","Passenger Seat Belt Switch Shorted To Battery"},
        {"B1055","Passenger Seat Belt Switch Shorted To Ground"},
    };

    // BCM DTCs
    static const QMap<QString, QString> bcmDtcs = {
        {"B1A00","Interior Lamp Circuit"},
        {"B1A10","Door Ajar Switch Circuit"},
        {"B2100","SKIM Communication Error"},
    };

    // Lookup by source module first, then generic
    if (src == Module::MotorECU || src == Module::EPC) {
        if (ecuDtcs.contains(code)) return ecuDtcs[code];
    }
    if (src == Module::TCM) {
        if (tcmDtcs.contains(code)) return tcmDtcs[code];
    }
    if (src == Module::ABS) {
        if (absDtcs.contains(code)) return absDtcs[code];
    }
    if (src == Module::Airbag) {
        if (airbagDtcs.contains(code)) return airbagDtcs[code];
    }
    if (src == Module::BCM) {
        if (bcmDtcs.contains(code)) return bcmDtcs[code];
    }

    // Generic fallback - search all maps
    if (ecuDtcs.contains(code)) return ecuDtcs[code];
    if (tcmDtcs.contains(code)) return tcmDtcs[code];
    if (absDtcs.contains(code)) return absDtcs[code];
    if (airbagDtcs.contains(code)) return airbagDtcs[code];
    if (bcmDtcs.contains(code)) return bcmDtcs[code];
    return "";
}

// ============================================================
// Compat Methods (eski mainwindow/livedata API uyumu icin)
// ============================================================

// startSession(callback) - compat: K-Line TCM (0x10) oturum ac
// Eski UI K-Line uzerinden calisiyor, J1850'ye gecmeden KWP session acar
void WJDiagnostics::startSession(std::function<void(bool)> cb)
{
    // K-Line'da kal, eski header'i kur (0x10 = eski TCM adresi)
    emit logMessage("TCM oturumu baslatiliyor (K-Line 0x10)...");
    m_activeBus = BusType::KLine;

    m_elm->sendCommand("ATSP5", [this, cb](const QString&) {
        m_elm->sendCommand("ATFI", [this, cb](const QString &fi) {
            if (fi.contains("?") || fi.contains("ERROR")) {
                m_elm->sendCommand("ATSP3", [this, cb](const QString&) {
                    this->_finishLegacySession(cb);
                });
            } else {
                this->_finishLegacySession(cb);
            }
        });
    });
}

void WJDiagnostics::_finishLegacySession(std::function<void(bool)> cb)
{
    m_elm->sendCommand("ATSH8110F1", [this, cb](const QString&) {
        m_elm->sendCommand("ATWM8110F13E", [this, cb](const QString&) {
            m_kwp->startDiagnosticSession(KWP2000Handler::DefaultSession,
                [this, cb](bool success) {
                    if (success) {
                        emit logMessage("TCM K-Line oturumu aktif (0x10)");
                        initLiveDataParams();
                    }
                    if (cb) cb(success);
                });
        });
    });
}

// readDTCs(callback) - compat: aktif modul
void WJDiagnostics::readDTCs(std::function<void(const QList<KWP2000Handler::DTCInfo>&)> cb)
{
    Module mod = m_activeModule;
    readDTCs(mod, [this, cb](const QList<DTCEntry> &dtcs) {
        QList<KWP2000Handler::DTCInfo> kwpDtcs;
        for (const auto &d : dtcs) {
            KWP2000Handler::DTCInfo k;
            k.codeStr = d.code;
            k.description = d.description;
            k.status = d.status;
            k.isActive = d.isActive;
            k.occurrences = d.occurrences;
            k.code = 0;
            k.isStored = !d.isActive;
            kwpDtcs.append(k);
        }
        if (cb) cb(kwpDtcs);
    });
}

// clearDTCs(callback) - compat: aktif modul
void WJDiagnostics::clearDTCs(std::function<void(bool)> cb)
{
    clearDTCs(m_activeModule, cb);
}

// readAllLiveData - compat: K-Line uzerinden TCM local ID'lerden oku
void WJDiagnostics::readAllLiveData(std::function<void(const TCMStatus&)> cb)
{
    auto tcm = std::make_shared<TCMStatus>();
    auto step = std::make_shared<int>(0);
    auto doNext = std::make_shared<std::function<void()>>();

    // Okunacak local ID'ler (emulator'un destekledigi)
    QList<uint8_t> ids = {0x01,0x02,0x04,0x05,0x07,0x08,0x09,0x0A,0x0B,0x0E,0x0F,
                          0x12,0x13,0x14,0x15,0x20,0x23,0x30};

    *doNext = [this, tcm, step, doNext, ids, cb]() {
        if (*step >= ids.size()) {
            fillTCMCompat(*tcm);
            m_lastTCM = *tcm;
            emit tcmStatusUpdated(*tcm);
            if (cb) cb(*tcm);
            return;
        }
        uint8_t lid = ids[*step];
        m_kwp->readLocalData(lid, [this, tcm, step, doNext, lid](const QByteArray &data) {
            if (data.size() >= 4) {
                uint8_t valByte = static_cast<uint8_t>(data[2]);
                uint16_t val16 = (static_cast<uint8_t>(data[2]) << 8) | static_cast<uint8_t>(data[3]);
                int16_t sval16 = static_cast<int16_t>(val16);

                switch (lid) {
                case 0x01: tcm->actualGear = valByte; break;
                case 0x02: tcm->selectedGear = valByte; break;
                case 0x04: tcm->turbineRPM = val16; break;
                case 0x05: tcm->outputRPM = val16; break;
                case 0x07: tcm->vehicleSpeed = val16; break;
                case 0x08: tcm->transTemp = static_cast<int8_t>(valByte); break;
                case 0x09: tcm->solenoidSupply = valByte * 0.1; break;
                case 0x0A: tcm->actualTCCslip = sval16; break;
                case 0x0B: tcm->desTCCslip = sval16; break;
                case 0x0E: tcm->linePressure = val16 * 0.1; break;
                case 0x0F: tcm->tccPressure = val16 * 0.1; break;
                case 0x12: tcm->coolantTemp = static_cast<int8_t>(valByte); break;
                case 0x13: tcm->turboBoost = val16 * 0.01; break;
                case 0x14: tcm->mafSensor = val16; break;
                case 0x15: tcm->mapSensor = val16; break;
                case 0x20: tcm->batteryVoltage = valByte * 0.1; break;
                case 0x23: tcm->limpMode = (valByte != 0); break;
                case 0x30: tcm->maxGear = valByte; break;
                }
            }
            (*step)++;
            QTimer::singleShot(20, *doNext);
        });
    };
    (*doNext)();
}

// readSingleParam - compat: tek bir KWP local ID oku
void WJDiagnostics::readSingleParam(uint8_t localID, std::function<void(double)> cb)
{
    m_kwp->readLocalData(localID, [this, localID, cb](const QByteArray &data) {
        double val = 0;
        if (data.size() >= 4) {
            // Basit: ilk 2 data byte'i uint16 olarak oku
            uint16_t raw = (static_cast<uint8_t>(data[2]) << 8) | static_cast<uint8_t>(data[3]);
            // LiveParam tablosundan factor/offset bul
            for (const auto &p : m_liveParams) {
                if (p.localID == localID) {
                    val = raw * p.factor + p.offset;
                    break;
                }
            }
            if (val == 0) val = raw; // fallback
        }
        if (cb) cb(val);
    });
}

// fillTCMCompat - TCM status'a compat field'lari doldur
void WJDiagnostics::fillTCMCompat(TCMStatus &tcm)
{
    tcm.solenoidVoltage = tcm.solenoidSupply;
    tcm.linePressure = tcm.tccPressure;
    if (tcm.actualGear >= 0 && tcm.actualGear <= 7)
        tcm.currentGear = static_cast<Gear>(tcm.actualGear);
    tcm.limpMode = (tcm.maxGear <= 2 && tcm.transTemp > 130);
}

// readTCMInfo - compat: K-Line TCM bilgisi oku (0x10 header)
void WJDiagnostics::readTCMInfo(std::function<void(const QMap<QString,QString>&)> cb)
{
    auto r = std::make_shared<QMap<QString,QString>>();
    (*r)["Module"] = "NAG1 722.6 TCM";
    (*r)["Bus"] = "K-Line";

    auto n = std::make_shared<int>(3);
    auto chk = [r, n, cb]() { if (--(*n) <= 0 && cb) cb(*r); };

    m_kwp->readECUIdentification(0x91, [r, chk](const QByteArray &d) {
        if (d.size() > 2) {
            (*r)["PartNumber"] = QString::fromLatin1(d.mid(2)).trimmed();
            (*r)["HardwareVersion"] = (*r)["PartNumber"];
        }
        chk();
    });
    m_kwp->readECUIdentification(0x90, [r, chk](const QByteArray &d) {
        if (d.size() > 2) (*r)["VIN"] = QString::fromLatin1(d.mid(2)).trimmed();
        chk();
    });
    m_kwp->readECUIdentification(0x86, [r, chk](const QByteArray &d) {
        if (d.size() > 2) (*r)["SoftwareVersion"] = QString::fromLatin1(d.mid(2)).trimmed();
        chk();
    });
}

// initLiveDataParams - TCM canli veri parametre listesi (K-Line local ID'ler)
void WJDiagnostics::initLiveDataParams()
{
    m_liveParams = {
        {0x01, "Mevcut Vites",               "",      0,   7,   1.0,    0, 1, false},
        {0x02, "Hedef Vites",                 "",      0,   7,   1.0,    0, 1, false},
        {0x03, "Vites Kolu Pozisyonu",        "",      0,  15,   1.0,    0, 1, false},
        {0x04, "Turbin (Giris) RPM",          "rpm",   0, 8000, 1.0,    0, 2, false},
        {0x05, "Cikis Mili RPM",              "rpm",   0, 8000, 1.0,    0, 2, false},
        {0x06, "Motor RPM (TCM)",             "rpm",   0, 8000, 1.0,    0, 2, false},
        {0x07, "Arac Hizi",                   "km/h",  0, 300,  1.0,    0, 2, false},
        {0x08, "Sanziman Sicakligi",          "C",   -40, 200,  1.0,  -40, 1, true},
        {0x09, "Selenoid Besleme Gerilimi",   "V",     0,  20,  0.1,    0, 1, false},
        {0x0A, "TCC Kayma (Gercek)",          "rpm",   0, 2000, 1.0,    0, 2, true},
        {0x0B, "TCC Kayma (Hedef)",           "rpm",   0, 2000, 1.0,    0, 2, true},
        {0x0C, "1245 Selenoid (Gercek)",      "%",     0, 100,  0.39,   0, 1, false},
        {0x0D, "2-3 Selenoid (Gercek)",       "%",     0, 100,  0.39,   0, 1, false},
        {0x0E, "Hat Basinci",                 "bar",   0,  25,  0.1,    0, 2, false},
        {0x0F, "TCC Basinci",                 "bar",   0,  25,  0.1,    0, 2, false},
        {0x10, "Park Kilidi Selenoid",        "",      0,   1,  1.0,    0, 1, false},
        {0x11, "Fren Sivici",                 "",      0,   1,  1.0,    0, 1, false},
        {0x12, "Motor Sicakligi (TCM CAN)",   "C",   -40, 150,  1.0,  -40, 1, true},
        {0x13, "Turbo Basinci (TCM CAN)",     "bar",   0,   3,  0.01,   0, 2, false},
        {0x14, "MAF Sensoru (TCM CAN)",       "mg/s",  0, 1500, 1.0,    0, 2, false},
        {0x15, "MAP Sensoru (TCM CAN)",       "mbar",  0, 3000, 1.0,    0, 2, false},
        {0x16, "Aktor Tork Talebi",           "%",     0, 100,  0.39,   0, 1, false},
        {0x20, "Aku Voltaji",                 "V",     0,  20,  0.1,    0, 1, false},
        {0x21, "3-4 Selenoid (Gercek)",       "%",     0, 100,  0.39,   0, 1, false},
        {0x22, "Kickdown Sivici",             "",      0,   1,  1.0,    0, 1, false},
        {0x23, "Limp Mode",                   "",      0,   1,  1.0,    0, 1, false},
        {0x30, "Max Vites",                   "",      0,   7,  1.0,    0, 1, false},
    };
    emit logMessage(QString("Canli veri: %1 parametre yuklendi").arg(m_liveParams.size()));
}

// ioDefinitions - I/O kontrol tanimlari (NAG1 selenoidler)
QList<WJDiagnostics::IODefinition> WJDiagnostics::ioDefinitions() const
{
    return {
        {0x10, "Shift Solenoid 1-2/4-5", "Vites 1-2 / 4-5 selenoid"},
        {0x11, "Shift Solenoid 2-3",     "Vites 2-3 selenoid"},
        {0x12, "Shift Solenoid 3-4",     "Vites 3-4 selenoid"},
        {0x13, "TCC PWM Solenoid",       "Tork konvertor kilitleme"},
        {0x14, "Modulating Pressure",    "Modulasyon basinci selenoid"},
        {0x15, "Shift Pressure",         "Vites basinci selenoid"},
        {0x16, "Park Lockout Solenoid",  "Park kilidi selenoid"},
        {0x17, "Starter Interlock",      "Mars kilidi"},
        {0x18, "Reverse Light",          "Geri vites lambasi"},
    };
}

// readIOStates - I/O durumlarini oku (SID 0x30 / 0x22)
void WJDiagnostics::readIOStates(std::function<void(const QList<IOState>&)> cb)
{
    auto defs = ioDefinitions();
    auto states = std::make_shared<QList<IOState>>();
    auto idx = std::make_shared<int>(0);
    auto readNext = std::make_shared<std::function<void()>>();

    *readNext = [this, defs, states, idx, readNext, cb]() {
        if (*idx >= defs.size()) {
            if (cb) cb(*states);
            return;
        }
        uint8_t lid = defs[*idx].localID;
        m_kwp->readLocalData(lid, [states, idx, readNext, lid](const QByteArray &data) {
            IOState st;
            st.localID = lid;
            st.rawValue = (data.size() > 2) ? static_cast<uint8_t>(data[2]) : 0;
            st.isActive = (st.rawValue != 0);
            states->append(st);
            (*idx)++;
            QTimer::singleShot(30, *readNext);
        });
    };

    switchToModule(Module::TCM, [readNext](bool ok) {
        if (ok) (*readNext)();
    });
}
