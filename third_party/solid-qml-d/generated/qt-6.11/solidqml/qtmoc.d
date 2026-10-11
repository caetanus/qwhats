// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// qtmoc — signals/slots for QObjects defined in D, WITHOUT moc: the meta-object is
// built at runtime (QMetaObjectBuilder, see qtdmoc.cpp) and, via
// CTFE + __traits, we generate the signatures, the signal emit and the slot
// dispatch. The user only marks the class with @QObject and the methods with @Slot:
//
//     @QObject class Counter {
//         Signal!int valueChanged;                                   // a signal
//         @Slot void setValue(int v) { ...; valueChanged.emit(v); }  // a slot
//     }
//
//     auto c = newQObject!Counter();                    // builds the meta-object
//     connectMeta(c, "valueChanged(int)", c, "onValue(int)");
//
// In D a UDA alone injects neither members nor a constructor — that's why the instance
// is born by the newQObject!T factory (which keeps the QObject's void* in an external
// registry, instead of a field inside the user's class).
//
// THREADING (critics r8 #6): this runtime is SINGLE-THREADED by design. The side-tables
// (_reg/_qmlFactories/_qmlRegistered here; g_moCache/g_moAttach in qtdmoc.cpp) are lock-free
// global mutable state. The restriction is not a silent assumption: the first
// construction/registration pins an "owner thread" into the C++ runtime, and creating/destroying/registering a
// @QObject from another thread ABORTS with a message (qtd_thread_guard) instead of corrupting a map.
// Create and destroy D @QObjects only on the thread that first used the runtime (typically the main one).
// Real support for worker QObjects (locking / per-thread tables) is a structural follow-up.
//
// ...AND ON ANDROID THE RULE IS WIDER THAN THIS RUNTIME, in a way nothing here can enforce. Qt's own
// documentation calls QImage and QImageReader REENTRANT — decoding in a worker thread is a normal Qt
// pattern, and on a desktop it is — but on an Adreno device it destroys the EGL surface. Measured on
// a Samsung with a real application (2026-09-16): worker threads decoding 3186 thumbnails left the
// window BLACK while the program stayed fully alive inside — its own watchdog kept logging, the
// model was populated, the QML engine reported no error at all — and the logcat showed
// `onWindowVisibilityChanged(8)=GONE` -> `surfaceDestroyed` -> "Skipping create egl on invalid or
// not yet created surface". The same code on an x86-64 emulator with the same .so rendered
// perfectly. Moving the decode onto the Qt thread, in slices that yield to the event loop, fixed it
// with the same work and the same memory.
//
// Two things it is NOT, both ruled out by measurement rather than by argument, because each would
// have implied a different fix:
//   * not memory pressure — the same decoding load on the Qt thread survives;
//   * not this runtime's side-tables — the C++ wrapper registry is mutex-protected
//     (qtd_holder.cpp), and the meta-object runtime ABORTS off its owner thread rather than
//     corrupting anything, so it would have said so;
//   * and not the D GC's stop-the-world, which cannot reach the render thread at all: the GC
//     suspends the threads the D runtime KNOWS, and Qt's Scene Graph render thread is created by
//     C++ and never registered. Heavy D allocation in a worker (1.3 MB of JSON, collections
//     throughout) coexists with a live render; it was measured alongside the fix.
//
// So: on Android, keep Qt image objects on the Qt thread even where Qt says they are reentrant. The
// failure has no error message, which is what makes it worth a paragraph.
module qtmoc;

import std.traits : Parameters, hasUDA, getUDAs, ReturnType;
import std.meta : AliasSeq, Filter, staticMap;

// ---- runtime C++ (qtdmoc.cpp) -----------------------------------------------
alias SlotCb = extern (C) void function(void*, int, void**) nothrow;
alias PropCb = extern (C) void function(void*, int, int, void**) nothrow;
extern (C) nothrow {
    void* qtd_moc_new(const(char)*, const(char)**, int, const(char)**, int,
                      const(char)**, const(char)**, const(int)*, int, void*, SlotCb, PropCb);
    // Register a D @QObject type as a QML element (only linked in for QtQml bindings).
    alias MakeCb = extern (C) void* function(void*, void*) nothrow;
    alias DestroyCb = extern (C) void function(void*, void*) nothrow;
    void* qtd_qml_register_type(const(char)*, int, int, const(char)*,
                      const(char)*, const(char)**, int, const(char)**, int,
                      const(char)**, const(char)**, const(int)*, int,
                      MakeCb, DestroyCb, SlotCb, PropCb);
    // ...and the same for a D subclass of a BOUND type: three extra facts about the C++ carrier
    // (trampoline size, the base's meta-object, the QQmlParserStatus offset), which the shim
    // publishes per bound class. See qmlRegisterType.
    void* qtd_qml_register_sub(const(char)*, int, int, const(char)*,
                      const(char)*, const(char)**, int, const(char)**, int,
                      const(char)**, const(char)**, const(int)*, int,
                      MakeCb, DestroyCb, SlotCb, PropCb, int, const(void)*, int);
    void  qtd_moc_activate(void*, int, void**);
    int qtd_connect_meta(void*, const(char)*, void*, const(char)*);
    int    qtd_vgroup_get_int(void*, const(char)*, const(char)*);
    bool   qtd_vgroup_get_bool(void*, const(char)*, const(char)*);
    double qtd_vgroup_get_double(void*, const(char)*, const(char)*);
    void*  qtd_vgroup_get_qs(void*, const(char)*, const(char)*);
    void qtd_attach_context(void*);
    void qtd_attach_context_url(void*, const(char)*);
    void qtd_ensure_module(const char*);
    int qtd_list_append(void*, const char*, void*);
    int qtd_bind_leaf(void*, const char*, const char*, void*, const char*);
    int qtd_connect_notify(void*, const char*, void*, const char*);
void qtd_parser_status(void*, int);
    int qtd_prop_set_var(void*, const(char)*, const(char)*, const(void)*);
    int qtd_prop_get_var(void*, const(char)*, const(char)*, void*);
    int qtd_vgroup_set_int(void*, const(char)*, const(char)*, int);
    int qtd_vgroup_set_bool(void*, const(char)*, const(char)*, bool);
    int qtd_vgroup_set_double(void*, const(char)*, const(char)*, double);
    int qtd_vgroup_set_qs(void*, const(char)*, const(char)*, const(char)*, int);
    void* qtd_metacast(void*, const(char)*);   // QObject::qt_metacast(n) on a qobj — for the identity test
    const(char)* qtd_moc_classname(void*);     // metaObject()->className() of the qobj
    int  qtd_moc_owner_check();                // 1=owner thread, 0=other thread, -1=no owner (r8 #6)
    // QString marshaling (implemented in qtdmoc.cpp, which links QtCore)
    void* qtd_str_to_qs(const(char)*, int);
    void  qtd_qs_free(void*);
    void* qtd_color_shade(const(char)*, double, int);       // Qt.darker / Qt.lighter -> QString*
    void* qtd_color_shade_rgba(uint, double, int);          // ...from a QColor's ARGB word
    void* qtd_color_name(uint);                             // a QColor's `#aarrggbb` spelling
    void* qtd_platform_name();                              // Qt.platform.pluginName -> QString*
    int   qtd_enum_value(const(char)*, const(char)*, int);  // enum KEY -> number, via QMetaEnum
    int   qtd_enum_value_on(void*, const(char)*, const(char)*, int);  // ...asked of the object
    void* qtd_color_alpha(const(char)*, double);            // Qt.alpha -> QString*
    void* qtd_color_alpha_rgba(uint, double);               // ...from a QColor's ARGB word
    void* qtd_tr(const(char)*, const(char)*, const(char)*, int);   // QCoreApplication::translate
    bool  qtd_install_translator(const(char)*);                    // new QTranslator + install (C++)
    void  qtd_qs_set(void*, const(char)*, int);   // assign a D string into an existing QString
    int   qtd_qs_utf8len(void*);
    void  qtd_qs_utf8(void*, char*);
    // property access by name (via QVariant)
    int    qtd_prop_get_int(void*, const(char)*);
    int    qtd_prop_set_int(void*, const(char)*, int);
    double qtd_prop_get_double(void*, const(char)*);
    int    qtd_prop_set_double(void*, const(char)*, double);
    bool   qtd_prop_get_bool(void*, const(char)*);
    int    qtd_prop_set_bool(void*, const(char)*, bool);
    void* qtd_prop_get_qs(void*, const(char)*);
void* qtd_style_hints();
void* qtd_list_at(void*, const(char)*, int);
void* qtd_qml_singleton(const(char)*, const(char)*, int, int);
void* qtd_invoke_str(void*, const(char)*, const(char)**, int);
void* qtd_prop_get_enum_key(void*, const(char)*);
    int    qtd_prop_set_qs(void*, const(char)*, const(char)*, int);
}

// ---- callback error policy (round-4 #6: silence is not acceptable) ----------
// A slot/property/signal callback invoked BY Qt must be `nothrow` — a D exception can't
// unwind across the C++ frame. Instead of swallowing it, record it: a thread-local last
// error + count (inspectable/testable), an optional global hook, and a debug stderr note.
// (Errors — asserts, etc. — are bugs and are intentionally NOT caught here: they terminate.)
__gshared void function(Throwable) nothrow qtdCallbackErrorHook;   // opt-in global sink
size_t qtdCallbackErrors;          // thread-local (module scope) — count for asserts/tests
Throwable qtdLastCallbackError;    // thread-local — the most recent swallowed exception
void qtdOnCallbackError(Throwable e) nothrow {
    qtdCallbackErrors++;
    qtdLastCallbackError = e;
    if (qtdCallbackErrorHook !is null) qtdCallbackErrorHook(e);
    debug {
        import core.stdc.stdio : fprintf, stderr;
        fprintf(stderr, "qtd: callback threw (swallowed at C++ boundary): %.*s\n",
            cast(int) e.msg.length, e.msg.ptr);
    }
}

// converts a QString* (meta-call arg) into a D string.
string qsToD(void* qs) {
    // A NULL QString IS THE EMPTY STRING, not a crash. Every C++ helper on this boundary hands over
    // an OWNED `new QString`, and D reads it and frees it — 33 return sites against 17 read sites,
    // and the ownership travels in a comment rather than in the type. The first stub attempt got it
    // wrong in exactly the way that shape invites (critics r14 #1): it inferred "returns a pointer"
    // and produced nullptr, where the real body always returns an empty QString. That specific bug
    // is gone — the stubs are the same source compiled without QML now — but the CLASS is not, and
    // one branch here closes it for all 33.
    //
    // The right fix is the one this makes cheap to defer and not cheap to forget: hand over a VALUE
    // (length + utf8 into a caller buffer) instead of an owned pointer, so the boundary stops having
    // an ownership convention at all. That is 33 C++ sites and 17 D sites, and it is the design this
    // helper should eventually make unnecessary.
    if (qs is null) return "";
    int n = qtd_qs_utf8len(qs);
    auto buf = new char[n];
    if (n) qtd_qs_utf8(qs, buf.ptr);
    return cast(string) buf[0 .. n];
}

// ---- translation (tr / translate / install) ---------------------------------
private string trImpl(string context, string source, string disambig, int n) {
    auto qs = qtd_tr((context ~ "\0").ptr, (source ~ "\0").ptr,
                     disambig is null ? null : (disambig ~ "\0").ptr, n);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}

/// `tr` FREE and UFCS — `"foo".tr`, `"foo".tr("disambiguation")`. The CONTEXT is the NAME of the
/// caller's module (via `__MODULE__`, which is resolved at the call site) — matching exactly what
/// lupdate-d extracts, so the same `.qm` covers extraction and runtime. With no translator/`.qm` covering the
/// string, Qt returns `source`, so it is always safe. For an explicit context use `translate`.
string tr(string source, string disambiguation = null, int n = -1, string context = __MODULE__) {
    return trImpl(context, source, disambiguation, n);
}

/// `translate` Qt-style: EXPLICIT context. `translate("Context", "foo")` — same as what
/// lupdate-d recognizes as `[QCoreApplication.]translate("Ctx","src")`.
string translate(string context, string source, string disambiguation = null, int n = -1) {
    return trImpl(context, source, disambiguation, n);
}

/// Installs a translator WITHOUT `_new`: `QTranslator.install("app_pt")`. The QTranslator (and a
/// QCoreApplication, if there isn't one yet) are built on the C++ side — the user never
/// builds anything by hand. Empty `.qm` -> empty translator (identity). Returns whether the `.qm` loaded.
struct QTranslator {
    static bool install(string qm = "") { return qtd_install_translator((qm ~ "\0").ptr); }
}

/// Class UDA: marks a D QObject with a runtime meta-object (signals/slots).
struct QObject {}
/// Method UDA: slot (invokable by Qt / connectable to a signal).
struct Slot {}
/// A method the meta-object exposes that RETURNS something. Qt calls this an invokable and draws
/// the line exactly there: a slot returns void, and QMetaObject::invokeMethod with Q_RETURN_ARG
/// only works on a method declared with a return type. A QML function that returns a value has no
/// other way to be callable from the engine — emitted as a plain D method it is invisible, and the
/// engine answers `Property 'visibleIndex' of object … is not a function` about a function the
/// document declares.
struct Invokable {}
/// A VALUE THAT CROSSES WITHOUT BEING INTERPRETED. Qt hands a metacall a `QVariant*` for an
/// untyped argument; this carries that pointer and nothing else, so a method can take one, pass it
/// on, and never decide what it is. It exists for QML functions whose parameters have no type
/// annotation — the compiler refuses to guess one, and guessing is how `f(x, y) { return x + y }`
/// becomes numeric addition and starts being wrong the moment it is called with strings.
struct QmlVarRef { void* p; }
/// Field UDA: exposes the field as a Q_PROPERTY. `notify` = name of the change
/// signal (optional), e.g. @Property("valueChanged") int value;
///
/// `name` publishes the property under a name of its own, when the FIELD cannot carry it: QML has
/// no reserved words in common with D, so a document is free to declare `property string ref` or
/// `property int align`, and the D field holding one has to be spelled otherwise. Without this the
/// generated code had a choice between not compiling and publishing a name Qt would not find, and
/// took the third option — dropping the property, which is how `required property string ref`
/// became a delegate row that read back nothing.
struct Property { string notify = ""; string name = ""; }
/// The D placeholder for a declared QML list property. It stores nothing: the elements live in the
/// runtime, behind the QQmlListProperty the meta-object hands out — which is also what the
/// `listAppend` the generated code already emits writes into.
struct QmlObjectList {}
/// A QML `property var`: the meta-object carries it as a QVariant and the RUNTIME owns the value
/// (see qtd_moc_var_read). Nothing is stored on the D side, which is deliberate — QVariant is bound
/// as opaque storage with a destructor and no copy constructor, so a D field of it double-frees.
struct QmlVar {}
/// The engine-built instance a wrapper holds, or null when the wrapper itself is not there yet.
/// A binding of the ENCLOSING object can run before its children are constructed — the root's
/// `implicitWidth` reads `placeholder.implicitWidth` while `_dc0` is still null — and reading the
/// field off a null reference segfaults where every other read in this compiler answers a default.
void* instOf(T)(T o) {
    static if (__traits(hasMember, T, "__inst")) return o is null ? null : o.__inst;
    else return qobjOf(o);
}
/// A property that FORWARDS instead of storing. A QML `property alias inner: kid.value` is a
/// REFERENCE: nothing is kept, reads go straight to the target and writes land on it — which is
/// what an alias means and why a field would be wrong (a copy can drift). qtmoc discovers ordinary
/// properties over FIELDS, so a forwarding one needs its own marker: put it on the GETTER, and the
/// setter is the same name with `_set`. The engine has these in its meta-object; without them the
/// full property dump showed `inner` on its side and no such key on ours.
struct PropertyAlias { string name; string notify = ""; }

/// A signal with the given argument types. Emitting calls QMetaObject::activate.
struct Signal(Args...) {
    private void* _owner;   // the owning QObject (qtd)
    private int   _idx;     // the signal's local index in the meta-object
    void _bind(void* owner, int idx) { _owner = owner; _idx = idx; }
    void emit(Args args) {
        void*[Args.length + 1] argv;
        void*[Args.length + 1] tofree = null;             // QStrings to free afterwards
        argv[0] = null;                                   // return slot (void)
        static foreach (i; 0 .. Args.length) {
            static if (is(Args[i] == string)) {
                argv[i + 1] = qtd_str_to_qs(args[i].ptr, cast(int) args[i].length);
                tofree[i + 1] = argv[i + 1];
            } else argv[i + 1] = cast(void*) &args[i];
        }
        qtd_moc_activate(_owner, _idx, argv.ptr);
        static foreach (i; 1 .. Args.length + 1)
            if (tofree[i]) qtd_qs_free(tofree[i]);
    }
    void opCall(Args args) { emit(args); }
}

// ---- per-object registry (avoids injecting members into the user class) -----
struct MocReg {
    void* qobj;                                    // the underlying QObject
    void delegate(int, void**) nothrow disp;       // slot dispatch (captures the object)
    void delegate(int, int, void**) nothrow prop;  // property read/write
}
__gshared MocReg[void*] _reg;              // key = the D object's pointer
// ...and the same table the OTHER way round, which the forward one cannot answer: given a QObject*
// that crossed the meta channel, which D object owns it. A property whose type is a BOUND wrapper
// is rebuilt from the pointer with `X.wrap`; a D-defined @QObject has no such constructor and there
// is only ever ONE D object per QtdMocObject, so the answer is a lookup, not a construction.
// Both entries are made together and dropped together (see __mocGlobalDestroy). Stored as a raw
// pointer, not an Object: an entry here must not keep the D object alive — `_reg` is not a GC root
// either, and making this one would silently change every compiled object's lifetime.
__gshared void*[void*] _byQObj;            // key = the QObject*, value = the D object's pointer

