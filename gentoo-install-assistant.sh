#!/usr/bin/env bash
# gentoo-install-assistant.sh
# Assistente installazione Gentoo Linux, allineato al manuale Handbook:AMD64
# (rete, dischi, stage3, base, kernel, sistema, strumenti, bootloader, finalizzazione).
#
# Uso dalla live minimal, come utente root: ./gentoo-install-assistant.sh
# Opzioni: --help, --dry-run, --config FILE.conf, --from-step NOME_STEP
# Esempio: ./gentoo-install-assistant.sh --config ./gentoo-install.conf
# Esempio: ./gentoo-install-assistant.sh --dry-run
# Esempio: ./gentoo-install-assistant.sh --from-step mount
#
# Riferimento: https://wiki.gentoo.org/wiki/Handbook:AMD64
# Lo script NON sostituisce la lettura del manuale; automatizza operazioni ripetitive
# e riduce errori di copia-incolla; molte scelte restano a chi installa.
#
# Policy fissa (non configurabile): architettura Handbook AMD64 (tarball amd64) soltanto;
# stage desktop + OpenRC; timezone Europe/Rome; locale it_IT.UTF-8; kernel
# gentoo-kernel-bin + dracut + installkernel-gentoo (apply_install_policy).
#
# Hardware di riferimento per flag di compilazione predefinite: Geekom Mini IT13,
# Intel Core i9-13900HK (13th Gen, Raptor Lake). Compilando sullo stesso PC,
# COMMON_FLAGS con march=native sono appropriati su questo hardware; con GCC recente
# in make.conf si puo usare march=raptorlake come alternativa esplicita (man gcc).
#
# Esempio gentoo-install.conf (bash, caricabile con --config):
#   GENTOO_ROOT=/mnt/gentoo
#   GENTOO_MIRROR=https://distfiles.gentoo.org
#   # GENTOO_STAGE_INDEX_URL=... # solo se il mirror non espone latest-stage3-amd64-desktop-openrc.txt
#   MAKEOPTS='-j20'
#   HOSTNAME=gentoo-box
#   BOOTLOADER=grub-efi          # grub-efi | grub-bios | skip
#   ESP_DEVICE=/dev/nvme0n1p1
#   NONINTERACTIVE=1
#   PORTAGE_PROFILE=             # es. numero da eselect profile list
#   EXTRA_PACKAGES='app-admin/syslog-ng app-editors/vim sys-apps/mlocate'
#   DISK_AUTO=1
#   DISK_TARGET=/dev/nvme0n1
#   DISK_ESP_MIB=512
#   DISK_SWAP_MIB=8192
#   DISK_WIPE_CONFIRM=YES
#   # oppure partizionamento gia fatto a mano:
#   DISK_ROOT_PART=/dev/nvme0n1p3
#   DISK_ESP_PART=/dev/nvme0n1p1
#   DISK_SWAP_PART=/dev/nvme0n1p2

set -euo pipefail

SCRIPT_VERSION="1.3.1"
STATE_FILE="${STATE_FILE:-/tmp/gentoo-install-assistant.state}"
LOG_FILE="${LOG_FILE:-/tmp/gentoo-install-assistant.log}"
PARTS_STATE="${PARTS_STATE:-/tmp/gentoo-install-assistant.parts}"
DRY_RUN=0
CONFIG_FILE=""
FROM_STEP=""

# ---------------------------------------------------------------------------
# Valori predefiniti (sovrascrivibili da file di config o variabili d'ambiente)
# ---------------------------------------------------------------------------
# Architettura: solo amd64 (Handbook:AMD64). Forzato anche in apply_install_policy.
GENTOO_ARCH="${GENTOO_ARCH:-amd64}"

# Dopo load_config, apply_install_policy() imposta sempre: OpenRC, stage desktop, multilib.
GENTOO_INIT="${GENTOO_INIT:-openrc}"
GENTOO_STAGE_FLAVOR="${GENTOO_STAGE_FLAVOR:-desktop}"
GENTOO_NOMULTILIB="${GENTOO_NOMULTILIB:-0}"

# Directory di mount del nuovo sistema (fissata in policy a /mnt/gentoo)
GENTOO_ROOT="${GENTOO_ROOT:-/mnt/gentoo}"

# Partizionamento automatico (Handbook: GPT, EFI System, swap, root). ATTENZIONE: cancella la tabella del disco.
# Richiede disco INTERO (es. /dev/nvme0n1), non una singola partizione.
DISK_AUTO="${DISK_AUTO:-0}"
DISK_TARGET="${DISK_TARGET:-}"
# Dimensioni in MiB (allineamento 1 MiB come da manuale)
DISK_ESP_MIB="${DISK_ESP_MIB:-512}"
DISK_SWAP_MIB="${DISK_SWAP_MIB:-8192}"
# In NONINTERACTIVE=1 con DISK_AUTO=1 deve valere esattamente YES
DISK_WIPE_CONFIRM="${DISK_WIPE_CONFIRM:-}"
# Partizioni (manuale o dopo DISK_AUTO): percorsi device; montaggio e swapon nello step mount
DISK_ROOT_PART="${DISK_ROOT_PART:-}"
DISK_ESP_PART="${DISK_ESP_PART:-}"
DISK_SWAP_PART="${DISK_SWAP_PART:-}"

# Mirror base (senza trailing slash); verrà usato distfiles.gentoo.org se vuoto
GENTOO_MIRROR="${GENTOO_MIRROR:-https://distfiles.gentoo.org}"

# URL opzionale al file latest-stage3-*.txt se i nomi automatici non coincidono col mirror
GENTOO_STAGE_INDEX_URL="${GENTOO_STAGE_INDEX_URL:-}"

# MAKEOPTS (COMMON_FLAGS fissati in apply_install_policy per i9-13900HK / build sullo stesso host)
MAKEOPTS="${MAKEOPTS:--j$(nproc 2>/dev/null || echo 2)}"
COMMON_FLAGS="${COMMON_FLAGS:--march=native -O2 -pipe}"

# Se 1, dopo lo stage3 esegue emerge-webrsync dentro chroot
DO_PORTAGE_SYNC="${DO_PORTAGE_SYNC:-1}"

# Profilo Portage da selezionare (es. default/linux/amd64/23.0/desktop); vuoto = non cambiare
PORTAGE_PROFILE="${PORTAGE_PROFILE:-}"

# Timezone e locale (sovrascritti da apply_install_policy a Europe/Rome e it_IT.UTF-8)
TIMEZONE="${TIMEZONE:-Europe/Rome}"
LOCALES="${LOCALES:-it_IT.UTF-8 UTF-8}"

# Hostname
HOSTNAME="${HOSTNAME:-gentoo}"

# Bootloader: grub-efi | grub-bios | skip
BOOTLOADER="${BOOTLOADER:-grub-efi}"

# Partizione EFI (per grub-efi), es. /dev/nvme0n1p1
ESP_DEVICE="${ESP_DEVICE:-}"

# Disco BIOS per grub-install legacy (BOOTLOADER=grub-bios), es. /dev/sda
GRUB_BIOS_DISK="${GRUB_BIOS_DISK:-}"

# Se 1, chiede password root dentro chroot (passwd)
SET_ROOT_PASSWORD="${SET_ROOT_PASSWORD:-1}"

# Pacchetti extra dopo il kernel (spazio separato); include microcode Intel per CPU disclose
EXTRA_PACKAGES="${EXTRA_PACKAGES:-app-admin/syslog-ng app-editors/vim sys-firmware/intel-microcode}"

# Non interattivo: usa solo config (nessun prompt); fallisce se mancano valori critici
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# Colori
if [[ -t 1 ]]; then
  C_INFO='\033[0;36m'
  C_WARN='\033[0;33m'
  C_ERR='\033[0;31m'
  C_OK='\033[0;32m'
  C_RST='\033[0m'
else
  C_INFO='' C_WARN='' C_ERR='' C_OK='' C_RST=''
fi

log() {
  local msg="[$(date -Iseconds)] $*"
  printf '%b\n' "${C_INFO}${msg}${C_RST}"
  printf '%s\n' "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

warn() { printf '%b\n' "${C_WARN}ATTENZIONE: $*${C_RST}" | tee -a "$LOG_FILE" >&2 || true; }
err()  { printf '%b\n' "${C_ERR}ERRORE: $*${C_RST}" | tee -a "$LOG_FILE" >&2 || true; exit 1; }
ok()   { printf '%b\n' "${C_OK}$*${C_RST}"; }

run() {
  log "Eseguo: $*"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  eval "$@"
}

chroot_exec() {
  local cmd=$1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run chroot] $cmd"
    return 0
  fi
  chroot "$GENTOO_ROOT" /bin/bash -c "$cmd"
}

