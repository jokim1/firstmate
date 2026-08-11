import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

const focusPromptTimeoutMs = 1000;

// OpenCode's chat.message hook runs before the model dispatches the prompt.
// Await the durable switch there while swallowing every adapter failure.
// See bin/fm-focus.sh and bin/fm-focus-prompt-hook.sh for the owner contract.

function runProcess(command, args, input = "") {
  return new Promise((resolveResult) => {
    let settled = false;
    const child = spawn(command, args, {
      stdio: ["pipe", "ignore", "ignore"],
    });
    const finish = (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolveResult(code);
    };
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      finish(0);
    }, focusPromptTimeoutMs);
    child.on("error", () => finish(0));
    child.on("close", (code) => finish(code ?? 0));
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await new Promise((resolveResult) => {
    const child = spawn("git", ["-C", anchor, "rev-parse", "--show-toplevel"], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolveResult(""));
    child.on("close", (code) => resolveResult(code === 0 ? stdout.trim() : ""));
  });
  return result || resolvePath(anchor);
}

function extractText(parts) {
  if (!Array.isArray(parts)) return "";
  return parts
    .map((part) => {
      if (!part || typeof part !== "object") return "";
      if (typeof part.text === "string") return part.text;
      if (typeof part.content === "string") return part.content;
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

export const FmPrimaryFocusLifecycle = async ({ directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    "chat.message": async (_input, output) => {
      if (!root) return;
      const text = extractText(output?.parts);
      if (!text) return;
      const payload = JSON.stringify({ prompt: text });
      await runProcess(`${root}/bin/fm-focus-prompt-hook.sh`, ["--opencode"], payload);
    },
  };
};
