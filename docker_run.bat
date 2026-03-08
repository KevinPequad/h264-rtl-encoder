@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
REM Remove trailing backslash for clean path handling
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
if "%IMAGE_NAME%"=="" set "IMAGE_NAME=h264-encoder"
if "%DOCKER_SCRIPT%"=="" set "DOCKER_SCRIPT=/workspace/docker/run_one_frame.sh"

echo Building Docker container...
docker build -t %IMAGE_NAME% "%SCRIPT_DIR%\docker"

echo Running encoder pipeline in Docker...
docker run --rm -it ^
    -v "%SCRIPT_DIR%:/workspace" ^
    %IMAGE_NAME% ^
    bash %DOCKER_SCRIPT%

endlocal
