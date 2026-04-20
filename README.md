# 🛡️ Plataforma Aurora — Fact Checking Bus

Motor de orquestração + barramento de eventos da **Plataforma Aurora**, uma infraestrutura descentralizada (Web 3.0) para curadoria técnica colaborativa. Este repositório entrega uma demonstração executável do requisito **RF08 — Gestão de Acesso e Credenciamento**: um checador envia documentos, um microsserviço valida automaticamente e, se aprovado, um curador humano decide o credenciamento final.

> 📐 Para visão conceitual completa (BPMN, contratos de evento, decisões de design e pegadinhas da imagem Flowable), veja **[ARCHITECTURE.md](./ARCHITECTURE.md)**.

---

## 🧱 Pré-requisitos

| Ferramenta | Versão mínima | Observação |
|---|---|---|
| Docker + Docker Compose | 24.x / v2 | Sobe Flowable, Kafka e Kafka UI |
| Node.js | 20.x | Roda os microsserviços TypeScript |
| npm | 10.x | Já vem com Node 20 |
| `curl` | qualquer | Usado no deploy e nos testes |

Portas usadas no host: **3000** (API produtora), **8080** (Flowable UI), **8081** (Kafka UI), **9092** (Kafka externo). Certifique-se de que nenhuma esteja em uso.

---

## 📁 Estrutura do Repositório

```
daurora-action-first/
├── docker-compose.yml              # Flowable UI + Kafka + Kafka UI
├── README.md                       # (este arquivo)
├── ARCHITECTURE.md                 # Documento-mestre de arquitetura
├── .gitignore
│
├── bpmn/
│   └── credenciamento-checador.bpmn20.xml   # Modelo BPMN 2.0
│
├── flowable-events/                # Contratos do Event Registry do Flowable
│   ├── validarDocumentosCmd.event
│   ├── validarDocumentosCmdChannel.channel
│   ├── documentosValidadosEvt.event
│   └── documentosValidadosEvtChannel.channel
│
└── services/
    ├── aurora-credenciamento-api/  # Produtor HTTP — dispara o processo no Flowable
    └── aurora-validador-docs/      # Consumidor reativo — valida documentos via Kafka
```

Padrão para novos microsserviços: `services/<nome>/` contendo `package.json`, `tsconfig.json` e `src/index.ts`.

---

## 🚀 Passo a passo — do zero até ver o processo concluído

### 1. Subir a infraestrutura

Na raiz do repositório:

```bash
docker compose up -d
```

Isso provisiona três containers:

| Serviço | URL | Credenciais |
|---|---|---|
| Flowable UI | http://localhost:8080/flowable-ui | `admin` / `test` |
| Kafka UI | http://localhost:8081 | — |
| Kafka Broker (acesso do host) | `localhost:9092` | — |

Aguarde ~30s para o Flowable terminar o boot. Para conferir, rode:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -u admin:test \
  http://localhost:8080/flowable-ui/process-api/repository/process-definitions
```

Deve retornar `200`.

### 2. Fazer deploy do BPMN e do Event Registry no Flowable

> **⚠️ Importante:** o Flowable UI usa um banco H2 em memória. **Toda vez que o container do Flowable reinicia, os deploys são perdidos.** Repita este passo após qualquer `docker compose restart flowable` ou `up -d` que recrie o container.

Cole este bloco inteiro no terminal (a partir da raiz do repo):

```bash
BASE=http://localhost:8080/flowable-ui
AUTH='-u admin:test'

# 1) Eventos e canais (Event Registry) — um arquivo por chamada
for f in flowable-events/validarDocumentosCmd.event \
         flowable-events/documentosValidadosEvt.event \
         flowable-events/validarDocumentosCmdChannel.channel \
         flowable-events/documentosValidadosEvtChannel.channel; do
  echo "--- deploy $f"
  curl -s $AUTH -F "file=@$f" \
    "$BASE/event-registry-api/event-registry-repository/deployments" | head -c 160
  echo
done

# 2) Processo BPMN (depende dos canais já existirem)
echo "--- deploy BPMN"
curl -s $AUTH -F "file=@bpmn/credenciamento-checador.bpmn20.xml" \
  "$BASE/process-api/repository/deployments" | head -c 200
echo
```

Valide:

```bash
curl -s -u admin:test \
  "$BASE/process-api/repository/process-definitions?key=credenciamentoChecador" \
  | grep -o '"total":[0-9]*'
# esperado: "total":1
```

### 3. Instalar dependências dos microsserviços

Em **dois terminais diferentes**:

```bash
# Terminal A
cd services/aurora-validador-docs
npm install
```

```bash
# Terminal B
cd services/aurora-credenciamento-api
npm install
```

### 4. Rodar os microsserviços

```bash
# Terminal A — validador reativo (fica escutando validar-documentos-cmd)
npm run dev
```

Deve imprimir:
```
[validador-docs] conectado ao Kafka em localhost:9092
[validador-docs] aguardando mensagens em "validar-documentos-cmd"...
```

```bash
# Terminal B — API produtora (expõe POST /credenciamento na porta 3000)
npm run dev
```

Deve imprimir:
```
[credenciamento-api] escutando em http://localhost:3000
[credenciamento-api] Flowable alvo: http://localhost:8080/flowable-ui (processKey=credenciamentoChecador)
```

### 5. Disparar uma solicitação de credenciamento

Em um terceiro terminal:

```bash
curl -s -X POST http://localhost:3000/credenciamento \
  -H 'Content-Type: application/json' \
  -d '{"nomeCompleto":"Maria Oliveira","documentos":"https://exemplo/maria.pdf"}'
