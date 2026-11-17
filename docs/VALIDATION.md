# Validation record

## Behavioral investigation, November 2026

One Lenovo Legion Y530-15ICH with i7-8750H, UHD 630 and GTX 1050 Ti was investigated. The OS/driver versions, quantitative A/B/A results, post-reboot observation, and limits are in the README. Raw ETLs, kernel dumps, personal paths, security-descriptor backups, and installation identifiers are not part of this repository.

Changing only the MixedReality keyword produced the large reversible difference in System CPU. The original configuration was restored during both A/B/A experiments and the symptom returned. The workaround was then applied again and persisted across a reboot without reapplication. A short NVIDIA D3D11 functional check succeeded.

These observations do not prove physical D3cold, every application's compatibility, absence of all DPC spikes, or a Windows 24H2 introduction date.

## Language handling

The language-independent parser was exercised under process cultures pt-BR, en-US, es-ES, de-DE, fr-FR, ja-JP and tr-TR. Tests also changed display labels/descriptions and checked refusal of nonzero/enabled/payload filters, missing fields and mismatched identities. This is not a claim of testing seven separate Windows installations.

## Public English package

Offline tests parse all PowerShell files, validate native x64 layouts, exercise invariant XML/filter guards and backup validation, verify embedded file hashes, and compare packaged content with source. `/check` compiles the helpers after extraction without invoking native changes. A separate elevated `/status` checks the real installation without applying or undoing the workaround.

Apply/Undo reuse the examined native registry/ETW mechanisms with additional installation-bound backup checks in this edition. They were not rerun just to test packaging. Runtime refusal and offline validation are not a substitute for behavioral testing on another PC.

The GitHub Actions workflow runs offline checks only. It never modifies registry values, starts/stops trace sessions, or attempts the workaround on a hosted runner.
