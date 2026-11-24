#!/usr/bin/env bash
# Création d'une VM Always Free OCI : VM.Standard.A1.Flex, 2 OCPU, 12 Go RAM, Ubuntu 24.04 ARM.
# Boucle de retry sur l'erreur "Out of host capacity" jusqu'à obtention de la VM.
#
# Codes de sortie :
#   0 = VM créée (ou déjà existante)   1 = erreur bloquante   2 = pas de capacité dans le délai imparti
#
# Surcharge possible par variables d'environnement : OCI_COMPARTMENT, OCI_AD, OCI_SUBNET,
# OCI_IMAGE, SSH_KEY_FILE, BOOT_VOLUME_GB, RETRY_INTERVAL, MAX_DURATION, LOG_FILE, INSTANCE_NAME
set -uo pipefail

export SUPPRESS_LABEL_WARNING=True

# --- Configuration (valeurs locales par défaut) ---
COMPARTMENT_ID="${OCI_COMPARTMENT:-ocid1.tenancy.oc1..aaaaaaaau627p24dptj2xafnhnpvdaelt3ypv4xoiljg4lbt6bfw32w66dfq}"
AD_ID="${OCI_AD:-KwvT:EU-PARIS-1-AD-1}"   # nom de l'AD (l'API attend le nom, pas l'OCID)
SUBNET_ID="${OCI_SUBNET:-ocid1.subnet.oc1.eu-paris-1.aaaaaaaaxzp7deviy2bitjjtei5zisu5cm3gknwjf66d7d4xjjds75nwglmq}"
IMAGE_ID="${OCI_IMAGE:-ocid1.image.oc1.eu-paris-1.aaaaaaaaxx5dgivegq7hf75j47ielh3dudyk7b2mpyc2dg2yyzvvmet6rvfa}" # Canonical-Ubuntu-24.04-aarch64-2026.11.05-0
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"

SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-150}"   # max gratuit = 200 Go ; 150 laisse ~50 Go pour une éventuelle 2e VM E2.Micro
INSTANCE_NAME="${INSTANCE_NAME:-vm-free-arm}"

RETRY_INTERVAL="${RETRY_INTERVAL:-60}"    # secondes entre deux tentatives
MAX_DURATION="${MAX_DURATION:-86400}"     # arrêt après 24 h (0 = illimité)
LOG_FILE="${LOG_FILE:-$(dirname "$0")/create-vm.log}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

for f in "$SSH_KEY_FILE"; do
  [[ -r $f ]] || { log "FATAL: fichier illisible: $f"; exit 1; }
done

get_public_ip() {  # $1 = instance-id
  local vnic_id public_ip
  vnic_id=$(oci compute vnic-attachment list --compartment-id "$COMPARTMENT_ID" \
    --instance-id "$1" --query 'data[0]."vnic-id"' --raw-output 2>/dev/null)
  public_ip=$(oci network vnic get --vnic-id "$vnic_id" \
    --query 'data."public-ip"' --raw-output 2>/dev/null)
  echo "${public_ip:-attribution-en-cours}"
}

# VM déjà créée ? (relances successives, notamment en CI)
existing_id=$(oci compute instance list --compartment-id "$COMPARTMENT_ID" \
  --display-name "$INSTANCE_NAME" --all \
  --query 'data[?contains(["PROVISIONING","RUNNING","STARTING","STOPPED"], "lifecycle-state")] | [0].id' --raw-output 2>/dev/null)
if [[ -n ${existing_id:-} ]]; then
  log "=== VM DÉJÀ PRÉSENTE : $existing_id (état conservé, rien à faire) ==="
  log "IP publique : $(get_public_ip "$existing_id")"
  exit 0
fi

log "=== Démarrage : $SHAPE ${OCPUS} OCPU / ${MEMORY_GB} Go / boot ${BOOT_VOLUME_GB} Go ==="
start=$(date +%s)
attempt=0
instance_id=""

while true; do
  attempt=$((attempt + 1))
  output=$(oci compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AD_ID" \
    --display-name "$INSTANCE_NAME" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
    --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --ssh-authorized-keys-file "$SSH_KEY_FILE" 2>&1)

  if [[ $? -eq 0 ]]; then
    instance_id=$(oci compute instance list --compartment-id "$COMPARTMENT_ID" \
      --display-name "$INSTANCE_NAME" --lifecycle-state PROVISIONING --lifecycle-state RUNNING \
      --query 'data[0].id' --raw-output 2>/dev/null)
    if [[ -z $instance_id ]]; then
      # fallback : parsing de la sortie de launch
      instance_id=$(printf '%s' "$output" | grep -o 'ocid1.instance.oc1[^"]*' | head -1)
    fi
    log "SUCCESS à la tentative $attempt : $instance_id"
    break
  fi

  if printf '%s' "$output" | grep -qiE 'out of (host )?capacity'; then
    log "Tentative $attempt : Out of host capacity — retry dans ${RETRY_INTERVAL}s"
  elif printf '%s' "$output" | grep -q 'TooManyRequests'; then
    log "Tentative $attempt : 429 TooManyRequests (limitation de débit) — retry dans ${RETRY_INTERVAL}s"
  else
    log "FATAL (erreur non liée à la capacité, arrêt) :"
    printf '%s\n' "$output" | tee -a "$LOG_FILE"
    exit 1
  fi

  if (( MAX_DURATION > 0 )); then
    now=$(date +%s)
    if (( now - start >= MAX_DURATION )); then
      log "TIMEOUT : ${MAX_DURATION}s écoulées sans capacité disponible. Arrêt (code 2)."
      exit 2
    fi
  fi
  sleep "$RETRY_INTERVAL"
done

log "Attente de l'état RUNNING..."
oci compute instance get --instance-id "$instance_id" \
  --wait-for-state RUNNING --wait-interval-seconds 15 --wait-max-seconds 900 >/dev/null 2>&1
log "VM RUNNING."

public_ip=$(get_public_ip "$instance_id")
log "=== VM CRÉÉE ==="
log "Instance : $instance_id"
log "IP publique : ${public_ip}"
log "Connexion : ssh ubuntu@${public_ip}"
