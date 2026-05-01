# 🏛️ Arquitetura — Aurora Fact Checking Bus

Este documento descreve a organização do repositório, os padrões arquiteturais adotados e o passo a passo operacional para rodar a demonstração do **RF08 — Gestão de Acesso e Credenciamento**.

---

## 1. Padrão Arquitetural

A plataforma Aurora combina dois paradigmas de integração, ambos presentes neste repositório:

| Paradigma | Onde vive | Responsabilidade |
|---|---|---|
| **Orquestração (BPMN 2.0)** | `bpmn/credenciamento-checador.bpmn20.xml` executado pelo Flowable | Mantém o estado do processo de credenciamento e decide quando acionar cada microsserviço. |
| **Coreografia reativa** | Microsserviços Node.js conectados ao Kafka | Executam etapas autônomas (validação de documentos, decisão de curadoria) sem conhecer o processo como um todo — apenas consomem e publicam eventos. |

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
│   ├── validarDocumentosCmd.event              # Comando: pedir validação dos documentos
│   ├── validarDocumentosCmdChannel.channel     # Canal Kafka outbound
│   ├── documentosValidadosEvt.event            # Evento: resultado da validação
│   ├── documentosValidadosEvtChannel.channel   # Canal Kafka inbound
│   ├── solicitarCuradoriaCmd.event             # Comando: pedir decisão da curadoria
│   ├── solicitarCuradoriaCmdChannel.channel    # Canal Kafka outbound
│   ├── decisaoCuradoriaEvt.event               # Evento: decisão final da curadoria
│   └── decisaoCuradoriaEvtChannel.channel      # Canal Kafka inbound
│
├── scripts/                        # Automação dos comandos do README
│   ├── healthcheck.sh
│   ├── deploy-flowable.sh
│   ├── disparar-credenciamento.sh
│   ├── listar-instancias.sh
│   ├── completar-tarefa.sh
│   └── demo-execucao-automatica.sh
│
└── services/
    ├── aurora-credenciamento-api/  # Produtor: dispara o processo via REST do Flowable
    │   ├── package.json
    │   ├── tsconfig.json
    │   └── src/index.ts
    │
    ├── aurora-validador-docs/      # Consumidor reativo: valida documentos via Kafka
    │   ├── package.json
    │   ├── tsconfig.json
    │   └── src/index.ts
    │
    └── aurora-curador-mock/        # Curador automatizado: consome solicitar-curadoria-cmd e publica decisao-curadoria-evt
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
                                            ┌─────────────────────────┐    ┌──────────────────┐
                                            │ ServiceTask             │    │ End: Rejeitada   │
                                            │ (send-event)            │    │ Automaticamente  │
                                            │ "Solicitar Curadoria"   │    └──────────────────┘
                                            │  → solicitarCuradoria…  │
                                            │  (Kafka outbound)       │
                                            └────────────┬────────────┘
                                                         ▼
                                            ┌─────────────────────────┐
                                            │ ReceiveTask             │
                                            │ "Aguardar Decisão"      │
                                            │  ← decisaoCuradoriaEvt  │
                                            │  (Kafka inbound,        │
                                            │   correlação checadorId)│
                                            └────────────┬────────────┘
                                                         ▼
                                            ┌──────────────────────┐
                                            │ End: Credenciado     │
                                            └──────────────────────┘