usage() {
  cat <<'EOF'
gentoo-install-assistant.sh - assistente installazione Gentoo (fasi Handbook)

Opzioni:
  --config FILE     Carica variabili da FILE (bash: VAR=valore)
  --dry-run         Mostra i comandi senza eseguirli
  --from-step NAME  Riprendi da uno step (vedi elenco sotto)
  -h, --help        Questo messaggio

Step disponibili (ordine manuale):
  intro network disks mount stage3 portage chroot profile timezone locale fstab
  hostname kernel tools bootloader finalize

Variabili principali (export o file --config):
  GENTOO_MIRROR GENTOO_STAGE_INDEX_URL MAKEOPTS HOSTNAME BOOTLOADER ESP_DEVICE
  GRUB_BIOS_DISK PORTAGE_PROFILE EXTRA_PACKAGES NONINTERACTIVE DO_PORTAGE_SYNC
  DISK_AUTO DISK_TARGET DISK_ESP_MIB DISK_SWAP_MIB DISK_WIPE_CONFIRM PARTS_STATE
  DISK_ROOT_PART DISK_ESP_PART DISK_SWAP_PART

Fissi dallo script: arch amd64; root /mnt/gentoo; stage desktop+OpenRC; Europe/Rome;
it_IT.UTF-8; COMMON_FLAGS -march=native -O2 -pipe (Geekom IT13 / i9-13900HK); kernel
gentoo-kernel-bin + dracut + installkernel-gentoo.

DISK_AUTO=1: GPT, EFI vfat, swap, root XFS (Handbook); richiede DISK_TARGET disco intero;
in NONINTERACTIVE anche DISK_WIPE_CONFIRM=YES. Dopo disks/mount: partprobe/blockdev, swapon,
mount root su /mnt/gentoo e EFI su boot/efi. fstab con UUID (solo voci per partizioni definite).
Senza DISK_AUTO: impostare DISK_ROOT_PART (e opzionalmente DISK_ESP_PART, DISK_SWAP_PART) nel .conf
oppure indicarli allo step disks; stesso montaggio nello step mount.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) CONFIG_FILE="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --from-step) FROM_STEP="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Opzione sconosciuta: $1 (usa --help)" ;;
    esac
  done
}

load_config() {
  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || err "File di config non trovato: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log "Caricato config: $CONFIG_FILE"
  fi
}

# AMD64 + stage desktop + OpenRC; fuso orario e lingua; flag compilazione per build sul Mini IT13;
# kernel binario + dracut + installkernel-gentoo.
apply_install_policy() {
  GENTOO_ARCH=amd64
  GENTOO_INIT=openrc
  GENTOO_STAGE_FLAVOR=desktop
  GENTOO_NOMULTILIB=0
  GENTOO_ROOT=/mnt/gentoo
  TIMEZONE=Europe/Rome
  LOCALES='it_IT.UTF-8 UTF-8'
  # i9-13900HK (Raptor Lake): compilazione nello stesso ambiente (live/chroot su Geekom IT13).
  COMMON_FLAGS='-march=native -O2 -pipe'
  log "Policy installazione: amd64, root ${GENTOO_ROOT}, stage desktop+OpenRC (latest-stage3-amd64-desktop-openrc.txt), ${TIMEZONE}, it_IT.UTF-8, COMMON_FLAGS=${COMMON_FLAGS}, kernel gentoo-kernel-bin + dracut + installkernel-gentoo (HW ref: Geekom Mini IT13, i9-13900HK)"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || err "Eseguire come root (live environment)."
}

