#!/usr/bin/env sh
# Standalone installer for nova-cli.
#
# Two modes, chosen automatically:
#   offline  - a binary for this OS/arch is bundled next to this script in ./bin
#   online   - download from GitLab Pages / Releases / job artifacts
#
# Usage: ./install.sh [options]
# Run ./install.sh --help for the full list.

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

GITLAB_BASE_URL="${NOVA_CLI_GITLAB_BASE_URL:-https://git.ringcentral.com}"
PAGES_BASE_URL="$(printf "%s" "${NOVA_CLI_PAGES_BASE_URL:-http://copilot-platform.pages.git.ringcentral.com/platform-tools/nova-cli}" | sed 's#/*$##')"
PROJECT_PATH_ESCAPED="copilot-platform%2Fplatform-tools%2Fnova-cli"
INSTALL_DIR="${NOVA_CLI_INSTALL_DIR:-${HOME}/.local/bin}"
BIN_NAME="${NOVA_CLI_BIN_NAME:-nova-cli}"
CHANNEL="${NOVA_CLI_CHANNEL:-stable}"
VERSION="${NOVA_CLI_VERSION:-}"
JOB_ID="${NOVA_CLI_JOB_ID:-}"
ALPHA_REF="${NOVA_CLI_ALPHA_REF:-}"
DRY_RUN="${NOVA_CLI_DRY_RUN:-false}"
FORCE_OFFLINE=false
FORCE_ONLINE=false

usage() {
  cat <<EOF
nova-cli installer

Usage: $0 [options]

Options:
  --install-dir DIR   Install into DIR            (default: ${HOME}/.local/bin)
  --bin-name NAME     Installed command name      (default: nova-cli)
  --channel CHANNEL   stable | beta | alpha       (default: stable)
  --version VERSION   Install an exact release (implies online)
  --alpha-ref REF     Required when --channel alpha
  --job-id ID         Install from a CI job artifact (implies online)
  --offline           Only use the bundled ./bin binaries; never download
  --online            Ignore bundled binaries; always download
  --dry-run           Print what would happen, change nothing
  --uninstall         Remove a previously installed binary
  -h, --help          Show this help

Equivalent environment variables:
  NOVA_CLI_INSTALL_DIR NOVA_CLI_BIN_NAME NOVA_CLI_CHANNEL NOVA_CLI_VERSION
  NOVA_CLI_ALPHA_REF NOVA_CLI_JOB_ID NOVA_CLI_DRY_RUN
  NOVA_CLI_GITLAB_BASE_URL NOVA_CLI_PAGES_BASE_URL
  GITLAB_TOKEN  (sent as PRIVATE-TOKEN for Release / job-artifact downloads)
EOF
}

need_value() {
  [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
}

do_uninstall=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-dir) need_value "$@"; INSTALL_DIR="$2"; shift 2 ;;
    --bin-name)    need_value "$@"; BIN_NAME="$2"; shift 2 ;;
    --channel)     need_value "$@"; CHANNEL="$2"; shift 2 ;;
    --version)     need_value "$@"; VERSION="$2"; shift 2 ;;
    --alpha-ref)   need_value "$@"; ALPHA_REF="$2"; shift 2 ;;
    --job-id)      need_value "$@"; JOB_ID="$2"; shift 2 ;;
    --offline)     FORCE_OFFLINE=true; shift ;;
    --online)      FORCE_ONLINE=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --uninstall)   do_uninstall=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "ERROR: unknown option $1 (try --help)" >&2; exit 2 ;;
  esac
done

detect_os() {
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    linux*) printf linux ;;
    darwin*) printf darwin ;;
    *) echo "ERROR: unsupported OS $(uname -s)" >&2; exit 1 ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf amd64 ;;
    arm64|aarch64) printf arm64 ;;
    *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "ERROR: need sha256sum or shasum to verify the download" >&2
    exit 1
  fi
}

verify_checksum() {
  # verify_checksum <binary> <checksums.txt> <asset name>
  expected="$(awk -v file="$3" '$2 == file || $2 == "*" file {print $1}' "$2" | head -n 1)"
  if [ -z "${expected}" ]; then
    echo "ERROR: $2 does not contain an entry for $3" >&2
    exit 1
  fi
  actual="$(sha256_file "$1")"
  if [ "${actual}" != "${expected}" ]; then
    echo "ERROR: checksum mismatch for $3" >&2
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    exit 1
  fi
}

install_binary() {
  # install_binary <source file> <source label>
  mkdir -p "${INSTALL_DIR}"
  chmod +x "$1"
  mv -f "$1" "${INSTALL_DIR}/${BIN_NAME}"
  echo "Installed ${BIN_NAME} from $2 to ${INSTALL_DIR}/${BIN_NAME}"
  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *) echo "NOTE: ${INSTALL_DIR} is not on PATH. Add: export PATH=\"${INSTALL_DIR}:\$PATH\"" ;;
  esac
  echo "Run: ${BIN_NAME} --version"
}

os_name="$(detect_os)"
arch_name="$(detect_arch)"
asset_name="nova-cli_${os_name}_${arch_name}"

