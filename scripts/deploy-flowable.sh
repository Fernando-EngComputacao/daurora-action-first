#!/usr/bin/env bash
# Redeploy dos artefatos no Flowable UI: Event Registry (.event/.channel) + BPMN.
# Necessário após qualquer restart do container do Flowable, porque a imagem
# flowable-ui:latest (6.8.0) usa H2 in-memory.
#
# Uso:
#   scripts/deploy-flowable.sh
#
# Variáveis opcionais:
#   FLOWABLE_URL   (default: http://localhost:8080/flowable-ui)
#   FLOWABLE_USER  (default: admin)
#   FLOWABLE_PASS  (default: test)
set -euo pipefail

FLOWABLE_URL="${FLOWABLE_URL:-http://localhost:8080/flowable-ui}"
FLOWABLE_USER="${FLOWABLE_USER:-admin}"
FLOWABLE_PASS="${FLOWABLE_PASS:-test}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AUTH=(-u "$FLOWABLE_USER:$FLOWABLE_PASS")
EVENT_ENDPOINT="$FLOWABLE_URL/event-registry-api/event-registry-repository/deployments"
BPMN_ENDPOINT="$FLOWABLE_URL/process-api/repository/deployments"

echo "==> Flowable: $FLOWABLE_URL (user: $FLOWABLE_USER)"

# 1) Event Registry — um arquivo por POST (a API ignora multipart extra, pegadinha #7)
for f in \
  "$REPO_ROOT/flowable-events/validarDocumentosCmd.event" \
  "$REPO_ROOT/flowable-events/documentosValidadosEvt.event" \
  "$REPO_ROOT/flowable-events/solicitarCuradoriaCmd.event" \
  "$REPO_ROOT/flowable-events/decisaoCuradoriaEvt.event" \
  "$REPO_ROOT/flowable-events/validarDocumentosCmdChannel.channel" \
  "$REPO_ROOT/flowable-events/documentosValidadosEvtChannel.channel" \
  "$REPO_ROOT/flowable-events/solicitarCuradoriaCmdChannel.channel" \
  "$REPO_ROOT/flowable-events/decisaoCuradoriaEvtChannel.channel"; do
  name="$(basename "$f")"
  echo "--> deploy event-registry: $name"
  curl -sS "${AUTH[@]}" -F "file=@$f" "$EVENT_ENDPOINT" | head -c 200
  echo
done

# 2) BPMN (depois dos canais, porque o XML referencia channelKey)
BPMN_FILE="$REPO_ROOT/bpmn/credenciamento-checador.bpmn20.xml"
echo "--> deploy bpmn: $(basename "$BPMN_FILE")"
curl -sS "${AUTH[@]}" -F "file=@$BPMN_FILE" "$BPMN_ENDPOINT" | head -c 200
echo

# 3) Validação: o process definition com key=credenciamentoChecador precisa existir
echo '--> validando deploy'
total="$(curl -sS "${AUTH[@]}" \
  "$FLOWABLE_URL/process-api/repository/process-definitions?key=credenciamentoChecador" \
  | grep -oE '"total":[0-9]+' | head -1 | cut -d: -f2 || true)"

if [[ "${total:-0}" -ge 1 ]]; then
  echo 'OK — process definition credenciamentoChecador disponível.'
else
  echo 'ERRO — process definition não encontrada após o deploy.' >&2
  echo '       Verifique `docker logs aurora-flowable` e rode novamente.' >&2
  exit 1
fi
