#!/usr/bin/env python3
"""finalize-check.shの結果を読み、確定処理の確認項目ごとに合否を出す。

usage: finalize-check-report.py <finalize-check.shの出力先directory> [basic|edit|crash|retry]
"""
import difflib
import glob
import json
import os
import re
import sys
import tempfile

KYOKO = [f"これは{i}番目の確認です。今日は晴れていて、会議を始めます。" for i in (1, 2, 3)]
OTOYA = ["はい、了解しました。資料は先ほど共有しました。"] * 3
LINE = re.compile(r"^\d\d:\d\d:\d\d \*\*(.+?)\*\*（(.*?)）: (.*)$")


def records(path):
    result = []
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return result


def ratio(a, b):
    return difflib.SequenceMatcher(None, a, b).ratio()


def majority(speakers):
    return max(set(speakers), key=speakers.count) if speakers else None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    directory = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "basic"
    out = f"{directory}/out"
    results = []

    def check(name, ok, detail=""):
        results.append((name, bool(ok), detail))

    timed_paths = sorted(glob.glob(f"{out}/*.timed.jsonl"))
    check("収録が1つできた", len(timed_paths) == 1, ", ".join(os.path.basename(p) for p in timed_paths))
    if len(timed_paths) != 1:
        report(results)
    timed_path = timed_paths[0]
    prefix = os.path.basename(timed_path).removesuffix(".timed.jsonl")
    timed = records(timed_path)

    finalized = [r for r in timed if r.get("t") == "finalized"]
    check("session_endがある", any(r.get("t") == "session_end" for r in timed))
    check(
        "run 1でsystemを含むfinalizedがある",
        any(r.get("run") == 1 and "system" in r.get("sources", []) for r in finalized),
        f"{len(finalized)}件")

    final_lines = []
    final_path = f"{directory}/snap0.final.md" if mode == "edit" else f"{out}/{prefix}.final.md"
    speakers_path = f"{directory}/snap0.speakers.json" if mode == "edit" else f"{out}/{prefix}.speakers.json"
    with open(final_path, encoding="utf-8") as lines:
        for line in lines:
            match = LINE.match(line.rstrip("\n"))
            if match:
                final_lines.append(match.groups())
    system_lines = [(speaker, text) for speaker, _, text in final_lines]
    labels = {speaker for speaker, _ in system_lines}
    check("final.mdに2種類以上の話者の表示がある", len(labels) >= 2, " ".join(sorted(labels)))

    def best(sentences, text):
        return max(ratio(sentence, text) for sentence in sentences)

    # 行ごとに、一致率の高い方の声の文へ対応付ける。どちらも0.5未満の行は数えない
    kyoko = [s for s, t in system_lines if best(KYOKO, t) >= 0.5 and best(KYOKO, t) > best(OTOYA, t)]
    otoya = [s for s, t in system_lines if best(OTOYA, t) >= 0.5 and best(OTOYA, t) >= best(KYOKO, t)]
    kyoko_major, otoya_major = majority(kyoko), majority(otoya)
    check(
        "Kyokoの行の8割以上が同じ話者",
        kyoko and kyoko.count(kyoko_major) / len(kyoko) >= 0.8,
        f"{kyoko_major} {kyoko.count(kyoko_major) if kyoko else 0}/{len(kyoko)}")
    check(
        "Otoyaの行の8割以上が同じ話者",
        otoya and otoya.count(otoya_major) / len(otoya) >= 0.8,
        f"{otoya_major} {otoya.count(otoya_major) if otoya else 0}/{len(otoya)}")
    check("2つの声の多数派の話者が違う", kyoko_major is not None and otoya_major is not None and kyoko_major != otoya_major,
          f"{kyoko_major} / {otoya_major}")

    with open(speakers_path, encoding="utf-8") as file:
        speakers = json.load(file)
    check("speakers.jsonのrunが1", speakers.get("run") == 1, str(speakers.get("run")))
    check("speakers.jsonの話者が2人以上", len(speakers.get("speakers", [])) >= 2, str(len(speakers.get("speakers", []))))
    check(
        "各centroidが256次元",
        all(len(s.get("centroid", [])) == 256 for s in speakers.get("speakers", [])) and speakers.get("speakers"))

    provisional = [r for r in timed if r.get("t") == "seg" and r.get("pass") != "final" and r.get("platform") == "mac"]
    live_path = f"{out}/{prefix}.live.txt"
    live_count = 0
    if os.path.exists(live_path):
        with open(live_path, encoding="utf-8") as live:
            live_count = sum(1 for _ in live)
    check("live.txtの行数が暫定版のmac発話の数と一致する", live_count == len(provisional), f"{live_count} / {len(provisional)}")

    events = records(f"{directory}/events.log")
    phases = [e["phase"] for e in events if e.get("ev") == "finalize_state" and e.get("prefix") == prefix]
    order = [p for i, p in enumerate(phases) if i == 0 or p != phases[i - 1]]
    if mode == "basic":
        check("finalize_stateがwaiting、running、finalizedの順に出た", order == ["waiting", "running", "finalized"], " ".join(order))
    check(
        "finalized eventに話者の一覧がある",
        any(e.get("ev") == "finalized" and e.get("prefix") == prefix and e.get("speakers") for e in events))

    raw = os.path.join(tempfile.gettempdir(), "notetake-capture", prefix)
    result_path = f"{raw}/finalize.json"
    result_run = None
    if os.path.exists(result_path):
        with open(result_path, encoding="utf-8") as file:
            result_run = json.load(file).get("run")
    expected_run = 2 if mode == "edit" else 1
    check(f"生音声ディレクトリのfinalize.jsonのrunが{expected_run}", result_run == expected_run, f"{result_path} run={result_run}")

    if mode == "edit":
        check_edit(check, directory, timed, events)
    elif mode == "crash":
        check_crash(check, directory, timed, events, prefix)
    elif mode == "retry":
        check_retry(check, directory, timed, events)

    leftovers = [name for name in os.listdir(out) if ".tmp" in name]
    with open(f"{directory}/state-dir.txt", encoding="utf-8") as listing:
        leftovers += [name for name in listing.read().split() if ".tmp" in name]
    check("出力先と状態ディレクトリに一時ファイルが残っていない", not leftovers, " ".join(leftovers))
    report(results)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as file:
            return file.read()
    except OSError:
        return ""


