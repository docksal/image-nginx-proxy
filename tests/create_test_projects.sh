#!/usr/bin/env bash

# PROJECTS_ROOT is set in Makefile
# Pre-creating test projects allows using fin project aliases ('fin @project <command>'), which simplifies things.
for dir in tests/projects/*; do

	cwd=$(pwd)

	project=$(basename ${dir})
	mkdir -p ${PROJECTS_ROOT}
	rm -rf ${PROJECTS_ROOT}/${project}
	cp -R tests/projects/${project} ${PROJECTS_ROOT}
	cd ${PROJECTS_ROOT}/${project} && fin docker-compose up --no-start

	cd ${cwd}
done