extern (C) void __mocGlobalDispatch(void* dobj, int idx, void** args) nothrow {
    if (auto p = dobj in _reg) p.disp(idx, args);
}
extern (C) void __mocGlobalProp(void* dobj, int idx, int write, void** args) nothrow {
    if (auto p = dobj in _reg) p.prop(idx, write, args);
}
// Called by the QtdMocObject destructor (C++) -> drops the `_reg` entry, closing the
// side-table when the object dies (not only on the QML path). Registered once at init.
// `destroyed` also fires during process shutdown, from posted deleteLater events, when the D
// runtime may already be going down — touching the GC then crashes. holder.d guards exactly this
// case with `_live`; this callback is reached from the same window and needs the same guard.
private __gshared bool _regLive = true;
shared static ~this() { _regLive = false; }
extern (C) void __mocGlobalDestroy(void* dobj) nothrow {
    if (!_regLive) return;
    if (auto p = dobj in _reg) _byQObj.remove(p.qobj);
    _reg.remove(dobj);
}

/// How many D @QObjects are currently registered. A test can assert this returns to its baseline
/// after a compiled object tree is destroyed — i.e. that nesting does not leak.
size_t mocRegisteredCount() { return _reg.length; }
private alias MocDestroyCb = extern (C) void function(void*) nothrow;
extern (C) void qtd_moc_set_destroy_cb(MocDestroyCb) nothrow;
shared static this() { qtd_moc_set_destroy_cb(&__mocGlobalDestroy); }

// Side-table lifetime (_reg + g_moAttach): an object created by `newQObject!T` keeps its
// `_reg` entry as long as the C++ QtdMocObject exists. If it is destroyed (parented to a
// QObject whose parent dies, or created by the QML engine), the destructor clears BOTH side-tables via
// this callback. A parentless QtdMocObject is NOT auto-deleted (it lives until process end) — that is the
// expected lifetime of a top-level signals/slots hub, just like a parentless C++ QObject.

/// Pointer to the underlying QObject: a raw void* passes straight through; a D @QObject is
/// resolved via the registry (null if not registered).
void* qobjOf(T)(T o) {
    static if (is(T == void*)) return o;
    else {
        // A null reference has no object to ask, and ptr() would call through it. A compiled
        // document reads exactly this: `control.palette` where `control` is a declared object
        // property nobody has assigned yet — QML gives undefined there, and null is how that
        // travels here. (Measured: Qt's Fusion Button, DelayButton and ToolButton segfaulted in
        // checkAlive the moment such a read compiled.)
        static if (__traits(compiles, o is null)) if (o is null) return null;
        if (auto p = cast(void*) o in _reg) return p.qobj;
        // A WRAPPER-mode bound object is not in `_reg` — that registry holds D-DEFINED @QObject
        // instances — and its address is the wrapper's, not the C++ object's. The C++ object is
        // behind ptr(). Without this every qobjOf() on a bound object returned null and connectMeta
        // reported "a null endpoint" for a perfectly valid QSlider.
        static if (__traits(hasMember, T, "ptr")) return o.ptr();
        else return null;
    }
}

/// The D object that owns a QObject*, or null. The reverse of [qobjOf], and the only way to give a
/// class-typed property a D-defined @QObject: `X.wrap(ptr)` exists on a bound wrapper and nowhere
/// else. Returns it as `Object` so the caller's `cast(X)` does the type check.
Object dObjectFor(void* qobj) {
    if (!qobj) return null;
    if (auto p = qobj in _byQObj) return cast(Object) *p;
    return null;
}

/// qt_metacast by name on the underlying QObject. Returns the QObject pointer if `n`
/// matches its own class (or a base), null otherwise — the same contract as
/// qobject_cast. Exists to prove the metaobject doesn't lie about the object (critics r8 #2).
void* metaCast(T)(T o, string n) {
    return qtd_metacast(qobjOf(o), (n ~ "\0").ptr);
}

/// metaObject()->className() of the underlying QObject (to test type identity).
string mocClassName(T)(T o) {
    import core.stdc.string : strlen;
    auto p = qtd_moc_classname(qobjOf(o));
    return p is null ? null : cast(string) p[0 .. strlen(p)].idup;
}

// ---- CTFE: D type -> C++ signature mapping ----------------------------------
template cppSig(T) {
         static if (is(T == int))    enum cppSig = "int";
    else static if (is(T == bool))   enum cppSig = "bool";
    else static if (is(T == double)) enum cppSig = "double";
    else static if (is(T == float))  enum cppSig = "float";
    else static if (is(T == uint))   enum cppSig = "uint";
    else static if (is(T == string)) enum cppSig = "QString";
    // Anything else the binding exposes as a value type: the meta-object records the property by
    // TYPE NAME and Qt resolves it through QMetaType::fromName, so a bound struct whose D name
    // matches its C++ one (QColor, QSize, QRectF, …) needs nothing special here. The marshalling
    // below is a plain copy, which is what a trivially-copyable value type wants.
    // A declared `property list<QtObject>`: the meta-object carries it as a QQmlListProperty and the
    // runtime owns the elements, so the D side needs no storage — only a name the moc can key on.
    else static if (is(T == QmlObjectList)) enum cppSig = "QQmlListProperty<QObject>";
    else static if (is(T == QmlVar)) enum cppSig = "QVariant";
    else static if (is(T == QmlVarRef)) enum cppSig = "QVariant";
    else static if (is(T == struct)) enum cppSig = T.stringof;
    // A bound wrapper CLASS is an object: the meta-object records the property as `X*` and Qt
    // resolves it through QMetaType::fromName, exactly as it does for the value types above. This is
    // what a QML `property Item control` needs — the property has to EXIST for whoever instantiates
    // the type to write it, and dropping it made those writes throw at construction.
    else static if (is(T == class)) enum cppSig = T.stringof ~ "*";
    // A `void*` in this position is an object the ENGINE built. A compiled QML type whose Qt type
    // exports no symbol cannot be subclassed, so the generated class holds the instance as an
    // untyped pointer (`void* __inst`) — and `property alias body: someEngineChild` publishes that
    // pointer. The engine's own meta-object records such a property as QObject*, which is also the
    // only thing Qt can be told about it, and the pointer crosses in exactly the same slot.
    else static if (is(T == void*)) enum cppSig = "QObject*";
    else static assert(0, "qtmoc: signal/slot type not yet supported: " ~ T.stringof);
}
string sigString(string name, Args...)() {
    string s = name ~ "(";
    static foreach (i, A; Args) s ~= (i ? "," : "") ~ cppSig!A;
    return s ~ ")";
}

// names of signals (Signal!... fields) and slots (@Slot), in allMembers order.
template signalMembers(T) {
    template isSig(string m) {
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...)) enum isSig = true;
        else enum isSig = false;
    }
    enum signalMembers = mocFilter!(T, isSig);
}
// Slots are keyed by FUNCTION SYMBOL, not by name, because Qt supports overloaded slots:
// `toggle()`, `toggle(int)` and `toggle(bool)` are three distinct entries in a meta-object,
// told apart by their full signature — moc emits all three. Keying by name would collapse
// them into one, so each overload gets its own entry here too.
// SLOTS AND INVOKABLES SHARE ONE INDEX SPACE, which is what lets the whole dispatch stay as it
// was: the metacall already hands `a` to the slot callback, and `a[0]` is the return slot every
// Qt method carries and a slot simply ignores.
template slotSymbols(T) {
    enum isSlotSym(alias f) = hasUDA!(f, Slot) || hasUDA!(f, Invokable);
    template ovlsOf(string m) {
        static if (m.length && __traits(compiles, __traits(getOverloads, T, m)))
            alias ovlsOf = Filter!(isSlotSym, __traits(getOverloads, T, m));
        else
            alias ovlsOf = AliasSeq!();
    }
    alias slotSymbols = staticMap!(ovlsOf, __traits(allMembers, T));
}
string[] mocFilter(T, alias pred)() {
    string[] r;
    static foreach (m; __traits(allMembers, T))
        static if (m.length && pred!m) r ~= m;
    return r;
}

// signatures ("name(types)") of signals/slots.
string[] signalSigs(T)() {
    string[] r;
    static foreach (m; signalMembers!T) {{   // {{ }} => per-iteration scope (A...)
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...))
            r ~= sigString!(m, A);
    }}
    return r;
}
string[] slotSigs(T)() {
    import std.traits : ReturnType;
    string[] r;
    static foreach (f; slotSymbols!T) {{
        auto sig = sigString!(__traits(identifier, f), Parameters!f);
        // `->` and the C++ spelling of the return, for an invokable. The separator cannot occur in
        // a signature the other branch produces, so buildMo tells the two apart without another
        // array and without touching any of its four callers.
        static if (!is(ReturnType!f == void)) sig ~= "->" ~ cppSig!(ReturnType!f);
        r ~= sig;
    }}
    return r;
}

// fields marked with @Property.
template propMembers(T) {
    template isProp(string m) {
        static if (is(typeof(__traits(getMember, T, m)) == function)) enum isProp = false;
        else enum isProp = hasUDA!(__traits(getMember, T, m), Property);
    }
    enum propMembers = mocFilter!(T, isProp);
}
// ---- forwarding properties (@PropertyAlias) ---------------------------------
// The GETTERS, in allMembers order. A setter is found by name (`<getter>_set`) rather than by an
// overload, so `__traits(getMember)` never has to re-resolve an overload set from argument types.
template aliasPropMembers(T) {
    template isAliasProp(string m) {
        // The FIRST overload, named explicitly: asking an overload set for its attributes is
        // deprecated, and a subclass of a bound type has overload sets it never wrote
        // (dataChanged/createIndex, mixed in by QtdWidget). The first overload is what the
        // attribute query answered for before, and what aliasPropNames/Types/Notify and
        // callPropAlias read — detecting the UDA on any OTHER overload would register a property
        // whose metadata comes from a different function.
        static if (is(typeof(__traits(getMember, T, m)) == function))
            enum isAliasProp = hasUDA!(__traits(getOverloads, T, m)[0], PropertyAlias);
        else enum isAliasProp = false;
    }
    enum aliasPropMembers = mocFilter!(T, isAliasProp);
}
string[] aliasPropNames(T)() {
    string[] r;
    static foreach (m; aliasPropMembers!T) r ~= getUDAs!(__traits(getMember, T, m), PropertyAlias)[0].name;
    return r;
}
string[] aliasPropTypes(T)() {
    string[] r;
    static foreach (m; aliasPropMembers!T) r ~= cppSig!(ReturnType!(__traits(getMember, T, m)));
    return r;
}
int[] aliasPropNotify(T)() {
    int[] r;
    static foreach (m; aliasPropMembers!T) {{
        enum note = getUDAs!(__traits(getMember, T, m), PropertyAlias)[0].notify;
        int idx = -1, i = 0;
        static foreach (s; signalMembers!T) { if (s == note) idx = i; i++; }
        r ~= idx;
    }}
    return r;
}
// Read/write a forwarding property: the getter and `<getter>_set` do the forwarding, so this only
// marshals, exactly as callProp does for a stored one.
void callPropAlias(T, string m)(T o, void* qobj, int notifyIdx, int write, void** a) {
    alias X = ReturnType!(__traits(getMember, T, m));
    if (write) {
        // An OBJECT target crosses as a POINTER, exactly as a stored object property does: a bound
        // wrapper is rebuilt with X.wrap, a D-defined @QObject is looked up. `default property alias
        // child: self.someObject` is this case — the engine holds the bare child through the alias.
        static if (is(X == class)) {
            auto pv = *cast(void**) a[0];
            static if (__traits(hasMember, X, "wrap"))
                X nv = pv is null ? null : X.wrap(pv);
            else
                X nv = pv is null ? null : cast(X) dObjectFor(pv);
        }
        else static if (is(X == string)) X nv = qsToD(a[0]);
        else                             X nv = *cast(X*) a[0];
        __traits(getMember, o, m ~ "_set")(nv);
        if (notifyIdx >= 0) {
            void*[2] argv; argv[0] = null;
            static if (is(X == string)) {
                auto qs = qtd_str_to_qs(nv.ptr, cast(int) nv.length);
                argv[1] = qs; qtd_moc_activate(qobj, notifyIdx, argv.ptr); qtd_qs_free(qs);
            } else static if (is(X == class)) {
                auto pv2 = nv is null ? null : qobjOf(nv);
                argv[1] = cast(void*) &pv2; qtd_moc_activate(qobj, notifyIdx, argv.ptr);
            } else { argv[1] = cast(void*) &nv; qtd_moc_activate(qobj, notifyIdx, argv.ptr); }
        }
    } else {
        auto cur = __traits(getMember, o, m)();
        static if (is(X == class)) *cast(void**) a[0] = cur is null ? null : qobjOf(cur);
        else static if (is(X == string)) qtd_qs_set(a[0], cur.ptr, cast(int) cur.length);
        else                             *cast(X*) a[0] = cur;
    }
}

string[] propTypes(T)() {
    string[] r;
    static foreach (m; propMembers!T) r ~= cppSig!(typeof(__traits(getMember, T, m)));
    return r;
}
// name of the notify signal of a @Property (tolerates @Property without parentheses).
template propNote(alias sym) {
    private alias U = getUDAs!(sym, Property);
    static if (is(U[0])) enum propNote = "";          // @Property (type) -> no notify
    else                 enum propNote = U[0].notify;  // @Property()/@Property("x")
}
// The name Qt publishes: the UDA's when it carries one, the FIELD's otherwise.
template propPub(alias sym, string member) {
    private alias U = getUDAs!(sym, Property);
    static if (is(U[0])) enum propPub = member;
    else static if (U[0].name.length) enum propPub = U[0].name;
    else enum propPub = member;
}
string[] propPubNames(T)() {
    string[] r;
    static foreach (m; propMembers!T) r ~= propPub!(__traits(getMember, T, m), m);
    return r;
}
// index (in signalMembers order) of each property's notify signal, or -1.
int[] propNotify(T)() {
    int[] r;
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        int idx = -1, i = 0;
        static foreach (s; signalMembers!T) { if (s == note) idx = i; i++; }
        r ~= idx;
    }}
    return r;
}

// ---- meta-method contract (critics r8 #4) -----------------------------------
// The metaobject cannot accept a declaration whose semantics it does not honor:
//   * a Qt @Slot returns void. A method that returns a value is an INVOKABLE — the
//     runtime does not marshal the return (it was silently discarded, and
//     QMetaObject::invokeMethod with Q_RETURN_ARG returned false). Reject it.
//   * a @Property("notifySig") whose NOTIFY does not name a Signal of this class
//     silently resolved to index -1 (no notification ever fires).
//     And if it names a Signal, the signature must match what callProp emits
//     (0 args, or 1 arg of the property's type) — otherwise the receiving slot reads garbage.
// All at compile time, with a message pointing to the fix. It is a function (statement
// scope) instantiated by a call at the top of each registration path — the
// instantiation fires the static asserts; at runtime it is a no-op (optimized away).
void validateMeta(T)() {
    import std.traits : ReturnType;
    static foreach (f; slotSymbols!T)
        static assert(is(ReturnType!f == void) || hasUDA!(f, Invokable),
            "qtmoc: @Slot " ~ T.stringof ~ "." ~ __traits(identifier, f) ~ " must return void. " ~
            "A method that returns a value is an invokable: mark it @Invokable, which declares " ~
            "the return type to the meta-object and marshals it back.");
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        static if (note.length) {
            alias PT = typeof(__traits(getMember, T, m));
            enum bool found = () {
                bool f = false;
                static foreach (s; signalMembers!T) if (s == note) f = true;
                return f;
            }();
            static assert(found,
                "qtmoc: @Property " ~ T.stringof ~ "." ~ m ~ " has NOTIFY \"" ~ note ~
                "\" which is not a Signal of this class.");
            static foreach (s; signalMembers!T)
                static if (s == note)
                    static if (is(typeof(__traits(getMember, T, s)) == Signal!A, A...))
                        static assert(A.length == 0 || (A.length == 1 && is(A[0] == PT)),
                            "qtmoc: NOTIFY \"" ~ note ~ "\" of " ~ T.stringof ~ "." ~ m ~
                            " must be parameterless or take a single " ~ PT.stringof ~
                            " (callProp emits the new value as the sole argument).");
        }
    }}
}

// reads/writes property `m` of `o` via the value slot a[0]. On write, if the
// value changes and there is a notify signal, emits it (so bindings/QML see the change).
void callProp(T, string m)(T o, void* qobj, int notifyIdx, int write, void** a) {
    alias X = typeof(__traits(getMember, T, m));
    if (write) {
        // A list property is never WRITTEN through this channel: QML appends through the
        // QQmlListProperty the read hands out, which is what `listAppend` does.
        static if (is(X == QmlObjectList)) { return; }
        // ...and NOTIFY, which this branch returned without emitting while every other type below
        // emits. A `var` whose value the runtime owns is still a property, and QML's capture arms
        // on the notify: Qt's Material SliderHandle writes `readonly property var control: parent`
        // in the late phase, and the delegated `root.control ? … : "transparent"` had already run
        // once against an empty slot, so the handle stayed transparent for good.
        else static if (is(X == QmlVar)) {
            qtd_moc_var_write(qobjOf(o), (m ~ "\0").ptr, a[0]);
            if (notifyIdx >= 0) { void*[2] argv; argv[0] = null; argv[1] = a[0];
                                  qtd_moc_activate(qobj, notifyIdx, argv.ptr); }
            return;
        }
        else {
        // An OBJECT property carries a POINTER in the slot, and the D side holds a wrapper: unwrap
        // on write, hand the C++ pointer back on read. Comparing wrappers with `!=` would compare
        // by value; identity is what QML assigns and what a notify must be based on.
        static if (is(X == class)) {
            auto pv = *cast(void**) a[0];
            // A NULL wrapper has no C++ object to ask: qobjOf() would call through it and segfault
            // (measured — Qt's Fusion Button, reading `control` before anything assigned it).
            auto cur = __traits(getMember, o, m);
            if ((cur is null ? null : qobjOf(cur)) !is pv) {
                // A BOUND wrapper is rebuilt from the pointer; a D-defined @QObject cannot be —
                // it has no `wrap`, and there is exactly one D object per QtdMocObject anyway, so
                // the registry answers it. Without this branch a `property CheckBox cb: CheckBox {}`
                // could not be a meta-object property at all: the emitter's UDA compiled to
                // "no property `wrap` for type ...".
                static if (__traits(hasMember, X, "wrap"))
                    __traits(getMember, o, m) = pv is null ? null : X.wrap(pv);
                else
                    __traits(getMember, o, m) = pv is null ? null : cast(X) dObjectFor(pv);
                if (notifyIdx >= 0) {
                    void*[2] argv; argv[0] = null; argv[1] = cast(void*) &pv;
                    qtd_moc_activate(qobj, notifyIdx, argv.ptr);
                }
            }
        } else {
            // ...and the value path, which must not even be COMPILED for a class: `nv` does not
            // exist there, and a `return` inside the static-if does not stop the rest from being
            // type-checked (17 link failures in Fusion said so).
            static if (is(X == string)) X nv = qsToD(a[0]);
            else                        X nv = *cast(X*) a[0];
            if (__traits(getMember, o, m) != nv) {
                __traits(getMember, o, m) = nv;
                if (notifyIdx >= 0) {
                    void*[2] argv; argv[0] = null;
                    static if (is(X == string)) {
                        auto qs = qtd_str_to_qs(nv.ptr, cast(int) nv.length);
                        argv[1] = qs; qtd_moc_activate(qobj, notifyIdx, argv.ptr); qtd_qs_free(qs);
                    } else {
                        argv[1] = cast(void*) &nv; qtd_moc_activate(qobj, notifyIdx, argv.ptr);
                    }
                }
            }
        }
        }
    } else {   // ReadProperty: assign the D value into the QVariant/typed slot at a[0]
        static if (is(X == QmlObjectList)) qtd_moc_list_read(qobjOf(o), (m ~ "\0").ptr, a[0]);
        else static if (is(X == QmlVar)) qtd_moc_var_read(qobjOf(o), (m ~ "\0").ptr, a[0]);
        else static if (is(X == class)) {
            auto cur = __traits(getMember, o, m);
            *cast(void**) a[0] = cur is null ? null : qobjOf(cur);
        }
        else static if (is(X == string)) {
            auto s = __traits(getMember, o, m);
            qtd_qs_set(a[0], s.ptr, cast(int) s.length);   // *(QString*)a[0] = s
        }
        else *cast(X*) a[0] = __traits(getMember, o, m);
    }
}

