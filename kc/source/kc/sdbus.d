/// sd-bus (libsystemd's D-Bus C API): the client side this package uses — method calls, signal
/// matches, reading containers. The same declarations as the app's qmlwhats.sdbus, plus calls.
module kc.sdbus;

extern (C) nothrow @nogc {
    struct sd_bus;
    struct sd_bus_slot;
    struct sd_bus_message;
    struct sd_bus_error { const(char)* name, message; int _need_free; }

    int sd_bus_open_user(sd_bus** bus);
    sd_bus* sd_bus_flush_close_unref(sd_bus* bus);
    int sd_bus_process(sd_bus* bus, sd_bus_message** r);
    int sd_bus_get_fd(sd_bus* bus);
    int sd_bus_get_events(sd_bus* bus);
    int sd_bus_get_timeout(sd_bus* bus, ulong* usec);
    int sd_bus_flush(sd_bus* bus);
    int sd_bus_add_match(sd_bus* bus, sd_bus_slot** slot, const(char)* match, sd_bus_message_handler_t callback, void* userdata);
    sd_bus_slot* sd_bus_slot_unref(sd_bus_slot* slot);

    int sd_bus_message_new_method_call(sd_bus* bus, sd_bus_message** m, const(char)* destination, const(char)* path,
                                       const(char)* iface, const(char)* member);
    int sd_bus_call(sd_bus* bus, sd_bus_message* m, ulong usec, sd_bus_error* ret_error, sd_bus_message** reply);
    int sd_bus_call_async(sd_bus* bus, sd_bus_slot** slot, sd_bus_message* m, sd_bus_message_handler_t callback,
                          void* userdata, ulong usec);
    sd_bus_message* sd_bus_message_unref(sd_bus_message* m);
    sd_bus_message* sd_bus_message_ref(sd_bus_message* m);
    void sd_bus_error_free(sd_bus_error* e);
    const(sd_bus_error)* sd_bus_message_get_error(sd_bus_message* m);
    int sd_bus_message_is_method_error(sd_bus_message* m, const(char)* name);

    const(char)* sd_bus_message_get_member(sd_bus_message* m);
    const(char)* sd_bus_message_get_path(sd_bus_message* m);
    const(char)* sd_bus_message_get_interface(sd_bus_message* m);
    int sd_bus_message_read_basic(sd_bus_message* m, char type, void* p);
    int sd_bus_message_enter_container(sd_bus_message* m, char type, const(char)* contents);
    int sd_bus_message_exit_container(sd_bus_message* m);
    int sd_bus_message_skip(sd_bus_message* m, const(char)* types);
    int sd_bus_message_peek_type(sd_bus_message* m, char* type, const(char)** contents);
    int sd_bus_message_append_basic(sd_bus_message* m, char type, const(void)* p);
    int sd_bus_message_open_container(sd_bus_message* m, char type, const(char)* contents);
    int sd_bus_message_close_container(sd_bus_message* m);
}
extern (C) alias sd_bus_message_handler_t = int function(sd_bus_message*, void*, sd_bus_error*) nothrow;
