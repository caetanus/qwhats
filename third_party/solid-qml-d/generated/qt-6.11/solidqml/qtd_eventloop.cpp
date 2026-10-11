// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// QT AS THE EVENT DRIVER FOR A D FIBER RUNTIME.
//
// A program that draws with Qt and does network I/O with vibe-core has two event loops and one
// thread, and only one of them can own the wait. Polling the second one costs a wakeup per
// millisecond whether or not anything happened, and it is what the first version of this measured
// as unacceptable. The answer is to let Qt own the wait and give the OTHER loop's descriptors to
// Qt: `QSocketNotifier` is Qt's own way of saying "tell me when this fd is ready", and it is
// exactly what an event driver needs to be handed over.
//
// This file is the C++ half — three calls and no moc. It is deliberately NOT part of the D binding:
// the D side declares these as `extern(C)` and nothing else, so the driver that uses them can live
// in eventcore's own source tree (its `PosixEventLoop` is package-private, so it must) without that
// tree acquiring any dependency on this project. The same shape eventcore's CFRunLoop driver has
// with CoreFoundation: FFI declarations on one side, the platform on the other.
#include <QtCore/QCoreApplication>
#include <QtCore/QSocketNotifier>
#include <QtCore/QObject>
#include <QtCore/QEventLoop>

extern "C" {

// A notifier for one descriptor and one readiness kind. `type` is QSocketNotifier::Type:
// 0 Read, 1 Write, 2 Exception — passed as an int so the D side names no Qt type.
//
// The callback is connected with a LAMBDA, which is what keeps moc out of this: a functor
// connection needs no meta-object of ours, and the notifier is its own context object so the
// connection dies with it.
void* qtd_ec_notifier_new(int fd, int type, void (*cb)(void*, int), void* ctx) {
    if (fd < 0 || !cb) return nullptr;
    auto* n = new QSocketNotifier(qintptr(fd), QSocketNotifier::Type(type));
    QObject::connect(n, &QSocketNotifier::activated, n,
                     [cb, ctx, fd](QSocketDescriptor, QSocketNotifier::Type) { cb(ctx, fd); });
    return n;
}

void qtd_ec_notifier_free(void* n) {
    if (n) delete static_cast<QSocketNotifier*>(n);
}

void qtd_ec_notifier_enable(void* n, int on) {
    if (n) static_cast<QSocketNotifier*>(n)->setEnabled(on != 0);
}

// ONE PASS OF QT'S LOOP, and the only place a timeout is spent. `msecs < 0` waits until something
// happens, which is what "no polling" means: with every descriptor the other runtime cares about
// registered above, Qt's own wait covers both.
//
// Returns 1 when there is an application to run the loop on, 0 when there is not — a program that
// has not built its QCoreApplication yet must not be told the wait succeeded.
int qtd_ec_process(int msecs) {
    if (!QCoreApplication::instance()) return 0;
    // THREE SEMANTICS, and getting them from one flag is what a first version got wrong:
    //   msecs  < 0 — wait until something happens, however long that is. This is the one that
    //                makes "no polling" true, and it needs WaitForMoreEvents with no deadline.
    //   msecs == 0 — drain what is already pending and return. A driver asks for this when it
    //                only wants to service what the last wait produced.
    //   msecs  > 0 — wait, but not past that deadline, because the caller has a timer of its own.
    // Passing a deadline WITHOUT WaitForMoreEvents does not wait at all: measured, a 60 ms request
    // returned in 0 ms, which reads exactly like a busy loop from the outside.
    if (msecs < 0)
        QCoreApplication::processEvents(QEventLoop::AllEvents | QEventLoop::WaitForMoreEvents);
    else if (msecs == 0)
        QCoreApplication::processEvents(QEventLoop::AllEvents);
    else
        QCoreApplication::processEvents(QEventLoop::AllEvents | QEventLoop::WaitForMoreEvents, msecs);
    return 1;
}

}  // extern "C"
