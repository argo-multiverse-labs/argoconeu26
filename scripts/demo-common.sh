#!/usr/bin/env bash

# Source demo-magic.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/demo-magic.sh"

# Typing speed (characters per second)
TYPE_SPEED=40

# Custom prompt per character role
PLATFORM_PROMPT="\033[1;34m[Platform Engineer]\033[0m $ "
ROGUE_PROMPT="\033[1;31m[Rogue Tenant]\033[0m $ "

# Reset to default
DEFAULT_PROMPT="$ "

# Scene separator
function scene_break() {
    echo ""
    echo -e "\033[1;33m═══════════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;33m  $1\033[0m"
    echo -e "\033[1;33m═══════════════════════════════════════════════════════\033[0m"
    echo ""
    wait
}

# Role switch
function as_platform_engineer() {
    DEMO_PROMPT="$PLATFORM_PROMPT"
}

function as_rogue_tenant() {
    DEMO_PROMPT="$ROGUE_PROMPT"
}

function as_narrator() {
    DEMO_PROMPT="$DEFAULT_PROMPT"
}
