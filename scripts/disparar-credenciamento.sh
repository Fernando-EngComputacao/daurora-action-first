#!/usr/bin/env bash
# Dispara uma nova solicitação de credenciamento na API produtora
# (aurora-credenciamento-api), que por sua vez inicia uma instância do
# processo BPMN no Flowable.
#
# Uso:
#   scripts/disparar-credenciamento.sh
#   scripts/disparar-credenciamento.sh "Nome Completo" "https://exemplo/docs.pdf"
#
# Variáveis opcionais:
#   AURORA_API_URL (default: http://localhost:3000)
set -euo pipefail

AURORA_API_URL="${AURORA_API_URL:-http://localhost:3000}"
NOME="${1:-Maria Oliveira}"
DOCS="${2:-https://exemplo/maria.pdf}"

payload="$(printf '{"nomeCompleto":"%s","documentos":"%s"}' "$NOME" "$DOCS")"

echo "==> POST $AURORA_API_URL/credenciamento"
echo "    nomeCompleto: $NOME"
echo "    documentos:   $DOCS"
echo

response="$(curl -sS -X POST "$AURORA_API_URL/credenciamento" \
  -H 'Content-Type: application/json' \
  -d "$payload")"

echo "$response"
echo

# Extrai o processInstanceId só para facilitar o próximo passo (completar a task)
pid="$(echo "$response" | grep -oE '"processInstanceId":"[^"]+"' | cut -d'"' -f4 || true)"
if [[ -n "$pid" ]]; then
  echo "processInstanceId=$pid"
  echo "Próximo passo (quando documentos forem aprovados):"
  echo "  scripts/completar-tarefa.sh $pid credenciar"
fi
