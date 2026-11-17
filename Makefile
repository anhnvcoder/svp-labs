# Static checks of this repository: the Markdown, and the Terraform, Go and shell scripts of the labs. `make help` lists
# the targets. No target reaches an AWS account: init runs with -backend=false, nothing calls apply or the AWS CLI, and
# the only plans are those of terraform test, against a mock AWS provider, in a container without network or credential.

# Every tool but Go runs from its official image pinned by digest, the same reference on a dev machine and in CI; Go
# runs on the host. Docker runs with DOCKER_DEFAULT_PLATFORM unset: the dev machine's shell sets it to linux/amd64 for
# another project, which would run these images under emulation.

# Parallel runs: a Terraform target with DIRS=<dir> writes below <dir> only the lock file of a module, test-guard writes
# into a directory of its own, and the plugin cache that every run shares only gains the versions it lacks, one writer
# at a time (CACHE_LOCK), so runs on different directories can go side by side.

# Same pins as the Makefile of svp-infra, whose recipes these Terraform targets copy.
# renovate: datasource=docker depName=hashicorp/terraform
TERRAFORM_IMAGE  := hashicorp/terraform:1.15.8@sha256:7ae513256f7ce67879e218ae8593d6fbe216ec9e123abe6c94e4e10704857963
# renovate: datasource=docker depName=ghcr.io/terraform-linters/tflint
TFLINT_IMAGE     := ghcr.io/terraform-linters/tflint:v0.65.0@sha256:2788f4d4fc663c0e953b011b01bf443fe5bfce7587ee916e588e6057b85d6359
# renovate: datasource=docker depName=ghcr.io/aquasecurity/trivy
TRIVY_IMAGE      := ghcr.io/aquasecurity/trivy:0.76.0@sha256:2416d1f74045b57274df1a340eee6b510cacd73c66a6ccb8da092b117eb7d222
# renovate: datasource=docker depName=koalaman/shellcheck
SHELLCHECK_IMAGE := koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d

# Platforms whose provider hashes `make lock` writes into the lock file of a root: the Mac that runs plan and apply,
# and the two Linux architectures of CI and of the images.
LOCK_PLATFORMS := darwin_arm64 linux_amd64 linux_arm64

# Directories to check, relative to this one; each stands for every directory below it that holds a *.tf file, go.mod
# or scripts/*.sh, and empty means the whole repository. A Terraform directory under a modules/ directory is a module:
# its lock file is not committed. Any other is a root: its committed lock file is used as it is (init
# -lockfile=readonly), so a provider change needs `make lock` first.
DIRS ?=

DOCKER := env -u DOCKER_DEFAULT_PLATFORM docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp
# HOME=/tmp: the container runs as the caller, who has no home directory in the image.
TF_RUN = $(DOCKER) -e CHECKPOINT_DISABLE=1 -e TF_IN_AUTOMATION=1 -v "$(CURDIR):/src" -w "/src/$$d"
TF = $(TF_RUN) $(TERRAFORM_IMAGE)
# init, validate and providers lock keep their working data in a temporary directory of the host, $$data, through
# TF_DATA_DIR: the .terraform/terraform.tfstate of a root the learner initialised would otherwise make
# `init -backend=false` read its backend.
TF_DATA = $(TF_RUN) -e TF_DATA_DIR=/tfdata -v "$$data:/tfdata" $(TF_CACHE) $(TERRAFORM_IMAGE)
# Starts each loop turn with an empty $$data; the trap removes the last one however the recipe ends.
NEW_DATA = rm -rf "$$data"; data=$$(mktemp -d) || exit 1

# One copy of each plugin version for every directory, gitignored and kept until removed (rm -rf .plugin-cache, plus the
# module lock files **/modules/**/.terraform.lock.hcl that recorded its hashes); the AWS provider unpacks to hundreds of
# MB. init links $$data/providers to /plugin-cache, so every container that runs Terraform after it mounts the cache.
PLUGIN_CACHE := .plugin-cache
# With no lock file entry (a module's lock file is not committed), init would download again and unpack over the cached
# copy another run may be executing; MAY_BREAK links that copy instead. The hashes of a root's lock file are still
# checked, and make lock still writes them for every LOCK_PLATFORMS.
TF_CACHE = -e TF_PLUGIN_CACHE_DIR=/plugin-cache -e TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1 \
	-v "$(CURDIR)/$(PLUGIN_CACHE)/terraform:/plugin-cache"
