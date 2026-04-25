import os
import sys
import json
import uuid
import shutil
import queue
import logging
import threading
import warnings
from pathlib import Path

warnings.filterwarnings("ignore", category=UserWarning, module="whisper")
warnings.filterwarnings("ignore", category=UserWarning, module="torch")

from flask import Flask, render_template, request, jsonify, Response, send_file

# Auto-setup ffmpeg from imageio-ffmpeg bundle
try:
    import imageio_ffmpeg
    _ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
    _ffmpeg_dir = os.path.dirname(_ffmpeg_exe)
    # On Windows the binary has a versioned name — create plain ffmpeg alias
    if sys.platform == "win32":
        _ffmpeg_named = os.path.join(_ffmpeg_dir, "ffmpeg.exe")
        if not os.path.exists(_ffmpeg_named):
            shutil.copy2(_ffmpeg_exe, _ffmpeg_named)
    os.environ["PATH"] = _ffmpeg_dir + os.pathsep + os.environ.get("PATH", "")
    print(f"[OK] ffmpeg: {_ffmpeg_exe}")
except ImportError:
    print("[WARNING] imageio-ffmpeg not found")

# Detect device: CUDA (Windows/Linux) > MPS (Apple Silicon) > CPU
import torch
if torch.cuda.is_available():
    DEVICE = "cuda"
    COMPUTE_TYPE = "float16"
    print(f"[OK] GPU CUDA: {torch.cuda.get_device_name(0)}")
elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
    DEVICE = "mps"
    COMPUTE_TYPE = "float32"  # WhisperX/CTranslate2 doesn't support MPS, falls back to CPU
    print("[OK] GPU MPS (Apple Silicon)")
else:
    DEVICE = "cpu"
    COMPUTE_TYPE = "float32"
    print("[INFO] Running on CPU")

# Pre-import backends
try:
    import whisper as _whisper
    print("[OK] whisper imported")
except Exception as e:
    print(f"[ERROR] whisper: {e}")
    _whisper = None

try:
    import whisperx as _whisperx
    print("[OK] whisperx imported")
except Exception as e:
    print(f"[ERROR] whisperx: {e}")
    _whisperx = None

try:
    from audio_separator.separator import Separator as _Separator
    print("[OK] audio-separator imported")
    _HAS_SEPARATOR = True
except Exception as e:
    print(f"[WARNING] audio-separator: {e}")
    _HAS_SEPARATOR = False

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 500 * 1024 * 1024

UPLOAD_DIR = Path("uploads")
RESULT_DIR = Path("results")
STEMS_DIR  = Path("stems")
for d in (UPLOAD_DIR, RESULT_DIR, STEMS_DIR):
    d.mkdir(exist_ok=True)

jobs: dict = {}

STEM_MODELS = {
    "UVR-MDX-NET-Inst_HQ_3": "MDX-NET Inst HQ 3 (универсальный)",
    "UVR-MDX-NET-Voc_FT":    "MDX-NET Voc FT (оптимизирован для вокала)",
    "Kim_Vocal_2":            "Kim Vocal 2 (популярный)",
}


