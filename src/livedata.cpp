#include "livedata.h"
#include <QFile>
#include <QTextStream>
#include <QDateTime>
#include <QDebug>

LiveDataManager::LiveDataManager(TCMDiagnostics *tcm, QObject *parent)
    : QObject(parent), m_tcm(tcm)
{
    m_pollTimer = new QTimer(this);
    connect(m_pollTimer, &QTimer::timeout,
            this, &LiveDataManager::onPollTimer);
}

void LiveDataManager::startPolling(int intervalMs)
{
    if (m_polling) return;

    m_polling = true;
    m_elapsed.start();
    m_pollTimer->start(intervalMs);
}

void LiveDataManager::stopPolling()
{
    m_polling = false;
    m_pollTimer->stop();
    m_fuelLhSum = 0; m_fuelLhN = 0;
    m_fuelLkmSum = 0; m_fuelLkmN = 0;
    stopLogging();
}

void LiveDataManager::setSelectedParams(const QList<uint8_t> &localIDs)
{
    m_selectedParams = localIDs;
}

void LiveDataManager::startLogging(const QString &filePath)
{
    if (m_logging) stopLogging();

    m_logFile = new QFile(filePath, this);
    if (!m_logFile->open(QIODevice::WriteOnly | QIODevice::Text)) {
        delete m_logFile;
        m_logFile = nullptr;
        return;
    }

    m_logStream = new QTextStream(m_logFile);

    // CSV baslik: TCM parametreleri + ECU parametreleri
    *m_logStream << "Timestamp(ms),DateTime";
    for (const auto &param : m_tcm->liveDataParams()) {
        if (m_selectedParams.isEmpty() || m_selectedParams.contains(param.localID)) {
            *m_logStream << "," << param.name << "(" << param.unit << ")";
        }
    }
    // ECU bloklari aktifse ECU sutunlari ekle
    if (m_mode == ECU_ONLY || m_mode == DUAL) {
        *m_logStream << ",ECU_RPM,ECU_Coolant(C),ECU_IAT(C),ECU_TPS(%)"
                     << ",ECU_Boost(mbar),ECU_BoostSet(mbar)"
                     << ",ECU_InjQty(mg),ECU_BattV(V)"
                     << ",ECU_MAF_Act,ECU_MAF_Spec"
                     << ",ECU_RailAct(bar),ECU_RailSpec(bar)";
    }
    *m_logStream << "\n";
    m_logStream->flush();

    m_logging = true;
}

void LiveDataManager::stopLogging()
{
    if (!m_logging) return;

    m_logging = false;
    if (m_logStream) {
        m_logStream->flush();
        delete m_logStream;
        m_logStream = nullptr;
    }
    if (m_logFile) {
        m_logFile->close();
        delete m_logFile;
        m_logFile = nullptr;
    }
}

// === Ana polling dispatcher ===

void LiveDataManager::onPollTimer()
{
    if (!m_polling || m_readPending) return;
    m_readPending = true;

    auto pollDone = [this]() {
        m_readPending = false;
        // Chain: immediately start next read (10ms for event loop)
        if (m_polling)
            QTimer::singleShot(10, this, &LiveDataManager::onPollTimer);
    };

    switch (m_mode) {
    case TCM_ONLY:
        pollTCM(pollDone);
        break;
    case ECU_ONLY:
        pollECU(pollDone);
        break;
    case DUAL:
        pollTCM([this, pollDone]() {
            pollECU(pollDone);
        });
        break;
    }
}

// === TCM Polling (K-Line 0x20, block 0x30) ===

void LiveDataManager::pollTCM(std::function<void()> then)
{
    m_tcm->readAllLiveData([this, then](const TCMDiagnostics::TCMStatus &status) {
        emit fullStatusUpdated(status);

        // Merge TCM values into map
        QMap<uint8_t, double> vals;
        vals[0x01] = status.actualGear;
        vals[0x10] = status.turbineRpm;
        vals[0x13] = status.outputRPM;
        vals[0x14] = status.transTemp;
        vals[0x15] = status.linePressure;
        vals[0x16] = status.solenoidSupply;
        vals[0x18] = status.actualTccSlip;
        vals[0x19] = status.desTccSlip;
        vals[0x20] = status.vehicleSpeed;
        vals[0x21] = status.frontVehicleSpd;
        vals[0x22] = status.rearVehicleSpd;
        vals[0x23] = status.shiftPsi;
        vals[0x24] = status.modulationPsi;
        vals[0x2B] = status.tcmBattery;
        vals[0x2C] = status.sensorSupply;
        vals[0x2D] = status.lfWheelSpd;
        vals[0x2E] = status.rfWheelSpd;
        vals[0x2F] = status.lrWheelSpd;
        vals[0x30] = status.rrWheelSpd;
        vals[0x31] = status.tccPressure;
        vals[0x32] = status.tcmTpsPercent;
        vals[0x33] = status.uphillGrad;
        for (auto it = vals.begin(); it != vals.end(); ++it)
            m_lastValues[it.key()] = it.value();
        emit dataUpdated(m_lastValues);

        logCurrentValues();
        if (then) then();
    });
}

// === ECU Polling (K-Line) ===

