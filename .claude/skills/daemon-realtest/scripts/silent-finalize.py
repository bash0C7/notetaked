# -*- coding: utf-8 -*-
"""音を出さずに確定処理を確かめる。say -oで書き出した2人分の音声から生音声ディレクトリを作る。

usage: silent-finalize.py <作業directory> <prefix>
作業directoryに out/（出力先）を作り、生音声はtmpのnotetake-captureへ置く。
"""
import json, os, subprocess, sys, tempfile, time, wave, array

work, prefix = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(work, "out"), exist_ok=True)
raw = os.path.join(tempfile.gettempdir(), "notetake-capture", prefix)
os.makedirs(raw)

def voice(name, text):
    aiff = os.path.join(work, name + ".aiff")
    wav = os.path.join(work, name + ".wav")
    subprocess.run(["say", "-v", name, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
    with wave.open(wav) as w:
        pcm = array.array("h")
        pcm.frombytes(w.readframes(w.getnframes()))
    return [s / 32768.0 for s in pcm]

gap = [0.0] * 16000
samples = []
for _ in range(2):
    samples += voice("Kyoko", "これは確認です。今日は晴れていて、会議を始めます。") + gap
    samples += voice("Otoya", "はい、了解しました。資料は先ほど共有しました。") + gap
with open(os.path.join(raw, "system.pcm"), "wb") as f:
    f.write(array.array("f", samples).tobytes())
start_ms = int(time.time() * 1000) - int(len(samples) / 16) - 5000
with open(os.path.join(raw, "system.meta.jsonl"), "w") as f:
    f.write(json.dumps({"ms": start_ms, "sample": 0, "state": "recording", "t": "state"}) + "\n")
    f.write(json.dumps({"ms": start_ms, "sample": 0, "t": "anchor"}) + "\n")
with open(os.path.join(raw, "session.json"), "w") as f:
    json.dump({"device": "silent-check", "device_name": "silent", "output_directory": os.path.join(work, "out"), "owner": "山田"}, f)
with open(os.path.join(work, "out", prefix + ".timed.jsonl"), "w") as f:
    f.write(json.dumps({"id": prefix, "owner": "山田", "started": start_ms, "t": "session"}, ensure_ascii=False) + "\n")
    f.write(json.dumps({"device": "silent-check", "device_name": "silent", "offset_ms": 0, "owner": "山田", "platform": "mac", "t": "device"}, ensure_ascii=False) + "\n")
print(raw, "%.1f秒" % (len(samples) / 16000))
