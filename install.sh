#!/bin/bash
# ============================================================
#  Graiber - Installer for macOS
#  Creates a local venv, installs all packages and models.
#  Requirements: macOS 12+, Python 3.10+
#  Usage: bash install.sh
# ============================================================

INST="$(cd "$(dirname "$0")" && pwd)"
VENV="$INST/venv"
PYEXE="$VENV/bin/python"
PIP="$VENV/bin/pip"
LOG="$INST/install_log.txt"

date > "$LOG"
echo "Graiber macOS install started" >> "$LOG"
echo "Installer: $INST" >> "$LOG"

echo ""
echo "============================================================"
echo "  Graiber - Installer for macOS"
echo "  All packages will be installed into: installer/venv/"
echo "  Log: installer/install_log.txt"
echo "============================================================"
echo ""

# ── 1. Check Python ──────────────────────────────────────────
echo "[1/5] Checking Python 3.10+..."

PYBIN=""
for cmd in python3.12 python3.11 python3.10 python3; do
    if command -v "$cmd" &>/dev/null; then
        VER=$("$cmd" -c "import sys; print(sys.version_info.major * 100 + sys.version_info.minor)" 2>/dev/null || echo "0")
        if [ "$VER" -ge 310 ]; then
            PYBIN="$cmd"
            break
        fi
    fi
done

if [ -z "$PYBIN" ]; then
    echo ""
    echo "  [ERROR] Python 3.10+ not found."
    echo "  Install via Homebrew:  brew install python@3.12"
    echo "  Or download from:      https://www.python.org/downloads/"
    echo ""
    echo "[1] Python 3.10+ not found" >> "$LOG"
    exit 1
fi

PY_VER=$("$PYBIN" -c "import sys; v=sys.version_info; print(f'{v.major}.{v.minor}.{v.micro}')")
echo "  [OK] Python $PY_VER  ($PYBIN)"
echo "[1] Python $PY_VER at $PYBIN" >> "$LOG"

# ── Detect architecture ──────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    HW_LABEL="Apple Silicon (arm64) — MPS available"
    IS_ARM=1
else
    HW_LABEL="Intel Mac (x86_64) — CPU only"
    IS_ARM=0
fi
echo "  [OK] Architecture: $HW_LABEL"
echo "[hw] $HW_LABEL" >> "$LOG"

# ── Create venv ──────────────────────────────────────────────
if [ -f "$PYEXE" ]; then
    echo "  [OK] venv already exists, skipping creation."
    echo "[1] venv already present" >> "$LOG"
else
    echo "  [..] Creating virtual environment..."
    if "$PYBIN" -m venv "$VENV" 2>> "$LOG"; then
        echo "  [OK] venv created: $VENV"
        echo "[1] venv created" >> "$LOG"
    else
        echo "  [ERROR] Failed to create venv. See install_log.txt"
        echo "[1] venv creation FAILED" >> "$LOG"
        exit 1
    fi
fi

echo "  [..] Upgrading pip..."
"$PIP" install --upgrade pip --quiet 2>> "$LOG"
echo "  [OK] pip up to date."
echo "[1] pip ready" >> "$LOG"

# ── 2. PyTorch ───────────────────────────────────────────────
echo ""
echo "[2/5] Installing PyTorch..."

if [ "$IS_ARM" -eq 1 ]; then
    TORCH_LABEL="MPS (Apple Silicon)"
else
    TORCH_LABEL="CPU only (Intel Mac)"
fi
echo "  [..] Installing PyTorch ($TORCH_LABEL)..."
echo "[2] torch $TORCH_LABEL" >> "$LOG"

# Standard PyTorch wheel already includes MPS support on arm64 — no special index URL needed
if "$PIP" install torch torchvision torchaudio 2>> "$LOG"; then
    echo "  [OK] PyTorch ($TORCH_LABEL)"
    echo "[2] torch DONE" >> "$LOG"
else
    echo "  [ERROR] PyTorch installation failed. See install_log.txt"
    echo "[2] torch FAILED" >> "$LOG"
    exit 1
fi

