import { setTimeout as sleep } from 'node:timers/promises';

const FLOWABLE_URL  = process.env.FLOWABLE_URL  ?? 'http://localhost:8080/flowable-ui';
const FLOWABLE_USER = process.env.FLOWABLE_USER ?? 'admin';
const FLOWABLE_PASS = process.env.FLOWABLE_PASS ?? 'test';
const CURADOR_GROUP           = process.env.CURADOR_GROUP           ?? 'curadores';
const CURADOR_ASSIGNEE        = process.env.CURADOR_ASSIGNEE        ?? 'curador-mock';
const CURADOR_POLL_MS         = Number(process.env.CURADOR_POLL_MS         ?? 5000);
const CURADOR_TAXA_APROVACAO  = Number(process.env.CURADOR_TAXA_APROVACAO  ?? 0.7);
const CURADOR_LATENCIA_MS     = Number(process.env.CURADOR_LATENCIA_MS     ?? 2000);

const SERVICE = 'curador-mock';
const basicAuth = 'Basic ' + Buffer.from(`${FLOWABLE_USER}:${FLOWABLE_PASS}`).toString('base64');

const log = (event: string, fields: Record<string, unknown> = {}) => {
  const parts = [`${new Date().toISOString()}`, `[${SERVICE}]`, `event=${event}`];
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined || v === null) continue;
    parts.push(`${k}=${v}`);
  }
  console.log(parts.join(' '));
};

type FlowableTask = {
  id: string;
  name?: string;
  assignee?: string | null;
  processInstanceId?: string;
};

type FlowableVariable = {
  name: string;
  type?: string;
  value: unknown;
  scope?: string;
};

type Decisao = 'credenciar' | 'recusar';

let parando = false;

const flowableFetch = async (path: string, init: RequestInit = {}) => {
  const res = await fetch(`${FLOWABLE_URL}${path}`, {
    ...init,
    headers: {
      Authorization: basicAuth,
      ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      ...(init.headers ?? {}),
    },
  });
  return res;
};

const listarTasksAbertas = async (): Promise<FlowableTask[]> => {
  const res = await flowableFetch(
    `/process-api/runtime/tasks?candidateGroup=${encodeURIComponent(CURADOR_GROUP)}&size=50`,
  );
  if (!res.ok) {
    throw new Error(`GET /tasks falhou (HTTP ${res.status}): ${await res.text()}`);
  }
  const body = (await res.json()) as { data?: FlowableTask[] };
  return (body.data ?? []).filter((t) => !t.assignee);
};

const lerVariaveis = async (taskId: string): Promise<Record<string, unknown>> => {
  const res = await flowableFetch(`/process-api/runtime/tasks/${taskId}/variables`);
  if (!res.ok) {
    throw new Error(`GET /tasks/${taskId}/variables falhou (HTTP ${res.status}): ${await res.text()}`);
  }
  const body = (await res.json()) as { data?: FlowableVariable[] } | FlowableVariable[];
  const lista = Array.isArray(body) ? body : (body.data ?? []);
  const out: Record<string, unknown> = {};
  for (const v of lista) out[v.name] = v.value;
  return out;
};

const reivindicar = async (taskId: string) => {
  const res = await flowableFetch(`/process-api/runtime/tasks/${taskId}`, {
    method: 'POST',
    body: JSON.stringify({ action: 'claim', assignee: CURADOR_ASSIGNEE }),
  });
  if (!res.ok) {
    throw new Error(`claim ${taskId} falhou (HTTP ${res.status}): ${await res.text()}`);
  }
};

const completar = async (taskId: string, decisao: Decisao) => {
  const res = await flowableFetch(`/process-api/runtime/tasks/${taskId}`, {
    method: 'POST',
    body: JSON.stringify({
      action: 'complete',
      variables: [{ name: 'decisaoFinal', value: decisao }],
    }),
  });
  if (!res.ok) {
    throw new Error(`complete ${taskId} falhou (HTTP ${res.status}): ${await res.text()}`);
  }
};

const decidir = (): Decisao =>
  Math.random() < CURADOR_TAXA_APROVACAO ? 'credenciar' : 'recusar';

const processarTask = async (task: FlowableTask) => {
  const taskId = task.id;
  let checadorId: string | undefined;

  try {
    const vars = await lerVariaveis(taskId);
    checadorId = typeof vars.checadorId === 'string' ? vars.checadorId : undefined;

    log('claim', { taskId, checadorId });
    await reivindicar(taskId);

    if (CURADOR_LATENCIA_MS > 0) await sleep(CURADOR_LATENCIA_MS);

    const decisaoFinal = decidir();
    await completar(taskId, decisaoFinal);
    log('complete', { taskId, checadorId, decisaoFinal });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    // 404/409: outra instância já fechou a task — warning, não erro fatal.
    const concorrencia = /HTTP 4(04|09)/.test(msg);
    log(concorrencia ? 'skip' : 'erro', { taskId, checadorId, motivo: JSON.stringify(msg) });
  }
};

const loop = async () => {
  log('startup', {
    flowable: FLOWABLE_URL,
    grupo: CURADOR_GROUP,
    pollMs: CURADOR_POLL_MS,
    taxaAprovacao: CURADOR_TAXA_APROVACAO,
    latenciaMs: CURADOR_LATENCIA_MS,
  });

  while (!parando) {
    try {
      const tasks = await listarTasksAbertas();
      if (tasks.length > 0) {
        log('poll', { tasksAbertas: tasks.length });
        for (const t of tasks) {
          if (parando) break;
          await processarTask(t);
        }
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      log('erro', { motivo: JSON.stringify(msg) });
    }
    if (!parando) await sleep(CURADOR_POLL_MS);
  }
  log('shutdown');
};

const desligar = () => {
  if (parando) return;
  parando = true;
  log('signal');
};

process.on('SIGINT', desligar);
process.on('SIGTERM', desligar);

loop().catch((err) => {
  console.error('[curador-mock] erro fatal:', err);
  process.exit(1);
});