# N-esima partizione (1..n) su disco intero (Handbook-style: GPT + nvme/sd).
disk_part_path() {
  local disk=$1 idx=$2
  if [[ "$disk" =~ ^/dev/(nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$ ]]; then
    printf '%sp%s\n' "$disk" "$idx"
  elif [[ "$disk" =~ ^/dev/(sd[a-z]|vd[a-z])$ ]]; then
    printf '%s%s\n' "$disk" "$idx"
  else
    err "Disco non supportato per partizionamento automatico: $disk (usare /dev/nvme0n1, /dev/sda, ... intero disco)"
  fi
}

disk_is_whole_block() {
  local d=$1
  [[ "$d" =~ ^/dev/(nvme[0-9]+n[0-9]+|mmcblk[0-9]+|sd[a-z]|vd[a-z])$ ]]
}

# True se qualche mountpoint usa una partizione (o il disco) con prefisso uguale a $disk.
disk_used_by_mounts() {
  local disk=$1 s
  while IFS= read -r s; do
    s=${s%%\[*}
    [[ -z "$s" || "$s" == "overlay" ]] && continue
    if [[ "$s" == "${disk}"* ]]; then
      return 0
    fi
  done < <(findmnt -rno SOURCE 2>/dev/null || true)
  return 1
}

require_disk_tools() {
  command -v parted >/dev/null 2>&1 || err "Serve parted (presente sulla live Gentoo)."
  command -v mkfs.xfs >/dev/null 2>&1 || err "Serve xfsprogs (mkfs.xfs)."
  command -v mkfs.vfat >/dev/null 2>&1 || err "Serve dosfstools (mkfs.vfat) per la EFI."
  command -v wipefs >/dev/null 2>&1 || err "Serve wipefs (util-linux)."
}

# Carica DISK_* da PARTS_STATE (se valido) o lascia quelli gia impostati nel config (es. gentoo-install.conf).
parts_load_for_mount() {
  local env_root=$DISK_ROOT_PART env_esp=$DISK_ESP_PART env_swap=$DISK_SWAP_PART
  if [[ -f "$PARTS_STATE" ]]; then
    # shellcheck source=/dev/null
    source "$PARTS_STATE"
    if [[ "${DISK_LAYOUT_AUTO:-}" != "1" && "${DISK_LAYOUT_MANUAL:-}" != "1" ]]; then
      DISK_ROOT_PART=$env_root
      DISK_ESP_PART=$env_esp
      DISK_SWAP_PART=$env_swap
    fi
  fi
  [[ -n "${DISK_ROOT_PART:-}" ]] || return 1
  return 0
}

# Disco padre di una partizione (per partprobe / blockdev).
disk_parent_of_partition() {
  local p=$1
  if [[ "$p" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$p" =~ ^(/dev/mmcblk[0-9]+)p[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$p" =~ ^(/dev/sd[a-z])[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$p" =~ ^(/dev/vd[a-z])[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

# Rilettura kernel tabella partizioni sui dischi coinvolti (Handbook: partprobe / blockdev).
disk_rescan_all_parts() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local p x
  declare -A seen=()
  for p in "${DISK_ROOT_PART:-}" "${DISK_ESP_PART:-}" "${DISK_SWAP_PART:-}"; do
    [[ -z "$p" ]] && continue
    x=$(disk_parent_of_partition "$p")
    [[ -n "$x" ]] || continue
    [[ -n "${seen[$x]:-}" ]] && continue
    seen[$x]=1
    log "Rilettura partizioni su ${x} (blockdev --rereadpt, partprobe)"
    blockdev --rereadpt "$x" 2>/dev/null || true
    partprobe "$x" 2>/dev/null || true
  done
  udevadm settle 2>/dev/null || sleep 1
}

disk_rescan_whole_disk() {
  local disk=$1
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ -z "$disk" ]] && return 0
  log "Rilettura partizioni su ${disk}"
  blockdev --rereadpt "$disk" 2>/dev/null || true
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 1
}

# Attiva swap (se definita), monta root XFS su GENTOO_ROOT, monta EFI vfat su boot/efi (Handbook).
mount_activate_install_partitions() {
  disk_rescan_all_parts
  [[ -b "${DISK_ROOT_PART}" ]] || err "Device root non trovato o non a blocchi: ${DISK_ROOT_PART}"

  if [[ -n "${DISK_SWAP_PART:-}" && "$DRY_RUN" -eq 0 ]]; then
    if [[ -b "${DISK_SWAP_PART}" ]]; then
      swapon "${DISK_SWAP_PART}" 2>/dev/null && ok "Swap attiva: ${DISK_SWAP_PART}" || warn "swapon ${DISK_SWAP_PART} non riuscito (gia attiva o altro)."
    else
      warn "Device swap non trovato: ${DISK_SWAP_PART}"
    fi
  fi

  if ! mountpoint -q "$GENTOO_ROOT" 2>/dev/null; then
    log "Mount root XFS: ${DISK_ROOT_PART} -> ${GENTOO_ROOT}"
    [[ "$DRY_RUN" -eq 1 ]] || mount -t xfs "${DISK_ROOT_PART}" "$GENTOO_ROOT"
  else
    ok "${GENTOO_ROOT} gia montato come root."
  fi

  if [[ -n "${DISK_ESP_PART:-}" ]]; then
    mkdir -p "${GENTOO_ROOT}/boot/efi"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      if [[ -b "${DISK_ESP_PART}" ]]; then
        mount -t vfat -o rw,noatime "${DISK_ESP_PART}" "${GENTOO_ROOT}/boot/efi" 2>/dev/null && \
          ok "EFI montata: ${DISK_ESP_PART} -> ${GENTOO_ROOT}/boot/efi" || \
          warn "Mount EFI fallito (gia montata?): ${DISK_ESP_PART}"
      else
        warn "Device EFI non trovato: ${DISK_ESP_PART}"
      fi
    fi
    ESP_DEVICE="${DISK_ESP_PART}"
  fi
}

# Layout Handbook UEFI: GPT, partizione ESP (vfat), swap, root XFS.
disk_auto_partition_format() {
  local disk=$1
  local esp_end swap_end
  esp_end=$((1 + DISK_ESP_MIB))
  swap_end=$((esp_end + DISK_SWAP_MIB))
  local p1 p2 p3
  p1=$(disk_part_path "$disk" 1)
  p2=$(disk_part_path "$disk" 2)
  p3=$(disk_part_path "$disk" 3)

  log "Layout: GPT | 1:EFI vfat 1MiB-${esp_end}MiB | 2:swap ${esp_end}MiB-${swap_end}MiB | 3:root xfs ${swap_end}MiB-100%"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] parted/wipefs/mkfs su $disk"
    return 0
  fi

  wipefs -a --all "$disk" 2>/dev/null || true
  parted -s "$disk" mklabel gpt
  parted -s "$disk" unit MiB mkpart esp fat32 1 "${esp_end}"
  parted -s "$disk" set 1 esp on
  parted -s "$disk" unit MiB mkpart swap linux-swap "${esp_end}" "${swap_end}"
  parted -s "$disk" unit MiB mkpart root xfs "${swap_end}" 100%
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 2

  [[ -b "$p1" && -b "$p2" && -b "$p3" ]] || err "Partizioni attese non trovate: $p1 $p2 $p3"

  mkfs.vfat -F32 -n EFI "$p1"
  mkswap -L swap "$p2"
  mkfs.xfs -f -L root "$p3"

  disk_rescan_whole_disk "$disk"

  printf '%s\n' \
    "DISK_LAYOUT_AUTO=1" \
    "DISK_ESP_PART=${p1}" \
    "DISK_SWAP_PART=${p2}" \
    "DISK_ROOT_PART=${p3}" \
    "DISK_TARGET=${disk}" \
    >"$PARTS_STATE"
  ESP_DEVICE="$p1"
  ok "Partizioni create; stato salvato in ${PARTS_STATE}"
}

save_state() { echo "$1" >"$STATE_FILE"; }
get_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo ""; }

step_should_run() {
  local step=$1
  local order=(intro network disks mount stage3 portage chroot profile timezone locale fstab hostname kernel tools bootloader finalize)
  local i from_idx=0 step_idx=-1
  if [[ -z "$FROM_STEP" ]]; then
    return 0
  fi
  for i in "${!order[@]}"; do
    [[ "${order[$i]}" == "$FROM_STEP" ]] && from_idx=$i
    [[ "${order[$i]}" == "$step" ]] && step_idx=$i
  done
  [[ "$step_idx" -ge "$from_idx" ]]
}

prompt_yn() {
  local def=$1; shift
  local q=$1
  [[ "$NONINTERACTIVE" -eq 1 ]] && { [[ "$def" == "y" ]]; return; }
  local a
  read -r -p "$q [${def}] " a || true
  a=${a:-$def}
  [[ "${a,,}" == "y" || "${a,,}" == "s" || "${a,,}" == "yes" || "${a,,}" == "si" ]]
}

prompt_val() {
  local def=$1; shift
  local var=$1; shift
  local q=$1
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    printf -v "$var" '%s' "${!var:-$def}"
    return
  fi
  local cur="${!var:-$def}"
  read -r -p "$q [${cur}] " input || true
  printf -v "$var" '%s' "${input:-$cur}"
}

step_intro() {
  log "=== Introduzione (Handbook: scelta media, panoramica) ==="
  cat <<EOF

Questo script guida le fasi del Gentoo Handbook:AMD64 (solo architettura amd64 / x86-64).
- Target hardware di riferimento: Geekom Mini IT13, Intel Core i9-13900HK (Raptor Lake).
- Stage fisso: desktop, OpenRC. Kernel: pacchetto binario ufficiale + dracut + installkernel-gentoo.
- Timezone Europe/Rome, locale principale it_IT.UTF-8; COMMON_FLAGS con -march=native sullo stesso PC.
- Dischi: con DISK_AUTO=1 crea GPT + EFI + swap + root XFS; nello step mount partprobe, swapon e mount su /mnt/gentoo (e EFI). Senza auto: indicare i device o DISK_* nel config.
- Dopo ogni blocco critico puoi interrompere (Ctrl+C) e riprendere con --from-step.

Manuale: https://wiki.gentoo.org/wiki/Handbook:${GENTOO_ARCH}

Versione script: ${SCRIPT_VERSION}
EOF
  prompt_yn n "Continuare?" || exit 0
}

step_network() {
  log "=== Rete (Handbook: configuring the network) ==="
  if ip route 2>/dev/null | grep -q default || ip -4 addr show scope global 2>/dev/null | grep -q inet; then
    ok "Sembra esserci connettività IP."
  else
    warn "Nessuna route default evidente. Configurare la rete (dhcpcd, iproute2, NetworkManager) prima di scaricare lo stage3."
    prompt_yn n "Procedere comunque?" || exit 1
  fi
}

step_disks() {
  log "=== Dischi (Handbook: preparing the disks) ==="
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,TYPE 2>/dev/null || lsblk

  if [[ "${DISK_AUTO:-0}" == "1" ]]; then
    warn "DISK_AUTO=1: verranno cancellate tutte le partizioni su DISK_TARGET e creato GPT + EFI (vfat) + swap + root XFS."
    [[ -n "$DISK_TARGET" ]] || err "Con DISK_AUTO=1 impostare DISK_TARGET=/dev/... (disco intero, es. /dev/nvme0n1)."
    disk_is_whole_block "$DISK_TARGET" || err "DISK_TARGET deve essere un disco a blocchi intero (es. /dev/nvme0n1), non una partizione."
    disk_used_by_mounts "$DISK_TARGET" && err "Il disco ${DISK_TARGET} risulta in uso (montato). Smontare o usare un altro disco."
    require_disk_tools
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      [[ "$DISK_WIPE_CONFIRM" == "YES" ]] || err "In modalita non interattiva impostare DISK_WIPE_CONFIRM=YES per confermare la cancellazione del disco."
    else
      echo "Disco selezionato: ${DISK_TARGET}"
      prompt_yn n "Confermi la DISTRUZIONE di tutti i dati su ${DISK_TARGET}?" || err "Operazione annullata."
    fi
    disk_auto_partition_format "$DISK_TARGET"
    return 0
  fi

  echo "Partizionamento manuale (come da manuale): GPT, EFI System (vfat), swap opzionale, root XFS sotto ${GENTOO_ROOT}."
  echo "Riferimento: https://wiki.gentoo.org/wiki/Handbook:${GENTOO_ARCH}/Installation/Disks"
  echo "Per automatizzare: DISK_AUTO=1 DISK_TARGET=/dev/nvme0n1 (e DISK_WIPE_CONFIRM=YES se NONINTERACTIVE=1)."
  if ! prompt_yn y "Ho gia creato e formattato le partizioni (root XFS) necessarie"; then
    err "Completare il partizionamento o impostare DISK_AUTO=1, poi rilanciare con --from-step mount"
  fi
  step_disks_collect_partition_paths
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s\n' \
      "DISK_LAYOUT_MANUAL=1" \
      "DISK_ESP_PART=${DISK_ESP_PART}" \
      "DISK_SWAP_PART=${DISK_SWAP_PART}" \
      "DISK_ROOT_PART=${DISK_ROOT_PART}" \
      >"$PARTS_STATE"
    disk_rescan_all_parts
    ok "Percorsi salvati in ${PARTS_STATE}; lo step mount: partprobe, swapon, mount root XFS e EFI."
  else
    log "[dry-run] non scrivo ${PARTS_STATE}; in esecuzione reale verrebbero salvati i device indicati."
  fi
}

# Chiede (o legge da config) i device per root / EFI / swap dopo partizionamento manuale.
step_disks_collect_partition_paths() {
  log "=== Percorsi partizioni per montaggio (Handbook: mount) ==="
  prompt_val "${DISK_ROOT_PART:-}" DISK_ROOT_PART "Partizione root XFS (es. /dev/nvme0n1p3)"
  [[ -n "$DISK_ROOT_PART" ]] || err "Impostare DISK_ROOT_PART (root XFS) o rispondere al prompt."
  prompt_val "${DISK_ESP_PART:-}" DISK_ESP_PART "Partizione EFI vfat (UEFI; Invio se assente)"
  prompt_val "${DISK_SWAP_PART:-}" DISK_SWAP_PART "Partizione swap (Invio se assente)"
}

step_mount() {
  log "=== Mount e attivazione partizioni (Handbook: mount filesystems) ==="
  ok "Mount point root fisso: ${GENTOO_ROOT}"
  mkdir -p "$GENTOO_ROOT"

  if parts_load_for_mount; then
    mount_activate_install_partitions
  else
    if mountpoint -q "$GENTOO_ROOT" 2>/dev/null; then
      ok "${GENTOO_ROOT} e gia montato."
    else
      warn "Nessun layout in ${PARTS_STATE} e nessun DISK_ROOT_PART in config."
      echo "Imposta DISK_ROOT_PART (e opzionalmente DISK_ESP_PART, DISK_SWAP_PART) nel .conf oppure riesegui lo step disks."
      echo "Oppure monta a mano: mount -t xfs /dev/... ${GENTOO_ROOT}"
      prompt_yn n "Ho montato la root XFS su ${GENTOO_ROOT} (verra ricontrollato)" || err "Montare la root e ripetere."
    fi
  fi
  mountpoint -q "$GENTOO_ROOT" 2>/dev/null || err "${GENTOO_ROOT} non e un mountpoint: montare la partizione root e ripetere."
  # bind mounts per chroot successivo
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mount --make-rslave /dev 2>/dev/null || true
    mount --types proc /proc "${GENTOO_ROOT}/proc" 2>/dev/null || mount -t proc proc "${GENTOO_ROOT}/proc"
    mount --rbind /sys "${GENTOO_ROOT}/sys"
    mount --make-rslave "${GENTOO_ROOT}/sys"
    mount --rbind /dev "${GENTOO_ROOT}/dev"
    mount --make-rslave "${GENTOO_ROOT}/dev"
    if [[ -d /run ]]; then
      mount --rbind /run "${GENTOO_ROOT}/run"
      mount --make-rslave "${GENTOO_ROOT}/run"
    fi
    cp --dereference /etc/resolv.conf "${GENTOO_ROOT}/etc/resolv.conf" 2>/dev/null || warn "resolv.conf non copiato (normale se /etc/resolv.conf assente)."
  fi
  ok "Mount e bind completati (live → chroot)."
}

fetch_latest_stage3_url() {
  # Indice ufficiale: releases/<arch>/autobuilds/latest-stage3-<arch>-<init>.txt
  # Override: esportare GENTOO_STAGE_INDEX_URL per URL completo al file .txt
  local base="${GENTOO_MIRROR}/releases/${GENTOO_ARCH}/autobuilds"
  local latest
  if [[ -n "${GENTOO_STAGE_INDEX_URL:-}" ]]; then
    latest="$GENTOO_STAGE_INDEX_URL"
  else
    local suffix
    if [[ "$GENTOO_NOMULTILIB" == "1" ]]; then
      if [[ -n "$GENTOO_STAGE_FLAVOR" ]]; then
        suffix="${GENTOO_ARCH}-${GENTOO_STAGE_FLAVOR}-nomultilib-${GENTOO_INIT}"
      else
        suffix="${GENTOO_ARCH}-nomultilib-${GENTOO_INIT}"
      fi
    else
      if [[ -n "$GENTOO_STAGE_FLAVOR" ]]; then
        suffix="${GENTOO_ARCH}-${GENTOO_STAGE_FLAVOR}-${GENTOO_INIT}"
      else
        suffix="${GENTOO_ARCH}-${GENTOO_INIT}"
      fi
    fi
    latest="${base}/latest-stage3-${suffix}.txt"
  fi
  if ! curl -fsSL "$latest" -o /tmp/stage3-latest.txt 2>/dev/null; then
    if ! wget -q -O /tmp/stage3-latest.txt "$latest" 2>/dev/null; then
      err "Impossibile scaricare l'indice stage3: $latest (verificare arch/init o impostare GENTOO_STAGE_INDEX_URL)"
    fi
  fi
  local path
  path=$(grep -v '^#' /tmp/stage3-latest.txt | awk 'NF{print $1; exit}')
  [[ -n "$path" ]] || err "Formato latest-stage3 inatteso in $latest"
  echo "${base}/${path}"
}

step_stage3() {
  log "=== Stage3 amd64 desktop + OpenRC (Handbook:AMD64 / the stage file) ==="
  prompt_val "$GENTOO_MIRROR" GENTOO_MIRROR "Mirror Gentoo (base URL)"
  ok "Architettura fissa: amd64 - stage desktop-openrc (latest-stage3-amd64-desktop-openrc.txt)"
  if [[ -n "$(ls -A "$GENTOO_ROOT" 2>/dev/null | grep -v '^lost+found$' || true)" ]]; then
    warn "${GENTOO_ROOT} non è vuoto. Estrarre lo stage3 qui sovrascriverà file."
    prompt_yn n "Procedere con download ed estrazione?" || return 0
  fi
  local url
  url=$(fetch_latest_stage3_url)
  log "URL stage3: $url"
  local tarball="/tmp/$(basename "$url")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    curl -fL "$url" -o "$tarball" || wget -O "$tarball" "$url" || err "Download fallito"
    # Verifica opzionale checksum (DIGESTS sul mirror)
    warn "Verifica firma/checksum: consultare il manuale (openssl / gpg) per il file DIGESTS associato."
    tar xpf "$tarball" -C "$GENTOO_ROOT" --xattrs-include='*.*' --numeric-owner || err "Estrazione stage3 fallita"
    rm -f "$tarball"
  fi
  ok "Stage3 installato in ${GENTOO_ROOT}"
}

write_make_conf() {
  local mc="${GENTOO_ROOT}/etc/portage/make.conf"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] aggiornerei ${mc}"
    return
  fi
  mkdir -p "${GENTOO_ROOT}/etc/portage"
  if [[ -f "$mc" ]]; then
    cp -a "$mc" "${mc}.bak.gentoo-install-assistant"
    warn "Backup make.conf: ${mc}.bak.gentoo-install-assistant"
  fi
  cat >"$mc" <<EOF
# Generato da gentoo-install-assistant.sh - rivedere USE e mirror (manuale Portage)
# Riferimento HW: Geekom Mini IT13, Intel Core i9-13900HK (Raptor Lake, amd64).
# COMMON_FLAGS=-march=native ottimizza per la CPU del sistema usato durante emerge (stesso IT13).
COMMON_FLAGS="${COMMON_FLAGS}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="${MAKEOPTS}"

GENTOO_MIRRORS="${GENTOO_MIRROR} https://distfiles.gentoo.org"
EOF
  ok "make.conf scritto."
}