```

**Variáveis de processo**: `checadorId` (string), `nomeCompleto` (string), `documentos` (string), `documentosValidos` (boolean, preenchida pelo evento `documentosValidadosEvt`), `decisaoFinal` (string, preenchida pelo evento `decisaoCuradoriaEvt` — `"credenciar"` ou `"recusar"`).

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

### 4.3 `solicitarCuradoriaCmd` — outbound (Flowable → Kafka)

| Campo | Tipo | Descrição |
|---|---|---|
| `checadorId` | string | ID único do checador (também usado como correlação). |
| `nomeCompleto` | string | Nome completo do candidato. |
| `documentos` | string | URL(s) ou referência aos documentos anexos. |

- **Tópico Kafka**: `solicitar-curadoria-cmd`
- **Serializador**: JSON

### 4.4 `decisaoCuradoriaEvt` — inbound (Kafka → Flowable)

| Campo | Tipo | Descrição |
|---|---|---|
| `checadorId` | string | Retornado do comando; usado para correlacionar a instância. |
| `decisaoFinal` | string | `"credenciar"` ou `"recusar"`. |

- **Tópico Kafka**: `decisao-curadoria-evt`
- **Desserializador**: JSON
- **Detecção do tipo de evento**: chave fixa `decisaoCuradoriaEvt` (`channelEventKeyDetection.fixedValue`) — o produtor (microsserviço curador) deve enviar um campo `eventKey: "decisaoCuradoriaEvt"` no payload.

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

> Conferir no Kafka UI se os quatro tópicos (`validar-documentos-cmd`, `documentos-validados-evt`, `solicitar-curadoria-cmd`, `decisao-curadoria-evt`) aparecem automaticamente (autocriação está ativada) ou serão criados na primeira publicação. O validador e o curador também chamam `admin.createTopics()` no startup, então os seus tópicos sobem mesmo antes da primeira mensagem.

### 5.2 Deploy dos artefatos no Flowable

A base do Flowable UI é H2 in-memory, então **toda vez que o container reinicia os deploys são perdidos** e precisam ser refeitos.

O caminho automatizado é o script da seção de automação do repositório:

```bash
./scripts/deploy-flowable.sh
```

Ele publica os 8 arquivos de `flowable-events/` (um `POST` por arquivo — ver §8 pegadinha #7), depois o BPMN, e valida que `process-definitions?key=credenciamentoChecador` retorna `total>=1`. Aceita `FLOWABLE_URL`/`FLOWABLE_USER`/`FLOWABLE_PASS` como variáveis de ambiente para apontar para outro host/credencial. Ver [`scripts/README.md`](./scripts/README.md) para o contrato completo.

Alternativa pela UI: acessar *Modeler App*, importar cada arquivo individualmente (menus *Channels*, *Events*, *Processes*) e publicar um *App Definition* que agrupe os artefatos.

Alternativa manual via REST (útil para debug, equivale ao que o script faz):

```bash
BASE=http://localhost:8080/flowable-ui
AUTH='-u admin:test'

for f in flowable-events/validarDocumentosCmd.event \
         flowable-events/documentosValidadosEvt.event \
         flowable-events/solicitarCuradoriaCmd.event \
         flowable-events/decisaoCuradoriaEvt.event \
         flowable-events/validarDocumentosCmdChannel.channel \
         flowable-events/documentosValidadosEvtChannel.channel \
         flowable-events/solicitarCuradoriaCmdChannel.channel \
         flowable-events/decisaoCuradoriaEvtChannel.channel; do
  curl -s $AUTH -F "file=@$f" \
    "$BASE/event-registry-api/event-registry-repository/deployments" | head -c 120; echo
done

curl -s $AUTH -F "file=@bpmn/credenciamento-checador.bpmn20.xml" \
  "$BASE/process-api/repository/deployments"
```

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

```bash
# Terminal 3 — Curador automatizado (consome Kafka, decide e publica de volta)
cd services/aurora-curador-mock
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
| `aurora-curador-mock` | `KAFKA_BROKER` | `localhost:9092` |
| `aurora-curador-mock` | `CURADOR_TAXA_APROVACAO` | `0.7` |
| `aurora-curador-mock` | `CURADOR_LATENCIA_MS` | `2000` |

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
   - Se `documentosValidos == true` → executa o `serviceTask` `enviarSolicitarCuradoria`, publicando em `solicitar-curadoria-cmd`, e fica bloqueado no novo `receiveTask` `aguardarDecisaoCurador`.
   - Se `false` → encerra com estado "Rejeitada Automaticamente".

