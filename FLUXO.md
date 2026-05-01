# Fluxo do Credenciamento de Checador (RF08)

Quem faz o quê, em raias. Caixas azuis são passos; losango amarelo é decisão; círculos verdes são início/fim. As setas pontilhadas com etiqueta `Kafka:` mostram onde o sistema troca mensagens via tópicos.

```mermaid
flowchart LR
    classDef inicio  fill:#7DDED8,stroke:#1F8E86,color:#0B3B38,stroke-width:1px
    classDef passo   fill:#3F8EE8,stroke:#1F5BAA,color:#FFFFFF,stroke-width:1px
    classDef decisao fill:#FFE680,stroke:#B49500,color:#3F3000,stroke-width:1px

    subgraph L1["Solicitante"]
        direction LR
        A((Pedido de<br/>credenciamento)):::inicio
        B[Chama a API<br/>POST /credenciamento]:::passo
    end

    subgraph L2["Flowable — Orquestrador BPMN"]
        direction LR
        C[Cria instância<br/>do processo]:::passo
        D[Solicita validação<br/>dos documentos]:::passo
        E[Aguarda o<br/>resultado]:::passo
        F{Documentos<br/>válidos?}:::decisao
        G[Solicita decisão<br/>da curadoria]:::passo
        M[Aguarda a<br/>decisão]:::passo
        H((Checador<br/>credenciado)):::inicio
        I((Rejeitado<br/>automaticamente)):::inicio
    end

    subgraph L3["Validador automático (microsserviço)"]
        direction LR
        J[Lê os documentos<br/>e decide se passam]:::passo
    end

    subgraph L4["Curador automático (microsserviço)"]
        direction LR
        N[Decide credenciar<br/>ou recusar]:::passo
    end

    A --> B --> C --> D
    D -. "Kafka:<br/>validar-documentos-cmd" .-> J
    J -. "Kafka:<br/>documentos-validados-evt" .-> E
    E --> F
    F -- Não  --> I
    F -- Sim  --> G
    G -. "Kafka:<br/>solicitar-curadoria-cmd" .-> N
    N -. "Kafka:<br/>decisao-curadoria-evt" .-> M
    M --> H
```

## Como ler o diagrama

1. **Solicitante** dispara o pedido na API.
2. **Flowable** cria o processo e, em vez de validar sozinho, **publica um comando no Kafka** pedindo a validação.
3. O **Validador automático** ouve esse tópico, avalia os documentos e **publica o resultado em outro tópico Kafka**.
4. O Flowable recebe o resultado e decide:
   - **Não** → encerra rejeitando.
   - **Sim** → publica um novo comando no Kafka pedindo a decisão da curadoria.
5. O **Curador automático** ouve esse tópico, decide `credenciar`/`recusar` e **publica a decisão em outro tópico Kafka**. O Flowable correlaciona pelo `checadorId` e finaliza o processo.

> O Flowable é quem mantém o estado do processo. O Kafka é o "correio" entre o Flowable e os microsserviços de validação e curadoria — nenhum dos dois conhece a URL do Flowable, ambos conhecem só seus tópicos. Atualmente o BPMN sempre converge para `endCredenciado` mesmo quando o curador `recusa`; a `decisaoFinal` fica gravada como variável do processo. Para diferenciar `credenciar` × `recusar` no `endActivityId`, basta adicionar um gateway depois do receive da curadoria.