```

Resposta:
```json
{ "checadorId": "<uuid>", "processInstanceId": "<id>" }
```

Guarde o `processInstanceId` para o próximo passo.

### 6. Observar o fluxo pelos logs

- **Terminal A** (validador) mostra `[IN ] ...` e depois `[OUT] ... documentosValidos=true|false`.
- **Kafka UI** (http://localhost:8081) mostra mensagens trafegando nos tópicos `validar-documentos-cmd` e `documentos-validados-evt`.
- Logs do Flowable:
  ```bash
  docker logs -f aurora-flowable | grep -iE "kafka|error"
  ```

### 7. Completar a tarefa humana (se documentos foram aprovados)

Quando `documentosValidos=true`, o Flowable cria a tarefa "Análise Curatorial". Encontre-a e conclua:

```bash
PID="<processInstanceId_do_passo_5>"

# Descobre o id da tarefa aberta
TASK_ID=$(curl -s -u admin:test \
  "http://localhost:8080/flowable-ui/process-api/runtime/tasks?processInstanceId=$PID" \
  | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
echo "Task aberta: $TASK_ID"

# Completa com decisão "credenciar"
curl -s -u admin:test -X POST \
  -H 'Content-Type: application/json' \
  -d '{"action":"complete","variables":[{"name":"decisaoFinal","value":"credenciar"}]}' \
  "http://localhost:8080/flowable-ui/process-api/runtime/tasks/$TASK_ID"
echo

# Checa que o processo encerrou em endCredenciado
curl -s -u admin:test \
  "http://localhost:8080/flowable-ui/process-api/history/historic-process-instances/$PID" \
  | grep -oE '"endActivityId":"[^"]+"'
# esperado: "endActivityId":"endCredenciado"
```

Alternativamente, logue no **Flowable UI → Task App** (http://localhost:8080/flowable-ui) com `admin`/`test`, clique em *Tasks*, reivindique e complete a tarefa pela interface gráfica.

---

## 📨 Endpoints e Tópicos em Uso

### HTTP

| Método | URL | Descrição |
|---|---|---|
| `POST` | `http://localhost:3000/credenciamento` | Inicia um processo de credenciamento. Body: `{ "nomeCompleto": "...", "documentos": "..." }`. Retorna `checadorId` e `processInstanceId`. |
| `GET` | `http://localhost:3000/health` | Health check. |

### Kafka

| Tópico | Direção | Payload (resumido) |
|---|---|---|
| `validar-documentos-cmd` | Flowable ➜ validador | `{ checadorId, nomeCompleto, documentos }` |
| `documentos-validados-evt` | validador ➜ Flowable | `{ eventKey: "documentosValidadosEvt", checadorId, documentosValidos }` |

### Variáveis de ambiente suportadas

| Serviço | Variável | Default |
|---|---|---|
| `aurora-validador-docs` | `KAFKA_BROKER` | `localhost:9092` |
| `aurora-credenciamento-api` | `PORT` | `3000` |
| `aurora-credenciamento-api` | `FLOWABLE_URL` | `http://localhost:8080/flowable-ui` |
| `aurora-credenciamento-api` | `FLOWABLE_USER` | `admin` |
| `aurora-credenciamento-api` | `FLOWABLE_PASS` | `test` |
| `aurora-credenciamento-api` | `PROCESS_KEY` | `credenciamentoChecador` |

---

## 🩺 Troubleshooting

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| `curl` no endpoint `/credenciamento` retorna 500 com mensagem sobre "process definition not found" | BPMN ainda não foi deployado ou Flowable reiniciou e perdeu o deploy (H2 in-memory). | Rerodar o passo **2**. |
| Logs do validador mostram `IN` mas o processo não avança | O `eventKey` no JSON de retorno não bate com `channelEventKeyDetection.fixedValue`. | Confirmar que `services/aurora-validador-docs/src/index.ts` envia `eventKey: "documentosValidadosEvt"`. |
| Validador recebe `checadorId=checadorId` (string literal) | BPMN usando `source=` em vez de `sourceExpression=` no `eventInParameter`. | Garantir que `bpmn/credenciamento-checador.bpmn20.xml` usa `sourceExpression="${checadorId}"`. |
| Logs do Flowable: `Could not find an outbound channel adapter for channel ...` | As flags `FLOWABLE_TASK_APP_*_ENABLED=true` não estão setadas, então o Kafka auto-config é pulado. | Conferir `docker-compose.yml` e recriar o container (`docker compose up -d flowable`). |
| `POST` no deploy de canal retorna `Error parsing channel definition JSON` | Canal inbound com `"topic"` (singular). Em inbound o campo é `"topics": [...]`. | Usar os arquivos `.channel` deste repo. |
| Porta 8080/9092/3000 já ocupada | Outro serviço local em conflito. | Matar o processo conflitante ou remapear a porta no `docker-compose.yml` / variável `PORT`. |

Para uma lista completa de armadilhas da imagem `flowable/flowable-ui:latest` (versão 6.8.0) veja **[ARCHITECTURE.md §8](./ARCHITECTURE.md#8-pegadinhas-da-imagem-flowableflowable-uilatest-680)**.

---

## 🧹 Parando e limpando o ambiente

```bash
# Parar containers (mantém configuração)
docker compose stop

# Remover containers (estado do Flowable é perdido de qualquer forma, pois H2 é in-memory)
docker compose down

# Parar os serviços Node: Ctrl+C nos dois terminais
```

---

## 🔭 Próximos passos sugeridos

- Migrar o Flowable para Postgres (volume persistente) para não perder deploys no restart.
- Transformar o bloco de deploy do passo 2 em `scripts/deploy-flowable.sh` e chamá-lo automaticamente após o boot.
- Adicionar novos microsserviços reativos em `services/` (ex.: `aurora-notificador-curadores`) reaproveitando o mesmo padrão de canais Kafka.
