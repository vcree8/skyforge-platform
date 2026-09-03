# Git branching model and code review policy

**Unit 4 - Cloud Computing and DevOps** &nbsp;·&nbsp; OTHM K/650/7997

| Field | Value |
|---|---|
| Artefact reference | P4.1 |
| Assessment criteria | AC 1.2 |
| Task | Task 2 - Project (practical implementation) |
| Learning outcome | LO1 - Understand CI/CD process and techniques |
| Learner | Vera Cree, candidate 240301062 |
| Centre | CIPS DC2401845 |

> Trunk-based development with short-lived branches was chosen over GitFlow: long-lived develop and release branches create merge debt and delay integration, which is the defect that CI exists to remove. Branch protection makes the review policy enforceable rather than advisory.

```text
  BRANCHING MODEL - trunk-based with short-lived feature branches

    main  ----o-------o---------o-----------o--------o------>  always deployable
               \     /           \         /        /
                o---o             o---o---o        /   feature/SKY-214 (2 days)
                 feature/SKY-201       \          /
                                        o--------o    hotfix/SKY-220

    Rules:  branches live no longer than 3 days
            main is always releasable; every commit on main is a release candidate
            releases are cut by tag (v1.8.2), not by branch
            incomplete work ships behind a feature flag, never on a long branch

  BRANCH PROTECTION ON main  (enforced by GitHub, not convention)

    [x] Require a pull request before merging
    [x] Require 2 approving reviews, at least 1 from CODEOWNERS
    [x] Dismiss stale approvals when new commits are pushed
    [x] Require status checks: build, unit-test, sast, sca, image-scan
    [x] Require branches to be up to date before merging
    [x] Require signed commits (GPG)
    [x] Require linear history (squash or rebase merge only)
    [x] Include administrators - no bypass
    [ ] Allow force pushes                          DISABLED
    [ ] Allow deletions                             DISABLED

  CODEOWNERS

    *                       @skyforge/platform-team
    /terraform/             @skyforge/infrastructure @skyforge/security
    /k8s/                   @skyforge/infrastructure
    /docker/Dockerfile      @skyforge/security
    /.github/workflows/     @skyforge/platform-leads

  CODE REVIEW STANDARD
    - Reviewer checks: correctness, test coverage, security, observability,
      rollback path. Style is enforced by the linter, never in review comments.
    - PRs over 400 changed lines are returned for splitting.
    - Review SLA 4 working hours; measured as part of change lead time.
```

---

## Evidence to capture

Screenshot the GitHub branch protection settings page and one merged PR showing 2 approvals and all checks green. Screenshot ref: SS-4.1a, SS-4.1b.
