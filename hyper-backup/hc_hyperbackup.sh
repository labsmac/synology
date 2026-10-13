#!/usr/bin/env bash
# ---------------------------------------------------------------
# Desarrollado por: Rodolfo Usquiano Moreno + ChatGPT :)
# Fecha: 13/10/2026
# Versión: 1.2
# Blog: https://www.labsmac.es/
# Linkedin: https://www.linkedin.com/in/rodolfo-usquiano/
# ---------------------------------------------------------------
#  hyperbackup-healthcheck.sh
#
#  Revisa TODAS las tareas de Hyper Backup del NAS y genera un
#  informe tabulado. El informe se muestra en consola/salida de
#  tarea programada y se envía vía HTTP POST a Healthchecks.
#
#  Si todas las tareas tienen un estado aceptable:
#       -> ping normal ($HC_URL)
#  Si alguna tarea está en estado NO aceptable:
#       -> ping a /fail ($HC_URL/fail)
#
#  Estados que fuerzan KO:
#       - restore_only: tarea dañada o disponible solo para restaurar
#       - unauth: error de autenticación
#
#  Healthchecks marcará el chequeo en verde o rojo según
#  la URL recibida. El cuerpo del POST es el informe en texto plano.
# ---------------------------------------------------------------

# 1) AJUSTES DE SEGURIDAD/ROBUSTEZ BASH ---------------------------
set -euo pipefail
IFS=$'\n\t'

# 2) CONFIGURACIÓN DE VARIABLES ------------------------------------

CONF="$(dirname "$0")/hc_hyperbackup.conf"
[ -r "$CONF" ] || { echo "Falta $CONF" >&2; exit 2; }
# shellcheck source=/dev/null

source "$CONF"
HC_FAIL_SUFFIX="/fail"
OK_VALUES=("done" "done_verify" "none")
KO_STATES=("restore_only" "unauth")
TAB=$'\t'
# -----------------------------------------------------------------

# 3) ARRAYS DONDE ACUMULAMOS LAS LÍNEAS DEL INFORME ---------------
declare -a ok_lines=()
declare -a ko_lines=()
declare -a tasks=()
# -----------------------------------------------------------------

# 4) FUNCIONES =====================================================

# 4.1) fetch_tasks: carga en tasks[] TODAS las tareas definidas
fetch_tasks() {
  mapfile -t tasks < <(
    synowebapi --exec \
      "api=SYNO.Backup.Task" "version=1" "method=list" 2>/dev/null |
    jq -r '.data.task_list[] | @base64'
  )
}

# 4.2) process_task: recibe JSON (base64), consulta su último estado
#       y lo clasifica en OK o KO.
process_task() {
  local task_b64="$1"
  local json

  json=$(echo "$task_b64" | base64 --decode)

  # Campos básicos de la tarea
  local id name state
  id=$(jq -r '.task_id' <<<"$json")
  name=$(jq -r '.name' <<<"$json")
  state=$(jq -r '.state // "unknown"' <<<"$json")

  # Consulta detallada: último resultado y hora de éxito
  local status
  status=$(synowebapi --exec \
    "api=SYNO.Backup.Task" "version=1" "method=status" \
    "task_id=$id" 'additional=["last_bkp_time","last_bkp_result"]' \
    2>/dev/null)

  local result success_time
  result=$(jq -r '.data.last_bkp_result // "none"' <<<"$status")
  success_time=$(jq -r '.data.last_bkp_success_time // "-"' <<<"$status")

  # Línea lista para imprimir/alinear por columnas
  local line="${id}${TAB}${name}${TAB}${state}${TAB}${success_time}${TAB}${result}"

  # VERSIÓN 1.2:
  # Los estados restore_only y unauth siempre son KO,
  # independientemente del resultado anterior de la copia.
  if printf '%s\n' "${KO_STATES[@]}" | grep -Fqx -- "$state"; then
    ko_lines+=("$line")
  elif printf '%s\n' "${OK_VALUES[@]}" | grep -Fqx -- "$result"; then
    ok_lines+=("$line")
  else
    ko_lines+=("$line")
  fi
}

# 4.3) print_section: imprime TÍTULO + CABECERA + todas las líneas
print_section() {
  local title="$1"
  local -n lines="$2"

  echo "$title"
  printf '%-6s  %-25s  %-15s  %-20s  %-s\n' \
    "ID" "NOMBRE" "ESTADO" "ULTIMA EJECUCION" "RESULTADO"

  if ((${#lines[@]} > 0)); then
    printf '%s\n' "${lines[@]}" |
      sort -t$'\t' -k1,1n |
      awk -F'\t' '{
        printf "%-6s  %-25s  %-15s  %-20s  %s\n",
        $1, $2, $3, $4, $5
      }'
  else
    echo "Sin tareas."
  fi

  echo
}

# 4.4) generate_report: concatena las dos secciones OK y KO
generate_report() {
  print_section "---- Tareas ejecutadas correctamente o sin ejecutar ----" ok_lines
  print_section "---- Tareas con errores, en ejecución o sin autenticación ----" ko_lines
}

# 4.5) send_report: muestra informe localmente y lo envía a Healthchecks
send_report() {
  local suffix="$1"
  local report

  report=$(generate_report)

  printf '%s\n' "$report"

  printf '%s\n' "$report" | curl -fsS --retry 3 -o /dev/null \
    -X POST -H "Content-Type: text/plain" \
    --data-binary @- "${HC_URL}${suffix}"
}

# 5) EJECUCIÓN PRINCIPAL ===========================================

fetch_tasks

for t in "${tasks[@]}"; do
  process_task "$t"
done

# 5.1) Decidir si se manda /fail y el código de salida
if [ "${#ko_lines[@]}" -eq 0 ]; then
  send_report ""
  exit 0
else
  send_report "${HC_FAIL_SUFFIX}"
  exit 1
fi
