#!/usr/bin/env bash

mkdir $GITHUB_WORKSPACE/test_results

python_exec=$(which python3)
python_version=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
python_lib=$(dirname $(dirname $python_exec))/lib/python$python_version
python_site_packages=$(python3 -c "import site; print(site.getsitepackages()[0])")

echo $python_exec
echo $python_lib
echo $python_site_packages

openstudio measure -t ./lib/measures >> $GITHUB_WORKSPACE/test_results/measure_check_output.txt


for dir in $(find . -type f \( -name 'measure.rb' -o -name 'measure.py' \) -exec dirname {} \;); do
    openstudio --python_path "$python_lib" --python_path "$python_site_packages" measure --run_tests $dir >> $GITHUB_WORKSPACE/test_results/test_output.txt
    if [ $? -ne 0 ]; then
        echo $dir >> $GITHUB_WORKSPACE/test_results/test_failed.txt
    fi
done

if [ -f $GITHUB_WORKSPACE/test_results/test_failed.txt ]; then
    echo "Some tests failed. Check the test output files for details."
else
    echo "All tests passed successfully."
fi