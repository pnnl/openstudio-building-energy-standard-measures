#!/usr/bin/env bash

mkdir $GITHUB_WORKSPACE/test_results

openstudio measure -t ./lib/measures >> $GITHUB_WORKSPACE/test_results/measure_check_output.txt

for dir in $(find . -type f -name 'measure.py' -exec dirname {} \; | sort -u); do
    pytest $dir >> $GITHUB_WORKSPACE/test_results/pytest_output.txt
done