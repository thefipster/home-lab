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

Extracted to [sonarqube.md](../sonarqube.md): what a Community Edition stack
would buy (issue, coverage and duplication *trends* rather than per-run
output), what it would cost, and the recommendation — don't, yet; the trigger
is the per-run output starting to feel insufficient, not a date.