def labels_of(final_text):
    return {m.group(1) for m in (LINE.match(line) for line in final_text.splitlines()) if m}


def check_edit(check, directory, timed, events):
    renamed = [r for r in timed if r.get("t") == "speaker_name" and r.get("speaker") == "s1" and r.get("name") == "山田太郎"]
    check("改名でrun 1のspeaker_nameが足された", any(r.get("run") == 1 for r in renamed), f"{len(renamed)}件")
    after_rename = read_text(f"{directory}/snap-rename.final.md")
    check("改名の後のfinal.mdに「山田太郎」がある", "**山田太郎**" in after_rename)
    try:
        with open(f"{directory}/snap-rename.speakers.json", encoding="utf-8") as file:
            named = [s for s in json.load(file).get("speakers", []) if s.get("id") == "s1"]
    except (OSError, json.JSONDecodeError):
        named = []
    check("改名の後のspeakers.jsonのs1に名前が入った", named and named[0].get("name") == "山田太郎")

    finalized = [r for r in timed if r.get("t") == "finalized"]
    check("確定し直しでrun 2のfinalizedが足された", any(r.get("run") == 2 for r in finalized), f"{len(finalized)}件")
    after_refinalize = read_text(f"{directory}/snap-refinalize.final.md")
    check("確定し直しの後も「山田太郎」が引き継がれた", "**山田太郎**" in after_refinalize)
    carried = [e["message"] for e in events if e.get("ev") == "log" and "名前を引き継ぎました" in e.get("message", "")]
    check("名前の引き継ぎのlogがある（類似度を報告する）", carried, " / ".join(carried))

    check("まとめるでspeaker_mergeが足された", any(r.get("t") == "speaker_merge" for r in timed))
    after_merge = read_text(f"{directory}/snap-merge.final.md")
    check("まとめた後のfinal.mdの話者が1人", len(labels_of(after_merge)) == 1, " ".join(sorted(labels_of(after_merge))))
    try:
        with open(f"{directory}/snap-merge.speakers.json", encoding="utf-8") as file:
            remaining = len(json.load(file).get("speakers", []))
    except (OSError, json.JSONDecodeError):
        remaining = -1
    check("まとめた後のspeakers.jsonが1人", remaining == 1, str(remaining))


def check_crash(check, directory, timed, events, prefix):
    steps = read_text(f"{directory}/steps.log")
    check("確定中の子processを見つけて強制終了した", " killed" in steps and " restarted" in steps, "child-not-foundなら子processが見つからなかった" if "child-not-found" in steps else "")
    restart = int(read_text(f"{directory}/restart-line.txt").strip() or 0)
    after = records(f"{directory}/events.log")[restart:] if restart else []
    phases = [e.get("phase") for e in after if e.get("ev") == "finalize_state" and e.get("prefix") == prefix]
    check("起動し直したserveでwaitingが出た", "waiting" in phases, " ".join(phases))
    check("起動し直したserveでfinalizedになった", "finalized" in phases, " ".join(phases))
    runs = [r.get("run") for r in timed if r.get("t") == "finalized"]
    check("timed.jsonlのfinalizedがrun 1の1件だけ", runs == [1], str(runs))


def check_retry(check, directory, timed, events):
    failed = [e for e in events if e.get("ev") == "finalize_state" and e.get("phase") == "failed"]
    check("finalize_stateがfailedになり、retry_atが付いた", failed and failed[0].get("retry_at"), str(len(failed)))
    check("失敗の後のfinalize-attemptsが1", read_text(f"{directory}/attempts-after-failure.txt").strip() == "1",
          read_text(f"{directory}/attempts-after-failure.txt").strip())
    check("再試行でfinalizedになった", any(e.get("ev") == "finalize_state" and e.get("phase") == "finalized" for e in events))
    check("確定の後にfinalize-attemptsが消えた", "finalize-attempts" not in read_text(f"{directory}/raw-dir.txt"))
    check("timed.jsonlのfinalizedがrun 1の1件だけ", [r.get("run") for r in timed if r.get("t") == "finalized"] == [1])


def report(results):
    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
    sys.exit(0 if results and all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
