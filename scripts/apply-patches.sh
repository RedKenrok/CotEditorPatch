#!/usr/bin/env bash
# Applies the numbered patches to the CotEditor submodule.
#
#   scripts/apply-patches.sh                  every patch, in order
#   scripts/apply-patches.sh --through PATCH  the patches up to and including PATCH: its name, such as
#                                             tabs, shell, webpage or remote, or its number, such as 02
#
# The submodule must be initialized and clean. Nothing is ever reset: a checkout with local changes,
# including an already patched one, is refused.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { echo "Usage: $0 [--through PATCH]" >&2; exit 2; }

through=""
case "${1:-}" in
    "") [[ $# -eq 0 ]] || usage ;;
    --through) [[ $# -eq 2 ]] || usage; through="$2" ;;
    *) usage ;;
esac

select_through "$through"
apply_series "$submodule" "${selected[@]}"
