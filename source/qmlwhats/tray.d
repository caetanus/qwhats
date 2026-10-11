// The tray icon and its menu, spoken straight to the session bus: a StatusNotifierItem
// (org.kde.StatusNotifierItem, what waybar/qbar/KDE/GNOME's AppIndicator show) whose menu is a
// com.canonical.dbusmenu. Qt's own tray menu needs QtWidgets (the host is a QGuiApplication), so the
// whole thing is here, over sd-bus. Qt-free.
//
// The bus lives on its OWN THREAD. A bar asks the item synchronously (properties, GetLayout); served
// from the UI thread, every second the UI spends busy (QtWebEngine starting, a page loading) froze
// the whole bar with it. Here the bus thread answers at once from a copy of the state kept under a
// lock; the UI thread only swaps that state (setIcon/setMenu) and, from its timer, `drain`s the
// clicks the bus thread queued — TrayControl is called on the UI thread only.
module qmlwhats.tray;

import qmlwhats.sdbus;
import std.string : toStringz, fromStringz;

/// One menu entry. `toggle`: a checkmark entry showing `checked`.
struct MenuEntry {
    int id;
    string label;            // "" with separator
    bool separator;
    bool toggle;
    bool checked;
}

interface TrayControl {
    void activate();           // a click on the icon
    void secondary();          // a middle click
    void menuClicked(int id);  // an entry of the menu
    void registered(bool ok);  // the watcher took the item (or lost it)
}

final class Tray {
    import core.sync.mutex : Mutex;
    import core.thread : Thread;
    import core.atomic : atomicLoad, atomicStore;

    private sd_bus* bus;
    private sd_bus_slot* itemSlot, menuSlot, matchSlot;
    private TrayControl control;
    private string service;
    private Mutex lock;
    private Thread thread;
    private shared bool stopping;

    // under `lock`: the state the bus thread serves, what it must announce, what it heard
    private string iconPath, title = "QWhats", tooltip = "QWhats";
    private MenuEntry[] menu;
    private uint revision = 1;
    private bool iconDirty, tipDirty, menuDirty;
    private Event[] events;
    private struct Event { int kind; int id; bool ok; }   // kind: 0 activate, 1 secondary, 2 menu, 3 registered

    this(TrayControl c) { control = c; lock = new Mutex; }

    /// Connect, publish and start the bus thread. False: no session bus (no tray).
    bool open() {
        if (sd_bus_open_user(&bus) < 0) { bus = null; return false; }
        auto self = cast(void*) this;
        if (sd_bus_add_object_vtable(bus, &itemSlot, ITEM_PATH, ITEM_IFACE, itemVtable.ptr, self) < 0
            || sd_bus_add_object_vtable(bus, &menuSlot, MENU_PATH, MENU_IFACE, menuVtable.ptr, self) < 0) {
            close();
            return false;
        }
        import std.process : thisProcessID;
        import std.conv : to;
        service = "org.kde.StatusNotifierItem-" ~ thisProcessID.to!string ~ "-1";
        if (sd_bus_request_name(bus, service.toStringz, 0) < 0) { close(); return false; }
        // The watcher is the bar: when it (re)starts, the item registers again.
        cast(void) sd_bus_add_match(bus, &matchSlot,
            "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'",
            &onWatcherChanged, self);
        register();
        thread = new Thread(&run);
        thread.isDaemon = true;   // never holds the process at exit
        thread.start();
        return true;
    }

    private void run() {
        while (!atomicLoad(stopping)) {
            announce();
            while (sd_bus_process(bus, null) > 0) {}
            sd_bus_wait(bus, 50_000);   // µs: wakes for traffic, or to announce a change
        }
    }

    /// The signals for what the UI thread changed (on the bus thread: sd-bus is single-threaded).
    private void announce() {
        bool icon, tip, menuNow;
        uint rev;
        synchronized (lock) {
            icon = iconDirty; tip = tipDirty; menuNow = menuDirty; rev = revision;
            iconDirty = tipDirty = menuDirty = false;
        }
        if (icon) cast(void) sd_bus_emit_signal(bus, ITEM_PATH, ITEM_IFACE, "NewIcon", null);
        if (tip) cast(void) sd_bus_emit_signal(bus, ITEM_PATH, ITEM_IFACE, "NewToolTip", null);
        if (menuNow) cast(void) sd_bus_emit_signal(bus, MENU_PATH, MENU_IFACE, "LayoutUpdated", "ui", rev, 0);
    }

