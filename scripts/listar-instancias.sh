#!/usr/bin/env bash
# Lista instâncias do processo credenciamentoChecador, imprimindo
# processInstanceId + businessKey (checadorId) + timestamps para copiar/colar
# no scripts/completar-tarefa.sh.
#
# Uso:
#   scripts/listar-instancias.sh                # ativas (default)
#   scripts/listar-instancias.sh concluidas     # últimas 20 concluídas
#
# Variáveis opcionais: FLOWABLE_URL, FLOWABLE_USER, FLOWABLE_PASS, PROCESS_KEY
set -euo pipefail

FLOWABLE_URL="${FLOWABLE_URL:-http://localhost:8080/flowable-ui}"
FLOWABLE_USER="${FLOWABLE_USER:-admin}"
FLOWABLE_PASS="${FLOWABLE_PASS:-test}"
PROCESS_KEY="${PROCESS_KEY:-credenciamentoChecador}"
AUTH=(-u "$FLOWABLE_USER:$FLOWABLE_PASS")

modo="${1:-ativas}"

case "$modo" in
  ativas|--ativas)
    url="$FLOWABLE_URL/process-api/runtime/process-instances?processDefinitionKey=$PROCESS_KEY&includeProcessVariables=true&size=50"
    titulo='ATIVAS'
    ;;
  concluidas|--concluidas|concluídas)
    url="$FLOWABLE_URL/process-api/history/historic-process-instances?processDefinitionKey=$PROCESS_KEY&finished=true&includeProcessVariables=true&size=20&sort=endTime&order=desc"
    titulo='CONCLUÍDAS (últimas 20)'
    ;;
  -h|--help)
    echo "Uso: $0 [ativas|concluidas]"
    exit 0
    ;;
  *)
    echo "Uso: $0 [ativas|concluidas]" >&2
    exit 2
    ;;
esac

echo "== Instâncias $titulo de $PROCESS_KEY =="

if ! command -v python3 >/dev/null 2>&1; then
  echo 'ERRO — python3 não encontrado no PATH.' >&2
  echo '       Alternativa manual:' >&2
  echo "       curl -sS -u $FLOWABLE_USER:$FLOWABLE_PASS '$url'" >&2
  exit 1
fi

PY_SCRIPT='
import json, sys
data = json.load(sys.stdin).get("data", [])
if not data:
    print("(nenhuma)")
    sys.exit(0)

def fmt_bool(v):
    if v is True:  return "true"
    if v is False: return "false"
    return "-"

def pick(vars_list, name):
    for v in vars_list or []:
        if v.get("name") == name:
            return v.get("value")
    return None

# Aspas simples p/ os literais dentro da f-string (Python não aceita backslash no {expr}):
hdr = (
    f"{'processInstanceId':<38}  {'businessKey':<36}  {'startTime':<20}  "
    f"{'end':<18}  {'docsValid':<10}  decisaoFinal"
)
print(hdr)
print("-" * len(hdr))
for p in data:
    pid = p.get("id", "")
    bk = p.get("businessKey") or "-"
    st = (p.get("startTime") or "")[:19]
    ea = p.get("endActivityId") or "(em andamento)"
    vars_list = p.get("variables") or p.get("processVariables") or []
    docs = fmt_bool(pick(vars_list, "documentosValidos"))
    decisao = pick(vars_list, "decisaoFinal") or "-"
    print(f"{pid:<38}  {bk:<36}  {st:<20}  {ea:<18}  {docs:<10}  {decisao}")
'

curl -sS "${AUTH[@]}" "$url" | python3 -c "$PY_SCRIPT"
