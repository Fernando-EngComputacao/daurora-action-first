# 🏛️ Arquitetura — Aurora Fact Checking Bus

Este documento descreve a organização do repositório, os padrões arquiteturais adotados e o passo a passo operacional para rodar a demonstração do **RF08 — Gestão de Acesso e Credenciamento**.

---

## 1. Padrão Arquitetural

A plataforma Aurora combina dois paradigmas de integração, ambos presentes neste repositório:

| Paradigma | Onde vive | Responsabilidade |
|---|---|---|
| **Orquestração (BPMN 2.0)** | `bpmn/credenciamento-checador.bpmn20.xml` executado pelo Flowable | Mantém o estado do processo de credenciamento e decide quando acionar os microsserviços e os humanos. |
| **Coreografia reativa** | Microsserviços Node.js conectados ao Kafka | Executam etapas autônomas (ex.: validação de documentos) sem conhecer o processo como um todo — apenas consomem e publicam eventos. |

A "cola" entre os dois mundos é o **Flowable Event Registry**, que traduz as tarefas de envio/recepção de evento do BPMN em mensagens Kafka reais, conforme os canais definidos em `flowable-events/`. Na XML do BPMN essas tarefas aparecem como `<serviceTask flowable:type="send-event">` (comando) e `<receiveTask>` com extension elements (aguardar resultado) — a imagem do Flowable UI 6.8 não aceita os elementos padrão `<sendEventTask>`/`<receiveEventTask>` do BPMN.

---

## 2. Estrutura de Pastas

```
daurora-action-first/
├── docker-compose.yml              # Flowable UI, Kafka, Kafka UI
├── README.md                       # Visão rápida e links
├── ARCHITECTURE.md                 # (este arquivo)
│
├── bpmn/
│   └── credenciamento-checador.bpmn20.xml   # Modelo BPMN2 do processo RF08
│
├── flowable-events/                # Contratos do Event Registry do Flowable
│   ├── validarDocumentosCmd.event           # Evento de saída (comando)
│   ├── validarDocumentosCmdChannel.channel  # Canal Kafka outbound
│   ├── documentosValidadosEvt.event         # Evento de entrada (resultado)
│   └── documentosValidadosEvtChannel.channel # Canal Kafka inbound
│
└── services/
    ├── aurora-credenciamento-api/  # Produtor: dispara o processo via REST do Flowable
    │   ├── package.json
    │   ├── tsconfig.json
    │   └── src/index.ts
    │
    └── aurora-validador-docs/      # Consumidor reativo: valida documentos via Kafka
        ├── package.json
        ├── tsconfig.json
        └── src/index.ts
```

**Regra de ouro**: cada microsserviço fica em `services/<nome>/` como projeto Node.js isolado (tem o próprio `package.json`/`tsconfig.json`). Novos serviços seguem o mesmo padrão.

---

## 3. Modelo de Processo BPMN — RF08

```
 ┌──────────────────────┐     ┌─────────────────────────┐     ┌─────────────────────────────┐
 │  Start: Nova         │────▶│ ServiceTask             │────▶│ ReceiveTask                 │
 │  Solicitação         │     │ (send-event)            │     │ (com eventType/channelKey)  │
 │  (checadorId,        │     │ "Solicitar Validação"   │     │ "Aguardar Resultado"        │
 │   nomeCompleto,      │     │  → validarDocumentosCmd │     │  ← documentosValidadosEvt   │
 │   documentos)        │     │  (Kafka outbound)       │     │  (Kafka inbound, correlação │
 │                      │     │                         │     │   por checadorId)           │
 └──────────────────────┘     └─────────────────────────┘     └──────────────┬──────────────┘
                                                                              │
                                                                              ▼
                                                              ┌────────────────────────────┐
                                                              │  Gateway: documentosValidos? │
                                                              └─────────────┬───────────┬───┘
                                                            true            │           │  false
                                                                            ▼           ▼
                                                          ┌────────────────────┐  ┌──────────────────┐
                                                          │ UserTask:          │  │ End: Rejeitada   │
                                                          │ Análise Curatorial │  │ Automaticamente  │
                                                          │ (grupo curadores)  │  └──────────────────┘
                                                          └────────┬───────────┘
                                                                   ▼
                                                          ┌──────────────────────┐
                                                          │ End: Credenciado     │
                                                          └──────────────────────┘
```

**Variáveis de processo**: `checadorId` (string), `nomeCompleto` (string), `documentos` (string), `documentosValidos` (boolean, preenchida pelo evento de retorno).

---

## 4. Contratos de Evento (Event Registry)

### 4.1 `validarDocumentosCmd` — outbound (Flowable → Kafka)

| Campo | Tipo | Descrição |
|---|---|---|
| `checadorId` | string | ID único do checador (também usado como correlação). |
| `nomeCompleto` | string | Nome completo do candidato. |
| `documentos` | string | URL(s) ou referência aos documentos anexos. |

