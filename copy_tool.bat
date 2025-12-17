@echo off
setlocal

:: Wrapper for BatchCopier.ps1
:: Usage: copy_tool.bat input.csv [options]

set SCRIPT_DIR=%~dp0
set PS_SCRIPT="%SCRIPT_DIR%BatchCopier.ps1"

if "%~1"=="/?" (
    echo Usage: copy_tool.bat [inputfile.csv] [options]
    echo.
    echo Options:
    echo   -dryrun    : Preview changes
    echo   -undo      : Delete copied files from last run
    echo.
    echo CSV Format:
    echo   Col 1: Source Full Path
    echo   Col 2: Destination Folder
    echo   Col 3: ^(Optional^) New Filename
    exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File %PS_SCRIPT% %*

if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Script execution failed.
    pause
)
