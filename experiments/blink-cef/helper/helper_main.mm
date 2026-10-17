// Entry point for every Chromium helper process (renderer, GPU, utility, plugin, alerts).
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
    // Chromium's macOS sandbox is initialised before the framework is loaded; it must not be skipped.
    CefScopedSandboxContext sandbox_context;
    if (!sandbox_context.Initialize(argc, argv)) return 1;

    CefScopedLibraryLoader library_loader;
    if (!library_loader.LoadInHelper()) return 1;

    CefMainArgs main_args(argc, argv);
    return CefExecuteProcess(main_args, nullptr, nullptr);
}
