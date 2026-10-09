// Builder guard: injected with every architect dispatch (`pi -e <path>`) to
// deny, before evaluation, the two failure modes a hermetic builder must not
// reach: git writes (the architect CLI owns all commits in a lane worktree)
// and commands bash cannot parse (a parse error at tool time burns a turn).
// Parse-level only: `bash -n` cannot catch runtime failures — those are the
// bash tool's own domain.
import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Git subcommands that mutate repository state. Reads (log, diff, show, …)
// stay allowed — only the write verbs are denied.
const GIT_WRITE_VERBS = new Set([
	"commit",
	"push",
	"pull",
	"reset",
	"merge",
	"rebase",
	"checkout",
	"switch",
	"branch",
	"tag",
	"cherry-pick",
	"revert",
	"stash",
	"worktree",
	"clean",
	"restore",
	"rm",
	"mv",
	"am",
	"apply",
]);

// Global flags that consume a following value, when locating the subcommand —
// `git -C <path> commit` must classify as commit (flags sit between `git` and
// the subcommand, so an adjacency pattern misses it).
const GIT_VALUE_FLAGS = new Set(["-C", "-c"]);

// Split a command line into simple-command segments at the shell's command
// separators. Whitespace tokenization only: this is a deny list, not a shell
// reimplementation, and the deny decision never depends on quoting structure
// beyond what the separator split already crossed.
function segments(command: string): string[] {
	return command.split(/\r?\n|\|\||&&|[;|]/);
}

// The git subcommand a segment invokes, or null: walk the tokens after `git`,
// skipping global flags (and their values) so the first positional token is
// the subcommand. Never substring-match the raw command — `git log
// --grep=commit` mentions `commit` but is a read.
function gitSubcommand(segment: string): string | null {
	const tokens = segment.trim().split(/\s+/);
	if (tokens[0] !== "git") return null;

	for (let i = 1; i < tokens.length; i++) {
		const tok = tokens[i];
		if (!tok.startsWith("-")) return tok;
		if (GIT_VALUE_FLAGS.has(tok)) i++; // skip the flag's value
	}
	return null;
}

function gitWriteDenial(command: string): string | null {
	for (const segment of segments(command)) {
		const sub = gitSubcommand(segment);
		if (sub && GIT_WRITE_VERBS.has(sub)) {
			return `git ${sub} writes repository state — the architect CLI owns all commits and git mutations; ` +
				`leave repository state alone and report what you would have run`;
		}
	}
	return null;
}

// Parse-check via `bash -n`: stdin carries the command, stderr is the reason.
function parseDenial(command: string): string | null {
	const check = spawnSync("bash", ["-n"], { input: command, encoding: "utf8" });
	if (check.status === 0) return null;
	return `command does not parse under \`bash -n\` and would burn a turn at tool time; ` +
		`fix the command's syntax — bash said: ${(check.stderr ?? "").trim()}`;
}

export default function builderGuard(pi: ExtensionAPI): void {
	pi.on("tool_call", (event) => {
		// bash only: the deny list is shell-command shaped; edit/write tools are
		// bounded by the lane's touch set, not this guard.
		if (event.toolName !== "bash") return;
		const command = (event.input as { command?: unknown }).command;
		if (typeof command !== "string") return;

		// Test the command string itself, never the JSON-rendered whole input —
		// a payload that merely mentions `git commit` in prose must not match.
		const denial = gitWriteDenial(command) ?? parseDenial(command);
		if (denial) {
			return {
				block: true,
				// The reason is the builder's only feedback: it must say what was
				// denied and what to do instead.
				reason: `architect builder guard: ${denial}`,
			};
		}
	});
}
