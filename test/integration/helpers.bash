#!/bin/bash

# Root directory of the repository.
SWARM_ROOT=${SWARM_ROOT:-${BATS_TEST_DIRNAME}/../..}

# Path of the Swarm binary.
SWARM_BINARY=`mktemp`

# Docker image and version to use for integration tests.
DOCKER_IMAGE=${DOCKER_IMAGE:-dockerswarm/docker}
DOCKER_VERSION=${DOCKER_VERSION:-1.6}

# Host on which the manager will listen to (random port between 6000 and 7000).
SWARM_HOST=127.0.0.1:$(( ( RANDOM % 1000 )  + 6000 ))

# Use a random base port (for engines) between 5000 and 6000.
BASE_PORT=$(( ( RANDOM % 1000 )  + 5000 ))

# Join an array with a given separator.
function join() {
	local IFS="$1"
	shift
	echo "$*"
}

# Build the Swarm binary (if not already built)
function build_swarm() {
	[ -x $SWARM_BINARY ] || (rm -f $SWARM_BINARY && cd $SWARM_ROOT && godep go build -o $SWARM_BINARY)
}

# Run the swarm binary. You must NOT fork this command (swarm foo &) as the PID
# ($!) will be the one of the subshell instead of swarm and you won't be able
# to kill it.
function swarm() {
	build_swarm
	"$SWARM_BINARY" "$@"
}

# Retry a command $1 times until it succeeds. Wait $2 seconds between retries.
function retry() {
	local attempts=$1
	shift
	local delay=$1
	shift
	local i

	for ((i=0; i < attempts; i++)); do
		run "$@"
		if [[ "$status" -eq 0 ]] ; then
			return 0
		fi
		sleep $delay
	done

	echo "Command \"$@\" failed $attempts times. Output: $output"
	[[ false ]]
}

# Waits until the given docker engine API becomes reachable.
function wait_until_reachable() {
	retry 10 1 docker -H $1 info
}

# Start the swarm manager in background.
function swarm_manage() {
	build_swarm

	local discovery
	if [ $# -eq 0 ]; then
		discovery=`join , ${HOSTS[@]}`
	else
		discovery="$@"
	fi

	$SWARM_BINARY manage -H $SWARM_HOST $discovery &
	SWARM_PID=$!
	wait_until_reachable $SWARM_HOST
}

# Start swarm join for every engine with the discovery as parameter
function swarm_join() {
	build_swarm

	local i=0
	for h in ${HOSTS[@]}; do
		echo "Swarm join #${i}: $h $@"
		$SWARM_BINARY join --addr=$h "$@" &
		SWARM_JOIN_PID[$i]=$!
		((++i))
	done
	wait_until_swarm_joined $i
}

# Wait until a swarm instance joins the cluster.
# Parameter $1 is number of nodes to check.
function wait_until_swarm_joined {
	local attempts=0
	local max_attempts=10

	until [ $attempts -ge $max_attempts ]; do
		run docker -H $SWARM_HOST info
		if [[ "${lines[3]}" == *"Nodes: $1"* ]]; then
			break
		fi 
		echo "Checking if joined successfully for the $((++attempts)) time" >&2
		sleep 1
	done
	[[ $attempts -lt $max_attempts ]]
}

# Stops the manager.
function swarm_manage_cleanup() {
	kill $SWARM_PID
}

# Clean up Swarm join processes
function swarm_join_cleanup() {
	for pid in ${SWARM_JOIN_PID[@]}; do
		kill $pid
	done
}

# Run the docker CLI against swarm.
function docker_swarm() {
	docker -H $SWARM_HOST "$@"
}

# Start N docker engines.
function start_docker() {
	local current=${#DOCKER_CONTAINERS[@]}
	local instances="$1"
	shift
	local i

	# Start the engines.
	for ((i=current; i < (current + instances); i++)); do
		local port=$(($BASE_PORT + $i))
		HOSTS[$i]=127.0.0.1:$port
		DOCKER_CONTAINERS[$i]=$(docker run -d --name node-$i -h node-$i --privileged -p 127.0.0.1:$port:$port -it ${DOCKER_IMAGE}:${DOCKER_VERSION} docker -d -H 0.0.0.0:$port "$@")
	done

	# Wait for the engines to be reachable.
	for ((i=current; i < (current + instances); i++)); do
		wait_until_reachable ${HOSTS[$i]}
	done
}

# Stop all engines.
function stop_docker() {
	for id in ${DOCKER_CONTAINERS[@]}; do
		echo "Stopping $id"
		docker rm -f -v $id > /dev/null;
	done
}