// invokes slot `m` of `o` reading the args from the C array (args[0] is the return).
// `f` is the slot's own function symbol, so an overloaded name still calls the RIGHT overload:
// __traits(child) binds that exact symbol to the instance, where __traits(getMember, o, name)
// would reopen the overload set and re-resolve it from the argument types.
void callSlot(alias f, T)(T o, void** args) {
    import std.traits : ReturnType;
    alias P = Parameters!f;
    P vals;
    static foreach (j, X; P) {
        static if (is(X == string)) vals[j] = qsToD(args[j + 1]);
        // The QVariant Qt allocated, by address: taking a copy would mean deciding what is in it.
        else static if (is(X == QmlVarRef)) vals[j] = QmlVarRef(args[j + 1]);
        else vals[j] = *cast(X*) args[j + 1];
    }
    // ...AND `a[0]` IS THE RETURN. Qt passes a slot the same array it passes an invokable, with
    // slot zero reserved for the result; a void method leaves it alone. Writing it is the whole
    // difference, and it is why invokables need no dispatch of their own.
    static if (is(ReturnType!f == void)) __traits(child, o, f)(vals);
    else {
        auto rv = __traits(child, o, f)(vals);
        if (args[0] !is null) {
            static if (is(ReturnType!f == string)) qtd_qs_set(args[0], rv.ptr, cast(int) rv.length);
            // A QmlVarRef return is a QVariant the callee made: copy it into the slot Qt
            // reserved, then free it. The callee cannot write args[0] itself — it is an ordinary
            // D method and never sees the metacall's array.
            else static if (is(ReturnType!f == QmlVarRef)) {
                qtd_var_assign(args[0], rv.p);
                qtd_var_free(rv.p);
            }
            else *cast(ReturnType!f*) args[0] = rv;
        }
    }
}

// ---- factory ----------------------------------------------------------------
/// Creates an instance of a D @QObject, builds its meta-object at runtime,
/// binds the Signal fields and registers the slot dispatch.
T newQObject(T, Args...)(Args ctorArgs) {
    static assert(hasUDA!(T, QObject),
        "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    validateMeta!T();   // @Slot void + existing/compatible NOTIFY (compile time)
    T o = new T(ctorArgs);
    // A CLASS THAT CARRIES QtdWidget IS ALREADY BUILT, and everything below would build it a
    // SECOND time. That mixin's constructor creates the real carrier — a `<Base>_subclass`, a
    // QQuickRectangle with QQuickRectangle's meta-object — registers it, and runs `__qmltcWire`
    // against it. Going on from here calls `qtd_moc_new`, which makes a QtdMocObject whose
    // meta-object descends from QObject, PUTS THAT IN THE REGISTRY in place of the item, and wires
    // the document a second time against it. Both halves were observed on a real reader:
    //
    //   qtd_attach_value_source: no property 'color' on Main      (the second wire, wrong object)
    //   setProp failed: no writable property "width" taking a double
    //
    // and once that exception was out of the way, the caller's own
    // `QQuickItem.wrap(qobjOf(ui)).setParentItem(view.contentItem())` took the QtdMocObject for an
    // item and went into QQuickItem::setParentItem with a pointer that is not one — SIGSEGV, under
    // gdb, frame #0 in libQt6Quick. `qobjOf` answering something that is not the object the caller
    // built is the defect; the two failures above are what it looks like from outside.
    //
    // `__qtdBuild` is the marker because it is what QtdWidget itself declares. `_adopt` — the test
    // three lines below — is NOT: it comes from the wrapper layer, and guarding on it read false
    // and changed nothing.
    static if (__traits(hasMember, T, "__qtdBuild")) return o;
    else {
    enum sigs  = signalSigs!T;
    enum slts  = slotSigs!T;
    // The forwarding ones are appended AFTER the stored ones, so a property index is still the
    // index into `propMembers` for everything below that length and into the alias list above it.
    enum pnames = propPubNames!T ~ aliasPropNames!T;
    enum ptypes = propTypes!T ~ aliasPropTypes!T;
    enum pnotif = propNotify!T ~ aliasPropNotify!T;
    // arrays of C-strings (signatures with \0 -> .ptr is safe in C); +1 avoids [0]
    const(char)*[sigs.length + 1] sigp;
    const(char)*[slts.length + 1] sltp;
    const(char)*[pnames.length + 1] pnp;
    const(char)*[ptypes.length + 1] ptp;
    int[pnotif.length + 1] pnt;
    static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
    static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
    static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
    void* qobj = qtd_moc_new((T.stringof ~ "\0").ptr,
        sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
        pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
        cast(void*) o, &__mocGlobalDispatch, &__mocGlobalProp);
    static if (__traits(hasMember, T, "_adopt")) o._adopt(qobj);   // WRAPPER: _cpp + pin
    wireQObject(o, qobj);
    return o;
    }
}

// Binds the Signal fields to (qobj, index) and registers the slot/prop dispatch of `o`.
// Shared by newQObject (qobj comes from qtd_moc_new) and by the QML factory
// (qobj = the QtdMocObject the engine allocated).
private void wireQObject(T)(T o, void* qobj) {
    enum pnotif = propNotify!T ~ aliasPropNotify!T;
    int si = 0;
    static foreach (m; signalMembers!T) {
        __traits(getMember, o, m)._bind(qobj, si);
        si++;
    }
    void delegate(int, void**) nothrow disp = (int idx, void** a) nothrow {
        try {
            static foreach (i, f; slotSymbols!T)
                if (idx == i) { callSlot!f(o, a); return; }
        } catch (Exception e) { qtdOnCallbackError(e); }
    };
    void delegate(int, int, void**) nothrow prop = (int idx, int write, void** a) nothrow {
        try {
            static foreach (i, m; propMembers!T)
                if (idx == i) { callProp!(T, m)(o, qobj, pnotif[i], write, a); return; }
            static foreach (j, m; aliasPropMembers!T)
                if (idx == propMembers!T.length + j) {
                    callPropAlias!(T, m)(o, qobj, pnotif[propMembers!T.length + j], write, a); return;
                }
        } catch (Exception e) { qtdOnCallbackError(e); }
    };
    _reg[cast(void*) o] = MocReg(qobj, disp, prop);
    _byQObj[qobj] = cast(void*) o;
    // Post-wire hook: signals are now bound and the meta-object exists, so a generated type can
    // connect its binding dependencies and compute initial values here (it CANNOT in its own
    // ctor, which runs before wiring). qmltc-d emits `__qmltcWire`; a no-op for every hand-written
    // @QObject (none declare it), so this is inert for the existing suite.
    //
static if (__traits(hasMember, T, "__qmltcWire")) o.__qmltcWire();
}

// ---- QML type registration --------------------------------------------------
// Registers a D @QObject as a QML element: `import <uri> <maj>.<min>; <T> { ... }`.
// The engine instantiates the C++ carrier (QtdMocObject) and calls back into `create` (C++),
// which in turn calls the D factory below to create+bind the T that backs the object.
// All D instances share the same C++ typeId (QtdMocObject*), distinguished
// by the runtime QMetaObject — proven by a probe where N types coexist.
private __gshared void* delegate(void* qobj) nothrow[void*] _qmlFactories;   // key = QtdQmlType* (C++)

// SINGLE C callbacks (not per-T -> no extern(C) symbol collision); they dispatch
// via the QtdQmlType* that C++ passes back as `self`.
private extern (C) void* __qmlMake(void* self, void* qobj) nothrow {
    if (auto f = self in _qmlFactories) return (*f)(qobj);
    return null;
}
// The same table for a subclass of a BOUND type: there the engine passes MEMORY, not a carrier —
// the D object placement-constructs its own trampoline there (see QtdPlace).
private __gshared void* delegate(void* mem) nothrow[void*] _qmlPlacers;
private extern (C) void* __qmlMakeAt(void* self, void* mem) nothrow {
    if (auto f = self in _qmlPlacers) return (*f)(mem);
    return null;
}
private extern (C) void __qmlDestroy(void* self, void* dobj) nothrow {
    _reg.remove(dobj);   // drops the T from the registry -> the GC can collect it
}

// publicKey ("uri/name maj.min", what the QML engine sees) -> D identity of the registered type.
// The identity is T.mangleof (fully-qualified mangled name): two homonymous D @QObjects
// (same T.stringof, different modules) have a DISTINCT mangleof. So the same (T, uri, name,
// version) is an idempotent no-op, but two DIFFERENT types under the same public key are an
// observable conflict — not a silent "already registered" (critics r8 #3).
private __gshared string[string] _qmlRegistered;

/// Registers the type `T` (D @QObject) as an instantiable QML element. Call before loading the
/// .qml. Error contract (critics r7 #2): **THROWS** if registration fails in the backend (Qt5 pool
/// exhausted or `qmlregister` refused) — the C++ failure does NOT become a silent success. Registering the
/// SAME (T, uri, name, version) again is idempotent (does not consume another Qt5 pool slot).
void qmlRegisterType(T)(string uri, int vmaj, int vmin, string qmlName) {
    static assert(hasUDA!(T, QObject),
        "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    static assert(__traits(compiles, new T()),
        "qtmoc: " ~ T.stringof ~ " precisa de construtor sem argumentos (o QML instancia sem args)");
    validateMeta!T();   // @Slot void + existing/compatible NOTIFY (compile time)
    import std.conv : to;
    enum typeId = T.mangleof;   // unambiguous D identity (homonyms differ in the mangle)
    auto pubKey = uri ~ "/" ~ qmlName ~ " " ~ vmaj.to!string ~ "." ~ vmin.to!string;
    if (auto prev = pubKey in _qmlRegistered) {
        if (*prev == typeId) return;   // SAME type, same version -> no-op (doesn't re-consume the Qt5 pool)
        throw new Exception("qmlRegisterType conflict: " ~ pubKey ~ " is already registered to a "
            ~ "different D type (" ~ *prev ~ " != " ~ typeId ~ "). Use a distinct name/URI/version.");
    }
    enum sigs = signalSigs!T;
    enum slts = slotSigs!T;
    enum pnames = propPubNames!T ~ aliasPropNames!T;   // the PUBLISHED names, not the fields'
    enum ptypes = propTypes!T ~ aliasPropTypes!T;
    enum pnotif = propNotify!T ~ aliasPropNotify!T;
    const(char)*[sigs.length + 1] sigp;
    const(char)*[slts.length + 1] sltp;
    const(char)*[pnames.length + 1] pnp;
    const(char)*[ptypes.length + 1] ptp;
    int[pnotif.length + 1] pnt;
    static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
    static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
    static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
    // A subclass of a BOUND type registers differently: the engine's `create` gets memory it sized
    // itself, so the shim's placement constructor and the bound base's meta-object are what make the
    // created object a real Item/Control rather than a bare QObject. Everything else — signals,
    // slots, properties, dispatch — is identical, which is why this is one branch and not one path.
    static if (__traits(hasMember, T, "__qtdBaseName")) {
        void* subKey = qtd_qml_register_sub(
            (uri ~ "\0").ptr, vmaj, vmin, (qmlName ~ "\0").ptr,
            (T.stringof ~ "\0").ptr,
            sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
            pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
            &__qmlMakeAt, &__qmlDestroy, &__mocGlobalDispatch, &__mocGlobalProp,
            T.__qtdSize(), T.__qtdSuper(), T.__qtdParserCast());
        if (subKey is null)
            throw new Exception("qmlRegisterType failed for " ~ T.stringof ~ " as " ~ pubKey
                ~ " (backend returned null; see stderr)");
        // The engine hands the placement factory the memory; the D object builds its trampoline
        // there and wires itself exactly as `new T()` does.
        _qmlPlacers[subKey] = (void* mem) nothrow {
            try { return cast(void*) new T(QtdPlace(mem)); }
            catch (Exception e) { qtdOnCallbackError(e); return null; }
        };
        _qmlRegistered[pubKey] = typeId;
        return;
    }
    void* key = qtd_qml_register_type(
        (uri ~ "\0").ptr, vmaj, vmin, (qmlName ~ "\0").ptr,
        (T.stringof ~ "\0").ptr,
        sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
        pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
        &__qmlMake, &__qmlDestroy, &__mocGlobalDispatch, &__mocGlobalProp);
    if (key is null)   // backend refused (Qt5 pool exhausted / qmlregister failed) -> OBSERVABLE
        throw new Exception("qmlRegisterType failed for " ~ T.stringof ~ " as " ~ pubKey
            ~ " (backend returned null; see stderr)");
    // per-T factory: the engine calls this (via __qmlMake) per instance created in QML.
    _qmlFactories[key] = (void* qobj) nothrow {
        try {
            T o = new T();
            wireQObject(o, qobj);
            return cast(void*) o;
        } catch (Exception e) { qtdOnCallbackError(e); return null; }
    };
    _qmlRegistered[pubKey] = typeId;
}

// ---- .qmltypes emission (type description for tooling) ----------------------
// Emits the QQmlJSTypeDescriptionReader-format block a `@QObject` D type would have
// if it were registered via qmlRegisterType — so qmllint / Qt Creator / qmltc can
// see D-defined QML types. This is qmltyperegistrar's `.qmltypes` output, produced
// by CTFE from the same __traits info the runtime meta-object is built from (no moc
// JSON). Pure compile-time string building; a tiny driver writes the result to disk.

/// The `.qmltypes` `Component { ... }` block describing `T` exported as `uri/qmlName vmaj.vmin`.
string qmlTypeComponent(T)(string uri, int vmaj, int vmin, string qmlName) {
    import std.traits : Parameters, ParameterIdentifierTuple;
    static assert(hasUDA!(T, QObject), "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    // qmltyperegistrar encodes the export version as a metaobject revision (major<<8 | minor).
    immutable rev = (vmaj << 8) | vmin;
    string s = "    Component {\n";
    s ~= "        name: \"" ~ T.stringof ~ "\"\n";
    s ~= "        accessSemantics: \"reference\"\n";
    s ~= "        prototype: \"QObject\"\n";
    s ~= "        exports: [\"" ~ uri ~ "/" ~ qmlName ~ " " ~ itoa(vmaj) ~ "." ~ itoa(vmin) ~ "\"]\n";
    s ~= "        exportMetaObjectRevisions: [" ~ itoa(rev) ~ "]\n";
    int pidx = 0;
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        s ~= "        Property { name: \"" ~ m ~ "\"; type: \""
            ~ cppSig!(typeof(__traits(getMember, T, m))) ~ "\"";
        if (note.length) s ~= "; notify: \"" ~ note ~ "\"";
        s ~= "; index: " ~ itoa(pidx) ~ " }\n";
        pidx++;
    }}
    static foreach (m; signalMembers!T) {{
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...)) {
            s ~= "        Signal { name: \"" ~ m ~ "\"";
            static if (A.length) {
                s ~= "\n";
                static foreach (i, X; A)
                    s ~= "            Parameter { name: \"arg" ~ itoa(cast(int) i)
                        ~ "\"; type: \"" ~ cppSig!X ~ "\" }\n";
                s ~= "        }\n";
            } else s ~= " }\n";
        }
    }}
    static foreach (f; slotSymbols!T) {{
        alias P = Parameters!f;
        alias PN = ParameterIdentifierTuple!f;
        s ~= "        Method { name: \"" ~ __traits(identifier, f) ~ "\"";
        static if (P.length) {
            s ~= "\n";
            static foreach (i, X; P)
                s ~= "            Parameter { name: \"" ~ (PN[i].length ? PN[i] : "arg" ~ itoa(cast(int) i))
                    ~ "\"; type: \"" ~ cppSig!X ~ "\" }\n";
            s ~= "        }\n";
        } else s ~= " }\n";
    }}
    s ~= "    }\n";
    return s;
}

/// Wrap one or more `qmlTypeComponent` blocks into a complete `.qmltypes` document.
string qmlTypesModule(string[] components) {
    string s = "import QtQuick.tooling 1.2\n\n";
    s ~= "// This file describes D @QObject types registered for QML (qmlRegisterType).\n";
    s ~= "// Generated by qt-dlang-gen from the CTFE meta-object. For tooling only.\n\n";
    s ~= "Module {\n";
    foreach (c; components) s ~= c;
    s ~= "}\n";
    return s;
}

