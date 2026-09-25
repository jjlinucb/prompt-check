// Prompt Check: grade a prompt live with Jev before it goes to an expensive LLM.
// Zero dependencies. Node 20+. The API key stays here, never in the browser.
import { createServer } from "node:http";
import { readFileSync, existsSync, readdirSync, statSync, openSync, readSync, closeSync, appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT ?? 4747);
const MODEL = process.env.TYPESAFE_MODEL ?? "jev-latest";
const BASE_URL = process.env.TYPESAFE_BASE_URL ?? "https://api.typesafe.ai";
const PRICE_PER_MTOK = 0.042; // jev-1.13 input price; output is free
const MAX_CHARS = 24_000; // stays well under the 32k state + question budget

// Key lookup order: the environment, then ~/.config/prompt-check/.env (outside any synced or
// shared folder), then .env beside this file.
function loadKey() {
  if (process.env.TYPESAFE_API_KEY) return process.env.TYPESAFE_API_KEY;
  const envFile = [join(homedir(), ".config", "prompt-check", ".env"), join(here, ".env")].find(existsSync);
  if (!envFile) return null;
  // Strip a BOM and split on CRLF too, so a .env saved by Windows Notepad still loads.
  const text = readFileSync(envFile, "utf8").replace(/^﻿/, "");
  const line = text.split(/\r?\n/).find((l) => l.startsWith("TYPESAFE_API_KEY="));
  return line ? line.slice("TYPESAFE_API_KEY=".length).trim().replace(/^["']|["']$/g, "") : null;
}
const API_KEY = loadKey();

// A reply like "yes, do that" only makes sense next to what Claude just said. Claude Code writes
// each session to ~/.claude/projects/<project>/<session>.jsonl, so take Claude's last text reply
// from the most recently written transcript. With several sessions active at once this can pick
// the wrong one. PROMPT_CHECK_CONTEXT=off turns it off.
const PROJECTS = join(homedir(), ".claude", "projects");
const REPLY_CHARS = 3_000; // the end of a reply is where the question to the user usually is
let newestCache = { at: 0, file: null };
function newestTranscript() {
  if (Date.now() - newestCache.at < 2_000) return newestCache.file;
  let best = null, bestT = 0;
  try {
    for (const d of readdirSync(PROJECTS)) {
      let names;
      try { names = readdirSync(join(PROJECTS, d)); } catch { continue; }
      for (const n of names) {
        if (!n.endsWith(".jsonl")) continue;
        const t = statSync(join(PROJECTS, d, n)).mtimeMs;
        if (t > bestT) { bestT = t; best = join(PROJECTS, d, n); }
      }
    }
  } catch { /* no Claude Code on this machine */ }
  newestCache = { at: Date.now(), file: best };
  return best;
}
function lastReply() {
  if (process.env.PROMPT_CHECK_CONTEXT === "off") return "";
  const file = newestTranscript();
  if (!file) return "";
  const size = statSync(file).size, len = Math.min(size, 512 * 1024);
  const buf = Buffer.alloc(len), fd = openSync(file, "r");
  readSync(fd, buf, 0, len, size - len);
  closeSync(fd);
  const lines = buf.toString("utf8").split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    let o;
    try { o = JSON.parse(lines[i]); } catch { continue; }
    if (o.type !== "assistant" || !Array.isArray(o.message?.content)) continue;
    const text = o.message.content.filter((c) => c.type === "text").map((c) => c.text).join("\n").trim();
    if (text) return text.length > REPLY_CHARS ? "…" + text.slice(-REPLY_CHARS) : text;
  }
  return "";
}

// Brandon's on-air version used one Choice (clear / missing / wasteful). He called it the wrong
// type: a prompt can be vague and padded at once. So: one Score for specificity, one Noul for
// padding, four Nouls that explain the gap. The verdict is policy, so it lives in code below.
const QUESTIONS = {
  // A chat is mostly replies, not new tasks. Grading "yes, do that" as a task spec calls every
  // good reply vague, so first ask what kind of message it is.
  kind: {
    type: "choice",
    instructions:
      "`prompt` is the next message someone will send in a chat with Claude. `previous_reply` is Claude's last message, or empty at the start of a chat. What kind of message is `prompt`?",
    criteria: {
      task: "Asks Claude to start a new piece of work that is not already under way in `previous_reply`",
      follow_up: "Changes, redirects, or adds to the work already under way in `previous_reply`",
      reply: "Confirms, approves, answers a question Claude asked, or gives feedback on what Claude did or said",
      question: "Asks Claude to explain something or give information, without asking for any change",
    },
  },
  next_step: {
    type: "score",
    instructions:
      "Read `prompt` as the next message after `previous_reply`. How clearly does it tell Claude what the person wants next, whether that is an action, an answer, or a change?",
    criteria: [
      "Unclear: Claude cannot tell what the person wants next",
      "Direction: says what the person wants, likes, or finds wrong, and leaves Claude to work out how",
      "Specific: Claude knows exactly what to do or answer next",
    ],
  },
  specificity: {
    type: "score",
    instructions:
      "`prompt` is a message about to be sent to Claude, which can open any file, folder, or repository the prompt names and can see the earlier chat. How much does the prompt tell Claude that it could not find out for itself, so it can do the task without guessing?",
    criteria: [
      "Vague: names a task at most; Claude would have to guess what is wanted",
      "Thin: states the task, but the scope or what counts as done is left for Claude to guess",
      "Workable: states the task and scope; one detail Claude cannot look up is missing",
      "Complete: the task, the scope, and what a good result looks like are clear, and anything else Claude needs is named where it can find it",
    ],
  },
  padded: {
    type: "noul",
    instructions: "Does `prompt` repeat itself or contain filler that adds no information for the task?",
    criteria: {
      true: "Repeats the same instruction or includes words that could be cut without losing anything",
      false: "Every sentence adds information",
    },
  },
  goal: {
    type: "noul",
    instructions: "Does `prompt` state what the person wants done?",
  },
  context: {
    type: "noul",
    instructions:
      "Does `prompt` give or point to the background the task depends on, such as the files, folder, audience, or prior decisions? Naming a file or folder Claude can open counts.",
  },
  format: {
    type: "noul",
    instructions: "Does `prompt` say what form the result should take, such as a file, a diff, a list, a length, or a language?",
  },
  constraints: {
    type: "noul",
    instructions: "Does `prompt` state any limits, requirements, or things to avoid?",
  },
  // vechen's EP 10 router, for Claude: pick the effort level, not the model. Levels match the
  // Claude app's effort menu. Judges the task, not how well the prompt is written.
  effort: {
    type: "score",
    instructions:
      "`prompt` will be sent to Claude after `previous_reply`. Ignoring how well it is written, how much thinking does the work it asks for need, including any work in `previous_reply` that it approves or asks Claude to continue?",
    criteria: [
      "Low: a lookup, a rename, a reformat, a short factual answer, or a small edit where the answer is obvious once read",
      "Medium: a routine task with a clear path, such as a normal edit, a summary, or an explanation of one or two things",
      "High: real reasoning, such as debugging, a change across several files, a design choice, or weighing trade-offs",
      "Extra high: long agentic work with many steps across many files or sources, likely running for over half an hour",
      "Max: the hardest problems where being right matters more than cost, such as subtle correctness, security, or a novel design",
    ],
  },
};
const EFFORTS = ["low", "medium", "high", "xhigh", "max"];

// Policy: the level nearest the score. Flag it as a guess when the prompt is too vague to judge.
function effort(a) {
  const e = a.effort;
  const level = EFFORTS[Math.min(4, Math.max(0, Math.round(e.score)))];
  const vague = a.kind.choice === "task" ? a.specificity.score < 1.0 : a.next_step.score < 0.8;
  const shaky = vague || e.confidence < 0.4;
  return { level, score: e.score, confidence: e.confidence, probabilities: e.probabilities, shaky };
}

// Policy: code decides what to tell the writer. Cut-offs set 2026-09-25 from ten live prompts:
// vague ones score near 0, workable agent prompts 1.8 to 2.2. Retune on your own prompts.
const KIND_LABEL = { follow_up: "follow-up", reply: "reply", question: "question" };
// Jev calls short replies ("yes do that", "hmm") padded, so padding counts only on longer messages.
const padded = (a, prompt) => a.padded.noul >= 0.5 && prompt.split(/\s+/).length >= 25;
function verdict(a, prompt) {
  const kind = a.kind.choice;
  if (kind !== "task") {
    // Replies, follow-ups and questions lean on the chat, so judge the next step instead of the spec.
    const n = a.next_step.score, what = KIND_LABEL[kind];
    if (n < 0.8) return { key: "missing", label: "Unclear next step", note: "Say what you want Claude to do next." };
    // A direction is a good chat message: it leaves the how to Claude on purpose. Wordiness in a
    // spoken back-and-forth costs little, so it is a note (the `padded` flag), not the verdict.
    return n < 1.5
      ? { key: "ready", label: `Clear ${what}`, note: "Gives a direction; Claude works out how." }
      : { key: "ready", label: `Clear ${what}`, note: "Claude knows exactly what to do." };
  }
  const s = a.specificity.score;
  if (s < 1.0) return { key: "missing", label: "Missing context", note: "Add what the model would otherwise guess." };
  if (padded(a, prompt)) return { key: "padded", label: "Padded", note: "Cut the repetition before sending." };
  if (s < 1.8) return { key: "almost", label: "Almost there", note: "One or two details would help." };
  return { key: "ready", label: "Ready to send", note: "Clear enough for the task." };
}

async function check(prompt, given) {
  const previous = typeof given === "string" ? given.slice(-REPLY_CHARS) : lastReply();
  const started = performance.now();
  const res = await fetch(`${BASE_URL}/v1/systemone`, {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: MODEL, state: { prompt, previous_reply: previous }, questions: QUESTIONS }),
  });
  const ms = Math.round(performance.now() - started);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(body?.detail ? JSON.stringify(body.detail) : `TypeSafe returned ${res.status}`);
    err.status = res.status;
    throw err;
  }
  const inTok = body.usage?.input_tokens ?? 0;
  logUsage({ at: new Date().toISOString(), model: body.model, input_tokens: inTok, ms, kind: body.answers.kind.choice });
  return {
    model: body.model,
    ms,
    usage: body.usage,
    costUsd: (inTok / 1e6) * PRICE_PER_MTOK,
    kind: body.answers.kind.choice,
    usedReply: previous.length > 0,
    // Format and limits only matter for a new task; a reply doesn't need them.
    missing: body.answers.kind.choice === "task"
      ? ["goal", "context", "format", "constraints"].filter((k) => body.answers[k].noul < 0.5)
      : [],
    padded: padded(body.answers, prompt),
    verdict: verdict(body.answers, prompt),
    effort: effort(body.answers),
    answers: body.answers,
  };
}

