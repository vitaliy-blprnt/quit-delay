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
readonly EXPECTED_GITHUB_ACCOUNT="vitaliy-blprnt"
readonly GITHUB_REPOSITORY="vitaliy-blprnt/quit-delay"
readonly NOTARY_PROFILE="${NOTARY_PROFILE:-QuitDelay}"
readonly DIST_DIR="${REPO_ROOT}/dist"

VERSION=""
RELEASE_KIND="published"

usage() {
    cat <<'EOF'
Usage: scripts/release.sh <version> [--draft | --prerelease]

Builds a universal Developer ID-signed archive, submits it to Apple's notary
service, staples and validates the ticket, then creates a GitHub Release.

Examples:
  scripts/release.sh 1.0.0
  scripts/release.sh 1.1.0 --draft

Environment variables:
  NOTARY_PROFILE     notarytool Keychain profile (default: QuitDelay)
  SIGNING_IDENTITY   exact Developer ID Application identity when more than
                     one is installed
  BUILD_NUMBER       positive integer CFBundleVersion (default: commit count)
  SKIP_TESTS=1       skip the unit-test phase
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
        --draft)
            [[ "${RELEASE_KIND}" == "published" ]] || die "Choose only one release kind."
            RELEASE_KIND="draft"
            ;;
        --prerelease)
            [[ "${RELEASE_KIND}" == "published" ]] || die "Choose only one release kind."
            RELEASE_KIND="prerelease"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            die "Unknown option: $1"
            ;;
        *)
            [[ -z "${VERSION}" ]] || die "Only one version may be supplied."
            VERSION="$1"
            ;;
    esac
    shift
done

[[ -n "${VERSION}" ]] || {
    usage >&2
    exit 2
}

