#!/usr/bin/env bash

INTERVAL=60
LOG_FILE="monitor.log"

while true; do
    {
        echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---"
        free -h
        df -h
        uptime
        echo
    } >> "$LOG_FILE" 2>&1
    sleep "$INTERVAL"
done
