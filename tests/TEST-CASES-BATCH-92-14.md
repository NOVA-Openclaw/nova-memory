# Test Cases: Batch Fix — nova-memory #92 / nova-relationships #14

**Fix:** Replace `cp -r` with `find`-based copy excluding `node_modules/` and `dist/`

---

## Setup

Create source dirs with this structure:

```
source-skill/
├── index.js
├── config.json
├── lib/
│   └── helper.js
├── node_modules/
│   └── lodash/
│       └── index.js (50KB+)
└── dist/
    └── bundle.js
```

---

## Test Cases

| # | Case | Steps | Expected |
|---|------|-------|----------|
| 1 | Fresh install — node_modules excluded | Run install with source containing `node_modules/` | Target has no `node_modules/` dir |
| 2 | Fresh install — dist excluded | Run install with source containing `dist/` | Target has no `dist/` dir |
| 3 | Fresh install — normal files copied | Run install with source containing `index.js`, `lib/helper.js` | All non-excluded files present in target with correct contents |
| 4 | Re-run — only real files synced | Run install twice; add `node_modules/` to source between runs | Target still has no `node_modules/`; real files updated |
| 5 | `--force` flag — still excludes | Run install with `--force` on source with `node_modules/` + `dist/` | Neither `node_modules/` nor `dist/` in target; real files present |
| 6 | Hooks install (nova-memory) | Source hook dir has `node_modules/` from a bundled dep | Hook copied to target without `node_modules/` |
| 7 | Skills install (both repos) | Source skill dir has `node_modules/` and `dist/` | Skill copied to target without either; `index.js` etc. present |

---

## Verification Commands

```bash
# After each test, run from target dir:
test ! -d node_modules && echo "PASS: no node_modules" || echo "FAIL"
test ! -d dist && echo "PASS: no dist" || echo "FAIL"
test -f index.js && echo "PASS: source files present" || echo "FAIL"
```

## Repos

- **nova-memory**: test cases 1–7 (has hooks + skills)
- **nova-relationships**: test cases 1–5, 7 (skills only, no hooks)
