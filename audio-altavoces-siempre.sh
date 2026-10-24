#!/usr/bin/env bash
# =============================================================================
#  audio-altavoces-siempre.sh                                          v1.0
# =============================================================================
#  Deja SIEMPRE seleccionables las dos salidas analógicas del portátil
#  (altavoces y auriculares), aunque el jack esté ocupado, y cambia solo
#  a auriculares al enchufarlos.
#
#  QUÉ PROBLEMA RESUELVE
#    ACP (el backend de audio de PipeWire/PulseAudio) define las rutas en
#    ficheros .conf. La ruta de altavoces suele declarar:
#
#        [Jack Headphone]
#        state.plugged = no
#
#    Es decir: "si hay auriculares enchufados, este puerto no está
#    disponible". Consecuencia: el puerto de altavoces pasa a "not available"
#    y desaparece (o se pone en gris) en los mezcladores. El plugin de sonido
#    de Xfce, además, sólo muestra el submenú "Port" si hay ≥2 puertos
#    disponibles, así que ni siquiera se puede elegir.
#
#  QUÉ HACE
#    1. Parchea esos .conf (state.plugged = no  →  unknown) y guarda el
#       original como *.distrib. Detección automática de la carpeta de rutas.
#    2. Instala /usr/local/bin/acp-speaker-always  (aplicar / --check / --revert)
#    3. Instala un .path + .service de systemd que reaplica el parche cuando
#       una actualización de pipewire/pulseaudio sobrescribe el fichero
#       (en Debian/Ubuntu además un hook de dpkg, como refuerzo).
#    4. Instala /usr/local/bin/audio-salida  (conmutar altavoces/auriculares)
#    5. Instala el servicio de usuario audio-jack.service, que vigila el jack
#       del kernel y cambia de salida al enchufar/desenchufar.
#    6. Instala entradas de menú (Salida de audio / altavoces / auriculares).
#
#  USO
#    sudo ./audio-altavoces-siempre.sh              instala (o repara)
#    sudo ./audio-altavoces-siempre.sh --check      estado, sin tocar nada
#    sudo ./audio-altavoces-siempre.sh --uninstall  desinstala y revierte
#    sudo ./audio-altavoces-siempre.sh --conservador   parchea sólo altavoces
#    ./audio-altavoces-siempre.sh --dump=DIR        extrae los scripts (sin sudo)
#
#  TRAS INSTALAR (como usuario normal, no root):
#    systemctl --user daemon-reload
#    systemctl --user enable --now audio-jack.service
#    audio-salida estado
#
#  NOTA: el parche hace que ACP deje de distinguir enchufado/desenchufado
#  (fuerza "unknown" en ambos puertos porque comparten jack). Por eso el
#  cambio automático lo hace audio-jack.service leyendo el control ALSA del
#  kernel 'Headphone Jack', no PipeWire.
# =============================================================================

set -uo pipefail

VERSION="1.0"
BIN=/usr/local/bin
USER_UNIT_DIR=/etc/systemd/user
SYS_UNIT_DIR=/etc/systemd/system
APP_DIR=/usr/share/applications
DPKG_DIR=/etc/dpkg/dpkg.cfg.d
MARKER=/run/acp-speaker-always.needed

MODE=install
CONSERVADOR=0
DUMP_DIR=

# ----------------------------------------------------------------- argumentos
for a in "$@"; do
    case "$a" in
        --install|install)        MODE=install ;;
        --uninstall|uninstall)    MODE=uninstall ;;
        --check|check|--status)   MODE=check ;;
        --conservador|--conservative) CONSERVADOR=1 ;;
        --dump=*)                 MODE=dump; DUMP_DIR=${a#--dump=} ;;
        -h|--help|help) sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "opción no reconocida: $a (usa --help)" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

# ------------------------------------------------------------------- helpers
detect_paths_dir() {
    local d
    for d in \
        /usr/share/alsa-card-profile/mixer/paths \
        /usr/share/pulseaudio/alsa-mixer/paths \
        /usr/share/alsa/alsa-card-profile/mixer/paths
    do
        [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
    done
    return 1
}

# ¿el fichero declara "con auriculares puestos, yo no estoy disponible"?
has_headphone_mute() {
    awk '
        /^\[[[:space:]]*Jack[^]]*Headphone[^]]*\][[:space:]]*$/ { f = 1; next }
        /^\[/ { f = 0 }
        f && /^[[:space:]]*state\.plugged[[:space:]]*=[[:space:]]*no[[:space:]]*$/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$1" 2>/dev/null
}

