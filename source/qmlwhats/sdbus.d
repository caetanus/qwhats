// sd-bus (libsystemd's D-Bus C API), the parts this app uses — the declarations and the vtable
// helpers are solid-player's (source/solidplayer/mpris.d), same author; link with -lsystemd.
module qmlwhats.sdbus;

import std.string : toStringz;

// --- sd-bus, the parts used (systemd/sd-bus.h, sd-bus-vtable.h) ----------------------------------

extern (C) nothrow @nogc {
    struct sd_bus;
    struct sd_bus_slot;
    struct sd_bus_message;
    struct sd_bus_error { const(char)* name, message; int _need_free; }

    extern __gshared const uint sd_bus_object_vtable_format;

    int sd_bus_open_user(sd_bus** ret);
    sd_bus* sd_bus_flush_close_unref(sd_bus* bus);
    int sd_bus_request_name(sd_bus* bus, const(char)* name, ulong flags);
    int sd_bus_process(sd_bus* bus, sd_bus_message** r);
    int sd_bus_add_object_vtable(sd_bus* bus, sd_bus_slot** slot, const(char)* path, const(char)* iface,
                                 const(sd_bus_vtable)* vtable, void* userdata);
    sd_bus_slot* sd_bus_slot_unref(sd_bus_slot* slot);
    int sd_bus_emit_properties_changed_strv(sd_bus* bus, const(char)* path, const(char)* iface, char** names);
    int sd_bus_emit_signal(sd_bus* bus, const(char)* path, const(char)* iface, const(char)* member,
                           const(char)* types, ...);
    int sd_bus_reply_method_return(sd_bus_message* call, const(char)* types, ...);
    int sd_bus_call_method_async(sd_bus* bus, sd_bus_slot** slot, const(char)* destination, const(char)* path,
                                 const(char)* iface, const(char)* member, sd_bus_message_handler_t callback,
                                 void* userdata, const(char)* types, ...);
    const(char)* sd_bus_message_get_member(sd_bus_message* m);
    int sd_bus_message_read_basic(sd_bus_message* m, char type, void* p);
    int sd_bus_message_read(sd_bus_message* m, const(char)* types, ...);
    int sd_bus_message_append_basic(sd_bus_message* m, char type, const(void)* p);
    int sd_bus_message_append_strv(sd_bus_message* m, char** l);
    int sd_bus_message_open_container(sd_bus_message* m, char type, const(char)* contents);
    int sd_bus_message_close_container(sd_bus_message* m);
}

extern (C) alias sd_bus_message_handler_t = int function(sd_bus_message*, void*, sd_bus_error*) nothrow;
extern (C) alias sd_bus_property_get_t = int function(sd_bus*, const(char)*, const(char)*, const(char)*, sd_bus_message*,
                                                      void*, sd_bus_error*) nothrow;
alias sd_bus_property_set_t = sd_bus_property_get_t;

enum ulong SD_BUS_VTABLE_PROPERTY_CONST = 1UL << 4, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE = 1UL << 5;

/// sd_bus_vtable: `type:8, flags:56` packed in one 64-bit word (little-endian), then a union of up
/// to six pointer-sized fields. The C macros fill it; these helpers do the same.
struct sd_bus_vtable {
    ulong typeAndFlags;
    const(void)*[6] x;   // pointers (GC-visible) or small integers stored as pointers

    static sd_bus_vtable make(char type, ulong flags, const(void)*[6] x...) {
        sd_bus_vtable v;
        v.typeAndFlags = cast(ubyte) type | (flags << 8);
        v.x = x;
        return v;
    }
    private static const(void)* n(size_t v) { return cast(const(void)*) v; }
    private static const(void)* z(string s) { return s.toStringz; }
    static sd_bus_vtable start() {
        return make('<', 0, n(sd_bus_vtable.sizeof), n(1) /* _SD_BUS_VTABLE_PARAM_NAMES */,
                    &sd_bus_object_vtable_format, null, null, null);
    }
    static sd_bus_vtable end() { return make('>', 0, null, null, null, null, null, null); }
    static sd_bus_vtable method(string member, string sig, string result, sd_bus_message_handler_t h) {
        return make('M', 0, z(member), z(sig), z(result), cast(const(void)*) h, null, "".ptr);
    }
    static sd_bus_vtable signal(string member, string sig) {
        return make('S', 0, z(member), z(sig), "".ptr, null, null, null);
    }
    static sd_bus_vtable prop(string member, string sig, sd_bus_property_get_t g, ulong flags) {
        return make('P', flags, z(member), z(sig), cast(const(void)*) g, null, null, null);
    }
    static sd_bus_vtable wprop(string member, string sig, sd_bus_property_get_t g, sd_bus_property_set_t s, ulong flags) {
        return make('W', flags, z(member), z(sig), cast(const(void)*) g, cast(const(void)*) s, null, null);
    }
}

static assert(sd_bus_vtable.sizeof == 56);
// added for the tray: matches, method calls, container reads
extern (C) nothrow @nogc {
    int sd_bus_add_match(sd_bus* bus, sd_bus_slot** slot, const(char)* match, sd_bus_message_handler_t callback, void* userdata);
    int sd_bus_message_enter_container(sd_bus_message* m, char type, const(char)* contents);
    int sd_bus_message_exit_container(sd_bus_message* m);
    int sd_bus_message_skip(sd_bus_message* m, const(char)* types);
    int sd_bus_message_new_method_return(sd_bus_message* call, sd_bus_message** m);
    int sd_bus_send(sd_bus* bus, sd_bus_message* m, ulong* cookie);
    sd_bus_message* sd_bus_message_unref(sd_bus_message* m);
    int sd_bus_get_fd(sd_bus* bus);
}
