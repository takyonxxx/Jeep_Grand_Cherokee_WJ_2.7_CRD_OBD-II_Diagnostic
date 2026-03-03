#pragma once

#include <QMainWindow>
#include <QTabWidget>
#include <QTableWidget>
#include <QTextEdit>
#include <QLineEdit>
#include <QSpinBox>
#include <QPushButton>
#include <QLabel>
#include <QGroupBox>
#include <QStatusBar>
#include <QProgressBar>
#include <QFrame>

#include "elm327connection.h"
#include "kwp2000handler.h"
#include "tcmdiagnostics.h"
#include "livedata.h"

class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow();

private slots:
    void onConnect();
    void onDisconnect();
    void onConnectionStateChanged(ELM327Connection::ConnectionState state);

    void onStartSession();
    void onReadDTCs();
    void onClearDTCs();

    void onStartLiveData();
    void onStopLiveData();
    void onLiveDataUpdated(const QMap<uint8_t, double> &values);
    void onFullStatusUpdated(const TCMDiagnostics::TCMStatus &status);

    void onReadIO();
    void onReadTCMInfo();

    void onLogMessage(const QString &msg);

private:
    void setupUI();
    QWidget* createDashboardPanel();
    QFrame* createGaugeCard(const QString &title, const QString &initValue,
                            const QString &unit, QLabel **valueLabel, QLabel **unitLabel);
    QWidget* createConnectionTab();
    QWidget* createDTCTab();
    QWidget* createLiveDataTab();
    QWidget* createIOTab();
    QWidget* createLogTab();

    void updateDashboardFromLiveData(const QMap<uint8_t, double> &values);
    void updateStatusLabels(const TCMDiagnostics::TCMStatus &status);
    void setGaugeColor(QLabel *valueLabel, const QString &color);
    QString gearToString(TCMDiagnostics::Gear gear);

#ifdef Q_OS_ANDROID
    void keepScreenOn(bool on);
#endif

    // Core objects
    ELM327Connection *m_elm;
    TCMDiagnostics   *m_tcm;
    LiveDataManager  *m_liveData;

    // UI elements
    QTabWidget   *m_tabs;

    // Connection tab
    QLineEdit    *m_hostEdit;
    QSpinBox     *m_portSpin;
    QPushButton  *m_connectBtn;
    QPushButton  *m_disconnectBtn;
    QPushButton  *m_startSessionBtn;
    QLabel       *m_connStatusLabel;
    QLabel       *m_elmVersionLabel;
    QLabel       *m_batteryVoltLabel;

    // TCM Info
    QLabel       *m_tcmPartLabel;
    QLabel       *m_tcmSwLabel;
    QLabel       *m_tcmHwLabel;

    // DTC tab
    QTableWidget *m_dtcTable;
    QPushButton  *m_readDtcBtn;
    QPushButton  *m_clearDtcBtn;
    QLabel       *m_dtcCountLabel;

    // Live Data tab
    QTableWidget *m_liveTable;
    QPushButton  *m_startLiveBtn;
    QPushButton  *m_stopLiveBtn;
    QPushButton  *m_logBtn;

    // Dashboard gauge value+unit labels
    QLabel       *m_dashGearVal;       QLabel *m_dashGearUnit;
    QLabel       *m_dashRpmVal;        QLabel *m_dashRpmUnit;
    QLabel       *m_dashSpeedVal;      QLabel *m_dashSpeedUnit;
    QLabel       *m_dashTempVal;       QLabel *m_dashTempUnit;
    QLabel       *m_dashSolVoltVal;    QLabel *m_dashSolVoltUnit;
    QLabel       *m_dashBatVoltVal;    QLabel *m_dashBatVoltUnit;
    QLabel       *m_dashThrottleVal;   QLabel *m_dashThrottleUnit;
    QLabel       *m_dashLimpVal;       QLabel *m_dashLimpUnit;

    // Compat aliases
    QLabel       *m_gearLabel;
    QLabel       *m_rpmLabel;
    QLabel       *m_tempLabel;
    QLabel       *m_solVoltLabel;
    QLabel       *m_limpLabel;
    QProgressBar *m_throttleBar;

    // I/O tab
    QTableWidget *m_ioTable;
    QPushButton  *m_readIOBtn;

    // Log tab
    QTextEdit    *m_logText;
};
