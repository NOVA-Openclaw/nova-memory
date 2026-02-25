#!/bin/bash
# Daily embedding cron job
# Runs both file-based and database embedders

LOG_FILE="$HOME/clawd/logs/embed-memories.log"
VENV="$HOME/clawd/scripts/tts-venv/bin/activate"

echo "=== $(date -Iseconds) ===" >> "$LOG_FILE"
source "$VENV"

# Embed file-based memories (daily logs, MEMORY.md)
echo "--- embed-memories (files) ---" >> "$LOG_FILE"
python "$HOME/clawd/scripts/embed-memories.py" >> "$LOG_FILE" 2>&1
echo "embed-memories exit: $?" >> "$LOG_FILE"

# Embed database tables (entities, tasks, projects, library, etc.)
echo "--- embed-full-database ---" >> "$LOG_FILE"
python "$HOME/clawd/scripts/embed-full-database.py" >> "$LOG_FILE" 2>&1
echo "embed-full-database exit: $?" >> "$LOG_FILE"

echo "" >> "$LOG_FILE"
