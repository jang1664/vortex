set(LIBRARY_NAME torch_vortex)

file(GLOB_RECURSE SOURCE_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp"
)

add_library(${LIBRARY_NAME} SHARED ${SOURCE_FILES})

# Link against libvortex.so by short name (-lvortex) rather than the
# imported-target full path, so the NEEDED entry reads "libvortex.so"
# instead of an absolute path.  This lets RUNPATH ($ORIGIN/lib) resolve
# the library from the bundled copy in torch_vortex/lib/.
target_link_libraries(${LIBRARY_NAME}
    PRIVATE torch_cpu_library
    PRIVATE -L${VORTEX_BUILD_DIR}/runtime -lvortex
)
target_include_directories(${LIBRARY_NAME} PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../include
    ${VORTEX_HOME}/runtime/include
    ${VORTEX_BUILD_DIR}/hw
)

install(TARGETS ${LIBRARY_NAME}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
