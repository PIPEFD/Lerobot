#!/usr/bin/env bash
# calibrar.sh — Calibración vía API (Phospho)
# Requisitos: bash, curl, jq

set -euo pipefail

HOST="${HOST:-localhost}"   # o phosphobot.local
PORT="${PORT:-80}"
RID="${RID:-0}"             # id del robot (0 por defecto)
SAVE_DIR="${SAVE_DIR:-/tmp}"
FORCE="false"
DRY_RUN="false"
SIMULATE="false"
POLL_INTERVAL="2"

info(){ printf "\033[1m[INFO]\033[0m %s\n" "$*"; }
err(){  printf "\033[31m[ERROR]\033[0m %s\n" "$*" 1>&2; }

usage(){
  cat <<EOF
Usage: $(basename "$0") [options]
Options:
  --host HOST           API host (default: $HOST)
  --port PORT           API port (default: $PORT)
  --rid ID              Robot id (default: $RID)
  --save-dir DIR        Directory to save failed JSON (default: $SAVE_DIR)
  --force               Force continue even if JSON contains NaN/null
  --dry-run             Do not perform HTTP requests (prints what would run)
  --simulate            Use simulated responses for testing
  --poll-interval SEC   Poll interval in seconds (default: $POLL_INTERVAL)
  -h, --help            Show this help
EOF
  exit 0
}

log(){
  # simple prefixed log for debug
  printf "[CALIBRAR] %s\n" "$*"
}

save_bad_json(){
  local json="$1"; local name="${2:-bad_response}"
  mkdir -p "$SAVE_DIR" 2>/dev/null || true
  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  local file="$SAVE_DIR/${name}_${ts}.json"
  printf "%s\n" "$json" > "$file"
  err "Saved bad JSON to: $file"
}

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
  local endpoint="$1"
  if [ "$DRY_RUN" = "true" ]; then
    log "DRY-RUN: POST http://${HOST}:${PORT}${endpoint}"
    echo "{}"
    return 0
  fi
  if [ "$SIMULATE" = "true" ]; then
    # simple simulate: return minimal progress JSON for /calibrate
    if [[ "$endpoint" == /calibrate* ]]; then
      printf '{"calibration_status":"success","total_nb_steps":10,"current_step":10,"message":"simulated"}'
      return 0
    fi
    if [[ "$endpoint" == /move/init* ]]; then
      printf '{"status":"ok","message":"simulated init"}'
      return 0
    fi
    echo "{}"
    return 0
  fi
  curl -fsS -X POST "http://${HOST}:${PORT}${endpoint}"
}

post_json(){   # POST con body JSON
  local endpoint="$1"; local json="${2:-{}}"
  if [ "$DRY_RUN" = "true" ]; then
    log "DRY-RUN: POST http://${HOST}:${PORT}${endpoint} -d '${json}'"
    echo "{}"
    return 0
  fi
  if [ "$SIMULATE" = "true" ]; then
    if [[ "$endpoint" == /joints/read* ]]; then
      printf '{"joints":[0.0,0.1,0.2,0.3,0.4,0.5]}'
      return 0
    fi
    echo "{}"
    return 0
  fi
  curl -fsS -X POST "http://${HOST}:${PORT}${endpoint}" \
       -H "Content-Type: application/json" -d "${json}"
}

# Parse CLI args (simple)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --rid) RID="$2"; shift 2;;
    --save-dir) SAVE_DIR="$2"; shift 2;;
    --force) FORCE="true"; shift 1;;
    --dry-run) DRY_RUN="true"; shift 1;;
    --simulate) SIMULATE="true"; shift 1;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2;;
    -h|--help) usage;;
    *) err "Unknown arg: $1"; usage;;
  esac
done

log "HOST=$HOST PORT=$PORT RID=$RID SAVE_DIR=$SAVE_DIR DRY_RUN=$DRY_RUN SIMULATE=$SIMULATE POLL_INTERVAL=$POLL_INTERVAL FORCE=$FORCE"

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
  err "Respuesta con valores no numéricos durante calibración."
  save_bad_json "$resp" calibrate_response
  if [ "$FORCE" != "true" ]; then
    err "Aborting (use --force to continue despite bad JSON)."
    exit 1
  else
    log "--force enabled: continuing despite bad JSON"
  fi
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
    err "Respuesta con valores no numéricos durante calibración (polling)."
    save_bad_json "$resp" calibrate_polling
    if [ "$FORCE" != "true" ]; then
      err "Aborting (use --force to continue despite bad JSON)."
      exit 1
    else
      log "--force enabled: continuing despite bad JSON"
    fi
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
  err "Lectura de joints contiene valores no válidos (NaN/null)."
  save_bad_json "$joints_resp" joints_read
  if [ "$FORCE" != "true" ]; then
    err "No se activará torque. Aborting (use --force to override)."
    exit 1
  else
    log "--force enabled: continuing despite invalid joints read"
  fi
else
  info "Lectura de joints OK (sin NaN)."
fi

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