#!/usr/bin/env bats

# Debugging
teardown () {
	echo
	echo "Output:"
	echo "================================================================"
	echo "${output}"
	echo "================================================================"
}

# Checks container health status (if available)
# @param $1 container id/name
_healthcheck ()
{
	local health_status
	health_status=$(${DOCKER} inspect --format='{{json .State.Health.Status}}' "$1" 2>/dev/null)

	# Wait for 5s then exit with 0 if a container does not have a health status property
	# Necessary for backward compatibility with images that do not support health checks
	if [[ $? != 0 ]]; then
		echo "Waiting 10s for container to start..."
		sleep 10
		return 0
	fi

	# If it does, check the status
	echo $health_status | grep '"healthy"' >/dev/null 2>&1
}

# Waits for containers to become healthy
_healthcheck_wait ()
{
	# Wait for cli to become ready by watching its health status
	local container_name="${1}"
	local delay=1
	local timeout=30
	local elapsed=0

	until _healthcheck "$container_name"; do
		echo "Waiting for $container_name to become ready..."
		sleep "$delay";

		# Give the container 30s to become ready
		elapsed=$((elapsed + delay))
		if ((elapsed > timeout)); then
			echo "$container_name heathcheck failed"
			exit 1
		fi
	done

	return 0
}

# To work on a specific test:
# run `export SKIP=1` locally, then comment skip in the test you want to debug

@test "${NAME} container is up and using the \"${IMAGE}\" image" {
	[[ ${SKIP} == 1 ]] && skip

	run _healthcheck_wait ${NAME}
	unset output

	# Using "bash -c" here to expand ${DOCKER} (in case it's more that a single word).
	# Without bats run returns "command not found"
	run bash -c "${DOCKER} ps --filter 'name=${NAME}' --format '{{ .Image }}'"
	[[ "$output" =~ "${IMAGE}" ]]
	unset output
}

@test "Projects directory is mounted" {
	[[ ${SKIP} == 1 ]] && skip

	run make exec -e CMD='ls -la /projects'
	[[ "$output" =~ "project1" ]]
	[[ "$output" =~ "project2" ]]
	[[ "$output" =~ "project3" ]]
}

@test "Cron is working" {
	[[ ${SKIP} == 1 ]] && skip

	# Start cron first (disabled during tests by default)
	run make exec -e CMD='supervisorctl start crond'
	[[ "$output" =~ "crond: started" ]]
	unset output

	# 'proxyctl cron' should be invoked every minute
	sleep 60s

	run make logs
	echo "$output" | grep "[proxyctl] [cron]"
	unset output

	# Stop cron after this test so it does not interfere with other tests.
	run make exec -e CMD='supervisorctl stop crond'
	[[ "$output" =~ "crond: stopped" ]]
	unset output
}

@test "Test project stacks exist" {
	[[ ${SKIP} == 1 ]] && skip

	run fin pl -a
	[[ "$output" =~ "project1" ]]
	[[ "$output" =~ "project2" ]]
	[[ "$output" =~ "project3" ]]
}

@test "Proxy returns 404 for a non-existing virtual-host" {
	[[ ${SKIP} == 1 ]] && skip

	run curl -sS -I http://nonsense.docksal.site
	[[ "$output" =~ "HTTP/1.1 404 Not Found" ]]
	unset output
}

@test "Proxy returns 200 for an existing virtual-host" {
	[[ ${SKIP} == 1 ]] && skip

	# Restart project to reset timing
	fin @project2 project restart

	# Give docker-gen and nginx a little time to reload config
	sleep ${DELAY}

	run curl -sS -I http://project2.docksal.site
	[[ "$output" =~ "HTTP/1.1 200 OK" ]]
	unset output
}

# We have to use a different version of curl here with built-in http2 support
@test "Proxy uses HTTP/2 for HTTPS connections" {
	[[ ${SKIP} == 1 ]] && skip

	# Non-existing project
	run make curl -- -sSk -I https://nonsense.docksal.site
	[[ "$output" =~ "HTTP/2 404" ]]
	unset output

	# Existing project
	run make curl -- -sSk -I https://project2.docksal.site
	[[ "$output" =~ "HTTP/2 200" ]]
	unset output
}

