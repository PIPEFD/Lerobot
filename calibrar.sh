#!/usr/bin/env bash
# calibrar.sh — Calibración vía API (Phospho)
# Requisitos: bash, curl, jq

set -euo pipefail

HOST="${HOST:-localhost}"   # o phosphobot.local
PORT="${PORT:-80}"
RID="${RID:-0}"             # id del robot (0 por defecto)

info(){ printf "\033[1m[INFO]\033[0m %s\n" "$*"; }
err(){  printf "\033[31m[ERROR]\033[0m %s\n" "$*" 1>&2; }

# Comprueba si un JSON contiene scalars problemáticos ("NaN", null o cadena vacía)
check_bad_response(){
  local json="$1"
  local bad
  bad=$(jq -r '([.. | scalars] | map(tostring) | map(select(.=="NaN" or .=="null" or .=="")) | length)'
         <<<"$json" 2>/dev/null || echo 0)
  if [ "${bad:-0}" -gt 0 ]; then
    return 1
  fi
  return 0
}

# Extrae un campo con jq y sustituye valores no numéricos por un valor por defecto
safe_jq(){
  local json="$1"; local expr="$2"; local def="${3:-0}"
  local out
  out=$(jq -r "${expr}" <<<"$json" 2>/dev/null || echo "${def}")
  if [ "${out}" = "NaN" ] || [ "${out}" = "null" ] || [ -z "${out}" ]; then
    echo "${def}"
  else
    echo "${out}"
  fi
}

post_nobody(){ # POST sin body JSON
  curl -fsS -X POST "http://${HOST}:${PORT}$1"
}

post_json(){   # POST con body JSON
  local endpoint="$1"; local json="${2:-{}}"
  curl -fsS -X POST "http://${HOST}:${PORT}${endpoint}" \
       -H "Content-Type: application/json" -d "${json}"
}

# 0) Inicializar el robot (posición segura de partida)
/bin/echo
info "Inicializando robot (move/init)…"
post_nobody "/move/init?robot_id=${RID}" | jq -r '.status,.message?' || true
# Doc: /move/init  [oai_citation:1‡docs.phospho.ai](https://docs.phospho.ai/control/move-init?utm_source=chatgpt.com)

# 1) (Opcional) Torque OFF explícito antes de calibrar (calibrar lo apagará igual)
info "Desactivando torque (por seguridad)…"
post_json "/torque/toggle?robot_id=${RID}" '{"torque_status": false}' | jq -r '.status,.message?' || true
# Doc: /torque/toggle  [oai_citation:2‡docs.phospho.ai](https://docs.phospho.ai/control/turn-torque)

# 2) Lanzar calibración y hacer polling hasta terminar
info "Iniciando calibración… (sujeta el brazo: el torque está OFF)"
resp="$(post_nobody "/calibrate?robot_id=${RID}")"
if ! check_bad_response "$resp"; then
  err "Respuesta con valores no numéricos durante calibración. Aborting."
  err "$resp"
  exit 1
fi
status="$(jq -r '.calibration_status // "error"' <<<"$resp")"
total="$(safe_jq "$resp" '.total_nb_steps // 0' 0)"
step="$(safe_jq "$resp" '.current_step // 0' 0)"
msg="$(jq -r '.message // ""' <<<"$resp")"
printf "  -> %s (%s/%s): %s\n" "$status" "$step" "$total" "$msg"

# Poll cada 2s hasta success / error
while [ "$status" = "in_progress" ]; do
  sleep 2
  resp="$(post_nobody "/calibrate?robot_id=${RID}")"
  if ! check_bad_response "$resp"; then
    err "Respuesta con valores no numéricos durante calibración (polling). Aborting."
    err "$resp"
    exit 1
  fi
  status="$(jq -r '.calibration_status // "error"' <<<"$resp")"
  step="$(safe_jq "$resp" '.current_step // 0' 0)"
  msg="$(jq -r '.message // ""' <<<"$resp")"
  printf "  -> %s (%s/%s): %s\n" "$status" "$step" "$total" "$msg"
done

if [ "$status" != "success" ]; then
  err "La calibración no terminó en success. Respuesta: $resp"
  exit 1
fi
info "Calibración COMPLETADA."

# 3a) Verificar que los joints leídos desde hardware no contienen NaN/null
info "Verificando joints leídos desde hardware (no debe contener NaN)…"
joints_resp="$(post_json "/joints/read?robot_id=${RID}" '{"unit":"rad","source":"robot"}')"
if ! check_bad_response "$joints_resp"; then
  err "Lectura de joints contiene valores no válidos (NaN/null). No se activará torque."
  err "$joints_resp"
  exit 1
fi
info "Lectura de joints OK (sin NaN)."

# Doc: /calibrate (status: in_progress|success|error)  [oai_citation:3‡docs.phospho.ai](https://docs.phospho.ai/control/calibration-sequence)

# 3) Re-activar torque
info "Re-activando torque…"
post_json "/torque/toggle?robot_id=${RID}" '{"torque_status": true}' | jq -r '.status,.message?'
# Doc: /torque/toggle  [oai_citation:4‡docs.phospho.ai](https://docs.phospho.ai/control/turn-torque)

# 4) Prueba rápida (movimiento pequeño desde la posición inicial)
# Nota: tras /move/init, (x=0,y=0,z=0) es la pose base; aquí subimos 2 cm en Z.
info "Prueba de movimiento absoluto: subir Z +2 cm (agarre abierto)…"
post_json "/move/absolute?robot_id=${RID}" '{"x":0,"y":0,"z":2,"open":1,"max_trials":10}' | jq -r '.status,.message?'
# Doc: /move/absolute  [oai_citation:5‡docs.phospho.ai](https://docs.phospho.ai/control/move-absolute-position)

# 5) Leer joints como verificación
info "Leyendo joints (rad) desde hardware…"
post_json "/joints/read?robot_id=${RID}" '{"unit":"rad","source":"robot"}' | jq
# Doc: /joints/read  [oai_citation:6‡docs.phospho.ai](https://docs.phospho.ai/control/read-joints?utm_source=chatgpt.com)

info "Listo ✅"