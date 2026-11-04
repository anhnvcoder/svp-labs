# Static check of the Markdown of this repository. `make help` lists the targets. Docker runs with DOCKER_DEFAULT_PLATFORM
# unset: the shell of the dev machine sets it to linux/amd64 for another project, which would run the images under emulation.

.DEFAULT_GOAL := help

.PHONY: help docs-check

help: ## List the targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

# Same pins and same recipe as the code repository's Makefile (svp-backend): markdownlint-cli2 with .markdownlint.yaml
# (style), then lychee --offline --include-fragments (relative links and heading anchors; links to other sites are not
# followed: the network is not stable and a check that depends on it fails for reasons outside the change), both from
# their official images pinned by digest, without network, the repository mounted read-only at /repo. DOCS narrows the
# files (paths or globs, relative to the repository); the default is every Markdown file git tracks plus the new ones it
# does not track yet, except drills/svp-backend/ and drills/svp-frontend/: those are verbatim copies of files of other
# repositories, kept as they were when the lab was built, so they follow the style of their origin, not this one.
# Both tools always run; the exit code is not 0 when either reports a problem.
# renovate: datasource=docker depName=davidanson/markdownlint-cli2
MARKDOWNLINT_IMAGE := davidanson/markdownlint-cli2:v0.24.0@sha256:70ead7c0352d22d04bbe612cd96b54ec591538d8f4626cafe391bb2ecf3639ca
# renovate: datasource=docker depName=lycheeverse/lychee
LYCHEE_IMAGE := lycheeverse/lychee:0.24.2@sha256:e2d19e57cf6ab037026f20b8e449a1f30d9d7f81eef4194763aab2eab20bd28d
# set -f keeps the globs of DOCS whole: the tools expand them (with **), sh does not and would drop the files at the top.
DOCS ?=
docs-check: ## markdownlint-cli2 + lychee --offline on the Markdown (DOCS='<files or globs>' narrows; pinned images, no network)
	@if [ -n '$(DOCS)' ]; then set -f; set -- $(DOCS); set +f; \
	else set --; for f in $$(git ls-files --cached --others --exclude-standard -- '*.md' ':!:drills/svp-backend/' ':!:drills/svp-frontend/'); do [ -f "$$f" ] && set -- "$$@" "$$f"; done; fi; \
	rc=0; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/repo:ro" --workdir /repo \
		$(MARKDOWNLINT_IMAGE) "$$@" || rc=1; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/repo:ro" --workdir /repo \
		$(LYCHEE_IMAGE) --offline --include-fragments "$$@" || rc=1; \
	exit $$rc
