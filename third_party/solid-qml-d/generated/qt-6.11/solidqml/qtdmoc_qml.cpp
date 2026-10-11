// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// QMLTC RUNTIME (critics r9 #2 / r11 #5) — the first code across the boundary the audit has asked
// for since round 9.
//
// `qtdmoc.cpp` is the SHARED meta-object runtime, compiled into every binding including the ones
// with no QtQml at all, and half of its exported functions exist only for compiled QML documents.
// That is what the audit meant by a QML compiler's "estado e lifecycle" living in the base product.
// This unit is where that half goes, one batch at a time.
//
// The criterion for this batch, and it is measurable: an exported function that touches
// QQml/QQuick, depends on NO file-scope state and NO helper defined in qtdmoc.cpp, and whose block
// is preprocessor-BALANCED on its own. The last clause is not pedantry — it is the thing that broke
// the first attempt. `qtd_attach_value_source` is written as two definitions (`#ifdef` … `#else` …
// `#endif`), a per-function scan took the first half, and qtdmoc.cpp was left one `#endif` deep:
// broken in a way only the compiler sees. It stays behind until it is moved WITH its twin.
//
// SECOND BATCH: the LEAF TABLE and everything that touches it. This one is not extraction, it is
// the decision the audit said each shared table needs — and for this table the answer is easy once
// asked: `g_leafConn` exists so that a compiled document's deep binding can re-subscribe when the
// object behind a property changes. Nothing outside QML has a deep binding. Measured before moving:
// no function outside the cluster calls `qtd_leaf_forget`, `qtd_leaf_watch` or `qtd_leaf_key`, so
// the table travels WITH its five functions and the shared unit loses the state, not just the code.
//
// What is still in the shared unit: the functions around `qtd_qml_engine()` (the engine singleton,
// nine of them) and `g_moAttach`, which is genuinely shared — the moc runtime uses it for
// D-defined QObjects with no QML anywhere.
//
// The whole file is QTD_HAVE_QML-guarded, so a binding without QtQml compiles it to nothing rather
// than failing to compile it — the shape `qtmoc-probe-noqml` already guards for the shared unit.

#include <QtCore/QObject>
#include <QtCore/QMetaObject>
#include <QtCore/QMetaProperty>
#include <QtCore/QVariant>
#include <QtCore/QString>
#include <QtCore/QStringList>
#include <QtCore/QList>
#include <QtCore/QUrl>
#include <unordered_map>
#include <vector>
#include <mutex>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>

#if defined(QTD_ENABLE_QML)
#  if __has_include(<QtQml/QQmlEngine>)
#    define QTD_HAVE_QML 1
#  endif
#endif

#ifdef QTD_HAVE_QML
#include <QtQml/QQmlEngine>
#include <QtQml/QQmlContext>
#include <QtQml/private/qqmldata_p.h>
#include <QtCore/private/qmetaobjectbuilder_p.h>
#include <QtCore/QPointer>
#include <QtCore/QTimer>
#include <QtCore/QCoreApplication>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlProperty>
#include <QtQml/QQmlExpression>
#include <QtQml/QQmlListReference>
#include <QtQml/QQmlParserStatus>
#include <QtQml/QJSValue>
#include <QtQml/QQmlPropertyMap>
#endif

// One helper from the shared unit, taken through the C ABI rather than by including anything: the
// object-path walk needs a property read, and `qtd_prop_get_obj` is already an exported symbol. A
// forward declaration is the whole dependency, which is what makes this a boundary and not a split.
extern "C" void* qtd_prop_get_obj(void* o, const char* n);

extern "C" void* qtd_context_object(void* o) {
#ifdef QTD_HAVE_QML
    if (!o) return nullptr;
    // ...found by walking UP, which is what `contextProperty` does implicitly and what a delegate's
    // CHILD needs: its own context nests inside the delegate root's and carries no object of its
    // own, so asking only the nearest one would answer null and the notify would never connect.
    for (QQmlContext* c = qmlContext(static_cast<QObject*>(o)); c; c = c->parentContext())
        if (QObject* co = c->contextObject()) return co;
    return nullptr;
#else
    (void) o; return nullptr;
#endif
}

// A CONTEXT READ ON A DYING OBJECT IS A CRASH, not an empty answer. `~QQuickItem` calls
// setParentItem(nullptr), which emits parentChanged, which runs a recompute slot of ours, which
// asked the object's QML context for a name — and by then QQmlContextData has been torn down:
//     #0 QQmlContextData::initPropertyNames()
//     #1 QQmlContext::contextProperty(QString const&)
//     ...
//     #10 QQuickItem::setParentItem(QQuickItem*)
//     #11 QQuickItem::~QQuickItem()
// gdb on the reader, in the frame that matters. Qt marks the object the moment deletion starts and
// asks this question itself everywhere it touches QML data on a QObject; so do we. A destroyed
// object's binding has nothing to compute, so refusing to read is also the right ANSWER.
#ifdef QTD_HAVE_QML
static QQmlContext* qtd_live_context(void* o) {
    if (!o) return nullptr;
    QObject* obj = static_cast<QObject*>(o);
    if (QQmlData::wasDeleted(obj)) return nullptr;
    QQmlContext* c = qmlContext(obj);
    // ...and the CONTEXT can die before the object does, which is the case that actually crashed: a
    // delegate's per-item context is released by the view while `~QQuickItem` is still running, so
    // the object is not yet marked deleted and its context is already unusable. isValid() is Qt's
    // own word for it and it is public.
    return c && c->isValid() ? c : nullptr;
}
#endif

extern "C" int qtd_context_prop_int(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    if (!o || !name) return 0;
    if (QQmlContext* c = qtd_live_context(o))
        return c->contextProperty(QString::fromUtf8(name)).toInt();
    return 0;
#else
    (void) o; (void) name; return 0;
#endif
}

extern "C" double qtd_context_prop_double(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    if (!o || !name) return 0;
    if (QQmlContext* c = qtd_live_context(o))
        return c->contextProperty(QString::fromUtf8(name)).toDouble();
    return 0;
#else
    (void) o; (void) name; return 0;
#endif
}

extern "C" void* qtd_context_prop_qs(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    if (o && name)
        if (QQmlContext* c = qtd_live_context(o))
            return new QString(c->contextProperty(QString::fromUtf8(name)).toString());
#else
    (void) o; (void) name;
#endif
    return new QString();
}