    private void queue(Event e) nothrow {
        try synchronized (lock) events ~= e;
        catch (Exception) {}
    }

    /// On the UI thread (its timer): hand what the bus thread heard to the backend.
    void drain() {
        Event[] got;
        synchronized (lock) { got = events; events = null; }
        foreach (e; got) final switch (e.kind) {
            case 0: control.activate(); break;
            case 1: control.secondary(); break;
            case 2: control.menuClicked(e.id); break;
            case 3: control.registered(e.ok); break;
        }
    }

    void close() {
        if (thread !is null) { atomicStore(stopping, true); thread.join(); thread = null; }
        if (matchSlot) matchSlot = sd_bus_slot_unref(matchSlot);
        if (itemSlot) itemSlot = sd_bus_slot_unref(itemSlot);
        if (menuSlot) menuSlot = sd_bus_slot_unref(menuSlot);
        if (bus) bus = sd_bus_flush_close_unref(bus);
    }

    /// New icon / tooltip: the bar is told (by the bus thread) and reads them again.
    void setIcon(string path, string tip) {
        synchronized (lock) {
            if (path != iconPath) iconDirty = true;
            if (tip != tooltip) tipDirty = true;
            iconPath = path;
            tooltip = tip;
        }
    }

    /// New menu (labels, checkmarks): LayoutUpdated makes the bar fetch it again.
    void setMenu(MenuEntry[] entries) {
        synchronized (lock) {
            menu = entries.dup;
            ++revision;
            menuDirty = true;
        }
    }

private:
    enum ITEM_PATH = "/StatusNotifierItem", ITEM_IFACE = "org.kde.StatusNotifierItem";
    enum MENU_PATH = "/MenuBar", MENU_IFACE = "com.canonical.dbusmenu";

    static Tray of(void* u) nothrow { return cast(Tray) u; }

    void register() {
        cast(void) sd_bus_call_method_async(bus, null, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem", &onRegistered, cast(void*) this,
            "s", service.toStringz);
    }

    extern (C) static int onRegistered(sd_bus_message* m, void* u, sd_bus_error* err) nothrow {
        of(u).queue(Event(3, 0, sd_bus_message_is_method_error(m, null) == 0));
        return 0;
    }

    extern (C) static int onWatcherChanged(sd_bus_message* m, void* u, sd_bus_error* err) nothrow {
        const(char)* name, oldOwner, newOwner;
        if (sd_bus_message_read(m, "sss", &name, &oldOwner, &newOwner) < 0) return 0;
        try {
            if (newOwner !is null && *newOwner != 0) of(u).register();
            else of(u).queue(Event(3, 0, false));
        } catch (Exception) {}
        return 0;
    }

    // ---- org.kde.StatusNotifierItem --------------------------------------------------------
    extern (C) static int onItemMethod(sd_bus_message* m, void* u, sd_bus_error* err) nothrow {
        try {
            auto t = of(u);
            switch (sd_bus_message_get_member(m).fromStringz) {
                case "Activate": t.queue(Event(0)); break;
                case "SecondaryActivate": t.queue(Event(1)); break;
                case "ContextMenu": break;   // the bar opens the dbusmenu itself
                case "Scroll": break;
                default: return -22;
            }
            return sd_bus_reply_method_return(m, null);
        } catch (Exception) return -5;
    }

