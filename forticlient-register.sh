#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Must run as root"
    exit 1
fi

if ! command -v forticlient &>/dev/null; then
    echo "[ERROR] FortiClient not installed"
    exit 1
fi

echo "[LOG] Registering FortiClient EMS: fems.iplace.se (site: INDNAV)"
forticlient epctrl register fems.iplace.se -s INDNAV 2>&1
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "[OK] FortiClient registered successfully"
else
    echo "[ERROR] Registration failed (exit code: $EXIT_CODE)"
    exit $EXIT_CODE
fi