// A HANDLER BODY THE COMPILER COULD NOT COMPILE, run by the engine when the signal fires.
//
// The sibling below (qtd_bind_js) delegates an EXPRESSION and keeps it live; a handler body needs
// neither liveness nor a value — it needs to run once, in a scope the compiler does not have. That
// scope is the whole point: QML resolves a name up the CONTEXT CHAIN, so a component's body can
// name an id belonging to the document that instantiated it. Measured on a real reader:
//
//     // Leaf.qml, which declares no `root` and no `toggleSelection`
//     onClicked: root.toggleSelection(verse.number)
//
// `root` is Main.qml's id, reachable only because the engine gave this object a context whose
// parent is Main's. The compiler compiles each document alone and cannot know that; the engine
// does not have to know it, it just looks the name up where it already is.
//
// Wrapped in a function so a BLOCK body (`{ a(); b() }`) and a bare expression are the same thing
// to QQmlExpression, which otherwise parses only the second.
// ...WITH THE NAMES THE BODY NEEDS, exactly as a delegated binding gets them. A handler delegated
// on an object the ENGINE built is evaluated in that object's own context, and the ids of the
// document it was written in are not in it: `onTriggered: root.grabToImage(...)` answered
// `ReferenceError: root is not defined`, 598 times, while the timer fired correctly.
extern "C" int qtd_run_js(void* o, const char* src, const char** names, void** objs, int n) {
#ifdef QTD_HAVE_QML
    if (!o || !src) return 0;
    QObject* obj = static_cast<QObject*>(o);
    QQmlContext* base = qmlContext(obj);
    if (!base) {
        std::fprintf(stderr, "qtd_run_js: %s has no QQmlContext — handler not run\n",
                     obj->metaObject()->className());
        return 0;
    }
    QQmlContext* ctx = base;
    if (n > 0) {
        ctx = new QQmlContext(base, obj);   // owned by the object, like the engine's per-item one
        for (int i = 0; i < n; ++i)
            if (names[i])
                ctx->setContextProperty(QString::fromUtf8(names[i]),
                                        static_cast<QObject*>(objs[i]));
    }
    QQmlExpression e(ctx, obj, QString("(function(){ ") + QString::fromUtf8(src) + "\n})()");
    e.evaluate();
    if (e.hasError()) {
        // LOUD, for the same reason the delegated binding is: a handler that silently does nothing
        // is indistinguishable from one that was never connected.
        std::fprintf(stderr, "qtd_run_js: delegated handler on %s threw: %s\n",
                     obj->metaObject()->className(), qPrintable(e.error().toString()));
        return 0;
    }
    return 1;
#else
    (void) o; (void) src; (void) names; (void) objs; (void) n; return 0;
#endif
}

// A QVariant THE CALLEE OWNS. The generated method has no access to the metacall's return slot —
// it is a plain D method that returns a value — so it makes one of these, the engine writes the
// result into it, and callSlot copies it into the slot Qt reserved and frees this one. Three
// functions rather than threading `args[0]` through a signature the meta-object also reads.
extern "C" void* qtd_var_new() { return new QVariant(); }
extern "C" void qtd_var_assign(void* dst, void* src) {
    if (dst && src) *static_cast<QVariant*>(dst) = *static_cast<QVariant*>(src);
}
extern "C" void qtd_var_free(void* v) { delete static_cast<QVariant*>(v); }

// RUN A QML FUNCTION IN THE ENGINE, WITH ITS ARGUMENTS AND ITS RESULT.
//
// A QML function whose parameters carry no type annotation is JavaScript, and guessing a type for
// a parameter is how `f(x, y) { return x + y }` becomes numeric addition and starts being wrong
// the moment it is called with strings. So the compiler refuses to compile one — and then emitted
// it nowhere, which made it callable from neither side: the engine answered `Property 'X' of
// object … is not a function` about a function the document declares (bugs.md #9, criterion 4).
//
// The engine can run it. What was missing is a crossing for the ARGUMENTS: QVariant, in both
// directions, because it is what Qt's meta-object already carries for an untyped value and what
// QJSEngine converts to and from without deciding anything. Nothing here interprets a value; the
// types stay the document's.
//
// The source is the WHOLE function — `function f(a, b) { … }` — evaluated once to obtain the JS
// function object, then called. Evaluating a bare body would lose the parameter names.
// ...AND THE NAMES ITS BODY READS. A function handed to the engine is evaluated in the object's
// own context, and the ids of the document it was written in are not names there: a body that says
// `root.seen = …` answered `ReferenceError: root is not defined`. Same handover a delegated binding
// and a delegated handler already get, for the same reason.
extern "C" int qtd_call_js(void* o, const char* src, const char** names, void** objs, int nn,
                           void** args, int n, void* ret) {
#ifdef QTD_HAVE_QML
    if (!o || !src) return 0;
    QObject* obj = static_cast<QObject*>(o);
    QQmlContext* ctx = qmlContext(obj);
    if (ctx && nn > 0) {
        ctx = new QQmlContext(ctx, obj);   // owned by the object, like the engine's per-item one
        for (int i = 0; i < nn; ++i)
            if (names[i])
                ctx->setContextProperty(QString::fromUtf8(names[i]),
                                        static_cast<QObject*>(objs[i]));
    }
    QQmlEngine* eng = ctx ? ctx->engine() : nullptr;
    if (!ctx || !eng) {
        std::fprintf(stderr, "qtd_call_js: %s has no QQmlContext — '%s' not called\n",
                     obj->metaObject()->className(), src);
        return 0;
    }
    // `(<source>)` so a function DECLARATION reads as an expression and yields the function.
    QQmlExpression e(ctx, obj, QString("(") + QString::fromUtf8(src) + ")");
    QVariant fnv = e.evaluate();
    if (e.hasError()) {
        std::fprintf(stderr, "qtd_call_js: '%s' on %s did not compile: %s\n", src,
                     obj->metaObject()->className(), qPrintable(e.error().description()));
        return 0;
    }
    QJSValue fn = eng->toScriptValue(fnv);
    if (!fn.isCallable()) {
        std::fprintf(stderr, "qtd_call_js: '%s' on %s did not evaluate to a function\n", src,
                     obj->metaObject()->className());
        return 0;
    }
    QJSValueList argv;
    argv.reserve(n);
    for (int i = 0; i < n; ++i)
        argv << eng->toScriptValue(args && args[i] ? *static_cast<QVariant*>(args[i]) : QVariant());
    QJSValue r = fn.call(argv);
    if (r.isError()) {
        // LOUD, like the delegated binding beside it: a call that silently returns nothing is
        // indistinguishable from one that was never made.
        std::fprintf(stderr, "qtd_call_js: '%s' on %s threw: %s\n", src,
                     obj->metaObject()->className(), qPrintable(r.toString()));
        return 0;
    }
    if (ret) *static_cast<QVariant*>(ret) = r.toVariant();
    return 1;
#else
    (void) o; (void) src; (void) names; (void) objs; (void) nn;
    (void) args; (void) n; (void) ret; return 0;
#endif
}

// A PROMISE FOR A NAME THAT IS NOT REACHABLE YET.
//
// QML resolves a bare name up the component scope — ultimately the root of the document that
// instantiated this one — and a compiled document is one document: `Settings.qml` writing
// `color: theme.paper` names something declared in `Main.qml` that the compiler cannot see.
//
// Handing the OWNER over does not work, and the reason is timing rather than lookup. Bindings are
// installed in each object's late phase as it is built, bottom-up; when a nested object installs
// its own, the object that declares the name is not its ancestor yet. A context property's value
// is captured at that moment, so a null there is permanent. Measured: 105 of 125 delegated
// bindings answered `Cannot read property 'X' of null`.
//
// So what is handed over is a QQmlPropertyMap — a QObject that exists NOW and whose contents
// arrive later, and which notifies when they do, so the binding re-evaluates by itself. The
// alternative that does not work is worth recording beside this one: giving the expression an
// extra QQmlContext with the root as its context object costs the import namespace and with it
// every type name (`ReferenceError: Shape is not defined`, seven of them).
#ifdef QTD_HAVE_QML
namespace {
// WHAT KEEPS A RESOLVED NAME ALIVE AFTER IT RESOLVES.
//
// The map holds a VALUE, read once when the promise resolved. When the value is an OBJECT that is
// enough — reads go through the object and its own notifies still fire. When it is a plain value it
// was a SNAPSHOT, and this is the gap that left: measured with a list replaced 60 ms in, the
// qualified read followed the engine to 3 while the bare one stayed at the 1 it had resolved to.
// A read that is right at startup and wrong ever after is worse than one that is always wrong,
// because nothing about it looks broken.
//
// Refreshing it means hearing the owner's NOTIFY, and hearing a signal means being a receiver with
// a SLOT — which this runtime has no moc to declare. It does not need one: a meta-object is data,
// QMetaObjectBuilder builds it, and qt_metacall dispatches it. That is the same channel qtdmoc.cpp
// already puts D slots on; this is one slot, built once, shared by every watch.
class QtdScopeWatch : public QObject {
public:
    QtdScopeWatch(QQmlPropertyMap* map, QObject* owner, const QByteArray& prop)
        : QObject(map), m_map(map), m_owner(owner), m_prop(prop) {}

