# Microsoft Visual C++ Runtime prerequisite

Feather does not bundle Microsoft Visual C++ Runtime DLLs or the Microsoft runtime installer, and does not automatically install a system runtime or accept its license terms.

Some bundled subtitle components use the Microsoft Visual C++ v14 x64 Runtime. If those dependencies are missing, the application should explain the requirement and let the user explicitly open Microsoft's official download page to install it themselves.

Official sources:

- Latest supported download page: https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist
- Microsoft x64 runtime download permalink: https://aka.ms/vc14/vc_redist.x64.exe
- Current Runtime license directory: https://visualstudio.microsoft.com/license-terms/vs2026-ga-visualcpp-v14-redist-runtime/
- Official REDIST list: https://learn.microsoft.com/en-us/visualstudio/releases/2026/redistribution

The Runtime terms and the separate Visual Studio REDIST list have different scopes. Redistribution rights depend on the applicable Visual Studio/Build Tools license terms; the project does not infer that the user holds that license. No Microsoft runtime binaries are included in the distributable or source archive.

A private static inspection of Microsoft's 14.51.36247.0 x64 package found the required `msvcp140.dll`, `msvcp140_1.dll`, `vcruntime140.dll`, `vcruntime140_1.dll` and `vcomp140.dll` families. Inspection artifacts and the exact URL/SHA/PE import/version manifest are outside the product source tree, under `work/windows-validation/runtime-inspection`. This is static evidence, not clean-Windows execution validation.
