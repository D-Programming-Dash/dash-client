Dash tester client
------------------

This repository is part of the Dash D performance tracker
project. It contains the tester client that executes the benchmarks
on the tester machine and reports the results back to the server.

Run `dub build dash-client:tester` to build the main test runner,
and `dub build dash-client:run-single` to build a helper tool for
running the tests from a given benchmark bundle in isolation.