    static const QMetaObject* mo() {
        static const QMetaObject* m = [] {
            QMetaObjectBuilder b;
            b.setClassName("QtdScopeWatch");
            b.setSuperClass(&QObject::staticMetaObject);
            b.addSlot("refresh()");
            return b.toMetaObject();
        }();
        return m;
    }

    const QMetaObject* metaObject() const override { return mo(); }
    void* qt_metacast(const char* n) override {
        if (n && std::strcmp(n, "QtdScopeWatch") == 0) return this;
        return QObject::qt_metacast(n);
    }
    int qt_metacall(QMetaObject::Call c, int id, void** a) override {
        id = QObject::qt_metacall(c, id, a);
        if (id < 0) return id;
        if (c == QMetaObject::InvokeMetaMethod) {
            if (id == 0) refresh();
            id -= 1;
        }
        return id;
    }
    void refresh() {
        if (!m_owner || !m_map) return;
        m_map->insert(QString::fromUtf8(m_prop), m_owner->property(m_prop.constData()));
    }
private:
    QQmlPropertyMap* m_map;
    QPointer<QObject> m_owner;      // the owner may be destroyed before the asker
    QByteArray m_prop;
};

// Hear `prop` changing on `owner`, and re-read it into `map`. Returns false when there is nothing
// to hear — a context property, or a property declared with no NOTIFY — which is not a failure:
// the engine cannot see those change either, and the snapshot is then the whole truth.
static bool qtd_watch_scope(QQmlPropertyMap* map, QObject* owner, const QByteArray& prop) {
    if (!map || !owner) return false;
    const QMetaObject* omo = owner->metaObject();
    const int pi = omo->indexOfProperty(prop.constData());
    if (pi < 0) return false;
    const QMetaMethod notify = omo->property(pi).notifySignal();
    if (!notify.isValid()) return false;
    auto* w = new QtdScopeWatch(map, owner, prop);
    const QMetaObject* wmo = QtdScopeWatch::mo();
    const int si = wmo->indexOfSlot("refresh()");
    if (si < 0) { delete w; return false; }
    return QObject::connect(owner, notify, w, wmo->method(si)) ? true : false;
}

struct QtdPromise { QQmlPropertyMap* map; QObject* obj; QByteArray prop; };
}
static QList<QtdPromise>& qtd_promises() { static QList<QtdPromise> v; return v; }

// ONE STEP UP THE SCOPE CHAIN, WHICH IS NOT `QObject::parent()`.
//
// A document this compiler compiled attaches a child by writing its `parent` PROPERTY — that is
// what the QML source says and what the differential asserts. For a QQuickItem `parent` is the
// VISUAL parent, and `QQuickItem::setParentItem` does not set the QObject parent, so a compiled
// tree that is fully built has `QObject::parent() == nullptr` at every level. The walk above was
// therefore standing still: measured on the two-deep fixture below, `0 ancestors` after all 32
// retries, on an object whose visual grandparent declared the very name being asked for.
//
// It never showed up as a refusal. The promise simply stayed unresolved, its property map kept no
// key, and JS read `undefined` — so `items.length` was `undefined` (written into an `int` as 0) and
// `items.length === 0` was FALSE at the same instant, on the same object, in the same pass. Two
// reads of one name disagreeing is what a missing key looks like from the JS side, and it is why
// this was reported as a Repeater that iterates while its empty-check also fires: the qualified
// read went to the object and the bare one to the map.
//
// So: the QObject parent when there is one — it is the stronger relationship and non-visual objects
// have only that — and otherwise whatever the object's own `parent` property names. Asking the
// meta-object keeps this generic: any type that declares `parent` answers, and QQuickItem is only
// the one that made it visible.
static QObject* qtd_scope_up(QObject* o) {
    if (!o) return nullptr;
    if (QObject* p = o->parent()) return p;
    const QMetaObject* mo = o->metaObject();
    const int pi = mo->indexOfProperty("parent");
    if (pi < 0) return nullptr;
    const QVariant v = mo->property(pi).read(o);
    if (!v.canConvert<QObject*>()) return nullptr;
    QObject* p = v.value<QObject*>();
    return p == o ? nullptr : p;
}

// WHO ANSWERS A NAME THIS DOCUMENT DOES NOT DECLARE. The first version of this walked `parent()`
// looking for an object carrying the property, which is a guess about where QML keeps such names —
// and the wrong one. It found nothing for `theme`, the promise stayed empty, and 298 bindings
// answered `Cannot read property 'ink' of undefined`: `theme` is a CONTEXT property, set on the
// engine's root context, and no ancestor OBJECT has ever heard of it.
//
// QML already has the answer and it is one call. QQmlContext::contextProperty walks the context
// chain — each context's own properties, then its context object's — which is exactly the scope
// lookup the engine performs for a bare name. So it is asked, rather than imitated. The parent walk
// stays behind it for the case a context cannot serve: an object built outside any engine.
// `ownerOut`, when given, receives the ancestor OBJECT the name was read from — the one whose
// NOTIFY can keep the answer current. It stays null for a context property, which has none.
static bool qtd_resolve_scope(QObject* from, const QByteArray& prop, QVariant& out,
                              QObject** ownerOut = nullptr) {
    if (ownerOut) *ownerOut = nullptr;
    if (QQmlContext* ctx = qmlContext(from)) {
        const QVariant v = ctx->contextProperty(QString::fromUtf8(prop));
        if (v.isValid()) { out = v; return true; }
    }
    // ...AND UP THE OBJECT TREE, asking each ancestor's CONTEXT before asking the ancestor itself.
    //
    // The context above answers names the document's own chain knows, and for a document this
    // compiler compiled on its own that chain stops at the engine's root: the context is made in
    // the object's CONSTRUCTOR, when it has no parent yet, so it is hung off the root rather than
    // nested under the context of whoever creates it. The creating document's own names — the nine
    // `chosen`, `active`, `region`, `place` … measured on a real application — live in a context
    // that is nowhere in that chain.
    //
    // Walking the objects reaches it once the tree exists, which is why the drain retries rather
    // than answering once: at construction there is no parent to walk to. Asking the ancestor's
    // CONTEXT and not merely the ancestor covers the case the parent walk alone never could — the
    // owner is a context property of an enclosing document, not a property of any object above.
    // Bounded: the step is a PROPERTY read now, and a property can name anything, including a cycle
    // the ownership tree could not have contained.
    int hops = 0;
    for (QObject* p = qtd_scope_up(from); p && hops < 256; p = qtd_scope_up(p), ++hops) {
        if (QQmlContext* pc = qmlContext(p)) {
            const QVariant v = pc->contextProperty(QString::fromUtf8(prop));
            if (v.isValid()) { out = v; return true; }
        }
        const QMetaObject* mo = p->metaObject();
        if (mo->indexOfProperty(prop.constData()) >= 0 || p->dynamicPropertyNames().contains(prop)) {
            out = p->property(prop.constData());
            if (ownerOut) *ownerOut = p;
            return true;
        }
    }
    return false;
}

