#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT="${REPO_ROOT}/QuitDelay.xcodeproj"
readonly SCHEME="QuitDelay"
readonly APP_NAME="QuitDelay"
readonly EXECUTABLE_NAME="QuitDelay"
readonly APPLE_TEAM_ID="4ZAZ4G22CR"
readonly EXPECTED_BUNDLE_ID="com.supagoku.QuitDelay"
readonly OUTPUT_DIR="${REPO_ROOT}/.build/production"
readonly OUTPUT_APP="${OUTPUT_DIR}/${APP_NAME}.app"

LAUNCH_AFTER_BUILD=0

usage() {
    cat <<'EOF'
Usage: scripts/build.sh [--launch]

Builds a universal, production-configured QuitDelay app, signs it with the
project's Developer ID Application identity, and places it at:

  .build/production/QuitDelay.app

The local build is not submitted for notarization and is not stapled. Use
scripts/release.sh when preparing an app for distribution.

This script intentionally signs the current working tree with QuitDelay's
production identity so uncommitted changes can be tested accurately.

Options:
  --launch            Launch the app after building, provided another copy of
                      QuitDelay is not already running
  -h, --help          Show this help

Environment variables:
  SIGNING_IDENTITY    exact Developer ID Application identity when more than
                      one is installed
  VERSION             CFBundleShortVersionString override (default: the
                      Release configuration's MARKETING_VERSION)
  BUILD_NUMBER        positive integer CFBundleVersion override (default: the
                      Release configuration's CURRENT_PROJECT_VERSION)
  SKIP_TESTS=1        skip the unit-test phase
EOF
}

log() {
    printf '\n==> %s\n' "$1"
}

die() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --launch)
            LAUNCH_AFTER_BUILD=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

for command_name in codesign ditto lipo openssl security xcodebuild; do
    require_command "${command_name}"
done

[[ -d "${PROJECT}" ]] || die "Xcode project not found: ${PROJECT}"

cd "${REPO_ROOT}"

printf '%s\n' "note: signing the current working tree with QuitDelay's production identity"

log "Reading the Release configuration"
BUILD_SETTINGS="$(
    xcodebuild \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -showBuildSettings \
        CODE_SIGNING_ALLOWED=NO 2>/dev/null
)"

DEFAULT_VERSION="$(
    printf '%s\n' "${BUILD_SETTINGS}" \
        | awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }'
)"
DEFAULT_BUILD_NUMBER="$(
    printf '%s\n' "${BUILD_SETTINGS}" \
        | awk -F ' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION = / { print $2; exit }'
)"

readonly VERSION="${VERSION:-${DEFAULT_VERSION}}"
readonly BUILD_NUMBER="${BUILD_NUMBER:-${DEFAULT_BUILD_NUMBER}}"

[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "VERSION must contain three numeric components, such as 1.0.1."
[[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]] || \
    die "BUILD_NUMBER must be a positive integer."

log "Checking the Developer ID signing identity"
AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning)"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "${AVAILABLE_IDENTITIES}" | grep -Fq "\"${SIGNING_IDENTITY}\"" || \
        die "SIGNING_IDENTITY is not a valid identity in this Mac's Keychain."
    SELECTED_SIGNING_IDENTITY="${SIGNING_IDENTITY}"
else
    SIGNING_IDENTITIES="$(
        printf '%s\n' "${AVAILABLE_IDENTITIES}" \
            | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p'
    )"
    SIGNING_IDENTITY_COUNT="$(
        printf '%s\n' "${SIGNING_IDENTITIES}" \
            | sed '/^$/d' \
            | wc -l \
            | tr -d ' '
    )"

    if [[ "${SIGNING_IDENTITY_COUNT}" == "0" ]]; then
        die "No Developer ID Application identity with a private key is installed."
    fi

    if [[ "${SIGNING_IDENTITY_COUNT}" != "1" ]]; then
        printf '%s\n' "${SIGNING_IDENTITIES}" >&2
        die "Multiple Developer ID identities are installed. Set SIGNING_IDENTITY to the exact identity to use."
    fi

    SELECTED_SIGNING_IDENTITY="${SIGNING_IDENTITIES}"
fi
readonly SELECTED_SIGNING_IDENTITY

[[ "${SELECTED_SIGNING_IDENTITY}" == Developer\ ID\ Application:* ]] || \
    die "The signing identity must be a Developer ID Application certificate."

CERTIFICATE_SUBJECT="$(
    security find-certificate -c "${SELECTED_SIGNING_IDENTITY}" -p \
        | openssl x509 -noout -subject -nameopt RFC2253
)"
[[ "${CERTIFICATE_SUBJECT}" == *"OU=${APPLE_TEAM_ID}"* ]] || \
    die "The selected signing identity does not belong to Apple team ${APPLE_TEAM_ID}."

readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quitdelay-build.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

