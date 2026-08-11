#!/usr/bin/env bats
#
# wires/wires-app — the applications installed on this machine.
#
# The apps directory is the census, so listing is a walk and removal is a
# directory - and removal must never reach into a Plug: what an application
# installed into a prefix stays until the Plug goes.
#
#   ./tests/run.sh tests/unit/wires-app.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

APPCMD() { bash "$REPO/wires/wires-app" "$@"; }

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export HOME
    export WIRES_HOME="$HOME/wires"
    unset WIRES_RUNTIME WIRES_PLUG
    mkdir -p "$HOME/.local/bin" "$WIRES_HOME/apps"
}

an_app() {   # name, [version], [min]
    local d="$WIRES_HOME/apps/$1"
    mkdir -p "$d"
    printf '#!/bin/sh\nWIRES_ABI_MIN=%s\n' "${3:-1}" > "$d/$1"
    chmod +x "$d/$1"
    [ -z "${2:-}" ] || printf '%s\n' "$2" > "$d/VERSION"
    ln -sfn "$d/$1" "$HOME/.local/bin/$1"
}

@test "list names every application with version and floor" {
    an_app ableton-live 2026.08.10.1 1
    an_app notepad-plus-plus 8.9.7 1
    run APPCMD list
    [ "$status" -eq 0 ]
    [[ "$output" == *"ableton-live"* ]]
    [[ "$output" == *"2026.08.10.1"* ]]
    [[ "$output" == *"notepad-plus-plus"* ]]
    [[ "$output" == *"8.9.7"* ]]
}

@test "list says so with nothing installed" {
    run APPCMD list
    [ "$status" -eq 0 ]
    [[ "$output" == *"(none)"* ]]
}

@test "rm removes the application and its own link, and nothing else" {
    an_app ableton-live 2026.08.10.1
    an_app notepad-plus-plus 8.9.7
    mkdir -p "$WIRES_HOME/plugs/studio/drive_c"
    printf 'work\n' > "$WIRES_HOME/plugs/studio/drive_c/set.als"

    run APPCMD rm notepad-plus-plus -y
    [ "$status" -eq 0 ]
    [ ! -e "$WIRES_HOME/apps/notepad-plus-plus" ]
    [ ! -e "$HOME/.local/bin/notepad-plus-plus" ]
    # the other application and the Plug's contents are untouched
    [ -x "$WIRES_HOME/apps/ableton-live/ableton-live" ]
    [ "$(cat "$WIRES_HOME/plugs/studio/drive_c/set.als")" = "work" ]
}

# guards: a same-named command from anywhere else is not ours to delete
@test "rm leaves a foreign PATH command alone" {
    an_app notepad-plus-plus 8.9.7
    printf '#!/bin/sh\n' > "$HOME/.local/bin/foreign"
    rm -f "$HOME/.local/bin/notepad-plus-plus"
    ln -sfn "$HOME/.local/bin/foreign" "$HOME/.local/bin/notepad-plus-plus"
    APPCMD rm notepad-plus-plus -y >/dev/null
    [ -L "$HOME/.local/bin/notepad-plus-plus" ]
}

@test "rm refuses an unknown application and lists what is installed" {
    an_app ableton-live
    run APPCMD rm nope -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such application"* ]]
    [[ "$output" == *"ableton-live"* ]]
}

# guards: with no terminal nobody consented; -y is how a script says it meant it
@test "rm without a terminal refuses unless -y" {
    an_app notepad-plus-plus
    run setsid bash "$REPO/wires/wires-app" rm notepad-plus-plus
    [ "$status" -ne 0 ]
    [ -d "$WIRES_HOME/apps/notepad-plus-plus" ]
}

@test "help ends on a command, not on prose" {
    run APPCMD help
    [ "$status" -eq 0 ]
    [[ "$output" == *"wires app rm"* ]]
}

# guards: found in review. An unknown option exited 1 from the app and Plug
# verbs and 2 from the runtime verb, so a caller could not tell "that is not an
# option" from "the command ran and refused" without reading the message.
@test "a usage error exits 2, the same as it does from every other verb" {
    run bash "$REPO/wires/wires" app rm --bogus
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" app rm one two
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" app rm
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" plug rm --bogus
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" runtime install --bogus
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# adopt — wiring up software already in a Plug by reading what its installer
# registered. Fixtures use shapes taken off ~/.wine-ableton.
# ---------------------------------------------------------------------------

a_plug() {                      # name; reads .reg on stdin, echoes the path
    local p="$WIRES_HOME/plugs/$1"
    mkdir -p "$p"
    cat > "$p/system.reg"
    printf '%s\n' "$p"
}

an_exe() {                      # plug, windows-relative dir, exe name
    mkdir -p "$1/drive_c/$2"
    printf 'MZ\n' > "$1/drive_c/$2/$3"
}

@test "adopt: reads the record, generates a launcher, links it on PATH" {
    local p
    p="$(a_plug scratch <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Notepad++] 1784299416
"DisplayName"="Notepad++ (64-bit x64)"
"DisplayIcon"="C:\\Program Files\\Notepad++\\notepad++.exe"
"DisplayVersion"="8.9.7"
REG
)"
    an_exe "$p" "Program Files/Notepad++" "notepad++.exe"

    run APPCMD adopt --plug scratch
    [ "$status" -eq 0 ]
    [[ "$output" == *"8.9.7"* ]]
    [ -x "$WIRES_HOME/apps/notepad++/notepad++" ]
    [ "$(cat "$WIRES_HOME/apps/notepad++/VERSION")" = "8.9.7" ]
    [ "$(readlink "$HOME/.local/bin/notepad++")" = "$WIRES_HOME/apps/notepad++/notepad++" ]
}

