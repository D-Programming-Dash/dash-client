module dash.benchmark.defaulttest;

import dash.api.benchmark;
import dash.benchmark.test;
import dash.compiler.base;
import vibecompat.data.json;

class DefaultTest : Test {
    this(string rootDir, Json specData) {
        _rootDir = rootDir;
        _name = specData["name"].get!string;
        deserializeJson(_sourceFiles, specData["sourceFiles"]);
        if (auto versions = "versionDefines" in specData) {
            deserializeJson(_versionDefines, *versions);
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

        uint repetitions = 1;
        if (auto rep = "repetitions" in configStrings) {
            repetitions = to!uint(*rep);
        }

        string[string] runEnv;
        if (auto wf = "workFactor" in configStrings) {
            // Convert to double and back here to make sure the value is valid.
            auto workFactor = to!double(*wf);
            runEnv["DASH_WORK_FACTOR"] = to!string(workFactor);
        }

        file.chdir(_rootDir);

        // DMD @@BUG@@: Cannot make compileCommand immutable.
        auto compileCommand = compiler.buildCompileCommand(name,
            _sourceFiles, _versionDefines, configStrings);

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
        foreach (i; 0 .. repetitions) {
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
        foreach (i; 0 .. repetitions) {
            // Discard stdin/stdout/stderr of the child process. Note that we
            // need to re-open those on every iteration.
            version (Posix) {
                import std.stdio;
                auto nullInput = File("/dev/null", "r");
                auto nullOutput = File("/dev/null", "w");
            } else {
                static assert(false, "Benchmark I/O silencing not implemented on this OS.");
            }

            auto runStats = executeWithStats!spawnProcess(
                buildPath(".", _name), nullInput, nullOutput, nullInput, runEnv);
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
    string[] _versionDefines;
}
