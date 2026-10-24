// Minimal stand-in for ATL's <atlbase.h>.
//
// flutter_local_notifications_windows includes <atlbase.h> but only uses the
// CW2A string converter, which atlstr.h (our stand-in) already provides.
// windows/CMakeLists.txt points the plugin here only when the Visual Studio
// "C++ ATL" component is not installed.
#ifndef TRACKONE_ATL_SHIM_ATLBASE_H_
#define TRACKONE_ATL_SHIM_ATLBASE_H_

#include "atlstr.h"

#endif  // TRACKONE_ATL_SHIM_ATLBASE_H_
