# 🧰 Scripts operacionais

Automação dos blocos de `curl` que aparecem no README principal. Todos os scripts são shell Bash, idempotentes onde faz sentido e sem dependência externa além de `curl` e `bash`.

Rode a partir da raiz do repositório para que os caminhos relativos resolvam corretamente.

| Script | O que faz | Quando usar |
|---|---|---|
| `healthcheck.sh` | Confere se o Flowable REST e a API produtora respondem. | Antes de deployar ou antes de disparar uma solicitação. |
| `deploy-flowable.sh` | Faz o deploy dos 4 artefatos do Event Registry e do BPMN, e valida que o process definition foi criado. | Toda vez que o container do Flowable for recriado (H2 in-memory perde tudo). |
| `disparar-credenciamento.sh` | Envia um `POST /credenciamento` para a API produtora e imprime o `processInstanceId`. | Para iniciar uma instância de teste do processo. |
| `listar-instancias.sh` | Lista instâncias ativas (ou últimas concluídas) do processo, com `processInstanceId` + `businessKey` (checadorId). | Quando você perdeu o `processInstanceId` da saída do `disparar-credenciamento.sh`. |
| `completar-tarefa.sh` | Encontra a userTask aberta da instância e completa com `decisaoFinal=credenciar\|recusar`. | **Alternativa manual** ao serviço `aurora-curador-mock`: use quando o curador-mock não estiver no ar e você quiser finalizar uma instância no terminal. |
| `demo-execucao-automatica.sh` | Dispara N credenciamentos, espera todos terminarem (timeout) e imprime sumário com distribuição (`endCredenciado` × `endRejeitada`) + p50/p95/max de duração. Exit 0 se todos terminaram. | Demo end-to-end automática (requer os 3 microsserviços rodando, incluindo o `aurora-curador-mock`). |

## Pré-requisitos

- Containers de pé: `docker compose up -d` na raiz.
- Microsserviços rodando (`npm run dev` em cada um) quando for usar `disparar-credenciamento.sh` ou `demo-execucao-automatica.sh`. A demo automática requer os **três** serviços (api, validador, curador-mock).

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

# 4. Se você perdeu o processInstanceId da saída acima, lista instâncias ativas
./scripts/listar-instancias.sh             # ativas
./scripts/listar-instancias.sh concluidas  # últimas 20 concluídas (history)

# 5. (manual) Completa a tarefa humana com decisão "credenciar"
#    — só necessário se o aurora-curador-mock não estiver rodando.
./scripts/completar-tarefa.sh <processInstanceId> credenciar

# 5b. Ou para recusar
./scripts/completar-tarefa.sh <processInstanceId> recusar

# 6. (automático) Demo end-to-end com sumário estatístico
./scripts/demo-execucao-automatica.sh        # 5 instâncias, timeout 60s
./scripts/demo-execucao-automatica.sh 10     # 10 instâncias
./scripts/demo-execucao-automatica.sh 5 120  # 5 instâncias, timeout 120s
```

## Notas

- `deploy-flowable.sh` faz 1 `POST` por arquivo porque o endpoint do Event Registry ignora silenciosamente arquivos extras no multipart (pegadinha #7 do `ARCHITECTURE.md §8`).
- `disparar-credenciamento.sh` extrai o `processInstanceId` da resposta e já imprime o comando pronto para o próximo passo (`completar-tarefa.sh`).
- Se `completar-tarefa.sh` reclamar que não há task aberta, provavelmente os documentos foram reprovados automaticamente (80% de aprovação no mock) — confira `history/historic-process-instances/<pid>` para ver se o `endActivityId` é `endRejeitada`. **Outra possibilidade**: o `aurora-curador-mock` já reivindicou e completou a task antes de você rodar o script (ele faz polling a cada 5s).
- `demo-execucao-automatica.sh` precisa de `python3` (parsing de JSON e estatísticas). Distribuição de duração esperada com defaults (`validador 3s` + `curador-mock` polling 5s + latência 2s): ~10s por instância.