# Neither Terraform nor tflint guards its cache against a second writer: an init waits for the lock directory (mkdir
# is atomic and needs no flock, which macOS lacks). The recipe's EXIT trap runs CACHE_UNLOCKED when the init fails.
CACHE_LOCK = mkdir -p "$(PLUGIN_CACHE)/terraform" "$(PLUGIN_CACHE)/tflint" || exit 1; n=0; \
	until mkdir "$(PLUGIN_CACHE)/lock" 2>/dev/null; do \
	  n=$$((n + 1)); [ $$n -lt 600 ] || { echo "FAIL: $(PLUGIN_CACHE)/lock held for 10 minutes; remove it if no make runs" >&2; exit 1; }; \
	  sleep 1; \
	done; locked=1
CACHE_UNLOCK = rmdir "$(PLUGIN_CACHE)/lock"; locked=
CACHE_UNLOCKED = [ -z "$$locked" ] || rmdir "$(PLUGIN_CACHE)/lock"

# Sets the positional parameters to the DIRS entries (default: .), or stops at the first one outside this repository
# or that is not a directory.
GIVEN_DIRS = set --; \
	for d in $(or $(DIRS),.); do \
	  d=$${d%/}; \
	  case "$$d" in (/*|..|../*|*/..|*/../*) echo "DIRS: $$d is outside this repository; give a path relative to it" >&2; exit 1;; esac; \
	  [ -d "$$d" ] || { echo "DIRS: $$d is not a directory" >&2; exit 1; }; \
	  set -- "$$@" "$$d"; \
	done

# Prints the Terraform directories to check, one per line, or stops at the first DIRS entry with no *.tf file below
# it. .test-guard/ holds the throwaway module of test-guard, only ever checked through its own DIRS.
LIST_DIRS = $(GIVEN_DIRS); \
	for d in "$$@"; do \
	  found=$$(find "$$d" -name .git -prune -o -name .terraform -prune -o -name .test-guard -prune -o -name '*.tf' -print \
	    | sed 's|/[^/]*$$||; s|^\./||' | sort -u); \
	  [ -n "$$found" ] || [ -z '$(DIRS)' ] || { echo "DIRS: $$d holds no *.tf file below it" >&2; exit 1; }; \
	  [ -z "$$found" ] || echo "$$found"; \
	done

# A directory under modules/ is a module; anything else is a root.
IS_MODULE = case "/$$d/" in (*/modules/*) true;; (*) false;; esac

# drills/ holds copies of other repositories, checked where they come from.
GO_MODULES = $(GIVEN_DIRS); \
	find "$$@" -name .git -prune -o -name .terraform -prune -o -path ./drills -prune -o -name go.mod -print \
	  | sed 's|/go\.mod$$||; s|^\./||' | sort -u

SH_FILES = $(GIVEN_DIRS); \
	find "$$@" -name .git -prune -o -name .terraform -prune -o -path '*/scripts/*.sh' -type f -print | sed 's|^\./||' | sort

# The self-tests of the scripts; drills/ holds copies of other repositories, checked where they come from.
TEST_SH_FILES = $(GIVEN_DIRS); \
	find "$$@" -name .git -prune -o -name .terraform -prune -o -name drills -prune -o -path '*/scripts/*-test.sh' -type f -print \
	  | sed 's|^\./||' | sort

# GOTOOLCHAIN=local: a go line newer than the host's Go fails instead of downloading another toolchain, so the only
# downloads are the modules of go.mod.
GO := env GOTOOLCHAIN=local go

.DEFAULT_GOAL := help

.PHONY: help check tf-check fmt-check fmt validate tflint trivy test test-guard lock go-test lambda-build shellcheck script-test docs-check

help: ## List the targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

check: docs-check test-guard tf-check go-test shellcheck script-test ## Every static check of the repository

tf-check: fmt-check validate tflint trivy test ## Every Terraform check on DIRS='<dir> ...' (default: the whole repository)

fmt-check: ## terraform fmt -check on the checked directories
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "fmt-check: no Terraform directory"; exit 0; }; \
	for d in $$dirs; do \
	  echo "fmt-check $$d"; \
	  $(TF) fmt -check -diff -recursive || { echo "FAIL: terraform fmt $$d (run make fmt DIRS=$$d)" >&2; exit 1; }; \
	done

fmt: ## terraform fmt, rewriting the files of the checked directories
	@dirs=$$($(LIST_DIRS)) || exit 1; for d in $$dirs; do $(TF) fmt -recursive || exit 1; done

validate: ## terraform init -backend=false, then terraform validate, in each checked directory
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "validate: no Terraform directory"; exit 0; }; \
	data=; locked=; trap 'rm -rf "$$data"; $(CACHE_UNLOCKED)' EXIT; \
	for d in $$dirs; do \
	  echo "validate $$d"; \
	  $(NEW_DATA); \
	  if $(IS_MODULE); then lock=; \
	  else \
	    [ -f "$$d/.terraform.lock.hcl" ] || { echo "FAIL: $$d is a root without .terraform.lock.hcl (run make lock DIRS=$$d)" >&2; exit 1; }; \
	    lock=-lockfile=readonly; \
	  fi; \
	  $(CACHE_LOCK); \
	  $(TF_DATA) init -backend=false -input=false -no-color $$lock >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(CACHE_UNLOCK); \
	  $(TF_DATA) validate -no-color || { echo "FAIL: terraform validate $$d" >&2; exit 1; }; \
	done

# The AWS ruleset is downloaded from GitHub into the plugin cache; CI passes its token in GITHUB_TOKEN against
# the anonymous rate limit, and only this container gets it. Local modules are inspected where they are called.
tflint: ## tflint --init, then tflint, in each checked directory (.tflint.hcl)
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "tflint: no Terraform directory"; exit 0; }; \
	locked=; trap '$(CACHE_UNLOCKED)' EXIT; \
	for d in $$dirs; do \
	  echo "tflint $$d"; \
	  set -- $(DOCKER) -e GITHUB_TOKEN -e "TFLINT_PLUGIN_DIR=/src/$(PLUGIN_CACHE)/tflint" -v "$(CURDIR):/src" -w "/src/$$d" \
	    $(TFLINT_IMAGE) --config=/src/.tflint.hcl; \
	  $(CACHE_LOCK); \
	  "$$@" --init >/dev/null || { echo "FAIL: tflint --init $$d" >&2; exit 1; }; \
	  $(CACHE_UNLOCK); \
	  "$$@" --format=compact || { echo "FAIL: tflint $$d" >&2; exit 1; }; \
	done

# HIGH and CRITICAL findings fail; a deliberate exception is a #trivy:ignore:<id> line right above the resource, with
# its reason, never an ignore file: --ignorefile /dev/null stops trivy reading a .trivyignore at the repository root.
# --skip-check-update keeps the checks built into the pinned image: the bundle trivy
# would fetch sits behind a moving tag. With no registry module to download, the scan runs without network.
trivy: ## trivy config on each checked directory (HIGH and CRITICAL fail; no network)
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "trivy: no Terraform directory"; exit 0; }; \
	for d in $$dirs; do \
	  echo "trivy $$d"; \
	  $(DOCKER) --network none -v "$(CURDIR):/src:ro" -w /src $(TRIVY_IMAGE) config --quiet --skip-check-update --ignorefile /dev/null --cache-dir /tmp/trivy \
	    --severity HIGH,CRITICAL --exit-code 1 "$$d" || { echo "FAIL: trivy $$d" >&2; exit 1; }; \
	done

# terraform test of each module (tests/*.tftest.hcl). The recipe holds the tests to three rules itself instead of
# trusting whoever wrote them: terraform runs from TERRAFORM_IMAGE, pinned by digest, with --network none (only init,
# in a container of its own, downloads providers); no credential goes in; TEST_GUARD accepts a test file only in a
# fixed layout.

# No credential: env(1) drops every AWS_* variable of the caller before docker starts, no -e passes one, HOME is /tmp
# of the container, and only the module directory and the provider cache are mounted (both read-only for the test),
# never ~/.aws or the repository root. A module directory holding .envrc or backend.hcl is refused.

# TEST_GUARD refuses anything outside the layout, naming the file and the line, rather than looking for known ways to
# break the rule (a run without command applies; a mock under an alias leaves the real provider as the default).
# Block comments and heredocs are refused so that every line is read here as HCL reads it.
NO_AWS_ENV = env $$(env | sed -n 's/^\(AWS_[A-Za-z0-9_]*\)=.*/-u \1/p') -u DOCKER_DEFAULT_PLATFORM
# Go tests run on the host: drop AWS_* and point the SDK at empty config so no test can find a real profile.
GO_NO_AWS = $(NO_AWS_ENV) AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null $(GO)
TEST_RUN = $(NO_AWS_ENV) docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp -e CHECKPOINT_DISABLE=1 \
	-e TF_IN_AUTOMATION=1 -e TF_DATA_DIR=/tfdata -v "$$data:/tfdata"
# Checks the module directory $$d and exits the recipe, naming the file (and the line), at the first one it refuses.
# The awk program reads each line with its leading and trailing blanks removed; run holds the line of the run block
# whose command line is still due.
TEST_GUARD = \
	links=$$(find "$$d" -name .terraform -prune -o -type l -print); \
	[ -z "$$links" ] || { echo "FAIL: make test refuses the symbolic links $$links (terraform test would read a file these checks never see)" >&2; exit 1; }; \
	files=$$(find "$$d" "$$d/tests" -maxdepth 1 -name '*.tftest.hcl' 2>/dev/null | sort -u); \
	[ -n "$$files" ] || { echo "FAIL: $$d/tests holds no *.tftest.hcl (every module tests its validation rules)" >&2; exit 1; }; \
	bad=$$(find "$$d" -name .terraform -prune -o \( -name '*.tftest.json' -o -name .envrc -o -name backend.hcl \) -print); \
	[ -z "$$bad" ] || { echo "FAIL: make test refuses $$bad (only *.tftest.hcl it can check; no credential file in a tested module)" >&2; exit 1; }; \
	for f in $$files; do \
	  awk -v f="$$f" ' \
	    { line = $$0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$$/, "", line) } \
	    /alias/ { print f ":" NR ": alias (the default aws provider must be the mock)"; bad = 1 } \
	    /\*\// { print f ":" NR ": block comment"; bad = 1 } \
	    /<</ { print f ":" NR ": heredoc"; bad = 1 } \
	    run && line != "" { if (line != "command = plan") { print f ":" NR ": the run block of line " run " does not start with command = plan"; bad = 1 }; run = 0; next } \
	    line ~ /^run/ { if (line ~ /^run "[A-Za-z0-9_-]+" [{]$$/) run = NR; else { print f ":" NR ": not a run \"<name>\" { line"; bad = 1 }; next } \
	    line ~ /^mock_provider/ { if (line == "mock_provider \"aws\" {" || line == "mock_provider \"aws\" {}") mocks++; else { print f ":" NR ": not a mock_provider \"aws\" { line"; bad = 1 }; next } \
	    line ~ /^(provider|override_|module|command|\/\*)/ { print f ":" NR ": provider, override_*, module, block comment or command outside the first line of a run"; bad = 1 } \
	    END { \
	      if (run) { print f ":" run ": run block without command = plan"; bad = 1 } \
	      if (mocks != 1) { print f ": " (mocks + 0) " mock_provider \"aws\" lines, exactly one allowed"; bad = 1 } \
	      exit bad \
	    }' "$$f" >&2 || { echo "FAIL: make test refuses $$f" >&2; exit 1; }; \
	done

test: ## terraform test of each checked module: mock AWS provider, plan only, no network, no credential
	@dirs=$$($(LIST_DIRS)) || exit 1; [ -n "$$dirs" ] || { echo "test: no Terraform directory"; exit 0; }; \
	data=; locked=; trap 'rm -rf "$$data"; $(CACHE_UNLOCKED)' EXIT; \
	for d in $$dirs; do \
	  $(IS_MODULE) || continue; \
	  echo "test $$d"; \
	  $(TEST_GUARD); \
	  $(NEW_DATA); \
	  $(CACHE_LOCK); \
	  $(TEST_RUN) $(TF_CACHE) -v "$(CURDIR)/$$d:/src" -w /src $(TERRAFORM_IMAGE) init -backend=false -input=false -no-color >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(CACHE_UNLOCK); \
	  $(TEST_RUN) --network none -v "$(CURDIR)/$(PLUGIN_CACHE)/terraform:/plugin-cache:ro" -v "$(CURDIR)/$$d:/src:ro" -w /src $(TERRAFORM_IMAGE) test -no-color || { echo "FAIL: terraform test $$d" >&2; exit 1; }; \
	done

# The guard cases run on modules in a temporary directory; the run of make test with a fake docker needs a module of
# this repository (DIRS stays inside it), so it gets one of its own under .test-guard/modules/, removed on exit.
# Its /tfdata mount must be gone once it ends: the recipe removes only the temporary data directory it made.
test-guard: ## Self-test of the rules of make test, with a fake docker (no container, network or credential)
	@echo "test-guard"; \
	mod=; tmp=$$(mktemp -d) || exit 1; \
	trap 'rm -rf "$$tmp" $${mod:+"$$mod"}; rmdir .test-guard/modules .test-guard 2>/dev/null; true' EXIT; \
	fail() { echo "FAIL: test-guard: $$*" >&2; exit 1; }; \
	good='mock_provider "aws" {}\nrun "a" {\n  command = plan\n}\n'; \
	full='# c\nmock_provider "aws" {\n  mock_data "aws_region" {\n    defaults = {\n      region = "x"\n    }\n  }\n}\n\nrun "a-1_b" {\n\n  command = plan\n\n  variables {\n    u = ["https://svp.example/*"]\n  }\n\n  expect_failures = [var.u]\n}\n'; \
	newmod() { rm -rf "$$tmp/m" "$$tmp/t"; mkdir -p "$$tmp/m/tests"; d="$$tmp/m"; }; \
	refuses() { \
	  out=$$( ( $(TEST_GUARD) ) 2>&1 ) && fail "$$1: accepted"; \
	  case "$$out" in (*"$$d/$$2"*) ;; (*) fail "$$1: the refusal does not name $$d/$$2: $$out";; esac; \
	}; \
	refused() { \
	  newmod; \
	  if [ -n "$$2" ]; then printf "$$2" > "$$d/tests/$$3"; fi; \
	  if [ -n "$$4" ]; then : > "$$d/$$4"; fi; \
	  refuses "$$1" "$${5:-}"; \
	}; \
	refused "no test file" "" "" ""; \
	refused "no mock_provider" 'run "a" {\n  command = plan\n}\n' a.tftest.hcl ""; \
	refused "two mock_provider" 'mock_provider "aws" {}\nmock_provider "aws" {}\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl ""; \
	refused "run without command" 'mock_provider "aws" {}\nrun "a" {}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "run without command, on several lines" 'mock_provider "aws" {}\nrun "a" {\n  variables {\n    x = 1\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:3:; \
	refused "command after other lines" 'mock_provider "aws" {}\nrun "a" {\n  variables {\n    x = 1\n  }\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:3:; \
	refused "command = apply" 'mock_provider "aws" {}\nrun "a" {\n  command = apply\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:3:; \
	refused "one-line run" 'mock_provider "aws" {}\nrun "a" { command = plan }\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "run label without quotes" 'mock_provider "aws" {}\nrun implicit_apply {}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "run x{" 'mock_provider "aws" {}\nrun x{\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "run  \"a\"{command=apply}" 'mock_provider "aws" {}\nrun  "a"{command=apply}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "provider block" 'mock_provider "aws" {}\nprovider "aws" {}\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "providers of a run" 'mock_provider "aws" {}\nrun "a" {\n  command = plan\n  providers = {\n    aws = aws\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:4:; \
	refused "module of a run" 'mock_provider "aws" {}\nrun "a" {\n  command = plan\n  module {\n    source = "../x"\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:4:; \
	refused "override_" 'mock_provider "aws" {}\noverride_data {\n  target = data.aws_region.this\n}\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "aliased mock" 'mock_provider "aws" {\n  alias = "x"\n}\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "one-line aliased mock" 'mock_provider "aws" { alias = "x" }\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:1:; \
	refused "block comment" 'mock_provider "aws" {}\n/*\nrun "x" {}\n*/\nrun "a" {\n  command = plan\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:2:; \
	refused "block comment closed on a comment line" 'run "a" {\n  command = plan\n  variables {\n    x = 1 /*\nmock_provider "aws" {}\n# */\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:6:; \
	refused "heredoc" 'run "a" {\n  command = plan\n  variables {\n    x = <<EOT\nmock_provider "aws" {\nEOT\n  }\n}\n' a.tftest.hcl "" tests/a.tftest.hcl:4:; \
	refused "tftest.json" "$$good" a.tftest.hcl tests/a.tftest.json tests/a.tftest.json; \
	refused ".envrc" "$$good" a.tftest.hcl .envrc; \
	refused "backend.hcl" "$$good" a.tftest.hcl backend.hcl; \
	newmod; printf "$$good" > "$$d/tests/a.tftest.hcl"; mkdir "$$d/fixtures"; printf 'run "x" {}\n' > "$$d/fixtures/u.hcl"; \
	ln -s ../fixtures/u.hcl "$$d/tests/b.tftest.hcl"; refuses "symbolic link to a test file" tests/b.tftest.hcl; \
	newmod; mkdir "$$tmp/t"; printf "$$good" > "$$tmp/t/a.tftest.hcl"; rmdir "$$d/tests"; ln -s ../t "$$d/tests"; \
	refuses "symbolic link to the tests directory" tests; \
	newmod; printf "$$good" > "$$d/tests/a.tftest.hcl"; ( $(TEST_GUARD) ) || fail "a valid test file was refused"; \
	newmod; printf "$$full" > "$$d/tests/a.tftest.hcl"; ( $(TEST_GUARD) ) || fail "a valid test file with comments, mock_data and blank lines was refused"; \
	mkdir -p .test-guard/modules && mod=$$(mktemp -d .test-guard/modules/guard.XXXXXX) || fail "cannot create the module under .test-guard/modules"; \
	mkdir "$$mod/tests"; printf 'terraform {}\n' > "$$mod/main.tf"; printf "$$good" > "$$mod/tests/a.tftest.hcl"; \
	mkdir "$$tmp/bin"; \
	printf '#!/bin/sh\n{ printf ARGS; for a in "$$@"; do printf " %%s" "$$a"; done; echo; env | sed -n "s/^AWS_/ENV AWS_/p"; } >> "$$FAKE_DOCKER_LOG"\n' > "$$tmp/bin/docker"; \
	chmod +x "$$tmp/bin/docker"; \
	[ "$$(PATH="$$tmp/bin:$$PATH" command -v docker)" = "$$tmp/bin/docker" ] || fail "the fake docker is not first on PATH; nothing was run"; \
	PATH="$$tmp/bin:$$PATH" FAKE_DOCKER_LOG="$$tmp/log" AWS_PROFILE=leak AWS_ACCESS_KEY_ID=leak AWS_SECRET_ACCESS_KEY=leak \
	  AWS_SESSION_TOKEN=leak $(MAKE) --no-print-directory test DIRS="$$mod" >/dev/null || fail "make test with the fake docker failed"; \
	[ "$$(grep -c '^ARGS run ' "$$tmp/log")" = 2 ] || fail "expected two docker runs (init, test): $$(cat "$$tmp/log")"; \
	! grep -q '^ENV ' "$$tmp/log" || fail "an AWS_* variable reached docker: $$(grep '^ENV ' "$$tmp/log")"; \
	! grep -E -q 'AWS_|/\.aws|\.envrc|backend\.hcl' "$$tmp/log" || fail "an AWS credential or env file reaches the container: $$(cat "$$tmp/log")"; \
	line=$$(grep ' test -no-color$$' "$$tmp/log") || fail "no terraform test run: $$(cat "$$tmp/log")"; \
	case "$$line" in (*" --network none "*) ;; (*) fail "terraform test runs with network: $$line";; esac; \
	mounts=$$(echo "$$line" | awk '{ for (i = 1; i <= NF; i++) \
	  if ($$i == "-v") print $$(++i); else if ($$i ~ /^(-v.|--volume|--mount)/) print $$i }'); \
	data=$$(echo "$$mounts" | sed -n 's|^\(/[^:]*\):/tfdata$$|\1|p'); \
	[ -n "$$data" ] && [ ! -e "$$data" ] && case "$$data" in (*/..*) false;; esac \
	  || fail "terraform test mounts at /tfdata what make test does not remove: $$line"; \
	mounts=$$(echo "$$mounts" | sed 's|^/[^:]*:/tfdata$$|DATA|' | sort | tr '\n' ' '); \
	want=$$(printf '%s\n' DATA "$(CURDIR)/$(PLUGIN_CACHE)/terraform:/plugin-cache:ro" "$(CURDIR)/$$mod:/src:ro" | sort | tr '\n' ' '); \
	[ "$$mounts" = "$$want" ] || fail "terraform test mounts more than its data directory, the module and the provider cache (read-only): $$line"; \
	case "$$line" in (*" $(TERRAFORM_IMAGE) "*) ;; (*) fail "terraform test does not run TERRAFORM_IMAGE: $$line";; esac; \
	case "$(TERRAFORM_IMAGE)" in (*@sha256:*) ;; (*) fail "TERRAFORM_IMAGE is not pinned by digest";; esac

lock: ## Write the lock file of each root below DIRS (default: every root) with hashes for LOCK_PLATFORMS
	@dirs=$$($(LIST_DIRS)) || exit 1; \
	data=; locked=; trap 'rm -rf "$$data"; $(CACHE_UNLOCKED)' EXIT; \
	for d in $$dirs; do \
	  if $(IS_MODULE); then echo "lock: $$d is a module, its lock file is not committed; skipped"; continue; fi; \
	  echo "lock $$d"; \
	  $(NEW_DATA); \
	  $(CACHE_LOCK); \
	  $(TF_DATA) init -backend=false -input=false -no-color >/dev/null || { echo "FAIL: terraform init $$d" >&2; exit 1; }; \
	  $(CACHE_UNLOCK); \
	  $(TF_DATA) providers lock -no-color $(addprefix -platform=,$(LOCK_PLATFORMS)) || { echo "FAIL: providers lock $$d" >&2; exit 1; }; \
	done

go-test: ## gofmt -l, go vet, go test -race in each Go module below DIRS (default: the repository but drills/; host Go)
	@mods=$$($(GO_MODULES)) || exit 1; [ -n "$$mods" ] || { echo "go-test: no Go module"; exit 0; }; \
	for m in $$mods; do \
	  echo "go-test $$m"; \
	  out=$$(cd "$$m" && gofmt -l .) || { echo "FAIL: gofmt $$m" >&2; exit 1; }; \
	  [ -z "$$out" ] || { echo "FAIL: gofmt $$m: not formatted: $$out (run gofmt -w)" >&2; exit 1; }; \
	  (cd "$$m" && $(GO_NO_AWS) vet ./...) || { echo "FAIL: go vet $$m" >&2; exit 1; }; \
	  (cd "$$m" && $(GO_NO_AWS) test -race ./...) || { echo "FAIL: go test $$m" >&2; exit 1; }; \
	done

# Each $(LAMBDA_SRC)/cmd/<name>/ becomes $(LAMBDA_OUT)/<name>/bootstrap for the provided.al2023 runtime on arm64;
# lambda.norpc drops the RPC mode that only the retired go1.x runtime used. Both paths can be set to try the recipe
# on another Go module.
LAMBDA_SRC ?= serverless-variant/functions
LAMBDA_OUT ?= serverless-variant/build
lambda-build: ## Build each Lambda function of serverless-variant/functions/cmd/ into serverless-variant/build/<name>/bootstrap
	@set -- $$(ls -d $(LAMBDA_SRC)/cmd/*/ 2>/dev/null); [ $$# -gt 0 ] || { echo "lambda-build: no Lambda function"; exit 0; }; \
	for c in "$$@"; do \
	  n=$$(basename "$$c"); \
	  echo "lambda-build $$n"; \
	  (cd $(LAMBDA_SRC) && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 $(GO) build -tags lambda.norpc -trimpath \
	    -o "$(CURDIR)/$(LAMBDA_OUT)/$$n/bootstrap" "./cmd/$$n") || { echo "FAIL: lambda-build $$n" >&2; exit 1; }; \
	done

shellcheck: ## shellcheck on every */scripts/*.sh below DIRS (default: the repository), or on the files of SH='<file> ...'
	@files="$${SH:-}"; [ -n "$$files" ] || { files=$$($(SH_FILES)) || exit 1; }; \
	[ -n "$$files" ] || { echo "shellcheck: no shell script"; exit 0; }; \
	echo "shellcheck $$(echo $$files | wc -w | tr -d ' ') files"; \
	env -u DOCKER_DEFAULT_PLATFORM docker run --rm --network none -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK_IMAGE) $$files

# Each test runs a script against fake commands first on PATH (no network, no account) and stops the run when it fails.
script-test: ## Run every */scripts/*-test.sh below DIRS (default: the repository but drills/); stops at the first failure
	@files=$$($(TEST_SH_FILES)) || exit 1; [ -n "$$files" ] || { echo "script-test: no script test"; exit 0; }; \
	for f in $$files; do \
	  echo "script-test $$f"; \
	  bash "$$f" >/dev/null || { echo "FAIL: script-test $$f (run bash $$f for its output)" >&2; exit 1; }; \
	done

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
