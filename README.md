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
│   ├── documentosValidadosEvtChannel.channel
│   ├── solicitarCuradoriaCmd.event
│   ├── solicitarCuradoriaCmdChannel.channel
│   ├── decisaoCuradoriaEvt.event
│   └── decisaoCuradoriaEvtChannel.channel
│
├── scripts/                        # Automação dos comandos do README
│   ├── healthcheck.sh
│   ├── deploy-flowable.sh
│   ├── disparar-credenciamento.sh
│   ├── listar-instancias.sh
│   └── completar-tarefa.sh
│
└── services/
    ├── aurora-credenciamento-api/  # Produtor HTTP — dispara o processo no Flowable
    ├── aurora-validador-docs/      # Consumidor reativo — valida documentos via Kafka
    └── aurora-curador-mock/        # Curador automatizado — consome solicitar-curadoria-cmd e publica decisao-curadoria-evt via Kafka
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

Aguarde ~30s para o Flowable terminar o boot. O passo 2 a seguir já valida implicitamente que a REST do Flowable está no ar (falha rápido se não estiver).

> **Não rode `./scripts/healthcheck.sh` agora.** Ele confere também a API Node em `:3000/health`, que ainda nem foi iniciada — o checkpoint dele é o **passo 5**.

### 2. Fazer deploy do BPMN e do Event Registry no Flowable

> **⚠️ Importante:** o Flowable UI usa um banco H2 em memória. **Toda vez que o container do Flowable reinicia, os deploys são perdidos.** Repita este passo após qualquer `docker compose restart flowable` ou `up -d` que recrie o container.

```bash
./scripts/deploy-flowable.sh
```