// Try every promise that is still waiting. Idempotent and cheap — the list only holds names that
// have not resolved — and called from every finalization, because the object that will answer may
// be finalized after the one that asked.
static int g_promiseRetries = 0;   // consecutive drains that resolved nothing
static bool g_promiseRetryArmed = false;
static void qtd_drain_promises();
static void qtd_drain_scope_conns();   // the compiled reads waiting on the same names, below
static void qtd_drain_promises() {
    auto& v = qtd_promises();
    for (int i = 0; i < v.size();) {
        QVariant val; QObject* owner = nullptr;
        if (!v[i].obj || !qtd_resolve_scope(v[i].obj, v[i].prop, val, &owner)) { ++i; continue; }
        const QByteArray prop = v[i].prop;
        QQmlPropertyMap* map = v[i].map;
        // WHAT IS STORED, AND WHAT THAT MEANS LATER. The value is read once, here. When it is an
        // OBJECT — which is what a palette published from D is — every read through it stays live,
        // because the reads go to the object and its own notifies still fire. When it is a plain
        // value it is a snapshot, and a later change does not reach the binding: refreshing it
        // would mean connecting the owner's NOTIFY to a slot, and this runtime has no moc to
        // declare one on a QQmlPropertyMap. Said here rather than discovered later.
        if (qEnvironmentVariableIsSet("QTD_PROMISE_DEBUG"))
            fprintf(stderr, "qtd_scope_promise: '%s' <- %s (valid=%d, null=%d)\n", prop.constData(),
                    val.typeName() ? val.typeName() : "?", (int) val.isValid(), (int) val.isNull());
        map->insert(QString::fromUtf8(prop), val);
        // ...and KEEP it current where that is possible at all. See QtdScopeWatch: the value read
        // here is a snapshot, and an owner with a NOTIFY is exactly the case where a snapshot is
        // avoidable. A context property has no notify and stays a snapshot; so does a property
        // declared without one, which the engine cannot follow either.
        if (owner) qtd_watch_scope(map, owner, prop);
        g_promiseRetries = 0;   // progress: the tree is still growing, keep trying for the rest
        v.removeAt(i);
    }
    // ...and the COMPILED reads waiting on the same names, for the same reason and on the same
    // schedule. One drain, two lists: a name becomes reachable for both at the same instant.
    qtd_drain_scope_conns();
    // A name that stays unreachable is the compiler's remaining gap, and it is invisible from the
    // JS side: the binding says "of undefined" and names the PROPERTY, never the scope name that
    // failed. Asked for by name so it costs nothing when it is not.
    // WHY ONCE IS NOT ENOUGH, and this is the whole reason the thing is called a promise. The
    // resolution above is attempted when the promise is made and again when a component finishes —
    // and for an object built by this compiler both of those happen inside its own CONSTRUCTOR,
    // before the caller has parented it or the engine has given the delegate its context. Measured
    // on a real application: 307 promises made, 209 resolved, and the 98 left were not unreachable
    // names but names asked for too early.
    //
    // So a drain that leaves work behind asks to be run again after the current event cycle, when
    // the tree has grown. It is bounded: a name that is genuinely not there would otherwise
    // reschedule for the life of the process, and the binding that reads it must be allowed to
    // fail like the engine's does rather than hang the loop in retries. The bound counts
    // CONSECUTIVE FRUITLESS attempts, not attempts: a single process-wide cap was spent in the
    // first milliseconds of a real application and left every later promise with no retry at all,
    // which is why the first version of this measured no improvement whatsoever.
    if (v.isEmpty()) return;
    if (QCoreApplication::instance() && g_promiseRetries < 32 && !g_promiseRetryArmed) {
        g_promiseRetryArmed = true;
        ++g_promiseRetries;
        QTimer::singleShot(0, QCoreApplication::instance(), [] {
            g_promiseRetryArmed = false;
            qtd_drain_promises();
        });
        return;
    }
    if (g_promiseRetryArmed) return;   // a retry is already pending; this is not the last word
    // REPORTED WHERE THE ANSWER IS FINAL, which is here — the point at which no further attempt is
    // scheduled. Reporting on the first drain instead described the tree as it was during
    // construction (every object an orphan, which they all are for a moment) and said nothing about
    // why a name was still missing once the tree existed.
    if (qEnvironmentVariableIsSet("QTD_PROMISE_DEBUG")) {
        // Once per NAME for the life of the process: a drain runs on every promise and every
        // finalize, so a per-call report buried the ten names that matter under 5623 lines.
        static QSet<QByteArray> reported;
        for (const auto& e : v) if (!reported.contains(e.prop)) {
            reported.insert(e.prop);
            int depth = 0; QObject* top = e.obj;
            for (QObject* q = e.obj; q && q->parent(); q = q->parent()) { ++depth; top = q->parent(); }
            fprintf(stderr, "qtd_scope_promise: '%s' unresolved (on %s, %d ancestors, top=%s, ctx=%d)\n",
                    e.prop.constData(), e.obj ? e.obj->metaObject()->className() : "?", depth,
                    top ? top->metaObject()->className() : "?",
                    (int) (e.obj && qmlContext(e.obj) != nullptr));
        }
    }
}

#endif   // QTD_HAVE_QML — everything above is QML-only; the entry point below is not
// THE TREE, WITH ITS GEOMETRY, because a screenshot says a document collapsed and not which item
// did. Read through the meta-object, so it needs no QtQuick header and works for an object the
// engine built as well as one this compiler did. Armed by QTD_DUMP_TREE=<milliseconds>, once, from
// the first finalize of an object that has no parent — by then the tree exists and has laid out.
#ifdef QTD_HAVE_QML
static void qtd_dump_tree(QObject* o, int depth) {
    if (!o || depth > 12) return;
    const QVariant w = o->property("width"), h = o->property("height");
    if (w.isValid())
        std::fprintf(stderr, "%*s%s%s %gx%g @%g,%g%s\n", depth * 2, "",
                     o->metaObject()->className(),
                     o->objectName().isEmpty() ? "" : qPrintable(" '" + o->objectName() + "'"),
                     w.toDouble(), h.toDouble(), o->property("x").toDouble(),
                     o->property("y").toDouble(),
                     o->property("visible").toBool() ? "" : " HIDDEN");
    // The VISUAL children, not the QObject ones: QQuickItem::setParentItem does not set a QObject
    // parent, so a whole document's tree reads as childless from QObject alone — the first version
    // of this printed one line and looked like the tree had not been built. QQmlListReference is
    // public QtQml, so this still needs no QtQuick header.
    QQmlListReference kids(o, "children");
    if (kids.isValid())
        for (qsizetype i = 0; i < kids.count(); ++i) qtd_dump_tree(kids.at(i), depth + 1);
    else
        for (QObject* c : o->children()) qtd_dump_tree(c, depth + 1);
}
#endif

// APPEND TO WHATEVER THE TYPE CALLS ITS DEFAULT PROPERTY, asked of the object rather than of a
// table. A type the engine builds and this compiler does not bind has no row anywhere — `Gradient`
// is the plain case, and its stops belong in `stops`. Qt writes the answer into the meta-object as
// Q_CLASSINFO("DefaultProperty"), which is exactly what the engine reads to place a bare child.
// Falls back to nothing: the caller hand-parents when this answers false, which is what a type with
// no list wants anyway.
extern "C" bool qtd_list_append_default(void* parent, void* child) {
#ifdef QTD_HAVE_QML
    if (!parent || !child) return false;
    QObject* p = static_cast<QObject*>(parent);
    for (const QMetaObject* mo = p->metaObject(); mo; mo = mo->superClass()) {
        int i = mo->indexOfClassInfo("DefaultProperty");
        if (i < 0 || mo->classInfo(i).enclosingMetaObject() != mo) continue;
        QQmlListReference r(p, mo->classInfo(i).value());
        if (!r.isValid() || !r.canAppend()) return false;
        return r.append(static_cast<QObject*>(child));
    }
    return false;
#else
    (void) parent; (void) child; return false;
#endif
}

