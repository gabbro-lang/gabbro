#!/bin/sh
# install.sh — install skarn from an extracted release archive (Linux / macOS).
#
# Run from inside the extracted archive (this script sits next to bin/ and lib/):
#   ./install.sh                 # -> ~/.sk, adds bin to PATH via your shell rc
#   SKARN_PREFIX=/opt/skarn ./install.sh
#   SKARN_NO_PATH=1 ./install.sh    # copy only, don't touch PATH
#
# skarn finds its standard library + linker relative to the skarn binary, so the whole
# install is just bin/ + lib/ kept together; SKARN_HOME is set as a robust fallback.
set -eu

prefix="${SKARN_PREFIX:-$HOME/.sk}"
src="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "$src/bin/skarn" ] && [ ! -f "$src/bin/skarn" ]; then
    echo "error: run this from inside the extracted skarn archive (no bin/skarn next to install.sh)" >&2
    exit 1
fi

# 1. Copy the layout to $prefix (replacing any prior install).
echo "Installing skarn -> $prefix"
rm -rf "$prefix/bin" "$prefix/lib"
mkdir -p "$prefix"
cp -R "$src/bin" "$prefix/bin"
cp -R "$src/lib" "$prefix/lib"
chmod +x "$prefix/bin/skarn" 2>/dev/null || true
for m in LICENSE-APACHE-2.0.txt LICENSE-GPLv3.txt NOTICE README.md VERSION.txt; do
    [ -f "$src/$m" ] && cp "$src/$m" "$prefix/" || true
done

# 2. PATH + SKARN_HOME via the shell rc (idempotent).
bin="$prefix/bin"
if [ "${SKARN_NO_PATH:-0}" != "1" ]; then
    case "${SHELL:-/bin/sh}" in
        *zsh)  rc="$HOME/.zshrc" ;;
        *bash) rc="$HOME/.bashrc" ;;
        *)     rc="$HOME/.profile" ;;
    esac
    touch "$rc"
    if grep -q 'SKARN_HOME=' "$rc" 2>/dev/null; then
        echo "PATH/SKARN_HOME already configured in $rc"
    else
        {
            printf '\n# added by skarn install.sh\n'
            printf 'export SKARN_HOME="%s"\n' "$prefix"
            printf 'export PATH="%s:$PATH"\n' "$bin"
        } >> "$rc"
        echo "Added skarn to PATH in $rc"
    fi
fi

ver=""
[ -f "$prefix/VERSION.txt" ] && ver="$(head -n1 "$prefix/VERSION.txt")"
echo ""
echo "skarn $ver installed. Open a new terminal (or 'source' your shell rc), then:  skarn version"