// ---- widget subclass + moc (merge trampoline + meta-object) -----------------
// (public helpers: the mixin below is instantiated in the user's module and resolves
//  in that scope, so it needs to see qtmoc's helpers/internals.)
/// Optional/documentary UDA: marks a method as an override of a base virtual.
struct Override {}

string itoa(int n) {   // simple CTFE
    if (n == 0) return "0";
    string s; bool neg = n < 0; if (neg) n = -n;
    while (n) { s = cast(char)('0' + n % 10) ~ s; n /= 10; }
    return neg ? "-" ~ s : s;
}
template __qtdIsFn(T, string m) {
    static if (is(typeof(__traits(getMember, T, m)) == function)) enum __qtdIsFn = true;
    else enum __qtdIsFn = false;
}
// generates the extern(C) trampoline that adapts the C++ virtual to the D method `vn`. A
// unique name per class (__ov_<Class>_<idx>) so it doesn't collide in C linkage.
/// A THREAD DRUNTIME HAS NEVER SEEN cannot run D code. Qt calls virtuals on threads it created —
/// `QThread::run()` is the entire purpose of QThread — and on such a thread D has no TLS, no GC
/// registration and no stack range for the collector to scan. That is undefined behaviour, not a
/// slow path: the first GC allocation inside `run()` decides how it fails.
///
/// So the attach lives at the ONE place every virtual callback enters D, rather than in a QThread
/// mechanism. `Thread.getThis()` is a TLS read, so the ordinary case (Qt's main thread, already
/// known) costs one comparison; only a genuinely foreign thread attaches, and it detaches on the
/// way out so druntime does not keep a Thread for a stack that is gone.
struct QtdAttached {
    private bool _mine;
    /// False when the thread is NOT usable from D. The caller must not enter D.
    bool ok = true;
    @disable this(this);
    ~this() nothrow @nogc { if (_mine) { import core.thread : thread_detachThis; thread_detachThis(); } }
}
/// FAIL CLOSED (critics r13 #7). Attaching a foreign thread to the druntime is the precondition for
/// running D at all on it; swallowing the failure and calling the D virtual anyway keeps going in
/// exactly the state the mechanism exists to prevent. `ok` is false when the thread is NOT usable,
/// and every trampoline checks it before entering D.
///
/// The `forceFail` parameter is the test seam the audit asked for, and it is a PARAMETER rather than
/// a global on purpose: a mutable module-level flag here would be counted by the runtime-boundary
/// ratchet as compiler state, and moving a ruler to fit a new line is how a ruler stops meaning
/// anything.
QtdAttached qtdAttachThreadImpl(bool forceFail) nothrow {
    import core.thread : Thread, thread_attachThis;
    QtdAttached a;
    if (Thread.getThis() is null) {
        if (forceFail) { a.ok = false; return a; }
        try { thread_attachThis(); a._mine = true; }
        catch (Throwable) { a.ok = false; }
    }
    return a;
}
/// The seam, reachable from a REAL foreign thread (critics r14 #6). The first version took the
/// forced failure only as a parameter, so nothing could drive the TRAMPOLINE's branch — the test
/// called the impl directly on the main thread, where `Thread.getThis()` is not null, so the forced
/// branch was never entered and the assertion was conditional on a situation that did not occur.
/// An environment variable is readable from the thread Qt created, costs a `getenv` per callback,
/// and adds no module-level state.
QtdAttached qtdAttachThread() nothrow {
    import core.stdc.stdlib : getenv;
    return qtdAttachThreadImpl(getenv("QTD_FORCE_ATTACH_FAIL") !is null);
}

/// What a trampoline does when the thread could not be attached — and it must touch NOTHING of D
/// (critics r14 #6). The first version built a `new Exception`, concatenated strings and called the
/// callback-error policy, which writes a TLS counter and keeps a `Throwable`: that is GC allocation
/// and D state on the very thread just declared unsafe, so "nothing D-side runs after this" was
/// literally false. libc only, `nothrow @nogc`, and the message is written a piece at a time so no
/// string is built.
void qtdAttachFailed(const(char)* what) nothrow @nogc {
    import core.stdc.stdio : fprintf, stderr;
    fprintf(stderr, "qtd FATAL-SAFE: could not attach this thread to the D runtime; refusing to "
                    ~ "enter D for %s\n", what);
}

string __ovTramp(T, string vn, size_t idx, string conv = "")() {
    import std.traits : ReturnType, Parameters;
    alias R = ReturnType!(__traits(getMember, T, vn));
    alias P = Parameters!(__traits(getMember, T, vn));
    string ps, as;
    static foreach (j, X; P) {
        ps ~= (j ? ", " : "") ~ X.stringof ~ " a" ~ itoa(cast(int) j);
        as ~= (j ? ", " : "") ~ "a" ~ itoa(cast(int) j);
    }
    auto nm = "__ov_" ~ T.stringof ~ "_" ~ itoa(cast(int) idx);
    auto call = "(cast(" ~ T.stringof ~ ") d)." ~ vn ~ "(" ~ as ~ ")";
    // A D exception can't unwind across the C++ virtual-call frame -> route it through the
    // callback error policy (counted/recorded/hooked), never silently swallowed.
    auto head = "extern(C) static ";
    auto attach = " nothrow { auto __at = qtdAttachThread();"
        ~ " if (!__at.ok) { qtdAttachFailed(\"" ~ T.stringof ~ "." ~ vn ~ "\".ptr); return";
    // A CONTAINER return: the trampoline wants a heap handle, built from the override's idiomatic D
    // container by the combo's `<id>_from` (qtvirt's __X_vconv names it). null = the override threw.
    // `conv` is "<module>:<combo id>"; imported INSIDE the function, so nothing has to be in scope
    // in the user's module, where this text lands.
    static if (conv.length) {
        enum colon = () { foreach (k, ch; conv) if (ch == ':') return k; return 0; }();
        enum cmod = conv[0 .. colon], cid = conv[colon + 1 .. $];
        return head ~ "void* " ~ nm ~ "(void* d" ~ (ps.length ? ", " ~ ps : "") ~ ")" ~ attach
            ~ " null; } try { import " ~ cmod ~ " : " ~ cid ~ "_from; return " ~ cid ~ "_from(" ~ call ~ "); }"
            ~ " catch (Exception e) { qtdOnCallbackError(e); return null; } }\n";
    }
    // A VALUE-RECORD return (QVariant, QModelIndex): the trampoline passes an OUT pointer to a value
    // it default-constructed. Assignment, not construction: D's assignment of a struct with a
    // destructor swaps, and the default value it displaces is destroyed on the D side — exactly
    // one construction and one destruction per object, whichever language made it.
    else static if (is(R == struct))
        return head ~ "void " ~ nm ~ "(void* d, " ~ R.stringof ~ "* __out" ~ (ps.length ? ", " ~ ps : "")
            ~ ")" ~ attach ~ "; } try { *__out = " ~ call ~ "; }"
            ~ " catch (Exception e) { qtdOnCallbackError(e); } }\n";
    else static if (is(R == void))
        return "extern(C) static void " ~ nm ~ "(void* d" ~ (ps.length ? ", " ~ ps : "")
            ~ ") nothrow { auto __at = qtdAttachThread();"
            ~ " if (!__at.ok) { qtdAttachFailed(\"" ~ T.stringof ~ "." ~ vn ~ "\".ptr); return; }"
            ~ " try { " ~ call
            ~ "; } catch (Exception e) { qtdOnCallbackError(e); } }\n";
    else
        return "extern(C) static " ~ R.stringof ~ " " ~ nm ~ "(void* d" ~ (ps.length ? ", " ~ ps : "")
            ~ ") nothrow { auto __at = qtdAttachThread();"
            ~ " if (!__at.ok) { qtdAttachFailed(\"" ~ T.stringof ~ "." ~ vn ~ "\".ptr); return "
            ~ R.stringof ~ ".init; }"
            ~ " try { return " ~ call
            ~ "; } catch (Exception e) { qtdOnCallbackError(e); return " ~ R.stringof ~ ".init; } }\n";
}

/// Mixin for a Qt class subclassed in D that is ALSO @QObject: it overrides
/// virtuals (methods named after a base virtual, e.g. paintEvent) AND has
/// its own signals/slots/props.
/// Memory to construct into — the tag that selects the placement constructor (see QtdWidget).
struct QtdPlace { void* mem; }

mixin template QtdWidget(Base) {
    void* _qobj;
    // What the QML type registration needs to know about the C++ carrier. The shim publishes it
    // per bound class; these forwarders exist because the shim's symbols are visible HERE (the
    // mixin is instantiated in the user's module, which imports the binding's qtvirt) and not in
    // qtmoc, where qmlRegisterType lives.
    enum string __qtdBaseName = Base.stringof;
    static int __qtdSize() { mixin("return qtd_sub_" ~ Base.stringof ~ "_size();"); }
    static const(void)* __qtdSuper() { mixin("return qtd_sub_" ~ Base.stringof ~ "_super();"); }
    static int __qtdParserCast() { mixin("return qtd_sub_" ~ Base.stringof ~ "_parser_cast();"); }
    private alias _Self = typeof(this);
    final void* __qtdObj() { return _qobj; }
    private enum string[] __vn = mixin("__" ~ Base.stringof ~ "_vnames");  // base virtuals (qtvirt)
    private enum string[] __vc = mixin("__" ~ Base.stringof ~ "_vconv");   // container-return converters
    private enum bool[] __vp = mixin("__" ~ Base.stringof ~ "_vpure");     // which are PURE
    // A PURE virtual the class does not implement is a null callback the trampoline will call the
    // first time Qt asks (it calls pure ones unconditionally). Refused here, by name, instead.
    static foreach (i, vn; __vn)
        static if (__vp[i])
            static assert(__traits(hasMember, typeof(this), vn) && __qtdIsFn!(typeof(this), vn),
                typeof(this).stringof ~ ": subclassing " ~ Base.stringof ~ " requires overriding its pure virtual `"
                ~ vn ~ "` — Qt calls it unconditionally");

    /// The C++ object, checked: once Qt has destroyed it (a parent deleted, deleteLater), the
    /// registry entry is gone (~trampoline -> qtd_moc_detach), and entering C++ through the stale
    /// pointer would be a use-after-free. The subclass thunks go through this.
    final void* __qtdLiveObj() {
        if (_qobj is null || (cast(void*) this) !in _reg)
            throw new Error("use of a destroyed C++ object (" ~ typeof(this).stringof ~ ")");
        return _qobj;
    }
    // What a subclass may call on its base but an outside caller may not — protected non-virtuals
    // (beginInsertRows, createIndex) and the public signals it emits (dataChanged) — as methods of
    // this class, through static members of the C++ trampoline. A member the D class declares with
    // the same name hides these, which is the mixin rule and exactly what an override-by-name wants.
    mixin(mixin("__" ~ Base.stringof ~ "_prot"));

    // extern(C) trampolines for the virtuals the class overrides (name matches).
    static foreach (i, vn; __vn)
        static if (__traits(hasMember, _Self, vn) && __qtdIsFn!(_Self, vn))
            mixin(__ovTramp!(_Self, vn, i, __vc[i]));

    this() { __qtdBuild(null); }
    /// Construct INTO memory somebody ELSE allocated. QML's type registration hands its `create`
    /// hook memory it sized itself (RegisterType::objectSize), so an object the ENGINE instantiates
    /// can only be a real Item/Control if its C++ trampoline is placement-constructed there. Same
    /// object and same wiring as `this()` — only the allocation differs.
    this(QtdPlace __p) { __qtdBuild(__p.mem); }
    private void __qtdBuild(void* __mem) {
        // 1. create the subclass trampoline, plugging in the overridden cbs (the rest null)
        enum __callArgs = () {
            string a;
            static foreach (i, vn; __vn)
                a ~= ", " ~ ((__traits(hasMember, _Self, vn) && __qtdIsFn!(_Self, vn))
                    ? "&__ov_" ~ _Self.stringof ~ "_" ~ itoa(cast(int) i) : "null");
            return a;
        }();
        if (__mem is null)
            mixin("_qobj = cast(void*) " ~ Base.stringof ~ "_subclass(cast(void*) this" ~ __callArgs ~ ");");
        else
            mixin("_qobj = cast(void*) " ~ Base.stringof ~ "_subclass_place(__mem, cast(void*) this"
                  ~ __callArgs ~ ");");
        // WRAPPER mode: adopt the C++ trampoline as our _cpp + pin (C++ holds a raw dself).
        static if (__traits(hasMember, _Self, "_adopt")) this._adopt(_qobj);

        // 2. attach the runtime meta-object (own signals/slots/props)
        enum sigs = signalSigs!_Self; enum slts = slotSigs!_Self;
        enum pnames = propPubNames!_Self ~ aliasPropNames!_Self;   // published, not the fields'
        enum ptypes = propTypes!_Self ~ aliasPropTypes!_Self;
        enum pnotif = propNotify!_Self ~ aliasPropNotify!_Self;
        const(char)*[sigs.length + 1] sigp; const(char)*[slts.length + 1] sltp;
        const(char)*[pnames.length + 1] pnp; const(char)*[ptypes.length + 1] ptp; int[pnotif.length + 1] pnt;
        static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
        static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
        static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
        static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
        static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
        mixin("qtd_sub_" ~ Base.stringof ~ "_attach")(_qobj, (_Self.stringof ~ "\0").ptr,
            sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
            pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
            cast(void*) this, &__mocGlobalDispatch, &__mocGlobalProp);

        // 3. bind the signals + register the slot/prop dispatch (like newQObject)
        int __si = 0;
        static foreach (m; signalMembers!_Self) { __traits(getMember, this, m)._bind(_qobj, __si); __si++; }
        auto __self = this;
        void delegate(int, void**) nothrow __disp = (int idx, void** a) nothrow {
            try { static foreach (i, f; slotSymbols!_Self) if (idx == i) { callSlot!f(__self, a); return; } }
            catch (Exception e) { qtdOnCallbackError(e); }
        };
        void delegate(int, int, void**) nothrow __prp = (int idx, int write, void** a) nothrow {
            try {
                static foreach (i, m; propMembers!_Self)
                    if (idx == i) { callProp!(_Self, m)(__self, _qobj, pnotif[i], write, a); return; }
                static foreach (j, m; aliasPropMembers!_Self)
                    if (idx == propMembers!_Self.length + j) {
                        callPropAlias!(_Self, m)(__self, _qobj,
                                                 pnotif[propMembers!_Self.length + j], write, a); return;
                    }
            } catch (Exception e) { qtdOnCallbackError(e); }
        };
        _reg[cast(void*) this] = MocReg(_qobj, __disp, __prp);
        _byQObj[_qobj] = cast(void*) this;
        // Post-wire hook (same as free wireQObject): a qmltc-d-generated subclass connects its
        // bindings and sets base properties here, after the trampoline + meta-object exist.
        static if (__traits(hasMember, _Self, "__qmltcWire")) this.__qmltcWire();
    }
}

// The object currently being constructed AS A PARENT, handed to the child qmltc-d generates.
// A generated child reads its enclosing object (`control.width` in QML) through a back-reference,
// but the mixin runs __qmltcWire at the END OF THE CONSTRUCTOR — so a field assigned after `new`
// is assigned too late and the wire dereferences null. The parent publishes itself here
// immediately before `new Child()`, and the child's wire takes it as its first statement, before
// it constructs any children of its own. Thread-local (D default) and only live across a
// synchronous construction, which is how an object tree is built.
void* __qmltcOuter;

// ---- properties (access by name via QVariant) -------------------------------
/// Reads an int property by name (custom @Property or built-in).
private extern(C) void* qtd_attached_obj(void*, const(char)*, const(char)*);
/// The ATTACHED-properties object a registered QML type provides for `o` — QML's `Type.prop`.
/// The type is resolved by NAME in Qt's registry, so no compile-time knowledge of it is needed.
void* attachedObj(T)(T o, string uri, string typeName) {
    return qtd_attached_obj(qobjOf(o), (uri ~ "\0").ptr, (typeName ~ "\0").ptr);
}
private extern(C) void qtd_set_parent(void*, void*);
/// Give `child` a Qt parent, so Qt owns it and destroys it with the parent. That destruction is
/// what releases the child's registry entry — see the side-table note above.
void setQtParent(T, U)(T child, U parent) { qtd_set_parent(qobjOf(child), qobjOf(parent)); }
private extern(C) bool qtd_prop_reset(void*, const(char)*);
/// Reset a property to its default (QML's `prop: undefined`). Goes through QMetaProperty::reset —
/// a Q_PROPERTY RESET method is not a slot, so it cannot be invoked by name.
bool resetProp(T)(T o, string name) { return qtd_prop_reset(qobjOf(o), (name ~ "\0").ptr); }
private extern(C) int qtd_prop_set_obj(void*, const(char)*, void*);
/// Attach an object to a QObject*-valued property (the write counterpart of [propObj]).
/// WHERE A PROPERTY OF THIS OBJECT ACTUALLY LIVES. A class the compiler generates for a child the
/// ENGINE builds is a shell around `__inst`: the properties the document declares on that element
/// are declared into the engine's object, not held here. Every write path would otherwise have to
/// know that, at each of its sites; instead a write that the shell cannot take is retried on the
/// object it holds. A failure steps down to the thing that can answer it rather than throwing.
private void* __writeRecv(T)(T o, string name) {
    static if (__traits(hasMember, T, "__inst")) {
        if (o !is null && o.__inst !is null && !hasProp(o, name)) return o.__inst;
    }
    return qobjOf(o);
}
void setPropObj(T, U)(T o, string name, U v) {
    auto r = __writeRecv(o, name);
    if (!qtd_prop_set_obj(r, (name ~ "\0").ptr, qobjOf(v)))
        __propWriteFailed(name, "QObject*", "", qtd_moc_classname(r));
}
private extern(C) bool qtd_invoke0(void*, const(char)*);
/// Invoke a parameterless member (signal or invokable) by name — used to emit a signal that
/// belongs to another object, e.g. a grouped property's.
bool invoke0(T)(T o, string member) { return qtd_invoke0(qobjOf(o), (member ~ "\0").ptr); }
private extern(C) void* qtd_prop_get_obj(void*, const(char)*);
/// The object held by a QObject*-valued property — how a GROUPED property (`group.count`) is
/// reached: the group is a child object, its members are plain properties on it.
void* propObj(T)(T o, string name) {
    auto r = __bindRecv(o, name);
    auto z = (name ~ "\0").ptr;
    auto v = qtd_prop_get_obj(r, z);
    // ...and if it is not there YET, it may be one Qt defers: reading is what builds it.
    if (v is null && __qmltcDeferred.length && __forceDeferred(r, name)) v = qtd_prop_get_obj(r, z);
    return v;
}
int propInt(T)(T o, string name) { return qtd_prop_get_int(__bindRecv(o, name), (name ~ "\0").ptr); }

