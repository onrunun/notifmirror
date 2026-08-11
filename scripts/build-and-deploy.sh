#!/usr/bin/env bash
# Builds the Android app and installs+launches it on a connected device,
# and builds the macOS app, copies it into /Applications, and launches it.
#
# Usage:
#   ./scripts/build-and-deploy.sh              # both platforms (parallel)
#   ./scripts/build-and-deploy.sh android      # android only
#   ./scripts/build-and-deploy.sh mac          # mac only
#   ./scripts/build-and-deploy.sh --sequential # run both, one after the other

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$PROJECT_ROOT/android"
MAC_DIR="$PROJECT_ROOT/mac"

ANDROID_PACKAGE="com.notifmirror.android"
ANDROID_LAUNCH_ACTIVITY="$ANDROID_PACKAGE/.MainActivity"

# Gradle needs a JDK 17+ to run AGP 8.x. If JAVA_HOME isn't set, fall back
# to the JBR bundled with Android Studio (typical install path on macOS).
if [[ -z "${JAVA_HOME:-}" ]]; then
    local_jbr="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    if [[ -d "$local_jbr" ]]; then
        export JAVA_HOME="$local_jbr"
    else
        err "JAVA_HOME is unset and no Android Studio JBR found at $local_jbr"
        err "export JAVA_HOME=/path/to/jdk17+ before running this script"
        exit 1
    fi
fi

MAC_SCHEME="NotifMirror"
MAC_PROJECT="$MAC_DIR/NotifMirror.xcodeproj"
MAC_APP_NAME="NotifMirror.app"
MAC_INSTALL_DIR="/Applications"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

log()  { printf "%s[%s]%s %s\n" "$BLUE"  "$(date +%H:%M:%S)" "$NC" "$*"; }
ok()   { printf "%s[%s] ✓%s %s\n"        "$GREEN" "$(date +%H:%M:%S)" "$NC" "$*"; }
warn() { printf "%s[%s] !%s %s\n"        "$YELLOW" "$(date +%H:%M:%S)" "$NC" "$*"; }
err()  { printf "%s[%s] ✗%s %s\n"        "$RED"   "$(date +%H:%M:%S)" "$NC" "$*" >&2; }

need() {
    command -v "$1" >/dev/null 2>&1 || { err "missing required tool: $1"; exit 1; }
}

build_android() {
    log "android: checking prerequisites"
    need adb

    local devices
    devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
    if [[ -z "$devices" ]]; then
        err "android: no device connected (adb devices shows none). plug in phone & enable USB debugging."
        return 1
    fi
    local device_count
    device_count=$(printf "%s\n" "$devices" | wc -l | tr -d ' ')
    log "android: $device_count device(s) ready: $(printf "%s " $devices)"

    log "android: building & installing debug apk via gradle"
    ( cd "$ANDROID_DIR" && ./gradlew :app:installDebug )

    log "android: launching $ANDROID_LAUNCH_ACTIVITY"
    while IFS= read -r serial; do
        adb -s "$serial" shell am start -n "$ANDROID_LAUNCH_ACTIVITY" >/dev/null
        ok "android: launched on $serial"
    done <<< "$devices"
}