# ── 3. Install packages ──────────────────────────────────────
echo ""
echo "[3/5] Installing packages..."
echo "      (errors are logged to install_log.txt)"
echo ""

pip_install() {
    local label="$1"
    local pkg="$2"
    echo "  --- [$label] $pkg ---"
    echo "[$label] $pkg" >> "$LOG"
    if "$PIP" install "$pkg" 2>> "$LOG"; then
        echo "  [OK] $pkg"
        echo "[$label] DONE" >> "$LOG"
    else
        echo "  [WARN] $pkg failed — see install_log.txt"
        echo "[$label] FAILED" >> "$LOG"
    fi
}

pip_install "3a" "openai-whisper"
pip_install "3b" "whisperx"
pip_install "3c" "flask"
pip_install "3d" "imageio-ffmpeg"

# audio-separator: retry with --no-build-isolation on failure
echo "  --- [3e] audio-separator ---"
echo "[3e] audio-separator" >> "$LOG"
if "$PIP" install audio-separator 2>> "$LOG"; then
    echo "  [OK] audio-separator"
    echo "[3e] DONE" >> "$LOG"
else
    echo "  [..] Retrying with --no-build-isolation..."
    echo "[3e] retry no-build-isolation" >> "$LOG"
    if "$PIP" install audio-separator --no-build-isolation 2>> "$LOG"; then
        echo "  [OK] audio-separator"
        echo "[3e] DONE (no-build-isolation)" >> "$LOG"
    else
        echo "  [WARN] audio-separator failed — vocal separation unavailable."
        echo "[3e] FAILED" >> "$LOG"
    fi
fi

echo ""
echo "  [OK] Packages done."
echo "[3] packages complete" >> "$LOG"

# ── 4. Download AI models ────────────────────────────────────
echo ""
echo "[4/5] Downloading AI models (Whisper medium + align ru/en + UVR stems)..."
echo ""
echo "[4] model download start" >> "$LOG"
"$PYEXE" "$INST/download_models.py" --auto 2>> "$LOG"
echo "[4] model download done" >> "$LOG"

# ── 5. Create run scripts ────────────────────────────────────
echo ""
echo "[5/5] Creating run scripts..."

cat > "$INST/run.sh" << 'RUNSH'
#!/bin/bash
INST="$(cd "$(dirname "$0")" && pwd)"
PYEXE="$INST/venv/bin/python"

if [ -z "${1:-}" ]; then
    echo ""
    echo " Usage:"
    echo "   bash run.sh \"song.mp3\""
    echo "   bash run.sh \"song.mp3\" -m large-v3"
    echo "   bash run.sh \"song.mp3\" -l ru"
    echo ""
    echo " Models: tiny, base, small, medium (default), large-v2, large-v3"
    echo " Languages: ru, en, uk, de, fr, es, ja, zh..."
    echo ""
    exit 0
fi

"$PYEXE" "$INST/transcribe.py" "$@"
RUNSH

cat > "$INST/run_web.sh" << 'WEBSH'
#!/bin/bash
INST="$(cd "$(dirname "$0")" && pwd)"
PYEXE="$INST/venv/bin/python"
echo "Starting Graiber web interface..."
echo "Open in browser: http://localhost:5000"
echo "Press Ctrl+C to stop."
echo ""
"$PYEXE" "$INST/app.py"
WEBSH

chmod +x "$INST/run.sh" "$INST/run_web.sh"
mkdir -p "$INST/uploads" "$INST/results" "$INST/stems"

echo "  [OK] run.sh, run_web.sh created."
echo "[5] run scripts created" >> "$LOG"

# ── Done ─────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Installation complete!"
echo "  Virtual env: $VENV"
echo "  Log:         $LOG"
echo ""
echo "  Web UI:  bash $INST/run_web.sh"
echo "           then open http://localhost:5000"
echo "  CLI:     bash $INST/run.sh \"song.mp3\""
echo "  Models:  $PYEXE $INST/download_models.py"
echo "============================================================"
echo ""
echo "[$(date)] Install finished" >> "$LOG"
