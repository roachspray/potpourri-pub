#!/usr/bin/env bash

# Avaya IP Office SSA launcher for macOS
#
# Purpose:
#   Runs the legacy Avaya System Status Application (SSA) Java applet.
#   SSA is for viewing system status, hardware, alarms, and licenses.
#   It does not change configuration, reset passwords, or factory-reset the unit.
#
# Requirements:
#   - Mac connected directly to the Avaya LAN port
#   - Mac Ethernet IP set to 192.168.42.10/24
#   - Avaya reachable at http://192.168.42.1
#   - curl and standard macOS command-line tools
#
# Java:
#   The script downloads an Azul Zulu Java 8 JDK into ~/.local/opt.
#   Java 8 is required because it includes appletviewer.
#   Nothing is installed system-wide and sudo is not used.
#
# Security:
#   The applet runs with narrowly scoped permissions and a temporary home
#   directory. Review the script before running because this is old Java code
#   downloaded from the Avaya device.
#
# Removal:
#   rm -rf ~/.local/opt/zulu8-avaya ~/Library/Caches/avaya-ssa


set -euo pipefail

SSA_URL="${1:-http://192.168.42.1/ssa/index.html}"
INSTALL_DIR="${HOME}/.local/opt/zulu8-avaya"
CACHE_DIR="${HOME}/Library/Caches/avaya-ssa"
WORK_DIR="$(mktemp -d -t avaya-ssa)"
SSA_HOME="${WORK_DIR}/home"
mkdir -p "$SSA_HOME"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT INT TERM

mkdir -p "$INSTALL_DIR" "$CACHE_DIR"

case "$(uname -m)" in
    arm64)
        API_ARCHES=(arm aarch64)
        ;;
    x86_64)
        API_ARCHES=(x86 x86_64 amd64)
        ;;
    *)
        die "Unsupported Mac architecture: $(uname -m)"
        ;;
esac

APPLET_VIEWER="$(
    find "$INSTALL_DIR" \
        -type f \
        -path '*/bin/appletviewer' \
        -perm -111 \
        -print \
        -quit 2>/dev/null || true
)"

if [[ -z "$APPLET_VIEWER" ]]; then
    METADATA="${WORK_DIR}/packages.json"
    DOWNLOAD_URL=""

    for API_ARCH in "${API_ARCHES[@]}"; do
        API_URL="https://api.azul.com/metadata/v1/zulu/packages/?java_version=8&os=macos&arch=${API_ARCH}&java_package_type=jdk&release_status=ga&availability_types=CA&archive_type=zip&latest=true&page=1&page_size=20"

        printf 'Checking Azul for Java 8 JDK, architecture %s...\n' \
            "$API_ARCH"

        if ! curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --proto '=https' \
            --tlsv1.2 \
            "$API_URL" \
            -o "$METADATA"
        then
            continue
        fi

        DOWNLOAD_URL="$(
            /usr/bin/plutil \
                -extract '0.download_url' \
                raw \
                -o - \
                "$METADATA" 2>/dev/null || true
        )"

        if [[ -z "$DOWNLOAD_URL" ]] &&
           command -v python3 >/dev/null 2>&1
        then
            DOWNLOAD_URL="$(
                python3 - "$METADATA" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    packages = json.load(handle)

if packages:
    print(packages[0].get("download_url", ""))
PY
            )"
        fi

        [[ -n "$DOWNLOAD_URL" ]] && break
    done

    [[ -n "$DOWNLOAD_URL" ]] ||
        die "Azul did not return a compatible Java 8 JDK."

    case "$DOWNLOAD_URL" in
        https://cdn.azul.com/* | https://api.azul.com/*)
            ;;
        *)
            die "Refusing unexpected download URL: $DOWNLOAD_URL"
            ;;
    esac

    ARCHIVE_NAME="$(basename "${DOWNLOAD_URL%%\?*}")"
    ARCHIVE="${CACHE_DIR}/${ARCHIVE_NAME}"

    printf 'Downloading Java 8 from:\n  %s\n' "$DOWNLOAD_URL"

    curl \
        --fail \
        --show-error \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        "$DOWNLOAD_URL" \
        -o "$ARCHIVE"

    printf '\nDownloaded archive SHA-256:\n'
    shasum -a 256 "$ARCHIVE"

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    case "$ARCHIVE" in
        *.zip)
            /usr/bin/ditto -x -k "$ARCHIVE" "$INSTALL_DIR"
            ;;
        *.tar.gz | *.tgz)
            tar -xzf "$ARCHIVE" -C "$INSTALL_DIR"
            ;;
        *)
            die "Unsupported archive format: $ARCHIVE"
            ;;
    esac

    APPLET_VIEWER="$(
        find "$INSTALL_DIR" \
            -type f \
            -path '*/bin/appletviewer' \
            -perm -111 \
            -print \
            -quit 2>/dev/null || true
    )"

    [[ -n "$APPLET_VIEWER" ]] ||
        die "The downloaded JDK does not contain appletviewer."
fi

JAVA_BIN="${APPLET_VIEWER%/appletviewer}/java"
SSA_BASE="${SSA_URL%/*}/"
ORIGINAL_HTML="${WORK_DIR}/original.html"
PATCHED_HTML="${WORK_DIR}/patched.html"
POLICY_FILE="${WORK_DIR}/avaya-ssa.policy"

printf '\nUsing Java installation:\n  %s\n\n' "$JAVA_BIN"
"$JAVA_BIN" -version

printf '\nDownloading Avaya SSA page:\n  %s\n' "$SSA_URL"

curl \
    --fail \
    --silent \
    --show-error \
    "$SSA_URL" \
    -o "$ORIGINAL_HTML" ||
    die "Could not download the Avaya SSA page."

grep -qi '<applet' "$ORIGINAL_HTML" ||
    die "The downloaded page does not contain an applet tag."

sed \
    -e 's/width="100%"/width="1024"/g' \
    -e 's/height="99%"/height="768"/g' \
    -e "s#<applet #<applet codebase=\"${SSA_BASE}\" #" \
    "$ORIGINAL_HTML" > "$PATCHED_HTML"

cat > "$POLICY_FILE" <<EOF
grant codeBase "${SSA_BASE}-" {
    permission java.io.FilePermission "/ssa/logging.properties", "read";
    permission java.util.logging.LoggingPermission "control";
    permission java.net.URLPermission "${SSA_BASE}-", "*:*";
    permission java.util.PropertyPermission "user.home", "read";
    permission java.io.FilePermission "${SSA_HOME}/address.ser", "read,write,delete";
    permission java.lang.RuntimePermission "preferences";
    permission java.util.PropertyPermission "java.util.prefs.syncInterval", "read";
    permission java.lang.RuntimePermission "setContextClassLoader";
    permission java.lang.RuntimePermission "shutdownHooks";
    permission java.util.PropertyPermission "java.util.prefs.flushDelay", "read";
};
EOF

printf '\nLaunching Avaya SSA Viewer...\n'
printf 'Close the Java window to exit.\n\n'

"$APPLET_VIEWER" \
    "-J-Djava.security.policy=${POLICY_FILE}" \
    "-J-Duser.home=${SSA_HOME}"  \
    "$PATCHED_HTML"