build_mac() {
    log "mac: checking prerequisites"
    need xcodebuild

    if [[ -f "$MAC_DIR/project.yml" ]] && command -v xcodegen >/dev/null 2>&1; then
        log "mac: regenerating xcode project via xcodegen"
        ( cd "$MAC_DIR" && xcodegen generate >/dev/null )
    fi

    local derived="$MAC_DIR/build/DerivedData"
    log "mac: building Release via xcodebuild (real ad-hoc signing)"
    # Real ad-hoc bundle signing (CODE_SIGN_IDENTITY="-"), not the
    # linker-signed stub that CODE_SIGNING_ALLOWED=NO produces. macOS
    # rejects UNUserNotificationCenter requests from linker-signed bundles
    # with UNErrorDomain 1 / notSupported settings, because the Info.plist
    # and entitlements aren't sealed into the signature.
    xcodebuild \
        -project "$MAC_PROJECT" \
        -scheme "$MAC_SCHEME" \
        -configuration Release \
        -derivedDataPath "$derived" \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual \
        build | xcbeautify 2>/dev/null || \
    xcodebuild \
        -project "$MAC_PROJECT" \
        -scheme "$MAC_SCHEME" \
        -configuration Release \
        -derivedDataPath "$derived" \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGN_STYLE=Manual \
        build

    local built_app="$derived/Build/Products/Release/$MAC_APP_NAME"
    if [[ ! -d "$built_app" ]]; then
        err "mac: built app not found at $built_app"
        return 1
    fi

    local installed_app="$MAC_INSTALL_DIR/$MAC_APP_NAME"
    log "mac: installing into $MAC_INSTALL_DIR"

    # Quit any running instance so we can replace the bundle cleanly.
    if pgrep -x "$MAC_SCHEME" >/dev/null 2>&1; then
        log "mac: quitting running instance"
        osascript -e "tell application \"$MAC_SCHEME\" to quit" >/dev/null 2>&1 || true
        sleep 1
        pkill -x "$MAC_SCHEME" 2>/dev/null || true
    fi

    if [[ -w "$MAC_INSTALL_DIR" ]]; then
        rm -rf "$installed_app"
        ditto "$built_app" "$installed_app"
        xattr -dr com.apple.provenance "$installed_app" 2>/dev/null || true
        xattr -dr com.apple.quarantine "$installed_app" 2>/dev/null || true
    else
        warn "mac: /Applications not writable — using sudo"
        sudo rm -rf "$installed_app"
        sudo ditto "$built_app" "$installed_app"
        sudo xattr -dr com.apple.provenance "$installed_app" 2>/dev/null || true
        sudo xattr -dr com.apple.quarantine "$installed_app" 2>/dev/null || true
    fi

    # Sanity-check: fail loudly if we still ended up with a linker-signed
    # binary (no sealed Info.plist → notifications silently broken).
    if codesign -dvv "$installed_app" 2>&1 | grep -q "linker-signed"; then
        err "mac: bundle is linker-signed only — notifications will not work. Check CODE_SIGN_* flags."
        return 1
    fi

    log "mac: launching $installed_app"
    open "$installed_app"
    ok "mac: launched $MAC_APP_NAME"
}

run_one() {
    case "$1" in
        android) build_android ;;
        mac)     build_mac ;;
        *) err "unknown target: $1"; exit 2 ;;
    esac
}

main() {
    local target="${1:-both}"
    local mode="parallel"

    for arg in "$@"; do
        case "$arg" in
            --sequential|-s) mode="sequential" ;;
        esac
    done

    case "$target" in
        android|mac)
            run_one "$target"
            ;;
        both|--sequential|-s|"")
            if [[ "$mode" == "sequential" ]]; then
                build_android
                build_mac
            else
                log "running android + mac builds in parallel"
                local a_log m_log
                a_log=$(mktemp -t android_build.XXXXXX.log)
                m_log=$(mktemp -t mac_build.XXXXXX.log)
                ( build_android ) >"$a_log" 2>&1 & local apid=$!
                ( build_mac )     >"$m_log" 2>&1 & local mpid=$!

                local a_status=0 m_status=0
                wait "$apid" || a_status=$?
                wait "$mpid" || m_status=$?

                printf "\n%s===== android output =====%s\n" "$BLUE" "$NC"
                cat "$a_log"
                printf "\n%s===== mac output =====%s\n" "$BLUE" "$NC"
                cat "$m_log"
                rm -f "$a_log" "$m_log"

                if (( a_status != 0 )); then err "android failed (exit $a_status)"; fi
                if (( m_status != 0 )); then err "mac failed (exit $m_status)"; fi
                (( a_status == 0 && m_status == 0 )) || exit 1
            fi
            ;;
        -h|--help)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *)
            err "unknown argument: $target (use: android | mac | both | --sequential)"
            exit 2
            ;;
    esac

    ok "all done"
}

main "$@"