void LiveDataManager::pollECU(std::function<void()> then)
{
    m_tcm->readECULiveData([this, then](const TCMDiagnostics::ECUStatus &ecu) {
        m_lastECU = ecu;
        emit ecuDataUpdated(ecu);

        // ECU verilerini virtual ID'lerle dataUpdated signal'ina ekle
        QMap<uint8_t, double> ecuValues;
        ecuValues[0xF0] = ecu.rpm;
        ecuValues[0xF1] = ecu.coolantTemp;
        ecuValues[0xF2] = ecu.iat;
        ecuValues[0xF3] = ecu.tps;
        ecuValues[0xF4] = ecu.boostPressure;
        ecuValues[0xF5] = ecu.mafActual;
        ecuValues[0xF6] = ecu.railActual;
        ecuValues[0xF7] = ecu.injectionQty;
        ecuValues[0xF8] = ecu.batteryVoltage;
        ecuValues[0xE0] = ecu.lowIdleSetpoint;
        ecuValues[0xE1] = ecu.pedalPos1;
        ecuValues[0xE2] = ecu.pedalPos2;
        ecuValues[0xE3] = ecu.pedalV1;
        ecuValues[0xE4] = ecu.pedalV2;
        ecuValues[0xE5] = ecu.boostVoltage;
        ecuValues[0xE6] = ecu.boostSetpoint;
        ecuValues[0xE7] = ecu.fuelLevel;
        ecuValues[0xE8] = ecu.fuelLevelV;
        ecuValues[0xE9] = ecu.fuelRegOutput;
        ecuValues[0xEA] = ecu.fuelPressureV;
        ecuValues[0xEB] = ecu.fuelPressureSet;
        ecuValues[0xEC] = ecu.fuelQtyPedal;
        ecuValues[0xED] = ecu.fuelQtyCruise;
        ecuValues[0xEE] = ecu.fuelDemand;
        ecuValues[0xEF] = ecu.fuelDriver;
        ecuValues[0xD0] = ecu.fuelActual;
        ecuValues[0xD1] = ecu.fuelStartSet;
        ecuValues[0xD2] = ecu.fuelLimit;
        ecuValues[0xD3] = ecu.fuelTorque;
        ecuValues[0xD4] = ecu.fuelIdleGov;
        ecuValues[0xD5] = ecu.batteryTemp;
        ecuValues[0xD6] = ecu.batteryTempV;
        ecuValues[0xD7] = ecu.alternatorField;
        ecuValues[0xD8] = ecu.alternatorDuty;
        ecuValues[0xD9] = ecu.oilPressure;
        ecuValues[0xDA] = ecu.oilPressureV;
        ecuValues[0xDB] = ecu.coolantSensorV;
        ecuValues[0xDC] = ecu.iatSensorV;
        ecuValues[0xDD] = ecu.outsideAirTemp;
        ecuValues[0xDE] = ecu.mafVoltage;
        ecuValues[0xDF] = ecu.baroPressure;
        ecuValues[0xC0] = ecu.baroPressureV;
        ecuValues[0xC1] = ecu.acPressure;
        ecuValues[0xC2] = ecu.acPressureV;
        ecuValues[0xC3] = ecu.vehicleSpeed;
        ecuValues[0xC4] = ecu.vehicleSpeedSet;
        ecuValues[0xC5] = ecu.cruiseSwitchV;
        ecuValues[0xC6] = ecu.mafEgrSetpoint;
        ecuValues[0xC7] = ecu.wastegate;
        ecuValues[0xC8] = ecu.transferCaseV;
        ecuValues[0xC9] = ecu.camCrankSync;
        ecuValues[0xCA] = ecu.injBankCap;
        ecuValues[0xCB] = ecu.railSpec;
        ecuValues[0xCC] = ecu.mafSpec;
        // Fuel: we calculate from rpm*injQty, so average to smooth out
        m_fuelLhSum += ecu.fuelFlowLH; m_fuelLhN++;
        if (ecu.vehicleSpeed > 5.0 && ecu.fuelLPer100km > 0) {
            m_fuelLkmSum += ecu.fuelLPer100km; m_fuelLkmN++;
        }
        double avgLh = m_fuelLhSum / m_fuelLhN;
        double avgLkm = (m_fuelLkmN > 0) ? m_fuelLkmSum / m_fuelLkmN : 0;
        ecuValues[0xCD] = (ecu.vehicleSpeed > 5.0) ? avgLkm : avgLh;
        // Merge with existing TCM values
        for (auto it = ecuValues.begin(); it != ecuValues.end(); ++it)
            m_lastValues[it.key()] = it.value();
        emit dataUpdated(m_lastValues);

        // DUAL modda: KLineTCM'e geri don
        if (m_mode == DUAL) {
            m_tcm->switchToModule(TCMDiagnostics::Module::KLineTCM, [then](bool) {
                if (then) then();
            });
        } else {
            if (then) then();
        }
    });
}

// === Loglama ===

void LiveDataManager::logCurrentValues()
{
    if (!m_logging || !m_logStream) return;

    qint64 ts = m_elapsed.elapsed();
    *m_logStream << ts << ","
                 << QDateTime::currentDateTime().toString(Qt::ISODate);

    // TCM parametreleri
    for (const auto &param : m_tcm->liveDataParams()) {
        if (m_selectedParams.isEmpty() || m_selectedParams.contains(param.localID)) {
            *m_logStream << "," << m_lastValues.value(param.localID, 0);
        }
    }

    // ECU verileri
    if (m_mode == ECU_ONLY || m_mode == DUAL) {
        *m_logStream << "," << m_lastECU.rpm
                     << "," << m_lastECU.coolantTemp
                     << "," << m_lastECU.iat
                     << "," << m_lastECU.tps
                     << "," << m_lastECU.boostPressure
                     << "," << m_lastECU.boostSetpoint
                     << "," << m_lastECU.injectionQty
                     << "," << m_lastECU.batteryVoltage
                     << "," << m_lastECU.mafActual
                     << "," << m_lastECU.mafSpec
                     << "," << m_lastECU.railActual
                     << "," << m_lastECU.railSpec;
    }

    *m_logStream << "\n";
    m_logStream->flush();
}
