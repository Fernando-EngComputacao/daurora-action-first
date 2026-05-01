import { Kafka, logLevel } from 'kafkajs';

const BROKER = process.env.KAFKA_BROKER ?? 'localhost:9092';
const TOPIC_IN = 'solicitar-curadoria-cmd';
const TOPIC_OUT = 'decisao-curadoria-evt';

const CURADOR_TAXA_APROVACAO = Number(process.env.CURADOR_TAXA_APROVACAO ?? 0.7);
const CURADOR_LATENCIA_MS    = Number(process.env.CURADOR_LATENCIA_MS    ?? 2000);

const SERVICE = 'curador-mock';
const log = (event: string, fields: Record<string, unknown> = {}) => {
  const parts = [`${new Date().toISOString()}`, `[${SERVICE}]`, `event=${event}`];
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined || v === null) continue;
    parts.push(`${k}=${v}`);
  }
  console.log(parts.join(' '));
};

const kafka = new Kafka({
  clientId: 'aurora-curador-mock',
  brokers: [BROKER],
  logLevel: logLevel.NOTHING,
});

const consumer = kafka.consumer({ groupId: 'grupo-curador-mock-1' });
const producer = kafka.producer();
const admin = kafka.admin();

type SolicitarCuradoriaCmd = {
  checadorId: string;
  nomeCompleto?: string;
  documentos?: string;
};

type Decisao = 'credenciar' | 'recusar';

type DecisaoCuradoriaEvt = {
  // Obrigatório para que o Flowable Event Registry detecte o tipo do evento
  // (channelEventKeyDetection.fixedValue === 'decisaoCuradoriaEvt')
  eventKey: 'decisaoCuradoriaEvt';
  checadorId: string;
  decisaoFinal: Decisao;
};

const decidir = (): Decisao =>
  Math.random() < CURADOR_TAXA_APROVACAO ? 'credenciar' : 'recusar';

const garantirTopicos = async () => {
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
  log('startup', {
    broker: BROKER,
    topicIn: TOPIC_IN,
    topicOut: TOPIC_OUT,
    taxaAprovacao: CURADOR_TAXA_APROVACAO,
    latenciaMs: CURADOR_LATENCIA_MS,
  });

  await consumer.subscribe({ topic: TOPIC_IN, fromBeginning: false });

  await consumer.run({
    eachMessage: async ({ message }) => {
      if (!message.value) return;
      const raw = JSON.parse(message.value.toString());
      const cmd: SolicitarCuradoriaCmd = raw.checadorId ? raw : (raw.eventPayload ?? raw.data ?? raw);

      log('in', { topic: TOPIC_IN, checadorId: cmd.checadorId });

      if (CURADOR_LATENCIA_MS > 0) {
        await new Promise((r) => setTimeout(r, CURADOR_LATENCIA_MS));
      }

      const decisaoFinal = decidir();
      const evento: DecisaoCuradoriaEvt = {
        eventKey: 'decisaoCuradoriaEvt',
        checadorId: cmd.checadorId,
        decisaoFinal,
      };

      await producer.send({
        topic: TOPIC_OUT,
        messages: [{ key: cmd.checadorId, value: JSON.stringify(evento) }],
      });

      log('out', { topic: TOPIC_OUT, checadorId: cmd.checadorId, decisaoFinal });
    },
  });
};

const desligar = async () => {
  log('shutdown');
  await Promise.allSettled([consumer.disconnect(), producer.disconnect()]);
  process.exit(0);
};

process.on('SIGINT', desligar);
process.on('SIGTERM', desligar);

iniciarServico().catch((err) => {
  log('erro_fatal', { motivo: JSON.stringify(err instanceof Error ? err.message : String(err)) });
  process.exit(1);
});
