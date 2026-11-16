#!/bin/sh

# countly_dsym_uploader.sh
#
# Uploads dSYM files to a Countly server, so that crash reports from the Countly
# Swift SDK can be symbolicated.
#
# This code is provided under the MIT License.
#
# Please visit https://countly.com/ for more information.
#
#
# Xcode: add a Run Script phase as the last build phase of every target that ships
# code (the app and each app extension), check "For install builds only", uncheck
# "Based on dependency analysis", and call the script from the package checkout:
#
#   COUNTLY_UPLOADER="${BUILD_DIR%/Build/*}/SourcePackages/checkouts/countly-sdk-swift/countly_dsym_uploader.sh"
#   if [ -f "$COUNTLY_UPLOADER" ]; then
#     sh "$COUNTLY_UPLOADER" "https://YOUR_COUNTLY_SERVER" "YOUR_APP_KEY"
#   else
#     echo "warning: [Countly] countly_dsym_uploader.sh was not found at $COUNTLY_UPLOADER"
#   fi
#
# Add these Input Files to the phase. They make Xcode run it after the dSYM is
# written, and let it read the dSYM when User Script Sandboxing is enabled:
#
#   ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}
#   ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist
#   ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${EXECUTABLE_NAME}
#
# Command line and CI: pass a .dSYM, or a folder of them such as MyApp.xcarchive/dSYMs,
# as the third argument:
#
#   sh countly_dsym_uploader.sh "https://YOUR_COUNTLY_SERVER" "YOUR_APP_KEY" "/path/to/MyApp.xcarchive/dSYMs"
#
# Each dSYM is uploaded under the platform it was built for, read from the dSYM itself.
#
# Environment:
#   COUNTLY_DSYM_PLATFORM  ios, macos, tvos or watchos, to override that platform.
#   COUNTLY_DSYM_STRICT    1 makes a failed upload exit with a non-zero status, for CI.
#                          By default the script never fails the build.

UPLOAD_ENDPOINT="/i/crash_symbols/upload_symbol"
CONNECT_TIMEOUT_SECONDS=30
UPLOAD_TIMEOUT_SECONDS=600

HOST=$(printf '%s' "${1:-}" | sed 's:/*$::')
APP_KEY="${2:-}"
DSYM_INPUT_PATH="${3:-}"
STRICT="${COUNTLY_DSYM_STRICT:-0}"
HAD_PROBLEM=0
STOPPED_REASON=""
UPLOADED_COUNT=0
SKIPPED_COUNT=0

# Prints an informational line to the build log.
countly_log() {
    echo "[Countly] $1"
}

# Reports a problem. Xcode lists lines starting with "warning:" or "error:" in the
# Issue navigator, so a failed upload is visible without failing the build.
countly_problem() {
    HAD_PROBLEM=1
    if [ "$STRICT" = "1" ]; then
        echo "error: [Countly] $1"
    else
        echo "warning: [Countly] $1"
    fi
}

# Ends the script: non-zero only in strict mode, after a problem.
countly_finish() {
    if [ "$HAD_PROBLEM" = "1" ] && [ "$STRICT" = "1" ]; then
        exit 1
    fi
    exit 0
}

# Prints how to call the script.
countly_usage() {
    countly_log "Usage: sh countly_dsym_uploader.sh \"https://YOUR_COUNTLY_SERVER\" \"YOUR_APP_KEY\" [\"/path/to/App.dSYM or a folder of dSYMs\"]"
}

# Points at the phase's Input Files when the script runs from Xcode, where missing
# ones both hide the dSYM from a sandboxed script and let the phase run before it exists.
countly_input_files_hint() {
    if [ -z "$DSYM_INPUT_PATH" ]; then
        echo " Add the dSYM folder, its Contents/Info.plist and its Contents/Resources/DWARF file to the Input Files of this Run Script phase."
    fi
}

# Prints the symbol platform of a dSYM, read from the build version of its DWARF
# file. visionOS is reported as ios, the platform the dashboard looks under for its crashes.
countly_dsym_platform() {
    if [ -n "${COUNTLY_DSYM_PLATFORM:-}" ]; then
        echo "$COUNTLY_DSYM_PLATFORM"
        return
    fi
    BUILD_PLATFORM=$(xcrun vtool -show-build "$1" 2>/dev/null | awk '$1 == "platform" { print $2; exit }')
    case "$BUILD_PLATFORM" in
        MACOS) echo "macos" ;;
        TVOS|TVOSSIMULATOR) echo "tvos" ;;
        WATCHOS|WATCHOSSIMULATOR) echo "watchos" ;;
        *) echo "ios" ;;
    esac
}

# Prints the comma separated build UUIDs of a dSYM, one per architecture.
countly_build_uuids() {
    xcrun dwarfdump --uuid "$1" 2>/dev/null | awk '$1 == "UUID:" { print $2 }' | paste -s -d ',' -
}