    extern (C) static int getItemProp(sd_bus* b, const(char)* path, const(char)* iface, const(char)* prop,
                                      sd_bus_message* r, void* u, sd_bus_error* err) nothrow {
        try {
            auto t = of(u).snapshot();
            int no = 0, zero = 0;
            switch (prop.fromStringz) {
                case "Category": return sd_bus_message_append_basic(r, 's', "Communications".ptr);
                case "Id": return sd_bus_message_append_basic(r, 's', "qwhats".ptr);
                case "Title": return sd_bus_message_append_basic(r, 's', t.title.toStringz);
                case "Status": return sd_bus_message_append_basic(r, 's', "Active".ptr);
                case "WindowId": return sd_bus_message_append_basic(r, 'i', &zero);
                case "IconName": return sd_bus_message_append_basic(r, 's', t.iconPath.toStringz);
                case "IconThemePath": {
                    import std.path : dirName;
                    return sd_bus_message_append_basic(r, 's', (t.iconPath.length ? dirName(t.iconPath) : "").toStringz);
                }
                case "OverlayIconName": case "AttentionIconName": case "AttentionMovieName":
                    return sd_bus_message_append_basic(r, 's', "".ptr);
                case "IconPixmap": case "OverlayIconPixmap": case "AttentionIconPixmap": {
                    int rc = sd_bus_message_open_container(r, 'a', "(iiay)");
                    if (rc >= 0) rc = sd_bus_message_close_container(r);
                    return rc;
                }
                case "ToolTip": {   // (s icon, a(iiay) pixmaps, s title, s text)
                    int rc = sd_bus_message_open_container(r, 'r', "sa(iiay)ss");
                    if (rc >= 0) rc = sd_bus_message_append_basic(r, 's', t.iconPath.toStringz);
                    if (rc >= 0) rc = sd_bus_message_open_container(r, 'a', "(iiay)");
                    if (rc >= 0) rc = sd_bus_message_close_container(r);
                    if (rc >= 0) rc = sd_bus_message_append_basic(r, 's', t.title.toStringz);
                    if (rc >= 0) rc = sd_bus_message_append_basic(r, 's', t.tooltip.toStringz);
                    if (rc >= 0) rc = sd_bus_message_close_container(r);
                    return rc;
                }
                case "ItemIsMenu": return sd_bus_message_append_basic(r, 'b', &no);
                case "Menu": return sd_bus_message_append_basic(r, 'o', MENU_PATH.ptr);
                default: return -22;
            }
        } catch (Exception) return -5;
    }

    // ---- com.canonical.dbusmenu ------------------------------------------------------------
    // a{sv} of one entry
    static int appendProps(sd_bus_message* r, const MenuEntry* e) {
        int rc = sd_bus_message_open_container(r, 'a', "{sv}");
        void str(string k, string v) {
            if (rc < 0) return;
            rc = sd_bus_message_open_container(r, 'e', "sv");
            if (rc >= 0) rc = sd_bus_message_append_basic(r, 's', k.toStringz);
            if (rc >= 0) rc = sd_bus_message_open_container(r, 'v', "s");
            if (rc >= 0) rc = sd_bus_message_append_basic(r, 's', v.toStringz);
            if (rc >= 0) rc = sd_bus_message_close_container(r);
            if (rc >= 0) rc = sd_bus_message_close_container(r);
        }
        void num(string k, int v) {
            if (rc < 0) return;
            rc = sd_bus_message_open_container(r, 'e', "sv");
            if (rc >= 0) rc = sd_bus_message_append_basic(r, 's', k.toStringz);
            if (rc >= 0) rc = sd_bus_message_open_container(r, 'v', "i");
            if (rc >= 0) rc = sd_bus_message_append_basic(r, 'i', &v);
            if (rc >= 0) rc = sd_bus_message_close_container(r);
            if (rc >= 0) rc = sd_bus_message_close_container(r);
        }
        if (e is null) str("children-display", "submenu");
        else if (e.separator) str("type", "separator");
        else {
            str("label", e.label);
            if (e.toggle) { str("toggle-type", "checkmark"); num("toggle-state", e.checked ? 1 : 0); }
        }
        if (rc >= 0) rc = sd_bus_message_close_container(r);
        return rc;
    }

    // (ia{sv}av): the root (e is null) with every entry as a child, or one entry alone
    static int appendLayout(sd_bus_message* r, const(MenuEntry)[] menu, const MenuEntry* e) {
        int id = e is null ? 0 : e.id;
        int rc = sd_bus_message_open_container(r, 'r', "ia{sv}av");
        if (rc >= 0) rc = sd_bus_message_append_basic(r, 'i', &id);
        if (rc >= 0) rc = appendProps(r, e);
        if (rc >= 0) rc = sd_bus_message_open_container(r, 'a', "v");
        if (e is null)
            foreach (ref child; menu) {
                if (rc >= 0) rc = sd_bus_message_open_container(r, 'v', "(ia{sv}av)");
                if (rc >= 0) rc = appendLayout(r, menu, &child);
                if (rc >= 0) rc = sd_bus_message_close_container(r);
            }
        if (rc >= 0) rc = sd_bus_message_close_container(r);
        if (rc >= 0) rc = sd_bus_message_close_container(r);
        return rc;
    }

    // a consistent copy of the served state (the UI thread may swap it at any moment)
    static struct State { string iconPath, title, tooltip; MenuEntry[] menu; uint revision; }
    State snapshot() {
        synchronized (lock) return State(iconPath, title, tooltip, menu, revision);
    }

    static const(MenuEntry)* find(const(MenuEntry)[] menu, int id) {
        foreach (ref e; menu) if (e.id == id) return &e;
        return null;
    }

