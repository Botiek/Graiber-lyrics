@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  Graiber - Portable Installer
::  Downloads Python 3.12, installs all packages and models.
::  No system Python required.
:: ============================================================

:: All paths are anchored to this bat file - works from any location,
:: including folders with Cyrillic/Unicode names.
set "INST=%~dp0"
set "PYDIR=%~dp0python"
set "PYEXE=%~dp0python\python.exe"
set "LOG=%~dp0install_log.txt"

:: Portable Python version to download
set "PY_VER=3.12.8"
set "PY_ZIP=python-%PY_VER%-embed-amd64.zip"
set "PY_URL=https://www.python.org/ftp/python/%PY_VER%/%PY_ZIP%"
set "GETPIP_URL=https://bootstrap.pypa.io/get-pip.py"

echo. > "%LOG%"
echo [%DATE% %TIME%] Graiber portable install started >> "%LOG%"
echo Installer: %INST% >> "%LOG%"
echo Python:    %PYDIR% >> "%LOG%"

echo.
echo ============================================================
echo   Graiber - Portable Installer
echo   Python %PY_VER% will be downloaded into: installer\python\
echo   Log: installer\install_log.txt
echo ============================================================
echo.

:: ── 1. Download + setup portable Python ──────────────────────
echo [1/5] Setting up portable Python %PY_VER%...

if exist "%PYEXE%" (
    echo  [OK] Portable Python already exists, skipping download.
    echo [1] Python already present >> "%LOG%"
    goto :python_ready
)

:: Check internet via PowerShell (also confirms PS is available)
powershell -NoProfile -Command "exit 0" >nul 2>&1
if errorlevel 1 (
    echo  [ERROR] PowerShell not available. Cannot download Python.
    echo [1] PowerShell missing >> "%LOG%"
    pause
    exit /b 1
)

echo  [..] Downloading Python %PY_VER% embeddable (~12 MB)...
echo [1] Downloading %PY_URL% >> "%LOG%"
powershell -NoProfile -Command ^
    "Invoke-WebRequest -Uri '%PY_URL%' -OutFile '%INST%%PY_ZIP%' -UseBasicParsing" ^
    2>> "%LOG%"
if errorlevel 1 (
    echo  [ERROR] Failed to download Python. Check internet connection.
    echo  URL: %PY_URL%
    echo [1] Download FAILED >> "%LOG%"
    pause
    exit /b 1
)
echo  [OK] Downloaded.

echo  [..] Extracting...
powershell -NoProfile -Command ^
    "Expand-Archive -Path '%INST%%PY_ZIP%' -DestinationPath '%PYDIR%' -Force" ^
    2>> "%LOG%"
if errorlevel 1 (
    echo  [ERROR] Failed to extract Python zip.
    echo [1] Extract FAILED >> "%LOG%"
    pause
    exit /b 1
)
del "%INST%%PY_ZIP%"
echo  [OK] Extracted to: %PYDIR%

:: Enable site-packages: uncomment "import site" in the ._pth file.
:: Without this, pip-installed packages are invisible to Python.
echo  [..] Enabling site-packages...
powershell -NoProfile -Command ^
    "Get-ChildItem '%PYDIR%' -Filter '*._pth' | ForEach-Object { (Get-Content $_.FullName) -replace '#import site','import site' | Set-Content $_.FullName }" ^
    2>> "%LOG%"
echo  [OK] site-packages enabled.

:: Download and run get-pip.py
echo  [..] Installing pip...
echo [1] Downloading get-pip.py >> "%LOG%"
powershell -NoProfile -Command ^
    "Invoke-WebRequest -Uri '%GETPIP_URL%' -OutFile '%INST%get-pip.py' -UseBasicParsing" ^
    2>> "%LOG%"
if errorlevel 1 (
    echo  [ERROR] Failed to download get-pip.py.
    echo [1] get-pip.py download FAILED >> "%LOG%"
    pause
    exit /b 1
)
"%PYEXE%" "%INST%get-pip.py" --quiet
if errorlevel 1 (
    echo  [ERROR] pip installation failed.
    echo [1] pip install FAILED >> "%LOG%"
    pause
    exit /b 1
)
del "%INST%get-pip.py"
echo  [OK] pip installed.
echo [1] Python %PY_VER% + pip ready >> "%LOG%"

:python_ready
echo  [OK] Python ready: %PYEXE%

