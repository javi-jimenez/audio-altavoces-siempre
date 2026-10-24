# Altavoces y auriculares siempre seleccionables

Utilidad para portátiles Linux con **PipeWire + WirePlumber** (o PulseAudio)
cuyo mezclador **oculta los altavoces en cuanto enchufas los auriculares**.

Instalador de un solo fichero, sin dependencias de la distribución.

> **El problema en una frase:** el puerto de altavoces se marca *no disponible*
> al enchufar el jack, así que el mezclador lo pone en gris y desaparece; y el
> plugin de sonido de Xfce ni siquiera muestra el submenú **Port** si no hay al
> menos dos puertos disponibles.

Resultado tras instalarlo:

- Los dos puertos (**altavoces** y **auriculares**) están **siempre seleccionables**.
- Al **enchufar** los auriculares, la salida cambia sola a auriculares.
- Al **desenchufar**, vuelve sola a los altavoces.
- Si eliges una salida **a mano**, **se respeta** hasta la siguiente transición del jack.

---

## Instalación

```bash
git clone ssh://git@gitea.app.brisecom.net:22/gitea/audio-altavoces-siempre.git
cd audio-altavoces-siempre
sudo ./audio-altavoces-siempre.sh
```

Después, **como usuario normal** (una sola vez):

```bash
systemctl --user daemon-reload
systemctl --user enable --now audio-jack.service
```

Comprobación:

```bash
audio-salida estado
acp-speaker-always --check
```

| Comando | Qué hace |
|---|---|
| `sudo ./audio-altavoces-siempre.sh` | instala o repara |
| `sudo ./audio-altavoces-siempre.sh --check` | muestra el estado, sin tocar nada |
| `sudo ./audio-altavoces-siempre.sh --uninstall` | desinstala y revierte |
| `sudo ./audio-altavoces-siempre.sh --conservador` | parchea sólo `analog-output-speaker.conf` |
| `./audio-altavoces-siempre.sh --dump=DIR` | extrae los scripts embebidos para revisarlos |

---

## Uso diario

```bash
audio-salida altavoces      # forzar altavoces (aunque haya auriculares puestos)
audio-salida auriculares    # forzar auriculares
audio-salida toggle         # alternar entre las dos
audio-salida estado         # diagnóstico: jack, puerto activo, disponibilidad, parche
audio-salida                # menú gráfico (zenity)
```

En el menú de aplicaciones aparecen **Salida de audio**, **Salida: altavoces** y
**Salida: auriculares**. En el icono de sonido del panel, el submenú **Port**
ofrece las dos opciones.

Si no quieres instalar nada, el conmutador también funciona a mano:

```bash
pactl set-sink-port <SINK> analog-output-speaker
pactl set-sink-port <SINK> analog-output-headphones
```

(`pactl set-sink-port` ignora el flag de disponibilidad, así que funciona aunque
el puerto figure como *no disponible*.)

---

## Cómo funciona

### 1. El parche (la raíz del problema)

ACP —el backend de audio de PipeWire/PulseAudio— define las rutas en ficheros
`.conf`. La ruta de altavoces declara habitualmente:

```
[Jack Headphone]
state.plugged = no        ; <- "con auriculares puestos, yo no estoy disponible"
```

El instalador cambia ese `no` por **`unknown`** en todas las rutas
`analog-output-*.conf` que tengan esa cláusula, guardando el original como
`*.conf.distrib`.

Por qué `unknown` y no `yes`: el plugin de sonido de Xfce cuenta como
seleccionable todo lo que **no** sea `no`
(`pulseaudio_menu_maybe_append_ports`: `ports[i].available || ports[i].active`),
y además exige **≥2 puertos** para crear el submenú **Port**. `unknown` cumple
sin mentir sobre el estado del jack.

### 2. El cambio automático

Esta es la parte menos obvia: al compartir el mismo jack físico, ACP mete los dos
puertos en el **mismo grupo de disponibilidad** y fuerza `unknown` en **ambos**
(`profile_set_set_availability_groups`). Consecuencia: **PipeWire deja de
informar** de si hay auriculares puestos, y ni WirePlumber ni `pactl subscribe`
avisan del cambio.

Por eso el conmutador automático **no** escucha a PipeWire: sondea el control del
kernel **`Headphone Jack`** con `amixer`, localizándolo **por nombre** (los
`numid` de ALSA cambian cada vez que el códec se reconfigura).

### 3. Que no se pierda con las actualizaciones

Una actualización de `pipewire`/`pulseaudio` sobrescribe el `.conf`. Hay dos
vigilantes, ambos automáticos:

| Mecanismo | Cobertura |
|---|---|
| `acp-speaker-always.path` (systemd, `PathModified=`) | cualquier distribución |
| `/etc/dpkg/dpkg.cfg.d/99-acp-speaker-always` (`post-invoke`) | Debian / Ubuntu |