    extern (C) static int onMenuMethod(sd_bus_message* m, void* u, sd_bus_error* err) nothrow {
        try {
            auto tray = of(u);
            auto t = tray.snapshot();
            sd_bus_message* reply;
            switch (sd_bus_message_get_member(m).fromStringz) {
                case "GetLayout": {
                    int parent, depth;
                    if (sd_bus_message_read(m, "ii", &parent, &depth) < 0) return -22;
                    if (sd_bus_message_new_method_return(m, &reply) < 0) return -12;
                    scope (exit) sd_bus_message_unref(reply);
                    int rc = sd_bus_message_append_basic(reply, 'u', &t.revision);
                    if (rc >= 0) rc = appendLayout(reply, t.menu, parent == 0 ? null : find(t.menu, parent));
                    if (rc < 0) return rc;
                    return sd_bus_send(null, reply, null);
                }
                case "GetGroupProperties": {
                    int[] ids;
                    if (sd_bus_message_enter_container(m, 'a', "i") < 0) return -22;
                    int id;
                    while (sd_bus_message_read_basic(m, 'i', &id) > 0) ids ~= id;
                    sd_bus_message_exit_container(m);
                    if (!ids.length) foreach (ref e; t.menu) ids ~= e.id;
                    if (sd_bus_message_new_method_return(m, &reply) < 0) return -12;
                    scope (exit) sd_bus_message_unref(reply);
                    int rc = sd_bus_message_open_container(reply, 'a', "(ia{sv})");
                    foreach (i; ids) {
                        auto e = i == 0 ? null : find(t.menu, i);
                        if (i != 0 && e is null) continue;
                        if (rc >= 0) rc = sd_bus_message_open_container(reply, 'r', "ia{sv}");
                        if (rc >= 0) rc = sd_bus_message_append_basic(reply, 'i', &i);
                        if (rc >= 0) rc = appendProps(reply, e);
                        if (rc >= 0) rc = sd_bus_message_close_container(reply);
                    }
                    if (rc >= 0) rc = sd_bus_message_close_container(reply);
                    if (rc < 0) return rc;
                    return sd_bus_send(null, reply, null);
                }
                case "GetProperty": {
                    int id;
                    const(char)* name;
                    if (sd_bus_message_read(m, "is", &id, &name) < 0) return -22;
                    auto e = find(t.menu, id);
                    if (sd_bus_message_new_method_return(m, &reply) < 0) return -12;
                    scope (exit) sd_bus_message_unref(reply);
                    int rc = sd_bus_message_open_container(reply, 'v', "s");
                    if (rc >= 0) rc = sd_bus_message_append_basic(reply, 's', (e is null ? "" : e.label).toStringz);
                    if (rc >= 0) rc = sd_bus_message_close_container(reply);
                    if (rc < 0) return rc;
                    return sd_bus_send(null, reply, null);
                }
                case "Event": {
                    int id;
                    const(char)* ev;
                    if (sd_bus_message_read(m, "is", &id, &ev) < 0) return -22;
                    if (ev.fromStringz == "clicked") tray.queue(Event(2, id));
                    return sd_bus_reply_method_return(m, null);
                }
                case "EventGroup": {
                    if (sd_bus_message_enter_container(m, 'a', "(isvu)") >= 0) {
                        while (sd_bus_message_enter_container(m, 'r', "isvu") > 0) {
                            int id;
                            const(char)* ev;
                            if (sd_bus_message_read(m, "is", &id, &ev) >= 0 && ev.fromStringz == "clicked") tray.queue(Event(2, id));
                            sd_bus_message_skip(m, "vu");
                            sd_bus_message_exit_container(m);
                        }
                        sd_bus_message_exit_container(m);
                    }
                    if (sd_bus_message_new_method_return(m, &reply) < 0) return -12;
                    scope (exit) sd_bus_message_unref(reply);
                    int rc = sd_bus_message_open_container(reply, 'a', "i");
                    if (rc >= 0) rc = sd_bus_message_close_container(reply);
                    if (rc < 0) return rc;
                    return sd_bus_send(null, reply, null);
                }
                case "AboutToShow": {
                    int no = 0;
                    if (sd_bus_message_new_method_return(m, &reply) < 0) return -12;
                    scope (exit) sd_bus_message_unref(reply);
                    if (sd_bus_message_append_basic(reply, 'b', &no) < 0) return -12;
                    return sd_bus_send(null, reply, null);
                }
                case "AboutToShowGroup": {
                    if (sd_bus_message_new_method_return(m, &reply) < 0) return -12;
                    scope (exit) sd_bus_message_unref(reply);
                    int rc = sd_bus_message_open_container(reply, 'a', "i");
                    if (rc >= 0) rc = sd_bus_message_close_container(reply);
                    if (rc >= 0) rc = sd_bus_message_open_container(reply, 'a', "i");
                    if (rc >= 0) rc = sd_bus_message_close_container(reply);
                    if (rc < 0) return rc;
                    return sd_bus_send(null, reply, null);
                }
                default: return -22;
            }
        } catch (Exception) return -5;
    }

