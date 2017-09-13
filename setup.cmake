# setup.cmake
#
# Script for setting up build directory.
#
# Run this file with `cmake -P setup.cmake`
#

# Create the build directory and initalize it
make_directory (build)
execute_process(
    COMMAND ${CMAKE_COMMAND} -DCMAKE_BUILD_TYPE=Debug ..
    WORKING_DIRECTORY build
)
