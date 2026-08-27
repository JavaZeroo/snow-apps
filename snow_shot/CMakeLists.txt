cmake_minimum_required(VERSION 3.30)

project(snow_shot VERSION ${SNOW_SHOT_VERSION} LANGUAGES CXX)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
include(RustStaticLibrary)

set(CMAKE_AUTOUIC OFF)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(SNOW_SHOT_ENABLE_STRICT_COMPILE "Enable strict compiler warnings and treat warnings as errors." ON)
option(SNOW_SHOT_BUILD_TESTS "Build Snow Shot test executables." OFF)
option(SNOW_SHOT_BUILD_BENCHMARKS "Build opt-in native Snow Shot benchmarks." OFF)
option(SNOW_SHOT_RELEASE_STATIC "Prefer static Snow Shot release linkage." OFF)
option(SNOW_SHOT_QT_STATIC "Link Snow Shot against a static Qt build." OFF)
option(
    SNOW_SHOT_ENABLE_AGGRESSIVE_RELEASE_OPTIMIZATION
    "Enable aggressive compiler and linker optimizations for Release."
    ON
)

include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/ProjectWarnings.cmake")
if(SNOW_SHOT_ENABLE_STRICT_COMPILE)
    snow_enable_strict_warnings()
endif()
snow_enable_clang_tidy()

find_package(Qt6 6.11.1 EXACT REQUIRED COMPONENTS Widgets LinguistTools Svg Network)

if(SNOW_SHOT_QT_STATIC)
    if(NOT QT_FEATURE_static)
        message(FATAL_ERROR
            "SNOW_SHOT_QT_STATIC requires a static Qt 6.11.1 kit. "
            "Set SNOW_QT_STATIC_DIR or Qt6_DIR to its lib/cmake/Qt6 directory.")
    endif()
    foreach(_snow_shot_static_qt_plugin IN ITEMS
        Qt6::QWindowsIntegrationPlugin
        Qt6::QSchannelBackendPlugin
    )
        if(NOT TARGET ${_snow_shot_static_qt_plugin})
            message(FATAL_ERROR
                "The static Qt kit does not provide ${_snow_shot_static_qt_plugin}.")
        endif()
    endforeach()
    unset(_snow_shot_static_qt_plugin)
endif()

if(NOT DEFINED SNOW_SHOT_API_BASE_URL OR SNOW_SHOT_API_BASE_URL STREQUAL "")
    if(CMAKE_CONFIGURATION_TYPES)
        set(SNOW_SHOT_API_BASE_URL "https://snowshot.top" CACHE STRING
            "Snow Shot API base URL." FORCE)
    elseif(CMAKE_BUILD_TYPE STREQUAL "Debug")
        set(SNOW_SHOT_API_BASE_URL "http://localhost:8080" CACHE STRING
            "Snow Shot API base URL." FORCE)
    else()
        set(SNOW_SHOT_API_BASE_URL "https://snowshot.top" CACHE STRING
            "Snow Shot API base URL." FORCE)
    endif()
endif()
if(WIN32)
    find_package(Qt6GuiPrivate 6.11.1 EXACT REQUIRED CONFIG
        PATHS "${Qt6_DIR}/.."
        NO_DEFAULT_PATH
    )
endif()

set(SNOW_SHOT_DRAW_ENGINE_QT_DIR
    "${SNOW_DRAW_ENGINE_SOURCE_DIR}"
    CACHE PATH
    "Path to the snow_draw_engine_qt project."
)
set(SNOW_SHOT_CAPTURE_CRATES_DIR
    "${SNOW_CAPTURE_CRATES_DIR}"
    CACHE PATH
    "Path to the snow-crates workspace."
)

set(SNOW_DRAW_ENGINE_QT_BUILD_DEMO OFF CACHE BOOL "Build Snow Draw Engine Qt demo." FORCE)
if(NOT SNOW_SHOT_BUILD_TESTS)
    # Keep the production configuration free of test targets from the nested
    # draw engine project, including values left in an existing build cache.
    set(
        SNOW_DRAW_ENGINE_QT_BUILD_TESTS
        OFF
        CACHE BOOL
        "Build Snow Draw Engine Qt test executables."
        FORCE
    )
    set(
        SNOW_DRAW_ENGINE_QT_BUILD_BENCHMARKS
        OFF
        CACHE BOOL
        "Build opt-in Snow Draw Engine Qt benchmarks."
        FORCE
    )
endif()
if(NOT TARGET snow_draw_engine_qt_canvas)
    add_subdirectory("${SNOW_SHOT_DRAW_ENGINE_QT_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/snow_draw_engine_qt")
endif()

if(WIN32)
    set(SNOW_SHOT_LIBCLANG_DIR
        "${SNOW_LIBCLANG_BIN_DIR}"
        CACHE PATH
        "Directory containing libclang.dll for ffmpeg-sys bindgen."
    )
    if(EXISTS "${SNOW_SHOT_LIBCLANG_DIR}/libclang.dll")
        set(ENV{LIBCLANG_PATH} "${SNOW_SHOT_LIBCLANG_DIR}")
    endif()
endif()

snow_add_rust_static_libraries(snow_shot_rust_ffi
    MANIFEST_DIR "${SNOW_SHOT_CAPTURE_CRATES_DIR}"
    TARGETS
        snow_capture_c
        snow_ui_selector_c
        snow_stitch_images_c
        snow_ocr_c
    PACKAGES
        snow-capture-c
        snow-ui-selector-c
        snow-stitch-images-c
        snow-ocr-c
    OUTPUT_NAMES
        snow_capture_c
        snow_ui_selector_c
        snow_stitch_images_c
        snow_ocr_c
    STRIP_MSVC_DIRECTIVES
)

# `snow-stitch-images-c` is a Rust static library that embeds the generated
# OpenCV bridge objects. Cargo does not propagate the OpenCV import library to
# a native CMake consumer, so make that dependency part of its link interface.
if(DEFINED OpenCV_DIR)
    get_filename_component(_SNOW_SHOT_OPENCV_INSTALL_PREFIX
        "${OpenCV_DIR}/../.."
        ABSOLUTE
    )
    if(EXISTS "${_SNOW_SHOT_OPENCV_INSTALL_PREFIX}/include/opencv4" AND
       EXISTS "${_SNOW_SHOT_OPENCV_INSTALL_PREFIX}/share")
        list(PREPEND CMAKE_PREFIX_PATH "${_SNOW_SHOT_OPENCV_INSTALL_PREFIX}")
    endif()
endif()
if(SNOW_SHOT_RELEASE_STATIC)
    # OpenCV's Windows package dispatcher uses this variable to select the
    # x64/<runtime>/staticlib target files instead of the shared-library set.
    set(OpenCV_STATIC ON)
endif()
# OpenCV keeps its real CMake package under share/opencv4/<arch>/<runtime>/ and
# leaves a dispatcher at share/opencv4 that recomputes <arch> from the consuming
# project. On a cross build the two disagree: vcpkg builds the port with Ninja,
# where OpenCV sees no generator platform and files the ARM64 build under "x64",
# while this project configures with the Visual Studio generator and the
# dispatcher looks for "ARM64". It then reports "Found OpenCV Windows Pack but it
# has no binaries compatible with your configuration" and advises pointing
# OpenCV_DIR at the real build, which is what this does. The guard keeps the
# native builds on their existing path: there the directory the dispatcher wants
# is present, so nothing is overridden.
if(WIN32 AND CMAKE_GENERATOR_PLATFORM AND NOT DEFINED OpenCV_DIR)
    set(_snow_shot_opencv_share
        "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/share/opencv4")
    if(NOT EXISTS "${_snow_shot_opencv_share}/${CMAKE_GENERATOR_PLATFORM}")
        set(_snow_shot_opencv_lib_dirs "lib" "staticlib")
        if(OpenCV_STATIC)
            set(_snow_shot_opencv_lib_dirs "staticlib" "lib")
        endif()
        foreach(_snow_shot_opencv_lib_dir IN LISTS _snow_shot_opencv_lib_dirs)
            file(GLOB _snow_shot_opencv_configs
                "${_snow_shot_opencv_share}/*/*/${_snow_shot_opencv_lib_dir}/OpenCVConfig.cmake")
            if(_snow_shot_opencv_configs)
                list(GET _snow_shot_opencv_configs 0 _snow_shot_opencv_config)
                get_filename_component(OpenCV_DIR "${_snow_shot_opencv_config}" DIRECTORY)
                message(STATUS
                    "Snow Shot: using the OpenCV package built for this triplet at ${OpenCV_DIR}")
                break()
            endif()
        endforeach()
        unset(_snow_shot_opencv_config)
        unset(_snow_shot_opencv_configs)
        unset(_snow_shot_opencv_lib_dir)
        unset(_snow_shot_opencv_lib_dirs)
    endif()
    unset(_snow_shot_opencv_share)
endif()
find_package(OpenCV CONFIG REQUIRED COMPONENTS core imgproc dnn objdetect wechat_qrcode)
find_package(onnxruntime CONFIG REQUIRED)

if(WIN32)
    set(SNOW_SHOT_DIRECTML_RUNTIME_DLL_DEBUG
        "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/debug/bin/DirectML.dll")
    set(SNOW_SHOT_DIRECTML_RUNTIME_DLL_RELEASE
        "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin/DirectML.dll")
    foreach(_snow_shot_directml_runtime IN ITEMS
            "${SNOW_SHOT_DIRECTML_RUNTIME_DLL_DEBUG}"
            "${SNOW_SHOT_DIRECTML_RUNTIME_DLL_RELEASE}")
        if(NOT EXISTS "${_snow_shot_directml_runtime}")
            message(FATAL_ERROR
                "The DirectML-enabled ONNX Runtime package is incomplete: "
                "${_snow_shot_directml_runtime} was not found.")
        endif()
    endforeach()
    unset(_snow_shot_directml_runtime)
endif()

target_link_libraries(snow_stitch_images_c INTERFACE opencv_wechat_qrcode)
target_link_libraries(snow_ocr_c INTERFACE onnxruntime::onnxruntime)

set(SNOW_SHOT_SNOW_IMAGE_DIR
    "${SNOW_IMAGE_SOURCE_DIR}"
    CACHE PATH
    "Path to the snow_image project used by Snow Shot."
)
if(NOT TARGET snow_image::snow_image)
    set(SNOW_IMAGE_BUILD_TESTS OFF CACHE BOOL "Build snow_image tests." FORCE)
    set(SNOW_IMAGE_BUILD_SHARED OFF CACHE BOOL "Build the shared snow_image library." FORCE)
    set(SNOW_IMAGE_BUILD_STATIC ON CACHE BOOL "Build the static snow_image library." FORCE)
    set(SNOW_IMAGE_CODEC_PNG ON CACHE BOOL "Enable the libpng codec." FORCE)
    set(SNOW_IMAGE_CODEC_WEBP ON CACHE BOOL "Enable WebP codecs." FORCE)
    add_subdirectory("${SNOW_SHOT_SNOW_IMAGE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/snow_image")
endif()

set(SNOW_SHOT_IMAGE_CODEC_SOURCES
    src/image/snowimageqtcodec.h
    src/image/snowimageqtcodec.cpp
)
add_library(snow_shot_image_codec STATIC ${SNOW_SHOT_IMAGE_CODEC_SOURCES})
snow_enable_unity_build(snow_shot_image_codec)
target_include_directories(snow_shot_image_codec PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/src/image"
)
target_link_libraries(snow_shot_image_codec PUBLIC
    snow_image::snow_image
    Qt6::Core
    Qt6::Gui
)
target_compile_features(snow_shot_image_codec PUBLIC cxx_std_20)

set(
    SNOW_SHOT_ADQT_DIR
    "${SNOW_ANT_DESIGN_SOURCE_DIR}"
    CACHE PATH
    "Path to the ant_design_qt source tree for standalone builds."
)

if(NOT EXISTS "${SNOW_SHOT_ADQT_DIR}/packages/ant_design_qt")
    message(
        FATAL_ERROR
        "Unable to locate ant_design_qt. Set SNOW_SHOT_ADQT_DIR to an external source tree for a standalone build."
    )
endif()

set(ADQT_ICON_CORE_DIR "${SNOW_SHOT_ADQT_DIR}/packages/adqt_icon_core")
set(ANT_DESIGN_ICONS_QT_DIR "${SNOW_SHOT_ADQT_DIR}/packages/ant_design_icons_qt")
set(ANT_DESIGN_QT_DIR "${SNOW_SHOT_ADQT_DIR}/packages/ant_design_qt")

if(NOT TARGET adqt::widgets)
    add_subdirectory("${SNOW_SHOT_ADQT_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/ant_design_qt")
endif()