step_portage() {
  log "=== Portage / make.conf (Handbook: configuring compile options) ==="
  ok "COMMON_FLAGS fissi dalla policy: ${COMMON_FLAGS} (amd64 / i9-13900HK su Geekom IT13: vedi commenti in make.conf)"
  prompt_val "$MAKEOPTS" MAKEOPTS "MAKEOPTS (i9-13900HK: spesso -j16 … -j20; su questo host nproc=$(nproc))"
  write_make_conf
}

step_chroot() {
  log "=== Ambiente chroot (Handbook: installing base system) ==="
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] emerge-webrsync / preparazione chroot"
    return
  fi
  if [[ "$DO_PORTAGE_SYNC" -eq 1 ]]; then
    chroot_exec "emerge-webrsync" || warn "emerge-webrsync fallito (rete?); provare emerge --sync manualmente."
  else
    warn "DO_PORTAGE_SYNC=0: saltato emerge-webrsync."
  fi
}

step_profile() {
  log "=== Selezione profilo Portage ==="
  if [[ -z "$PORTAGE_PROFILE" ]]; then
    if [[ "$NONINTERACTIVE" -ne 1 ]]; then
      chroot_exec "eselect profile list || true"
      read -r -p "Indice o nome profilo per eselect profile set (vuoto = nessun cambio): " PORTAGE_PROFILE || true
    fi
  fi
  if [[ -n "$PORTAGE_PROFILE" && "$DRY_RUN" -eq 0 ]]; then
    chroot_exec "eselect profile set '${PORTAGE_PROFILE}'" || warn "eselect profile set fallito (usare indice numerico se il nome non basta)"
  fi
}

