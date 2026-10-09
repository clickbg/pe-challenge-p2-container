# pe-challenge-p2-container

[![CI](https://github.com/clickbg/pe-challenge-p2-container/actions/workflows/ci.yml/badge.svg)](https://github.com/clickbg/pe-challenge-p2-container/actions/workflows/ci.yml)
[![Publish](https://github.com/clickbg/pe-challenge-p2-container/actions/workflows/publish.yml/badge.svg)](https://github.com/clickbg/pe-challenge-p2-container/actions/workflows/publish.yml)

Phase 2 of the Mondoo Platform Engineer challenge. This repo turns releases of [pe-challenge-p1-go-app](https://github.com/clickbg/pe-challenge-p1-go-app) into a signed container image on Docker Hub ([clickbg/hello-mondoo](https://hub.docker.com/r/clickbg/hello-mondoo)) and holds the Kubernetes manifests that deploy it.

## How a release flows

```
p1-go-app                                      p2-container
---------                                      ------------
git push tag v1.2.3
  -> Release: CI gate, build, sign, publish
  -> Dispatch deploy (workflow_run)
       GitHub App token, 1h, this repo only
       repository_dispatch app-released  ---->  Publish
                                                  resolve + validate tag
                                                  cnspec policy gate on the built image
                                                  smoke test (kind)
                                                  verify P1 signature, build amd64+arm64
                                                  push, sign, SBOM + provenance
                                                  bump k8s/ to 1.2.3@sha256:...
```

Nothing is built from source here. The image contains the exact binary from the GitHub release, and the build only runs after that binary's signature checks out against the app repo's release workflow.

## Deploy

```
kubectl apply -f k8s/
kubectl -n hello-mondoo rollout status deployment/hello-mondoo
kubectl -n hello-mondoo port-forward svc/hello-mondoo 8080:80
curl localhost:8080
```

`k8s/10-deployment.yaml` always points at the latest stable release by digest, so this deploys exactly the image that was smoke-tested and signed.

To run on another port, change `HTTP_PORT` and `containerPort` in `k8s/10-deployment.yaml`. The Service and probes use the named port `http` and follow automatically. Outside Kubernetes:

```
docker run --rm -e HTTP_PORT=9090 -p 9090:9090 clickbg/hello-mondoo:latest
```

## The image

| | |
| --- | --- |
| Base | `gcr.io/distroless/static-debian13:nonroot`, pinned by digest |
| Binary | `/usr/local/bin/hello-mondoo` (entrypoint) |
| User | `65532:65532` |
| Port | `8080` (`EXPOSE`, `HTTP_PORT=8080`) |
| Platforms | `linux/amd64`, `linux/arm64` |

Tags per release:

| App release | Image tags |
| --- | --- |
| `v1.2.3` | `1.2.3`, `1.2`, `1`, `latest` |
| `v0.4.0` | `0.4.0`, `0.4`, `latest` (no `0`, 0.x has no compatibility promise) |
| `v1.3.0-rc.1` | `1.3.0-rc.1` only |

Verify the signature and look at the attestations:

```
cosign verify clickbg/hello-mondoo:0.1.0 \
  --certificate-identity "https://github.com/clickbg/pe-challenge-p2-container/.github/workflows/publish.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect clickbg/hello-mondoo:0.1.0 --format '{{json .SBOM}}'
docker buildx imagetools inspect clickbg/hello-mondoo:0.1.0 --format '{{json .Provenance}}'
```

## Workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | PR, push to main | hadolint, shellcheck, kubeconform (strict, k8s 1.37), cnspec on the Dockerfile and `k8s/` (SARIF to code scanning), then the smoke test for the tag currently in the manifest. |
| `smoke-test.yml` | called by CI and Publish | Fetches and verifies a release, builds the image, runs cnspec against it, loads it into kind, applies `k8s/` with only the image swapped, waits for rollout and checks the response. |
| `publish.yml` | `repository_dispatch: app-released`, or manual with a tag | Smoke test, then build, push and sign, then bump the manifest. |

Rebuild any release by hand:

```
gh workflow run publish.yml -R clickbg/pe-challenge-p2-container -f tag=v0.1.0
```

## Local build

```
make run                    # fetch + verify, build for this machine, run on :8080
make run PORT=9090          # different port
make build TAG=v0.1.0-rc.1  # another release
make build ARCH=amd64       # force an architecture
make scan                   # cnspec: Dockerfile, built image and k8s/, same gate as CI
make clean
```

`TAG` defaults to the release the manifest deploys. `ARCH` defaults to the Docker engine's architecture, so Apple Silicon builds arm64 and x86 Linux builds amd64, and the image always runs natively. Releases are downloaded and verified once per tag.

Needs Docker with buildx, `curl`, `cosign`, and `sha256sum` or `shasum`. `make scan` also needs cnspec 14.4.0 with the `os@14.18.1` and `k8s@14.1.2` providers (see `.github/actions/setup-cnspec`).

## Policy checks with cnspec

The policy is `policies/hello-mondoo.mql.yaml`: one bundle, three groups, each scoped to one kind of asset so the same file serves every scan.

| Group | Scanned as | Checks |
| --- | --- | --- |
| Dockerfile | `cnspec scan docker file Dockerfile` | **COPY to `/usr/local/bin/hello-mondoo` and ENTRYPOINT runs it**, **EXPOSE 8080/tcp**, non-root USER, base pinned by digest |
| Built image | `cnspec scan docker container <id>` | **binary exists, is a file, executable by others**, **image config exposes 8080/tcp**, exec-form entrypoint, non-root user, binary not writable |
| Manifests | `cnspec scan k8s k8s/ --discover clusters` | `HTTP_PORT`, `containerPort` and port name agree, restricted Pod Security Standard, namespace enforces restricted, image pinned by digest |

Bold checks are the two the brief requires (impact 100). The rest are hardening (impact 70). Both block.

### Where it runs, and why there

- **On the built image, inside the smoke test, before anything is pushed.** This is the check that matters. It looks at the artifact, not the recipe, so it catches things a Dockerfile scan can't: a `.dockerignore` that drops the binary, a wrong `--chmod`, an EXPOSE lost in a refactor. The smoke test runs in CI on every change and in Publish before the push, so an image that fails the policy never reaches Docker Hub.
- **On the Dockerfile and `k8s/`, statically, in CI.** Seconds, no build, and findings show up as code scanning annotations on the PR. It also catches drift between the manifest and the image, for example someone changing `containerPort` but not `HTTP_PORT`.
- **Not in the app repo.** It produces binaries, not containers, and its binary is already covered by tests and the smoke test. Adding cnspec there would be for show.
- **Not after the push.** By then the image is public and the signature is on it.

### What happens on failure

The job fails and the pipeline stops. In Publish that means no push, no signature, no manifest bump. Findings are in the job log, as code scanning alerts for the Dockerfile and manifests, and as a SARIF artifact for the image scan (30 days), so every release keeps a record of what was checked before it shipped.

`scripts/cnspec-scan.sh` is the gate, used by CI, the smoke test and `make scan`. Two cnspec defaults made it necessary:

- `--risk-threshold` defaults to 101, so `cnspec scan` never fails a pipeline unless told to.
- A check that errors does not lower the score. In a test run, three checks errored and the asset still scored `LOW (0)`.

So the script also reads a JUnit report and fails on any failed, errored or skipped check, and on zero checks. The last one matters: a group filter that matches nothing would otherwise pass with nothing checked.

### What I found getting the image checks to work

The required checks need both the image's filesystem (the binary) and its config (exposed ports), and cnspec sees different things depending on how the image is scanned:

| Scan target | Filesystem | Image config |
| --- | --- | --- |
| `docker image` | yes | no, scanned as an exported tarball, which won't query the Docker engine |
| running container | no, file checks need `stat` and distroless has no shell | yes |
| created, never started container | yes, read from a `docker export` snapshot | yes |

So the smoke test runs `docker create`, scans the container and removes it. Nothing executes during the scan.

GitHub code scanning also rejected cnspec's SARIF at first: cnspec writes a result for every check, passing ones included, and checks that fail because something is missing have no source line to point at, only a logical location. The scan script drops passing results and anchors the rest to the scanned file before upload.

### Versions

cnspec 14.4.0 is pinned with a checksum, and the providers separately (`os@14.18.1`, `k8s@14.1.2`), since provider versions don't follow cnspec's. 14.4.0 was a day old when I pinned it, which breaks the 7 day cooldown used everywhere else. `docker.image.exposedPorts` first appears in `os` 14.18.1, so there was no older release that could do the image config check. Mondoo's own `docker-image` action wasn't used: it runs a floating `mondoo/cnspec:13` image and can't load a custom policy.

### Where else cnspec could help

- **The live cluster.** The smoke test already has a kind cluster with the app running. `cnspec scan k8s` against it would check what the API server actually admitted, not just what the YAML says.
- **Signed images only.** A cnspec check that every container image in the namespace is pinned by digest, alongside a Sigstore admission policy that only allows images signed by `publish.yml`.
- **The repos themselves.** `cnspec scan github repo` can check branch protection, tag rules, required reviews and Actions permissions on both repos. Those settings are part of the supply chain but live outside the code, which is why the READMEs have to list them by hand.
- **Published images over time.** A weekly scheduled scan of `latest` on Docker Hub, reported to Mondoo Platform with a service account, would pick up new CVEs in the base image between releases.

## Setup outside the code

Cross-repo trigger (in the app repo):

- GitHub App `clickbg-release-dispatch` with Contents read/write only, installed on this repo only.
- `DISPATCH_APP_CLIENT_ID` variable and `DISPATCH_APP_PRIVATE_KEY` secret in the app repo.

This repo:

- Environment `dockerhub`, limited to `main`, holding `DOCKERHUB_USERNAME` (variable) and `DOCKERHUB_TOKEN` (secret).
- The Docker Hub token is a personal access token with Read & Write (no Delete) and a 90 day expiry. It needs rotating before it runs out.

## Decisions and tradeoffs

**Docker Hub over GHCR.** Docker Hub is the default registry everywhere, so the image can be pulled from any cluster or laptop without extra config. The cost is a long-lived token stored as a secret. GHCR would have needed no stored secret at all, since `GITHUB_TOKEN` can push to it. I limited the damage instead: Read & Write scope only, 90 day expiry, and the token lives in an environment that only jobs on `main` can read, so PR runs never see it. Docker Hub also lists new OCI referrers with a short delay, which made the first signature check fail right after signing. The verify step now retries with backoff.

**Package the released binary, don't rebuild it.** The deploy repo has no Go toolchain and never touches source. It downloads the release assets and runs `cosign verify-blob` with the app repo's release workflow and tag as the expected identity, then checks the hashes. A binary signed by any other workflow, fork or tag is rejected. This makes the image contents traceable to one specific release, and the trust between the two repos is checked with cryptography instead of assumed.

**GitHub App instead of a PAT for the dispatch.** A PAT belongs to a person and lives for months. The App's key only mints installation tokens that last an hour, cover only this repo, and are narrowed further at mint time to `contents: write`. Nothing breaks if the person who set it up leaves.

**The dispatch payload is untrusted.** Anyone holding a token that can dispatch to this repo controls `client_payload`. The tag is passed through an env var (never interpolated into shell), checked against a semver regex in `publish.yml` and again in `fetch-release.sh`, and in the end a tag that doesn't match a signed release fails the cosign check anyway.

**Smoke test before push.** Publish deploys the new release to kind with the real manifests before pushing anything. An image that can't start under the restricted Pod Security policy, or doesn't answer on its port, never reaches Docker Hub. CI runs the same reusable workflow against the tag in the manifest, so it tests exactly what `kubectl apply` would deploy.

**Manifest pinned by digest and bumped by the pipeline.** Tags can be moved, digests can't, so `kubectl apply` is reproducible. The bump only happens for stable releases, so release candidates get an image but never become the default deployment. It never goes backwards: rebuilding an old tag by hand refreshes the image but leaves the manifest alone. The bot pushes straight to `main`. With branch protection, which a production repo would have, it would open a PR to be merged after checks pass instead. Commits pushed with `GITHUB_TOKEN` don't start other workflows, so CI doesn't run on the bump commit. That's acceptable because the smoke test already ran on that tag inside the same publish run.

**One publish at a time.** All publish runs share one concurrency group and never cancel each other, so two releases close together can't race on the manifest. The push step also rebases and retries if `main` moved.

**Signing and attestations.** The multi-arch index is signed keyless with cosign under this repo's publish workflow identity. buildx attaches an SBOM and SLSA provenance (`mode=max`) per platform. One signature on the index digest covers the image as clusters pull it, by tag or by that digest.

**Distroless static, nonroot.** No shell, no package manager, CA certs and tzdata included, UID 65532. The binary is static, so nothing else is needed. The Dockerfile has no `RUN` steps, so building arm64 on an amd64 runner needs no QEMU, it's just a file copy.

**Plain manifests.** The brief asks for something a simple `kubectl` command can deploy, and three short YAML files do that. Files are numbered because `kubectl apply -f dir/` goes alphabetically and the Namespace has to exist first. Helm or Kustomize would earn their place once there are environments to vary between.

**Kubernetes hardening.** The namespace enforces the `restricted` Pod Security Standard. The pod runs as non-root with a read-only root filesystem, all capabilities dropped, no privilege escalation, RuntimeDefault seccomp and no service account token. Rolling updates use `maxUnavailable: 0`. There's a memory limit but no CPU limit, because CPU limits throttle the pod even when the node has spare capacity, while a memory limit is what protects the node.

**Pinning and updates.** Actions are pinned to commit SHAs, the base image and kind node image by digest, and the kubeconform download by SHA256. Dependabot updates the base image digest and the actions weekly with a 7 day cooldown. It does not track the kind node image or the kubeconform version, which are bumped by hand.

## Not done, and what I'd add next

- PodDisruptionBudget, NetworkPolicy and an HPA. Left out to keep the manifests minimal.
- The cnspec ideas above, starting with the live cluster scan, since the cluster already exists in the smoke test.
- Enforcing the image signature in the cluster with an admission controller (Sigstore policy-controller or Kyverno), so only images signed by `publish.yml` can run.
- A PR-based manifest bump once `main` is protected.

## License

BSD 2-Clause, see [LICENSE](LICENSE).