extern "C" void* qtd_scope_promise(void* o, const char* prop) {
    if (qEnvironmentVariableIsSet("QTD_PROMISE_DEBUG")) {
        fprintf(stderr, "qtd_scope_promise: ENTER '%s'\n", prop ? prop : "?");
        fflush(stderr);
    }
#ifdef QTD_HAVE_QML
    if (!o || !prop) return nullptr;
    QObject* obj = static_cast<QObject*>(o);
    auto* map = new QQmlPropertyMap(obj);
    map->insert(QString::fromUtf8(prop), QVariant());
    qtd_promises().append({map, obj, QByteArray(prop)});
    g_promiseRetries = 0;   // a new name to answer is progress too

    qtd_drain_promises();          // it may already be reachable
    return map;
#else
    (void) o; (void) prop; return nullptr;
#endif
}

// THE OBJECT A SCOPE NAME STANDS FOR, for code that was COMPILED rather than delegated.
//
// `theme.paper` — where `theme` is a name the application published and no registry can type — was
// refused outright, and that one shape is most of what this compiler refuses on a real application:
// 75 of 210 refused expressions in one reader's Main.qml, 91 mentions of `theme.<member>`. The type
// was never the missing part. The engine answers such a read by asking the CONTEXT for the object
// and then reading the member off it, and both halves already exist here: qtd_resolve_scope is the
// same context lookup the promise uses, and the meta-object reads a member by name.
//
// Null when the name is not reachable YET, which is the normal case during the wire: a compiled read
// is `propAny!T(scopeObj(...), "paper")`, and propAny throws QmlNullDeref on a null receiver, which
// is what makes the binding abort and write nothing — the engine's own behaviour for `undefined.x`.
// The value arrives when the name does; see qtd_scope_notify.
extern "C" void* qtd_scope_object(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    if (!o || !name) return nullptr;
    QVariant v;
    if (!qtd_resolve_scope(static_cast<QObject*>(o), QByteArray(name), v)) return nullptr;
    if (!v.isValid()) return nullptr;          // not reachable yet — the normal answer during a wire
    // ...RESOLVED, BUT NOT TO AN OBJECT, which is a different thing and must not pass for the first.
    // A published name may hold a JS value or a map (`modelData` for a model of JS objects), and a
    // member of one of those is not something a meta-object read can answer: the binding will abort
    // and write nothing where the engine reads a key. That is a silent wrong value, so it says so —
    // once per name, because a binding re-evaluates.
    if (!v.canConvert<QObject*>()) {
        static QSet<QByteArray> told;
        if (!told.contains(QByteArray(name))) {
            told.insert(QByteArray(name));
            std::fprintf(stderr, "qtd_scope_object: '%s' resolved to %s, which is not an object — a "
                         "compiled member read of it writes nothing (the engine would read a key)\n",
                         name, v.typeName() ? v.typeName() : "?");
        }
        return nullptr;
    }
    return v.value<QObject*>();
#else
    (void) o; (void) name; return nullptr;
#endif
}

#ifdef QTD_HAVE_QML
extern "C" int qtd_connect_by_name(void* sndrV, const char* signalName, void* recvV, const char* slot);
namespace {
// One request to keep a compiled read of `<name>.<prop>` current. The asker is held weakly: it may
// die before the name it is waiting for ever resolves.
struct QtdScopeConn { QPointer<QObject> asker; QByteArray name, prop, slot; };
}
static QList<QtdScopeConn>& qtd_scope_conns() { static QList<QtdScopeConn> v; return v; }

// WHEN, not whether. This is the whole difficulty of compiling a read through a published name: the
// object is not reachable while the wire runs (the context is hung off the engine's root in the
// constructor, and an ancestor's context only becomes reachable once the tree exists), so a connect
// made at emit time connects to nothing and the first read is null. So the request is QUEUED and
// retried by the same drain the promises use — every finalization, and once more after the event
// cycle. When it lands, the slot is invoked ONCE: that is the evaluation that finally has a value.
//
// Both notify spellings are tried, because both occur: a per-property `<prop>Changed()` and the
// object's own `changed()`. Neither being present is not a failure — it is a value that cannot
// change, which the engine cannot follow either.
static void qtd_drain_scope_conns() {
    auto& v = qtd_scope_conns();
    for (int i = 0; i < v.size();) {
        QObject* asker = v[i].asker.data();
        if (!asker) { v.removeAt(i); continue; }          // the reader is gone; so is the request
        QObject* owner = static_cast<QObject*>(qtd_scope_object(asker, v[i].name.constData()));
        if (!owner) { ++i; continue; }                    // not reachable yet — try again later
        const QByteArray sig = v[i].prop + "Changed";
        qtd_connect_by_name(owner, sig.constData(), asker, v[i].slot.constData());
        qtd_connect_by_name(owner, "changed", asker, v[i].slot.constData());
        QByteArray slot = v[i].slot;
        if (int cut = slot.indexOf('('); cut >= 0) slot.truncate(cut);
        v.removeAt(i);
        QMetaObject::invokeMethod(asker, slot.constData(), Qt::DirectConnection);
    }
}
#endif

extern "C" void qtd_scope_notify(void* o, const char* name, const char* prop, const char* slot) {
#ifdef QTD_HAVE_QML
    if (!o || !name || !prop || !slot) return;
    qtd_scope_conns().append({QPointer<QObject>(static_cast<QObject*>(o)),
                              QByteArray(name), QByteArray(prop), QByteArray(slot)});
    qtd_drain_scope_conns();   // it may already be reachable
#else
    (void) o; (void) name; (void) prop; (void) slot;
#endif
}

extern "C" int qtd_bind_js(void* o, const char* prop, const char* src,
                           const char** names, void** objs, int n) {
#ifdef QTD_HAVE_QML
    if (!o || !prop || !src) return 0;
    QObject* obj = static_cast<QObject*>(o);
    QQmlContext* base = qmlContext(obj);
    // LOUD, not silent. A delegated binding that quietly does nothing is the worst outcome of the
    // three: the property keeps its default and nothing anywhere says why. Measured exactly once,
    // and that was enough -- a QtQml-only harness with no application object has no engine, so
    // there was no context and the value simply stayed empty against the engine's.
    if (!base) {
        std::fprintf(stderr, "qtd_bind_js: '%s' on %s has no QQmlContext — binding not installed\n",
                     prop, obj->metaObject()->className());
        return 0;
    }
    QQmlContext* ctx = base;
    if (n > 0) {
        ctx = new QQmlContext(base, obj);   // owned by the object, like the engine's per-item one
        for (int i = 0; i < n; ++i)
            if (names[i])
                ctx->setContextProperty(QString::fromUtf8(names[i]),
                                        static_cast<QObject*>(objs[i]));
    }
    QString p = QString::fromUtf8(prop);
    auto* e = new QQmlExpression(ctx, obj, QString::fromUtf8(src), obj);
    // Read ONCE: this runs on every re-evaluation of every delegated binding.
    static const bool trace = std::getenv("QTD_JS_TRACE") != nullptr;
    // A delegated binding that THROWS leaves the property at its default and, counted as a
    // delegation, looked like neither a refusal nor a defect. It is a defect: Qt's Material Button
    // paints white instead of #d6d7d7 because `control.Material.buttonColor(…)` throws, and the
    // census said "delegated" with no hint that anything was wrong. Reported ONCE per binding —
    // the first evaluation is where the cause is, and a binding that recovers later says so by not
    // repeating.
    auto reported = std::make_shared<bool>(false);
    auto eval = [e, obj, p, reported]() {
        QVariant v = e->evaluate();
        if (trace)
            std::fprintf(stderr, "qtd_bind_js: %s = %s%s\n", qPrintable(p), qPrintable(v.toString()),
                         e->hasError() ? qPrintable(" ERROR: " + e->error().toString()) : "");
        if (e->hasError()) {
            if (!*reported) {
                *reported = true;
                std::fprintf(stderr, "qtd_bind_js: delegated binding for '%s' on %s threw: %s%s\n",
                             qPrintable(p), obj->metaObject()->className(),
                             qPrintable(e->error().description()),
                             qEnvironmentVariableIsSet("QTD_CTX_DEBUG")
                                 ? (qmlContext(obj) && qmlContext(obj)
                                        ->contextProperty(QStringLiteral("modelData")).isValid()
                                        ? "  [ctx HAS modelData]" : "  [ctx has NO modelData]")
                                 : "");
            }
            e->clearError();
            return;
        }
        const bool wrote = QQmlProperty(obj, p, qmlContext(obj)).write(v);
        if (trace && !wrote)
            std::fprintf(stderr, "qtd_bind_js: %s WRITE REFUSED (value %s)\n", qPrintable(p),
                         qPrintable(v.toString()));
    };
    e->setNotifyOnValueChanged(true);
    QObject::connect(e, &QQmlExpression::valueChanged, obj, eval);
    eval();
    return 1;
#else
    (void) o; (void) prop; (void) src; (void) names; (void) objs; (void) n; return 0;
#endif
}

