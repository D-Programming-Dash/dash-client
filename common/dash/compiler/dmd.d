module dash.compiler.dmd;

import dash.compiler.base;
import std.algorithm : canFind, find, joiner, zip;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import file = std.file;
import std.path;
import std.process : execute, pipeProcess, Redirect, wait;
import std.range;

class DMD : Compiler {
    this(string executable) {
        _dmdPath = executable;
    }

    override string readVersionBanner() {
        auto pipes = pipeProcess(_dmdPath, Redirect.stdout);
        scope (exit) enforce(wait(pipes.pid) == 1, "Unexpected DMD exit code.");

        return pipes.stdout.byLine.takeExactly(1).front.idup;
    }

    override string[] buildCompileCommand(string exeName, string[] sourceFiles,
        string[] versionDefines, string[string] config
    ) {
        auto cmd = buildDmdCompatibleCompileCommand(
            _dmdPath, exeName, sourceFiles, config).appender;
        versionDefines.map!(a => "-version=" ~ a).copy(cmd);
        return cmd.data;
    }

private:
    string _dmdPath;
}


class DMDGitSource : CompilerSource {
    this(string name, string workDir, string tempDir) {
        _name = name;
        _workDir = workDir;
        _tempDir = tempDir;
        _targetDir = buildPath(_workDir, _name);
        _compilerExe = buildPath(_targetDir, "bin", "dmd");
        _compiler = new DMD(_compilerExe);
    }

    override void update(string[string] config) {
        import dash.scm;

        immutable urls = [config["url0"], config["url1"], config["url2"]];
        immutable versions = [config["version0"], config["version1"], config["version2"]];

        auto find(string name) {
            auto result = zip(urls, versions).find!(a => a[0].canFind(name));
            enforce(!result.empty, "'" ~ name ~ "' not found in received URLs.");
            return result.front;
        }

        auto clone(typeof(find("")) spec) {
            auto dir = cloneOrFetch(spec[0], spec[1], _workDir);
            file.chdir(dir);

            // TODO: libgit2.
            auto clean = execute(["git", "clean", "-fdx"]);
            enforce(clean.status == 0,
                text("Error trying to clean '", dir, "': ", clean.output));

            return dir;
        }

        immutable dmdDir = clone(find("dmd"));
        immutable druntimeDir = clone(find("druntime"));
        immutable phobosDir = clone(find("phobos"));

        void makeInstall(string dir, string[] extraArgs = []) {
            file.chdir(dir);
            auto make = execute(["make", "-f", "posix.mak",
                "install", "INSTALL_DIR=" ~ _targetDir] ~ extraArgs);
            enforce(make.status == 0,
                text("Error on running make install in '", dir, "': ", make.output));
        }

        makeInstall(dmdDir);
        // Make sure that we don't end up with an incomplete DMD install.
        scope(failure) file.remove(_compilerExe);

        // The default config installed by the DMD makefile is actually specific
        // to the layout of the binary zip file.
        file.write(buildPath(_targetDir, "bin", "dmd.conf"), r"EOC
[Environment]
DFLAGS=-I%@P%/../import -L-L%@P%/../lib -L--export-dynamic
EOC");

        makeInstall(druntimeDir, ["DMD=" ~ _compilerExe]);

        // Fix up dependencies of install target (shared lib needs to be built).
        file.chdir(phobosDir);
        execute(["sed", "-i", "s/install2 : release/install2 : all/", "posix.mak"]);
        makeInstall(phobosDir, [
            "DMD=" ~ _compilerExe,
            "DRUNTIME_PATH=" ~ druntimeDir,
            "VERSION=" ~ buildPath(dmdDir, "VERSION")
        ]);
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
    registerCompilerSourceFactory(api.CompilerType.dmdGit,
        (name, workDir, tempDir) => cast(CompilerSource)
            new DMDGitSource(name, workDir, tempDir)
    );
}
