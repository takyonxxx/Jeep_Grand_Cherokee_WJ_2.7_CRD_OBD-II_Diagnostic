QT += core network widgets
CONFIG += c++17
TARGET = JeepWJDiag
TEMPLATE = app

INCLUDEPATH += include

HEADERS += \
    include/elm327connection.h \
    include/kwp2000handler.h \
    include/tcmdiagnostics.h \
    include/mainwindow.h \
    include/livedata.h

SOURCES += \
    src/main.cpp \
    src/elm327connection.cpp \
    src/kwp2000handler.cpp \
    src/tcmdiagnostics.cpp \
    src/mainwindow.cpp \
    src/livedata.cpp

# --- Android ---
android {
    ANDROID_PACKAGE_SOURCE_DIR = $$PWD/android
    ANDROID_MIN_SDK_VERSION = 24
    ANDROID_TARGET_SDK_VERSION = 34
}
