# Roadmap: CI — code analysis

Goal: the pipeline flags code problems, not just compile errors — without
adding heavyweight infrastructure until it earns its keep.

## Phases

1. **Compiler-level, zero new services (do this first).**
   - Roslyn analyzers + `.editorconfig` severities in the app repo;
     `TreatWarningsAsErrors=true` (or `/warnaserror`) in the CI build so drift
     fails the run.
   - `dotnet format --verify-no-changes` as a cheap style gate.
   - Optionally add analyzer packages with real signal for a web app:
     `Microsoft.CodeAnalysis.NetAnalyzers` (built in, raise the level),
     `SonarAnalyzer.CSharp` (works standalone, no SonarQube server needed).

   This is 90 % of the value for one workflow step and zero containers.

2. **SonarQube server — only if history/browsing is wanted.** Community
   edition as an `infra/sonarqube` stack would add issue/coverage/duplication
   *trends* and a browsable UI, and would also solve the history question
   from [ci-testing.md](ci-testing.md). Costs: ~2–3 GB RAM on a 4 GB VM
   (needs the RAM bump from the [monitoring roadmap](monitoring.md) first),
   its own Postgres, and it only supports its own local login in Community —
   so it would join Authentik by the forward-auth pattern like Dockge.

   **Recommendation: stay on phase 1 until the analyzer output feels
   insufficient.** A one-person lab rarely needs trend dashboards for issues.

## Notes

- Analyzer severities live in the app repo (`.editorconfig`), so IDE and CI
  agree by construction — no CI-only rule set.
- If SonarQube lands, scanner steps go into the test job (it wants coverage
  files), not the build job.
