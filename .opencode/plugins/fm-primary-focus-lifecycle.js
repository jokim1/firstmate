import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

// Degraded OpenCode path: no verified pre-submit blocking hook exists.
// Reconcile at message.updated as best-effort fail-open recording so a
// captain prompt still leaves a durable focus snapshot when possible.
// See bin/fm-focus.sh and bin/fm-focus-prompt-hook.sh for the owner contract.

function runProcess(command, args, input = "") {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "ignore", "ignore"],
    });
    child.on("error", () => resolveResult(0));
    child.on("close", (code) => resolveResult(code ?? 0));
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
  const seen = new Set();

  return {
    event: async ({ event }) => {
      if (!root) return;
      // message.updated is post-fact; still the best documented OpenCode surface.
      if (event.type !== "message.updated" && event.type !== "message.completed") {
        return;
      }
      const info = event.properties?.info ?? event.properties?.message ?? {};
      const role = info.role ?? info.author?.role ?? "";
      if (role && role !== "user") return;
      const text =
        (typeof info.content === "string" && info.content) ||
        extractText(info.parts) ||
        (typeof info.text === "string" && info.text) ||
        "";
      if (!text) return;
      // Dedupe repeated updates for the same message id when present.
      const mid = String(info.id ?? info.messageID ?? text.slice(0, 64));
      if (seen.has(mid)) return;
      seen.add(mid);
      if (seen.size > 256) {
        const first = seen.values().next().value;
        seen.delete(first);
      }
      const payload = JSON.stringify({ prompt: text });
      await runProcess(`${root}/bin/fm-focus-prompt-hook.sh`, ["--opencode"], payload);
    },
  };
};