targets() {   # lista de .conf a parchear
    local dir="$1" f
    if [ "$CONSERVADOR" -eq 1 ]; then
        [ -f "$dir/analog-output-speaker.conf" ] && printf '%s\n' "$dir/analog-output-speaker.conf"
        return 0
    fi
    for f in "$dir"/analog-output-*.conf; do
        [ -f "$f" ] || continue
        has_headphone_mute "$f" && printf '%s\n' "$f"
    done
}

as_user() {   # ejecuta algo como el usuario que invocó sudo
    local u="${SUDO_USER:-}" uid
    [ -n "$u" ] && [ "$u" != root ] || return 1
    uid=$(id -u "$u" 2>/dev/null) || return 1
    runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@" 2>/dev/null
}

# =============================================================================
#  audio-salida  (conmutador; detección en tiempo de ejecución)
# =============================================================================
read -r -d '' AUDIO_SALIDA <<'EOS' || true
#!/usr/bin/env bash
# audio-salida - conmuta la salida analógica altavoces / auriculares
#   audio-salida [menu|altavoces|auriculares|toggle|estado|watch]
# Detecta tarjeta, sink y puertos en tiempo de ejecución (sin nombres fijos).
set -uo pipefail

CARD=""; SINK=""; PORT_SPK=""; PORT_HP=""; ALSA_CARD=""

detectar() {
    local info
    info=$(pactl -f json list cards 2>/dev/null | python3 -c '
import json, sys
try:
    cards = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for c in cards:
    ports = c.get("ports") or {}
    spk = hp = None
    for n, p in ports.items():
        t = (p.get("properties") or {}).get("port.type") or ""
        if t == "speaker" and not spk:
            spk = n
        elif t == "headphones" and not hp:
            hp = n
    if spk and hp:
        print(c.get("name",""), spk, hp, (c.get("properties") or {}).get("api.alsa.card",""))
        break
') || return 1
    [ -n "$info" ] || return 1
    # shellcheck disable=SC2086
    set -- $info
    CARD=${1:-}; PORT_SPK=${2:-}; PORT_HP=${3:-}; ALSA_CARD=${4:-}
    [ -n "$CARD" ] && [ -n "$PORT_SPK" ] && [ -n "$PORT_HP" ] || return 1

    local base=${CARD#alsa_card.}
    SINK="alsa_output.$base.analog-stereo"
    if ! pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$SINK"; then
        SINK=$(pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -m1 "^alsa_output\.$base") || true
    fi
    [ -n "$SINK" ] || return 1

    if [ -z "$ALSA_CARD" ]; then
        ALSA_CARD=$(pactl list cards 2>/dev/null | awk -v c="$CARD" '
            $1=="Name:" { n=$2 } n==c && $1=="api.alsa.card" { gsub(/"/,"",$2); print $2; exit }')
    fi
    [ -n "$ALSA_CARD" ] || ALSA_CARD=0
}

alsa_dev() { printf 'hw:%s' "$ALSA_CARD"; }

jack_control() {
    amixer -D "$(alsa_dev)" contents 2>/dev/null |
        grep -oE "iface=CARD,name='[^']*Headphone Jack'" |
        head -1 | sed "s/.*name='//; s/'$//"
}

# 0=enchufado 1=libre 2=no se puede saber
jack_plugged() {
    local ctl v
    ctl=$(jack_control) || return 2
    [ -n "$ctl" ] || return 2
    v=$(amixer -D "$(alsa_dev)" contents 2>/dev/null |
        grep -F -A2 "name='$ctl'" | grep -m1 -oE 'values=[a-z,]+') || true
    case "$v" in
        values=on*)  return 0 ;;
        values=off*) return 1 ;;
        *)           return 2 ;;
    esac
}

port_availability() {
    pactl -f json list cards 2>/dev/null | python3 -c '
import json, sys
card, port = sys.argv[1], sys.argv[2]
try:
    cards = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for c in cards:
    if c.get("name") != card:
        continue
    p = (c.get("ports") or {}).get(port)
    if p:
        a = (p.get("availability") or "").lower()
        print("yes" if a == "available" else "no" if "not available" in a else "unknown")
' "$CARD" "$1"
}

active_port() {
    pactl list sinks 2>/dev/null | awk -v s="$SINK" '
        $1 == "Name:" { n = $2 }
        n == s && $1 == "Active" && $2 == "Port:" { print $3; exit }'
}

set_port() { pactl set-sink-port "$SINK" "$1" >/dev/null 2>&1; }

notify() {
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a "Salida de audio" -i "$1" -t 1800 "Salida de audio" "$2" 2>/dev/null
}

nombre_port() {
    case "$1" in
        "$PORT_SPK") echo "altavoces" ;;
        "$PORT_HP")  echo "auriculares" ;;
        *)           echo "${1:-desconocido}" ;;
    esac
}

