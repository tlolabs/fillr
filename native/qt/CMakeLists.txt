cmake_minimum_required(VERSION 3.21)
project(FILLRQt LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/../../script/version.py"
    OUTPUT_VARIABLE FILLR_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE VERSION_RESULT)
if(NOT VERSION_RESULT EQUAL 0)
    message(FATAL_ERROR "Could not read the FILLR version")
endif()

find_package(Qt6 6.4 REQUIRED COMPONENTS Widgets Network)

add_executable(fillr_qt
    main.cpp
    MainWindow.cpp
    MainWindow.h
    Engine.cpp
    Engine.h
    Settings.cpp
    Settings.h
    SettingsDialog.cpp
    SettingsDialog.h
    UpdateService.cpp
    UpdateService.h
    WindowsInstaller.cpp
    WindowsInstaller.h
    icons.qrc
)
if(NOT FILLR_CORE_LIBRARY)
    message(FATAL_ERROR "Set FILLR_CORE_LIBRARY to the absolute path of the built Rust library")
endif()
target_link_libraries(fillr_qt PRIVATE Qt6::Widgets Qt6::Network "${FILLR_CORE_LIBRARY}")
target_include_directories(fillr_qt PRIVATE ../macos/Sources/CFillr/include)
target_compile_definitions(fillr_qt PRIVATE FILLR_VERSION="${FILLR_VERSION}")
if(UNIX AND NOT APPLE)
    set_target_properties(fillr_qt PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "$ORIGIN")
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(LIBNOTIFY REQUIRED IMPORTED_TARGET libnotify)
    target_link_libraries(fillr_qt PRIVATE PkgConfig::LIBNOTIFY)
endif()
if(WIN32)
    string(REPLACE "." ";" FILLR_VERSION_PARTS "${FILLR_VERSION}")
    list(GET FILLR_VERSION_PARTS 0 FILLR_VERSION_MAJOR)
    list(GET FILLR_VERSION_PARTS 1 FILLR_VERSION_MINOR)
    list(GET FILLR_VERSION_PARTS 2 FILLR_VERSION_PATCH)
    configure_file(Version.rc.in "${CMAKE_CURRENT_BINARY_DIR}/Version.rc" @ONLY)
    target_sources(fillr_qt PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/Version.rc")
    target_link_libraries(fillr_qt PRIVATE windowsapp ole32 shlwapi)
endif()

include(CTest)
if(BUILD_TESTING)
    find_package(Qt6 REQUIRED COMPONENTS Test)
    add_executable(fillr_qt_tests tests.cpp SettingsDialog.cpp SettingsDialog.h Settings.cpp Settings.h)
    target_link_libraries(fillr_qt_tests PRIVATE Qt6::Widgets Qt6::Test)
    add_test(NAME fillr_qt_settings COMMAND fillr_qt_tests)
    add_executable(fillr_qt_accessibility_tests accessibility_tests.cpp SettingsDialog.cpp SettingsDialog.h)
    target_link_libraries(fillr_qt_accessibility_tests PRIVATE Qt6::Widgets Qt6::Test)
    add_test(NAME fillr_qt_accessibility COMMAND fillr_qt_accessibility_tests)
    if(UNIX AND NOT APPLE)
        set_tests_properties(fillr_qt_settings fillr_qt_accessibility PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    endif()
endif()
