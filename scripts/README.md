# 🧰 Scripts operacionais

Automação dos blocos de `curl` que aparecem no README principal. Todos os scripts são shell Bash, idempotentes onde faz sentido e sem dependência externa além de `curl` e `bash`.

Rode a partir da raiz do repositório para que os caminhos relativos resolvam corretamente.

| Script | O que faz | Quando usar |
|---|---|---|
| `healthcheck.sh` | Confere se o Flowable REST e a API produtora respondem. | Antes de deployar ou antes de disparar uma solicitação. |
| `deploy-flowable.sh` | Faz o deploy dos 4 artefatos do Event Registry e do BPMN, e valida que o process definition foi criado. | Toda vez que o container do Flowable for recriado (H2 in-memory perde tudo). |
| `disparar-credenciamento.sh` | Envia um `POST /credenciamento` para a API produtora e imprime o `processInstanceId`. | Para iniciar uma instância de teste do processo. |
| `completar-tarefa.sh` | Encontra a userTask aberta da instância e completa com `decisaoFinal=credenciar\|recusar`. | Depois que `documentosValidos=true` e você quer finalizar o processo. |

## Pré-requisitos

- Containers de pé: `docker compose up -d` na raiz.
- Microsserviços rodando (`npm run dev` em cada um) quando for usar `disparar-credenciamento.sh`.

## Variáveis de ambiente suportadas

Todos os scripts seguem os mesmos defaults do `docker-compose.yml` + README. Para apontar para outro host/credencial, exporte antes:

| Variável | Default | Usada por |
|---|---|---|
| `FLOWABLE_URL` | `http://localhost:8080/flowable-ui` | `healthcheck`, `deploy-flowable`, `completar-tarefa` |
| `FLOWABLE_USER` | `admin` | idem |
| `FLOWABLE_PASS` | `test` | idem |
| `AURORA_API_URL` | `http://localhost:3000` | `healthcheck`, `disparar-credenciamento` |

## Exemplos

```bash
# 1. Confere que os serviços estão no ar
./scripts/healthcheck.sh

# 2. Redeploy (após qualquer restart do container do Flowable)
./scripts/deploy-flowable.sh

# 3. Inicia um processo de teste com os defaults (Maria Oliveira)
./scripts/disparar-credenciamento.sh

# 3b. Com dados customizados
./scripts/disparar-credenciamento.sh "João Silva" "https://exemplo/joao.pdf"

# 4. Completa a tarefa humana com decisão "credenciar"
./scripts/completar-tarefa.sh <processInstanceId> credenciar

# 4b. Ou para recusar
./scripts/completar-tarefa.sh <processInstanceId> recusar
```

## Notas

- `deploy-flowable.sh` faz 1 `POST` por arquivo porque o endpoint do Event Registry ignora silenciosamente arquivos extras no multipart (pegadinha #7 do `ARCHITECTURE.md §8`).
- `disparar-credenciamento.sh` extrai o `processInstanceId` da resposta e já imprime o comando pronto para o próximo passo (`completar-tarefa.sh`).
- Se `completar-tarefa.sh` reclamar que não há task aberta, provavelmente os documentos foram reprovados automaticamente (80% de aprovação no mock) — confira `history/historic-process-instances/<pid>` para ver se o `endActivityId` é `endRejeitada`.