aplicar_segun_jack() {
    case "$(jack_plugged; echo $?)" in
        0)
            [ "$(active_port)" = "$PORT_HP" ] || { set_port "$PORT_HP"; notify audio-headphones "Auriculares"; }
            ;;
        1)
            [ "$(active_port)" = "$PORT_SPK" ] || { set_port "$PORT_SPK"; notify audio-speakers "Altavoces"; }
            ;;
    esac
}

detectar || { echo "audio-salida: no encuentro una tarjeta con altavoces y auriculares" >&2; exit 1; }

case "${1:-menu}" in
    altavoces|altavoz|speakers|speaker)
        set_port "$PORT_SPK"; notify audio-speakers "Altavoces" ;;
    auriculares|auricular|headphones|headphone)
        set_port "$PORT_HP"; notify audio-headphones "Auriculares" ;;
    toggle)
        if [ "$(active_port)" = "$PORT_HP" ]; then
            set_port "$PORT_SPK"; notify audio-speakers "Altavoces"
        else
            set_port "$PORT_HP"; notify audio-headphones "Auriculares"
        fi ;;
    estado|status)
        case "$(jack_plugged; echo $?)" in
            0) j="auriculares ENCHUFADOS" ;;
            1) j="libre (nada puesto)" ;;
            *) j="desconocido (sin control de jack)" ;;
        esac
        printf 'Tarjeta       : %s\n' "$CARD"
        printf 'Sink          : %s\n' "$SINK"
        printf 'Jack (ALSA)   : %s\n' "$j"
        printf 'Puerto activo : %s (%s)\n' "$(active_port)" "$(nombre_port "$(active_port)")"
        printf 'Disp.altavoz  : %s\n' "$(port_availability "$PORT_SPK")"
        printf 'Disp.auric.   : %s\n' "$(port_availability "$PORT_HP")"
        if command -v acp-speaker-always >/dev/null 2>&1; then
            printf 'Parche ACP    : %s\n' "$(acp-speaker-always --state 2>/dev/null || echo '?')"
        fi
        printf 'Servicio      : %s\n' "$(systemctl --user is-active audio-jack.service 2>/dev/null)"
        ;;
    watch)
        # Sólo actúa en TRANSICIONES: la elección manual se respeta.
        last=""
        case "$(jack_plugged; echo $?)" in
            0) last=on ;; 1) last=off ;;
        esac
        aplicar_segun_jack
        marca_vista=""
        while sleep 1; do
            # El parche de ACP reaplicado (tras actualizar pipewire) deja marca:
            # hay que reiniciar WirePlumber para que relea las rutas.
            if [ -e /run/acp-speaker-always.needed ]; then
                m=$(stat -c %Y /run/acp-speaker-always.needed 2>/dev/null || echo 0)
                if [ "$m" != "$marca_vista" ]; then
                    marca_vista=$m
                    systemctl --user restart wireplumber.service 2>/dev/null || \
                        systemctl --user restart pipewire.service 2>/dev/null
                    sleep 2
                    detectar || true
                    case "$(jack_plugged; echo $?)" in
                        0) last=on ;; 1) last=off ;;
                    esac
                    aplicar_segun_jack
                fi
            fi
            case "$(jack_plugged; echo $?)" in
                0) ahora=on ;; 1) ahora=off ;; *) ahora=desconocido ;;
            esac
            [ "$ahora" = desconocido ] && continue
            [ "$ahora" = "$last" ] && continue
            sleep 0.3
            case "$(jack_plugged; echo $?)" in
                0) ahora=on ;; 1) ahora=off ;; *) ahora=desconocido ;;
            esac
            [ "$ahora" = desconocido ] && continue
            [ "$ahora" = "$last" ] && continue
            last=$ahora
            detectar || true
            aplicar_segun_jack
        done ;;
    menu|"")
        sel=$(zenity --list --title="Salida de audio" \
            --text="Puerto activo: <b>$(nombre_port "$(active_port)")</b>" \
            --column="Salida" --column="puerto" --hide-column=2 --print-column=2 \
            --width=340 --height=210 \
            "Altavoces" "$PORT_SPK" "Auriculares" "$PORT_HP" 2>/dev/null) || exit 0
        [ -n "$sel" ] || exit 0
        set_port "$sel"
        notify "$([ "$sel" = "$PORT_HP" ] && echo audio-headphones || echo audio-speakers)" "$(nombre_port "$sel")" ;;
    -h|--help|help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "uso: $(basename "$0") [menu|altavoces|auriculares|toggle|estado|watch]" >&2; exit 2 ;;
