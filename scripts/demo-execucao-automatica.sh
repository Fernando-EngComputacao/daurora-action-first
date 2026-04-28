#!/usr/bin/env bash
# Roteiro reproduzível da demo "execução automática": dispara N
# credenciamentos via aurora-credenciamento-api, espera todos terminarem (com
# timeout) e imprime sumário com distribuição esperada (~80% docs válidos x
# ~70% credenciar = ~56% endCredenciado).
#
# Pré-requisitos: docker compose up + deploy-flowable.sh + os 3 microsserviços
# rodando (aurora-credenciamento-api, aurora-validador-docs, aurora-curador-mock).
#
# Uso:
#   scripts/demo-execucao-automatica.sh            # N=5
#   scripts/demo-execucao-automatica.sh 10
#   scripts/demo-execucao-automatica.sh 5 120      # N=5, timeout=120s
#
# Variáveis opcionais:
#   AURORA_API_URL  (default: http://localhost:3000)
#   FLOWABLE_URL    (default: http://localhost:8080/flowable-ui)
#   FLOWABLE_USER   (default: admin)
#   FLOWABLE_PASS   (default: test)
#
# Saída: exit 0 se todos terminaram dentro do timeout; !=0 caso contrário.
set -euo pipefail

N="${1:-5}"
TIMEOUT_S="${2:-60}"

AURORA_API_URL="${AURORA_API_URL:-http://localhost:3000}"
FLOWABLE_URL="${FLOWABLE_URL:-http://localhost:8080/flowable-ui}"
FLOWABLE_USER="${FLOWABLE_USER:-admin}"
FLOWABLE_PASS="${FLOWABLE_PASS:-test}"
AUTH=(-u "$FLOWABLE_USER:$FLOWABLE_PASS")

if ! command -v python3 >/dev/null 2>&1; then
  echo 'ERRO — python3 não encontrado no PATH (necessário para parse de JSON e estatísticas).' >&2
  exit 1
fi

if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 1 )); then
  echo "ERRO — N inválido: '$N' (esperado inteiro >=1)" >&2
  exit 2
fi
if ! [[ "$TIMEOUT_S" =~ ^[0-9]+$ ]] || (( TIMEOUT_S < 1 )); then
  echo "ERRO — timeout inválido: '$TIMEOUT_S' (esperado inteiro >=1)" >&2
  exit 2
fi

echo "== Demo execução automática =="
echo "  alvo:    $AURORA_API_URL"
echo "  flowable: $FLOWABLE_URL"
echo "  N=$N  timeout=${TIMEOUT_S}s"
echo

PIDS=()
CHECADORES=()

echo "==> Disparando $N credenciamento(s)"
for i in $(seq 1 "$N"); do
  nome="Demo Checador $i"
  docs="https://exemplo/demo-$i.pdf"
  payload="$(printf '{"nomeCompleto":"%s","documentos":"%s"}' "$nome" "$docs")"

  resp="$(curl -sS -X POST "$AURORA_API_URL/credenciamento" \
    -H 'Content-Type: application/json' \
    -d "$payload")"

  pid="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("processInstanceId",""))')"
  checador="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("checadorId",""))')"

  if [[ -z "$pid" ]]; then
    echo "ERRO — disparo $i não retornou processInstanceId. Resposta: $resp" >&2
    exit 1
  fi
  PIDS+=("$pid")
  CHECADORES+=("$checador")
  printf '  [%d/%d] pid=%s  checadorId=%s\n' "$i" "$N" "$pid" "$checador"
done
echo

# Polling: espera até todos terem endActivityId preenchido, ou timeout.
echo "==> Aguardando término (timeout ${TIMEOUT_S}s)"
deadline=$(( $(date +%s) + TIMEOUT_S ))
pendentes_n="$N"
while (( $(date +%s) < deadline )); do
  pendentes_n=0
  for pid in "${PIDS[@]}"; do
    end_act="$(curl -sS "${AUTH[@]}" \
      "$FLOWABLE_URL/process-api/history/historic-process-instances/$pid" \
      | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("endActivityId") or "")
