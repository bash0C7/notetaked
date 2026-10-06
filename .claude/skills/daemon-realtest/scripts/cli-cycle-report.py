#!/usr/bin/env python3
"""cli-cycle.shの結果を読み、段階1の確認項目ごとに合否を出す。

usage: cli-cycle-report.py <cli-cycle.shの出力先directory>
"""
import bisect
import glob
import json
import os
import sys

SAMPLE_RATE = 16_000
UNRESPONSIVE = "capture-daemonが応答していません"


def records(path):
    result = []
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return result


def anchors(meta_path):
    return sorted((r["sample"], r["ms"]) for r in records(meta_path) if r.get("t") == "anchor")


def wall_ms(points, sample):
    index = max(bisect.bisect_right([s for s, _ in points], sample) - 1, 0)
    anchor_sample, anchor_ms = points[index]
    return anchor_ms + (sample - anchor_sample) * 1000 / SAMPLE_RATE


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    directory = sys.argv[1]
    steps = {}
    with open(f"{directory}/steps.log", encoding="utf-8") as lines:
        for line in lines:
            ms, name = line.split(" ", 1)
            steps[name.strip()] = int(ms)
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok), detail))

    timed = sorted(glob.glob(f"{directory}/out/*.timed.jsonl"))
    check("開始と区切りで収録が2つできた", len(timed) == 2, ", ".join(os.path.basename(p) for p in timed))
    if len(timed) == 2:
        first, second = (records(p) for p in timed)
        prefix2 = os.path.basename(timed[1]).removesuffix(".timed.jsonl")
        segs1 = [r for r in first if r.get("t") == "seg"]
        segs2 = [r for r in second if r.get("t") == "seg"]

        for key, segs in (("say1", segs1), ("say2", segs2), ("say3", segs2), ("say4", segs2)):
            candidates = [s for s in segs if s["start"] >= steps[key] - 500]
            seg = min(candidates, key=lambda s: s["start"]) if candidates else None
            delay = seg["start"] - steps[key] if seg else None
            check(
                f"{key}の発話が壁時計の時刻で記録された（話し始めから4秒以内）",
                seg is not None and -500 <= delay <= 4000,
                f"{delay}ms {seg['source']} {seg['text']}" if seg else "segが無い")

        check("収録中の発話に話者が付いていない", all("speaker" not in s for s in segs1 + segs2))

        before = [s for s in segs2 if s["received_at"] < steps["serve-killed"]]
        after = [s for s in segs2 if s["received_at"] > steps["serve-restarted"]]
        check(
            "serveの再起動後も同じ収録へseqを続けて書いた",
            before and after and min(s["seq"] for s in after) > max(s["seq"] for s in before),
            f"再起動の前{len(before)}件、後{len(after)}件")

        old_directory = json.load(open(f"{directory}/desired-recording.json"))["recording"]["directory"]
        new_directory = os.path.join(os.path.dirname(old_directory), prefix2)
        old_points = anchors(f"{old_directory}/mic.meta.jsonl")
        new_points = anchors(f"{new_directory}/mic.meta.jsonl")
        if old_points and new_points:
            old_end = wall_ms(old_points, os.path.getsize(f"{old_directory}/mic.pcm") // 4)
            gap = new_points[0][1] - old_end
            check("区切りの前後でmicの生音声の時刻が続いている（500ms以内）", abs(gap) <= 500, f"{gap:.0f}ms")
        else:
            check("区切りの前後でmicの生音声の時刻が続いている（500ms以内）", False, "anchorが無い")
        check(
            "capture-daemonの再起動の後、同じ収録へanchorを足して書き続けた",
            any(ms > steps["capture-killed"] for _, ms in new_points),
            f"anchor {len(new_points)}個")

    events = records(f"{directory}/events.log")
    statuses = [e for e in events if e.get("ev") == "status"]
    check(
        "収録中はsourceごとの取り込みの状態をstatusで伝えた",
        any(any(c.get("state") == "recording" for c in e.get("capture") or []) for e in statuses))
    check(
        "capture-daemonが止まった間は応答なしを伝えた",
        any(any(c.get("reason") == UNRESPONSIVE for c in e.get("capture") or []) for e in statuses))
    check("serveが収録を引き継いだ", any("resumed" in e.get("message", "") for e in events))

    desired = json.load(open(f"{directory}/desired-stopped.json"))
    check("停止で望む状態から収録が消えた", "recording" not in desired)
    actual = json.load(open(f"{directory}/actual-stopped.json"))
    check("停止でcapture-daemonが書くのをやめた", actual.get("prefix") is None and actual["sources"] == [])
    check("final.mdが2つ書かれた", len(glob.glob(f"{directory}/out/*.final.md")) == 2)
    with open(f"{directory}/state-dir.txt", encoding="utf-8") as listing:
        leftovers = [name for name in listing.read().split() if name.endswith(".tmp")]
    # serveとcapture-daemonをSIGKILLで止めるため、書き込みの最中に止まった一時ファイルは最大2つ残りうる
    check("状態ディレクトリに一時ファイルが溜まっていない（SIGKILLの2回分まで許す）", len(leftovers) <= 2, " ".join(leftovers))
    with open(f"{directory}/orphan.txt", encoding="utf-8") as orphan:
        check("起動したprocessが終わったcapture-daemonは自分で終えた", orphan.read().strip() == "exited")

    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
    sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
