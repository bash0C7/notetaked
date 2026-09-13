#!/bin/bash
osascript - "$1" <<'AS'
on run argv
tell application "System Events" to tell process "Notetake"
  set els to entire contents of window "Notetake Settings"
  repeat with e in els
    try
      if (class of e as string) is "text field" and (name of e as string) is (item 1 of argv) then return value of e
    end try
  end repeat
  return "?"
end tell
end run
AS
