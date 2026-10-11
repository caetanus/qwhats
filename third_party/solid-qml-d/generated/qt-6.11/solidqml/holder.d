// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// holder.d — the D wrapper lifetime layer.
//
// Design (parenting-pins):
//   - Every generated object wrapper extends QtdObject, which holds the C++ pointer
//     `_cpp` (nullable) and checks it on every call — a destroyed object throws
//     instead of segfaulting.
//   - Identity: `wrap(cptr, factory)` returns the SAME wrapper for a C++ pointer
//     (the map is C++-side, so it does not pin — see qtd_holder.cpp).
//   - Parenting pins: a parented child is held in `_pinned` (a GC root) so it lives
//     as long as its parent, even with no D-side reference. Unparenting / destruction
//     unpins it.
//   - A dropped, UNparented wrapper is collected by the GC; its finalizer calls
//     deleteLater (you own it). A parented one's finalizer does nothing (Qt owns it).
//   - destroyed() (C++ deleted the object) nulls `_cpp` and drops the entries.
//
// Single-threaded by design (Qt main thread; stop-the-world GC).
module holder;

import core.memory : GC;

alias QtdDestroyedFn = extern (C) void function(void *) nothrow;
alias QtdDeleteFn    = extern (C) void function(void *) nothrow @nogc;

extern (C) nothrow @nogc {
    void  qtd_holder_set_destroyed_hook(QtdDestroyedFn);
    void  qtd_holder_track(void *);
    int   qtd_holder_has_parent(void *);
    void  qtd_holder_delete_later(void *);
    int   qtd_holder_is_app(void *);
    void  qtd_holder_reg(void *, void *);
    void *qtd_holder_find(void *);
    void  qtd_holder_unreg(void *);
    int   qtd_holder_inherits(void *, const(char) *);
    size_t qtd_holder_count();
}

/// The tag that selects the ADOPT constructor — "wrap this existing C++ pointer" — as opposed to
/// the ordinary constructors, which allocate. Untagged it was `this(void* c)`, and D cannot choose
/// between that and `this(QWidget parent = null, int f = 0)` when the argument is a literal
/// `null`: `new QWidget(null)` did not compile, which is the first line of the README's own
/// example. Nothing outside the generated code ever calls it, so giving it a name costs a user
/// nothing and gives back the spelling everyone tries first.
struct QtdAdopt { void* p; }

/// Base of every generated object wrapper. Holds the C++ pointer and its lifetime.
class QtdObject {
    package void *_cpp;
    package bool _isQObj;   // has destroyed()/parent() -> lifetime is tracked; else dispose-only
    // WHO CREATED THIS OBJECT — not "who has it now", which is what parenting answers.
    //
    // The finalizer used to decide ownership from parenting alone: unparented and not the app
    // singleton meant "ours, delete it". That is right for `new QWidget()` and WRONG for every
    // pointer Qt hands back. `QThread.currentThread()` compiles to `QThread.wrap(__QThread_1())`
    // and the current thread has no parent — so dropping the D reference scheduled a deleteLater
    // on the running thread, from what looks like a getter. Qt documents that deleting a running
    // QThread crashes.
    //
    // The distinction was already present at the two call sites and simply not recorded: a
    // generated CONSTRUCTOR allocated the object (`__cpp_new` then `_register()`), while `wrap()`
    // was GIVEN a pointer. So the default is BORROWED and only the paths that created the object
    // say otherwise. Nothing in the 385 generated `_register()` call sites has to change.
    //
    // This is deliberately not a full ownership model: an API that TRANSFERS ownership either way
    // (`QLayout::addItem`, a factory return) still needs the typesystem to say so. What it removes
    // is the failure mode where the binding deletes something it never owned — a leak is the
    // conservative error here, a use-after-free is not.
    package bool _ownedByD;
    // HOW to delete this object, for a type Qt will not delete for us. Only the generated class
    // knows the C++ type; only the holder knows the policy — so the class supplies the one and the
    // finalizer below decides the other. Null for everything that has no declared way to be
    // disposed of, which is every class until its transfer surface has been audited.
    package QtdDeleteFn _deleter;

    this(void *c, bool isQObj) @nogc nothrow { _cpp = c; _isQObj = isQObj; }

    // THE LESS-DERIVED VIEWS THIS WRAPPER REPLACED (see `wrapAs`). They hold the same C++ pointer
    // but are no longer in the identity map, so `destroyed()` would never reach them; it reaches
    // them through here. `_successor` is the other direction: it keeps the replacing wrapper alive
    // for as long as an old view is, so the pair lives and dies together.
    package QtdObject[] _aliases;
    package QtdObject _successor;

    /// C++ deleted the object -> mark dead; a later call throws via checkAlive.
    final void _invalidate() @nogc nothrow {
        _cpp = null;
        foreach (a; _aliases) a._cpp = null;
    }

