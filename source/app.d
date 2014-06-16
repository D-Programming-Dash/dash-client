import dash.api;
import dash.compiler;
import std.exception : enforce;
import std.range;
import std.string : format;
import vibecompat.data.json;

struct ClientConfig {
    string serverName;
    ushort serverPort;
    string sslCACert;
    string sslCert;
    string sslKey;

    string machineName;
    Config globalConfig;
    string workDir;
    string tempDir;
}

ClientConfig readClientConfig(string path) {
    import std.algorithm;
    import file = std.file;
    import std.path;

    auto json = file.readText(path).parseJsonString();

    ClientConfig result;

    auto server = json["resultServer"];
    result.serverName = server["host"].get!string;
    result.serverPort = server["port"].get!ushort;

    result.machineName = json["machineName"].get!string;
    deserializeJson(result.globalConfig, json["globalConfig"]);

    immutable configDir = absolutePath(path).dirName;
    auto paths = json["paths"];
    auto readPath(string name) {
        import std.string;
        import std.file;
        import std.path;

        immutable raw = paths[name].to!string;
        enforce(isValidPath(raw), format("'%s' path '%s' not valid.", name, raw));

        immutable expanded = raw.expandTilde.absolutePath(configDir);
        enforce(expanded.exists, format("'%s' path '%s' does not exist.", name, raw));
        return expanded;
    }
    auto readDir(string name) {
        import std.file;
        auto result = readPath(name);
        enforce(result.isDir, format("'%s' path '%s' is not a directory.", name, result));
        return result;
    }
    result.workDir = readDir("workDir");
    result.tempDir = readDir("tempDir");
    result.sslCACert = readPath("sslCACert");
    result.sslCert = readPath("sslCert");
    result.sslKey = readPath("sslKey");

    return result;
}

string[string] foldConfigs(R)(R configs) if (
    isInputRange!R && is(ElementType!R : const(Config))
) {
    import std.algorithm;

    string[string] result;
    foreach (config; configs.schwartzSort!(a => a.priority)) {
        foreach (key; config.strings.byKey) {
            result[key] = config.strings[key];
        }
    }
    return result;
}

BenchmarkResult executeBenchmark(string taskId, string sourceDir, Compiler compiler, string[string] config) {
    import dash.benchmark.spec;
    import std.process;

    auto spec = readSpec(sourceDir);

    BenchmarkResult result;
    result.taskId = taskId;
    result.name = spec.name;

    auto uname = execute(["uname", "-a"]);
    enforce(uname.status == 0, "Could not execute uname."); // TODO: Log instead?
    result.testEnvData["systemInfo"] = uname.output;
    result.testEnvData["compilerBanner"] = compiler.readVersionBanner();
    foreach (test; spec.tests) {
        result.tests ~= test.execute(compiler, config);
    }

    return result;
}

void main(string[] args) {
    import dash.scm;
    import thrift.codegen.client;
    import thrift.protocol.compact;
    import thrift.transport.buffered;
    import thrift.transport.socket;
    import thrift.transport.ssl;
    import std.stdio;
    import std.typecons : Nullable;

    enforce(args.length == 2, "Pass exactly one argument, the config file path.");

    auto config = readClientConfig(args[1]);
    string[string] flatten(Config[] c) {
        return foldConfigs(c ~ [config.globalConfig]);
    }

    auto sslCtx = new TSSLContext();
    with (sslCtx) {
        serverSide = false;
        loadTrustedCertificates(config.sslCACert);
        loadCertificate(config.sslCert);
        loadPrivateKey(config.sslKey);
        authenticate = true;
    }

    auto socket = new TBufferedTransport(
        new TSSLSocket(sslCtx, config.serverName, config.serverPort));
    auto server = tClient!ResultServer(tCompactProtocol(socket));

    CompilerSource[string] compilerSources;
    CompilerSource getOrCreateCompilerSource(CompilerType type, string name) {
        auto source = name in compilerSources;
        if (source) return *source;
        return (compilerSources[name] = createCompilerSource(
            type, name, config.workDir, config.tempDir));
    }

    writefln("Connecting to server %s (port %s)...", config.serverName, config.serverPort);
    socket.open();
    writeln("...done.");
    while (true) {
        writeln("Polling server for next task...");
        auto task = server.nextTask(config.machineName);
        if (task.isSet!"benchmarkTask") {
            auto bt = task.benchmarkTask;
            writefln("Running benchmark: %s", bt);

            auto benchmarkConfig = flatten(bt.config);
            auto compilerName =
                *enforce("compiler" in benchmarkConfig, "No compiler specified");

            // We need to fetch the compiler configuration from the server if
            // we don't know it, or we no longer have it installed (should not
            // happen during normal operation).
            Nullable!CompilerInfo ci;
            auto compilerSource = compilerSources.get(compilerName, null);
            if (!compilerSource) {
                ci = server.getCompilerInfo(config.machineName, compilerName);
                compilerSource = getOrCreateCompilerSource(ci.type, ci.name);
            }

            auto compiler = compilerSource.getCompiler();
            if (!compiler) {
                if (ci.isNull) {
                    ci = server.getCompilerInfo(config.machineName, compilerName);
                }
                writefln("Updating compiler: %s", compilerName);
                compilerSource.update(flatten(ci.config));
                compiler = compilerSource.getCompiler();
            }

            auto benchmarkDir = cloneOrFetch(bt.scmUrl, bt.scmRevision, config.workDir);

            auto result = executeBenchmark(bt.id, benchmarkDir, compiler, benchmarkConfig);
            server.postResult(config.machineName, result);
        } else if (task.isSet!"compilerUpdateTask") {
            auto cut = task.compilerUpdateTask;
            writefln("Updating compiler: %s", cut);

            auto source = getOrCreateCompilerSource(cut.type, cut.name);
            source.update(flatten(cut.config));
        } else {
            writeln("No task to perform, sleeping.");
            import core.thread;
            import core.time;
            // TODO: Make longer and configurable.
            Thread.sleep(5.seconds);
        }
    }
}