@test "Proxy stops project containers after \"${PROJECT_INACTIVITY_TIMEOUT}\" of inactivity" {
	[[ ${SKIP} == 1 ]] && skip

	[[ "$PROJECT_INACTIVITY_TIMEOUT" == "0" ]] &&
		skip "Stopping has been disabled via PROJECT_INACTIVITY_TIMEOUT=0"

	# Restart projects to reset timing
	fin @project1 project restart
	fin @project2 project restart

	# Confirm projects are considered active here
	run make exec -e CMD='proxyctl stats'
	echo "$output" | grep project1 | grep "Active: 1"
	echo "$output" | grep project2 | grep "Active: 1"
	unset output

	# Wait
	sleep ${PROJECT_INACTIVITY_TIMEOUT}

	# Confirm projects are considered inactive here
	run make exec -e CMD='proxyctl stats'
	echo "$output" | grep project1 | grep "Active: 0"
	echo "$output" | grep project2 | grep "Active: 0"
	unset output

	# Trigger proxyctl stop manually to skip the cron job wait.
	# Note: cron job may still have already happened here and stopped the inactive projects
	run make exec -e CMD='proxyctl stop'
	[[ "$output" =~ "Stopping inactive project: project1" ]]
	[[ "$output" =~ "Stopping inactive project: project2" ]]
	unset output

	# Check projects were stopped, but not removed
	run make exec -e CMD='proxyctl stats'
	echo "$output" | grep project1 | grep "Running: 0"
	echo "$output" | grep project2 | grep "Running: 0"
	unset output

	# Check project networks were removed
	run bash -c "${DOCKER} network ls"
	[[ ${status} == 0 ]]
	[[ ! "$output" =~ "project1" ]]
	[[ ! "$output" =~ "project2" ]]
	unset output
}

@test "Proxy starts an existing stopped project [HTTP]" {
	[[ ${SKIP} == 1 ]] && skip

	# Make sure the project is stopped
	fin @project2 project stop

	# Give docker-gen and nginx a little time to reload config
	sleep ${DELAY}

	run curl -sS http://project2.docksal.site
	[[ "$output" =~ "Loading project..." ]]
	unset output

	# Wait for container to become healthy
	_healthcheck_wait project2_web_1

	run curl -sS http://project2.docksal.site
	[[ "$output" =~ "Project 2" ]]
	unset output
}

@test "Proxy starts an existing stopped project [HTTPS]" {
	[[ ${SKIP} == 1 ]] && skip

	# Make sure the project is stopped
	fin @project2 project stop

	# Give docker-gen and nginx a little time to reload config
	sleep ${DELAY}

	run make curl -- -sSk https://project2.docksal.site
	[[ "$output" =~ "Loading project..." ]]
	unset output

	# Wait for container to become healthy
	_healthcheck_wait project2_web_1

	run make curl -- -sSk https://project2.docksal.site
	[[ "$output" =~ "Project 2" ]]
	unset output
}

@test "Proxy cleans up non-permanent projects after \"${PROJECT_DANGLING_TIMEOUT}\" of inactivity" {
	[[ ${SKIP} == 1 ]] && skip

	[[ "$PROJECT_DANGLING_TIMEOUT" == "0" ]] &&
		skip "Cleanup has been disabled via PROJECT_DANGLING_TIMEOUT=0"

	# Restart projects to reset timing
	run fin @project1 restart
	run fin @project2 restart
	unset output

	# Wait
	sleep ${PROJECT_DANGLING_TIMEOUT}

	# Confirm projects are considered dangling here.
	run make exec -e CMD='proxyctl stats'
	echo "$output" | grep project1 | grep "Dangling: 1"
	echo "$output" | grep project2 | grep "Dangling: 1"
	unset output

	# Trigger proxyctl cleanup manually, since cron is disabled in this test (see above).
	run make exec -e CMD='proxyctl cleanup'
	[[ "$output" =~ "Removing dangling project: project1" ]]
	[[ ! "$output" =~ "Removing dangling project: project2" ]]
	unset output

	# Check that all project1 containers were removed
	run bash -c "${DOCKER} ps -a -q --filter 'label=com.docker.compose.project=project1'"
	[[ "$output" == "" ]]
	unset output

	# Check project1 network was removed
	run bash -c "${DOCKER} network ls"
	echo "$output" | grep -v project1
	unset output

	# Check project1 folder was removed
	run make exec -e CMD='ls -la /projects'
	echo "$output" | grep -v project1

	# Check that project2 still exist
	run fin pl -a
	echo "$output" | grep project2
	unset output
	
	# Check that project2 folder was NOT removed
	run make exec -e CMD='ls -la /projects'
	echo "$output" | grep project2
	unset output
}

@test "Proxy can route request to a non-default port [project stack]" {
	[[ ${SKIP} == 1 ]] && skip

	# Restart projects to reset timing
	fin @project3 restart

	# Wait for container to become healthy
	_healthcheck_wait project3_web_1

	run curl -sS http://project3.docksal.site
	[[ "$output" =~ "Hello world: Project 3" ]]
	unset output
}

