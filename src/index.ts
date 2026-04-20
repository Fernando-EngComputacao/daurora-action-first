const { Kafka } = require('kafkajs');

// Configuração do client Kafka conectando ao broker local
const kafka = new Kafka({
  clientId: 'aurora-validador-docs',
  brokers: ['localhost:9092']
});

const consumer = kafka.consumer({ groupId: 'grupo-validador-docs-1' });
const producer = kafka.producer();

const iniciarServico = async () => {
  try {
    await consumer.connect();
    await producer.connect();
    console.log('✅ [Validador Docs] Conectado ao Kafka com sucesso.');
    
    await consumer.subscribe({ topic: 'validar-documentos-cmd', fromBeginning: false });
    console.log('🎧 [Validador Docs] Aguardando novas solicitações de credenciamento...');

    await consumer.run({
      eachMessage: async ({ topic, partition, message }) => {
        const payload = JSON.parse(message.value.toString());
        const checadorId = payload.checadorId;
        
        console.log(`\n📥 [Kafka IN] Comando recebido para avaliar checador ID: ${checadorId}`);
        console.log(`⏳ Processando análise de documentação...`);

        // Mock de Regra de Negócio: Delay de 3 segundos e 80% de chance de aprovação
        setTimeout(async () => {
            const documentosValidos = Math.random() > 0.2; 
            const status = documentosValidos ? 'APROVADA' : 'REJEITADA';
            
            const eventoRetorno = {
                checadorId: checadorId, 
                documentosValidos: documentosValidos
            };

            await producer.send({
                topic: 'documentos-validados-evt',
                messages: [
                    { value: JSON.stringify(eventoRetorno) }
                ],
            });

            console.log(`📤 [Kafka OUT] Análise concluída (${status}). Evento publicado no barramento.`);
        }, 3000);
      },
    });
  } catch (error) {
    console.error('❌ [Validador Docs] Erro fatal no serviço:', error);
  }
};

iniciarServico();