    extern (C) static int getMenuProp(sd_bus* b, const(char)* path, const(char)* iface, const(char)* prop,
                                      sd_bus_message* r, void* u, sd_bus_error* err) nothrow {
        switch (prop.fromStringz) {
            case "Version": { uint v = 3; return sd_bus_message_append_basic(r, 'u', &v); }
            case "TextDirection": return sd_bus_message_append_basic(r, 's', "ltr".ptr);
            case "Status": return sd_bus_message_append_basic(r, 's', "normal".ptr);
            case "IconThemePath": {
                char*[1] none = [null];
                return sd_bus_message_append_strv(r, none.ptr);
            }
            default: return -22;
        }
    }

    __gshared sd_bus_vtable[] itemVtable, menuVtable;
    shared static this() {
        alias V = sd_bus_vtable;
        enum constant = SD_BUS_VTABLE_PROPERTY_CONST, emits = SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE;
        itemVtable = [V.start()]
            ~ V.method("Activate", "ii", "", &onItemMethod) ~ V.method("SecondaryActivate", "ii", "", &onItemMethod)
            ~ V.method("ContextMenu", "ii", "", &onItemMethod) ~ V.method("Scroll", "is", "", &onItemMethod)
            ~ V.signal("NewIcon", "") ~ V.signal("NewToolTip", "") ~ V.signal("NewTitle", "")
            ~ V.signal("NewStatus", "s")
            ~ V.prop("Category", "s", &getItemProp, constant) ~ V.prop("Id", "s", &getItemProp, constant)
            ~ V.prop("Title", "s", &getItemProp, 0) ~ V.prop("Status", "s", &getItemProp, 0)
            ~ V.prop("WindowId", "i", &getItemProp, constant)
            ~ V.prop("IconName", "s", &getItemProp, 0) ~ V.prop("IconThemePath", "s", &getItemProp, 0)
            ~ V.prop("IconPixmap", "a(iiay)", &getItemProp, 0)
            ~ V.prop("OverlayIconName", "s", &getItemProp, 0) ~ V.prop("OverlayIconPixmap", "a(iiay)", &getItemProp, 0)
            ~ V.prop("AttentionIconName", "s", &getItemProp, 0) ~ V.prop("AttentionIconPixmap", "a(iiay)", &getItemProp, 0)
            ~ V.prop("AttentionMovieName", "s", &getItemProp, 0)
            ~ V.prop("ToolTip", "(sa(iiay)ss)", &getItemProp, 0)
            ~ V.prop("ItemIsMenu", "b", &getItemProp, constant) ~ V.prop("Menu", "o", &getItemProp, constant)
            ~ V.end();
        menuVtable = [V.start()]
            ~ V.method("GetLayout", "iias", "u(ia{sv}av)", &onMenuMethod)
            ~ V.method("GetGroupProperties", "aias", "a(ia{sv})", &onMenuMethod)
            ~ V.method("GetProperty", "is", "v", &onMenuMethod)
            ~ V.method("Event", "isvu", "", &onMenuMethod)
            ~ V.method("EventGroup", "a(isvu)", "ai", &onMenuMethod)
            ~ V.method("AboutToShow", "i", "b", &onMenuMethod)
            ~ V.method("AboutToShowGroup", "ai", "aiai", &onMenuMethod)
            ~ V.signal("LayoutUpdated", "ui") ~ V.signal("ItemsPropertiesUpdated", "a(ia{sv})a(ias)")
            ~ V.prop("Version", "u", &getMenuProp, constant) ~ V.prop("TextDirection", "s", &getMenuProp, constant)
            ~ V.prop("Status", "s", &getMenuProp, constant) ~ V.prop("IconThemePath", "as", &getMenuProp, constant)
            ~ V.end();
    }
}

extern (C) nothrow @nogc int sd_bus_message_is_method_error(sd_bus_message* m, const(char)* name);
extern (C) nothrow @nogc int sd_bus_wait(sd_bus* bus, ulong timeout_usec);