step_timezone() {
  log "=== Timezone (Europe/Rome) ==="
  if [[ "$DRY_RUN" -eq 0 ]]; then
    chroot_exec "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"
    chroot_exec "sh -c \"echo '${TIMEZONE}' > /etc/timezone\"" 2>/dev/null || true
  fi
}

step_locale() {
  log "=== Locale (it_IT.UTF-8) ==="
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s\n' "${LOCALES//|/$'\n'}" >"${GENTOO_ROOT}/etc/locale.gen"
    chroot_exec "locale-gen"
    local first
    first=$(printf '%s\n' "${LOCALES//|/$'\n'}" | awk 'NF{print $1; exit}')
    if [[ -n "$first" ]]; then
      echo "LANG=${first}" >"${GENTOO_ROOT}/etc/env.d/02locale"
    fi
  fi
}

step_fstab() {
  log "=== /etc/fstab (Handbook: UUID) ==="
  if parts_load_for_mount && [[ -n "${DISK_ROOT_PART:-}" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] generazione fstab da UUID partizioni note"
      return 0
    fi
    local u_efi u_swap u_root
    u_root=$(blkid -s UUID -o value "${DISK_ROOT_PART}")
    [[ -n "$u_root" ]] || err "blkid UUID root mancante per ${DISK_ROOT_PART}"
    {
      printf '%s\n' "# /etc/fstab - generato da gentoo-install-assistant (UUID come da Handbook)"
      if [[ -n "${DISK_ESP_PART:-}" ]]; then
        u_efi=$(blkid -s UUID -o value "${DISK_ESP_PART}")
        [[ -n "$u_efi" ]] || err "blkid UUID EFI mancante per ${DISK_ESP_PART}"
        printf '%s\n' "UUID=${u_efi}	/boot/efi	vfat	defaults,noatime	0 2"
      fi
      if [[ -n "${DISK_SWAP_PART:-}" ]]; then
        u_swap=$(blkid -s UUID -o value "${DISK_SWAP_PART}")
        [[ -n "$u_swap" ]] || err "blkid UUID swap mancante per ${DISK_SWAP_PART}"
        printf '%s\n' "UUID=${u_swap}	none		swap	sw	0 0"
      fi
      printf '%s\n' "UUID=${u_root}	/		xfs	defaults,noatime	0 1"
    } >"${GENTOO_ROOT}/etc/fstab"
    ok "Scritto ${GENTOO_ROOT}/etc/fstab con UUID (righe secondo partizioni definite)."
    return 0
  fi
  warn "Senza partizionamento automatico: rivedere fstab a mano nel chroot (UUID consigliati)."
  if prompt_yn n "Mostrare blkid per copia manuale in /etc/fstab?"; then
    blkid
  fi
}

step_hostname() {
  log "=== Hostname / hosts ==="
  prompt_val "$HOSTNAME" HOSTNAME "Hostname"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "$HOSTNAME" >"${GENTOO_ROOT}/etc/hostname"
    cat >"${GENTOO_ROOT}/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain	${HOSTNAME}
EOF
  fi
}

step_kernel() {
  log "=== Kernel binario + dracut + installkernel (Handbook / wiki Dracut) ==="
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "${GENTOO_ROOT}/etc/portage/package.use"
    # installkernel-gentoo: USE dracut (initramfs); niente heredoc cosi non si rischia il terminatore PKUSE spostato
    printf '%s\n' \
      '# gentoo-install-assistant: kernel binario con initramfs dracut' \
      'sys-kernel/installkernel-gentoo dracut' \
      >"${GENTOO_ROOT}/etc/portage/package.use/50-installkernel-dracut"
  fi
  # Prima dracut + installkernel (USE dracut), poi il kernel binario così gli hook generano l'initramfs.
  chroot_exec "emerge -av sys-kernel/dracut sys-kernel/installkernel-gentoo" || \
    warn "Emerge dracut/installkernel fallito (wiki: Dracut, installkernel-gentoo)."
  chroot_exec "emerge -av sys-kernel/gentoo-kernel-bin" || \
    warn "Emerge gentoo-kernel-bin fallito: profilo Portage, USE e wiki Gentoo Kernel."
}

step_tools() {
  log "=== Strumenti di sistema (Handbook: installing tools) ==="
  prompt_val "$EXTRA_PACKAGES" EXTRA_PACKAGES "Pacchetti extra (spazio separato)"
  if [[ -n "$EXTRA_PACKAGES" ]]; then
    chroot_exec "emerge -av ${EXTRA_PACKAGES}"
  fi
  if [[ "$SET_ROOT_PASSWORD" -eq 1 && "$NONINTERACTIVE" -ne 1 ]]; then
    warn "Impostare password root nel chroot."
    if [[ "$DRY_RUN" -eq 0 ]]; then
      chroot "$GENTOO_ROOT" /bin/passwd
    fi
  fi
}

step_bootloader() {
  log "=== Bootloader ==="
  prompt_val "$BOOTLOADER" BOOTLOADER "Bootloader: grub-efi|grub-bios|skip"
  case "$BOOTLOADER" in
    skip) warn "Bootloader saltato." ;;
    grub-efi)
      parts_load_for_mount 2>/dev/null || true
      [[ -n "$ESP_DEVICE" ]] || ESP_DEVICE="${DISK_ESP_PART:-}"
      prompt_val "$ESP_DEVICE" ESP_DEVICE "Partizione EFI (es. /dev/nvme0n1p1)"
      [[ -n "$ESP_DEVICE" ]] || err "ESP_DEVICE obbligatorio per grub-efi"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        mkdir -p "${GENTOO_ROOT}/boot/efi"
        mount "$ESP_DEVICE" "${GENTOO_ROOT}/boot/efi" || warn "Mount EFI fallito (già montato?)"
        chroot_exec "emerge -av sys-boot/grub"
        chroot_exec "grub-install --target=x86_64-efi --efi-directory=/boot/efi"
        chroot_exec "grub-mkconfig -o /boot/grub/grub.cfg"
      fi
      ;;
    grub-bios)
      prompt_val "$GRUB_BIOS_DISK" GRUB_BIOS_DISK "Disco BIOS per grub-install (es. /dev/sda)"
      [[ -n "$GRUB_BIOS_DISK" ]] || err "GRUB_BIOS_DISK obbligatorio"
      chroot_exec "emerge -av sys-boot/grub"
      chroot_exec "grub-install ${GRUB_BIOS_DISK}"
      chroot_exec "grub-mkconfig -o /boot/grub/grub.cfg"
      ;;
    *)
      err "BOOTLOADER sconosciuto"
      ;;
  esac
}

step_finalize() {
  log "=== Finalizzazione ==="
  cat <<EOF
Checklist manuale (Handbook: finalizing):
  - utenti non-root, gruppi, sudo
  - firmware (linux-firmware), microcode CPU
  - rete permanente (net.* / systemd-networkd)
  - servizi (cron, logger, sshd)
  - uscire da chroot, swapoff se avevi swapon sulla partizione swap, smontare in ordine inverso: umount -R ${GENTOO_ROOT}

Riferimento: https://wiki.gentoo.org/wiki/Handbook:${GENTOO_ARCH}/Installation/Finalizing
EOF
  save_state "done"
  ok "Fine flusso assistito."
}

