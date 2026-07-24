# Agent Skills

Reusable [Agent Skills](https://agentskills.io/) distributed through the
[`skills`](https://github.com/vercel-labs/skills) CLI.

## Install

List the skills available in this repository:

```sh
npx skills add ildanno/skills --list
```

Install every skill in the repository:

```sh
npx skills add ildanno/skills --all
```

The CLI detects supported agents and installs each skill in the appropriate
project or user directory.

## Available Skills

- [figma](skills/figma/README.md): verifies a Figma personal access token,
    reads files, nodes, and comments, and adds or replies to comments.
- [youtrack](skills/youtrack/README.md): reads, creates, comments on, moves,
    assigns, and links issues in a configured YouTrack instance.

## Repository Layout

```text
skills/
└── <skill-name>/
    ├── README.md        # Optional human-facing setup and usage
    ├── SKILL.md
    ├── scripts/       # Optional executable helpers
    ├── references/    # Optional documentation loaded on demand
    └── assets/        # Optional templates and static resources
```

Each skill is self-contained. Its directory name must match the `name` in the
`SKILL.md` frontmatter.

## Development

Create a skill from the CLI template:

```sh
cd skills
npx skills init my-skill
```

After editing it, verify local discovery from the repository root:

```sh
npx skills add . --list
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the authoring rules and review
checklist.
