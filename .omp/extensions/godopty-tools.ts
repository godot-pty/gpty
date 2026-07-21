import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.setLabel("godopty-tools");

  // ══════════════════════════════════════════════════════════════
  // 2. Edit hash rejection UX — enrich error with file diff
  // ══════════════════════════════════════════════════════════════
  pi.on("tool_result", async (event, ctx) => {
    if (event.toolName !== "edit") return;
    const result = event.result;
    if (!result?.isError) return;
    const text = result.content?.[0]?.text ?? "";
    if (!text.includes("#") || !text.includes("not from this session")) return;

    try {
      const filePath = event.input?.input?.match(/(?:^|\n)\[([^\]]+)#/)?.[1];
      if (!filePath) return;

      const output = await pi.exec("git", ["diff", "--", filePath], {
        cwd: ctx?.cwd,
        timeout: 3000,
      });
      if (output?.stdout) {
        result.content[0].text += `\n\n[godopty-tools] File changed since your last read:\n\`\`\`diff\n${output.stdout.slice(0, 2000)}\n\`\`\``;
      }
    } catch {
      // best-effort
    }
  });

  // ══════════════════════════════════════════════════════════════
  // 3. YAML/TOML/JSON validation on write
  // ══════════════════════════════════════════════════════════════
  const STRUCTURED_EXTS = [".yml", ".yaml", ".toml", ".json"];

  function isStructured(path: string): boolean {
    return STRUCTURED_EXTS.some(ext => path.endsWith(ext));
  }

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "write") return;
    const path = event.input?.path;
    const content = event.input?.content;
    if (typeof path !== "string" || typeof content !== "string") return;
    if (!isStructured(path)) return;

    const validation = await validateFile(path, content);
    if (validation?.error) {
      return {
        block: true,
        reason: `[godopty-tools] ${validation.error}`,
      };
    }
  });

  // ══════════════════════════════════════════════════════════════
  // 4. Post-edit validation on structured files
  // ══════════════════════════════════════════════════════════════
  pi.on("tool_result", async (event, ctx) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    const result = event.result;
    if (result?.isError) return;

    const path = event.input?.path;
    if (typeof path !== "string" || !isStructured(path)) return;

    try {
      const output = await pi.exec("cat", [path], { cwd: ctx?.cwd, timeout: 3000 });
      if (!output?.stdout) return;
      const validation = await validateFile(path, output.stdout);
      if (validation?.error && result) {
        result.content ??= [];
        result.content.push({
          type: "text",
          text: `\n[godopty-tools] WARNING: ${validation.error}\nThe file was written but may be corrupt. Review before committing.`,
        });
      }
    } catch {
      // file may not exist yet
    }
  });

  async function validateFile(path: string, content: string): Promise<{ error?: string }> {
    if (path.endsWith(".json")) {
      try { JSON.parse(content); } catch (e: any) {
        return { error: `Invalid JSON in ${path}: ${e.message}` };
      }
      return {};
    }

    // Use Python for YAML/TOML validation (stdlib has both parsers)
    if (path.endsWith(".yml") || path.endsWith(".yaml") || path.endsWith(".toml")) {
      const isToml = path.endsWith(".toml");
      const checker = isToml
        ? "import sys,tomllib; tomllib.loads(sys.stdin.read())"
        : "import sys,yaml; yaml.safe_load(sys.stdin.read())";
      try {
        const proc = Bun.spawnSync(["python3", "-c", checker], {
          stdin: content,
        });
        if (proc.exitCode !== 0) {
          return { error: `Invalid ${isToml ? "TOML" : "YAML"} in ${path}: ${proc.stderr.toString().trim()}` };
        }
      } catch {
        return { error: `Could not validate ${path} (Python unavailable)` };
      }
    }

    return {};
  }

  // ══════════════════════════════════════════════════════════════
  // 5. Agent type mismatch — warn when scout gets write tasks
  // ══════════════════════════════════════════════════════════════
  const WRITE_VERBS = /\b(write|edit|create|commit|update|modify|implement|add|remove|delete|rename|rewrite)\b/i;

  pi.on("agent_start", async (event, ctx) => {
    const agent = (event as any)?.agent;
    if (!agent || agent.type !== "scout") return;
    const task = (event as any)?.task ?? "";
    if (WRITE_VERBS.test(task)) {
      ctx?.ui?.notify(
        `scout agent given write task: "${task.slice(0, 80)}..." — scout is read-only. Did you mean task?`,
        "warn",
      );
    }
  });

  // ══════════════════════════════════════════════════════════════
  // 6. Skill freshness — warn when skill is older than AGENTS.md
  // ══════════════════════════════════════════════════════════════
  pi.on("tool_result", async (event, ctx) => {
    if (event.toolName !== "read") return;
    const path: string | undefined = event.input?.path;
    if (typeof path !== "string" || !path.startsWith("skill://")) return;
    const result = event.result;
    if (!result?.content?.[0]) return;

    try {
      const skillName = path.replace("skill://", "").split("/")[0];
      const home = process.env.HOME ?? "~";
      const skillPath = `${home}/.omp/agent/managed-skills/${skillName}/SKILL.md`;
      const agentsPath = `${home}/.omp/agent/managed-skills/${skillName}/SKILL.md`;
      // Compare mtimes
      const out = await pi.exec("stat", ["-c", "%Y", skillPath, `${ctx?.cwd ?? "."}/AGENTS.md`], { timeout: 2000 });
      if (out?.stdout) {
        const [skillTime, agentsTime] = out.stdout.trim().split("\n").map(Number);
        if (skillTime && agentsTime && skillTime < agentsTime) {
          result.content[0].text =
            `[godopty-tools] WARNING: This skill was last modified before AGENTS.md. It may be stale.\n\n` +
            result.content[0].text;
        }
      }
    } catch {
      // best-effort
    }
  });

  // ══════════════════════════════════════════════════════════════
  // 7. Context utilization — warn at 80%+
  // ══════════════════════════════════════════════════════════════
  let warned = false;

  pi.on("turn_end", async (_event, ctx) => {
    if (warned) return;
    try {
      const usage = ctx?.getContextUsage?.();
      if (typeof usage === "number" && usage > 0.8) {
        ctx?.ui?.notify(
          `Context ${Math.round(usage * 100)}% full — consider starting a fresh session`,
          "warn",
        );
        warned = true;
      }
    } catch {
      // API may not be available
    }
  });
}
