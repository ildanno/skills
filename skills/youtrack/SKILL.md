---
name: youtrack
description: "Manage YouTrack issues and cards. Use when the user wants to read or create a YouTrack ticket, publish a comment, move a card between board columns, assign a card, or link issues as dependencies, parents, or subtasks."
---

# YouTrack

Use the bundled helper to communicate with a configured YouTrack instance. The
helper reads and creates issues, publishes comments, changes a card's column,
assigns issues, and adds dependency or hierarchy links. Resolve relative paths
from the directory containing this file. The helper requires `curl` and `jq`.

Treat "card" and "issue" as the same YouTrack entity. Moving a card changes the
custom field represented by `YOUTRACK_COLUMN_FIELD`, which defaults to `State`.

## Steps

1. Resolve the request to `read`, `comment`, `move`, `assign`, `create`, or
   `link`. Accept an issue ID in `PROJECT-NUMBER` format or a bare number, which
   the helper resolves against `YOUTRACK_PROJECT`. For `link`, resolve both issue
   IDs and the direction of the relationship. This step is complete when every
   issue, value, and direction is unambiguous.
2. Check configuration without exposing the token:
  ```sh
  test -n "${YOUTRACK_URL:-}" || echo "YOUTRACK_URL missing"
  test -n "${YOUTRACK_TOKEN:-}" || echo "YOUTRACK_TOKEN missing"
   ```
   `YOUTRACK_URL` is the instance URL without `/youtrack/api`, and
   `YOUTRACK_PROJECT` is the optional default project short name. It is required
   for a bare issue number and for `create` without `--project`. When a required
   value is missing, ask the user to set it directly in their terminal, then
   stop. This step is complete when the command prints nothing or after the user
   receives the missing variable names.
3. For any write, state the exact pending change and obtain the user's explicit
   approval immediately before executing it. Include the issue IDs and all
   comment, column, assignee, project, summary, description, or link direction
   values. Do not reuse approval after changing any value. Reads do not require
   approval.
4. Follow the selected branch:
   - **Read:** run `bash scripts/youtrack.sh read DEMO-403`. Add
     `--no-comments` only when comments are irrelevant. Summarize the title,
     relevant fields, description, and every material comment. This branch is
     complete when every part requested by the user is represented.
   - **Comment:** after approval, pass the exact text on standard input:
     ```bash
     bash scripts/youtrack.sh comment 403 <<'COMMENT'
     Approved comment text
     COMMENT
     ```
     Report the returned comment ID and author. This branch is complete only
     when YouTrack confirms the created comment.
   - **Move:** after approval, run
     `bash scripts/youtrack.sh move DEMO-403 "In Progress"`. This applies
     `State In Progress` by default. Set `YOUTRACK_COLUMN_FIELD` when the board's
     columns use another custom field. Report the confirmed issue and query.
   - **Assign:** after approval, run
     `bash scripts/youtrack.sh assign DEMO-403 jane.doe`, using the user's login
     rather than display name. `me` assigns the authenticated user. Report the
     confirmed issue and query.
   - **Create:** require a non-empty summary and exact project. Treat the
     description as optional, and show both values during approval. Then run:
     ```bash
     bash scripts/youtrack.sh create --project DEMO --summary "Card summary" <<'DESCRIPTION'
     Approved description.
     DESCRIPTION
     ```
     Omit `--project` only when `YOUTRACK_PROJECT` is correct. Report the new
     readable issue ID, summary, and project.
   - **Link:** choose one direction and explain it during approval:
     `depends-on` means the first issue depends on the second; `required-for`
     means the first is required by the second; `parent-for` means the first is
     the parent; `subtask-of` means the first is the child. Then run, for example:
     ```bash
     bash scripts/youtrack.sh link DEMO-403 depends-on DEMO-401
     ```
     Report both IDs and the confirmed query. Never infer the direction solely
     from an ambiguous request such as "link A and B".
5. On failure, report the issue ID or project, operation, HTTP status, and
   diagnostic from the helper. Do not retry a write until any ambiguous column,
   login, project, or link direction has been corrected and approved again.
   This step is complete when authentication, permission, missing-issue, or
   validation failures are identified distinctly.

For endpoint details or manual diagnosis after a helper failure, read
[`references/api.md`](references/api.md) before constructing an API request.
