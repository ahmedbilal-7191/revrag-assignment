# SECURITY AUDIT — DevSecOps Assignment

## Overview
This document explains all security and quality issues identified in the provided Dockerfile and CI/CD pipeline, the risks they introduce, and the fixes applied.

---

# Task 1 — Dockerfile Audit

## 1. Using `node:latest`
**Problem:** The problem with latest is that it's a moving target. Today it might point to Node 20, tomorrow it could pull Node 22 with breaking changes or new vulnerabilities without you even knowing. It also makes rollbacks harder because you can't be sure what exact image was used in a previous deployment.  
**Fix:** I fixed this by pinning to a specific version like node:20.19.0-alpine3.21 so every build is predictable and traceable.

---

## 2. `COPY . .`
**Problem:** Copies secrets, git history, and unnecessary files into the image. Two problems here: first, sensitive files can end up baked into the image. Second, Docker builds in layers and caches them — if you copy everything upfront, any file change breaks the cache and forces a full reinstall 
**Fix:** I fixed this by adding a `.dockerignore` to exclude things like .env, .git, node_modules etc, and copying package.json first separately before the rest of the source so the dependency install layer gets cached properly..

---

## 3. Hardcoded Secrets in ENV
**Problem:** `ENV SECRET_KEY=s3cr3t_k3y_abc123` is a big mistake. The secret gets baked into the image layer permanently. Anyone who runs `docker history <image>` can see every instruction used to build it including these values. If the image is ever pushed to a registry and someone pulls it, the secrets are just sitting there. 
**Fix:** The fix is to never put secrets in the Dockerfile at all — pass them at runtime using docker run -e or using `.env` file or better, use a secrets manager.

---

## 4. Installing curl/vim/wget
**Problem:** These tools are not needed to run a Node.js app. Keeping them in the image increases attack surface — if someone compromises the container, they now have wget and curl to download more tools, exfiltrate data, etc.(another issue might be it's placement in the docker file. if the conatiner is used for debugging then the issue will be with the placement since its kept after `Copy . .` then it will break the caching.)
**Fix:** Vim is a debugging tool, it has no place in a production image. I removed this line entirely.(if tools are necessary then its better to keep it after `Workdir` and also removing the apt/list/* after installing the packages it will help in reducing the image layer size)

---

## 6. Exposing Port 22
**Problem:** Port 22 is SSH. There's no reason a Node.js web server container should be listening on SSH. Exposing it opens the door for brute force attacks and makes lateral movement easier if the container is compromised.
**Fix:** Removed it, only port 3000 should be exposed.

---

Additional issues I found (not marked):
1.No non-root user — the container runs as root by default which means if the app is exploited the attacker has root inside the container. I added USER node since the official node image already has this user built in.

2.Separate build and runtime stages.Only runtime artifacts are copied into the final image.

---

# Task 2 — CI/CD Pipeline Audit

## Hardcoded Secrets in workflow
**Risk:** `DOCKER_HUB_PASSWORD` and `AWS_SECRET_ACCESS_KEY` are sitting in plain text in the workflow file. Anyone with repo access can read them. If the repo is public it's even worse — these are visible to the entire internet, get indexed by search engines, and live in git history forever even after deletion.
**Fix:** These should be stored in GitHub Actions Secrets and referenced as `${{ secrets.DOCKER_HUB_PASSWORD }}` — they get masked in logs and are never stored in the file itself.

---

## Unpinned / Older Actions
**Risk:** @v3 is a mutable tag. The maintainer can push any code to that tag and your pipeline picks it up automatically on the next run without any review.
**Fix:** The fix is pinning to a full commit SHA like actions/checkout@1131231.... which is immutable — that exact SHA will always point to that exact code, no surprises.

---

## docker push myapp:latest with no versioning
**Risk:** Pushing only with the latest tag means you can never trace which exact image is running in production. If something breaks you can't roll back to a specific version because every push overwrites `latest`  
**Fix:** I fixed this by tagging with the Git commit SHA so each push produces a traceable image like myapp:a3f2c91 .

---

## SSH Host Key Checking Disabled
**Risk:** This disables host key verification which opens the door to a man-in-the-middle attack. When you SSH without checking the host key, you're essentially saying "I'll connect to whoever answers on this IP" — an attacker who intercepts that connection could receive your deployment commands instead of your actual server.
**Fix:** Add known hosts verification.(best practise is to use OIDC when deploying on cloud or instead of CI pushing to the server, the server itself watches for new image tags and pulls them. Tools like: **Watchtower** or **ArgoCD / FluxCD**)

---

## Using Privileged Container
**Risk:** This gives the container near-root access to the host machine — it can read host devices, bypass cgroup restrictions, load kernel modules. If the app is compromised, the attacker doesn't just own the container, they own the host.
**Fix:** Remove --privileged and grant only required capabilities.

---

# Task 3 — Vulnerability Scan Placement

I placed the Trivy scan step **after the image is built but before it is pushed to the registry or deployed**. The reason placement matters here is the shift-left principle — catch problems as early as possible in the pipeline so a vulnerable image never makes it to production or even the registry. If the scan fails on CRITICAL CVEs, the pipeline stops there, nothing gets pushed, nothing gets deployed.
---

# Decision Questions

## Q1 — Handling Critical CVEs
First, I would understand the real impact instead of blindly upgrading.

Steps I would take:
- Check CVE details and exploit conditions
- Verify whether the vulnerable OpenSSL functionality is actually used
- Determine exposure level and exploitability

Since upgrading breaks native modules and cannot be fixed within 24 hours, a full fix is not immediately possible.

My approach:

1.Temporarily block deployment initially
2.Perform risk evaluation
3.If exploitability is low, allow deployment under a documented security exception
4.Apply mitigations immediately

Mitigations include:
- run container as non-root
- remove unnecessary packages
- restrict network access
- avoid privileged mode
- enable logging and monitoring

Then:
document accepted risk and create a high-priority task assign owner for proper upgrade

The final goal remains upgrading the base image. The temporary decision is risk mitigation, not risk acceptance forever.
---

## Q2 — Why `--privileged` Is Unsafe
The risk is not about internet exposure. The risk is privilege escalation.A privileged container has almost the same power as root on the host.If any internal service is compromised, attackers can move laterally inside the network.

Internal systems are common attack paths because:
- phishing or credential leaks give internal access
- attackers move between services after initial breach

Attack chain example:
App vulnerability => container access => privileged container => host takeover

After host compromise, attackers can:

- access Docker daemon
- control other containers
- read mounted secrets
- persist inside infrastructure

Internal access does not equal trusted access. Security should assume breach and limit damage.The correct solution is granting only required capabilities instead of full privilege.

---

## Q3 — Git History & Secrets
No.Git keeps immutable history. Even after removing secrets:

- old commits still contain them
- forks and clones may have copies
- CI logs may store exposed values

Anyone can retrieve them using repository history.

Additional actions required

- Rewrite git history using tools like git filter-repo or BFG
- Force push cleaned history
- Invalidate old clones if possible
- Audit CI logs and artifacts
- Rotate credentials again after cleanup

Rotation alone fixes access but does not remove exposure evidence.

---

## Q4 — Pinning Actions vs Maintainability
Pinning actions to commit SHAs improves supply chain security but makes updates harder.

A practical balance:

Pin actions to commit SHA for production workflows
Use **`Dependabot`** or scheduled reviews to update SHAs periodically
Test updates in a separate branch before merging

This provides:
- deterministic security
- controlled updates
- manageable maintenance effort

Security and usability both remain practical.

Also always comment the human-readable version next to the SHA:
uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

---