- **Tópico Kafka**: `validar-documentos-cmd`
- **Serializador**: JSON

### 4.2 `documentosValidadosEvt` — inbound (Kafka → Flowable)

| Campo | Tipo | Descrição |
|---|---|---|
| `checadorId` | string | Retornado do comando; usado para correlacionar a instância. |
| `documentosValidos` | boolean | Resultado da avaliação automática. |

- **Tópico Kafka**: `documentos-validados-evt`
- **Desserializador**: JSON
- **Detecção do tipo de evento**: chave fixa `documentosValidadosEvt` (`channelEventKeyDetection.fixedValue`) — o produtor (microsserviço validador) deve enviar um campo `eventKey: "documentosValidadosEvt"` no payload.

---

## 5. Como Subir o Ambiente

### 5.1 Infraestrutura

```bash
docker compose up -d
```

Serviços disponíveis:

| Serviço | URL | Credenciais |
|---|---|---|
| Flowable UI | http://localhost:8080/flowable-ui | `admin` / `test` |
| Kafka UI | http://localhost:8081 | — |
| Kafka Broker (host) | `localhost:9092` | — |
| Kafka Broker (containers) | `kafka:29092` | — |

> Conferir no Kafka UI se os tópicos `validar-documentos-cmd` e `documentos-validados-evt` aparecem automaticamente (autocriação está ativada) ou serão criados na primeira publicação.

### 5.2 Deploy dos artefatos no Flowable

A base do Flowable UI é H2 in-memory, então **toda vez que o container reinicia os deploys são perdidos** e precisam ser refeitos.

O caminho mais rápido é via REST, **um arquivo por chamada** (a API rejeita mais de um `file=` por deployment):

```bash
BASE=http://localhost:8080/flowable-ui
AUTH='-u admin:test'

# 1) Eventos e canais (Event Registry)
for f in flowable-events/validarDocumentosCmd.event \
         flowable-events/documentosValidadosEvt.event \
         flowable-events/validarDocumentosCmdChannel.channel \
         flowable-events/documentosValidadosEvtChannel.channel; do
  curl -s $AUTH -F "file=@$f" \
    "$BASE/event-registry-api/event-registry-repository/deployments" | head -c 120; echo
done

# 2) Processo BPMN (depois dos canais, porque o BPMN referencia channelKey)
curl -s $AUTH -F "file=@bpmn/credenciamento-checador.bpmn20.xml" \
  "$BASE/process-api/repository/deployments"
```

Alternativa pela UI: acessar *Modeler App*, importar cada arquivo individualmente (menus *Channels*, *Events*, *Processes*) e publicar um *App Definition* que agrupe os 4 artefatos.

### 5.3 Microsserviços

Em dois terminais distintos (com os containers já de pé):

```bash
# Terminal 1 — Validador reativo (consome Kafka)
cd services/aurora-validador-docs
npm install
npm run dev
```

```bash
# Terminal 2 — API produtora (inicia processos no Flowable)
cd services/aurora-credenciamento-api
npm install
npm run dev
```

Variáveis de ambiente relevantes:

| Serviço | Variável | Default |
|---|---|---|
| `aurora-validador-docs` | `KAFKA_BROKER` | `localhost:9092` |
| `aurora-credenciamento-api` | `PORT` | `3000` |
| `aurora-credenciamento-api` | `FLOWABLE_URL` | `http://localhost:8080/flowable-ui` |
| `aurora-credenciamento-api` | `FLOWABLE_USER` / `FLOWABLE_PASS` | `admin` / `test` |
| `aurora-credenciamento-api` | `PROCESS_KEY` | `credenciamentoChecador` |

---

## 6. Fluxo de Ponta a Ponta (Demo)

1. **Disparar credenciamento**:

   ```bash
   curl -X POST http://localhost:3000/credenciamento \
     -H 'Content-Type: application/json' \
     -d '{
       "nomeCompleto": "Maria Oliveira",
       "documentos": "https://exemplo/maria.pdf"
     }'
   ```

   Resposta: `{ "checadorId": "...", "processInstanceId": "..." }`.

2. **O Flowable**:
   - cria a instância do processo `credenciamentoChecador`;
   - executa o service task de `send-event`, publicando no tópico `validar-documentos-cmd`;
   - fica bloqueado no `receiveTask` aguardando o evento de retorno.

3. **O `aurora-validador-docs`**:
   - consome o comando;
   - roda a regra mock (80% aprova);
   - publica o evento em `documentos-validados-evt` com `eventKey: "documentosValidadosEvt"` e o mesmo `checadorId`.