ORDER=(intro network disks mount stage3 portage chroot profile timezone locale fstab hostname kernel tools bootloader finalize)

main() {
  parse_args "$@"
  load_config
  require_root
  apply_install_policy
  touch "$LOG_FILE"
  log "Avvio gentoo-install-assistant ${SCRIPT_VERSION}"

  local s
  for s in "${ORDER[@]}"; do
    if step_should_run "$s"; then
      "step_${s}"
      save_state "$s"
    else
      log "Salto step $s (before --from-step)"
    fi
  done
}

main "$@"
require_disk_tools() {
  command -v parted >/dev/null 2>&1 || err "Serve parted (presente sulla live Gentoo)."
  command -v mkfs.xfs >/dev/null 2>&1 || err "Serve xfsprogs (mkfs.xfs)."
  command -v mkfs.vfat >/dev/null 2>&1 || err "Serve dosfstools (mkfs.vfat) per la EFI."
  command -v wipefs >/dev/null 2>&1 || err "Serve wipefs (util-linux)."
}

load_parts_state() {
  [[ -f "$PARTS_STATE" ]] || return 1
  # shellcheck source=/dev/null
  source "$PARTS_STATE"
  [[ "${DISK_LAYOUT_AUTO:-}" == "1" ]] || return 1
  return 0
}

# Layout Handbook UEFI: GPT, partizione ESP (vfat), swap, root XFS.
disk_auto_partition_format() {
  local disk=$1
  local esp_end swap_end
  esp_end=$((1 + DISK_ESP_MIB))
  swap_end=$((esp_end + DISK_SWAP_MIB))
  local p1 p2 p3
  p1=$(disk_part_path "$disk" 1)
  p2=$(disk_part_path "$disk" 2)
  p3=$(disk_part_path "$disk" 3)

  log "Layout: GPT | 1:EFI vfat 1MiB-${esp_end}MiB | 2:swap ${esp_end}MiB-${swap_end}MiB | 3:root xfs ${swap_end}MiB-100%"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] parted/wipefs/mkfs su $disk"
    return 0
  fi

  wipefs -a --all "$disk" 2>/dev/null || true
  parted -s "$disk" mklabel gpt
  parted -s "$disk" unit MiB mkpart esp fat32 1 "${esp_end}"
  parted -s "$disk" set 1 esp on
  parted -s "$disk" unit MiB mkpart swap linux-swap "${esp_end}" "${swap_end}"
  parted -s "$disk" unit MiB mkpart root xfs "${swap_end}" 100%
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 2

  [[ -b "$p1" && -b "$p2" && -b "$p3" ]] || err "Partizioni attese non trovate: $p1 $p2 $p3"

  mkfs.vfat -F32 -n EFI "$p1"
  mkswap -L swap "$p2"
  mkfs.xfs -f -L root "$p3"

  printf '%s\n' \
    "DISK_LAYOUT_AUTO=1" \
    "DISK_ESP_PART=${p1}" \
    "DISK_SWAP_PART=${p2}" \
    "DISK_ROOT_PART=${p3}" \
    "DISK_TARGET=${disk}" \
    >"$PARTS_STATE"
  ESP_DEVICE="$p1"
  ok "Partizioni create; stato salvato in ${PARTS_STATE}"
}

save_state() { echo "$1" >"$STATE_FILE"; }
get_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo ""; }

step_should_run() {
  local step=$1
  local order=(intro network disks mount stage3 portage chroot profile timezone locale fstab hostname kernel tools bootloader finalize)
  local i from_idx=0 step_idx=-1
  if [[ -z "$FROM_STEP" ]]; then
    return 0
  fi
  for i in "${!order[@]}"; do
    [[ "${order[$i]}" == "$FROM_STEP" ]] && from_idx=$i
    [[ "${order[$i]}" == "$step" ]] && step_idx=$i
  done
  [[ "$step_idx" -ge "$from_idx" ]]
}

prompt_yn() {
  local def=$1; shift
  local q=$1
  [[ "$NONINTERACTIVE" -eq 1 ]] && { [[ "$def" == "y" ]]; return; }
  local a
  read -r -p "$q [${def}] " a || true
  a=${a:-$def}
  [[ "${a,,}" == "y" || "${a,,}" == "s" || "${a,,}" == "yes" || "${a,,}" == "si" ]]
}

prompt_val() {
  local def=$1; shift
  local var=$1; shift
  local q=$1
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    printf -v "$var" '%s' "${!var:-$def}"
    return
  fi
  local cur="${!var:-$def}"
  read -r -p "$q [${cur}] " input || true
  printf -v "$var" '%s' "${input:-$cur}"
}

step_intro() {
  log "=== Introduzione (Handbook: scelta media, panoramica) ==="
  cat <<EOF

Questo script guida le fasi del Gentoo Handbook:AMD64 (solo architettura amd64 / x86-64).
- Target hardware di riferimento: Geekom Mini IT13, Intel Core i9-13900HK (Raptor Lake).
- Stage fisso: desktop, OpenRC. Kernel: pacchetto binario ufficiale + dracut + installkernel-gentoo.
- Timezone Europe/Rome, locale principale it_IT.UTF-8; COMMON_FLAGS con -march=native sullo stesso PC.
- Dischi: con DISK_AUTO=1 lo script crea GPT + EFI + swap + root XFS e monta su /mnt/gentoo; altrimenti partizioni a mano come nel manuale.
- Dopo ogni blocco critico puoi interrompere (Ctrl+C) e riprendere con --from-step.

Manuale: https://wiki.gentoo.org/wiki/Handbook:${GENTOO_ARCH}

Versione script: ${SCRIPT_VERSION}
EOF
  prompt_yn n "Continuare?" || exit 0
}

step_network() {
  log "=== Rete (Handbook: configuring the network) ==="
  if ip route 2>/dev/null | grep -q default || ip -4 addr show scope global 2>/dev/null | grep -q inet; then
    ok "Sembra esserci connettività IP."
  else
    warn "Nessuna route default evidente. Configurare la rete (dhcpcd, iproute2, NetworkManager) prima di scaricare lo stage3."
    prompt_yn n "Procedere comunque?" || exit 1
  fi
}

step_disks() {
  log "=== Dischi (Handbook: preparing the disks) ==="
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,TYPE 2>/dev/null || lsblk

  if [[ "${DISK_AUTO:-0}" == "1" ]]; then
    warn "DISK_AUTO=1: verranno cancellate tutte le partizioni su DISK_TARGET e creato GPT + EFI (vfat) + swap + root XFS."
    [[ -n "$DISK_TARGET" ]] || err "Con DISK_AUTO=1 impostare DISK_TARGET=/dev/... (disco intero, es. /dev/nvme0n1)."
    disk_is_whole_block "$DISK_TARGET" || err "DISK_TARGET deve essere un disco a blocchi intero (es. /dev/nvme0n1), non una partizione."
    disk_used_by_mounts "$DISK_TARGET" && err "Il disco ${DISK_TARGET} risulta in uso (montato). Smontare o usare un altro disco."
    require_disk_tools
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      [[ "$DISK_WIPE_CONFIRM" == "YES" ]] || err "In modalita non interattiva impostare DISK_WIPE_CONFIRM=YES per confermare la cancellazione del disco."
    else
      echo "Disco selezionato: ${DISK_TARGET}"
      prompt_yn n "Confermi la DISTRUZIONE di tutti i dati su ${DISK_TARGET}?" || err "Operazione annullata."
    fi
    disk_auto_partition_format "$DISK_TARGET"
    return 0
  fi

  echo "Partizionamento manuale (come da manuale): GPT, EFI System (vfat), swap opzionale, root XFS sotto ${GENTOO_ROOT}."
  echo "Riferimento: https://wiki.gentoo.org/wiki/Handbook:${GENTOO_ARCH}/Installation/Disks"
  echo "Per automatizzare: DISK_AUTO=1 DISK_TARGET=/dev/nvme0n1 (e DISK_WIPE_CONFIRM=YES se NONINTERACTIVE=1)."
  if ! prompt_yn y "Ho gia creato e formattato le partizioni (root XFS) necessarie"; then
    err "Completare il partizionamento o impostare DISK_AUTO=1, poi rilanciare con --from-step mount"
  fi
}