5. **O `aurora-curador-mock`** consome `solicitar-curadoria-cmd`, simula `CURADOR_LATENCIA_MS` de processamento e publica em `decisao-curadoria-evt` com `eventKey: "decisaoCuradoriaEvt"`, `checadorId` e `decisaoFinal=credenciar|recusar` (probabilidade controlada por `CURADOR_TAXA_APROVACAO`). O Flowable correlaciona pelo `checadorId`, grava `decisaoFinal` na variável do processo e finaliza em `endCredenciado`. Hoje o BPMN não diferencia `credenciar` de `recusar` no `endActivityId`; ver §9.

Para acionar o fluxo inteiro N vezes sem intervenção humana e medir a distribuição de resultados: `scripts/demo-execucao-automatica.sh [N] [timeout_s]`.

Durante a demo, o **Kafka UI** (`http://localhost:8081`) mostra as mensagens trafegando em tempo real nos quatro tópicos.

### 6.1 Logs estruturados

Os três serviços imprimem linhas no formato:

```
2026-04-28T15:33:01.123Z [validador-docs]    event=in       topic=validar-documentos-cmd       checadorId=abc-123
2026-04-28T15:33:04.418Z [validador-docs]    event=out      topic=documentos-validados-evt     checadorId=abc-123 documentosValidos=true
2026-04-28T15:33:09.812Z [curador-mock]      event=in       topic=solicitar-curadoria-cmd      checadorId=abc-123
2026-04-28T15:33:11.901Z [curador-mock]      event=out      topic=decisao-curadoria-evt        checadorId=abc-123 decisaoFinal=credenciar
```

Com isso, `grep checadorId=<id>` agregando os logs dos três serviços reconstrói a história cronológica de uma instância (produção do comando de validação → consumo no validador → produção do resultado → consumo no curador → produção da decisão).

---

## 7. Decisões de Design

- **Event Registry nativo em vez de bridge HTTP**: mantém a promessa do README ("o motor de orquestração publica uma mensagem no Kafka") sem intermediários. O preço é precisar fazer o deploy dos canais/eventos na UI do Flowable.
- **Dois listeners Kafka (INTERNAL/EXTERNAL)**: `kafka:29092` para tráfego container-a-container (Flowable e Kafka UI) e `localhost:9092` para os microsserviços rodando no host. Sem isso, ou o Flowable não acha o broker pelo nome `localhost`, ou os microsserviços do host não falam com o container.
- **Autocriação de tópicos ativada** no broker (`KAFKA_AUTO_CREATE_TOPICS_ENABLE=true`): facilita a demonstração; em produção isso seria desligado e os tópicos criados com replicação explícita.
- **Tópicos criados explicitamente pelo validador**: apesar da flag acima, o Kafka 3.7 só auto-cria em *produce*; um `consumer.subscribe()` em tópico inexistente falha com `UNKNOWN_TOPIC_OR_PARTITION`. Por isso o `aurora-validador-docs` chama `admin.createTopics()` no startup (idempotente) antes de assinar.
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
- **Reintroduzir etapa humana**: o BPMN é hoje 100% reativo. Para reintroduzir um curador humano (ou misturar humano + bot), adicionar um `userTask` com `flowable:candidateGroups="curadores"` em paralelo ou substituindo o par `serviceTask` + `receiveTask` da curadoria, e usar o IDM App do Flowable para gerenciar os usuários do grupo.
- **Persistência real do Flowable**: hoje o container usa H2 in-memory (dados somem ao reiniciar). Para demo estendida, anexar um banco externo (Postgres) via `SPRING_DATASOURCE_*` + volume para o container do Flowable.
- **Automatizar o redeploy no boot**: o script `scripts/deploy-flowable.sh` já existe; falta encadeá-lo a `docker compose up` (healthcheck do container + hook ou `Makefile`) para eliminar o passo manual.
- **Gateway pós-curadoria**: hoje o `flowReceiveCuradoriaToEnd` liga o `aguardarDecisaoCurador` direto em `endCredenciado`, ignorando `decisaoFinal=recusar`. Adicionar gateway que distinga `credenciar` × `recusar` e introduzir `endReprovadoCurador` para o BPMN refletir o resultado real. O `aurora-curador-mock` já envia `recusar` na proporção `1 - CURADOR_TAXA_APROVACAO` esperando esta evolução.
