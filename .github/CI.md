# GoMove test-only CI (M5.7.3A)

The workflow in [workflows/ci.yml](workflows/ci.yml) runs on pull requests and pushes to `main` or `feature/**`. It contains no publishing or deployment step and uses only the read-only `contents` permission. Pull requests execute repository code without production secrets. The checkout action does not retain its Git credential in the worktree.

| Job | Runner | Check |
| --- | --- | --- |
| `backend-tests` | GitHub-hosted `ubuntu-24.04` x64 | Java 21 and `./mvnw -B -ntp clean test`; PostgreSQL/PostGIS is started by Testcontainers using the runner's Docker Engine. On failure, available Surefire reports are retained for seven days. |
| `flutter-checks` | GitHub-hosted `ubuntu-24.04` x64 | Flutter 3.47.5, `flutter pub get --enforce-lockfile`, `flutter analyze --no-pub`, and the full `flutter test --no-pub` suite. The reported count comes from the run; it is not fixed in the workflow. |
| `backend-image-build` | GitHub-hosted `ubuntu-24.04` x64 | After Backend tests pass, builds `backend/Dockerfile` for `linux/amd64` in the ephemeral runner. The image is not pushed or exported. |

The Flutter version is pinned to the version recorded in `mobile/README.md`; the committed `mobile/pubspec.lock` requires Flutter `>=3.38.4`. The workflow uses the lockfile exactly. If the SDK or dependencies change, review and update the SDK pin and lockfile together. All referenced Actions are pinned to full commit SHAs, with their release tags noted beside them. Review updates before changing these SHAs.

Maven dependencies are cached by `setup-java`. Feature pushes and pull requests only restore cache entries; a push to `main` may save a new cache. Jobs must still work with an empty cache.

The test profile in `backend/src/main/resources/application-test.yml` contains only a test JWT key. The integration tests use the shared PostGIS Testcontainer and do not use the development Compose database. CI does not require `JWT_SECRET`, database credentials, an Android device, a Backend server, or a public API URL. The image-build job assembles an image only; it does not start the image or use Compose.

## Local reproduction and first GitHub run

On a machine with a working Docker Engine, from `D:\goMove`:

```powershell
cd backend
.\mvnw.cmd -B -ntp clean test
cd ..\mobile
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
```

The image-build equivalent is `docker build --platform linux/amd64 -f backend/Dockerfile -t gomove-backend:ci backend` from the repository root. Run it only if a local build is needed; the GitHub job uses an isolated runner and does not touch the ASUS development containers.

After code review and an authorized push, open the GitHub **Actions → CI** run for the feature branch or pull request. Verify all three jobs finish successfully, inspect the actual test count and Surefire output, and check the image-build result. Until such a run exists, this workflow is **implemented locally, not verified on GitHub**.

## Troubleshooting

- **Backend Testcontainers or PostGIS fails:** Check the `Check Docker availability` step, Docker Hub pull errors, and the Surefire artifact. The CI runner is x64; the PostGIS test image is used only inside Testcontainers. Do not point tests at a developer database.
- **Maven Wrapper cannot execute:** Check the `chmod +x ./mvnw` step and that `backend/.mvn/wrapper/maven-wrapper.properties` remains committed.
- **Flutter dependency resolution fails:** `--enforce-lockfile` deliberately rejects a lockfile inconsistent with `pubspec.yaml` or package hashes. Review the dependency change; do not silently upgrade packages in CI.
- **Docker image build fails:** Inspect the plain BuildKit log for base-image pull, disk, memory, network, or Maven package errors. A failure or skipped job is not a successful image build.
- **Job is cancelled:** A newer run for the same pull request or branch cancels the older run. Review the latest run.

This CI does not verify Nokia installation, Android E2E, Flutter Profile performance, public HTTPS/WSS, ARM64 PostGIS, or deployment.
