# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `question`           | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

## Notes

- Upstream (`Leviidev/Henge`) has no contribution rules, issue templates or triage scheme; it uses only GitHub's stock labels (`bug`, `enhancement`, `question`, `wontfix`, ...), which the fork inherited. `wontfix` and `question` are those stock labels, reused here. The other three were created on the fork.
- `question` doubles as the `needs-info` role. It is also the stock label for ordinary questions, so when triaging, treat a `question` issue as needs-info only if the reporter owes us details.
- The stock `bug` / `enhancement` labels are the category labels. They are independent of these state labels and can be combined with them.