step_mount() {
  log "=== Mount filesystems (Handbook) ==="
  ok "Mount point root fisso: ${GENTOO_ROOT}"
  mkdir -p "$GENTOO_ROOT"

  if load_parts_state; then
    [[ -n "${DISK_ROOT_PART:-}" ]] || err "PARTS_STATE senza DISK_ROOT_PART"
    if mountpoint -q "$GENTOO_ROOT" 2>/dev/null; then
      ok "${GENTOO_ROOT} gia montato."
    else
      log "Mount root XFS: ${DISK_ROOT_PART} -> ${GENTOO_ROOT}"
      [[ "$DRY_RUN" -eq 1 ]] || mount -t xfs "${DISK_ROOT_PART}" "$GENTOO_ROOT"
    fi
    if [[ -n "${DISK_ESP_PART:-}" ]]; then
      mkdir -p "${GENTOO_ROOT}/boot/efi"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        mount -t vfat "${DISK_ESP_PART}" "${GENTOO_ROOT}/boot/efi" 2>/dev/null || \
          warn "Mount EFI su ${GENTOO_ROOT}/boot/efi fallito (gia montato?)"
      fi
      ESP_DEVICE="${DISK_ESP_PART}"
    fi
    if [[ -n "${DISK_SWAP_PART:-}" && "$DRY_RUN" -eq 0 ]]; then
      swapon "${DISK_SWAP_PART}" 2>/dev/null || warn "swapon ${DISK_SWAP_PART} non riuscito (opzionale in live)."
    fi
  else
    if mountpoint -q "$GENTOO_ROOT" 2>/dev/null; then
      ok "${GENTOO_ROOT} è già montato."
    else
      warn "${GENTOO_ROOT} non risulta montato. Montare manualmente la root XFS, ad es.:"
      echo "  mount -t xfs /dev/nvme0n1pX ${GENTOO_ROOT}"
      prompt_yn n "Ho montato la root XFS su ${GENTOO_ROOT} (verrà ricontrollato)" || err "Montare la root e ripetere."
    fi
  fi
  mountpoint -q "$GENTOO_ROOT" 2>/dev/null || err "${GENTOO_ROOT} non è un mountpoint: montare la partizione root e ripetere."
  # bind mounts per chroot successivo
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mount --make-rslave /dev 2>/dev/null || true
    mount --types proc /proc "${GENTOO_ROOT}/proc" 2>/dev/null || mount -t proc proc "${GENTOO_ROOT}/proc"
    mount --rbind /sys "${GENTOO_ROOT}/sys"
    mount --make-rslave "${GENTOO_ROOT}/sys"
    mount --rbind /dev "${GENTOO_ROOT}/dev"
    mount --make-rslave "${GENTOO_ROOT}/dev"
    if [[ -d /run ]]; then
      mount --rbind /run "${GENTOO_ROOT}/run"
      mount --make-rslave "${GENTOO_ROOT}/run"
    fi
    cp --dereference /etc/resolv.conf "${GENTOO_ROOT}/etc/resolv.conf" 2>/dev/null || warn "resolv.conf non copiato (normale se /etc/resolv.conf assente)."
  fi
  ok "Mount e bind completati (live → chroot)."
}

fetch_latest_stage3_url() {
  # Indice ufficiale: releases/<arch>/autobuilds/latest-stage3-<arch>-<init>.txt
  # Override: esportare GENTOO_STAGE_INDEX_URL per URL completo al file .txt
  local base="${GENTOO_MIRROR}/releases/${GENTOO_ARCH}/autobuilds"
  local latest
  if [[ -n "${GENTOO_STAGE_INDEX_URL:-}" ]]; then
    latest="$GENTOO_STAGE_INDEX_URL"
  else
    local suffix
    if [[ "$GENTOO_NOMULTILIB" == "1" ]]; then
      if [[ -n "$GENTOO_STAGE_FLAVOR" ]]; then
        suffix="${GENTOO_ARCH}-${GENTOO_STAGE_FLAVOR}-nomultilib-${GENTOO_INIT}"
      else
        suffix="${GENTOO_ARCH}-nomultilib-${GENTOO_INIT}"
      fi
    else
      if [[ -n "$GENTOO_STAGE_FLAVOR" ]]; then
        suffix="${GENTOO_ARCH}-${GENTOO_STAGE_FLAVOR}-${GENTOO_INIT}"
      else
        suffix="${GENTOO_ARCH}-${GENTOO_INIT}"
      fi
    fi
    latest="${base}/latest-stage3-${suffix}.txt"
  fi
  if ! curl -fsSL "$latest" -o /tmp/stage3-latest.txt 2>/dev/null; then
    if ! wget -q -O /tmp/stage3-latest.txt "$latest" 2>/dev/null; then
      err "Impossibile scaricare l'indice stage3: $latest (verificare arch/init o impostare GENTOO_STAGE_INDEX_URL)"
    fi
  fi
  local path
  path=$(grep -v '^#' /tmp/stage3-latest.txt | awk 'NF{print $1; exit}')
  [[ -n "$path" ]] || err "Formato latest-stage3 inatteso in $latest"
  echo "${base}/${path}"
}

step_stage3() {
  log "=== Stage3 amd64 desktop + OpenRC (Handbook:AMD64 / the stage file) ==="
  prompt_val "$GENTOO_MIRROR" GENTOO_MIRROR "Mirror Gentoo (base URL)"
  ok "Architettura fissa: amd64 - stage desktop-openrc (latest-stage3-amd64-desktop-openrc.txt)"
  if [[ -n "$(ls -A "$GENTOO_ROOT" 2>/dev/null | grep -v '^lost+found$' || true)" ]]; then
    warn "${GENTOO_ROOT} non è vuoto. Estrarre lo stage3 qui sovrascriverà file."
    prompt_yn n "Procedere con download ed estrazione?" || return 0
  fi
  local url
  url=$(fetch_latest_stage3_url)
  log "URL stage3: $url"
  local tarball="/tmp/$(basename "$url")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    curl -fL "$url" -o "$tarball" || wget -O "$tarball" "$url" || err "Download fallito"
    # Verifica opzionale checksum (DIGESTS sul mirror)
    warn "Verifica firma/checksum: consultare il manuale (openssl / gpg) per il file DIGESTS associato."
    tar xpf "$tarball" -C "$GENTOO_ROOT" --xattrs-include='*.*' --numeric-owner || err "Estrazione stage3 fallita"
    rm -f "$tarball"
  fi
  ok "Stage3 installato in ${GENTOO_ROOT}"
}

write_make_conf() {
  local mc="${GENTOO_ROOT}/etc/portage/make.conf"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] aggiornerei ${mc}"
    return
  fi
  mkdir -p "${GENTOO_ROOT}/etc/portage"
  if [[ -f "$mc" ]]; then
    cp -a "$mc" "${mc}.bak.gentoo-install-assistant"
    warn "Backup make.conf: ${mc}.bak.gentoo-install-assistant"
  fi
  cat >"$mc" <<EOF
# Generato da gentoo-install-assistant.sh - rivedere USE e mirror (manuale Portage)
# Riferimento HW: Geekom Mini IT13, Intel Core i9-13900HK (Raptor Lake, amd64).
# COMMON_FLAGS=-march=native ottimizza per la CPU del sistema usato durante emerge (stesso IT13).
COMMON_FLAGS="${COMMON_FLAGS}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="${MAKEOPTS}"

GENTOO_MIRRORS="${GENTOO_MIRROR} https://distfiles.gentoo.org"
EOF
  ok "make.conf scritto."
}

step_portage() {
  log "=== Portage / make.conf (Handbook: configuring compile options) ==="
  ok "COMMON_FLAGS fissi dalla policy: ${COMMON_FLAGS} (amd64 / i9-13900HK su Geekom IT13: vedi commenti in make.conf)"
  prompt_val "$MAKEOPTS" MAKEOPTS "MAKEOPTS (i9-13900HK: spesso -j16 … -j20; su questo host nproc=$(nproc))"
  write_make_conf
}