Si detectan cambios reaplican el parche y dejan `/run/acp-speaker-always.needed`;
el servicio de usuario lo ve y reinicia WirePlumber para que relea las rutas.
**No hay que hacer nada tras actualizar.** Para verificarlo:

```bash
acp-speaker-always --check
```

---

## ¿Y en Ubuntu con GNOME? ¿no se podía ya?

Respuesta corta: **no, GNOME no permite elegir el puerto.** Lo que sí hay (y
probablemente es lo que recuerdas) es **`pavucontrol`**, el «Control de volumen».

Comprobado en el código de `gnome-control-center`: el panel de Sonido
**no gestiona puertos en ninguna versión reciente** (0 referencias a
`get_ports`/`set_port` en las ramas 42, 44, 46 y 48). Solo lista *dispositivos*
(un sink por tarjeta) y *perfiles* de tarjeta. Con una tarjeta analógica normal
eso es **una sola entrada**, así que no hay dónde elegir altavoces vs
auriculares.

Lo que sí funciona en cualquier GNOME:

```bash
sudo apt install pavucontrol
pavucontrol      # pestaña "Salida" -> desplegable "Puerto"
```

`pavucontrol` **sí** lista los dos puertos y **no** filtra por disponibilidad
(`DeviceWidget::prepareMenu` no comprueba `available`), así que permite
seleccionar los altavoces aunque estén marcados como *no disponibles*.

Resumen de diferencias:

| Entorno | ¿Elegir puerto de serie? |
|---|---|
| Xubuntu (plugin de Xfce) | No: exige ≥2 puertos disponibles para mostrar **Port** |
| Ubuntu GNOME (Ajustes → Sonido) | No: no gestiona puertos |
| Cualquiera + `pavucontrol` | **Sí**, aunque estén marcados *no disponible* |
| Este proyecto | **Sí**, y además cambia solo al enchufar |

Es decir: en Ubuntu *sí* puedes hacerlo con `pavucontrol`, pero es manual y no
evita el gris; este proyecto arregla la causa y automatiza el cambio.

---

## Otras distribuciones y equipos

- **Fedora, Arch, Debian…**: funciona igual. El reaplicado principal es el
  `.path` de systemd, que no depende de la distro; el hook de `dpkg` solo se
  instala si existe `/etc/dpkg/dpkg.cfg.d`.
- **Sobremesa** con `analog-output-lineout` en vez de `-speaker`: también se
  parchea; el criterio es «cualquier ruta de salida que se oculte al enchufar».
- **Sin nombres fijos**: tarjeta ALSA, sink y puertos se detectan en ejecución.
- **Sin control `Headphone Jack`**: el cambio automático no se hace (lo indica
  `audio-salida estado`), pero la elección manual sigue funcionando.
- **PulseAudio clásico**: el parche sirve igual; `audio-jack.service` también
  (usa `amixer`, no PipeWire).

### Qué se instala

| Ruta | Para qué |
|---|---|
| `/usr/local/bin/acp-speaker-always` | aplica / comprueba / revierte el parche |
| `/usr/local/bin/audio-salida` | conmutador de salida |
| `/etc/systemd/user/audio-jack.service` | vigila el jack y cambia de salida |
| `/etc/systemd/system/acp-speaker-always.{service,path}` | reaplica el parche |
| `/etc/dpkg/dpkg.cfg.d/99-acp-speaker-always` | refuerzo en Debian/Ubuntu |
| `/usr/share/applications/audio-*.desktop` | lanzadores |

---

## Desinstalar

```bash
sudo ./audio-altavoces-siempre.sh --uninstall
```

Si ya no tienes el script:

```bash
systemctl --user disable --now audio-jack.service
sudo systemctl disable --now acp-speaker-always.path
sudo rm -f /etc/systemd/system/acp-speaker-always.{service,path} \
           /etc/systemd/user/audio-jack.service \
           /usr/local/bin/{audio-salida,acp-speaker-always} \
           /etc/dpkg/dpkg.cfg.d/99-acp-speaker-always \
           /usr/share/applications/audio-{salida,altavoces,auriculares}.desktop
cd /usr/share/alsa-card-profile/mixer/paths && \
  sudo sh -c 'for f in *.conf.distrib; do cp -f "$f" "${f%.distrib}"; done'
sudo systemctl daemon-reload
```

---

## Probado en

- Acer Nitro AN517-52 (Realtek ALC295), Xubuntu 26.04,
  PipeWire 1.6.2 + WirePlumber 0.5.13, `xfce4-pulseaudio-plugin` 0.5.1
  (Xfce 4.20).

## Licencia

MIT — ver [LICENSE](LICENSE).
