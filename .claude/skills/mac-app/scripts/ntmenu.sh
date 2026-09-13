#!/bin/bash
# usage: ntmenu.sh "<menu item title>"  |  ntmenu.sh --list
if [ "$1" = "--list" ]; then
osascript <<'AS'
tell application "System Events" to tell process "Notetake"
  set mbi to menu bar item 1 of menu bar 2
  click mbi
  delay 0.4
  set names to name of every menu item of menu 1 of mbi
  key code 53
  return names
end tell
AS
else
osascript - "$1" <<'AS'
on run argv
tell application "System Events" to tell process "Notetake"
  set mbi to menu bar item 1 of menu bar 2
  click mbi
  delay 0.4
  click menu item (item 1 of argv) of menu 1 of mbi
  return "clicked " & (item 1 of argv)
end tell
end run
AS
fi
