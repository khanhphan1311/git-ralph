# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles
to the actual label strings used in this repo's issue tracker, plus the operational
labels this harness drives.

## Canonical triage roles

| Role in mattpocock/skills | Label in our tracker | Meaning                                  |
| ------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`            | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`              | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`         | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`         | `ready-for-human`    | Requires human implementation            |
| `wontfix`                 | `wontfix`            | Will not be actioned                     |

## Operational labels (driven by `ralph-gh.sh`)

| Label             | Meaning                                                      |
| ----------------- | ----------------------------------------------------------- |
| `ready-for-agent` | The loop may pick this issue up (also a triage role above)  |
| `needs-human`     | A gate failed; an agent stopped and a human must look       |
| `blocked`         | Skipped by the selector until unblocked                     |
| `awaiting-plan`   | Plan posted; parked until a human approves (skipped like `blocked`) |
| `plan-approved`   | Plan approved; selected first, implemented straight away    |
| `P0` / `P1` / `P2`| Priority; the selector sorts `P0 < P1 < P2 < unlabelled`    |

When a skill mentions a role, use the corresponding label string from these tables.