// A MEMBER OF A VALUE-TYPED PROPERTY: `color.a`, `font.pixelSize`, `size.width`. QColor is neither a
// QObject nor a Q_GADGET, so no meta-object of its own answers for `a` — QML reaches it through a
// VALUE TYPE, and QQmlProperty resolves a dotted path straight through it — the same route QML
// itself takes, so the set of readable members is EXACTLY QML's. Nothing here knows what a colour
// is, which is the point.
//
// `layer.enabled: control.enabled && color.a > 0 && !control.flat` is Qt's Material Button, and
// `color.a` is the whole reason that line could not compile — so the background was never put in a
// layer, and seven of Material's documents drew a shape the engine does not draw at all.
extern "C" int qtd_prop_value_member(void* o, const char* prop, const char* member, double* out) {
#ifdef QTD_HAVE_QML
    if (!o || !prop || !member || !out) return 0;
    QObject* q = static_cast<QObject*>(o);
    // QQmlProperty resolves a DOTTED path through a value type — it is what QML itself uses for
    // `color.a`, and it is public, where the value-type registry is not.
    QQmlProperty p(q, QString::fromUtf8(prop) + QLatin1Char('.') + QString::fromUtf8(member));
    if (!p.isValid()) return 0;
    const QVariant got = p.read();
    if (!got.isValid() || !got.canConvert<double>()) return 0;
    *out = got.toDouble();
    return 1;
#else
    (void) o; (void) prop; (void) member; (void) out;
    return 0;
#endif
}

// The Nth element of a list property, THROUGH the meta-object — the same walk the oracle does.
// A default child is appended with qtd_list_append and Qt may reparent it (a Flickable moves visual
// children into its content item), so the D field that holds it and `<prop>[N]` on the object are
// not the same thing. Dumping the field under that label compared two different objects.
extern "C" void* qtd_list_at(void* o, const char* prop, int i) {
#ifdef QTD_HAVE_QML
    if (!o) return nullptr;
    QQmlListReference ref(static_cast<QObject*>(o), prop);
    if (!ref.isValid() || !ref.canAt() || i < 0 || i >= ref.count()) return nullptr;
    return ref.at(i);
#else
    (void) o; (void) prop; (void) i; return nullptr;
#endif
}

