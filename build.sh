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

echo " - Pull latest image ..."
docker pull centos:latest

echo " - Delete old container if needed ..."
JENKINS_BUILD_CONTAINER=$(docker ps -a | grep "${CONT_NAME}")

if [ ! -z "$JENKINS_BUILD_CONTAINER" ]; then
	echo " - Found old container"
	JENKINS_BUILD_ID=$(echo "${JENKINS_BUILD_CONTAINER}" | awk ' { print $1 } ')

	echo " - Delete old container with id '${JENKINS_BUILD_ID}'"
	docker rm -f "${JENKINS_BUILD_ID}"
fi

echo " - Run new container ..."
docker run -it -d --name "${CONT_NAME}" -p 8080:8080 centos:latest sleep inf

JENKINS_BUILD_ID=$(docker ps -a | grep "${CONT_NAME}" | awk ' { print $1 } ')
echo " - JENKINS_BUILD_ID: ${JENKINS_BUILD_ID}"

if [ -z "${JENKINS_BUILD_ID}" ]; then
	echo "ERROR: Something went wrong!"
	exit 1
fi

echo " - Install all relevant stuff for building Jenkins ..."
docker exec -it "${JENKINS_BUILD_ID}" yum update -y
docker exec -it "${JENKINS_BUILD_ID}" yum install -y git wget java-1.8.0-openjdk-devel java-1.8.0-openjdk which make
docker exec -it "${JENKINS_BUILD_ID}" bash -c "set -e && cd /root && wget -O maven.tar.gz ${MAVEN_SRC_URL} && tar xvf maven.tar.gz"

echo " - Download Jenkins source code ..."
docker exec -it "${JENKINS_BUILD_ID}" bash -c "cd /root && git clone https://github.com/jenkinsci/jenkins.git"
docker exec -it "${JENKINS_BUILD_ID}" bash -c "PATH=/root/apache-maven-${MAVEN_VER}/bin:$PATH && cd /root/jenkins && mvn package -DskipTests"
docker exec -it "${JENKINS_BUILD_ID}" bash -c "set -e && mkdir -vp /opt/jenkins && cp -v /root/jenkins/war/target/jenkins.war /opt/jenkins"
docker exec -d -it "${JENKINS_BUILD_ID}" bash -c "cd /opt/jenkins && nohup java -jar jenkins.war"
docker exec -it "${JENKINS_BUILD_ID}" bash -c "sleep 60s && cat /root/.jenkins/secrets/initialAdminPassword"

