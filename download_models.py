"""
Graiber - Model Downloader

Usage:
  python download_models.py           # interactive menu
  python download_models.py --auto    # silent, downloads defaults
"""

import sys
import os
import argparse

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--auto", action="store_true",
                    help="Non-interactive: download default models without prompts")
args, _ = parser.parse_known_args()

AUTO = args.auto

# ── defaults used in --auto mode ─────────────────────────────────────────────
DEFAULT_WHISPER = ["medium"]
DEFAULT_LANGS   = ["ru", "en"]
DEFAULT_STEMS   = ["UVR-MDX-NET-Inst_HQ_3", "UVR-MDX-NET-Voc_FT"]

# ── helpers ───────────────────────────────────────────────────────────────────

def ok(msg):    print(f"  [OK]  {msg}", flush=True)
def err(msg):   print(f"  [ERR] {msg}", flush=True)
def info(msg):  print(f"  [..]  {msg}", flush=True)
def warn(msg):  print(f"  [!!]  {msg}", flush=True)

def section(title):
    print(flush=True)
    print("=" * 55, flush=True)
    print(f"  {title}", flush=True)
    print("=" * 55, flush=True)

def ask_menu(prompt, options, default):
    """Interactive menu. Returns list of chosen keys."""
    if AUTO:
        info(f"Auto-selecting: {default}")
        return default

    print(flush=True)
    print(prompt, flush=True)
    keys = list(options.keys())
    for i, k in enumerate(keys, 1):
        mark = " *" if k in default else ""
        print(f"  {i}) {k:35s} {options[k]}{mark}", flush=True)
    print("  0) Use defaults (marked *)", flush=True)
    raw = input("  Numbers separated by comma (or 0/Enter for defaults): ").strip()
    if not raw or raw == "0":
        return default
    chosen = []
    for part in raw.split(","):
        part = part.strip()
        if part.isdigit():
            idx = int(part) - 1
            if 0 <= idx < len(keys):
                chosen.append(keys[idx])
    return chosen if chosen else default


# ── header ────────────────────────────────────────────────────────────────────

print(flush=True)
print("====================================================", flush=True)
if AUTO:
    print("  Graiber - Downloading default models (auto)", flush=True)
else:
    print("  Graiber - Model Downloader (interactive)", flush=True)
print("====================================================", flush=True)

# ── detect device ─────────────────────────────────────────────────────────────

section("Detecting device")
try:
    import torch
    if torch.cuda.is_available():
        DEVICE = "cuda"
        info(f"GPU: {torch.cuda.get_device_name(0)} (CUDA {torch.version.cuda})")
    else:
        DEVICE = "cpu"
        info("No GPU - using CPU")
except ImportError:
    DEVICE = "cpu"
    warn("torch not installed - using CPU")

# ── 1. Whisper models ─────────────────────────────────────────────────────────

section("1/3  Whisper speech recognition models")

WHISPER_SIZES = {
    "tiny":     "~75 MB   fast, low quality",
    "base":     "~145 MB  fast",
    "small":    "~465 MB  good quality",
    "medium":   "~1.5 GB  recommended *",
    "large-v2": "~3 GB    high quality",
    "large-v3": "~3 GB    best quality",
}

chosen_whisper = ask_menu(
    "Which Whisper model sizes to download?",
    WHISPER_SIZES,
    DEFAULT_WHISPER,
)

if chosen_whisper:
    try:
        import whisper
        for name in chosen_whisper:
            info(f"Downloading whisper/{name} ...")
            try:
                whisper.load_model(name, device="cpu")
                ok(f"whisper/{name}")
            except Exception as e:
                err(f"whisper/{name}: {e}")
    except ImportError:
        err("openai-whisper not installed - run install.bat first")
else:
    info("Skipped.")

# ── 2. WhisperX alignment models ─────────────────────────────────────────────

section("2/3  WhisperX alignment models")

ALIGN_LANGS = {
    "ru": "Russian *",
    "en": "English *",
    "uk": "Ukrainian",
    "de": "German",
    "fr": "French",
    "es": "Spanish",
    "pl": "Polish",
    "zh": "Chinese",
    "ja": "Japanese",
    "ko": "Korean",
}

chosen_langs = ask_menu(
    "Which languages to download alignment models for?",
    ALIGN_LANGS,
    DEFAULT_LANGS,
)

if chosen_langs:
    try:
        import whisperx
        for lang in chosen_langs:
            info(f"Downloading align model for '{lang}' ...")
            try:
                model_a, metadata = whisperx.load_align_model(
                    language_code=lang, device="cpu"
                )
                ok(f"align/{lang}")
                del model_a
            except Exception as e:
                err(f"align/{lang}: {e}")
    except ImportError:
        err("whisperx not installed - run install.bat first")
else:
    info("Skipped.")

# ── 3. Audio separator UVR models ─────────────────────────────────────────────

section("3/3  Audio separator UVR models")

STEM_MODELS = {
    "UVR-MDX-NET-Inst_HQ_3": "Universal (recommended) *",
    "UVR-MDX-NET-Voc_FT":    "Vocal-optimized *",
    "Kim_Vocal_2":            "Kim Vocal 2",
}

chosen_stems = ask_menu(
    "Which UVR models to download?",
    STEM_MODELS,
    DEFAULT_STEMS,
)

if chosen_stems:
    try:
        import logging
        from audio_separator.separator import Separator

        stems_dir = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "stems"
        )
        os.makedirs(stems_dir, exist_ok=True)

        sep = Separator(output_dir=stems_dir, log_level=logging.WARNING)
        for model_name in chosen_stems:
            info(f"Downloading {model_name}.onnx ...")
            try:
                sep.load_model(f"{model_name}.onnx")
                ok(f"{model_name}.onnx")
            except Exception as e:
                err(f"{model_name}: {e}")
    except ImportError:
        err("audio-separator not installed - run install.bat first")
else:
    info("Skipped.")

# ── Done ──────────────────────────────────────────────────────────────────────

print(flush=True)
print("====================================================", flush=True)
print("  Model download complete.", flush=True)
print("  Web UI:  run_web.bat", flush=True)
print("  CLI:     run.bat \"song.mp3\"", flush=True)
print("====================================================", flush=True)
print(flush=True)
