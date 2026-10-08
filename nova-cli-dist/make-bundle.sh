#!/usr/bin/env sh
# Build a standalone, distributable nova-cli package.
#
# Downloads the nova-cli binaries for every supported platform, verifies them
# against the upstream checksums.txt, and emits a tarball that installs with
# no network access:
#
#   nova-cli-<version>/
#     install.sh
#     checksums.txt       (only the platforms actually bundled)
#     version.json        (if upstream publishes one)
#     README.md
#     bin/nova-cli_linux_amd64
#     bin/nova-cli_linux_arm64
#     bin/nova-cli_darwin_amd64
#     bin/nova-cli_darwin_arm64
#
# Usage: ./make-bundle.sh [--channel stable|beta|alpha] [--version V]
#                         [--alpha-ref REF] [--job-id ID]
#                         [--platforms "linux_amd64 darwin_arm64"]
#                         [--out DIR]

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

GITLAB_BASE_URL="${NOVA_CLI_GITLAB_BASE_URL:-https://git.ringcentral.com}"
PAGES_BASE_URL="$(printf "%s" "${NOVA_CLI_PAGES_BASE_URL:-http://copilot-platform.pages.git.ringcentral.com/platform-tools/nova-cli}" | sed 's#/*$##')"
PROJECT_PATH_ESCAPED="copilot-platform%2Fplatform-tools%2Fnova-cli"

CHANNEL="${NOVA_CLI_CHANNEL:-stable}"
VERSION="${NOVA_CLI_VERSION:-}"
ALPHA_REF="${NOVA_CLI_ALPHA_REF:-}"
JOB_ID="${NOVA_CLI_JOB_ID:-}"
PLATFORMS="linux_amd64 linux_arm64 darwin_amd64 darwin_arm64"
OUT_DIR="${SCRIPT_DIR}/dist"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel)   CHANNEL="$2"; shift 2 ;;
    --version)   VERSION="$2"; shift 2 ;;
    --alpha-ref) ALPHA_REF="$2"; shift 2 ;;
    --job-id)    JOB_ID="$2"; shift 2 ;;
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --out)       OUT_DIR="$2"; shift 2 ;;
    -h|--help)   awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "ERROR: tar is required" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

download() {
  url="$1"; output="$2"; use_token="${3:-true}"; required="${4:-true}"
  if [ "${use_token}" = "true" ] && [ -n "${GITLAB_TOKEN:-}" ]; then
    set -- -fsSL -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}"
  else
    set -- -fsSL
  fi
  if curl "$@" "${url}" -o "${output}"; then
    return 0
  fi
  [ "${required}" = "true" ] && { echo "ERROR: failed to download ${url}" >&2; exit 1; }
  return 1
}

gitlab_api_base="$(printf "%s" "${GITLAB_BASE_URL}" | sed 's#/*$##')/api/v4/projects/${PROJECT_PATH_ESCAPED}"

if [ -n "${JOB_ID}" ]; then
  base_url="${gitlab_api_base}/jobs/${JOB_ID}/artifacts/raw/dist"
  bin_base="${base_url}"
  source_label="job artifact ${JOB_ID}"
  use_gitlab_token=true
elif [ -z "${VERSION}" ] && [ "${CHANNEL}" = "stable" ]; then
  base_url="${PAGES_BASE_URL}/downloads"
  bin_base="${base_url}"
  source_label="latest stable from GitLab Pages"
  use_gitlab_token=false
else
  if [ -n "${VERSION}" ]; then
    release_id="${VERSION}"
  else
    case "${CHANNEL}" in
      beta) release_id="beta-latest" ;;
      alpha)
        [ -n "${ALPHA_REF}" ] || { echo "ERROR: --alpha-ref required for channel alpha" >&2; exit 1; }
        release_id="alpha-${ALPHA_REF}"
        ;;
      *) echo "ERROR: unsupported channel ${CHANNEL}" >&2; exit 1 ;;
    esac
  fi
  base_url="${gitlab_api_base}/releases/${release_id}/downloads"
  bin_base="${base_url}/bin"
  source_label="${CHANNEL} release ${release_id}"
  use_gitlab_token=true
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT INT TERM

echo "Source: ${source_label}"

download "${base_url}/checksums.txt" "${work}/upstream-checksums.txt" "${use_gitlab_token}"
bundle_version=""
if download "${base_url}/version.json" "${work}/version.json" "${use_gitlab_token}" false; then
  flat="$(tr -d ' \t\n' < "${work}/version.json")"
  for key in releaseTag buildVersion version; do
    bundle_version="$(printf '%s' "${flat}" | sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p")"
    [ -n "${bundle_version}" ] && break
  done
fi
[ -n "${bundle_version}" ] || bundle_version="${VERSION:-${CHANNEL}}"

pkg_name="nova-cli-${bundle_version}"
pkg="${work}/${pkg_name}"
mkdir -p "${pkg}/bin"

: > "${pkg}/checksums.txt"
for platform in ${PLATFORMS}; do
  asset="nova-cli_${platform}"
  echo "  fetching ${asset}"
  download "${bin_base}/${asset}" "${pkg}/bin/${asset}" "${use_gitlab_token}"

  expected="$(awk -v f="${asset}" '$2 == f || $2 == "*" f {print $1}' \
    "${work}/upstream-checksums.txt" | head -n 1)"
  [ -n "${expected}" ] || { echo "ERROR: upstream checksums.txt has no entry for ${asset}" >&2; exit 1; }

  actual="$(sha256_file "${pkg}/bin/${asset}")"
  if [ "${actual}" != "${expected}" ]; then
    echo "ERROR: checksum mismatch for ${asset}" >&2
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    exit 1
  fi

  chmod +x "${pkg}/bin/${asset}"
  printf '%s  %s\n' "${expected}" "${asset}" >> "${pkg}/checksums.txt"
done

cp "${SCRIPT_DIR}/install.sh" "${pkg}/install.sh"
chmod +x "${pkg}/install.sh"
[ -f "${SCRIPT_DIR}/README.md" ] && cp "${SCRIPT_DIR}/README.md" "${pkg}/README.md"
[ -f "${work}/version.json" ] && cp "${work}/version.json" "${pkg}/version.json"

mkdir -p "${OUT_DIR}"
tarball="${OUT_DIR}/${pkg_name}.tar.gz"
tar -C "${work}" -czf "${tarball}" "${pkg_name}"
printf '%s  %s\n' "$(sha256_file "${tarball}")" "${pkg_name}.tar.gz" > "${tarball}.sha256"

echo
echo "Built ${tarball}"
echo "      ${tarball}.sha256"
echo
echo "Distribute the tarball. Recipients run:"
echo "  tar -xzf ${pkg_name}.tar.gz && ./${pkg_name}/install.sh"
