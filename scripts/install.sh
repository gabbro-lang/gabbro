#!/bin/sh
# install.sh — install gabbro from an extracted release archive (Linux / macOS).
#
# Run from inside the extracted archive (this script sits next to bin/ and lib/):
#   ./install.sh                 # -> ~/.gab, adds bin to PATH via your shell rc
#   GABBRO_PREFIX=/opt/gabbro ./install.sh
#   GABBRO_NO_PATH=1 ./install.sh    # copy only, don't touch PATH
#
# gabbro finds its standard library + linker relative to the gabbro binary, so the whole
# install is just bin/ + lib/ kept together; GABBRO_HOME is set as a robust fallback.
set -eu

prefix="${GABBRO_PREFIX:-$HOME/.gab}"
src="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$src/bin/gabbro" ] && [ ! -f "$src/bin/gabbro" ]; then
    echo "error: run this from inside the extracted gabbro archive (no bin/gabbro next to install.sh)" >&2
    exit 1
fi

# 1. Copy the layout to $prefix (replacing any prior install).
echo "Installing gabbro -> $prefix"
rm -rf "$prefix/bin" "$prefix/lib"
mkdir -p "$prefix"
cp -R "$src/bin" "$prefix/bin"
cp -R "$src/lib" "$prefix/lib"
chmod +x "$prefix/bin/gabbro" 2>/dev/null || true
for m in LICENSE-APACHE-2.0.txt LICENSE-GPLv3.txt NOTICE README.md VERSION.txt; do
    [ -f "$src/$m" ] && cp "$src/$m" "$prefix/" || true
done

# 2. PATH + GABBRO_HOME via the shell rc (idempotent).
bin="$prefix/bin"
if [ "${GABBRO_NO_PATH:-0}" != "1" ]; then
    case "${SHELL:-/bin/sh}" in
        *zsh)  rc="$HOME/.zshrc" ;;
        *bash) rc="$HOME/.bashrc" ;;
        *)     rc="$HOME/.profile" ;;
    esac
    touch "$rc"
    if grep -q 'GABBRO_HOME=' "$rc" 2>/dev/null; then
        echo "PATH/GABBRO_HOME already configured in $rc"
    else
        {
            printf '\n# added by gabbro install.sh\n'
            printf 'export GABBRO_HOME="%s"\n' "$prefix"
            printf 'export PATH="%s:$PATH"\n' "$bin"
        } >> "$rc"
        echo "Added gabbro to PATH in $rc"
    fi
fi

ver=""
[ -f "$prefix/VERSION.txt" ] && ver="$(head -n1 "$prefix/VERSION.txt")"
echo ""
echo "gabbro $ver installed. Open a new terminal (or 'source' your shell rc), then:  gabbro version"