4. **O Flowable** correlaciona pelo `checadorId`, destrava o `receiveTask` e avalia o gateway:
   - Se `documentosValidos == true` → cria uma **tarefa humana** `Análise Curatorial` (visível em *Task App*) para o grupo `curadores`.
   - Se `false` → encerra com estado "Rejeitada Automaticamente".

5. **Completar a tarefa humana**: no *Task App* do Flowable UI, um usuário do grupo `curadores` reivindica e completa a tarefa, finalizando o processo como "Checador Credenciado".

Durante a demo, o **Kafka UI** (`http://localhost:8081`) mostra as mensagens trafegando em tempo real nos dois tópicos.

---

## 7. Decisões de Design

- **Event Registry nativo em vez de bridge HTTP**: mantém a promessa do README ("o motor de orquestração publica uma mensagem no Kafka") sem intermediários. O preço é precisar fazer o deploy dos canais/eventos na UI do Flowable.
- **Dois listeners Kafka (INTERNAL/EXTERNAL)**: `kafka:29092` para tráfego container-a-container (Flowable e Kafka UI) e `localhost:9092` para os microsserviços rodando no host. Sem isso, ou o Flowable não acha o broker pelo nome `localhost`, ou os microsserviços do host não falam com o container.
- **Autocriação de tópicos ativada**: facilita a demonstração; em produção isso seria desligado e os tópicos criados com replicação explícita.
- **`eventKey` explícito no payload de retorno**: o canal inbound usa `channelEventKeyDetection.fixedValue`, mas deixar o `eventKey` no JSON mantém o evento self-describing e tolera mudanças futuras para `jsonPointer`/`jsonField`.
- **Start do processo via REST em vez de Message Start Event**: é mais simples de testar e não exige um tópico adicional só para iniciar.

---

## 8. Pegadinhas da Imagem `flowable/flowable-ui:latest` (6.8.0)

Confirmadas durante a integração; todas já estão aplicadas neste repositório:

| # | Problema | Solução |
|---|---|---|
| 1 | Kafka autoconfig é bloqueado por uma `FlowableUiAppEventRegistryCondition` específica da imagem. | Setar `FLOWABLE_TASK_APP_EVENT_REGISTRY_ENABLED=true` e `FLOWABLE_TASK_APP_KAFKA_ENABLED=true` no docker-compose. |
| 2 | Env vars do Spring precisam de underscore entre cada parte kebab-case. | `SPRING_KAFKA_BOOTSTRAP_SERVERS` (NÃO `BOOTSTRAPSERVERS`), `SPRING_KAFKA_CONSUMER_GROUP_ID`, `SPRING_KAFKA_CONSUMER_AUTO_OFFSET_RESET`. |
| 3 | REST do Flowable fica em `/flowable-ui/process-api/...`, não `/process-api/...` nem `/flowable-rest/...`. | Ajustar clients: `FLOWABLE_URL=http://localhost:8080/flowable-ui`. |
| 4 | O parser de BPMN 2.0 rejeita `<sendEventTask>`/`<receiveEventTask>` (não estão no XSD base). | Usar `<serviceTask flowable:type="send-event">` + `<receiveTask>` com `<flowable:eventType>` e `<flowable:channelKey>` como extension elements. |
| 5 | Canal inbound Kafka usa `"topics": [...]` (array), outbound usa `"topic": "..."` (string). | Já refletido nos arquivos `.channel`. |
| 6 | `<flowable:eventInParameter source="varName" .../>` trata `source` como **literal**, enviando a string `"varName"` no payload. | Usar `sourceExpression="${varName}"` para resolver a variável de processo. |
| 7 | Endpoint de deploy do Event Registry aceita **1 arquivo por chamada** (multipart extra é silenciosamente descartado). | Fazer um `POST` por arquivo, loopando. |
| 8 | H2 in-memory: qualquer `docker compose up -d` que recrie o container do Flowable apaga BPMN e Event Registry. | Após reiniciar, rodar novamente os deploys da §5.2. |

---

## 9. Como Evoluir

- **Novo microsserviço reativo**: criar `services/<nome>/` no mesmo padrão; declarar o canal/evento em `flowable-events/` e referenciar no BPMN via `<serviceTask flowable:type="send-event">` ou `<receiveTask>` com `flowable:eventType` + `flowable:channelKey`.
- **Nova etapa humana**: adicionar `UserTask` no BPMN e usar `flowable:candidateGroups` apontando para grupos definidos no IDM App do Flowable.
- **Persistência real do Flowable**: hoje o container usa H2 in-memory (dados somem ao reiniciar). Para demo estendida, anexar um banco externo (Postgres) via `SPRING_DATASOURCE_*` + volume para o container do Flowable.
- **Automatizar o redeploy**: transformar o bloco `curl ... for f in ...` do §5.2 num script `scripts/deploy-flowable.sh`, chamado automaticamente após `docker compose up`.