// Spend log: one line per Jev call with tokens and time, never the prompt text.
const USAGE_FILE = join(here, "usage.jsonl");
function logUsage(row) {
  try { appendFileSync(USAGE_FILE, JSON.stringify(row) + "\n"); } catch { /* read-only folder: skip */ }
}
function usageTotals() {
  if (!existsSync(USAGE_FILE)) return { calls: 0, input_tokens: 0, costUsd: 0, since: null };
  const rows = readFileSync(USAGE_FILE, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const tok = rows.reduce((n, r) => n + r.input_tokens, 0);
  return { calls: rows.length, input_tokens: tok, costUsd: (tok / 1e6) * PRICE_PER_MTOK, since: rows[0]?.at ?? null };
}

function send(res, status, obj) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(obj));
}

createServer(async (req, res) => {
  if (req.method === "GET" && (req.url === "/" || req.url === "/index.html")) {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(readFileSync(join(here, "index.html")));
  }
  if (req.method === "GET" && req.url === "/api/status") {
    return send(res, 200, { hasKey: Boolean(API_KEY), model: MODEL });
  }
  if (req.method === "GET" && req.url === "/api/usage") return send(res, 200, usageTotals());
  if (req.method === "POST" && req.url === "/api/check") {
    if (!API_KEY) return send(res, 503, { error: "No TYPESAFE_API_KEY set. See README." });
    let raw = "";
    for await (const chunk of req) raw += chunk;
    let prompt, given;
    try {
      const body = JSON.parse(raw);
      prompt = String(body.prompt ?? "").trim();
      given = body.previous_reply; // optional: tests and callers that know the chat
    } catch {
      return send(res, 400, { error: "Body must be JSON: {\"prompt\": \"...\"}" });
    }
    if (!prompt) return send(res, 400, { error: "Empty prompt" });
    if (prompt.length > MAX_CHARS) return send(res, 413, { error: `Prompt over ${MAX_CHARS} characters` });
    try {
      return send(res, 200, await check(prompt, given));
    } catch (e) {
      return send(res, e.status === 401 ? 401 : 502, { error: e.message });
    }
  }
  send(res, 404, { error: "Not found" });
  // Loopback only: anyone else on the network could otherwise spend the key.
}).listen(PORT, "127.0.0.1", () => {
  console.log(`Prompt Check on http://localhost:${PORT}  (model ${MODEL}, key ${API_KEY ? "loaded" : "MISSING"})`);
});
