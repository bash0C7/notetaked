#!/bin/bash
# usage: ntset.sh <field name> <text> [enter|close]   -- Settings window must be open
osascript - "$1" "$2" "$3" <<'AS'
on run argv
tell application "System Events" to tell process "Notetake"
  set frontmost to true
  set w to window "Notetake Settings"
  perform action "AXRaise" of w
  set els to entire contents of w
  set tf to missing value
  repeat with e in els
    try
      if (class of e as string) is "text field" and (name of e as string) is (item 1 of argv) then
        set tf to e
        exit repeat
      end if
    end try
  end repeat
  if tf is missing value then error "field not found"
  set focused of tf to true
  delay 0.3
  set value of tf to (item 2 of argv)
  delay 0.2
  if (item 3 of argv) is "enter" then
    keystroke return
  else if (item 3 of argv) is "close" then
    keystroke "w" using command down
  end if
  delay 0.5
  return "set " & (item 1 of argv)
end tell
end run
AS
