# Contributing to Tidal

The easiest way to help is to teach Tidal about another app. No Swift required.

## Add an app to the cleanup catalog

Rules live in [`Resources/catalog.json`](Resources/catalog.json). Each rule is one line:

```json
{ "id": "dev.pip", "title": "pip cache", "pattern": "~/Library/Caches/pip", "tier": "safe", "category": "developer", "kind": "devcache", "note": "Optional hint shown to the user." }
```

| Field | Meaning |
| --- | --- |
| `id` | Unique, dotted, lowercase (`dev.pip`, `app.slack`). |
| `title` | What the user sees. |
| `pattern` | Path to clean. `~` is expanded. |
| `tier` | `safe` = regenerates on its own, `review` = removable but personal or costly to rebuild, `never` = Tidal must never touch it. |
| `category` | `apps`, `developer`, `personal`, `system`, `backups` or `other`. |
| `kind` | What it is: `cache`, `log`, `devcache`, `leftover`, `build`, ... (see existing entries). |
| `note` | Optional short explanation. |

**Rules of thumb**

- If you're not sure deleting it is harmless, use `review`, not `safe`.
- `safe` means the app rebuilds it without losing user data or sign-ins.
- Check the path exists on a real Mac and say which app/version in your PR.
- One app per PR keeps review quick.

## Code changes

1. Fork and branch.
2. `./build.sh` to build, and try your change on a real disk (carefully, this app deletes files).
3. Open a PR describing what and why. Small, focused PRs get merged fastest.

## Bugs and ideas

Use the [issue templates](../../issues/new/choose). For anything that deleted something it shouldn't have,
please include the entry from the Activity log.
