IMAGE    := hello-mondoo
DIST     := dist
MANIFEST := k8s/10-deployment.yaml

# Release to package. Defaults to the one the manifest deploys, same as CI.
TAG ?= v$(shell sed -nE 's#^[[:space:]]*image: docker\.io/clickbg/hello-mondoo:([^@[:space:]]+).*#\1#p' $(MANIFEST))

# Build for the architecture the Docker engine runs, so the image runs
# natively: arm64 on Apple Silicon, amd64 on x86 Linux. Override with ARCH=.
ARCH ?= $(shell docker version --format '{{.Server.Arch}}' 2>/dev/null || uname -m)
override ARCH := $(strip $(patsubst x86_64,amd64,$(patsubst aarch64,arm64,$(ARCH))))

PORT ?= 8080

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-8s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  TAG=$(TAG)  ARCH=$(ARCH)  PORT=$(PORT)"

.PHONY: check-arch
check-arch:
	@case "$(ARCH)" in amd64|arm64) ;; *) echo "unsupported ARCH '$(ARCH)', use amd64 or arm64" >&2; exit 1 ;; esac

# Stamp file, so a tag is only downloaded and verified once.
$(DIST)/.verified-$(TAG):
	scripts/fetch-release.sh $(TAG) $(DIST)
	@touch $@

.PHONY: fetch
fetch: $(DIST)/.verified-$(TAG) ## Download and verify the release binaries

.PHONY: build
build: check-arch fetch ## Build the image for the local architecture
	docker buildx build --platform linux/$(ARCH) --load -t $(IMAGE):$(TAG:v%=%) .

.PHONY: run
run: build ## Build and run on localhost:$(PORT)
	docker run --rm -p $(PORT):$(PORT) -e HTTP_PORT=$(PORT) $(IMAGE):$(TAG:v%=%)

.PHONY: clean
clean: ## Remove downloaded binaries and the local image
	rm -rf $(DIST)
	-docker image rm $(IMAGE):$(TAG:v%=%) 2>/dev/null