esac
EOS

# =============================================================================
#  acp-speaker-always  (parche de rutas de ACP)
# =============================================================================
read -r -d '' ACP_PATCH <<'EOS' || true
#!/usr/bin/env bash
# acp-speaker-always - los puertos de salida no se ocultan al enchufar auriculares
#   acp-speaker-always            aplica (idempotente)
#   acp-speaker-always --check    estado detallado
#   acp-speaker-always --state    resumen de una línea
#   acp-speaker-always --revert   restaura los originales
#   acp-speaker-always --quiet    modo automático (systemd/dpkg)
set -uo pipefail

MARKER=/run/acp-speaker-always.needed
QUIET=0
ACTION=apply
for a in "$@"; do
    case "$a" in
        --quiet|-q)  QUIET=1 ;;
        --check|-c)  ACTION=check ;;
        --state)     ACTION=state ;;
        --revert|-r) ACTION=revert ;;
        *) : ;;
    esac
done

say()  { [ "$QUIET" -eq 1 ] || echo "$@"; }
diag() { [ "$QUIET" -eq 1 ] && command -v logger >/dev/null 2>&1 && logger -t acp-speaker-always "$*"; return 0; }

paths_dir() {
    local d
    for d in /usr/share/alsa-card-profile/mixer/paths \
             /usr/share/pulseaudio/alsa-mixer/paths \
             /usr/share/alsa/alsa-card-profile/mixer/paths; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

DIR=$(paths_dir) || { say "no encuentro la carpeta de rutas de ACP"; exit 1; }

# ficheros que dicen "con auriculares puestos, no estoy disponible"
has_mute() {
    awk '
        /^\[[[:space:]]*Jack[^]]*Headphone[^]]*\][[:space:]]*$/ { f = 1; next }
        /^\[/ { f = 0 }
        f && /^[[:space:]]*state\.plugged[[:space:]]*=[[:space:]]*no[[:space:]]*$/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$1" 2>/dev/null
}

list_targets() {
    local f
    for f in "$DIR"/analog-output-*.conf; do
        [ -f "$f" ] && has_mute "$f" && echo "$f"
    done
}

case "$ACTION" in
    state)
        n=$(list_targets | wc -l)
        if [ "$n" -eq 0 ]; then echo "aplicado"; else echo "SIN aplicar ($n ficheros)"; fi
        exit 0 ;;
    check)
        echo "carpeta: $DIR"
        pend=$(list_targets)
        if [ -z "$pend" ]; then
            echo "resultado: ✅ parcheado — ambas salidas siempre seleccionables"
            for f in "$DIR"/analog-output-*.conf.distrib; do
                [ -f "$f" ] && echo "   original: $f"
            done
            exit 0
        fi
        echo "resultado: ⚠️  SIN parchear — los altavoces se ocultarán con auriculares puestos"
        echo "$pend" | sed 's/^/   pendiente: /'
        exit 1 ;;
    revert)
        n=0
        for f in "$DIR"/analog-output-*.conf; do
            [ -f "$f.distrib" ] || continue
            cp -f "$f.distrib" "$f" && n=$((n + 1))
        done
        if [ "$n" -gt 0 ]; then
            touch "$MARKER" 2>/dev/null
            say "revertidos $n ficheros (reinicia wireplumber para aplicarlo)"
            diag "revertidos $n ficheros"
        else
            say "nada que revertir (no hay ficheros .distrib)"
        fi
        exit 0 ;;
