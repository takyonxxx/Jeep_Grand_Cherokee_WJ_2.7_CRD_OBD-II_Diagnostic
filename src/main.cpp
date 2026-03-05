#include <QApplication>
#include <QStyleFactory>
#include <QScreen>
#include "mainwindow.h"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    // Ocean coral theme
    app.setStyle(QStyleFactory::create("Fusion"));

    QPalette p;
    p.setColor(QPalette::Window,          QColor(18, 62, 98));    // koyu okyanus mavi
    p.setColor(QPalette::WindowText,      QColor(240, 245, 255)); // beyaz-mavi
    p.setColor(QPalette::Base,            QColor(14, 52, 82));    // daha koyu mavi
    p.setColor(QPalette::AlternateBase,   QColor(24, 75, 115));   // satir alternate
    p.setColor(QPalette::ToolTipBase,     QColor(48, 136, 184));
    p.setColor(QPalette::ToolTipText,     QColor(255, 255, 255));
    p.setColor(QPalette::Text,            QColor(230, 240, 255));
    p.setColor(QPalette::Button,          QColor(32, 100, 155));  // orta mavi butonlar
    p.setColor(QPalette::ButtonText,      QColor(255, 255, 255));
    p.setColor(QPalette::BrightText,      QColor(232, 84, 48));   // mercan turuncu
    p.setColor(QPalette::Link,            QColor(112, 200, 240)); // acik mavi
    p.setColor(QPalette::Highlight,       QColor(232, 84, 48));   // turuncu selection
    p.setColor(QPalette::HighlightedText, QColor(255, 255, 255));
    p.setColor(QPalette::Disabled, QPalette::WindowText, QColor(100, 130, 160));
    p.setColor(QPalette::Disabled, QPalette::Text,       QColor(100, 130, 160));
    p.setColor(QPalette::Disabled, QPalette::ButtonText, QColor(90, 120, 150));
    app.setPalette(p);

    app.setStyleSheet(
        // --- Global font scale for mobile ---
        "* { font-size: 13px; }"

        // --- Group boxes ---
        "QGroupBox { border: 1px solid #3088B8; border-radius: 6px; "
        "            margin-top: 12px; padding-top: 18px; "
        "            background: rgba(14,52,82,200); } "
        "QGroupBox::title { subcontrol-origin: margin; left: 12px; "
        "                    padding: 0 6px; color: #FFFFFF; "
        "                    font-weight: bold; font-size: 13px; } "

        // --- Buttons ---
        "QPushButton { padding: 8px 18px; border-radius: 5px; font-size: 13px; "
        "              background: qlineargradient(x1:0,y1:0,x2:0,y2:1, "
        "                stop:0 #28729C, stop:1 #1E5A82); "
        "              border: 1px solid #3088B8; color: #FFFFFF; } "
        "QPushButton:hover { background: qlineargradient(x1:0,y1:0,x2:0,y2:1, "
        "                    stop:0 #3090B8, stop:1 #2878A0); "
        "                    border-color: #70C8F0; } "
        "QPushButton:pressed { background: #E85430; border-color: #FF7040; color: #FFFFFF; } "
        "QPushButton:disabled { background: #1A3C58; color: #5A7A90; "
        "                       border-color: #204060; } "

        // --- Tables ---
        "QTableWidget { gridline-color: #2A6090; background: #0E3452; "
        "               font-size: 12px; } "
        "QHeaderView::section { background: #1E5A82; border: 1px solid #3088B8; "
        "                        padding: 6px; color: #70C8F0; "
        "                        font-weight: bold; font-size: 12px; } "

        // --- Combo boxes ---
        "QComboBox { padding: 6px 10px; border-radius: 4px; font-size: 13px; "
        "            background: #1A4A72; border: 1px solid #3088B8; "
        "            color: #E0F0FF; } "
        "QComboBox::drop-down { border: none; width: 24px; } "
        "QComboBox QAbstractItemView { background: #1A4A72; "
        "           selection-background-color: #E85430; color: #E0F0FF; } "

        // --- Progress bar ---
        "QProgressBar { border: 1px solid #3088B8; border-radius: 4px; "
        "               background: #0E3452; text-align: center; "
        "               color: #70C8F0; font-size: 12px; } "
        "QProgressBar::chunk { background: qlineargradient(x1:0,y1:0,x2:1,y2:0, "
        "                      stop:0 #E85430, stop:1 #FF8040); "
        "                      border-radius: 3px; } "

        // --- Scroll bars ---
        "QScrollBar:vertical { background: #0E3452; width: 6px; border: none; } "
        "QScrollBar::handle:vertical { background: #3088B8; border-radius: 3px; "
        "                              min-height: 30px; } "
        "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; } "

        // --- Text edits ---
        "QTextEdit, QPlainTextEdit { background: #0C2E4A; color: #B0D0E8; "
        "           border: 1px solid #2A6090; border-radius: 4px; "
        "           font-size: 12px; } "
        "QLineEdit { background: #143E62; color: #E0F0FF; "
        "            border: 1px solid #3088B8; border-radius: 4px; "
        "            padding: 6px; font-size: 13px; } "

        // --- Status bar ---
        "QStatusBar { background: #0A2840; color: #70C8F0; font-size: 12px; "
        "             border-top: 1px solid #3088B8; } "
        );

    MainWindow window;
    window.show();

    return app.exec();
}
