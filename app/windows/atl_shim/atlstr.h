// Minimal stand-in for ATL's <atlstr.h>.
//
// flutter_secure_storage_windows (legacy Credential Manager code) includes
// <atlstr.h>, which only ships with the Visual Studio "C++ ATL" component.
// The plugin uses nothing from it except the CA2W / CW2A string converters,
// so when ATL is not installed, windows/CMakeLists.txt points the plugin at
// this header instead. If ATL is installed, the real header is used and this
// file is ignored.
#ifndef TRACKONE_ATL_SHIM_ATLSTR_H_
#define TRACKONE_ATL_SHIM_ATLSTR_H_

#include <windows.h>

#include <string>

// char* -> wchar_t* (ANSI code page, same default as ATL)
class CA2W {
 public:
  explicit CA2W(LPCSTR src, UINT code_page = CP_ACP) {
    const int n = src ? ::MultiByteToWideChar(code_page, 0, src, -1, nullptr, 0) : 0;
    buffer_.assign(n > 0 ? n : 1, L'\0');
    if (n > 0) ::MultiByteToWideChar(code_page, 0, src, -1, &buffer_[0], n);
    m_psz = &buffer_[0];
  }
  CA2W(const CA2W&) = delete;
  CA2W& operator=(const CA2W&) = delete;
  operator LPWSTR() const { return m_psz; }

  LPWSTR m_psz;

 private:
  std::wstring buffer_;
};

// wchar_t* -> char* (ANSI code page, same default as ATL)
class CW2A {
 public:
  explicit CW2A(LPCWSTR src, UINT code_page = CP_ACP) {
    const int n = src ? ::WideCharToMultiByte(code_page, 0, src, -1, nullptr, 0, nullptr, nullptr) : 0;
    buffer_.assign(n > 0 ? n : 1, '\0');
    if (n > 0) ::WideCharToMultiByte(code_page, 0, src, -1, &buffer_[0], n, nullptr, nullptr);
    m_psz = &buffer_[0];
  }
  CW2A(const CW2A&) = delete;
  CW2A& operator=(const CW2A&) = delete;
  operator LPSTR() const { return m_psz; }

  LPSTR m_psz;

 private:
  std::string buffer_;
};

#endif  // TRACKONE_ATL_SHIM_ATLSTR_H_
