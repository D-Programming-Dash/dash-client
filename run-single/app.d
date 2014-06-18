int main(string[] args) {
    import dash.benchmark.spec;
    import dash.compiler;
    import std.array : array;
    import std.algorithm : map;
    import std.stdio;

    if (args.length < 4) {
        writeln("Usage: ", args[0], " <benchmarkDir> <compilerType> <compilerExe>");
        return 1;
    }

    immutable benchmarkDir = args[1];

    import dash.compiler.dmd;
    import dash.compiler.ldc;
    Compiler function(string)[string] compilerConstructors = [
        "dmd": a => new DMD(a),
        "ldc": a => new LDC(a)
    ];

    auto c = args[2] in compilerConstructors;
    if (!c) {
        writeln("Unknown compiler type, must be one of ",
            compilerConstructors.keys);
    }
    auto compiler = (*c)(args[3]);

    auto spec = readSpec(benchmarkDir);
    foreach (test; spec.tests) {
        writefln(" :: Executing %s", test.name);
        writeln(test.execute(compiler, null));
    }

    return 0;
}