// ---- QQmlParserStatus ---------------------------------------------------------
// The engine calls classBegin() before setting a component's properties and componentComplete()
// once the whole tree is built; a type that implements QQmlParserStatus does real initialisation
// there (QQuickControl computes hoverEnabled in componentComplete). A compiler that only
// constructs objects and assigns properties produces something that is built but NOT complete,
// which differs from the engine in ways no individual assignment explains.
//
// dynamic_cast because QQmlParserStatus is a secondary base: the interface pointer needs the
// correct offset, and a type that does not implement it must be left alone rather than called
// through a wrong vtable.
extern "C" void qtd_parser_status(void* o, int complete) {
#ifdef QTD_HAVE_QML
    if (!o) return;
    if (auto* ps = dynamic_cast<QQmlParserStatus*>(static_cast<QObject*>(o))) {
        if (complete) ps->componentComplete();
        else ps->classBegin();
    }
#else
    (void) o; (void) complete;
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

extern "C" void qtd_component_finalized(void* o) {
#ifdef QTD_HAVE_QML
    qtd_drain_promises();   // the tree grew; a name that was unreachable may not be any more
    if (o && !static_cast<QObject*>(o)->parent() && qEnvironmentVariableIsSet("QTD_DUMP_TREE")) {
        static bool armed = false;
        if (!armed && QCoreApplication::instance()) {
            armed = true;
            QObject* root = static_cast<QObject*>(o);
            QTimer::singleShot(qEnvironmentVariableIntValue("QTD_DUMP_TREE"),
                               QCoreApplication::instance(),
                               [root] {
                                   // UP TO THE TOP FIRST. The arming object is whichever finished
                                   // first with no QObject parent, and a delegate is exactly that
                                   // — so the dump started from one leaf and showed one line.
                                   // The visual parent is a property, so climbing it needs no
                                   // QtQuick header either.
                                   QObject* top = root;
                                   for (int i = 0; i < 32; ++i) {
                                       QObject* p = qvariant_cast<QObject*>(top->property("parent"));
                                       if (!p) break;
                                       top = p;
                                   }
                                   std::fprintf(stderr, "--- qtd tree ---\n");
                                   qtd_dump_tree(top, 0); std::fflush(stderr); });
        }
    }
#endif

#if defined(QTD_HAVE_QML) && QT_VERSION >= QT_VERSION_CHECK(6, 2, 0)
    if (!o) return;
    // qobject_cast, not dynamic_cast: the hook is reached through qt_metacast by IID, which is what
    // makes the locally-declared interface work at all.
    if (auto* fh = qobject_cast<QQmlFinalizerHook*>(static_cast<QObject*>(o)))
        fh->componentFinalized();
#else
    (void) o;
#endif
}

// Dumps EVERY property an object's meta-object declares, as `<path>.<name>\t<value>`. Both the
// compiled side and the QQmlComponent oracle call THIS function, so the comparison covers what
// the objects actually are rather than what the compiler chose to record — and no difference can
// come from the two sides formatting a value differently, since there is only one formatter.
// ...and the same dump with the `__class` decided by the CALLER. The walk below cannot tell our
// generated class from a Qt one — both are just names, and ours is named after the document exactly
// as the engine names a document-defined type — so for a NESTED child the compiler passes the C++
// base it built the object on. An empty hint keeps the walk, which is what the root wants.
extern "C" void qtd_dump_object_as(void* o, const char* path, const char* cls);
extern "C" void qtd_dump_object(void* o, const char* path) { qtd_dump_object_as(o, path, nullptr); }

// Dump ONE object named by a PATH from a root — `contentItem.effect.data[1]`, resolved segment by
// segment through the meta-object. A document handed to the engine wholesale has no D fields to
// walk, so the dump cannot be a chain of field accesses the way a compiled one is; the paths are
// the same ones `--objpaths` already hands the oracle, so both sides walk the same tree by the same
// names. LOUD when a segment does not resolve: a path silently skipped would read as agreement.
extern "C" void qtd_dump_path(void* root, const char* path) {
    if (!root || !path || !*path) return;
    QByteArray p(path);
    QObject* cur = static_cast<QObject*>(root);
    int at = 0;
    while (at < p.size() && cur) {
        int dot = p.indexOf('.', at);
        QByteArray seg = p.mid(at, dot < 0 ? -1 : dot - at);
        at = dot < 0 ? p.size() : dot + 1;
        int br = seg.indexOf('[');
        if (br < 0) {
            cur = static_cast<QObject*>(qtd_prop_get_obj(cur, seg.constData()));
        } else {
            QByteArray nm = seg.left(br);
            int idx = seg.mid(br + 1, seg.size() - br - 2).toInt();
            cur = static_cast<QObject*>(qtd_list_at(cur, nm.constData(), idx));
        }
    }
    if (!cur) {
        std::fprintf(stderr, "qtd_dump_path: '%s' resolves to nothing\n", path);
        return;
    }
    qtd_dump_object_as(cur, (p + ".").constData(), "");
}

extern "C" void qtd_dump_object_as(void* o, const char* path, const char* cls) {
    if (!o) return;
    QObject* q = static_cast<QObject*>(o);
    const QMetaObject* mo = q->metaObject();
    // The C++ class each object actually IS, so comparing two DIFFERENT objects shows up as one
    // clear difference instead of a scattered set of property mismatches. Our objects are D
    // subclasses whose own className is generated, so the chain is walked to the first Qt class —
    // which is the bound base for ours and the class itself for the engine's, and therefore
    // comparable. Qt's Flickable reparents visual children into its contentItem, so `data[0]` on a
    // ListView is NOT the child the document wrote there: without this the two sides quietly
    // compared a Rectangle against an internal content item.
    {
// ...skipping any class that declares no properties of its own. Qt puts pure enum-holders in the
        // chain (QQuickDialogButtonBox's is DialogButtonBox_QMLTYPE < QPlatformDialogHelper <
        // QQuickDialogButtonBox), and stopping at the first Qt name picked the holder instead of the type.
        // A hint is where the walk STARTS, not what it answers: the engine applies the same
        // "skip a class that declares no properties of its own" rule above whatever it found, and a
        // QQuickMenuSeparator declares none — its answer is QQuickControl. Starting at the hinted
        // class and then walking gives the engine's answer for the same object.
        const QMetaObject* c = mo;
        bool named = false;   // the caller pointed AT this class, so it is not one to skip past
        if (cls && *cls)
            for (const QMetaObject* k = mo; k; k = k->superClass())
                if (std::strcmp(k->className(), cls) == 0) { c = k; named = true; break; }
        auto qtdGenerated = [](const QMetaObject* k) {
            for (int i = k->classInfoOffset(); i < k->classInfoCount(); ++i)
                if (std::strcmp(k->classInfo(i).name(), "qtdGenerated") == 0) return true;
            return false;
        };
        // The leading-Q test applies to the NAMED class too, and that is not a detail: the oracle
        // runs this same walk over the ENGINE's chain, where a document type is `<Document>_QML_n`.
        // `Locals.qml` produces `Locals_QML_0`, which fails the test there and answers QObject --
        // so our `Locals` has to fail it here for the same reason, or the two sides disagree about
        // a document whose name simply does not begin with Q. Being NAMED exempts a class only from
        // being skipped for being ours, which is what an inline component needs and a document root
        // must not have.
        while (c && (c->className()[0] != 'Q' || (qtdGenerated(c) && !named)
                     || c->propertyCount() <= c->propertyOffset())) { c = c->superClass(); named = false; }
        // Qt generates a subclass per QML type (`QQuickRectangle_QML_2`); it IS that type, so the
        // suffix is normalised away — otherwise every object the document declares would read as a
        // type mismatch and the real ones would be lost in it.
        QByteArray cn(c ? c->className() : mo->className());
        int cut = cn.indexOf("_QML");
        if (cut > 0) cn.truncate(cut);
        std::printf("%s__class\t%s\n", path, cn.constData());
    }
    for (int i = 0; i < mo->propertyCount(); ++i) {
        QMetaProperty mp = mo->property(i);
        if (!mp.isReadable()) continue;
        // A property whose metatype the type system does not know cannot be read into a QVariant
        // safely: QMetaType::canConvert walks a null interface and the process dies there (gdb, on
        // a `QQmlListProperty<QObject>` property added before its metatype was registered).
        // Skipping is what every other untextable property here already does; crashing the dump is
        // not one of the options.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        if (!mp.metaType().isValid()) continue;
#endif
        QVariant v = mp.read(q);
        QString out;
        if (mp.isEnumType()) {
            const char* k = mp.enumerator().valueToKey(v.toInt());
            out = k ? QString::fromUtf8(k) : QString::number(v.toInt());
        } else if (v.canConvert<QObject *>()) {   // Qt5 has no QVariant::metaType()
            // The ADDRESS differs between the two runs by construction; what is comparable is
            // whether the slot is filled at all.
            out = v.value<QObject*>() ? QStringLiteral("<object>") : QStringLiteral("<null>");
#ifdef QTD_HAVE_QML
        } else if (v.canConvert<QJSValue>()) {
            // A QJSValue-typed property that HOLDS an object is an object slot like any other, and
            // saying so is the difference between a comparison and a blank. `Rectangle.gradient` is
            // one, and both sides printed empty for it whether it held a Gradient or null — which is
            // precisely how `gradient: control.down ? null : buttonGradient` stayed a one-shot with
            // nothing in the value differential to show for it.
            QJSValue jv = v.value<QJSValue>();
            // ONLY when it holds a QObject. A plain JS object has no text form worth comparing —
            // `[object Object]` says nothing, and Text.fontInfo is one on the engine's side and
            // nothing on ours, which would have added eleven differences that are a spelling, not
            // a defect. Skipped, exactly as a list or a gadget is. A slot filled on one side and
            // empty on the other still shows: the key is present for one and absent for the other.
            if (!jv.toQObject()) continue;
            out = QStringLiteral("<object>");
#endif
        } else if (v.canConvert<QString>()) {
            out = v.toString();
        } else {
            continue;   // a list or an opaque gadget: not comparable as text, and not faked as one
        }
        std::printf("%s%s\t%s\n", path, mp.name(), out.toUtf8().constData());
    }
}


// ---- dependencies reached THROUGH an object property ------------------------------------------
// `x: (parent.width - width) / 2` depends on an object our constructor cannot see: a root's
// `parent` (and HeaderView's `syncView`) is assigned by whoever instantiates it, AFTER the wire
// runs, so a one-shot connect to propObj(this,"parent") connected to null and threw. QML re-binds
// such a dependency when the property changes, and that is what these two do:
//   qtd_connect_notify  - follow the PROPERTY (parentChanged -> re-evaluate the binding)
//   qtd_bind_leaf       - (re)subscribe to the leaf signal on whatever object it now holds
// The slot calls bind_leaf on every run, so a new parent is subscribed and the old one dropped.
// An entry knows EVERY index it sits in (critics r13 #4). It used to be `key -> Connection` with a
// separate reverse index per object, and `qtd_leaf_forget(o)` dropped the key from o's vector only
// — the same key stayed in the OTHER endpoint's vector for ever. With a long-lived receiver and
// transient owners, that vector grows without bound, and the probe could not see it because
// `qtd_leaf_table_size()` reported the main table alone.
//
// Three endpoints, not two: the real connection is `cur -> recv`, and `cur` (the object the
// property currently holds) can die on its own. Qt invalidates the Connection and the entry used to
// survive until some other event touched it.
struct QtdLeafEntry {
    QMetaObject::Connection c;
    QObject* ends[3];        // owner, recv, cur — any of them may be null
};
static std::unordered_map<std::string, QtdLeafEntry> g_leafConn;

static std::unordered_map<QObject*, std::vector<std::string>> g_leafByObj;

static std::mutex g_leafMx;

// The key carries the OWNER, and it must. It did not, and the receiving slot is emitted once per
// BINDING (`__rc_<prop>()`), so an expression reading the same property name through two different
// objects — `a.parent.width + b.parent.width` — registered both dependencies under one key. The
// second call disconnected the first and BOTH returned success. A reactive dependency that stops
// updating without saying so is the worst failure this runtime can have, because nothing observes
// it: the frame is merely stale, never wrong-looking.
static std::string qtd_leaf_key(void* owner, void* recv, const char* slot, const char* prop,
                                const char* sig) {
    char b[48]; std::snprintf(b, sizeof b, "%p|%p|", owner, recv);
    return std::string(b) + slot + "|" + prop + "|" + sig;
}

// ...and the table must not outlive the objects it keys on. Qt invalidates the Connection when
// either end dies, but the ENTRY survives until that exact key is reused — and with a dynamic tree
// the addresses are recycled, so a stale entry is not merely a leak: it can be found by a later
// object that lands on the same address. Both ends are watched; the first key an object registers
// arms its watch.
static void qtd_leaf_watch(QObject* o, const std::string& k);   // below

// Drop ONE key from every index that holds it, then the entry. This is the half that was missing.
static void qtd_leaf_drop(const std::string& k) {             // g_leafMx HELD
    auto e = g_leafConn.find(k);
    if (e == g_leafConn.end()) return;
    for (QObject* o : e->second.ends) {
        if (!o) continue;
        auto it = g_leafByObj.find(o);
        if (it == g_leafByObj.end()) continue;
        auto& v = it->second;
        v.erase(std::remove(v.begin(), v.end(), k), v.end());
        if (v.empty()) g_leafByObj.erase(it);
    }
    g_leafConn.erase(k);
}

static void qtd_leaf_forget(QObject* o) {                    // g_leafMx HELD
    auto it = g_leafByObj.find(o);
    if (it == g_leafByObj.end()) return;
    const std::vector<std::string> keys = it->second;   // by value: drop mutates the map
    for (auto& k : keys) qtd_leaf_drop(k);
    g_leafByObj.erase(o);                               // no-op if drop already emptied it
}

// How many entries the REVERSE index holds, summed over objects. The main table returning to its
// baseline says nothing about this one — which is exactly how the one-sided cleanup stayed
// invisible — so the probe gets to see both.
extern "C" int qtd_leaf_index_size() {
    std::lock_guard<std::mutex> g(g_leafMx);
    size_t n = 0;
    for (auto& kv : g_leafByObj) n += kv.second.size();
    return (int) n;
}

static void qtd_leaf_watch(QObject* o, const std::string& k) {   // g_leafMx HELD
    if (!o) return;                                          // `cur` may be null
    auto& keys = g_leafByObj[o];
    if (keys.empty())
        QObject::connect(o, &QObject::destroyed, o, [o] {
            std::lock_guard<std::mutex> g(g_leafMx);
            qtd_leaf_forget(o);
        });
    if (std::find(keys.begin(), keys.end(), k) == keys.end()) keys.push_back(k);
}

extern "C" int qtd_bind_leaf(void* ownerV, const char* prop, const char* sig, void* recvV,
                             const char* slot) {
    QObject* owner = static_cast<QObject*>(ownerV);
    QObject* recv  = static_cast<QObject*>(recvV);
    if (!owner || !recv) return 0;
    int pi = owner->metaObject()->indexOfProperty(prop);
    if (pi < 0) return 0;
    QObject* cur = qvariant_cast<QObject*>(owner->metaObject()->property(pi).read(owner));
    std::string k = qtd_leaf_key(owner, recv, slot, prop, sig);
    std::lock_guard<std::mutex> g(g_leafMx);
    if (auto it = g_leafConn.find(k); it != g_leafConn.end()) {
        QObject::disconnect(it->second.c);
        qtd_leaf_drop(k);                       // every index, not just this one
    }
    if (!cur) return 0;                       // not assigned yet: the notify connect will come back
    std::string s = std::string("2") + sig, m = std::string("1") + slot;
    auto c = QObject::connect(cur, s.c_str(), recv, m.c_str());
    if (!c) return 0;
    g_leafConn[k] = QtdLeafEntry{c, {owner, recv, cur}};
    qtd_leaf_watch(owner, k);
    qtd_leaf_watch(recv, k);
    qtd_leaf_watch(cur, k);                     // the connection's real sender (critics r13 #4)
    return 1;
}

// THE SAME SUBSCRIPTION, WITH THE SIGNAL RESOLVED FROM THE OBJECT instead of named by the caller.
// `background.topPadding` is written all over Qt's Imagine style, and `background` is declared as an
// `Item` — which has no topPadding. The member belongs to the NinePatchImage that is actually there,
// so no static table can name its notify, and the compiler refused the read outright rather than
// wire something it could not see. The meta-object of the object in hand can name it, which is the
// same channel the rest of this file already travels on.
extern "C" int qtd_bind_leaf_prop(void* ownerV, const char* prop, const char* leafProp, void* recvV,
                                  const char* slot) {
    QObject* owner = static_cast<QObject*>(ownerV);
    QObject* recv  = static_cast<QObject*>(recvV);
    if (!owner || !recv) return 0;
    int pi = owner->metaObject()->indexOfProperty(prop);
    if (pi < 0) return 0;
    QObject* cur = qvariant_cast<QObject*>(owner->metaObject()->property(pi).read(owner));
    // The key is the PROPERTY, not the signal: the signal is whatever the object currently there
    // answers with, and a re-subscription after that object is replaced must find the same entry.
    std::string kk = std::string("#") + leafProp;
    std::string k = qtd_leaf_key(owner, recv, slot, prop, kk.c_str());
    std::lock_guard<std::mutex> g(g_leafMx);
    if (auto it = g_leafConn.find(k); it != g_leafConn.end()) {
        QObject::disconnect(it->second.c);
        qtd_leaf_drop(k);                       // every index, not just this one
    }
    if (!cur) return 0;                       // not assigned yet: the notify connect will come back
    int li = cur->metaObject()->indexOfProperty(leafProp);
    if (li < 0) return 0;                     // the object there does not have it either
    QMetaMethod ns = cur->metaObject()->property(li).notifySignal();
    if (!ns.isValid()) return 0;              // a constant property never changes; nothing to wire
    std::string s = std::string("2") + ns.methodSignature().constData(), m = std::string("1") + slot;
    auto c = QObject::connect(cur, s.c_str(), recv, m.c_str());
    if (!c) return 0;
    g_leafConn[k] = QtdLeafEntry{c, {owner, recv, cur}};
    qtd_leaf_watch(owner, k);
    qtd_leaf_watch(recv, k);
    qtd_leaf_watch(cur, k);                     // the connection's real sender (critics r13 #4)
    return 1;
}

// How many leaf connections the table holds. A probe cannot prove the cleanup above from the
// outside — the entries are invisible — so the count is exported for exactly that: build a tree,
// destroy it, and require the table back at its baseline.
extern "C" int qtd_leaf_table_size() {
    std::lock_guard<std::mutex> g(g_leafMx);
    return (int) g_leafConn.size();
}
