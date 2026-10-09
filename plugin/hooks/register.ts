import type { EngineInterface, Register } from 'claude-code';

type PillState =
  | 'idle'
  | 'thinking'
  | 'working'
  | 'waiting'
  | 'asking'
  | 'done'
  | 'ended';

type Entry = {
  project: string;
  branch: string;
  title: string;
  state: PillState;
  text: string;
  updatedAt: number;
};

const APP = 'ClaudePill.app';
const TITLE_LENGTH = 40;

// Инструменты, которые сами ждут ответа человека: не путать с запросом разрешения
const ASKING = new Set(['AskUserQuestion', 'ExitPlanMode']);
const ASKING_TEXT = 'есть вопрос, нужно одобрение';
const WAITING_TEXT = 'нужно разрешение';

// Фоновые задачи (Bash, Workflow, Monitor…): id → что запущено. Хук Stop в desktop не срабатывает, поэтому считаем сами
const backgroundTasks = new Map<string, string>();
const BACKGROUND_HINT = /background|You will be notified|task-notification/i;
const BACKGROUND_ID = /\bID\b[\s:"'`]*([A-Za-z0-9_-]{6,})/;
// Настоящие сабагенты: служебные циклы движка (заголовок, классификатор) тоже несут agentId, но в $.agent.list их нет
const subagents = new Set<string>();
let dir = '';
let entry: Entry = {
  project: '',
  branch: '',
  title: '',
  state: 'idle',
  text: '',
  updatedAt: 0,
};
let file = '';

const basename = (path: string) => {
  return path.split('/').filter(Boolean).pop() ?? path;
};

const toTitle = (text: string) => {
  const [firstLine = ''] = text.trim().split('\n');
  const line = firstLine.trim();

  return line.length > TITLE_LENGTH ? `${line.slice(0, TITLE_LENGTH)}…` : line;
};

const describe = (tool: string, input: Record<string, unknown>) => {
  const name =
    typeof input.file_path === 'string' ? basename(input.file_path) : undefined;
  const command =
    typeof input.command === 'string' ? input.command.slice(0, 40) : undefined;

  if (tool === 'Bash' && command) {
    return `$ ${command}`;
  }

  if (tool === 'Read' && name) {
    return `читаю ${name}`;
  }

  if ((tool === 'Edit' || tool === 'Write') && name) {
    return `правлю ${name}`;
  }

  if (tool === 'Grep' || tool === 'Glob') {
    return 'ищу по коду';
  }

  if (tool === 'Agent' || tool === 'Task') {
    return typeof input.description === 'string'
      ? `сабагент: ${input.description}`
      : 'запустил сабагента';
  }

  return tool;
};

async function write($: EngineInterface, state: PillState, text: string) {
  if (!file) {
    return;
  }
  entry = { ...entry, state, text, updatedAt: Date.now() };

  await $.fs.write(file, JSON.stringify(entry));
}

// Фоновый инструмент сразу отвечает «running in background with ID: X», а по завершении шлёт <task-notification> с тем же id
const backgroundTaskId = (ran: unknown) => {
  const typed = (ran as { result?: { backgroundTaskId?: string } }).result
    ?.backgroundTaskId;

  if (typed) {
    return typed;
  }

  const text = JSON.stringify(ran);

  return BACKGROUND_HINT.test(text)
    ? text.match(BACKGROUND_ID)?.[1]
    : undefined;
};

async function listBackground($: EngineInterface) {
  const agents = (await $.agent.list()).filter((agent) => {
    return agent.status === 'running' && !agent.parentId;
  });

  return [
    ...backgroundTasks.values(),
    ...agents.map((agent) => {
      return agent.description;
    }),
  ];
}

const backgroundText = (tasks: string[]) => {
  const [first = ''] = tasks;
  const rest = tasks.length > 1 ? ` и ещё ${tasks.length - 1}` : '';

  return `фоном: ${first.slice(0, 40)}${rest}`;
};

async function isSubagent($: EngineInterface, agentId: string) {
  if (!subagents.has(agentId)) {
    for (const agent of await $.agent.list()) {
      subagents.add(agent.id);
    }
  }
  return subagents.has(agentId);
}

async function readBranch($: EngineInterface) {
  const { exitCode, stdout } = await $.process.run([
    'git',
    'rev-parse',
    '--abbrev-ref',
    'HEAD',
  ]);
  return exitCode === 0 ? stdout.trim() : '';
}

// После /clear id меняется без session.start: подхватываем новый id и сохранённое название
async function syncSession($: EngineInterface) {
  const next = `${dir}/sessions/${await $.session.id()}.json`;
  if (next === file) {
    return;
  }

  file = next;
  const saved = await $.fs
    .read(file)
    .then((text) => {
      return JSON.parse(text) as Partial<Entry>;
    })
    .catch(() => {
      return {} as Partial<Entry>;
    });
  entry = { ...entry, title: saved.title ?? '' };
}

// Мод только наблюдает: если хук упал, он считается отсутствующим и не блокирует вызов
const skip = () => {
  return undefined;
};

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    const started = await next(e);

    dir = `${await $.env.get('HOME')}/.claude/pet`;
    entry = { ...entry, project: basename(e.cwd), branch: await readBranch($) };
    await syncSession($);
    await write($, 'idle', 'жду задачу');

    if (e.isInteractive) {
      await $.process.run(['open', '-g', `${dir}/${APP}`]).catch(() => {
        return undefined;
      });
    }

    return started;
  });

  on('turn.start', async ($, e, next) => {
    await syncSession($);

    entry = {
      ...entry,
      branch: await readBranch($),
      title: entry.title || toTitle(e.text),
    };

    return next(e);
  });

  // turn.start не отличает основной ход от служебного цикла, а turn.step отличает по agentId
  on('turn.step', async function* ($, e, next) {
    if (!e.agentId && e.index === 0) {
      await write($, 'thinking', 'думаю…');
    }

    return yield* next(e);
  });

  // Действие остаётся на виду до следующего: Read/Grep быстрее, чем пилюля успевает перерисоваться
  on('tool.call', async ($, e, next) => {
    if (e.agentId && !(await isSubagent($, e.agentId))) {
      return next(e);
    }
    const action = describe(e.tool, e as unknown as Record<string, unknown>);

    if (ASKING.has(e.tool)) {
      await write($, 'asking', ASKING_TEXT);
    } else {
      await write($, 'working', e.agentId ? `сабагент · ${action}` : action);
    }
    const ran = await next(e);
    const taskId = backgroundTaskId(ran);

    if (taskId) {
      backgroundTasks.set(taskId, action);
    }

    if (entry.state === 'asking' || entry.state === 'waiting') {
      await write($, 'thinking', 'думаю…');
    }

    return ran;
  }).catch(skip);

  // tool.check отвечает ask и в auto-режиме, где решает классификатор, — поэтому слушаем только реальный диалог
  on('classic.PermissionRequest', async ($, e, next) => {
    if (!ASKING.has(e.tool_name)) {
      await write($, 'waiting', WAITING_TEXT);
    }

    return next(e);
  }).catch(skip);

  on('classic.Notification', async ($, e, next) => {
    if (
      e.notification_type === 'permission_prompt' &&
      entry.state !== 'asking'
    ) {
      await write($, 'waiting', WAITING_TEXT);
    }

    return next(e);
  }).catch(skip);

  // У сабагента свой цикл со своим turn.complete: «готово» ставит только основной
  on('turn.complete', async ($, e, next) => {
    const done = await next(e);
    if (e.agentId) {
      return done;
    }

    const tasks = await listBackground($);
    if (tasks.length > 0) {
      await write($, 'working', backgroundText(tasks));
    } else {
      await write(
        $,
        'done',
        e.answer.trim().endsWith('?') ? 'готово, есть вопрос' : 'готово',
      );
    }

    return done;
  });

  // Уведомление о завершении фоновой задачи приходит строкой транскрипта с <task-id>
  on('session.append', async ($, e, next) => {
    const appended = await next(e);

    for (const [, id] of JSON.stringify(e.message.content).matchAll(
      /<task-id>([^<]+)<\/task-id>/g,
    )) {
      if (id) {
        backgroundTasks.delete(id);
      }
    }

    return appended;
  }).catch(skip);

  // Файл не удаляем: при resume название беседы подхватится обратно
  on('session.end', async ($, e, next) => {
    await write($, 'ended', '');

    return next(e);
  });
};
