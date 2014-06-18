module dash.benchmark.spec;

import dash.benchmark.test;
import std.algorithm : all;
import vibecompat.data.json;

struct Spec {
    string name;
    Test[] tests;
}

immutable Test delegate(string, Json)[string] testTypeMap;
shared static this() {
    import dash.benchmark.defaulttest;
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