:: ── 2. Select CUDA version ───────────────────────────────────
echo.
echo [2/5] Select PyTorch build (check your CUDA version in nvidia-smi):
echo.

:: Show detected CUDA as hint (not binding)
set "HINT="
for /f %%c in ('powershell -NoProfile -Command ^
    "try { $s = nvidia-smi; $m = [regex]::Match($s,'CUDA Version:\s*(\d+\.\d+)'); if ($m.Success){$m.Groups[1].Value}else{''} } catch { '' }"') do set HINT=%%c
if not "!HINT!"=="" echo  Detected CUDA: !HINT!
echo.

echo    1) CPU only
echo    2) CUDA 11.8   (GTX 10xx / RTX 20xx)
echo    3) CUDA 12.1   (RTX 30xx)
echo    4) CUDA 12.4   (RTX 40xx)
echo    5) CUDA 12.8   (RTX 50xx / Blackwell)
echo.
set /p CUDA_CHOICE="  Enter 1-5: "

if "!CUDA_CHOICE!"=="2" (
    set "TORCH_URL=https://download.pytorch.org/whl/cu118"
    set "TORCH_LABEL=CUDA 11.8"
) else if "!CUDA_CHOICE!"=="3" (
    set "TORCH_URL=https://download.pytorch.org/whl/cu121"
    set "TORCH_LABEL=CUDA 12.1"
) else if "!CUDA_CHOICE!"=="4" (
    set "TORCH_URL=https://download.pytorch.org/whl/cu124"
    set "TORCH_LABEL=CUDA 12.4"
) else if "!CUDA_CHOICE!"=="5" (
    set "TORCH_URL=https://download.pytorch.org/whl/cu128"
    set "TORCH_LABEL=CUDA 12.8"
) else (
    set "TORCH_URL=https://download.pytorch.org/whl/cpu"
    set "TORCH_LABEL=CPU only"
)

echo  [OK] Selected: !TORCH_LABEL!
echo [2] Torch: !TORCH_LABEL! >> "%LOG%"

:: ── 3. Install Python packages ───────────────────────────────
echo.
echo [3/5] Installing packages into portable Python...
echo       (errors are logged to install_log.txt)
echo.

:: Shortcut for pip calls
set "PIP=%PYEXE% -m pip install"

:: 3a. PyTorch
echo --- [3a] PyTorch (!TORCH_LABEL!) ---
echo [3a] torch !TORCH_LABEL! >> "%LOG%"
%PIP% torch torchvision torchaudio --index-url "!TORCH_URL!" 2>> "%LOG%"
if errorlevel 1 (
    echo  [WARN] CUDA torch failed, retrying CPU...
    echo [3a] CUDA failed -> CPU >> "%LOG%"
    %PIP% torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/cpu" 2>> "%LOG%"
    if errorlevel 1 (
        echo  [ERROR] PyTorch could not be installed. See install_log.txt
        echo [3a] FAILED >> "%LOG%"
        pause
        exit /b 1
    )
    set "TORCH_URL=https://download.pytorch.org/whl/cpu"
    set "TORCH_LABEL=CPU only"
)
echo  [OK] PyTorch (!TORCH_LABEL!)
echo [3a] DONE >> "%LOG%"

:: 3b. openai-whisper
echo --- [3b] openai-whisper ---
echo [3b] openai-whisper >> "%LOG%"
%PIP% openai-whisper 2>> "%LOG%"
if errorlevel 1 ( echo  [WARN] openai-whisper failed & echo [3b] FAILED >> "%LOG%" ) else ( echo  [OK] openai-whisper & echo [3b] DONE >> "%LOG%" )

:: 3c. whisperx
echo --- [3c] whisperx ---
echo [3c] whisperx >> "%LOG%"
%PIP% whisperx 2>> "%LOG%"
if errorlevel 1 ( echo  [WARN] whisperx failed & echo [3c] FAILED >> "%LOG%" ) else ( echo  [OK] whisperx & echo [3c] DONE >> "%LOG%" )

:: 3d. Restore CUDA torch (whisperx may downgrade it)
if not "!TORCH_URL!"=="https://download.pytorch.org/whl/cpu" (
    echo --- [3d] Restoring CUDA torch ---
    echo [3d] restore CUDA torch >> "%LOG%"
    %PIP% torch torchvision torchaudio --index-url "!TORCH_URL!" --force-reinstall --no-deps 2>> "%LOG%"
    echo  [OK] torch !TORCH_LABEL! restored
    echo [3d] DONE >> "%LOG%"
)