esac

# --------------------------------------------------------------- aplicar
files=$(list_targets)
if [ -z "$files" ]; then
    say "ya estaba parcheado, sin cambios"
    exit 0
fi

changed=0
for f in $files; do
    [ -f "$f.distrib" ] || cp -n "$f" "$f.distrib" 2>/dev/null || true
    n=$(python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
try:
    lines = open(p).readlines()
except OSError:
    print(0); sys.exit(0)
out, cur, n = [], None, 0
for line in lines:
    m = re.match(r'^\[(.+)\]\s*$', line)
    if m:
        cur = m.group(1)
    if cur and 'Headphone' in cur and cur.startswith('Jack') \
       and re.match(r'^state\.plugged\s*=\s*no\s*$', line):
        line = 'state.plugged = unknown\n'
        n += 1
    out.append(line)
if n:
    open(p, 'w').writelines(out)
print(n)
PY
) || n=0
    [ "${n:-0}" -gt 0 ] 2>/dev/null && { say "parcheado: $f ($n)"; changed=$((changed + n)); }
done

if [ "$changed" -gt 0 ]; then
    touch "$MARKER" 2>/dev/null
    say "total: $changed líneas. Aplicar con: systemctl --user restart wireplumber.service"
    diag "parcheadas $changed líneas"
fi
exit 0
EOS

# =============================================================================
#  Unidades de systemd y lanzadores
# =============================================================================
user_unit() {
cat <<'EOF'
[Unit]
Description=Vigila el jack de auriculares y conmuta la salida de audio
Documentation=file:/usr/local/bin/audio-salida
After=pipewire.service wireplumber.service pipewire-pulse.service
Wants=pipewire.service wireplumber.service

[Service]
Type=simple
ExecStart=/usr/local/bin/audio-salida watch
Restart=always
RestartSec=3
StandardOutput=null

[Install]
WantedBy=default.target
EOF
}

sys_service() {
cat <<'EOF'
[Unit]
Description=Reaplica el parche de rutas de ACP (salidas siempre seleccionables)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/acp-speaker-always --quiet
EOF
}

desktop_entry() {  # $1=nombre  $2=comentario  $3=exec  $4=icono
cat <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$1
Comment=$2
Exec=$3
Icon=$4
Terminal=false
Categories=AudioVideo;Audio;Settings;
EOF
}

# =============================================================================
#  Acciones
# =============================================================================

# -------------------------------------------------------------------- --dump
# Extrae los dos scripts auxiliares sin instalar nada (para revisarlos o
# empaquetarlos). No necesita root.
if [ "$MODE" = dump ]; then
    [ -n "$DUMP_DIR" ] || { err "uso: --dump=DIRECTORIO"; exit 2; }
    mkdir -p "$DUMP_DIR" || { err "no puedo crear $DUMP_DIR"; exit 1; }
    printf '%s\n' "$AUDIO_SALIDA"     > "$DUMP_DIR/audio-salida"
    printf '%s\n' "$ACP_PATCH"        > "$DUMP_DIR/acp-speaker-always"
    chmod 0755 "$DUMP_DIR/audio-salida" "$DUMP_DIR/acp-speaker-always"
    ok "$DUMP_DIR/audio-salida"
    ok "$DUMP_DIR/acp-speaker-always"
    say ""
    say "Para revisar:  bash -n $DUMP_DIR/audio-salida && shellcheck $DUMP_DIR/audio-salida"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- "$0" "$@"
    fi
    err "hay que ejecutarlo como root"
    exit 1
fi

PATHS_DIR=$(detect_paths_dir) || {
    err "no encuentro la carpeta de rutas de ACP."
    warn "¿está instalado pipewire o pulseaudio?"
    exit 1
}

