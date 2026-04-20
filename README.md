# 🛡️ Plataforma Aurora - Fact Checking Bus

Este repositório contém a implementação do motor de orquestração e o barramento de eventos da Plataforma Aurora, uma infraestrutura descentralizada baseada em Web 3.0 para curadoria técnica colaborativa.

## 🌐 Endereços Locais (Docker)

Após subir o ambiente via `docker-compose up -d`, utilize os links abaixo para acessar as ferramentas de gestão e monitoramento:

* **Flowable UI (Orquestrador BPMN):** [http://localhost:8080/flowable-ui](http://localhost:8080/flowable-ui)
  * *Credenciais:* `admin` / `test`
* **Kafka UI (Monitoramento de Eventos):** [http://localhost:8081](http://localhost:8081)
  * *Cluster:* `Meu-Cluster-Aurora`

---

## 🎯 Requisito Técnico em Foco: RF08

O foco desta implementação é o **RF08 - Gestão de Acesso e Credenciamento**, um requisito crítico para a integridade do sistema.

> **Descrição:** "Possibilitar o credenciamento de novos checadores via formulário com envio de documentação comprobatória (certidões, comprovante de residência, etc.) para avaliação por curadores".

### 🏗️ Arquitetura do Fluxo
Este requisito demonstra a coexistência de dois paradigmas arquiteturais exigidos pela plataforma:

1. **Coreografia (Microsserviços Reativos):** A etapa de **Validação de Documentos** é realizada de forma assíncrona. O motor de orquestração publica uma mensagem no Kafka (`validar-documentos-cmd`), e um serviço autônomo processa e devolve o evento de resultado (`documentos-validados-evt`).
2. **Orquestração (BPMN 2.0):** O Flowable atua como o coordenador central (Fact Checking Bus), gerenciando o estado do processo e atribuindo a **Tarefa Humana** final aos Curadores apenas se as validações sistêmicas forem bem-sucedidas.

---

## 🚀 Setup do Microsserviço de Validação (Node.js)

Este serviço atua como o validador assíncrono conectado ao barramento Kafka.

### 1. Instalação
Na pasta do microsserviço (`aurora-validador-docs`), inicialize o projeto e instale a dependência do Kafka:

```bash
npm init -y
npm install kafkajs