:: 3e. flask
echo --- [3e] flask ---
echo [3e] flask >> "%LOG%"
%PIP% flask 2>> "%LOG%"
if errorlevel 1 ( echo  [WARN] flask failed & echo [3e] FAILED >> "%LOG%" ) else ( echo  [OK] flask & echo [3e] DONE >> "%LOG%" )

:: 3f. imageio-ffmpeg
echo --- [3f] imageio-ffmpeg ---
echo [3f] imageio-ffmpeg >> "%LOG%"
%PIP% imageio-ffmpeg 2>> "%LOG%"
if errorlevel 1 ( echo  [WARN] imageio-ffmpeg failed & echo [3f] FAILED >> "%LOG%" ) else ( echo  [OK] imageio-ffmpeg & echo [3f] DONE >> "%LOG%" )

:: 3g. audio-separator (try with --no-build-isolation as fallback for build errors)
echo --- [3g] audio-separator ---
echo [3g] audio-separator >> "%LOG%"
%PIP% audio-separator 2>> "%LOG%"
if errorlevel 1 (
    echo  [..] Retrying with --no-build-isolation...
    echo [3g] retry no-build-isolation >> "%LOG%"
    %PIP% audio-separator --no-build-isolation 2>> "%LOG%"
    if errorlevel 1 (
        echo  [WARN] audio-separator failed - vocal separation unavailable.
        echo [3g] FAILED >> "%LOG%"
    ) else (
        echo  [OK] audio-separator
        echo [3g] DONE (no-build-isolation) >> "%LOG%"
    )
) else (
    echo  [OK] audio-separator
    echo [3g] DONE >> "%LOG%"
)

echo.
echo  [OK] Packages done.
echo [3] packages complete >> "%LOG%"

:: ── 4. Download AI models ────────────────────────────────────
echo.
echo [4/5] Downloading AI models (Whisper medium + align ru/en + UVR stems)...
echo.
echo [4] model download start >> "%LOG%"
"%PYEXE%" "%INST%download_models.py" --auto 2>> "%LOG%"
echo [4] model download done >> "%LOG%"

:: ── 5. Create run.bat and run_web.bat inside installer\ ─────
echo.
echo [5/5] Creating run scripts...

:: run.bat - CLI transcription
(
    echo @echo off
    echo cd /d "%%~dp0"
    echo if "%%~1"=="" ^(
    echo   echo.
    echo   echo  Usage:
    echo   echo    run.bat "song.mp3"
    echo   echo    run.bat "song.mp3" -m large-v3
    echo   echo    run.bat "song.mp3" -l ru
    echo   echo.
    echo   echo  Models: tiny, base, small, medium ^(default^), large-v2, large-v3
    echo   echo  Languages: ru, en, uk, de, fr, es, ja, zh...
    echo   echo.
    echo   pause ^& exit /b 0
    echo ^)
    echo "%%~dp0python\python.exe" "%%~dp0transcribe.py" %%*
    echo echo.
    echo pause
) > "%INST%run.bat"

:: run_web.bat - web UI
(
    echo @echo off
    echo cd /d "%%~dp0"
    echo echo Starting Graiber web interface...
    echo echo Open in browser: http://localhost:5000
    echo echo Press Ctrl+C to stop.
    echo echo.
    echo "%%~dp0python\python.exe" "%%~dp0app.py"
    echo pause
) > "%INST%run_web.bat"

:: Also create required runtime directories
if not exist "%INST%uploads" mkdir "%INST%uploads"
if not exist "%INST%results" mkdir "%INST%results"
if not exist "%INST%stems"   mkdir "%INST%stems"

echo  [OK] run.bat, run_web.bat created.
echo [5] run scripts created >> "%LOG%"

:: ── Done ─────────────────────────────────────────────────────
echo.
echo ============================================================
echo   Installation complete!
echo   Portable Python: %PYDIR%
echo   Log:             %LOG%
echo.
echo   Web UI:      %INST%run_web.bat
echo   CLI:         %INST%run.bat "song.mp3"
echo   More models: "%PYEXE%" "%INST%download_models.py"
echo ============================================================
echo.
echo [%DATE% %TIME%] Install finished >> "%LOG%"
pause