# guards: the decision that makes per-project Plugs work. An absolute path
# would pin the launcher to the Plug it was adopted from rather than the one
# selection resolves to.
@test "adopt: the launcher records the executable relative to the Plug" {
    local p
    p="$(a_plug scratch <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Thing] 1784299416
"DisplayName"="Thing"
"DisplayIcon"="C:\\Thing\\thing.exe"
"DisplayVersion"="1.0"
REG
)"
    an_exe "$p" "Thing" "thing.exe"
    APPCMD adopt --plug scratch >/dev/null
    grep -qF 'EXE="$WINEPREFIX/drive_c/Thing/thing.exe"' "$WIRES_HOME/apps/thing/thing"
    ! grep -qF "$p/drive_c" "$WIRES_HOME/apps/thing/thing"
}

@test "adopt: --name overrides the slug taken from the executable" {
    local p
    p="$(a_plug scratch <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Thing] 1784299416
"DisplayName"="Thing"
"DisplayIcon"="C:\\Thing\\thing.exe"
REG
)"
    an_exe "$p" "Thing" "thing.exe"
    APPCMD adopt --plug scratch --name my-thing >/dev/null
    [ -x "$WIRES_HOME/apps/my-thing/my-thing" ]
    [ ! -e "$WIRES_HOME/apps/thing" ]
    # no DisplayVersion in the record, and the version says so rather than lying
    [ "$(cat "$WIRES_HOME/apps/my-thing/VERSION")" = "unknown" ]
}

@test "adopt: a platform runtime is not an application" {
    local p
    p="$(a_plug scratch <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\EdgeWebView] 1784299416
"DisplayName"="Microsoft Edge WebView2 Runtime"
"DisplayIcon"="C:\\WebView\\msedgewebview2.exe"
"DisplayVersion"="140.0"
REG
)"
    an_exe "$p" "WebView" "msedgewebview2.exe"
    run APPCMD adopt --plug scratch
    [ "$status" -ne 0 ]
    [ ! -e "$WIRES_HOME/apps/msedgewebview2" ]
}

@test "adopt: software already fronted by a record is not adopted twice" {
    local p
    p="$(a_plug scratch <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Thing] 1784299416
"DisplayName"="Thing"
"DisplayIcon"="C:\\Thing\\thing.exe"
"DisplayVersion"="1.0"
REG
)"
    an_exe "$p" "Thing" "thing.exe"
    APPCMD adopt --plug scratch >/dev/null
    run APPCMD adopt --plug scratch
    [ "$status" -ne 0 ]
    [[ "$output" == *"Nothing in scratch"* ]]
}

# guards: measured on ~/.wine-ableton. Live registers only in
# RegisteredApplications, whose Capabilities key carries no ApplicationIcon, so
# there is no executable path to be had. Reporting "nothing here" would be a
# lie about a 13G application sitting in the Plug.
@test "adopt: names what the census sees but the record reader cannot reach" {
    local p
    p="$(a_plug studio <<'REG'
[Software\\RegisteredApplications] 1784299416
"Ableton Live 12 Suite"="SOFTWARE\\Ableton\\LiveSuite.12\\Capabilities"
[Software\\Ableton\\LiveSuite.12\\Capabilities] 1784299416
"ApplicationName"="Ableton Live 12 Suite"
REG
)"
    run APPCMD adopt --plug studio
    [ "$status" -ne 0 ]
    [[ "$output" == *"Ableton Live 12 Suite"* ]]
    [[ "$output" == *"not adoptable"* ]]
}

# ...and it stays quiet about it when the Plug also holds something adoptable
# that the caller asked for by name
@test "adopt: a match filter applies to the unreachable list too" {
    local p
    p="$(a_plug studio <<'REG'
[Software\\RegisteredApplications] 1784299416
"Ableton Live 12 Suite"="SOFTWARE\\Ableton\\LiveSuite.12\\Capabilities"
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Notepad++] 1784299416
"DisplayName"="Notepad++ (64-bit x64)"
"DisplayIcon"="C:\\Program Files\\Notepad++\\notepad++.exe"
"DisplayVersion"="8.9.7"
REG
)"
    an_exe "$p" "Program Files/Notepad++" "notepad++.exe"
    run APPCMD adopt Notepad --plug studio
    [ "$status" -eq 0 ]
    [[ "$output" != *"Ableton"* ]]
    [ -x "$WIRES_HOME/apps/notepad++/notepad++" ]
}

@test "adopt: an entry with no reachable executable is named and skipped" {
    local p
    p="$(a_plug scratch <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Ghost] 1784299416
"DisplayName"="Ghost Application"
"DisplayIcon"="C:\\Ghost\\ghost.exe"
REG
)"
    run APPCMD adopt --plug scratch
    [ "$status" -ne 0 ]
    [[ "$output" == *"Ghost Application"* ]]
    [ ! -e "$WIRES_HOME/apps/ghost" ]
}

@test "adopt: an unknown Plug and an unknown option are told apart" {
    run APPCMD adopt --plug nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"no such Plug"* ]]
    run bash "$REPO/wires/wires" app adopt --bogus
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" app adopt one two
    [ "$status" -eq 2 ]
}