/// JS SEMANTICS, WHICH A BINDING INHERITS: reading a property off `null` THROWS, and a QML binding
/// that throws writes NOTHING — the property keeps what it had, which for an initial binding is the
/// type's default. Measured against the engine on a document whose `property Item control` is null:
///
///   readonly property color c: Qt.darker(control.palette.text, 1.2)   engine: #000000 (INVALID)
///   property string        s: "x" + control.objectName                engine: "" — not "x"
///
/// Our reads were null-tolerant and produced a value instead: a TRANSPARENT colour (#00000000) and
/// "x". Seven of Qt's own documents — Fusion's CheckIndicator, RadioIndicator, SliderGroove,
/// ButtonPanel and DelayButton, Universal's CheckIndicator — disagreed with the engine on exactly
/// this and nothing else. `s` is the decisive one: had the expression merely yielded `undefined`,
/// the engine would read "xundefined".
///
/// The reads stay null-tolerant OUTSIDE a binding, because the WIRING uses the same helpers:
/// `tryConnectMeta(propObj(__outer, "control"), ...)` must survive a null control rather than abort
/// the object's construction. So the throw is SCOPED — only code running inside [bindEval] sees it.
class QmlNullDeref : Exception {
    this(string prop) @safe pure nothrow { super("QML TypeError: null has no property '" ~ prop ~ "'"); }
}
private bool __inBinding = false;
/// The receiver of a property read, checked for the null a binding must not survive.
void* __bindRecv(T)(T o, string name) {
    auto q = qobjOf(o);
    if (q is null && __inBinding) throw new QmlNullDeref(name);
    return q;
}
private extern(C) int qtd_call_js(void*, const(char)*, const(char)**, void**, int, void**, int, void*);
private extern(C) void* qtd_var_new();
private extern(C) void qtd_var_assign(void*, void*);
private extern(C) void qtd_var_free(void*);
/// Run a QML function's SOURCE in the engine, with the arguments the metacall was handed and the
/// result written into the slot it reserved. The whole crossing is QVariant, so nothing here — and
/// nothing in the generated code — decides what an untyped parameter holds.
///
/// `ret` is `args[0]`: Qt reserves it for the return of every method, and an invokable declared to
/// return QVariant gets a QVariant there to assign into.
private extern(C) void* qtd_var_of_int(long);
private extern(C) void* qtd_var_of_double(double);
private extern(C) void* qtd_var_of_bool(bool);
private extern(C) void* qtd_var_of_str(const(char)*, int);
/// A typed D value as the untyped thing JavaScript takes. `callJsFunc` hands each argument to the
/// engine as a QVariant; a function whose D signature is typed — because its parameter's type could
/// be inferred — still has to cross that way when its BODY is the engine's.
private extern(C) void* qtd_var_text(void*, const(char)*);
/// A `var` property rendered as text, the way the differential's oracle renders it. The D field of
/// a `var` is an empty marker — the runtime owns the value — so reading the field prints nothing.
private extern(C) int qtd_var_count(void*, const(char)*);
/// How many rows a `var` property holds, or -1 when it is not a list. `varText` cannot answer this:
/// a row is a map and a map has no string form, so a model of any size reads back as "".
int varCount(T)(T o, string name) {
    return qtd_var_count(qobjOf(o), (name ~ "\0").ptr);
}

string varText(T)(T o, string name) {
    auto p = qtd_var_text(qobjOf(o), (name ~ "\0").ptr);
    auto s = qsToD(p); qtd_qs_free(p); return s;
}

QmlVarRef varOf(T)(T v) {
    static if (is(T == string))        return QmlVarRef(qtd_var_of_str(v.ptr, cast(int) v.length));
    else static if (is(T == bool))     return QmlVarRef(qtd_var_of_bool(v));
    else static if (is(T : long))      return QmlVarRef(qtd_var_of_int(cast(long) v));
    else static if (is(T : double))    return QmlVarRef(qtd_var_of_double(cast(double) v));
    else static if (is(T == QmlVarRef)) return v;
    else static assert(0, "varOf: no QVariant for " ~ T.stringof);
}

private extern(C) long qtd_varbox_as_int(void*);
private extern(C) double qtd_varbox_as_double(void*);
private extern(C) bool qtd_varbox_as_bool(void*);
private extern(C) void* qtd_varbox_as_str(void*);

/// The scalar inside the QVariant a DELEGATED function returned, converted the way the engine
/// converts it. A function with an untyped parameter is declared to the meta-object and its body
/// handed to the engine, so its D signature returns a QmlVarRef — and a compiled caller that needs
/// a `bool` cannot use the box.
///
/// The box is this call's to free: `callJsFunc` allocated it for the return and, outside a metacall,
/// nothing else will. That is why this is the only reader — one place owning the free.
T varAs(T)(QmlVarRef v) {
    scope (exit) if (v.p !is null) qtd_var_free(v.p);
    static if (is(T == bool))        return qtd_varbox_as_bool(v.p);
    else static if (is(T == string)) { auto q = qtd_varbox_as_str(v.p);
                                       auto s = qsToD(q); qtd_qs_free(q); return s; }
    else static if (is(T : long))    return cast(T) qtd_varbox_as_int(v.p);
    else static if (is(T : double))  return cast(T) qtd_varbox_as_double(v.p);
    else static assert(0, "varAs: no conversion to " ~ T.stringof);
}

/// `ids`/`objs` publish the names the body reads that are not its own — the enclosing document's
/// ids — on a context of its own, exactly as a delegated binding gets them.
QmlVarRef callJsFunc(T, A...)(T o, string src, QmlVarRef[] argv, string[] ids = null,
                              A objs = A.init) {
    auto ps = new void*[argv.length];
    foreach (i, a; argv) ps[i] = a.p;
    const(char)*[A.length ? A.length : 1] ns;
    void*[A.length ? A.length : 1] os;
    static foreach (i, a; objs) {
        ns[i] = (ids[i] ~ "\0").ptr;
        os[i] = qobjOf(a);
    }
    auto ret = qtd_var_new();
    qtd_call_js(qobjOf(o), (src ~ "\0").ptr, ns.ptr, os.ptr, cast(int) A.length,
                ps.ptr, cast(int) ps.length, ret);
    return QmlVarRef(ret);   // callSlot copies it into the metacall's slot and frees this one
}

/// Evaluate ONE binding. A null dereference inside aborts it and writes nothing, as the engine
/// does; any other exception propagates. Each initial binding is wrapped separately because the
/// engine aborting one does not stop the object being built — only that one property stays at its
/// default.
void bindEval(scope void delegate() f) {
    auto saved = __inBinding;
    __inBinding = true;
    scope(exit) __inBinding = saved;
    try f(); catch (QmlNullDeref) {}
}
/// Writes an int property by name (fires the notify, if any).
/// Writes a property and THROWS when the write did not land: an undeclared name (which would
/// quietly become a DYNAMIC property, changing nothing the meta-object knows about) or a value the
/// meta-type cannot convert. Generated code writes properties by name in the thousands, and a
/// typo there used to be invisible — the same silent failure connectMeta was fixed for.
void setProp(T)(T o, string name, int v) {
    if (!qtd_prop_set_int(qobjOf(o), (name ~ "\0").ptr, v)) __propWriteFailed(name, "int");
}
private extern(C) int qtd_prop_set_list(void*, const(char)*, const(char)*, const(char)**, int);
/// Writes a LIST-valued property: `model: ["a", "b"]`, `columns: [1, 2, 3]`.
///
/// One overload for every element type, because the elements cross as TEXT and QMetaType converts
/// on the other side — the channel a colour and an enum key already use. An array literal used to
/// compile to a D `string[]`/`int[]`/`double[]` with no `setProp` to take it, so a document using
/// the commonest form of a static model emitted code that did not compile.
// `!is(E == immutable char)` because a `string` IS an array of those, and without it this overload
// competed with the scalar-string one on every single-string write in the corpus.
void setProp(T, E)(T o, string name, E[] v)
        if (!is(E == class) && !is(immutable E == immutable char)) {
    import std.conv : to;
    import std.string : toStringz;
    const(char)*[] cs;
    string[] keep;                       // the .toStringz results have to outlive the call
    keep.reserve(v.length); cs.reserve(v.length);
    foreach (e; v) {
        static if (is(E == string)) keep ~= e;
        else                        keep ~= e.to!string;
        cs ~= keep[$ - 1].toStringz;
    }
    // The ELEMENT type as Qt names it, so the conversion happens where the meta-types are.
    static if (is(E == string))      enum tn = "QString";
    else static if (is(E == int))    enum tn = "int";
    else static if (is(E == bool))   enum tn = "bool";
    else static if (is(E == double)) enum tn = "double";
    else                             enum tn = E.stringof;
    if (!qtd_prop_set_list(qobjOf(o), (name ~ "\0").ptr, tn, cs.ptr, cast(int) cs.length))
        __propWriteFailed(name, tn ~ "[]");
}
private extern(C) int qtd_prop_set_any(void*, const(char)*, const(char)*);
/// Write a property on an object whose TYPE WE DO NOT KNOW, creating it if the meta-object has no
/// such name — which is what QML itself does: `ListElement { name: "alpha" }` gives a
/// QQmlListElement a `name` it did not have. [setProp] throws on an undeclared name on purpose, so
/// a typo cannot quietly become a dynamic property; that check needs a registry entry to mean
/// anything, and for a type outside the binding there is none. The value crosses as TEXT and
/// QMetaType converts, the same channel every value here already travels on.
void setPropAny(T, V)(T o, string name, V v) {
    import std.conv : to;
    static if (is(V == string)) auto s = v;
    else                        auto s = v.to!string;
    qtd_prop_set_any(qobjOf(o), (name ~ "\0").ptr, (s ~ "\0").ptr);
}

/// Reads a real (double) property by name.
double propDouble(T)(T o, string name) { return qtd_prop_get_double(__bindRecv(o, name), (name ~ "\0").ptr); }
/// Writes a real (double) property by name (fires the notify, if any).
void setProp(T)(T o, string name, double v) {
    if (!qtd_prop_set_double(qobjOf(o), (name ~ "\0").ptr, v)) __propWriteFailed(name, "double");
}
/// Reads a bool property by name.
bool propBool(T)(T o, string name) { return qtd_prop_get_bool(__bindRecv(o, name), (name ~ "\0").ptr); }
/// Writes a bool property by name (fires the notify, if any).
void setProp(T)(T o, string name, bool v) {
    if (!qtd_prop_set_bool(qobjOf(o), (name ~ "\0").ptr, v)) __propWriteFailed(name, "bool");
}
/// Reads a QString property by name as a D string.
string propStr(T)(T o, string name) {
    auto qs = qtd_prop_get_qs(__bindRecv(o, name), (name ~ "\0").ptr);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}
/// JS `||` and `&&` return an OPERAND, not a bool: `a || b` is `a` when `a` is truthy, else `b`.
/// In a bool target that distinction is invisible, but `implicitWidth: a || b` (Qt's TextField)
/// must yield a WIDTH — compiled as a bool comparison it would set 1 or 0. `lazy` keeps JS's
/// short-circuit, and taking `a` by value evaluates it exactly once.
/// TRUTHINESS IS JS'S, NOT D'S, and for a string the two disagree: JS calls `""` falsy while D
/// would take a non-null slice as true, so the test is on LENGTH. `a || ""` on a string is the
/// ordinary way a document supplies a default — the reader writes `(place || "").length` — and
/// compiled as D's `||` it yields a bool, which does not even have a `.length` to read.
private bool __qmltcTruthy(T)(auto ref T v) {
    static if (is(T == string) || is(T == wstring) || is(T == dstring) || __traits(isStaticArray, T)
               || is(T : const(U)[], U)) return v.length != 0;
    else static if (is(T == bool)) return v;
    else return v != 0;
}
T __qmltcOr(T)(T a, lazy T b) { return __qmltcTruthy(a) ? a : b; }
/// ...and its twin: `a && b` is `b` when `a` is truthy, else `a`.
T __qmltcAnd(T)(T a, lazy T b) { return __qmltcTruthy(a) ? b : a; }

/// The QML globals `Qt.darker` / `Qt.lighter`. Both take a colour and a factor and return a
/// colour; colours travel as TEXT here (a colour read is a propStr and a colour write goes through
/// QMetaType), so this is string-in/string-out and composes with every other colour expression.
/// The default factors are QML's own: 2.0 for darker, 1.5 for lighter.
/// The argument is a string when it came off the meta channel and a real QColor when it is a
/// DECLARED `property color` (a QColor field) — a colour written in the same document reaches both
/// ways. QColor is a binding type this unit cannot name, so the value crosses as its ARGB word,
/// which is a plain scalar; C++ rebuilds the colour from it and formats the result.
string colorDarker(C)(C c, double f = 2.0) { return __shade(c, f, 0); }
/// ditto
string colorLighter(C)(C c, double f = 1.5) { return __shade(c, f, 1); }
/// A real crossing the meta channel as TEXT. `to!string` formats a double with six significant
/// digits, which does not round-trip: `Color.transparent(c, 210 / 255)` reached Qt as 0.823529 and
/// came back one alpha step short of what the engine computed. 17 digits always round-trips.
/// A NUMBER RENDERED AS TEXT, and still a number as far as a call is concerned. Everything scalar
/// crosses a metacall as text, and the generator wraps a numeric literal in this before an invoke —
/// so by the time `invokeMixed` looked at the argument its D type was `string` and the far side
/// built a QString. Harmless for a typed parameter, which converts; wrong for a `var` one, which
/// takes whatever it is given: `v + base` came out "25" where the engine gives 7. The `alias this`
/// keeps every existing use working, since this IS its text.
struct QmlNum { string t; alias t this; }
QmlNum numText(double v) { import std.format : format; return QmlNum(format("%.17g", v)); }
/// The QML global `Qt.alpha`: the same colour at a new opacity. Same two argument shapes as the
/// shade helpers, for the same reason — a colour arrives here as text or as a declared QColor.
string colorAlpha(C)(C c, double a) {
    static if (is(C : string)) auto qs = qtd_color_alpha((c ~ "\0").ptr, a);
    else                       auto qs = qtd_color_alpha_rgba(cast(uint) c.rgba(), a);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}
/// A colour's text, for the places a value has to cross as text (an invokable's argument).
string colorName(C)(C c) {
    auto qs = qtd_color_name(cast(uint) c.rgba());
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}
private string __shade(C)(C c, double f, int lighter) {
    static if (is(C : string)) auto qs = qtd_color_shade((c ~ "\0").ptr, f, lighter);
    else                       auto qs = qtd_color_shade_rgba(cast(uint)c.rgba(), f, lighter);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}
/// The NUMBER behind an enum key, on the C++ type that declares it. QML spells these as
/// `StandardKey.Undo` — an uncreatable type exported for its enum alone, with no object to read
/// from — and the number is what QML assigns. Falls back to `def` when the lookup fails.
/// ...and asked of an OBJECT first, which is the form that always has an answer: a bound class need
/// not have a metatype (nothing instantiates a `QQuickAbstractAnimation*`), but the object being
/// assigned carries the whole chain in its own meta-object.
int enumValueOn(T)(T o, string cxxType, string key, int def = 0) {
    return qtd_enum_value_on(qobjOf(o), (cxxType ~ "\0").ptr, (key ~ "\0").ptr, def);
}
int enumValue(string cxxType, string key, int def = 0) {
    return qtd_enum_value((cxxType ~ "\0").ptr, (key ~ "\0").ptr, def);
}
/// The QML global `Qt.platform.pluginName` — QGuiApplication::platformName(), which is what QML
/// returns there. Empty in a binding without QtGui.
string platformName() {
    auto qs = qtd_platform_name();
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}
/// The QML global `Qt.styleHints`: an ordinary QObject, so every member below it is reachable
/// with the ordinary propObj/propEnumKey channel. Null in a binding without QtGui.
void* styleHintsObj() { return qtd_style_hints(); }
/// The Nth element of a list property, through the meta-object — where the ENGINE holds it, which
/// is not always the field we appended from.
void* listAt(T)(T o, string prop, int i) { return qtd_list_at(qobjOf(o), (prop ~ "\0").ptr, i); }

