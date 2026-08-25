@echo off
REM ============================================================
REM  Build and run the JRPC example API demo
REM
REM  Usage:
REM    BuildExample.bat                 - build + run (Delphi 13 default)
REM    BuildDemo.bat 22.0|23.0|37.0  - pick the Studio version
REM
REM  Requirements:
REM    - RAD Studio with Delphi (default: Studio\37.0 = Delphi 13)
REM    - Neon checkout (https://github.com/paolo-rossi/delphi-neon).
REM      Point the NEON env var at it, or clone it as Libs\Neon inside
REM      this repository:
REM        git clone https://github.com/paolo-rossi/delphi-neon Libs\Neon
REM ============================================================
@echo off
setlocal

set "STUDIO_VERSION=%1"
if "%STUDIO_VERSION%"=="" set "STUDIO_VERSION=37.0"

set "BDS=C:\Program Files (x86)\Embarcadero\Studio\%STUDIO_VERSION%"
set "BDSINCLUDE=%BDS%\include"
set "BDSCOMMONDIR=C:\Users\Public\Documents\Embarcadero\Studio\%STUDIO_VERSION%"
set "FrameworkDir=C:\Windows\Microsoft.NET\Framework\v4.0.30319"
set "FrameworkVersion=v4.5"
set "FrameworkSDKDir="
set "PATH=%FrameworkDir%;%FrameworkSDKDir%;%BDS%\bin;%BDS%\bin64;%PATH%"
set "LANGDIR=EN"
set "PLATFORM="
set "PlatformSDK="

if not exist "%BDS%\bin\dcc32.exe" (
  echo [ERROR] Delphi %STUDIO_VERSION% not found at "%BDS%"
  exit /b 1
)

REM Neon is resolved from the NEON env var, or from a local Libs\Neon clone
if "%NEON%"=="" (
  if exist "%~dp0Libs\Neon\Source" (
    set "NEON=%~dp0Libs\Neon"
  ) else (
    echo [ERROR] Set the NEON env var to the delphi-neon checkout
    echo         or clone it into Libs\Neon, then retry.
    exit /b 1
  )
)

if not exist "%~dp0Libs\Logify\Source" (
  echo [ERROR] Logify not found in Libs\Logify
  echo         Clone it with: git clone https://github.com/delphi-blocks/Logify Libs\Logify
  exit /b 1
)

echo [BUILD] Delphi %STUDIO_VERSION% - Neon at "%NEON%"
cd /d "%~dp0Demo\JRPCExample"
msbuild JRPCExample.dproj /t:Make /p:config=Debug /p:platform=Win32
if %ERRORLEVEL% NEQ 0 (
  echo.
  echo =================================================
  echo ===     JRPCExample Failed to Compile          ===
  echo =================================================
  exit /b 1
)

echo.
echo [RUN] JRPCExample.exe
"..\Bin\JRPCExample.exe"
exit /b %ERRORLEVEL%
