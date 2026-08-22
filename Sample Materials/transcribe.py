import whisper
m = whisper.load_model("small")
r = m.transcribe(r"D:\AI\Pen\Sample Materials\20260804_130825.mp4", language="en", verbose=False)
out = r"D:\AI\Pen\Sample Materials\transcript.txt"
with open(out, "w", encoding="utf-8") as f:
    f.write(r["text"].strip() + "\n\n---SEGMENTS---\n")
    for s in r.get("segments", []):
        f.write(f"[{s['start']:.1f}-{s['end']:.1f}] {s['text'].strip()}\n")
print("wrote", out)
print("chars", len(r["text"]))
