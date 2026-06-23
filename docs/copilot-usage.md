# Copilot CLI Usage

GitHub Copilot CLI can be used interactively with `copilot` or non-interactively with `copilot -p`.

## Non-interactive usage for this workflow

The workflow scripts use Copilot in prompt mode and capture stdout into both the expected artifact file and the stage log:

```bash
set -o pipefail; copilot -p "$(cat "$PROMPT_FILE")" -s --allow-all-tools | tee "$OUTPUT_FILE"
```

Useful flags:

- `-p, --prompt <text>`: execute a prompt in non-interactive mode and exit after completion.
- `-s, --silent`: output only the agent response, which is suitable for writing generated scripts or Markdown documents.
- `--allow-all-tools`: allow tool execution without interactive prompts while preserving path and URL controls.
- `--model <model>`: choose a specific model; omit it or use `auto` when the CLI should choose.

The scripts expose `COPILOT_*_CMD_TEMPLATE` environment variables when a team needs to override the default command, for example to use a different model, agent, or permission policy.
