module dash.compiler.gdc;

import api = dash.api;
import dash.compiler.base;
import std.algorithm : joiner;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import file = std.file;
import std.path;
import std.process : execute, pipeProcess, Redirect, wait;
import std.range;

class GDC : Compiler {
    this(string executable) {
        _gdcPath = executable;
    }

    override string readVersionBanner() {
        auto pipes = pipeProcess([_gdcPath, "--version"], Redirect.stdout);
        scope (exit) enforce(wait(pipes.pid) == 0, "Unexpected GDC exit code.");

        return pipes.stdout.byLine.takeExactly(1).front.idup;
    }

    override string[] buildCompileCommand(string exeName, string[] sourceFiles,
        string[] versionDefines, string[string] config
    ) {
        import std.algorithm : copy, splitter;
        auto cmd = appender!(string[]);
        cmd ~= _gdcPath;
        cmd ~= "-o";
        cmd ~= exeName;
        sourceFiles.copy(cmd);
        if (auto dflags = "dflags" in config) {
            (*dflags).splitter(' ').copy(cmd);
        }
        versionDefines.map!(a => "-fversion=" ~ a).copy(cmd);
        return cmd.data;
    }

private:
    string _gdcPath;
}

class GDCGitSource : CompilerSource {
    this(string name, string workDir, string tempDir) {
        _name = name;
        _workDir = workDir;
        _tempDir = tempDir;
        _targetDir = buildPath(_workDir, _name);
        _compilerExe = buildPath(_targetDir, "bin", "gdc");
        _compiler = new GDC(_compilerExe);
    }

    override void update(string[string] config) {
        import dash.scm;

        // Be sure not to leave an existing out-of-date installation behind
        // in the target directory if the build fails.
        void cleanTargetDir() {
            if (file.exists(_targetDir)) {
                file.rmdirRecurse(_targetDir);
            }
        }
        cleanTargetDir();
        scope (failure) cleanTargetDir();

        immutable sourceDir =
            cloneOrFetch(config["url0"], config["version0"], _workDir);

        immutable buildRootDir = buildPath(_tempDir, _name);
        enforce(!file.exists(buildRootDir),
            "Build root '" ~ buildRootDir ~ "' already exists, please remove.");
        scope(exit) file.rmdirRecurse(buildRootDir);

        auto cpGdc = execute(["cp", "-a", sourceDir, buildRootDir]);
        enforce(cpGdc.status == 0,
            text("Error on copying GDC sources: ", cpGdc.output));
        file.chdir(buildRootDir);

        immutable gccName = "gcc-" ~ config["gdcGitGccVersion"];
        immutable archiveRoot = expandTilde(config["gdcGitGccArchiveRoot"]);
        enforce(file.exists(archiveRoot), "GCC archive root path '" ~
            archiveRoot ~ "' does not exist.");
        auto extractGcc = execute(["tar", "xzf",
            buildPath(archiveRoot, gccName ~ ".tar.gz")]);
        enforce(extractGcc.status == 0,
            text("Error on extracting GCC sources: ", extractGcc.output));

        auto runSetupGcc = execute(["./setup-gcc.sh", gccName]);
        enforce(runSetupGcc.status == 0,
            text("Error on running setup-gcc.sh: ", runSetupGcc.output));

        immutable buildWorkDir = buildPath(buildRootDir, "build");
        file.mkdirRecurse(buildWorkDir);
        file.chdir(buildWorkDir);

        auto configure = execute([buildPath("..", gccName, "configure"),
            "--disable-bootstrap",
            "--disable-libgomp",
            "--disable-libmudflap",
            "--disable-libquadmath",
            "--disable-multilib",
            "--disable-nls",
            "--enable-checking=release",
            "--enable-languages=d",
            "--prefix=" ~ _targetDir
        ]);
        enforce(configure.status == 0,
            text("Error on configure: ", configure.output));

        auto make = execute(["make"]);
        enforce(make.status == 0,
            text("Error on running make: ", make.output));

        auto install = execute(["make", "install"]);
        enforce(install.status == 0,
            text("Error on running make install: ", install.output));
    }

    override Compiler getCompiler() {
        if (!file.exists(_compilerExe)) return null;
        return _compiler;
    }

private:
    immutable string _name;
    immutable string _workDir;
    immutable string _tempDir;
    immutable string _targetDir;
    immutable string _compilerExe;
    Compiler _compiler;
}

shared static this() {
    // DMD @@BUG@@: Interface upcast is not inserted without explicit cast.
    registerCompilerSourceFactory(api.CompilerType.gdcGit,
        (name, workDir, tempDir) => cast(CompilerSource)
            new GDCGitSource(name, workDir, tempDir)
    );
}
