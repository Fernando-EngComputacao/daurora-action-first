#!/usr/bin/env bash
# Completa a userTask "Análise Curatorial" (grupo curadores) de uma instância
# do processo credenciamentoChecador que já passou pela validação automática.
#
# Uso:
#   scripts/completar-tarefa.sh <processInstanceId> [credenciar|recusar]
#
# Variáveis opcionais:
#   FLOWABLE_URL   (default: http://localhost:8080/flowable-ui)
#   FLOWABLE_USER  (default: admin)
#   FLOWABLE_PASS  (default: test)
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Uso: $0 <processInstanceId> [credenciar|recusar]" >&2
  exit 2
fi

PID="$1"
DECISAO="${2:-credenciar}"

if [[ "$DECISAO" != "credenciar" && "$DECISAO" != "recusar" ]]; then
  echo "ERRO — decisão inválida: '$DECISAO' (esperado: credenciar | recusar)" >&2
  exit 2
fi

FLOWABLE_URL="${FLOWABLE_URL:-http://localhost:8080/flowable-ui}"
FLOWABLE_USER="${FLOWABLE_USER:-admin}"
FLOWABLE_PASS="${FLOWABLE_PASS:-test}"
AUTH=(-u "$FLOWABLE_USER:$FLOWABLE_PASS")

echo "==> Buscando task aberta para pid=$PID"
TASK_ID="$(curl -sS "${AUTH[@]}" \
  "$FLOWABLE_URL/process-api/runtime/tasks?processInstanceId=$PID" \
  | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4 || true)"

if [[ -z "$TASK_ID" ]]; then
  echo 'ERRO — nenhuma task aberta para esse processInstanceId.' >&2
  echo '       Possíveis causas: PID errado, documentos reprovados (processo já encerrou em endRejeitada), ou a validação ainda não retornou.' >&2
  exit 1
fi
echo "    task: $TASK_ID"

echo "==> Completando com decisaoFinal=$DECISAO"
curl -sS "${AUTH[@]}" -X POST \
  -H 'Content-Type: application/json' \
  -d "$(printf '{"action":"complete","variables":[{"name":"decisaoFinal","value":"%s"}]}' "$DECISAO")" \
  "$FLOWABLE_URL/process-api/runtime/tasks/$TASK_ID"
echo

echo '==> Verificando término'
END_ACTIVITY="$(curl -sS "${AUTH[@]}" \
  "$FLOWABLE_URL/process-api/history/historic-process-instances/$PID" \
  | grep -oE '"endActivityId":"[^"]+"' | cut -d'"' -f4 || true)"
echo "endActivityId: ${END_ACTIVITY:-<ainda em andamento>}"
