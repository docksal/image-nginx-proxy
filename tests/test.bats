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
	health_status=$(docker inspect --format='{{json .State.Health.Status}}' "$1" 2>/dev/null)

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
	local container_name="${NAME}"
	local delay=5
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
	_healthcheck_wait

	run docker ps --filter "name=${NAME}" --format "{{ .Image }}"
	[[ "$output" =~ "${IMAGE}" ]]
	unset output
}

@test "Projects directory is mounted" {
	[[ ${SKIP} == 1 ]] && skip

	run make exec -e CMD='ls -la /projects'
	[[ "$output" =~ "project1" ]]
	[[ "$output" =~ "project2" ]]
}

@test "Cron is working" {
	[[ ${SKIP} == 1 ]] && skip

	# 'proxyctl cron' should be invoked every minute
	sleep 60s

	run make logs
	echo "$output" | grep "[proxyctl] [cron]"
	unset output

	# Kill crontab once this test completes, so that cron does not interfere with the rest of the tests
	make exec -e CMD='crontab -r'
}

@test "Test projects are up and running" {
	[[ ${SKIP} == 1 ]] && skip

	fin @project1 restart
	fin @project2 restart
	fin @project3 restart

	run fin pl
	[[ "$output" =~ "project1" ]]
	[[ "$output" =~ "project2" ]]
	[[ "$output" =~ "project3" ]]
}

@test "Proxy returns 404 for a non-existing virtual-host" {
	[[ ${SKIP} == 1 ]] && skip

	run curl -I http://nonsense.docksal
	[[ "$output" =~ "HTTP/1.1 404 Not Found" ]]
	unset output
}

@test "Proxy returns 200 for an existing virtual-host" {
	[[ ${SKIP} == 1 ]] && skip

	run curl -I http://project1.docksal
	[[ "$output" =~ "HTTP/1.1 200 OK" ]]
	unset output

	run curl -I http://project2.docksal
	[[ "$output" =~ "HTTP/1.1 200 OK" ]]
	unset output
}

# We have to use a different version of curl here built with http2 support
@test "Proxy uses HTTP/2 for HTTPS connections" {
	[[ ${SKIP} == 1 ]] && skip

	# Non-existing project
	run make curl -e ARGS='-kI https://nonsense.docksal'
	[[ "$output" =~ "HTTP/2 404" ]]
	unset output

	# Existing projects
	run make curl -e ARGS='-kI https://project1.docksal'
	[[ "$output" =~ "HTTP/2 200" ]]
	unset output

	run make curl -e ARGS='-kI https://project2.docksal'
	[[ "$output" =~ "HTTP/2 200" ]]
	unset output
}

@test "Proxy stops project containers after \"${PROJECT_INACTIVITY_TIMEOUT}\" of inactivity" {
	[[ ${SKIP} == 1 ]] && skip

	[[ "$PROJECT_INACTIVITY_TIMEOUT" == "0" ]] &&
		skip "Stopping has been disabled via PROJECT_INACTIVITY_TIMEOUT=0"

	# Restart projects to reset timing
	fin @project1 restart
	fin @project2 restart

	# Wait
	date
	sleep ${PROJECT_INACTIVITY_TIMEOUT}
	date

	make exec -e CMD='proxyctl stats'
	# Trigger proxyctl stop manually to skip the cron job wait.
	# Note: cron job may still have already happened here and stopped the inactive projects
	make exec -e CMD='proxyctl stop'

	# Check projects were stopped, but not removed
	run fin pl -a
	echo "$output" | grep project1 | grep 'Exited (0)'
	echo "$output" | grep project2 | grep 'Exited (0)'
	unset output

	# Check project networks were removed
	run docker network ls
	echo "$output" | grep -v project1
	echo "$output" | grep -v project2
	unset output
}

@test "Proxy starts an existing stopped project (HTTP)" {
	[[ ${SKIP} == 1 ]] && skip

	# Make sure the project is stopped
	fin @project1 stop

	run curl http://project1.docksal
	[[ "$output" =~ "Restarting project" ]]
	unset output

	run curl http://project1.docksal
	[[ "$output" =~ "Project 1" ]]
	unset output
}

@test "Proxy starts an existing stopped project (HTTPS)" {
	[[ ${SKIP} == 1 ]] && skip

	# Make sure the project is stopped
	fin @project1 stop

	run curl -k https://project1.docksal
	[[ "$output" =~ "Restarting project" ]]
	unset output

	run curl -k https://project1.docksal
	[[ "$output" =~ "Project 1" ]]
	unset output
}