private extern(C) void* qtd_invoke_mixed(void*, const(char)*, int, const(int)*, const(void*)*);
private extern(C) void* qtd_invoke_mixed_obj(void*, const(char)*, int, const(int)*, const(void*)*);
/// // A NUMBER OR A BOOL IS A VALUE, and in invokeMixed it reached the OBJECT branch: everything that
/// was neither a string nor a colour fell through to qobjOf, which is for QObjects, so
/// `outer.take(d)` with a `double d` instantiated qobjOf!double and LDC answered
///     qtmoc.d(286): Error: invalid cast from `double` to `void*`
/// and ONLY when an object file was actually written — `ldc2 -c -o-` stops at semantic analysis
/// and reports zero errors on the same file. Reported from the outside (bugs.md 8) with that
/// distinction spelled out, which is what made it findable at all.
///
/// A LITERAL never hit it: the generator wraps one in numText() before the call. So the two
/// spellings of the same argument disagreed about whose job the conversion is. They cross the same
/// way now — and through the same numText, because `to!string` formats a double with six
/// significant digits and does not round-trip, which the sibling was quietly doing.
/// An INTEGER keeps to!string: %.17g would render a long past 2^53 as a rounded double.
/// Call a Q_INVOKABLE by name with mixed arguments — TEXT (QMetaType converts it to the declared
/// parameter type) and OBJECTS, which no text can stand in for. Qt's Fusion style computes its
/// colours as `Fusion.buttonColor(control.palette, …)`; the palette has to travel as a pointer.
string invokeMixed(T, A...)(T recv, string method, A args) {
    int[A.length] kinds; const(void)*[A.length] vals;
    string[A.length] keep;
    static foreach (i, a; args) {
        static if (is(typeof(a) == QmlNum)) {
            keep[i] = a.t ~ "\0"; kinds[i] = 2; vals[i] = keep[i].ptr;
        } else static if (is(typeof(a) == string)) {
            keep[i] = a ~ "\0"; kinds[i] = 0; vals[i] = keep[i].ptr;
        // A COLOUR is a value, not an object: `Fusion.buttonColor(control.palette, …, tint)` mixes
        // the two in one call. It crosses as TEXT, which is how a colour crosses everywhere else
        // here, and QMetaType converts it back on the far side. Keyed on the capability rather
        // than on the type name: this unit cannot name QColor (it is a binding type).
        } else static if (__traits(compiles, a.rgba())) {
            keep[i] = colorName(a) ~ "\0"; kinds[i] = 0; vals[i] = keep[i].ptr;
        // KIND 2 AND 3 SAY WHAT THE TEXT IS. Everything scalar crosses as text and the far side
        // converts it to the parameter's type, which works for every type except the one that
        // accepts anything: a `var` parameter is a QVariant, and a QString does not convert to one
        // — `qtd: argument 0 of 'apply' does not convert to QVariant`, about a call the engine
        // makes without trouble. The kind carries what D already knew, so the far side builds a
        // number as a number rather than guessing from the digits.
        } else static if (is(typeof(a) == bool)) {
            keep[i] = (a ? "true" : "false") ~ "\0"; kinds[i] = 3; vals[i] = keep[i].ptr;
        } else static if (__traits(isIntegral, typeof(a))) {
            import std.conv : to; keep[i] = a.to!string ~ "\0"; kinds[i] = 2; vals[i] = keep[i].ptr;
        } else static if (__traits(isFloating, typeof(a))) {
            keep[i] = numText(cast(double) a) ~ "\0"; kinds[i] = 2; vals[i] = keep[i].ptr;
        } else {
            kinds[i] = 1; vals[i] = qobjOf(a);
        }
    }
    auto p = qtd_invoke_mixed(qobjOf(recv), (method ~ "\0").ptr, cast(int) A.length,
                              kinds.ptr, vals.ptr);
    auto s = qsToD(p); qtd_qs_free(p); return s;
}

/// ...and the same call whose RESULT is an OBJECT: `parent.itemAtIndex(i)` on a view. Text cannot
/// carry one, so this is the only way such a call can be a value at all. Returns the QObject* for a
/// `cast(X) dObjectFor(...)` or a plain propObj read to work on.
void* invokeMixedObj(T, A...)(T recv, string method, A args) {
    int[A.length] kinds; const(void)*[A.length] vals;
    string[A.length] keep;
    static foreach (i, a; args) {
        static if (is(typeof(a) == string)) { keep[i] = a ~ "\0"; kinds[i] = 0; vals[i] = keep[i].ptr; }
        else static if (__traits(compiles, a.rgba())) { keep[i] = colorName(a) ~ "\0"; kinds[i] = 0; vals[i] = keep[i].ptr; }
        else static if (is(typeof(a) == bool)) {
            keep[i] = (a ? "true" : "false") ~ "\0"; kinds[i] = 0; vals[i] = keep[i].ptr;
        } else static if (__traits(isIntegral, typeof(a))) {
            import std.conv : to; keep[i] = a.to!string ~ "\0"; kinds[i] = 0; vals[i] = keep[i].ptr;
        } else static if (__traits(isFloating, typeof(a))) {
            keep[i] = numText(cast(double) a) ~ "\0"; kinds[i] = 0; vals[i] = keep[i].ptr;
        } else { kinds[i] = 1; vals[i] = qobjOf(a); }
    }
    return qtd_invoke_mixed_obj(qobjOf(recv), (method ~ "\0").ptr, cast(int) A.length,
                                kinds.ptr, vals.ptr);
}

private extern(C) void* qtd_find_outer(void*, const(char)*);
/// The nearest ENCLOSING object of class `cls`, by visual then QObject parent, as the D OBJECT
/// (what a cast to the generated class needs). What a compiled child gets handed at construction,
/// an ENGINE-created object (a delegate instance) has to find — it is created by a view, not by
/// its enclosing document object.
void* findOuter(T)(T o, string cls) { return qtd_find_outer(qobjOf(o), (cls ~ "\0").ptr); }

private extern(C) int qtd_qml_write(void*, const(char)*, const(char)*, int);
/// Write a member of a value type QML resolves through its own registry (`font.bold`), by NAME. A
/// QFont member has no gadget meta-object to read-modify-write, so this is the channel — the same
/// one the engine uses for that line in the .qml. Reports failure rather than pretending.
void setQmlProp(T, V)(T o, string path, V v) {
    import std.conv : to;
    static if (is(V == bool)) enum kind = 0;
    else static if (is(V : long)) enum kind = 1;
    else static if (is(V : double)) enum kind = 2;
    else enum kind = 3;
    static if (kind == 0) string sv = v ? "true" : "false";
    else static if (kind == 3) string sv = v;
    else string sv = v.to!string;
    if (!qtd_qml_write(qobjOf(o), (path ~ "\0").ptr, (sv ~ "\0").ptr, kind))
        __propWriteFailed(path, "value-type member");
}

private extern(C) void* qtd_varlist_new();
private extern(C) void* qtd_varmap_new();
private extern(C) void qtd_varmap_set_str(void*, const(char)*, const(char)*, int);
private extern(C) void qtd_varmap_set_int(void*, const(char)*, long);
private extern(C) void qtd_varmap_set_double(void*, const(char)*, double);
private extern(C) void qtd_varmap_set_bool(void*, const(char)*, bool);
private extern(C) void qtd_varlist_push(void*, void*);
private extern(C) void qtd_varlist_into(void*, void*);

/// PUBLISH AN ARRAY OF STRUCTS AS A QML MODEL. Each element becomes a map whose keys are the
/// struct's FIELD NAMES, and a QVariantList of those is what a QML view already accepts as a model —
/// no QAbstractListModel, no moc, no roles to register.
///
/// The struct is the row's schema, in one place, and it is the same list of names the delegate
/// claims:
///
///     struct Verse { int number; string text; bool marked; }
///     setModel(this, "page", verses);          // D
///
///     delegate: Text {                          // QML
///         required property int number
///         required property string text
///         text: number + "  " + text
///     }
///
/// Written that way the delegate COMPILES: `required property` is a property of the object itself,
/// where `modelData.text` is a name from a scope this compiler cannot see and has to delegate
/// (docs/qmltc-d-good-practices.md §5.2). The alternative applications reach for — a JSON string the
/// QML re-parses — pays a serialise, a parse and that delegation on every change.
///
/// `name` must be a `QmlVar` @Property of `o`: that is the meta-object's `QVariant` slot, which is
/// what a QML `var` property is.
void setModel(T, R)(T o, string name, R[] rows) if (is(R == struct)) {
    // LOUD ON A NULL RECEIVER. The write goes to a side table keyed by the QObject, so an object
    // that is not registered yet keys the slot on NULL and the value is dropped without a word —
    // the property then reads empty and the view shows nothing, which looks like a compiler gap
    // and is a call made too early. Reported from an application: `setModel` from inside the
    // constructor, before `newQObject` had registered the object, cost hours of looking in the
    // wrong place. The rule is the same one the property writers keep: a write that cannot land
    // says so.
    if (qobjOf(o) is null)
        throw new Exception("setModel(\"" ~ name ~ "\"): the object is not registered yet — "
                            ~ "qobjOf() is null, so the rows would be written to nobody. Publish "
                            ~ "the model AFTER newQObject/qmlRegisterType has the object, not from "
                            ~ "inside its constructor.");
    auto list = qtd_varlist_new();
    foreach (ref row; rows) {
        auto m = qtd_varmap_new();
        foreach (i, ref fld; row.tupleof) {
            enum k = __traits(identifier, R.tupleof[i]) ~ "\0";
            alias F = typeof(fld);
            static if (is(F == string))      qtd_varmap_set_str(m, k.ptr, fld.ptr, cast(int) fld.length);
            else static if (is(F == bool))   qtd_varmap_set_bool(m, k.ptr, fld);
            else static if (is(F : long))    qtd_varmap_set_int(m, k.ptr, cast(long) fld);
            else static if (is(F : double))  qtd_varmap_set_double(m, k.ptr, cast(double) fld);
            else static assert(0, "setModel: a row field must be a string, an integral, a "
                                  ~ "floating-point value or a bool — `" ~ F.stringof ~ " "
                                  ~ __traits(identifier, R.tupleof[i]) ~ "` is none of those");
        }
        qtd_varlist_push(list, m);
    }
    // Into the property's QVariant slot, through the same door a `var` property is read by.
    QmlVarBox box;
    qtd_varlist_into(list, &box);
    qtd_moc_var_write(qobjOf(o), (name ~ "\0").ptr, &box);
    qtd_var_box_clear(&box);
}
/// Storage the size and alignment of a QVariant, so one can be built and released without D naming
/// the type. QVariant is bound as a value type elsewhere; this path deliberately does not depend on
/// which binding is linked, since setModel is useful from a program that binds no QtQml types at all.
private struct QmlVarBox { align(8) ubyte[32] _; }
private extern(C) void qtd_var_box_clear(void*);

private extern(C) void qtd_moc_list_read(void*, const(char)*, void*);
private extern(C) void qtd_moc_var_read(void*, const(char)*, void*);
private extern(C) void qtd_moc_var_write(void*, const(char)*, void*);
private extern(C) void* qtd_context_object(void*);
/// The object the per-item QQmlContext carries — what publishes `index`/`model` for a delegate,
/// with notify signals, so a binding on them can be connected like any other.
void* contextObject(T)(T o) { return qtd_context_object(qobjOf(o)); }

private extern(C) int qtd_context_prop_int(void*, const(char)*);
private extern(C) double qtd_context_prop_double(void*, const(char)*);
private extern(C) void* qtd_context_prop_qs(void*, const(char)*);
/// A CONTEXT property (`index`, `model`, `modelData` in a delegate): the view publishes them on the
/// per-item QQmlContext, so they belong to no object and are read by name through the context.
int contextInt(T)(T o, string n) { return qtd_context_prop_int(qobjOf(o), (n ~ "\0").ptr); }
double contextDouble(T)(T o, string n) { return qtd_context_prop_double(qobjOf(o), (n ~ "\0").ptr); }
private extern(C) int qtd_ctx_fill_int(void*, const(char)*);
private extern(C) double qtd_ctx_fill_double(void*, const(char)*);
private extern(C) void* qtd_ctx_fill_qs(void*, const(char)*);
/// The value a view WOULD have injected into a required property, read past the object's own
/// shadow. Only for filling such a property: an ordinary context read must NOT skip the shadow,
/// because the engine does not skip it either (a plain declared `index` reads 0 on every item there
/// too). See qtd_item_context.
private extern(C) void qtd_ctx_fill_var(void*, const(char)*);
/// ...and a `var` role, which goes straight into the slot: a `var`'s value is not in the D field.
void fillVar(T)(T o, string n) { qtd_ctx_fill_var(qobjOf(o), (n ~ "\0").ptr); }
int fillInt(T)(T o, string n) { return qtd_ctx_fill_int(qobjOf(o), (n ~ "\0").ptr); }
double fillDouble(T)(T o, string n) { return qtd_ctx_fill_double(qobjOf(o), (n ~ "\0").ptr); }
string fillStr(T)(T o, string n) {
    auto p = qtd_ctx_fill_qs(qobjOf(o), (n ~ "\0").ptr);
    auto s = qsToD(p); qtd_qs_free(p); return s;
}
string contextStr(T)(T o, string n) {
    auto p = qtd_context_prop_qs(qobjOf(o), (n ~ "\0").ptr);
    auto s = qsToD(p); qtd_qs_free(p); return s;
}

private extern(C) int qtd_bind_js(void*, const(char)*, const(char)*,
                                  const(char)**, void**, int);
/// A binding the compiler could NOT translate, left to the QML engine: the original expression
/// source is evaluated by QQmlExpression and written into `prop`, and re-evaluated whenever the
/// engine says one of its dependencies changed. `ids` are the names the expression mentions that
/// exist in our world only as fields — they are published on a context nested inside the object's
/// own, so a per-item `index`/`model` one level up still resolves.
///
/// This is a DELEGATION, not a compilation: it is emitted only where the alternative was a refusal,
/// and the compiler reports it as its own kind of diagnostic so the census never mistakes one for
/// the other.
int bindJs(T, A...)(T o, string prop, string src, string[] ids, A objs) {
    const(char)*[A.length] ns;
    void*[A.length] ps;
    static foreach (i, a; objs) {
        ns[i] = (ids[i] ~ "\0").ptr;
        ps[i] = qobjOf(a);
    }
    return qtd_bind_js(qobjOf(o), (prop ~ "\0").ptr, (src ~ "\0").ptr,
                       ns.ptr, ps.ptr, cast(int) A.length);
}

private extern(C) int qtd_run_js(void*, const(char)*, const(char)**, void**, int);
/// Run a handler body the compiler could not compile, in the engine's scope, when the signal
/// fires. See qtd_run_js in qtdmoc_qml.cpp for why a body may need a scope the compiler lacks.
int runJs(T)(T o, string src) {
    return qtd_run_js(qobjOf(o), (src ~ "\0").ptr, null, null, 0);
}
/// ...and the form that hands the body the names it cannot otherwise see — the enclosing
/// document's ids, for a handler delegated on an object the engine built.
int runJs(T, A...)(T o, string src, string[] ids, A objs) {
    const(char)*[A.length ? A.length : 1] ns;
    void*[A.length ? A.length : 1] ps;
    static foreach (i, a; objs) {
        ns[i] = (ids[i] ~ "\0").ptr;
        ps[i] = qobjOf(a);
    }
    return qtd_run_js(qobjOf(o), (src ~ "\0").ptr, ns.ptr, ps.ptr, cast(int) A.length);
}

private extern(C) int qtd_bind_shadow(void*, const(char)*, const(char)*, const(char)*, const(char)**, void**, int);
/// PHASE 2: the same delegation, from a SHADOW compiled at build time. The expression lives in a
/// generated QML document — a real one, with the original document's imports — and the value is
/// written back by a `Binding` inside it, so it stays reactive without a signal being wired here.
/// Emitted in place of `bindJs` when the compiler is given --shadow-dir; identical otherwise.
/// `src` is the same expression the shadow was built from: if the shadow does not load or build,
/// the runtime evaluates it through the engine rather than leaving the property unbound.
int bindShadow(T, A...)(T o, string prop, string url, string src, string[] ids, A objs) {
    const(char)*[A.length ? A.length : 1] ns;
    void*[A.length ? A.length : 1] ps;
    static foreach (i, a; objs) {
        ns[i] = (ids[i] ~ "\0").ptr;
        ps[i] = qobjOf(a);
    }
    return qtd_bind_shadow(qobjOf(o), (prop ~ "\0").ptr, (url ~ "\0").ptr, (src ~ "\0").ptr,
                           ns.ptr, ps.ptr, cast(int) A.length);
}

private extern(C) void* qtd_scope_object(void*, const(char)*);
private extern(C) void qtd_scope_notify(void*, const(char)*, const(char)*, const(char)*);
/// The OBJECT a scope name stands for — a name this document does not declare and the application
/// published (`theme`, `bible`), resolved the way the engine resolves it: up the context chain.
///
/// Null while the name is not reachable, which during the wire is the normal answer. That is not a
/// failure and must not be papered over: the generated read is `propAny!T(scopeObj(...), "x")`, and
/// propAny throws on a null receiver so the binding aborts and writes nothing — exactly what the
/// engine does with `undefined.x`. [scopeNotify] is what brings the value in when the name arrives.
void* scopeObj(T)(T o, string name) {
    return qtd_scope_object(qobjOf(o), (name ~ "\0").ptr);
}

/// Keep such a read current: when `name` resolves, connect the member's notify (both spellings) to
/// `slot` on `o` and run `slot` once — the evaluation that finally has a value. Queued until then.
void scopeNotify(T)(T o, string name, string prop, string slot) {
    qtd_scope_notify(qobjOf(o), (name ~ "\0").ptr, (prop ~ "\0").ptr, (slot ~ "\0").ptr);
}

private extern(C) void qtd_publish_context(const(char)*, void*);
/// Publish `obj` to QML under `name`, as a CONTEXT PROPERTY — the way an application hands QML an
/// object it owns (`theme`, `bible`) rather than a type QML instantiates.
///
/// It may be called before there is a QCoreApplication, which is where a program naturally wants to
/// say it: the name is queued and applied the first time an engine exists. See qtd_publish_context.
void publishContext(T)(string name, T obj) {
    qtd_publish_context((name ~ "\0").ptr, qobjOf(obj));
}

extern(C) void* qtd_make_component(const(char)*, const(char)*, const(char)*, const(char)*);
// The QQmlComponent for a compiled delegate class: `uri`/`typeName` are what the generated code
// registered it as. Returned as an opaque pointer — the caller wraps it in whatever QQmlComponent
// binding its module has, because this unit compiles for bindings that have no QtQml at all.
void* makeComponent(string uri, string typeName, string docUrl = "", string decls = "") {
    return qtd_make_component((uri ~ "\0").ptr, (typeName ~ "\0").ptr, (docUrl ~ "\0").ptr,
                              decls.length ? (decls ~ "\0").ptr : null);
}

