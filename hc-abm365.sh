#!/usr/bin/env bash
# ---------------------------------------------------------------
# Desarrollado por: Rodolfo Usquiano Moreno + ChatGPT :)
# Fecha: 25/04/2025
# Versión: 1.0
# Blog: https://www.labsmac.es/
# Linkedin: https://www.linkedin.com/in/rodolfo-usquiano/
# ---------------------------------------------------------------
# Script para monitorizar las copias de Active Backup for Microsoft 365 de Synology enviando informes a Healthchecks.io
# ---------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

######################## CONFIG ##################################
HC_URL="URL-HEALTHECKS.IO"
HC_FAIL_SUFFIX="/fail"          # se añade cuando hay tareas KO o servicio parado
PARTIAL_OK=true                 # ¿aceptar PARTIAL/FAILURE como OK?
TAB=$'\t'                       # separador de columnas
SERVICE_NAME="pkg-ActiveBackup-Office365.service"
MSG_ERROR_APP="Servicio de Active Backup for Microsoft 365 no está activo"
##################################################################

# ---------- VERIFICAR ESTADO DEL SERVICIO -----------------------
status=$(synosystemctl get-active-status "$SERVICE_NAME" 2>/dev/null || echo "inactive")
if [[ "$status" != "active" ]]; then
  echo $MSG_ERROR_APP
  # Ping a Healthchecks con sufijo /fail
  curl -fsS --retry 3 -X POST -H 'Content-Type: text/plain' \
    --data-binary $MSG_ERROR_APP "${HC_URL}${HC_FAIL_SUFFIX}"
  exit 1
fi

# ---------- 1) OBTENER IDS DE TAREAS ----------------------------
mapfile -t IDS < <(
  synowebapi --exec api=SYNO.ActiveBackupOffice365 version=1 method=list_tasks \
    2>/dev/null | jq -r '.data.tasks[].task_id'
)

# ---------- 2) DESCARGAR LOGS (últimos 2000) --------------------
LOGS=$(synowebapi --exec api=SYNO.ActiveBackupOffice365 version=1 \
        method=get_general_log offset=0 limit=2000 2>/dev/null)

# ---------- ARRAYS PARA EL INFORME ------------------------------
declare -a ok_lines=()
declare -a ko_lines=()

# ---------- 3) PROCESAR CADA TAREA ------------------------------
for id in "${IDS[@]}"; do
  # último backup automático
  auto=$(jq -c --arg id "$id" '
    .data.logs | map(select(.category==0 and (.task_id|tostring)==$id))
    | sort_by(.timestamp) | last // empty
  ' <<<"$LOGS")

  # última cancelación
  cancel=$(jq -c --arg id "$id" '
    .data.logs
    | map(select(.category==3 and (.task_id|tostring)==$id and
                 (.description|test("canceled";"i"))))
    | sort_by(.timestamp) | last // empty
  ' <<<"$LOGS")

  # --------- determinar estado ----------------------------------
  if [[ -z $auto && -z $cancel ]]; then
    result="NO_LOGS"
    time="-"
    desc="Sin registros"
  else
    auto_ts=${auto:+$(jq -r '.timestamp' <<<"$auto")}
    cancel_ts=${cancel:+$(jq -r '.timestamp' <<<"$cancel")}

    if (( cancel_ts > auto_ts )); then
      result="CANCELED"
      ts=$cancel_ts
      desc=$(jq -r '.description' <<<"$cancel")
    else
      logt=$(jq -r '.log_type' <<<"$auto")
      result=$([[ $logt -eq 0 ]] && echo SUCCESS || echo PARTIAL/FAILURE)
      ts=$(jq -r '.timestamp' <<<"$auto")
      desc=$(jq -r '.description' <<<"$auto")
    fi

    desc=${desc#Backup task }                # limpio prefijo
    time=$(date -d "@$ts" '+%F %T')
  fi

  line="${id}${TAB}${time}${TAB}${result}${TAB}${desc}"

  if [[ $result == SUCCESS ]] || { $PARTIAL_OK && [[ $result == "PARTIAL/FAILURE" ]]; }; then
    ok_lines+=("$line")
  else
    ko_lines+=("$line")
  fi
 done

# ---------- 4) GENERAR INFORME TABULADO --------------------------
print_section() {
  local title="$1"; local -n arr="$2"
  echo "$title"
  printf '%-6s  %-19s  %-17s  %-s
' "ID" "ULTIMA EJECUCION" "RESULTADO" "DESCRIPCION"
  printf '%s
' "${arr[@]}" |
    sort -t$'\t' -k1,1n |
    awk -F$'\t' '{ printf "%-6s  %-19s  %-17s  %s\n", $1, $2, $3, $4 }'
  echo
}

generate_report() {
  print_section "---- Backups correctos ----" ok_lines
  print_section "---- Backups con errores / cancelados ----" ko_lines
}

# ---------- 5) ENVIAR INFORME A HEALTHCHECKS ---------------------
report=$(generate_report)
printf '%s
' "$report"

suffix=""
if [ "${#ko_lines[@]}" -ne 0 ]; then
  suffix="$HC_FAIL_SUFFIX"
fi

printf '%s
' "$report" | curl -fsS --retry 3 -o /dev/null \
  -X POST -H 'Content-Type: text/plain' \
  --data-binary @- "${HC_URL}${suffix}"

# ---------- 6) CÓDIGO DE SALIDA ----------------------------------
[ -z "$suffix" ] && exit 0 || exit 1