step_chroot() {
  log "=== Ambiente chroot (Handbook: installing base system) ==="
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] emerge-webrsync / preparazione chroot"
    return
  fi
  if [[ "$DO_PORTAGE_SYNC" -eq 1 ]]; then
    chroot_exec "emerge-webrsync" || warn "emerge-webrsync fallito (rete?); provare emerge --sync manualmente."
  else
    warn "DO_PORTAGE_SYNC=0: saltato emerge-webrsync."
  fi
}

step_profile() {
  log "=== Selezione profilo Portage ==="
  if [[ -z "$PORTAGE_PROFILE" ]]; then
    if [[ "$NONINTERACTIVE" -ne 1 ]]; then
      chroot_exec "eselect profile list || true"
      read -r -p "Indice o nome profilo per eselect profile set (vuoto = nessun cambio): " PORTAGE_PROFILE || true
    fi
  fi
  if [[ -n "$PORTAGE_PROFILE" && "$DRY_RUN" -eq 0 ]]; then
    chroot_exec "eselect profile set '${PORTAGE_PROFILE}'" || warn "eselect profile set fallito (usare indice numerico se il nome non basta)"
  fi
}

step_timezone() {
  log "=== Timezone (Europe/Rome) ==="
  if [[ "$DRY_RUN" -eq 0 ]]; then
    chroot_exec "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"
    chroot_exec "sh -c \"echo '${TIMEZONE}' > /etc/timezone\"" 2>/dev/null || true
  fi
}

step_locale() {
  log "=== Locale (it_IT.UTF-8) ==="
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s\n' "${LOCALES//|/$'\n'}" >"${GENTOO_ROOT}/etc/locale.gen"
    chroot_exec "locale-gen"
    local first
    first=$(printf '%s\n' "${LOCALES//|/$'\n'}" | awk 'NF{print $1; exit}')
    if [[ -n "$first" ]]; then
      echo "LANG=${first}" >"${GENTOO_ROOT}/etc/env.d/02locale"
    fi
  fi
}

step_fstab() {
  log "=== /etc/fstab (Handbook: UUID) ==="
  if load_parts_state && [[ -n "${DISK_ROOT_PART:-}" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] generazione fstab da UUID partizioni automatiche"
      return 0
    fi
    local u_efi u_swap u_root
    u_efi=$(blkid -s UUID -o value "${DISK_ESP_PART}")
    u_swap=$(blkid -s UUID -o value "${DISK_SWAP_PART}")
    u_root=$(blkid -s UUID -o value "${DISK_ROOT_PART}")
    [[ -n "$u_efi" && -n "$u_swap" && -n "$u_root" ]] || err "blkid UUID incompleto (efi/swap/root)."
    cat >"${GENTOO_ROOT}/etc/fstab" <<FSTAB
# /etc/fstab - generato da gentoo-install-assistant (UUID come da Handbook)
UUID=${u_efi}	/boot/efi	vfat	defaults,noatime	0 2
UUID=${u_swap}	none		swap	sw	0 0
UUID=${u_root}	/		xfs	defaults,noatime	0 1
FSTAB
    ok "Scritto ${GENTOO_ROOT}/etc/fstab con UUID (EFI, swap, root XFS)."
    return 0
  fi
  warn "Senza partizionamento automatico: rivedere fstab a mano nel chroot (UUID consigliati)."
  if prompt_yn n "Mostrare blkid per copia manuale in /etc/fstab?"; then
    blkid
  fi
}

step_hostname() {
  log "=== Hostname / hosts ==="
  prompt_val "$HOSTNAME" HOSTNAME "Hostname"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "$HOSTNAME" >"${GENTOO_ROOT}/etc/hostname"
    cat >"${GENTOO_ROOT}/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain	${HOSTNAME}
EOF
  fi
}

step_kernel() {
  log "=== Kernel binario + dracut + installkernel (Handbook / wiki Dracut) ==="
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "${GENTOO_ROOT}/etc/portage/package.use"
    # installkernel-gentoo: USE dracut (initramfs); niente heredoc cosi non si rischia il terminatore PKUSE spostato
    printf '%s\n' \
      '# gentoo-install-assistant: kernel binario con initramfs dracut' \
      'sys-kernel/installkernel-gentoo dracut' \
      >"${GENTOO_ROOT}/etc/portage/package.use/50-installkernel-dracut"
  fi
  # Prima dracut + installkernel (USE dracut), poi il kernel binario così gli hook generano l'initramfs.
  chroot_exec "emerge -av sys-kernel/dracut sys-kernel/installkernel-gentoo" || \
    warn "Emerge dracut/installkernel fallito (wiki: Dracut, installkernel-gentoo)."
  chroot_exec "emerge -av sys-kernel/gentoo-kernel-bin" || \
    warn "Emerge gentoo-kernel-bin fallito: profilo Portage, USE e wiki Gentoo Kernel."
}

step_tools() {
  log "=== Strumenti di sistema (Handbook: installing tools) ==="
  prompt_val "$EXTRA_PACKAGES" EXTRA_PACKAGES "Pacchetti extra (spazio separato)"
  if [[ -n "$EXTRA_PACKAGES" ]]; then
    chroot_exec "emerge -av ${EXTRA_PACKAGES}"
  fi
  if [[ "$SET_ROOT_PASSWORD" -eq 1 && "$NONINTERACTIVE" -ne 1 ]]; then
    warn "Impostare password root nel chroot."
    if [[ "$DRY_RUN" -eq 0 ]]; then
      chroot "$GENTOO_ROOT" /bin/passwd
    fi
  fi
}

step_bootloader() {
  log "=== Bootloader ==="
  prompt_val "$BOOTLOADER" BOOTLOADER "Bootloader: grub-efi|grub-bios|skip"
  case "$BOOTLOADER" in
    skip) warn "Bootloader saltato." ;;
    grub-efi)
      load_parts_state 2>/dev/null || true
      [[ -n "$ESP_DEVICE" ]] || ESP_DEVICE="${DISK_ESP_PART:-}"
      prompt_val "$ESP_DEVICE" ESP_DEVICE "Partizione EFI (es. /dev/nvme0n1p1)"
      [[ -n "$ESP_DEVICE" ]] || err "ESP_DEVICE obbligatorio per grub-efi"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        mkdir -p "${GENTOO_ROOT}/boot/efi"
        mount "$ESP_DEVICE" "${GENTOO_ROOT}/boot/efi" || warn "Mount EFI fallito (già montato?)"
        chroot_exec "emerge -av sys-boot/grub"
        chroot_exec "grub-install --target=x86_64-efi --efi-directory=/boot/efi"
        chroot_exec "grub-mkconfig -o /boot/grub/grub.cfg"
      fi
      ;;
    grub-bios)
      prompt_val "$GRUB_BIOS_DISK" GRUB_BIOS_DISK "Disco BIOS per grub-install (es. /dev/sda)"
      [[ -n "$GRUB_BIOS_DISK" ]] || err "GRUB_BIOS_DISK obbligatorio"
      chroot_exec "emerge -av sys-boot/grub"
      chroot_exec "grub-install ${GRUB_BIOS_DISK}"
      chroot_exec "grub-mkconfig -o /boot/grub/grub.cfg"
      ;;
    *)
      err "BOOTLOADER sconosciuto"
      ;;
  esac
}

step_finalize() {
  log "=== Finalizzazione ==="
  cat <<EOF
Checklist manuale (Handbook: finalizing):
  - utenti non-root, gruppi, sudo
  - firmware (linux-firmware), microcode CPU
  - rete permanente (net.* / systemd-networkd)
  - servizi (cron, logger, sshd)
  - uscire da chroot, smontare in ordine inverso: umount -R ${GENTOO_ROOT}

Riferimento: https://wiki.gentoo.org/wiki/Handbook:${GENTOO_ARCH}/Installation/Finalizing
EOF
  save_state "done"
  ok "Fine flusso assistito."
}

ORDER=(intro network disks mount stage3 portage chroot profile timezone locale fstab hostname kernel tools bootloader finalize)

main() {
  parse_args "$@"
  load_config
  require_root
  apply_install_policy
  touch "$LOG_FILE"
  log "Avvio gentoo-install-assistant ${SCRIPT_VERSION}"

  local s
  for s in "${ORDER[@]}"; do
    if step_should_run "$s"; then
      "step_${s}"
      save_state "$s"
    else
      log "Salto step $s (before --from-step)"
    fi
  done
}

main "$@"
