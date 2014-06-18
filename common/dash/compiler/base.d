module dash.compiler.base;

import api = dash.api;
import std.conv : text;
import vibecompat.data.json;

interface Compiler {
    string readVersionBanner();
    string[] buildCompileCommand(string exeName, string[] sourceFiles,
    string[string] config);
}

interface CompilerSource {
    void update(string[string] config);
    Compiler getCompiler();
}

CompilerSource createCompilerSource(api.CompilerType type, string name, string workDir, string tempDir) {
    auto factory = type in _sourceTypeMap;
    enforce(factory, text("Unknown compiler source type: ", type));
    return (*factory)(name, workDir, tempDir);
}

alias SourceFactory = CompilerSource delegate(string, string, string);
package void registerCompilerSourceFactory(api.CompilerType type, SourceFactory factory) {
    enforce(type !in _sourceTypeMap, text("Compiler source type already handled: ", type));
    _sourceTypeMap[type] = factory;
}

private __gshared SourceFactory[api.CompilerType] _sourceTypeMap;
