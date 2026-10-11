// qml-whats' build: a D application (DSide) with a solid-qml UI, through solid-qml-d.
//
//     reggae -b binary . --reggaefile-import-path $PWD/../dside/reggae --reggaefile-import-path $PWD/../solid-qml-d/reggae
//     ./build ui && ./build qml-whats-ldc2 && ./qml-whats-ldc2
import reggae;
import qtd_build;
import solidqml_build;
import std.file : getcwd;

string[] appSources(string here) {
    import std.file : dirEntries, SpanMode;
    string[] out_;
    foreach (e; dirEntries(buildPath(here, "source", "qmlwhats"), "*.d", SpanMode.depth)) out_ ~= e.name;
    return out_;
}

Build reggaeBuild() {
    auto s = solidQml();
    auto here = getcwd();
    // The UI is plain QML (ui/qml/), copied beside the binary. (ui/main.tsx + ui/app/ is the solid-qml
    // TSX version, kept for when solid-qml's CSS engine stops re-laying-out hovered items: `./build ui-tsx`.)
    Target[] all = [Target.phony("ui", "rm -rf " ~ buildPath(here, "qml") ~ " && mkdir -p " ~ buildPath(here, "qml")
                                 ~ " && cp " ~ buildPath(here, "ui", "qml") ~ "/*.qml " ~ buildPath(here, "qml") ~ "/", []),
                    solidQmlUi(s, "ui-tsx", buildPath(here, "ui", "main.tsx"), buildPath(here, "qml-tsx"))];
    foreach (dc; ["ldc2", "dmd"])
        all ~= solidQmlApp(s, "qml-whats-" ~ dc, buildPath(here, "source", "app.d"), dc,
                           appSources(here), [buildPath(here, "source")], [],
                           ["-J" ~ buildPath(here, "assets", "icons"), "-J" ~ buildPath(here, "assets"), "-L-lsystemd"]);
    all ~= Target.phony("unittest", "cd " ~ here
                        ~ " && ldc2 -unittest -main -run source/qmlwhats/settings.d"
                        ~ " && ldc2 -unittest -main -run source/qmlwhats/env.d"
                        ~ " && ldc2 -unittest -main -run source/qmlwhats/single.d"
                        ~ " && ldc2 -unittest -main -run source/qmlwhats/rpc.d"
                        ~ " && echo unittest OK", []);
    return Build(all);
}

mixin BuildgenMain;