    /// Register a freshly-constructed wrapper (built by a `new X(args)` ctor, whose _cpp is
    /// already set via super) for identity + lifetime: the same step wrap() runs after make() —
    /// map the C++ pointer to this wrapper, track destroyed(), and pin if it was born parented.
    /// `owned`: this wrapper's object was allocated by the binding (a generated ctor). `wrap()`
    /// passes false — see the note on `_ownedByD`. Defaulted so the 385 generated call sites,
    /// which are all constructors, keep meaning exactly what they meant.
    final void _register(bool owned = true) nothrow {
        _ownedByD = owned;
        qtd_holder_reg(_cpp, cast(void *) this);
        if (_isQObj) {
            qtd_holder_track(_cpp);
            if (qtd_holder_has_parent(_cpp) != 0) _pinned[_cpp] = this;
        }
    }

    /// The generated class says HOW it is freed; the holder decides WHETHER (see the finalizer).
    /// A method rather than a field because `package` does not cross into `qt.<pkg>`, and because
    /// naming it makes the one legitimate caller — the adopt ctor — obvious.
    final void _setDeleter(QtdDeleteFn d) @nogc nothrow { _deleter = d; }

    /// A D subclass / @QObject object adopts its C++ trampoline pointer: set _cpp, register
    /// for identity, PIN (C++ holds a raw dself back-ref, so the GC must not collect this),
    /// and track destroyed(). Called by the moc mixin/newQObject (wrapper mode only).
    final void _adopt(void *c) nothrow {
        _cpp = c;
        _ownedByD = true;   // the C++ trampoline was created for THIS D object, by us

        qtd_holder_reg(c, cast(void *) this);
        qtd_holder_track(c);
        _pinned[c] = this;
    }

    final void checkAlive() {
        if (_cpp is null)
            throw new Error("use of a destroyed C++ object");
    }
    /// The live C++ pointer (throws if already destroyed).
    final void *ptr() { checkAlive(); return _cpp; }

    /// GC finalizer: if still alive and WE own it (no Qt parent), deleteLater it.
    /// A parented object is Qt-owned -> do nothing. Only C calls here (finalizer-safe).
    ~this() @nogc nothrow {
        if (!_live) return;   // runtime shutting down -> don't touch Qt/GC
        if (_ownedByD && _isQObj && _cpp !is null
                && qtd_holder_has_parent(_cpp) == 0 && qtd_holder_is_app(_cpp) == 0)
            qtd_holder_delete_later(_cpp);   // QObject WE created and Qt has not adopted
        // ...and a NON-QObject we still own: nobody took it, so nobody else will free it. There is
        // no deleteLater here and there must not be — that is a QObject event, and this type has no
        // event loop, no parent and no destroyed(). Ownership was decided at the calls that move it
        // (see `transferred`), never by asking now, because asking would dereference a pointer Qt
        // may already have freed.
        else if (_ownedByD && !_isQObj && _cpp !is null && _deleter !is null)
            _deleter(_cpp);
        // Only the wrapper the map holds may remove the entry: after a promotion the retired view
        // shares the pointer, and its finalizer must not unmap the wrapper that replaced it.
        if (_cpp !is null && qtd_holder_find(_cpp) is cast(void *) this)
            qtd_holder_unreg(_cpp);
    }
}

// Parented children pinned here (a GC root) so they outlive any dropped D reference.
private __gshared QtdObject[void *] _pinned;

// True between module init and teardown. destroyed() fires from Qt during exit() too
// (posted deleteLater events), when the D runtime is going down — touching the GC then
// crashes, so guard on this (mirrors Shiboken bailing on !Py_IsInitialized).
private __gshared bool _live = false;

shared static this() { qtd_holder_set_destroyed_hook(&onDestroyed); _live = true; }
shared static ~this() { _live = false; }

/// ---- leak instrumentation ---------------------------------------------------------------
///
/// Two numbers, because the two tables fail differently and a single total would hide which one
/// did. `wrapperCount` is every C++ pointer that currently has a D wrapper; `pinnedCount` is the
/// subset the binding holds as a GC root, which is the one that can retain memory the collector
/// would otherwise have taken back. A probe reads both at the start and end of a workload: flat
/// across a cycle that allocates means the retention is NOT here, and that reading is worth as
/// much as the positive one — it is what lets a caller stop looking at this layer.
size_t wrapperCount() @nogc nothrow { return qtd_holder_count(); }
/// ...and the pinned subset (parented children + adopted D subclasses). See `_pinned`.
size_t pinnedCount() @nogc nothrow { return _pinned.length; }

/// The existing wrapper for a C++ pointer, or null.
QtdObject find(void *cptr) @nogc nothrow {
    return cast(QtdObject) qtd_holder_find(cptr);
}

