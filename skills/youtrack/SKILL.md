---
name: youtrack
description: "YouTrack issue communication. Use when the user wants to read a YouTrack ticket or add a comment to it."
---

# YouTrack

Use the bundled helper to communicate with a configured YouTrack instance. The
supported write is adding a comment; field, state, and assignee changes remain in
the YouTrack UI. Resolve relative paths from the directory containing this file.
The helper requires `curl` and Python 3.

## Steps

1. Resolve the request to one issue and either `read` or `comment`. Accept an ID
   in `PROJECT-NUMBER` format or a bare issue number, which the helper resolves
   against `YOUTRACK_PROJECT`. This step is complete when the issue and operation
   are unambiguous.
2. Check configuration without exposing the token:
  ```sh
  test -n "${YOUTRACK_URL:-}" || echo "YOUTRACK_URL missing"
  test -n "${YOUTRACK_PROJECT:-}" || echo "YOUTRACK_PROJECT missing"
  test -n "${YOUTRACK_TOKEN:-}" || echo "YOUTRACK_TOKEN missing"
   ```
   `YOUTRACK_URL` is the instance URL without `/youtrack/api`, and
   `YOUTRACK_PROJECT` is the default project name. When a value is missing, ask
   the user to set it directly in their terminal, then stop. This step is
   complete when the command prints nothing or after the user receives the
   missing variable names.
3. Follow the selected branch:
   - **Read:** run `bash scripts/youtrack.sh read DEMO-403`. Add
     `--no-comments` only when comments are irrelevant. Summarize the title,
     relevant fields, description, and every material comment. This branch is
     complete when every part requested by the user is represented.
   - **Comment:** draft the exact comment and obtain the user's explicit
     approval. After approval, pass the text on standard input:
     ```bash
     bash scripts/youtrack.sh comment 403 <<'COMMENT'
     Approved comment text
     COMMENT
     ```
     Report the returned comment ID and author. This branch is complete only
     when YouTrack confirms the created comment.
4. On failure, report the issue ID, operation, and diagnostic from the helper.
   This step is complete when authentication, permission, missing-issue, or
   service failures are identified distinctly.

For endpoint details or manual diagnosis after a helper failure, read
[`references/api.md`](references/api.md) before constructing an API request.