# ---------------------------------------------------------------- --check
if [ "$MODE" = check ]; then
    say "audio-altavoces-siempre $VERSION — estado"
    say ""
    say "Carpeta de rutas ACP : $PATHS_DIR"
    pend=$(targets "$PATHS_DIR")
    if [ -z "$pend" ]; then
        ok "parche aplicado (todas las salidas siempre seleccionables)"
    else
        warn "parche PENDIENTE en:"
        say "$pend" | sed 's/^/      /'
    fi
    for f in "$BIN/audio-salida" "$BIN/acp-speaker-always" \
             "$USER_UNIT_DIR/audio-jack.service" "$SYS_UNIT_DIR/acp-speaker-always.path"; do
        [ -e "$f" ] && ok "$f" || warn "falta $f"
    done
    say ""
    say "Puertos ahora mismo:"
    if command -v pactl >/dev/null 2>&1; then
        # como root no hay sesión de audio: consultar como el usuario que invocó sudo
        json=$(as_user pactl -f json list cards 2>/dev/null)
        [ -n "$json" ] || json=$(pactl -f json list cards 2>/dev/null)
        if [ -n "$json" ]; then
            printf '%s' "$json" | python3 -c '
import json, sys
try:
    for c in json.load(sys.stdin):
        out = {n: p for n, p in (c.get("ports") or {}).items()
               if (p.get("properties") or {}).get("port.type") in ("speaker", "headphones")}
        if not out:
            continue
        print("   " + c.get("name", ""))
        for n, p in sorted(out.items()):
            print("      %-28s %s" % (n, p.get("availability")))
except Exception:
    pass'
        else
            warn "no se pudo consultar el servidor de audio"
            say "      ejecuta como usuario:  audio-salida estado"
        fi
    else
        warn "pactl no disponible"
    fi
    say ""
    say "Servicio de usuario:"
    if as_user systemctl --user is-enabled audio-jack.service >/dev/null 2>&1; then
        ok "audio-jack.service habilitado"
    else
        warn "audio-jack.service NO habilitado para ${SUDO_USER:-<usuario>}"
        say "      systemctl --user enable --now audio-jack.service"
    fi
    exit 0
fi

# ------------------------------------------------------------ --uninstall
if [ "$MODE" = uninstall ]; then
    say "Desinstalando audio-altavoces-siempre $VERSION"
    as_user systemctl --user disable --now audio-jack.service >/dev/null 2>&1 || true
    systemctl disable --now acp-speaker-always.path >/dev/null 2>&1 || true
    rm -f "$SYS_UNIT_DIR/acp-speaker-always.path" "$SYS_UNIT_DIR/acp-speaker-always.service"
    rm -f "$USER_UNIT_DIR/audio-jack.service"
    rm -f "$BIN/audio-salida" "$BIN/acp-speaker-always"
    rm -f "$APP_DIR"/audio-salida.desktop "$APP_DIR"/audio-altavoces.desktop "$APP_DIR"/audio-auriculares.desktop
    rm -f "$DPKG_DIR/99-acp-speaker-always"
    "$BIN/acp-speaker-always" --revert 2>/dev/null || true
    systemctl daemon-reload
    as_user systemctl --user daemon-reload >/dev/null 2>&1 || true
    ok "desinstalado"
    warn "los ficheros *.conf.distrib se conservan (no molestan)"
    warn "reinicia el audio:  systemctl --user restart wireplumber.service"
    exit 0
fi

# --------------------------------------------------------------- instalar
say "Instalando audio-altavoces-siempre $VERSION"
say ""

for cmd in pactl amixer python3; do
    command -v "$cmd" >/dev/null 2>&1 || warn "no encuentro '$cmd' (puede hacer falta)"
done

# 1) scripts
install -m 0755 /dev/stdin "$BIN/audio-salida"      <<<"$AUDIO_SALIDA"
install -m 0755 /dev/stdin "$BIN/acp-speaker-always" <<<"$ACP_PATCH"
ok "$BIN/audio-salida"
ok "$BIN/acp-speaker-always"