def seconds_to_lrc(seconds: float) -> str:
    m = int(seconds // 60)
    s = seconds % 60
    return f"[{m:02d}:{s:05.2f}]"


def separate_vocals(audio_path: Path, stem_model: str, emit) -> Path:
    emit("log", f"[Stems] Загрузка модели {stem_model} (CPU)...")

    sep = _Separator(
        output_dir=str(STEMS_DIR),
        output_format="WAV",
        log_level=logging.WARNING,
    )
    sep.load_model(f"{stem_model}.onnx")
    emit("log", "[Stems] Разделение вокала и инструментала...")
    files = sep.separate(str(audio_path))

    vocals_path = next(
        (STEMS_DIR / f for f in files if "Vocals" in f or "vocal" in f.lower()),
        None,
    )
    if vocals_path is None or not vocals_path.exists():
        raise RuntimeError(f"Vocals file not found. Got: {files}")

    emit("log", f"[Stems] Вокал выделен: {vocals_path.name}")
    return vocals_path


def run_whisper(job_id, audio_path, model_size, language, use_stems, stem_model):
    q = jobs[job_id]["queue"]
    stems_file = None

    def emit(t, msg):
        print(f"[{job_id[:8]}] {t}: {msg}")
        q.put({"type": t, "msg": msg})

    try:
        if use_stems and _HAS_SEPARATOR:
            stems_file = separate_vocals(audio_path, stem_model, emit)
            transcribe_path = stems_file
        else:
            transcribe_path = audio_path

        emit("log", f"[Whisper] Loading model '{model_size}' on {DEVICE}...")
        model = _whisper.load_model(model_size, device=DEVICE)
        emit("log", "Transcribing...")

        result = model.transcribe(
            str(transcribe_path),
            language=language or None,
            verbose=False,
            fp16=(DEVICE == "cuda"),
            word_timestamps=True,
        )

        emit("log", f"Language: {result.get('language', '?')}")
        lines = []
        for seg in result["segments"]:
            text = seg["text"].strip()
            if not text:
                continue
            # Use first word's actual timestamp instead of segment start.
            # Whisper often sets segment start=0.0 even when speech starts later.
            words = seg.get("words", [])
            start = words[0]["start"] if words else seg["start"]
            line = f"{seconds_to_lrc(start)} {text}"
            lines.append(line)
            emit("line", line)

        _finish(job_id, lines, emit)

    except Exception as exc:
        import traceback
        print(traceback.format_exc(), file=sys.stderr)
        jobs[job_id]["status"] = "error"
        emit("error", str(exc))
    finally:
        _cleanup(audio_path)
        if stems_file:
            _cleanup(stems_file)
            # also clean no_vocals sibling
            for f in STEMS_DIR.glob("*Instrumental*"):
                _cleanup(f)


def run_whisperx(job_id, audio_path, model_size, language, word_level, use_stems, stem_model):
    q = jobs[job_id]["queue"]
    stems_file = None

    def emit(t, msg):
        print(f"[{job_id[:8]}] {t}: {msg}")
        q.put({"type": t, "msg": msg})

    try:
        if use_stems and _HAS_SEPARATOR:
            stems_file = separate_vocals(audio_path, stem_model, emit)
            transcribe_path = stems_file
        else:
            transcribe_path = audio_path

        emit("log", f"[WhisperX] Loading model '{model_size}' on {DEVICE}...")
        model = _whisperx.load_model(
            model_size, DEVICE,
            compute_type=COMPUTE_TYPE,
            language=language or None,
        )

        emit("log", "Transcribing...")
        audio = _whisperx.load_audio(str(transcribe_path))
        batch = 16 if DEVICE == "cuda" else 4
        result = model.transcribe(audio, batch_size=batch, language=language or None)

        detected = result.get("language", language or "?")
        emit("log", f"Language: {detected}. Aligning word timestamps...")

        model_a, metadata = _whisperx.load_align_model(language_code=detected, device=DEVICE)
        result = _whisperx.align(
            result["segments"], model_a, metadata, audio, DEVICE,
            return_char_alignments=False,
        )

        emit("log", "Alignment done. Building LRC...")
        lines = []

        if word_level:
            for seg in result["segments"]:
                for w in seg.get("words", []):
                    word = w.get("word", "").strip()
                    start = w.get("start")
                    if word and start is not None:
                        line = f"{seconds_to_lrc(start)} {word}"
                        lines.append(line)
                        emit("line", line)
        else:
            for seg in result["segments"]:
                text = seg["text"].strip()
                if not text:
                    continue
                words = seg.get("words", [])
                start = words[0]["start"] if words and "start" in words[0] else seg["start"]
                line = f"{seconds_to_lrc(start)} {text}"
                lines.append(line)
                emit("line", line)

        _finish(job_id, lines, emit)

    except Exception as exc:
        import traceback
        print(traceback.format_exc(), file=sys.stderr)
        jobs[job_id]["status"] = "error"
        emit("error", str(exc))
    finally:
        _cleanup(audio_path)
        if stems_file:
            _cleanup(stems_file)
            for f in STEMS_DIR.glob("*Instrumental*"):
                _cleanup(f)


def _finish(job_id, lines, emit):
    lrc = "\n".join(lines)
    (RESULT_DIR / f"{job_id}.lrc").write_text(lrc, encoding="utf-8")
    jobs[job_id]["status"] = "done"
    jobs[job_id]["lrc"] = lrc
    emit("done", f"Done! {len(lines)} lines")


def _cleanup(path):
    try:
        Path(path).unlink()
    except OSError:
        pass


@app.route("/")
def index():
    return render_template("index.html",
                           device=DEVICE,
                           has_separator=_HAS_SEPARATOR,
                           stem_models=STEM_MODELS)


@app.route("/upload", methods=["POST"])
def upload():
    if "file" not in request.files or not request.files["file"].filename:
        return jsonify({"error": "No file"}), 400

    f = request.files["file"]
    model_size  = request.form.get("model", "medium")
    language    = request.form.get("language", "") or None
    backend     = request.form.get("backend", "whisper")
    word_level  = request.form.get("word_level") == "true"
    use_stems   = request.form.get("use_stems") == "true"
    stem_model  = request.form.get("stem_model", "UVR-MDX-NET-Inst_HQ_3")

    job_id = str(uuid.uuid4())
    ext = Path(f.filename).suffix.lower() or ".mp3"
    audio_path = UPLOAD_DIR / f"{job_id}{ext}"
    f.save(str(audio_path))
    print(f"[upload] {audio_path.name} ({audio_path.stat().st_size} B) "
          f"backend={backend} model={model_size} stems={use_stems}")

    jobs[job_id] = {"status": "running", "queue": queue.Queue(), "lrc": None}

    if backend == "whisperx" and _whisperx:
        target = run_whisperx
        args = (job_id, audio_path, model_size, language, word_level, use_stems, stem_model)
    else:
        target = run_whisper
        args = (job_id, audio_path, model_size, language, use_stems, stem_model)

    threading.Thread(target=target, args=args, daemon=True).start()
    return jsonify({"job_id": job_id})


@app.route("/progress/<job_id>")
def progress(job_id):
    if job_id not in jobs:
        return jsonify({"error": "Not found"}), 404

    def generate():
        q = jobs[job_id]["queue"]
        yield f"data: {json.dumps({'type': 'ping'})}\n\n"
        while True:
            try:
                msg = q.get(timeout=30)
                yield f"data: {json.dumps(msg, ensure_ascii=False)}\n\n"
                if msg["type"] in ("done", "error"):
                    break
            except queue.Empty:
                yield f"data: {json.dumps({'type': 'ping'})}\n\n"

    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache",
                             "X-Accel-Buffering": "no",
                             "Connection": "keep-alive"})


@app.route("/status/<job_id>")
def status(job_id):
    if job_id not in jobs:
        return jsonify({"error": "not found"}), 404
    return jsonify({"status": jobs[job_id]["status"], "lrc": jobs[job_id].get("lrc")})


@app.route("/download/<job_id>")
def download(job_id):
    p = RESULT_DIR / f"{job_id}.lrc"
    if not p.exists():
        return jsonify({"error": "Not found"}), 404
    return send_file(str(p.resolve()), as_attachment=True, download_name="lyrics.lrc")


if __name__ == "__main__":
    print(f"Open: http://localhost:5000  (device={DEVICE})")
    app.run(host="0.0.0.0", port=5000, threaded=True, debug=False)
