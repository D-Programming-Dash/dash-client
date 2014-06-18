module dash.benchmark.test;

import dash.api.benchmark;
import dash.compiler;

interface Test {
    @property string name();
    TestResult execute(Compiler compiler, string[string] configStrings);
}
