#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="InferenceMeter"
PROJECT_NAME="InferenceMeter.xcodeproj"
SCHEME_NAME="InferenceMeter"
CONFIGURATION="Release"
DERIVED_DATA_DIR="${ROOT_DIR}/DerivedData/Release"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/build/release"
APP_PATH="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

require_tool() {
  local tool="$1"

  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing prerequisite: ${tool}" >&2
    exit 127
  fi
}

require_tool xcodegen
require_tool xcodebuild
require_tool xcrun
require_tool codesign
require_tool ditto

cd "${ROOT_DIR}"

VERSION="$(
  awk -F': ' '/MARKETING_VERSION:/ {
    gsub(/"/, "", $2)
    print $2
    exit
  }' project.yml
)"
VERSION="${VERSION:-0.1.0}"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"

rm -rf "${BUILD_DIR}" "${DERIVED_DATA_DIR}"
mkdir -p "${DIST_DIR}" "${BUILD_DIR}"
rm -f "${ZIP_PATH}"

echo "Generating ${PROJECT_NAME}"
xcodegen generate

echo "Building ${APP_NAME} ${CONFIGURATION}"
xcodebuild \
  -project "${PROJECT_NAME}" \
  -scheme "${SCHEME_NAME}" \
  -configuration "${CONFIGURATION}" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Expected app bundle was not produced at ${APP_PATH}" >&2
  exit 1
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "Signing with Developer ID identity: ${CODESIGN_IDENTITY}"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "${CODESIGN_IDENTITY}" \
    "${APP_PATH}"

  echo "Creating notarization zip at ${ZIP_PATH}"
  ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

  NOTARY_ARGS=()
  if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS+=(--keychain-profile "${NOTARYTOOL_KEYCHAIN_PROFILE}")
  fi

  echo "Submitting notarization request"
  xcrun notarytool submit "${ZIP_PATH}" "${NOTARY_ARGS[@]}" --wait

  echo "Stapling notarization ticket"
  xcrun stapler staple "${APP_PATH}"

  rm -f "${ZIP_PATH}"
else
  echo "CODESIGN_IDENTITY is not set; using ad-hoc signing."
  echo "Gatekeeper caveat: this build is not signed for distribution. On first launch, right-click the app and choose Open, or run: xattr -dr com.apple.quarantine /path/to/${APP_NAME}.app"
  codesign --force --sign - "${APP_PATH}"
fi

echo "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "Packaging ${ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "Release artifact: ${ZIP_PATH}"
