# Allow using a different docker binary
DOCKER ?= docker

ifeq ($(VERSION),)
	VERSION = build
	LATEST_VERSION = $(VERSION)
endif

BUILD_TAG ?= $(VERSION)

REPO = docksal/vhost-proxy
NAME = docksal-vhost-proxy

DOCKSAL_VHOST_PROXY_ACCESS_LOG = 1
DOCKSAL_VHOST_PROXY_DEBUG_LOG = 1
DOCKSAL_VHOST_PROXY_STATS_LOG = 1
PROJECT_INACTIVITY_TIMEOUT = 30s
PROJECT_DANGLING_TIMEOUT = 60s

# A delay necessary for docker-gen/nginx to reload configuration when containers start/stop.
DELAY = 2s

# Do not use ?= here to prevent possible data loss on the host system
PROJECTS_ROOT = $(PWD)/tests/projects_mount

-include tests/env_make

# Make it possible to pass arguments to Makefile from command line
# https://stackoverflow.com/a/6273809/1826109
ARGS = $(filter-out $@,$(MAKECMDGOALS))

.EXPORT_ALL_VARIABLES:

.PHONY: build exec test push shell run start stop logs debug clean release

default: build

build:
	$(DOCKER) build -t $(REPO):$(BUILD_TAG) .

test:
	# Create test projects before starting tests. This allows using "fin @project" aliases in tests.
	tests/create_test_projects.sh
	IMAGE=$(REPO):$(BUILD_TAG) tests/test.bats

push:
	$(DOCKER) push $(REPO):$(BUILD_TAG)

conf-vhosts:
	make exec -e CMD='cat /etc/nginx/conf.d/vhosts.conf'

# This is the only place where fin is used/necessary
start: clean
	# Create PROJECTS_ROOT directory used in cleanup tests
	mkdir -p $(PROJECTS_ROOT)
	# Copy custom certs used in cert tets
	cp -R tests/certs ~/.docksal
	IMAGE_VHOST_PROXY=$(REPO):$(BUILD_TAG) fin system reset vhost-proxy
	# Give vhost-proxy a bit of time to initialize
	sleep 10s
	# Stop crond, so it does not interfere with tests
	make exec -e CMD='supervisorctl stop crond'

exec:
	$(DOCKER) exec $(NAME) bash -lc '$(CMD)'

exec-it:
	$(DOCKER) exec -it $(NAME) bash -lic '$(CMD)'

stop:
	$(DOCKER) stop $(NAME)

logs:
	$(DOCKER) logs $(NAME)

logs-follow:
	$(DOCKER) logs -f $(NAME)

debug: build start logs-follow

# Curl command with http2 support via a $(DOCKER) container
# Usage: make curl -e ARGS='-kI https://docksal.io'
curl:
	$(DOCKER) run -t --rm --dns=192.168.64.100 --dns=8.8.8.8 badouralix/curl-http2 $(ARGS)

clean:
	fin @project1 rm -f &>/dev/null || true
	fin @project2 rm -f &>/dev/null || true
	fin @project3 rm -f &>/dev/null || true
	$(DOCKER) rm -vf $(NAME) &>/dev/null || true
	$(DOCKER) rm -vf standalone &>/dev/null || true
	rm -rf $(PROJECTS_ROOT)
	rm -f ~/.docksal/certs/example.com.*

release:
	@scripts/docker-push.sh

# https://stackoverflow.com/a/6273809/1826109
%:
	@:
