# Follow-up Device Verification Implementation Plan

> **For agentic workers:** Execute the tasks serially. This is an operational verification plan: do not change product code unless the evidence from a failing check establishes a specific defect and the user approves the resulting fix design.

**Goal:** Re-verify the rebased `followup-issue-18-8-4-2` branch, determine whether the iPhone flat-lying azimuth fix for issue #2 works on the connected iPhone 13 Pro, and leave issue #8 with evidence from a natural multi-speaker recording when one is available.

**Architecture:** Treat the shipped app and its recording artifacts as the source of truth. First establish a single, serial build/deploy baseline; then collect one continuous iPhone recording for issue #2 and inspect its iOS segments. Issue #8 is evaluated only from an ordinary multi-speaker recording, by comparing the final second-pass rendering with the live-equivalent rendering; synthetic speech is not substituted for a naturally occurring conversation.

**Tech Stack:** GNU Make, SwiftPM, Xcode, `xcrun devicectl`, Notetake menu-bar app, iPhone 13 Pro, Apple Watch, `.claude/skills/device`, `.claude/skills/recordings`.

**Spec:** `docs/superpowers/specs/2026-09-13-spatial-location-polish-design.md` (issue #2); `docs/superpowers/plans/2026-09-16-remaining-issue-fixes.md` and `HANDOFF.md` (issue #8 behavior and real-device procedure).

## Global Constraints

- Work only in `.claude/worktrees/followup-issue-18-8-4-2`; the main checkout remains untouched.
- Run builds serially. Do not run `make verify`, Xcode device builds, or active diarized recording concurrently.
- Before every Mac app deployment, use the Makefile target that stops the prior app instance, launches the newly deployed app, and verifies readiness without `notetaked error` output.
- Do not store device identifiers, profiles, pairing codes, credentials, or live user speech in tracked files.
- A Personal Team profile must be trusted on the iPhone before launch. If launch reports an untrusted profile, stop and request that trust action; do not alter signing identities as a workaround.
- Do not force-push, update GitHub issues, rewrite history, merge, or push as part of this plan.
- A failed #2 measurement is evidence, not permission for another speculative axis change. Record the measured result and obtain a new design approval before code changes.
- A missing natural multi-speaker recording leaves #8 as **unverified**, not failed or passed.

## Review Focus

- Rebased artifacts: build and install results must come from this worktree, not the main checkout or a stale bundle.
- App replacement: the old `/Applications/Notetake.app` process must exit before the new bundle is declared healthy.
- iPhone trust: an installed but unlaunchable app is not a device verification result.
- #2 evidence: each of the four source positions needs an identifiable iOS segment; four nearly identical azimuths are a negative result.
- #8 evidence: `fallback-diff.sh` must restore the original `final.md`, and an empty diff is not proof that the race condition occurred.

---

### Task 1: Establish the rebased build baseline

**Files:**
- Read: `Makefile`
- Read: `.build/logs/verify-*.log`
- Output: ephemeral build logs under `.build/logs/`

- [ ] **Step 1: Confirm the target worktree and clean working state**

Run:

```bash
git worktree list
git status --short
git rev-parse --abbrev-ref HEAD
git log -1 --oneline
```

Expected: branch is `followup-issue-18-8-4-2`; the worktree has no unrelated changes.

- [ ] **Step 2: Check that no build or Xcode process is already consuming the machine**

Run:

```bash
ps -ax -o pid=,ppid=,command= | rg '(^|/)(make|xcodebuild|swift)( |$)' || true
```

Expected: no active project build that would overlap this verification. If one exists, wait for it to finish rather than starting another build.

- [ ] **Step 3: Run the repository verification gate**

Run:

```bash
make verify
```

Expected: exit code `0`, final line `verify: OK`, no compiler diagnostic matching the Makefile's `DIAG`, and no `xcodebuild: error:` line in `verify-app.log` or `verify-ios.log`.

- [ ] **Step 4: Record the gate result**

If it fails, preserve the full logs, report every failing target together, and stop before changing source. If it passes, continue without rebuilding in parallel.

### Task 2: Deploy the branch and make the connected devices launchable

**Files:**
- Read: `Makefile`
- Read: `.claude/skills/mac-app/scripts/launch.sh`
- Read: `.claude/skills/device/SKILL.md`
- Output: `/Applications/Notetake.app`, Xcode derived data, device console

- [ ] **Step 1: Deploy and readiness-check the Mac app through Makefile**

Run:

```bash
make register-login-item
```

Expected: the target copies the branch's app to `/Applications/Notetake.app`, terminates the prior instance, starts the replacement, observes `diarizer ready` and the peer listener, finds no `notetaked error`, and reports the login item as `enabled and allowed`.

- [ ] **Step 2: Discover the physical iPhone and Watch without persisting identifiers**

Run:

```bash
xcrun devicectl list devices
```

Expected: the connected iPhone 13 Pro is listed as connected. Record its identifier only in the transient command session. If the Watch is absent, continue with iPhone verification and report the Watch as unavailable.

- [ ] **Step 3: Build, install, and launch the iPhone app against that identifier**

Run the device build and installation serially after Task 1 completes:

```bash
make project
xcodebuild -project Apps/Notetake.xcodeproj -scheme NotetakeMobile -destination 'id=<connected-iphone-id>' -derivedDataPath .build/DerivedData-device -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device <connected-iphone-id> .build/DerivedData-device/Build/Products/Debug-iphoneos/NotetakeMobile.app
xcrun devicectl device process launch --device <connected-iphone-id> --terminate-existing io.github.bash0c7.notetake.ios
```

Expected: install and launch succeed, then `xcrun devicectl device info processes --device <connected-iphone-id>` lists NotetakeMobile. If launch says that the profile is not explicitly trusted, request the user to trust the Personal Team profile in iPhone Settings, then retry only the launch command.

- [ ] **Step 4: Check the Watch only after the iPhone is healthy**

Use the device skill's Watch installation/launch path if the paired Watch is listed and unlocked. Confirm that its app process remains present after launch; otherwise retain the exact device-tool failure as the Watch result.

### Task 3: Run the issue #2 flat-lying azimuth measurement

**Files:**
- Read: `Apps/NotetakeMobile/Recorder.swift`
- Read: `docs/superpowers/specs/2026-09-13-spatial-location-polish-design.md`
- Output: an ordinary recording directory selected in the app; its `<prefix>.timed.jsonl` and `<prefix>.final.md`

- [ ] **Step 1: Start a Mac session and capture its prefix**

Use the menu-bar app to start a session after Task 2's healthy deployment. Identify the created prefix from the status or recording directory before the physical test begins.

- [ ] **Step 2: Collect one continuous four-position iPhone recording**

Ask the user to perform exactly these physical actions while the iPhone app is connected:

1. Lay the iPhone 13 Pro flat, screen up, with its top edge facing a stable reference direction.
2. Tap `取り込み開始`.
3. Play or speak a distinct marker from the reference direction, then at 90-degree clockwise intervals for the other three directions. Include an audible marker such as `位置1` through `位置4` at each position.
4. Tap `取り込み終了`.

Do not stop or restart the Mac session between positions.

- [ ] **Step 3: Stop the Mac session and inspect primary artifacts**

Run:

```bash
.claude/skills/recordings/scripts/inspect.sh <prefix> <recording-directory>
ruby -rjson -e 'ARGF.each_line.filter_map { |l| x = JSON.parse(l) rescue nil; x if x && x["t"] == "seg" && x["platform"] == "ios" }.each { |x| puts [x["start"], x["text"], x.dig("direction", "azimuth_deg"), x.dig("direction", "confidence")].join("\t") }' <recording-directory>/<prefix>.timed.jsonl
```

Expected: iOS segments show `input.spatial: true` and contain usable `direction.azimuth_deg` values corresponding to the four markers.

- [ ] **Step 4: Make the bounded result decision**

Pass: four marker groups have materially separated azimuth values, even if their rotation direction or absolute offset differs from the physical reference.

Fail: `input.spatial` is false, no usable iOS segments arrive, directions are absent, or all four marker groups are clustered. Preserve the extracted values and stop: no channel swap, sign flip, or offset adjustment is permitted without a new approved design.

### Task 4: Obtain and evaluate issue #8 evidence without manufacturing a conversation

**Files:**
- Read: `Sources/NotetakeCore/Reconcile/Reconciler.swift`
- Read: `.claude/skills/recordings/scripts/fallback-diff.sh`
- Output: existing natural-recording artifacts only

- [ ] **Step 1: Wait for an ordinary recording with the target shape**

The recording must contain at least two speakers on the same device and a short acknowledgement or interruption between neighboring spoken turns. Do not claim that generated speech reproduces the diarization race.

- [ ] **Step 2: Inspect the completed recording and run the non-destructive comparison**

Run:

```bash
.claude/skills/recordings/scripts/inspect.sh <prefix> <recording-directory>
.claude/skills/recordings/scripts/fallback-diff.sh <prefix> <recording-directory>
```

Expected: the script reports that it restored `final.md`. A diff that changes a short owner-labelled row to the neighboring speaker is direct real-world evidence of the second pass. An empty diff means only that this recording did not exercise the condition.

- [ ] **Step 3: Classify #8 accurately**

If the diff shows a correction and the surrounding utterances are semantically consistent, mark the real-device scenario verified. If the diff is empty or no natural recording is available, retain #8 as unverified. If the result assigns a wrong speaker, preserve the artifact evidence and prepare a new fix design rather than tuning thresholds ad hoc.

### Task 5: Consolidate evidence and decide the next safe action

**Files:**
- Modify only after verified evidence: `HANDOFF.md`
- Read: `.build/logs/verify-*.log`, recording artifacts, device console output

- [ ] **Step 1: Produce a result matrix**

For `make verify`, Mac deployment, iPhone launch, Watch launch, #2, and #8, classify each as `passed`, `failed with evidence`, or `unverified`, with its log or artifact path.

- [ ] **Step 2: Update the handoff only with verified outcomes**

Add a dated concise entry. Never call #2 or #8 complete from a build result alone; never include live speech or device identifiers.

- [ ] **Step 3: Route the branch**

If all executable checks pass and #8 remains waiting for a natural recording, leave the code unchanged and report that single outstanding evidence requirement. If #2 or #8 produces a concrete defect, return to the brainstorming/design gate for that defect. Git author rewriting, force-push, issue updates, PR changes, merge, and push remain separate user-authorized operations.