# Prints "version (build)" from a dSYM's Info.plist, or nothing when it has neither.
countly_version_note() {
    NOTE_PLIST="$1/Contents/Info.plist"
    [ -f "$NOTE_PLIST" ] || return 0
    NOTE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$NOTE_PLIST" 2>/dev/null) || NOTE_VERSION=""
    NOTE_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$NOTE_PLIST" 2>/dev/null) || NOTE_BUILD=""
    if [ -n "$NOTE_VERSION" ] && [ -n "$NOTE_BUILD" ]; then
        echo "$NOTE_VERSION ($NOTE_BUILD)"
    else
        echo "$NOTE_VERSION$NOTE_BUILD"
    fi
}

# Zips one dSYM bundle and uploads it with its build UUIDs.
countly_upload_dsym() {
    DSYM_PATH="$1"
    DSYM_NAME=$(basename "$DSYM_PATH")
    DSYM_PARENT=$(dirname "$DSYM_PATH")
    countly_log "Processing $DSYM_PATH"

    # The server reads the DWARF folder's only file, so the zip holds that and the Info.plist, never a hidden file.
    DSYM_FILES="$WORK_DIR/files"
    (CDPATH='' cd -- "$DSYM_PARENT" && find -L "$DSYM_NAME/Contents/Resources/DWARF" -type f ! -name '.*' && find -L "$DSYM_NAME/Contents" -maxdepth 1 -name Info.plist) > "$DSYM_FILES" 2>/dev/null
    DWARF_FILE=$(grep -m 1 "/Contents/Resources/DWARF/" "$DSYM_FILES")
    if [ -z "$DWARF_FILE" ]; then
        countly_problem "$DSYM_NAME has no DWARF file, so it was not uploaded.$(countly_input_files_hint)"
        return
    fi

    BUILD_UUIDS=$(countly_build_uuids "$DSYM_PARENT/$DWARF_FILE")
    if [ -z "$BUILD_UUIDS" ]; then
        countly_problem "Could not read the build UUIDs of $DSYM_NAME, so it was not uploaded.$(countly_input_files_hint)"
        return
    fi
    PLATFORM=$(countly_dsym_platform "$DSYM_PARENT/$DWARF_FILE")
    countly_log "Build UUIDs: $BUILD_UUIDS, platform: $PLATFORM"

    # curl reads ";" and "," inside a --form value, so the uploaded file gets a name without them.
    ZIP_PATH="$WORK_DIR/$(printf '%s' "$DSYM_NAME.zip" | tr -c 'A-Za-z0-9._-' '_')"
    rm -f "$ZIP_PATH"
    if ! (CDPATH='' cd -- "$(dirname "$DSYM_PATH")" && zip -q -X "$ZIP_PATH" -@ < "$DSYM_FILES"); then
        countly_problem "Could not read every file of $DSYM_NAME, so it was not uploaded.$(countly_input_files_hint)"
        rm -f "$ZIP_PATH"
        return
    fi
    ZIP_KB=$(( ($(wc -c < "$ZIP_PATH") + 1023) / 1024 ))

    NOTE=$(countly_version_note "$DSYM_PATH")
    RESPONSE_FILE="$WORK_DIR/response"
    rm -f "$RESPONSE_FILE"
    # One attempt only: the server stores every request it accepts, so a retry can store the dSYM twice.
    HTTP_STATUS=$(curl --silent --show-error \
        --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
        --max-time "$UPLOAD_TIMEOUT_SECONDS" \
        --output "$RESPONSE_FILE" \
        --write-out '%{http_code}' \
        --form "symbols=@${ZIP_PATH};type=application/zip" \
        --form-string "platform=$PLATFORM" \
        --form-string "app_key=$APP_KEY" \
        --form-string "build=$BUILD_UUIDS" \
        --form-string "note=$NOTE" \
        "$HOST$UPLOAD_ENDPOINT" 2>"$WORK_DIR/curl_error")
    CURL_STATUS=$?
    RESPONSE_BODY=$(cat "$RESPONSE_FILE" 2>/dev/null)
    rm -f "$ZIP_PATH"

    if [ "$CURL_STATUS" -ne 0 ]; then
        countly_problem "Uploading $DSYM_NAME ($ZIP_KB KB) failed: $(cat "$WORK_DIR/curl_error")"
        case "$CURL_STATUS" in
            5|6|7|28|35|51|58|60) STOPPED_REASON="the server could not be reached" ;;
        esac
        return
    fi
    # Servers answer {"result":"Success"} or {"message":"Success",...}; a proxy's 200 page has neither.
    case "$HTTP_STATUS:$RESPONSE_BODY" in
        2??:*'"Success"'*)
            UPLOADED_COUNT=$((UPLOADED_COUNT + 1))
            countly_log "Uploaded $DSYM_NAME ($ZIP_KB KB)."
            return
            ;;
    esac
    countly_problem "The server did not accept $DSYM_NAME ($ZIP_KB KB). HTTP status: $HTTP_STATUS, response: $RESPONSE_BODY"
    case "$HTTP_STATUS" in
        401|403) STOPPED_REASON="the server refused the app key" ;;
    esac
}

