TF   ?= terraform
DIRS ?= .

.PHONY: fmt fmt-check init validate lint security test check

fmt:
	$(TF) fmt -recursive

fmt-check:
	$(TF) fmt -check -recursive

init:
	@for d in $(DIRS); do $(TF) -chdir=$$d init -backend=false -input=false >/dev/null || exit 1; done

validate: init
	@for d in $(DIRS); do echo "validate $$d"; $(TF) -chdir=$$d validate || exit 1; done

lint:
	tflint --init --config "$(CURDIR)/.tflint.hcl"
	tflint --recursive --config "$(CURDIR)/.tflint.hcl"

security:
	checkov --config-file .checkov.yaml

test: init
	@for d in $(DIRS); do echo "test $$d"; $(TF) -chdir=$$d test || exit 1; done

check: fmt-check validate lint security test
