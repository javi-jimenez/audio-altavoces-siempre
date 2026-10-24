#!/usr/bin/env bash
# Prueba de humo: valida el instalador sin tocar el sistema.
#   ./tests/smoke.sh
# No necesita root ni modifica nada (usa un directorio temporal).

set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
INST="$HERE/audio-altavoces-siempre.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
paso() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fallo() { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=1; }

echo "Prueba de humo — $(basename "$INST")"
echo ""

# 1. sintaxis del instalador
[ -x "$INST" ] || { fallo "no es ejecutable"; }
if bash -n "$INST" 2>"$TMP/e"; then paso "sintaxis del instalador"; else fallo "sintaxis: $(cat "$TMP/e")"; fi

# 2. ayuda
if "$INST" --help | grep -q 'audio-altavoces-siempre'; then paso "--help"; else fallo "--help"; fi

# 3. extracción de los scripts embebidos
if "$INST" --dump="$TMP/out" >/dev/null 2>&1; then paso "--dump"; else fallo "--dump"; fi

for s in audio-salida acp-speaker-always; do
    f="$TMP/out/$s"
    if [ ! -f "$f" ]; then fallo "no se extrajo $s"; continue; fi
    if bash -n "$f" 2>"$TMP/e"; then paso "sintaxis de $s"; else fallo "sintaxis de $s: $(cat "$TMP/e")"; fi
    if [ -x "$f" ]; then paso "$s es ejecutable"; else fallo "$s no es ejecutable"; fi
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck -S error -q "$f"; then paso "shellcheck $s"; else fallo "shellcheck $s"; fi
    fi
done

# 4. comprobaciones que solo leen (no requieren root)
if "$TMP/out/acp-speaker-always" --state >/dev/null 2>&1; then
    paso "acp-speaker-always --state"
else
    fallo "acp-speaker-always --state"
fi

# 5. el conmutador debe reconocer el hardware o avisar limpiamente
if out=$("$TMP/out/audio-salida" estado 2>&1); then
    paso "audio-salida estado"
    printf '%s\n' "$out" | sed 's/^/      /'
elif printf '%s' "$out" | grep -q 'no encuentro una tarjeta'; then
    paso "audio-salida estado (sin tarjeta analógica: correcto)"
else
    fallo "audio-salida estado: $out"
fi

echo ""
if [ "$fail" -eq 0 ]; then
    echo "Todo correcto."
else
    echo "Hay fallos." >&2
fi
exit "$fail"
