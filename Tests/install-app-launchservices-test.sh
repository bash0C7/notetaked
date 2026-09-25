#!/bin/bash
set -euo pipefail

fail() {
  echo "install-app must register and restart the copied app after ditto" >&2
  exit 1
}

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

test ! -e .agents || fail
grep -qxF '.agents/' .gitignore || fail
grep -qxF -- '- 決定論的な作業で使うskillの正本はリポジトリ内の`.claude/skills/`のみ。`.agents/`はgitignore済みで、作成・参照しない。' AGENTS.md || fail

install_recipe=$(awk '
  /^install-app: app$/ { in_recipe = 1; next }
  in_recipe && /^[^[:space:]]/ { exit }
  in_recipe { print }
' Makefile)

ditto_line=$(printf '%s\n' "$install_recipe" | grep -nF 'ditto --rsrc --extattr --acl "$(APP_BUNDLE)" "$(INSTALL_APP)"' | cut -d: -f1)
register_line=$(printf '%s\n' "$install_recipe" | grep -nF '$(LSREGISTER) -f "$(INSTALL_APP)"' | cut -d: -f1)
restart_line=$(printf '%s\n' "$install_recipe" | grep -nF './.claude/skills/mac-app/scripts/launch.sh /tmp/notetake-app.log' | cut -d: -f1)

test -n "$ditto_line" || fail
test -n "$register_line" || fail
test -n "$restart_line" || fail
test "$ditto_line" -lt "$register_line" || fail
test "$register_line" -lt "$restart_line" || fail

login_recipe=$(awk '
  /^register-login-item: install-app$/ { in_recipe = 1; next }
  in_recipe && /^[^[:space:]]/ { exit }
  in_recipe { print }
' Makefile)

printf '%s\n' "$login_recipe" | grep -qF 'sfltool dumpbtm' || fail
grep -qxF 'APP_BUNDLE_ID := io.github.bash0c7.notetake' Makefile || fail
printf '%s\n' "$login_recipe" | grep -qF 'bundle="$(APP_BUNDLE_ID)"' || fail
grep -qF 'make register-login-item' README.md || fail
make -n register-login-item | bash -n || fail

grep -qF 'DAEMON_IDENTITY ?= $(shell security find-identity -v -p codesigning' Makefile || fail
grep -qF 'if [ -z "$$identity" ]; then identity=-; fi' Makefile || fail
grep -qF -- '-allowProvisioningUpdates build' Makefile || fail
! grep -qF 'CODE_SIGN_STYLE: Manual' Apps/project.yml || fail
! grep -qF 'CODE_SIGN_IDENTITY: "-"' Apps/project.yml || fail
grep -qF 'case .notRegistered, .notFound:' Apps/Notetake/NotetakeApp.swift || fail
grep -qF 'try service.register()' Apps/Notetake/NotetakeApp.swift || fail
