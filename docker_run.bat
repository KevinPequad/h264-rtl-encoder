@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
REM Remove trailing backslash for clean path handling
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

echo Building Docker container...
docker build -t h264-encoder "%SCRIPT_DIR%\docker"

echo Running encoder pipeline in Docker...
docker run --rm -it ^
    -v "%SCRIPT_DIR%:/workspace" ^
    h264-encoder ^
    bash /workspace/run.sh

endlocal