@test "Proxy cleans up non-permanent projects after \"${PROJECT_DANGLING_TIMEOUT}\" of inactivity" {
	[[ ${SKIP} == 1 ]] && skip

	[[ "$PROJECT_DANGLING_TIMEOUT" == "0" ]] &&
		skip "Cleanup has been disabled via PROJECT_DANGLING_TIMEOUT=0"

	# Restart projects to reset timing
	fin @project1 restart
	fin @project2 restart

	# Wait
	date
	sleep ${PROJECT_DANGLING_TIMEOUT}
	date

	make exec -e CMD='proxyctl stats'
	# Trigger proxyctl cleanup manually to skip the cron job wait.
	make exec -e CMD='proxyctl cleanup'

	# Check project1 containers were removed
	run docker ps -a -q --filter "label=com.docker.compose.project=project1"
	[[ "$output" == "" ]]
	unset output
	# Check project1 network was removed
	run docker network ls
	echo "$output" | grep -v project1
	unset output
	# Check project1 folder was removed
	make exec -e CMD='ls -la /projects'
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

@test "Proxy can route request to a non-default port (project)" {
	[[ ${SKIP} == 1 ]] && skip

	# Restart projects to reset timing
	fin @project3 restart

	# TODO: WTF is it stopped here?
	make exec -e CMD='proxyctl stats'
	curl -I http://project3.docksal

	run curl http://project3.docksal
	[[ "$output" =~ "Hello World!" ]]
	unset output
}

@test "Proxy can route request to a non-default port (standalone container)" {
	[[ ${SKIP} == 1 ]] && skip

	run curl -k http://nodejs.docksal
	[[ "$output" =~ "Hello World!" ]]
	unset output
}

@test "Certs: proxy picks up custom cert based on hostname [stack]" {
	[[ ${SKIP} == 1 ]] && skip

	# Stop all running projects to get a clean output of vhosts configured in nginx
	fin stop -a

	# Cleanup and restart the test project (using project2 as it is set to be permanent for testing purposes)
	fin @project2 config rm VIRTUAL_HOST || true
	fin @project2 config rm VIRTUAL_HOST_CERT_NAME || true
	fin @project2 up

	# Check fallback cert is used by default
	run make conf-vhosts
	[[ "$output" =~ "server_name project2.docksal;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/server.crt;" ]]
	unset output

	# Set custom domain for project2
	fin @project2 config set VIRTUAL_HOST=project2.example.com
	fin @project2 up

	# Check custom cert was picked up
	run make conf-vhosts
	[[ "$output" =~ "server_name project2.example.com;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/custom/example.com.crt;" ]]
	unset output
}

@test "Certs: proxy picks up custom cert based on cert name override [stack]" {
	[[ ${SKIP} == 1 ]] && skip

	# Stop all running projects to get a clean output of vhosts configured in nginx
	fin stop -a

	# Cleanup and restart the test project (using project2 as it is set to be permanent for testing purposes)
	fin @project2 config rm VIRTUAL_HOST || true
	fin @project2 config rm VIRTUAL_HOST_CERT_NAME || true
	fin @project2 up

	# Set VIRTUAL_HOST_CERT_NAME for project2
	fin @project2 config set VIRTUAL_HOST_CERT_NAME=example.com
	fin @project2 up

	# Check server_name is intact while custom cert was picked up
	run make conf-vhosts
	[[ "$output" =~ "server_name project2.docksal;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/custom/example.com.crt;" ]]
	unset output
}

@test "Certs: proxy picks up custom cert based on hostname [standalone]" {
	#[[ ${SKIP} == 1 ]] && skip

	# Stop all running projects to get a clean output of vhosts configured in nginx
	fin stop -a

	# Start a standalone container
	docker rm -vf nginx || true
	docker run --name nginx -d \
		--label=io.docksal.virtual-host='nginx.example.com' \
		nginx:alpine
	sleep 1

	# Check custom cert was picked up
	run make conf-vhosts
	[[ "$output" =~ "server_name nginx.example.com;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/custom/example.com.crt;" ]]
	unset output

	# Cleanup
	docker rm -vf nginx || true
}

@test "Certs: proxy picks up custom cert based on cert name override [standalone]" {
	#[[ ${SKIP} == 1 ]] && skip

	# Stop all running projects to get a clean output of vhosts configured in nginx
	fin stop -a
	docker rm -vf nginx || true

	# Start a standalone container
	docker rm -vf nginx || true
	docker run --name nginx -d \
		--label=io.docksal.virtual-host='apache.example.com' \
		--label=io.docksal.cert-name='example.com' \
		nginx:alpine
	sleep 1

	# Check server_name is intact while custom cert was picked up
	run make conf-vhosts
	[[ "$output" =~ "server_name apache.example.com;" ]]
	[[ "$output" =~ "ssl_certificate /etc/certs/custom/example.com.crt;" ]]
	unset output

	# Cleanup
	docker rm -vf nginx || true
}
