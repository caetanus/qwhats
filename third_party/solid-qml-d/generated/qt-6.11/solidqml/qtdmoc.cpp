// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Generic meta-object runtime for QObjects defined in D (without moc).
// A single QtdMocObject trampoline builds its QMetaObject at runtime
// via QMetaObjectBuilder from signatures the D side provides (extracted
// by CTFE). qt_metacall maps: signal indices -> activate; slot indices -> D.
#include <memory>
#include <QObject>
#ifdef QT_QML_LIB
#include <QtQml/QQmlPropertyValueSource>
#include <QtQml/QQmlProperty>
#endif
#include <QString>
#include <QMetaProperty>
#include <QMetaEnum>
#include <QMetaMethod>
#ifdef QT_GUI_LIB
// QGuiApplication alone: the result is handed out as an opaque void* and every member below it is
// reached through the meta-object, so neither QStyleHints nor QAccessibilityHints needs to be a
// complete type here. Including them would also have pinned this file to Qt 6.10+, where
// qaccessibilityhints.h first exists — Qt5 has no such header and the whole binding stopped
// compiling.
#  include <QGuiApplication>
// QColor is a VALUE type and the only one this file constructs, for Qt.darker/Qt.lighter — the
// two QML globals with no object behind them.
#  include <QtGui/QColor>
#endif
#include <QMetaType>
#include <QCoreApplication>
#include <QTranslator>
#include <QtCore/private/qmetaobjectbuilder_p.h>
#include <cstring>
#include <type_traits>
#include <utility>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <string>
#include <unordered_map>
#include <vector>
#include <algorithm>
#include <thread>
#include <mutex>

// QML type registration is compiled in ONLY when reggae defines QTD_ENABLE_QML — i.e. the
// binding's pkg-config modules include Qt5Qml or Qt6Qml. (An __has_include probe does NOT work:
// the base `-I…/qt6` exposes QtQml headers to EVERY binding, so a widgets binding would wrongly
// pull in QQmlPrivate::qmlregister and fail to link against QtQml.) Widgets/core stay QtQml-free.
// The QQmlPrivate::RegisterType layout differs between Qt5 and Qt6 — handled below via QT_VERSION.
#ifdef QTD_ENABLE_QML
#  define QTD_HAVE_QML 1
#  include <QtQml/qqmlprivate.h>
#  include <QtQml/qqmllist.h>
#  include <QtQml/qqmlparserstatus.h>
#  include <QtQml/QQmlEngine>
#  include <QtQml/QJSValue>
#  include <QtQml/QQmlListProperty>
#  include <QtQml/QQmlContext>
#  include <QtQml/QQmlExpression>
#  include <QtQml/QQmlComponent>
#  if QT_VERSION >= 0x060000
#    include <QtQml/private/qqmlmetatype_p.h>
// A property value INTERCEPTOR is installed on the property rather than handed it, and the only way
// in from outside is QQmlInterceptorMetaObject — Q_QML_EXPORTed, PRIVATE header. Qt6 only: Qt5 has
// no such entry point.
#    include <QtQml/private/qqmlpropertyvalueinterceptor_p.h>
#    include <QtQml/private/qqmlvmemetaobject_p.h>
#    include <QtQml/private/qqmldata_p.h>
#    include <QtQml/qqml.h>
#  endif
#  include <array>
#  include <utility>
#endif


