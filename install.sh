#!/bin/sh

set -eu

REPO="${JSON_SERVER_REPO:-Mustafaamirzada/json-server}"
VERSION="${JSON_SERVER_VERSION:-latest}"
INSTALL_DIR="${JSON_SERVER_INSTALL_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
SKIP_CHECKSUM="${JSON_SERVER_SKIP_CHECKSUM:-0}"

print_usage() {
  cat <<'EOF'
Install json-server from a GitHub release.

Usage:
  install.sh [options]

Options:
  --version <tag>        Release tag to install (default: latest)
  --install-dir <dir>    Directory for the executable
                         (default: $XDG_BIN_HOME or ~/.local/bin)
  --repo <owner/repo>    GitHub repository (default: Mustafaamirzada/json-server)
  --no-verify            Skip SHA-256 checksum verification
  -h, --help             Show this help message

Environment:
  JSON_SERVER_VERSION, JSON_SERVER_INSTALL_DIR, JSON_SERVER_REPO,
  JSON_SERVER_SKIP_CHECKSUM

Examples:
  curl --proto '=https' --tlsv1.2 -sSfL \
    https://raw.githubusercontent.com/Mustafaamirzada/json-server/main/install.sh | sh

  curl --proto '=https' --tlsv1.2 -sSfL \
    https://raw.githubusercontent.com/Mustafaamirzada/json-server/main/install.sh \
    | sh -s -- --version v1.0.0 --install-dir /usr/local/bin
EOF
}

fail() {
  printf 'install.sh: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || fail "Missing value for --version."
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    --install-dir)
      [ "$#" -ge 2 ] || fail "Missing value for --install-dir."
      INSTALL_DIR="$2"
      shift 2
      ;;
    --install-dir=*)
      INSTALL_DIR="${1#*=}"
      shift
      ;;
    --repo)
      [ "$#" -ge 2 ] || fail "Missing value for --repo."
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#*=}"
      shift
      ;;
    --no-verify)
      SKIP_CHECKSUM=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[ -n "$REPO" ] || fail "Repository cannot be empty."
[ -n "$VERSION" ] || fail "Version cannot be empty."
[ -n "$INSTALL_DIR" ] || fail "Install directory cannot be empty."

if [ "$VERSION" != "latest" ]; then
  case "$VERSION" in
    v*)
      ;;
    *)
      VERSION="v${VERSION}"
      ;;
  esac
fi

case "$(uname -s)" in
  Linux)
    OS="linux"
    ;;
  Darwin)
    OS="macos"
    ;;
  *)
    fail "Unsupported operating system: $(uname -s). Use Linux or macOS."
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64)
    ARCH="x64"
    ;;
  arm64|aarch64)
    ARCH="arm64"
    ;;
  *)
    fail "Unsupported architecture: $(uname -m). Use x86_64 or arm64."
    ;;
esac

ASSET="json-server-${OS}-${ARCH}"

if [ -n "${JSON_SERVER_BASE_URL:-}" ]; then
  BASE_URL="$JSON_SERVER_BASE_URL"
elif [ "$VERSION" = "latest" ]; then
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi

BINARY_URL="${BASE_URL}/${ASSET}"
CHECKSUM_URL="${BASE_URL}/checksums.txt"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/json-server-install.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

download() {
  url="$1"
  destination="$2"

  if command -v curl >/dev/null 2>&1; then
    case "$url" in
      http://*)
        curl --proto '=https,http' -fsSL "$url" -o "$destination"
        ;;
      *)
        curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$destination"
        ;;
    esac
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    case "$url" in
      http://*)
        wget -q "$url" -O "$destination"
        ;;
      *)
        wget -q --https-only "$url" -O "$destination"
        ;;
    esac
    return
  fi

  fail "curl or wget is required to download json-server."
}

sha256_file() {
  file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | sed 's/^.* //'
    return
  fi

  fail "No SHA-256 tool found. Install sha256sum, shasum, or openssl."
}

printf 'Downloading %s\n' "$BINARY_URL"
download "$BINARY_URL" "$TMP_DIR/$ASSET" ||
  fail "Could not download $BINARY_URL."

if [ "$SKIP_CHECKSUM" != "1" ]; then
  if ! download "$CHECKSUM_URL" "$TMP_DIR/checksums.txt"; then
    fail "Could not download $CHECKSUM_URL. Re-run with --no-verify to skip checksum verification."
  fi

  EXPECTED=$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1; exit }' "$TMP_DIR/checksums.txt")
  [ -n "$EXPECTED" ] || fail "No checksum found for $ASSET."
  ACTUAL=$(sha256_file "$TMP_DIR/$ASSET")

  if [ "$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$ACTUAL" | tr '[:upper:]' '[:lower:]')" ]; then
    fail "Checksum verification failed for $ASSET."
  fi

  printf 'Verified checksum for %s\n' "$ASSET"
fi

mkdir -p "$INSTALL_DIR" || fail "Could not create $INSTALL_DIR."

if command -v install >/dev/null 2>&1; then
  install -m 0755 "$TMP_DIR/$ASSET" "$INSTALL_DIR/json-server"
else
  cp "$TMP_DIR/$ASSET" "$INSTALL_DIR/json-server"
  chmod 0755 "$INSTALL_DIR/json-server"
fi

if ! "$INSTALL_DIR/json-server" --help >/dev/null 2>&1; then
  fail "Installed json-server failed to run."
fi

printf '\nInstalled json-server to %s/json-server\n' "$INSTALL_DIR"

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    ;;
  *)
    printf '\nAdd %s to your PATH:\n' "$INSTALL_DIR"
    printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
    ;;
esac

printf '\nStart a server with:\n'
printf '  json-server db.json\n'
