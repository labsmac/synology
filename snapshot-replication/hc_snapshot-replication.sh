#!/usr/bin/env bash
# ---------------------------------------------------------------
# Desarrollado por: Rodolfo Usquiano Moreno + ChatGPT :)
# Fecha: 13/10/2026
# Versión: 1.0
# Blog: https://www.labsmac.es/
# Linkedin: https://www.linkedin.com/in/rodolfo-usquiano/
# ---------------------------------------------------------------
# ---------------------------------------------------------------
#  Snapshot Replication - Healthcheck V5
#  Envia informe a Healthchecks: /ping si todo OK, /fail si algo KO
# ---------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

HC_URL="https://hc.infotec-navarra.com/ping/eda23462-30dc-4da2-ba08-4b9c1ae013f3"
HC_FAIL_SUFFIX="/fail"

epoch_to_date() {
  local ts="$1"
  if [[ "$ts" =~ ^[0-9]+$ ]] && [[ "$ts" -gt 0 ]]; then
    date -d @"$ts" +"%Y-%m-%d %H:%M:%S"
  else
    echo "-"
  fi
}

# Cabecera de tabla (más espacio en columnas)
report=$(printf "%-35s %-25s %-12s\n" "SHARED FOLDER/LUN" "LAST RUN" "STATUS")

fail_found=0

# Obtener lista de planes
plan_ids=$(synowebapi -s --exec "api=SYNO.DR.Plan" "version=1" "method=list" 2>/dev/null \
  | jq -r '.data.plans[].plan_id')

for id in $plan_ids; do
  json=$(synowebapi -s --exec "api=SYNO.DR.Plan" "version=1" "method=info" "plan_id=\"$id\"" 2>/dev/null)

  folder=$(echo "$json" | jq -r '.data.target_name')
  ts=$(echo "$json" | jq -r '.data.last_op_info.update_time // 0')
  datetime=$(epoch_to_date "$ts")
  success=$(echo "$json" | jq -r '.data.last_op_info.is_success')
  site_status=$(echo "$json" | jq -r '.data.op_info.site_op_status.op_status_str' | xargs)

  if [ "$site_status" = "sync" ]; then
    status="sync"
  elif [ "$success" = "true" ]; then
    status="ok"
  else
    status="error"
  fi

  # Si no es "ok", marcamos fallo
  if [ "$status" != "ok" ]; then
    fail_found=1
  fi

  line=$(printf "%-35s %-25s %-12s\n" "$folder" "$datetime" "$status")
  report="${report}\n${line}"
done

# Mostrar informe por consola
echo -e "$report"

# Enviar a Healthchecks
if [ "$fail_found" -eq 0 ]; then
  echo -e "$report" | curl -fsS --retry 3 -o /dev/null \
    -X POST -H "Content-Type: text/plain" \
    --data-binary @- "$HC_URL"
  exit 0
else
  echo -e "$report" | curl -fsS --retry 3 -o /dev/null \
    -X POST -H "Content-Type: text/plain" \
    --data-binary @- "${HC_URL}${HC_FAIL_SUFFIX}"
  exit 1
fi