@test "Proxy can route request to a non-default port [standalone container]" {
	[[ ${SKIP} == 1 ]] && skip

	# Start a standalone container
	${DOCKER} rm -vf standalone &>/dev/null || true
	${DOCKER} run --name standalone -d \
		--expose 2580 \
		--label=io.docksal.virtual-host='standalone.docksal.site' \
		--label=io.docksal.virtual-port='2580' \
		hashicorp/http-echo:0.2.3 -listen=:2580 -text="Hello world: standalone"


	# Wait for container to become healthy
	_healthcheck_wait standalone

	run curl -sS http://standalone.docksal.site
	[[ "$output" =~ "Hello world: standalone" ]]
	unset output

	# Cleanup
	${DOCKER} rm -vf standalone &>/dev/null || true
}

@test "Certs: proxy picks up custom cert based on hostname [project stack]" {
	[[ ${SKIP} == 1 ]] && skip

	# Stop all running projects to get a clean output of vhosts configured in nginx
	fin stop -a

	# Cleanup and restart the test project (using project2 as it is set to be permanent for testing purposes)
	fin @project2 config rm VIRTUAL_HOST &>/dev/null || true
	fin @project2 config rm VIRTUAL_HOST_CERT_NAME &>/dev/null || true
	fin @project2 project start

	# Give docker-gen and nginx a little time to reload config
	sleep ${DELAY}

	# Check fallback cert is used by default
	run make conf-vhosts
	[[ "$output" =~ "server_name project2.docksal.site;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/server.crt;" ]]
	unset output

	# Set custom domain for project2
	fin @project2 config set VIRTUAL_HOST=project2.example.com
	fin @project2 project start

	# Give docker-gen and nginx a little time to reload config
	sleep ${DELAY}

	# Check custom cert was picked up
	run make conf-vhosts
	[[ "$output" =~ "server_name project2.example.com;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/custom/example.com.crt;" ]]
	unset output
}

@test "Certs: proxy picks up custom cert based on cert name override [project stack]" {
	[[ ${SKIP} == 1 ]] && skip

	# Stop all running projects to get a clean output of vhosts configured in nginx
	fin project stop -a

	# Cleanup and restart the test project (using project2 as it is set to be permanent for testing purposes)
	fin @project2 config rm VIRTUAL_HOST &>/dev/null || true
	fin @project2 config rm VIRTUAL_HOST_CERT_NAME &>/dev/null || true
	fin @project2 project start

	# Set VIRTUAL_HOST_CERT_NAME for project2
	fin @project2 config set VIRTUAL_HOST_CERT_NAME=example.com
	fin @project2 project start

	# Give docker-gen and nginx a little time to reload config
	sleep ${DELAY}

	# Check server_name is intact while custom cert was picked up
	run make conf-vhosts
	[[ "$output" =~ "server_name project2.docksal.site;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/custom/example.com.crt;" ]]
	unset output
}

@test "Certs: proxy picks up custom cert based on hostname [standalone container]" {
	[[ ${SKIP} == 1 ]] && skip

	# Stop all running projects to get a clean output of vhosts configured in nginx
	fin stop -a

	# Start a standalone container
	${DOCKER} rm -vf standalone &>/dev/null || true
	${DOCKER} run --name standalone-cert1 -d \
		--label=io.docksal.virtual-host='standalone-cert1.example.com' \
		hashicorp/http-echo:0.2.3

	# Wait for container to become healthy
	_healthcheck_wait standalone-cert1

	# Check custom cert was picked up
	run make conf-vhosts
	[[ "$output" =~ "server_name standalone-cert1.example.com;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/custom/example.com.crt;" ]]
	unset output

	# Cleanup
	${DOCKER} rm -vf standalone-cert1 &>/dev/null || true
}

@test "Certs: proxy picks up custom cert based on cert name override [standalone container]" {
	[[ ${SKIP} == 1 ]] && skip

	# Stop all running projects to get a clean output of vhosts configured in nginx
	fin stop -a

	# Start a standalone container
	${DOCKER} rm -vf standalone &>/dev/null || true
	${DOCKER} run --name standalone-cert2 -d \
		--label=io.docksal.virtual-host='standalone-cert2.example.com' \
		--label=io.docksal.cert-name='example.com' \
		hashicorp/http-echo:0.2.3

	# Wait for container to become healthy
	_healthcheck_wait standalone-cert2

	# Check server_name is intact while custom cert was picked up
	run make conf-vhosts
	[[ "$output" =~ "server_name standalone-cert2.example.com;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/custom/example.com.crt;" ]]
	unset output

	# Cleanup
	${DOCKER} rm -vf standalone-cert2 &>/dev/null || true
}
