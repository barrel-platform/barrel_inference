#!/bin/sh
# erllama_server installer. Detects OS + arch, picks the right
# release asset, untars it, symlinks `erllama_server` and `erllama`
# into the chosen bin dir.
#
# Usage:
#   curl -fsSL https://github.com/benoitc/erllama_server/releases/latest/download/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --variant cuda12
#   curl -fsSL .../install.sh | sh -s -- --prefix /opt --bindir /usr/local/bin
#   curl -fsSL .../install.sh | sh -s -- --version 0.1.0
#
# Environment variables (override the auto-detection):
#   ERLLAMA_PREFIX     install prefix    (default /usr/local)
#   ERLLAMA_BINDIR     symlink dir       (default $PREFIX/bin)
#   ERLLAMA_VARIANT    cpu | cuda12 | rocm   (default cpu)
#   ERLLAMA_VERSION    e.g. 0.1.0        (default: latest release)
#
# License: MIT. https://github.com/benoitc/erllama_server

set -eu

REPO="benoitc/erllama_server"
PREFIX="${ERLLAMA_PREFIX:-/usr/local}"
BINDIR="${ERLLAMA_BINDIR:-$PREFIX/bin}"
VARIANT="${ERLLAMA_VARIANT:-cpu}"
VERSION="${ERLLAMA_VERSION:-}"

# ---- Parse flags ----------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)   PREFIX="$2";  BINDIR="${ERLLAMA_BINDIR:-$PREFIX/bin}"; shift 2 ;;
    --bindir)   BINDIR="$2";  shift 2 ;;
    --variant)  VARIANT="$2"; shift 2 ;;
    --version)  VERSION="$2"; shift 2 ;;
    --help|-h)
      cat <<EOF
Usage: install.sh [--prefix DIR] [--bindir DIR] [--variant V] [--version VSN]

  --prefix   install prefix (default /usr/local)
  --bindir   directory for symlinks (default \$PREFIX/bin)
  --variant  cpu | cuda12 | rocm  (default cpu; darwin ignores)
  --version  release version e.g. 0.1.0 (default: latest)
EOF
      exit 0 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ---- OS + arch detection --------------------------------------------------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) printf 'unsupported arch: %s\n' "$ARCH_RAW" >&2; exit 1 ;;
esac

case "$OS" in
  darwin)
    EXT="tgz"
    case "$ARCH" in
      arm64)   PLATFORM=darwin-arm64 ;;
      amd64)   PLATFORM=darwin-x86_64 ;;
    esac
    [ "$VARIANT" != "cpu" ] && {
      printf 'note: macOS uses Metal natively; --variant %s ignored.\n' "$VARIANT" >&2
      VARIANT="cpu"
    }
    ;;
  linux)
    EXT="tar.zst"
    case "$VARIANT" in
      cpu)     SUFFIX="" ;;
      cuda12)  SUFFIX="-cuda12" ;;
      rocm)    SUFFIX="-rocm" ;;
      *) printf 'unknown variant: %s\n' "$VARIANT" >&2; exit 2 ;;
    esac
    [ "$ARCH" = "arm64" ] && [ -n "$SUFFIX" ] && {
      printf 'note: only CPU variant is published for linux-arm64\n' >&2
      SUFFIX=""
    }
    PLATFORM="linux-${ARCH}${SUFFIX}"
    ;;
  *) printf 'unsupported OS: %s\n' "$OS" >&2; exit 1 ;;
esac

# ---- Resolve version + URL ------------------------------------------------
if [ -z "$VERSION" ]; then
  printf '==> resolving latest release ... '
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
             | sed -n 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$VERSION" ] || { printf '\nfailed.\n' >&2; exit 1; }
  printf 'v%s\n' "$VERSION"
fi

ASSET="erllama_server-${VERSION}-${PLATFORM}.${EXT}"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${ASSET}"

# ---- Permissions check ----------------------------------------------------
if [ ! -w "$PREFIX" ] || [ ! -w "$BINDIR" ]; then
  SUDO="sudo"
  command -v sudo >/dev/null || {
    printf 'need write access to %s and %s; rerun as root.\n' "$PREFIX" "$BINDIR" >&2
    exit 1
  }
  printf '==> %s and %s are not writeable; will use sudo.\n' "$PREFIX" "$BINDIR"
else
  SUDO=""
fi

# ---- Download + unpack ----------------------------------------------------
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

printf '==> downloading %s\n' "$ASSET"
curl -fSL --progress-bar "$URL" -o "$TMPDIR/$ASSET"

printf '==> extracting to %s/erllama_server\n' "$PREFIX"
$SUDO mkdir -p "$PREFIX"
case "$EXT" in
  tgz)      $SUDO tar -C "$PREFIX" -xzf "$TMPDIR/$ASSET" ;;
  tar.zst)
    if command -v zstd >/dev/null; then
      $SUDO tar -C "$PREFIX" --use-compress-program=zstd -xf "$TMPDIR/$ASSET"
    else
      printf 'zstd not found; please install it (apt install zstd or brew install zstd).\n' >&2
      exit 1
    fi
    ;;
esac

# ---- Symlink + finish ----------------------------------------------------
printf '==> linking binaries into %s\n' "$BINDIR"
$SUDO mkdir -p "$BINDIR"
$SUDO ln -sf "$PREFIX/erllama_server/bin/erllama_server" "$BINDIR/erllama_server"
$SUDO ln -sf "$PREFIX/erllama_server/bin/erllama"        "$BINDIR/erllama"

cat <<EOF

  erllama_server v$VERSION installed.

    Start the daemon:   erllama_server daemon
    Verify:             curl http://127.0.0.1:8080/health
    CLI:                erllama help

  Docs: https://benoitc.github.io/erllama_server/
  Repo: https://github.com/$REPO

EOF
