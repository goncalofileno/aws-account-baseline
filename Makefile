TF   ?= terraform
DIRS ?= . bootstrap

.PHONY: fmt fmt-check init validate lint security test check

fmt:
	$(TF) fmt -recursive

fmt-check:
	$(TF) fmt -check -recursive

# The committed .terraform.lock.hcl files are Terraform's. OpenTofu rewrites a
# lock file's entries to point at registry.opentofu.org as soon as it inits
# against it, so for any TF other than `terraform`, this canned recipe backs
# up each directory's lock file before running `$(TF) init` (and, when $(1) is
# given, the subcommand after it) and restores it afterwards, even on failure,
# instead of leaving it mutated on disk; TF=terraform uses `-lockfile=readonly`
# instead, which fails on drift against the committed lock file. $(1) is the
# optional subcommand to run after init (e.g. validate, test); with no
# argument it just does init. Directories without a lock file yet are
# unaffected (the backup/restore steps are skipped for them).
# Checks use their own data dir, so a working copy that was initialised against the real S3
# backend (after a local apply) doesn't make `init -backend=false` try to reach AWS.
CHECKS_DATA_DIR ?= .terraform-checks

define tf_each
	@for d in $(DIRS); do \
		if [ -n "$(1)" ]; then echo "$(1) $$d"; fi; \
		lock="$$d/.terraform.lock.hcl"; backup="$$lock.orig"; \
		[ "$(TF)" != "terraform" ] && [ -f "$$lock" ] && cp "$$lock" "$$backup"; \
		if [ "$(TF)" = "terraform" ]; then \
			TF_DATA_DIR=$(CHECKS_DATA_DIR) $(TF) -chdir=$$d init -backend=false -input=false -lockfile=readonly >/dev/null; rc=$$?; \
		else \
			TF_DATA_DIR=$(CHECKS_DATA_DIR) $(TF) -chdir=$$d init -backend=false -input=false >/dev/null; rc=$$?; \
		fi; \
		if [ $$rc -eq 0 ] && [ -n "$(1)" ]; then TF_DATA_DIR=$(CHECKS_DATA_DIR) $(TF) -chdir=$$d $(1); rc=$$?; fi; \
		[ "$(TF)" != "terraform" ] && [ -f "$$backup" ] && mv "$$backup" "$$lock"; \
		[ $$rc -eq 0 ] || exit $$rc; \
	done
endef

init:
	$(call tf_each)

validate:
	$(call tf_each,validate)

lint:
	tflint --init --config "$(CURDIR)/.tflint.hcl"
	tflint --recursive --config "$(CURDIR)/.tflint.hcl"

security:
	@want=$$(cat .checkov-version); have=$$(checkov --version); \
	  [ "$$want" = "$$have" ] || { echo "checkov $$have installed, $$want expected (pipx install checkov==$$want)"; exit 1; }
	checkov --config-file .checkov.yaml

test:
	$(call tf_each,test)

check: fmt-check validate lint security test