if [ -z "$HOST" ] || [ -z "$APP_KEY" ]; then
    countly_usage
    countly_problem "The server URL and the app key are both required. No dSYM was uploaded."
    countly_finish
fi

case "$HOST" in
    http://*|https://*) ;;
    *)
        countly_problem "The server URL must start with http:// or https://, it was \"$HOST\". No dSYM was uploaded."
        countly_finish
        ;;
esac

case "${COUNTLY_DSYM_PLATFORM:-ios}" in
    ios|macos|tvos|watchos) ;;
    *)
        countly_problem "COUNTLY_DSYM_PLATFORM must be ios, macos, tvos or watchos, it was \"$COUNTLY_DSYM_PLATFORM\". No dSYM was uploaded."
        countly_finish
        ;;
esac

if ! command -v xcrun >/dev/null 2>&1; then
    countly_problem "xcrun was not found. The script needs the Xcode command line tools."
    countly_finish
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/countly_dsym.XXXXXX") || {
    countly_problem "Could not create a temporary folder. No dSYM was uploaded."
    countly_finish
}
trap 'rm -rf "$WORK_DIR"' EXIT
DSYM_LIST="$WORK_DIR/dsyms"

if [ -n "$DSYM_INPUT_PATH" ]; then
    case "$DSYM_INPUT_PATH" in
        *.dSYM|*.dSYM/)
            if [ -d "$DSYM_INPUT_PATH" ]; then
                printf '%s\n' "${DSYM_INPUT_PATH%/}" > "$DSYM_LIST"
            fi
            ;;
        *)
            if [ -d "$DSYM_INPUT_PATH" ]; then
                find -L "${DSYM_INPUT_PATH%/}" -mindepth 1 -maxdepth 1 -type d -name '*.dSYM' | sort > "$DSYM_LIST"
            fi
            ;;
    esac
    if [ ! -s "$DSYM_LIST" ]; then
        countly_problem "No dSYM was found at \"$DSYM_INPUT_PATH\"."
        countly_finish
    fi
else
    if [ -n "${DEBUG_INFORMATION_FORMAT:-}" ] && [ "$DEBUG_INFORMATION_FORMAT" != "dwarf-with-dsym" ]; then
        NO_DSYM_MESSAGE="This build configuration produces no dSYM, so there is nothing to upload. Set Debug Information Format to \"DWARF with dSYM File\" for the builds you ship."
        # An install build is one that ships, so a configuration without a dSYM there is a mistake.
        if [ "${DEPLOYMENT_POSTPROCESSING:-}" = "YES" ]; then
            countly_problem "$NO_DSYM_MESSAGE"
        else
            countly_log "$NO_DSYM_MESSAGE"
        fi
        countly_finish
    fi
    if [ -z "${DWARF_DSYM_FOLDER_PATH:-}" ] || [ -z "${DWARF_DSYM_FILE_NAME:-}" ]; then
        countly_usage
        countly_problem "No dSYM path was given and the Xcode build variables that locate one are not set. No dSYM was uploaded."
        countly_finish
    fi
    XCODE_DSYM_PATH="$DWARF_DSYM_FOLDER_PATH/$DWARF_DSYM_FILE_NAME"
    if [ ! -d "$XCODE_DSYM_PATH" ]; then
        countly_problem "The dSYM Xcode should have produced is missing: $XCODE_DSYM_PATH.$(countly_input_files_hint)"
        countly_finish
    fi
    printf '%s\n' "$XCODE_DSYM_PATH" > "$DSYM_LIST"
fi

MASKED_APP_KEY="$(printf '%s' "$APP_KEY" | cut -c1-4)****"
countly_log "Server: $HOST, app key: $MASKED_APP_KEY"

TOTAL_COUNT=$(wc -l < "$DSYM_LIST" | tr -d ' ')
while IFS= read -r DSYM; do
    if [ -n "$STOPPED_REASON" ]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi
    countly_upload_dsym "$DSYM"
done < "$DSYM_LIST"

if [ "$SKIPPED_COUNT" -gt 0 ]; then
    countly_problem "Skipped the other $SKIPPED_COUNT dSYM files, because $STOPPED_REASON."
fi
countly_log "Uploaded $UPLOADED_COUNT of $TOTAL_COUNT dSYM files."
countly_finish