/// Retrieve-or-wrap: identity for a C++ pointer. `make` builds the correct wrapper
/// type when none exists yet (the orphan path). A newly-wrapped, already-parented
/// object is pinned immediately. `isQObj` gates the destroyed() hook + the parent
/// query — a non-QObject has neither (touching them would misuse a non-QObject as one).
QtdObject wrap(void *cptr, scope QtdObject delegate(void *) make) {
    if (cptr is null) return null;
    if (auto w = find(cptr)) return w;
    auto w = make(cptr);           // make() sets w._cpp = cptr via the adopt ctor
    w._register(false);            // BORROWED: Qt handed us this pointer, we did not allocate it
    return w;
}

/// `wrap`, ASKED FOR A TYPE. Identity makes the FIRST wrapper of a pointer the only one, and Qt
/// mostly hands objects back as `QObject*` — `QQmlApplicationEngine::rootObjects()` does — so the
/// QObject view came first and `QQuickWindow.wrap(p)` returned it, cast to null: a window the
/// binding could never reach as a window. When the existing wrapper is not a `T` and Qt's
/// meta-object says the object IS a `cppClass`, the existing view is PROMOTED: a `T` wrapper
/// takes over the map entry, the pin and the ownership, and the old view is kept as its alias so
/// `destroyed()` still invalidates it. A pointer Qt says is not a `cppClass` answers null, as before.
T wrapAs(T : QtdObject)(void *cptr, scope QtdObject delegate(void *) make, const(char) *cppClass) {
    if (cptr is null) return null;
    auto old = find(cptr);
    if (old is null) return cast(T) wrap(cptr, make);
    if (auto t = cast(T) old) return t;
    if (!old._isQObj || old._cpp is null || qtd_holder_inherits(cptr, cppClass) == 0) return null;
    QtdObject w = make(cptr);   // typed as the base: the fields below are `package`, and a
    auto t = cast(T) w;         // `T` from another package does not see them
    if (t is null) return null;
    w._ownedByD = old._ownedByD;
    old._ownedByD = false;   // ownership moves with the map entry: only one finalizer may act
    w._aliases = old._aliases ~ old;
    old._aliases = null;
    old._successor = w;
    qtd_holder_reg(cptr, cast(void *) w);   // destroyed() is already tracked: once per object
    if (cptr in _pinned) _pinned[cptr] = w;
    return t;
}

/// Parenting pins the child; call when a parent is established (ctor-with-parent / setParent).
void pin(void *cptr, QtdObject w) nothrow { _pinned[cptr] = w; }
void unpin(void *cptr) nothrow { _pinned.remove(cptr); }

/// Re-evaluate a wrapper's pin against its CURRENT Qt parent. Called after any non-const
/// method (which may have re-parented `this` or an object argument via setParent / a layout
/// add-remove / etc.): gained a parent -> pin (survives with the parent even with no D ref);
/// lost its parent -> unpin (now D-owned again -> the GC may collect + deleteLater it).
void reparented(QtdObject w) nothrow {
    if (w is null || w._cpp is null || !w._isQObj) return;
    auto c = w._cpp;
    bool nowParented = qtd_holder_has_parent(c) != 0;
    bool pinned = (c in _pinned) !is null;
    if (nowParented && !pinned) _pinned[c] = w;
    else if (!nowParented && pinned) _pinned.remove(c);
}

/// OWNERSHIP MOVES AT THE CALL THAT MOVES IT. For a `QObject` the question can be asked afterwards
/// — `reparented()` above asks Qt who the parent is now. For everything else it cannot, and that is
/// not an inconvenience but the whole difficulty: `QTreeWidget` deletes its items and
/// `QLayout` deletes its `QLayoutItem`s with no signal at all, so by the time a finalizer wants to
/// know, the object it would have to ask may already be freed. Measured: destroy a QTreeWidget and
/// the item's wrapper still reports `_cpp` non-null. **The question is itself the use-after-free.**
///
/// So the transfer is recorded where the API says it happens. `QTreeWidget::addTopLevelItem` takes
/// ownership; the generated method calls this on the argument, and the wrapper stops being the
/// owner from that line on — nothing has to be asked later.
///
/// The failure modes are NOT symmetric, which is why the list of such methods is per class and
/// audited rather than guessed: a method that transfers and is MISSING from the list leaves us
/// believing we own something Qt will delete (double free), while a method wrongly listed only
/// means nobody deletes it (leak). Deletion is therefore enabled per class, and only for classes
/// whose transfer surface has been walked.
void transferred(QtdObject w) nothrow {
    if (w is null) return;
    w._ownedByD = false;
}

/// ...and the other direction: `takeTopLevelItem`, `takeAt`, `takeItem` hand the object BACK, so
/// the caller owns it again. Without this the ladder is one-way and a taken item leaks forever.
void takenBack(QtdObject w) nothrow {
    if (w is null) return;
    w._ownedByD = true;
}

/// destroyed() hook: C++ deleted the object -> invalidate any live wrapper + drop it.
extern (C) void onDestroyed(void *cptr) nothrow {
    if (!_live) return;   // runtime shutting down -> don't touch the GC
    if (auto w = find(cptr)) w._invalidate();
    qtd_holder_unreg(cptr);
    _pinned.remove(cptr);
}
