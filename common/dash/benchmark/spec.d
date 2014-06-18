module dash.benchmark.spec;

import dash.api.benchmark;
import dash.compiler;
import std.algorithm : all, map, copy, join;
import vibecompat.data.json;

interface Test {
    @property string name();
    TestResult execute(Compiler compiler, string[string] configStrings);
}

class DefaultTest : Test {
    this(string rootDir, Json specData) {
        _rootDir = rootDir;
        _name = specData["name"].get!string;
        foreach (f; specData["sourceFiles"]) {
            _sourceFiles ~= f.get!string;
        }
    }

    override @property string name() {
        return _name;
    }

    TestResult execute(Compiler compiler, string[string] configStrings) {
        import process_stats;
        import std.array : array;
        import std.conv : to;
        import file = std.file;
        import std.path : buildPath;
        import std.process : spawnProcess;

        int workFactor = 1;
        if (auto wf = "workFactor" in configStrings) {
            workFactor = to!int(*wf);
        }
        enforce(workFactor > 0, "Work factor must be positive.");


        file.chdir(_rootDir);

        // DMD @@BUG@@: Cannot make compileCommand immutable.
        auto compileCommand = compiler.buildCompileCommand(name,
            _sourceFiles, configStrings);

        // Would like to use UFCS for these, does not work…
        static void add(ref double[][string] samples, string name, double value) {
            if (auto array = name in samples) {
                *array ~= value;
            } else {
                samples[name] = [value];
            }
        }
        static void addStats(ref double[][string] samples, const ref Stats stats) {
            add(samples, "totalSeconds", stats.totalTime.to!("seconds", double));
            add(samples, "maxMemKB", stats.maxMemKB);
        }

        // TODO: Which order of phases gives the more relevant result w.r.t.
        // cache warming, …? First all compilations, then the test execution,
        // or interleaved?
        auto buildPhase = TestPhase("build");
        foreach (i; 0 .. workFactor) {
            auto compileStats = executeWithStats!spawnProcess(compileCommand);
            if (compileStats.exitCode) {
                // FIXME: Capture stderr.
                buildPhase.exitCode = compileStats.exitCode;
                return TestResult(_name, [buildPhase]);
            }
            addStats(buildPhase.resultSamples, compileStats);

            if (i == 0) {
                // Only add executable size once, it should not vary.
                add(buildPhase.resultSamples, "exeSizeBytes", file.getSize(_name));
            }
        }

        auto runPhase = TestPhase("run");
        foreach (i; 0 .. workFactor) {
            auto runStats = executeWithStats!spawnProcess(buildPath(".", _name));
            if (runStats.exitCode) {
                runPhase.exitCode = runStats.exitCode;
                break;
            } else {
                addStats(runPhase.resultSamples, runStats);
            }
        }

        return TestResult(_name, [buildPhase, runPhase]);
    }

private:
    string _name;
    string _rootDir;
    string[] _sourceFiles;
}

struct Spec {
    string name;
    Test[] tests;
}

immutable Test delegate(string, Json)[string] testTypeMap;
shared static this() {
    testTypeMap["default"] = (d, j) => new DefaultTest(d, j);
}


Spec readSpec(string benchmarkDir) {
    import file = std.file;
    import std.exception;
    import std.path;
    import std.uni : isWhite;

    enforce(isValidPath(benchmarkDir), "Benchmark dir not valid.");
    enforce(file.exists(benchmarkDir), "Benchmark dir does not exist.");
    immutable filePath = buildPath(benchmarkDir, "dash-benchmark.json");
    enforce(file.exists(filePath), "Spec file not found in benchmark dir.");

    auto text = file.readText(filePath);
    auto json = parseJson(text);
    enforce(text.all!isWhite, "Garbage found at end of JSON spec file.");

    Spec result;
    result.name = json["name"].get!string;
    foreach (test; json["tests"]) {
        auto jt = test["type"];
        immutable typeName = jt == Json.undefined ? jt.get!string : "default";
        auto constructor = enforce(typeName in testTypeMap, "Unknown benchmark type.");
        result.tests ~= (*constructor)(benchmarkDir, test);
    }

    return result;
}
