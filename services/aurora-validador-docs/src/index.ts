import { Kafka, logLevel } from 'kafkajs';

const BROKER = process.env.KAFKA_BROKER ?? 'localhost:9092';
const TOPIC_IN = 'validar-documentos-cmd';
const TOPIC_OUT = 'documentos-validados-evt';

const kafka = new Kafka({
  clientId: 'aurora-validador-docs',
  brokers: [BROKER],
  logLevel: logLevel.NOTHING,
});

const consumer = kafka.consumer({ groupId: 'grupo-validador-docs-1' });
const producer = kafka.producer();
const admin = kafka.admin();

type ValidarDocumentosCmd = {
  checadorId: string;
  nomeCompleto?: string;
  documentos?: string;
};

type DocumentosValidadosEvt = {
  // Obrigatório para que o Flowable Event Registry detecte o tipo do evento
  // (channelEventKeyDetection.fixedValue === 'documentosValidadosEvt')
  eventKey: 'documentosValidadosEvt';
  checadorId: string;
  documentosValidos: boolean;
};

const avaliarDocumentos = (_payload: ValidarDocumentosCmd): boolean => {
  // Mock: 80% de aprovação. Em produção, aqui entraria a regra real de validação.
  return Math.random() > 0.2;
};

const garantirTopicos = async () => {
  // Kafka 3.7 só auto-cria tópico em produce; subscribe em tópico inexistente
  // falha com UNKNOWN_TOPIC_OR_PARTITION. Criamos explicitamente via admin.
  await admin.connect();
  try {
    await admin.createTopics({
      waitForLeaders: true,
      topics: [
        { topic: TOPIC_IN,  numPartitions: 1, replicationFactor: 1 },
        { topic: TOPIC_OUT, numPartitions: 1, replicationFactor: 1 },
      ],
    });
  } finally {
    await admin.disconnect();
  }
};

const iniciarServico = async () => {
  await garantirTopicos();
  await consumer.connect();
  await producer.connect();
  console.log(`[validador-docs] conectado ao Kafka em ${BROKER}`);

  await consumer.subscribe({ topic: TOPIC_IN, fromBeginning: false });
  console.log(`[validador-docs] aguardando mensagens em "${TOPIC_IN}"...`);

  await consumer.run({
    eachMessage: async ({ message }) => {
      if (!message.value) return;
      const raw = JSON.parse(message.value.toString());
      // O Event Registry do Flowable envia o evento envelopado com metadados;
      // o payload de negócio pode vir em raw ou em raw.eventPayload/raw.data dependendo da versão.
      const cmd: ValidarDocumentosCmd = raw.checadorId ? raw : (raw.eventPayload ?? raw.data ?? raw);

      console.log(`[IN ] ${TOPIC_IN} checadorId=${cmd.checadorId}`);

      await new Promise((r) => setTimeout(r, 3000));

      const documentosValidos = avaliarDocumentos(cmd);
      const evento: DocumentosValidadosEvt = {
        eventKey: 'documentosValidadosEvt',
        checadorId: cmd.checadorId,
        documentosValidos,
      };

      await producer.send({
        topic: TOPIC_OUT,
        messages: [{ key: cmd.checadorId, value: JSON.stringify(evento) }],
      });

      console.log(
        `[OUT] ${TOPIC_OUT} checadorId=${cmd.checadorId} documentosValidos=${documentosValidos}`,
      );
    },
  });
};

const desligar = async () => {
  console.log('\n[validador-docs] encerrando...');
  await Promise.allSettled([consumer.disconnect(), producer.disconnect()]);
  process.exit(0);
};

process.on('SIGINT', desligar);
process.on('SIGTERM', desligar);

iniciarServico().catch((err) => {
  console.error('[validador-docs] erro fatal:', err);
  process.exit(1);
});