/// The QQmlComponent for a delegate whose TYPE this compiler does not bind but the engine knows —
/// a `Shape` from QtQuick.Shapes, say. `uri` is the ';'-separated list of the document's own
/// imports, so the body may name types from any of them; `decls` is the delegate's body verbatim.
///
/// The same containment an engine-built CHILD already uses, applied to a Component: what the view
/// receives is a real QQmlComponent of the engine's own type, not a D shell wrapping one.
void bindComponentText(U)(U owner, string prop, string uri, string typeName,
                          string docUrl, string decls) {
    auto c = makeComponent(uri, typeName, docUrl, decls);
    if (c is null)
        throw new Exception("bindComponentText: no QQmlComponent could be made for '" ~ typeName
                            ~ "' bound to '" ~ prop ~ "'");
    if (!qtd_prop_set_obj(qobjOf(owner), (prop ~ "\0").ptr, c))
        throw new Exception("bindComponentText: property '" ~ prop ~ "' did not take the component for '"
                            ~ typeName ~ "'");
}

extern(C) void* qtd_qml_create_object(const(char)*, const(char)*);
private extern(C) void* qtd_qml_create_object_in(const(char)*, const(char)*, const(char)*, const(char)*, const(char)**, void**, int);
/// An object of a registered QML type that exports no C++ symbol (Qt's DialImpl and friends live in
/// a style plugin): it cannot be SUBCLASSED, but the engine builds it by name and everything after
/// that goes through the meta-object like any other object.
private extern(C) void qtd_dump_path(void*, const(char)*);
/// Dump one object named by a PATH from a root. A document handed to the engine wholesale has no D
/// fields to walk, so its dump is driven by the same path list `--objpaths` hands the oracle.
void dumpPath(void* root, string path) { qtd_dump_path(root, (path ~ "\0").ptr); }

private extern(C) void* qtd_qml_create_document(const(char)*);
/// A WHOLE DOCUMENT built by the engine. The compiler emits this for a document it cannot compile:
/// the object is the engine's and the generated class is a holder, exactly as it already is for a
/// child whose type no subclass can wrap. Returns null (loudly) if the document will not load.
void* createQmlDocument(string docUrl) {
    return qtd_qml_create_document((docUrl ~ "\0").ptr);
}

/// Build `typeName` from whichever of `uris` (a `;`-separated list) the engine can resolve it in.
/// The compiler emits this when its own registry does not know the type at all — `Timer`,
/// `ListModel`, `RowLayout` — because the DOCUMENT'S IMPORTS are what the engine would consult, and
/// which of them defines the type is not something the registry can answer. Trying is exact: the
/// first one that yields an object is the right one, and a type no import defines returns null,
/// which the caller already treats as "the engine could not build it".
/// `decls` is the QML the DOCUMENT declares on this element (`property string target: ""`). It goes
/// to the ENGINE, because the engine owns the object: a property the document adds to a type outside
/// the binding is not on the D shell, it is on the thing every expression actually reads.
private extern(C) bool qtd_list_append_default(void*, void*);
/// Append to the type's OWN default property, read from its meta-object. For a child of a type the
/// engine builds and nothing here binds — a `GradientStop` under a `Gradient` — where no table
/// carries the property's name and a QObject parent puts the child nowhere the type looks.
bool listAppendDefault(P, C)(P parent, C child) {
    return qtd_list_append_default(qobjOf(parent), qobjOf(child));
}

void* createQmlObjectAny(A...)(string uris, string typeName, string docUrl = "", string decls = "",
                               string[] ids = null, A objs = A.init) {
    import std.algorithm : splitter;
    // ONE CALL WITH EVERY IMPORT FIRST. qtd_make_component takes this ';'-separated list and emits
    // an `import` line for each of them, which is exactly what a type whose BODY names a second
    // module needs (a Shape's ShapePath is QtQuick.Shapes while everything around it is QtQuick).
    // Splitting here before calling defeated that: every module but the right one became a FAILED
    // attempt, and each failure prints its own "X is not a type" — so a call that then succeeded
    // left a run looking broken. Found by the fixture for the engine-built paths.
    if (uris.length) if (auto o = createQmlObject(uris, typeName, docUrl, decls, ids, objs)) return o;
    // ...then one at a time, for a type that resolves only under a single import.
    foreach (u; uris.splitter(';')) {
        if (u.length == 0) continue;
        if (auto o = createQmlObject(u.idup, typeName, docUrl, decls, ids, objs)) return o;
    }
    return null;
}

void* createQmlObject(A...)(string uri, string typeName, string docUrl = "", string decls = "",
                            string[] ids = null, A objs = A.init) {
    const(char)*[A.length ? A.length : 1] ns;
    void*[A.length ? A.length : 1] ps;
    static foreach (i, a; objs) {
        ns[i] = (ids[i] ~ "\0").ptr;
        ps[i] = qobjOf(a);
    }
    if (docUrl.length || decls.length || A.length)
        return qtd_qml_create_object_in((uri ~ "\0").ptr, (typeName ~ "\0").ptr,
                                        (docUrl ~ "\0").ptr, (decls ~ "\0").ptr,
                                        ns.ptr, ps.ptr, cast(int) A.length);
    return qtd_qml_create_object((uri ~ "\0").ptr, (typeName ~ "\0").ptr);
}

/// `delegate: Text {}` — a TEMPLATE the type instantiates itself, N times. Registers the compiled
/// delegate class as a QML element and gives `owner.<prop>` a QQmlComponent that builds it, which
/// is the only thing a view accepts. One call, because the two halves are meaningless apart.
void bindComponent(T, U)(U owner, string prop, string docUrl = "", string uri = "qtd.qmltc") {
    qmlRegisterType!T(uri, 1, 0, T.stringof);
    // ...with the DOCUMENT's url: the delegate's context inherits the component's, and a relative
    // `source:` inside a delegate resolves against it. A synthetic url made every such path resolve
    // somewhere else, which is what the differential caught on `baseUrl`.
    // LOUD on both failure modes. A null component silently left the property null, and Qt does not
    // check: QQuickItemLayer::activateEffect() dereferences `effect` the moment `layer.enabled`
    // becomes true, so the outcome was a SEGV three frames away from the cause (measured on Qt's
    // Material ComboBox, gdb).
    auto c = makeComponent(uri, T.stringof, docUrl);   // versionless: Qt 6 takes the latest
    if (c is null) {
        throw new Exception("bindComponent: no QQmlComponent could be made for '" ~ T.stringof
                            ~ "' bound to '" ~ prop ~ "'");
    }
    if (!qtd_prop_set_obj(qobjOf(owner), (prop ~ "\0").ptr, c))
        throw new Exception("bindComponent: property '" ~ prop ~ "' did not take the component for '"
                            ~ T.stringof ~ "'");
}
/// JavaScript's `encodeURIComponent`, which a QML document reaches for whenever it builds a
/// `data:` URL — an inline SVG in an `Image.source` is the shape that brought this in.
///
/// The unreserved set is the one RFC 3986 names and JS keeps: A-Z a-z 0-9 and `-_.!~*'()`.
/// Everything else becomes %XX of its UTF-8 BYTES, which is why this walks the string as bytes and
/// not as characters: `%C3%A1` for `á` is two escapes, and a per-character loop would emit one.
string encodeURIComponentD(string s) @safe {
    static immutable char[16] hex = "0123456789ABCDEF";
    char[] out_;
    out_.reserve(s.length);
    foreach (char c; s) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                || c == '-' || c == '_' || c == '.' || c == '!' || c == '~' || c == '*'
                || c == '\'' || c == '(' || c == ')')
            out_ ~= c;
        else {
            out_ ~= '%';
            out_ ~= hex[(cast(ubyte) c) >> 4];
            out_ ~= hex[(cast(ubyte) c) & 0xF];
        }
    }
    // The array is local and never escapes, so the cast to immutable is sound — but @safe cannot
    // see that, so it is the cast that is trusted rather than the whole loop above it.
    return (() @trusted => cast(string) out_)();
}

/// JavaScript's `parseInt`, which is not `to!int`: it reads the LONGEST NUMERIC PREFIX and ignores
/// the rest, so `parseInt("12px")` is 12 and `to!int` would throw. Leading whitespace, an optional
/// sign and a `0x` prefix (radix 16, as JS does when no radix is given) are all part of it.
///
/// WHERE THIS DIVERGES, said plainly: JS returns NaN when there is no numeric prefix at all, and
/// this returns 0. The two agree wherever the value reaches an `int` property, which is every use in
/// the corpus this was written for — the engine coerces that NaN to 0 on the way in. They differ if
/// the result is read as a string or a `var`: `String(parseInt("x"))` is "NaN" in the engine and "0"
/// here. Returning a NaN-capable double instead would trade that for a cast at every int target.
int parseIntD(string s, int radix = 0) @safe {
    size_t i = 0;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
    bool neg = false;
    if (i < s.length && (s[i] == '+' || s[i] == '-')) { neg = s[i] == '-'; ++i; }
    if (radix == 0) {
        radix = 10;
        if (i + 1 < s.length && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
            radix = 16; i += 2;
        }
    } else if (radix == 16 && i + 1 < s.length && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
        i += 2;
    }
    long v = 0; bool any = false;
    for (; i < s.length; ++i) {
        int d = -1;
        if (s[i] >= '0' && s[i] <= '9') d = s[i] - '0';
        else if (s[i] >= 'a' && s[i] <= 'z') d = s[i] - 'a' + 10;
        else if (s[i] >= 'A' && s[i] <= 'Z') d = s[i] - 'A' + 10;
        if (d < 0 || d >= radix) break;
        v = v * radix + d; any = true;
        if (v > int.max) return neg ? int.min : int.max;
    }
    if (!any) return 0;
    return cast(int) (neg ? -v : v);
}

/// ...and its counterpart, for the same reason.
string decodeURIComponentD(string s) @safe {
    static int nib(char c) @safe {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }
    char[] out_;
    out_.reserve(s.length);
    for (size_t i = 0; i < s.length; ++i) {
        if (s[i] == '%' && i + 2 < s.length) {
            const hi = nib(s[i + 1]), lo = nib(s[i + 2]);
            if (hi >= 0 && lo >= 0) { out_ ~= cast(char) ((hi << 4) | lo); i += 2; continue; }
        }
        out_ ~= s[i];
    }
    // The array is local and never escapes, so the cast to immutable is sound — but @safe cannot
    // see that, so it is the cast that is trusted rather than the whole loop above it.
    return (() @trusted => cast(string) out_)();
}

/// A QML singleton's one instance — the engine's, not one of ours: a singleton has state, and a
/// second instance would be a different object that happens to share a type.
void* qmlSingleton(string uri, string name, int major, int minor) {
    return qtd_qml_singleton((uri ~ "\0").ptr, (name ~ "\0").ptr, major, minor);
}
/// Calls a method by NAME, passing every argument as text and letting QMetaType convert it to the
/// parameter's own type — the same channel the properties use. The result comes back as text for
/// the same reason a colour property does: that is what both sides of the differential compare.
string invokeStr(void* obj, string method, string[] args) {
    auto cs = new const(char)*[args.length];
    foreach (i, a; args) cs[i] = (a ~ "\0").ptr;
    auto q = qtd_invoke_str(obj, (method ~ "\0").ptr, cs.ptr, cast(int) args.length);
    auto r = qsToD(q); qtd_qs_free(q); return r;
}
/// Reads an enum property as its KEY string — the spelling `setProp(o, name, "AlignRight")`
/// takes, so a read and a literal compare directly.
string propEnumKey(T)(T o, string name) {
    auto qs = qtd_prop_get_enum_key(qobjOf(o), (name ~ "\0").ptr);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}
/// Writes a QString property by name (fires the notify, if any).
void setProp(T)(T o, string name, string v) {
    auto r = __writeRecv(o, name);
    if (!qtd_prop_set_qs(r, (name ~ "\0").ptr, v.ptr, cast(int) v.length))
        __propWriteFailed(name, "string", v, qtd_moc_classname(r));
}

private void __propWriteFailed(string name, string ty, string v = "",
                               const(char)* cls = null) {
    // The VALUE and the class, not just the name: a string write also fails when the value does
    // not CONVERT to the property's declared type (an empty colour, say), and the two causes are
    // indistinguishable from the name alone — which cost a bisect through a whole document.
    import std.string : fromStringz;
    throw new Exception("setProp failed: no writable property \"" ~ name ~ "\" taking a " ~ ty
                        ~ (cls ? " on " ~ cast(string) cls.fromStringz.idup : "")
                        ~ (v.length ? " (value \"" ~ v ~ "\")" : " (empty value)")
                        ~ " (an undeclared name would silently have become a dynamic property)");
}

/// Reads/writes a property of ANY registered type through the meta-object, keyed by the type
/// NAME that cppSig already computes. The typed helpers above only reach types with a QString
/// conversion — QColor has one, QSize does not — so these are what make a value-typed property
/// actually usable through the channel rather than only as a D field.
bool setPropVar(T, V)(T o, string name, V v) {
    return qtd_prop_set_var(qobjOf(o), (name ~ "\0").ptr,
                            (cppSig!V ~ "\0").ptr, cast(const(void)*) &v) != 0;
}
/// Returns false when the property is absent or does not convert — which the typed readers
/// cannot distinguish from a zero value.
bool propVar(V, T)(T o, string name, ref V outv) {
    return qtd_prop_get_var(qobjOf(o), (name ~ "\0").ptr,
                            (cppSig!V ~ "\0").ptr, cast(void*) &outv) != 0;
}

/// The target a value source is about to be attached to, published by the parent immediately
/// before constructing it. The object's wire runs inside its CONSTRUCTOR — it sets `running: true`
/// and completes — so attaching afterwards starts an animation with no property to drive. Same
/// handoff as __qmltcOuter, and for the same reason.
void* __qmltcVsTarget;
string __qmltcVsProp;

private extern(C) void* qtd_cast_class(void*, const(char)*);
/// `X as SomeType` inside an expression handed to the engine: the object when it is of that type,
/// null otherwise. The type name cannot travel (a hand-made context has no import namespace), so
/// the compiler passes the object and the C++ class name and the question is answered by walking
/// the meta-object chain — one generic call, no per-type knowledge on either side.
void* castQml(T)(T o, string cxxClass) {
    return qtd_cast_class(qobjOf(o), (cxxClass ~ "\0").ptr);
}

private extern(C) int qtd_attach_value_source(void*, void*, const(char)*);
/// Attaches a property VALUE SOURCE (`NumberAnimation on width`, `Behavior on x`) to its target.
/// One generic interface covers every animation type and Behavior — the caller never has to know
/// which, exactly like a property write never has to know the value type.
bool attachValueSource(S, T)(S src, T target, string prop) {
    return qtd_attach_value_source(qobjOf(src), qobjOf(target), (prop ~ "\0").ptr) != 0;
}

private extern(C) int qtd_has_prop(void*, const(char)*);
/// True when the object's meta-object declares `name` — only an Item has `parent`, so a check can
/// ask instead of assuming.
bool hasProp(T)(T o, string name) { return qtd_has_prop(qobjOf(o), (name ~ "\0").ptr) != 0; }

private extern(C) int qtd_prop_copy(void*, const(char)*, void*, const(char)*);
private extern(C) int qtd_prop_copy_group(void*, const(char)*, const(char)*, void*, const(char)*);

/// Copies a property between objects through the meta-object without naming its type: the
/// QVariant carries it and QMetaType converts on write. This is what makes `font: control.font`
/// or `color: control.palette.text` compile without the generator knowing QFont or QColor.
bool copyProp(S, D)(S src, string sname, D dst, string dname) {
    return qtd_prop_copy(qobjOf(src), (sname ~ "\0").ptr, qobjOf(dst), (dname ~ "\0").ptr) != 0;
}
/// Same, for a member of a value-typed grouped property (`palette.text`).
bool copyGroupProp(S, D)(S src, string group, string member, D dst, string dname) {
    return qtd_prop_copy_group(qobjOf(src), (group ~ "\0").ptr, (member ~ "\0").ptr,
                               qobjOf(dst), (dname ~ "\0").ptr) != 0;
}

/// Drives QQmlParserStatus on a bound type: `classBegin()` before its properties are set and
/// `componentComplete()` once the tree is built, which is what the engine does. A type that does
/// not implement the interface is left untouched.
void classBegin(T)(T o) { attachContext(o); qtd_parser_status(qobjOf(o), 0); }
/// ...and the form that carries the object's DOCUMENT, for a baseUrl a relative URL resolves against.
void classBegin(T)(T o, string docUrl) { attachContext(o, docUrl); qtd_parser_status(qobjOf(o), 0); }

/// Give an object a QQmlContext. Anything that instantiates children through the engine (views,
/// Loader, delegates) reads QQmlContext::engine() in componentComplete() and crashes without one.
private extern(C) void* qtd_scope_promise(void*, const(char)*);
/// A handle for a name this document cannot reach yet.
///
/// QML resolves a bare name up the component scope; a compiled document is one document and cannot
/// name the object that will hold it. Handing the OWNER over fails on timing, not on lookup:
/// bindings are installed as each object is built, bottom-up, and the object that declares the
/// name is not an ancestor yet — a context property's value is captured then, so a null is
/// permanent. This hands over something that exists NOW and fills in later, notifying when it
/// does, so the binding re-evaluates by itself.
void* scopePromise(T)(T o, string prop) {
    return qtd_scope_promise(qobjOf(o), (prop ~ "\0").ptr);
}

private extern(C) void qtd_set_qml_engine(void*);
/// POINT THE RUNTIME AT THE ENGINE YOUR APPLICATION ALREADY HAS.
///
/// A compiled document's contexts and every expression it delegates live in a QQmlEngine. Without
/// this the runtime makes its own — right for a program whose whole interface is compiled, wrong
/// for one that puts compiled documents inside a QQuickView it created, because the view's engine
/// is where the application registered its context properties. A delegated expression in the other
/// engine cannot see them, and says so:
///
///     qtd_run_js: delegated handler on Main_dc7 threw: ReferenceError: bible is not defined
///
/// Call it once, before building the compiled tree:
///
///     useQmlEngine(view.engine());
void useQmlEngine(T)(T engine) { qtd_set_qml_engine(qobjOf(engine)); }