extern "C" {

// D callback that dispatches a slot: (D object, slot-local-index, Qt args)
typedef void (*QtdSlotCb)(void* dobj, int slotIdx, void** args);
// D property callback: (D object, local-index, write?, value slot a[0])
typedef void (*QtdPropCb)(void* dobj, int propIdx, int write, void** args);
// D callback invoked when a moc object is destroyed -> drops the D registry entry (_reg).
typedef void (*QtdMocDestroyCb)(void* dobj);

namespace {
QtdMocDestroyCb g_mocDestroy = nullptr;   // set once by D (qtd_moc_set_destroy_cb) at module init
static void qtd_moc_teardown(void* self, void* dobj);   // side-table cleanup (defined below)

// ---- thread affinity (critics r8 #6) ---------------------------------------
// Every runtime side-table is unsynchronized global mutable state: g_moCache/g_moAttach here,
// _reg/_qmlFactories/_qmlRegistered on the D side, _pinned in the holder. The runtime is
// single-threaded BY DESIGN (as holder.d already declares). Rather than silent UB when a second
// thread mutates a map (rehash mid-read = memory corruption), the FIRST mutation pins an owner
// thread and any mutation from another thread aborts LOUDLY with the offending op. Deterministic,
// never a corrupted map. Reads on the hot dispatch path stay lock-free. Real per-thread/locked
// tables for worker QObjects (QThread/networking/timers) are a tracked STRUCTURAL follow-up — this
// makes the current limitation explicit and ENFORCED instead of assumed.
std::mutex g_ownerMx;
std::thread::id g_ownerThread;
bool g_ownerSet = false;
static void qtd_thread_guard(const char* op) {
    std::lock_guard<std::mutex> lk(g_ownerMx);
    auto self = std::this_thread::get_id();
    if (!g_ownerSet) { g_ownerThread = self; g_ownerSet = true; return; }
    if (self != g_ownerThread) {
        std::fprintf(stderr, "qtd FATAL: meta-object runtime mutated off its owner thread "
            "(op=%s). The qtd moc/QML runtime is single-threaded — create and destroy D "
            "@QObjects only on the thread that first used it.\n", op);
        std::abort();
    }
}
#ifdef QTD_HAVE_QML
static void qtd_qml_on_destroy(void* self);   // QML-created instance teardown (defined below)
#endif
struct QtdMocObject : QObject {
    const QMetaObject* mo;
    void* dobj;
    QtdSlotCb slotcb;
    QtdPropCb propcb;
    int nsig, nslot, nprop;
#ifdef QTD_HAVE_QML
    void* qmlUserdata = nullptr;   // non-null iff QML created this instance (QtdQmlType*)
#endif
    ~QtdMocObject() override {
#ifdef QTD_HAVE_QML
        if (qmlUserdata) { qtd_qml_on_destroy(this); return; }   // QML path cleans both side-tables
#endif
        // Non-QML (newQObject): drop both side-tables so a destroyed object doesn't leak an
        // entry (nor let a reused pointer alias a stale one). g_mocDestroy clears the D _reg.
        qtd_moc_teardown(this, dobj);
    }
    // A DYNAMIC meta-object installed on us wins — that is what QObject::metaObject() itself does.
    // QML installs a QQmlVMEMetaObject whenever a .qml declares members on an instance
    // (`property int doubled: value * 2`); it chains OUR `mo` as its parent. Returning `mo`
    // unconditionally made those QML-declared members invisible: they were never created, and
    // reading one gave an empty QVariant instead of its bound value.
    const QMetaObject* metaObject() const override {
        return d_ptr->metaObject ? d_ptr->dynamicMetaObject() : mo;
    }
    // A Qt moc first matches the class's OWN name (returns this), THEN delegates to base.
    // The old body skipped step 1 -> qt_metacast("Dup") on a runtime `Dup` returned null even
    // though metaObject()->className() is "Dup" (critics r8 #2). qobject_cast/interfaces/name
    // discovery all depend on this. mocClassName() is a strcmp-normalized className.
    void* qt_metacast(const char* n) override {
        if (n && mo && std::strcmp(n, mo->className()) == 0) return this;
        return QObject::qt_metacast(n);
    }
    int qt_metacall(QMetaObject::Call c, int id, void** a) override {
        id = QObject::qt_metacall(c, id, a);
        if (id < 0) return id;
        if (c == QMetaObject::InvokeMetaMethod) {
            if (id < nsig) QMetaObject::activate(this, mo, id, a);   // signal relay
            else if (dobj) slotcb(dobj, id - nsig, a);               // slot -> D (guard: failed QML
                                                                     // instance has no backing obj, r8 #5)
            id -= (nsig + nslot);
        } else if (c == QMetaObject::ReadProperty || c == QMetaObject::WriteProperty) {
            if (propcb && dobj && id < nprop)                        // prop <-> D (dobj-guarded)
                propcb(dobj, id, c == QMetaObject::WriteProperty, a);
            id -= nprop;
        }
        return id;
    }
};

// meta-object built once per SHAPE. `super` = the superclass meta (QObject for
// QtdMocObject; QWidget/etc. for subclass trampolines). The cache key is the class name PLUS
// the super's name PLUS every signal/slot/property signature — NOT the name alone (critics r6 #6:
// two homonymous D classes with different shapes would otherwise share, and get, the wrong
// metaobject). Two identically-shaped homonyms still share (harmless — they ARE the same shape).
std::unordered_map<std::string, const QMetaObject*> g_moCache;
// A declared QML list property is `QQmlListProperty<QObject>`, and TWO registrations are needed
// before one works — probed one at a time against a QMetaObjectBuilder-built object:
//   * the METATYPE, or QMetaProperty::read hands back a QVariant with an invalid type and the
//     property dump dies inside QMetaType::canConvert;
//   * the list's ELEMENT type in QQmlMetaType, or `listElementType()` is null and
//     QQmlListReference::append refuses every non-null object while happily taking a null one
//     (that asymmetry is what named it).
// From a FUNCTION, not a file-scope static: the link uses --gc-sections, and a static whose value
// nothing reads is exactly what that removes — the registration silently never ran.
// `extern "C++"` because this file is compiled inside an `extern "C"` region.
#ifdef QTD_HAVE_QML
extern "C++" {
static void qtd_register_list_metatype() {
    static const bool once = [] {
        qRegisterMetaType<QQmlListProperty<QObject>>("QQmlListProperty<QObject>");
        qmlRegisterAnonymousType<QObject>("qtd.list", 1);
        return true;
    }();
    (void) once;
}
}
#endif
const QMetaObject* buildMo(const char* cn, const QMetaObject* super,
                           const char** sigs, int nsig,
                           const char** slotSigs, int nslot,
                           const char** propNames, const char** propTypes,
                           const int* propNotify, int nprop) {
    qtd_thread_guard("buildMo");   // mutates g_moCache
    std::string key(cn);
    key += '\x1'; key += (super ? super->className() : "");
    for (int i = 0; i < nsig; ++i)  { key += '\x2'; key += sigs[i]; }
    for (int i = 0; i < nslot; ++i) { key += '\x3'; key += slotSigs[i]; }
    for (int i = 0; i < nprop; ++i) {   // name:type@notify — NOTIFY participates too (critics r7 #3)
        key += '\x4'; key += propNames[i]; key += ':'; key += propTypes[i];
        key += '@'; key += std::to_string(propNotify[i]);
    }
    auto it = g_moCache.find(key);
    if (it != g_moCache.end()) return it->second;
    QMetaObjectBuilder b;
    b.setClassName(cn);
    b.setSuperClass(super);
    // A class WE built, said in the meta-object itself rather than guessed from its name. The dump
    // answers `__class` by walking to the first Qt class, and "Qt" was decided by a leading 'Q' —
    // a compiled document named QDelegateKidCtx.qml produces QDelegateKidCtx_dc0_delegate, which
    // passes that test and made every delegate item in the QtQuick fixture set report our class
    // name against the engine's QQuickItem. The channel already carries this kind of fact.
    b.addClassInfo("qtdGenerated", "1");
    for (int i = 0; i < nsig; ++i)  b.addSignal(sigs[i]);
    // A RETURN TYPE TRAVELS INSIDE THE SIGNATURE, after `->`. Qt's meta-object distinguishes a
    // SLOT (returns void) from an INVOKABLE (returns something), and until now this builder could
    // only make the first — so a QML function that returns a value was emitted as a plain D method
    // the meta-object never saw, and the engine answered
    //     TypeError: Property 'visibleIndex' of object Main_dc9 is not a function
    // about a function the document declares (bugs.md #9, criterion 4).
    //
    // Encoded in the string rather than passed as another array, because `buildMo` has four
    // callers and `qtd_moc_new` is one of them: a separator no existing signature can contain
    // costs nothing at any of them, and the cache key below already hashes the raw strings.
    for (int i = 0; i < nslot; ++i) {
        const char* arrow = std::strstr(slotSigs[i], "->");
        if (!arrow) { b.addSlot(slotSigs[i]); continue; }
        QMetaMethodBuilder m = b.addMethod(QByteArray(slotSigs[i], int(arrow - slotSigs[i])));
        m.setReturnType(QByteArray(arrow + 2));
    }
    for (int i = 0; i < nprop; ++i) {
        // An OBJECT property is declared by its precise type (`QQuickItem*`), and that name only
        // resolves to a QMetaType if something in the process instantiated one — QtQuick registers
        // its QML types, not a metatype under every pointer name. A property with NO metatype
        // cannot be written at all: QVariant has nothing to convert to, so `control: control` on
        // Qt's Fusion indicators silently left the property null and every read through it came
        // back empty. QObject* is always registered and always convertible, and every read here
        // goes through the meta-object by NAME, which never consults the declared type. So the
        // precise name is kept whenever it resolves, and falls back only when it does not.
        const char* pty = propTypes[i];
        size_t plen = std::strlen(pty);
#ifdef QTD_HAVE_QML
        if (std::strcmp(pty, "QQmlListProperty<QObject>") == 0) qtd_register_list_metatype();
#endif
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        bool known = QMetaType::fromName(pty).isValid();
#else
        bool known = QMetaType::type(pty) != QMetaType::UnknownType;
#endif
        if (plen > 1 && pty[plen - 1] == '*' && !known) pty = "QObject*";
        QMetaPropertyBuilder p = b.addProperty(propNames[i], pty);
        p.setReadable(true); p.setWritable(true);
        if (propNotify[i] >= 0) p.setNotifySignal(b.method(propNotify[i]));  // signals are the first methods
    }
    const QMetaObject* mo = b.toMetaObject();
    g_moCache[key] = mo;
    return mo;
}

// GENERIC moc attachable to a subclass trampoline (qtvirt): the meta-object
// logic lives here (per-object side-table), so the per-class trampoline only
// delegates metaObject/qt_metacall. Used when a D class subclasses a Qt
// widget AND is @QObject (its own signals/slots/props) — e.g.: CannonField.
struct MocInfo {
    const QMetaObject* mo; void* dobj; QtdSlotCb slotcb; QtdPropCb propcb;
    int nsig, nslot, nprop;
};
std::unordered_map<void*, MocInfo> g_moAttach;   // key = the QObject* (the trampoline's self)
// Drop both side-tables for a destroyed moc object (the D _reg via g_mocDestroy, g_moAttach here).
static void qtd_moc_teardown(void* self, void* dobj) {
    qtd_thread_guard("teardown");   // erases g_moAttach (+ D _reg via g_mocDestroy)
    g_moAttach.erase(self);
    if (g_mocDestroy && dobj) g_mocDestroy(dobj);
}
} // namespace

// attaches a meta-object to `self` (the already-built trampoline). `super` = &Base::staticMetaObject.
void qtd_moc_attach(void* self, const char* cn, const void* super,
                    const char** sigs, int nsig, const char** slotSigs, int nslot,
                    const char** propNames, const char** propTypes, const int* propNotify, int nprop,
                    void* dobj, QtdSlotCb slotcb, QtdPropCb propcb) {
    qtd_thread_guard("moc_attach");   // inserts g_moAttach
    MocInfo mi;
    mi.mo = buildMo(cn, static_cast<const QMetaObject*>(super),
                    sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    mi.dobj = dobj; mi.slotcb = slotcb; mi.propcb = propcb;
    mi.nsig = nsig; mi.nslot = nslot; mi.nprop = nprop;
    g_moAttach[self] = mi;
}
// for the trampoline's metaObject() override: the attached mo, or null if not attached.
const void* qtd_moc_meta(void* self) {
    auto it = g_moAttach.find(self);
    return it != g_moAttach.end() ? it->second.mo : nullptr;
}
// for the trampoline's qt_metacast(): matches the attached metaobject's className before
// delegating to the base. Without it, qt_metacast("Sub") on a QtdWidget!Sub returned null even with
// metaObject()->className()=="Sub" (critics r8 #2), breaking qobject_cast and type discovery.
bool qtd_moc_classmatch(void* self, const char* n) {
    if (!n) return false;
    auto it = g_moAttach.find(self);
    return it != g_moAttach.end() && it->second.mo &&
           std::strcmp(n, it->second.mo->className()) == 0;
}
// Identity probes (for the r8 #2 test): qt_metacast by name and the metaobject's className.
extern "C" void* qtd_metacast(void* qobj, const char* n) {
    return qobj ? static_cast<QObject*>(qobj)->qt_metacast(n) : nullptr;
}
extern "C" const char* qtd_moc_classname(void* qobj) {
    return qobj ? static_cast<QObject*>(qobj)->metaObject()->className() : nullptr;
}
// for the trampoline's qt_metacall() override (called AFTER Base::qt_metacall).
int qtd_moc_metacall(void* self, int c, int id, void** a) {
    auto it = g_moAttach.find(self);
    if (it == g_moAttach.end()) return id;
    MocInfo& mi = it->second;
    if (c == QMetaObject::InvokeMetaMethod) {
        if (id < mi.nsig) QMetaObject::activate(static_cast<QObject*>(self), mi.mo, id, a);
        // Guarded exactly like QtdMocObject::qt_metacall above: a QML instance whose D
        // constructor threw has no backing object, and dispatching into it crashes (r8 #5). This
        // copy was missing both guards while the other had them — the two had drifted, which is
        // the hazard of keeping two demuxes. They stay separate on purpose (that one reads the
        // object's own fields on the hot path; this one serves trampolines, which have none), so
        // ANY change to one belongs in the other.
        else if (mi.slotcb && mi.dobj) mi.slotcb(mi.dobj, id - mi.nsig, a);
        id -= (mi.nsig + mi.nslot);
    } else if (c == QMetaObject::ReadProperty || c == QMetaObject::WriteProperty) {
        if (mi.propcb && mi.dobj && id < mi.nprop) mi.propcb(mi.dobj, id, c == QMetaObject::WriteProperty, a);
        id -= mi.nprop;
    }
    return id;
}

// D registers here (once, at module init) the callback that clears the D registry on destruction.
void qtd_moc_set_destroy_cb(QtdMocDestroyCb cb) { g_mocDestroy = cb; }
// Called by the subclass trampoline's destructor (Qtd_<Base>, generated) when Qt destroys it:
// drops g_moAttach[self] AND the D object's _reg entry. Closes the QtdWidget path (not just the
// QtdMocObject from newQObject).
void qtd_moc_detach(void* self, void* dobj) { qtd_moc_teardown(self, dobj); }
// diagnostic/test: live entries in the side-table; and deletes a QtdMocObject (its dtor cleans everything).
size_t qtd_moc_attach_count() { return g_moAttach.size(); }
// Owner-thread inspection for tests (does NOT abort): 1 = current thread IS the owner,
// 0 = an owner is set and current thread is NOT it, -1 = no owner pinned yet (critics r8 #6).
int qtd_moc_owner_check() {
    std::lock_guard<std::mutex> lk(g_ownerMx);
    if (!g_ownerSet) return -1;
    return std::this_thread::get_id() == g_ownerThread ? 1 : 0;
}
void qtd_moc_delete(void* o) { delete static_cast<QtdMocObject*>(o); }
// deletes ANY QObject via the virtual dtor (works for the Qtd_<Base> trampoline — its ~ calls detach).
void qtd_qobject_delete(void* o) { delete static_cast<QObject*>(o); }

// creates a QObject whose meta-object has the given signals/slots/properties.
void* qtd_moc_new(const char* cn, const char** sigs, int nsig,
                  const char** slotSigs, int nslot,
                  const char** propNames, const char** propTypes, const int* propNotify, int nprop,
                  void* dobj, QtdSlotCb slotcb, QtdPropCb propcb) {
    auto* o = new QtdMocObject();
    o->mo = buildMo(cn, &QObject::staticMetaObject, sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    o->dobj = dobj; o->slotcb = slotcb; o->propcb = propcb;
    o->nsig = nsig; o->nslot = nslot; o->nprop = nprop;
    g_moAttach[o] = MocInfo{o->mo, dobj, slotcb, propcb, nsig, nslot, nprop};  // for the unified activate
    return o;
}

// emits signal index sigIdx (args[0]=return, then values). Unified via
// g_moAttach, so it works for the QtdMocObject AND for subclass trampolines.
void qtd_moc_activate(void* self, int sigIdx, void** args) {
    auto it = g_moAttach.find(self);
    if (it != g_moAttach.end()) QMetaObject::activate(static_cast<QObject*>(self), it->second.mo, sigIdx, args);
}

// QString marshaling for signal/slot args (the D side is fixed runtime and can't
// import the generated QString helpers; here we already link QtCore).
void* qtd_str_to_qs(const char* p, int n) { return new QString(QString::fromUtf8(p, n)); }
void  qtd_qs_free(void* qs) { delete static_cast<QString*>(qs); }
// ReadProperty metacall: a[0] points to an existing QString to assign the value INTO.
void  qtd_qs_set(void* dest, const char* p, int n) { *static_cast<QString*>(dest) = QString::fromUtf8(p, n); }
// ...and NULL is the empty string on this side too (critics r14 #1). D guards it as well; both
// guard it because either one alone is a rule that lives in one place and is read in the other.
int   qtd_qs_utf8len(void* qs) { return qs ? (int) static_cast<QString*>(qs)->toUtf8().size() : 0; }
void  qtd_qs_utf8(void* qs, char* dst) {
    QByteArray b = static_cast<QString*>(qs)->toUtf8();
    memcpy(dst, b.constData(), b.size());
}

// tr(): QCoreApplication::translate(context, source[, disambiguation[, n]]). Returns a heap
// QString* (freed by qtd_qs_free on the D side, like qtd_str_to_qs). No translator installed
// -> Qt returns `source` unchanged, so tr() is always safe to call.
void* qtd_tr(const char* ctx, const char* src, const char* disambig, int n) {
    return new QString(QCoreApplication::translate(ctx, src, disambig, n));
}

// Install a translator that loaded `qmBase` (.qm; empty -> an empty translator). Ensures a
// QCoreApplication exists first (installTranslator needs the app singleton), so it works even
// before the user builds one. Everything is heap-constructed in C++ — no D-side _new/factory.
bool qtd_install_translator(const char* qmBase) {
    if (!QCoreApplication::instance()) {
        static int argc = 1;
        static char arg0[] = "qtd";
        static char* argv[] = { arg0, nullptr };
        new QCoreApplication(argc, argv);
    }
    auto* t = new QTranslator();
    bool ok = (qmBase && *qmBase) ? t->load(QString::fromUtf8(qmBase)) : true;
    QCoreApplication::installTranslator(t);
    return ok;
}

// property access by name via QVariant (runs ReadProperty/WriteProperty on the
// meta-object -> propcb on the D side). Works for custom AND built-in.
// Every property helper below is NULL-GUARDED. These are reached through propObj, which returns
// null whenever a property does not actually hold an object; a null there must be a visible
// no-op/zero, never a crash inside QObject::setProperty.
int  qtd_prop_get_int(void* o, const char* n) { return o ? static_cast<QObject*>(o)->property(n).toInt() : 0; }
// A property write REPORTS whether it landed. QObject::setProperty returns false both when the
// name is not a declared Q_PROPERTY (it then creates a DYNAMIC property, so the write "succeeds"
// while nothing the meta-object knows about changed) and when the QVariant conversion fails.
// Both were indistinguishable from success across ~1400 generated call sites — the same silent
// failure connectMeta was fixed for. The declared-property test comes first so that creating a
// dynamic property is reported as the miss it is.
static int qtd_prop_write(void* o, const char* n, const QVariant& v) {
    if (!o) return 0;
    auto* obj = static_cast<QObject*>(o);
    if (obj->metaObject()->indexOfProperty(n) < 0) return 0;
    return obj->setProperty(n, v) ? 1 : 0;
}

int qtd_prop_set_int(void* o, const char* n, int v) { return qtd_prop_write(o, n, v); }
double qtd_prop_get_double(void* o, const char* n) { if (!o) return 0; return static_cast<QObject*>(o)->property(n).toDouble(); }
int qtd_prop_set_double(void* o, const char* n, double v) { return qtd_prop_write(o, n, v); }
bool qtd_prop_get_bool(void* o, const char* n) { if (!o) return false; return static_cast<QObject*>(o)->property(n).toBool(); }
int qtd_prop_set_bool(void* o, const char* n, bool v) { return qtd_prop_write(o, n, v); }
// A LIST-VALUED property: `model: ["a", "b"]`, `columns: [1, 2, 3]`. One channel for every element
// type rather than one per type, because the element crosses as TEXT and QMetaType converts it —
// the same route every scalar here already travels, and the reason a colour needs no colour-shaped
// function. `typeName` empty (or "QString") keeps the strings as strings, which is what a model
// wants; anything else is converted element by element and an element that will not convert makes
// the whole write fail rather than yielding a list with a hole in it.
//
// Without this the compiler emitted `setProp(this, "model", ["a", "b"])` — a D `string[]` for
// which no overload existed — so a document using the commonest form of a static model produced
// output that did not compile. That is the worst of the three outcomes: not a refusal, not a
// value, but a build failure in someone else's project with no diagnostic pointing back here.
// ASK THE TYPE, NOT THE VERSION NUMBER. Two things in Qt's private QML API moved inside the 6.x
// line, and both were guarded by `QT_VERSION >= 6.0.0`, which is a claim about a boundary rather
// than about the declaration in front of us. Against Qt 6.4 this file did not compile:
//
//     error: no member named 'CurrentVersion' in 'QQmlPrivate::RegisterType'
//     error: cannot initialize a parameter of type 'QQmlEnginePrivate *' with an rvalue of type
//            'QQmlTypeLoader *'
//
// three errors in one file, taking 757 qmltc targets with them. This project generates a wrapper
// for whatever Qt is installed, so the question has to be asked of the type — which also answers
// for the versions nobody has tried yet.
// (extern "C++": this whole file is inside `extern "C"`, but templates need C++ linkage — the
// same reason the Qt5 create-pool below is wrapped. Without it these are not ill-formed in a way
// that says so: the definitions are simply not found, and clang answers `no matching function for
// call to 'qtdRegisterTypeVersion'` about a template three hundred lines above the call.)
extern "C++" {
template <class T, class = void> struct QtdHasCurrentVersion : std::false_type {};
template <class T>
struct QtdHasCurrentVersion<T, std::void_t<decltype(T::CurrentVersion)>> : std::true_type {};

/// The struct version to declare. Where Qt names one, that is the answer; where it does not — 6.4
/// and earlier — the layout this file fills is base plus `finalizerCast`, which is version 1.
template <class RT> static constexpr int qtdRegisterTypeVersion() {
    if constexpr (QtdHasCurrentVersion<RT>::value) return int(RT::CurrentVersion);
    else return 1;
}

}   // extern "C++"

extern "C" int qtd_prop_set_list(void* o, const char* n, const char* typeName,
                                 const char** items, int count) {
    if (!o || !n) return 0;
    QVariantList vs;
    vs.reserve(count);
    const bool asText = !typeName || !*typeName || !std::strcmp(typeName, "QString");
    // BOTH QT MAJORS NAME A METATYPE DIFFERENTLY, and the Qt6 spelling is not a superset: Qt5 has
    // `QMetaType::type(const char*)` returning an int and `QVariant::convert(int)`, Qt6 has
    // `QMetaType::fromName` and `convert(QMetaType)`. Written for Qt6 only, this did not compile
    // against Qt 5.15 at all — `no matching member function for call to 'convert'` — and took the
    // whole qtwidgets-wrap shim archive with it, so 22 Qt5 targets failed on a file none of them
    // is about.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    const QMetaType mt = asText ? QMetaType(QMetaType::QString) : QMetaType::fromName(typeName);
    const bool ok = asText || mt.isValid();
#else
    const int mt = asText ? int(QMetaType::QString) : QMetaType::type(typeName);
    const bool ok = asText || mt != QMetaType::UnknownType;
#endif
    if (!ok) return 0;
    for (int i = 0; i < count; ++i) {
        QVariant one = QString::fromUtf8(items[i] ? items[i] : "");
        if (!asText && !one.convert(mt)) return 0;
        vs.push_back(one);
    }
    return qtd_prop_write(o, n, QVariant(vs));
}
// A QObject*-valued property — a GROUPED property (`group.count: 42` in QML) is one of these:
// the group is a real child object reached through the parent's meta-object, and its members are
// ordinary properties on it. Returns null if the property is absent or not an object.
void* qtd_prop_get_obj(void* o, const char* n) {
    if (!o) return nullptr;
    QVariant v = static_cast<QObject*>(o)->property(n);
    if (QObject* p = v.value<QObject*>()) return p;
    // ...and a property the engine exposes as a QJSValue still HOLDS an object. `Rectangle.gradient`
    // is one — it takes either a Gradient or a preset name — so reading it as QObject* gave null and
    // the dump walked no further: the two GradientStops that decide a Fusion ToolBar's whole frame
    // were emitted by neither side, and the render differed by one step of grey with nothing in the
    // value differential to show for it. The oracle unwraps it the same way.
#ifdef QTD_HAVE_QML
    if (v.canConvert<QJSValue>()) return v.value<QJSValue>().toQObject();
#endif
    return nullptr;
}
// ---- generic property access by TYPE NAME -------------------------------------
// The typed helpers below (int/double/bool/QString) can only reach a value type that happens to
// have a registered QString conversion: QColor does, QSize does not, so `@Property QSize` was
// unreachable THROUGH the meta-object even though the property was registered correctly. The
// meta-object records a property by type NAME and QMetaType resolves it, so one pair keyed by
// that name serves every registered type — which is what principle 1 of the moc says.
//
// `data`/`out` point at the caller's value of that exact type; QVariant(QMetaType, const void*)
// copies it in, and QMetaType::destruct/construct handle the lifetime.
extern "C" int qtd_prop_set_var(void* o, const char* n, const char* typeName, const void* data) {
    if (!o || !typeName) return 0;
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    QMetaType mt = QMetaType::fromName(typeName);
    if (!mt.isValid()) return 0;
    return static_cast<QObject*>(o)->setProperty(n, QVariant(mt, data)) ? 1 : 0;
#else
    // Qt5 names the same operations differently: QMetaType::type() for the id, and the
    // (typeId, copy) QVariant constructor. The mechanism is identical.
    int id = QMetaType::type(typeName);
    if (id == QMetaType::UnknownType) return 0;
    return static_cast<QObject*>(o)->setProperty(n, QVariant(id, data)) ? 1 : 0;
#endif
}

// Reads into `out` (already default-constructed by the caller). Returns 0 when the property is
// absent, or holds something that cannot convert to the requested type — both of which used to
// be indistinguishable from a zero value.
extern "C" int qtd_prop_get_var(void* o, const char* n, const char* typeName, void* out) {
    if (!o || !typeName) return 0;
    QVariant v = static_cast<QObject*>(o)->property(n);
    if (!v.isValid()) return 0;
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    QMetaType mt = QMetaType::fromName(typeName);
    if (!mt.isValid()) return 0;
    if (v.metaType() != mt && !v.convert(mt)) return 0;
    mt.destruct(out);
    mt.construct(out, v.constData());
#else
    int id = QMetaType::type(typeName);
    if (id == QMetaType::UnknownType) return 0;
    if (v.userType() != id && !v.convert(id)) return 0;
    QMetaType::destruct(id, out);
    QMetaType::construct(id, out, v.constData());
#endif
    return 1;
}

// ---- default children go through the type's DEFAULT PROPERTY -------------------------------
// The engine appends a default child to the type's default list property, and each type decides
// what that MEANS: QQuickItem's `data` sets the QObject parent and parentItem, QQuickFlickable's
// `flickableData` reparents into the flickable's contentItem, QQuickPopup/Control's `contentData`
// into theirs. Doing it by hand (setQtParent + parent) put the child somewhere the engine never
// has it. QQmlListReference is the generic channel -- one call, every type's own rule.
extern "C" void qtd_ensure_module(const char* uri);
extern "C" int qtd_list_append(void* ownerV, const char* prop, void* childV) {
#ifdef QTD_HAVE_QML
    if (!ownerV || !childV || !prop) return 0;
    // QQmlListReference type-checks the element against the list's declared type, and that check
    // needs QML's type registry populated — which only IMPORTING the module does. Without it,
    // appending to a typed list (`transform`, `transitions`) silently returns false while `data`
    // (a list of QObject, no lookup) works, so the objects were built, wired and never linked:
    // Qt's ScrollBar had no transition and its Dial handle no transforms. Measured: the identical
    // append returns true right after `import QtQuick`. Once, like the value-type writer.
    static bool imported = false;
    if (!imported) { imported = true; qtd_ensure_module("QtQuick"); }
    QQmlListReference ref(static_cast<QObject*>(ownerV), prop);
    if (!ref.isValid() || !ref.canAppend()) return 0;
    return ref.append(static_cast<QObject*>(childV)) ? 1 : 0;
#else
    (void) ownerV; (void) prop; (void) childV; return 0;
#endif
}

#ifdef QTD_HAVE_QML
// Guarded because this SAME unit is compiled for bindings with no QtQml at all (QtWidgets,
// libsample): an unguarded QQmlEngine here broke the default build, which is a feature-isolation
// defect, not a QML one. qtd_probe_noqml.cpp compiles this file without QtQml so it cannot recur.
static QQmlEngine* qtd_qml_engine();   // defined with the QQmlContext helpers below
#endif

// ---- QML module bootstrap -------------------------------------------------------------------
// A compiled Control reads its palette from the QQuickTheme the STYLE module installs, and that
// module is only initialised when the engine IMPORTS it. Without it, Qt's own Pane.qml compiled
// to `background.color = #efefef` where the engine gives #ffffff -- no diagnostic, no crash, just
// a different colour. Measured: importing QtQuick.Templates or QtQuick.Controls does NOT do it;
// the style module (QtQuick.Controls.Basic) does. Palette resolution is lazy, so a control built
// BEFORE this still picks the theme up -- what matters is only that it precedes the first READ.
// Cost: ~1.8 ms, once per module. The URI comes from the document's own qmldir, so nothing here
// knows anything about Controls.
extern "C" void qtd_ensure_module(const char* uri) {
#ifdef QTD_HAVE_QML
    if (!uri || !*uri || !QCoreApplication::instance()) return;
    static std::unordered_map<std::string, bool> done;
    if (!done.emplace(uri, true).second) return;
    QQmlComponent c(qtd_qml_engine());
    // `qrc:`, NOT `file:///…`. These URLs are SYNTHETIC — a name for a document that has no file,
    // needed only so the engine has a base to report errors against. Spelled `file:///name.qml`
    // they are a drive-less absolute path, which is a real path on POSIX and not one on Windows:
    // Qt's Windows filesystem engine turns it into an empty native path and says
    //     Empty filename passed to function
    // on stderr, once per document. Measured with a six-line probe: the same setData with a
    // `qrc:` URL is silent, and `qrc:` never reaches a filesystem at all. Nothing here resolves
    // anything relative to this base, so the scheme is free to be the one that touches no disk.
    c.setData(QByteArray("import ") + uri + "\nimport QtQml\nQtObject {}",
              QUrl(QStringLiteral("qrc:/qtd_module_bootstrap.qml")));
    if (QObject* o = c.create()) delete o;
#else
    (void) uri;
#endif
}

// Invoke a Q_INVOKABLE by NAME with mixed arguments: text (converted to the declared parameter type
// by QMetaType, the same channel every value here travels) and OBJECT pointers, which no text can
// stand in for. Qt's Fusion style computes almost every colour this way —
// `Fusion.buttonColor(control.palette, highlighted, down, hovered)` — and a string-only invoke could
// not pass the palette. The result comes back as text for the same reason.
// A returned value as TEXT — the channel every result crosses on. A COLOUR is spelled with the
// full precision QColor holds: Qt's Fusion computes `gradientStop(buttonColor(...))`, and
// buttonColor's colour is NOT 8-bit — spelled `#rrggbb` and parsed back it shifts by one step,
// which is exactly the difference the engine showed on every gradient stop. `#rrrrggggbbbb` is
// Qt's own 16-bit-per-channel spelling and QColor parses it back exactly. There is no such form
// WITH alpha, so a translucent colour keeps the 8-bit one QVariant gives.
static QString qtd_var_text(const QVariant& v) {
#ifdef QT_GUI_LIB
    if (v.userType() == QMetaType::QColor) {
        QColor c = v.value<QColor>();
        if (c.isValid() && c.alpha() == 255) {
            QRgba64 r = c.rgba64();
            return QString::asprintf("#%04x%04x%04x", r.red(), r.green(), r.blue());
        }
    }
#endif
    return v.toString();
}
// The call itself, with the RESULT still a QVariant: what the two entry points below disagree about
// is only how to hand it back. Text carries a scalar (QMetaType converts, which is how a colour
// travels everywhere here); an OBJECT cannot travel as text at all, and `itemAtIndex` returning one
// is what Qt's ComboBox reads for `highlightedItem`.
static bool qtd_invoke_mixed_var(void* o, const char* method, int n, const int* kinds,
                                 void* const* vals, QVariant &ret) {
    if (!o || !method) return false;
    QObject* obj = static_cast<QObject*>(o);
    const QMetaObject* mo = obj->metaObject();
    int idx = -1;
    for (int i = 0; i < mo->methodCount(); ++i) {
        QMetaMethod m = mo->method(i);
        if (m.name() == QByteArray(method) && m.parameterCount() == n) { idx = i; break; }
    }
    if (idx < 0) {
        std::fprintf(stderr, "qtd: no invokable '%s' with %d argument(s) on %s\n", method, n,
                     mo->className());
        return false;
    }
    QMetaMethod m = mo->method(idx);
    // Qt5 names these differently (int ids, not QMetaType) — the same unit compiles for both.
#if QT_VERSION >= 0x060000
    const QMetaType retType = m.returnMetaType();
    auto paramType = [&](int i) { return m.parameterMetaType(i); };
#else
    const QMetaType retType(m.returnType());
    auto paramType = [&](int i) { return QMetaType(m.parameterType(i)); };
#endif
#if QT_VERSION >= 0x060000
    ret = QVariant(retType);
#else
    ret = QVariant(retType.id(), nullptr);   // Qt5: QVariant has no QMetaType ctor
#endif
    std::vector<QVariant> conv(n);
    std::vector<void*> argv(n + 1, nullptr);
    argv[0] = retType.id() == QMetaType::Void ? nullptr : ret.data();
    for (int i = 0; i < n; ++i) {
        if (kinds[i] == 1) { argv[i + 1] = const_cast<void**>(&vals[i]); continue; }  // pointer slot
        const QString txt = QString::fromUtf8(static_cast<const char*>(vals[i]));
        // The kind says what the text IS — 2 a number, 3 a bool — which is what the caller knew and
        // the digits alone do not say. It matters for a `var` parameter, where nothing converts the
        // text afterwards and the value is whatever is put in.
        QVariant v = kinds[i] == 2 ? QVariant(txt.toDouble())
                   : kinds[i] == 3 ? QVariant(txt == QLatin1String("true"))
                                   : QVariant(txt);
        // A QVariant PARAMETER takes anything, so there is nothing to convert to: converting is
        // exactly what fails, since no type converts to "any type". This is a `var` in the document.
        if (paramType(i).id() == QMetaType::QVariant) {
            conv[i] = v;
            argv[i + 1] = &conv[i];
            continue;
        }
#if QT_VERSION >= 0x060000
        if (!v.convert(paramType(i))) {
#else
        if (!v.convert(paramType(i).id())) {
#endif
            std::fprintf(stderr, "qtd: argument %d of '%s' does not convert to %s\n", i, method,
                         QByteArray(paramType(i).name()).constData());
            return false;
        }
        conv[i] = v;
        argv[i + 1] = conv[i].data();
    }
    QMetaObject::metacall(obj, QMetaObject::InvokeMetaMethod, idx, argv.data());
    return true;
}
extern "C" void* qtd_invoke_mixed(void* o, const char* method, int n, const int* kinds,
                                  void* const* vals) {
    QVariant ret;
    if (!qtd_invoke_mixed_var(o, method, n, kinds, vals, ret)) return new QString();
    return new QString(qtd_var_text(ret));
}
// ...and the same call whose RESULT is an object.
extern "C" void* qtd_invoke_mixed_obj(void* o, const char* method, int n, const int* kinds,
                                      void* const* vals) {
    QVariant ret;
    if (!qtd_invoke_mixed_var(o, method, n, kinds, vals, ret)) return nullptr;
    return ret.value<QObject*>();
}

// The nearest ENCLOSING object of a given class, found by walking Qt parents. An object the ENGINE
// creates (a delegate instance) cannot be handed its enclosing document object the way a compiled
// child is — it is created by a view, not by its parent — but it IS parented into that document's
// object tree, and the class match goes through the meta-object like everything else here.
extern "C" void* qtd_find_outer(void* o, const char* cls) {
    if (!o || !cls) return nullptr;
    QObject* cur = static_cast<QObject*>(o);
    for (int hops = 0; cur && hops < 64; ++hops) {
        // The VISUAL parent first: an item a view created is given a parentItem, and its QObject
        // parent may be something else entirely (a Repeater's items are owned by the delegate model
        // and shown under the Repeater's own parent). Falling back to the QObject parent keeps this
        // working for objects that are not Items at all.
        QObject* next = nullptr;
        QVariant pv = cur->property("parent");
        if (pv.isValid()) next = pv.value<QObject*>();
        if (!next) next = cur->parent();
        if (!next) return nullptr;
        if (qtd_moc_classmatch(next, cls)) {
            // ...and hand back the D OBJECT, not the C++ one: the caller casts it to the generated
            // class, and a raw QObject* reinterpreted as a D reference is a wrong object that reads
            // as a valid one (found by a delegate whose enclosing reads all came back empty).
            auto it = g_moAttach.find(next);
            return it != g_moAttach.end() ? it->second.dobj : nullptr;
        }
        cur = next;
    }
    return nullptr;
}

// A CONTEXT property (`index`, `model`, `modelData` inside a delegate): the view publishes them on
// the QQmlContext it creates per item, not as properties of any object, so they are read by name
// through the context chain. Returned as a QVariant the callers convert, same as every other value
// channel here.
// `font.bold: true` — a member of a value type reached through an EXTENSION (QFont via
// QQuickFontValueType), which has no meta-object of its own, so the gadget read-modify-write cannot
// reach it. QQmlProperty resolves exactly these by NAME, through QML's own value-type registry:
// the same public channel the engine uses for the same line in the .qml.
//
// That registry is populated by IMPORTING the module — measured: with no import, `font.bold` is not
// even a valid QQmlProperty on a plain QQuickText created in C++ (while `text` is); after
// `import QtQuick` it is valid, writable and typed `bool`. Importing the STYLE module is not
// enough, so this asks for QtQuick by name, once. A binding without QtQuick gets a failed import
// and a refused write, which is the honest outcome there.
extern "C" void qtd_ensure_module(const char* uri);
extern "C" int qtd_qml_write(void* o, const char* path, const char* value, int kind) {
#ifdef QTD_HAVE_QML
    if (!o || !path || !value) return 0;
    static bool imported = false;
    if (!imported) { imported = true; qtd_ensure_module("QtQuick"); }
    QObject* obj = static_cast<QObject*>(o);
    QQmlProperty p(obj, QString::fromUtf8(path), qmlContext(obj));
    if (!p.isValid() || !p.isWritable()) return 0;
    QString v = QString::fromUtf8(value);
    switch (kind) {
        case 0: return p.write(QVariant(v == QLatin1String("true"))) ? 1 : 0;   // bool
        case 1: return p.write(QVariant(v.toInt())) ? 1 : 0;                    // int
        case 2: return p.write(QVariant(v.toDouble())) ? 1 : 0;                 // double
        default: return p.write(QVariant(v)) ? 1 : 0;                           // string
    }
#else
    (void) o; (void) path; (void) value; (void) kind; return 0;
#endif
}

// The object a per-item QQmlContext carries (QQmlDelegateModelItem for a view's delegate). It is
// what publishes `index`/`model`, and it publishes them as real properties WITH notify — so a
// binding on `index` can be as live as any other, through the same meta-object channel.
// The per-item data, read PAST the object's own shadow -- and used ONLY to FILL a required
// property, never for an ordinary context read.
//
// The engine makes a delegate item the CONTEXT OBJECT of its innermost context, so
// `contextProperty("index")` finds the ITEM's own property first. That is not a defect: measured in
// pure QML, a delegate that declares `property int index` (no `required`) reads 0 on every item --
// the engine shadows it exactly the same way. What differs is that a `required` declaration is
// FILLED by the view, and ours cannot be, because the meta-object flag that asks for it does not
// exist before Qt 6.
//
// So the value we need is the one the view would have written, and it lives one level up:
// measured, item 1 of a Repeater has index 0 at the item's own level and 1 at the delegate model's.
// Reading ordinary context names past the shadow would be WRONG -- it would answer the context
// where the engine answers the property -- which is why this is a separate door.
//
// The engine makes a delegate item the CONTEXT OBJECT of its own innermost context, so
// `contextProperty("index")` finds a property of the ITEM before it reaches the per-item data. When
// the document declares `required property int index`, that is our own property -- which nobody
// writes, because we cannot mark it required for the view to fill -- and the read answered its
// default. Measured, item 1 of a Repeater: L0 (context object = the item) says 0, L1
// (QQmlDMListAccessorData) says 1. The value was never missing; it was shadowed.
//
// This channel only ever carries names the compiler could NOT resolve locally -- a name the
// document declares is read from the field, not from here -- so skipping the level whose context
// object IS the asking object is exactly right for it.
#ifdef QTD_HAVE_QML
static QQmlContext* qtd_item_context(QObject* obj) {
    QQmlContext* c = qmlContext(obj);
    while (c && c->contextObject() == obj) c = c->parentContext();
    return c ? c : qmlContext(obj);
}
#endif
// THE VALUE A REQUIRED PROPERTY SHOULD BE FILLED WITH. The per-item context carries the model's
// roles by name for a QAbstractItemModel, and for a plain list of objects it carries `modelData` —
// the element itself. A delegate written `required property string t` over a QVariantList of
// QVariantMap (which is what setModel produces) found nothing under `t` and kept its default: every
// row of a real reader's page came out with an empty string and a number of 0, so the text was
// there and invisible and every row believed it was the chapter title.
//
// Asked in the order the engine resolves it: the context first, then the element's own key.
#ifdef QTD_HAVE_QML
static QVariant qtd_ctx_role(void* o, const char* name) {
    QQmlContext* c = o && name ? qtd_item_context(static_cast<QObject*>(o)) : nullptr;
    if (!c) return QVariant();
    const QString n = QString::fromUtf8(name);
    QVariant v = c->contextProperty(n);
    if (v.isValid()) return v;
    const QVariant md = c->contextProperty(QStringLiteral("modelData"));
    if (md.canConvert<QVariantMap>()) {
        const QVariantMap m = md.toMap();
        auto it = m.find(n);
        if (it != m.end()) return *it;
    }
    return QVariant();
}
#endif
extern "C" int qtd_ctx_fill_int(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    return qtd_ctx_role(o, name).toInt();
#else
    (void) o; (void) name;
#endif
    return 0;
}
extern "C" double qtd_ctx_fill_double(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    return qtd_ctx_role(o, name).toDouble();
#else
    (void) o; (void) name;
#endif
    return 0;
}
extern "C" void* qtd_ctx_fill_qs(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    return new QString(qtd_ctx_role(o, name).toString());
#else
    (void) o; (void) name;
#endif
    return new QString();
}

// ---- an expression the compiler could not translate, left to the engine -------------------------
// The last resort, and deliberately a NARROW one: the compiler emits this only for a binding it
// would otherwise have REFUSED, and it counts as a delegation, never as a compiled binding.
//
// What makes it work where the D translation cannot is that the value never becomes a D value:
// `control.model[control.headerView.textRole]` reads a role off a `required property var` by a name
// only known at run time, and a `var` has no D type to hold it. Inside the engine it is an ordinary
// JS property read.
//
// Two things must be true for the expression to see what it saw in the .qml:
//   - the ids it names. In the interpreted document an id is a property of the document's root
//     context; in ours it is a D field with no name the engine knows. So the caller passes the ids
//     the expression mentions, already resolved to objects, and they are published on a context
//     that NESTS INSIDE the object's own -- so a per-item `index`/`model`/`modelData` one level up
//     still resolves, exactly as it does for the interpreted delegate.
//   - the object itself as SCOPE, which is what makes a bare property name (`pressed`, `font`)
//     resolve against it before anything else, the same order the engine uses.
//
// An error is not swallowed by accident: the engine leaves a property alone when its binding
// throws, and so do we. Basic's PageIndicator reads `pressed`, which no PageIndicator declares --
// interpreted, that is a ReferenceError and the opacity keeps its default. Delegated, it is the
// same ReferenceError and the same default.
// PHASE 2: the same delegation, from a SHADOW compiled at build time instead of a source string
// compiled at run time. The shadow is a real QML document carrying a real BINDING — not a function,
// because what makes a delegated expression LIVE is the engine capturing a binding's dependencies
// and a function call captures nothing. Measured with the .qml moved off disk: the bytecode answers
// and still updates when its source changes.
//
// It also writes the result ITSELF, through a QML `Binding` inside it, so there is no signal to
// connect and no slot to invent here. And because it is a real document it carries the ORIGINAL
// document's imports, which is the one thing the runtime string path never had.
// A TIER, NOT AN ULTIMATUM. Every failure below used to `return 0` and install nothing: the
// property kept its default, no binding existed, and the only trace was a line on stderr. That is
// the worst of the three outcomes — worse than compiling it, worse than delegating it — because
// the document still says the property is bound and nothing in the running program agrees.
//
// So the ladder is: compiled where the compiler can, this AOT shadow where it cannot, and the
// engine evaluating the expression directly where the shadow does not load or build. The engine is
// the floor and it always answers, because it is what would have run had none of this existed. The
// expression travels with the shadow for exactly this reason.
extern "C" int qtd_bind_js(void* o, const char* prop, const char* src,
                           const char** names, void** objs, int n);
extern "C" int qtd_bind_shadow(void* o, const char* prop, const char* url, const char* src,
                               const char** names, void** objs, int n) {
#ifdef QTD_HAVE_QML
    if (!o || !prop || !url) return 0;
    QObject* obj = static_cast<QObject*>(o);
    // Reported once per binding and then handed down, so a tier DROP stays measurable — the reason
    // a blanket fallback was resisted is that it hides how much the compiler actually covers.
    auto fallback = [&](const char* why) {
        std::fprintf(stderr, "qtd_bind_shadow: '%s' on %s — %s; falling back to the engine\n",
                     prop, obj->metaObject()->className(), why);
        return src ? qtd_bind_js(o, prop, src, names, objs, n) : 0;
    };
    if (!QCoreApplication::instance()) {
        std::fprintf(stderr, "qtd_bind_shadow: '%s' on %s has no application — not installed\n",
                     prop, obj->metaObject()->className());
        return 0;   // the engine path needs one too; there is no lower tier to fall to
    }
    // FAULT INJECTION, because a fallback nothing ever takes is a fallback nobody knows is broken.
    // The shadows are BYTECODE inside the binary by the time this runs, so there is no file to
    // remove and no way to make them fail from outside. shadowaot- runs the same program twice:
    // once as built, and once with this set, and both runs must produce the engine's values.
    if (qEnvironmentVariableIsSet("QTD_SHADOW_FORCE_FAIL"))
        return fallback("QTD_SHADOW_FORCE_FAIL is set");
    auto* c = new QQmlComponent(qtd_qml_engine(), QUrl(QString::fromUtf8(url)), obj);
    if (c->isError()) {
        std::fprintf(stderr, "qtd_bind_shadow: shadow '%s' failed to load: %s\n", url,
                     qPrintable(c->errorString()));
        return fallback("the shadow document did not load");
    }
    // beginCreate / completeCreate, NOT create(). `create()` completes the object, which is when
    // the engine evaluates its bindings — and the shadow's whole value is a binding that reads the
    // objects we have not handed over yet. It evaluated against a null `root`:
    //     qrc:/qtdshadow/QJsDelegated_e0.qml:22: TypeError: Cannot read property 'key' of null
    // Split in two, every property is in place before any binding runs, which is also what the
    // note below about the target was reaching for and could not get from create().
    QQmlContext* ctx = qmlContext(obj);
    if (!ctx) ctx = c->creationContext();
    if (!ctx) ctx = qtd_qml_engine()->rootContext();
    QObject* sh = c->beginCreate(ctx);
    if (!sh) {
        std::fprintf(stderr, "qtd_bind_shadow: shadow '%s' failed to build: %s\n", url,
                     qPrintable(c->errorString()));
        return fallback("the shadow document did not build");
    }
    sh->setParent(obj);   // dies with the object whose property it drives
    for (int i = 0; i < n; ++i)
        if (names[i]) sh->setProperty(names[i], QVariant::fromValue(static_cast<QObject*>(objs[i])));
    // The target LAST: the Binding inside the shadow starts writing the moment it has one, and
    // writing before the handed-over names are in place would push one wrong value first.
    sh->setProperty("prop", QString::fromUtf8(prop));
    sh->setProperty("target", QVariant::fromValue(obj));
    c->completeCreate();
    return 1;
#else
    (void) o; (void) prop; (void) url; (void) src; (void) names; (void) objs; (void) n; return 0;
#endif
}


// ---- a Component (a delegate) ------------------------------------------------------------------
// `delegate: Text {}` is a TEMPLATE: the type instantiates it itself, N times, whenever its model
// says so. A compiler cannot create those objects — only the type knows when — so what it hands
// over must be a real QQmlComponent. The delegate body is compiled to a class like any other and
// registered as a QML type (qmlRegisterType, which is how a D @QObject reaches QML at all); this
// builds the one-line document that instantiates it, on the SAME engine every compiled object
// already uses, so the created items share the engine's contexts and its type registry.
// `decls` is QML text the DOCUMENT declares on this element — `property string target: ""`. A type
// outside the binding is built by the engine, so the properties the document adds to it have to be
// on the ENGINE's object: held on the D shell instead, they were invisible to every expression the
// engine evaluates, and `shotTimer.target = x` answered `Cannot assign to non-existent property`.
// The engine builds what the document describes, which is the whole point of this path.
extern "C" void* qtd_make_component(const char* uri, const char* typeName, const char* docUrl,
                                    const char* decls) {
#ifdef QTD_HAVE_QML
    if (!uri || !typeName || !QCoreApplication::instance()) return nullptr;
    QQmlEngine* e = qtd_qml_engine();
    // ...and the same for the fallback name of a delegate with no document of its own. See the
    // note on qtd_ensure_module: a drive-less `file:///` path is what makes Qt warn on Windows.
    QUrl url(QString::fromUtf8(docUrl && *docUrl ? docUrl : "qrc:/qtd_delegate.qml"));
    // HOSTED IN A DOCUMENT, because a QQmlComponent built with setData has NO CREATION CONTEXT and
    // Qt dereferences it without checking. `QQuickItemLayer::activateEffect()` calls
    // `m_effectComponent->beginCreate(m_effectComponent->creationContext())`, and beginCreate takes
    // the context apart straight away — so a null one is a SIGSEGV inside QtQml, three frames from
    // anything of ours. Measured with gdb on Qt's Material Popup, and it is not one document:
    // ComboBox, Dialog, Menu, Popup and SearchField all crash, all Material, all through
    // `layer.effect`. Probed directly: setData gives creationContext() == nullptr and a
    // `Component { X {} }` built BY a document gives a real one, which is what the engine itself
    // hands to that call. The document's own url is used, so a relative path inside the component
    // resolves where the engine resolves it.
    // EVERY IMPORT THE DOCUMENT HAD, not one. `uri` arrives as the ';'-separated list the engine
    // child path already builds from the document's own imports, because a delegate's body names
    // types from more than one module: a `Shape` delegate's `ShapePath`/`PathLine` are
    // QtQuick.Shapes while everything around them is QtQuick. Given only the first, the engine
    // answered `Shape is not a type` and the delegate was lost.
    QByteArray imports("import QtQml\n");
    for (const QByteArray &u : QByteArray(uri).split(';'))
        if (!u.trimmed().isEmpty()) imports += "import " + u.trimmed() + "\n";
    if (qEnvironmentVariableIsSet("QTD_COMPONENT_DEBUG"))
        std::fprintf(stderr, "qtd_make_component: uri='%s' type='%s' imports=[%s]\n",
                     uri, typeName, imports.trimmed().replace('\n', ' ').constData());
    {
        QQmlComponent host(e, e);
        host.setData(imports + "Component { " + typeName
                         + " { " + (decls ? decls : "") + " } }",
                     url);
        if (!host.isError())
            if (QQmlComponent* hc = qobject_cast<QQmlComponent*>(host.create())) {
                QQmlEngine::setObjectOwnership(hc, QQmlEngine::CppOwnership);
                hc->setParent(e);
                return hc;
            }
    }
    // ...and the old shape as a fallback: a type the hosted form cannot spell is still better
    // instantiated than refused. It is only unusable where Qt asks for the creation context.
    QQmlComponent* c = new QQmlComponent(e, e);
    c->setData(imports + typeName + " { " + (decls ? decls : "") + " }", url);
    if (c->isError()) {
        std::fprintf(stderr, "qtd: delegate component for '%s' failed: %s\n", typeName,
                     qPrintable(c->errorString()));
        delete c;
        return nullptr;
    }
    return c;
#else
    (void) uri; (void) typeName; (void) docUrl; (void) decls; return nullptr;
#endif
}

// A WHOLE DOCUMENT handed to the engine, rather than an object of a named type. This is the same
// containment the engine-built child already uses — the object is the engine's and our class only
// holds a pointer to it — applied at the ROOT: a document we cannot compile is not abandoned, it is
// instantiated by the engine and reached through its interface like any other opaque object.
// From the FILE, not from `import <uri>; <Type> {}`: a style's document is not a registered type of
// its own (Qt's Imagine ProgressBar is the implementation of QtQuick.Controls.ProgressBar, not a
// type anyone can name), and the file is what the engine itself loads.
extern "C" void* qtd_qml_create_document(const char* docUrl) {
#ifdef QTD_HAVE_QML
    if (!docUrl || !*docUrl || !QCoreApplication::instance()) return nullptr;
    QQmlEngine* e = qtd_qml_engine();
    QQmlComponent* c = new QQmlComponent(e, QUrl(QString::fromUtf8(docUrl)), e);
    if (c->isError()) {
        std::fprintf(stderr, "qtd: delegated DOCUMENT '%s' failed to load: %s\n", docUrl,
                     qPrintable(c->errorString()));
        return nullptr;
    }
    QObject* o = c->create();
    if (!o) std::fprintf(stderr, "qtd: delegated DOCUMENT '%s' failed to build: %s\n", docUrl,
                         qPrintable(c->errorString()));
    return o;
#else
    (void) docUrl; return nullptr;
#endif
}

// An object of a registered QML TYPE that exports no C++ symbol — Qt's own DialImpl,
// BusyIndicatorImpl, ProgressBarImpl are compiled into their style plugin and cannot be linked
// against, so no D subclass of them can exist. They can still be BUILT: the engine knows them by
// name, and everything after that is the meta-object channel like any other object.
// `docUrl` is the DOCUMENT the object is written in, and it is not cosmetic: the object inherits it
// as its baseUrl, so every relative path inside it resolves against that document — which is what
// the engine does. Passing nothing left `file:///qtd_delegate.qml` there (measured on Qt's Material
// TextField, whose placeholder reports it in the dump).
// ...AND THE NAMES ITS BODY READS. A body the engine owns is evaluated in the context it is created
// in, and the ids of the document that wrote it are not there: `Connections { target: bible;
// function onTranslationChanged() { root.readTranslations() } }` built and then answered
// `root is not defined` — silently, because Qt's default handler is where that message goes and
// this program does not print it. Same handover a delegated binding gets, for the same reason.
extern "C" void* qtd_qml_create_object_in(const char* uri, const char* typeName, const char* docUrl,
                                          const char* decls, const char** names, void** objs,
                                          int n) {
#ifdef QTD_HAVE_QML
    void* c = qtd_make_component(uri, typeName, docUrl, decls);
    if (!c) return nullptr;
    auto* comp = static_cast<QQmlComponent*>(c);
    QQmlContext* ctx = comp->creationContext();
    if (!ctx) ctx = qtd_qml_engine()->rootContext();
    if (n > 0) {
        ctx = new QQmlContext(ctx, comp);
        for (int i = 0; i < n; ++i)
            if (names[i])
                ctx->setContextProperty(QString::fromUtf8(names[i]),
                                        static_cast<QObject*>(objs[i]));
    }
    QObject* o = comp->create(ctx);
    if (!o) std::fprintf(stderr, "qtd: creating '%s' from '%s' failed: %s\n", typeName, uri,
                         qPrintable(comp->errorString()));
    if (qEnvironmentVariableIsSet("QTD_CTX_DEBUG"))
        std::fprintf(stderr, "qtd: created '%s' -> %s%s\n", typeName, o ? "ok" : "NULL",
                     decls && *decls ? " (with body)" : "");
    return o;
#else
    (void) uri; (void) typeName; (void) docUrl; return nullptr;
#endif
}
extern "C" void* qtd_qml_create_object(const char* uri, const char* typeName) {
#ifdef QTD_HAVE_QML
    void* c = qtd_make_component(uri, typeName, nullptr, nullptr);
    if (!c) return nullptr;
    auto* comp = static_cast<QQmlComponent*>(c);
    QObject* o = comp->create();
    if (!o) std::fprintf(stderr, "qtd: creating '%s' from '%s' failed: %s\n", typeName, uri,
                         qPrintable(comp->errorString()));
    return o;
#else
    (void) uri; (void) typeName; return nullptr;
#endif
}







// QT DEFERS SOME CHILDREN, and says which in the META-OBJECT: Q_CLASSINFO("DeferredPropertyNames",
// "background,contentItem,indicator"). Those objects are not built during the object pass at all —
// QQuickControl::componentComplete builds them itself, completes each as it is built, and only then
// calls resizeContent. Building them eagerly, as we did, lets the control stretch a contentItem
// before it has ever laid out, and a QQuickText freezes baselineOffset at its FIRST layout: six of
// Qt's documents disagreed on exactly that value and nothing else.
//
// Returns a RANK to build in, or -1 for "not deferred, build it now". The rank is not the order the
// classinfo lists: Qt runs the most-derived class's deferred properties first. A Button's indicator
// is introduced by QQuickAbstractButton and its background/contentItem by QQuickControl, and Qt runs
// indicator, then background, then contentItem — the reverse of the one string that names all three.
// So the rank is (how far the DECLARING class is from the object's own class, then the position
// within that class's list), which reproduces Qt's order without encoding any type's names.
extern "C" int qtd_deferred_index(void* o, const char* name) {
    if (!o || !name) return -1;
    const QMetaObject* mo = static_cast<QObject*>(o)->metaObject();
    int pi = mo->indexOfProperty(name);
    if (pi < 0) return -1;
    QByteArray want(name);
    int depth = 0;
    for (const QMetaObject* m = mo; m; m = m->superClass(), ++depth) {
        // The class that DECLARES the property owns the moment it is built.
        if (m->propertyOffset() > pi) continue;
        for (int i = m->classInfoOffset(); i < m->classInfoCount(); ++i) {
            QMetaClassInfo ci = m->classInfo(i);
            if (qstrcmp(ci.name(), "DeferredPropertyNames") != 0) continue;
            int pos = 0;
            const QList<QByteArray> parts = QByteArray(ci.value()).split(',');
            for (const QByteArray& part : parts) {
                if (part.trimmed() == want) return depth * 1000 + pos;
                ++pos;
            }
        }
        break;   // the declaring class does not defer it; a base's list cannot introduce it
    }
    return -1;
}


// Does the object in hand declare this property at all? Asked before a read the compiler could not
// check statically, so a name nothing answers to aborts the binding instead of quietly reading 0.
extern "C" int qtd_prop_has(void* o, const char* n) {
    if (!o || !n) return 0;
    return static_cast<QObject*>(o)->metaObject()->indexOfProperty(n) >= 0 ? 1 : 0;
}

// A SIGNAL FOUND BY NAME on the object that is there. A child the ENGINE builds can be of a type
// our registry never heard of — `Timer` is the plain one — so `onTriggered` has no signature to
// connect with and the handler was refused outright. QML names a handler after the signal and
// nothing else, so the name is all we are given and all we need: the meta-object supplies the
// signature. The receiving slot takes no parameters, which Qt allows for any signal.
extern "C" int qtd_connect_by_name(void* sndrV, const char* signalName, void* recvV,
                                   const char* slot) {
    QObject* s = static_cast<QObject*>(sndrV);
    QObject* r = static_cast<QObject*>(recvV);
    if (!s || !r || !signalName || !slot) return 0;
    const QMetaObject* mo = s->metaObject();
    QByteArray want(signalName);
    for (int i = 0; i < mo->methodCount(); ++i) {
        QMetaMethod m = mo->method(i);
        if (m.methodType() != QMetaMethod::Signal || m.name() != want) continue;
        std::string sig = std::string("2") + m.methodSignature().constData();
        std::string sl  = std::string("1") + slot;
        return QObject::connect(s, sig.c_str(), r, sl.c_str()) ? 1 : 0;
    }
    return 0;
}

// A property write that CREATES the property when the meta-object has none, which is what QML does
// for a type whose members the document itself declares (`ListElement { name: "alpha" }`). Used only
// where the compiler has no registry entry to check against — see setPropAny in qtmoc.d.
extern "C" int qtd_prop_set_any(void* o, const char* n, const char* v) {
    if (!o || !n) return 0;
    QObject* q = static_cast<QObject*>(o);
    QVariant val = QString::fromUtf8(v ? v : "");
    int pi = q->metaObject()->indexOfProperty(n);
    if (pi >= 0) {                       // declared: convert to its type, as setProp would
        QMetaProperty mp = q->metaObject()->property(pi);
        QVariant c = val;
        // Qt 5 converts by type ID, Qt 6 by QMetaType — the same seam the rest of this file uses.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        if (c.convert(mp.metaType())) return mp.write(q, c) ? 1 : 0;
#else
        if (c.convert(mp.userType())) return mp.write(q, c) ? 1 : 0;
#endif
        return mp.write(q, val) ? 1 : 0;
    }
    return q->setProperty(n, val) ? 1 : 0;   // undeclared: QML creates it, and so do we
}


extern "C" int qtd_connect_notify(void* ownerV, const char* prop, void* recvV, const char* slot) {
    QObject* owner = static_cast<QObject*>(ownerV);
    QObject* recv  = static_cast<QObject*>(recvV);
    if (!owner || !recv) return 0;
    int pi = owner->metaObject()->indexOfProperty(prop);
    if (pi < 0) return 0;
    QMetaProperty mp = owner->metaObject()->property(pi);
    if (!mp.hasNotifySignal()) return 0;
    std::string s = std::string("2") + mp.notifySignal().methodSignature().constData();
    std::string m = std::string("1") + slot;
    return QObject::connect(owner, s.c_str(), recv, m.c_str(),
                            Qt::UniqueConnection) ? 1 : 0;
}

// ---- QQmlContext --------------------------------------------------------------------------
// A compiled object still needs a QQmlContext. Types that build their children THROUGH the engine
// -- QQmlDelegateModel behind every view, Loader, anything instantiating a QQmlComponent -- call
// QQmlContext::engine() from componentComplete() and segfault on a null context (ComboBox's popup
// contentItem is a ListView: that is the crash). Qt's own qmltc takes a QQmlEngine* in every
// generated constructor for exactly this reason; the win is not parsing QML, not doing without an
// engine. This engine parses nothing -- it exists so those internals have a context to reach.
#ifdef QTD_HAVE_QML
// THE ENGINE THE APPLICATION IS ACTUALLY USING, when it says so.
//
// A compiled document's contexts, its delegated bindings and its delegated handlers all live in an
// engine. Left to itself this file makes one — which is right for a program whose whole interface
// is compiled, and wrong for one that embeds compiled documents in a QQuickView it already has:
// the view's engine is where the application registered its context properties, and a delegated
// expression evaluated in OUR engine cannot see them. Measured on a real reader:
//
//     qtd_run_js: delegated handler on Main_dc7 threw: ReferenceError: bible is not defined
//
// about a context property the application had registered — on the other engine.
//
// So the application may name one. Nothing changes for a program that does not.
static QQmlEngine* g_qtdEngine = nullptr;
#ifdef QTD_HAVE_QML
// A NAME THE APPLICATION PUBLISHES, QUEUED UNTIL THERE IS AN ENGINE TO PUT IT ON.
//
// A context property is how an application hands QML an object it owns — `theme`, `bible` — and
// every expression that reads one is at the mercy of WHEN it was published. The natural place for a
// program to say it is before anything else happens, which is before QCoreApplication exists, and a
// QQmlEngine cannot be built that early (it qFatals). So it is a QUEUE: said whenever the program
// likes, applied the first time an engine is asked for or handed over.
//
// It is also the one place both sides of the differential can share. The oracle builds its own
// QQmlEngine and hands it here; the compiled program uses the engine below. One list, drained onto
// whichever exists, so a published name cannot be on one side and missing from the other.
static QList<QPair<QByteArray, QObject*>>& qtd_pending_ctx() {
    static QList<QPair<QByteArray, QObject*>> v; return v;
}
static void qtd_drain_pending_ctx(QQmlEngine* eng) {
    if (!eng) return;
    auto& v = qtd_pending_ctx();
    for (const auto& p : v)
        eng->rootContext()->setContextProperty(QString::fromUtf8(p.first), p.second);
    v.clear();
}
#endif
extern "C" void qtd_publish_context(const char* name, void* obj) {
#ifdef QTD_HAVE_QML
    if (!name || !*name) return;
    qtd_pending_ctx().append({QByteArray(name), static_cast<QObject*>(obj)});
    // ...and at once, when there already is an engine: a program may publish after startup.
    if (g_qtdEngine) qtd_drain_pending_ctx(g_qtdEngine);
#else
    (void) name; (void) obj;
#endif
}
extern "C" void qtd_set_qml_engine(void* e) {
#ifdef QTD_HAVE_QML
    g_qtdEngine = static_cast<QQmlEngine*>(e);
    qtd_drain_pending_ctx(g_qtdEngine);
#else
    (void) e;
#endif
}
static QQmlEngine* qtd_qml_engine() {
    if (g_qtdEngine) return g_qtdEngine;
    static QQmlEngine* eng = nullptr;
    if (!eng) {
        eng = new QQmlEngine;   // leaked on purpose: it outlives every object pointing at it
        qtd_drain_pending_ctx(eng);
    }
    return eng;
}
#endif
// A QML SINGLETON's one instance, and a call on it. Qt's own controls compute colours with
// `Color.blend(a, b, f)` — a method on a C++ singleton the ENGINE owns, so there is no way to
// reach it by name from any object we hold and no honest way to fake it (constructing our own
// would be a different object with different state). The engine we already keep for contexts owns
// this one too.
extern "C" void qtd_ensure_module(const char* uri);
extern "C" void* qtd_qml_singleton(const char* uri, const char* name, int major, int minor) {
#ifdef QTD_HAVE_QML
    if (!QCoreApplication::instance()) return nullptr;
    // The module has to be LOADED before its types have ids: a compiled document imports nothing
    // by itself, so without this qmlTypeId answers -1, the instance comes back null, the call
    // returns an empty string and the write fails — loudly, which is how this was found.
    qtd_ensure_module(uri);
    int id = qmlTypeId(uri, major, minor, name);
    if (id < 0) return nullptr;
    return qtd_qml_engine()->singletonInstance<QObject*>(id);
#else
    (void) uri; (void) name; (void) major; (void) minor; return nullptr;
#endif
}
// ...and the call itself, by NAME, with every argument passed as text and converted to the
// parameter's own type by QMetaType — the same principle as every property here: the meta-object
// says what the types are, so one function serves every method of every singleton.
extern "C" void* qtd_invoke_str(void* o, const char* method, const char** args, int n) {
    if (!o) return new QString();
    QObject* q = static_cast<QObject*>(o);
    const QMetaObject* mo = q->metaObject();
    QByteArray want(method);
    for (int i = 0; i < mo->methodCount(); ++i) {
        QMetaMethod m = mo->method(i);
        if (m.name() != want || m.parameterCount() != n || n > 8) continue;
        QVariant vals[8];
        QGenericArgument ga[8];
        for (int k = 0; k < n; ++k) {
            vals[k] = QVariant(QString::fromUtf8(args[k]));
#if QT_VERSION >= 0x060000
            if (!vals[k].convert(m.parameterMetaType(k))) return new QString();
#else
            if (!vals[k].convert(m.parameterType(k))) return new QString();
#endif
            ga[k] = QGenericArgument(vals[k].typeName(), vals[k].constData());
        }
#if QT_VERSION >= 0x060000
        QMetaType rt = m.returnMetaType();
        void* rd = rt.create();
#else
        int rtId = m.returnType();
        void* rd = QMetaType::create(rtId);
#endif
        bool ok = m.invoke(q, Qt::DirectConnection,
#if QT_VERSION >= 0x060000
                           QGenericReturnArgument(rt.name(), rd),
#else
                           QGenericReturnArgument(QMetaType::typeName(rtId), rd),
#endif
                           ga[0], ga[1], ga[2], ga[3], ga[4], ga[5], ga[6], ga[7]);
#if QT_VERSION >= 0x060000
        QVariant rv(rt, rd);
        QString out = ok ? rv.toString() : QString();
        rt.destroy(rd);
#else
        QVariant rv(rtId, rd);
        QString out = ok ? rv.toString() : QString();
        QMetaType::destroy(rtId, rd);
#endif
        return new QString(out);
    }
    return new QString();
}
extern "C" void qtd_attach_context(void* o);
// An object whose context the ENGINE owns: it is about to be given one and ours must not take the
// slot first. Measured on a Repeater's delegate: the document context attached in our constructor
// won, the engine's per-item context was never installed, and every `index`/`modelData`/role read
// inside a delegate answered nothing. Item 0 hid it — its index IS zero, and so is a lookup that
// found nothing — which is why the delegate acceptance test had been green throughout.
// Marked on the object itself rather than in a side table, so it dies with the object; a dynamic
// property is invisible to the dump, which walks the meta-object.
// Whether the object HAS a context at all. For an object whose slot we are holding open this is
// exactly "the engine has installed the per-item context yet", which is what a delegate's body has
// to wait for before it reads `index`.
extern "C" int qtd_has_context(void* o) {
#ifdef QTD_HAVE_QML
    return o && QQmlEngine::contextForObject(static_cast<QObject*>(o)) != nullptr;
#else
    (void) o; return 0;
#endif
}
extern "C" void qtd_hold_context(void* o) {
    if (o) static_cast<QObject*>(o)->setProperty("__qtdEngineCtx", true);
}
static bool qtd_context_held(void* o) {
    return o && static_cast<QObject*>(o)->property("__qtdEngineCtx").toBool();
}
// ...with the DOCUMENT the object was written in. The engine gives each component a context whose
// baseUrl is its own document; sharing the engine's root context gave every compiled object an
// empty baseUrl, so a relative `source:`/`font.source` resolved against the process's working
// directory rather than against the .qml file. One context per document, cached: they are
// long-lived by construction and there is one per file, not per object.
extern "C" void qtd_attach_context_url(void* o, const char* docUrl) {
#ifdef QTD_HAVE_QML
    if (!o || qtd_context_held(o)) return;
    if (!docUrl || !*docUrl) { qtd_attach_context(o); return; }
    QObject* obj = static_cast<QObject*>(o);
    if (QQmlEngine::contextForObject(obj)) return;
    if (!QCoreApplication::instance()) return;
    static QHash<QString, QQmlContext*> cache;
    QString key = QString::fromUtf8(docUrl);
    QQmlContext*& ctx = cache[key];
    if (!ctx) {
        ctx = new QQmlContext(qtd_qml_engine()->rootContext(), qtd_qml_engine());
        ctx->setBaseUrl(QUrl(key));
    }
    QQmlEngine::setContextForObject(obj, ctx);
#else
    (void) o; (void) docUrl;
#endif
}
// ...and a context whose PARENT is another object's. A delegate's ROOT gets the per-item context
// the view made — `index`, `modelData` and every model role live there — and its CHILDREN got the
// document's, where those names do not exist, so a binding one level below the delegate root read
// nothing. Contexts nest in the engine; this makes them nest here.
extern "C" void qtd_attach_context_in(void* o, void* parent, const char* docUrl) {
#ifdef QTD_HAVE_QML
    if (!o || qtd_context_held(o)) return;
    QObject* obj = static_cast<QObject*>(o);
    if (QQmlEngine::contextForObject(obj)) return;
    if (!QCoreApplication::instance()) return;
    QQmlContext* up = parent ? QQmlEngine::contextForObject(static_cast<QObject*>(parent)) : nullptr;
    if (!up) { qtd_attach_context_url(o, docUrl); return; }   // no enclosing context: as before
    auto* ctx = new QQmlContext(up, obj);   // owned by the object, like the engine's own per-item one
    if (docUrl && *docUrl) ctx->setBaseUrl(QUrl(QString::fromUtf8(docUrl)));
    QQmlEngine::setContextForObject(obj, ctx);
#else
    (void) o; (void) parent; (void) docUrl;
#endif
}
extern "C" void qtd_attach_context(void* o) {
#ifdef QTD_HAVE_QML
    if (!o || qtd_context_held(o)) return;
    QObject* obj = static_cast<QObject*>(o);
    if (QQmlEngine::contextForObject(obj)) return;   // engine-created objects already have one
    // A QQmlEngine cannot exist before the application object, and it qFatals rather than fail:
    // a program with no QCoreApplication is one that cannot need a context anyway, so leave it be.
    if (!QCoreApplication::instance()) return;
    QQmlEngine::setContextForObject(obj, qtd_qml_engine()->rootContext());
#else
    (void) o;
#endif
}


// ---- declared list properties (`property list<QtObject> kids`) ----------------
// The compiled side ALREADY appends through the meta-object list property —
// `listAppend(this, "kids", _al_kids_0)` is emitted for every element of an array binding — and the
// call did nothing because the property did not exist. Only the callee was missing, and the storage
// need not be on the D side: the runtime owns one vector per (object, property), the append that
// already exists lands in it, and QQmlListReference finds it from either side. The entry dies with
// the object, through the same destroyed() hook the meta-object side-tables use.
#ifdef QTD_HAVE_QML
extern "C++" {
struct QtdListSlot { QObject* owner; QByteArray prop; QVector<QObject*> items; };
static QVector<QtdListSlot*>& qtd_list_slots() { static QVector<QtdListSlot*> v; return v; }
// Qt5 indexes a list property with `int` and Qt6 with `qsizetype`; the class NAMES the type, so
// take it from there rather than branching on the version.
using QtdLsIndex = decltype(QQmlListProperty<QObject>().count(nullptr));
static void qtd_ls_append(QQmlListProperty<QObject>* p, QObject* v) {
    static_cast<QtdListSlot*>(p->data)->items.append(v);
}
static QtdLsIndex qtd_ls_count(QQmlListProperty<QObject>* p) {
    return static_cast<QtdLsIndex>(static_cast<QtdListSlot*>(p->data)->items.size());
}
static QObject* qtd_ls_at(QQmlListProperty<QObject>* p, QtdLsIndex i) {
    auto& v = static_cast<QtdListSlot*>(p->data)->items;
    return (i >= 0 && i < static_cast<QtdLsIndex>(v.size())) ? v.at(int(i)) : nullptr;
}
static void qtd_ls_clear(QQmlListProperty<QObject>* p) {
    static_cast<QtdListSlot*>(p->data)->items.clear();
}
static QtdListSlot* qtd_list_slot(QObject* o, const char* name) {
    for (QtdListSlot* s : qtd_list_slots())
        if (s->owner == o && s->prop == name) return s;
    auto* s = new QtdListSlot{o, QByteArray(name), {}};
    qtd_list_slots().append(s);
    QObject::connect(o, &QObject::destroyed, o, [s]() { qtd_list_slots().removeOne(s); delete s; });
    return s;
}
}
#endif
// A QML `property var`: the meta-object carries it as a QVariant and the RUNTIME owns the value.
// The D side holds nothing — which is the whole point. `QVariant` IS bound, but as opaque storage
// with a destructor and NO copy constructor, so a D field of it is copied bytewise and freed twice;
// that prerequisite is what blocked this for so long. It disappears once the question is asked the
// other way round: nobody said the value had to live on the D side. Same shape as the list slot
// above, and the entry dies with the object through the same destroyed() hook.
//
// NOT BEHIND THE QML SWITCH, and it was — which cost a real user a blank page on a real phone.
// Everything here is QtCore: QObject, QByteArray, QVariant, and a destroyed() connection. The
// switch is about whether QtQml is LINKED, and a `property var`'s storage never needed it.
//
// Built without QTD_HAVE_QML, `qtd_moc_var_write` was an empty function. The symptom is what makes
// this worth spelling out: `setModel` builds its QVariantList through the varlist/varmap calls,
// which are QtCore and compiled in every configuration, so the model was built correctly; the
// notify fired, because a signal is independent of any of this; and only the WRITE went nowhere,
// so QML read `undefined` for the one property that mattered and every neighbouring `@Property
// string` kept working. Measured on Android by the session that ships the application: the reading
// page came up blank on the device and rendered on the desktop, from the same D source.
extern "C++" {
struct QtdVarSlot { QObject* owner; QByteArray prop; QVariant v; };
static QVector<QtdVarSlot*>& qtd_var_slots() { static QVector<QtdVarSlot*> v; return v; }
static QtdVarSlot* qtd_var_slot(QObject* o, const char* name) {
    for (QtdVarSlot* s : qtd_var_slots())
        if (s->owner == o && s->prop == name) return s;
    auto* s = new QtdVarSlot{o, QByteArray(name), QVariant()};
    qtd_var_slots().append(s);
    QObject::connect(o, &QObject::destroyed, o, [s]() { qtd_var_slots().removeOne(s); delete s; });
    return s;
}
}
// ---- a MODEL, built on the D side --------------------------------------------------------------
//
// A QVariantList of QVariantMap IS a QML model: a view iterates it and a delegate reads each map's
// keys by name, with no QAbstractListModel and no moc anywhere. What the D side lacked was a way to
// BUILD one — `qtd_prop_set_list` makes a flat list of scalars from strings and nothing made a map
// — so applications reached for the only thing that did cross: a JSON string the QML re-parses on
// every change. That costs a serialise, a parse, and a delegate that reads through `modelData`,
// which is the shape this compiler cannot compile (docs/qmltc-d-gaps.md, gaps 1-3).
//
// Handles, not values, because a QVariant tree has no place in a D struct: the D side calls these in
// order and the last one consumes what it was given. QVariantList and QVariantMap are QtCore, so
// none of this needs QtQml and it builds in every configuration.
// A SINGLE VALUE IN A QVariant, so a typed D argument can be handed to JavaScript. The list
// builder above makes rows; this makes one operand — what a function body delegated to the engine
// needs for each of its parameters, which arrive here already typed and have to leave untyped.
// A `var` PROPERTY AS TEXT, formatted the way the differential's oracle formats it: a list joined
// by commas, anything else through QVariant::toString. Without it the dump printed the D field —
// which for a `var` is an empty marker struct, since the runtime owns the value — so a property
// holding [1,2,3] compared EQUAL to one holding nothing, on every document in the corpus.
extern "C" void* qtd_var_text(void* o, const char* name) {
    QString out;
    if (o && name) {
        QVariant v = static_cast<QObject*>(o)->property(name);
        // BOTH QT MAJORS NAME IT DIFFERENTLY, and the Qt6 spelling does not exist in Qt5:
        // `QVariant::metaType()` arrived with Qt 6 and `userType()` is what 5 has. Written for one
        // of them, this took the whole qml binding's shim archive down on the other.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        const int vt = v.metaType().id();
#else
        const int vt = v.userType();
#endif
        if (v.canConvert<QVariantList>() && vt != QMetaType::QString) {
            const QVariantList l = v.toList();
            for (const QVariant& e : l) { if (!out.isEmpty()) out += QLatin1Char(','); out += e.toString(); }
        } else {
            out = v.toString();
        }
    }
    return new QString(out);
}
extern "C" void* qtd_var_of_int(long long v) { return new QVariant(qlonglong(v)); }
extern "C" void* qtd_var_of_double(double v) { return new QVariant(v); }
extern "C" void* qtd_var_of_bool(bool v) { return new QVariant(v); }
extern "C" void* qtd_var_of_str(const char* v, int len) {
    return new QVariant(QString::fromUtf8(v ? v : "", len));
}
extern "C" void* qtd_varlist_new() { return new QVariantList(); }
extern "C" void* qtd_varmap_new()  { return new QVariantMap(); }
extern "C" void qtd_varmap_set_str(void* m, const char* k, const char* v, int len) {
    if (m && k) static_cast<QVariantMap*>(m)->insert(QString::fromUtf8(k),
                    QString::fromUtf8(v ? v : "", len));
}
extern "C" void qtd_varmap_set_int(void* m, const char* k, long long v) {
    if (m && k) static_cast<QVariantMap*>(m)->insert(QString::fromUtf8(k), qlonglong(v));
}
extern "C" void qtd_varmap_set_double(void* m, const char* k, double v) {
    if (m && k) static_cast<QVariantMap*>(m)->insert(QString::fromUtf8(k), v);
}
extern "C" void qtd_varmap_set_bool(void* m, const char* k, bool v) {
    if (m && k) static_cast<QVariantMap*>(m)->insert(QString::fromUtf8(k), v);
}
// Appends and DELETES the map: the list owns the value from here on, and a caller that has to
// remember to free each row is a caller that will not.
extern "C" void qtd_varlist_push(void* l, void* m) {
    if (!l || !m) return;
    static_cast<QVariantList*>(l)->append(*static_cast<QVariantMap*>(m));
    delete static_cast<QVariantMap*>(m);
}
extern "C" int qtd_varlist_count(void* l) {
    return l ? int(static_cast<QVariantList*>(l)->size()) : 0;
}
// ...and the list itself is consumed by the write. `out` is a QVariant the caller owns.
// The caller's QVariant storage is a plain byte box on the D side (see QmlVarBox): built here,
// released here, never named there.
// ...AND THE OTHER DIRECTION. A function with an untyped parameter is declared to the meta-object
// and delegated to the engine (see callJsFunc), so its RESULT crosses as a QVariant — and a
// compiled call site needs it as the scalar the surrounding expression is typed for. QVariant's own
// conversion is the one the engine would have applied.
extern "C" long long qtd_varbox_as_int(void* v) {
    return v ? static_cast<QVariant*>(v)->toLongLong() : 0;
}
extern "C" double qtd_varbox_as_double(void* v) {
    return v ? static_cast<QVariant*>(v)->toDouble() : 0.0;
}
extern "C" bool qtd_varbox_as_bool(void* v) {
    return v ? static_cast<QVariant*>(v)->toBool() : false;
}
extern "C" void* qtd_varbox_as_str(void* v) {
    return new QString(v ? static_cast<QVariant*>(v)->toString() : QString());
}

extern "C" void qtd_var_box_clear(void* v) { if (v) static_cast<QVariant*>(v)->~QVariant(); }
extern "C" void qtd_varlist_into(void* l, void* out) {
    if (out) new (out) QVariant();
    if (!l) return;
    if (out) *static_cast<QVariant*>(out) = QVariant(*static_cast<QVariantList*>(l));
    delete static_cast<QVariantList*>(l);
}

// HOW MANY ROWS A `var` PROPERTY HOLDS, which `qtd_var_text` cannot answer: a row is a QVariantMap
// and a map has no string form, so a model of any size renders as the empty string. That is correct
// for text and useless for a test — a check written on it passes on an empty property and on a full
// one alike. Returns -1 when the value is not a list at all, so "not a model" and "an empty model"
// stay apart.
extern "C" int qtd_var_count(void* o, const char* name) {
    if (!o || !name) return -1;
    const QVariant v = static_cast<QObject*>(o)->property(name);
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    const int vt = v.metaType().id();
#else
    const int vt = v.userType();
#endif
    if (!v.canConvert<QVariantList>() || vt == QMetaType::QString) return -1;
    return int(v.toList().size());
}

extern "C" void qtd_moc_var_read(void* o, const char* name, void* out) {
    if (o && out) *static_cast<QVariant*>(out) = qtd_var_slot(static_cast<QObject*>(o), name)->v;
}
extern "C" void qtd_moc_var_write(void* o, const char* name, void* in_) {
    if (o && in_) qtd_var_slot(static_cast<QObject*>(o), name)->v = *static_cast<QVariant*>(in_);
}

// ...AND A `var` ROLE, WHICH HAD NO FILL AT ALL. The table above types a required role as string,
// int, bool or double and a `var` is none of those, so the whole branch was skipped and the
// property was never given the view's value — it stayed at its (empty) default while every typed
// role beside it was filled.
//
// Measured on a real reader's search panel: the delegate declares `required property string label`
// and `required property var refs`; the section heading painted from `label` and the verses under
// it never appeared, because the inner Repeater's model is `refs`. A whole role type missing from
// a per-type table, which is the shape this compiler keeps producing.
//
// The value goes straight into the var slot rather than being returned, because a `var`'s value is
// not in the D field: the field is a marker and the runtime owns the value.
extern "C" void qtd_ctx_fill_var(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    if (o && name) qtd_var_slot(static_cast<QObject*>(o), name)->v = qtd_ctx_role(o, name);
#else
    (void) o; (void) name;
#endif
}


// Fills `*out` with the QQmlListProperty for `<o>.<name>` — the only way one is ever handed out.
extern "C" void qtd_moc_list_read(void* o, const char* name, void* out) {
#ifdef QTD_HAVE_QML
    if (!o || !out) return;
    qtd_register_list_metatype();
    auto* obj = static_cast<QObject*>(o);
    *static_cast<QQmlListProperty<QObject>*>(out) = QQmlListProperty<QObject>(
        obj, qtd_list_slot(obj, name), &qtd_ls_append, &qtd_ls_count, &qtd_ls_at, &qtd_ls_clear);
#else
    (void) o; (void) name; (void) out;
#endif
}

// ---- QQmlFinalizerHook --------------------------------------------------------
// Qt 6 gives a bound type a THIRD construction phase, after classBegin and componentComplete:
// QQmlFinalizerHook::componentFinalized(), which QQmlComponent::completeCreate() runs once the
// WHOLE component is built. Nothing in QQmlParserStatus stands in for it — measured on Qt's own
// HorizontalHeaderView: after classBegin + componentComplete (twice, and an event-loop turn) the
// object still reports rows/columns/contentWidth/contentHeight all -1 and `model` unset, where the
// engine reports 1/0/0/0 and `model` int 0. One call to componentFinalized() reproduces the
// engine's state exactly.
//
// It is not a per-type mechanism: the registry publishes it (`interfaces: ["QQmlFinalizerHook"]`
// on QQuickTableView and friends) and Q_INTERFACES puts it in the meta-object, so a cast by IID
// finds it for any type that has one.
//
// The interface is DECLARED here rather than included from QtQml/private: it is a virtual
// destructor followed by one pure virtual, and the cast resolves it by IID string, so a matching
// declaration is ABI-compatible without making the runtime depend on a private header that "may
// change from version to version without notice". Qt5 has no such phase at all — its engine never
// calls one — so doing nothing there IS the parity.
// `extern "C++"` because this file is compiled inside an `extern "C"` region: a class with virtual
// members and the template Q_DECLARE_INTERFACE generates are both C++-linkage-only, and the
// compiler says so rather than silently mis-linking.
#if defined(QTD_HAVE_QML) && QT_VERSION >= QT_VERSION_CHECK(6, 2, 0)
extern "C++" {
class QQmlFinalizerHook
{
public:
    virtual ~QQmlFinalizerHook();
    virtual void componentFinalized() = 0;
};
#define QQmlFinalizerHook_iid "org.qt-project.Qt.QQmlFinalizerHook"
Q_DECLARE_INTERFACE(QQmlFinalizerHook, QQmlFinalizerHook_iid)
}
#endif

// ---- value-type ("gadget") grouped properties --------------------------------
// `Q_PROPERTY(ValueTypeGroup vt ...)` where ValueTypeGroup is a Q_GADGET: `vt.count` in QML does
// NOT go through an object, because there is no object — the property holds a VALUE. Reading is
// read-then-extract, and writing is read-modify-WRITE-BACK: changing a member of the temporary
// alone would be discarded, which is the difference from a QObject group (a reference, where the
// member write lands directly). Qt exposes exactly this via QMetaProperty's gadget overloads.
static const QMetaObject* gadgetMeta(const QVariant& v) {
    // Qt6 reaches the gadget's meta-object through QMetaType; Qt5 has no QVariant::metaType(),
    // but QMetaType::metaObjectForType(userType) answers the same question. readOnGadget /
    // writeOnGadget themselves exist in both.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    return v.metaType().metaObject();
#else
    return QMetaType::metaObjectForType(v.userType());
#endif
}
static bool gadgetProp(const QVariant& v, const char* member, QMetaProperty& out) {
    const QMetaObject* mo = gadgetMeta(v);
    if (!mo) return false;
    int i = mo->indexOfProperty(member);
    if (i < 0) return false;
    out = mo->property(i);
    return true;
}

// `X as SomeType` in a DELEGATED expression. QML's `as` yields the object when it is of that type
// and null otherwise, and the type name itself cannot survive into a hand-made context (no import
// namespace). So the compiler hands the object over and asks the question HERE, where it is one
// generic walk up the meta-object chain — no table of types, and nothing that knows what a
// NinePatchImage is.
extern "C" void *qtd_cast_class(void *o, const char *cls) {
    if (!o || !cls || !*cls) return nullptr;
    for (const QMetaObject *mo = static_cast<QObject *>(o)->metaObject(); mo; mo = mo->superClass())
        if (std::strcmp(mo->className(), cls) == 0) return o;
    return nullptr;
}

// Attach a PROPERTY VALUE SOURCE (`NumberAnimation on width`, `Behavior on x`) to its target.
// QQmlPropertyValueSource is one generic interface: the object says "I drive this property", Qt
// hands it a QQmlProperty and the object takes it from there. So this one entry point covers every
// animation type, Behavior, and anything else that implements it — no per-type mechanism, and no
// need for the compiler to know what a NumberAnimation is.
// Only where QtQml is actually LINKED. This file is compiled into every binding's shims, and the
// widgets binding has no QtQml: the symbols exist in the headers but not in the link, so an
// unconditional definition broke every widgets test with undefined references. QT_QML_LIB is what
// pkg-config defines for Qt6Qml, so it marks exactly the bindings that can satisfy them.
#ifdef QT_QML_LIB
extern "C" int qtd_attach_value_source(void *src, void *target, const char *prop) {
    if (!src || !target) return 0;
    auto *vs = dynamic_cast<QQmlPropertyValueSource *>(static_cast<QObject *>(src));
    // `X on prop` has TWO mechanisms in QML — a value SOURCE and a value INTERCEPTOR — and the
    // object itself says which it is. Probed against Qt alone: QQuickNinePatchImageSelector, which
    // is how every Imagine control resolves its image, answers `is value source: 0  is
    // interceptor: 1`. Handling only the first is what made the whole style compile with the
    // unresolved base path and no suffix.
    if (!vs) {
        // `X on prop` binds a value SOURCE or a value INTERCEPTOR, and Qt's Imagine style uses the
        // second for every image it shows (`NinePatchImageSelector on source`) — as does
        // `Behavior on x`. An interceptor is not given the property, it is INSTALLED on it and
        // rewrites each write that passes. Probed against Qt alone before building this: it
        // resolves only when the object was created from the real DOCUMENT, because the path it
        // computes is relative to it — which is why the same call produced nothing until the
        // engine-created objects started carrying their document url.
// QTD_HAVE_QML, not QT_QML_LIB: those two answer different questions. QT_QML_LIB is "does this
        // binding LINK QtQml" and guards this whole function; QTD_ENABLE_QML is "does it register QML
        // types", and it is the one that puts the VERSIONED include path of Qt's private headers on
        // the command line. The webengine binding links QtQml with registration off, so an
        // interceptor branch keyed on the first found no `qqmlmetatype_p.h` at all. A binding that
        // does not register types also never compiles a QML document, so it loses nothing here.
#if defined(QTD_HAVE_QML) && QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        auto *iv = qobject_cast<QQmlPropertyValueInterceptor *>(static_cast<QObject *>(src));
        if (!iv) {
            std::fprintf(stderr, "qtd_attach_value_source: '%s' on %s is neither a value source nor "
                                 "an interceptor\n", prop,
                         static_cast<QObject *>(src)->metaObject()->className());
            return 0;
        }
        QObject *tgt = static_cast<QObject *>(target);
        QQmlProperty p(tgt, QString::fromUtf8(prop), qmlContext(tgt));
        if (!p.isValid()) {
            std::fprintf(stderr, "qtd_attach_value_source: no property '%s' on %s for an interceptor\n",
                         prop, tgt->metaObject()->className());
            return 0;
        }
        iv->setTarget(p);
        int idx = tgt->metaObject()->indexOfProperty(prop);
        if (idx < 0) return 0;
        // The property CACHE, not just the meta-object. Qt's interception path reads the type of
        // the property being written off `QQmlData::get(object)->propertyCache`, and on an object
        // the engine never built that pointer is null — Qt's Basic Switch segfaulted inside
        // QQmlInterceptorMetaObject::doIntercept the first time its `Behavior on x` actually fired.
        // ensurePropertyCache builds one from the object's own meta-object, which is what
        // QQmlObjectCreator does for the objects it makes.
        auto cache = QQmlData::ensurePropertyCache(tgt);
        if (!cache) {
            std::fprintf(stderr, "qtd_attach_value_source: no property cache for %s — '%s' left "
                                 "uninterceptable\n", tgt->metaObject()->className(), prop);
            return 0;
        }
        auto *imo = QQmlInterceptorMetaObject::get(tgt);
        if (!imo) imo = new QQmlInterceptorMetaObject(tgt, cache);
        imo->registerInterceptor(QQmlPropertyIndex(idx), iv);
        return 1;
#else
        std::fprintf(stderr, "qtd_attach_value_source: '%s' on %s is not a value source (no way in "
                             "for an interceptor in this build)\n", prop,
                     static_cast<QObject *>(src)->metaObject()->className());
        return 0;
#endif
    }
    QQmlProperty p(static_cast<QObject *>(target), QString::fromUtf8(prop));
    if (!p.isValid()) {
        std::fprintf(stderr, "qtd_attach_value_source: no property '%s' on %s\n",
                     prop, static_cast<QObject *>(target)->metaObject()->className());
        return 0;
    }
    vs->setTarget(p);
    return 1;
}
#else
extern "C" int qtd_attach_value_source(void *, void *, const char *) { return 0; }
#endif

// Does the object's meta-object declare this property at all? Only an Item has `parent`, so a
// linkage check can ask before asserting instead of assuming every child is visual.
extern "C" int qtd_has_prop(void* o, const char* n) {
    if (!o) return 0;
    return static_cast<QObject*>(o)->metaObject()->indexOfProperty(n) >= 0 ? 1 : 0;
}

// Copy a property from one object to another WITHOUT naming its type. The QVariant carries the
// type and QMetaType converts on write, so this reaches QColor, QFont, an enum, a model — every
// value type at once. The typed helpers each need the D type spelled out, which is exactly what a
// generated binding does not have for `font: control.font`.
extern "C" int qtd_prop_copy(void* src, const char* sname, void* dst, const char* dname) {
    if (!src || !dst) return 0;
    QVariant v = static_cast<QObject*>(src)->property(sname);
    if (!v.isValid()) return 0;
    // A null OBJECT copied into a QVariant-typed property is QML's `null`, not "a pointer of this
    // class that happens to be null". Qt's ComboBox binds `model: control.delegateModel`, which is
    // null until a model is set: the engine leaves `std::nullptr_t` there and we left
    // `QQmlInstanceModel*`, so the dump read `<null>` against the engine's empty — the same value,
    // spelled as a different type. Only for a QVariant target: a typed object property must keep
    // taking a typed null, or the write would simply fail.
    if (v.canConvert<QObject*>() && !v.value<QObject*>()) {
        auto* d = static_cast<QObject*>(dst);
        int i = d->metaObject()->indexOfProperty(dname);
        // Qt5 has no QMetaProperty::metaType(); userType() answers the same question there.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        bool variantTarget = i >= 0 && d->metaObject()->property(i).metaType()
                                       == QMetaType::fromType<QVariant>();
#else
        bool variantTarget = i >= 0 && d->metaObject()->property(i).userType() == QMetaType::QVariant;
#endif
        if (variantTarget) return qtd_prop_write(dst, dname, QVariant::fromValue(nullptr));
    }
    return qtd_prop_write(dst, dname, v);
}

// Reads <obj>.<group>.<member> into a QVariant. Returns an invalid QVariant when anything in the
// chain is absent, which the typed wrappers below turn into the type's default.
static QVariant qtd_valuegroup_read(void* o, const char* group, const char* member) {
    if (!o) return QVariant();
    QVariant v = static_cast<QObject*>(o)->property(group);
    QMetaProperty p;
    if (!v.isValid() || !gadgetProp(v, member, p)) return QVariant();
    return p.readOnGadget(v.constData());
}

// Writes <obj>.<group>.<member>, preserving every other member of the value.
static int qtd_valuegroup_write(void* o, const char* group, const char* member, const QVariant& val) {
    if (!o) return 0;
    auto* obj = static_cast<QObject*>(o);
    QVariant v = obj->property(group);
    QMetaProperty p;
    if (!v.isValid() || !gadgetProp(v, member, p)) return 0;
    // An ENUM member takes its KEY, which is how every enum crosses this channel — and
    // writeOnGadget does NOT do the key lookup that QMetaProperty::write does for a QObject, so
    // `easing.type: Easing.OutCubic` failed the write outright. QMetaEnum is the same translator
    // the reader (qtd_prop_get_enum_key) uses in the other direction.
    QVariant use = val;
    if (p.isEnumType() && val.userType() == QMetaType::QString) {
        bool ok = false;
        QMetaEnum me = p.enumerator();
        const QByteArray key = val.toString().toUtf8();
        int iv = p.isFlagType() ? me.keysToValue(key.constData(), &ok)
                                : me.keyToValue(key.constData(), &ok);
        if (!ok) return 0;
        use = QVariant(iv);
    }
    if (!p.writeOnGadget(v.data(), use)) return 0;
    return obj->setProperty(group, v) || true;   // setProperty is false for a non-Q_PROPERTY name
}

extern "C" {
// ...and the same copy for a member of a value-typed GROUP: `color: control.palette.text`.
extern "C" int qtd_prop_copy_group(void* src, const char* g, const char* m, void* dst, const char* dname) {
    if (!src || !dst) return 0;
    // A "group" is either a Q_GADGET VALUE (QFont -> readOnGadget) or a QObject (QQuickPalette,
    // which is what `control.palette` actually is). Reading an object with readOnGadget reads
    // through a pointer as if it were the value and yields nothing usable, so the object case is
    // dispatched on what the QVariant really holds.
    QVariant gv = static_cast<QObject*>(src)->property(g);
    QVariant v;
    if (gv.canConvert<QObject*>()) {
        QObject* go = gv.value<QObject*>();
        if (!go) return 0;
        v = go->property(m);
    } else {
        v = qtd_valuegroup_read(src, g, m);
    }
    if (!v.isValid()) return 0;
    return qtd_prop_write(dst, dname, v);
}

int  qtd_vgroup_get_int(void* o, const char* g, const char* m)    { return qtd_valuegroup_read(o, g, m).toInt(); }
bool qtd_vgroup_get_bool(void* o, const char* g, const char* m)   { return qtd_valuegroup_read(o, g, m).toBool(); }
double qtd_vgroup_get_double(void* o, const char* g, const char* m){ return qtd_valuegroup_read(o, g, m).toDouble(); }
// Same string convention as the scalar helpers: hand back a QString the D side frees.
void* qtd_vgroup_get_qs(void* o, const char* g, const char* m) {
    return new QString(qtd_valuegroup_read(o, g, m).toString());
}
int qtd_vgroup_set_int(void* o, const char* g, const char* m, int v)    { return qtd_valuegroup_write(o, g, m, v); }
int qtd_vgroup_set_bool(void* o, const char* g, const char* m, bool v)  { return qtd_valuegroup_write(o, g, m, v); }
int qtd_vgroup_set_double(void* o, const char* g, const char* m, double v){ return qtd_valuegroup_write(o, g, m, v); }
int qtd_vgroup_set_qs(void* o, const char* g, const char* m, const char* s, int n) {
    return qtd_valuegroup_write(o, g, m, QString::fromUtf8(s, n));
}
}

// Attached-property lookup needs QQmlMetaType::qmlType(QString, QString, QTypeRevision) and
// qmlAttachedPropertiesObject — QTypeRevision is Qt6-only and Qt5's QQmlMetaType has no
// (QString, QString, …) overload at all. Qt5 gets the stub; a Qt5 document using an attached
// property fails to resolve it rather than failing to build. (Same shape as the QT_VERSION
// branch in the RegisterType block below.)
#if defined(QTD_HAVE_QML) && QT_VERSION >= 0x060000
// (extern "C++" again, and INSIDE this guard on purpose: the else branch names QQmlEnginePrivate,
// and a name in a template body must be declarable where the template is DEFINED even when
// `if constexpr` discards the branch that uses it. Defined in the general section it broke the one
// build that compiles this file without QtQml at all — the Android shims:
//     qtdmoc.cpp:468: error: unknown type name 'QQmlEnginePrivate'
// which is a compile that had nothing to do with attached properties.)
extern "C++" {
/// `attachedPropertiesFunction` takes a QQmlTypeLoader* in recent Qt and a QQmlEnginePrivate* in
/// older ones, and 6.10 briefly carried both — which is why the argument is cast rather than left
/// as a bare `nullptr` (ambiguous there). The cast target is whichever the declaration wants.
/// The test is on the CALL, not on `&QT::attachedPropertiesFunction`: while 6.10 carries both
/// overloads, taking the member's address is itself ambiguous ("reference to overloaded function
/// could not be resolved") and the file did not compile against Qt 6.10 at all.
template <class QT, class = void>
struct qtdTakesTypeLoader : std::false_type {};
template <class QT>
struct qtdTakesTypeLoader<QT, std::void_t<decltype(std::declval<const QT &>()
        .attachedPropertiesFunction(static_cast<QQmlTypeLoader *>(nullptr)))>> : std::true_type {};
template <class QT>
static auto qtdAttachedFn(const QT &t) {
    if constexpr (qtdTakesTypeLoader<QT>::value)
        return t.attachedPropertiesFunction(static_cast<QQmlTypeLoader *>(nullptr));
    else
        return t.attachedPropertiesFunction(static_cast<QQmlEnginePrivate *>(nullptr));
}
}   // extern "C++"

// The ATTACHED-properties object a QML type provides for `obj` (`TestType.attachedCount` in QML).
// The type is looked up BY NAME in Qt's own QML type registry, so this works for any registered
// type without the D side knowing it at compile time. Returns null when the type is unknown or
// attaches nothing — the callers null-guard, so that stays a visible no-op.
void* qtd_attached_obj(void* obj, const char* uri, const char* typeName) {
    if (!obj) return nullptr;
    auto t = QQmlMetaType::qmlType(QString::fromUtf8(typeName), QString::fromUtf8(uri), QTypeRevision());
    if (!t.isValid()) return nullptr;
    // The cast is not decoration: Qt 6.10 still carries an older overload beside the
    // QQmlTypeLoader* one, so a bare `nullptr` is ambiguous there and the file does not compile —
    // `call to member function 'attachedPropertiesFunction' is ambiguous`. 6.11 kept only this
    // one, so naming it works on both.
    auto fn = qtdAttachedFn(t);
    if (!fn) return nullptr;
    // Go through qmlAttachedPropertiesObject, NOT the raw function: the raw one CONSTRUCTS an
    // attached object every time it is called. The public entry point caches per (object, type),
    // which is what QML semantics require — `Type.x: 1` then reading `Type.x` must see the same
    // object. Calling the raw function gave a fresh, empty attachment on every access.
    return qmlAttachedPropertiesObject(static_cast<QObject*>(obj), fn, /*create*/ true);
}
#else
void* qtd_attached_obj(void*, const char*, const char*) { return nullptr; }
#endif

// Reset a property to its default — what `prop: undefined` means in QML. It must go through
// QMetaProperty::reset: the RESET method named by Q_PROPERTY is an ordinary member, not a slot or
// Q_INVOKABLE, so invoking it BY NAME finds nothing and silently does nothing.
bool qtd_prop_reset(void* o, const char* n) {
    if (!o) return false;
    auto* obj = static_cast<QObject*>(o);
    int i = obj->metaObject()->indexOfProperty(n);
    return i >= 0 && obj->metaObject()->property(i).reset(obj);
}
// Parent a QObject to another — Qt then OWNS the child and destroys it with the parent, which is
// what closes the side-table entry (~QtdMocObject -> qtd_moc_teardown -> the D registry drops it).
// A compiled QML document nests objects; without a parent each one would keep its registry entry,
// and therefore its D object, alive for the life of the process.
void qtd_set_parent(void* child, void* parent) {
    if (!child) return;
    static_cast<QObject*>(child)->setParent(static_cast<QObject*>(parent));
}
// Write a QObject* into a property — how a child object built in D is attached to a member of a
// GROUPED property (`group.object: QtObject { … }`).
int qtd_prop_set_obj(void* o, const char* n, void* v) {
    if (!o) return 0;
    QObject* q = static_cast<QObject*>(o);
    // The property is usually declared as a DERIVED pointer (`QQuickItem*`, `AbstractButton*`)
    // and a QVariant holding a plain QObject* does NOT convert to one — setProperty just returns
    // false, leaving the property null and every binding that reads through it quietly empty
    // (Qt's Fusion writes `control: control` on every indicator it builds). The declared metatype
    // is right there in the meta-object, so the variant is built AS that type: one rule for every
    // object property, with no type name crossing from D.
    const QMetaObject* mo = q->metaObject();
    int i = mo->indexOfProperty(n);
    if (i >= 0) {
        QMetaProperty mp = mo->property(i);
#ifdef QTD_HAVE_QML
        // ...and a property declared as a QJSValue takes a SCRIPT value, not a variant: Qt's
        // Rectangle declares `gradient` that way, so `gradient: Gradient { ... }` — which every
        // Fusion control writes — silently did nothing and the shape drew flat. The engine turns
        // an object into a script value; it is the same engine the document is attached to.
        if (std::strcmp(mp.typeName(), "QJSValue") == 0) {
            QObject* vo = static_cast<QObject*>(v);
            QQmlEngine* e = qmlEngine(q);
            if (!e && vo) e = qmlEngine(vo);
            if (e) return mp.write(q, QVariant::fromValue(e->newQObject(vo))) ? 1 : 0;
        }
#endif
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        QMetaType mt = mp.metaType();
        // ...and only when the object REALLY IS one: the variant built this way is a
        // reinterpretation, not a conversion, so an object of the wrong class would be handed to
        // Qt as the declared type and dereferenced as one (a plain QObject written into
        // `first.handle` segfaulted inside QQuickItem::setParentItem). The check is the one
        // qobject_cast performs, on the meta-object chain.
        if ((mt.flags() & QMetaType::PointerToQObject) && mt.metaObject()) {
            QObject* vo = static_cast<QObject*>(v);
            if (!vo || vo->metaObject()->inherits(mt.metaObject()))
                return mp.write(q, QVariant(mt, &v)) ? 1 : 0;
            return 0;
        }
#else
        int tid = mp.userType();
        if (QMetaType::typeFlags(tid) & QMetaType::PointerToQObject)
            return mp.write(q, QVariant(tid, &v)) ? 1 : 0;
#endif
    }
    return q->setProperty(n, QVariant::fromValue(static_cast<QObject*>(v))) ? 1 : 0;
}
// Invoke a parameterless member (a signal or an invokable) by name on any QObject — how a QML
// handler emits a signal that belongs to a GROUPED property's object rather than to itself.
// Returns false if there is no such member.
bool qtd_invoke0(void* o, const char* member) {
    if (!o) return false;
    return QMetaObject::invokeMethod(static_cast<QObject*>(o), member, Qt::DirectConnection);
}
// `Qt.styleHints` in QML is QGuiApplication::styleHints() — an ORDINARY QObject whose members
// are ordinary properties (`accessibility` is a CONSTANT QObject property, `contrastPreference`
// an enum one with a notify). So the generic channel already reaches all of it; the only thing
// missing was the ROOT, which cannot be reached by name from any object we hold. Guarded on
// QT_GUI_LIB — a define pkg-config supplies exactly when Gui is one of the binding's modules,
// so a core-only binding neither compiles nor links QtGui for it (see the QTD_ENABLE_QML note).
// `Qt.platform.pluginName` — a QML global with no QObject behind it, like the colour helpers.
// QML returns QGuiApplication::platformName() there, so that is what this returns; empty in a
// binding without QtGui, which is also what a document reading it would see.
// The NUMERIC value of an enum key, looked up on the C++ type that declares it. QML spells these
// as `StandardKey.Undo`, where `StandardKey` is an UNCREATABLE type (QKeySequence) exported for its
// enum alone — there is no object to read the member from, and the key as text is no use either
// (Qt would parse "Undo" as three letters). The number is what QML assigns, and QMetaEnum is where
// it lives. Returns `def` when the type or the key is unknown, so a wrong guess is a value the
// caller chose rather than a silent zero.
extern "C" int qtd_enum_value(const char* cxxType, const char* key, int def) {
    if (!cxxType || !key) return def;
    // The Qt NAMESPACE is not a type: `QMetaType::fromName("Qt")` answers nothing (measured), so
    // every `Qt.Checked` where a NUMBER is wanted fell through to the default. Its meta-object is
    // reachable directly, and it carries every Qt:: enum — one branch for the whole namespace,
    // not one per enum.
    if (std::strcmp(cxxType, "Qt") == 0) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        for (int i = 0; i < Qt::staticMetaObject.enumeratorCount(); ++i) {
            bool ok = false;
            int v = Qt::staticMetaObject.enumerator(i).keyToValue(key, &ok);
            if (ok) return v;
        }
        return def;
#elif defined(QTD_HAVE_QML)
        // Qt5 has no `Qt::staticMetaObject` — the namespace only became introspectable in Qt6, and
        // the Qt5 build stopped compiling the moment this was written, which is what the noqml/qml5
        // probe targets are for. The value is still reachable there, through the channel that
        // publishes these names to every .qml in the first place: the engine's own `Qt` object.
        if (QCoreApplication::instance()) {
            QQmlExpression e(qtd_qml_engine()->rootContext(), nullptr,
                             QString::fromUtf8("Qt.") + QString::fromUtf8(key));
            QVariant v = e.evaluate();
            if (!e.hasError() && v.isValid()) return v.toInt();
        }
        return def;
#else
        return def;
#endif
    }
    // QMetaType::fromName is Qt6; Qt5 answers the same question through the type id.
    // ...under the bare name for a GADGET or a namespace (`StandardKey`), and under the POINTER for
    // a QObject class: `QQuickAbstractAnimation` has no metatype, `QQuickAbstractAnimation*` does.
    // Only the first spelling was tried, so every enum of an object type answered the fallback --
    // `loops: Animation.Infinite` came out 0 where the engine has -1.
    const QByteArray star = QByteArray(cxxType) + "*";
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    const QMetaObject* mo = QMetaType::fromName(cxxType).metaObject();
    if (!mo) mo = QMetaType::fromName(star).metaObject();
#else
    const QMetaObject* mo = QMetaType::metaObjectForType(QMetaType::type(cxxType));
    if (!mo) mo = QMetaType::metaObjectForType(QMetaType::type(star.constData()));
#endif
    if (!mo) return def;
    for (int i = 0; i < mo->enumeratorCount(); ++i) {
        bool ok = false;
        int v = mo->enumerator(i).keyToValue(key, &ok);
        if (ok) return v;
    }
    return def;
}
// ...and the same question asked of an OBJECT, which is the form that always has an answer. A bound
// class need not have a metatype at all -- nothing in the process ever instantiates a
// `QQuickAbstractAnimation*` -- but the object being assigned carries the whole chain in its own
// meta-object, and `Animation.Infinite` is by construction an enum of a class in that chain.
extern "C" int qtd_enum_value_on(void* o, const char* cxxType, const char* key, int def) {
    if (o && key) {
        const QMetaObject* mo = static_cast<QObject*>(o)->metaObject();
        for (int i = 0; mo && i < mo->enumeratorCount(); ++i) {
            bool ok = false;
            int v = mo->enumerator(i).keyToValue(key, &ok);
            if (ok) return v;
        }
    }
    return qtd_enum_value(cxxType, key, def);   // ...then the named class, for an unrelated enum
}
extern "C" void* qtd_platform_name() {
#ifdef QT_GUI_LIB
    return new QString(QGuiApplication::platformName());
#else
    return new QString();
#endif
}
extern "C" void* qtd_style_hints() {
#ifdef QT_GUI_LIB
    return QGuiApplication::styleHints();
#else
    return nullptr;
#endif
}
// `Qt.darker(c, f)` / `Qt.lighter(c, f)` — QML globals with no QObject behind them, so the meta
// channel cannot reach them: the engine implements both by calling QColor::darker/lighter with the
// factor as a PERCENTAGE (`qRound(f * 100)`), which is what this does. Colours travel through the
// compiled code as text (a colour read is a propStr, a colour write a setProp of a string that
// QMetaType converts), so the argument and the result are both strings and the result composes
// with everything else — including `Color.transparent(...)`, the singleton whose arguments these
// usually are. QVariant does the formatting, the same converter the dump uses, so a value produced
// here and one read back off a property are spelled identically.
#ifdef QT_GUI_LIB
static QString qtd_shade_of(const QColor& c, double factor, int lighter) {
    if (!c.isValid()) return QString();
    // A non-finite factor is what a JS expression yields when an operand is still undefined. Qt's
    // qRound ASSERTS on NaN (a hard abort, not a wrong colour), and QML's own conversion of a
    // non-finite number to an int gives 0 — which QColor documents as returning the colour
    // unchanged. Doing the same keeps the engine's outcome instead of killing the process.
    int pct = qIsFinite(factor) ? qRound(factor * 100.0) : 0;
    return qtd_var_text(QVariant::fromValue(lighter ? c.lighter(pct) : c.darker(pct)));
}
#endif
// The colour as its ARGB word: a DECLARED `property color` is a real QColor field on the D side,
// and this unit cannot name QColor (it is a binding type, and this file compiles into bindings
// that have no QtGui at all), so the scalar is what crosses.
// A colour's TEXT, spelled the way every other colour here is spelled (QVariant's converter, the
// one the dump uses). Needed because a colour is a value the meta channel carries as text: passing
// a QColor to an invokable is `#aarrggbb` on the wire, exactly like a colour property write.
// `Qt.alpha(c, a)` — the same colour at a new opacity, which is what the engine's own
// QQuickColorProvider::alpha does (`setAlphaF`). Fusion's Switch draws both of its gradient stops
// through it.
//
// Every helper below spells its result with qtd_var_text, for the reason written there: `#rrggbb`
// loses the 16 bits QColor holds, and a colour that crosses this channel as text is parsed back
// one step off. It showed as SIX full rows of a Fusion ToolBar's gradient rendering one grey
// brighter than the engine's, with both sides' stop colours comparing equal — because the
// comparison was reading the same truncated 8-bit spelling.
extern "C" void* qtd_color_alpha(const char* s, double a) {
#ifdef QT_GUI_LIB
#if QT_VERSION >= QT_VERSION_CHECK(6, 4, 0)
    QColor c = QColor::fromString(QString::fromUtf8(s));
#else
    QColor c; c.setNamedColor(QString::fromUtf8(s));
#endif
    if (!c.isValid()) return new QString();
    c.setAlphaF(qIsFinite(a) ? qBound(0.0, a, 1.0) : 1.0);
    return new QString(qtd_var_text(QVariant::fromValue(c)));
#else
    (void)s; (void)a;
    return new QString();
#endif
}
extern "C" void* qtd_color_alpha_rgba(unsigned rgba, double a) {
#ifdef QT_GUI_LIB
    QColor c = QColor::fromRgba(rgba);
    if (!c.isValid()) return new QString();
    c.setAlphaF(qIsFinite(a) ? qBound(0.0, a, 1.0) : 1.0);
    return new QString(qtd_var_text(QVariant::fromValue(c)));
#else
    (void)rgba; (void)a;
    return new QString();
#endif
}
extern "C" void* qtd_color_name(unsigned rgba) {
#ifdef QT_GUI_LIB
    return new QString(qtd_var_text(QVariant::fromValue(QColor::fromRgba(rgba))));
#else
    (void)rgba;
    return new QString();
#endif
}
extern "C" void* qtd_color_shade_rgba(unsigned rgba, double factor, int lighter) {
#ifdef QT_GUI_LIB
    return new QString(qtd_shade_of(QColor::fromRgba(rgba), factor, lighter));
#else
    (void)rgba; (void)factor; (void)lighter;
    return new QString();
#endif
}
extern "C" void* qtd_color_shade(const char* s, double factor, int lighter) {
#ifdef QT_GUI_LIB
    // QColor::fromString is Qt 6.4+; setNamedColor is the spelling both versions accept (Qt6
    // deprecates it, hence the version split rather than one call for both).
#if QT_VERSION >= QT_VERSION_CHECK(6, 4, 0)
    QColor c = QColor::fromString(QString::fromUtf8(s));
#else
    QColor c; c.setNamedColor(QString::fromUtf8(s));
#endif
    return new QString(qtd_shade_of(c, factor, lighter));
#else
    (void)s; (void)factor; (void)lighter;
    return new QString();
#endif
}
// Reads an ENUM property as its KEY — the same spelling the SETTER already takes, so a value
// read here compares against the key a `Qt.HighContrast` literal compiles to. QVariant::toString
// on an enum gives nothing useful; the key lives in the QMetaEnum, which the meta-object carries
// for every registered enum property. Non-enum properties fall back to the string form rather
// than reporting a failure the caller cannot act on.
extern "C" void* qtd_prop_get_enum_key(void* o, const char* n) {
    if (!o) return new QString();
    QObject* q = static_cast<QObject*>(o);
    const QMetaObject* mo = q->metaObject();
    int i = mo->indexOfProperty(n);
    if (i < 0) return new QString();
    QMetaProperty mp = mo->property(i);
    QVariant v = mp.read(q);
    if (!mp.isEnumType()) return new QString(v.toString());
    const char* k = mp.enumerator().valueToKey(v.toInt());
    return new QString(k ? QString::fromUtf8(k) : QString());
}
void* qtd_prop_get_qs(void* o, const char* n) { return new QString(o ? static_cast<QObject*>(o)->property(n).toString() : QString()); }
int qtd_prop_set_qs(void* o, const char* n, const char* p, int len) {
    // An EMPTY string is how this channel spells `undefined`: a read through an object that is
    // not assigned yet comes back empty. QML leaves a property alone when a binding evaluates to
    // undefined, so a non-string target takes no write rather than a failed conversion — which
    // would otherwise be reported as an error and abort a document whose only fault is that the
    // engine would have evaluated the binding later. A STRING target keeps taking it: "" is a
    // value there.
    if (len == 0 && o) {
        auto* obj = static_cast<QObject*>(o);
        int i = obj->metaObject()->indexOfProperty(n);
        if (i >= 0) {
            const char* tn = obj->metaObject()->property(i).typeName();
            if (tn && std::strcmp(tn, "QString") != 0) return 1;
        }
    }
    return qtd_prop_write(o, n, QString::fromUtf8(p, len));
}

// connects signal->slot by signature (works for custom AND built-in: both have a
// meta-object). Returns a QMetaObject::Connection* (or null if not found).
// Returns 1 on success, 0 if either side is null or a signature does not resolve. It used to
// return a heap-allocated QMetaObject::Connection that no caller ever freed or used; the
// connection is owned by the two QObjects anyway, so nothing is allocated now. The D side turns
// a 0 into a thrown error — a mistyped signature must not be a connection that silently never
// fires (qmltc-d emits hundreds of these).
int qtd_connect_meta(void* s, const char* sig, void* r, const char* slot) {
    if (!s || !r) return 0;
    auto* so = static_cast<QObject*>(s);
    auto* ro = static_cast<QObject*>(r);
    int si = so->metaObject()->indexOfSignal(QMetaObject::normalizedSignature(sig));
    int ri = ro->metaObject()->indexOfMethod(QMetaObject::normalizedSignature(slot));
    if (si < 0 || ri < 0) return 0;
    return QObject::connect(so, so->metaObject()->method(si),
                            ro, ro->metaObject()->method(ri)) ? 1 : 0;
}

// ---- QML type registration (qmlRegisterType for D @QObject types) -------------
// A D @QObject registered as a QML element instantiates the SAME C++ carrier
// (QtdMocObject), differentiated by its runtime QMetaObject. When QML creates
// `MyType {}`, QQmlPrivate calls qtd_qml_create with pre-allocated memory: we
// placement-new a QtdMocObject, wire its dynamic meta-object, and call back into
// D to create + bind the backing T instance (makeInstance). Verified viable by a
// standalone probe (runtime QMetaObject + shared typeId works for N distinct types).
#ifdef QTD_HAVE_QML
namespace {
struct QtdQmlType {
    const QMetaObject* mo;
    int nsig, nslot, nprop;
    QtdSlotCb slotcb; QtdPropCb propcb;
    void* (*makeInstance)(void*, void*);   // (self=QtdQmlType*, qobj) -> D backing object
    void  (*destroyInstance)(void*, void*); // (self, dobj) -> unregister on the D side
};
// Shared creation: placement-new the carrier in QML-owned memory, wire its meta-object, and
// call back into D to build + bind the backing T instance.
static void qtd_qml_construct(void* mem, QtdQmlType* t) {
    qtd_thread_guard("qml_construct");   // inserts g_moAttach (QML engine thread must be the owner)
    auto* o = new (mem) QtdMocObject();
    o->mo = t->mo; o->slotcb = t->slotcb; o->propcb = t->propcb;
    o->nsig = t->nsig; o->nslot = t->nslot; o->nprop = t->nprop;
    o->qmlUserdata = t;
    g_moAttach[o] = MocInfo{o->mo, nullptr, t->slotcb, t->propcb, t->nsig, t->nslot, t->nprop};
    void* dobj = t->makeInstance(t, o);   // D: new T, bind signals to `o`, register dispatch
    if (!dobj) {
        // The D constructor threw (the factory caught it, recorded it via qtdOnCallbackError, and
        // returned null). Qt's QML create() has no failure channel, so we can't unwind the
        // placement-new — but we MUST NOT hand back a carrier with a null backing object and a
        // stale side-table entry (critics r8 #5). Complete the cleanup: drop the half-attached
        // g_moAttach entry, leave dobj==null (qt_metacall is guarded to no-op on it), and emit a
        // visible error. The element degrades to an inert QObject; its bindings do nothing instead
        // of dispatching into null. qmlUserdata stays set so ~QtdMocObject takes the QML teardown.
        g_moAttach.erase(o);
        qWarning("qtd: QML instantiation of '%s' failed (D constructor threw); the element has no "
                 "backing object — its properties/slots are inert", t->mo->className());
        return;
    }
    o->dobj = dobj;
    g_moAttach[o].dobj = dobj;
}
// ~QtdMocObject for a QML-created instance: drop the side-tables (D side + g_moAttach).
static void qtd_qml_on_destroy(void* self) {
    qtd_thread_guard("qml_destroy");   // erases g_moAttach (+ D _reg via destroyInstance)
    auto* o = static_cast<QtdMocObject*>(self);
    auto* t = static_cast<QtdQmlType*>(o->qmlUserdata);
    g_moAttach.erase(self);
    if (t && o->dobj && t->destroyInstance) t->destroyInstance(t, o->dobj);
}
// A subclass of a BOUND type: the D factory placement-constructs its own C++ trampoline into the
// engine's memory and attaches its own meta-object, so there is nothing to do here but call it.
static void qtd_qml_construct_sub(void* mem, QtdQmlType* t) {
    qtd_thread_guard("qml_construct_sub");
    if (!t->makeInstance(t, mem))
        qWarning("qtd: QML instantiation of '%s' failed (D constructor threw)", t->mo->className());
}
#if QT_VERSION >= 0x060000
// Qt6: RegisterType.create carries userdata (the QtdQmlType*).
static void qtd_qml_create6(void* mem, void* udata) { qtd_qml_construct(mem, static_cast<QtdQmlType*>(udata)); }
static void qtd_qml_create_sub6(void* mem, void* udata) { qtd_qml_construct_sub(mem, static_cast<QtdQmlType*>(udata)); }
#else
// Qt5: RegisterType.create is `void(*)(void*)` with NO userdata field. Give each registered type
// its own create trampoline from a fixed pool, each hardwired (compile-time) to a slot that holds
// the QtdQmlType*. Caps registrable D QML types at the pool size — plenty for a real app.
// (extern "C++": this whole file is inside `extern "C"`, but templates need C++ linkage.)
extern "C++" {
static QtdQmlType* g_qt5Types[256];
static int g_qt5Count = 0;
template<size_t N> static void qt5_create(void* mem) { qtd_qml_construct(mem, g_qt5Types[N]); }
template<size_t... Is>
static std::array<void(*)(void*), sizeof...(Is)> mkCreators(std::integer_sequence<size_t, Is...>) {
    return {{ &qt5_create<Is>... }};
}
static const auto g_qt5Creators = mkCreators(std::make_index_sequence<256>());
// ...and a second pool for the subclass path, which constructs differently.
static QtdQmlType* g_qt5SubTypes[256];
static int g_qt5SubCount = 0;
template<size_t N> static void qt5_create_sub(void* mem) { qtd_qml_construct_sub(mem, g_qt5SubTypes[N]); }
template<size_t... Is>
static std::array<void(*)(void*), sizeof...(Is)> mkSubCreators(std::integer_sequence<size_t, Is...>) {
    return {{ &qt5_create_sub<Is>... }};
}
static const auto g_qt5SubCreators = mkSubCreators(std::make_index_sequence<256>());
}
#endif
} // namespace

// ...and the same registration for a D subclass of a BOUND type (`mixin QtdWidget!QQuickText`).
// Everything the engine needs about the C++ carrier comes from the shim, keyed by the bound class:
// how big the trampoline is, its base meta-object (so the created object METACASTS to the real
// type — without it a Repeater silently drops the delegate as "not an Item"), and whether it
// implements QQmlParserStatus (so classBegin/componentComplete run as they do for any QML object).
// The D factory placement-constructs into the engine's memory and does its own meta-object attach,
// so there is no QtdMocObject in this path at all.
void* qtd_qml_register_sub(
    const char* uri, int vmaj, int vmin, const char* qmlName,
    const char* cn, const char** sigs, int nsig, const char** slotSigs, int nslot,
    const char** propNames, const char** propTypes, const int* propNotify, int nprop,
    void* (*makeInstance)(void*, void*), void (*destroyInstance)(void*, void*),
    QtdSlotCb slotcb, QtdPropCb propcb,
    int objectSize, const void* superMo, int parserCast) {
    const QMetaObject* mo = buildMo(cn, static_cast<const QMetaObject*>(superMo),
        sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    auto* t = new QtdQmlType{mo, nsig, nslot, nprop, slotcb, propcb, makeInstance, destroyInstance};
    QQmlPrivate::RegisterType rt{};
    rt.objectSize = objectSize;
    rt.uri = uri;
    rt.elementName = qmlName;
    rt.metaObject = mo;
    rt.parserStatusCast = parserCast;
    rt.valueSourceCast = -1;
    rt.valueInterceptorCast = -1;
#if QT_VERSION >= 0x060000
    rt.structVersion = qtdRegisterTypeVersion<QQmlPrivate::RegisterType>();
    // NO metatype of our own, and NO list metatype. Registering `QObject*` as THIS type's id told
    // Qt that the QObject* metatype IS this type, and from then on every QQmlListReference over a
    // `data` list (whose element metatype is exactly that) resolved its element type to our last
    // registered delegate class and REFUSED every append — silently, because the generated code has
    // a parent-setting fallback. Measured on Qt's Fusion ComboBox: four appends failed and the
    // background came out with an empty `data`.
    // A metatype that is OURS and is not QObject*: registering `QObject*` as this type's id told Qt
    // that the QObject* metatype IS this type, and every QQmlListReference over a `data` list (whose
    // element metatype is exactly that) then resolved its element type to our last registered
    // delegate class and REFUSED every append — silently, because the generated code falls back to
    // parenting. Measured on Qt's Fusion ComboBox: four appends failed and the background came out
    // with an empty `data`. An INVALID metatype is not an option either: Qt's type loader
    // dereferences it and segfaults on the QQmlThread.
    rt.typeId = QMetaType::fromType<QtdMocObject*>();
    // NO list metatype. Registering `QQmlListProperty<QObject>` here told Qt that THAT metatype —
    // the one every `data` list uses — is a list of THIS type, so afterwards every
    // QQmlListReference on any object's `data` reported our last-registered delegate class as its
    // element type and refused to append anything else. Measured on Qt's Fusion ComboBox: the
    // background's child silently failed to append (`elem=ICB_delegate`) and the object came out
    // with an empty `data`. A registered type needs no list type of its own.
    rt.listId = QMetaType();
    rt.create = &qtd_qml_create_sub6;
    rt.userdata = t;
    rt.version = QTypeRevision::fromVersion(vmaj, vmin);
    rt.finalizerCast = -1;
    rt.revision = QTypeRevision::fromVersion(vmaj, vmin);
#else
    rt.version = 0;
    rt.typeId = int(QMetaType::QObjectStar);
    rt.listId = 0;
    if (g_qt5SubCount >= 256) {
        fprintf(stderr, "qtd: qmlRegisterType Qt5 create-pool exhausted (>256 D QML subclass types);"
                        " '%s' NOT registered\n", qmlName);
        delete t; return nullptr;
    }
    rt.create = g_qt5SubCreators[g_qt5SubCount];
    g_qt5SubTypes[g_qt5SubCount++] = t;
    rt.versionMajor = vmaj;
    rt.versionMinor = vmin;
    rt.revision = 0;
#endif
    int tid = QQmlPrivate::qmlregister(QQmlPrivate::TypeRegistration, &rt);
    if (tid < 0) {
        fprintf(stderr, "qtd: qmlRegisterType (subclass) failed for '%s' (qmlregister returned %d)\n",
                qmlName, tid);
#if QT_VERSION < 0x060000
        if (g_qt5SubCount > 0 && g_qt5SubTypes[g_qt5SubCount - 1] == t) g_qt5SubTypes[--g_qt5SubCount] = nullptr;
#endif
        delete t;
        return nullptr;
    }
    return t;
}

// Register a D @QObject type `cn` as the QML element `uri/qmlName vmaj.vmin`. Same
// sig/slot/prop arrays as qtd_moc_new. Returns the QtdQmlType* (the D side keys its
// per-type factory on it). All QString/QMetaType/QVariant handling stays in C++.
void* qtd_qml_register_type(
    const char* uri, int vmaj, int vmin, const char* qmlName,
    const char* cn, const char** sigs, int nsig, const char** slotSigs, int nslot,
    const char** propNames, const char** propTypes, const int* propNotify, int nprop,
    void* (*makeInstance)(void*, void*), void (*destroyInstance)(void*, void*),
    QtdSlotCb slotcb, QtdPropCb propcb) {
    const QMetaObject* mo = buildMo(cn, &QObject::staticMetaObject,
        sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    auto* t = new QtdQmlType{mo, nsig, nslot, nprop, slotcb, propcb, makeInstance, destroyInstance};
    QQmlPrivate::RegisterType rt{};
    rt.objectSize = int(sizeof(QtdMocObject));
    rt.uri = uri;
    rt.elementName = qmlName;
    rt.metaObject = mo;
    rt.parserStatusCast = -1;
    rt.valueSourceCast = -1;
    rt.valueInterceptorCast = -1;
#if QT_VERSION >= 0x060000
    rt.structVersion = qtdRegisterTypeVersion<QQmlPrivate::RegisterType>();
    rt.typeId = QMetaType::fromType<QtdMocObject*>();
    rt.listId = QMetaType::fromType<QQmlListProperty<QtdMocObject>>();
    rt.create = &qtd_qml_create6;   // userdata carries the QtdQmlType*
    rt.userdata = t;
    rt.version = QTypeRevision::fromVersion(vmaj, vmin);
    rt.finalizerCast = -1;
    rt.revision = QTypeRevision::fromVersion(vmaj, vmin);
#else
    rt.version = 0;   // Qt5 RegisterType struct version
    // Built-in QObject* metatype (id 39): every carrier is a QObject subclass, and QML keys the
    // element on the metaObject, not the metatype. Avoids qRegisterMetaType<QtdMocObject*>, which
    // in Qt5 pulls a sizeof(QWidget) probe (QtWidgets isn't included here).
    rt.typeId = int(QMetaType::QObjectStar);
    rt.listId = 0;
    if (g_qt5Count >= 256) {   // pool exhausted -> HONEST failure, not apparent success (critics r6 #6)
        fprintf(stderr, "qtd: qmlRegisterType Qt5 create-pool exhausted (>256 D QML types); '%s' NOT registered\n", qmlName);
        delete t; return nullptr;
    }
    rt.create = g_qt5Creators[g_qt5Count];   // per-type trampoline
    g_qt5Types[g_qt5Count++] = t;
    rt.versionMajor = vmaj;
    rt.versionMinor = vmin;
    rt.revision = 0;
#endif
    int tid = QQmlPrivate::qmlregister(QQmlPrivate::TypeRegistration, &rt);
    if (tid < 0) {   // the registration itself failed -> clean up, roll back, don't pretend it worked
        fprintf(stderr, "qtd: qmlRegisterType failed for '%s' (qmlregister returned %d)\n", qmlName, tid);
#if QT_VERSION < 0x060000
        if (g_qt5Count > 0 && g_qt5Types[g_qt5Count - 1] == t) g_qt5Types[--g_qt5Count] = nullptr;  // roll back the pool slot
#endif
        delete t;
        return nullptr;
    }
    return t;
}
#endif // QTD_HAVE_QML

} // extern "C"