readonly TEST_DERIVED_DATA="${TEMP_DIR}/TestDerivedData"
readonly ARCHIVE_DERIVED_DATA="${TEMP_DIR}/ArchiveDerivedData"
readonly ARCHIVE_PATH="${TEMP_DIR}/QuitDelay.xcarchive"
readonly ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
readonly ENTITLEMENTS_PATH="${TEMP_DIR}/entitlements.plist"

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    log "Running unit tests"
    xcodebuild \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -destination 'platform=macOS' \
        -derivedDataPath "${TEST_DERIVED_DATA}" \
        test \
        CODE_SIGNING_ALLOWED=NO
fi

log "Archiving ${APP_NAME} ${VERSION} (${BUILD_NUMBER})"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${ARCHIVE_DERIVED_DATA}" \
    -archivePath "${ARCHIVE_PATH}" \
    archive \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${SELECTED_SIGNING_IDENTITY}" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS='--timestamp' \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"

[[ -d "${ARCHIVED_APP}" ]] || \
    die "Archive did not contain ${ARCHIVED_APP}."

log "Verifying the production signature"
codesign --verify --deep --strict --all-architectures --verbose=2 "${ARCHIVED_APP}"

SIGNATURE_DETAILS="$(codesign --display --verbose=4 "${ARCHIVED_APP}" 2>&1)"
printf '%s\n' "${SIGNATURE_DETAILS}" | grep -Fq 'Authority=Developer ID Application:' || \
    die "The app is not signed with Developer ID Application."
printf '%s\n' "${SIGNATURE_DETAILS}" | grep -Fq "TeamIdentifier=${APPLE_TEAM_ID}" || \
    die "The app has the wrong TeamIdentifier."
printf '%s\n' "${SIGNATURE_DETAILS}" | grep -Eq 'flags=.*runtime' || \
    die "Hardened Runtime is not enabled."
printf '%s\n' "${SIGNATURE_DETAILS}" | grep -Fq 'Timestamp=' || \
    die "The Developer ID signature does not contain a secure timestamp."

codesign --display --entitlements - "${ARCHIVED_APP}" \
    >"${ENTITLEMENTS_PATH}" 2>/dev/null || true
GET_TASK_ALLOW="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.security.get-task-allow' \
        "${ENTITLEMENTS_PATH}" 2>/dev/null || true
)"
[[ "${GET_TASK_ALLOW}" != "true" ]] || \
    die "The production build contains the development-only get-task-allow entitlement."
APP_SANDBOX="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :com.apple.security.app-sandbox' \
        "${ENTITLEMENTS_PATH}" 2>/dev/null || true
)"
[[ "${APP_SANDBOX}" != "true" ]] || \
    die "The production build is sandboxed, which prevents global key interception."

INFO_PLIST="${ARCHIVED_APP}/Contents/Info.plist"
APP_BUNDLE_ID="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}"
)"
APP_VERSION="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}"
)"
APP_BUILD_NUMBER="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}"
)"

[[ "${APP_BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]] || \
    die "The app bundle identifier is ${APP_BUNDLE_ID}, expected ${EXPECTED_BUNDLE_ID}."
[[ "${APP_VERSION}" == "${VERSION}" ]] || \
    die "The app version is ${APP_VERSION}, expected ${VERSION}."
[[ "${APP_BUILD_NUMBER}" == "${BUILD_NUMBER}" ]] || \
    die "The app build number is ${APP_BUILD_NUMBER}, expected ${BUILD_NUMBER}."

APP_ARCHITECTURES="$(lipo -archs "${ARCHIVED_APP}/Contents/MacOS/${EXECUTABLE_NAME}")"
lipo "${ARCHIVED_APP}/Contents/MacOS/${EXECUTABLE_NAME}" \
    -verify_arch arm64 x86_64 || \
    die "The app must contain arm64 and x86_64; found ${APP_ARCHITECTURES}."

log "Copying the verified app to ${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_APP}"
ditto "${ARCHIVED_APP}" "${OUTPUT_APP}"
codesign --verify --deep --strict --all-architectures --verbose=2 "${OUTPUT_APP}"

log "Local production build complete"
printf 'App: %s\nVersion: %s (%s)\nArchitectures: %s\nSigning identity: %s\n' \
    "${OUTPUT_APP}" \
    "${VERSION}" \
    "${BUILD_NUMBER}" \
    "${APP_ARCHITECTURES}" \
    "${SELECTED_SIGNING_IDENTITY}"
printf '\nThis app is Developer ID signed, but it has not been notarized or stapled.\n'

if [[ "${LAUNCH_AFTER_BUILD}" == "1" ]]; then
    if pgrep -x "${EXECUTABLE_NAME}" >/dev/null 2>&1; then
        printf '\nQuit the running copy of QuitDelay, then launch this exact build with:\n  open "%s"\n' \
            "${OUTPUT_APP}"
    else
        open "${OUTPUT_APP}"
    fi
else
    printf '\nTo test it, quit any running copy of QuitDelay, then run:\n  open "%s"\n' \
        "${OUTPUT_APP}"
fi
