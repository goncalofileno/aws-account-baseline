TF   ?= terraform
DIRS ?= .

.PHONY: fmt fmt-check init validate lint security test check

fmt:
	$(TF) fmt -recursive

fmt-check:
	$(TF) fmt -check -recursive

init:
ifeq ($(TF),terraform)
	@for d in $(DIRS); do $(TF) -chdir=$$d init -backend=false -input=false -lockfile=readonly >/dev/null || exit 1; done
else
	@for d in $(DIRS); do $(TF) -chdir=$$d init -backend=false -input=false >/dev/null || exit 1; done
endif

# The committed .terraform.lock.hcl files are Terraform's. OpenTofu rewrites a
# lock file's entries to point at registry.opentofu.org as soon as it inits
# against it, so for any TF other than `terraform`, validate/test back up
# each directory's lock file first and restore it afterwards (even if the
# command fails), instead of leaving it mutated on disk. They run their own
# init inline (rather than depending on the `init` target) so the backup
# happens before init, which is what actually rewrites the lock file.
validate:
	@for d in $(DIRS); do \
		echo "validate $$d"; \
		lock="$$d/.terraform.lock.hcl"; backup="$$lock.orig"; \
		[ "$(TF)" != "terraform" ] && [ -f "$$lock" ] && cp "$$lock" "$$backup"; \
		if [ "$(TF)" = "terraform" ]; then \
			$(TF) -chdir=$$d init -backend=false -input=false -lockfile=readonly >/dev/null && $(TF) -chdir=$$d validate; \
		else \
			$(TF) -chdir=$$d init -backend=false -input=false >/dev/null && $(TF) -chdir=$$d validate; \
		fi; rc=$$?; \
		[ "$(TF)" != "terraform" ] && [ -f "$$backup" ] && mv "$$backup" "$$lock"; \
		[ $$rc -eq 0 ] || exit $$rc; \
	done

lint:
	tflint --init --config "$(CURDIR)/.tflint.hcl"
	tflint --recursive --config "$(CURDIR)/.tflint.hcl"

security:
	checkov --config-file .checkov.yaml

test:
	@for d in $(DIRS); do \
		echo "test $$d"; \
		lock="$$d/.terraform.lock.hcl"; backup="$$lock.orig"; \
		[ "$(TF)" != "terraform" ] && [ -f "$$lock" ] && cp "$$lock" "$$backup"; \
		if [ "$(TF)" = "terraform" ]; then \
			$(TF) -chdir=$$d init -backend=false -input=false -lockfile=readonly >/dev/null && $(TF) -chdir=$$d test; \
		else \
			$(TF) -chdir=$$d init -backend=false -input=false >/dev/null && $(TF) -chdir=$$d test; \
		fi; rc=$$?; \
		[ "$(TF)" != "terraform" ] && [ -f "$$backup" ] && mv "$$backup" "$$lock"; \
		[ $$rc -eq 0 ] || exit $$rc; \
	done

check: fmt-check validate lint security test
