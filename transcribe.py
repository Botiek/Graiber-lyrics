import sys
import os
import argparse
from pathlib import Path


def seconds_to_lrc(seconds: float) -> str:
    m = int(seconds // 60)
    s = seconds % 60
    return f"[{m:02d}:{s:05.2f}]"


def transcribe(audio_path: str, model_size: str, language: str | None, output: str | None):
    import whisper

    print(f"Загрузка модели '{model_size}'...")
    model = whisper.load_model(model_size)

    print(f"Транскрибирование: {audio_path}")
    result = model.transcribe(
        audio_path,
        language=language,
        verbose=False,
        word_timestamps=False,
    )

    lines = []
    for seg in result["segments"]:
        text = seg["text"].strip()
        if text:
            lines.append(f"{seconds_to_lrc(seg['start'])} {text}")

    lrc_content = "\n".join(lines)

    if output:
        out_path = output
    else:
        out_path = str(Path(audio_path).with_suffix(".lrc"))

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(lrc_content)

    print(f"\nГотово! LRC сохранён: {out_path}")
    print(f"Строк: {len(lines)}")
    print(f"Язык: {result.get('language', 'неизвестен')}")
    return lrc_content


def main():
    parser = argparse.ArgumentParser(
        description="Грайбер текста песни с таймингом (Whisper → LRC)"
    )
    parser.add_argument("audio", help="Путь к аудио файлу (mp3, wav, flac, m4a, ...)")
    parser.add_argument(
        "-m", "--model",
        default="medium",
        choices=["tiny", "base", "small", "medium", "large", "large-v2", "large-v3"],
        help="Размер модели Whisper (по умолчанию: medium)",
    )
    parser.add_argument(
        "-l", "--language",
        default=None,
        help="Язык (ru, en, uk, ... — авто-определение если не указан)",
    )
    parser.add_argument(
        "-o", "--output",
        default=None,
        help="Путь для сохранения .lrc (по умолчанию: рядом с аудио)",
    )
    parser.add_argument(
        "--print",
        action="store_true",
        help="Вывести LRC в консоль",
    )

    args = parser.parse_args()

    if not os.path.isfile(args.audio):
        print(f"Ошибка: файл не найден: {args.audio}", file=sys.stderr)
        sys.exit(1)

    lrc = transcribe(args.audio, args.model, args.language, args.output)

    if args.print:
        print("\n--- LRC ---")
        print(lrc)


if __name__ == "__main__":
    main()
