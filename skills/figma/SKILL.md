---
name: figma
description: "Access Figma through its REST API. Use when the user wants to verify FIGMA_TOKEN, read a Figma file or nodes, inspect file comments, or add or reply to a Figma comment."
---

# Figma

Use the bundled helper to read Figma files, nodes, and comments or to publish
comments with the personal access token in `FIGMA_TOKEN`. Resolve relative paths
from the directory containing this file. The helper requires Bash, `curl`, and
`jq`.

## Steps

1. Resolve the request to `verify`, `read-file`, `read-nodes`,
   `read-comments`, `add-comment`, or `reply-comment`. Accept a file key or a
   Figma Design, legacy file, prototype, or FigJam URL. When an otherwise
   ambiguous read request contains `node-id`, choose `read-nodes`; otherwise
   choose `read-file`. This step is complete when the operation, file, node IDs,
   comment ID, and requested content are unambiguous.
2. Check configuration without exposing the token:
   ```sh
   test -n "${FIGMA_TOKEN:-}" || echo "FIGMA_TOKEN missing"
   ```
   When it is missing, direct the user to [`README.md`](README.md) and stop.
   Ask the user to set the variable in their terminal rather than paste a token
   into chat. This step is complete when the command prints nothing or the user
   receives the missing variable name.
3. Follow the selected read branch:
   - **Verify:** run `bash scripts/figma.sh verify`. Report the returned account
     ID and handle.
   - **Read file:** run
     `bash scripts/figma.sh read-file URL_OR_FILE_KEY`. The helper uses
     `depth=2`, which returns pages and their top-level objects. Add
     `--depth POSITIVE_INTEGER` only when the request needs another depth.
   - **Read nodes:** run
     `bash scripts/figma.sh read-nodes URL_WITH_NODE_ID`. For an explicit batch,
     run
     `bash scripts/figma.sh read-nodes FILE_KEY "12:34,56:78"`. Node subtrees
     are complete by default; add `--depth POSITIVE_INTEGER` to bound them.
     Treat a `null` entry in the returned `nodes` map as a missing or
     inaccessible node, not as an empty node.
   - **Read comments:** run
     `bash scripts/figma.sh read-comments URL_OR_FILE_KEY`. The helper returns
     all comments, including resolved comments and replies, with Markdown
     equivalents where Figma provides them.

   Summarize the requested facts rather than pasting the full JSON by default.
   Include the file key and every relevant node ID, name, and type. State when
   file results stop at a requested depth. This step is complete when every
   requested fact is represented and every missing node or depth limit is
   explicit.
4. Prepare a write:
   - **New comment:** use a general file comment unless the user requests an
     anchored comment. An anchored comment requires a frame node ID plus exact
     `x` and `y` offsets. A URL containing `node-id` is an anchored request; ask
     for missing offsets before proceeding.
   - **Reply:** first run `read-comments` and locate the requested comment ID.
     If it has `parent_id`, use that root comment ID. Show both the requested ID
     and root ID when they differ. Figma accepts replies only to root comments.
   - Treat the approved message as exact text. Preserve its line breaks and
     characters without special handling for mentions.

   State the file key, exact message, and either the general location, anchored
   node and offsets, or reply root. Obtain explicit approval immediately before
   the POST. Any changed value requires fresh approval. This step is complete
   only when all write values are exact and the user has approved those values.
5. Execute the approved write:
   - **General comment:**
     ```bash
     bash scripts/figma.sh add-comment FILE_KEY <<'COMMENT'
     Approved comment text
     COMMENT
     ```
   - **Anchored comment:**
     ```bash
     bash scripts/figma.sh add-comment FILE_KEY \
       --node 12:34 --offset-x 20 --offset-y 40 <<'COMMENT'
     Approved comment text
     COMMENT
     ```
   - **Reply:**
     ```bash
     bash scripts/figma.sh reply-comment FILE_KEY ROOT_OR_REPLY_ID <<'COMMENT'
     Approved reply text
     COMMENT
     ```

   Report the returned comment ID, author, parent ID when present, and location.
   This step is complete only when Figma confirms the created comment.
6. On failure, report the operation, file or comment identifier, HTTP status,
   and helper diagnostic. For HTTP 429, also report `Retry-After`. Retry only
   after the user requests it; every write retry requires fresh approval. For
   endpoint details or manual diagnosis, read
   [`references/api.md`](references/api.md) before constructing a request. This
   step is complete when authentication, permission, validation, missing
   resource, and rate-limit failures are distinguished.
