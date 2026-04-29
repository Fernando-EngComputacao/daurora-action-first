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
        G[Cria tarefa<br/>para os curadores]:::passo
        H((Checador<br/>credenciado)):::inicio
        I((Rejeitado<br/>automaticamente)):::inicio
    end

    subgraph L3["Validador automático (microsserviço)"]
        direction LR
        J[Lê os documentos<br/>e decide se passam]:::passo
    end

    subgraph L4["Curador (humano)"]
        direction LR
        K[Reivindica<br/>a tarefa]:::passo
        L[Aprova ou<br/>recusa]:::passo
    end

    A --> B --> C --> D
    D -. "Kafka:<br/>validar-documentos-cmd" .-> J
    J -. "Kafka:<br/>documentos-validados-evt" .-> E
    E --> F
    F -- Não  --> I
    F -- Sim  --> G --> K --> L --> H
```

## Como ler o diagrama

1. **Solicitante** dispara o pedido na API.
2. **Flowable** cria o processo e, em vez de validar sozinho, **publica um comando no Kafka** pedindo a validação.
3. O **Validador automático** ouve esse tópico, avalia os documentos e **publica o resultado em outro tópico Kafka**.
4. O Flowable recebe o resultado e decide:
   - **Não** → encerra rejeitando.
   - **Sim** → cria uma tarefa humana para o **Curador**, que reivindica e aprova/recusa, fechando o processo.

> O Flowable é quem mantém o estado do processo. O Kafka é só o "correio" entre o Flowable e o serviço de validação. O curador conversa com o Flowable diretamente (sem Kafka).
