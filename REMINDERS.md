# REMINDERS.md — Periodic Actions

*This file is triggered by cron every 30 minutes. Execute these actions, don't just read them.*

## Actions to Perform

### 1. Scan SOPs from Database
```sql
SELECT name, description FROM sops ORDER BY name;
```
Review the list. If any are relevant to recent work, refresh your memory on the full procedure.

### 2. Scan 1Password Vault
```bash
eval $(gpg --decrypt ~/.secrets/1password-master.gpg 2>/dev/null | op signin --account family) && op item list --format=json | jq -r '.[] | "\(.title) | \(.category)"' | sort
```
Review the list. Note any accounts you'd forgotten about.

### 3. Check for Pending Tasks
```sql
SELECT id, title, status, due_date FROM tasks WHERE status != 'completed' AND assigned_to = 1 ORDER BY due_date;
```
Review pending tasks. Flag any that are overdue or due soon.

---

*After completing these actions, log a brief summary to `memory/YYYY-MM-DD.md` if anything notable was found.*
