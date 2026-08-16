# Task: SonarQube (parked decision)

The one piece of code analysis still open, and the only part of it that would
ever be *this* repo's work rather than the app repo's. Everything else landed —
analyzers enforced in the build, `dotnet format` gate, tests and coverage in
the run summary ([done/ci-code-analysis.md](done/ci-code-analysis.md)).

**The question it answers.** Everything that landed is **per-run**: a list of
warnings in one build, a coverage number on one run page. Neither answers "is
this getting better or worse?" A SonarQube Community Edition stack at
`infra/sonarqube` would — issue, coverage and duplication *trends* in a
browsable UI — and it answers that question once for both, which is why
coverage history and analysis history are one decision and not two.

**What it would cost.**

- ~2–3 GB of RAM on the infra VM, and a fifth Postgres beside the four running.
- Community Edition has only local login, so it joins Authentik by
  **forward-auth** like Dockge — a DNS row, an SSO row and a Kuma row, plus a
  backup.sh/restore.sh pair like any other stateful stack.
- A scanner step in the workflow that already produces coverage files — in the
  app repo, not here.

## Recommendation

**Don't, yet** — unchanged. A one-person lab rarely needs trend dashboards for
its own issue count, and the per-run output has not felt insufficient. The
trigger is that feeling arriving, not a date. If it arrives, the row above is
already the design: SonarQube is a routine stack by this repo's conventions,
and the only genuinely new work is the scanner step on the other side.