# 2) parche de rutas
say ""
say "Parcheando rutas de ACP en $PATHS_DIR"
if [ "$CONSERVADOR" -eq 1 ]; then
    warn "modo conservador: sólo analog-output-speaker.conf"
    f="$PATHS_DIR/analog-output-speaker.conf"
    [ -f "$f" ] && has_headphone_mute "$f" && "$BIN/acp-speaker-always" --quiet
else
    "$BIN/acp-speaker-always" --quiet
fi
"$BIN/acp-speaker-always" --check | sed 's/^/    /'

# 3) unidades de systemd
say ""
mkdir -p "$USER_UNIT_DIR" "$SYS_UNIT_DIR"
user_unit > "$USER_UNIT_DIR/audio-jack.service"
chmod 0644 "$USER_UNIT_DIR/audio-jack.service"
ok "$USER_UNIT_DIR/audio-jack.service"

sys_service > "$SYS_UNIT_DIR/acp-speaker-always.service"
chmod 0644 "$SYS_UNIT_DIR/acp-speaker-always.service"

cat > "$SYS_UNIT_DIR/acp-speaker-always.path" <<EOF
[Unit]
Description=Vigila las rutas de ACP (las actualizaciones las sobrescriben)

[Path]
PathModified=$PATHS_DIR
Unit=acp-speaker-always.service

[Install]
WantedBy=paths.target
EOF
chmod 0644 "$SYS_UNIT_DIR/acp-speaker-always.path"
ok "$SYS_UNIT_DIR/acp-speaker-always.{service,path}"

# 4) refuerzo en Debian/Ubuntu
if [ -d "$DPKG_DIR" ]; then
    cat > "$DPKG_DIR/99-acp-speaker-always" <<'EOF'
# Reaplica el parche de rutas de ACP tras cada instalación/actualización:
# una actualización de pipewire sobrescribe analog-output-speaker.conf y los
# altavoces vuelven a ocultarse al enchufar auriculares.
# El script es idempotente: si ya está bien, no hace nada.
#   Comprobar: acp-speaker-always --check
#   Deshacer : acp-speaker-always --revert  + borrar este fichero
post-invoke "/usr/local/bin/acp-speaker-always --quiet"
EOF
    chmod 0644 "$DPKG_DIR/99-acp-speaker-always"
    ok "$DPKG_DIR/99-acp-speaker-always"
else
    warn "sin dpkg: la reaplicación depende del .path de systemd"
fi

# 5) lanzadores
desktop_entry "Salida de audio (altavoces / auriculares)" \
    "Elige la salida analógica aunque el jack esté ocupado" \
    "$BIN/audio-salida menu" audio-speakers > "$APP_DIR/audio-salida.desktop"
desktop_entry "Salida: altavoces" "Fuerza la salida por los altavoces" \
    "$BIN/audio-salida altavoces" audio-speakers > "$APP_DIR/audio-altavoces.desktop"
desktop_entry "Salida: auriculares" "Fuerza la salida por los auriculares" \
    "$BIN/audio-salida auriculares" audio-headphones > "$APP_DIR/audio-auriculares.desktop"
chmod 0644 "$APP_DIR"/audio-*.desktop
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" 2>/dev/null
ok "entradas de menú en $APP_DIR"

# 6) activar
say ""
systemctl daemon-reload
systemctl enable --now acp-speaker-always.path >/dev/null 2>&1 && ok "vigilancia de systemd activa"

if as_user systemctl --user daemon-reload >/dev/null 2>&1; then
    if as_user systemctl --user enable --now audio-jack.service >/dev/null 2>&1; then
        ok "audio-jack.service activo para ${SUDO_USER}"
        as_user systemctl --user restart wireplumber.service >/dev/null 2>&1 || true
    else
        warn "no se pudo activar el servicio de ${SUDO_USER}; hazlo tú:"
        say "      systemctl --user daemon-reload && systemctl --user enable --now audio-jack.service"
    fi
else
    warn "activa el servicio de usuario:"
    say "      systemctl --user daemon-reload && systemctl --user enable --now audio-jack.service"
fi

say ""
say "Listo. Comprobaciones:"
say "   audio-salida estado            (jack, puerto activo, parche)"
say "   acp-speaker-always --check     (estado del parche)"
say "   audio-salida altavoces         / audio-salida auriculares"
say "   sudo $0 --uninstall            (deshacer todo)"
