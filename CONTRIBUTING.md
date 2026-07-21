# Contributing

## Add a Skill

1. Create `skills/<skill-name>/SKILL.md`.
2. Use a lowercase name containing only letters, numbers, and single hyphens.
3. Make the frontmatter `name` exactly match the parent directory.
4. Describe both what the skill does and when an agent should activate it.
5. Write concrete, ordered instructions that an agent can execute.
6. Put optional executables, detailed documentation, and templates in
   `scripts/`, `references/`, and `assets/` respectively.
7. Put human-facing installation, configuration, and usage instructions in an
   optional `README.md` at the skill root. Keep `references/` focused on
   material the agent loads while executing the skill.

At minimum, every `SKILL.md` starts with:

```yaml
---
name: my-skill
description: "Performs a specific workflow. Use when the user asks for that workflow or mentions its main trigger terms."
---
```

The `name` must be 1-64 characters. The `description` must be 1-1024
characters. Follow the complete [Agent Skills
specification](https://agentskills.io/specification) for optional fields and
resource conventions.

## Authoring Guidelines

- Keep `SKILL.md` focused and below 500 lines.
- Put activation keywords in `description`; agents use it for discovery.
- Prefer imperative steps and explicit decision criteria over general advice.
- Keep file references one level deep and relative to the skill root.
- Document dependencies and environment requirements.
- Make bundled scripts self-contained, deterministic, and safe to rerun.
- Include edge cases when they materially change the workflow.

## Verify a Change

From the repository root, confirm that the CLI discovers the skill:

```sh
npx skills add . --list
```

Before opening a pull request, also check that:

- the directory and frontmatter names match;
- the description says what the skill does and when to use it;
- every referenced file exists;
- examples contain no credentials or environment-specific paths;
- the instructions do not depend on context outside the skill unless stated.
