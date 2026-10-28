@echo off
rem WJ Diag - Arac Veri Kaydedici baslatici
rem Bu dosyayi car_logger_gui.py ve wjpro_cmdseq.json ile AYNI klasorde tut.
cd /d "%~dp0"
title WJ Diag - Arac Veri Kaydedici

rem Once 'python', olmazsa 'py' dene
python --version >nul 2>&1
if %errorlevel%==0 (
    python "%~dp0car_logger_gui.py"
    goto end
)
py --version >nul 2>&1
if %errorlevel%==0 (
    py "%~dp0car_logger_gui.py"
    goto end
)

echo.
echo Python bulunamadi. python.org'dan Python 3 kur (kurarken "Add to PATH" isaretle).
echo.
pause

:end
