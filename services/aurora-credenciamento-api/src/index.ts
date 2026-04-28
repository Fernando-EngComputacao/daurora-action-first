import http from 'node:http';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env.PORT ?? 3000);
const FLOWABLE_URL = process.env.FLOWABLE_URL ?? 'http://localhost:8080/flowable-ui';
const FLOWABLE_USER = process.env.FLOWABLE_USER ?? 'admin';
const FLOWABLE_PASS = process.env.FLOWABLE_PASS ?? 'test';
const PROCESS_KEY = process.env.PROCESS_KEY ?? 'credenciamentoChecador';

const basicAuth = 'Basic ' + Buffer.from(`${FLOWABLE_USER}:${FLOWABLE_PASS}`).toString('base64');

const SERVICE = 'credenciamento-api';
const log = (event: string, fields: Record<string, unknown> = {}) => {
  const parts = [`${new Date().toISOString()}`, `[${SERVICE}]`, `event=${event}`];
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined || v === null) continue;
    parts.push(`${k}=${v}`);
  }
  console.log(parts.join(' '));
};

type CredenciamentoRequest = {
  nomeCompleto: string;
  documentos: string;
  checadorId?: string;
};

type FlowableVariable = {
  name: string;
  type: 'string' | 'boolean' | 'integer';
  value: unknown;
};

const iniciarProcesso = async (req: CredenciamentoRequest) => {
  const checadorId = req.checadorId ?? randomUUID();

  const variables: FlowableVariable[] = [
    { name: 'checadorId',   type: 'string', value: checadorId },
    { name: 'nomeCompleto', type: 'string', value: req.nomeCompleto },
    { name: 'documentos',   type: 'string', value: req.documentos },
  ];

  const res = await fetch(`${FLOWABLE_URL}/process-api/runtime/process-instances`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: basicAuth,
    },
    body: JSON.stringify({
      processDefinitionKey: PROCESS_KEY,
      businessKey: checadorId,
      variables,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Flowable rejeitou o start (HTTP ${res.status}): ${body}`);
  }

  const instance = (await res.json()) as { id: string; businessKey: string };
  return { checadorId, processInstanceId: instance.id };
};

const lerCorpo = (req: http.IncomingMessage): Promise<string> =>
  new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });

const servidor = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  if (req.method === 'POST' && req.url === '/credenciamento') {
    try {
      const body = await lerCorpo(req);
      const payload = JSON.parse(body) as CredenciamentoRequest;

      if (!payload.nomeCompleto || !payload.documentos) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ erro: 'Campos nomeCompleto e documentos são obrigatórios.' }));
        return;
      }

      const { checadorId, processInstanceId } = await iniciarProcesso(payload);
      log('start', { checadorId, processInstanceId });

      res.writeHead(202, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ checadorId, processInstanceId }));
    } catch (err) {
      log('erro', { motivo: JSON.stringify((err as Error).message) });
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ erro: (err as Error).message }));
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ erro: 'rota não encontrada' }));
});

servidor.listen(PORT, () => {
  log('startup', { porta: PORT, flowable: FLOWABLE_URL, processKey: PROCESS_KEY });
});
