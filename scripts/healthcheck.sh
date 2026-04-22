#!/usr/bin/env bash
# Verifica se Flowable e a API produtora estão respondendo.
#
# Uso:
#   scripts/healthcheck.sh
#
# Variáveis opcionais:
#   FLOWABLE_URL   (default: http://localhost:8080/flowable-ui)
#   FLOWABLE_USER  (default: admin)
#   FLOWABLE_PASS  (default: test)
#   AURORA_API_URL (default: http://localhost:3000)
set -euo pipefail

FLOWABLE_URL="${FLOWABLE_URL:-http://localhost:8080/flowable-ui}"
FLOWABLE_USER="${FLOWABLE_USER:-admin}"
FLOWABLE_PASS="${FLOWABLE_PASS:-test}"
AURORA_API_URL="${AURORA_API_URL:-http://localhost:3000}"

check() {
  local label="$1" url="$2"; shift 2
  local code
  # -w já imprime 000 em caso de falha de rede; não concatenar outro fallback.
  code="$(curl -s -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null || true)"
  code="${code:-000}"
  printf '  %-22s %-55s HTTP %s\n' "$label" "$url" "$code"
  [[ "$code" =~ ^2 ]]
}

echo '== Healthcheck =='
ok=0
check 'Flowable REST'     "$FLOWABLE_URL/process-api/repository/process-definitions" -u "$FLOWABLE_USER:$FLOWABLE_PASS" || ok=1
check 'Aurora API /health' "$AURORA_API_URL/health" || ok=1

if [[ $ok -eq 0 ]]; then
  echo 'OK — tudo no ar.'
else
  echo 'Falhou — veja os códigos HTTP acima.' >&2
  exit 1
fi
