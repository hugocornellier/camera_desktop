#pragma once

// TEST ONLY. A live Media Foundation source that behaves like a webcam but
// produces solid red YUY2 frames, so CI machines without a camera can run the
// real capture pipeline end to end. Compiled into the plugin only when the
// CAMERA_DESKTOP_FAKE_CAMERA environment variable is set at build time (see
// CMakeLists.txt); release builds never contain it.

#ifdef CAMERA_DESKTOP_FAKE_CAMERA

#include <windows.h>
#include <mfidl.h>

// Symbolic link and friendly name the fake camera is listed under.
constexpr wchar_t kFakeCameraSymbolicLink[] = L"camera_desktop_fake_camera";
constexpr wchar_t kFakeCameraFriendlyName[] = L"Fake Red Camera";

// Creates a new fake camera media source.
HRESULT CreateFakeCameraSource(IMFMediaSource** out);

#endif  // CAMERA_DESKTOP_FAKE_CAMERA
