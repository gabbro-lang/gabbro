// In-process LLD COFF linker shim. Bundled (with LLD + its LLVM static deps)
// into skarnlld.dll so the compiler can link without spawning a 69 MB lld-link.exe
// each build. Exposes a single C entry point; all LLVM/LLD symbols stay private
// to this DLL, so they never clash with the LLVM-C.dll the codegen path uses.

#include "lld/Common/Driver.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Support/raw_ostream.h"

LLD_HAS_DRIVER(coff)

// libxml2 is not shipped as a usable static lib in this SDK (xml2s.lib is empty),
// yet LLD's COFF driver references it via WindowsManifest. Manifest *merging* is
// never invoked for a normal executable link, so these symbols are referenced
// but never called — stub them so the DLL links. (Link a real libxml2 if you
// ever need `/manifest:embed` merging at comptime.)
extern "C" {
void *xmlReadMemory(const char *, int, const char *, const char *, int) { return nullptr; }
void *xmlDocGetRootElement(void *) { return nullptr; }
void xmlDocSetRootElement(void *, void *) {}
void *xmlNewDoc(const unsigned char *) { return nullptr; }
void *xmlNewNs(void *, const unsigned char *, const unsigned char *) { return nullptr; }
void *xmlNewProp(void *, const unsigned char *, const unsigned char *) { return nullptr; }
void *xmlAddChild(void *, void *) { return nullptr; }
void *xmlCopyNamespace(void *) { return nullptr; }
unsigned char *xmlStrdup(const unsigned char *) { return nullptr; }
void xmlUnlinkNode(void *) {}
void xmlFreeNode(void *) {}
void xmlFreeNs(void *) {}
void xmlFreeDoc(void *) {}
void xmlSetGenericErrorFunc(void *, void *) {}
int xmlDocDumpFormatMemoryEnc(void *, unsigned char **, int *, const char *, int) { return 0; }
// xmlFree is a function-pointer global in libxml2, not a function.
void (*xmlFree)(void *) = nullptr;
}

// Returns 0 on success, non-zero on link failure. argv[0] must be the linker
// name ("lld-link"); the rest are normal lld-link arguments.
extern "C" __declspec(dllexport) int skarn_lld_link_coff(int argc, const char **argv) {
    llvm::ArrayRef<const char *> args(argv, static_cast<size_t>(argc));
    const bool ok = lld::coff::link(args, llvm::outs(), llvm::errs(),
                                    /*exitEarly=*/false, /*disableOutput=*/false);
    return ok ? 0 : 1;
}