except Exception:
    print("")')"
    if [[ -z "$end_act" ]]; then
      pendentes_n=$(( pendentes_n + 1 ))
    fi
  done
  if (( pendentes_n == 0 )); then
    break
  fi
  printf '  ...pendentes=%d\n' "$pendentes_n"
  sleep 2
done

# Coleta resultado final de cada instância.
RESULTS_JSON='['
sep=''
for idx in "${!PIDS[@]}"; do
  pid="${PIDS[$idx]}"
  checador="${CHECADORES[$idx]}"
  raw="$(curl -sS "${AUTH[@]}" "$FLOWABLE_URL/process-api/history/historic-process-instances/$pid")"
  RESULTS_JSON+="$sep{\"pid\":\"$pid\",\"checadorId\":\"$checador\",\"raw\":$raw}"
  sep=','
done
RESULTS_JSON+=']'

PY_REPORT='
import json, sys
from datetime import datetime

items = json.loads(sys.stdin.read())

def parse(ts):
    if not ts: return None
    # Flowable retorna ISO 8601 com offset (ex: 2026-04-28T12:34:56.123+0000).
    # Normaliza para fromisoformat aceitar.
    s = ts.replace("Z", "+00:00")
    if len(s) >= 5 and (s[-5] in "+-") and s[-3] != ":":
        s = s[:-2] + ":" + s[-2:]
    try:
        return datetime.fromisoformat(s)
    except Exception:
        return None

cols = ("pid", "checadorId", "endActivityId", "startTime", "endTime", "duration_ms")
header = "%-38s  %-36s  %-18s  %-23s  %-23s  %s" % cols
print(header)
print("-" * len(header))

duracoes = []
end_count = {}
pendentes = 0
for it in items:
    raw = it.get("raw") or {}
    pid = it["pid"]
    checador = it["checadorId"] or "-"
    end_act = raw.get("endActivityId") or "(em andamento)"
    st = parse(raw.get("startTime"))
    et = parse(raw.get("endTime"))
    dur_ms = ""
    if st and et:
        dur_ms = int((et - st).total_seconds() * 1000)
        duracoes.append(dur_ms)
    if end_act == "(em andamento)":
        pendentes += 1
    end_count[end_act] = end_count.get(end_act, 0) + 1
    st_s = (raw.get("startTime") or "")[:23]
    et_s = (raw.get("endTime") or "")[:23]
    print("%-38s  %-36s  %-18s  %-23s  %-23s  %s" % (pid, checador, end_act, st_s, et_s, dur_ms))

total = len(items)
print()
print("== Sumário ==")
print(f"  total:      {total}")
for k in sorted(end_count.keys()):
    pct = 100.0 * end_count[k] / total if total else 0.0
    print(f"  {k:<22} {end_count[k]:>3}  ({pct:5.1f}%)")

if duracoes:
    duracoes.sort()
    def pct(p):
        if not duracoes: return 0
        idx = max(0, min(len(duracoes)-1, int(round((p/100.0)*(len(duracoes)-1)))))
        return duracoes[idx]
    print(f"  duracao_ms p50/p95/max: {pct(50)} / {pct(95)} / {duracoes[-1]}")

# Exit code: 0 só se ninguém ficou pendente.
sys.exit(0 if pendentes == 0 else 3)
'

echo
exit_code=0
echo "$RESULTS_JSON" | python3 -c "$PY_REPORT" || exit_code=$?

if (( exit_code == 0 )); then
  echo
  echo 'OK — todas as instâncias terminaram dentro do timeout.'
else
  echo
  echo "FALHA — $pendentes_n instância(s) não terminaram em ${TIMEOUT_S}s. Verifique se os 3 microsserviços estão no ar." >&2
fi
exit $exit_code
