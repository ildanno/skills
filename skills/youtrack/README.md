# YouTrack Skill

This skill lets an agent read and create YouTrack issues, publish comments,
change board columns, assign issues, and create dependency or hierarchy links.

## Requirements

- Bash
- `curl`
- `jq`
- A YouTrack account with access to the required projects

## Create a Permanent Token

The token uses the permissions of the account that creates it. Its scope selects
which service the token can call; it does not grant additional permissions.

1. In YouTrack, select your avatar, then **Profile**.
2. Open the **Account Security** tab.
3. In the **Tokens** section, select **New token**.
4. Enter a recognizable name and select the **YouTrack** scope. The **YouTrack
   Administration** scope is not required by this skill.
5. Select **Create token**, then copy the generated value immediately. YouTrack
   does not display it again after the dialog is closed.

Creating or revoking your own token requires the global `Update Self`
permission. Permanent tokens do not expire automatically; delete a token from
the same **Account Security** page when it is no longer needed or may have been
exposed.

See the official YouTrack documentation for
[permanent tokens](https://www.jetbrains.com/help/youtrack/cloud/manage-permanent-token.html).

## Required Permissions

Permissions are granted to the token's account through roles. Project-scoped
permissions must be assigned for every project the skill accesses.

| Operation | Required project permissions |
| --- | --- |
| Read an issue without comments | `Read Project Basic`, `Read Issue` |
| Read an issue with comments | `Read Project Basic`, `Read Issue`, `Read Issue Comment` |
| Add a comment | `Read Project Basic`, `Read Issue`, `Create Issue Comment` |
| Create an issue | `Read Project Basic`, `Create Issue` |
| Move or assign an issue | `Read Project Basic`, `Read Issue`, `Update Issue` |
| Link issues | `Read Project Basic` and `Read Issue` for both issues; `Link Issues` for the project of the first issue |

`Read Project Basic` is implied when a role includes `Read Issue` or `Create
Issue`, but it is shown explicitly because the helper resolves projects through
the API. For assignment, the target login must also be an eligible assignee for
the project.

The default `Contributor` role includes the permissions needed by every
operation and is the simplest setup. It also includes unrelated permissions,
including issue deletion. For least privilege, create a custom project role with
only the permissions required by the operations that the account will use.
Creating or editing roles requires `Low-level Admin Write`; an administrator can
then assign the role to the account or one of its groups for the selected
projects.

See the official references for
[permissions](https://www.jetbrains.com/help/youtrack/cloud/youtrack-permissions-reference.html),
[default roles](https://www.jetbrains.com/help/youtrack/cloud/default-roles.html),
and [custom roles](https://www.jetbrains.com/help/youtrack/cloud/create-and-edit-roles.html).

## Configure the Environment

Set the instance URL and, optionally, the default project short name:

```sh
export YOUTRACK_URL="https://example.youtrack.cloud"
export YOUTRACK_PROJECT="DEMO"
```

Set the token in the environment without committing it to the repository. For
example, in Bash you can enter it without displaying it or storing it in shell
history:

```bash
read -r -s -p "YouTrack token: " YOUTRACK_TOKEN
printf '\n'
export YOUTRACK_TOKEN
```

Use your operating system's secret manager when the token must persist across
terminal sessions. Never commit it to a shell configuration file or repository.

`YOUTRACK_PROJECT` is required only when using a bare issue number or creating
an issue without an explicit project. `YOUTRACK_URL` must be the instance URL,
without the `/youtrack/api` suffix.

## Verify the Setup

From this directory, run a read-only request against an issue the account can
access:

```sh
bash scripts/youtrack.sh read DEMO-123 --no-comments
```

An HTTP `401` response indicates a missing or invalid token. An HTTP `403`
response indicates that the account does not have a required permission in the
project.