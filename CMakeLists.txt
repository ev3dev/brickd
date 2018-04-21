cmake_minimum_required(VERSION 3.5)

project(brickpower VERSION 1.1.3 LANGUAGES C)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)

include(GNUInstallDirs)

# add_subdirectory(docs)
add_subdirectory(src)