if [ "${do_uninstall}" = "true" ]; then
  target="${INSTALL_DIR}/${BIN_NAME}"
  if [ ! -e "${target}" ]; then
    echo "Nothing to uninstall: ${target} does not exist"
    exit 0
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    echo "Would remove ${target}"
    exit 0
  fi
  rm -f "${target}"
  echo "Removed ${target}"
  exit 0
fi

# ---------------------------------------------------------------- offline ---

# Look for a payload next to this script, and also in an unpacked bundle below
# it, so running either copy of install.sh works.
bundled_binary=""
for root in "${SCRIPT_DIR}" "${SCRIPT_DIR}"/dist/nova-cli-*; do
  if [ -f "${root}/bin/${asset_name}" ]; then
    bundled_binary="${root}/bin/${asset_name}"
    bundled_root="${root}"
    break
  fi
done

if [ "${FORCE_ONLINE}" != "true" ] && [ -n "${bundled_binary}" ]; then
  bundled_checksums=""
  for candidate in "${bundled_root}/checksums.txt" "${bundled_root}/bin/checksums.txt"; do
    [ -f "${candidate}" ] && { bundled_checksums="${candidate}"; break; }
  done
  if [ -z "${bundled_checksums}" ]; then
    echo "ERROR: found ${bundled_binary} but no checksums.txt beside it or in ${bundled_root}" >&2
    exit 1
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    echo "Would install ${asset_name} from bundled package"
    echo "Source: ${bundled_binary}"
    echo "Target: ${INSTALL_DIR}/${BIN_NAME}"
    exit 0
  fi
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT INT TERM
  cp "${bundled_binary}" "${tmp_dir}/${asset_name}"
  verify_checksum "${tmp_dir}/${asset_name}" "${bundled_checksums}" "${asset_name}"
  install_binary "${tmp_dir}/${asset_name}" "bundled package"
  exit 0
fi

if [ "${FORCE_OFFLINE}" = "true" ]; then
  echo "ERROR: --offline requested but no ${asset_name} was found in this package" >&2
  echo "Searched: ${SCRIPT_DIR}/bin and ${SCRIPT_DIR}/dist/nova-cli-*/bin" >&2
  exit 1
fi

# ----------------------------------------------------------------- online ---

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required for online install" >&2; exit 1; }

download() {
  url="$1"; output="$2"; use_token="${3:-true}"
  if [ "${use_token}" = "true" ] && [ -n "${GITLAB_TOKEN:-}" ]; then
    curl -fsSL -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${url}" -o "${output}"
  else
    curl -fsSL "${url}" -o "${output}"
  fi
}

gitlab_api_base="$(printf "%s" "${GITLAB_BASE_URL}" | sed 's#/*$##')/api/v4/projects/${PROJECT_PATH_ESCAPED}"

if [ -n "${JOB_ID}" ]; then
  asset_url="${gitlab_api_base}/jobs/${JOB_ID}/artifacts/raw/dist/${asset_name}"
  checksums_url="${gitlab_api_base}/jobs/${JOB_ID}/artifacts/raw/dist/checksums.txt"
  version_url="${gitlab_api_base}/jobs/${JOB_ID}/artifacts/raw/dist/version.json"
  source_label="job artifact ${JOB_ID}"
  use_gitlab_token=true
elif [ -z "${VERSION}" ] && [ "${CHANNEL}" = "stable" ]; then
  asset_url="${PAGES_BASE_URL}/downloads/${asset_name}"
  checksums_url="${PAGES_BASE_URL}/downloads/checksums.txt"
  version_url="${PAGES_BASE_URL}/downloads/version.json"
  source_label="latest stable from GitLab Pages"
  use_gitlab_token=false
else
  if [ -n "${VERSION}" ]; then
    release_id="${VERSION}"
  else
    case "${CHANNEL}" in
      beta)
        release_id="beta-latest"
        ;;
      alpha)
        if [ -z "${ALPHA_REF}" ]; then
          echo "ERROR: --alpha-ref (NOVA_CLI_ALPHA_REF) is required when channel=alpha" >&2
          exit 1
        fi
        release_id="alpha-${ALPHA_REF}"
        ;;
      *)
        echo "ERROR: unsupported channel ${CHANNEL}" >&2
        exit 1
        ;;
    esac
  fi
  asset_url="${gitlab_api_base}/releases/${release_id}/downloads/bin/${asset_name}"
  checksums_url="${gitlab_api_base}/releases/${release_id}/downloads/checksums.txt"
  version_url="${gitlab_api_base}/releases/${release_id}/downloads/version.json"
  source_label="${CHANNEL} release ${release_id}"
  use_gitlab_token=true
fi

if [ "${DRY_RUN}" = "true" ]; then
  echo "Would install ${asset_name} from ${source_label}"
  echo "Binary URL:   ${asset_url}"
  echo "Checksum URL: ${checksums_url}"
  echo "Version URL:  ${version_url}"
  echo "Target:       ${INSTALL_DIR}/${BIN_NAME}"
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT INT TERM

binary_path="${tmp_dir}/${asset_name}"
checksums_path="${tmp_dir}/checksums.txt"

download "${asset_url}" "${binary_path}" "${use_gitlab_token}"
download "${checksums_url}" "${checksums_path}" "${use_gitlab_token}"

verify_checksum "${binary_path}" "${checksums_path}" "${asset_name}"
install_binary "${binary_path}" "${source_label}"
