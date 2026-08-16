# Roadmap: CI — code analysis history

Compiler-level analysis has **landed**. Roslyn analyzers with `.editorconfig`
severities, `TreatWarningsAsErrors`, and a `dotnet format --verify-no-changes`
gate all run in the app repo's own workflow, so drift fails the run — and the
severities live beside the code, which is what makes the IDE and CI agree by
construction rather than through a CI-only rule set. Tests and coverage landed
in the same pass: a failing test fails the run, and the coverage report is
rendered into the run summary.

That was the phase worth doing first, and it needed no new service. **One
decision is still open**, and it is the only part of code analysis that would
ever be *this* repo's work rather than the app repo's.

## SonarQube — only if history is wanted

Both of the pieces that landed above are **per-run**: the analyzer output is a
list of warnings in one build, and the coverage number is a summary on one run
page. Neither answers "is this getting better or worse?" A SonarQube Community
Edition stack at `infra/sonarqube` would — issue, coverage and duplication
*trends*, plus a browsable UI — and it would answer that question once for both,
which is why the coverage-history option and the analysis-history option are
the same decision and not two.

What it would cost:

- ~2–3 GB of RAM on the infra VM, and its own Postgres beside the four already
  running.
- Community Edition supports only its own local login, so it would join
  Authentik by the **forward-auth** pattern like Dockge — a DNS row, an SSO row
  and a Kuma row, like any other gated UI.
- A scanner step in the workflow that already produces coverage files, in the
  app repo, not here.

**Recommendation: don't, yet.** A one-person lab rarely needs trend dashboards
for its own issue count, and the per-run output has not yet felt insufficient.
Revisit when it does — that is the trigger, not a date.
