@echo off
setlocal

set "ROOT=%~dp0"
set "DIST=%ROOT%dist-server-linux"
set "ADMIN_DIST=%ROOT%dist-server-linux-admin"
set "PROJECT=%ROOT%FluxChat.Server\FluxChat.Server.csproj"
set "ADMIN_PROJECT=%ROOT%FluxChat.Admin\FluxChat.Admin.csproj"

echo Building FluxChat relay server for Ubuntu/Linux x64...

if exist "%DIST%" (
    rmdir /s /q "%DIST%"
)

if exist "%ADMIN_DIST%" (
    rmdir /s /q "%ADMIN_DIST%"
)

dotnet publish "%PROJECT%" ^
    -c Release ^
    -r linux-x64 ^
    --self-contained true ^
    -o "%DIST%" ^
    -p:PublishSingleFile=true ^
    -p:IncludeNativeLibrariesForSelfExtract=true ^
    -p:EnableCompressionInSingleFile=true ^
    -p:DebugType=None ^
    -p:DebugSymbols=false

if errorlevel 1 (
    echo.
    echo Publish failed.
    exit /b 1
)

dotnet publish "%ADMIN_PROJECT%" ^
    -c Release ^
    -r linux-x64 ^
    --self-contained true ^
    -o "%ADMIN_DIST%" ^
    -p:PublishSingleFile=true ^
    -p:IncludeNativeLibrariesForSelfExtract=true ^
    -p:EnableCompressionInSingleFile=true ^
    -p:DebugType=None ^
    -p:DebugSymbols=false

if errorlevel 1 (
    echo.
    echo Admin publish failed.
    exit /b 1
)

for %%F in ("%DIST%\*.pdb") do (
    if exist "%%~fF" del /q "%%~fF"
)

copy /y "%ADMIN_DIST%\fluxus" "%DIST%\fluxus" >nul
rmdir /s /q "%ADMIN_DIST%"

echo.
echo Done: %DIST%\FluxChat.Server
echo Done: %DIST%\fluxus
