#pragma once

#include <windows.h>

#include <cstdio>
#include <sstream>
#include <string>

inline void DebugLog(const std::string& msg) {
  std::string line = "[camera_desktop/windows] " + msg + "\n";
  OutputDebugStringA(line.c_str());
  std::fputs(line.c_str(), stderr);
  std::fflush(stderr);
}

inline std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(),
                                 nullptr, 0, nullptr, nullptr);
  std::string s(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(),
                      s.data(), size, nullptr, nullptr);
  return s;
}

inline std::string HrToString(HRESULT hr) {
  std::ostringstream ss;
  ss << "0x" << std::hex << static_cast<unsigned long>(hr);
  return ss.str();
}
