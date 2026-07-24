# Figma Skill

This skill uses a Figma personal access token to verify the authenticated
account, read files and nodes, inspect comments, and add or reply to comments.
It does not render images, export vector geometry, read historical versions, or
perform other write operations.

## Requirements

- Bash
- `curl`
- `jq`
- A Figma account with access to the target files

## Create a Personal Access Token

1. Sign in to Figma and open the account menu from the file browser.
2. Select **Settings**, then **Security**.
3. Under **Personal access tokens**, select **Generate new token**.
4. Choose an expiration and the scopes needed for your operations.
5. Generate and copy the token. Figma displays it only once.

Use the narrowest scopes that cover the required commands:

| Command | Required scope |
| --- | --- |
| `verify` | `current_user:read` |
| `read-file`, `read-nodes` | `file_content:read` |
| `read-comments` | `file_comments:read` |
| `add-comment` | `file_comments:write` |
| `reply-comment` | `file_comments:read`, `file_comments:write` |

For every feature, grant `current_user:read`, `file_content:read`,
`file_comments:read`, and `file_comments:write`. Scopes do not add access to
files that the account cannot already open.

See Figma's official documentation for
[personal access tokens](https://developers.figma.com/docs/rest-api/personal-access-tokens/)
and [scopes](https://developers.figma.com/docs/rest-api/scopes/).

## Configure the Environment

Set the token without committing it to the repository or pasting it into chat.
For example, Bash can read it without displaying it or storing it in shell
history:

```bash
read -r -s -p "Figma token: " FIGMA_TOKEN
printf '\n'
export FIGMA_TOKEN
```

Use an operating-system secret manager when the token must persist across
terminal sessions. Revoke the token immediately if it may have been exposed.

## Verify the Setup

Run the read-only authentication check:

```sh
bash scripts/figma.sh verify
```

The output contains only the authenticated account's Figma ID and handle. HTTP
403 indicates an invalid token, a missing scope, or insufficient access.

## Read Files and Nodes

Pass either a file key or an HTTPS URL from Figma Design, a legacy Figma file,
a prototype, or FigJam:

```sh
bash scripts/figma.sh read-file \
  "https://www.figma.com/design/FILE_KEY/Example"

bash scripts/figma.sh read-file FILE_KEY --depth 3
```

File reads default to `depth=2`: pages and the top-level objects on each page.
Read a node directly from its URL:

```sh
bash scripts/figma.sh read-nodes \
  "https://www.figma.com/design/FILE_KEY/Example?node-id=12-34"
```

Or request several nodes in one API call:

```sh
bash scripts/figma.sh read-nodes FILE_KEY "12:34,56:78"
bash scripts/figma.sh read-nodes FILE_KEY "12:34,56:78" --depth 2
```

Node reads return complete subtrees unless `--depth` is present. The helper
normalizes the `12-34` URL form to the `12:34` API form.

## Read and Write Comments

Read all comments, including replies and resolved comments:

```sh
bash scripts/figma.sh read-comments FILE_KEY
```

Add a general file comment:

```bash
bash scripts/figma.sh add-comment FILE_KEY <<'COMMENT'
Please review this flow.
COMMENT
```

Figma requires both a frame node and an offset for an anchored comment:

```bash
bash scripts/figma.sh add-comment FILE_KEY \
  --node 12:34 --offset-x 20 --offset-y 40 <<'COMMENT'
Please review this frame.
COMMENT
```

Reply using either a root comment ID or one of its reply IDs. The helper reads
the file's comments and sends the reply to the root because Figma does not
accept replies to replies:

```bash
bash scripts/figma.sh reply-comment FILE_KEY COMMENT_ID <<'COMMENT'
Addressed in the latest revision.
COMMENT
```

The helper sends comment text exactly as received on standard input. Figma's
public REST API does not document a syntax for creating user mentions, so the
helper does not transform `@handle` text.

Agents using this skill show the exact pending write and request approval before
calling a write command. The helper itself is also suitable for direct terminal
use and therefore does not implement an interactive approval prompt.

## Errors and Rate Limits

The helper reports the operation, resource, HTTP status, and any Figma
diagnostic. It does not retry requests. On HTTP 429 it also reports the
`Retry-After` duration supplied by Figma.
