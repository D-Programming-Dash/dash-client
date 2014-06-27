module dash.compiler.ldc;

import api = dash.api;
import dash.compiler.base;
import dash.scm;
import std.algorithm : joiner;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import file = std.file;
import std.path;
import std.process : execute, pipeProcess, Redirect, wait;
import std.range;

class LDC : Compiler {
    this(string executable) {
        _ldc2Path = executable;
    }

    override string readVersionBanner() {
        auto pipes = pipeProcess([_ldc2Path, "-version"], Redirect.stdout);
        scope (exit) enforce(wait(pipes.pid) == 0, "Unexpected LDC exit code.");

        return pipes.stdout.byLine.takeExactly(4).joiner("\n").to!string;
    }

    override string[] buildCompileCommand(string exeName, string[] sourceFiles,
        string[] versionDefines, string[string] config
    ) {
        auto cmd = buildDmdCompatibleCompileCommand(
            _ldc2Path, exeName, sourceFiles, config).appender;
        versionDefines.map!(a => "-d-version=" ~ a).copy(cmd);
        return cmd.data;
    }

private:
    string _ldc2Path;
}

class LDCGitSource : CompilerSource {
    this(string name, string workDir, string tempDir) {
        _name = name;
        _workDir = workDir;
        _tempDir = tempDir;
        _targetDir = buildPath(_workDir, _name);
        _compilerExe = buildPath(_targetDir, "bin", "ldc2");
        _compiler = new LDC(_compilerExe);
    }

    override void update(string[string] config) {
        immutable sourceDir = cloneOrFetch(config["url0"], config["version0"], _workDir);

        // TODO: Implement this using libgit2.
        file.chdir(sourceDir);
        auto submoduleUpdate =
            execute(["git", "submodule", "update", "--init", "--force", "--recursive"]);
        enforce(submoduleUpdate.status == 0,
            text("Error updating submodules: ", submoduleUpdate.output));

        // Be sure not to leave an existing out-of-date installation behind
        // in the target directory if the build fails.
        if (file.exists(_targetDir)) {
            file.rmdirRecurse(_targetDir);
        }

        immutable buildDir = buildPath(_tempDir, _name);
        enforce(!file.exists(buildDir));
        file.mkdirRecurse(buildDir);
        scope(exit) file.rmdirRecurse(buildDir);
        file.chdir(buildDir);

        auto cmake = execute(["cmake",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_INSTALL_PREFIX='" ~ _targetDir ~ "'",
            sourceDir
        ]);
        enforce(cmake.status == 0,
            text("Error on running CMake: ", cmake.output));

        auto make = execute(["make", "install"]);
        enforce(make.status == 0, text("Error on running make install: ", make.output));
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
    registerCompilerSourceFactory(api.CompilerType.ldcGit,
        (name, workDir, tempDir) => cast(CompilerSource) new LDCGitSource(name, workDir, tempDir));
}
