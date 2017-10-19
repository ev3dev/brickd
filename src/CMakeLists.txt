
find_package(Valac REQUIRED)
find_package(PkgConfig REQUIRED)

pkg_check_modules(BRICKD_DEPS REQUIRED
    glib-2.0
    gobject-2.0
    gio-2.0
    gio-unix-2.0
    gudev-1.0
)

configure_file(version.vala.in version.vala @ONLY)

vala2c(BRICKD_C_FILES
    PACKAGES
        gio-2.0
        gio-unix-2.0
        gudev-1.0
        linux
        posix
    TARGET_GLIB
        2.48
    SOURCE_FILES
        ${CMAKE_CURRENT_BINARY_DIR}/version.vala
        board_info.vala
        brickd.vala
        power_monitor.vala
)

set(BRICKD_TARGET "brickd")
add_executable(${BRICKD_TARGET} ${BRICKD_C_FILES})
target_compile_options(${BRICKD_TARGET} PRIVATE "-w")
target_include_directories(${BRICKD_TARGET} PRIVATE ${BRICKD_DEPS_INCLUDE_DIRS})
target_link_libraries(${BRICKD_TARGET} ${BRICKD_DEPS_LIBRARIES} ${SHARED_LIBRARY_TARGET})

install(TARGETS ${BRICKD_TARGET} RUNTIME DESTINATION ${CMAKE_INSTALL_SBINDIR})