[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "Version must contain three numeric components, such as 1.0.0."

readonly TAG="v${VERSION}"
readonly BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "${REPO_ROOT}" rev-list --count HEAD)}"
[[ "${BUILD_NUMBER}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER must be a positive integer."

for command_name in codesign ditto gh git lipo openssl plutil security shasum spctl unzip xcodebuild xcrun; do
    require_command "${command_name}"
done

[[ -d "${PROJECT}" ]] || die "Xcode project not found: ${PROJECT}"

cd "${REPO_ROOT}"

log "Checking source and release destination"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || \
    die "The working tree must be clean before releasing."

CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
[[ -n "${CURRENT_BRANCH}" ]] || die "Releases must be created from a branch, not a detached HEAD."
[[ "${CURRENT_BRANCH}" == "main" ]] || die "Releases must be created from the main branch."
readonly CURRENT_BRANCH

readonly HEAD_SHA="$(git rev-parse HEAD)"
readonly ACTIVE_GITHUB_ACCOUNT="$(gh api user --jq .login 2>/dev/null || true)"
[[ "${ACTIVE_GITHUB_ACCOUNT}" == "${EXPECTED_GITHUB_ACCOUNT}" ]] || \
    die "GitHub CLI must be active as ${EXPECTED_GITHUB_ACCOUNT}. Run: gh auth switch --hostname github.com --user ${EXPECTED_GITHUB_ACCOUNT}"

readonly REPOSITORY_VISIBILITY="$(gh repo view "${GITHUB_REPOSITORY}" --json visibility --jq .visibility 2>/dev/null || true)"
[[ "${REPOSITORY_VISIBILITY}" == "PUBLIC" ]] || \
    die "${GITHUB_REPOSITORY} must exist and be public before releasing."

readonly REMOTE_HEAD_SHA="$(gh api "repos/${GITHUB_REPOSITORY}/commits/${CURRENT_BRANCH}" --jq .sha 2>/dev/null || true)"
[[ "${REMOTE_HEAD_SHA}" == "${HEAD_SHA}" ]] || \
    die "Push the current ${CURRENT_BRANCH} commit to ${GITHUB_REPOSITORY} before releasing."

if gh release view "${TAG}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1; then
    die "GitHub Release ${TAG} already exists."
fi

if gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
    die "Git tag ${TAG} already exists on GitHub without a release. Resolve it before retrying."
fi

log "Checking Apple signing identity"
readonly AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning)"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "${AVAILABLE_IDENTITIES}" | grep -Fq "\"${SIGNING_IDENTITY}\"" || \
        die "SIGNING_IDENTITY is not a valid identity in this Mac's Keychain."
else
    SIGNING_IDENTITIES="$(printf '%s\n' "${AVAILABLE_IDENTITIES}" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')"
    SIGNING_IDENTITY_COUNT="$(printf '%s\n' "${SIGNING_IDENTITIES}" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "${SIGNING_IDENTITY_COUNT}" == "0" ]]; then
        die "No Developer ID Application identity with a private key is installed. Install it in Keychain Access before releasing."
    fi

    if [[ "${SIGNING_IDENTITY_COUNT}" != "1" ]]; then
        printf '%s\n' "${SIGNING_IDENTITIES}" >&2
        die "Multiple Developer ID identities are installed. Set SIGNING_IDENTITY to the exact identity to use."
    fi

    SIGNING_IDENTITY="${SIGNING_IDENTITIES}"
fi
readonly SIGNING_IDENTITY

[[ "${SIGNING_IDENTITY}" == Developer\ ID\ Application:* ]] || \
    die "The signing identity must be a Developer ID Application certificate."

CERTIFICATE_SUBJECT="$(security find-certificate -c "${SIGNING_IDENTITY}" -p | openssl x509 -noout -subject -nameopt RFC2253)"
[[ "${CERTIFICATE_SUBJECT}" == *"OU=${APPLE_TEAM_ID}"* ]] || \
    die "The selected signing identity does not belong to Apple team ${APPLE_TEAM_ID}."
readonly CERTIFICATE_SUBJECT

log "Checking Apple notarization credentials"
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" --output-format json >/dev/null 2>&1; then
    die "notarytool Keychain profile '${NOTARY_PROFILE}' is missing or invalid. Create it interactively with: xcrun notarytool store-credentials ${NOTARY_PROFILE}"
fi

readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quitdelay-release.XXXXXX")"
trap 'rm -rf "${TEMP_DIR}"' EXIT

readonly TEST_DERIVED_DATA="${TEMP_DIR}/TestDerivedData"
readonly ARCHIVE_PATH="${TEMP_DIR}/QuitDelay.xcarchive"
readonly APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
readonly SUBMISSION_ZIP="${TEMP_DIR}/${APP_NAME}-${TAG}-submission.zip"
readonly NOTARY_RESULT="${TEMP_DIR}/notary-result.json"
readonly NOTARY_LOG="${DIST_DIR}/${APP_NAME}-${TAG}-notarization-log.json"
readonly FINAL_ZIP="${DIST_DIR}/${APP_NAME}-${TAG}.zip"
readonly CHECKSUM_FILE="${FINAL_ZIP}.sha256"
readonly VERIFY_DIR="${TEMP_DIR}/verify"

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
    -archivePath "${ARCHIVE_PATH}" \
    archive \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS='--timestamp' \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"

[[ -d "${APP_PATH}" ]] || die "Archive did not contain ${APP_PATH}."

log "Verifying the archived app"
codesign --verify --deep --strict --all-architectures --verbose=2 "${APP_PATH}"

SIGNATURE_DETAILS="$(codesign --display --verbose=4 "${APP_PATH}" 2>&1)"
printf '%s\n' "${SIGNATURE_DETAILS}" | grep -Fq 'Authority=Developer ID Application:' || \
    die "Archive is not signed with Developer ID Application."
printf '%s\n' "${SIGNATURE_DETAILS}" | grep -Fq "TeamIdentifier=${APPLE_TEAM_ID}" || \
    die "Archive has the wrong TeamIdentifier."
printf '%s\n' "${SIGNATURE_DETAILS}" | grep -Eq 'flags=.*runtime' || \
    die "Hardened Runtime is not enabled in the archive."
printf '%s\n' "${SIGNATURE_DETAILS}" | grep -Fq 'Timestamp=' || \
    die "The Developer ID signature does not contain a secure timestamp."

ENTITLEMENTS_PATH="${TEMP_DIR}/entitlements.plist"
codesign --display --entitlements :- "${APP_PATH}" >"${ENTITLEMENTS_PATH}" 2>/dev/null || true
GET_TASK_ALLOW="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "${ENTITLEMENTS_PATH}" 2>/dev/null || true)"
[[ "${GET_TASK_ALLOW}" != "true" ]] || die "Release archive contains the development-only get-task-allow entitlement."

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
[[ "${APP_VERSION}" == "${VERSION}" ]] || die "Archived app version is ${APP_VERSION}, expected ${VERSION}."

APP_ARCHITECTURES="$(lipo -archs "${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}")"
lipo "${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}" -verify_arch arm64 x86_64 || \
    die "Archive must contain both arm64 and x86_64 architectures; found ${APP_ARCHITECTURES}."

log "Submitting ${APP_NAME} to Apple's notary service"
ditto -c -k --sequesterRsrc --keepParent --noqtn --zlibCompressionLevel 9 \
    "${APP_PATH}" "${SUBMISSION_ZIP}"
unzip -tq "${SUBMISSION_ZIP}"

NOTARY_EXIT_CODE=0
xcrun notarytool submit "${SUBMISSION_ZIP}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait \
    --output-format json >"${NOTARY_RESULT}" || NOTARY_EXIT_CODE=$?

cat "${NOTARY_RESULT}"
NOTARY_STATUS="$(plutil -extract status raw -o - "${NOTARY_RESULT}" 2>/dev/null || true)"
NOTARY_SUBMISSION_ID="$(plutil -extract id raw -o - "${NOTARY_RESULT}" 2>/dev/null || true)"

if [[ "${NOTARY_EXIT_CODE}" != "0" || "${NOTARY_STATUS}" != "Accepted" ]]; then
    mkdir -p "${DIST_DIR}"
    if [[ -n "${NOTARY_SUBMISSION_ID}" ]]; then
        xcrun notarytool log "${NOTARY_SUBMISSION_ID}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            "${NOTARY_LOG}" || true
    fi
    die "Apple returned notarization status '${NOTARY_STATUS:-unknown}'. See ${NOTARY_LOG}."
fi

log "Stapling and validating the notarization ticket"
xcrun stapler staple -v "${APP_PATH}"
xcrun stapler validate -v "${APP_PATH}"
spctl --assess --type execute --verbose=4 "${APP_PATH}"

log "Packaging the stapled app"
mkdir -p "${DIST_DIR}"
rm -f "${FINAL_ZIP}" "${CHECKSUM_FILE}"
ditto -c -k --sequesterRsrc --keepParent --noqtn --zlibCompressionLevel 9 \
    "${APP_PATH}" "${FINAL_ZIP}"
unzip -tq "${FINAL_ZIP}"

mkdir -p "${VERIFY_DIR}"
ditto -x -k --noqtn "${FINAL_ZIP}" "${VERIFY_DIR}"
readonly EXTRACTED_APP="${VERIFY_DIR}/${APP_NAME}.app"
[[ -d "${EXTRACTED_APP}" ]] || die "Final ZIP did not preserve the app bundle."
codesign --verify --deep --strict --all-architectures --verbose=2 "${EXTRACTED_APP}"
xcrun stapler validate -v "${EXTRACTED_APP}"
lipo "${EXTRACTED_APP}/Contents/MacOS/${EXECUTABLE_NAME}" -verify_arch arm64 x86_64

(
    cd "${DIST_DIR}"
    shasum -a 256 "$(basename "${FINAL_ZIP}")" >"$(basename "${CHECKSUM_FILE}")"
)

log "Creating GitHub Release ${TAG}"
GH_RELEASE_ARGS=(
    release create "${TAG}"
    "${FINAL_ZIP}#${APP_NAME} ${VERSION} for macOS"
    "${CHECKSUM_FILE}#SHA-256 checksum"
    --repo "${GITHUB_REPOSITORY}"
    --target "${HEAD_SHA}"
    --title "${APP_NAME} ${VERSION}"
    --generate-notes
)

case "${RELEASE_KIND}" in
    draft) GH_RELEASE_ARGS+=(--draft) ;;
    prerelease) GH_RELEASE_ARGS+=(--prerelease) ;;
esac

gh "${GH_RELEASE_ARGS[@]}"

UPLOADED_ASSETS="$(gh release view "${TAG}" --repo "${GITHUB_REPOSITORY}" --json assets --jq '.assets[].name')"
printf '%s\n' "${UPLOADED_ASSETS}" | grep -Fxq "$(basename "${FINAL_ZIP}")" || \
    die "GitHub did not report the release ZIP after upload."
printf '%s\n' "${UPLOADED_ASSETS}" | grep -Fxq "$(basename "${CHECKSUM_FILE}")" || \
    die "GitHub did not report the checksum after upload."

readonly RELEASE_URL="$(gh release view "${TAG}" --repo "${GITHUB_REPOSITORY}" --json url --jq .url)"
log "Release complete: ${RELEASE_URL}"
printf 'Artifact: %s\nChecksum: %s\n' "${FINAL_ZIP}" "${CHECKSUM_FILE}"
