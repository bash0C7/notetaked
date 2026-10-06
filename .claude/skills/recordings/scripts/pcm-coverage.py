#!/usr/bin/env python3
"""生音声ディレクトリの1つのsourceについて、壁時計の区間ごとに書かれた音声の秒数と最大音量を出す。

usage: pcm-coverage.py <生音声ディレクトリ> <mic|system> [区間の秒数（既定10）]
"""
import array
import bisect
import datetime
import json
import math
import sys

SAMPLE_RATE = 16_000
BLOCK = 1_600  # 100ms


def load_meta(path):
    anchors, states = [], []
    with open(path, encoding="utf-8") as meta:
        for line in meta:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("t") == "anchor":
                anchors.append((record["sample"], record["ms"]))
            elif record.get("t") == "state":
                states.append(record)
    anchors.sort()
    return anchors, states


def wall_ms(anchors, starts, sample):
    index = bisect.bisect_right(starts, sample) - 1
    anchor_sample, anchor_ms = anchors[max(index, 0)]
    return anchor_ms + (sample - anchor_sample) * 1000 / SAMPLE_RATE


def clock(ms):
    return datetime.datetime.fromtimestamp(ms / 1000).strftime("%H:%M:%S")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    directory, source = sys.argv[1], sys.argv[2]
    bucket_seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
    anchors, states = load_meta(f"{directory}/{source}.meta.jsonl")
    if not anchors:
        sys.exit("anchorがありません")
    starts = [sample for sample, _ in anchors]

    # 長い収録でもメモリに載せきらないよう、100msずつ読む
    buckets = {}
    offset = 0
    with open(f"{directory}/{source}.pcm", "rb") as pcm:
        while True:
            data = pcm.read(BLOCK * 4)
            if len(data) < 4:
                break
            block = array.array("f")
            block.frombytes(data[: len(data) // 4 * 4])
            rms = math.sqrt(sum(value * value for value in block) / len(block))
            dbfs = 20 * math.log10(rms) if rms > 0 else -120.0
            key = int(wall_ms(anchors, starts, offset) // (bucket_seconds * 1000))
            count, loudest = buckets.get(key, (0, -120.0))
            buckets[key] = (count + len(block), max(loudest, dbfs))
            offset += len(block)

    print(f"samples={offset} ({offset / SAMPLE_RATE:.1f}s) anchors={len(anchors)}")
    for record in states:
        print(f"state {clock(record['ms'])} sample={record['sample']} {record['state']} {record.get('reason') or ''}")
    for key in sorted(buckets):
        count, loudest = buckets[key]
        print(f"{clock(key * bucket_seconds * 1000)}  {count / SAMPLE_RATE:5.1f}s  max {loudest:7.1f} dBFS")


if __name__ == "__main__":
    main()
