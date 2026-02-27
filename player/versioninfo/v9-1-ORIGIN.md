# v9-1 ORIGIN — Production Firstboot Hardening

**Date Range:** February 26, 2026  
**Images:** v9-1-0 through v9-1-7  
**Codename:** ORIGIN

---

## Overview

The v9-1 series was a rapid-fire root cause analysis sprint that resolved 6 cascading firstboot failures. Each version isolated and fixed a single root cause, progressing from gate file races to clock skew to self-deleting service symlinks.

## Root Causes Fixed

| Version | Root Cause | Fix |
|---------|-----------|-----|
| v9-1-0 | Armbian `armbian-firstlogin` deletes ODS gate file → blocks firstboot | ODS-owned gate file at `/var/lib/ods/atlas_firstboot_pending` + mask Armbian first-login |
| v9-1-1 | `After=network-online.target` blocks indefinitely without ethernet at golden boot | `After=basic.target` + script-level `wait_for_network()` with timeout |
| v9-1-2 | `set -e` silently kills 1400-line firstboot on any non-zero return | `set -o pipefail` + ERR trap that logs the failing line number |
| v9-1-3/4 | Single `apt-get install` batch — one 404 cascades to skip ALL packages | 3 resilient batches (infra, display, build tools) with `--fix-missing` |
| v9-1-5 | Clock skew (Pi starts with image creation date) → apt signature check fails → stale index → Chromium 404 | NTP sync in `wait_for_network()` before apt + Chromium-specific retry with fresh `apt-get update` |
| v9-1-7 | `armbian-resize-filesystem` is one-shot + self-deleting: runs during P:1, deletes own symlink → cloned cards stuck at 4G | `finalize_phase1()` re-enables the service before shutdown — clones auto-expand |

## Key Design Decision

The resize fix was initially implemented as a bandaid in `inject_atlas.sh` (v9-1-6), but forensic analysis of all golden images on jdl-mini-box revealed the issue was latent since v8-1-0. The proper fix was moved to `atlas_firstboot.sh` `finalize_phase1()` (v9-1-7), making P:0 clean and self-contained.

## Forensic Evidence (jdl-mini-box image analysis)

| Image | Resize Symlink | Phase |
|-------|---------------|-------|
| All pre-P1 goldens (v4-v9) | ✅ Present (from base Armbian) | — |
| v8-1-0-FLASH clone | ❌ Missing (self-deleted) | 2 |
| v9-1-4 clone | ❌ Missing (self-deleted) | 2 |
| v9-1-6 clone (manual fix) | ✅ Present (manually re-added) | 2 |
| v9-1-7 clone (proper fix) | ✅ Present (from `finalize_phase1()`) | 2 |

## Commits

| Commit | Change |
|--------|--------|
| `7b82395` | ODS gate file + disable Armbian first-login |
| `ef98b61` | `After=basic.target` + script-level `wait_for_network()` |
| `6ab2af1` | Replace `set -e` with `set -o pipefail` + ERR trap |
| `ddc498e` | 3 resilient apt batches with `--fix-missing` |
| `c568e7b` | NTP clock sync + Chromium retry |
| `bd7c668` | Re-enable resize in inject (interim — replaced by v9-1-7) |
| `054a3d0` | `finalize_phase1()` re-enables resize — proper fix |
