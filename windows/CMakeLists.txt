cmake_minimum_required(VERSION 3.14)
project(camera_desktop LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(PLUGIN_NAME "camera_desktop_plugin")

add_library(${PLUGIN_NAME} SHARED
  camera_desktop_plugin.cpp
  camera.cpp
  camera_texture.cpp
  device_enumerator.cpp
  image_stream_ffi.cpp
  photo_handler.cpp
  record_handler.cpp
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

if(MSVC)
  # Force MSVC to read source (and emit narrow string literals) as UTF-8,
  # regardless of the host's ANSI code page. Without this, hosts with a
  # non-UTF-8 ACP (e.g. CP936 on Simplified Chinese Windows) fail with C4819
  # → C2220 on our Unicode comments. See chinese-pc-compat.md.
  target_compile_options(${PLUGIN_NAME} PRIVATE /utf-8)
endif()

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  mf
  mfplat
  mfreadwrite
  mfuuid
  ole32
  strmiids
  uuid
  windowscodecs
  d3d11
  dxgi
)
