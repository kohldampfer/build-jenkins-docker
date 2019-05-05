#!/bin/bash

set -e

echo " - Check if correct rights exist ..."
if [ "$EUID" -ne 0 ]; then
	echo "Please run this script as root!"
	exit 1
fi

CONT_NAME=jenkins_build
MAVEN_VER="3.6.0"
MAVEN_SRC_URL="https://www-eu.apache.org/dist/maven/maven-3/${MAVEN_VER}/binaries/apache-maven-${MAVEN_VER}-bin.tar.gz"
NETWORK_NAME="local-jenkins-network"

echo " - Pull latest image ..."
docker pull centos:latest

function create_network() {
	local network_name

	network_name="$1"

	if [ -z "${network_name}" ]; then
		echo "ERROR: Function create_network was called without any parameter."
		exit 1
	fi

	echo " - Try to create docker network '${network_name}'"

	jenkins_network=$(docker network ls | grep "${network_name}" || [[ $? == 1 ]])
	# create network if it does not exist
	if [ -z "${jenkins_network}" ]; then
		docker network create "${network_name}"
	fi

	echo " - List of docker networks on machine ..."
	docker network ls
}

function clear_container() {
	local container

	container="$1"
	if [ -z "$container" ]; then
		echo "ERROR: Function clear_container was called without any parameter."
		exit 1
	fi

	echo " - Delete old container '${container}' if needed ..."
	JENKINS_BUILD_CONTAINER=$(docker ps -a | grep "${container}" || [[ $? == 1 ]])

	if [ ! -z "$JENKINS_BUILD_CONTAINER" ]; then
		echo " - Found old container '${container}'"
		JENKINS_BUILD_ID=$(echo "${JENKINS_BUILD_CONTAINER}" | awk ' { print $1 } ')

		echo " - Delete old container with id '${JENKINS_BUILD_ID}'"
		docker rm -f "${JENKINS_BUILD_ID}"
	else
		echo " - No old container '${container}' found."
	fi
}

function build_slave() {
	local container

	container="$1"
	if [ -z "$container" ]; then
		echo "ERROR: Function build_slave was called without any parameter."
		exit 1
	fi

	docker run -it -d --name "${container}" --network "${NETWORK_NAME}" -p 22 centos:latest sleep inf

	# check if container started
	SLAVE_ID=$(docker ps -a | grep "${container}" | awk ' { print $1 } ')
	if [ -z "$SLAVE_ID" ]; then
		echo "ERROR: Something went wrong in starting container '${container}'"
		exit 1
	fi

	# now install relevant stuff withing docker container
	docker exec -it "${SLAVE_ID}" yum update -y
	docker exec -it "${SLAVE_ID}" yum install -y make openssh-server java-1.8.0-openjdk git make gcc gcc-c++
	docker exec -it "${SLAVE_ID}" bash -c "/usr/bin/ssh-keygen -A"
	docker exec -it "${SLAVE_ID}" bash -c "nohup /usr/sbin/sshd"

	# create user for ssh into slave from Master
	docker exec -it "${SLAVE_ID}" bash -c "adduser jenkinsslave && echo jenkinsslave | passwd --stdin jenkinsslave"

	# install cmake
	docker exec -it "${SLAVE_ID}" bash -c "cd /home/jenkinsslave && git clone https://github.com/Kitware/CMake"
	docker exec -it "${SLAVE_ID}" bash -c "cd /home/jenkinsslave/CMake && ./bootstrap && make install"

}

create_network "${NETWORK_NAME}"

clear_container "${CONT_NAME}"
clear_container "slave1"

build_slave "slave1"

echo " - Start creating Jenkins Master ..."
docker run -it -d --name "${CONT_NAME}" -p 8080:8080 --network "${NETWORK_NAME}" -p 22 centos:latest sleep inf

JENKINS_BUILD_ID=$(docker ps -a | grep "${CONT_NAME}" | awk ' { print $1 } ')
echo " - JENKINS_BUILD_ID: ${JENKINS_BUILD_ID}"

if [ -z "${JENKINS_BUILD_ID}" ]; then
	echo "ERROR: Something went wrong!"
	exit 1
fi

echo " - Install all relevant stuff for building Jenkins Master ..."
docker exec -it "${JENKINS_BUILD_ID}" yum update -y
docker exec -it "${JENKINS_BUILD_ID}" yum install -y git wget java-1.8.0-openjdk-devel java-1.8.0-openjdk which make openssh-server gcc gcc-c++
docker exec -it "${JENKINS_BUILD_ID}" bash -c "set -e && cd /root && wget -O maven.tar.gz ${MAVEN_SRC_URL} && tar xvf maven.tar.gz"

echo " - Download Jenkins source code and compile it ..."
docker exec -it "${JENKINS_BUILD_ID}" bash -c "cd /root && git clone https://github.com/jenkinsci/jenkins.git"
docker exec -it "${JENKINS_BUILD_ID}" bash -c "PATH=/root/apache-maven-${MAVEN_VER}/bin:$PATH && cd /root/jenkins && mvn package -DskipTests"
docker exec -it "${JENKINS_BUILD_ID}" bash -c "set -e && mkdir -vp /opt/jenkins && cp -v /root/jenkins/war/target/jenkins.war /opt/jenkins"
docker exec -d -it "${JENKINS_BUILD_ID}" bash -c "cd /opt/jenkins && nohup java -jar jenkins.war"
docker exec -it "${JENKINS_BUILD_ID}" bash -c "/usr/bin/ssh-keygen -A && /usr/sbin/sshd"
# docker exec -it "${JENKINS_BUILD_ID}" bash -c "sleep 60s && cat /root/.jenkins/secrets/initialAdminPassword"

docker exec -it "${JENKINS_BUILD_ID}" bash -c "cd /root && git clone https://github.com/Kitware/CMake"
docker exec -it "${JENKINS_BUILD_ID}" bash -c "cd /root/CMake && ./bootstrap && make install"

docker exec -it "${JENKINS_BUILD_ID}" bash -c "sleep 60s && cat /root/.jenkins/secrets/initialAdminPassword"