void attachContext(T)(T o) { qtd_attach_context(qobjOf(o)); }
/// ...with the document the object was written in, so its relative URLs resolve like the engine's.
private extern(C) void qtd_attach_context_in(void*, void*, const(char)*);
private extern(C) void qtd_hold_context(void*);
private extern(C) int qtd_has_context(void*);
/// True once the object has a QQmlContext. With the slot held for the engine ([holdContext]) this
/// is the delegate's "the per-item context has arrived" — the condition its body waits on.
bool hasContext(T)(T o) { return qtd_has_context(qobjOf(o)) != 0; }
/// Keeps the context slot free for the ENGINE: a delegate is created by the view, which installs a
/// per-item context on it carrying `index`, `modelData` and the model roles. Attaching the document
/// context in the constructor took that slot and the per-item one never arrived.
void holdContext(T)(T o) { qtd_hold_context(qobjOf(o)); }
/// ...and one nested INSIDE another object's, which is what a delegate's children need: the view
/// publishes `index`, `modelData` and the model roles on the delegate ROOT's context, and a child
/// given the document's context cannot see any of them.
void attachContextIn(T)(T o, void* parent, string docUrl) {
    // `__qmltcOuter` carries the D object, not its QObject — the handoff exists so the child can
    // `cast(Class)` it. Passing it straight to C++ as a QObject* is a segfault (measured), so it
    // goes through the registry like every other D-object-to-QObject step. A parent that is not
    // there falls back to the document context, which is what every object had before.
    void* pq = null;
    if (parent !is null) if (auto e = parent in _reg) pq = e.qobj;
    qtd_attach_context_in(qobjOf(o), pq, docUrl.length ? (docUrl ~ "\0").ptr : null);
}
void attachContext(T)(T o, string docUrl) {
    qtd_attach_context_url(qobjOf(o), docUrl.length ? (docUrl ~ "\0").ptr : null);
}

/// Append a default child through the type's own default list property. `data` on an Item,
/// `flickableData` on a Flickable (which reparents into its contentItem), `contentData` on a
/// Control -- one channel, and each type applies its own rule. Returns false if the property is
/// not an appendable list, so the caller can fall back to plain parenting.
bool listAppend(T, C)(T owner, string prop, C child) {
    import std.string : toStringz;
    return qtd_list_append(qobjOf(owner), prop.toStringz, qobjOf(child)) != 0;
}

/// Import a QML module once, so the types this document uses behave as they do under the engine.
/// A Control's palette comes from the theme its STYLE module installs on import; without it the
/// colours differ from the interpreted document with nothing to show for it.
void ensureModule(string uri) {
    import std.string : toStringz;
    qtd_ensure_module(uri.toStringz);
}

/// Subscribe `recv.slot` to `sig` of the object currently held by `owner.prop`, replacing whatever
/// this (owner, recv, slot, prop, sig) was subscribed to before. Called from the binding's own
/// slot, so a property that changes object re-subscribes instead of staying on the old one.
///
/// The OWNER is part of that identity, and it has to be: the receiving slot is emitted once per
/// binding, so `mid.indicator.width + outer.indicator.width` produced two subscriptions that were
/// identical in every other component. Returns non-zero when the connection was made.
int bindLeaf(T, R)(T owner, string prop, string sig, R recv, string slot) {
    import std.string : toStringz;
    return qtd_bind_leaf(qobjOf(owner), prop.toStringz, sig.toStringz, qobjOf(recv), slot.toStringz);
}

private extern(C) int qtd_bind_leaf_prop(void*, const(char)*, const(char)*, void*, const(char)*);
/// The same subscription as [bindLeaf], for a leaf whose NOTIFY NO STATIC TABLE CAN NAME. Qt's
/// Imagine style writes `background.topPadding` on every control, and `background` is declared as an
/// `Item`, which has no such member: it belongs to the NinePatchImage that is actually assigned. The
/// property name is all the document gives, and the object's own meta-object supplies the signal.
int bindLeafProp(T, R)(T owner, string prop, string leafProp, R recv, string slot) {
    import std.string : toStringz;
    return qtd_bind_leaf_prop(qobjOf(owner), prop.toStringz, leafProp.toStringz,
                              qobjOf(recv), slot.toStringz);
}

private extern(C) int qtd_prop_value_member(void*, const(char)*, const(char)*, double*);
/// Read a MEMBER of a value-typed property — `color.a`, `font.pixelSize`, `size.width`. QColor is
/// neither a QObject nor a Q_GADGET; QML reaches its members through a VALUE TYPE the engine
/// registers per metatype, and that is the channel used here, so what is readable is exactly what
/// QML can read. A member nothing answers to aborts the binding, like every other read that finds
/// nothing: the engine yields `undefined` there and the assignment is refused.
double propValueMember(T)(T o, string prop, string member) {
    import std.string : toStringz;
    double v = 0;
    auto r = __bindRecv(o, prop);
    if (!qtd_prop_value_member(r, prop.toStringz, member.toStringz, &v))
        throw new QmlNullDeref(prop ~ "." ~ member);
    return v;
}

private extern(C) int qtd_prop_has(void*, const(char)*);
/// Read a property THE DECLARED TYPE DOES NOT HAVE, off whatever object is there. Companion to
/// [setPropAny] on the read side, and it needs one thing that one does not: a name the object does
/// not answer to must abort the binding. In JS the read yields `undefined` and the assignment is
/// refused, so the property keeps its default — writing 0 instead would be a value the engine never
/// produces, and it would be invisible, which is worse.
T propAny(T, O)(O o, string name) {
    import std.string : toStringz;
    auto r = __bindRecv(o, name);
    auto z = name.toStringz;
    if (!qtd_prop_has(r, z)) throw new QmlNullDeref(name);
    static if (is(T == double))     return qtd_prop_get_double(r, z);
    else static if (is(T == bool))  return qtd_prop_get_bool(r, z);
    else static if (is(T == int))   return qtd_prop_get_int(r, z);
    else static if (is(T == string)) {
        auto qs = qtd_prop_get_qs(r, z);
        auto s = qsToD(qs); qtd_qs_free(qs); return s;
    } else static assert(false, "propAny: no channel for " ~ T.stringof);
}

/// QT COMPLETES IN REVERSE CREATION ORDER. `QQmlObjectCreator::finalize` keeps every object it
/// built on a STACK and drains it with `pop()`, so the object created LAST gets componentComplete
/// FIRST, and the root — created first — gets it last. We completed each child the moment we created
/// it, which is the opposite for every sibling but the first.
///
/// It is observable. Qt's DelayButton holds two ClippedText siblings in an ItemGroup; a Text freezes
/// its `baselineOffset` at its FIRST layout and never recomputes it on a later resize. Completing
/// the first child while the group is still 0 high lays it out at height 0 (ascent - height/2 =
/// 5.34375) where the engine has the ascent itself (14.84375), and the second child — appended into
/// a group that already has a height — gets the right one. Both sides freeze one child in each state
/// and disagree about which.
///
/// `mark`/`drain` rather than one global list, because a document can build another: the inner build
/// must drain only what IT created, exactly as the engine gives each component its own creator.
private void*[] __qmltcPending;
/// Where the current build's objects start. Take it before building, pass it to [drainComplete].
size_t completeMark() { return __qmltcPending.length; }
/// Queue `o` for completion instead of completing it now.
void deferComplete(T)(T o) { __qmltcPending ~= qobjOf(o); }
/// Complete everything queued since `mark`, newest first, and forget it.
void drainComplete(size_t mark) {
    for (size_t i = __qmltcPending.length; i > mark; --i)
        qtd_parser_status(__qmltcPending[i - 1], 1);
    __qmltcPending.length = mark;
    __qmltcPending.assumeSafeAppend();
}

private extern(C) int qtd_deferred_index(void*, const(char)*);
private struct __Deferred { void* owner; string prop; int rank; void delegate() build; }
private __Deferred[] __qmltcDeferred;

/// Build the child bound to `prop` — NOW, or at the owner's own completion if QT DEFERS that
/// property. Which properties those are is in the META-OBJECT and nowhere else: it is not in
/// plugins.qmltypes, so no registry carries it, and a hard-coded "background, contentItem,
/// indicator" would be the per-type mechanism this project keeps refusing. The object is asked.
///
/// A property nothing defers takes the immediate branch, which is what every document compiled to
/// before this existed.
void buildProp(T)(T owner, string prop, void delegate() build) {
    import std.string : toStringz;
    auto q = qobjOf(owner);
    int rank = q is null ? -1 : qtd_deferred_index(q, prop.toStringz);
    if (rank < 0) { build(); return; }
    __qmltcDeferred ~= __Deferred(q, prop, rank, build);
}

/// READING A DEFERRED PROPERTY BUILDS IT. Qt's deferred pointer does this — the getter executes
/// what was held — and Qt's own QML depends on it: `contentWidth: contentItem.contentWidth` in
/// Basic's DialogButtonBox is evaluated while the contentItem is still unbuilt, and under the engine
/// that read is what brings it into existence. Held back, the read finds null, the binding aborts
/// and the property keeps its default of -1 where the engine has 0.
/// Returns true when something was built, so the caller can read again.
private bool __forceDeferred(void* owner, string prop) {
    foreach (i, d; __qmltcDeferred) {
        if (d.owner !is owner || d.prop != prop) continue;
        auto build = d.build;
        __qmltcDeferred = __qmltcDeferred[0 .. i] ~ __qmltcDeferred[i + 1 .. $];
        auto m = completeMark();
        build();
        drainComplete(m);
        return true;
    }
    return false;
}

/// Build what was held for this object, in the order its meta-object puts them, each child complete
/// before the next is built — and all of them before the OWNER completes, which is the whole point:
/// QQuickControl::componentComplete builds background and contentItem and only then resizes them, so
/// a Text that measures itself here does so at its natural size, exactly as under the engine.
void runDeferred(T)(T owner) {
    if (__qmltcDeferred.length == 0) return;
    auto q = qobjOf(owner);
    if (q is null) return;
    __Deferred[] mine;
    size_t keep = 0;
    foreach (d; __qmltcDeferred) {
        if (d.owner is q) mine ~= d;
        else __qmltcDeferred[keep++] = d;
    }
    __qmltcDeferred.length = keep;
    if (mine.length == 0) return;
    import std.algorithm : sort;
    mine.sort!((a, b) => a.rank < b.rank);
    // EACH ONE COMPLETE BEFORE THE NEXT IS BUILT, which is what Qt's quickCompleteDeferred does and
    // the whole reason for deferring: a contentItem measured here is measured at its natural size,
    // and the owner stretches it only afterwards. Its own mark/drain, so the subtree it builds
    // completes with it rather than waiting for the owner's drain — by then the owner has resized it.
    foreach (d; mine) {
        auto m = completeMark();
        d.build();
        drainComplete(m);
    }
}

private extern(C) int qtd_connect_by_name(void*, const(char)*, void*, const(char)*);
/// Connect a signal found by NAME on whatever object is there, to a parameterless slot. A child the
/// ENGINE builds can be of a type our registry never heard of, so `onTriggered` on a `Timer` has no
/// signature to connect with — and QML names a handler after the signal and nothing else, so the
/// name is all there is and all that is needed: the meta-object supplies the rest. Returns non-zero
/// when the connection was made; a name no signal answers to returns 0 rather than throwing,
/// because the handler is then simply not wired and the level demotes the document.
int connectMetaByName(T, R)(T sndr, string signalName, R recv, string slot) {
    import std.string : toStringz;
    return qtd_connect_by_name(qobjOf(sndr), signalName.toStringz, qobjOf(recv), slot.toStringz);
}

/// Connect `owner.prop`'s NOTIFY to `recv.slot`, so a binding that reads through an object property
/// re-evaluates when that property is assigned — a root's `parent` is null while its ctor runs.
void connectNotify(T, R)(T owner, string prop, R recv, string slot) {
    import std.string : toStringz;
    qtd_connect_notify(qobjOf(owner), prop.toStringz, qobjOf(recv), slot.toStringz);
}
void componentComplete(T)(T o) { qtd_parser_status(qobjOf(o), 1); }
private extern(C) void qtd_component_finalized(void*);
/// The THIRD phase, after every componentComplete in the tree: QQmlFinalizerHook. A QQuickTableView
/// computes nothing until it gets this — its rows, columns and content size all stay at -1 — and no
/// number of componentComplete calls stands in for it. A type that does not implement the hook is
/// left untouched, and Qt5 has no such phase at all.
void componentFinalized(T)(T o) { qtd_component_finalized(qobjOf(o)); }

// ---- value-type ("gadget") grouped properties --------------------------------
// `vt.count` where `vt` is a Q_GADGET-valued property: there is no object to reach, so a read
// extracts the member from the VALUE and a write is read-modify-write-back. Writing through
// propObj (the QObject-group path) would dereference null; keeping these separate is what makes
// that a compile-time choice rather than a crash.
int vgroupInt(T)(T o, string g, string m) {
    return qtd_vgroup_get_int(qobjOf(o), (g ~ "\0").ptr, (m ~ "\0").ptr);
}
double vgroupDouble(T)(T o, string g, string m) {
    return qtd_vgroup_get_double(qobjOf(o), (g ~ "\0").ptr, (m ~ "\0").ptr);
}
bool vgroupBool(T)(T o, string g, string m) {
    return qtd_vgroup_get_bool(qobjOf(o), (g ~ "\0").ptr, (m ~ "\0").ptr);
}
string vgroupStr(T)(T o, string g, string m) {
    auto qs = qtd_vgroup_get_qs(qobjOf(o), (g ~ "\0").ptr, (m ~ "\0").ptr);
    auto r = qsToD(qs); qtd_qs_free(qs); return r;
}
// The member is resolved BY NAME through the gadget's meta-object, so a name that does not exist
// is not a compile error — it has to fail loudly here, or the assignment is silently dropped and
// the object keeps a default that looks deliberate.
private void __vgroupWriteFailed(string g, string m) {
    throw new Exception("setVgroup failed: no member \"" ~ m ~ "\" on value group \"" ~ g
                        ~ "\" (or it does not convert)");
}
void setVgroup(T)(T o, string g, string m, int v) {
    if (!qtd_vgroup_set_int(qobjOf(o), (g ~ "\0").ptr, (m ~ "\0").ptr, v)) __vgroupWriteFailed(g, m);
}
void setVgroup(T)(T o, string g, string m, double v) {
    if (!qtd_vgroup_set_double(qobjOf(o), (g ~ "\0").ptr, (m ~ "\0").ptr, v)) __vgroupWriteFailed(g, m);
}
void setVgroup(T)(T o, string g, string m, bool v) {
    if (!qtd_vgroup_set_bool(qobjOf(o), (g ~ "\0").ptr, (m ~ "\0").ptr, v)) __vgroupWriteFailed(g, m);
}
void setVgroup(T)(T o, string g, string m, string v) {
    if (!qtd_vgroup_set_qs(qobjOf(o), (g ~ "\0").ptr, (m ~ "\0").ptr, v.ptr, cast(int) v.length))
        __vgroupWriteFailed(g, m);
}

// ---- connection -------------------------------------------------------------
/// Connects signal->slot by signature ("valueChanged(int)"). Symmetric: each
/// end can be a D @QObject or a raw built-in QObject (void*), in any
/// combination — both have a meta-object.
void connectMeta(A, B)(A sender, string sig, B receiver, string slot) {
    if (!tryConnectMeta(sender, sig, receiver, slot))
        throw new Exception("connectMeta failed: no such signal \"" ~ sig ~ "\" or slot \""
                            ~ slot ~ "\" (or a null endpoint)");
}

/// Same, but reports failure instead of throwing — for callers that legitimately probe.
bool tryConnectMeta(A, B)(A sender, string sig, B receiver, string slot) {
    return qtd_connect_meta(qobjOf(sender), (sig ~ "\0").ptr,
                            qobjOf(receiver), (slot ~ "\0").ptr) != 0;
}

/// Type-checked connect between two D @QObjects, by MEMBER NAME rather than by signature string:
///
///     connect!("valueChanged", "setValue")(src, dst);
///
/// The signature strings are still what reaches Qt — this builds them at compile time from the
/// actual declarations, so a misspelled name or a slot that cannot take the signal's arguments is
/// a build error instead of a runtime throw. The string form (connectMeta) stays: generated code
/// resolves names that have no D symbol to point at, which is exactly the case qmltc-d is in.
///
/// An OVERLOADED slot needs no disambiguation here: the overload is selected by the signal's own
/// parameter types, so `connect!("withInt", "toggle")` and `connect!("withBool", "toggle")` each
/// pick the right `toggle`. Qt's pointer-to-member form needs qOverload for this.
template connect(string signalName, string slotName) {
    void connect(S, R)(S sender, R receiver) {
        static assert(__traits(hasMember, S, signalName),
            "qtmoc: " ~ S.stringof ~ " has no member '" ~ signalName ~ "'");
        alias SigField = typeof(__traits(getMember, S, signalName));
        static assert(is(SigField == Signal!A, A...),
            "qtmoc: " ~ S.stringof ~ "." ~ signalName ~ " is not a Signal");
        static if (is(SigField == Signal!A, A...)) {
            static assert(__traits(hasMember, R, slotName),
                "qtmoc: " ~ R.stringof ~ " has no member '" ~ slotName ~ "'");
            // Pick the overload whose parameters are exactly the signal's. Qt also allows a slot
            // to take FEWER arguments, but an exact match is the only one that cannot silently
            // read the wrong thing, so that is what is offered until the shorter forms are tested.
            alias Ovls = __traits(getOverloads, R, slotName);
            enum matches(alias f) = is(Parameters!f == A);
            alias Picked = Filter!(matches, Ovls);
            static assert(Picked.length != 0,
                "qtmoc: no overload of " ~ R.stringof ~ "." ~ slotName ~ " takes ("
                ~ A.stringof ~ "), which is what " ~ S.stringof ~ "." ~ signalName ~ " emits");
            static assert(Picked.length == 1,
                "qtmoc: " ~ R.stringof ~ "." ~ slotName ~ " has several overloads taking ("
                ~ A.stringof ~ ")");
            static assert(hasUDA!(Picked[0], Slot),
                "qtmoc: " ~ R.stringof ~ "." ~ slotName ~ " is not marked @Slot, so it is not in "
                ~ "the meta-object and nothing could be connected to it");
            connectMeta(sender, sigString!(signalName, A), receiver, sigString!(slotName, A));
        }
    }
}
