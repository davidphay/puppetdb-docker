PUPPERWARE_ANALYTICS_STREAM ?= dev
NAMESPACE ?= davidphay
git_describe = $(shell git describe)
vcs_ref := $(shell git rev-parse HEAD)
build_date := $(shell date -u +%FT%T)
hadolint_available := $(shell hadolint --help > /dev/null 2>&1; echo $$?)
hadolint_command := hadolint --ignore DL3008 --ignore DL3028
hadolint_container := ghcr.io/hadolint/hadolint:latest
export BUNDLE_PATH = $(PWD)/.bundle/gems
export BUNDLE_BIN = $(PWD)/.bundle/bin
export GEMFILE = $(PWD)/Gemfile
export DOCKER_BUILDKIT ?= 1
export PUPPETSERVER_IMAGE ?= davidphay/puppetserver:latest

VERSION ?= $(shell echo $(git_describe) | sed 's/-.*//')
# to work around failures that occur between when the repo is tagged and when the package
# is actually shipped, see if this version exists in dujour
PUBLISHED_VERSION ?= $(shell curl --silent 'https://updates.puppetlabs.com/?product=puppetdb&version=$(VERSION)' | jq '."version"' | tr -d '"')
# For our containers built from packages, we want those to be built once then never changed
# so check to see if that container already exists on dockerhub
CONTAINER_EXISTS = $(shell DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect $(NAMESPACE)/puppetdb:$(VERSION) > /dev/null 2>&1; echo $$?)
ifeq ($(CONTAINER_EXISTS),0)
	SKIP_BUILD ?= true
else ifneq ($(VERSION),$(PUBLISHED_VERSION))
	SKIP_BUILD ?= true
endif


prep:
	@git fetch --unshallow 2> /dev/null ||:
	@git fetch origin 'refs/tags/*:refs/tags/*'
	@echo $(VERSION)
ifeq ($(SKIP_BUILD),true)
	@echo "SKIP_BUILD is true, exiting with 1"
	@exit 1
endif

lint:
ifeq ($(hadolint_available),0)
	@$(hadolint_command) Dockerfile
else
	@docker pull $(hadolint_container)
	@docker run --rm -v $(PWD)/Dockerfile:/Dockerfile -i $(hadolint_container) $(hadolint_command) Dockerfile
endif

build: prep
	@docker images
	docker buildx build \
		${DOCKER_BUILD_FLAGS} \
		--load \
		--pull \
		--build-arg vcs_ref=$(vcs_ref) \
		--build-arg build_date=$(build_date) \
		--build-arg version=$(VERSION) \
		--build-arg pupperware_analytics_stream=$(PUPPERWARE_ANALYTICS_STREAM) \
		--no-cache \
		--tag $(NAMESPACE)/puppetdb:$(VERSION) \
		./
	@docker tag $(NAMESPACE)/puppetdb:$(VERSION) $(NAMESPACE)/puppetdb:latest

test: prep
	bundle install --path $$BUNDLE_PATH --gemfile $$GEMFILE --with test
	bundle update
	PUPPET_TEST_DOCKER_IMAGE=$(NAMESPACE)/puppetdb:$(VERSION) bundle exec --gemfile $$GEMFILE rspec spec

push-image: prep
	@docker images
	@docker push $(NAMESPACE)/puppetdb:$(VERSION)
	@docker push $(NAMESPACE)/puppetdb:latest

push-readme:
	@docker pull sheogorath/readme-to-dockerhub
	@docker run --rm \
		-v $(PWD)/README.md:/data/README.md \
		-e DOCKERHUB_USERNAME="$(DOCKERHUB_USERNAME)" \
		-e DOCKERHUB_PASSWORD="$(DOCKERHUB_PASSWORD)" \
		-e DOCKERHUB_REPO_PREFIX=$(NAMESPACE) \
		-e DOCKERHUB_REPO_NAME=puppetdb \
		sheogorath/readme-to-dockerhub

publish: push-image push-readme

.PHONY: prep lint build publish push-image push-readme