O script publica os 8 arquivos de `flowable-events/` (um `POST` por arquivo, que é como a API aceita — veja [ARCHITECTURE §8 pegadinha #7](./ARCHITECTURE.md#8-pegadinhas-da-imagem-flowableflowable-uilatest-680)), em seguida publica o BPMN, e ao final confere que `process-definitions?key=credenciamentoChecador` retorna `total>=1`. Sai com código `1` se alguma etapa falhar.

Detalhes e variáveis de ambiente suportadas: [`scripts/README.md`](./scripts/README.md).

### 3. Instalar dependências dos microsserviços

Em **três terminais diferentes**:

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

```bash
# Terminal C
cd services/aurora-curador-mock
npm install
```

### 4. Rodar os microsserviços

```bash
# Terminal A — validador reativo (consome validar-documentos-cmd)
npm run dev
```

Deve imprimir uma linha de startup:
```
2026-04-28T12:00:00.000Z [validador-docs] event=startup broker=localhost:9092 topicIn=validar-documentos-cmd topicOut=documentos-validados-evt
```

```bash
# Terminal B — API produtora (expõe POST /credenciamento na porta 3000)
npm run dev
```

Deve imprimir:
```
2026-04-28T12:00:00.000Z [credenciamento-api] event=startup porta=3000 flowable=http://localhost:8080/flowable-ui processKey=credenciamentoChecador
```

```bash
# Terminal C — curador automatizado (consome solicitar-curadoria-cmd, publica decisao-curadoria-evt)
npm run dev
```

Deve imprimir:
```
2026-04-28T12:00:00.000Z [curador-mock] event=startup broker=localhost:9092 topicIn=solicitar-curadoria-cmd topicOut=decisao-curadoria-evt taxaAprovacao=0.7 latenciaMs=2000
```

> O curador-mock é um consumidor Kafka idêntico em formato ao validador: assina `solicitar-curadoria-cmd`, simula `CURADOR_LATENCIA_MS` (default 2000) de processamento e publica em `decisao-curadoria-evt` com `decisaoFinal=credenciar` (probabilidade `CURADOR_TAXA_APROVACAO`, default 0,7) ou `decisaoFinal=recusar`. O Flowable correlaciona o retorno pelo `checadorId` e segue o processo. Não há mais userTask — o BPMN agora é 100% reativo.

### 5. Checkpoint: tudo no ar?

Com os containers rodando (passo 1), o deploy feito (passo 2) e os dois `npm run dev` ativos (passo 4), rode agora o healthcheck completo em um terceiro terminal:

```bash
./scripts/healthcheck.sh
```

Agora sim deve listar **HTTP 200** nas duas linhas:

```
  Flowable REST          http://localhost:8080/flowable-ui/...   HTTP 200
  Aurora API /health     http://localhost:3000/health            HTTP 200
OK — tudo no ar.
```

Se a linha da Aurora API vier `HTTP 000`, o serviço `aurora-credenciamento-api` não está rodando — volte ao passo 4.

### 6. Disparar uma solicitação de credenciamento

No mesmo terceiro terminal:

```bash
# Com defaults (nomeCompleto="Maria Oliveira", documentos="https://exemplo/maria.pdf")
./scripts/disparar-credenciamento.sh

# Ou com dados custom
./scripts/disparar-credenciamento.sh "João Silva" "https://exemplo/joao.pdf"
```

Resposta:
```json
{ "checadorId": "<uuid>", "processInstanceId": "<id>" }
```

O script já imprime o `processInstanceId` em uma linha separada e sugere o comando do próximo passo.

### 7. Observar o fluxo pelos logs

- **Terminal A** (validador) mostra `event=in ...` e depois `event=out ... documentosValidos=true|false`.
- **Terminal C** (curador) mostra `event=in ...` e depois `event=out ... decisaoFinal=credenciar|recusar`, mas só para as instâncias que passaram na validação automática.
- **Kafka UI** (http://localhost:8081) mostra mensagens trafegando nos quatro tópicos: `validar-documentos-cmd`, `documentos-validados-evt`, `solicitar-curadoria-cmd` e `decisao-curadoria-evt`.
- Logs do Flowable:
  ```bash
  docker logs -f aurora-flowable | grep -iE "kafka|error"
  ```

### 8. Acompanhar a finalização do processo

Como tanto o validador quanto o curador são reativos via Kafka, o processo finaliza sozinho em poucos segundos. Os caminhos possíveis são:

- `documentosValidos=false` → encerra direto em `endRejeitada` (~20% das instâncias).
- `documentosValidos=true` → o Flowable publica em `solicitar-curadoria-cmd`, o curador-mock decide, publica em `decisao-curadoria-evt` e o Flowable encerra em `endCredenciado` (~80% das instâncias).

Se você perdeu o `processInstanceId`, liste as instâncias:

```bash
./scripts/listar-instancias.sh
# ou, para processos já finalizados:
./scripts/listar-instancias.sh concluidas
```

> No BPMN atual, `decisaoFinal` (`credenciar`/`recusar`) é gravada como variável mas não influencia o fim do processo: as duas decisões convergem para `endCredenciado`. Para que `recusar` termine em estado distinto, basta adicionar um gateway depois do `aguardarDecisaoCurador` — ver [ARCHITECTURE §9](./ARCHITECTURE.md#9-como-evoluir).

### 9. Demo end-to-end automática

Para ver os 3 serviços rodando o fluxo inteiro **sem nenhuma intervenção humana**:

```bash
./scripts/demo-execucao-automatica.sh        # 5 instâncias, timeout 60s
./scripts/demo-execucao-automatica.sh 10     # 10 instâncias
./scripts/demo-execucao-automatica.sh 5 120  # 5 instâncias, timeout 120s
```

O script dispara N credenciamentos via `aurora-credenciamento-api`, faz polling no `history` até todos terminarem e imprime sumário com distribuição (`endCredenciado` × `endRejeitada`) e estatísticas de duração (p50/p95/max). Sai com código 0 se todos terminaram dentro do timeout. Distribuição esperada: ~80% `endCredenciado` (passou no validador) + ~20% `endRejeitada` (reprovado no validador). A `decisaoFinal` do curador é registrada na variável do processo mas não influencia o `endActivityId` enquanto o BPMN não tiver gateway pós-curadoria — ver [ARCHITECTURE §9](./ARCHITECTURE.md#9-como-evoluir).

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
| `solicitar-curadoria-cmd` | Flowable ➜ curador | `{ checadorId, nomeCompleto, documentos }` |
| `decisao-curadoria-evt` | curador ➜ Flowable | `{ eventKey: "decisaoCuradoriaEvt", checadorId, decisaoFinal }` |

### Variáveis de ambiente suportadas

| Serviço | Variável | Default |
|---|---|---|
| `aurora-validador-docs` | `KAFKA_BROKER` | `localhost:9092` |
| `aurora-credenciamento-api` | `PORT` | `3000` |
| `aurora-credenciamento-api` | `FLOWABLE_URL` | `http://localhost:8080/flowable-ui` |
| `aurora-credenciamento-api` | `FLOWABLE_USER` | `admin` |
| `aurora-credenciamento-api` | `FLOWABLE_PASS` | `test` |
| `aurora-credenciamento-api` | `PROCESS_KEY` | `credenciamentoChecador` |
| `aurora-curador-mock` | `KAFKA_BROKER` | `localhost:9092` |
| `aurora-curador-mock` | `CURADOR_TAXA_APROVACAO` | `0.7` |
| `aurora-curador-mock` | `CURADOR_LATENCIA_MS` | `2000` |

---

## 🩺 Troubleshooting

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| `./scripts/healthcheck.sh` mostra `Aurora API … HTTP 000` logo após `docker compose up -d` | A API Node em `:3000` ainda não foi iniciada — o `docker compose` só sobe a infra. | Seguir até o passo **4** (subir os dois `npm run dev`) antes de rodar o healthcheck. |
| Validador sobe e cai com `KafkaJSProtocolError: This server does not host this topic-partition` (`UNKNOWN_TOPIC_OR_PARTITION`) | Kafka 3.7 só auto-cria tópico em *produce*; o `consumer.subscribe()` falha se ninguém publicou antes. | Já está corrigido em `services/aurora-validador-docs/src/index.ts` — a função `garantirTopicos()` usa `admin.createTopics()` antes de assinar. Se voltar a falhar, confira se o código local está atualizado e reinicie o `npm run dev`. |
| Aviso `TimeoutNegativeWarning: -... is a negative number` na subida do validador | Bug conhecido do `kafkajs` sob Node 20+. Não afeta o funcionamento. | Pode ignorar; desaparece quando o kafkajs for atualizado. |
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

- Migrar o Flowable para Postgres (volume persistente) para não perder deploys no restart — assim `./scripts/deploy-flowable.sh` deixa de ser necessário a cada reboot do container.
- Encadear `./scripts/deploy-flowable.sh` automaticamente após `docker compose up -d` (via healthcheck + hook ou Makefile).
- Adicionar novos microsserviços reativos em `services/` (ex.: `aurora-notificador-curadores`) reaproveitando o mesmo padrão de canais Kafka.
