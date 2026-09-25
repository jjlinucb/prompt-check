# Prompt Check

Grades the prompt you are typing into the Claude app, live, and tells you which effort level to
run it at. A small overlay sits just above Claude's message box and updates as you type or
dictate:

> **Ready to send** · Run at High
> Missing: format, limits · 120 ms

The grading comes from [Jev](https://docs.typesafe.ai), TypeSafe's fast decision model. Each check
takes 70 to 200 ms and costs about $0.00005. The idea comes from
[Superlinear EP 10](https://www.youtube.com/watch?v=icujI6SX4Ko): Brandon Kase's live prompt
checker, plus vechen's use of Jev to pick reasoning effort per step.

It runs on a Mac and on Windows. You need:

- a TypeSafe API key, from [console.typesafe.ai/keys](https://console.typesafe.ai/keys)
- Node 20 or later
- the Claude desktop app, for the live overlay

**Privacy.** While the overlay runs, everything you type into Claude's message box is sent to
TypeSafe, along with the end of Claude's last reply. Pause it (menu bar on a Mac, tray icon on
Windows) for anything that must not leave your machine. The server listens on 127.0.0.1 only, and
the key never reaches a browser.

## 1. Save your key, once per machine

The key goes in `~/.config/prompt-check/.env`, outside this folder, so it can't end up in git or a
synced drive. These commands ask for it without showing it on screen.

Mac (Terminal):

```bash
mkdir -p ~/.config/prompt-check && bash -c 'read -rsp "TypeSafe API key: " k && printf "TYPESAFE_API_KEY=%s\n" "$k" > ~/.config/prompt-check/.env && chmod 600 ~/.config/prompt-check/.env'
```

Windows (PowerShell):

```powershell
New-Item -ItemType Directory -Force "$HOME\.config\prompt-check" | Out-Null; $s = Read-Host "TypeSafe API key" -AsSecureString; $k = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)); Set-Content "$HOME\.config\prompt-check\.env" "TYPESAFE_API_KEY=$k" -Encoding ascii; Remove-Variable s,k
```

A `TYPESAFE_API_KEY` environment variable, or a `.env` beside `server.mjs`, also works.

## 2. Start it

| | Mac | Windows |
|---|---|---|
| Live overlay on Claude's message box | `Prompt Check Live.command` | `Prompt Check Live.cmd` |
| Side window you type into, then copy from | `Prompt Check.command` | `Prompt Check.cmd` |

Double-click the file. Each launcher starts the local server if it isn't running.

**Mac.** The first launch builds `live/Prompt Check Live.app` from `live/PromptCheckLive.swift`
(needs the Xcode command line tools), and macOS asks you to allow it under Privacy & Security →
Accessibility, which is how it reads Claude's message box. A rebuild asks again. Pause and Quit are
under "Jev" in the menu bar.

**Windows.** `live/PromptCheckLive.ps1` reads the box through UI Automation and runs in the
Windows PowerShell that ships with Windows 10 and 11. Pause and Quit are on the tray icon
(right-click). **Written on a Mac and not yet run on Windows.** If it fails to start, a dialog names
the log at `%TEMP%\prompt-check-live.log`.

Only the Claude app's Code tab has been checked so far; its message box is labelled "Prompt" to
accessibility tools. The side window works with anything, since you copy from it (⌘/Ctrl + Enter).

## Replies are graded as replies

Most of a chat is not new tasks. "Yes, add it" is a good message and a bad task spec, so Jev first
decides the kind: a new **task**, a **follow-up** to work under way, a **reply** (confirmation,
answer, feedback), or a **question**. Only tasks get the specificity grade and the
goal/context/format/limits checks. Everything else is graded on whether Claude can tell what to do
next, and a message that gives a direction and leaves the how to Claude counts as clear.

To judge a reply, Jev needs what it replies to. The server reads Claude's last message from the
newest transcript in `~/.claude/projects/` (the last 3,000 characters). With several Code sessions
running at once, or while Claude is still mid-turn, that can be the wrong message.
`PROMPT_CHECK_CONTEXT=off` turns it off. A caller can also pass `previous_reply` in the request.

Wordiness is a note ("wordy"), not the verdict, for replies: in a spoken back-and-forth it costs
little. It only counts at all on messages of 25 words or more, because Jev calls "hmm" padded.

## What it costs

Every call is logged to `usage.jsonl` beside `server.mjs`: time, model, input tokens, kind. The prompt
text is never logged. `http://127.0.0.1:4747/api/usage` returns the running total. A call with the
previous reply attached is about 1,200 to 1,700 input tokens, roughly $0.00005 to $0.00007.

## What it asks Jev, in one batched request

| Id | Type | Question |
|---|---|---|
| `kind` | Choice | New task, follow-up, reply, or question |
| `next_step` | Score, 3 levels | For non-tasks: unclear, a direction, or specific |
| `effort` | Score, 5 levels | How much thinking does the task need: low, medium, high, xhigh, max |
| `specificity` | Score, 4 levels | Does the prompt tell Claude what it can't find out for itself? |
| `padded` | Noul | Does it repeat itself or carry filler? |
| `goal`, `context`, `format`, `constraints` | Noul | The four explanatory checks from the episode |

Effort judges the task, not the writing, so "fix it" and a careful bug report can land at the
same level. When the prompt is too vague to judge (specificity under 1.0) or the effort answer is
spread out (confidence under 0.4), the effort is shown in grey as a guess.

The specificity question tells Jev that Claude can open any file or folder the prompt names. Without
that, Jev marked every agent prompt "Missing context", because it assumed Claude could see only
the prompt.

The prompt verdict ("Missing context", "Padded", "Almost there", "Ready to send") and the effort
level come from `verdict()` and `effort()` in `server.mjs`, not from the model. The cut-offs were
set on 2026-09-25 from ten live prompts: vague prompts scored near 0 and workable agent prompts
1.8 to 2.2. Retune them on prompts you actually send.

Brandon used one Choice (clear / missing / wasteful) and said on air that it was the wrong type,
because a prompt can be vague and padded at once.

## Is changing effort free?

Mostly, but check before relying on it. In vechen's Codex setup, changing effort kept the prompt
cache. On Claude it depends on how the change is sent:

- A new top-level `output_config.effort` value **invalidates the cached conversation**. The next
  turn re-reads the whole chat at full input price, as a model switch would.
- A per-message effort change (beta, on Opus 5.5, Opus 5, Fable 5.1 and Mythos 5.1) is sent inside
  the conversation and **keeps the cache**.

Source: platform.claude.com, the Effort and Prompt caching pages. Nobody has checked which of the two
the Claude app uses when you change effort mid-chat. The change applies from the next turn either way.
So pick the effort before the first message where you can, and don't flip it every turn.

Optional env vars: `PORT` (default 4747), `TYPESAFE_MODEL` (default `jev-latest`; pin `jev-1.13.0`
now that the cut-offs are set) and `TYPESAFE_BASE_URL`.
