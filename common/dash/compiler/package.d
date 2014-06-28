module dash.compiler;

public import dash.compiler.base;

// Pull in compilers to register them.
import dash.compiler.dmd;
import dash.compiler.gdc;
import dash.compiler.ldc;
