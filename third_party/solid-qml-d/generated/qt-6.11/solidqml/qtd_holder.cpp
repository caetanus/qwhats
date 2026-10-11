// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// qtd_holder.cpp — C support for the D wrapper lifetime layer. QtCore-only.
//
// The identity map lives HERE (C++ side) on purpose: the D GC does not scan C++
// memory, so a D wrapper stored here is NOT pinned by it — the map is naturally
// "weak". Pinning of parented children is done separately on the D side. Verified:
// a D object referenced only from this map is collectable.
#include <QObject>
#include <QCoreApplication>
#include <unordered_map>
#include <unordered_set>
#include <mutex>

extern "C" {

typedef void (*QtdDestroyedFn)(void *cptr);
static QtdDestroyedFn g_onDestroyed = nullptr;

// cptr -> D wrapper (an opaque void*). Weak from D's point of view. HEAP-allocated and
// never freed on purpose: a D GC finalizer can run during process teardown AFTER C++ static
// destructors, so a static map object would be a use-after-free (destruction-order fiasco).
static std::unordered_map<void *, void *> &g_wrappers() {
    static std::unordered_map<void *, void *> *m = new std::unordered_map<void *, void *>();
    return *m;
}

// The map is touched from any thread: the GC finalizer of a wrapper runs on whichever
// thread triggered the collection, while the Qt thread registers new wrappers. Same
// lifetime rule as the map (heap, never freed).
static std::recursive_mutex &g_lock() {
    static std::recursive_mutex *m = new std::recursive_mutex();
    return *m;
}

void qtd_holder_set_destroyed_hook(QtdDestroyedFn fn) { g_onDestroyed = fn; }

// Which objects already have the destroyed() connection below. NOT answerable from g_wrappers:
// that map is erased when a WRAPPER dies, which for a borrowed pointer happens while the C++
// object is still alive and still connected. Without this set, every re-wrap of such an object
// added another connection to it — measured at 20 hooks for 20 re-wraps of one object, a list
// that only ever grows on a long-lived sender. Same lifetime rule as the map (heap, never freed).
static std::unordered_set<void *> &g_tracked() {
    static std::unordered_set<void *> *m = new std::unordered_set<void *>();
    return *m;
}

// Route obj->destroyed() to the D hook; the connection dies with the object and
// forwards the dying pointer as the map key. ONCE PER OBJECT — see g_tracked.
void qtd_holder_track(void *obj) {
    {
        std::lock_guard<std::recursive_mutex> g(g_lock());
        if (!g_tracked().insert(obj).second) return;   // already connected
    }
    QObject *o = static_cast<QObject *>(obj);
    QObject::connect(o, &QObject::destroyed, [](QObject *dead) {
        void *p = static_cast<void *>(dead);
        { std::lock_guard<std::recursive_mutex> g(g_lock()); g_tracked().erase(p); }
        if (g_onDestroyed) g_onDestroyed(p);
    });
}

// A parented QObject is owned by Qt (deleted with its parent) — D must not delete it.
int  qtd_holder_has_parent(void *obj) { return static_cast<QObject *>(obj)->parent() != nullptr ? 1 : 0; }
void qtd_holder_delete_later(void *obj) { static_cast<QObject *>(obj)->deleteLater(); }
// The QApplication/QCoreApplication singleton must NEVER be finalize-deleted (deleteLater'ing
// it tears down the platform plugin under Qt's feet). The user owns it for the app's lifetime.
int  qtd_holder_is_app(void *obj) { return obj == QCoreApplication::instance() ? 1 : 0; }

// Is this QObject an instance of the C++ class `cls` (or derived from it)? The meta-object chain
// answers, which is what qobject_cast asks too — so it holds for a D subclass's builder meta-object.
int  qtd_holder_inherits(void *obj, const char *cls) { return static_cast<QObject *>(obj)->inherits(cls) ? 1 : 0; }

// identity map
void  qtd_holder_reg(void *cptr, void *wrapper) { std::lock_guard<std::recursive_mutex> g(g_lock()); g_wrappers()[cptr] = wrapper; }
void *qtd_holder_find(void *cptr) { std::lock_guard<std::recursive_mutex> g(g_lock()); auto it = g_wrappers().find(cptr); return it == g_wrappers().end() ? nullptr : it->second; }
void  qtd_holder_unreg(void *cptr) { std::lock_guard<std::recursive_mutex> g(g_lock()); g_wrappers().erase(cptr); }
// How many C++ pointers currently have a live D wrapper. A leak probe watches this: it is the
// only number that grows when wrappers are created and not released, and it cannot be faked by
// a run that does nothing (an idle run leaves it flat, which is what makes the reading falsifiable).
size_t qtd_holder_count(void) { std::lock_guard<std::recursive_mutex> g(g_lock()); return g_wrappers().size(); }

} // extern "C"