set(SNOW_SHOT_STORAGE_SOURCES
    include/snow_shot/storage/applicationstorage.h
    include/snow_shot/storage/capturehistoryrepository.h
    include/snow_shot/storage/capturehistorytypes.h
    include/snow_shot/storage/configurationstore.h
    include/snow_shot/storage/configurationschema.h
    include/snow_shot/storage/persistedselectioncodec.h
    include/snow_shot/storage/settingsadapters.h
    include/snow_shot/storage/storagelogging.h
    include/snow_shot/storage/storageresult.h
    src/storage/applicationstorage.cpp
    src/storage/capturehistorypolicy_p.h
    src/storage/capturehistoryrepository.cpp
    src/storage/configurationstore.cpp
    src/storage/configurationschema.cpp
    src/storage/persistedselectioncodec.cpp
    src/storage/settingsadapters.cpp
    src/storage/storagelogging.cpp
)
add_library(snow_shot_storage STATIC ${SNOW_SHOT_STORAGE_SOURCES})
snow_enable_unity_build(snow_shot_storage)
target_include_directories(snow_shot_storage PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(snow_shot_storage PUBLIC
    snow_shot_image_codec
    Qt6::Core
    Qt6::Gui
)

set(QT_I18N_SOURCE_LANGUAGE en_US)
file(GLOB TS_FILES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/i18n/snow_shot_*.ts"
)
list(SORT TS_FILES)

function(snow_shot_add_translations target)
    if(target STREQUAL "snow_shot")
        set(_lupdate_target snow_shot_update_translations)
        set(_lrelease_target snow_shot_release_translations)
        set(_translation_source_targets
            ${target}
            snow_shot_settings_catalog
            snow_shot_settings_search
            snow_shot_settings
        )
    else()
        set(_lupdate_target "${target}_update_translations")
        set(_lrelease_target "${target}_release_translations")
        set(_translation_source_targets ${target})
    endif()

    qt_add_translations(
        ${target}
        TS_FILES ${TS_FILES}
        SOURCE_TARGETS ${_translation_source_targets}
        RESOURCE_PREFIX "/i18n"
        MERGE_QT_TRANSLATIONS
        LUPDATE_TARGET ${_lupdate_target}
        LUPDATE_OPTIONS -no-obsolete
        LRELEASE_TARGET ${_lrelease_target}
        LRELEASE_OPTIONS -fail-on-unfinished
    )
endfunction()

set(SNOW_SHOT_SETTINGS_CATALOG_SOURCES
    include/snow_shot/presentation/settings/settingscatalog.h
    src/presentation/components/icons/snowshoticons.cpp
    src/presentation/settings/settingscatalog.cpp
)
add_library(snow_shot_settings_catalog STATIC ${SNOW_SHOT_SETTINGS_CATALOG_SOURCES})
snow_enable_unity_build(snow_shot_settings_catalog)
target_include_directories(snow_shot_settings_catalog PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(snow_shot_settings_catalog PUBLIC
    ant_design_icons_qt
    Qt6::Widgets
)

set(SNOW_SHOT_SETTINGS_SEARCH_SOURCES
    include/snow_shot/presentation/components/applicationsearchwidget.h
    include/snow_shot/presentation/languagemanager.h
    include/snow_shot/presentation/settings/settingssearchindex.h
    src/presentation/components/applicationsearchwidget.cpp
    src/presentation/services/languagemanager.cpp
    src/presentation/settings/settingssearchindex.cpp
)
add_library(snow_shot_settings_search STATIC ${SNOW_SHOT_SETTINGS_SEARCH_SOURCES})
snow_enable_unity_build(snow_shot_settings_search)
target_include_directories(snow_shot_settings_search PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(snow_shot_settings_search PUBLIC
    ant_design_icons_qt
    ant_design_qt
    snow_shot_settings_catalog
    snow_shot_storage
    Qt6::Widgets
)

set(SNOW_SHOT_SETTINGS_SOURCES
    include/snow_shot/presentation/globalshortcutmanager.h
    include/snow_shot/presentation/components/infotooltipicon.h
    include/snow_shot/presentation/components/pagecontainerwidget.h
    include/snow_shot/presentation/components/sectionheaderwidget.h
    include/snow_shot/presentation/components/screenshothistorypagewidget.h
    include/snow_shot/presentation/components/settingscustomwidget.h
    include/snow_shot/presentation/components/settingspagewidget.h
    include/snow_shot/presentation/components/shortcutkeyrow.h
    include/snow_shot/presentation/components/storagestatussettingswidget.h
    include/snow_shot/presentation/settings/settingsruntimebindings.h
    include/snow_shot/presentation/settings/applicationpriority.h
    include/snow_shot/presentation/settings/textrecognitionacceleration.h
    include/snow_shot/presentation/styles/thememanager.h
    src/presentation/components/infotooltipicon.cpp
    src/presentation/components/pagecontainerwidget.cpp
    src/presentation/components/sectionheaderwidget.cpp
    src/presentation/components/screenshothistorypagewidget.cpp
    src/presentation/components/settingscustomwidget.cpp
    src/presentation/components/settingspagewidget.cpp
    src/presentation/components/shortcutkeyrow.cpp
    src/presentation/components/storagestatussettingswidget.cpp
    src/presentation/services/globalshortcutmanager.cpp
    src/presentation/settings/settingsruntimebindings.cpp
    src/presentation/settings/applicationpriority.cpp
    src/presentation/settings/textrecognitionacceleration.cpp
    src/presentation/styles/buttonborder.cpp
    src/presentation/styles/mainwindowcomponenttoken.cpp
    src/presentation/styles/themecolorscheme.cpp
    src/presentation/styles/thememanager.cpp
)
add_library(snow_shot_settings STATIC ${SNOW_SHOT_SETTINGS_SOURCES})
snow_enable_unity_build(snow_shot_settings)
target_include_directories(snow_shot_settings PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(snow_shot_settings PRIVATE
    "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-ocr-c/include"
)
target_link_libraries(snow_shot_settings PUBLIC
    ant_design_icons_qt
    ant_design_qt
    snow_shot_settings_search
    snow_shot_storage
    snow_ocr_c
    Qt6::Widgets
)
if(WIN32)
    target_link_libraries(snow_shot_settings PUBLIC user32 bcrypt ntdll)
endif()

set(PROJECT_HEADERS
    include/snow_shot/network/snowshotapiclient.h
    include/snow_shot/presentation/screenshottabledocument.h
    include/snow_shot/presentation/screenshottableeditor.h
    include/snow_shot/app/applicationcontroller.h
    include/snow_shot/app/singleinstancecoordinator.h
    include/snow_shot/platform/windows/windowchrome.h
    include/snow_shot/presentation/components/contentcardwidget.h
    include/snow_shot/presentation/components/maincontentheaderwidget.h
    include/snow_shot/presentation/components/icons/snowshoticons.h
    include/snow_shot/presentation/components/settingspageutils.h
    include/snow_shot/presentation/components/sidebarwidget.h
    include/snow_shot/presentation/components/titlebarwidget.h
    include/snow_shot/presentation/mainwindow.h
    include/snow_shot/presentation/screenshotcapturecoordinator.h
    include/snow_shot/presentation/screenshotcapturedisplaymodelreconciler.h
    include/snow_shot/presentation/screenshotcaptureruntimeadapter.h
    include/snow_shot/presentation/screenshotcapturestate.h
    include/snow_shot/presentation/screenshotcaptureworkflow.h
    include/snow_shot/presentation/screenshotcaptureworkflowports.h
    include/snow_shot/presentation/screenshotcanvasrenderer.h
    include/snow_shot/presentation/screenshotclipboardservice.h
    include/snow_shot/presentation/screenshotresultcompositor.h
    include/snow_shot/presentation/screenshotselectionshadowrenderer.h
    include/snow_shot/presentation/screenshotcolorpickercontroller.h
    include/snow_shot/presentation/screenshotcolorpickerwidget.h
    include/snow_shot/presentation/screenshotcontroller.h
    include/snow_shot/presentation/screenshotdefaultstyles.h
    include/snow_shot/presentation/screenshotdisplayconfigurationobserver.h
    include/snow_shot/presentation/screenshotdisplaysession.h
    include/snow_shot/presentation/screenshotexportservice.h
    include/snow_shot/presentation/screenshotfloatingtoolpalettewindow.h
    include/snow_shot/presentation/screenshotgeometry.h
    include/snow_shot/presentation/screenshothistoryservice.h
    include/snow_shot/presentation/screenshothistorytypes.h
    include/snow_shot/presentation/screenshotintelligentselectionmodel.h
    include/snow_shot/presentation/screenshotinteractionstate.h
    include/snow_shot/presentation/screenshotocrcontroller.h
    include/snow_shot/presentation/screenshotocrrecognitionservice.h
    include/snow_shot/presentation/screenshotqrrecognitionservice.h
    include/snow_shot/presentation/screenshotmessageservice.h
    include/snow_shot/presentation/screenshotocrpresentation.h
    include/snow_shot/presentation/screenshotocrtexteditingsession.h
    include/snow_shot/presentation/screenshotocrtextlayer.h
    include/snow_shot/presentation/screenshotrecognitionwindow.h
    include/snow_shot/presentation/screenshotrecognitionsessioncontroller.h
    include/snow_shot/presentation/screenshotpinnededitcontroller.h
    include/snow_shot/presentation/screenshotpinnedcopyservice.h
    include/snow_shot/presentation/screenshotpinnedwindow.h
    include/snow_shot/presentation/screenshotpresentationservices.h
    include/snow_shot/presentation/screenshotsmartselectiontransition.h
    include/snow_shot/presentation/screenshotselectioneditworkflow.h
    include/snow_shot/presentation/screenshotselectioneditworkflowports.h
    include/snow_shot/presentation/screenshotselectionexportworkflow.h
    include/snow_shot/presentation/screenshotselectionexportworkflowports.h
    include/snow_shot/presentation/screenshotselectionexportuiservices.h
    include/snow_shot/presentation/screenshotselectiongeometry.h
    include/snow_shot/presentation/screenshotselectionlimits.h
    include/snow_shot/presentation/screenshotselectionmodel.h
    include/snow_shot/presentation/screenshotselectionparams.h
    include/snow_shot/presentation/screenshotselectionresizemodalcontent.h
    include/snow_shot/presentation/screenshotselectionresizeworkflow.h
    include/snow_shot/presentation/screenshotselectionsettingsstore.h
    include/snow_shot/presentation/screenshotsourceimagecomposer.h
    include/snow_shot/presentation/screenshotselectiontoolbarwindow.h
    include/snow_shot/presentation/screenshotscrollingcapturecontroller.h
    include/snow_shot/presentation/screenshotscrollingtypes.h
    include/snow_shot/presentation/screenshotscrollingthumbnailwidget.h
    include/snow_shot/presentation/screenshotoverlaycanvaspresenter.h
    include/snow_shot/presentation/screenshotoverlaycoordinator.h
    include/snow_shot/presentation/screenshotoverlayeventsink.h
    include/snow_shot/presentation/screenshotoverlayinteractionadapter.h
    include/snow_shot/presentation/screenshotoverlayinputhandler.h
    include/snow_shot/presentation/screenshotoverlaypool.h
    include/snow_shot/presentation/screenshotoverlayuihost.h
    include/snow_shot/presentation/screenshotoverlaywindow.h
    include/snow_shot/presentation/screenshotselectorcoordinator.h
    src/presentation/selector/screenshotselectorpolicy.h
    include/snow_shot/presentation/screenshotselectorworkflow.h
    include/snow_shot/presentation/screenshotselectorworkflowports.h
    include/snow_shot/presentation/screenshottoolbarcommands.h
    include/snow_shot/presentation/screenshottoolbarpresenter.h
    include/snow_shot/presentation/screenshottoolbarpresentationstatefactory.h
    include/snow_shot/presentation/screenshottoolcommandworkflow.h
    include/snow_shot/presentation/screenshottoolcommandworkflowports.h
    include/snow_shot/presentation/screenshottoolbarmainpanel.h
    include/snow_shot/presentation/screenshottoolpalette.h
    include/snow_shot/presentation/screenshottoolpalettehost.h
    include/snow_shot/presentation/screenshottoolbarwindow.h
    include/snow_shot/presentation/screenshottypes.h
    include/snow_shot/presentation/videorecordingareawindow.h
    include/snow_shot/presentation/videorecordingcontroller.h
    include/snow_shot/presentation/videorecordingtoolbarwindow.h
    include/snow_shot/presentation/styles/mainwindowcomponenttoken.h
    include/snow_shot/presentation/styles/buttonborder.h
    include/snow_shot/presentation/styles/floatingcontroltoolbarstyle.h
    include/snow_shot/presentation/styles/themecolorscheme.h
    include/snow_shot/presentation/systemtraycontroller.h
)

set(PROJECT_CXX_SOURCES
    src/app/applicationcontroller.cpp
    src/app/main.cpp
    src/app/singleinstancecoordinator.cpp
    src/platform/windows/windowchrome.cpp
    src/presentation/components/contentcardwidget.cpp
    src/presentation/components/maincontentheaderwidget.cpp
    src/presentation/components/sidebarwidget.cpp
    src/presentation/components/titlebarwidget.cpp
    src/presentation/mainwindow.cpp
    src/presentation/capture/screenshotcapturecoordinator.cpp
    src/presentation/capture/screenshotcapturedisplaymodelreconciler.cpp
    src/presentation/capture/screenshotcaptureruntimeadapter.cpp
    src/presentation/capture/screenshotcaptureworker.cpp
    src/presentation/capture/screenshotcaptureworkflow.cpp
    src/presentation/capture/adaptivescrollingcapturecadence.h
    src/presentation/capture/latestbridgemailbox.h
    src/presentation/capture/screenshotscrollingcapturecontroller.cpp
    src/presentation/capture/screenshotscrollingthumbnailwidget.cpp
    src/presentation/services/screenshotcolorpickercontroller.cpp
    src/presentation/services/screenshotclipboardservice.cpp
    src/network/snowshotapiclient.cpp
    src/presentation/services/screenshotcolorpickerwidget.cpp
    src/presentation/services/screenshotcontroller.cpp
    src/presentation/services/screenshotmessageservice.cpp
    src/presentation/services/screenshothistoryservice.cpp
    src/presentation/services/screenshotdisplayconfigurationobserver.cpp
    src/presentation/services/screenshotexportservice.cpp
    src/presentation/tools/screenshotfloatingtoolpalettenative.cpp
    src/presentation/tools/screenshotfloatingtoolpalettewindow.cpp
    src/presentation/core/screenshotgeometry.cpp
    src/presentation/core/screenshotintelligentselectionmodel.cpp
    src/presentation/core/screenshotinteractionstate.cpp
    src/presentation/core/screenshotsmartselectiontransition.cpp
    src/presentation/ocr/screenshotocrcontroller.cpp
    src/presentation/ocr/screenshotrecognitionsessioncontroller.cpp
    src/presentation/ocr/screenshotrecognitionwindow.cpp
    src/presentation/ocr/screenshottabledocument.cpp
    src/presentation/ocr/screenshottableeditor.cpp
    src/presentation/ocr/screenshotocrtexttransform.cpp
    src/presentation/ocr/screenshotocrrecognitionservice.cpp
    src/presentation/ocr/screenshotqrrecognitionservice.cpp
    src/presentation/ocr/screenshotocrpresentation.cpp
    src/presentation/ocr/screenshotocrtexteditingsession.cpp
    src/presentation/pinned/screenshotpinnednativegeometrycontroller.cpp
    src/presentation/pinned/screenshotpinnednativegeometrycontroller.h
    src/presentation/pinned/screenshotpinnedcopyservice.cpp
    src/presentation/pinned/screenshotpinnedwindownative.cpp
    src/presentation/pinned/screenshotpinnededitcontroller.cpp
    src/presentation/pinned/screenshotpinnedresizegeometry.cpp
    src/presentation/pinned/screenshotpinnedwindow.cpp
    src/presentation/pinned/screenshotpintoperfinstrumentation.cpp
    src/presentation/services/screenshotpresentationservices.cpp
    src/presentation/services/screenshotsourceimagecomposer.cpp
    src/presentation/services/systemtraycontroller.cpp
    src/presentation/selection/screenshotselectioneditworkflow.cpp
    src/presentation/selection/screenshotselectionexportworkflow.cpp
    src/presentation/selection/screenshotselectionexportuiservices.cpp
    src/presentation/selection/screenshotselectiongeometry.cpp
    src/presentation/selection/screenshotselectionmodel.cpp
    src/presentation/selection/screenshotselectionparams.cpp
    src/presentation/selection/screenshotselectionresizemodalcontent.cpp
    src/presentation/selection/screenshotselectionresizeworkflow.cpp
    src/presentation/selection/screenshotselectionsettingsstore.cpp
    src/presentation/selection/screenshotselectiontoolbarwindow.cpp
    src/presentation/selection/screenshotselectiontoolbarwidgets.cpp
    src/presentation/overlay/screenshotoverlaycanvaspresenter.cpp
    src/presentation/overlay/screenshotcanvasrenderer.cpp
    src/presentation/overlay/screenshotselectionshadowrenderer.cpp
    src/presentation/overlay/screenshotoverlaycoordinator.cpp
    src/presentation/overlay/screenshotoverlayinteractionadapter.cpp
    src/presentation/overlay/screenshotoverlayinputhandler.cpp
    src/presentation/overlay/screenshotoverlaypool.cpp
    src/presentation/overlay/screenshotoverlayuihost.cpp
    src/presentation/overlay/screenshotoverlaywindow.cpp
    src/presentation/selector/screenshotselectorserviceclient.cpp
    src/presentation/selector/screenshotselectorcoordinator.cpp
    src/presentation/selector/screenshotselectorworkflow.cpp
    src/presentation/toolbar/screenshottoolbarpresenter.cpp
    src/presentation/toolbar/screenshottoolbarpresentationstatefactory.cpp
    src/presentation/tools/screenshottoolcommandworkflow.cpp
    src/presentation/tools/screenshottoolbarmainpanel.cpp
    src/presentation/tools/screenshottoolpalettebuttons.cpp
    src/presentation/tools/screenshottoolpalettestylecontrols.cpp
    src/presentation/tools/screenshottoolpalettestylemodel.cpp
    src/presentation/tools/screenshottoolpalette.cpp
    src/presentation/tools/screenshottoolpalettehost.cpp
    src/presentation/toolbar/screenshottoolbarwindow.cpp
    src/presentation/recording/videorecordingareawindow.cpp
    src/presentation/recording/videorecordingcontroller.cpp
    src/presentation/recording/videorecordinggeometry.cpp
    src/presentation/recording/videorecordingtoolbarwindow.cpp
    src/presentation/styles/floatingcontroltoolbarstyle.cpp
)

set(PROJECT_RCC_SOURCES)

set(PROJECT_SOURCES
    ${PROJECT_CXX_SOURCES}
    ${PROJECT_HEADERS}
    ${PROJECT_RCC_SOURCES}
    ${TS_FILES}
)

qt_add_executable(snow_shot
    MANUAL_FINALIZATION
    ${PROJECT_SOURCES}
)

if(WIN32)
    configure_file(
        resources/windows-app-resource.rc.in
        "${CMAKE_CURRENT_BINARY_DIR}/generated/windows-app-resource.rc"
        @ONLY
    )
    target_sources(snow_shot PRIVATE
        resources/app-icon.ico
        "${CMAKE_CURRENT_BINARY_DIR}/generated/windows-app-resource.rc"
    )
endif()

target_compile_definitions(snow_shot PRIVATE
    SNOW_SHOT_API_BASE_URL=\"${SNOW_SHOT_API_BASE_URL}\"
)
if(MSVC AND TARGET Qt6::BundledLibpng)
    # Snow Image also links libpng. Load the implementation used to build
    # static Qt first so Qt's PNG image handler cannot bind to another ABI.
    target_link_libraries(snow_shot PRIVATE
        "$<LINK_LIBRARY:WHOLE_ARCHIVE,Qt6::BundledLibpng>"
    )
endif()
target_link_libraries(snow_shot PRIVATE snow_shot_image_codec)

qt_add_resources(snow_shot "snow_shot_app_assets"
    PREFIX "/snow-shot/app-icons"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/resources"
    FILES
        "${CMAKE_CURRENT_SOURCE_DIR}/resources/snow-shot-tray-default.png"
)

if(SNOW_SHOT_BUILD_TESTS)
    if(DEFINED CMAKE_RUNTIME_OUTPUT_DIRECTORY)
        set(_SNOW_SHOT_RUNTIME_OUTPUT_DIRECTORY_WAS_DEFINED TRUE)
        set(
            _SNOW_SHOT_SAVED_RUNTIME_OUTPUT_DIRECTORY
            "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}"
        )
    else()
        set(_SNOW_SHOT_RUNTIME_OUTPUT_DIRECTORY_WAS_DEFINED FALSE)
    endif()
    set(
        CMAKE_RUNTIME_OUTPUT_DIRECTORY
        "${CMAKE_CURRENT_BINARY_DIR}/test-bin"
    )

    enable_testing()

    add_executable(snow-shot-application-storage-tests
        tests/application_storage_tests.cpp
    )
    target_link_libraries(snow-shot-application-storage-tests PRIVATE snow_shot_storage Qt6::Core)
    add_test(NAME snow-shot-application-storage-tests
             COMMAND snow-shot-application-storage-tests)
    set_tests_properties(snow-shot-application-storage-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-capture-history-repository-tests
        tests/capture_history_repository_tests.cpp
    )
    target_link_libraries(snow-shot-capture-history-repository-tests PRIVATE
        snow_shot_storage
        Qt6::Core
        Qt6::Gui
    )
    add_test(NAME snow-shot-capture-history-repository-tests
             COMMAND snow-shot-capture-history-repository-tests)
    set_tests_properties(snow-shot-capture-history-repository-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-single-instance-coordinator-tests
        tests/single_instance_coordinator_tests.cpp
        include/snow_shot/app/singleinstancecoordinator.h
        src/app/singleinstancecoordinator.cpp
    )
    target_include_directories(snow-shot-single-instance-coordinator-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-single-instance-coordinator-tests PRIVATE
        Qt6::Core
        Qt6::Network
    )
    add_test(NAME snow-shot-single-instance-coordinator-tests
             COMMAND snow-shot-single-instance-coordinator-tests)
    set_tests_properties(snow-shot-single-instance-coordinator-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_test(NAME snow-shot-storage-boundary-check
        COMMAND ${CMAKE_COMMAND}
            -DSNOW_SHOT_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/scripts/check_storage_boundary.cmake
    )

    add_executable(snow-shot-screenshot-result-compositor-tests
        tests/screenshot_result_compositor_tests.cpp
        include/snow_shot/presentation/screenshotclipboardservice.h
        include/snow_shot/presentation/screenshotresultcompositor.h
        include/snow_shot/presentation/screenshotselectionshadowrenderer.h
        src/presentation/overlay/screenshotselectionshadowrenderer.cpp
        src/presentation/services/screenshotclipboardservice.cpp
    )
    target_include_directories(snow-shot-screenshot-result-compositor-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-screenshot-result-compositor-tests PRIVATE
        Qt6::Widgets
    )
    if(WIN32)
        target_link_libraries(snow-shot-screenshot-result-compositor-tests PRIVATE user32)
    endif()
    add_test(NAME snow-shot-screenshot-result-compositor-tests
             COMMAND snow-shot-screenshot-result-compositor-tests)

    add_executable(snow-shot-screenshot-result-geometry-tests
        tests/screenshot_result_geometry_tests.cpp
        src/presentation/core/screenshotgeometry.cpp
    )
    target_include_directories(snow-shot-screenshot-result-geometry-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-screenshot-result-geometry-tests PRIVATE Qt6::Widgets)
    add_test(NAME snow-shot-screenshot-result-geometry-tests
             COMMAND snow-shot-screenshot-result-geometry-tests)

    add_executable(snow-shot-i18n-catalog-conformance-tests
        tests/i18n_catalog_conformance_tests.cpp
    )
    target_link_libraries(snow-shot-i18n-catalog-conformance-tests PRIVATE
        Qt6::Core
    )
    add_test(
        NAME snow-shot-i18n-catalog-conformance-tests
        COMMAND snow-shot-i18n-catalog-conformance-tests
            "${CMAKE_CURRENT_SOURCE_DIR}"
            "$<TARGET_FILE:Qt6::lupdate>"
            ${TS_FILES}
    )
    set_tests_properties(snow-shot-i18n-catalog-conformance-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-language-manager-tests
        tests/language_manager_tests.cpp
        include/snow_shot/presentation/languagemanager.h
        src/presentation/services/languagemanager.cpp
    )
    target_include_directories(snow-shot-language-manager-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-language-manager-tests PRIVATE
        ant_design_qt
        Qt6::Widgets
    )
    snow_shot_add_translations(snow-shot-language-manager-tests)
    add_test(
        NAME snow-shot-language-manager-tests
        COMMAND snow-shot-language-manager-tests
    )
    set_tests_properties(snow-shot-language-manager-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-settings-catalog-tests
        tests/settings_catalog_tests.cpp
    )
    target_include_directories(snow-shot-settings-catalog-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-settings-catalog-tests PRIVATE
        snow_shot_settings_search
        Qt6::Core
    )
    add_test(NAME snow-shot-settings-catalog-tests
             COMMAND snow-shot-settings-catalog-tests)
    set_tests_properties(snow-shot-settings-catalog-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-settings-page-tests
        tests/settings_page_tests.cpp
        include/snow_shot/presentation/components/contentcardwidget.h
        include/snow_shot/presentation/components/maincontentheaderwidget.h
        include/snow_shot/presentation/components/sidebarwidget.h
        src/presentation/components/contentcardwidget.cpp
        src/presentation/components/maincontentheaderwidget.cpp
        src/presentation/components/sidebarwidget.cpp
    )
    target_include_directories(snow-shot-settings-page-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-settings-page-tests PRIVATE
        snow_shot_settings
        Qt6::Widgets
    )
    add_test(NAME snow-shot-settings-page-tests
             COMMAND snow-shot-settings-page-tests)
    set_tests_properties(snow-shot-settings-page-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-selector-policy-tests
        tests/screenshot_selector_policy_tests.cpp
        src/presentation/selector/screenshotselectorpolicy.h
    )
    target_include_directories(snow-shot-selector-policy-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src/presentation/selector"
        "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-ui-selector-c/include"
    )
    target_link_libraries(snow-shot-selector-policy-tests PRIVATE
        Qt6::Core
    )
    add_test(NAME snow-shot-selector-policy-tests
             COMMAND snow-shot-selector-policy-tests)
    set_tests_properties(snow-shot-selector-policy-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-system-tray-controller-tests
        tests/system_tray_controller_tests.cpp
        include/snow_shot/presentation/languagemanager.h
        include/snow_shot/presentation/systemtraycontroller.h
        src/presentation/services/languagemanager.cpp
        src/presentation/services/systemtraycontroller.cpp
    )
    target_include_directories(snow-shot-system-tray-controller-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-system-tray-controller-tests PRIVATE
        ant_design_qt
        Qt6::Widgets
    )
    qt_add_resources(snow-shot-system-tray-controller-tests "snow_shot_tray_test_assets"
        PREFIX "/snow-shot/app-icons"
        BASE "${CMAKE_CURRENT_SOURCE_DIR}/resources"
        FILES
            "${CMAKE_CURRENT_SOURCE_DIR}/resources/snow-shot-tray-default.png"
    )
    snow_shot_add_translations(snow-shot-system-tray-controller-tests)
    add_test(
        NAME snow-shot-system-tray-controller-tests
        COMMAND snow-shot-system-tray-controller-tests
    )
    if(WIN32)
        set_tests_properties(snow-shot-system-tray-controller-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=windows;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QWindowsIntegrationPlugin>"
            ENVIRONMENT_MODIFICATION
                "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )
    else()
        set_tests_properties(snow-shot-system-tray-controller-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
            ENVIRONMENT_MODIFICATION
                "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )
    endif()

    add_executable(snow-shot-context-menu-rendering-tests
        tests/context_menu_rendering_tests.cpp
    )
    target_link_libraries(snow-shot-context-menu-rendering-tests PRIVATE
        ant_design_qt
        Qt6::Widgets
    )
    add_test(
        NAME snow-shot-context-menu-rendering-tests
        COMMAND snow-shot-context-menu-rendering-tests
    )
    if(WIN32)
        set_tests_properties(snow-shot-context-menu-rendering-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=windows;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QWindowsIntegrationPlugin>"
            ENVIRONMENT_MODIFICATION
                "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )
    else()
        set_tests_properties(snow-shot-context-menu-rendering-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
            ENVIRONMENT_MODIFICATION
                "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )
    endif()

    add_executable(snow-shot-global-shortcut-manager-tests
        tests/global_shortcut_manager_tests.cpp
        include/snow_shot/presentation/globalshortcutmanager.h
        src/presentation/services/globalshortcutmanager.cpp
    )
    target_include_directories(snow-shot-global-shortcut-manager-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-global-shortcut-manager-tests PRIVATE
        Qt6::Widgets
    )
    if(WIN32)
        target_link_libraries(snow-shot-global-shortcut-manager-tests PRIVATE user32)
    endif()
    add_test(
        NAME snow-shot-global-shortcut-manager-tests
        COMMAND snow-shot-global-shortcut-manager-tests
    )

    add_executable(snow-shot-shortcut-key-row-tests
        tests/shortcut_key_row_tests.cpp
        include/snow_shot/presentation/components/infotooltipicon.h
        include/snow_shot/presentation/components/shortcutkeyrow.h
        include/snow_shot/presentation/styles/buttonborder.h
        include/snow_shot/presentation/styles/mainwindowcomponenttoken.h
        include/snow_shot/presentation/styles/thememanager.h
        include/snow_shot/presentation/styles/themecolorscheme.h
        src/presentation/components/icons/snowshoticons.cpp
        src/presentation/components/infotooltipicon.cpp
        src/presentation/components/shortcutkeyrow.cpp
        src/presentation/styles/buttonborder.cpp
        src/presentation/styles/mainwindowcomponenttoken.cpp
        src/presentation/styles/thememanager.cpp
        src/presentation/styles/themecolorscheme.cpp
    )
    target_include_directories(snow-shot-shortcut-key-row-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-shortcut-key-row-tests PRIVATE
        adqt_icon_core
        ant_design_icons_qt
        ant_design_qt
        Qt6::Widgets
    )
    add_test(
        NAME snow-shot-shortcut-key-row-tests
        COMMAND snow-shot-shortcut-key-row-tests
    )
    set_tests_properties(snow-shot-shortcut-key-row-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-form-layout-tests
        tests/form_layout_tests.cpp
        include/snow_shot/presentation/screenshotselectionresizemodalcontent.h
        src/presentation/components/icons/snowshoticons.cpp
        src/presentation/selection/screenshotselectionresizemodalcontent.cpp
        src/presentation/selection/screenshotselectionparams.cpp
    )
    target_link_libraries(snow-shot-form-layout-tests PRIVATE
        ant_design_qt
        Qt6::Widgets
    )
    target_include_directories(snow-shot-form-layout-tests PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    )
    add_test(
        NAME snow-shot-form-layout-tests
        COMMAND snow-shot-form-layout-tests
    )
    set_tests_properties(snow-shot-form-layout-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-selection-resize-workflow-tests
        tests/screenshot_selection_resize_workflow_tests.cpp
        include/snow_shot/presentation/screenshotselectioneditworkflowports.h
        include/snow_shot/presentation/languagemanager.h
        include/snow_shot/presentation/screenshotselectionresizemodalcontent.h
        include/snow_shot/presentation/screenshotselectionresizeworkflow.h
        include/snow_shot/presentation/screenshotselectionsettingsstore.h
        src/presentation/components/icons/snowshoticons.cpp
        src/presentation/services/languagemanager.cpp
        src/presentation/selection/screenshotselectionparams.cpp
        src/presentation/selection/screenshotselectionresizemodalcontent.cpp
        src/presentation/selection/screenshotselectionresizeworkflow.cpp
        src/presentation/selection/screenshotselectionsettingsstore.cpp
    )
    target_include_directories(snow-shot-selection-resize-workflow-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-selection-resize-workflow-tests PRIVATE
        ant_design_qt
        Qt6::Widgets
    )
    snow_shot_add_translations(snow-shot-selection-resize-workflow-tests)
    add_test(
        NAME snow-shot-selection-resize-workflow-tests
        COMMAND snow-shot-selection-resize-workflow-tests
    )
    set_tests_properties(snow-shot-selection-resize-workflow-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-capture-workflow-tests
        tests/screenshot_capture_workflow_tests.cpp
        include/snow_shot/presentation/screenshotcapturedisplaymodelreconciler.h
        include/snow_shot/presentation/screenshotcapturestate.h
        include/snow_shot/presentation/screenshotcaptureworkflow.h
        include/snow_shot/presentation/screenshotcaptureworkflowports.h
        include/snow_shot/presentation/screenshotdisplaysession.h
        include/snow_shot/presentation/screenshotgeometry.h
        include/snow_shot/presentation/screenshotintelligentselectionmodel.h
        include/snow_shot/presentation/screenshotinteractionstate.h
        include/snow_shot/presentation/screenshotselectiongeometry.h
        include/snow_shot/presentation/screenshotselectionmodel.h
        include/snow_shot/presentation/screenshotselectionparams.h
        src/presentation/capture/screenshotcapturedisplaymodelreconciler.cpp
        src/presentation/capture/screenshotcaptureworkflow.cpp
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/core/screenshotintelligentselectionmodel.cpp
        src/presentation/core/screenshotinteractionstate.cpp
        src/presentation/selection/screenshotselectiongeometry.cpp
        src/presentation/selection/screenshotselectionmodel.cpp
        src/presentation/selection/screenshotselectionparams.cpp
    )
    target_include_directories(snow-shot-capture-workflow-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-capture-workflow-tests PRIVATE
        Qt6::Gui
    )
    add_test(
        NAME snow-shot-capture-workflow-tests
        COMMAND snow-shot-capture-workflow-tests
    )

    add_executable(snow-shot-tool-command-workflow-tests
        tests/screenshot_tool_command_workflow_tests.cpp
        include/snow_shot/presentation/screenshotcapturestate.h
        include/snow_shot/presentation/screenshotdisplaysession.h
        include/snow_shot/presentation/screenshotgeometry.h
        include/snow_shot/presentation/screenshotintelligentselectionmodel.h
        include/snow_shot/presentation/screenshotinteractionstate.h
        include/snow_shot/presentation/screenshotselectiongeometry.h
        include/snow_shot/presentation/screenshotselectionmodel.h
        include/snow_shot/presentation/screenshotselectionparams.h
        include/snow_shot/presentation/screenshottoolcommandworkflow.h
        include/snow_shot/presentation/screenshottoolcommandworkflowports.h
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/core/screenshotintelligentselectionmodel.cpp
        src/presentation/core/screenshotinteractionstate.cpp
        src/presentation/selection/screenshotselectiongeometry.cpp
        src/presentation/selection/screenshotselectionmodel.cpp
        src/presentation/selection/screenshotselectionparams.cpp
        src/presentation/tools/screenshottoolcommandworkflow.cpp
    )
    target_include_directories(snow-shot-tool-command-workflow-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-tool-command-workflow-tests PRIVATE
        Qt6::Widgets
        snow_draw_engine_qt_canvas
    )
    add_test(
        NAME snow-shot-tool-command-workflow-tests
        COMMAND snow-shot-tool-command-workflow-tests
    )

    add_executable(snow-shot-smart-selection-transition-tests
        tests/screenshot_smart_selection_transition_tests.cpp
        include/snow_shot/presentation/screenshotsmartselectiontransition.h
        src/presentation/core/screenshotsmartselectiontransition.cpp
    )
    target_include_directories(snow-shot-smart-selection-transition-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-smart-selection-transition-tests PRIVATE
        Qt6::Core
    )
    add_test(
        NAME snow-shot-smart-selection-transition-tests
        COMMAND snow-shot-smart-selection-transition-tests
    )

    add_executable(snow-shot-selection-geometry-tests
        tests/screenshot_selection_geometry_tests.cpp
        include/snow_shot/presentation/screenshotgeometry.h
        include/snow_shot/presentation/screenshotselectiongeometry.h
        include/snow_shot/presentation/screenshotselectionmodel.h
        include/snow_shot/presentation/screenshotselectionparams.h
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/selection/screenshotselectiongeometry.cpp
        src/presentation/selection/screenshotselectionmodel.cpp
        src/presentation/selection/screenshotselectionparams.cpp
    )
    target_include_directories(snow-shot-selection-geometry-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-selection-geometry-tests PRIVATE
        Qt6::Gui
    )
    add_test(
        NAME snow-shot-selection-geometry-tests
        COMMAND snow-shot-selection-geometry-tests
    )
    set_tests_properties(snow-shot-selection-geometry-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-selection-export-workflow-tests
        tests/screenshot_selection_export_workflow_tests.cpp
        include/snow_shot/presentation/screenshotclipboardservice.h
        include/snow_shot/presentation/screenshotselectionexportworkflow.h
        include/snow_shot/presentation/screenshotselectionexportworkflowports.h
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/selection/screenshotselectionexportworkflow.cpp
        src/presentation/selection/screenshotselectiongeometry.cpp
        src/presentation/selection/screenshotselectionmodel.cpp
        src/presentation/selection/screenshotselectionparams.cpp
        src/presentation/services/screenshotclipboardservice.cpp
    )
    target_include_directories(snow-shot-selection-export-workflow-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-selection-export-workflow-tests PRIVATE Qt6::Gui)
    if(WIN32)
        target_link_libraries(snow-shot-selection-export-workflow-tests PRIVATE user32)
    endif()
    add_test(NAME snow-shot-selection-export-workflow-tests
             COMMAND snow-shot-selection-export-workflow-tests)
    set_tests_properties(snow-shot-selection-export-workflow-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-screenshot-history-tests
        tests/screenshot_history_tests.cpp
        include/snow_shot/presentation/screenshothistoryservice.h
        include/snow_shot/presentation/screenshotdisplaysession.h
        include/snow_shot/presentation/screenshotgeometry.h
        include/snow_shot/presentation/screenshotintelligentselectionmodel.h
        include/snow_shot/presentation/screenshotinteractionstate.h
        include/snow_shot/presentation/screenshotoverlayinputhandler.h
        include/snow_shot/presentation/screenshotselectiongeometry.h
        include/snow_shot/presentation/screenshotselectionmodel.h
        include/snow_shot/presentation/screenshotselectionparams.h
        src/presentation/services/screenshothistoryservice.cpp
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/core/screenshotintelligentselectionmodel.cpp
        src/presentation/core/screenshotinteractionstate.cpp
        src/presentation/overlay/screenshotoverlayinputhandler.cpp
        src/presentation/selection/screenshotselectiongeometry.cpp
        src/presentation/selection/screenshotselectionmodel.cpp
        src/presentation/selection/screenshotselectionparams.cpp
    )
    target_include_directories(snow-shot-screenshot-history-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-screenshot-history-tests PRIVATE
        snow_draw_engine_qt_canvas
        Qt6::Widgets
    )
    add_test(
        NAME snow-shot-screenshot-history-tests
        COMMAND snow-shot-screenshot-history-tests
    )
    set_tests_properties(snow-shot-screenshot-history-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-scrolling-preview-benchmark
        tests/scrolling_preview_benchmark.cpp
        include/snow_shot/presentation/screenshotscrollingtypes.h
        include/snow_shot/presentation/screenshotscrollingthumbnailwidget.h
        src/presentation/capture/screenshotscrollingthumbnailwidget.cpp
    )
    target_compile_definitions(snow-shot-scrolling-preview-benchmark PRIVATE
        SNOW_SHOT_BENCH_INTERNALS=1
    )
    target_include_directories(snow-shot-scrolling-preview-benchmark PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-scrolling-preview-benchmark PRIVATE
        ant_design_qt
        Qt6::Widgets
    )

    add_executable(snow-shot-scrolling-result-async-benchmark
        tests/scrolling_result_async_benchmark.cpp
    )
    target_include_directories(snow-shot-scrolling-result-async-benchmark PRIVATE
        "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-stitch-images-c/include"
    )
    target_link_libraries(snow-shot-scrolling-result-async-benchmark PRIVATE
        snow_stitch_images_c
        snow_shot_image_codec
        Qt6::Widgets
    )
    if(WIN32)
        target_link_libraries(snow-shot-scrolling-result-async-benchmark PRIVATE
            Ntdll
            Ws2_32
        )
    endif()

    add_executable(snow-shot-latest-bridge-mailbox-tests
        tests/latest_bridge_mailbox_tests.cpp
        src/presentation/capture/latestbridgemailbox.h
    )
    target_include_directories(snow-shot-latest-bridge-mailbox-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
    )
    add_test(
        NAME snow-shot-latest-bridge-mailbox-tests
        COMMAND snow-shot-latest-bridge-mailbox-tests
    )

    add_executable(snow-shot-scrolling-capture-cadence-tests
        tests/scrolling_capture_cadence_tests.cpp
        src/presentation/capture/adaptivescrollingcapturecadence.h
    )
    target_include_directories(snow-shot-scrolling-capture-cadence-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
    )
    add_test(
        NAME snow-shot-scrolling-capture-cadence-tests
        COMMAND snow-shot-scrolling-capture-cadence-tests
    )

    add_executable(snow-shot-screenshot-canvas-renderer-tests
        tests/screenshot_canvas_renderer_tests.cpp
        include/snow_shot/presentation/screenshotocrtextlayer.h
        include/snow_shot/presentation/screenshotmessageservice.h
        include/snow_shot/presentation/screenshotoverlaywindow.h
        include/snow_shot/presentation/screenshotscrollingtypes.h
        include/snow_shot/presentation/screenshotscrollingthumbnailwidget.h
        src/presentation/capture/screenshotscrollingthumbnailwidget.cpp
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/selection/screenshotselectiongeometry.cpp
        src/presentation/selection/screenshotselectionmodel.cpp
        src/presentation/selection/screenshotselectionparams.cpp
        src/presentation/overlay/screenshotcanvasrenderer.cpp
        src/presentation/overlay/screenshotselectionshadowrenderer.cpp
        src/presentation/overlay/screenshotoverlaycanvaspresenter.cpp
        src/presentation/overlay/screenshotoverlaywindow.cpp
        src/presentation/services/screenshotmessageservice.cpp
        src/presentation/ocr/screenshotocrpresentation.cpp
        src/presentation/ocr/screenshottabledocument.cpp
    )
    target_include_directories(snow-shot-screenshot-canvas-renderer-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_compile_definitions(snow-shot-screenshot-canvas-renderer-tests PRIVATE
        SNOW_SHOT_BENCH_INTERNALS=1
    )
    target_link_libraries(snow-shot-screenshot-canvas-renderer-tests PRIVATE
        ant_design_qt
        Qt6::Widgets
        snow_draw_engine_qt_canvas
    )
    add_test(
        NAME snow-shot-screenshot-canvas-renderer-tests
        COMMAND snow-shot-screenshot-canvas-renderer-tests
    )
    set_tests_properties(snow-shot-screenshot-canvas-renderer-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-pinned-resize-geometry-tests
        tests/screenshot_pinned_resize_geometry_tests.cpp
        src/presentation/pinned/screenshotpinnedresizegeometry.cpp
    )
    target_include_directories(snow-shot-pinned-resize-geometry-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src/presentation/pinned"
    )
    target_link_libraries(snow-shot-pinned-resize-geometry-tests PRIVATE
        Qt6::Core
    )
    add_test(
        NAME snow-shot-pinned-resize-geometry-tests
        COMMAND snow-shot-pinned-resize-geometry-tests
    )

    add_executable(snow-shot-pinned-native-geometry-controller-tests
        tests/screenshot_pinned_native_geometry_controller_tests.cpp
        src/presentation/pinned/screenshotpinnednativegeometrycontroller.cpp
        src/presentation/pinned/screenshotpinnedresizegeometry.cpp
    )
    target_include_directories(snow-shot-pinned-native-geometry-controller-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src/presentation/pinned"
    )
    target_link_libraries(snow-shot-pinned-native-geometry-controller-tests PRIVATE
        Qt6::Core
    )
    add_test(
        NAME snow-shot-pinned-native-geometry-controller-tests
        COMMAND snow-shot-pinned-native-geometry-controller-tests
    )

    add_executable(snow-shot-pinned-window-tests
        tests/screenshot_pinned_window_tests.cpp
        include/snow_shot/presentation/screenshotfloatingtoolpalettewindow.h
        include/snow_shot/presentation/screenshotpinnededitcontroller.h
        include/snow_shot/presentation/screenshotpinnedcopyservice.h
        include/snow_shot/presentation/screenshotpinnedwindow.h
        include/snow_shot/presentation/screenshotrecognitionsessioncontroller.h
        include/snow_shot/presentation/screenshotrecognitionwindow.h
        include/snow_shot/presentation/screenshottableeditor.h
        include/snow_shot/presentation/screenshotmessageservice.h
        include/snow_shot/presentation/screenshotselectiongeometry.h
        include/snow_shot/presentation/screenshotselectionmodel.h
        include/snow_shot/presentation/screenshotselectionparams.h
        include/snow_shot/network/snowshotapiclient.h
        include/snow_shot/presentation/screenshottoolpalette.h
        include/snow_shot/presentation/screenshottoolpalettehost.h
        include/snow_shot/presentation/styles/thememanager.h
        src/presentation/components/icons/snowshoticons.cpp
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/ocr/screenshotocrpresentation.cpp
        src/presentation/ocr/screenshotocrtexteditingsession.cpp
        src/presentation/ocr/screenshotocrtexttransform.cpp
        src/presentation/ocr/screenshotrecognitionsessioncontroller.cpp
        src/presentation/ocr/screenshotrecognitionwindow.cpp
        src/presentation/ocr/screenshottabledocument.cpp
        src/presentation/ocr/screenshottableeditor.cpp
        src/presentation/overlay/screenshotcanvasrenderer.cpp
        src/presentation/overlay/screenshotselectionshadowrenderer.cpp
        src/presentation/services/screenshotclipboardservice.cpp
        src/presentation/services/screenshotmessageservice.cpp
        src/presentation/selection/screenshotselectiongeometry.cpp
        src/presentation/selection/screenshotselectionmodel.cpp
        src/presentation/selection/screenshotselectionparams.cpp
        src/network/snowshotapiclient.cpp
        src/presentation/pinned/screenshotpinnededitcontroller.cpp
        src/presentation/pinned/screenshotpinnedcopyservice.cpp
        src/presentation/pinned/screenshotpinnednativegeometrycontroller.cpp
        src/presentation/pinned/screenshotpinnedresizegeometry.cpp
        src/presentation/pinned/screenshotpinnedwindow.cpp
        src/presentation/pinned/screenshotpinnedwindownative.cpp
        src/presentation/styles/buttonborder.cpp
        src/presentation/styles/floatingcontroltoolbarstyle.cpp
        src/presentation/styles/themecolorscheme.cpp
        src/presentation/styles/thememanager.cpp
        src/presentation/tools/screenshotfloatingtoolpalettenative.cpp
        src/presentation/tools/screenshotfloatingtoolpalettewindow.cpp
        src/presentation/tools/screenshottoolbarmainpanel.cpp
        src/presentation/tools/screenshottoolpalette.cpp
        src/presentation/tools/screenshottoolpalettebuttons.cpp
        src/presentation/tools/screenshottoolpalettehost.cpp
        src/presentation/tools/screenshottoolpalettestylecontrols.cpp
        src/presentation/tools/screenshottoolpalettestylemodel.cpp
    )
    target_include_directories(snow-shot-pinned-window-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-pinned-window-tests PRIVATE
        adqt_icon_core
        ant_design_icons_qt
        ant_design_qt
        Qt6::Network
        Qt6::Widgets
        snow_draw_engine_qt_canvas
    )
    if(WIN32)
        target_link_libraries(snow-shot-pinned-window-tests PRIVATE
            Qt6::GuiPrivate
            comctl32
            dwmapi
            user32
        )
    endif()
    add_test(
        NAME snow-shot-pinned-window-tests
        COMMAND snow-shot-pinned-window-tests
    )
    add_test(
        NAME snow-shot-pinned-recognition-provider-loss-tests
        COMMAND snow-shot-pinned-window-tests --recognition-provider-loss-only
    )
    set_tests_properties(
        snow-shot-pinned-window-tests
        snow-shot-pinned-recognition-provider-loss-tests
        PROPERTIES
        RUN_SERIAL TRUE
        TIMEOUT 90
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-pinned-copyservice-tests
        tests/screenshot_pinned_copyservice_tests.cpp
        include/snow_shot/presentation/screenshotclipboardservice.h
        include/snow_shot/presentation/screenshotpinnedcopyservice.h
        include/snow_shot/presentation/screenshotresultcompositor.h
        src/presentation/overlay/screenshotselectionshadowrenderer.cpp
        src/presentation/services/screenshotclipboardservice.cpp
        src/presentation/pinned/screenshotpinnedcopyservice.cpp
    )
    target_include_directories(snow-shot-pinned-copyservice-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-pinned-copyservice-tests PRIVATE
        Qt6::Widgets
        snow_draw_engine_qt_canvas
    )
    if(WIN32)
        target_link_libraries(snow-shot-pinned-copyservice-tests PRIVATE user32)
    endif()
    add_test(NAME snow-shot-pinned-copyservice-tests
             COMMAND snow-shot-pinned-copyservice-tests)
    set_tests_properties(snow-shot-pinned-copyservice-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    if(WIN32)
        add_executable(snow-shot-pinned-context-menu-real-mouse-repro
            tests/screenshot_pinned_context_menu_real_mouse_repro.cpp
            include/snow_shot/presentation/screenshotfloatingtoolpalettewindow.h
            include/snow_shot/presentation/screenshotpinnededitcontroller.h
            include/snow_shot/presentation/screenshotpinnedcopyservice.h
            include/snow_shot/presentation/screenshotpinnedwindow.h
            include/snow_shot/presentation/screenshottoolpalette.h
            include/snow_shot/presentation/screenshottoolpalettehost.h
            include/snow_shot/presentation/styles/thememanager.h
            src/presentation/components/icons/snowshoticons.cpp
            src/presentation/core/screenshotgeometry.cpp
            src/presentation/ocr/screenshotocrpresentation.cpp
            src/presentation/overlay/screenshotcanvasrenderer.cpp
            src/presentation/overlay/screenshotselectionshadowrenderer.cpp
            src/presentation/services/screenshotclipboardservice.cpp
            src/presentation/pinned/screenshotpinnededitcontroller.cpp
            src/presentation/pinned/screenshotpinnedcopyservice.cpp
            src/presentation/pinned/screenshotpinnednativegeometrycontroller.cpp
            src/presentation/pinned/screenshotpinnedresizegeometry.cpp
            src/presentation/pinned/screenshotpinnedwindow.cpp
            src/presentation/pinned/screenshotpinnedwindownative.cpp
            src/presentation/styles/buttonborder.cpp
            src/presentation/styles/floatingcontroltoolbarstyle.cpp
            src/presentation/styles/themecolorscheme.cpp
            src/presentation/styles/thememanager.cpp
            src/presentation/tools/screenshotfloatingtoolpalettenative.cpp
            src/presentation/tools/screenshotfloatingtoolpalettewindow.cpp
            src/presentation/tools/screenshottoolbarmainpanel.cpp
            src/presentation/tools/screenshottoolpalette.cpp
            src/presentation/tools/screenshottoolpalettebuttons.cpp
            src/presentation/tools/screenshottoolpalettehost.cpp
            src/presentation/tools/screenshottoolpalettestylecontrols.cpp
            src/presentation/tools/screenshottoolpalettestylemodel.cpp
        )
        target_include_directories(snow-shot-pinned-context-menu-real-mouse-repro PRIVATE
            "${CMAKE_CURRENT_SOURCE_DIR}/include"
        )
        target_link_libraries(snow-shot-pinned-context-menu-real-mouse-repro PRIVATE
            adqt_icon_core
            ant_design_icons_qt
            ant_design_qt
            Qt6::GuiPrivate
            Qt6::Widgets
            snow_draw_engine_qt_canvas
            comctl32
            dwmapi
            user32
        )
        add_test(
            NAME snow-shot-pinned-context-menu-real-mouse-repro
            COMMAND snow-shot-pinned-context-menu-real-mouse-repro
        )
        set_tests_properties(snow-shot-pinned-context-menu-real-mouse-repro PROPERTIES
            LABELS "regression;interactive"
            RUN_SERIAL TRUE
            TIMEOUT 20
            ENVIRONMENT_MODIFICATION
                "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )
    endif()

    add_executable(snow-shot-screenshot-tool-palette-tests
        tests/screenshot_tool_palette_tests.cpp
        include/snow_shot/presentation/languagemanager.h
        include/snow_shot/presentation/screenshottoolpalette.h
        include/snow_shot/presentation/styles/thememanager.h
        src/presentation/components/icons/snowshoticons.cpp
        src/presentation/services/languagemanager.cpp
        src/presentation/tools/screenshottoolbarmainpanel.cpp
        src/presentation/tools/screenshottoolpalettebuttons.cpp
        src/presentation/tools/screenshottoolpalettestylecontrols.cpp
        src/presentation/tools/screenshottoolpalettestylemodel.cpp
        src/presentation/tools/screenshottoolpalette.cpp
        src/presentation/styles/thememanager.cpp
        src/presentation/styles/themecolorscheme.cpp
    )
    target_include_directories(snow-shot-screenshot-tool-palette-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_compile_definitions(snow-shot-screenshot-tool-palette-tests PRIVATE
        SNOW_SHOT_TEST_HOOKS=1
    )
    target_link_libraries(snow-shot-screenshot-tool-palette-tests PRIVATE
        adqt_icon_core
        ant_design_icons_qt
        ant_design_qt
        Qt6::Widgets
        snow_draw_engine_qt_canvas
    )
    snow_shot_add_translations(snow-shot-screenshot-tool-palette-tests)
    add_test(
        NAME snow-shot-screenshot-tool-palette-tests
        COMMAND snow-shot-screenshot-tool-palette-tests
    )
    set_tests_properties(snow-shot-screenshot-tool-palette-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    if(WIN32)
        add_executable(snow-shot-screenshot-toolbar-fill-color-hover-tests
            tests/screenshot_toolbar_fill_color_hover_tests.cpp
            include/snow_shot/presentation/screenshotfloatingtoolpalettewindow.h
            include/snow_shot/presentation/screenshottoolbarwindow.h
            include/snow_shot/presentation/screenshottoolpalette.h
            include/snow_shot/presentation/screenshottoolpalettehost.h
            include/snow_shot/presentation/styles/thememanager.h
            src/presentation/components/icons/snowshoticons.cpp
            src/presentation/core/screenshotgeometry.cpp
            src/presentation/tools/screenshotfloatingtoolpalettenative.cpp
            src/presentation/tools/screenshotfloatingtoolpalettewindow.cpp
            src/presentation/tools/screenshottoolbarmainpanel.cpp
            src/presentation/tools/screenshottoolpalettebuttons.cpp
            src/presentation/tools/screenshottoolpalettehost.cpp
            src/presentation/tools/screenshottoolpalettestylecontrols.cpp
            src/presentation/tools/screenshottoolpalettestylemodel.cpp
            src/presentation/tools/screenshottoolpalette.cpp
            src/presentation/toolbar/screenshottoolbarwindow.cpp
            src/presentation/styles/thememanager.cpp
            src/presentation/styles/themecolorscheme.cpp
        )
        target_include_directories(
            snow-shot-screenshot-toolbar-fill-color-hover-tests
            PRIVATE
                "${CMAKE_CURRENT_SOURCE_DIR}/include"
        )
        target_link_libraries(
            snow-shot-screenshot-toolbar-fill-color-hover-tests
            PRIVATE
                adqt_icon_core
                ant_design_icons_qt
                ant_design_qt
                Qt6::Widgets
                snow_draw_engine_qt_canvas
                comctl32
        )
        add_test(
            NAME snow-shot-screenshot-toolbar-fill-color-hover-tests
            COMMAND snow-shot-screenshot-toolbar-fill-color-hover-tests
        )
        set_tests_properties(
            snow-shot-screenshot-toolbar-fill-color-hover-tests
            PROPERTIES
                ENVIRONMENT
                    "QT_QPA_PLATFORM=windows;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QWindowsIntegrationPlugin>"
                ENVIRONMENT_MODIFICATION
                    "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )

        # This is intentionally not registered with CTest. It creates native
        # always-on-top windows, moves the real cursor, and is designed for
        # explicit Release benchmarking sessions.
        add_executable(snow-shot-screenshot-toolbar-render-benchmark
            tests/screenshot_toolbar_render_benchmark.cpp
            include/snow_shot/presentation/screenshotfloatingtoolpalettewindow.h
            include/snow_shot/presentation/screenshottoolbarwindow.h
            include/snow_shot/presentation/screenshottoolpalette.h
            include/snow_shot/presentation/screenshottoolpalettehost.h
            include/snow_shot/presentation/styles/thememanager.h
            src/presentation/components/icons/snowshoticons.cpp
            src/presentation/core/screenshotgeometry.cpp
            src/presentation/tools/screenshotfloatingtoolpalettenative.cpp
            src/presentation/tools/screenshotfloatingtoolpalettewindow.cpp
            src/presentation/tools/screenshottoolbarmainpanel.cpp
            src/presentation/tools/screenshottoolpalettebuttons.cpp
            src/presentation/tools/screenshottoolpalettehost.cpp
            src/presentation/tools/screenshottoolpalettestylecontrols.cpp
            src/presentation/tools/screenshottoolpalettestylemodel.cpp
            src/presentation/tools/screenshottoolpalette.cpp
            src/presentation/tools/screenshottoolbarperfinstrumentation.h
            src/presentation/toolbar/screenshottoolbarwindow.cpp
            src/presentation/styles/thememanager.cpp
            src/presentation/styles/themecolorscheme.cpp
        )
        target_compile_definitions(
            snow-shot-screenshot-toolbar-render-benchmark
            PRIVATE
                NOMINMAX
                SNOW_SHOT_TOOLBAR_PERF_INSTRUMENTATION=1
        )
        target_include_directories(
            snow-shot-screenshot-toolbar-render-benchmark
            PRIVATE
                "${CMAKE_CURRENT_SOURCE_DIR}/include"
        )
        target_link_libraries(
            snow-shot-screenshot-toolbar-render-benchmark
            PRIVATE
                adqt_icon_core
                ant_design_icons_qt
                ant_design_qt
                Qt6::Widgets
                snow_draw_engine_qt_canvas
                comctl32
                dwmapi
                user32
        )
    endif()

    add_executable(snow-shot-floating-toolbar-drag-tests
        tests/screenshot_floating_toolbar_drag_tests.cpp
        include/snow_shot/presentation/screenshotfloatingtoolpalettewindow.h
        include/snow_shot/presentation/screenshottoolbarwindow.h
        include/snow_shot/presentation/screenshottoolpalette.h
        include/snow_shot/presentation/screenshottoolpalettehost.h
        include/snow_shot/presentation/styles/thememanager.h
        src/presentation/components/icons/snowshoticons.cpp
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/styles/thememanager.cpp
        src/presentation/styles/themecolorscheme.cpp
        src/presentation/tools/screenshotfloatingtoolpalettenative.cpp
        src/presentation/tools/screenshotfloatingtoolpalettewindow.cpp
        src/presentation/tools/screenshottoolbarmainpanel.cpp
        src/presentation/tools/screenshottoolpalettebuttons.cpp
        src/presentation/tools/screenshottoolpalettehost.cpp
        src/presentation/tools/screenshottoolpalettestylecontrols.cpp
        src/presentation/tools/screenshottoolpalettestylemodel.cpp
        src/presentation/tools/screenshottoolpalette.cpp
        src/presentation/toolbar/screenshottoolbarwindow.cpp
    )
    target_compile_definitions(snow-shot-floating-toolbar-drag-tests PRIVATE
        SNOW_SHOT_TEST_HOOKS=1
    )
    target_include_directories(snow-shot-floating-toolbar-drag-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-floating-toolbar-drag-tests PRIVATE
        adqt_icon_core
        ant_design_icons_qt
        ant_design_qt
        Qt6::Widgets
        snow_draw_engine_qt_canvas
    )
    if(WIN32)
        target_link_libraries(snow-shot-floating-toolbar-drag-tests PRIVATE
            comctl32
        )
    endif()
    add_test(
        NAME snow-shot-floating-toolbar-drag-tests
        COMMAND snow-shot-floating-toolbar-drag-tests
    )
    set_tests_properties(snow-shot-floating-toolbar-drag-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )
    if(NOT WIN32)
        set_tests_properties(snow-shot-floating-toolbar-drag-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        )
    endif()

    add_executable(snow-shot-adqt-dpi-stable-tests
        tests/adqt_dpi_stable_tests.cpp
    )
    if(WIN32)
        target_link_libraries(snow-shot-adqt-dpi-stable-tests PRIVATE comctl32)
    endif()
    target_link_libraries(snow-shot-adqt-dpi-stable-tests PRIVATE
        adqt_icon_core
        ant_design_icons_qt
        ant_design_qt
        Qt6::Widgets
        Qt6::Svg
    )
    add_test(
        NAME snow-shot-adqt-dpi-stable-tests
        COMMAND snow-shot-adqt-dpi-stable-tests
    )
    set_tests_properties(snow-shot-adqt-dpi-stable-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-generated-icon-pack-tests
        tests/generated_icon_pack_tests.cpp
        src/presentation/components/icons/snowshoticons.cpp
    )
    target_include_directories(snow-shot-generated-icon-pack-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-generated-icon-pack-tests PRIVATE
        ant_design_icons_qt
        Qt6::Widgets
        Qt6::Svg
    )
    add_test(
        NAME snow-shot-generated-icon-pack-tests
        COMMAND snow-shot-generated-icon-pack-tests
    )
    set_tests_properties(snow-shot-generated-icon-pack-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-application-icon-tests
        tests/application_icon_tests.cpp
        src/presentation/components/icons/snowshoticons.cpp
    )
    if(WIN32)
        target_sources(snow-shot-application-icon-tests PRIVATE
            resources/app-icon.ico
            resources/windows-app-icon.rc
        )
    endif()
    target_include_directories(snow-shot-application-icon-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-application-icon-tests PRIVATE
        ant_design_icons_qt
        Qt6::Widgets
        Qt6::Svg
    )
    add_test(
        NAME snow-shot-application-icon-tests
        COMMAND snow-shot-application-icon-tests
    )
    set_tests_properties(snow-shot-application-icon-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-sidebar-widget-tests
        tests/sidebar_widget_tests.cpp
        include/snow_shot/presentation/components/sidebarwidget.h
        include/snow_shot/presentation/styles/themecolorscheme.h
        include/snow_shot/presentation/styles/thememanager.h
        src/presentation/components/sidebarwidget.cpp
        src/presentation/styles/themecolorscheme.cpp
        src/presentation/styles/thememanager.cpp
    )
    target_include_directories(snow-shot-sidebar-widget-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-sidebar-widget-tests PRIVATE
        ant_design_qt
        snow_shot_settings_catalog
        Qt6::Widgets
    )
    add_test(
        NAME snow-shot-sidebar-widget-tests
        COMMAND snow-shot-sidebar-widget-tests
    )
    set_tests_properties(snow-shot-sidebar-widget-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-main-content-header-tests
        tests/main_content_header_tests.cpp
        include/snow_shot/presentation/components/maincontentheaderwidget.h
        include/snow_shot/presentation/styles/themecolorscheme.h
        include/snow_shot/presentation/styles/thememanager.h
        src/presentation/components/maincontentheaderwidget.cpp
        src/presentation/styles/themecolorscheme.cpp
        src/presentation/styles/thememanager.cpp
    )
    target_include_directories(snow-shot-main-content-header-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-main-content-header-tests PRIVATE
        ant_design_icons_qt
        ant_design_qt
        snow_shot_settings_search
        Qt6::Widgets
        snow_shot_storage
    )
    add_test(
        NAME snow-shot-main-content-header-tests
        COMMAND snow-shot-main-content-header-tests
    )
    set_tests_properties(snow-shot-main-content-header-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-tooltip-tests
        tests/tooltip_tests.cpp
    )
    target_link_libraries(snow-shot-tooltip-tests PRIVATE
        ant_design_qt
        Qt6::Widgets
    )
    add_test(
        NAME snow-shot-tooltip-tests
        COMMAND snow-shot-tooltip-tests
    )
    if(WIN32)
    set_tests_properties(snow-shot-tooltip-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=windows;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QWindowsIntegrationPlugin>"
            ENVIRONMENT_MODIFICATION
                "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )
    else()
        set_tests_properties(snow-shot-tooltip-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        )
    endif()

    add_executable(snow-shot-toolbar-main-panel-tests
        tests/screenshot_toolbar_main_panel_tests.cpp
        include/snow_shot/presentation/screenshottoolpalette.h
        include/snow_shot/presentation/styles/thememanager.h
        src/presentation/components/icons/snowshoticons.cpp
        src/presentation/styles/thememanager.cpp
        src/presentation/styles/themecolorscheme.cpp
        src/presentation/tools/screenshottoolbarmainpanel.cpp
        src/presentation/tools/screenshottoolpalettebuttons.cpp
        src/presentation/tools/screenshottoolpalettestylecontrols.cpp
        src/presentation/tools/screenshottoolpalettestylemodel.cpp
        src/presentation/tools/screenshottoolpalette.cpp
    )
    target_include_directories(snow-shot-toolbar-main-panel-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-toolbar-main-panel-tests PRIVATE
        ant_design_qt
        snow_draw_engine_qt_canvas
        Qt6::Widgets
        Qt6::Svg
        Qt6::Network
    )
    add_test(
        NAME snow-shot-toolbar-main-panel-tests
        COMMAND snow-shot-toolbar-main-panel-tests
    )
    set_tests_properties(snow-shot-toolbar-main-panel-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-video-recording-geometry-tests
        tests/video_recording_geometry_tests.cpp
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/recording/videorecordinggeometry.cpp
    )
    target_include_directories(snow-shot-video-recording-geometry-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/src"
    )
    target_link_libraries(snow-shot-video-recording-geometry-tests PRIVATE
        Qt6::Widgets
    )
    add_test(
        NAME snow-shot-video-recording-geometry-tests
        COMMAND snow-shot-video-recording-geometry-tests
    )
    set_tests_properties(snow-shot-video-recording-geometry-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>;QT_SCALE_FACTOR=1.25"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-ocr-presentation-tests
        tests/screenshot_ocr_presentation_tests.cpp
        include/snow_shot/presentation/screenshotocrpresentation.h
        include/snow_shot/presentation/screenshotocrtexteditingsession.h
        include/snow_shot/presentation/screenshotocrtexttransform.h
        include/snow_shot/presentation/screenshottabledocument.h
        include/snow_shot/presentation/screenshotsourceimagecomposer.h
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/ocr/screenshotocrpresentation.cpp
        src/presentation/ocr/screenshotocrtexteditingsession.cpp
        src/presentation/ocr/screenshottabledocument.cpp
        src/presentation/ocr/screenshotocrtexttransform.cpp
        src/presentation/services/screenshotsourceimagecomposer.cpp
    )
    target_include_directories(snow-shot-ocr-presentation-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-ocr-presentation-tests PRIVATE
        Qt6::Widgets
    )
    add_test(
        NAME snow-shot-ocr-presentation-tests
        COMMAND snow-shot-ocr-presentation-tests
    )
    set_tests_properties(snow-shot-ocr-presentation-tests PROPERTIES
        ENVIRONMENT
            "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-recognition-window-tests
        tests/screenshot_recognition_window_tests.cpp
        include/snow_shot/presentation/screenshotcanvasrenderer.h
        include/snow_shot/presentation/screenshotgeometry.h
        include/snow_shot/presentation/screenshotocrpresentation.h
        include/snow_shot/presentation/screenshotocrtextlayer.h
        include/snow_shot/presentation/screenshottabledocument.h
        include/snow_shot/presentation/screenshottableeditor.h
        include/snow_shot/presentation/screenshotrecognitionwindow.h
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/ocr/screenshotocrpresentation.cpp
        src/presentation/ocr/screenshottabledocument.cpp
        src/presentation/ocr/screenshottableeditor.cpp
        src/presentation/ocr/screenshotrecognitionwindow.cpp
        src/presentation/overlay/screenshotcanvasrenderer.cpp
        src/presentation/overlay/screenshotselectionshadowrenderer.cpp
        src/presentation/styles/buttonborder.cpp
    )
    target_include_directories(snow-shot-recognition-window-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-recognition-window-tests PRIVATE
        ant_design_qt
        Qt6::Widgets
        snow_draw_engine_qt_canvas
    )
    if(WIN32)
        target_link_libraries(snow-shot-recognition-window-tests PRIVATE
            user32
        )
    endif()
    add_test(
        NAME snow-shot-recognition-window-tests
        COMMAND snow-shot-recognition-window-tests
    )
    if(WIN32)
        set_tests_properties(snow-shot-recognition-window-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=windows;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QWindowsIntegrationPlugin>"
            ENVIRONMENT_MODIFICATION
                "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )
    else()
        set_tests_properties(snow-shot-recognition-window-tests PROPERTIES
            ENVIRONMENT
                "QT_QPA_PLATFORM=offscreen;QT_QPA_PLATFORM_PLUGIN_PATH=$<TARGET_FILE_DIR:Qt6::QOffscreenIntegrationPlugin>"
            ENVIRONMENT_MODIFICATION
                "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
        )
    endif()

    add_executable(snow-shot-ocr-recognition-service-tests
        tests/screenshot_ocr_recognition_service_tests.cpp
        include/snow_shot/presentation/screenshotocrpresentation.h
        include/snow_shot/presentation/screenshotocrrecognitionservice.h
        src/presentation/ocr/screenshotocrpresentation.cpp
        src/presentation/ocr/screenshotocrrecognitionservice.cpp
    )
    target_include_directories(snow-shot-ocr-recognition-service-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
        "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-ocr-c/include"
    )
    target_link_libraries(snow-shot-ocr-recognition-service-tests PRIVATE
        snow_ocr_c
        Qt6::Core
        Qt6::Gui
    )
    if(WIN32)
        target_link_libraries(snow-shot-ocr-recognition-service-tests PRIVATE
            bcrypt
            ntdll
        )
    endif()
    add_test(
        NAME snow-shot-ocr-cpu-recognition-service-tests
        COMMAND snow-shot-ocr-recognition-service-tests
    )
    add_test(
        NAME snow-shot-ocr-directml-recognition-service-tests
        COMMAND snow-shot-ocr-recognition-service-tests --directml
    )
    set_tests_properties(snow-shot-ocr-cpu-recognition-service-tests PROPERTIES
        TIMEOUT 120
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )
    set_tests_properties(snow-shot-ocr-directml-recognition-service-tests PROPERTIES
        TIMEOUT 120
        SKIP_RETURN_CODE 77
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    add_executable(snow-shot-qr-recognition-service-tests
        tests/screenshot_qr_recognition_service_tests.cpp
        include/snow_shot/presentation/screenshotqrrecognitionservice.h
        src/presentation/ocr/screenshotqrrecognitionservice.cpp
    )
    target_include_directories(snow-shot-qr-recognition-service-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-qr-recognition-service-tests PRIVATE
        opencv_wechat_qrcode
        Qt6::Core
        Qt6::Gui
    )
    add_test(
        NAME snow-shot-qr-recognition-service-tests
        COMMAND snow-shot-qr-recognition-service-tests
    )
    set_tests_properties(snow-shot-qr-recognition-service-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>;PATH=path_list_prepend:$<TARGET_FILE_DIR:opencv_wechat_qrcode>"
    )

    add_executable(snow-shot-api-client-tests
        tests/snowshot_api_client_tests.cpp
        include/snow_shot/network/snowshotapiclient.h
        src/network/snowshotapiclient.cpp
    )
    target_include_directories(snow-shot-api-client-tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-api-client-tests PRIVATE
        Qt6::Core
        Qt6::Gui
        Qt6::Network
        snow_shot_image_codec
    )
    add_test(
        NAME snow-shot-api-client-tests
        COMMAND snow-shot-api-client-tests
    )
    set_tests_properties(snow-shot-api-client-tests PROPERTIES
        ENVIRONMENT_MODIFICATION
            "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>"
    )

    if(WIN32)
        add_executable(snow-shot-scrolling-thumbnail-uia-e2e-test
            tests/scrolling_thumbnail_uia_e2e_test.cpp
        )
        target_link_libraries(snow-shot-scrolling-thumbnail-uia-e2e-test PRIVATE
            Ole32
            Uiautomationcore
            Gdi32
            User32
        )
        add_dependencies(snow-shot-scrolling-thumbnail-uia-e2e-test snow_shot)
        add_test(
            NAME snow-shot-scrolling-thumbnail-uia-e2e-test
            COMMAND snow-shot-scrolling-thumbnail-uia-e2e-test $<TARGET_FILE:snow_shot>
        )
        set_tests_properties(snow-shot-scrolling-thumbnail-uia-e2e-test PROPERTIES
            LABELS "e2e;uia;interactive"
            RUN_SERIAL TRUE
            WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
        )
    endif()

    foreach(_storage_test_target IN ITEMS
        snow-shot-language-manager-tests
        snow-shot-interface-settings-tests
        snow-shot-system-tray-controller-tests
        snow-shot-global-shortcut-manager-tests
        snow-shot-shortcut-key-row-tests
        snow-shot-selection-resize-workflow-tests
        snow-shot-screenshot-history-tests
        snow-shot-pinned-window-tests
        snow-shot-pinned-context-menu-real-mouse-repro
        snow-shot-screenshot-tool-palette-tests
        snow-shot-screenshot-toolbar-fill-color-hover-tests
        snow-shot-screenshot-toolbar-render-benchmark
        snow-shot-floating-toolbar-drag-tests
        snow-shot-sidebar-widget-tests
        snow-shot-toolbar-main-panel-tests
    )
        if(TARGET ${_storage_test_target})
            target_link_libraries(${_storage_test_target} PRIVATE snow_shot_storage)
        endif()
    endforeach()

    if(_SNOW_SHOT_RUNTIME_OUTPUT_DIRECTORY_WAS_DEFINED)
        set(
            CMAKE_RUNTIME_OUTPUT_DIRECTORY
            "${_SNOW_SHOT_SAVED_RUNTIME_OUTPUT_DIRECTORY}"
        )
    else()
        unset(CMAKE_RUNTIME_OUTPUT_DIRECTORY)
    endif()
    unset(_SNOW_SHOT_SAVED_RUNTIME_OUTPUT_DIRECTORY)
    unset(_SNOW_SHOT_RUNTIME_OUTPUT_DIRECTORY_WAS_DEFINED)

endif()

if(WIN32 AND SNOW_SHOT_BUILD_BENCHMARKS)
    # This executable deliberately is not registered with CTest. It creates a
    # native 4K widget and reports hardware-sensitive timing for explicit
    # Windows performance sessions.
    add_executable(snow-shot-selection-render-benchmark
        tests/screenshot_selection_render_benchmark.cpp
        include/snow_shot/presentation/screenshotcanvasrenderer.h
        include/snow_shot/presentation/screenshotselectionshadowrenderer.h
        src/presentation/ocr/screenshotocrpresentation.cpp
        src/presentation/overlay/screenshotcanvasrenderer.cpp
        src/presentation/overlay/screenshotselectionshadowrenderer.cpp
    )
    target_compile_definitions(snow-shot-selection-render-benchmark PRIVATE
        NOMINMAX
        SNOW_SHOT_BENCH_INTERNALS=1
    )
    target_include_directories(snow-shot-selection-render-benchmark PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
        "${SNOW_SHOT_DRAW_ENGINE_QT_DIR}/src/rendering"
        "${SNOW_SHOT_DRAW_ENGINE_QT_DIR}/crates/snow-draw-engine-c/include"
    )
    target_link_libraries(snow-shot-selection-render-benchmark PRIVATE
        Qt6::Widgets
        snow_draw_engine_qt_canvas
        dwmapi
        user32
    )

    add_executable(snow-shot-history-performance-benchmark
        tests/screenshot_history_performance_benchmark.cpp
        include/snow_shot/presentation/components/contentcardwidget.h
        src/presentation/components/contentcardwidget.cpp
    )
    target_compile_definitions(snow-shot-history-performance-benchmark PRIVATE
        NOMINMAX
        SNOW_SHOT_HISTORY_BENCHMARK_BASELINE_PATH="${CMAKE_CURRENT_SOURCE_DIR}/tests/baselines/screenshot_history_performance.json"
    )
    target_include_directories(snow-shot-history-performance-benchmark PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-history-performance-benchmark PRIVATE
        snow_shot_settings
        snow_shot_storage
        snow_shot_settings_catalog
        ant_design_qt
        Qt6::Widgets
        Psapi
    )

    # This executable deliberately is not registered with CTest. It publishes
    # generated images through the real Windows clipboard for explicit Release
    # performance sessions and leaves the final fixture on the clipboard.
    add_executable(snow-shot-clipboard-performance-benchmark
        tests/screenshot_clipboard_performance_benchmark.cpp
        include/snow_shot/presentation/screenshotclipboardservice.h
        include/snow_shot/presentation/screenshotdisplaysession.h
        include/snow_shot/presentation/screenshotexportservice.h
        include/snow_shot/presentation/screenshotgeometry.h
        include/snow_shot/presentation/screenshotresultcompositor.h
        include/snow_shot/presentation/screenshotselectionshadowrenderer.h
        src/presentation/core/screenshotgeometry.cpp
        src/presentation/overlay/screenshotselectionshadowrenderer.cpp
        src/presentation/services/screenshotclipboardperfinstrumentation.h
        src/presentation/services/screenshotclipboardservice.cpp
        src/presentation/services/screenshotexportservice.cpp
    )
    target_compile_definitions(snow-shot-clipboard-performance-benchmark PRIVATE
        NOMINMAX
        SNOW_SHOT_CLIPBOARD_PERF_INSTRUMENTATION=1
    )
    target_include_directories(snow-shot-clipboard-performance-benchmark PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-clipboard-performance-benchmark PRIVATE
        Qt6::Widgets
        snow_draw_engine_qt_canvas
        Psapi
        user32
    )
endif()

target_include_directories(snow_shot PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-capture-c/include"
    "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-ui-selector-c/include"
    "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-stitch-images-c/include"
    "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-ocr-c/include"
)
target_precompile_headers(snow_shot PRIVATE
    <algorithm>
    <memory>
    <optional>
    <string>
    <vector>
    <QtCore/QObject>
    <QtCore/QString>
    <QtGui/QColor>
    <QtGui/QImage>
    <QtGui/QPainter>
    <QtWidgets/QWidget>
)

target_link_libraries(
    snow_shot PRIVATE
        adqt_icon_core
        ant_design_icons_qt
        ant_design_qt
        snow_shot_settings
        snow_shot_storage
        snow_draw_engine_qt_canvas
        snow_capture_c
        snow_ui_selector_c
        snow_stitch_images_c
        snow_ocr_c
        opencv_wechat_qrcode
        Qt6::Widgets
        Qt6::Svg
        Qt6::Network
)

target_compile_definitions(snow_shot PRIVATE
    $<$<CONFIG:Release>:QT_NO_DEBUG_OUTPUT>
)

if(WIN32 AND SNOW_SHOT_BUILD_BENCHMARKS)
    add_executable(snow-shot-pin-to-screen-performance-benchmark
        tests/screenshot_pin_to_screen_performance_benchmark.cpp
    )
    target_include_directories(snow-shot-pin-to-screen-performance-benchmark PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include"
    )
    target_link_libraries(snow-shot-pin-to-screen-performance-benchmark PRIVATE
        Qt6::Core
        dwmapi
        gdi32
        ole32
        oleaut32
        psapi
        Uiautomationcore
        user32
    )
    target_compile_definitions(snow-shot-pin-to-screen-performance-benchmark PRIVATE NOMINMAX)

    target_compile_definitions(snow_shot PRIVATE
        SNOW_SHOT_PIN_PERF_INSTRUMENTATION=1
    )
endif()

snow_shot_add_translations(snow_shot)

if(WIN32)
    foreach(_ocr_runtime_target IN ITEMS snow_shot snow-shot-ocr-recognition-service-tests)
        if(TARGET ${_ocr_runtime_target})
            add_custom_command(TARGET ${_ocr_runtime_target} POST_BUILD
                COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                    "$<IF:$<CONFIG:Debug>,${SNOW_SHOT_DIRECTML_RUNTIME_DLL_DEBUG},${SNOW_SHOT_DIRECTML_RUNTIME_DLL_RELEASE}>"
                    "$<TARGET_FILE_DIR:${_ocr_runtime_target}>/DirectML.dll"
                COMMENT "Staging DirectML for ${_ocr_runtime_target}"
                VERBATIM
            )
            if(NOT SNOW_SHOT_RELEASE_STATIC)
                add_custom_command(TARGET ${_ocr_runtime_target} POST_BUILD
                    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                        "$<TARGET_FILE:onnxruntime::onnxruntime>"
                        "$<TARGET_FILE_DIR:${_ocr_runtime_target}>/onnxruntime.dll"
                    COMMENT "Staging dynamic ONNX Runtime for ${_ocr_runtime_target}"
                    VERBATIM
                )
            endif()
        endif()
    endforeach()
    unset(_ocr_runtime_target)
endif()

if(SNOW_SHOT_ENABLE_AGGRESSIVE_RELEASE_OPTIMIZATION OR SNOW_SHOT_RELEASE_STATIC)
    snow_apply_release_options(snow_shot)
endif()

if(WIN32)
    target_link_libraries(snow_shot PRIVATE
        Qt6::GuiPrivate
        dwmapi
        advapi32
        bcrypt
        comctl32
        d3d11
        dxgi
        dxguid
        gdi32
        ole32
        oleacc
        oleaut32
        psapi
        runtimeobject
        user32
        userenv
        windowsapp
        ws2_32
    )
endif()

if(WIN32)
    set(SNOW_SHOT_FFMPEG_BIN_DIR
        "${SNOW_FFMPEG_ROOT}/bin"
        CACHE PATH
        "Directory containing the FFmpeg runtime DLLs used by snow-screen-recorder."
    )
    find_program(PKG_CONFIG_EXECUTABLE
        NAMES pkgconf pkg-config
        HINTS "${VCPKG_INSTALLED_DIR}/x64-windows/tools/pkgconf"
        NO_DEFAULT_PATH
        REQUIRED
    )
    set(_SNOW_SHOT_SAVED_PKG_CONFIG_PATH "$ENV{PKG_CONFIG_PATH}")
    set(ENV{PKG_CONFIG_PATH} "${SNOW_FFMPEG_ROOT}/lib/pkgconfig")
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SNOW_SHOT_FFMPEG REQUIRED IMPORTED_TARGET GLOBAL
        libavformat
        libavcodec
        libswresample
        libswscale
        libavutil
    )
    set(ENV{PKG_CONFIG_PATH} "${_SNOW_SHOT_SAVED_PKG_CONFIG_PATH}")
    unset(_SNOW_SHOT_SAVED_PKG_CONFIG_PATH)
    target_link_libraries(snow_shot PRIVATE PkgConfig::SNOW_SHOT_FFMPEG)
    if(EXISTS "${SNOW_SHOT_FFMPEG_BIN_DIR}" AND NOT SNOW_SHOT_RELEASE_STATIC)
        set(SNOW_SHOT_FFMPEG_DLL_PATTERNS
            "avcodec-*.dll"
            "avdevice-*.dll"
            "avfilter-*.dll"
            "avformat-*.dll"
            "avutil-*.dll"
            "swresample-*.dll"
            "swscale-*.dll"
            "libx264-*.dll"
            "openh264-*.dll"
        )
        set(SNOW_SHOT_FFMPEG_DLLS)
        foreach(_ffmpeg_dll_pattern IN LISTS SNOW_SHOT_FFMPEG_DLL_PATTERNS)
            file(GLOB _ffmpeg_matching_dlls
                "${SNOW_SHOT_FFMPEG_BIN_DIR}/${_ffmpeg_dll_pattern}"
            )
            list(APPEND SNOW_SHOT_FFMPEG_DLLS ${_ffmpeg_matching_dlls})
        endforeach()
        set(SNOW_SHOT_FFMPEG_RUNTIME_FILES ${SNOW_SHOT_FFMPEG_DLLS}
            CACHE INTERNAL "FFmpeg runtime files installed with Snow Shot.")
    endif()
endif()

if(MSVC)
    # Parallel CL invocations otherwise race over the target's shared PDB.
    target_compile_options(snow_shot PRIVATE /FS /utf-8)
endif()

if(SNOW_SHOT_ENABLE_STRICT_COMPILE)
    if(MSVC)
        target_compile_options(snow_shot PRIVATE
            /WX
            /W4
            /sdl
            /permissive-
            /Zc:__cplusplus
            /Zc:preprocessor
            /Zc:inline
            /w14242
            /w14254
            /w14263
            /w14265
            /w14287
            /we4289
            /w14296
            /w14311
            /w14545
            /w14546
            /w14547
            /w14549
            /w14555
            /w14619
            /w14640
            /w14826
            /w14905
            /w14906
            /w14928
        )
    else()
        target_compile_options(snow_shot PRIVATE
            -Werror
            -Wall
            -Wextra
            -Wpedantic
            -Wcast-qual
            -Wcast-align
            -Wconversion
            -Wdouble-promotion
            -Wextra-semi
            -Wfloat-equal
            -Wformat=2
            -Wimplicit-fallthrough
            -Wmissing-declarations
            -Wnon-virtual-dtor
            -Wnull-dereference
            -Wold-style-cast
            -Woverloaded-virtual
            -Wredundant-decls
            -Wshadow
            -Wsign-conversion
            -Wswitch-default
            -Wswitch-enum
            -Wundef
            -Wunreachable-code
            -Wzero-as-null-pointer-constant
        )
    endif()

    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        target_compile_options(snow_shot PRIVATE
            -Wcomma
            -Wdocumentation
            -Wimplicit-int-conversion
            -Wnewline-eof
            -Wreserved-identifier
            -Wshorten-64-to-32
            -Wthread-safety
        )
    endif()

    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        target_compile_options(snow_shot PRIVATE
            -Wduplicated-cond
            -Wduplicated-branches
            -Wlogical-op
            -Wuseless-cast
        )
    endif()
endif()

set_target_properties(snow_shot PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER com.snowshot.snow_shot
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)
if(MSVC AND SNOW_SHOT_RELEASE_STATIC AND NOT SNOW_SHOT_QT_STATIC)
    # The shared Qt kit's entry-point shim is built with /MD. Use the static
    # CRT startup directly so the /MT release does not mix CRT variants.
    set_property(TARGET snow_shot PROPERTY qt_no_entrypoint TRUE)
    target_link_options(snow_shot PRIVATE /ENTRY:mainCRTStartup)
endif()
if(MSVC AND (SNOW_SHOT_RELEASE_STATIC OR
             (CMAKE_MSVC_RUNTIME_LIBRARY MATCHES "^MultiThreaded" AND
              NOT CMAKE_MSVC_RUNTIME_LIBRARY MATCHES "DLL")))
    # Each independently built Rust staticlib carries its own copy of Rust's
    # runtime support. Static Qt can also bundle codec symbols supplied by
    # Snow Image. These implementations are ABI-identical and intentionally
    # coalesced by the final executable link.
    target_link_options(snow_shot PRIVATE /FORCE:MULTIPLE)
endif()

include(GNUInstallDirs)
install(TARGETS snow_shot
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
if(WIN32 AND NOT SNOW_SHOT_RELEASE_STATIC)
    install(FILES "$<TARGET_FILE:onnxruntime::onnxruntime>"
        DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
endif()

if(WIN32)
    install(FILES "${SNOW_SHOT_DIRECTML_RUNTIME_DLL_RELEASE}"
        DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
endif()

if(WIN32 AND NOT SNOW_SHOT_RELEASE_STATIC)
    get_filename_component(_SNOW_SHOT_OPENCV_PREFIX
        "${OpenCV_DIR}/../.."
        ABSOLUTE
    )
    file(GLOB _SNOW_SHOT_OPENCV_RELEASE_RUNTIME_FILES
        "${_SNOW_SHOT_OPENCV_PREFIX}/bin/*.dll"
    )
    file(GLOB _SNOW_SHOT_OPENCV_DEBUG_RUNTIME_FILES
        "${_SNOW_SHOT_OPENCV_PREFIX}/debug/bin/*.dll"
    )
    if(_SNOW_SHOT_OPENCV_RELEASE_RUNTIME_FILES)
        install(FILES ${_SNOW_SHOT_OPENCV_RELEASE_RUNTIME_FILES}
            DESTINATION ${CMAKE_INSTALL_BINDIR}
            CONFIGURATIONS Release RelWithDebInfo MinSizeRel
        )
    endif()
    if(_SNOW_SHOT_OPENCV_DEBUG_RUNTIME_FILES)
        install(FILES ${_SNOW_SHOT_OPENCV_DEBUG_RUNTIME_FILES}
            DESTINATION ${CMAKE_INSTALL_BINDIR}
            CONFIGURATIONS Debug
        )
    endif()

    if(SNOW_SHOT_FFMPEG_RUNTIME_FILES)
        install(FILES ${SNOW_SHOT_FFMPEG_RUNTIME_FILES}
            DESTINATION ${CMAKE_INSTALL_BINDIR}
        )
    endif()
endif()

if(WIN32 AND NOT SNOW_SHOT_QT_STATIC)
    set(_snow_shot_qt_deploy_arguments)
    # The release staging policy keeps only the platform and Schannel TLS
    # plugins. Snow Shot uses its project-owned resources and statically linked
    # image codecs, so Qt's optional image, style, and generic plugins are not
    # needed in the installer.
    list(APPEND _snow_shot_qt_deploy_arguments
        EXCLUDE_PLUGIN_TYPES
            generic
            iconengines
            imageformats
            networkinformation
            styles
        EXCLUDE_PLUGINS
            qcertonlybackend
    )
    if(SNOW_SHOT_RELEASE_STATIC)
        list(APPEND _snow_shot_qt_deploy_arguments
            NO_COMPILER_RUNTIME
            DEPLOY_TOOL_OPTIONS
                --release
        )
    endif()
    qt_generate_deploy_app_script(
        TARGET snow_shot
        OUTPUT_SCRIPT SNOW_SHOT_QT_DEPLOY_SCRIPT
        NO_UNSUPPORTED_PLATFORM_ERROR
        ${_snow_shot_qt_deploy_arguments}
    )
    install(SCRIPT "${SNOW_SHOT_QT_DEPLOY_SCRIPT}")

    # Qt's deployment helper copies every Qt base translation catalog. Snow
    # Shot ships only en_US, zh_CN, and zh_TW application catalogs, so retain
    # only the corresponding Qt catalogs in the final install tree.
    install(CODE [=[
        set(_snow_shot_qt_translation_dir
            "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/translations")
        set(_snow_shot_allowed_qt_translations
            qt_en.qm
            qt_zh_CN.qm
            qt_zh_TW.qm
        )
        if(IS_DIRECTORY "${_snow_shot_qt_translation_dir}")
            file(GLOB _snow_shot_qt_translation_catalogs
                "${_snow_shot_qt_translation_dir}/qt_*.qm")
            foreach(_snow_shot_qt_catalog IN LISTS _snow_shot_qt_translation_catalogs)
                get_filename_component(_snow_shot_qt_catalog_name
                    "${_snow_shot_qt_catalog}" NAME)
                if(NOT _snow_shot_qt_catalog_name IN_LIST _snow_shot_allowed_qt_translations)
                    file(REMOVE "${_snow_shot_qt_catalog}")
                endif()
            endforeach()
        endif()
        unset(_snow_shot_qt_translation_dir)
        unset(_snow_shot_allowed_qt_translations)
        unset(_snow_shot_qt_translation_catalogs)
        unset(_snow_shot_qt_catalog)
        unset(_snow_shot_qt_catalog_name)
    ]=])

    # windeployqt deploys optional Qt plugins based on broad module metadata.
    # Snow Shot only needs the Windows platform integration and the Schannel
    # TLS backend at runtime. Remove optional image, style, input,
    # network-information, icon-engine, and certificate-only backends.
    install(CODE [=[
        set(_snow_shot_qt_plugin_dir
            "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/plugins")
        set(_snow_shot_allowed_qt_plugins
            platforms/qwindows.dll
            tls/qschannelbackend.dll
        )
        if(IS_DIRECTORY "${_snow_shot_qt_plugin_dir}")
            file(GLOB_RECURSE _snow_shot_qt_plugin_files
                RELATIVE "${_snow_shot_qt_plugin_dir}"
                "${_snow_shot_qt_plugin_dir}/*.dll")
            foreach(_snow_shot_qt_plugin IN LISTS _snow_shot_qt_plugin_files)
                if(NOT _snow_shot_qt_plugin IN_LIST _snow_shot_allowed_qt_plugins)
                    file(REMOVE "${_snow_shot_qt_plugin_dir}/${_snow_shot_qt_plugin}")
                endif()
            endforeach()
        endif()
        unset(_snow_shot_qt_plugin_dir)
        unset(_snow_shot_allowed_qt_plugins)
        unset(_snow_shot_qt_plugin_files)
        unset(_snow_shot_qt_plugin)
    ]=])
endif()

if(SNOW_SHOT_QT_STATIC)
    # Static Qt does not load these plugins from a deployment directory.
    # Import only the integrations required by the Windows release binary.
    qt_import_plugins(snow_shot
        NO_DEFAULT
        INCLUDE
            Qt6::QWindowsIntegrationPlugin
            Qt6::QSchannelBackendPlugin
    )
endif()

set(SNOW_SHOT_LICENSE_FILES "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
foreach(_license_file IN ITEMS
    "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-ocr-c/THIRD_PARTY_NOTICES.md"
    "${SNOW_SHOT_CAPTURE_CRATES_DIR}/crates/snow-ocr-c/assets/onnxruntime/LICENSE.txt"
)
    if(EXISTS "${_license_file}")
        list(APPEND SNOW_SHOT_LICENSE_FILES "${_license_file}")
    endif()
endforeach()
if(SNOW_SHOT_LICENSE_FILES)
    install(FILES ${SNOW_SHOT_LICENSE_FILES}
        DESTINATION "${CMAKE_INSTALL_DATADIR}/snow-shot/licenses"
    )
endif()

qt_finalize_executable(snow_shot)
