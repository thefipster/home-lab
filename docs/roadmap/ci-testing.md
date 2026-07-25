# Roadmap: CI — tests, coverage & results

Goal: a manual `workflow_dispatch` run **fails when tests fail**, and coverage
is visible per run without leaving Forgejo.

Applies to the app repo's `.forgejo/workflows/build-and-push.yml` (template:
`infra/forgejo/build-and-push.yml`).

## Phases

1. **Test job before the build job.** A separate job using the .NET SDK image
   (`mcr.microsoft.com/dotnet/sdk:9.0`) rather than the `act` image — it only
   needs `dotnet`, and the build job stays as is, gated with `needs: test`.

   ```yaml
   - run: dotnet test src/dotnet
       --logger trx
       --collect:"XPlat Code Coverage"
       --results-directory ./test-results
   ```

2. **Coverage report in the run summary.** ReportGenerator converts the
   Cobertura output to Markdown and HTML; the Markdown goes to
   `$GITHUB_STEP_SUMMARY` (Forgejo renders step summaries), the HTML report is
   uploaded as a run artifact. That covers "see results per run" with zero
   extra services.

3. **Thresholds.** Once a baseline exists, fail the job under a minimum line
   coverage (ReportGenerator or `coverlet` `/p:Threshold=`). Start
   report-only; flip to enforcing after a few runs.

4. **History over time** — decide later. Options, in ascending weight:
   - keep it per-run (artifacts + summaries) — free, probably enough;
   - ReportGenerator's history feature persisted to a cache/artifact;
   - SonarQube, which tracks coverage trends properly — but that's the
     [code-analysis roadmap](ci-code-analysis.md) decision, don't buy it for
     coverage alone.

## Notes

- Cache NuGet packages (`actions/cache` on `~/.nuget/packages`) — the test job
  otherwise restores from scratch every run.
- Tests run in the workflow, not in the Dockerfile: a Dockerfile test stage
  can't publish TRX/coverage artifacts to the run, and it would slow every
  image build.
- Mirror caveat as always: workflow changes are committed to **GitHub** and
  mirror in; test them via **Run workflow** after a sync.
